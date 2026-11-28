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
    /** False until a fix has matched this route (start in a yard / parking lot, or a reroute that still begins at
     *  the road-snapped point): until then only moving AWAY from the line counts as off-route. */
    private var hasBeenOnRoute = false
    private var minOffRouteDistance = Double.POSITIVE_INFINITY
    /** First fix that did not match while the route had never been matched: position and distance from the line. */
    private var firstUnmatchedPosition: GeoPoint? = null
    private var firstUnmatchedDistance = 0.0
    /** Match threshold used by the latest [update] ([offRouteThreshold] widened by the accuracy of that fix). */
    var lastMatchThreshold: Double = offRouteThreshold
        private set

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

    /**
     * [countsTowardsOffRoute]: pass false for a poor fix (low GPS accuracy) — it still advances the progress when it
     * matches the route, but a far-off position neither counts towards nor clears the off-route state.
     * [course]: optional GPS course (degrees clockwise from north, only meaningful while moving): route segments
     * running against it by more than 100° are not matched while a continuous candidate exists.
     */
    fun update(position: GeoPoint, horizontalAccuracy: Double? = null, countsTowardsOffRoute: Boolean = true,
               course: Double? = null): RouteProgress {
        val total = totalDistance
        val threshold = offRouteThreshold + min(50.0, max(0.0, (horizontalAccuracy ?: 0.0) - 10))
        lastMatchThreshold = threshold

        // Incremental search near the last match first (avoids jumping to overlapping parts of the route).
        var projection: Geo.Projection? = null
        if (polyline.size >= 2) {
            val lo = max(0, lastSegment - 5)
            val hi = min(polyline.size - 1, lastSegment + 80)
            // 1) Continuity first: the nearest candidate that keeps the progress within [-30 m, +150 m] of the last
            //    match. Prevents snapping to the return leg of an out-and-back section (U-turn at a median break).
            val minAlong = lastAlong - 30
            val maxAlong = lastAlong + 150
            var i = lo
            while (i < hi) {
                if (cumulative[i] > maxAlong) break
                if (cumulative[i + 1] >= minAlong) {
                    val candidate = Geo.project(position, polyline, cumulative, i until (i + 1))
                    if (candidate != null && candidate.distanceAlong >= minAlong && candidate.distanceAlong <= maxAlong &&
                        candidate.distanceFromLine <= threshold &&
                        (course == null || Geo.angleDifference(candidate.segmentBearing, course) <= 100)) {
                        val best = projection
                        if (best == null) {
                            projection = candidate
                        } else {
                            // A candidate much further along (the opposite carriageway just before the U-turn) must
                            // be clearly nearer, not merely within GPS noise of the current one.
                            val jumpsAhead = candidate.distanceAlong - best.distanceAlong > 40
                            if (candidate.distanceFromLine + (if (jumpsAhead) 10.0 else 0.0) < best.distanceFromLine) {
                                projection = candidate
                            }
                        }
                    }
                }
                i += 1
            }
            // 2) No continuous candidate on the route: the wide window, then the whole route.
            if (projection == null) {
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
            }
        } else {
            projection = Geo.project(position, polyline, cumulative)
        }

        val proj = projection ?: return RouteProgress(0.0, 0.0, 0.0, 0.0, null, null, null, ManeuverType.UNKNOWN,
            null, 0.0, isOffRoute = false, hasArrived = false, snappedPosition = position)

        if (proj.distanceFromLine > threshold) {
            if (!countsTowardsOffRoute) {
                // Poor fix: the progress holds and the off-route state stays as it was.
            } else if (hasBeenOnRoute) {
                offRouteCount += 1
            } else {
                // Not on this route yet: off-route only when the car moves away from the line, or drives a real
                // distance without approaching it (a parallel street) — not while it stands still or approaches
                // (otherwise every reroute would start off-route again — a reroute storm).
                minOffRouteDistance = min(minOffRouteDistance, proj.distanceFromLine)
                if (firstUnmatchedPosition == null) {
                    firstUnmatchedPosition = position
                    firstUnmatchedDistance = proj.distanceFromLine
                }
                val travelled = firstUnmatchedPosition?.let { Geo.distance(it, position) } ?: 0.0
                val closed = firstUnmatchedDistance - proj.distanceFromLine
                val drivingPast = travelled > UNMATCHED_TRAVEL_LIMIT && closed < travelled * UNMATCHED_CLOSING_SHARE
                if (proj.distanceFromLine > minOffRouteDistance + offRouteThreshold || drivingPast) offRouteCount += 1
                else offRouteCount = 0
            }
        } else {
            hasBeenOnRoute = true
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

    companion object {
        /** Metres the car must travel without approaching the line before a never-matched route is off-route. */
        const val UNMATCHED_TRAVEL_LIMIT: Double = 150.0
        /** "Approaching" = the cross-track distance shrank by at least this share of the distance travelled. */
        const val UNMATCHED_CLOSING_SHARE: Double = 0.3
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

/** Reroute policy helpers (pure logic shared by the navigation controller and its tests; iOS `ReroutePolicy`). */
object ReroutePolicy {
    /** Bearing from the first point of [polyline] to its first point at least [minDistance] metres away. */
    fun initialBearing(polyline: List<GeoPoint>, minDistance: Double = 15.0): Double? {
        val first = polyline.firstOrNull() ?: return null
        for (i in 1 until polyline.size) {
            if (Geo.distance(first, polyline[i]) >= minDistance) return Geo.bearing(first, polyline[i])
        }
        return null
    }

    /**
     * Index of the route to follow after a reroute: the first one (fastest first) that starts within [tolerance]
     * degrees of the travel [heading]. Falls back to 0 when the heading is unknown or no route matches.
     *
     * [travelTimes] (seconds, parallel to [polylines]; index 0 = fastest) bounds the preference: a route slower than
     * the fastest one by more than max([minExtraSeconds], [maxExtraShare] × fastest) is never preferred — a forward
     * start must not buy an unbounded detour. Routes without a known time are not bounded.
     */
    fun preferredIndex(
        polylines: List<List<GeoPoint>>, heading: Double?, tolerance: Double = 90.0,
        travelTimes: List<Double> = emptyList(), minExtraSeconds: Double = 120.0, maxExtraShare: Double = 0.15,
    ): Int {
        if (heading == null || !heading.isFinite()) return 0
        val fastest: Double? = travelTimes.firstOrNull()?.takeIf { it.isFinite() && it >= 0 }
        for ((index, polyline) in polylines.withIndex()) {
            if (fastest != null && index < travelTimes.size) {
                val time = travelTimes[index]
                val allowance = max(minExtraSeconds, fastest * maxExtraShare)
                if (!time.isFinite() || time > fastest + allowance) continue
            }
            val bearing = initialBearing(polyline) ?: continue
            if (Geo.angleDifference(bearing, heading) <= tolerance) return index
        }
        return 0
    }

    /** Minimum pause before the next automatic reroute: [base] doubled per consecutive failure, capped at [maximum]. */
    fun retryInterval(base: Double = 15.0, failures: Int, maximum: Double = 120.0): Double =
        min(base * Math.pow(2.0, failures.coerceIn(0, 3).toDouble()), maximum)

    /** True for a newly listed incident at or behind the car (within [margin] metres ahead). */
    fun isIncidentAtOrBehind(distanceAlongRoute: Double, carDistanceAlong: Double, margin: Double = 30.0): Boolean =
        distanceAlongRoute <= carDistanceAlong + margin
}
