package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

// Camera-based driving events (violations) for the trip report. All of them are HEURISTICS on monocular estimates.
// `timestamp` values are seconds on the frame clock; `dateMillis` is the wall-clock epoch-ms of the frame.

/**
 * Detects "drove through a red light": own speed above `minSpeedKmh` while a confirmed red-light track in the
 * upper-centre of the frame disappears off the top edge.
 */
class RedLightRunningDetector(var config: Config = Config()) {
    data class Config(
        val minSpeedKmh: Double = 15.0,
        /** The last box must touch this band at the top of the frame (box minY ≤ value). */
        val topEdge: Double = 0.06,
        /** Horizontal range of the box centre treated as "our" light. */
        val minX: Double = 0.25,
        val maxX: Double = 0.75,
        /** The red track must have been seen at least this long, seconds. */
        val minTrackAge: Double = 0.8,
        /** A track not seen for this long is considered gone, seconds. */
        val lostAfter: Double = 0.3,
    )

    private data class Entry(
        var box: BBox, var color: TrafficLightColor, val firstSeen: Double, var lastSeen: Double, var speedAtLastSeen: Double?,
    )

    private val entries = LinkedHashMap<Int, Entry>()

    fun reset() { entries.clear() }

    /** Returns the own speed (km/h) when a red light was just passed, else null. */
    fun update(tracks: List<TrackedObject>, speedKmh: Double?, timestamp: Double): Double? {
        val seen = HashSet<Int>()
        for (t in tracks) {
            if (!(t.kind == VehicleKind.TRAFFIC_LIGHT && t.isConfirmed && t.missed == 0)) continue
            val color = t.lightColor ?: TrafficLightColor.UNKNOWN
            val e = entries[t.id]
            if (e != null) {
                e.box = t.box
                if (color != TrafficLightColor.UNKNOWN) e.color = color
                e.lastSeen = timestamp
                e.speedAtLastSeen = speedKmh
                seen.add(t.id)
            } else if (color == TrafficLightColor.RED && t.box.midX >= config.minX && t.box.midX <= config.maxX && t.box.midY < 0.5) {
                entries[t.id] = Entry(t.box, color, timestamp, timestamp, speedKmh)
                seen.add(t.id)
            }
        }
        var result: Double? = null
        val it = entries.entries.iterator()
        while (it.hasNext()) {
            val (id, e) = it.next()
            if (id in seen || timestamp - e.lastSeen < config.lostAfter) continue
            it.remove()
            val speed = e.speedAtLastSeen ?: speedKmh
            if (!(e.color == TrafficLightColor.RED && e.box.minY <= config.topEdge && e.box.midX >= config.minX - 0.05 &&
                    e.box.midX <= config.maxX + 0.05 && e.lastSeen - e.firstSeen >= config.minTrackAge &&
                    speed != null && speed > config.minSpeedKmh)
            ) continue
            result = max(result ?: 0.0, speed)
        }
        return result
    }
}

/**
 * Detects "did not stop at a STOP sign": a confirmed STOP sign within `armDistance` metres ahead arms an episode;
 * when the sign has been out of sight for `passTimeout` seconds the episode ends, and if the own speed never dropped
 * below `stopSpeedKmh` meanwhile, it is a violation.
 */
class StopSignComplianceMonitor(var config: Config = Config()) {
    data class Config(
        val armDistance: Double = 30.0,
        val stopSpeedKmh: Double = 5.0,
        val passTimeout: Double = 2.5,
        /** Typical STOP sign width, metres. */
        val signWidthMeters: Double = 0.7,
        /** Only arm while moving at least this fast, km/h. */
        val minArmSpeedKmh: Double = 8.0,
    )

    data class Violation(
        /** Lowest own speed while passing, km/h. */
        val minSpeedKmh: Double,
        /** Distance of the sign when the episode was armed, metres. */
        val armedDistance: Double,
        val duration: Double,
    )

    private var armedAt: Double? = null
    private var armedDistance = 0.0
    private var minSpeed = Double.POSITIVE_INFINITY
    private var lastSignSeen = Double.NEGATIVE_INFINITY
    private var speedKnown = true

    val isArmed: Boolean get() = armedAt != null

    fun reset() {
        armedAt = null
        minSpeed = Double.POSITIVE_INFINITY
        speedKnown = true
    }

    /** Approximate distance of a STOP sign box, metres. */
    fun distance(box: BBox, geometry: CameraGeometry): Double? {
        if (!(box.width > 0.003 && geometry.imageWidth > 0)) return null
        return geometry.focalLengthPixels * config.signWidthMeters / (box.width * geometry.imageWidth)
    }

