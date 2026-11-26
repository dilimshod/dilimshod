package uz.roadvis.app.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import uz.roadvis.core.OSRM
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * Settings that iOS keeps outside `AppSettings` (iOS `DriverAssistSettings`, `NavigatorSettingsKeys.osrmEndpoint`),
 * stored in the same SharedPreferences file ("roadvis") with the iOS keys and defaults, as Compose state.
 * Doubles use the same raw-long-bits encoding as [uz.roadvis.app.app.AppSettings].
 */
class ExtraSettings private constructor(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    private inner class Pref<T>(private val key: String, default: T) : ReadWriteProperty<Any?, T> {
        @Suppress("UNCHECKED_CAST")
        private val state: MutableState<T> = mutableStateOf(
            if (!prefs.contains(key)) default else when (default) {
                is Boolean -> prefs.getBoolean(key, default) as T
                is Double -> java.lang.Double.longBitsToDouble(prefs.getLong(key, java.lang.Double.doubleToRawLongBits(default))) as T
                is String -> (prefs.getString(key, default) ?: default) as T
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
                }
            }.apply()
        }
    }

    // Driver assistant (iOS DriverAssistSettings)
    var voiceCoachingEnabled by Pref("rv.coachVoiceEnabled", true)
    var laneDepartureEnabled by Pref("rv.laneDepartureWarnings", true)
    var showLaneOverlay by Pref("rv.showLaneOverlay", true)
    var signAnnouncementsEnabled by Pref("rv.signAnnouncements", true)
    var trafficLightHintsEnabled by Pref("rv.trafficLightHints", true)
    var pedestrianWarningsEnabled by Pref("rv.pedestrianWarnings", true)
    var showRoadwayBoundary by Pref("rv.showRoadwayBoundary", true)
    var laneWarningMinSpeedKmh by Pref("rv.laneWarningMinSpeedKmh", 40.0)

    // Navigator (iOS NavigatorSettingsKeys)
    var osrmEndpoint by Pref("rv.osrmEndpoint", OSRM.defaultEndpoint)

    companion object {
        @Volatile private var instance: ExtraSettings? = null
        fun get(context: Context): ExtraSettings =
            instance ?: synchronized(this) { instance ?: ExtraSettings(context.applicationContext).also { instance = it } }
    }
}
