package uz.roadvis.core

import kotlin.math.max

// Voice coaching for beginner drivers: decides WHAT to say and WHEN. No texts here — the app turns a `CoachMessage`
// into a phrase of the current language.
//
// Priorities (highest first): collision risk > pedestrian on the roadway > red light ahead > lane departure > tailgating >
// traffic officer / road works ahead > signs > green light hint. A global minimum gap between utterances (≈ 3 s) keeps
// the coach calm; a collision warning and a pedestrian danger warning bypass it. Every category additionally has its
// own cooldown, and pending messages expire when they are no longer relevant. All times are seconds.

/** One thing the coach wants to say (parameters only; localized by the app). */
sealed class CoachMessage {
    /** Forward-collision warning (closing fast on the lead vehicle). */
    data object CollisionRisk : CoachMessage()
    /** Pedestrian in front of the car in the own lane (or about to enter it): give way. */
    data class PedestrianDanger(val trackID: Int) : CoachMessage()
    /** Pedestrian on the roadway outside the own lane, or approaching it: be careful. */
    data class PedestrianCaution(val trackID: Int) : CoachMessage()
    /** A red traffic light ahead while still driving. */
    data object RedLightAhead : CoachMessage()
    /** Drifting over the lane marking on [side]. */
    data class LaneDeparture(val side: LaneSide) : CoachMessage()
    /** Too close to the lead vehicle; [recommendedMeters] = recommended minimum gap (rounded), when known. */
    data class KeepDistance(val recommendedMeters: Int?) : CoachMessage()
    /** OSM road feature / sign ahead at about [distanceMeters]. */
    data class RoadSign(val kind: RouteFeatureKind, val distanceMeters: Int) : CoachMessage()
    /** The speed limit of the current road changed. */
    data class SpeedLimit(val kmh: Int) : CoachMessage()
    /** A new speed limit starts ahead. */
    data class SpeedLimitAhead(val kmh: Int, val distanceMeters: Int) : CoachMessage()
    /** The camera sees a STOP sign ahead. */
    data object StopSignAhead : CoachMessage()
    /** Driving over the posted limit. */
    data class OverSpeedLimit(val limitKmh: Int) : CoachMessage()
    /** Stopped at a light that turned green, nobody close ahead: gentle "you can go". */
    data object GreenLightGo : CoachMessage()
    /** A traffic police officer (colour heuristic) ahead on / at the roadway. */
    data class TrafficOfficerAhead(val trackID: Int) : CoachMessage()
    /** Road workers (orange vests, colour heuristic) on / near the roadway ahead: slow down. */
    data class RoadWorkersAhead(val trackID: Int) : CoachMessage()

    val category: CoachCategory
        get() = when (this) {
            CollisionRisk -> CoachCategory.COLLISION
            is PedestrianDanger, is PedestrianCaution -> CoachCategory.PEDESTRIAN
            RedLightAhead -> CoachCategory.RED_LIGHT
            is LaneDeparture -> CoachCategory.LANE_DEPARTURE
            is KeepDistance -> CoachCategory.TAILGATING
            is RoadSign, is SpeedLimit, is SpeedLimitAhead, StopSignAhead, is OverSpeedLimit -> CoachCategory.SIGN
            GreenLightGo -> CoachCategory.GREEN_LIGHT
            is TrafficOfficerAhead, is RoadWorkersAhead -> CoachCategory.ROAD_STAFF
        }

    /** How urgent the utterance is (the app maps it to its speech priority: high interrupts). */
    val urgency: CoachUrgency
        get() {
            if (this is PedestrianCaution) return CoachUrgency.NORMAL
            return when (category) {
                CoachCategory.COLLISION, CoachCategory.PEDESTRIAN, CoachCategory.RED_LIGHT -> CoachUrgency.HIGH
                CoachCategory.LANE_DEPARTURE, CoachCategory.TAILGATING, CoachCategory.ROAD_STAFF, CoachCategory.SIGN -> CoachUrgency.NORMAL
                CoachCategory.GREEN_LIGHT -> CoachUrgency.LOW
            }
        }

    /** Safety-critical messages that may interrupt the calm global gap between utterances. */
    val bypassesGlobalGap: Boolean
        get() = this == CollisionRisk || this is PedestrianDanger

