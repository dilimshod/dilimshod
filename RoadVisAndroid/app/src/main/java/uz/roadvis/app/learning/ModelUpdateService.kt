package uz.roadvis.app.learning

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.l10n.L
import uz.roadvis.app.roaddata.Http
import uz.roadvis.app.settings.validatedUrl
import uz.roadvis.core.ModelManifest
import uz.roadvis.core.ModelUpdatePolicy
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * State of the downloaded detector models (`docs/TRAINING_API.md` "App model update rules"): the active version,
 * the versions that failed (never used again), the last manifest check, and what the settings show about the model.
 * Models live in `filesDir/models/<version>/yolo-roadvis.onnx`; the bundled asset stays the permanent fallback.
 *
 * [generation] changes on every switch or revert; the detector compares it per frame and reloads.
 */
object ModelStore {
    private const val K_ACTIVE = "rv.learning.model.active"
    private const val K_BAD = "rv.learning.model.bad"
    private const val K_LAST_CHECK = "rv.learning.model.lastCheck"
    private const val K_INFO = "rv.learning.model.info"

    @Volatile var generation: Int = 0
        private set

    /** What the downloaded model is, for the settings screen. */
    data class Info(val version: String, val createdAt: String?, val map50: Double?)

    /** Active downloaded model shown in the settings (null = bundled). Main-thread Compose state. */
    var shownInfo by mutableStateOf<Info?>(null)
        private set

    private val main = Handler(Looper.getMainLooper())

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    fun modelsDir(context: Context) = File(context.applicationContext.filesDir, "models")
    fun modelFile(context: Context, version: String) = File(File(modelsDir(context), version), ModelUpdatePolicy.ANDROID_MODEL_FILE)

    fun badVersions(context: Context): List<String> =
        prefs(context).getString(K_BAD, "")!!.split(',').map { it.trim() }.filter { it.isNotEmpty() }

    fun activeVersion(context: Context): String? = prefs(context).getString(K_ACTIVE, null)

    /** The downloaded model the detector should use now, or null for the bundled asset. */
    fun effectiveModel(context: Context): Pair<String, File>? {
        val version = ModelUpdatePolicy.effectiveVersion(activeVersion(context), badVersions(context).toSet()) { v ->
            val f = modelFile(context, v)
            f.isFile && f.length() > 0
        } ?: return null
        return version to modelFile(context, version)
    }

    fun lastCheckMillis(context: Context): Long? = prefs(context).getLong(K_LAST_CHECK, 0).takeIf { it > 0 }
    fun setLastCheck(context: Context, millis: Long) = prefs(context).edit().putLong(K_LAST_CHECK, millis).apply()

    /**
     * Atomic switch: the verified temp folder becomes `models/<version>` (rename on one file system), then one
     * synchronous preferences commit makes it active. Older version folders are deleted afterwards.
     */
    @Synchronized fun activate(context: Context, version: String, verifiedDir: File, manifest: ModelManifest): Boolean {
        val target = File(modelsDir(context), version)
        if (target.exists()) target.deleteRecursively()
        if (!verifiedDir.renameTo(target)) return false
        val info = JSONObject().put("version", version).put("createdAt", manifest.createdAt ?: JSONObject.NULL)
            .put("map50", manifest.metrics?.map50 ?: JSONObject.NULL)
        if (!prefs(context).edit().putString(K_ACTIVE, version).putString(K_INFO, info.toString()).commit()) return false
        generation += 1
        modelsDir(context).listFiles()?.forEach { if (it.name != version) it.deleteRecursively() }
        refresh(context)
        return true
    }

    /** Reverts to the bundled model and remembers [version] as bad (load failure or no output for 30 s). */
    @Synchronized fun markBad(context: Context, version: String) {
        val bad = ModelUpdatePolicy.markBad(badVersions(context), version)
        val edit = prefs(context).edit().putString(K_BAD, bad.joinToString(","))
        if (activeVersion(context) == version) edit.remove(K_ACTIVE).remove(K_INFO)
        edit.commit()
        generation += 1
        File(modelsDir(context), version).deleteRecursively()
        refresh(context)
    }

    fun refresh(context: Context) {
        val p = prefs(context)
        val info = if (effectiveModel(context) == null) null else try {
            val o = JSONObject(p.getString(K_INFO, null) ?: "{}")
            Info(o.getString("version"), o.optString("createdAt").takeIf { it.isNotEmpty() && it != "null" },
                if (o.isNull("map50")) null else o.optDouble("map50"))
        } catch (_: Exception) {
            activeVersion(context)?.let { Info(it, null, null) }
        }
        main.post { shownInfo = info }
    }
}

/** WorkManager entry point of the daily manifest check (Wi-Fi only) and of "Check for model update". */
class ModelUpdateWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val settings = LearningFeature.settings(applicationContext) ?: return Result.retry()
        val force = inputData.getBoolean(LearningUploadWorker.KEY_FORCE, false)
        val result = ModelUpdater(applicationContext, settings).check(force)
        if (force) LearningStatus.postActionMessage(result.message)
        return Result.success()
    }
}

/**
 * Checks `GET /api/v1/model/latest?platform=android`, downloads a new `.onnx` into a temp folder, verifies its size
 * and sha256, test-opens an ONNX Runtime session (one inference on a zero image at the smallest manifest input) and
 * only then switches atomically ([ModelStore.activate]).
 */
