import SwiftUI

/// Compact top banner of turn-by-turn guidance: maneuver arrow, distance countdown (with a thin progress bar for the
/// last 300 m), instruction, lane guidance (engine lanes, else OSM `turn:lanes`) and "затем …" with its arrow.
/// Shows a rerouting / off-route state instead of the instruction when appropriate.
struct ManeuverBannerView: View {
    let progress: RouteProgress
    /// True while a new route is being computed.
    var isRerouting: Bool = false
    /// Lanes at the next maneuver (left → right) and the recommended ones; empty → no lane row.
    var lanes: [Lane] = []
    var recommendedLanes: [Bool] = []
    /// Source of the lanes ("Valhalla", "OSRM", "OSM").
    var laneSource: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                symbol
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    if isRerouting {
                        Text("Перестраиваю маршрут…")
                            .font(.headline)
                        Text("Новый маршрут от текущего положения")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    } else if progress.isOffRoute {
                        Text("Вы съехали с маршрута")
                            .font(.headline)
                        Text("Маршрут будет перестроен")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let distance = progress.distanceToNextManeuver {
                                Text(RVFormat.appDistance(distance))
                                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .layoutPriority(1)
                            }
                            Text(instructionText)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        if let following = progress.followingInstruction, !following.isEmpty {
                            HStack(spacing: 4) {
                                Text("затем")
                                Image(systemName: ManeuverClassifier.classify(following).symbolName)
                                    .font(.caption2.weight(.bold))
                                Text(following)
                                    .lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                        }
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            if showsLanes {
                HStack(spacing: 6) {
                    LaneGuidanceView(lanes: lanes, recommended: recommendedLanes)
                    if let laneSource {
                        SourceTag(text: laneSource)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let fraction = approachFraction {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: 3)
                .background(Color.white.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background.opacity(0.92), in: RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
        .shadow(color: RVTheme.shadow, radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .animation(.easeInOut(duration: 0.25), value: progress.nextStepIndex)
    }

    private var showsLanes: Bool {
        !isRerouting && !progress.isOffRoute && !lanes.isEmpty && (progress.distanceToNextManeuver ?? .infinity) <= 1_500
    }

    /// 0…1 while approaching the maneuver within the last 300 m.
    private var approachFraction: CGFloat? {
        guard !isRerouting, !progress.isOffRoute, let d = progress.distanceToNextManeuver, d <= 300 else { return nil }
        return CGFloat(1 - d / 300)
    }

    @ViewBuilder
    private var symbol: some View {
        if isRerouting {
            ProgressView()
                .tint(.white)
        } else {
            Image(systemName: progress.isOffRoute ? "arrow.triangle.branch" : progress.nextManeuver.symbolName)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var instructionText: String {
        let text = progress.nextInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Продолжайте движение по маршруту" : text
    }

    private var background: Color {
        if isRerouting || progress.isOffRoute {
            return Color(red: 0.62, green: 0.33, blue: 0.02)
        }
        return Color(red: 0.04, green: 0.36, blue: 0.24)
    }

    private var accessibilityText: String {
        if isRerouting { return "Перестраиваю маршрут" }
        if progress.isOffRoute { return "Вы съехали с маршрута" }
        var parts: [String] = []
        if let distance = progress.distanceToNextManeuver { parts.append(RVFormat.appSpokenDistance(distance)) }
        parts.append(instructionText)
        if let following = progress.followingInstruction, !following.isEmpty { parts.append("затем \(following)") }
        return parts.joined(separator: ", ")
    }
}