    /** Pedestrian track of a pedestrian message. */
    val pedestrianTrackID: Int?
        get() = when (this) {
            is PedestrianDanger -> trackID
            is PedestrianCaution -> trackID
            else -> null
        }

    /** Officer / road-worker track of a road-staff message. */
    val roadStaffTrackID: Int?
        get() = when (this) {
            is TrafficOfficerAhead -> trackID
            is RoadWorkersAhead -> trackID
            else -> null
        }

    companion object {
        /** Rounds a distance for speech: 10 m steps below 100 m, 50 m steps above. */
        fun spokenDistance(meters: Double): Int {
            if (!(meters.isFinite() && meters > 0)) return 0
            if (meters < 100) return max(10, (meters / 10).rounded().toInt() * 10)
            return (meters / 50).rounded().toInt() * 50
        }
    }
}

/** Priority order of coach messages (higher raw value = more important; enum order = priority order). */
enum class CoachCategory(val rawValue: Int) {
    GREEN_LIGHT(0), SIGN(1), ROAD_STAFF(2), TAILGATING(3), LANE_DEPARTURE(4), RED_LIGHT(5), PEDESTRIAN(6), COLLISION(7);
}

enum class CoachUrgency(val rawValue: Int) {
    LOW(0), NORMAL(1), HIGH(2);
}

/**
 * Gatekeeper: queue of offered messages → at most one utterance at a time, by priority, with a global gap,
 * per-category cooldowns and expiry.
 */
class CoachRules(var config: Config = Config()) {
    data class Config(
        /** Minimum time between two utterances, seconds (collision and pedestrian danger bypass). */
        val minGap: Double = 3.0,
        /** Minimum time between two utterances of the same category. */
        val cooldowns: Map<CoachCategory, Double> = mapOf(
            CoachCategory.COLLISION to 5.0, CoachCategory.PEDESTRIAN to 2.0, CoachCategory.RED_LIGHT to 10.0,
            CoachCategory.LANE_DEPARTURE to 6.0, CoachCategory.TAILGATING to 12.0, CoachCategory.SIGN to 2.0,
            CoachCategory.GREEN_LIGHT to 20.0, CoachCategory.ROAD_STAFF to 8.0,
        ),
        /** An offered message is dropped when it could not be spoken within this time. */
        val timeToLive: Map<CoachCategory, Double> = mapOf(
            CoachCategory.COLLISION to 1.5, CoachCategory.PEDESTRIAN to 1.5, CoachCategory.RED_LIGHT to 3.0,
            CoachCategory.LANE_DEPARTURE to 2.0, CoachCategory.TAILGATING to 3.0, CoachCategory.SIGN to 8.0,
            CoachCategory.GREEN_LIGHT to 3.0, CoachCategory.ROAD_STAFF to 4.0,
        ),
    )

    private data class Pending(val message: CoachMessage, val offeredAt: Double)

    private val pending = mutableListOf<Pending>()
    private val lastSpoken = HashMap<CoachCategory, Double>()
    private var lastUtterance = Double.NEGATIVE_INFINITY

    val pendingMessages: List<CoachMessage> get() = pending.map { it.message }

    fun reset() {
        pending.clear()
    }

    /**
     * Queues a message (an identical pending message is refreshed instead of duplicated; a newer message of the same
     * non-sign category replaces the older one).
     */
    fun offer(message: CoachMessage, now: Double) {
        pending.removeAll { it.message == message || (it.message.category == message.category && message.category != CoachCategory.SIGN) }
        pending.add(Pending(message, now))
    }

    /** Marks a category as just spoken without speaking. */
    fun markSpoken(category: CoachCategory, now: Double) {
        lastSpoken[category] = now
    }

    /** The message to speak now, if any (removes it from the queue). */
    fun next(now: Double): CoachMessage? {
        pending.removeAll { now - it.offeredAt > (config.timeToLive[it.message.category] ?: 3.0) }
        var bestIndex = -1
        for ((i, item) in pending.withIndex()) {
            val category = item.message.category
            val last = lastSpoken[category]
            if (last != null && now - last < (config.cooldowns[category] ?: 0.0)) continue
            if (!(item.message.bypassesGlobalGap || now - lastUtterance >= config.minGap)) continue
            if (bestIndex < 0) { bestIndex = i; continue }
            val best = pending[bestIndex]
            // "best < item": same category → oldest first; otherwise higher category.
            val less = if (best.message.category == category) best.offeredAt > item.offeredAt
            else best.message.category < category
            if (less) bestIndex = i
        }
        if (bestIndex < 0) return null
        val best = pending.removeAt(bestIndex)
        lastSpoken[best.message.category] = now
        lastUtterance = now
        return best.message
    }
}

