package uz.roadvis.core

import java.util.Date
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Kind of an event along the route. */
sealed class RouteTimelineKind {
    data class Maneuver(val type: ManeuverType) : RouteTimelineKind()
    /** Posted speed limit changes to this value (null = not mapped). */
    data class SpeedLimit(val kmh: Int?) : RouteTimelineKind()
    /** Lanes in the travel direction change from → to. */
    data class Lanes(val from: Int, val to: Int) : RouteTimelineKind()
    data object TrafficSignal : RouteTimelineKind()
    data class Feature(val kind: RouteFeatureKind) : RouteTimelineKind()
    data class Incident(val kind: RoadIncidentKind) : RouteTimelineKind()
    data object Destination : RouteTimelineKind()

    /** Sorting priority for events at (almost) the same place (lower first). */
    internal val priority: Int
        get() = when (this) {
            is Maneuver -> 0
            Destination -> 1
            is Incident -> 2
            TrafficSignal -> 3
            is Feature -> 4
            is SpeedLimit -> 5
            is Lanes -> 6
        }

    /** A speed camera: from OpenStreetMap or the user's own camera mark. */
    val isSpeedCamera: Boolean
        get() = this == Feature(RouteFeatureKind.SPEED_CAMERA) || this == Incident(RoadIncidentKind.SPEED_CAMERA)

    /** Short machine-friendly name ("maneuver", "speedLimit" …) used for filtering and stable ids. */
    val category: String
        get() = when (this) {
            is Maneuver -> "maneuver"
            is SpeedLimit -> "speedLimit"
            is Lanes -> "lanes"
            TrafficSignal -> "signal"
            is Feature -> if (kind.isPointOfInterest) "poi" else "hazard"
            is Incident -> "incident"
            Destination -> "destination"
        }
}

/** One upcoming event along the route ("Впереди" list, route strip, map markers). */
data class RouteTimelineEvent(
    val id: String,
    /** Distance from the route start, metres. */
    val distanceAlongRoute: Double,
    val kind: RouteTimelineKind,
    /** Russian title ("Поверните налево на …", "Ограничение 60 км/ч", "Светофор"). */
    val title: String,
    val detail: String?,
    val symbolName: String,
    /** Where the fact comes from ("маршрут Valhalla", "OSM", "Valhalla (OSM)", "ваша отметка"). */
    val source: String,
    val coordinate: GeoPoint?,
)

/** A stretch of the route with one posted speed limit (null = unknown), for the coloured route strip. */
data class SpeedLimitSegment(val start: Double, val end: Double, val limitKmh: Int?) {
    val length: Double get() = max(0.0, end - start)
}

/**
 * User-facing texts of [RouteTimeline.build] (titles, details, sources). [russian] is the default; the app passes
 * a table in its current language.
 */
class RouteTimelineText(
    val engineSource: (RouteSource) -> String,
    val lanesDetail: (total: Int, suitable: Int) -> String,
    val destination: String,
    val speedLimitTitle: (Int?) -> String,
    val speedLimitDetail: (isFirst: Boolean, length: Double) -> String,
    val laneChangeTitle: (from: Int, to: Int) -> String,
    val laneChangeDetail: (from: Int) -> String,
    val trafficSignal: String,
    val cameraLimit: (Int) -> String,
    val featureName: (RouteFeatureKind) -> String,
    val incidentName: (RoadIncidentKind) -> String,
    val incidentSource: (Date) -> String,
) {
    companion object {
        /** The original Russian texts. */
        val russian: RouteTimelineText
            get() = RouteTimelineText(
                engineSource = { if (it == RouteSource.APPLE) "маршрут Apple" else "маршрут ${it.badge}" },
                lanesDetail = { total, good -> if (good > 0) "полос: $total, подходят: $good" else "полос: $total" },
                destination = "Пункт назначения",
                speedLimitTitle = { it?.let { v -> "Ограничение $v км/ч" } ?: "Ограничение не указано в OSM" },
                speedLimitDetail = { isFirst, length -> if (isFirst) "в начале маршрута" else "на ${RVFormat.distance(length)}" },
                laneChangeTitle = { from, to -> if (to > from) "Расширение до $to полос" else "Сужение до $to полос" },
                laneChangeDetail = { "было $it" },
                trafficSignal = "Светофор",
                cameraLimit = { "контроль $it км/ч" },
                featureName = { it.displayName },
                incidentName = { it.displayName },
                incidentSource = { "ваша отметка, " + RVFormat.clock(it) },
            )
    }
}

