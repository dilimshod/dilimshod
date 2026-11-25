import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Camera + vehicle recognition, as seen by the UI.
///
/// The main-actor object only holds published state. Frames are processed by `RecognitionWorker` on its own serial
/// queue (throttled to ≤ 15 fps, a frame is processed only when the previous one is finished), and every processed
/// frame publishes one snapshot back to the main actor — so observable updates stay ≤ 15 Hz.
///
/// Wording: detector scores are "уверенность" (model confidence), distances/speeds are "≈ оценка".
@Observable
@MainActor
final class RecognitionPipeline {
    let camera: CameraService

    /// Visible tracks (confirmed and tentative) for the overlay.
    private(set) var tracks: [TrackedObject] = []
    /// Currently visible confirmed objects by kind.
    private(set) var visibleCounts: [VehicleKind: Int] = [:]
    /// Unique confirmed objects since the last reset.
    private(set) var uniqueCounts: [VehicleKind: Int] = [:]
    /// Processed frames per second (moving average).
    private(set) var fps: Double = 0
    /// Detector inference time, milliseconds (moving average).
    private(set) var inferenceMs: Double = 0
    private(set) var detectorStatus: ModelStatus = .loading
    private(set) var makeClassifierStatus: ModelStatus = .loading
    /// Colour of the largest visible traffic light (`.unknown` when not determined); nil when none is visible.
    private(set) var currentLightColor: TrafficLightColor?
    /// True while the capture session is running.
    private(set) var isRunning = false
    /// Camera access was denied or restricted (the UI offers a button to the Settings app).
    private(set) var cameraPermissionDenied = false
    /// Pixel size of the processed (upright) camera frames; used to map boxes with aspect-fill geometry.
    private(set) var frameSize = CGSize(width: 1080, height: 1920)
    /// Camera configuration error (e.g. no camera in the simulator).
    private(set) var cameraError: String?
    /// The system interrupted the camera (another app uses it, Split View, phone call…).
    private(set) var isCameraInterrupted = false
    /// Start of the active research recording.
    private(set) var recordingStartedAt: Date?
    /// Files written by the last finished recording.
    private(set) var lastRecordingFiles: [URL] = []
    /// Error of the last recording export.
    private(set) var recordingError: String?
    /// Frames processed since launch (for the status sheet).
    private(set) var processedFrames = 0

    var isRecording: Bool { recordingStartedAt != nil }

    /// Unique confirmed road vehicles (car, truck, bus, motorcycle, bicycle) since the last reset.
    var totalUniqueVehicles: Int {
        uniqueCounts.reduce(0) { $0 + ($1.key.isVehicle ? $1.value : 0) }
    }

    /// Currently visible confirmed road vehicles.
    var totalVisibleVehicles: Int {
        visibleCounts.reduce(0) { $0 + ($1.key.isVehicle ? $1.value : 0) }
    }

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let signals: TrafficSignalService
    @ObservationIgnored private let worker: RecognitionWorker
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var isFinishingRecording = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRecordSetting: Bool

