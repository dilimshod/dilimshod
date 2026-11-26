package uz.roadvis.core

import java.util.Locale
import kotlin.math.max

/**
 * Language of user-facing text produced by the core (distances, durations, turn instructions).
 * Uzbek (Latin script), Russian, English. The parameterless [RVFormat] APIs stay Russian.
 */
enum class RVLang(val raw: String) {
    UZ("uz"), RU("ru"), EN("en");

    /** Valhalla `directions_options.language`. Valhalla has no Uzbek narrative, so Uzbek requests English. */
    val valhallaLanguage: String
        get() = when (this) {
            RU -> "ru-RU"
            EN, UZ -> "en-US"
        }

    /** True when the text Valhalla returns can be shown as is (otherwise it is rebuilt from maneuver types). */
    val usesValhallaNarrative: Boolean get() = this != UZ

    companion object {
        fun fromRaw(raw: String): RVLang? = entries.firstOrNull { it.raw == raw }
    }
}

/** Decimal with the language's separator: comma for Uzbek / Russian ("1,3"), point for English ("1.3"). */
fun RVFormat.decimal(value: Double, digits: Int, language: RVLang): String {
    val text = String.format(Locale.US, "%.${digits}f", value)
    return if (language == RVLang.EN) text else text.replace(".", ",")
}

/** "350 m" / "1,2 km" (uz), "350 м" / "1,2 км" (ru), "350 m" / "1.2 km" (en). */
fun RVFormat.distance(meters: Double, language: RVLang): String {
    if (language == RVLang.RU) return distance(meters)
    if (!meters.isFinite()) return "—"
    val m = max(0.0, meters)
    if (m < 1000) {
        val rounded = if (m < 100) (m / 10).rounded() * 10 else (m / 50).rounded() * 50
        if (rounded >= 1000) return "1 km"
        return "${rounded.toInt()} m"
    }
    if (m < 10_000) return decimal(m / 1000, 1, language) + " km"
    return "${(m / 1000).rounded().toInt()} km"
}

/** Spoken distance before a maneuver: "400 metrdan keyin" (uz), "через 400 метров" (ru), "In 400 metres" (en). */
fun RVFormat.spokenDistance(meters: Double, language: RVLang): String {
    if (language == RVLang.RU) return spokenDistance(meters)
    val m = max(0.0, meters)
    if (m < 1000) {
        val rounded = if (m < 100) max(10.0, (m / 10).rounded() * 10) else (m / 50).rounded() * 50
        if (rounded < 1000) {
            val n = rounded.toInt()
            return if (language == RVLang.UZ) "$n metrdan keyin" else "In $n metres"
        }
    }
    val km = (m / 100).rounded() / 10
    val number = if (km == km.rounded()) "${km.toInt()}" else decimal(km, 1, language)
    if (language == RVLang.UZ) return "$number kilometrdan keyin"
    return if (km == 1.0) "In 1 kilometre" else "In $number kilometres"
}

/** "45 s" / "12 daq" / "1 soat 05 daq" (uz), "45 с" / "12 мин" / "1 ч 05 мин" (ru), "45 s" / "12 min" / "1 h 05 min" (en). */
fun RVFormat.duration(seconds: Double, language: RVLang): String {
    if (language == RVLang.RU) return duration(seconds)
    if (!seconds.isFinite()) return "—"
    val s = max(0, seconds.rounded().toInt())
    val minute = if (language == RVLang.UZ) "daq" else "min"
    val hour = if (language == RVLang.UZ) "soat" else "h"
    if (s < 60) return "$s s"
    val totalMinutes = (s / 60.0).rounded().toInt()
    if (totalMinutes < 60) return "$totalMinutes $minute"
    val h = totalMinutes / 60; val mm = totalMinutes % 60
    return "$h $hour " + String.format(Locale.US, "%02d", mm) + " $minute"
}

/** Unit labels in the given language. */
fun RVFormat.unitMeters(language: RVLang): String = if (language == RVLang.RU) "м" else "m"
fun RVFormat.unitKilometers(language: RVLang): String = if (language == RVLang.RU) "км" else "km"
fun RVFormat.unitSeconds(language: RVLang): String = if (language == RVLang.RU) "с" else "s"
fun RVFormat.unitKmh(language: RVLang): String = when (language) {
    RVLang.RU -> "км/ч"
    RVLang.UZ -> "km/soat"
    RVLang.EN -> "km/h"
}