/**
 * Builds the ordered list of events along a route from all sources: maneuvers (routing engine), speed-limit and
 * lane-count changes and signals (Valhalla trace attributes), OSM features (cameras, schools, crossings, bumps,
 * rail crossings, construction, fuel, parking) and user-reported incidents.
 */
object RouteTimeline {
    /** Shorter limit / lane segments are folded into their neighbours (avoids noise at junctions), metres. */
    const val minimumSegmentLength: Double = 120.0
    /** A Valhalla signal within this distance of an OSM signal is the same intersection, metres. */
    const val signalMergeDistance: Double = 60.0

    /**
     * Start distance of each step (scaled so the step distances sum to the polyline length) — the same
     * convention as [RouteProgressTracker.maneuverDistances].
     */
    fun maneuverDistances(steps: List<RouteStepInfo>, totalLength: Double): List<Double> {
        val stepSum = steps.sumOf { max(0.0, it.distance) }
        val scale = if (stepSum > 0) totalLength / stepSum else 1.0
        var acc = 0.0
        val result = ArrayList<Double>()
        for (s in steps) {
            result.add(min(totalLength, acc * scale))
            acc += max(0.0, s.distance)
        }
        return result
    }

    fun build(route: NavRoute, edges: List<RouteEdgeAttributes>, features: List<RouteFeature>,
              incidents: List<IncidentOnRoute>, text: RouteTimelineText = RouteTimelineText.russian): List<RouteTimelineEvent> {
        val cumulative = Geo.cumulativeDistances(route.polyline)
        val total = cumulative.lastOrNull() ?: route.distance
        fun point(d: Double): GeoPoint? = Geo.pointAtDistance(d, route.polyline, cumulative)
        val events = ArrayList<RouteTimelineEvent>()
        val engine = text.engineSource(route.source)

        // Maneuvers.
        val starts = maneuverDistances(route.steps, total)
        for ((i, step) in route.steps.withIndex()) {
            if (i < 1) continue
            val instruction = step.instruction.swiftTrim()
            if (instruction.isEmpty()) continue
            val maneuver = step.resolvedManeuver
            if (maneuver == ManeuverType.ARRIVE) continue
            var detail: String? = null
            if (step.lanes.isNotEmpty()) {
                val good = step.activeLanes.count { it }
                detail = text.lanesDetail(step.lanes.size, good)
            }
            events.add(RouteTimelineEvent("m$i", starts[i], RouteTimelineKind.Maneuver(maneuver), instruction, detail,
                maneuver.symbolName, engine, point(starts[i])))
        }
        events.add(RouteTimelineEvent("dest", total, RouteTimelineKind.Destination, text.destination, null,
            "flag.checkered", engine, route.polyline.lastOrNull()))

        // Speed-limit changes.
        val limits = speedLimitSegments(edges, total)
        var hasPrevious = false
        var previousLimit: Int? = null
        for (segment in limits) {
            if (hasPrevious && previousLimit == segment.limitKmh) continue
            val isFirst = !hasPrevious
            hasPrevious = true
            previousLimit = segment.limitKmh
            if (isFirst && segment.limitKmh == null) continue
            val title = text.speedLimitTitle(segment.limitKmh)
            val detail = text.speedLimitDetail(isFirst, segment.length)
            events.add(RouteTimelineEvent("sl${segment.start.toInt()}", segment.start,
                RouteTimelineKind.SpeedLimit(segment.limitKmh), title, detail, "speedometer", "Valhalla (OSM)",
                point(segment.start)))
        }

        // Lane-count changes (Valhalla's 1 often means "not tagged" → ignored).
        for (change in laneChanges(edges)) {
            val title = text.laneChangeTitle(change.from, change.to)
            events.add(RouteTimelineEvent("ln${change.distance.toInt()}", change.distance,
                RouteTimelineKind.Lanes(change.from, change.to), title, text.laneChangeDetail(change.from),
                "road.lanes", "Valhalla (OSM)", point(change.distance)))
        }

        // Traffic signals: OSM features first, then Valhalla signals that are not near any of them.
        val osmSignals = features.filter { it.kind == RouteFeatureKind.TRAFFIC_SIGNALS }
        for (f in osmSignals) {
            events.add(RouteTimelineEvent("s|" + f.id, f.distanceAlongRoute, RouteTimelineKind.TrafficSignal,
                text.trafficSignal, f.name, RouteFeatureKind.TRAFFIC_SIGNALS.symbolName, "OSM", f.coordinate))
        }
        for (d in Valhalla.signalDistances(edges)) {
            if (osmSignals.any { abs(it.distanceAlongRoute - d) < signalMergeDistance }) continue
            events.add(RouteTimelineEvent("vs${d.toInt()}", d, RouteTimelineKind.TrafficSignal, text.trafficSignal,
                null, RouteFeatureKind.TRAFFIC_SIGNALS.symbolName, "Valhalla (OSM)", point(d)))
        }

        // Other OSM features.
        for (f in features) {
            if (f.kind == RouteFeatureKind.TRAFFIC_SIGNALS) continue
            var detail = f.name
            if (f.kind == RouteFeatureKind.SPEED_CAMERA) {
                val limit = f.tags["maxspeed"]?.let { MaxSpeedParser.parse(it)?.kmh }
                if (limit != null) detail = listOfNotNull(detail, text.cameraLimit(limit)).joinToString(" · ")
            }
            if (f.kind == RouteFeatureKind.FUEL) {
                val brand = f.tags["brand"]
                if (brand != null && brand != f.name) detail = listOfNotNull(detail, brand).joinToString(" · ")
            }
            events.add(RouteTimelineEvent("f|" + f.id, f.distanceAlongRoute, RouteTimelineKind.Feature(f.kind),
                text.featureName(f.kind), detail, f.kind.symbolName, "OSM", f.coordinate))
        }

        // User-reported incidents.
        for (item in incidents) {
            events.add(RouteTimelineEvent("i|" + item.id.toString().uppercase(), item.distanceAlongRoute,
                RouteTimelineKind.Incident(item.incident.kind), text.incidentName(item.incident.kind),
                item.incident.note, item.incident.kind.symbolName, text.incidentSource(item.incident.date),
                item.incident.coordinate))
        }

        return events.swiftSorted { lhs, rhs ->
            if (abs(lhs.distanceAlongRoute - rhs.distanceAlongRoute) > 0.5) {
                lhs.distanceAlongRoute < rhs.distanceAlongRoute
            } else if (lhs.kind.priority != rhs.kind.priority) {
                lhs.kind.priority < rhs.kind.priority
            } else {
                lhs.id < rhs.id
            }
        }
    }

