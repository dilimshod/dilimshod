package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

/** One turn-by-turn step. */
data class RouteStepInfo(
    val instruction: String,
    val distance: Double,
    val notice: String? = null,
    /** Explicit maneuver type from the routing engine; null → classified from [instruction]. */
    val maneuver: ManeuverType? = null,
    /** Lanes at the maneuver point (left → right), empty when unknown. */
    val lanes: List<Lane> = emptyList(),
    /** Lanes recommended by the routing engine for this maneuver (same count as [lanes]), empty when unknown. */
    val activeLanes: List<Boolean> = emptyList(),
    /** Street name(s) after the maneuver. */
    val streetNames: List<String> = emptyList(),
) {
    /** Engine maneuver if present, otherwise keyword classification of the instruction. */
    val resolvedManeuver: ManeuverType get() = maneuver ?: ManeuverClassifier.classify(instruction)
}

/** Position of the vehicle relative to the active route. */
data class RouteProgress(
    val distanceAlong: Double,
    val remainingDistance: Double,
    val remainingTimeSeconds: Double,
    val fractionCompleted: Double,
    /** Index of the step whose maneuver comes next. */
    val nextStepIndex: Int?,
    val distanceToNextManeuver: Double?,
    val nextInstruction: String?,
    val nextManeuver: ManeuverType,
    /** The maneuver after the next one (for "затем …"). */
    val followingInstruction: String?,
    val crossTrackDistance: Double,
    val isOffRoute: Boolean,
    val hasArrived: Boolean,
    val snappedPosition: GeoPoint,
    /** Lanes at the next maneuver (from the routing engine), empty when unknown. */
    val nextLanes: List<Lane> = emptyList(),
    /** Recommended lanes for the next maneuver (same count as [nextLanes]). */
    val nextActiveLanes: List<Boolean> = emptyList(),
)

