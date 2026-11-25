import SwiftUI
import UIKit

/// Full-screen camera with live vehicle recognition.
///
/// Layout (safe-area aware HUD over an edge-to-edge camera picture):
/// - top-left: speedometer + speed-limit sign, road chip (name, lanes, source "OSM");
///   in landscape also the compact following-distance card;
/// - top-right: settings, status line (к/с · мс · model) → status sheet, traffic-light indicator;
/// - top-centre: unique counters by kind with "Всего ТС" and reset (below the top row in portrait);
/// - bottom-centre (portrait): following-distance card above the bottom row;
/// - bottom-left: AI assistant, bottom-centre: research recording, bottom-right corner: navigator button.
///
/// Camera layers (full screen, same aspect-fill mapping): own-lane corridor, corner-bracket boxes with the lead vehicle
/// highlighted, the animated distance line to the lead, tap targets (tap a box → detail card), and a red edge glow
/// during a forward-collision warning. The tap targets sit below the HUD, so every button keeps working.
///
/// The camera itself is started/stopped by `AppState.updateCameraForMode()`, not by this view.
struct RecognitionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showStatus = false
    @State private var showNorms = false
    @State private var selectedTrackID: Int?
    @AppStorage(FollowingDistanceHUD.expandedKey) private var distanceHUDExpanded = false
    @State private var lastSpeedWarning: Date?
    @State private var export: RecordingExport?
    @State private var isSavingRecording = false
    @State private var hideModelBanner = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        let pipeline = app.recognition
        ZStack {
            Color.black.ignoresSafeArea()

            if pipeline.cameraPermissionDenied {
                CameraPermissionCard()
            } else {
                CameraPreviewView(session: pipeline.camera.session)
                    .ignoresSafeArea()
                LiveDetectionLayer(pipeline: pipeline, settings: app.settings,
                                   selectedTrackID: $selectedTrackID, labelInsets: leadLabelInsets)
                    .ignoresSafeArea()
            }

            hud(pipeline: pipeline)

            if !pipeline.cameraPermissionDenied {
                TrackDetailLayer(pipeline: pipeline, selectedTrackID: $selectedTrackID)
                    .ignoresSafeArea()
            }
            CollisionWarningGlow(pipeline: pipeline, settings: app.settings)
                .ignoresSafeArea()
        }
        .onChange(of: app.location.speedKmh) { _, speed in
            checkSpeedWarning(speed)
        }
        .sheet(isPresented: $showStatus) {
            RecognitionStatusView(pipeline: pipeline)
        }
        .sheet(item: $export) { item in
            RecordingExportSheet(export: item)
        }
        .sheet(isPresented: $showNorms) {
            DistanceNormsSheet()
        }
    }

    /// Area kept free for the floating distance label (full-screen coordinates, approximate HUD extents).
    private var leadLabelInsets: EdgeInsets {
        if isLandscape {
            return EdgeInsets(top: 60, leading: 290, bottom: 120, trailing: 170)
        }
        return EdgeInsets(top: 300, leading: 16, bottom: distanceHUDExpanded ? 400 : 300, trailing: 16)
    }

    private var showsDistanceHUD: Bool {
        app.settings.followingDistanceEnabled && !app.recognition.cameraPermissionDenied
    }

    // MARK: - HUD

    private func hud(pipeline: RecognitionPipeline) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    SpeedHUD()
                    RoadChip(road: app.roadInfo.currentRoad)
                    if isLandscape && showsDistanceHUD {
                        FollowingDistanceSlot(pipeline: pipeline, settings: app.settings, style: .mini) {
                            showNorms = true
                        }
                    }
                }
                Spacer(minLength: 8)
                if isLandscape {
                    CountersPanel(pipeline: pipeline, showPedestrians: app.settings.trackPedestrians)
                    Spacer(minLength: 8)
                }
                VStack(alignment: .trailing, spacing: 8) {
                    GlassIconButton(systemName: "gearshape.fill", label: "Настройки") {
                        app.showSettings = true
                    }
                    StatusLineButton(pipeline: pipeline) {
                        showStatus = true
                    }
                    TrafficLightSlot(pipeline: pipeline)
                }
                // The road chip truncates first; buttons and the status line keep their size.
                .layoutPriority(1)
            }

            if !isLandscape {
                CountersPanel(pipeline: pipeline, showPedestrians: app.settings.trackPedestrians)
                    .frame(maxWidth: .infinity)
            }

            BannerStack(pipeline: pipeline, hideModelBanner: $hideModelBanner)
                .frame(maxWidth: 560)

            Spacer(minLength: 0)

            if !isLandscape && showsDistanceHUD {
                FollowingDistanceSlot(pipeline: pipeline, settings: app.settings, style: .full) {
                    showNorms = true
                }
                .frame(maxWidth: 420)
            }

            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom) {
                    AssistantButton()
                    Spacer()
                    NavigatorCornerButton {
                        app.switchTo(.navigator)
                    }
                }
                RecordButton(isRecording: pipeline.isRecording,
                             startedAt: pipeline.recordingStartedAt,
                             isSaving: isSavingRecording,
                             isEnabled: pipeline.isRecording || pipeline.detectorStatus.isReady) {
                    toggleRecording(pipeline)
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func toggleRecording(_ pipeline: RecognitionPipeline) {
        if pipeline.isRecording {
            isSavingRecording = true
            Task {
                let urls = await pipeline.finishRecording()
                isSavingRecording = false
                let error = urls.isEmpty ? (pipeline.recordingError ?? "Нет данных для сохранения") : nil
                export = RecordingExport(urls: urls, error: error)
            }
        } else {
            pipeline.startRecording()
        }
    }

    /// Speaks "Превышение скорости" at most once per 30 s while the limit (+ tolerance) is exceeded.
    private func checkSpeedWarning(_ speed: Double?) {
        let settings = app.settings
        guard settings.speedWarningEnabled,
              SpeedometerView.isOverLimit(speedKmh: speed,
                                          limitKmh: app.roadInfo.currentRoad?.speedLimit?.kmh,
                                          tolerance: settings.speedWarningTolerance) else { return }
        let now = Date()
        if let lastSpeedWarning, now.timeIntervalSince(lastSpeedWarning) < 30 { return }
        lastSpeedWarning = now
        app.speech.speak("Превышение скорости", priority: .low)
    }
}

