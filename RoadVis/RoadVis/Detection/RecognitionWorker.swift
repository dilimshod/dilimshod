import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

/// Frame-processing engine of `RecognitionPipeline`.
///
/// Everything heavy (Vision/Core ML inference, tracking, distance/speed estimation, lead-vehicle selection,
/// make classification, traffic-light colour sampling, research logging) runs on the private serial
/// `recognition.processing` queue — never on the main actor.
///
/// Threading contract
/// - `detector`, `makeClassifier`, `tracker`, `estimator`, `leadTracker` and the frame statistics are confined to `queue`.
/// - Inputs coming from the main actor (GPS, settings), the activity flags and the handlers are lock-protected.
/// - The experiment recording has its own lock so the main actor can stop it without waiting for inference.
/// - Results are delivered through `outputHandler` (called on `queue`, at most `maxFramesPerSecond` times per second).
final class RecognitionWorker: @unchecked Sendable {
    /// Values pushed from the main actor before/while processing.
    struct Inputs: Sendable {
        var ownSpeedKmh: Double?
        var latitude: Double?
        var longitude: Double?
        var detection = VehicleDetector.Options()
        var makeRecognitionEnabled = true
        /// Run the lead-vehicle (following distance) estimation.
        var followingDistanceEnabled = true
        /// Horizon of the own-lane corridor, fraction of the frame height (`settings.corridorHorizon`).
        var corridorHorizon = EgoCorridor.default.horizonY
        /// Run the classical lane-marking detector (~5 Hz, on a downsampled copy of the frame).
        var laneDetectionEnabled = true
        /// Run the pedestrian-on-the-roadway check (`DriverAssistSettings.pedestrianWarningsEnabled`).
        var pedestrianWarningsEnabled = true
    }

    /// Snapshot published after every processed frame.
    struct Output: Sendable {
        /// Generation the frame was processed in (outputs of an older generation are stale and dropped).
        var generation: Int
        /// Visible tracks (confirmed or not) with distance/speed estimates.
        var tracks: [TrackedObject]
        /// Visible confirmed tracks by kind.
        var visibleCounts: [VehicleKind: Int]
        /// Unique confirmed objects since the last reset.
        var uniqueCounts: [VehicleKind: Int]
        var fps: Double
        var inferenceMs: Double
        /// Colour of the largest currently visible confirmed traffic light with ≥ 5 hits and confidence ≥ 0.5
        /// (`.unknown` when not determined); nil when none.
        var lightColor: TrafficLightColor?
        /// Size of the processed (upright) buffer, pixels.
        var frameSize: CGSize
        /// Frames processed since the worker was created.
        var processedFrames: Int
        /// Closest confirmed vehicle in the own-lane corridor with a fused distance estimate (nil when none
        /// or when following distance is switched off).
        var leadVehicle: LeadVehicle?
        /// Latest lane-marking estimate (refreshed ~5 Hz, repeated in between; nil while lane detection is off).
        /// Its `timestamp` is the system uptime of the analysed frame.
        var laneEstimate: LaneEstimate?
        /// Pedestrians on / about to enter the roadway, most urgent first (empty when the feature is off).
        var pedestrianHazards: [PedestrianHazard]
        /// Own-lane corridor the lead was picked from (centre follows a confident lane estimate).
        var corridor: EgoCorridor
    }

    /// Load results of the two models.
    struct ModelStatuses: Sendable, Equatable {
        var detector: ModelStatus
        var makeClassifier: ModelStatus
    }

    /// Unique counts and log of an active recording.
    private final class RecordingState {
        let log: ExperimentLog
        /// Tracker counts when the recording saw its first frame (or after the last reset).
        var baseline: [VehicleKind: Int]?
        /// Counts collected before counter resets during this recording.
        var accumulated: [VehicleKind: Int] = [:]
        /// Unique objects counted during this recording.
        var uniqueInSession: [VehicleKind: Int] = [:]

        init(log: ExperimentLog) {
            self.log = log
        }
    }

