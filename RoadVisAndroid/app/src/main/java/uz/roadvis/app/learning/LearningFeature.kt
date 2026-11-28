package uz.roadvis.app.learning

import android.content.Context
import android.os.SystemClock
import androidx.compose.runtime.snapshotFlow
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.RoadVisApp
import uz.roadvis.app.app.AppMode
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.AppState
import java.util.concurrent.TimeUnit

/** Called once from [AppState.start]: drive-start hook, background work scheduling, status refresh. */
fun installLearning(app: AppState) {
    LearningFeature.install(app)
}

/**
 * Process-wide glue of the continuous-learning feature (`RoadVis/docs/TRAINING_API.md`): the flags the collector and
 * the background workers share, and the WorkManager schedule that follows the settings.
 */
object LearningFeature {
    /** Incremented on every drive start ("Поехали"); the collector resets its per-trip counter when it changes. */
    @Volatile var tripGeneration: Int = 0
        private set
    /** True while the camera screen wants frames processed (set by the recognition controller). */
    @Volatile var cameraProcessing: Boolean = false
    /** `SystemClock.elapsedRealtime()` of the last processed camera frame. */
    @Volatile var lastFrameElapsedMs: Long = 0L

    const val UPLOAD_PERIODIC = "rv.learning.upload"
    const val UPLOAD_NOW = "rv.learning.uploadNow"
    const val UPLOAD_RETRY = "rv.learning.uploadRetry"
    const val MODEL_PERIODIC = "rv.learning.modelCheck"
    const val MODEL_NOW = "rv.learning.modelCheckNow"

    /** Uploads run hourly (WorkManager's minimum is 15 min); back-off retries are scheduled as one-time work. */
    private const val UPLOAD_INTERVAL_MINUTES = 60L
    /** Frames older than this no longer count as "camera active" (the activity stopped without a pause). */
    private const val CAMERA_STALE_MS = 5_000L

    private var installed = false

    fun install(app: AppState) {
        if (installed) return
        installed = true
        app.bus.onDriveStarted += { tripGeneration += 1 }
        val s = app.settings
        MainScope().launch {
            snapshotFlow { listOf(s.learningEnabled, s.learningWifiOnly, s.learningDownloadModels) }.collect {
                reschedule(app.context, s)
            }
        }
        MainScope().launch {
            withContext(Dispatchers.IO) {
                LearningStore(app.context).applyRetention(s.learningStorageLimitMb)
                LearningStatus.refresh(app.context)
                ModelStore.refresh(app.context)
            }
        }
    }

    /** The app's settings (null if the application object is not set up yet). */
    fun settings(context: Context): AppSettings? = (context.applicationContext as? RoadVisApp)?.stateOrNull?.settings

    /**
     * True while the camera screen is shown and processing frames: no uploads then (contract §2). The background
     * worker cannot rely on [AppState.mode] alone (it stays CAMERA while the app is in the background), so the
     * controller's processing flag and the time of the last processed frame are combined with it.
     */
    fun isCameraScreenActive(context: Context): Boolean {
        val mode = (context.applicationContext as? RoadVisApp)?.stateOrNull?.mode
        if (mode != null && mode != AppMode.CAMERA) return false
        return cameraProcessing && SystemClock.elapsedRealtime() - lastFrameElapsedMs < CAMERA_STALE_MS
    }

    private fun uploadConstraints(wifiOnly: Boolean): Constraints = Constraints.Builder()
        .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .build()

    /** Model downloads always wait for Wi-Fi (an unmetered network). */
    private val modelConstraints: Constraints
        get() = Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).setRequiresBatteryNotLow(true).build()

    /** Enqueues or cancels the periodic upload and model-check work for the current settings. */
    fun reschedule(context: Context, s: AppSettings) {
        val wm = try { WorkManager.getInstance(context) } catch (_: Exception) { return }
        if (!s.learningEnabled) {
            wm.cancelUniqueWork(UPLOAD_PERIODIC)
            wm.cancelUniqueWork(UPLOAD_RETRY)
            wm.cancelUniqueWork(MODEL_PERIODIC)
            return
        }
        val upload = PeriodicWorkRequestBuilder<LearningUploadWorker>(UPLOAD_INTERVAL_MINUTES, TimeUnit.MINUTES)
            .setConstraints(uploadConstraints(s.learningWifiOnly))
            .setInitialDelay(15, TimeUnit.MINUTES)
            .build()
        wm.enqueueUniquePeriodicWork(UPLOAD_PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, upload)
        if (s.learningDownloadModels) {
            val check = PeriodicWorkRequestBuilder<ModelUpdateWorker>(1, TimeUnit.DAYS)
                .setConstraints(modelConstraints)
                .setInitialDelay(1, TimeUnit.HOURS)
                .build()
            wm.enqueueUniquePeriodicWork(MODEL_PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, check)
        } else {
            wm.cancelUniqueWork(MODEL_PERIODIC)
        }
    }

    /** "Upload now": one run that ignores the back-off (still on Wi-Fi only when that setting is on). */
    fun uploadNow(context: Context, s: AppSettings) {
        val request = OneTimeWorkRequestBuilder<LearningUploadWorker>()
            .setConstraints(Constraints.Builder()
                .setRequiredNetworkType(if (s.learningWifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED).build())
            .setInputData(workDataOf(LearningUploadWorker.KEY_FORCE to true))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(UPLOAD_NOW, ExistingWorkPolicy.REPLACE, request)
    }

    /** "Check for model update": one manifest check now (Wi-Fi only when that setting is on). */
    fun checkModelNow(context: Context, s: AppSettings) {
        val request = OneTimeWorkRequestBuilder<ModelUpdateWorker>()
            .setConstraints(Constraints.Builder()
                .setRequiredNetworkType(if (s.learningWifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED).build())
            .setInputData(workDataOf(LearningUploadWorker.KEY_FORCE to true))
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(MODEL_NOW, ExistingWorkPolicy.REPLACE, request)
    }

    /** One upload run after [delayMinutes] (back-off retry or the next batch). */
    fun scheduleUploadRetry(context: Context, s: AppSettings, delayMinutes: Long) {
        val request = OneTimeWorkRequestBuilder<LearningUploadWorker>()
            .setConstraints(uploadConstraints(s.learningWifiOnly))
            .setInitialDelay(delayMinutes, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(UPLOAD_RETRY, ExistingWorkPolicy.REPLACE, request)
    }
}
