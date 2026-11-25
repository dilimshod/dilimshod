import SwiftUI

/// Compact next-maneuver banner for the camera screen while guidance runs (voice continues): maneuver arrow,
/// distance, instruction, remaining distance / arrival time; tap → back to the navigator. While a trip is being
/// recorded a small red dot with the elapsed time and the number of events is shown (also without navigation,
/// then with a stop button). Self-contained: reads `AppState`, renders nothing when there is nothing to show.
///
/// Embedding (RecognitionView HUD, under the banners): `NavigationMiniBanner()`
struct NavigationMiniBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let nav = app.navigation
        let recorder = app.tripRecorder
        Group {
            if nav.state == .navigating || nav.state == .arrived {
                guidance(nav, recorder: recorder)
            } else if recorder.isRecording || recorder.isFinishing {
                recordingChip(recorder, showsStop: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 460)
        .animation(RVTheme.snappy, value: nav.state)
        .animation(RVTheme.snappy, value: recorder.isRecording)
    }

    // MARK: - Guidance

    private func guidance(_ nav: NavigationService, recorder: TripRecorder) -> some View {
        Button {
            app.switchTo(.navigator)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbolName(nav))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(nav.state == .arrived ? RVTheme.safe : .white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    primaryLine(nav)
                    secondaryLine(nav, recorder: recorder)
                }
                Spacer(minLength: 0)
                Image(systemName: "map.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: RVTheme.HUD.hit)
            .rvGlass(cornerRadius: RVTheme.Radius.panel, tint: nav.progress?.isOffRoute == true ? RVTheme.caution : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel(accessibilityText(nav))
        .accessibilityHint("Открыть навигатор")
    }

    private func symbolName(_ nav: NavigationService) -> String {
        if nav.state == .arrived { return "flag.checkered" }
        if nav.isRecalculating || nav.progress?.isOffRoute == true { return "arrow.triangle.2.circlepath" }
        return nav.progress?.nextManeuver.symbolName ?? "location.north.line.fill"
    }

    @ViewBuilder
    private func primaryLine(_ nav: NavigationService) -> some View {
        if nav.state == .arrived {
            Text("Вы прибыли")
                .font(RVTheme.font(16, weight: .bold))
        } else if nav.isRecalculating {
            Text("Перестраиваю маршрут…")
                .font(RVTheme.font(15, weight: .bold))
        } else if let progress = nav.progress, progress.isOffRoute {
            Text("Вы съехали с маршрута")
                .font(RVTheme.font(15, weight: .bold))
        } else if let progress = nav.progress {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let distance = progress.distanceToNextManeuver {
                    Text(RVFormat.distance(distance))
                        .rvNumeric(18, weight: .heavy)
                        .contentTransition(.numericText())
                }
                Text(progress.nextInstruction ?? "Продолжайте движение")
                    .font(RVTheme.font(14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            Text("Ожидаю GPS…")
                .font(RVTheme.font(15, weight: .bold))
        }
    }

    @ViewBuilder
    private func secondaryLine(_ nav: NavigationService, recorder: TripRecorder) -> some View {
        HStack(spacing: 6) {
            if nav.state == .navigating, let progress = nav.progress {
                Text("\(RVFormat.distance(progress.remainingDistance)) · прибытие \(RVFormat.clock(Date().addingTimeInterval(progress.remainingTimeSeconds)))")
                    .monospacedDigit()
                    .lineLimit(1)
            } else if let name = nav.destinationName {
                Text(name).lineLimit(1)
            }
            if recorder.isRecording || recorder.isFinishing {
                recordingChip(recorder, showsStop: false)
            }
        }
        .font(RVTheme.font(11, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: - Recording

    @ViewBuilder
    private func recordingChip(_ recorder: TripRecorder, showsStop: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(RVTheme.recording)
                .frame(width: 7, height: 7)
                .rvPulse(recorder.isRecording, minOpacity: 0.35, period: 1.4)
            if recorder.isFinishing {
                Text("Сохраняю поездку…")
            } else if let started = recorder.startedAt {
                Text(started, style: .timer)
                    .monospacedDigit()
                if recorder.liveEventCount > 0 {
                    Text("· \(recorder.liveEventCount) соб.")
                        .foregroundStyle(RVTheme.caution)
                }
            }
            if showsStop && recorder.isRecording {
                Button {
                    app.stopTripRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Остановить запись поездки")
            }
        }
        .font(RVTheme.font(11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.leading, showsStop ? 10 : 0)
        .padding(.trailing, showsStop ? 2 : 0)
        .frame(minHeight: showsStop ? 32 : nil)
        .modifier(RecordingChipBackground(isStandalone: showsStop))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Идёт запись поездки")
    }

    private func accessibilityText(_ nav: NavigationService) -> String {
        if nav.state == .arrived { return "Вы прибыли" }
        guard let progress = nav.progress else { return "Навигация" }
        let distance = progress.distanceToNextManeuver.map { RVFormat.distance($0) + ", " } ?? ""
        return distance + (progress.nextInstruction ?? "Продолжайте движение")
    }
}

/// Glass capsule only for the stand-alone chip (inside the banner the chip sits on the banner's glass).
private struct RecordingChipBackground: ViewModifier {
    let isStandalone: Bool

    func body(content: Content) -> some View {
        if isStandalone {
            content.rvGlassCapsule(tint: RVTheme.recording, shadow: false)
        } else {
            content
        }
    }
}
