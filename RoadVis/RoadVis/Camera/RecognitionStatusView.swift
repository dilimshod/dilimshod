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
                Section(L("recStatus.models")) {
                    detectorRow
                    makeRow
                }

                Section(L("recStatus.performance")) {
                    LabeledContent(L("recStatus.processing"), value: pipeline.isRunning ? L("recStatus.fps", Int(pipeline.fps.rounded())) : "—")
                    LabeledContent(L("recStatus.inference"), value: pipeline.isRunning ? L("recStatus.ms", Int(pipeline.inferenceMs.rounded())) : "—")
                    LabeledContent(L("recStatus.frame"), value: "\(Int(pipeline.frameSize.width)) × \(Int(pipeline.frameSize.height))")
                    LabeledContent(L("recStatus.fov"), value: "\(Int(pipeline.camera.horizontalFieldOfView.rounded()))°")
                    LabeledContent(L("recStatus.frames"), value: "\(pipeline.processedFrames)")
                }
                .monospacedDigit()

                Section(L("common.camera")) {
                    Label(cameraStateText, systemImage: cameraStateSymbol)
                    if pipeline.isRecording, let started = pipeline.recordingStartedAt {
                        Label(L("recStatus.recordingSince", RVFormat.clock(started)), systemImage: "record.circle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(Self.countedKinds, id: \.self) { kind in
                        LabeledContent {
                            Text("\(pipeline.uniqueCounts[kind] ?? 0)")
                                .monospacedDigit()
                        } label: {
                            Label(kind.localizedName, systemImage: kind.symbolName)
                        }
                    }
                    LabeledContent(L("recStatus.totalVehicles"), value: "\(pipeline.totalUniqueVehicles)")
                        .font(.headline)
                    Button(role: .destructive) {
                        pipeline.resetCounters()
                    } label: {
                        Label(L("counters.reset"), systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text(l: "recStatus.uniqueHeader")
                } footer: {
                    Text(l: "recStatus.uniqueFooter", pipeline.totalVisibleVehicles)
                }

                Section(L("recStatus.howToRead")) {
                    Text(l: "recStatus.read.confidence")
                    Text(l: "recStatus.read.distance")
                    Text(l: "recStatus.read.lead")
                    Text(l: "recStatus.read.light")
                    Text(l: "recStatus.read.osm")
                }
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .navigationTitle(L("recStatus.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
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
                Label(L("recStatus.detector"), systemImage: "cpu")
            }
        case .loading:
            LabeledContent {
                ProgressView()
            } label: {
                Label(L("recStatus.detector.loading"), systemImage: "cpu")
            }
        case .missing:
            Label(L("recStatus.detector.missing"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(L("recStatus.detector.failed", message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var makeRow: some View {
        if !app.settings.makeRecognitionEnabled {
            Label(L("recStatus.make.off"), systemImage: "tag")
                .foregroundStyle(.secondary)
        } else {
            switch pipeline.makeClassifierStatus {
            case .ready(let name):
                LabeledContent {
                    Text(name)
                } label: {
                    Label(L("recStatus.make"), systemImage: "tag")
                }
            case .loading:
                LabeledContent {
                    ProgressView()
                } label: {
                    Label(L("recStatus.make.loading"), systemImage: "tag")
                }
            case .missing:
                Label(L("recStatus.make.missing"), systemImage: "tag.slash")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(L("recStatus.make.failed", message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var cameraStateText: String {
        if pipeline.cameraPermissionDenied { return L("camera.noAccess") }
        if let error = pipeline.cameraError { return L("common.errorWith", error) }
        if pipeline.isCameraInterrupted { return L("camera.interrupted") }
        return pipeline.isRunning ? L("camera.running") : L("camera.stopped")
    }

    private var cameraStateSymbol: String {
        if pipeline.cameraPermissionDenied || pipeline.cameraError != nil { return "video.slash.fill" }
        if pipeline.isCameraInterrupted { return "pause.circle.fill" }
        return pipeline.isRunning ? "video.fill" : "video"
    }
}
