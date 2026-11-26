import SwiftUI

/// Minimal next-maneuver banner for the camera screen while guidance runs (voice continues). Designed for the
/// TOP-LEFT corner, directly below the speedometer row: white SF Symbol turn arrow + white distance ("350 м"),
/// an optional small street / instruction line, and a thin white countdown bar for the last 300 m. No heavy plate —
/// only a very light material and a soft shadow; ≈ 48 pt tall. Tap → back to the navigator.
/// Trip recording runs silently in the background (controlled in Settings → Поездки), so nothing about it is
/// shown here. Self-contained: reads `AppState`, renders nothing when there is nothing to show.
///
/// Embedding (RecognitionView HUD, leading column right under the `SpeedHUD()` / `RoadLine` row):
/// `NavigationMiniBanner()`
struct NavigationMiniBanner: View {
    @Environment(AppState.self) private var app

    /// Countdown bar starts at this distance before the maneuver, metres.
    static let countdownDistance: Double = 300

    var body: some View {
        let nav = app.navigation
        Group {
            if nav.state == .navigating || nav.state == .arrived {
                guidance(nav)
            }
        }
        .frame(width: 96, alignment: .leading)
        .animation(RVTheme.snappy, value: nav.state)
    }

    // MARK: - Guidance

    private func guidance(_ nav: NavigationService) -> some View {
        Button {
            app.switchTo(.navigator)
        } label: {
            // Vertical, minimal and slightly transparent: arrow on top, distance underneath, thin countdown bar.
            VStack(alignment: .center, spacing: 3) {
                Image(systemName: symbolName(nav))
                    .font(.system(size: 40, weight: .semibold))
                    .frame(width: 52, height: 46)
                primaryText(nav)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let street = streetText(nav) {
                    // Street / road after the maneuver — small and quiet, up to two lines.
                    Text(street)
                        .font(RVTheme.font(11, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .opacity(0.85)
                }
                if let fraction = countdownFraction(nav) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(width: 44, height: 3)
                    .animation(.linear(duration: 0.4), value: fraction)
                }
            }
            .foregroundStyle(.white)
            .opacity(0.85)
            .frame(width: 96)
            .padding(.vertical, 6)
            .shadow(color: .black.opacity(0.55), radius: 4, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel(accessibilityText(nav))
        .accessibilityHint(L("mini.openNavigator"))
    }

    private func symbolName(_ nav: NavigationService) -> String {
        if nav.state == .arrived { return "flag.checkered" }
        if nav.isRecalculating || nav.progress?.isOffRoute == true { return "arrow.triangle.2.circlepath" }
        return nav.progress?.nextManeuver.symbolName ?? "location.north.line.fill"
    }

    @ViewBuilder
    private func primaryText(_ nav: NavigationService) -> some View {
        if nav.state == .arrived {
            Text(l: "voice.arrived")
                .font(RVTheme.font(13, weight: .bold))
        } else if nav.isRecalculating || nav.progress?.isOffRoute == true {
            Text(l: "mini.rerouting")
                .font(RVTheme.font(12, weight: .bold))
        } else if let distance = nav.progress?.distanceToNextManeuver {
            Text(RVFormat.appDistance(distance))
                .rvNumeric(17, weight: .bold)
                .contentTransition(.numericText())
        } else {
            Text(l: "nav.waitingGPS")
                .font(RVTheme.font(11, weight: .bold))
        }
    }

    /// Name of the street / road the next maneuver leads onto (engine street names), else the instruction text;
    /// before any maneuver is known, the current road from OpenStreetMap.
    private func streetText(_ nav: NavigationService) -> String? {
        if nav.state == .arrived { return nav.destinationName }
        guard let progress = nav.progress, !progress.isOffRoute, !nav.isRecalculating else { return nil }
        if let index = progress.nextStepIndex, let steps = nav.selectedRouteOption?.route.steps,
           steps.indices.contains(index) {
            let names = steps[index].streetNames.filter { !$0.isEmpty }
            if let first = names.first { return first }
        }
        if let road = app.roadInfo.currentRoad?.displayName, !road.isEmpty { return road }
        return nil
    }

    /// Small second line: the instruction (usually contains the street name).
    private func detailText(_ nav: NavigationService) -> String? {
        if nav.state == .arrived { return nav.destinationName }
        guard let progress = nav.progress, !progress.isOffRoute, !nav.isRecalculating,
              let instruction = progress.nextInstruction, !instruction.isEmpty else { return nil }
        return instruction
    }

    /// 0…1 over the last 300 m before the maneuver; nil outside that window.
    private func countdownFraction(_ nav: NavigationService) -> Double? {
        guard nav.state == .navigating, let progress = nav.progress, !progress.isOffRoute,
              let distance = progress.distanceToNextManeuver, distance <= Self.countdownDistance else { return nil }
        return min(1, max(0, 1 - distance / Self.countdownDistance))
    }

    private func accessibilityText(_ nav: NavigationService) -> String {
        if nav.state == .arrived { return L("voice.arrived") }
        guard let progress = nav.progress else { return L("settings.nav.title") }
        let distance = progress.distanceToNextManeuver.map { RVFormat.appDistance($0) + ", " } ?? ""
        return distance + (progress.nextInstruction ?? L("mini.continue"))
    }
}
