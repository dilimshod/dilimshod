package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// Road surface

/** Road surface condition used to scale the recommended following distance. */
enum class RoadSurfaceCondition(val raw: String) {
    DRY("dry"), WET("wet"), SNOW("snow"), ICE("ice");

    val displayName: String
        get() = when (this) {
            DRY -> "Сухо"
            WET -> "Мокро"
            SNOW -> "Снег"
            ICE -> "Гололёд"
        }

    val symbolName: String
        get() = when (this) {
            DRY -> "sun.max.fill"
            WET -> "cloud.rain.fill"
            SNOW -> "snowflake"
            ICE -> "thermometer.snowflake"
        }

    /** Typical tyre–road friction coefficient for braking (engineering approximation). */
    val frictionCoefficient: Double
        get() = when (this) {
            DRY -> 0.7
            WET -> 0.35
            SNOW -> 0.2
            ICE -> 0.1
        }

    companion object {
        fun fromRaw(raw: String): RoadSurfaceCondition? = entries.firstOrNull { it.raw == raw }

        /** Guesses the surface from Open-Meteo current weather (WMO code, °C, mm of precipitation). */
        fun from(weatherCode: Int?, temperatureC: Double?, precipitationMm: Double?): RoadSurfaceCondition {
            val code = weatherCode ?: 0
            val temp = temperatureC ?: 15.0
            val precip = precipitationMm ?: 0.0
            val freezing = setOf(56, 57, 66, 67)
            val snow = setOf(71, 73, 75, 77, 85, 86)
            val rain = setOf(51, 53, 55, 61, 63, 65, 80, 81, 82, 95, 96, 97, 99)
            if (code in freezing || (temp <= 0 && code in rain) || (code == 48 && temp <= 0)) return ICE
            if (code in snow) return if (temp <= -2) ICE else SNOW
            if (code in rain || precip > 0.1) return if (temp <= 1) ICE else WET
            return DRY
        }
    }
}

// Policy

/**
 * Following-distance settings. Defaults are RECOMMENDATIONS, not legal norms — the Uzbek traffic rules (п.73) require a
 * safe distance without giving a number: 2 s dry, 4 s wet, 6 s snow (app choice), 10 s ice, ≥ 2 m when standing.
 */
data class FollowingDistancePolicy(
    val timeGapDry: Double = 2.0,
    val timeGapWet: Double = 4.0,
    val timeGapSnow: Double = 6.0,
    val timeGapIce: Double = 10.0,
    /** Minimum gap to the vehicle ahead when standing (queue, traffic light), metres. */
    val stoppedGapMeters: Double = 2.0,
    /** Driver reaction time used for the stopping-distance estimate, seconds. */
    val reactionTimeSeconds: Double = 1.0,
    /** Below this own speed the car is considered standing, km/h. */
    val stoppedSpeedKmh: Double = 5.0,
    /** Forward-collision warning threshold (time to collision), seconds. */
    val collisionWarningSeconds: Double = 2.5,
) {
    fun timeGap(condition: RoadSurfaceCondition): Double = when (condition) {
        RoadSurfaceCondition.DRY -> timeGapDry
        RoadSurfaceCondition.WET -> timeGapWet
        RoadSurfaceCondition.SNOW -> timeGapSnow
        RoadSurfaceCondition.ICE -> timeGapIce
    }
}

// Assessment

enum class DistanceStatus(val raw: String) {
    SAFE("safe"), CAUTION("caution"), DANGER("danger"), UNKNOWN("unknown");

    val displayName: String
        get() = when (this) {
            SAFE -> "Дистанция в норме"
            CAUTION -> "Мала дистанция"
            DANGER -> "Опасно близко"
            UNKNOWN -> "Нет данных"
        }

    companion object {
        fun fromRaw(raw: String): DistanceStatus? = entries.firstOrNull { it.raw == raw }
    }
}

data class FollowingDistanceAssessment(
    var distanceMeters: Double?,
    var ownSpeedKmh: Double?,
    var isStopped: Boolean,
    var condition: RoadSurfaceCondition,
    /** Recommended minimum gap for the current state, metres. */
    var recommendedDistanceMeters: Double,
    /** Recommended time gap (moving) — null when stopped. */
    var recommendedTimeGapSeconds: Double?,
    /** Estimated stopping distance = reaction distance + braking distance, metres (moving only). */
    var stoppingDistanceMeters: Double? = null,
    /** Time headway = distance / own speed, seconds (moving only). */
    var timeHeadwaySeconds: Double? = null,
    /** Closing speed, km/h; positive = the gap is shrinking. */
    var closingSpeedKmh: Double? = null,
    /** Time to collision at the current closing speed, seconds (only when closing). */
    var timeToCollisionSeconds: Double? = null,
    /** distance / recommended (1 = exactly the recommended gap). */
    var fractionOfRecommended: Double? = null,
    var status: DistanceStatus = DistanceStatus.UNKNOWN,
) {
    val isCollisionWarning: Boolean
        get() = status == DistanceStatus.DANGER && (timeToCollisionSeconds ?: Double.POSITIVE_INFINITY) < Double.POSITIVE_INFINITY
}

