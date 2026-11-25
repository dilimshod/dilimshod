import SwiftUI

/// Lane guidance strip: one rounded cell per lane (left → right) with its arrows (first two turns of the lane).
/// Recommended lanes are bright (white arrows on blue), the others dim.
struct LaneGuidanceView: View {
    let lanes: [Lane]
    let recommended: [Bool]

    /// - Parameters:
    ///   - lanes: lanes of the travel direction, left → right.
    ///   - recommended: per lane whether it suits the next maneuver (same count as `lanes`; missing entries = false).
    init(lanes: [Lane], recommended: [Bool]) {
        self.lanes = lanes
        self.recommended = recommended
    }

    /// Lanes of the current road (OSM `turn:lanes`) with recommendations derived from the next maneuver.
    init(laneInfo: LaneInfo, maneuver: ManeuverType?) {
        let lanes = laneInfo.lanes
        self.init(lanes: lanes, recommended: LaneGuidance.recommendedLanes(lanes, for: maneuver ?? .straight))
    }

    var body: some View {
        if !lanes.isEmpty {
            HStack(spacing: lanes.count > 6 ? 2 : 4) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    LaneCellView(lane: lane, isRecommended: isRecommended(index), width: cellWidth)
                }
            }
            .padding(5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var cellWidth: CGFloat {
        switch lanes.count {
        case ...4: return 34
        case 5...6: return 30
        default: return 24
        }
    }

    private func isRecommended(_ index: Int) -> Bool {
        recommended.indices.contains(index) && recommended[index]
    }

    private var accessibilityText: String {
        let good = lanes.indices.filter { isRecommended($0) }.map { String($0 + 1) }
        if good.isEmpty { return "Полос: \(lanes.count)" }
        return "Полос: \(lanes.count). Рекомендуемые полосы слева: \(good.joined(separator: ", "))"
    }
}

/// One lane cell of `LaneGuidanceView`.
private struct LaneCellView: View {
    let lane: Lane
    let isRecommended: Bool
    let width: CGFloat

    var body: some View {
        let symbols = arrowSymbols
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isRecommended ? Color.blue : Color.white.opacity(0.08))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isRecommended ? Color.white.opacity(0.9) : Color.white.opacity(0.2), lineWidth: 1)
            HStack(spacing: symbols.count > 1 ? -4 : 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, name in
                    Image(systemName: name)
                        .font(.system(size: symbols.count > 1 ? width * 0.36 : width * 0.5, weight: .bold))
                }
            }
            .foregroundStyle(isRecommended ? Color.white : Color.white.opacity(0.35))
        }
        .frame(width: width, height: 38)
    }

    /// Arrows of the first two turns; a lane without arrows is drawn as "straight".
    private var arrowSymbols: [String] {
        let turns = lane.turns.isEmpty ? [LaneTurn.through] : Array(lane.turns.prefix(2))
        var names: [String] = []
        for turn in turns where !names.contains(turn.symbolName) {
            names.append(turn.symbolName)
        }
        return names
    }
}
