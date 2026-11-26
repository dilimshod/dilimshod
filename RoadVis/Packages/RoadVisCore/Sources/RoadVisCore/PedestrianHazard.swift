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

    /// Plausibility filter against false positives (a hand, the dashboard, a passenger, a sign or a poster
    /// recognised as "person"): the box must look like a standing person seen in the scene.
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

    /// True when the track looks like a real pedestrian in the road scene.
    public func isPlausible(_ t: TrackedObject) -> Bool {
        let b = t.box
        guard t.confidence >= minConfidence, t.hits >= minHits else { return false }
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

            guard isPlausible(t), footY > corridor.horizonY else { continue }
            let laneHalf = corridor.halfWidth(atY: footY)
            guard laneHalf > 0 else { continue }
            let dx = abs(footX - corridor.centerX)
            let roadHalf = laneHalf * roadWidthFactor
            // The feet (bottom centre) decide — a box merely overlapping the corridor does not.
            let inLane = dx <= laneHalf
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
            if let d = distance, d > maxDistance || d < minDistance { continue }

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