    init(location: LocationService, settings: AppSettings, signals: TrafficSignalService) {
        self.location = location
        self.settings = settings
        self.signals = signals
        let camera = CameraService()
        self.camera = camera
        self.worker = RecognitionWorker(camera: camera)
        self.lastRecordSetting = settings.recordExperimentLog

        worker.outputHandler = { [weak self] output in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(output)
                }
            }
        }
        worker.statusHandler = { [weak self] statuses in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyModelStatuses(statuses)
                }
            }
        }
        camera.stateHandler = { [weak self] running, interrupted in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.applyCameraState(running: running, interrupted: interrupted)
                }
            }
        }
        worker.attach(to: camera)
        pushSettings()
        pushLocation()
        location.addListener { [weak self] _ in
            self?.pushLocation()
        }
        observeSettings()
        // Compile/load the models in the background right away so they are ready when the camera starts.
        worker.loadModels()
    }

    // MARK: - Start / stop

    /// Starts the camera and recognition (asks for camera permission on first use).
    /// Calling it again while running is harmless (the app calls it on every mode switch and foreground).
    func start() {
        // A recording is started automatically (setting "record experiment log") only when the camera was idle,
        // not on repeated start() calls, so a recording the user stopped is not restarted behind their back.
        let wasIdle = !wantsRunning
        wantsRunning = true
        switch CameraService.authorizationStatus {
        case .authorized:
            cameraPermissionDenied = false
            startCamera(autoRecord: wasIdle)
        case .notDetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            Task { [weak self] in
                let granted = await CameraService.requestAccess()
                guard let self else { return }
                self.isRequestingPermission = false
                self.cameraPermissionDenied = !granted
                if granted && self.wantsRunning {
                    self.startCamera(autoRecord: true)
                }
            }
        case .denied, .restricted:
            cameraPermissionDenied = true
        @unknown default:
            cameraPermissionDenied = true
        }
    }

    /// Stops the camera and clears the visible objects (unique counters and an active recording are kept).
    func stop() {
        wantsRunning = false
        worker.setActive(false)
        camera.stop()
        generation += 1
        worker.setGeneration(generation)
        clearVisibleState()
    }

    private func startCamera(autoRecord: Bool) {
        cameraError = nil
        pushSettings()
        pushLocation()
        worker.setActive(true)
        camera.start { [weak self] error in
            let message = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.cameraDidStart(errorMessage: message)
                }
            }
        }
        if autoRecord && settings.recordExperimentLog && !isRecording {
            startRecording()
        }
    }

    private func cameraDidStart(errorMessage: String?) {
        if let errorMessage {
            cameraError = errorMessage
            worker.setActive(false)
        } else if !wantsRunning {
            // stop() was called while the session was starting.
            camera.stop()
        }
    }

    // MARK: - Counters

    /// Resets the unique counters, the tracks and the estimator history.
    func resetCounters() {
        generation += 1
        worker.reset(generation: generation)
        uniqueCounts = [:]
        clearVisibleState()
    }

    // MARK: - Research recording

    /// Starts recording per-frame detections and unique counts (CSV export on stop).
    func startRecording() {
        guard !isRecording else { return }
        let started = Date()
        worker.startRecording(modelName: detectorStatus.modelName ?? "нет модели", startedAt: started)
        recordingStartedAt = started
        recordingError = nil
    }

    /// Stops the recording and writes `…_detections.csv` and `…_summary.csv` to Documents/Experiments/.
    /// Writes synchronously on the main actor — prefer `finishRecording()` for long sessions.
    @discardableResult
    func stopRecording() -> [URL] {
        guard !isFinishingRecording else { return [] }
        defer { recordingStartedAt = nil }
        guard let finished = worker.stopRecording() else { return [] }
        do {
            let urls = try Self.write(log: finished.log, uniqueCounts: finished.uniqueCounts, endedAt: Date())
            lastRecordingFiles = urls
            return urls
        } catch {
            recordingError = error.localizedDescription
            return []
        }
    }

    /// Same as `stopRecording()`, but builds and writes the CSV files off the main actor.
    /// `isRecording` stays true until the files are on disk, so observers of it find the new files.
    func finishRecording() async -> [URL] {
        guard !isFinishingRecording else { return [] }
        guard let finished = worker.stopRecording() else {
            recordingStartedAt = nil
            return []
        }
        isFinishingRecording = true
        defer {
            isFinishingRecording = false
            recordingStartedAt = nil
        }
        let endedAt = Date()
        // The worker no longer references the finished log, so it can be handed to a background queue.
        let handoff = FinishedRecording(log: finished.log, uniqueCounts: finished.uniqueCounts)
        let result: Result<[URL], Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let urls = try Self.write(log: handoff.log, uniqueCounts: handoff.uniqueCounts, endedAt: endedAt)
                    continuation.resume(returning: .success(urls))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        switch result {
        case .success(let urls):
            lastRecordingFiles = urls
            return urls
        case .failure(let error):
            recordingError = error.localizedDescription
            return []
        }
    }

    /// Documents/Experiments/
    nonisolated static var experimentsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Experiments", isDirectory: true)
    }

    private nonisolated static func write(log: ExperimentLog, uniqueCounts: [VehicleKind: Int],
                                          endedAt: Date) throws -> [URL] {
        try log.writeFiles(to: experimentsDirectory, uniqueCounts: uniqueCounts, endedAt: endedAt)
    }

    // MARK: - Updates from the worker / camera

    private func apply(_ output: RecognitionWorker.Output) {
        guard output.generation == generation, wantsRunning else { return }
        // Avoid invalidating the overlay when nothing changed (e.g. an empty road).
        if tracks != output.tracks { tracks = output.tracks }
        if visibleCounts != output.visibleCounts { visibleCounts = output.visibleCounts }
        if uniqueCounts != output.uniqueCounts { uniqueCounts = output.uniqueCounts }
        if abs(fps - output.fps) >= 0.5 { fps = output.fps }
        if abs(inferenceMs - output.inferenceMs) >= 1 { inferenceMs = output.inferenceMs }
        if frameSize != output.frameSize { frameSize = output.frameSize }
        if currentLightColor != output.lightColor {
            currentLightColor = output.lightColor
            signals.cameraLightColor = output.lightColor
        }
        processedFrames = output.processedFrames
    }

    private func applyModelStatuses(_ statuses: RecognitionWorker.ModelStatuses) {
        if detectorStatus != statuses.detector { detectorStatus = statuses.detector }
        if makeClassifierStatus != statuses.makeClassifier { makeClassifierStatus = statuses.makeClassifier }
    }

    private func applyCameraState(running: Bool, interrupted: Bool) {
        if isRunning != running { isRunning = running }
        if isCameraInterrupted != interrupted { isCameraInterrupted = interrupted }
        if !running || interrupted {
            clearVisibleState()
        }
    }

    private func clearVisibleState() {
        if !tracks.isEmpty { tracks = [] }
        if !visibleCounts.isEmpty { visibleCounts = [:] }
        if fps != 0 { fps = 0 }
        if currentLightColor != nil {
            currentLightColor = nil
            signals.cameraLightColor = nil
        }
    }

    // MARK: - Inputs to the worker

    private func pushLocation() {
        let speed = location.speedKmh
        let coordinate = location.location?.coordinate
        worker.update { inputs in
            inputs.ownSpeedKmh = speed
            inputs.latitude = coordinate?.latitude
            inputs.longitude = coordinate?.longitude
        }
    }

    private func pushSettings() {
        let options = VehicleDetector.Options(
            confidenceThreshold: settings.detectionConfidence,
            iouThreshold: settings.nmsIoUThreshold,
            trackPedestrians: settings.trackPedestrians,
            detectTrafficLights: settings.detectTrafficLights)
        let makeEnabled = settings.makeRecognitionEnabled
        worker.update { inputs in
            inputs.detection = options
            inputs.makeRecognitionEnabled = makeEnabled
        }
    }

    /// Re-pushes the recognition settings whenever one of them changes; turning on "record experiment log"
    /// while the camera runs starts a recording.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.detectionConfidence
            _ = settings.nmsIoUThreshold
            _ = settings.trackPedestrians
            _ = settings.detectTrafficLights
            _ = settings.makeRecognitionEnabled
            _ = settings.recordExperimentLog
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pushSettings()
                let record = self.settings.recordExperimentLog
                if record != self.lastRecordSetting {
                    self.lastRecordSetting = record
                    if record && self.wantsRunning && !self.isRecording {
                        self.startRecording()
                    }
                }
                self.observeSettings()
            }
        }
    }
}

/// A finished research log handed to a background queue for writing (exclusive ownership transfer).
private struct FinishedRecording: @unchecked Sendable {
    let log: ExperimentLog
    let uniqueCounts: [VehicleKind: Int]
}