    fun update(tracks: List<TrackedObject>, geometry: CameraGeometry, speedKmh: Double?, timestamp: Double): Violation? {
        val signs = tracks.filter { it.kind == VehicleKind.STOP_SIGN && it.isConfirmed && it.missed == 0 }
        val nearest = signs.mapNotNull { distance(it.box, geometry) }.minOrNull()
        if (signs.isNotEmpty()) lastSignSeen = timestamp
        if (armedAt == null) {
            if (nearest != null && nearest <= config.armDistance && speedKmh != null && speedKmh >= config.minArmSpeedKmh) {
                armedAt = timestamp
                armedDistance = nearest
                minSpeed = speedKmh
                speedKnown = true
            }
            return null
        }
        if (speedKmh != null) minSpeed = min(minSpeed, speedKmh) else speedKnown = false
        val start = armedAt
        if (timestamp - lastSignSeen < config.passTimeout || start == null) return null
        armedAt = null
        val ms = minSpeed
        minSpeed = Double.POSITIVE_INFINITY
        if (!(speedKnown && ms.isFinite() && ms >= config.stopSpeedKmh)) return null
        return Violation(ms, armedDistance, timestamp - start)
    }
}

/**
 * Detects "did not give way to a pedestrian": a DANGER pedestrian hazard in the own lane within `maxDistance` metres
 * while the own speed stays above `minSpeedKmh` for at least `minDuration` seconds (same track). Reported once per track.
 */
class PedestrianYieldMonitor(var config: Config = Config()) {
    data class Config(
        val minSpeedKmh: Double = 15.0,
        val maxDistance: Double = 15.0,
        val minDuration: Double = 0.4,
    )

    data class Violation(
        val trackID: Int,
        /** Closest distance to the pedestrian during the episode, metres (≈). */
        val closestDistance: Double,
        /** Lowest own speed during the episode, km/h. */
        val minSpeedKmh: Double,
        val duration: Double,
    )

    private data class Episode(val start: Double, var closest: Double, var minSpeed: Double)

    private val episodes = HashMap<Int, Episode>()
    private var reported = HashSet<Int>()

    fun reset() {
        episodes.clear()
        reported.clear()
    }

    fun update(hazards: List<PedestrianHazard>, speedKmh: Double?, timestamp: Double): List<Violation> {
        val result = mutableListOf<Violation>()
        val active = HashSet<Int>()
        if (speedKmh != null && speedKmh > config.minSpeedKmh) {
            for (h in hazards) {
                if (!(h.level == PedestrianHazardLevel.DANGER && h.inOwnLane)) continue
                val d = h.distanceMeters ?: continue
                if (d > config.maxDistance) continue
                active.add(h.trackID)
                val e = episodes.getOrPut(h.trackID) { Episode(timestamp, d, speedKmh) }
                e.closest = min(e.closest, d)
                e.minSpeed = min(e.minSpeed, speedKmh)
                if (timestamp - e.start >= config.minDuration && reported.add(h.trackID)) {
                    result.add(Violation(h.trackID, e.closest, e.minSpeed, timestamp - e.start))
                }
            }
        }
        episodes.keys.retainAll(active)
        if (reported.size > 256) reported = HashSet(reported.intersect(active))
        return result
    }
}

/** Inputs of one processed frame for the event monitor. */
data class CameraEventInput(
    /** Frame clock, seconds. */
    val timestamp: Double,
    /** Wall-clock time of the frame, epoch ms (used as the event date). */
    val dateMillis: Long = System.currentTimeMillis(),
    val speedKmh: Double?,
    val coordinate: GeoPoint? = null,
    val assessment: FollowingDistanceAssessment? = null,
    val hasLead: Boolean = false,
    val collisionWarning: Boolean = false,
    /** Collision TTC threshold of the policy, seconds (for `DrivingEvent.limit`). */
    val collisionThresholdSeconds: Double = 2.5,
    /** NEW lane departure on this frame (from [LaneDepartureDetector]). */
    val laneDeparture: LaneSide? = null,
    /** Lane offset at the departure (for `DrivingEvent.value`). */
    val laneOffset: Double? = null,
    val tracks: List<TrackedObject> = emptyList(),
    val geometry: CameraGeometry? = null,
    /** Pedestrians on / about to enter the roadway (from [PedestrianHazardDetector]). */
    val pedestrianHazards: List<PedestrianHazard> = emptyList(),
    /** Traffic officers / road workers on or at the roadway (colour heuristic). */
    val roadStaff: List<RoadStaffSighting> = emptyList(),
)

