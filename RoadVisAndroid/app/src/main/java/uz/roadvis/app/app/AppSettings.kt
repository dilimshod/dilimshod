package uz.roadvis.app.app

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import uz.roadvis.core.DetectionThresholds
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
    /** ".v2": new default and the slider now moves every class threshold, so older stored values are not carried over. */
    var detectionConfidence by Pref("rv.detectionConfidence.v2", DetectionThresholds.DEFAULT_GLOBAL_NANO)
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
    /**
     * Measure the horizon from the lane vanishing point while driving (`LaneHorizonEstimator`); [corridorHorizon] is
     * then the start value and the fallback.
     */
    var autoHorizonEnabled by Pref("rv.autoHorizonEnabled", true)
    /** Last measured horizon for portrait / landscape frames (0 = nothing measured yet). */
    var autoHorizonPortrait by Pref("rv.autoHorizonPortrait", 0.0)
    var autoHorizonLandscape by Pref("rv.autoHorizonLandscape", 0.0)

    // Driver assist sounds
    var alertSoundsEnabled by Pref("rv.alertSounds", true)
    var voiceMuted by Pref("rv.voiceMuted", false)

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
