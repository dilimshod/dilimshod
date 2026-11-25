import SwiftUI
import UIKit

/// Full-screen camera with live vehicle recognition.
///
/// Layout (safe-area aware HUD over an edge-to-edge camera picture):
/// - top-left: speedometer + speed-limit sign, road chip (name, lanes, source "OSM");
/// - top-right: settings, status line (к/с · мс · model) → status sheet, traffic-light indicator;
/// - top-centre: unique counters by kind with "Всего ТС" and reset (below the top row in portrait);
/// - bottom-left: AI assistant, bottom-centre: research recording, bottom-right corner: navigator button.
///
/// The camera itself is started/stopped by `AppState.updateCameraForMode()`, not by this view.
struct RecognitionView: View {
    @Environment(AppState.self) private var app
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showStatus = false
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
                LiveDetectionLayer(pipeline: pipeline, settings: app.settings)
                    .ignoresSafeArea()
            }

            hud(pipeline: pipeline)
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
    }

    // MARK: - HUD

    private func hud(pipeline: RecognitionPipeline) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    SpeedHUD()
                    RoadChip(road: app.roadInfo.currentRoad)
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
            }

            if !isLandscape {
                CountersPanel(pipeline: pipeline, showPedestrians: app.settings.trackPedestrians)
                    .frame(maxWidth: .infinity)
            }

            BannerStack(pipeline: pipeline, hideModelBanner: $hideModelBanner)
                .frame(maxWidth: 560)

            Spacer(minLength: 0)

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

/// Boxes for the current tracks (a separate view so only it re-renders with every processed frame).
private struct LiveDetectionLayer: View {
    let pipeline: RecognitionPipeline
    let settings: AppSettings

    var body: some View {
        DetectionOverlayView(tracks: pipeline.tracks, imageSize: pipeline.frameSize,
                             showDistance: settings.showDistanceEstimates, showSpeed: settings.showSpeedEstimates)
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
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Разрешите доступ к камере в Настройках, чтобы распознавать транспорт. Спидометр, навигатор и ассистент работают и без камеры.")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Открыть настройки", systemImage: "gearshape.fill")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "road.lanes")
                    Text(Self.lanesText(road.laneInfo))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("OSM")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 240, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(.ultraThinMaterial, in: Capsule())
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

    private var dotColor: Color {
        switch pipeline.detectorStatus {
        case .ready: return pipeline.isRunning && !pipeline.isCameraInterrupted ? .green : .yellow
        case .loading: return .yellow
        case .missing, .failed: return .red
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
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.scale.combined(with: .opacity))
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
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if showPedestrians {
                    HStack(spacing: 3) {
                        Image(systemName: VehicleKind.person.symbolName)
                            .foregroundStyle(DetectionOverlayView.color(for: .person))
                        Text("\(pipeline.uniqueCounts[.person] ?? 0)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Пешеходы: \(pipeline.uniqueCounts[.person] ?? 0)")
                }
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .bold))
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.8, perform: reset)
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
                .foregroundStyle(DetectionOverlayView.color(for: kind))
            Text("\(count)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
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
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.5), lineWidth: 1)
        )
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
                        .strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: 30, height: 30)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.red)
                            .frame(width: 13, height: 13)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 20, height: 20)
                    }
                }
                if isSaving {
                    ProgressView()
                        .tint(.white)
                    Text("Сохранение…")
                } else if isRecording, let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.elapsedText(from: startedAt, to: context.date))
                    }
                } else {
                    Text("Запись")
                }
            }
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(isRecording ? Color.red : Color.white.opacity(0.2), lineWidth: isRecording ? 2 : 1)
            )
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
                    .background(Circle().fill(Color(red: 0.1, green: 0.48, blue: 1.0).gradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 3)
                Text("Навигатор")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
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
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
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
                .font(.system(size: 14, design: .rounded))
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
