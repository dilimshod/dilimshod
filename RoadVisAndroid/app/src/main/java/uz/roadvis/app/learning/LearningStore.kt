package uz.roadvis.app.learning

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uz.roadvis.core.LearningStorePolicy
import java.io.File

/**
 * Collected samples in `filesDir/learning/pending` (`docs/TRAINING_API.md` §2): `<uuid>.jpg` + `<uuid>.json`.
 * A sample is complete once its JSON exists (the JPEG is written first, both through a temp file + rename).
 * All file operations take one process-wide lock (collector, uploader and settings screen run on different threads).
 */
class LearningStore(context: Context) {
    private val appContext = context.applicationContext
    val dir: File = File(appContext.filesDir, "learning/pending")

    fun jpegFile(id: String) = File(dir, "$id.jpg")
    fun jsonFile(id: String) = File(dir, "$id.json")

    /** Complete samples; incomplete leftovers older than [ORPHAN_AGE_MS] are deleted. */
    fun samples(nowMillis: Long = System.currentTimeMillis()): List<LearningStorePolicy.StoredSample> = synchronized(LOCK) {
        val files = dir.listFiles() ?: return emptyList()
        val result = ArrayList<LearningStorePolicy.StoredSample>()
        for (f in files) {
            val name = f.name
            when {
                name.endsWith(".json") -> {
                    val id = name.removeSuffix(".json")
                    val jpg = jpegFile(id)
                    if (jpg.exists()) {
                        result.add(LearningStorePolicy.StoredSample(id, f.length() + jpg.length(), f.lastModified()))
                    } else if (nowMillis - f.lastModified() > ORPHAN_AGE_MS) {
                        f.delete()
                    }
                }
                name.endsWith(".jpg") -> {
                    if (!jsonFile(name.removeSuffix(".jpg")).exists() && nowMillis - f.lastModified() > ORPHAN_AGE_MS) f.delete()
                }
                else -> if (nowMillis - f.lastModified() > ORPHAN_AGE_MS) f.delete()
            }
        }
        result
    }

    /** Writes one sample (JPEG first, JSON last). Returns false on an I/O error (nothing half-written stays). */
    fun write(id: String, jpeg: ByteArray, json: String): Boolean = synchronized(LOCK) {
        try {
            dir.mkdirs()
            writeAtomically(jpegFile(id), jpeg)
            writeAtomically(jsonFile(id), json.toByteArray(Charsets.UTF_8))
            true
        } catch (_: Exception) {
            jpegFile(id).delete()
            jsonFile(id).delete()
            false
        }
    }

    fun delete(id: String) = synchronized(LOCK) {
        jsonFile(id).delete()
        jpegFile(id).delete()
    }

    /** Deletes every collected frame; returns how many samples there were. */
    fun deleteAll(): Int = synchronized(LOCK) {
        val count = samples().size
        dir.listFiles()?.forEach { it.delete() }
        count
    }

    /** Deletes expired samples and the oldest ones over the storage cap; counts them as "deleted by limit". */
    fun applyRetention(limitMb: Int, nowMillis: Long = System.currentTimeMillis()): Int = synchronized(LOCK) {
        val r = LearningStorePolicy.retention(samples(nowMillis), LearningStorePolicy.limitBytes(limitMb), nowMillis)
        for (id in r.all) delete(id)
        if (r.all.isNotEmpty()) LearningStatus.addDeletedByLimit(appContext, r.all.size)
        r.all.size
    }

    private fun writeAtomically(target: File, bytes: ByteArray) {
        val tmp = File(target.parentFile, target.name + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) {
                tmp.delete()
                throw java.io.IOException("rename failed: ${target.name}")
            }
        }
    }

    companion object {
        private val LOCK = Any()
        private const val ORPHAN_AGE_MS = 10 * 60 * 1000L
    }
}

/**
 * Status rows of the continuous-learning settings section, persisted in the "roadvis" SharedPreferences with
 * `rv.learning.` keys. Writers may run on any thread; Compose state is refreshed on the main thread.
 */