/** Map-matches GPS fixes onto the route polyline and derives next maneuver, remaining distance/time and off-route state. */
class RouteProgressTracker(
    val polyline: List<GeoPoint>,
    val steps: List<RouteStepInfo>,
    expectedTravelTime: Double,
    val offRouteThreshold: Double = 50.0,
    offRouteConfirmations: Int = 3,
    val arrivalThreshold: Double = 30.0,
) {
    val cumulative: List<Double> = Geo.cumulativeDistances(polyline)
    val expectedTravelTime: Double = max(0.0, expectedTravelTime)
    val offRouteConfirmations: Int = max(1, offRouteConfirmations)
    /** Start distance (along the polyline) of each step = where its maneuver happens. */
    val maneuverDistances: List<Double>

    /** Language of the fallback "destination" instruction (default Russian). */
    var language: RVLang = RVLang.RU

    private var lastSegment = 0
    private var lastAlong = 0.0
    private var offRouteCount = 0

    val totalDistance: Double get() = cumulative.lastOrNull() ?: 0.0

    init {
        val total = cumulative.lastOrNull() ?: 0.0
        val stepSum = steps.sumOf { max(0.0, it.distance) }
        val scale = if (stepSum > 0) total / stepSum else 1.0
        var acc = 0.0
        val starts = ArrayList<Double>()
        for (s in steps) {
            starts.add(min(total, acc * scale))
            acc += max(0.0, s.distance)
        }
        maneuverDistances = starts
    }

    fun update(position: GeoPoint, horizontalAccuracy: Double? = null): RouteProgress {
        val total = totalDistance
        val threshold = offRouteThreshold + min(50.0, max(0.0, (horizontalAccuracy ?: 0.0) - 10))

        // Incremental search near the last match first (avoids jumping to overlapping parts of the route).
        var projection: Geo.Projection? = null
        if (polyline.size >= 2) {
            val lo = max(0, lastSegment - 5)
            val hi = min(polyline.size - 1, lastSegment + 80)
            if (lo < hi) {
                // Swift half-open lo..<hi == Kotlin lo until hi.
                projection = Geo.project(position, polyline, cumulative, lo until hi)
            }
            if (projection == null || projection.distanceFromLine > threshold) {
                val full = Geo.project(position, polyline, cumulative)
                if (full != null && full.distanceFromLine < (projection?.distanceFromLine ?: Double.POSITIVE_INFINITY)) {
                    projection = full
                }
            }
        } else {
            projection = Geo.project(position, polyline, cumulative)
        }

        val proj = projection ?: return RouteProgress(0.0, 0.0, 0.0, 0.0, null, null, null, ManeuverType.UNKNOWN,
            null, 0.0, isOffRoute = false, hasArrived = false, snappedPosition = position)

        if (proj.distanceFromLine > threshold) {
            offRouteCount += 1
        } else {
            offRouteCount = 0
            lastSegment = proj.segmentIndex
            lastAlong = proj.distanceAlong
        }
        val isOffRoute = offRouteCount >= offRouteConfirmations
        val along = if (proj.distanceFromLine > threshold) lastAlong else proj.distanceAlong
        val remaining = max(0.0, total - along)
        val remainingTime = if (total > 0) expectedTravelTime * remaining / total else 0.0

        // Next maneuver: first announced step (index ≥ 1, non-empty instruction) starting ahead of us.
        var nextIndex: Int? = null
        for (i in steps.indices) {
            if (i < 1) continue
            val text = steps[i].instruction.swiftTrim()
            if (text.isNotEmpty() && maneuverDistances[i] > along + 2) {
                nextIndex = i
                break
            }
        }
        var following: String? = null
        if (nextIndex != null) {
            for (j in steps.indices) {
                if (j <= nextIndex) continue
                val text = steps[j].instruction.swiftTrim()
                if (text.isNotEmpty()) { following = text; break }
            }
        }

        val distanceToEnd = polyline.lastOrNull()?.let { Geo.distance(position, it) } ?: Double.POSITIVE_INFINITY
        val arrived = total > 0 && (remaining <= arrivalThreshold || (distanceToEnd <= arrivalThreshold && along > total * 0.5))

        val nextInstruction: String?
        val nextManeuver: ManeuverType
        val distanceToNext: Double?
        if (nextIndex != null) {
            nextInstruction = steps[nextIndex].instruction
            nextManeuver = steps[nextIndex].resolvedManeuver
            distanceToNext = max(0.0, maneuverDistances[nextIndex] - along)
        } else {
            nextInstruction = NavInstructionText.destination(arrived, language)
            nextManeuver = ManeuverType.ARRIVE
            distanceToNext = remaining
        }

        return RouteProgress(
            distanceAlong = along,
            remainingDistance = remaining,
            remainingTimeSeconds = remainingTime,
            fractionCompleted = if (total > 0) min(1.0, along / total) else 0.0,
            nextStepIndex = nextIndex,
            distanceToNextManeuver = distanceToNext,
            nextInstruction = nextInstruction,
            nextManeuver = nextManeuver,
            followingInstruction = following,
            crossTrackDistance = proj.distanceFromLine,
            isOffRoute = isOffRoute,
            hasArrived = arrived,
            snappedPosition = proj.point,
            nextLanes = nextIndex?.let { steps[it].lanes } ?: emptyList(),
            nextActiveLanes = nextIndex?.let { steps[it].activeLanes } ?: emptyList(),
        )
    }
}

/** Decides when to speak turn-by-turn prompts. Each threshold is spoken at most once per step. */
class VoicePromptScheduler(thresholds: List<Double> = listOf(1000.0, 400.0, 100.0)) {
    val thresholds: List<Double> = thresholds.sortedDescending()
    private val announced = HashMap<Int, MutableSet<Int>>()
    /** Language of the spoken distance prefix (default Russian). */
    var language: RVLang = RVLang.RU

    fun reset() {
        announced.clear()
    }

    fun prompt(stepIndex: Int, distance: Double, instruction: String, speedKmh: Double?): String? {
        val text = instruction.swiftTrim()
        if (text.isEmpty() || !(distance >= 0)) return null
        // Smallest threshold already crossed (thresholds are sorted descending).
        val idx = thresholds.indices.lastOrNull { distance <= thresholds[it] } ?: return null
        val done = announced.getOrPut(stepIndex) { HashSet() }
        if (done.contains(idx)) return null
        // Mark this and all larger thresholds as done so they are never spoken late.
        for (i in 0..idx) done.add(i)

        val threshold = thresholds[idx]
        if (threshold >= 1000 && (speedKmh ?: 0.0) < 30) {
            return null   // far announcements are noise in slow city traffic
        }
        if (threshold <= 150 || distance < 60) {
            return text
        }
        return "${RVFormat.spokenDistance(distance, language)} ${lowercasingFirst(text)}"
    }

    companion object {
        internal fun lowercasingFirst(s: String): String = s.rvLowercasedFirst()
    }
}
