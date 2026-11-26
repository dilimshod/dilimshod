package uz.roadvis.core

import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** Swift-compatible rounding (half away from zero). */
internal fun Double.rounded(): Double = if (this >= 0) Math.floor(this + 0.5) else -Math.floor(-this + 0.5)

/** Russian formatting helpers for distances, durations and speeds (port of `RVFormat`). */
object RVFormat {
    fun distance(meters: Double): String {
        if (!meters.isFinite()) return "—"
        val m = max(0.0, meters)
        if (m < 1000) {
            val rounded = if (m < 100) (m / 10).rounded() * 10 else (m / 50).rounded() * 50
            if (rounded >= 1000) return "1 км"
            return "${rounded.toInt()} м"
        }
        if (m < 10_000) return decimal(m / 1000, 1) + " км"
        return "${(m / 1000).rounded().toInt()} км"
    }

    fun spokenDistance(meters: Double): String {
        val m = max(0.0, meters)
        if (m < 1000) {
            val rounded = if (m < 100) max(10.0, (m / 10).rounded() * 10) else (m / 50).rounded() * 50
            if (rounded < 1000) {
                val n = rounded.toInt()
                return "через $n ${plural(n, "метр", "метра", "метров")}"
            }
        }
        val km = (m / 100).rounded() / 10
        if (km == km.rounded()) {
            val n = km.toInt()
            return "через $n ${plural(n, "километр", "километра", "километров")}"
        }
        return "через ${decimal(km, 1)} километра"
    }

    fun duration(seconds: Double): String {
        if (!seconds.isFinite()) return "—"
        val s = max(0, seconds.rounded().toInt())
        if (s < 60) return "$s с"
        val totalMinutes = (s / 60.0).rounded().toInt()
        if (totalMinutes < 60) return "$totalMinutes мин"
        return String.format(Locale.US, "%d ч %02d мин", totalMinutes / 60, totalMinutes % 60)
    }

    fun speed(kmh: Double): String {
        if (!kmh.isFinite()) return "—"
        return "${max(0.0, kmh).rounded().toInt()}"
    }

    fun clock(date: Date): String {
        val c = Calendar.getInstance().apply { time = date }
        return String.format(Locale.US, "%02d:%02d", c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE))
    }

    fun plural(n: Int, one: String, few: String, many: String): String {
        val n10 = abs(n) % 10; val n100 = abs(n) % 100
        if (n10 == 1 && n100 != 11) return one
        if (n10 in 2..4 && n100 !in 12..14) return few
        return many
    }

    fun decimal(value: Double, digits: Int): String =
        String.format(Locale.US, "%.${digits}f", value).replace(".", ",")
}
