package uz.roadvis.app.trips

import android.app.ActivityManager
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import uz.roadvis.app.app.AppMode
import uz.roadvis.app.app.AppState

/** Called once from [AppState.start] (after permissions): create the feature's controllers, register bus hooks. */
fun installTrips(app: AppState) {
    TripsFeature.get(app).install()
}

/** Process-wide access to the trips controller (created lazily, also by the sheets before [installTrips]). */
object TripsFeature {
    private var controller: TripsController? = null

    fun get(app: AppState): TripsController = controller ?: TripsController(app).also { controller = it }
}

/**
 * Trip-recording lifecycle (port of the trip part of iOS `AppState`): «Поехали» starts a recording when
 * «Фоновая запись поездок» is on; driving ≥ 10 km/h for 10 s with the camera screen open starts one; a trip started
 * this way or by «Поехали» ends after 3 min standing still (not while navigating — arrival ends those) or, when the
 * driving detector started it, when the app leaves the screen. Arrival opens the report; automatic stops are silent.
 * While recording, [TripRecordingService] keeps background location alive.
 */
class TripsController(val app: AppState) {
    val store = TripStore(app.context)
    val recorder = TripRecorder(app, store)
    private val scope = MainScope()
    private var installed = false

    private var movingSince: Long? = null
    private var stationarySince: Long? = null
    /** True when the current recording was started by the driving detector (not «Поехали» / Settings). */
    private var autoStartedTrip = false
    private var wasForeground = true

    companion object {
        const val AUTO_START_SPEED_KMH = 10.0
        const val AUTO_START_MS = 10_000L
        const val AUTO_STATIONARY_SPEED_KMH = 3.0
        const val AUTO_STOP_MS = 180_000L
    }

    fun install() {
        if (installed) return
        installed = true
        store.load()
        app.bus.onDriveStarted += { onDriveStarted() }
        app.bus.onDriveEnded += { arrived -> onDriveEnded(arrived) }
        scope.launch { app.bus.events.collect { recorder.ingest(it) } }
        scope.launch {
            while (isActive) {
                delay(1000)
                autoTripTick()
            }
        }
    }

    // Drive & trips

    private fun onDriveStarted() {
        if (app.settings.tripAutoRecord && !recorder.isRecording) {
            startRecording(withNavigation = true)
            autoStartedTrip = false
        }
    }

    /** Arrival or cancelled guidance ends a recording that «Поехали» started (the report opens after an arrival). */
    private fun onDriveEnded(arrived: Boolean) {
        if (!recorder.isRecording || !recorder.startedWithNavigation) return
        stopTripRecording(arrived = arrived, presentReport = arrived)
    }

    /** Manual trip recording (Settings → Trips, trip history). */
    fun startTripRecording() {
        startRecording(withNavigation = app.bus.isNavigating)
        autoStartedTrip = false
    }

    private fun startRecording(withNavigation: Boolean) {
        recorder.start(withNavigation)
        if (recorder.isRecording) TripRecordingService.start(app.context)
    }

    /**
     * Stops the recording and saves it to the history. [presentReport] opens its report (after an arrival or an
     * explicit stop — automatic stops are silent; nothing is shown without a track).
     */
    fun stopTripRecording(arrived: Boolean = false, presentReport: Boolean = true) {
        autoStartedTrip = false
        stationarySince = null
        scope.launch {
            val trip = recorder.stop(arrived)
            TripRecordingService.stop(app.context)
            if (trip == null || !presentReport) return@launch
            app.showSettings = false
            app.showTripHistory = false
            app.presentedTripId = trip.id.toString()
        }
    }

    // Background trip recording

    private fun isAppInForeground(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        // A running foreground service reports 125; only a visible activity reports IMPORTANCE_FOREGROUND (100).
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    /** Own GPS speed, km/h (0 without a fix from the last 10 s). */
    private val currentSpeedKmh: Double
        get() {
            val fix = app.location.location ?: return 0.0
            if (System.currentTimeMillis() - fix.time >= 10_000 || !fix.hasSpeed() || fix.speed < 0) return 0.0
            return fix.speed * 3.6
        }

    private fun autoTripTick() {
        val now = System.currentTimeMillis()
        val foreground = isAppInForeground()
        if (foreground != wasForeground) {
            wasForeground = foreground
            if (!foreground) onBackground()
        }
        if (!app.settings.tripAutoRecord || !foreground) {
            movingSince = null
            stationarySince = null
            return
        }
        val speed = currentSpeedKmh
        if (!recorder.isRecording) {
            stationarySince = null
            if (recorder.isFinishing || app.mode != AppMode.CAMERA || speed < AUTO_START_SPEED_KMH) {
                movingSince = null
                return
            }
            val since = movingSince ?: now
            movingSince = since
            if (now - since >= AUTO_START_MS) {
                movingSince = null
                startRecording(withNavigation = app.bus.isNavigating)
                autoStartedTrip = recorder.isRecording
            }
            return
        }
        movingSince = null
        if (!(autoStartedTrip || recorder.startedWithNavigation) || app.bus.isNavigating || speed > AUTO_STATIONARY_SPEED_KMH) {
            stationarySince = null
            return
        }
        val since = stationarySince ?: now
        stationarySince = since
        if (now - since >= AUTO_STOP_MS) stopTripRecording(presentReport = false)
    }

    /** A trip the driving detector started ends when the app leaves the screen (unless guidance runs). */
    private fun onBackground() {
        movingSince = null
        stationarySince = null
        if (recorder.isRecording && autoStartedTrip && !app.bus.isNavigating) stopTripRecording(presentReport = false)
    }
}