    /** Events ahead of [distanceAlong] (a few metres behind are kept so a passing event does not flicker away). */
    fun upcoming(events: List<RouteTimelineEvent>, distanceAlong: Double, limit: Int? = null): List<RouteTimelineEvent> {
        val ahead = events.filter { it.distanceAlongRoute >= distanceAlong - 5 }
        return if (limit != null) ahead.take(max(0, limit)) else ahead
    }

    /**
     * Consecutive edges with the same limit merged; segments shorter than [minimumSegmentLength] take the limit of
     * the previous segment; gaps (no edges) are null. Empty without edges.
     */
    fun speedLimitSegments(edges: List<RouteEdgeAttributes>, totalDistance: Double? = null): List<SpeedLimitSegment> {
        if (edges.isEmpty()) return emptyList()
        val raw = ArrayList<SpeedLimitSegment>()
        for (e in edges) {
            if (!(e.endDistance > e.startDistance)) continue
            val last = raw.lastOrNull()
            if (last != null && last.limitKmh == e.speedLimitKmh && e.startDistance - last.end < 1) {
                raw[raw.size - 1] = last.copy(end = max(last.end, e.endDistance))
            } else {
                if (last != null && e.startDistance - last.end >= 1) {
                    raw.add(SpeedLimitSegment(last.end, e.startDistance, null))
                }
                raw.add(SpeedLimitSegment(e.startDistance, e.endDistance, e.speedLimitKmh))
            }
        }
        // Fold short segments into the previous one, then re-merge equal neighbours.
        val folded = ArrayList<SpeedLimitSegment>()
        for (segment in raw) {
            val last = folded.lastOrNull()
            if (last != null && (segment.length < minimumSegmentLength || last.limitKmh == segment.limitKmh)) {
                folded[folded.size - 1] = last.copy(end = segment.end)
            } else {
                folded.add(segment)
            }
        }
        val last = folded.lastOrNull()
        if (totalDistance != null && last != null && totalDistance > last.end + 1) {
            folded.add(SpeedLimitSegment(last.end, totalDistance, null))
        }
        return folded
    }

