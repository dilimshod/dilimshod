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
}

/// Decides whether detected pedestrians are on the roadway / in front of the car.
///
/// Geometry (image space, y down): a person's ground contact point is the bottom-centre of the box. It is
///  - "in the own lane" when inside the `EgoCorridor` trapezoid at that row,
///  - "on the roadway" when inside a wider trapezoid (`roadWidthFactor` × corridor width) — adjacent lanes,
///    the crossing zone right in front of the car,
///  - "approaching" when near the roadway edge and moving towards the corridor centre.
/// This is a camera heuristic (no lane semantics beyond the corridor), so warnings are phrased as advice.
public final class PedestrianHazardDetector {
    public var corridor: EgoCorridor
    /// Width of the roadway zone relative to the own-lane corridor.
    public var roadWidthFactor: Double
    /// Extra margin outside the roadway zone in which an approaching pedestrian is reported.
    public var approachMarginFactor: Double
    /// Minimum lateral speed towards the lane (fraction of image width per second) to count as approaching.
    public var minApproachSpeed: Double
    /// Pedestrians farther than this are ignored, metres.
    public var maxDistance: Double

    private var history: [Int: [(t: TimeInterval, x: Double)]] = [:]

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
    }

    /// Returns hazards sorted by urgency (danger first, then nearest).
    public func update(tracks: [TrackedObject], ownSpeedKmh: Double?, geometry: CameraGeometry,
                       timestamp: TimeInterval) -> [PedestrianHazard] {
        var result: [PedestrianHazard] = []
        var seen = Set<Int>()
        for t in tracks where t.kind == .person && t.isConfirmed && t.missed == 0 {
            seen.insert(t.id)
            let footX = t.box.midX, footY = min(1, t.box.maxY)
            var h = history[t.id] ?? []
            h.append((timestamp, footX))
            h.removeAll { timestamp - $0.t > 1.0 }
            history[t.id] = h

            guard footY > corridor.horizonY else { continue }
            let laneHalf = corridor.halfWidth(atY: footY)
            guard laneHalf > 0 else { continue }
            let dx = abs(footX - corridor.centerX)
            let roadHalf = laneHalf * roadWidthFactor
            let inLane = dx <= laneHalf || (t.box.minX < corridor.centerX + laneHalf && t.box.maxX > corridor.centerX - laneHalf)
            let onRoad = inLane || dx <= roadHalf

            var approaching = false
            if let first = h.first, timestamp - first.t >= 0.3 {
                let v = (footX - first.x) / (timestamp - first.t)           // + = moving right
                let towardsCentre = (footX < corridor.centerX && v > 0) || (footX > corridor.centerX && v < 0)
                approaching = towardsCentre && abs(v) >= minApproachSpeed
            }
            let nearEdge = dx <= roadHalf + laneHalf * approachMarginFactor

            let distance = MonocularDistance.distance(realHeight: VehicleKind.person.typicalHeightMeters ?? 1.7,
                                                      normalizedBoxHeight: t.box.height, geometry: geometry)
            if let d = distance, d > maxDistance { continue }

            var level: PedestrianHazardLevel?
            if inLane {
                level = .danger
            } else if onRoad {
                level = approaching ? .danger : .caution
            } else if nearEdge && approaching {
                level = .caution
            }
            // When standing still a pedestrian off the own lane is only informative.
            if let lvl = level, lvl == .caution, (ownSpeedKmh ?? 0) < 3, !inLane {
                level = approaching ? .caution : nil
            }
            guard let finalLevel = level else { continue }
            result.append(PedestrianHazard(trackID: t.id, box: t.box, level: finalLevel, distanceMeters: distance,
                                           inOwnLane: inLane, onRoadway: onRoad, approaching: approaching))
        }
        for id in history.keys where !seen.contains(id) { history[id] = nil }
        return result.sorted {
            $0.level != $1.level ? $0.level > $1.level : ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity)
        }
    }
}