// MARK: - Camera layers

/// Everything drawn over the camera picture that follows the processed frames (a separate view so only it
/// re-renders with every frame): lane corridor, boxes, distance line and the tap targets.
private struct LiveDetectionLayer: View {
    let pipeline: RecognitionPipeline
    let settings: AppSettings
    @Binding var selectedTrackID: Int?
    let labelInsets: EdgeInsets

    var body: some View {
        let following = settings.followingDistanceEnabled
        let lead = following ? pipeline.leadVehicle : nil
        let assessment = following ? pipeline.followingAssessment : nil
        let status: DistanceStatus = lead == nil ? .unknown : (assessment?.status ?? .unknown)
        ZStack {
            if following && settings.showEgoCorridor {
                EgoCorridorOverlay(corridor: pipeline.egoCorridor, imageSize: pipeline.frameSize,
                                   tint: status == .unknown ? .white : RVTheme.statusColor(status))
            }
            DetectionOverlayView(tracks: pipeline.tracks, imageSize: pipeline.frameSize,
                                 showDistance: settings.showDistanceEstimates, showSpeed: settings.showSpeedEstimates,
                                 lead: lead, leadStatus: status, selectedTrackID: selectedTrackID)
            if let lead {
                LeadDistanceOverlay(lead: lead, assessment: assessment, imageSize: pipeline.frameSize,
                                    labelInsets: labelInsets)
                    .transition(.opacity)
            }
            TrackHitLayer(tracks: pipeline.tracks, imageSize: pipeline.frameSize, selectedTrackID: $selectedTrackID)
        }
        .animation(.easeInOut(duration: 0.25), value: lead == nil)
    }
}

/// Detail card of the tapped box, next to it (above the HUD so it is never hidden). It stays while the track
/// flickers for a moment, closes 1.5 s after the object left the frame, or after 12 s.
private struct TrackDetailLayer: View {
    let pipeline: RecognitionPipeline
    @Binding var selectedTrackID: Int?
    @State private var cached: TrackedObject?