    internal data class LaneChange(val distance: Double, val from: Int, val to: Int)

    /**
     * Lane-count changes ≥ [minimumSegmentLength] long; transitions to or from 1 lane are skipped (Valhalla
     * reports 1 for untagged roads).
     */
    internal fun laneChanges(edges: List<RouteEdgeAttributes>): List<LaneChange> {
        data class Run(val start: Double, var end: Double, val count: Int?)
        val runs = ArrayList<Run>()
        for (e in edges) {
            val last = runs.lastOrNull()
            if (last != null && last.count == e.laneCount) last.end = e.endDistance
            else runs.add(Run(e.startDistance, e.endDistance, e.laneCount))
        }
        val result = ArrayList<LaneChange>()
        var current: Int? = null
        for (run in runs) {
            if (!(run.end - run.start >= minimumSegmentLength)) continue
            val count = run.count ?: continue
            if (count <= 1) continue
            val previous = current
            if (previous != null && previous != count) result.add(LaneChange(run.start, previous, count))
            current = count
        }
        return result
    }

    /**
     * Time to travel from [distanceAlong] to [target] (metres along the route), seconds, proportional to the
     * typical edge speeds and scaled so that the time to the end equals [remainingTime]. Linear without edges.
     */
    fun timeOffset(target: Double, distanceAlong: Double, remainingTime: Double, totalDistance: Double,
                   edges: List<RouteEdgeAttributes>): Double {
        val remaining = max(0.0, totalDistance - distanceAlong)
        if (!(target > distanceAlong) || !(remaining > 0) || !(remainingTime > 0)) return 0.0
        val linear = remainingTime * min(1.0, (target - distanceAlong) / remaining)
        if (edges.isEmpty()) return linear
        fun typicalTime(a: Double, b: Double): Double? {
            var t = 0.0
            var covered = 0.0
            for (e in edges) {
                if (!(e.endDistance > a && e.startDistance < b)) continue
                val length = min(b, e.endDistance) - max(a, e.startDistance)
                val speed = e.typicalSpeedKmh
                if (!(length > 0) || speed == null || !(speed > 1)) continue
                t += length / (speed / 3.6)
                covered += length
            }
            if (!(covered > 0.5 * (b - a))) return null
            return t * (b - a) / covered
        }
        val part = typicalTime(distanceAlong, min(target, totalDistance)) ?: return linear
        val whole = typicalTime(distanceAlong, totalDistance) ?: return linear
        if (!(whole > 0)) return linear
        return remainingTime * min(1.0, part / whole)
    }
}