    /// Upper bound of the processing rate (the camera delivers 30 fps).
    static let maxFramesPerSecond: Double = 15
    /// A traffic light drives the colour indicator only with this many hits and this detector confidence.
    static let lightMinHits = 5
    static let lightMinConfidence = 0.5
    /// Lane detection interval, seconds (≈ 5 Hz).
    static let laneInterval: TimeInterval = 0.2
    /// Width of the downsampled image analysed by the lane detector, pixels.
    static let laneImageWidth = 160

    let queue = DispatchQueue(label: "recognition.processing", qos: .userInitiated)
    private let camera: CameraService

    // MARK: Queue-confined
    private let detector = VehicleDetector()
    private let makeClassifier = MakeClassifier()
    private let tracker = ObjectTracker()
    private let estimator = MonocularSpeedEstimator()
    private let leadTracker = LeadVehicleTracker()
    private let laneDetector = LaneDetector()
    private let pedestrianDetector = PedestrianHazardDetector()
    private var lastLaneUptime: TimeInterval = -.infinity
    private var laneEstimate: LaneEstimate?
    /// Smoothed corridor centre X (follows `LaneEstimate.laneCenterX` when the lane estimate is confident).
    private var corridorCenterX = 0.5
    private var generation = 0
    private var lastFrameTimestamp: TimeInterval?
    private var fpsEstimate: Double = 0
    private var inferenceEstimate: Double = 0
    private var processedFrames = 0

    // MARK: Lock-protected
    private let lock = NSLock()
    private var inputs = Inputs()
    private var isActive = false
    private var isBusy = false
    private var detectorReady = false
    private var lastAcceptedUptime: TimeInterval = 0
    private var storedOutputHandler: (@Sendable (Output) -> Void)?
    private var storedStatusHandler: (@Sendable (ModelStatuses) -> Void)?

    private let recordingLock = NSLock()
    private var recording: RecordingState?

    init(camera: CameraService) {
        self.camera = camera
    }

    // MARK: - Configuration (any thread)

    /// Receives every processed frame's snapshot (on the processing queue).
    var outputHandler: (@Sendable (Output) -> Void)? {
        get { locked { storedOutputHandler } }
        set { locked { storedOutputHandler = newValue } }
    }

    /// Receives the model load results (on the processing queue).
    var statusHandler: (@Sendable (ModelStatuses) -> Void)? {
        get { locked { storedStatusHandler } }
        set { locked { storedStatusHandler = newValue } }
    }

    /// Installs the frame handler on the camera. The closure is created here, outside any actor, so it is a plain
    /// nonisolated closure that may run on the camera's frames queue.
    func attach(to camera: CameraService) {
        camera.frameHandler = { [weak self] pixelBuffer, time in
            self?.handleFrame(pixelBuffer, time: time)
        }
    }

    /// Loads the detector and the make classifier on the processing queue and reports their status.
    func loadModels() {
        queue.async { [self] in
            let detectorStatus = detector.load()
            locked { detectorReady = detectorStatus.isReady }
            // Report the detector right away; the make classifier is optional and may take a moment more.
            statusHandler?(ModelStatuses(detector: detectorStatus, makeClassifier: .loading))
            let makeStatus = makeClassifier.load()
            statusHandler?(ModelStatuses(detector: detectorStatus, makeClassifier: makeStatus))
        }
    }

    /// Updates the inputs used by the next processed frame.
    func update(_ mutate: (inout Inputs) -> Void) {
        locked { mutate(&inputs) }
    }

    /// Starts or stops accepting camera frames. Stopping drops frames immediately.
    func setActive(_ active: Bool) {
        locked {
            isActive = active
            if active { lastAcceptedUptime = 0 }
        }
        if !active {
            queue.async { [self] in
                lastFrameTimestamp = nil
                fpsEstimate = 0
                leadTracker.reset()
                laneDetector.reset()
                pedestrianDetector.reset()
                laneEstimate = nil
                corridorCenterX = 0.5
            }
        }
    }

    /// Marks subsequent outputs with `generation` (the main actor drops outputs of older generations).
    func setGeneration(_ newGeneration: Int) {
        queue.async { [self] in
            generation = newGeneration
        }
    }