    var body: some View {
        let current = selectedTrackID.flatMap { id in pipeline.tracks.first { $0.id == id } }
        let shown = current ?? (cached?.id == selectedTrackID ? cached : nil)
        GeometryReader { proxy in
            if let track = shown {
                let mapping = AspectFillMapping(imageSize: pipeline.frameSize, viewSize: proxy.size)
                let position = TrackDetailCard.position(for: mapping.rect(for: track.box), in: proxy.size,
                                                        safeArea: proxy.safeAreaInsets)
                let lead = pipeline.leadVehicle?.trackID == track.id ? pipeline.leadVehicle : nil
                TrackDetailCard(track: track, lead: lead, assessment: lead == nil ? nil : pipeline.followingAssessment) {
                    selectedTrackID = nil
                }
                .position(position)
                .animation(.smooth(duration: 0.25), value: position)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(RVTheme.snappy, value: shown?.id)
        .onChange(of: current) { _, newValue in
            if let newValue { cached = newValue }
        }
        .task(id: selectedTrackID) {
            guard let id = selectedTrackID else { return }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            if selectedTrackID == id { selectedTrackID = nil }
        }
        .task(id: current == nil && selectedTrackID != nil) {
            guard let id = selectedTrackID, current == nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            if selectedTrackID == id, !pipeline.tracks.contains(where: { $0.id == id }) {
                selectedTrackID = nil
            }
        }
    }
}

/// Pulsing red glow around the screen edges during a forward-collision warning (when warnings are enabled).
private struct CollisionWarningGlow: View {
    let pipeline: RecognitionPipeline
    let settings: AppSettings

    var body: some View {
        let active = pipeline.isForwardCollisionWarning && settings.distanceWarningsEnabled
        ZStack {
            if active {
                Rectangle()
                    .strokeBorder(RVTheme.danger, lineWidth: 28)
                    .blur(radius: 24)
                    .rvPulse(true, minOpacity: 0.3, period: 0.55)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Following-distance card bound to the pipeline (separate view: it re-renders with every processed frame).
private struct FollowingDistanceSlot: View {
    let pipeline: RecognitionPipeline
    let settings: AppSettings
    let style: FollowingDistanceHUD.Style
    let onShowNorms: () -> Void

    var body: some View {
        if let assessment = pipeline.followingAssessment {
            FollowingDistanceHUD(assessment: assessment, lead: pipeline.leadVehicle,
                                 policy: pipeline.followingDistancePolicy,
                                 surfaceSource: pipeline.roadSurfaceSource,
                                 isForwardCollisionWarning: pipeline.isForwardCollisionWarning
                                    && settings.distanceWarningsEnabled,
                                 style: style, onShowNorms: onShowNorms)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Shown instead of the camera picture when access was denied.
private struct CameraPermissionCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Нет доступа к камере")
                .font(RVTheme.font(22, weight: .bold))
            Text("Разрешите доступ к камере в Настройках, чтобы распознавать транспорт. Спидометр, навигатор и ассистент работают и без камеры.")
                .font(RVTheme.font(16, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Открыть настройки", systemImage: "gearshape.fill")
                    .font(RVTheme.font(17, weight: .bold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(RVTheme.accent)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 420)
        .rvGlass(cornerRadius: 24)
        .padding(32)
    }
}

// MARK: - Top-left

/// Speedometer bound to GPS speed and the OSM speed limit.
private struct SpeedHUD: View {
    @Environment(AppState.self) private var app

    var body: some View {
        SpeedometerView(speedKmh: app.location.speedKmh,
                        limitKmh: app.roadInfo.currentRoad?.speedLimit?.kmh,
                        warningTolerance: app.settings.speedWarningTolerance,
                        warningEnabled: app.settings.speedWarningEnabled)
    }
}

/// Current road from OpenStreetMap: name and lane count.
private struct RoadChip: View {
    let road: RoadSegmentInfo?

    var body: some View {
        if let road {
            VStack(alignment: .leading, spacing: 3) {
                Text(road.displayName)
                    .font(RVTheme.font(15, weight: .bold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                HStack(spacing: 6) {
                    Image(systemName: "road.lanes")
                    Text(Self.lanesText(road.laneInfo))
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text("OSM")
                        .font(RVTheme.font(10, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                .font(RVTheme.font(13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 210, alignment: .leading)
            .rvGlass(cornerRadius: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(road))
        }
    }

    /// "Полос: 3 из 6" (our direction of total), "≈" when the count is inferred from the road class.
    static func lanesText(_ info: LaneInfo) -> String {
        let approx = info.isEstimated ? "≈ " : ""
        if let inDirection = info.lanesInDirection {
            if let total = info.totalLanes, !info.isOneway, total != inDirection {
                return "Полос: \(approx)\(inDirection) из \(total)"
            }
            return "Полос: \(approx)\(inDirection)"
        }
        if let total = info.totalLanes {
            return "Полос: \(approx)\(total)"
        }
        return "Полос: нет данных"
    }

    static func accessibilityText(_ road: RoadSegmentInfo) -> String {
        var text = "Дорога: \(road.displayName). \(lanesText(road.laneInfo).replacingOccurrences(of: "≈ ", with: ""))"
        if road.laneInfo.isEstimated {
            text += " (оценка)"
        }
        return text + ". Данные OpenStreetMap."
    }
}

// MARK: - Top-right

/// "15 к/с · 32 мс · yolo11n" — opens the status sheet.
private struct StatusLineButton: View {
    let pipeline: RecognitionPipeline
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor.opacity(0.8), radius: 3)
                    .rvPulse(pipeline.detectorStatus == .loading, minOpacity: 0.3, period: 1.2)
                // Full "к/с · мс · model" when it fits, otherwise without the model name.
                ViewThatFits(in: .horizontal) {
                    Text(text)
                    Text(shortText)
                }
                .font(RVTheme.font(12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .rvGlassCapsule(shadow: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel("Состояние распознавания: \(text)")
        .accessibilityHint("Открыть подробности")
    }

    private var text: String {
        switch pipeline.detectorStatus {
        case .ready(let name):
            guard pipeline.isRunning else { return "Камера выкл. · \(name)" }
            return "\(Int(pipeline.fps.rounded())) к/с · \(Int(pipeline.inferenceMs.rounded())) мс · \(name)"
        case .loading:
            return "Загрузка модели…"
        case .missing:
            return "Нет модели"
        case .failed:
            return "Ошибка модели"
        }
    }

    private var shortText: String {
        guard case .ready = pipeline.detectorStatus, pipeline.isRunning else { return text }
        return "\(Int(pipeline.fps.rounded())) к/с · \(Int(pipeline.inferenceMs.rounded())) мс"
    }

    private var dotColor: Color {
        switch pipeline.detectorStatus {
        case .ready: return pipeline.isRunning && !pipeline.isCameraInterrupted ? RVTheme.safe : RVTheme.caution
        case .loading: return RVTheme.caution
        case .missing, .failed: return RVTheme.danger
        }
    }
}

/// Traffic-light colour estimated from the camera (shown only while a light is tracked).
private struct TrafficLightSlot: View {
    let pipeline: RecognitionPipeline

    var body: some View {
        if let color = pipeline.currentLightColor {
            TrafficLightIndicatorView(color: color, lampSize: 18)
                .padding(8)
                .rvGlass(cornerRadius: RVTheme.Radius.control)
                .transition(.scale.combined(with: .opacity))
                .animation(RVTheme.snappy, value: color)
        }
    }
}

// MARK: - Counters

/// Unique vehicles counted since the last reset (each tracked object once, when its track is confirmed).
private struct CountersPanel: View {
    let pipeline: RecognitionPipeline
    let showPedestrians: Bool
    @State private var resetCount = 0

    private static let vehicleKinds: [VehicleKind] = [.car, .bus, .truck, .motorcycle, .bicycle]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Self.vehicleKinds, id: \.self) { kind in
                    CounterChip(kind: kind, count: pipeline.uniqueCounts[kind] ?? 0)
                }
            }
            HStack(spacing: 10) {
                Text("Всего ТС: \(pipeline.totalUniqueVehicles)")
                    .rvNumeric(15, weight: .bold)
                    .contentTransition(.numericText())
                    .animation(RVTheme.snappy, value: pipeline.totalUniqueVehicles)
                if showPedestrians {
                    HStack(spacing: 3) {
                        Image(systemName: VehicleKind.person.symbolName)
                            .foregroundStyle(RVTheme.kindColor(.person))
                        Text("\(pipeline.uniqueCounts[.person] ?? 0)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(RVTheme.font(14, weight: .semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Пешеходы: \(pipeline.uniqueCounts[.person] ?? 0)")
                }
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .bold))
                        .symbolEffect(.bounce, value: resetCount)
                        .frame(width: 52, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RVPressableButtonStyle())
                .accessibilityLabel("Сбросить счётчики")
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .rvGlass(cornerRadius: RVTheme.Radius.panel)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.8).onEnded { _ in reset() }
        )
        .sensoryFeedback(.success, trigger: resetCount)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Уникальные транспортные средства")
    }

    private func reset() {
        pipeline.resetCounters()
        resetCount += 1
    }
}

/// Icon + count for one vehicle class.
private struct CounterChip: View {
    let kind: VehicleKind
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(RVTheme.kindColor(kind))
                .symbolEffect(.bounce, value: count)
            Text("\(count)")
                .rvNumeric(16, weight: .heavy)
                .contentTransition(.numericText())
                .animation(RVTheme.snappy, value: count)
                .foregroundStyle(count > 0 ? Color.white : Color.white.opacity(0.5))
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 52, minHeight: 32)
        .background(Color.black.opacity(0.25), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.displayName): \(count)")
    }
}

// MARK: - Banners

/// Model / camera problems. The navigator, speedometer and assistant keep working in every case.
private struct BannerStack: View {
    let pipeline: RecognitionPipeline
    @Binding var hideModelBanner: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !hideModelBanner {
                switch pipeline.detectorStatus {
                case .missing:
                    InfoBanner(systemImage: "exclamationmark.triangle.fill", tint: .orange,
                               title: "Модель YOLO не найдена. Экспортируйте yolo11n в CoreML (см. README → «Модель распознавания») и добавьте в проект",
                               message: "Спидометр, навигатор и ассистент работают без неё.") {
                        hideModelBanner = true
                    }
                case .failed(let message):
                    InfoBanner(systemImage: "exclamationmark.triangle.fill", tint: .red,
                               title: "Не удалось загрузить модель распознавания",
                               message: message) {
                        hideModelBanner = true
                    }
                case .loading, .ready:
                    EmptyView()
                }
            }
            if let error = pipeline.cameraError {
                InfoBanner(systemImage: "video.slash.fill", tint: .red,
                           title: "Камера недоступна", message: error, onClose: nil)
            } else if pipeline.isCameraInterrupted {
                InfoBanner(systemImage: "pause.circle.fill", tint: .yellow,
                           title: "Камера приостановлена системой",
                           message: "Камера используется другим приложением или недоступна в этом режиме.",
                           onClose: nil)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hideModelBanner)
    }
}

/// Glass banner with an icon, a title, an optional message and an optional close button.
private struct InfoBanner: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String?
    let onClose: (() -> Void)?

    init(systemImage: String, tint: Color, title: String, message: String?, onClose: (() -> Void)?) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.message = message
        self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RVTheme.font(15, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(RVTheme.font(13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RVPressableButtonStyle())
                .accessibilityLabel("Скрыть")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, onClose == nil ? 12 : 2)
        .padding(.vertical, 10)
        .rvGlass(cornerRadius: 16, tint: tint.opacity(0.7))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Bottom

/// Starts/stops the research recording; shows the elapsed time while recording.
private struct RecordButton: View {
    let isRecording: Bool
    let startedAt: Date?
    let isSaving: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(isRecording ? RVTheme.recording : Color.white, lineWidth: 3)
                        .frame(width: 30, height: 30)
                        .rvPulse(isRecording, minOpacity: 0.35, period: 1.4)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(RVTheme.recording)
                            .frame(width: 13, height: 13)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle()
                            .fill(RVTheme.recording)
                            .frame(width: 20, height: 20)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(RVTheme.snappy, value: isRecording)
                if isSaving {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Сохранение")
                } else if isRecording, let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.elapsedText(from: startedAt, to: context.date))
                    }
                } else {
                    Text("Запись")
                }
            }
            .rvNumeric(17, weight: .bold)
            .contentTransition(.numericText())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .rvGlassCapsule(tint: isRecording ? RVTheme.recording : nil)
            .overlay {
                if isRecording {
                    Capsule().strokeBorder(RVTheme.recording, lineWidth: 2)
                }
            }
        }
        .buttonStyle(RVPressableButtonStyle())
        .disabled(!isEnabled || isSaving)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(isRecording ? "Остановить запись эксперимента" : "Начать запись эксперимента")
        .accessibilityHint("Сохраняет покадровые детекции и уникальные ТС в CSV")
    }

    /// "04:17" or "1:02:03".
    static func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Large round button in the bottom-right corner that switches to the navigator.
private struct NavigatorCornerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "map.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(RVTheme.accent.gradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
                Text("Навигатор")
                    .font(RVTheme.font(13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel("Навигатор")
        .accessibilityHint("Переключить на карту")
    }
}

// MARK: - Recording export

/// Files of a finished recording (or the reason why nothing was written).
private struct RecordingExport: Identifiable {
    let id = UUID()
    let urls: [URL]
    let error: String?
}

/// Sheet with the CSV files of a recording and a share button.
private struct RecordingExportSheet: View {
    let export: RecordingExport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = export.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if !export.urls.isEmpty {
                    Section("Файлы (Документы → Experiments)") {
                        ForEach(export.urls, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "doc.text")
                                .font(.system(size: 14, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    Section {
                        ShareLink(items: export.urls) {
                            Label("Поделиться файлами", systemImage: "square.and.arrow.up")
                                .font(RVTheme.font(17, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                Section("Что внутри") {
                    Text("detections.csv — каждая детекция на каждом обработанном кадре (track_id связывает кадры одного объекта).")
                    Text("summary.csv — по классам: покадровые детекции и уникальные ТС за время записи.")
                    Text("Проценты — уверенность модели, а не точность. Расстояния и скорости — оценка по одной камере (≈).")
                        .foregroundStyle(.secondary)
                }
                .font(RVTheme.font(14, weight: .regular))
            }
            .navigationTitle(export.urls.isEmpty ? "Запись не сохранена" : "Запись сохранена")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