object FollowingDistanceCalculator {
    /** S = v·t_r + v² / (2·μ·g), metres. */
    fun stoppingDistance(speedKmh: Double, reactionTime: Double, friction: Double): Double {
        val v = max(0.0, speedKmh) / 3.6
        val mu = max(0.05, friction)
        return v * max(0.0, reactionTime) + v * v / (2 * mu * 9.81)
    }

    /** Recommended minimum gap: own speed × time gap while moving (never below the stopped gap), stopped gap otherwise. */
    fun recommendedDistance(speedKmh: Double?, policy: FollowingDistancePolicy, condition: RoadSurfaceCondition): Double {
        val speed = max(0.0, speedKmh ?: 0.0)
        if (speed < policy.stoppedSpeedKmh) return policy.stoppedGapMeters
        return max(policy.stoppedGapMeters, speed / 3.6 * policy.timeGap(condition))
    }

    /** [relativeSpeedKmh]: rate of change of the gap (positive = lead pulling away), from the lead tracker. */
    fun assess(
        distanceMeters: Double?, ownSpeedKmh: Double?, relativeSpeedKmh: Double?,
        policy: FollowingDistancePolicy, condition: RoadSurfaceCondition,
    ): FollowingDistanceAssessment {
        val speed = ownSpeedKmh?.let { max(0.0, it) }
        val stopped = (speed ?: 0.0) < policy.stoppedSpeedKmh
        val recommended = recommendedDistance(speed, policy, condition)
        val a = FollowingDistanceAssessment(
            distanceMeters = distanceMeters, ownSpeedKmh = speed, isStopped = stopped, condition = condition,
            recommendedDistanceMeters = recommended,
            recommendedTimeGapSeconds = if (stopped) null else policy.timeGap(condition),
        )
        if (speed != null && !stopped) {
            a.stoppingDistanceMeters = stoppingDistance(speed, policy.reactionTimeSeconds, condition.frictionCoefficient)
        }
        val d = distanceMeters
        if (d == null || !d.isFinite() || d <= 0) return a

        if (speed != null && !stopped) a.timeHeadwaySeconds = d / (speed / 3.6)
        if (relativeSpeedKmh != null) {
            val closing = -relativeSpeedKmh
            a.closingSpeedKmh = closing
            if (closing > 3) a.timeToCollisionSeconds = d / (closing / 3.6)
        }
        val fraction = d / max(0.1, recommended)
        a.fractionOfRecommended = fraction

        val ttc = a.timeToCollisionSeconds
        a.status = when {
            ttc != null && ttc < policy.collisionWarningSeconds && !stopped -> DistanceStatus.DANGER
            fraction >= 1 -> DistanceStatus.SAFE
            fraction >= 0.5 -> DistanceStatus.CAUTION
            else -> DistanceStatus.DANGER
        }
        return a
    }

    /** The distance-cue description of a lead estimate ("ширина+высота", "ширина (обрезано)") in [language]. */
    fun methodDisplay(method: String, language: RVLang): String {
        if (language == RVLang.RU) return method
        val words = listOf(
            Triple("ширина", "eni", "width"), Triple("высота", "balandligi", "height"), Triple("обрезано", "kesilgan", "cropped"),
        )
        var text = method
        for ((ru, uz, en) in words) text = text.replace(ru, if (language == RVLang.UZ) uz else en)
        return text
    }
}

// Lead vehicle

