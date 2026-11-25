import Foundation

/// Maneuver type derived from a turn-by-turn instruction text.
public enum ManeuverType: String, Codable, Hashable, Sendable, CaseIterable {
    case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight,
         uTurn, roundabout, merge, keepLeft, keepRight, exitLeft, exitRight, arrive, unknown

    /// SF Symbol for the maneuver banner.
    public var symbolName: String {
        switch self {
        case .depart: return "location.north.line.fill"
        case .straight, .unknown: return "arrow.up"
        case .slightLeft, .keepLeft, .exitLeft: return "arrow.up.left"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight, .keepRight, .exitRight: return "arrow.up.right"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .uTurn: return "arrow.uturn.down"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .merge: return "arrow.merge"
        case .arrive: return "flag.checkered"
        }
    }

    /// Lane arrows that are suitable for this maneuver.
    public var compatibleLaneTurns: Set<LaneTurn> {
        switch self {
        case .depart, .straight, .merge, .unknown: return [.through, .none]
        case .left: return [.left, .sharpLeft, .slightLeft]
        case .sharpLeft: return [.sharpLeft, .left]
        case .slightLeft, .keepLeft, .exitLeft: return [.slightLeft, .left]
        case .right: return [.right, .sharpRight, .slightRight]
        case .sharpRight: return [.sharpRight, .right]
        case .slightRight, .keepRight, .exitRight: return [.slightRight, .right]
        case .uTurn: return [.reverse, .left, .sharpLeft]
        case .roundabout, .arrive: return []
        }
    }

    public var isLeftward: Bool {
        [.slightLeft, .left, .sharpLeft, .keepLeft, .exitLeft, .uTurn].contains(self)
    }

    public var isRightward: Bool {
        [.slightRight, .right, .sharpRight, .keepRight, .exitRight].contains(self)
    }
}

public enum ManeuverClassifier {
    /// Classifies a MapKit step instruction (Russian, English or Uzbek Latin) by keywords.
    public static func classify(_ instruction: String) -> ManeuverType {
        let s = instruction.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "ʻ", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .depart }

        func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }

        let left = has("налево", "левее", "влево", "слева", "left", "chapga", "chap ")
        let right = has("направо", "правее", "вправо", "справа", "right", "o'ngga", "ongga", "o'ng ")

        // Arrival
        if has("пункт назначения", "прибыт", "место назначения", "вы на месте", "destination", "arrive",
               "manzil", "yetib keld") {
            return .arrive
        }
        // U-turn
        if has("развернитесь", "разворот", "u-turn", "u turn", "make a u", "orqaga qayril", "burilib qayt", "qayriling") {
            return .uTurn
        }
        // Roundabout
        if has("кругов", "кольц", "roundabout", "traffic circle", "rotary", "aylanma", "halqa") {
            return .roundabout
        }
        // Exits / ramps
        if has("съезд", "exit", "ramp", "chiqish", "сверните на выезд") {
            if left { return .exitLeft }
            return right ? .exitRight : .exitRight
        }
        // Keep left / right at forks
        if has("держитесь", "keep ", "keep left", "keep right", "перестройтесь", "ushlang", "tomonda qoling") {
            if left { return .keepLeft }
            if right { return .keepRight }
        }
        // Merge
        if has("merge", "влейтесь", "вливайтесь", "примкните", "qo'shiling") {
            return .merge
        }
        // Sharp / slight turns
        let sharp = has("резко", "круто", "sharp", "keskin")
        let slight = has("плавно", "немного", "slight", "bear ", "sekin", "biroz")
        if left {
            if sharp { return .sharpLeft }
            if slight { return .slightLeft }
            return .left
        }
        if right {
            if sharp { return .sharpRight }
            if slight { return .slightRight }
            return .right
        }
        // Straight
        if has("прямо", "продолжайте", "двигайтесь", "следуйте", "continue", "straight", "head ", "proceed",
               "to'g'ri", "davom et") {
            return .straight
        }
        // Departure ("Начните движение…", "Выезжайте на …")
        if has("начните", "выезжайте", "start", "depart", "harakatni boshlang") {
            return .depart
        }
        return .unknown
    }
}

public enum LaneGuidance {
    /// For each lane (left → right) whether it suits the maneuver.
    /// Lanes without arrows count as "through". If no lane has a matching arrow, a turn falls back to the
    /// outermost lane on that side; straight maneuvers fall back to all lanes without turn-only arrows.
    public static func recommendedLanes(_ lanes: [Lane], for maneuver: ManeuverType) -> [Bool] {
        guard !lanes.isEmpty else { return [] }
        let wanted = maneuver.compatibleLaneTurns
        guard !wanted.isEmpty else { return lanes.map { _ in false } }

        let effective: [[LaneTurn]] = lanes.map { $0.turns.isEmpty ? [.through] : $0.turns }
        var result = effective.map { turns in turns.contains { wanted.contains($0) } }
        if result.contains(true) { return result }

        result = lanes.map { _ in false }
        if maneuver.isLeftward {
            result[0] = true
        } else if maneuver.isRightward {
            result[lanes.count - 1] = true
        } else {
            let turnOnly: Set<LaneTurn> = [.left, .sharpLeft, .right, .sharpRight, .reverse]
            result = effective.map { turns in !turns.allSatisfy { turnOnly.contains($0) } }
        }
        return result
    }
}