    /// Clears tracks, unique counts and estimator history; subsequent outputs carry `generation`.
    func reset(generation newGeneration: Int) {
        queue.async { [self] in
            recordingLock.lock()
            if let recording {
                recording.accumulated = recording.uniqueInSession
                recording.baseline = [:]
            }
            recordingLock.unlock()
            tracker.reset()
            estimator.reset()
            leadTracker.reset()
            laneDetector.reset()
            pedestrianDetector.reset()
            laneEstimate = nil
            corridorCenterX = 0.5
            makeClassifier.reset()
            generation = newGeneration
            lastFrameTimestamp = nil
        }
    }

    // MARK: - Recording (any thread)

    /// Starts a new research log (replaces an unfinished one).
    func startRecording(modelName: String, startedAt: Date) {
        recordingLock.lock()
        recording = RecordingState(log: ExperimentLog(modelName: modelName, startedAt: startedAt))
        recordingLock.unlock()
    }

    /// Ends the recording and hands over its log with the unique counts collected during it.
    func stopRecording() -> (log: ExperimentLog, uniqueCounts: [VehicleKind: Int])? {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let finished = recording else { return nil }
        recording = nil
        return (finished.log, finished.uniqueInSession)
    }

    var isRecording: Bool {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return recording != nil
    }

    // MARK: - Frames (camera frames queue)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let now = ProcessInfo.processInfo.systemUptime
        let minInterval = 1 / Self.maxFramesPerSecond
        lock.lock()
        // Drop the frame while the previous one is still processed or when it comes too early. Without a detector
        // (model missing / failed) frames still run the lane detector when it is enabled.
        guard isActive, detectorReady || inputs.laneDetectionEnabled, !isBusy,
              now - lastAcceptedUptime >= minInterval * 0.9 else {
            lock.unlock()
            return
        }
        isBusy = true
        lastAcceptedUptime = now
        lock.unlock()