/** Trapezoidal region of the image where the own lane is expected (normalized coordinates, y down). */
data class EgoCorridor(
    val centerX: Double = 0.5,
    /** Approximate horizon line (fraction of image height); nothing above it is "in our lane". */
    val horizonY: Double = 0.42,
    /** Half width of the corridor at the bottom edge (fraction of image width). */
    val bottomHalfWidth: Double = 0.24,
    /** Half width at the horizon. */
    val horizonHalfWidth: Double = 0.04,
) {
    /** Half width of the corridor at image row y. */
    fun halfWidth(atY: Double): Double {
        if (atY <= horizonY) return 0.0
        val t = min(1.0, (atY - horizonY) / max(0.01, 1 - horizonY))
        return horizonHalfWidth + (bottomHalfWidth - horizonHalfWidth) * t
    }

    /** True when the box's bottom edge overlaps the corridor at its row. */
    fun contains(box: BBox): Boolean {
        val y = min(1.0, box.maxY)
        val hw = halfWidth(y)
        if (hw <= 0) return false
        val left = centerX - hw; val right = centerX + hw
        val overlap = min(right, box.maxX) - max(left, box.minX)
        return (box.midX >= left && box.midX <= right) || overlap >= 0.4 * box.width
    }

    /** Normalized lateral offset of the box centre from the corridor centre (0 = centred, 1 = edge); null above horizon. */
    fun lateralOffset(box: BBox): Double? {
        val hw = halfWidth(min(1.0, box.maxY))
        if (hw <= 0) return null
        return abs(box.midX - centerX) / hw
    }

    /** Fraction of the box width that overlaps the corridor at the box's bottom row (0…1). */
    fun overlapFraction(box: BBox): Double {
        val hw = halfWidth(min(1.0, box.maxY))
        if (!(hw > 0 && box.width > 0)) return 0.0
        val overlap = min(centerX + hw, box.maxX) - max(centerX - hw, box.minX)
        return max(0.0, min(1.0, overlap / box.width))
    }

    /** Strictly ahead: centre within `centerFraction` of the half-width, or at least `minOverlap` overlapping. */
    fun isStrictlyAhead(box: BBox, centerFraction: Double = 0.6, minOverlap: Double = 0.6): Boolean {
        val offset = lateralOffset(box) ?: return false
        return offset <= centerFraction || overlapFraction(box) >= minOverlap
    }

    /** Corridor polygon (bottom-left, top-left, top-right, bottom-right) as (x, y) pairs for drawing. */
    val polygon: List<Pair<Double, Double>>
        get() = listOf(
            (centerX - bottomHalfWidth) to 1.0, (centerX - horizonHalfWidth) to horizonY,
            (centerX + horizonHalfWidth) to horizonY, (centerX + bottomHalfWidth) to 1.0,
        )

    companion object {
        val default = EgoCorridor()

        /**
         * Next smoothed corridor centre X: moves toward [LaneEstimate.laneCenterX] (clamped to [range]) when the lane
         * estimate is confident (≥ [minConfidence]), otherwise back toward 0.5. [alpha] is the EMA weight per call.
         */
        fun smoothedCenterX(
            previous: Double, lane: LaneEstimate?, minConfidence: Double = 0.5,
            range: ClosedFloatingPointRange<Double> = 0.35..0.65, alpha: Double = 0.15,
        ): Double {
            var target = 0.5
            val center = lane?.laneCenterX
            if (lane != null && lane.confidence >= minConfidence && center != null && center.isFinite()) {
                target = min(range.endInclusive, max(range.start, center))
            }
            val next = previous + max(0.0, min(1.0, alpha)) * (target - previous)
            return min(range.endInclusive, max(range.start, next))
        }
    }
}

/** The vehicle directly ahead in the own lane, with a fused distance estimate. */
data class LeadVehicle(
    val trackID: Int,
    val kind: VehicleKind,
    val box: BBox,
    /** Smoothed gap from the own FRONT BUMPER to the lead's rear, metres (≈): camera distance − cameraToBumperMeters. */
    val distanceMeters: Double,
    /** Smoothed distance from the camera (windscreen) to the lead's rear, metres (≈). */
    val cameraDistanceMeters: Double = 0.0,
    /** Rate of change of the gap, km/h (positive = pulling away), null until enough samples. */
    val relativeSpeedKmh: Double? = null,
    /** Which cues were used: "ширина+высота", "ширина", "высота". */
    val method: String,
)

/**
 * Selects the lead vehicle — the vehicle directly AHEAD in the own lane — and estimates its distance by fusing the
 * apparent width and height of its box with typical vehicle dimensions. See the Swift original for the selection rules
 * (strictly ahead, not touching a side edge, closeness rank + lateral penalty, hysteresis with `switchMargin`).
 */