// Traffic-light coaching (camera)

/** The traffic light the coach looks at (largest confirmed light of the frame). */
data class ObservedTrafficLight(val trackID: Int, val color: TrafficLightColor, val box: BBox) {
    companion object {
        /** Largest confirmed, currently seen traffic light of [tracks]. */
        fun largest(tracks: List<TrackedObject>): ObservedTrafficLight? =
            tracks.filter { it.kind == VehicleKind.TRAFFIC_LIGHT && it.isConfirmed && it.missed == 0 }
                .maxByOrNull { it.box.area }
                ?.let { ObservedTrafficLight(it.id, it.lightColor ?: TrafficLightColor.UNKNOWN, it.box) }
    }
}

/** "Red light ahead" while driving and the gentle "green, you can go" after waiting at a red light. */
class TrafficLightCoach(var config: Config = Config()) {
    data class Config(
        /** "Red ahead" only above this speed, km/h. */
        val redMinSpeedKmh: Double = 20.0,
        /** The red light must be seen this long (same track) before warning. */
        val redHold: Double = 0.5,
        /** Standing below this speed, km/h. */
        val stoppedSpeedKmh: Double = 3.0,
        /** Green must be seen this long while standing. */
        val greenHold: Double = 1.0,
        /** No "go" hint while a lead vehicle is closer than this, metres. */
        val minLeadGapMeters: Double = 4.0,
        /** Horizontal range (normalized x of the box centre) treated as "ahead". */
        val aheadMinX: Double = 0.2,
        val aheadMaxX: Double = 0.8,
        /** Above this speed the waiting episode is over, km/h. */
        val movingSpeedKmh: Double = 8.0,
    )

    private var redTrack: Int? = null
    private var redSince: Double? = null
    private var warnedRedTracks = HashSet<Int>()
    private var sawRedWhileStopped = false
    private var greenSince: Double? = null

    fun reset() {
        redTrack = null
        redSince = null
        sawRedWhileStopped = false
        greenSince = null
    }

    fun update(light: ObservedTrafficLight?, speedKmh: Double?, leadDistanceMeters: Double?, timestamp: Double): CoachMessage? {
        val speed = speedKmh ?: 0.0
        val ahead = light?.let { it.box.midX >= config.aheadMinX && it.box.midX <= config.aheadMaxX } ?: false

        if (light != null && ahead && light.color == TrafficLightColor.RED && speedKmh != null && speed > config.redMinSpeedKmh) {
            if (redTrack != light.trackID) {
                redTrack = light.trackID
                redSince = timestamp
            }
            val since = redSince
            if (since != null && timestamp - since >= config.redHold && warnedRedTracks.add(light.trackID)) {
                if (warnedRedTracks.size > 64) warnedRedTracks = hashSetOf(light.trackID)
                return CoachMessage.RedLightAhead
            }
        } else {
            redTrack = null
            redSince = null
        }

        if (speedKmh == null) return null
        if (speed >= config.movingSpeedKmh) {
            sawRedWhileStopped = false
            greenSince = null
            return null
        }
        if (!(speed < config.stoppedSpeedKmh && light != null && ahead)) {
            greenSince = null
            return null
        }
        when (light.color) {
            TrafficLightColor.RED, TrafficLightColor.YELLOW -> {
                if (light.color == TrafficLightColor.RED) sawRedWhileStopped = true
                greenSince = null
            }
            TrafficLightColor.GREEN -> {
                if (!sawRedWhileStopped) return null
                val since = greenSince ?: timestamp
                greenSince = since
                val leadOK = (leadDistanceMeters ?: Double.POSITIVE_INFINITY) >= config.minLeadGapMeters
                if (timestamp - since >= config.greenHold && leadOK) {
                    sawRedWhileStopped = false
                    greenSince = null
                    return CoachMessage.GreenLightGo
                }
            }
            TrafficLightColor.UNKNOWN -> {}
        }
        return null
    }
}

// Engine

