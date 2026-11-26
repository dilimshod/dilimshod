package uz.roadvis.app.camera

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf

/**
 * Settings of the beginner-driver assistant (port of iOS `DriverAssistSettings`, same "rv." keys and defaults).
 * They are not part of [uz.roadvis.app.app.AppSettings], so the camera feature reads them from the shared
 * "roadvis" SharedPreferences and follows changes written by any other screen (settings) through a listener.
 * `alertSoundsEnabled` lives in AppSettings (derived from the sound mode, "rv.soundMode").
 */
class AssistSettings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)
    private val bools = HashMap<String, Pair<MutableState<Boolean>, Boolean>>()
    private val laneMinSpeed = mutableStateOf(readLaneMinSpeed())

    // Keep a strong reference: SharedPreferences holds listeners weakly.
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == null) return@OnSharedPreferenceChangeListener
        bools[key]?.let { (state, def) -> state.value = prefs.getBoolean(key, def) }
        if (key == KEY_LANE_MIN_SPEED) laneMinSpeed.value = readLaneMinSpeed()
    }

    init { prefs.registerOnSharedPreferenceChangeListener(listener) }

    private fun bool(key: String, def: Boolean): MutableState<Boolean> =
        bools.getOrPut(key) { mutableStateOf(prefs.getBoolean(key, def)) to def }.first

    private fun readLaneMinSpeed(): Double {
        if (!prefs.contains(KEY_LANE_MIN_SPEED)) return 40.0
        val v = try {
            java.lang.Double.longBitsToDouble(prefs.getLong(KEY_LANE_MIN_SPEED, 0L))
        } catch (_: ClassCastException) {
            try { prefs.getFloat(KEY_LANE_MIN_SPEED, 40f).toDouble() } catch (_: ClassCastException) { 40.0 }
        }
        return if (v.isFinite()) v.coerceIn(20.0, 90.0) else 40.0
    }

    /** Master switch of the spoken coaching (lane, signs, traffic lights). */
    val voiceCoachingEnabled: Boolean get() = bool("rv.coachVoiceEnabled", true).value
    val laneDepartureEnabled: Boolean get() = bool("rv.laneDepartureWarnings", true).value
    val showLaneOverlay: Boolean get() = bool("rv.showLaneOverlay", true).value
    val signAnnouncementsEnabled: Boolean get() = bool("rv.signAnnouncements", true).value
    val trafficLightHintsEnabled: Boolean get() = bool("rv.trafficLightHints", true).value
    val pedestrianWarningsEnabled: Boolean get() = bool("rv.pedestrianWarnings", true).value
    val showRoadwayBoundary: Boolean get() = bool("rv.showRoadwayBoundary", true).value
    /** Lane-departure warnings only at or above this GPS speed, km/h (20…90, default 40). */
    val laneWarningMinSpeedKmh: Double get() = laneMinSpeed.value

    /** The lane detector runs when its result is used. */
    val laneDetectionNeeded: Boolean get() = laneDepartureEnabled || showLaneOverlay

    /** Persisted UI state of the camera HUD (distance card expanded). */
    var distanceHUDExpanded: Boolean
        get() = bool(KEY_HUD_EXPANDED, false).value
        set(value) { bool(KEY_HUD_EXPANDED, false).value = value; prefs.edit().putBoolean(KEY_HUD_EXPANDED, value).apply() }

    var countersExpanded: Boolean
        get() = bool(KEY_COUNTERS_EXPANDED, false).value
        set(value) { bool(KEY_COUNTERS_EXPANDED, false).value = value; prefs.edit().putBoolean(KEY_COUNTERS_EXPANDED, value).apply() }

    companion object {
        const val KEY_LANE_MIN_SPEED = "rv.laneWarningMinSpeedKmh"
        const val KEY_HUD_EXPANDED = "rv.distanceHUDExpanded"
        const val KEY_COUNTERS_EXPANDED = "rv.countersExpanded"
    }
}
