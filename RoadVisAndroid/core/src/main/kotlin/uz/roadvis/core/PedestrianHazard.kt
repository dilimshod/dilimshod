package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** How urgent a pedestrian warning is (ordered: CAUTION < DANGER). */
enum class PedestrianHazardLevel(val rawValue: Int) {
    /** Pedestrian at the roadway edge moving towards it, or on the roadway outside the own lane. */
    CAUTION(1),
    /** Pedestrian in front of the car in the own lane (or about to enter it) — give way. */
    DANGER(2);

    companion object {
        fun fromRaw(raw: Int): PedestrianHazardLevel? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** A pedestrian on or about to enter the roadway ahead. */
data class PedestrianHazard(
    val trackID: Int,
    val box: BBox,
    val level: PedestrianHazardLevel,
    /** Rough monocular distance (≈), metres. */
    val distanceMeters: Double?,
    /** Feet are inside the own-lane corridor. */
    val inOwnLane: Boolean,
    /** Feet are on the roadway area (own lane or wider road zone). */
    val onRoadway: Boolean,
    /** Moving laterally towards the own lane. */
    val approaching: Boolean,
)

/**
 * A traffic police officer or road worker (colour heuristic, [PersonRole]) on / at the edge of the roadway. At the
 * roadway edge / in other lanes they get their own banner / voice instead of "yield to the pedestrian"; in the own lane
 * they raise the pedestrian danger as well.
 */
data class RoadStaffSighting(
    val trackID: Int,
    val role: PersonRole,
    val box: BBox,
    /** Rough monocular distance (≈), metres. */
    val distanceMeters: Double?,
    /** Feet inside the roadway zone (not only at its edge). */
    val onRoadway: Boolean,
    /** Feet inside the own-lane corridor. */
    val inOwnLane: Boolean,
)

/** Result of one frame of [PedestrianHazardDetector.evaluate]. */
data class PersonSceneResult(
    /**
     * Pedestrians on / about to enter the roadway, most urgent first. Officers / workers are included only when they
     * are in the own lane or on the roadway moving toward it (then they are in [staff] too).
     */
    val hazards: List<PedestrianHazard> = emptyList(),
    /** Officers / road workers on or at the edge of the roadway, nearest first. */
    val staff: List<RoadStaffSighting> = emptyList(),
    /** Person tracks on / at the roadway or moving toward it: shown, counted and logged. */
    val relevantIDs: Set<Int> = emptySet(),
    /** Person tracks outside the roadway zone and not moving toward it (sidewalk): hidden completely. */
    val filteredIDs: Set<Int> = emptySet(),
)

/**
 * Decides whether detected pedestrians are on the roadway / in front of the car, and which persons are outside the
 * roadway (sidewalk) and must not be recognised at all. A person's ground contact point is the bottom-centre of the box:
 * "in the own lane" inside the [EgoCorridor], "on the roadway" inside the [RoadwayZone] (+ [edgeMargin]),
 * "approaching" when moving towards the roadway centre in ROAD-RELATIVE coordinates (u = offset from the zone centre ÷
 * the perspective half width of the zone at the feet row, ∝ lateral metres), so the car's own forward motion and turns
 * do not count; otherwise filtered out (sidewalk) — also when approaching but more than [timeToEdgeSeconds] away from
 * the roadway edge. Officers and road workers at the roadway are reported as [RoadStaffSighting]s. The role is a colour
 * guess, so it never SUPPRESSES a danger: a person in the own lane (or on the roadway and moving toward the lane) is a
 * DANGER pedestrian hazard whatever the role.
 */
class PedestrianHazardDetector(
    var corridor: EgoCorridor = EgoCorridor.default,
    /** Width of the fallback roadway zone relative to the own-lane corridor. */
    var roadWidthFactor: Double = 2.2,
    /** Extra margin outside the roadway zone in which an approaching pedestrian is reported, in own-lane half widths. */
    var approachMarginFactor: Double = 1.0,
    /** Fallback only (no usable zone width at the feet row): minimum lateral speed towards the lane, image widths / s. */
    var minApproachSpeed: Double = 0.04,
    /** Pedestrians farther than this are ignored, metres. */
    var maxDistance: Double = 60.0,
) {
    /** Roadway zone (from [RoadwayZoneEstimator]); null → the corridor widened by [roadWidthFactor]. */
    var roadway: RoadwayZone? = null
    /** Feet up to this far beyond the roadway boundary (in roadway half widths) still count as "at the roadway edge". */
    var edgeMargin: Double = 0.08
    /** A person already relevant stays relevant until this much farther out (no flicker at the boundary). */
    var relevanceHysteresis: Double = 0.1
    /**
     * Officers / road workers are kept up to this far beyond the roadway boundary (in roadway half widths): they
     * normally stand on the shoulder / kerb. Bounded on purpose — the role is a vest-colour heuristic.
     */
    var staffEdgeMargin: Double = 1.0

    /**
     * Minimum speed toward the road centre in road-relative units (perspective zone half widths per second). Pinhole
     * arithmetic (not a measurement): a pedestrian walking 1.4 m/s toward a road of 3.5–7 m half width changes u by
     * 0.2–0.4 per second, while a standing one stays constant.
     */
    var minRoadRelativeApproachSpeed: Double = 0.20
    /** History needed before the road-relative slope is trusted, seconds / samples. */
    var minApproachHistory: Double = 0.4
    var minApproachSamples: Int = 4
    /** A person outside the roadway is reported when the feet reach the roadway edge within this many seconds… */
    var timeToEdgeSeconds: Double = 2.5
    /** …but never from farther out than this (zone half widths beyond the boundary). */
    var maxApproachOutside: Double = 1.0

    /**
     * Plausibility filter against false positives: the box must look like a standing person seen in the scene.
     * Compared with the track's best score so far ([TrackedObject.peakConfidence]), not the latest frame's.
     */
    var minConfidence: Double = 0.55
    /** Frames the track must have been matched before it can raise a warning. */
    var minHits: Int = 5
    /**
     * Minimum height / width ratio of a standing person's box IN PIXELS (the normalized sides are scaled by the
     * frame's height / width first: normalized 1.5 would mean 2.67 in a portrait frame and 0.84 in landscape).
     */
    var minAspectRatio: Double = 1.5
    /** Boxes taller than this share of the frame are ignored. */
    var maxBoxHeight: Double = 0.6
    /** Boxes reaching the bottom edge are ignored. */
    var bottomEdgeMargin: Double = 0.03
    /** Pedestrians estimated closer than this are ignored. */
    var minDistance: Double = 2.0

    /** Per track: time, feet x (image), road-relative u (null when the zone has no width at that row). */
    private class Sample(val t: Double, val x: Double, val u: Double?)

    private val history = HashMap<Int, MutableList<Sample>>()
    /** Last time each person track was relevant (hysteresis; kept ≈ 1 s across missed frames). */
    private var relevant = HashMap<Int, Double>()

    /** True when the track looks like a real pedestrian in the road scene. */
    fun isPlausible(t: TrackedObject, geometry: CameraGeometry = CameraGeometry.defaultPortrait): Boolean {
        val b = t.box
        if (!(max(t.confidence, t.peakConfidence) >= minConfidence && t.hits >= minHits)) return false
        // Box sides are normalized to the frame width / height separately: compare the ratio in pixels.
        val frameAspect = if (geometry.imageWidth > 0 && geometry.imageHeight > 0) geometry.imageHeight / geometry.imageWidth else 1.0
        if (!(b.width > 0 && (b.height / b.width) * frameAspect >= minAspectRatio && b.height <= maxBoxHeight)) return false
        if (b.maxY > 1 - bottomEdgeMargin) return false
        // Large boxes cut by the left/right frame edge are almost always parts of the car or the driver's hand.
        if ((b.minX <= 0.01 || b.maxX >= 0.99) && b.height > 0.3) return false
        return true
    }

    fun reset() {
        history.clear()
        relevant.clear()
    }

    /** The zone in use (the explicit roadway or the widened corridor). */
    val effectiveRoadway: RoadwayZone
        get() = roadway ?: RoadwayZone.fromCorridor(corridor, roadWidthFactor)

    /** Returns hazards sorted by urgency (danger first, then nearest). */
    fun update(tracks: List<TrackedObject>, ownSpeedKmh: Double?, geometry: CameraGeometry, timestamp: Double): List<PedestrianHazard> =
        evaluate(tracks, ownSpeedKmh, geometry, timestamp).hazards

    /** Classifies every person track of the frame: hazard / road staff / relevant / filtered (sidewalk). */
    fun evaluate(tracks: List<TrackedObject>, ownSpeedKmh: Double?, geometry: CameraGeometry, timestamp: Double): PersonSceneResult {
        val hazards = mutableListOf<PedestrianHazard>()
        val staff = mutableListOf<RoadStaffSighting>()
        val relevantIDs = LinkedHashSet<Int>()
        val filteredIDs = LinkedHashSet<Int>()
        val seen = HashSet<Int>()
        val coastedIDs = HashSet<Int>()
        val zone = effectiveRoadway
        val fallbackApproachMargin = approachMarginFactor / max(1.0, roadWidthFactor)
        for (t in tracks) {
            if (t.kind != VehicleKind.PERSON) continue
            seen.add(t.id)
            if (t.missed > 0) {
                // Coasted track (predicted box, `ObjectTracker.Config.coastFrames`): never a warning and no motion
                // sample from a prediction. It only keeps its previous sidewalk / roadway classification and its
                // history, so a sidewalk person does not flash up and the crossing-intent history survives the gap.
                coastedIDs.add(t.id)
                if (relevant.containsKey(t.id)) relevantIDs.add(t.id) else filteredIDs.add(t.id)
                continue
            }
            val footX = t.box.midX; val footY = min(1.0, t.box.maxY)
            val roadCenter = zone.centerX(footY) ?: corridor.centerX
            val zoneHalf = zone.halfWidth(footY)
            // Road-relative lateral position: offset ÷ (growth of the zone half width per row × rows below the
            // horizon) — proportional to the lateral distance in metres, whatever the depth.
            val perspectiveHalf = perspectiveHalfWidth(zone, footY)
            val u: Double? = if (perspectiveHalf > 1e-4) (footX - roadCenter) / perspectiveHalf else null
            val h = history.getOrPut(t.id) { mutableListOf() }
            h.add(Sample(timestamp, footX, u))
            h.removeAll { timestamp - it.t > 1.0 }

            // Crossing intent. Road-relative: least-squares slope of u over the last second.
            var approaching = false
            var approachSpeed = 0.0 // zone half widths per second toward the centre (road-relative path)
            var roadRelative = false
            val first = h.firstOrNull()
            if (u != null && first != null && timestamp - first.t >= minApproachHistory) {
                val samples = h.filter { it.u != null }
                if (samples.size >= minApproachSamples && samples.size == h.size) {
                    val n = samples.size.toDouble()
                    val mt = samples.sumOf { it.t } / n
                    val mu = samples.sumOf { it.u ?: 0.0 } / n
                    var num = 0.0; var den = 0.0
                    for (sample in samples) {
                        num += (sample.t - mt) * ((sample.u ?: 0.0) - mu)
                        den += (sample.t - mt) * (sample.t - mt)
                    }
                    if (den > 1e-9) {
                        roadRelative = true
                        val slope = num / den // + = moving right of the road centre
                        val toward = if (u > 0) -slope else slope
                        if (toward >= minRoadRelativeApproachSpeed) {
                            approaching = true
                            approachSpeed = toward
                        }
                    }
                }
            }
            if (!roadRelative && u == null && first != null && timestamp - first.t >= 0.3) {
                // Fallback (zone without width at this row): raw image velocity.
                val v = (footX - first.x) / (timestamp - first.t) // + = moving right
                val towardsCentre = (footX < roadCenter && v > 0) || (footX > roadCenter && v < 0)
                approaching = towardsCentre && abs(v) >= minApproachSpeed
            }

            // Sidewalk filter (zone relation of the feet).
            val outside = zone.outsideDistance(footX, footY)
            val hysteresis = if (relevant.containsKey(t.id)) relevanceHysteresis else 0.0
            val margin = edgeMargin + hysteresis
            // Road staff stand beside the carriageway: a wider margin keeps them visible. They are reported with
            // onRoadway = false below (no pedestrian hazard there).
            val isStaff = t.personRole?.isRoadStaff == true
            val atRoad = outside <= margin || (isStaff && outside <= staffEdgeMargin + hysteresis)
            // Outside the zone: reported when the feet would reach the roadway edge within `timeToEdgeSeconds`.
            val unitRatio = if (zoneHalf > 1e-6) perspectiveHalf / zoneHalf else 1.0
            val approachReach = if (roadRelative) min(maxApproachOutside, approachSpeed * timeToEdgeSeconds * unitRatio)
            else fallbackApproachMargin
            val nearEdge = outside <= margin + approachReach
            if (!(atRoad || (approaching && nearEdge))) {
                filteredIDs.add(t.id)
                continue
            }
            relevantIDs.add(t.id)

            if (!(t.isConfirmed && isPlausible(t, geometry) && footY > corridor.horizonY)) continue
            val laneHalf = corridor.halfWidth(footY)
            if (laneHalf <= 0) continue
            // The feet (bottom centre) decide — a box merely overlapping the corridor does not.
            val inLane = abs(footX - corridor.centerX) <= laneHalf
            val onRoad = inLane || outside <= edgeMargin

            val distance = MonocularDistance.distance(VehicleKind.PERSON.typicalHeightMeters ?: 1.7, t.box.height, geometry)
            if (distance != null && (distance > maxDistance || distance < minDistance)) continue

            val role = t.personRole
            if (role != null && role.isRoadStaff) {
                staff.add(RoadStaffSighting(t.id, role, t.box, distance, onRoad, inLane))
                // The role is a vest-colour guess. Suppressing a danger on that guess is the wrong failure direction:
                // a person in the own lane, or on the roadway and moving toward the lane, is a danger whatever the role.
                if (inLane || (onRoad && approaching)) {
                    hazards.add(PedestrianHazard(t.id, t.box, PedestrianHazardLevel.DANGER, distance, inLane, onRoad, approaching))
                }
                continue
            }

            var level: PedestrianHazardLevel? = when {
                inLane -> PedestrianHazardLevel.DANGER
                onRoad -> if (approaching) PedestrianHazardLevel.DANGER else PedestrianHazardLevel.CAUTION
                approaching -> PedestrianHazardLevel.CAUTION
                else -> null
            }
            // When standing still a pedestrian off the own lane is only informative.
            if (level == PedestrianHazardLevel.CAUTION && (ownSpeedKmh ?: 0.0) < 3 && !inLane) {
                level = if (approaching) PedestrianHazardLevel.CAUTION else null
            }
            val finalLevel = level ?: continue
            hazards.add(PedestrianHazard(t.id, t.box, finalLevel, distance, inLane, onRoad, approaching))
        }
        history.keys.retainAll(seen)
        for (id in filteredIDs) relevant.remove(id)
        // A coasted person does not refresh its relevance time (it still expires 1 s after the last detection).
        for (id in relevantIDs) if (id !in coastedIDs) relevant[id] = timestamp
        relevant = HashMap(relevant.filter { timestamp - it.value <= 1.0 })
        hazards.sortWith { a, b ->
            if (a.level != b.level) b.level.rawValue.compareTo(a.level.rawValue)
            else (a.distanceMeters ?: Double.POSITIVE_INFINITY).compareTo(b.distanceMeters ?: Double.POSITIVE_INFINITY)
        }
        staff.sortBy { it.distanceMeters ?: Double.POSITIVE_INFINITY }
        return PersonSceneResult(hazards, staff, relevantIDs, filteredIDs)
    }

    companion object {
        /**
         * Half width of the zone at row [y] without its residual width at the horizon: the slope of the half width
         * per row × the rows below the horizon. 0 at / above the horizon or for a zone that does not widen downward.
         */
        internal fun perspectiveHalfWidth(zone: RoadwayZone, y: Double): Double {
            if (y <= zone.horizonY) return 0.0
            val low = zone.halfWidth(1.0); val high = zone.halfWidth(zone.horizonY + 1e-6)
            val span = 1 - zone.horizonY
            if (!(span > 0.01 && low > high)) return 0.0
            return (low - high) / span * (y - zone.horizonY)
        }
    }
}
