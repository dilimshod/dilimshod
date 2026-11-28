package uz.roadvis.core

import kotlin.math.min

/**
 * Local storage, auto-deletion and upload rules of the continuous-learning samples (`docs/TRAINING_API.md` §2).
 * Pure logic; the app does the file and network work.
 */
object LearningStorePolicy {
    /** Samples older than this are deleted. */
    const val MAX_AGE_DAYS = 14
    const val MAX_AGE_MILLIS: Long = MAX_AGE_DAYS * 24L * 60 * 60 * 1000
    /** Storage cap choices of the settings, megabytes, and the default. */
    val STORAGE_LIMIT_CHOICES_MB: List<Int> = listOf(100, 300, 1000)
    const val DEFAULT_STORAGE_LIMIT_MB = 300
    /** At most this many samples per upload run. */
    const val UPLOAD_BATCH_SIZE = 20
    /** The server rejects larger images (HTTP 413). */
    const val MAX_UPLOAD_BYTES: Long = 2L * 1024 * 1024
    /** Exponential back-off after failed uploads: 1, 2, 4 … minutes, capped. */
    const val MAX_BACKOFF_MINUTES = 60L
    /** Saved JPEG: long side and quality (0–100). */
    const val JPEG_LONG_SIDE = 960
    const val JPEG_QUALITY = 80

    /** One stored sample (`<id>.jpg` + `<id>.json`). */
    data class StoredSample(val id: String, val bytes: Long, val createdAtMillis: Long)

    /** Samples to delete: [expired] (older than [MAX_AGE_DAYS]) and [overLimit] (oldest first until under the cap). */
    data class Retention(val expired: List<String>, val overLimit: List<String>) {
        val all: List<String> get() = expired + overLimit
    }

    fun limitBytes(megabytes: Int): Long = normalizedLimitMb(megabytes).toLong() * 1024 * 1024

    /** A stored limit that is not one of the choices falls back to the default. */
    fun normalizedLimitMb(megabytes: Int): Int =
        if (megabytes in STORAGE_LIMIT_CHOICES_MB) megabytes else DEFAULT_STORAGE_LIMIT_MB

    fun retention(samples: List<StoredSample>, limitBytes: Long, nowMillis: Long): Retention {
        val expired = ArrayList<String>()
        val kept = ArrayList<StoredSample>()
        for (s in samples) {
            if (nowMillis - s.createdAtMillis > MAX_AGE_MILLIS) expired.add(s.id) else kept.add(s)
        }
        var total = kept.sumOf { it.bytes }
        val overLimit = ArrayList<String>()
        if (total > limitBytes) {
            for (s in kept.sortedWith(compareBy<StoredSample> { it.createdAtMillis }.thenBy { it.id })) {
                if (total <= limitBytes) break
                overLimit.add(s.id)
                total -= s.bytes
            }
        }
        return Retention(expired, overLimit)
    }

    /** The next upload batch: oldest first, at most [UPLOAD_BATCH_SIZE]. */
    fun uploadBatch(samples: List<StoredSample>): List<StoredSample> =
        samples.sortedWith(compareBy<StoredSample> { it.createdAtMillis }.thenBy { it.id }).take(UPLOAD_BATCH_SIZE)

    /** Back-off before the next attempt after [consecutiveFailures] failed runs (0 → none), minutes. */
    fun backoffMinutes(consecutiveFailures: Int): Long {
        if (consecutiveFailures <= 0) return 0
        if (consecutiveFailures > 7) return MAX_BACKOFF_MINUTES
        return min(MAX_BACKOFF_MINUTES, 1L shl (consecutiveFailures - 1))
    }

    /** What to do with a sample after an upload attempt answered with an HTTP status. */
    enum class UploadOutcome {
        /** 201 created / 409 duplicate: the server has it — delete it locally. */
        UPLOADED,
        /** 413 too large / 422 invalid meta: the server will never take it — delete it, keep going. */
        REJECTED,
        /** 401 bad token: stop the run until the user fixes the token. */
        UNAUTHORIZED,
        /** 429 rate limit, 5xx, anything else: keep the sample, stop the run and back off. */
        RETRY_LATER,
    }

    fun outcome(httpStatus: Int): UploadOutcome = when (httpStatus) {
        201, 409 -> UploadOutcome.UPLOADED
        413, 422 -> UploadOutcome.REJECTED
        401 -> UploadOutcome.UNAUTHORIZED
        else -> UploadOutcome.RETRY_LATER
    }

    /** Upload is allowed only with the feature on, on a suitable network, and while the camera screen is not active. */
    fun mayUpload(enabled: Boolean, wifiOnly: Boolean, onUnmeteredNetwork: Boolean, connected: Boolean,
                  cameraActive: Boolean): Boolean =
        enabled && connected && !cameraActive && (!wifiOnly || onUnmeteredNetwork)
}