object LearningStatus {
    private const val K_UPLOADED = "rv.learning.uploadedTotal"
    private const val K_DELETED_QUALITY = "rv.learning.deletedQuality"
    private const val K_DELETED_LIMIT = "rv.learning.deletedLimit"
    private const val K_LAST_UPLOAD = "rv.learning.lastUploadMillis"
    private const val K_LAST_ERROR = "rv.learning.lastError"
    private const val K_FAILURES = "rv.learning.uploadFailures"
    private const val K_NEXT_ATTEMPT = "rv.learning.nextAttemptMillis"

    private val main = Handler(Looper.getMainLooper())

    var pendingCount by mutableIntStateOf(0); private set
    var pendingBytes by mutableLongStateOf(0L); private set
    var uploadedTotal by mutableIntStateOf(0); private set
    var deletedByQuality by mutableIntStateOf(0); private set
    var deletedByLimit by mutableIntStateOf(0); private set
    var lastUploadMillis by mutableLongStateOf(0L); private set
    var lastError by mutableStateOf<String?>(null); private set
    /** Result line of the last "Upload now" / "Check for model update" action (not persisted). */
    var actionMessage by mutableStateOf<String?>(null)

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    @Synchronized private fun add(context: Context, key: String, n: Int) {
        val p = prefs(context)
        p.edit().putInt(key, p.getInt(key, 0) + n).apply()
        refresh(context, files = false)
    }

    fun addUploaded(context: Context, n: Int) = add(context, K_UPLOADED, n)
    fun addDeletedByQuality(context: Context, n: Int) = add(context, K_DELETED_QUALITY, n)
    fun addDeletedByLimit(context: Context, n: Int) = add(context, K_DELETED_LIMIT, n)

    /** A run that uploaded something: clears the error and the back-off. */
    @Synchronized fun recordSuccess(context: Context, nowMillis: Long) {
        prefs(context).edit().putLong(K_LAST_UPLOAD, nowMillis).remove(K_LAST_ERROR).putInt(K_FAILURES, 0)
            .putLong(K_NEXT_ATTEMPT, 0).apply()
        refresh(context, files = false)
    }

    /** A failed run: stores the error and the next allowed attempt; returns the back-off in minutes. */
    @Synchronized fun recordFailure(context: Context, message: String, nowMillis: Long): Long {
        val p = prefs(context)
        val failures = p.getInt(K_FAILURES, 0) + 1
        val minutes = LearningStorePolicy.backoffMinutes(failures)
        p.edit().putString(K_LAST_ERROR, message).putInt(K_FAILURES, failures)
            .putLong(K_NEXT_ATTEMPT, nowMillis + minutes * 60_000L).apply()
        refresh(context, files = false)
        return minutes
    }

    /** An error that is not a network failure (no token, bad URL…): shown, no back-off. */
    fun recordError(context: Context, message: String?) {
        prefs(context).edit().apply { if (message == null) remove(K_LAST_ERROR) else putString(K_LAST_ERROR, message) }.apply()
        refresh(context, files = false)
    }

    fun nextAttemptMillis(context: Context): Long = prefs(context).getLong(K_NEXT_ATTEMPT, 0)

    /** Re-reads the counters (and, with [files], the pending samples) and publishes them to Compose. */
    fun refresh(context: Context, files: Boolean = true) {
        val p = prefs(context)
        val uploaded = p.getInt(K_UPLOADED, 0)
        val quality = p.getInt(K_DELETED_QUALITY, 0)
        val limit = p.getInt(K_DELETED_LIMIT, 0)
        val last = p.getLong(K_LAST_UPLOAD, 0)
        val error = p.getString(K_LAST_ERROR, null)
        val samples = if (files) LearningStore(context).samples() else null
        main.post {
            uploadedTotal = uploaded
            deletedByQuality = quality
            deletedByLimit = limit
            lastUploadMillis = last
            lastError = error
            if (samples != null) {
                pendingCount = samples.size
                pendingBytes = samples.sumOf { it.bytes }
            }
        }
    }

    fun postActionMessage(message: String?) {
        main.post { actionMessage = message }
    }
}
