import SwiftUI

/// Details of the recognition pipeline: model status, performance, camera state, counters and how to read them.
///
/// This is also the single place where a missing make classifier is mentioned ("Марка: модель не установлена"),
/// instead of repeating it on every box.
struct RecognitionStatusView: View {
    let pipeline: RecognitionPipeline
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private static let countedKinds: [VehicleKind] = [.car, .bus, .truck, .motorcycle, .bicycle, .person, .trafficLight, .stopSign]

    var body: some View {
        NavigationStack {
            List {
                Section("Модели") {
                    detectorRow
                    makeRow
                }

                Section("Производительность") {
                    LabeledContent("Обработка", value: pipeline.isRunning ? "\(Int(pipeline.fps.rounded())) к/с" : "—")
                    LabeledContent("Время модели", value: pipeline.isRunning ? "\(Int(pipeline.inferenceMs.rounded())) мс" : "—")
                    LabeledContent("Кадр", value: "\(Int(pipeline.frameSize.width)) × \(Int(pipeline.frameSize.height))")
                    LabeledContent("Угол обзора камеры", value: "\(Int(pipeline.camera.horizontalFieldOfView.rounded()))°")
                    LabeledContent("Обработано кадров", value: "\(pipeline.processedFrames)")
                }
                .monospacedDigit()

                Section("Камера") {
                    Label(cameraStateText, systemImage: cameraStateSymbol)
                    if pipeline.isRecording, let started = pipeline.recordingStartedAt {
                        Label("Идёт запись эксперимента с \(RVFormat.clock(started))", systemImage: "record.circle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(Self.countedKinds, id: \.self) { kind in
                        LabeledContent {
                            Text("\(pipeline.uniqueCounts[kind] ?? 0)")
                                .monospacedDigit()
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                    LabeledContent("Всего ТС", value: "\(pipeline.totalUniqueVehicles)")
                        .font(.headline)
                    Button(role: .destructive) {
                        pipeline.resetCounters()
                    } label: {
                        Label("Сбросить счётчики", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Уникальные объекты с последнего сброса")
                } footer: {
                    Text("Каждый объект считается один раз — когда его трек подтверждён на нескольких кадрах подряд. Сейчас в кадре: \(pipeline.totalVisibleVehicles) ТС.")
                }

                Section("Как читать данные") {
                    Text("Проценты у рамок — уверенность модели, а не точность распознавания.")
                    Text("Расстояние и скорость других машин — оценка (≈) по размеру рамки на одной камере при типичной высоте ТС; возможна ошибка в десятки процентов.")
                    Text("Цвет светофора определяется по цвету пикселей — это оценка, проверяйте глазами.")
                    Text("Полосы, ограничения скорости и названия дорог — из OpenStreetMap и могут быть неполными.")
                }
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Распознавание")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Rows

    @ViewBuilder
    private var detectorRow: some View {
        switch pipeline.detectorStatus {
        case .ready(let name):
            LabeledContent {
                Text(name)
            } label: {
                Label("Детектор", systemImage: "cpu")
            }
        case .loading:
            LabeledContent {
                ProgressView()
            } label: {
                Label("Детектор: загрузка…", systemImage: "cpu")
            }
        case .missing:
            Label("Детектор: модель YOLO не найдена (см. README → «Модель распознавания»)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label("Детектор: ошибка загрузки — \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var makeRow: some View {
        if !app.settings.makeRecognitionEnabled {
            Label("Марка: выключено в настройках", systemImage: "tag")
                .foregroundStyle(.secondary)
        } else {
            switch pipeline.makeClassifierStatus {
            case .ready(let name):
                LabeledContent {
                    Text(name)
                } label: {
                    Label("Марка", systemImage: "tag")
                }
            case .loading:
                LabeledContent {
                    ProgressView()
                } label: {
                    Label("Марка: загрузка…", systemImage: "tag")
                }
            case .missing:
                Label("Марка: модель не установлена", systemImage: "tag.slash")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label("Марка: ошибка загрузки — \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var cameraStateText: String {
        if pipeline.cameraPermissionDenied { return "Нет доступа к камере" }
        if let error = pipeline.cameraError { return "Ошибка: \(error)" }
        if pipeline.isCameraInterrupted { return "Приостановлена системой" }
        return pipeline.isRunning ? "Работает" : "Остановлена"
    }

    private var cameraStateSymbol: String {
        if pipeline.cameraPermissionDenied || pipeline.cameraError != nil { return "video.slash.fill" }
        if pipeline.isCameraInterrupted { return "pause.circle.fill" }
        return pipeline.isRunning ? "video.fill" : "video"
    }
}
