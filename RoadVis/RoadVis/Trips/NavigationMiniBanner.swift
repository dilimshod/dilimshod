import SwiftUI

/// Minimal next-maneuver banner for the camera screen while guidance runs (voice continues). Designed for the
/// TOP-LEFT corner, directly below the speedometer row: white SF Symbol turn arrow + white distance ("350 м"),
/// an optional small street / instruction line, and a thin white countdown bar for the last 300 m. No heavy plate —
/// only a very light material and a soft shadow; ≈ 48 pt tall. Tap → back to the navigator.
/// While a trip is recorded a tiny red dot with the elapsed time is shown (without navigation: a small chip with
/// a stop button). Self-contained: reads `AppState`, renders nothing when there is nothing to show.
///
/// Embedding (RecognitionView HUD, leading column right under the `SpeedHUD()` / `RoadLine` row):
/// `NavigationMiniBanner()`
struct NavigationMiniBanner: View {
    @Environment(AppState.self) private var app

    /// Countdown bar starts at this distance before the maneuver, metres.
    static let countdownDistance: Double = 300

    var body: some View {
        let nav = app.navigation
        let recorder = app.tripRecorder
        Group {
            if nav.state == .navigating || nav.state == .arrived {
                guidance(nav, recorder: recorder)
            } else if recorder.isRecording || recorder.isFinishing {
                recordingChip(recorder)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .animation(RVTheme.snappy, value: nav.state)
        .animation(RVTheme.snappy, value: recorder.isRecording)
    }

    // MARK: - Guidance

    private func guidance(_ nav: NavigationService, recorder: TripRecorder) -> some View {
        Button {
            app.switchTo(.navigator)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: symbolName(nav))
                        .font(.system(size: 26, weight: .bold))
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        primaryText(nav)
                        if let detail = detailText(nav) {
                            Text(detail)
                                .font(RVTheme.font(11, weight: .medium))
                                .opacity(0.85)
                                .lineLimit(1)
                        }
                    }
                    if recorder.isRecording || recorder.isFinishing {
                        recordingDot(recorder)
                    }
                }
                if let fraction = countdownFraction(nav) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(Color.white)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                    .animation(.linear(duration: 0.4), value: fraction)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: RVTheme.HUD.hit)
            .background(.ultraThinMaterial.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: RVTheme.Radius.control, style: .continuous))
            .shadow(color: RVTheme.textShadow, radius: 3, x: 0, y: 1)
            .fixedSize(horizontal: true, vertical: false)
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
                .font(RVTheme.font(17, weight: .bold))
        } else if nav.isRecalculating || nav.progress?.isOffRoute == true {
            Text(l: "mini.rerouting")
                .font(RVTheme.font(16, weight: .bold))
        } else if let distance = nav.progress?.distanceToNextManeuver {
            Text(RVFormat.appDistance(distance))
                .rvNumeric(20, weight: .heavy)
                .contentTransition(.numericText())
        } else {
            Text(l: "nav.waitingGPS")
                .font(RVTheme.font(15, weight: .bold))
        }
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

    // MARK: - Recording

    private func recordingDot(_ recorder: TripRecorder) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(RVTheme.recording)
                .frame(width: 7, height: 7)
                .rvPulse(recorder.isRecording, minOpacity: 0.35, period: 1.4)
            if let started = recorder.startedAt {
                Text(started, style: .timer)
                    .font(RVTheme.font(10, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.85)
            }
        }
        .padding(.leading, 4)
        .accessibilityLabel(L("trip.recording"))
    }

    private func recordingChip(_ recorder: TripRecorder) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(RVTheme.recording)
                .frame(width: 7, height: 7)
                .rvPulse(recorder.isRecording, minOpacity: 0.35, period: 1.4)
            if recorder.isFinishing {
                Text(l: "trip.saving")
            } else if let started = recorder.startedAt {
                Text(started, style: .timer)
                    .monospacedDigit()
                if recorder.liveEventCount > 0 {
                    Text(l: "mini.eventsShort", recorder.liveEventCount)
                        .foregroundStyle(RVTheme.caution)
                }
            }
            if recorder.isRecording {
                Button {
                    app.stopTripRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("trip.record.stop"))
            }
        }
        .font(RVTheme.font(11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 32)
        .background(.ultraThinMaterial.opacity(0.35), in: Capsule(style: .continuous))
        .shadow(color: RVTheme.textShadow, radius: 3, x: 0, y: 1)
        .fixedSize()
    }

    private func accessibilityText(_ nav: NavigationService) -> String {
        if nav.state == .arrived { return L("voice.arrived") }
        guard let progress = nav.progress else { return L("settings.nav.title") }
        let distance = progress.distanceToNextManeuver.map { RVFormat.appDistance($0) + ", " } ?? ""
        return distance + (progress.nextInstruction ?? L("mini.continue"))
    }
}