/**
 * Produces camera-based [DrivingEvent]s: tailgating (moving, gap < ½ recommended for ≥ 2 s), collision risk,
 * lane departure, red-light running, STOP sign ignored, pedestrian not given way, officer / road workers seen.
 * Repeats are collapsed with [DrivingEventDebouncer], so only NEW events are returned.
 */
class CameraDrivingEventMonitor(cooldown: Double = 8.0) {
    /** Tailgating: gap below this fraction of the recommended gap… */
    var tailgatingFraction: Double = 0.5
    /** …for at least this long, seconds. */
    var tailgatingDuration: Double = 2.0

    var redLight = RedLightRunningDetector()
    var stopSign = StopSignComplianceMonitor()
    var pedestrians = PedestrianYieldMonitor()
    private var loggedStaffTracks = HashSet<Int>()
    val debouncer: DrivingEventDebouncer = DrivingEventDebouncer(cooldown)
    private var tailgatingSince: Double? = null
    private var tailgatingReported = false
    private var worstGap = Double.POSITIVE_INFINITY
    private var collisionActive = false

    fun reset() {
        tailgatingSince = null
        tailgatingReported = false
        worstGap = Double.POSITIVE_INFINITY
        collisionActive = false
        redLight.reset()
        stopSign.reset()
        pedestrians.reset()
        loggedStaffTracks.clear()
    }

    /** New events of this frame. */
    fun update(input: CameraEventInput): List<DrivingEvent> {
        val events = mutableListOf<DrivingEvent>()
        fun make(kind: DrivingEventKind, value: Double? = null, limit: Double? = null, duration: Double = 0.0, heuristic: Boolean = true) =
            DrivingEvent(kind = kind, dateMillis = input.dateMillis, coordinate = input.coordinate, speedKmh = input.speedKmh,
                value = value, limit = limit, duration = duration, note = if (heuristic) heuristicNote else null)

        val a = input.assessment
        val d = a?.distanceMeters
        val fraction = a?.fractionOfRecommended
        if (input.hasLead && a != null && !a.isStopped && d != null && fraction != null && fraction < tailgatingFraction) {
            val since = tailgatingSince ?: input.timestamp
            tailgatingSince = since
            worstGap = min(worstGap, d)
            if (!tailgatingReported && input.timestamp - since >= tailgatingDuration) {
                tailgatingReported = true
                events.add(make(DrivingEventKind.TAILGATING, worstGap, a.recommendedDistanceMeters, input.timestamp - since))
            }
        } else {
            tailgatingSince = null
            tailgatingReported = false
            worstGap = Double.POSITIVE_INFINITY
        }

        if (input.collisionWarning) {
            if (!collisionActive) {
                collisionActive = true
                events.add(make(DrivingEventKind.COLLISION_RISK, input.assessment?.timeToCollisionSeconds, input.collisionThresholdSeconds))
            }
        } else {
            collisionActive = false
        }

        input.laneDeparture?.let { side ->
            val e = make(DrivingEventKind.LANE_DEPARTURE, input.laneOffset)
            e.note = "$heuristicNote; side=${side.raw}"
            events.add(e)
        }

        redLight.update(input.tracks, input.speedKmh, input.timestamp)?.let { speed ->
            val e = make(DrivingEventKind.RED_LIGHT_RUNNING, speed)
            e.speedKmh = speed
            events.add(e)
        }

        val geometry = input.geometry
        if (geometry != null) {
            stopSign.update(input.tracks, geometry, input.speedKmh, input.timestamp)?.let { v ->
                events.add(make(DrivingEventKind.STOP_SIGN_IGNORED, v.minSpeedKmh, stopSign.config.stopSpeedKmh, v.duration))
            }
        }

        for (v in pedestrians.update(input.pedestrianHazards, input.speedKmh, input.timestamp)) {
            events.add(make(DrivingEventKind.PEDESTRIAN_NOT_YIELDED, v.closestDistance, pedestrians.config.maxDistance, v.duration))
        }

        for (s in input.roadStaff) {
            if (!loggedStaffTracks.add(s.trackID)) continue
            if (loggedStaffTracks.size > 256) loggedStaffTracks = hashSetOf(s.trackID)
            val kind = if (s.role == PersonRole.TRAFFIC_OFFICER) DrivingEventKind.TRAFFIC_OFFICER_SEEN else DrivingEventKind.ROAD_WORKERS_SEEN
            events.add(make(kind, s.distanceMeters))
        }

        return events.filter { debouncer.add(it) }
    }

    companion object {
        /** Note attached to heuristic events. */
        const val heuristicNote = "heuristic"
    }
}