class LeadVehicleTracker(
    var corridor: EgoCorridor = EgoCorridor.default,
    var selection: SelectionConfig = SelectionConfig(),
) {
    data class SelectionConfig(
        /** Box centre within this fraction of the corridor half-width at its bottom row counts as "ahead". */
        val centerFraction: Double = 0.6,
        /** …or at least this fraction of the box width overlapping the corridor. */
        val minOverlap: Double = 0.6,
        /** Boxes touching the left / right frame edge (within this margin) are never selected. */
        val edgeMargin: Double = 0.01,
        /** Score weight of the normalized lateral offset; one closeness rank = 1. */
        val lateralPenalty: Double = 2.0,
        /** Bottom edges closer than this (fraction of the height) share a closeness rank. */
        val rankTolerance: Double = 0.03,
        /** Another candidate must score better by this to replace the current lead. */
        val switchMargin: Double = 0.5,
    )

    /** Distance from the camera to the own front bumper (bonnet length + mount offset), metres. */
    var cameraToBumperMeters: Double = 0.0
    private var currentID: Int? = null
    private var smoothed: Double? = null
    private val samples = mutableListOf<Pair<Double, Double>>() // (t, d)
    private var lostSince: Double? = null

    fun reset() {
        currentID = null
        smoothed = null
        samples.clear()
        lostSince = null
    }

    fun update(tracks: List<TrackedObject>, geometry: CameraGeometry, timestamp: Double): LeadVehicle? {
        val lead = selectLead(tracks)
        val rd = lead?.let { rawDistance(it.kind, it.box, geometry) }
        if (lead == null || rd == null || !rd.first.isFinite() || rd.first <= 0.3 || rd.first >= 150) {
            if (lostSince == null) lostSince = timestamp
            val since = lostSince
            if (since != null && timestamp - since > 0.8) reset()
            return null
        }
        val (raw, method) = rd
        lostSince = null
        if (lead.id != currentID) {
            currentID = lead.id
            smoothed = null
            samples.clear()
        }
        val alpha = 0.35
        val value = smoothed?.let { it + alpha * (raw - it) } ?: raw
        smoothed = value
        samples.add(timestamp to value)
        samples.removeAll { timestamp - it.first > 1.2 }

        var rel: Double? = null
        val first = samples.firstOrNull()
        if (samples.size >= 4 && first != null && timestamp - first.first >= 0.5) {
            val n = samples.size.toDouble()
            val mt = samples.sumOf { it.first } / n
            val md = samples.sumOf { it.second } / n
            var num = 0.0; var den = 0.0
            for (s in samples) {
                num += (s.first - mt) * (s.second - md)
                den += (s.first - mt) * (s.first - mt)
            }
            if (den > 1e-9) {
                val kmh = num / den * 3.6
                if (abs(kmh) < 150) rel = kmh
            }
        }
        val gap = max(0.2, value - max(0.0, cameraToBumperMeters))
        return LeadVehicle(lead.id, lead.kind, lead.box, gap, value, rel, method)
    }

    /** True when the box touches exactly one of the left / right frame edges. */
    internal fun touchesSideEdge(box: BBox): Boolean {
        val left = box.minX <= selection.edgeMargin
        val right = box.maxX >= 1 - selection.edgeMargin
        return left != right
    }

    /** Lead candidates (strictly ahead, not at a side edge) with their selection score (lower is better). */
    internal fun scoredCandidates(tracks: List<TrackedObject>): List<Pair<TrackedObject, Double>> {
        val candidates = tracks.filter {
            it.isConfirmed && it.missed == 0 && it.kind.isVehicle && it.kind != VehicleKind.BICYCLE &&
                !touchesSideEdge(it.box) &&
                corridor.isStrictlyAhead(it.box, selection.centerFraction, selection.minOverlap)
        }
        return candidates.map { track ->
            val closer = candidates.count { it.box.maxY > track.box.maxY + selection.rankTolerance }
            val lateral = min(2.0, corridor.lateralOffset(track.box) ?: 2.0)
            track to (closer.toDouble() + selection.lateralPenalty * lateral)
        }
    }

    /** The lead for this frame (with hysteresis on the current lead), or null. */
    internal fun selectLead(tracks: List<TrackedObject>): TrackedObject? {
        val scored = scoredCandidates(tracks)
        val best = scored.minByOrNull { it.second } ?: return null
        val id = currentID
        if (id != null) {
            val current = scored.firstOrNull { it.first.id == id }
            if (current != null && best.first.id != id && best.second > current.second - selection.switchMargin) {
                return current.first
            }
        }
        return best.first
    }

    companion object {
        /** Raw (unsmoothed) distance and cue description for a box, or null when no cue is usable. */
        fun rawDistance(kind: VehicleKind, box: BBox, geometry: CameraGeometry): Pair<Double, String>? {
            val f = geometry.focalLengthPixels
            val estimates = mutableListOf<Double>()
            val cues = mutableListOf<String>()
            val widthTruncated = box.minX <= 0.005 || box.maxX >= 0.995
            val heightTruncated = box.maxY >= 0.985 || box.minY <= 0.005
            val w = kind.typicalWidthMeters
            if (w != null && !widthTruncated && box.width > 0.01 && geometry.imageWidth > 0) {
                estimates.add(f * w / (box.width * geometry.imageWidth))
                cues.add("ширина")
            }
            val h = kind.typicalHeightMeters
            if (h != null && !heightTruncated && box.height > 0.01 && geometry.imageHeight > 0) {
                estimates.add(f * h / (box.height * geometry.imageHeight))
                cues.add("высота")
            }
            if (estimates.isEmpty()) {
                if (w != null && box.width > 0.01 && geometry.imageWidth > 0) {
                    return Pair(f * w / (box.width * geometry.imageWidth), "ширина (обрезано)")
                }
                return null
            }
            return Pair(estimates.sum() / estimates.size, cues.joinToString("+"))
        }
    }
}
