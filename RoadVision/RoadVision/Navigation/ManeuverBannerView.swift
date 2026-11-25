import SwiftUI

/// Top banner of turn-by-turn guidance: big maneuver arrow, distance to the maneuver, instruction and "Затем: …".
/// Shows a rerouting / off-route state instead of the instruction when appropriate.
struct ManeuverBannerView: View {
    let progress: RouteProgress
    /// True while a new route is being computed.
    var isRerouting: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            symbol
                .frame(width: 68, height: 68)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                if isRerouting {
                    Text("Перестраиваю маршрут…")
                        .font(.title3.weight(.bold))
                    Text("Новый маршрут от текущего положения")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                } else if progress.isOffRoute {
                    Text("Вы съехали с маршрута")
                        .font(.title3.weight(.bold))
                    Text("Маршрут будет перестроен")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    if let distance = progress.distanceToNextManeuver {
                        Text(RVFormat.distance(distance))
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Text(instructionText)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    if let following = progress.followingInstruction, !following.isEmpty {
                        Text("Затем: \(following)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .animation(.easeInOut(duration: 0.25), value: progress.nextStepIndex)
    }

    @ViewBuilder
    private var symbol: some View {
        if isRerouting {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        } else {
            Image(systemName: progress.isOffRoute ? "arrow.triangle.branch" : progress.nextManeuver.symbolName)
                .font(.system(size: 42, weight: .bold))
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
        if let distance = progress.distanceToNextManeuver { parts.append(RVFormat.spokenDistance(distance)) }
        parts.append(instructionText)
        if let following = progress.followingInstruction, !following.isEmpty { parts.append("затем \(following)") }
        return parts.joined(separator: ", ")
    }
}
