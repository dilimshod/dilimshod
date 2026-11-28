package uz.roadvis.app.learning

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.l10n.L
import uz.roadvis.app.roaddata.Http
import uz.roadvis.app.settings.validatedUrl
import uz.roadvis.core.LearningStorePolicy
import uz.roadvis.core.ModelUpdatePolicy
import java.io.ByteArrayOutputStream
import java.util.UUID

/** WorkManager entry point of the sample upload (periodic, "Upload now", back-off retries). */
class LearningUploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val settings = LearningFeature.settings(applicationContext) ?: return Result.retry()
        LearningUploader(applicationContext, settings).run(force = inputData.getBoolean(KEY_FORCE, false))
        return Result.success()
    }

    companion object {
        const val KEY_FORCE = "force"
    }
}

/**
 * Uploads collected samples to `POST /api/v1/samples` (`docs/TRAINING_API.md` §2–3): oldest first, at most
 * [LearningStorePolicy.UPLOAD_BATCH_SIZE] per run, multipart `image` + `meta`, `Authorization: Bearer <token>`.
 * 201 / 409 delete the sample at once; 413 / 422 delete it as rejected; 401 stops the run; anything else (429, 5xx,
 * network) stops the run with exponential back-off (1, 2, 4 … 60 min). Never while the camera screen is active.
 */
class LearningUploader(private val context: Context, private val settings: AppSettings) {
    enum class Outcome { DISABLED, CAMERA_ACTIVE, BACKING_OFF, NOTHING_TO_DO, UPLOADED, FAILED }

    private val store = LearningStore(context)

    suspend fun run(force: Boolean): Outcome = withContext(Dispatchers.IO) {
        if (!settings.learningEnabled) return@withContext Outcome.DISABLED
        val now = System.currentTimeMillis()
        store.applyRetention(settings.learningStorageLimitMb, now)
        LearningStatus.refresh(context)
        if (LearningFeature.isCameraScreenActive(context)) {
            if (force) LearningStatus.postActionMessage(L("learning.error.cameraActive"))
            return@withContext Outcome.CAMERA_ACTIVE
        }
        if (!force && now < LearningStatus.nextAttemptMillis(context)) return@withContext Outcome.BACKING_OFF
        val base = validatedUrl(settings.learningServerUrl)
        if (base == null) {
            LearningStatus.recordError(context, L("navset.badURL"))
            return@withContext Outcome.FAILED
        }
        val token = settings.deviceToken
        if (token.isEmpty()) {
            LearningStatus.recordError(context, L("learning.error.noToken"))
            return@withContext Outcome.FAILED
        }
        val all = store.samples()
        val batch = LearningStorePolicy.uploadBatch(all)
        if (batch.isEmpty()) {
            if (force) LearningStatus.postActionMessage(L("learning.uploadNow.empty"))
            return@withContext Outcome.NOTHING_TO_DO
        }

        val url = ModelUpdatePolicy.samplesUrl(base)
        val headers = mapOf("Authorization" to "Bearer $token", "User-Agent" to userAgent(context))
        var uploaded = 0
        var rejected = 0
        var failure: String? = null
        var unauthorized = false
        for (sample in batch) {
            if (LearningFeature.isCameraScreenActive(context)) break
            val jpeg = try { store.jpegFile(sample.id).readBytes() } catch (_: Exception) { null }
            val meta = try { store.jsonFile(sample.id).readText() } catch (_: Exception) { null }
            if (jpeg == null || meta == null) continue
            if (jpeg.size > LearningStorePolicy.MAX_UPLOAD_BYTES) {
                store.delete(sample.id)
                rejected += 1
                continue
            }
            val boundary = "RoadVis-" + UUID.randomUUID().toString()
            val body = multipart(boundary, sample.id, jpeg, sanitizedMeta(meta))
            val status = try {
                Http.post(url, body, "multipart/form-data; boundary=$boundary", timeoutMs = 60_000, headers = headers).status
            } catch (e: Exception) {
                failure = Http.describe(e)
                break
            }
            when (LearningStorePolicy.outcome(status)) {
                LearningStorePolicy.UploadOutcome.UPLOADED -> {
                    store.delete(sample.id)
                    uploaded += 1
                }
                LearningStorePolicy.UploadOutcome.REJECTED -> {
                    store.delete(sample.id)
                    rejected += 1
                }
                LearningStorePolicy.UploadOutcome.UNAUTHORIZED -> {
                    unauthorized = true
                    failure = L("learning.error.token")
                    break
                }
                LearningStorePolicy.UploadOutcome.RETRY_LATER -> {
                    failure = "HTTP $status"
                    break
                }
            }
        }

        val done = System.currentTimeMillis()
        if (uploaded > 0) LearningStatus.addUploaded(context, uploaded)
        if (rejected > 0) LearningStatus.addDeletedByQuality(context, rejected)
        val outcome: Outcome
        if (failure != null) {
            val minutes = LearningStatus.recordFailure(context, failure, done)
            // A rejected token needs the user; the periodic run tries again after the back-off anyway.
            if (!unauthorized) LearningFeature.scheduleUploadRetry(context, settings, minutes)
            outcome = Outcome.FAILED
        } else {
            if (uploaded > 0) LearningStatus.recordSuccess(context, done)
            // More waiting: the next batch in a minute (still under the same network constraint).
            if (all.size > batch.size) LearningFeature.scheduleUploadRetry(context, settings, 1)
            outcome = if (uploaded > 0) Outcome.UPLOADED else Outcome.NOTHING_TO_DO
        }
        if (force) LearningStatus.postActionMessage(failure ?: L("learning.uploadNow.done", uploaded))
        LearningStatus.refresh(context)
        outcome
    }

    /** Drops `lat` / `lon` when "send location" is off now (the setting may have changed after collection). */
    private fun sanitizedMeta(text: String): ByteArray {
        if (settings.learningSendLocation) return text.toByteArray(Charsets.UTF_8)
        return try {
            val o = JSONObject(text)
            o.remove("lat")
            o.remove("lon")
            o.toString().toByteArray(Charsets.UTF_8)
        } catch (_: Exception) {
            text.toByteArray(Charsets.UTF_8)
        }
    }

    companion object {
        /** `RoadVis-Android/<version>` (contract §3). */
        fun userAgent(context: Context): String {
            val version = try {
                context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "1.0"
            } catch (_: Exception) {
                "1.0"
            }
            return "RoadVis-Android/$version"
        }

        /** multipart/form-data with the parts `image` (image/jpeg) and `meta` (application/json). */
        fun multipart(boundary: String, id: String, jpeg: ByteArray, meta: ByteArray): ByteArray {
            val out = ByteArrayOutputStream(jpeg.size + meta.size + 512)
            fun line(s: String) = out.write((s + "\r\n").toByteArray(Charsets.UTF_8))
            line("--$boundary")
            line("Content-Disposition: form-data; name=\"image\"; filename=\"$id.jpg\"")
            line("Content-Type: image/jpeg")
            line("")
            out.write(jpeg)
            line("")
            line("--$boundary")
            line("Content-Disposition: form-data; name=\"meta\"")
            line("Content-Type: application/json")
            line("")
            out.write(meta)
            line("")
            line("--$boundary--")
            return out.toByteArray()
        }
    }
}