class ModelUpdater(private val context: Context, private val settings: AppSettings) {
    sealed class Result(val message: String) {
        class UpToDate : Result(L("learning.model.upToDate"))
        class NoModel : Result(L("learning.model.none"))
        class Updated(version: String) : Result(L("learning.model.updated", version))
        class Skipped : Result("")
        class Failed(reason: String) : Result(L("learning.model.failed", reason))
    }

    suspend fun check(force: Boolean): Result = withContext(Dispatchers.IO) {
        if (!force && !(settings.learningEnabled && settings.learningDownloadModels)) return@withContext Result.Skipped()
        val now = System.currentTimeMillis()
        if (!force && !ModelUpdatePolicy.isCheckDue(now, ModelStore.lastCheckMillis(context))) return@withContext Result.Skipped()
        val base = validatedUrl(settings.learningServerUrl) ?: return@withContext Result.Failed(L("navset.badURL"))
        val token = settings.learningToken.trim()
        if (token.isEmpty()) return@withContext Result.Failed(L("learning.error.noToken"))
        val headers = mapOf("Authorization" to "Bearer $token", "User-Agent" to LearningUploader.userAgent(context))
        val response = try {
            Http.get(ModelUpdatePolicy.latestUrl(base), headers = headers)
        } catch (e: Exception) {
            return@withContext Result.Failed(Http.describe(e))
        }
        ModelStore.setLastCheck(context, now)
        when (response.status) {
            204 -> return@withContext Result.NoModel()
            401 -> return@withContext Result.Failed(L("learning.error.token"))
            200 -> {}
            else -> return@withContext Result.Failed("HTTP ${response.status}")
        }
        val manifest = ModelManifest.parse(response.text) ?: return@withContext Result.Failed("manifest")
        val active = ModelStore.activeVersion(context)
        if (!ModelUpdatePolicy.shouldDownload(manifest, active, ModelStore.badVersions(context).toSet())) {
            return@withContext Result.UpToDate()
        }
        val android = manifest.android ?: return@withContext Result.UpToDate()
        val tempDir = File(ModelStore.modelsDir(context), ".download-${manifest.version}")
        try {
            tempDir.deleteRecursively()
            tempDir.mkdirs()
            val file = File(tempDir, ModelUpdatePolicy.ANDROID_MODEL_FILE)
            val sha = download(ModelUpdatePolicy.fileUrl(base, manifest.version, android.file.path), headers, file,
                android.file.size)
            if (file.length() != android.file.size) return@withContext Result.Failed("size")
            if (!ModelUpdatePolicy.sha256Matches(android.file.sha256, sha)) return@withContext Result.Failed("sha256")
            testOpen(file, android.inputs)?.let { return@withContext Result.Failed(it) }
            if (!ModelStore.activate(context, manifest.version, tempDir, manifest)) return@withContext Result.Failed("switch")
            Result.Updated(manifest.version)
        } catch (e: Exception) {
            Result.Failed(if (e is Http.NetworkException) Http.describe(e) else (e.message ?: e.javaClass.simpleName))
        } finally {
            if (tempDir.exists()) tempDir.deleteRecursively()
        }
    }

    /** Streams the file to [target] and returns its sha256 (hex). Aborts beyond [expectedSize]. */
    private fun download(url: String, headers: Map<String, String>, target: File, expectedSize: Long): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 60_000
            connection.instanceFollowRedirects = true
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            val status = connection.responseCode
            if (status != 200) throw IOException("HTTP $status")
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            connection.inputStream.use { input ->
                target.outputStream().use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n
                        if (total > expectedSize || total > ModelUpdatePolicy.MAX_MODEL_BYTES) throw IOException("size")
                        digest.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                    }
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Opens the model with ONNX Runtime at the smallest manifest input (dynamic axes pinned like the detector does)
     * and runs one zero image; null when it works, else the reason.
     */
    private fun testOpen(file: File, inputs: List<ModelManifest.InputSize>): String? {
        val size = inputs.minByOrNull { it.width * it.height } ?: ModelManifest.InputSize(640, 384)
        return try {
            val env = OrtEnvironment.getEnvironment()
            val options = OrtSession.SessionOptions().apply {
                setSymbolicDimensionValue("batch", 1)
                setSymbolicDimensionValue("height", size.height.toLong())
                setSymbolicDimensionValue("width", size.width.toLong())
                setIntraOpNumThreads(2)
            }
            env.createSession(file.absolutePath, options).use { session ->
                val name = session.inputNames.firstOrNull() ?: return "input"
                val count = 3 * size.width * size.height
                val buffer = ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
                OnnxTensor.createTensor(env, buffer, longArrayOf(1, 3, size.height.toLong(), size.width.toLong())).use { tensor ->
                    session.run(mapOf(name to tensor)).use { result ->
                        val out = result.get(0) as? OnnxTensor ?: return "output"
                        val shape = out.info.shape
                        if (shape.size != 3 || shape.any { it <= 0 }) return "output shape"
                    }
                }
            }
            null
        } catch (t: Throwable) {
            t.message ?: t.javaClass.simpleName
        }
    }
}