/** Everything the coach needs from one camera frame (or a location update without camera). */
data class CoachFrameInput(
    val timestamp: Double,
    val speedKmh: Double?,
    /** Following-distance assessment (null when the feature is off). */
    val assessment: FollowingDistanceAssessment? = null,
    /** A lead vehicle is currently tracked. */
    val hasLead: Boolean = false,
    val collisionWarning: Boolean = false,
    /** A NEW lane departure was detected on this frame. */
    val laneDeparture: LaneSide? = null,
    /** Largest confirmed traffic light of the frame. */
    val light: ObservedTrafficLight? = null,
)

/** Which coaching topics are switched on. */
data class CoachToggles(
    val distance: Boolean = true,
    val laneDeparture: Boolean = true,
    val signs: Boolean = true,
    val trafficLights: Boolean = true,
    val pedestrians: Boolean = true,
    /** Traffic officer / road works ahead (colour heuristic). */
    val roadStaff: Boolean = true,
)

/** Combines the camera cues, sign events and [CoachRules] into utterances. Pure logic, one owner. */
class DriverCoachEngine(
    var toggles: CoachToggles = CoachToggles(),
    rules: CoachRules = CoachRules(),
    lights: TrafficLightCoach = TrafficLightCoach(),
) {
    /** Collision condition must hold this long before the voice warning, seconds. */
    var collisionPersistence: Double = 0.2
    /** "Too close" (moving, < ½ recommended, no imminent collision) must hold this long, seconds. */
    var tooClosePersistence: Double = 1.0
    /** The same pedestrian track is not warned again (at the same or a lower level) for this long, seconds. */
    var pedestrianTrackCooldown: Double = 6.0
    /** Caution warnings only above this own speed, km/h (danger warnings always). */
    var pedestrianCautionMinSpeedKmh: Double = 3.0
    /** The same officer / road-worker track is announced at most once per this many seconds. */
    var roadStaffTrackCooldown: Double = 20.0
    /** "Traffic police ahead" only for officers estimated closer than this, metres. */
    var officerMaxDistance: Double = 60.0

    val rules: CoachRules = rules
    val lights: TrafficLightCoach = lights
    private var collisionSince: Double? = null
    private var tooCloseSince: Double? = null
    private var pedestrianWarned = HashMap<Int, Pair<PedestrianHazardLevel, Double>>()
    private var roadStaffAnnounced = HashMap<Int, Double>()
    private var roadStaffRoleAnnounced = HashMap<PersonRole, Double>()

    fun reset() {
        collisionSince = null
        tooCloseSince = null
        pedestrianWarned.clear()
        roadStaffAnnounced.clear()
        roadStaffRoleAnnounced.clear()
        lights.reset()
        rules.reset()
    }

    /**
     * Offers a warning for the most urgent pedestrian hazard of the frame. Danger is always offered; caution only above
     * [pedestrianCautionMinSpeedKmh]. A track already warned within [pedestrianTrackCooldown] is skipped unless the
     * level rose (caution → danger).
     */
    fun updatePedestrians(hazards: List<PedestrianHazard>, speedKmh: Double?, now: Double) {
        pedestrianWarned = HashMap(pedestrianWarned.filter { now - it.value.second < pedestrianTrackCooldown })
        if (!toggles.pedestrians) return
        val moving = (speedKmh ?: 0.0) > pedestrianCautionMinSpeedKmh
        val candidates = hazards.filter { it.level == PedestrianHazardLevel.DANGER || moving }
        var top: PedestrianHazard? = null
        for (h in candidates) {
            val t = top
            if (t == null) { top = h; continue }
            val less = if (t.level != h.level) t.level < h.level
            else (t.distanceMeters ?: Double.POSITIVE_INFINITY) > (h.distanceMeters ?: Double.POSITIVE_INFINITY)
            if (less) top = h
        }
        val chosen = top ?: return
        val warned = pedestrianWarned[chosen.trackID]
        if (warned != null && warned.first >= chosen.level) return
        val message = if (chosen.level == PedestrianHazardLevel.DANGER) CoachMessage.PedestrianDanger(chosen.trackID)
        else CoachMessage.PedestrianCaution(chosen.trackID)
        rules.offer(message, now)
    }

    /**
     * Offers "traffic police ahead" (officer within [officerMaxDistance]) or "road works ahead" for the nearest sighting
     * not announced within [roadStaffTrackCooldown] (per track and per role). Officers are preferred.
     */
    fun updateRoadStaff(staff: List<RoadStaffSighting>, now: Double) {
        roadStaffAnnounced = HashMap(roadStaffAnnounced.filter { now - it.value < roadStaffTrackCooldown })
        roadStaffRoleAnnounced = HashMap(roadStaffRoleAnnounced.filter { now - it.value < roadStaffTrackCooldown })
        if (!toggles.roadStaff) return
        val fresh = staff.filter { !roadStaffAnnounced.containsKey(it.trackID) && !roadStaffRoleAnnounced.containsKey(it.role) }
        val officer = fresh.filter { it.role == PersonRole.TRAFFIC_OFFICER && (it.distanceMeters ?: 0.0) <= officerMaxDistance }
            .minByOrNull { it.distanceMeters ?: Double.POSITIVE_INFINITY }
        if (officer != null) {
            rules.offer(CoachMessage.TrafficOfficerAhead(officer.trackID), now)
            return
        }
        val worker = fresh.filter { it.role == PersonRole.ROAD_WORKER }.minByOrNull { it.distanceMeters ?: Double.POSITIVE_INFINITY }
        if (worker != null) rules.offer(CoachMessage.RoadWorkersAhead(worker.trackID), now)
    }

    /** Feeds one camera frame; offers the resulting messages to the rules. */
    fun update(input: CoachFrameInput) {
        val now = input.timestamp
        val a = input.assessment
        if (toggles.distance && input.hasLead && a != null && !a.isStopped) {
            if (input.collisionWarning) {
                tooCloseSince = null
                val since = collisionSince ?: now
                collisionSince = since
                if (now - since >= collisionPersistence) rules.offer(CoachMessage.CollisionRisk, now)
            } else if (a.status == DistanceStatus.DANGER) {
                collisionSince = null
                val since = tooCloseSince ?: now
                tooCloseSince = since
                if (now - since >= tooClosePersistence) {
                    val rec = a.recommendedDistanceMeters
                    rules.offer(CoachMessage.KeepDistance(if (rec.isFinite()) CoachMessage.spokenDistance(rec) else null), now)
                }
            } else {
                collisionSince = null
                tooCloseSince = null
            }
        } else {
            collisionSince = null
            tooCloseSince = null
        }
        val side = input.laneDeparture
        if (toggles.laneDeparture && side != null) rules.offer(CoachMessage.LaneDeparture(side), now)
        if (toggles.trafficLights) {
            val leadDistance = if (input.hasLead) input.assessment?.distanceMeters else null
            lights.update(input.light, input.speedKmh, leadDistance, now)?.let { rules.offer(it, now) }
        }
    }

    /** Offers a sign event (ignored while sign announcements are off). */
    fun offerSign(event: RoadSignEvent, now: Double) {
        if (!toggles.signs) return
        when (event) {
            is RoadSignEvent.Feature -> rules.offer(CoachMessage.RoadSign(event.kind, CoachMessage.spokenDistance(event.distance)), now)
            is RoadSignEvent.SpeedLimit -> rules.offer(CoachMessage.SpeedLimit(event.kmh), now)
            is RoadSignEvent.SpeedLimitAhead ->
                rules.offer(CoachMessage.SpeedLimitAhead(event.kmh, CoachMessage.spokenDistance(event.distance)), now)
            is RoadSignEvent.CameraStopSign -> rules.offer(CoachMessage.StopSignAhead, now)
        }
    }

    /** Offers any message directly (e.g. [CoachMessage.OverSpeedLimit]). */
    fun offer(message: CoachMessage, now: Double) {
        rules.offer(message, now)
    }

    /** The message to speak now, if any. */
    fun next(now: Double): CoachMessage? {
        val message = rules.next(now) ?: return null
        message.pedestrianTrackID?.let { id ->
            pedestrianWarned[id] = Pair(
                if (message is CoachMessage.PedestrianDanger) PedestrianHazardLevel.DANGER else PedestrianHazardLevel.CAUTION, now,
            )
        }
        message.roadStaffTrackID?.let { id ->
            roadStaffAnnounced[id] = now
            roadStaffRoleAnnounced[if (message is CoachMessage.TrafficOfficerAhead) PersonRole.TRAFFIC_OFFICER else PersonRole.ROAD_WORKER] = now
        }
        if (message == CoachMessage.CollisionRisk) rules.markSpoken(CoachCategory.TAILGATING, now)
        return message
    }
}