        // The buffer is handed over to the processing queue exclusively (the camera never touches it again).
        let frame = UncheckedFrame(pixelBuffer: pixelBuffer)
        queue.async { [self] in
            process(frame.pixelBuffer, time: time)
            locked { isBusy = false }
        }
    }

    // MARK: - Processing (processing queue)

    private func process(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let frameInputs = locked { inputs }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }
        let timestamp = time.isValid && time.seconds.isFinite ? time.seconds : ProcessInfo.processInfo.systemUptime

        // Lanes first: independent of the detector, and the lead corridor below follows the fresh lane estimate.
        updateLanes(in: pixelBuffer, width: width, height: height, inputs: frameInputs)

        // Frames are rotated upright by the capture connection, so Vision always uses `.up`.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard let result = detector.detect(handler: handler, imageWidth: width, imageHeight: height,
                                           options: frameInputs.detection) else {
            // No detector: still publish the lane estimate so the lane overlay / departure warning work.
            if frameInputs.laneDetectionEnabled, !locked({ detectorReady }) {
                outputHandler?(Output(generation: generation, tracks: [], visibleCounts: [:],
                                      uniqueCounts: tracker.uniqueCounts, fps: fpsEstimate, inferenceMs: 0,
                                      lightColor: nil, frameSize: CGSize(width: width, height: height),
                                      processedFrames: processedFrames, leadVehicle: nil,
                                      laneEstimate: laneEstimate, pedestrianHazards: [],
                                      corridor: leadTracker.corridor))
            }
            return
        }
        var detections = result.detections
        classifyTrafficLights(&detections, in: pixelBuffer, width: width, height: height)

        let countsBeforeUpdate = tracker.uniqueCounts
        var tracks = tracker.update(detections: detections, timestamp: timestamp)
        let geometry = CameraGeometry(horizontalFOVDegrees: camera.horizontalFieldOfView,
                                      imageWidth: Double(width), imageHeight: Double(height))
        tracks = estimator.update(tracks: tracks, ownSpeedKmh: frameInputs.ownSpeedKmh,
                                  geometry: geometry, timestamp: timestamp)
        let leadVehicle = updateLeadVehicle(tracks: tracks, inputs: frameInputs, geometry: geometry,
                                            timestamp: timestamp)
        let pedestrianHazards = updatePedestrians(tracks: tracks, inputs: frameInputs, geometry: geometry,
                                                  timestamp: timestamp)

        if frameInputs.makeRecognitionEnabled, makeClassifier.status.isReady {
            // Votes become visible in the tracks of the next frame.
            for observation in makeClassifier.classify(tracks: tracks, handler: handler, timestamp: timestamp) {
                tracker.addMakeObservation(trackID: observation.trackID, make: observation.make,
                                           confidence: observation.confidence)
            }
        }

        updateStatistics(timestamp: timestamp, inferenceMs: result.inferenceMs)
        let uniqueCounts = tracker.uniqueCounts
        record(tracks: tracks, inputs: frameInputs, countsBeforeUpdate: countsBeforeUpdate, countsNow: uniqueCounts,
               leadTrackID: leadVehicle?.trackID)

        var visibleCounts: [VehicleKind: Int] = [:]
        var largestLight: TrackedObject?
        for track in tracks where track.isConfirmed {
            visibleCounts[track.kind, default: 0] += 1
            // Indicator only for a solid, currently visible light (no flicker from one-off false positives).
            if track.kind == .trafficLight, track.missed == 0, track.hits >= Self.lightMinHits,
               track.confidence >= Self.lightMinConfidence, track.box.area > (largestLight?.box.area ?? 0) {
                largestLight = track
            }
        }
        let lightColor: TrafficLightColor? = largestLight.map { $0.lightColor ?? .unknown }

        let output = Output(generation: generation, tracks: tracks, visibleCounts: visibleCounts,
                            uniqueCounts: uniqueCounts, fps: fpsEstimate, inferenceMs: inferenceEstimate,
                            lightColor: lightColor, frameSize: CGSize(width: width, height: height),
                            processedFrames: processedFrames, leadVehicle: leadVehicle, laneEstimate: laneEstimate,
                            pedestrianHazards: pedestrianHazards, corridor: leadTracker.corridor)
        outputHandler?(output)
    }

    /// Picks the lead vehicle (the vehicle strictly ahead in the own-lane corridor, see `LeadVehicleTracker`) and fuses
    /// its distance from the apparent box width and height. The corridor centre follows the lane centre
    /// (`LaneEstimate.laneCenterX`, smoothed, clamped 0.35–0.65) while the lane estimate is confident (≥ 0.5), else
    /// it returns to the frame centre. Resets the tracker while the feature is off so it restarts cleanly.
    private func updateLeadVehicle(tracks: [TrackedObject], inputs: Inputs, geometry: CameraGeometry,
                                   timestamp: TimeInterval) -> LeadVehicle? {
        guard inputs.followingDistanceEnabled else {
            leadTracker.reset()
            return nil
        }
        let horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        corridorCenterX = EgoCorridor.smoothedCenterX(previous: corridorCenterX,
                                                      lane: inputs.laneDetectionEnabled ? laneEstimate : nil)
        let centerX = (corridorCenterX * 1000).rounded() / 1000
        if leadTracker.corridor.horizonY != horizon || leadTracker.corridor.centerX != centerX {
            leadTracker.corridor = EgoCorridor(centerX: centerX, horizonY: horizon)
        }
        return leadTracker.update(tracks: tracks, geometry: geometry, timestamp: timestamp)
    }

    /// Pedestrians on / about to enter the roadway ahead (own-lane corridor with the same horizon as the lead tracker).
    private func updatePedestrians(tracks: [TrackedObject], inputs: Inputs, geometry: CameraGeometry,
                                   timestamp: TimeInterval) -> [PedestrianHazard] {
        guard inputs.pedestrianWarningsEnabled, inputs.detection.trackPedestrians else {
            pedestrianDetector.reset()
            return []
        }
        let horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        if pedestrianDetector.corridor.horizonY != horizon {
            pedestrianDetector.corridor = EgoCorridor(horizonY: horizon)
        }
        return pedestrianDetector.update(tracks: tracks, ownSpeedKmh: inputs.ownSpeedKmh, geometry: geometry,
                                         timestamp: timestamp)
    }

    /// Runs the lane detector at ≈ 5 Hz on a downsampled (≤ 160 px wide) marking-brightness copy of the locked BGRA
    /// buffer (rows above the horizon are skipped). Between runs the previous estimate is repeated.
    private func updateLanes(in pixelBuffer: CVPixelBuffer, width: Int, height: Int, inputs: Inputs) {
        guard inputs.laneDetectionEnabled else {
            if laneEstimate != nil {
                laneDetector.reset()
                laneEstimate = nil
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLaneUptime >= Self.laneInterval * 0.9,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer) else { return }
        lastLaneUptime = now
        let horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        if laneDetector.config.horizonY != horizon {
            laneDetector.config.horizonY = horizon
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        let image: LaneImage
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            image = LaneImage.fromBGRA(base: UnsafeRawPointer(base), width: width, height: height,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                       targetWidth: Self.laneImageWidth, roiTop: max(0, horizon - 0.02))
        } else {
            image = LaneImage(width: 0, height: 0)
        }
        _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        guard image.width > 0 else { return }
        laneEstimate = laneDetector.process(image, timestamp: now)
    }

    /// Estimates the colour of every traffic light from the BGRA pixels inside its box.
    private func classifyTrafficLights(_ detections: inout [Detection], in pixelBuffer: CVPixelBuffer,
                                       width: Int, height: Int) {
        guard detections.contains(where: { $0.kind == .trafficLight }),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer) else { return }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for index in detections.indices where detections[index].kind == .trafficLight {
            let box = detections[index].box.clamped
            let rectX = Int((box.x * Double(width)).rounded(.down))
            let rectY = Int((box.y * Double(height)).rounded(.down))
            let rectWidth = Int((box.width * Double(width)).rounded(.up))
            let rectHeight = Int((box.height * Double(height)).rounded(.up))
            guard rectWidth >= 3, rectHeight >= 6 else { continue }
            // About 24 samples along the short side keeps the cost constant for near and far lights.
            let step = max(1, min(rectWidth, rectHeight) / 24)
            detections[index].lightColor = TrafficLightColorClassifier.classifyBGRA(
                base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow,
                rectX: rectX, rectY: rectY, rectWidth: rectWidth, rectHeight: rectHeight, step: step)
        }
    }

    /// Exponential moving averages of the processing rate and the inference time.
    private func updateStatistics(timestamp: TimeInterval, inferenceMs: Double) {
        if let last = lastFrameTimestamp {
            let dt = timestamp - last
            if dt > 0.001 && dt < 2 {
                let instant = 1 / dt
                fpsEstimate = fpsEstimate == 0 ? instant : fpsEstimate * 0.85 + instant * 0.15
            }
        }
        lastFrameTimestamp = timestamp
        inferenceEstimate = inferenceEstimate == 0 ? inferenceMs : inferenceEstimate * 0.85 + inferenceMs * 0.15
        processedFrames += 1
    }

    /// Appends one record per visible track to the active research log.
    private func record(tracks: [TrackedObject], inputs: Inputs,
                        countsBeforeUpdate: [VehicleKind: Int], countsNow: [VehicleKind: Int],
                        leadTrackID: Int? = nil) {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recording else { return }

        if recording.baseline == nil {
            recording.baseline = countsBeforeUpdate
        }
        let baseline = recording.baseline ?? [:]
        var session = recording.accumulated
        for (kind, count) in countsNow {
            let added = count - (baseline[kind] ?? 0)
            if added > 0 { session[kind, default: 0] += added }
        }
        recording.uniqueInSession = session

        recording.log.markFrame()
        let frameIndex = recording.log.frameCount
        let now = Date()
        for track in tracks {
            recording.log.append(ExperimentRecord(
                timestamp: now, frameIndex: frameIndex, trackID: track.id, kind: track.kind, label: track.label,
                confidence: track.confidence, box: track.box, make: track.make, makeConfidence: track.makeConfidence,
                distanceMeters: track.distanceMeters, estimatedSpeedKmh: track.estimatedSpeedKmh,
                lightColor: track.lightColor, latitude: inputs.latitude, longitude: inputs.longitude,
                ownSpeedKmh: inputs.ownSpeedKmh, isConfirmed: track.isConfirmed, trackHits: track.hits,
                isLead: track.id == leadTrackID))
        }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Hands a pixel buffer from the camera queue to the processing queue (exclusive ownership transfer).
private struct UncheckedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}
