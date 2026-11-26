import Foundation

/// How urgent a pedestrian warning is.
public enum PedestrianHazardLevel: Int, Codable, Hashable, Sendable, Comparable {
    /// Pedestrian at the roadway edge moving towards it, or on the roadway outside the own lane.
    case caution = 1
    /// Pedestrian in front of the car in the own lane (or about to enter it) — give way.
    case danger = 2

    public static func < (lhs: PedestrianHazardLevel, rhs: PedestrianHazardLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A pedestrian on or about to enter the roadway ahead.
public struct PedestrianHazard: Hashable, Sendable {
    public var trackID: Int
    public var box: BBox
    public var level: PedestrianHazardLevel
    /// Rough monocular distance (≈), metres.
    public var distanceMeters: Double?
    /// Feet are inside the own-lane corridor.
    public var inOwnLane: Bool
    /// Feet are on the roadway area (own lane or wider road zone).
    public var onRoadway: Bool
    /// Moving laterally towards the own lane.
    public var approaching: Bool

    public init(trackID: Int, box: BBox, level: PedestrianHazardLevel, distanceMeters: Double?, inOwnLane: Bool,
                onRoadway: Bool, approaching: Bool) {
        self.trackID = trackID
        self.box = box
        self.level = level
        self.distanceMeters = distanceMeters
        self.inOwnLane = inOwnLane
        self.onRoadway = onRoadway
        self.approaching = approaching
    }
}

/// A traffic police officer or road worker (colour heuristic, `PersonRole`) on / at the edge of the roadway. They are
/// on the road deliberately, so they get their own banner / voice instead of "yield to the pedestrian".
public struct RoadStaffSighting: Hashable, Sendable {
    public var trackID: Int
    public var role: PersonRole
    public var box: BBox
    /// Rough monocular distance (≈), metres.
    public var distanceMeters: Double?
    /// Feet inside the roadway zone (not only at its edge).
    public var onRoadway: Bool
    /// Feet inside the own-lane corridor.
    public var inOwnLane: Bool

    public init(trackID: Int, role: PersonRole, box: BBox, distanceMeters: Double?, onRoadway: Bool, inOwnLane: Bool) {
        self.trackID = trackID
        self.role = role
        self.box = box
        self.distanceMeters = distanceMeters
        self.onRoadway = onRoadway
        self.inOwnLane = inOwnLane
    }
}

/// Result of one frame of `PedestrianHazardDetector.evaluate`.
public struct PersonSceneResult: Hashable, Sendable {
    /// Pedestrians on / about to enter the roadway, most urgent first (officers and workers excluded).
    public var hazards: [PedestrianHazard]
    /// Officers / road workers on or at the edge of the roadway, nearest first.
    public var staff: [RoadStaffSighting]
    /// Person tracks on / at the roadway or moving toward it: they are shown, counted and logged.
    public var relevantIDs: Set<Int>
    /// Person tracks outside the roadway zone and not moving toward it (sidewalk): hidden completely.
    public var filteredIDs: Set<Int>

    public init(hazards: [PedestrianHazard] = [], staff: [RoadStaffSighting] = [], relevantIDs: Set<Int> = [],
                filteredIDs: Set<Int> = []) {
        self.hazards = hazards
        self.staff = staff
        self.relevantIDs = relevantIDs
        self.filteredIDs = filteredIDs
    }
}

/// Decides whether detected pedestrians are on the roadway / in front of the car, and which persons are outside the
/// roadway (sidewalk) and must not be recognised at all.
///
/// Geometry (image space, y down): a person's ground contact point is the bottom-centre of the box. It is
///  - "in the own lane" when inside the `EgoCorridor` trapezoid at that row,
///  - "on the roadway" when inside the `RoadwayZone` (lane markings extended by the typical number of lanes, or the
///    corridor widened by `roadWidthFactor` when no markings are confident) plus a small `edgeMargin`,
///  - "approaching" when moving laterally towards the roadway centre,
///  - "filtered out" (sidewalk) when outside the zone by more than `edgeMargin` and not approaching — or approaching
///    but still farther than the approach margin. Such persons get no box, no label, no warning and are not counted.
/// Officers and road workers (`TrackedObject.personRole`) inside the zone are reported as `RoadStaffSighting`s, never as
/// pedestrian hazards. This is a camera heuristic, so warnings are phrased as advice.
public final class PedestrianHazardDetector {
    public var corridor: EgoCorridor
    /// Roadway zone (from `RoadwayZoneEstimator`); nil → the corridor widened by `roadWidthFactor`.
    public var roadway: RoadwayZone?
    /// Width of the fallback roadway zone relative to the own-lane corridor.
    public var roadWidthFactor: Double
    /// Extra margin outside the roadway zone in which an approaching pedestrian is reported, in own-lane half widths
    /// (converted to roadway half widths by dividing by `roadWidthFactor`).
    public var approachMarginFactor: Double
    /// Feet up to this far beyond the roadway boundary (in roadway half widths) still count as "at the roadway edge".
    public var edgeMargin: Double = 0.08
    /// A person already relevant stays relevant until this much farther out (no flicker at the boundary).
    public var relevanceHysteresis: Double = 0.1
    /// Officers / road workers are kept up to this far beyond the roadway boundary (in roadway half widths): they
    /// normally stand on the shoulder / kerb. Bounded on purpose — the role is a vest-colour heuristic, so an
    /// unlimited exemption would surface every sidewalk pedestrian in an orange or lime jacket.
    public var staffEdgeMargin: Double = 1.0
    /// Minimum lateral speed towards the lane (fraction of image width per second) to count as approaching.
    public var minApproachSpeed: Double
    /// Pedestrians farther than this are ignored, metres.
    public var maxDistance: Double

    /// Plausibility filter against false positives (a hand, the dashboard, a passenger, a sign or a poster
    /// recognised as "person"): the box must look like a standing person seen in the scene.
    /// Compared with the track's best score so far (`TrackedObject.peakConfidence`), not the latest frame's.
    public var minConfidence: Double = 0.55
    /// Frames the track must have been matched before it can raise a warning (≈ 0.35 s at 15 fps).
    public var minHits: Int = 5
    /// Minimum height / width ratio of a standing person's box.
    public var minAspectRatio: Double = 1.5
    /// Boxes taller than this share of the frame are ignored (objects right in front of the lens).
    public var maxBoxHeight: Double = 0.6
    /// Boxes reaching the bottom edge are ignored (hands / dashboard; a pedestrian's feet are visible on the road).
    public var bottomEdgeMargin: Double = 0.03
    /// Pedestrians estimated closer than this are ignored (≈ inside the car / under the bonnet).
    public var minDistance: Double = 2.0

    private var history: [Int: [(t: TimeInterval, x: Double)]] = [:]
    /// Last time each person track was relevant (hysteresis; kept ≈ 1 s across missed frames).
    private var relevant: [Int: TimeInterval] = [:]

    /// True when the track looks like a real pedestrian in the road scene.
    public func isPlausible(_ t: TrackedObject) -> Bool {
        let b = t.box
        guard max(t.confidence, t.peakConfidence) >= minConfidence, t.hits >= minHits else { return false }
        guard b.width > 0, b.height / b.width >= minAspectRatio, b.height <= maxBoxHeight else { return false }
        guard b.maxY <= 1 - bottomEdgeMargin else { return false }
        // Large boxes cut by the left/right frame edge are almost always parts of the car or the driver's hand.
        if (b.minX <= 0.01 || b.maxX >= 0.99) && b.height > 0.3 { return false }
        return true
    }

    public init(corridor: EgoCorridor = .default, roadWidthFactor: Double = 2.2, approachMarginFactor: Double = 1.0,
                minApproachSpeed: Double = 0.04, maxDistance: Double = 60) {
        self.corridor = corridor
        self.roadWidthFactor = roadWidthFactor
        self.approachMarginFactor = approachMarginFactor
        self.minApproachSpeed = minApproachSpeed
        self.maxDistance = maxDistance
    }

    public func reset() {
        history.removeAll()
        relevant.removeAll()
    }

    /// The zone in use (the explicit roadway or the widened corridor).
    public var effectiveRoadway: RoadwayZone {
        roadway ?? RoadwayZone.fromCorridor(corridor, widthFactor: roadWidthFactor)
    }

    /// Returns hazards sorted by urgency (danger first, then nearest).
    public func update(tracks: [TrackedObject], ownSpeedKmh: Double?, geometry: CameraGeometry,
                       timestamp: TimeInterval) -> [PedestrianHazard] {
        evaluate(tracks: tracks, ownSpeedKmh: ownSpeedKmh, geometry: geometry, timestamp: timestamp).hazards
    }

    /// Classifies every person track of the frame: hazard / road staff / relevant / filtered (sidewalk).
    public func evaluate(tracks: [TrackedObject], ownSpeedKmh: Double?, geometry: CameraGeometry,
                         timestamp: TimeInterval) -> PersonSceneResult {
        var result = PersonSceneResult()
        var seen = Set<Int>()
        let zone = effectiveRoadway
        let approachMargin = approachMarginFactor / max(1, roadWidthFactor)
        for t in tracks where t.kind == .person && t.missed == 0 {
            seen.insert(t.id)
            let footX = t.box.midX, footY = min(1, t.box.maxY)
            var h = history[t.id] ?? []
            h.append((timestamp, footX))
            h.removeAll { timestamp - $0.t > 1.0 }
            history[t.id] = h

            let roadCenter = zone.centerX(atY: footY) ?? corridor.centerX
            var approaching = false
            if let first = h.first, timestamp - first.t >= 0.3 {
                let v = (footX - first.x) / (timestamp - first.t)           // + = moving right
                let towardsCentre = (footX < roadCenter && v > 0) || (footX > roadCenter && v < 0)
                approaching = towardsCentre && abs(v) >= minApproachSpeed
            }

            // Sidewalk filter (zone relation of the feet).
            let outside = zone.outsideDistance(x: footX, y: footY)
            let hysteresis = relevant[t.id] != nil ? relevanceHysteresis : 0
            let margin = edgeMargin + hysteresis
            // Road staff (officer / worker) stand beside the carriageway: a wider margin keeps them visible. They
            // are reported with `onRoadway == false` below and never become pedestrian hazards.
            let isStaff = t.personRole?.isRoadStaff == true
            let atRoad = outside <= margin || (isStaff && outside <= staffEdgeMargin + hysteresis)
            let nearEdge = outside <= margin + approachMargin
            guard atRoad || (approaching && nearEdge) else {
                result.filteredIDs.insert(t.id)
                continue
            }
            result.relevantIDs.insert(t.id)

            guard t.isConfirmed, isPlausible(t), footY > corridor.horizonY else { continue }
            let laneHalf = corridor.halfWidth(atY: footY)
            guard laneHalf > 0 else { continue }
            // The feet (bottom centre) decide — a box merely overlapping the corridor does not.
            let inLane = abs(footX - corridor.centerX) <= laneHalf
            let onRoad = inLane || outside <= edgeMargin

            let distance = MonocularDistance.distance(realHeight: VehicleKind.person.typicalHeightMeters ?? 1.7,
                                                      normalizedBoxHeight: t.box.height, geometry: geometry)
            if let d = distance, d > maxDistance || d < minDistance { continue }

            if let role = t.personRole, role.isRoadStaff {
                result.staff.append(RoadStaffSighting(trackID: t.id, role: role, box: t.box, distanceMeters: distance,
                                                      onRoadway: onRoad, inOwnLane: inLane))
                continue
            }

            var level: PedestrianHazardLevel?
            if inLane {
                level = .danger
            } else if onRoad {
                level = approaching ? .danger : .caution
            } else if approaching {
                level = .caution
            }
            // When standing still a pedestrian off the own lane is only informative.
            if let lvl = level, lvl == .caution, (ownSpeedKmh ?? 0) < 3, !inLane {
                level = approaching ? .caution : nil
            }
            guard let finalLevel = level else { continue }
            result.hazards.append(PedestrianHazard(trackID: t.id, box: t.box, level: finalLevel, distanceMeters: distance,
                                                   inOwnLane: inLane, onRoadway: onRoad, approaching: approaching))
        }
        for id in history.keys where !seen.contains(id) { history[id] = nil }
        for id in result.filteredIDs { relevant[id] = nil }
        for id in result.relevantIDs { relevant[id] = timestamp }
        relevant = relevant.filter { timestamp - $0.value <= 1.0 }
        result.hazards.sort {
            $0.level != $1.level ? $0.level > $1.level : ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
        }
        result.staff.sort { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
        return result
    }
}
