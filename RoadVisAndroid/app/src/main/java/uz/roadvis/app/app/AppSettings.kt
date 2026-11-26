package uz.roadvis.app.app

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import uz.roadvis.core.SoundMode
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * User settings persisted in SharedPreferences, exposed as Compose state (port of iOS `AppSettings`,
 * same keys and defaults). Core-typed derived values (following-distance policy, trip thresholds,
 * signal assumptions) are built by the feature code from these primitives.
 */
class AppSettings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    private inner class Pref<T>(private val key: String, default: T) : ReadWriteProperty<Any?, T> {
        @Suppress("UNCHECKED_CAST")
        private val state: MutableState<T> = mutableStateOf(
            if (!prefs.contains(key)) default else when (default) {
                is Boolean -> prefs.getBoolean(key, default) as T
                is Double -> java.lang.Double.longBitsToDouble(
                    prefs.getLong(key, java.lang.Double.doubleToRawLongBits(default))) as T
                is String -> (prefs.getString(key, default) ?: default) as T
                is Int -> prefs.getInt(key, default) as T
                else -> default
            }
        )
        override fun getValue(thisRef: Any?, property: KProperty<*>): T = state.value
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
            if (state.value == value) return
            state.value = value
            prefs.edit().apply {
                when (value) {
                    is Boolean -> putBoolean(key, value)
                    is Double -> putLong(key, java.lang.Double.doubleToRawLongBits(value))
                    is String -> putString(key, value)
                    is Int -> putInt(key, value)
                }
            }.apply()
        }
    }

    // Recognition
    var detectionConfidence by Pref("rv.detectionConfidence", 0.45)
    var nmsIoUThreshold by Pref("rv.nmsIoUThreshold", 0.45)
    var makeRecognitionEnabled by Pref("rv.makeRecognitionEnabled", true)
    var showDistanceEstimates by Pref("rv.showDistanceEstimates", true)
    var showSpeedEstimates by Pref("rv.showSpeedEstimates", true)
    var trackPedestrians by Pref("rv.trackPedestrians", true)
    var detectTrafficLights by Pref("rv.detectTrafficLights", true)
    var recordExperimentLog by Pref("rv.recordExperimentLog", false)

    // Following distance
    var followingDistanceEnabled by Pref("rv.followingDistanceEnabled", true)
    var followingTimeGapDry by Pref("rv.followingTimeGapDry", 2.0)
    var stoppedGapMeters by Pref("rv.stoppedGapMeters", 2.0)
    var reactionTimeSeconds by Pref("rv.reactionTimeSeconds", 1.0)
    /** Camera → front bumper distance (bonnet), metres; subtracted from the camera distance. */
    var hoodLengthMeters by Pref("rv.hoodLength", 2.2)
    var roadSurfaceMode by Pref("rv.roadSurfaceMode", "auto")
    var distanceWarningsEnabled by Pref("rv.distanceWarningsEnabled", true)
    var showEgoCorridor by Pref("rv.showEgoCorridor", false)
    var corridorHorizon by Pref("rv.corridorHorizon", 0.42)

    // Driver assist sounds
    private fun legacyBool(key: String): Boolean? = if (prefs.contains(key)) prefs.getBoolean(key, false) else null
    private var soundModeRaw by Pref(SoundMode.STORAGE_KEY, SoundMode.resolve(null,
        legacyBool(SoundMode.LEGACY_VOICE_MUTED_KEY), legacyBool(SoundMode.LEGACY_ALERT_SOUNDS_KEY)).raw)
    /**
     * The one persisted sound mode ("rv.soundMode": all / sounds only / voice only / silent), migrated from the
     * older "rv.voiceMuted" + "rv.alertSounds" flags on first read (both are still written on every change).
     */
    var soundMode: SoundMode
        get() = SoundMode.resolve(soundModeRaw, null, null)
        set(value) {
            soundModeRaw = value.raw
            prefs.edit().putBoolean(SoundMode.LEGACY_VOICE_MUTED_KEY, !value.voiceEnabled)
                .putBoolean(SoundMode.LEGACY_ALERT_SOUNDS_KEY, value.tonesEnabled).apply()
        }
    /** Alert tones: derived from [soundMode] (the Settings toggle keeps the voice half of the mode). */
    var alertSoundsEnabled: Boolean
        get() = soundMode.tonesEnabled
        set(value) { soundMode = soundMode.withTones(value) }
    /** Voice prompts off: derived from [soundMode] (the Settings toggle keeps the tone half of the mode). */
    var voiceMuted: Boolean
        get() = !soundMode.voiceEnabled
        set(value) { soundMode = soundMode.withVoice(!value) }

    // Navigation
    var voiceGuidanceEnabled by Pref("rv.voiceGuidanceEnabled", true)
    var avoidTolls by Pref("rv.avoidTolls", false)
    var avoidHighways by Pref("rv.avoidHighways", false)
    var showCameraPiP by Pref("rv.showCameraPiP", true)
    var showTrafficOnMap by Pref("rv.showTrafficOnMap", true)
    var roadDataEnabled by Pref("rv.roadDataEnabled", true)
    var overpassEndpoint by Pref("rv.overpassEndpoint", DEFAULT_OVERPASS_ENDPOINT)
    var speedWarningEnabled by Pref("rv.speedWarningEnabled", true)
    var speedWarningTolerance by Pref("rv.speedWarningTolerance", 5.0)
    var incidentLifetimeMinutes by Pref("rv.incidentLifetimeMinutes", 120.0)
    var showWazeButton by Pref("rv.showWazeButton", true)
    var osmCamerasEnabled by Pref("rv.osmCamerasEnabled", true)
    var ownMarksEnabled by Pref("rv.ownMarksEnabled", true)
    /** "auto" | "valhalla" | "osrm". */
    var routingEngine by Pref("rv.routingEngine", "auto")
    var valhallaEndpoint by Pref("rv.valhallaEndpoint", DEFAULT_VALHALLA_ENDPOINT)
    var routeAttributesEnabled by Pref("rv.routeAttributesEnabled", true)
    /** "cartoDark" | "osmStandard" (fallback). */
    var mapStyle by Pref("rv.mapStyle", "cartoDark")

    // Signals
    var signalCycleSeconds by Pref("rv.signalCycleSeconds", 90.0)
    var signalGreenRatio by Pref("rv.signalGreenRatio", 0.45)
    var learnSignalTimings by Pref("rv.learnSignalTimings", true)

    // Trips
    var tripAutoRecord by Pref("rv.tripAutoRecord", true)
    var tripRecordCameraCSV by Pref("rv.tripRecordCameraCSV", false)
    var tripSpeedToleranceKmh by Pref("rv.tripSpeedToleranceKmh", 5.0)
    var tripSpeedingMinSeconds by Pref("rv.tripSpeedingMinSeconds", 5.0)
    var tripHarshBrakingMps2 by Pref("rv.tripHarshBrakingMps2", 3.5)
    var tripHarshAccelerationMps2 by Pref("rv.tripHarshAccelerationMps2", 3.0)

    companion object {
        const val DEFAULT_OVERPASS_ENDPOINT = "https://overpass-api.de/api/interpreter"
        const val DEFAULT_VALHALLA_ENDPOINT = "https://valhalla1.openstreetmap.de"
        val OVERPASS_ENDPOINTS = listOf(
            "https://overpass-api.de/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
        )
    }
}
