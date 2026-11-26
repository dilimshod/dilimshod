package uz.roadvis.core

import java.util.Calendar
import java.util.Date
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min

/** Congestion level of a route or road. */
enum class CongestionLevel(val raw: String) {
    FREE("free"), LIGHT("light"), MODERATE("moderate"), HEAVY("heavy"), SEVERE("severe");

    /** Russian display name. */
    val displayName: String
        get() = when (this) {
            FREE -> "Свободно"
            LIGHT -> "Небольшие затруднения"
            MODERATE -> "Умеренные пробки"
            HEAVY -> "Сильные пробки"
            SEVERE -> "Очень сильные пробки"
        }

    /** 0 (free) … 4 (severe), e.g. for colouring. */
    val severity: Int
        get() = when (this) {
            FREE -> 0
            LIGHT -> 1
            MODERATE -> 2
            HEAVY -> 3
            SEVERE -> 4
        }

    companion object {
        fun fromRaw(raw: String): CongestionLevel? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Traffic on a route, derived by comparing the current ETA with a free-flow ETA
 * (e.g. an ETA now vs. for a 03:00 departure). An estimate, not measured traffic data.
 */
data class TrafficAssessment(
    /** Travel time with current traffic, seconds. */
    val currentSeconds: Double,
    /** Travel time without traffic, seconds. */
    val freeFlowSeconds: Double,
) {
    /** `max(0, current − freeFlow)` seconds (0 for invalid input). */
    val delaySeconds: Double
        get() {
            if (!currentSeconds.isFinite() || !freeFlowSeconds.isFinite()) return 0.0
            return max(0.0, currentSeconds - freeFlowSeconds)
        }

    /** `current / freeFlow` (1 when the free-flow time is unknown or not positive). */
    val ratio: Double
        get() {
            if (!currentSeconds.isFinite() || !freeFlowSeconds.isFinite() || freeFlowSeconds <= 0 || currentSeconds < 0) return 1.0
            return currentSeconds / freeFlowSeconds
        }

    /** < 1.1 free, < 1.25 light, < 1.5 moderate, < 2 heavy, otherwise severe. */
    val level: CongestionLevel
        get() {
            val r = ratio
            if (r < 1.1) return CongestionLevel.FREE
            if (r < 1.25) return CongestionLevel.LIGHT
            if (r < 1.5) return CongestionLevel.MODERATE
            if (r < 2) return CongestionLevel.HEAVY
            return CongestionLevel.SEVERE
        }

    /** Russian one-liner, marked as an estimate: "Умеренные пробки, задержка ≈ 7 мин (оценка)". */
    val summary: String
        get() {
            val delay = delaySeconds
            if (level == CongestionLevel.FREE || delay < 60) return "${level.displayName} (оценка)"
            return "${level.displayName}, задержка ≈ ${RVFormat.duration(delay)} (оценка)"
        }
}

object TrafficDelay {
    /**
     * Next `hour`:00 local time (in [timeZone]) strictly after [date] (used as a low-traffic departure for the
     * free-flow ETA). [hour] is clamped to 0…23. Handles days where that hour is skipped by a DST change.
     */
    fun nextOffPeakDate(after: Date, timeZone: TimeZone = TimeZone.getDefault(), hour: Int = 3): Date {
        val h = min(23, max(0, hour))
        for (dayOffset in 0..2) {
            val c = GregorianCalendar(timeZone)
            c.time = after
            c.set(Calendar.HOUR_OF_DAY, 0)
            c.set(Calendar.MINUTE, 0)
            c.set(Calendar.SECOND, 0)
            c.set(Calendar.MILLISECOND, 0)
            c.add(Calendar.DAY_OF_MONTH, dayOffset)
            c.set(Calendar.HOUR_OF_DAY, h)
            c.set(Calendar.MINUTE, 0)
            c.set(Calendar.SECOND, 0)
            c.set(Calendar.MILLISECOND, 0)
            val candidate = c.time
            if (candidate.after(after)) return candidate
        }
        // Unreachable for real calendars; keep a sane fallback.
        return Date(after.time + 24 * 3600 * 1000L)
    }
}
