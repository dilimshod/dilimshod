package uz.roadvis.app.trips

import uz.roadvis.core.TripStandstillTimer
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
    /** Standing-still / GPS-outage timers of the automatic stop (≤ 3 km/h for 3 min, or 15 min without GPS speed). */
    private val standstill = TripStandstillTimer()
    /** True when the current recording was started by the driving detector (not «Поехали» / Settings). */
    private var autoStartedTrip = false
    private var wasForeground = true

    companion object {
        const val AUTO_START_SPEED_KMH = 10.0
        const val AUTO_START_MS = 10_000L
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
        if (recorder.isRecording) {
            // A trip the driving detector started becomes the trip of this navigation (arrival ends it and opens the
            // report); a manual recording from Settings stays independent.
            if (autoStartedTrip) {
                recorder.adoptNavigation()
                autoStartedTrip = false
            }
        } else if (app.settings.tripAutoRecord) {
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
        standstill.reset()
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

    /** Own GPS speed, km/h; null without a fix from the last 10 s or without a valid speed (GPS outage). */
    private val currentSpeedKmh: Double?
        get() {
            val fix = app.location.location ?: return null
            if (System.currentTimeMillis() - fix.time >= 10_000 || !fix.hasSpeed() || fix.speed < 0) return null
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
            standstill.reset()
            return
        }
        val speed = currentSpeedKmh
        if (!recorder.isRecording) {
            standstill.reset()
            if (recorder.isFinishing || app.mode != AppMode.CAMERA || speed == null || speed < AUTO_START_SPEED_KMH) {
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
        if (!(autoStartedTrip || recorder.startedWithNavigation) || app.bus.isNavigating) {
            standstill.reset()
            return
        }
        // A GPS outage (tunnel) is not "standing": without a valid speed the trip ends only after 15 min.
        if (standstill.update(now, speed)) stopTripRecording(presentReport = false)
    }

    /** A trip the driving detector started ends when the app leaves the screen (unless guidance runs). */
    private fun onBackground() {
        movingSince = null
        standstill.reset()
        if (recorder.isRecording && autoStartedTrip && !app.bus.isNavigating) stopTripRecording(presentReport = false)
    }
}
