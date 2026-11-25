import Foundation

/// One arrow value of an OSM `turn:lanes` entry.
public enum LaneTurn: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case slightLeft = "slight_left"
    case sharpLeft = "sharp_left"
    case through
    case right
    case slightRight = "slight_right"
    case sharpRight = "sharp_right"
    case reverse
    case mergeToLeft = "merge_to_left"
    case mergeToRight = "merge_to_right"
    case none

    /// SF Symbol for a lane arrow.
    public var symbolName: String {
        switch self {
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightLeft: return "arrow.up.left"
        case .through, .none: return "arrow.up"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .slightRight: return "arrow.up.right"
        case .reverse: return "arrow.uturn.down"
        case .mergeToLeft: return "arrow.up.left"
        case .mergeToRight: return "arrow.up.right"
        }
    }
}

/// One lane with its allowed turn directions (from `turn:lanes`). Empty `turns` = unknown / any.
public struct Lane: Hashable, Codable, Sendable {
    public var turns: [LaneTurn]

    public init(turns: [LaneTurn]) {
        self.turns = turns
    }
}

/// Lane configuration of a road for the travel direction of the user.
public struct LaneInfo: Hashable, Codable, Sendable {
    /// Value of the OSM `lanes` tag (both directions together).
    public var totalLanes: Int?
    /// Lanes available in the user's travel direction.
    public var lanesInDirection: Int?
    /// Lanes of the opposite direction.
    public var lanesOpposite: Int?
    /// Per-lane arrows for the user's direction, ordered left → right. May be empty when `turn:lanes` is not mapped.
    public var lanes: [Lane]
    public var isOneway: Bool
    /// True when the lane count is inferred from the road class because no `lanes` tag exists.
    public var isEstimated: Bool

    public init(totalLanes: Int?, lanesInDirection: Int?, lanesOpposite: Int?, lanes: [Lane],
                isOneway: Bool, isEstimated: Bool) {
        self.totalLanes = totalLanes
        self.lanesInDirection = lanesInDirection
        self.lanesOpposite = lanesOpposite
        self.lanes = lanes
        self.isOneway = isOneway
        self.isEstimated = isEstimated
    }

    public static let unknown = LaneInfo(totalLanes: nil, lanesInDirection: nil, lanesOpposite: nil,
                                         lanes: [], isOneway: false, isEstimated: true)
}

/// A speed limit parsed from OSM `maxspeed`.
public struct SpeedLimit: Hashable, Codable, Sendable {
    public var kmh: Int
    /// Raw tag value, e.g. "60", "RU:urban".
    public var raw: String
    /// True for zone codes ("RU:urban") resolved through the national default table.
    public var isImplicit: Bool

    public init(kmh: Int, raw: String, isImplicit: Bool) {
        self.kmh = kmh
        self.raw = raw
        self.isImplicit = isImplicit
    }
}
