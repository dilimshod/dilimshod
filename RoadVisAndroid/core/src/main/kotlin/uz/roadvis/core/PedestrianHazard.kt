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

/** A traffic police officer or road worker (colour heuristic, [PersonRole]) on / at the edge of the roadway. */
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
    /** Pedestrians on / about to enter the roadway, most urgent first (officers and workers excluded). */
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
 * "approaching" when moving laterally towards the roadway centre, otherwise filtered out (sidewalk).
 * Officers and road workers are reported as [RoadStaffSighting]s, never as pedestrian hazards.
 */
class PedestrianHazardDetector(
    var corridor: EgoCorridor = EgoCorridor.default,
    /** Width of the fallback roadway zone relative to the own-lane corridor. */
    var roadWidthFactor: Double = 2.2,
    /** Extra margin outside the roadway zone in which an approaching pedestrian is reported, in own-lane half widths. */
    var approachMarginFactor: Double = 1.0,
    /** Minimum lateral speed towards the lane (fraction of image width per second) to count as approaching. */
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

    /** Plausibility filter against false positives: the box must look like a standing person seen in the scene. */
    var minConfidence: Double = 0.55
    /** Frames the track must have been matched before it can raise a warning. */
    var minHits: Int = 5
    /** Minimum height / width ratio of a standing person's box. */
    var minAspectRatio: Double = 1.5
    /** Boxes taller than this share of the frame are ignored. */
    var maxBoxHeight: Double = 0.6
    /** Boxes reaching the bottom edge are ignored. */
    var bottomEdgeMargin: Double = 0.03
    /** Pedestrians estimated closer than this are ignored. */
    var minDistance: Double = 2.0

    private val history = HashMap<Int, MutableList<Pair<Double, Double>>>() // (t, x)
    private var relevant = HashMap<Int, Double>()

    /** True when the track looks like a real pedestrian in the road scene. */
    fun isPlausible(t: TrackedObject): Boolean {
        val b = t.box
        if (!(t.confidence >= minConfidence && t.hits >= minHits)) return false
        if (!(b.width > 0 && b.height / b.width >= minAspectRatio && b.height <= maxBoxHeight)) return false
        if (b.maxY > 1 - bottomEdgeMargin) return false
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
        val zone = effectiveRoadway
        val approachMargin = approachMarginFactor / max(1.0, roadWidthFactor)
        for (t in tracks) {
            if (t.kind != VehicleKind.PERSON || t.missed != 0) continue
            seen.add(t.id)
            val footX = t.box.midX; val footY = min(1.0, t.box.maxY)
            val h = history.getOrPut(t.id) { mutableListOf() }
            h.add(timestamp to footX)
            h.removeAll { timestamp - it.first > 1.0 }

            val roadCenter = zone.centerX(footY) ?: corridor.centerX
            var approaching = false
            val first = h.firstOrNull()
            if (first != null && timestamp - first.first >= 0.3) {
                val v = (footX - first.second) / (timestamp - first.first)
                val towardsCentre = (footX < roadCenter && v > 0) || (footX > roadCenter && v < 0)
                approaching = towardsCentre && abs(v) >= minApproachSpeed
            }

            val outside = zone.outsideDistance(footX, footY)
            val margin = edgeMargin + (if (relevant.containsKey(t.id)) relevanceHysteresis else 0.0)
            val atRoad = outside <= margin
            val nearEdge = outside <= margin + approachMargin
            if (!(atRoad || (approaching && nearEdge))) {
                filteredIDs.add(t.id)
                continue
            }
            relevantIDs.add(t.id)

            if (!(t.isConfirmed && isPlausible(t) && footY > corridor.horizonY)) continue
            val laneHalf = corridor.halfWidth(footY)
            if (laneHalf <= 0) continue
            val inLane = abs(footX - corridor.centerX) <= laneHalf
            val onRoad = inLane || outside <= edgeMargin

            val distance = MonocularDistance.distance(VehicleKind.PERSON.typicalHeightMeters ?: 1.7, t.box.height, geometry)
            if (distance != null && (distance > maxDistance || distance < minDistance)) continue

            val role = t.personRole
            if (role != null && role.isRoadStaff) {
                staff.add(RoadStaffSighting(t.id, role, t.box, distance, onRoad, inLane))
                continue
            }

            var level: PedestrianHazardLevel? = when {
                inLane -> PedestrianHazardLevel.DANGER
                onRoad -> if (approaching) PedestrianHazardLevel.DANGER else PedestrianHazardLevel.CAUTION
                approaching -> PedestrianHazardLevel.CAUTION
                else -> null
            }
            if (level == PedestrianHazardLevel.CAUTION && (ownSpeedKmh ?: 0.0) < 3 && !inLane) {
                level = if (approaching) PedestrianHazardLevel.CAUTION else null
            }
            val finalLevel = level ?: continue
            hazards.add(PedestrianHazard(t.id, t.box, finalLevel, distance, inLane, onRoad, approaching))
        }
        history.keys.retainAll(seen)
        for (id in filteredIDs) relevant.remove(id)
        for (id in relevantIDs) relevant[id] = timestamp
        relevant = HashMap(relevant.filter { timestamp - it.value <= 1.0 })
        hazards.sortWith { a, b ->
            if (a.level != b.level) b.level.rawValue.compareTo(a.level.rawValue)
            else (a.distanceMeters ?: Double.POSITIVE_INFINITY).compareTo(b.distanceMeters ?: Double.POSITIVE_INFINITY)
        }
        staff.sortBy { it.distanceMeters ?: Double.POSITIVE_INFINITY }
        return PersonSceneResult(hazards, staff, relevantIDs, filteredIDs)
    }
}
