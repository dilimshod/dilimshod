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
/// - `detector`, `makeClassifier`, `tracker`, `estimator`, `leadTracker`, `qualityGovernor` and the frame statistics
///   are confined to `queue`.
/// - Inputs coming from the main actor (GPS, settings), the activity flags and the handlers are lock-protected.
/// - The experiment recording has its own lock so the main actor can stop it without waiting for inference.
/// - Results are delivered through `outputHandler` (called on `queue`, at most `maxFramesPerSecond` times per second).
/// - Continuous learning: `learning` (hard-frame collector) and `modelHealth` (downloaded-model watchdog) are
///   confined to `queue` as well; the collector encodes kept frames on its own utility queue.
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
        /// Measure the horizon from the lane vanishing point (`LaneHorizonEstimator`); `corridorHorizon` is then only
        /// the start value (`settings.autoHorizonEnabled`).
        var autoHorizonEnabled = true
        /// Last measured horizons of earlier sessions (nil = none), used until this session has its own estimate.
        var storedHorizonPortrait: Double?
        var storedHorizonLandscape: Double?
        /// Camera → front bumper distance subtracted from the lead distance (`settings.hoodLengthMeters`).
        var cameraToBumperMeters = 2.2
        /// Run the classical lane-marking detector (~5 Hz, on a downsampled copy of the frame).
        var laneDetectionEnabled = true
        /// Run the pedestrian-on-the-roadway check (`DriverAssistSettings.pedestrianWarningsEnabled`).
        var pedestrianWarningsEnabled = true
        /// Continuous learning: collect hard frames (`LearningCollector`, setting «Обучение модели», off by default).
        var learningEnabled = false
        /// Put the GPS position into the sample metadata (setting «send location», off by default).
        var learningSendLocation = false
        /// Local sample storage cap, MB.
        var learningStorageLimitMB = LearningStorePolicy.defaultLimitMB
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
        /// Stable colour of the traffic light that applies to the own lane (`TrafficLightSelection.ownLane`: confirmed,
        /// ≥ 5 hits, known colour from the tracker's time-window vote, ahead of the corridor); nil when none.
        var lightColor: TrafficLightColor?
        /// The light `lightColor` comes from (track ID, colour, box) — the one the coach looks at.
        var observedLight: ObservedTrafficLight?
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
        /// Traffic officers / road workers (colour heuristic) on or at the roadway, nearest first (empty when off).
        var roadStaff: [RoadStaffSighting]
        /// Smoothed roadway zone that separates the roadway from the sidewalk (nil while persons are not tracked).
        var roadwayZone: RoadwayZone?
        /// Own-lane corridor the lead was picked from (centre follows a confident lane estimate).
        var corridor: EgoCorridor
        /// Horizon row in use on this frame (manual setting, or the measured one while auto horizon is on).
        var horizonY: Double
        /// Horizon measured in this session from the lane vanishing point (nil until the estimator converged or
        /// while auto horizon is off), with the frame orientation it belongs to.
        var measuredHorizon: Double?
        var measuredHorizonIsLandscape: Bool
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
    /// A traffic light drives the colour indicator / coach only with this many hits AND a stable known colour
    /// (`TrafficLightSelection.ownLane`). The former extra 0.5 confidence floor is gone: the class threshold is 0.30
    /// for recall (see `DetectionThresholds.classBase`), and the colour requirement is what filters false boxes.
    static let lightMinHits = TrafficLightSelection.minHits
    /// A pedestrian can raise a warning once its track has reached this detector confidence (plus the hit / shape
    /// checks of `PedestrianHazardDetector`). Same value as the person threshold at the default slider position;
    /// the previous 0.55 was stacked on top of the tracker's own 0.5.
    static let pedestrianMinConfidence = DetectionThresholds.threshold(for: .person)
    /// Lane detection interval, seconds (≈ 5 Hz).
    static let laneInterval: TimeInterval = 0.2
    /// Width of the downsampled image analysed by the lane detector, pixels.
    static let laneImageWidth = 160

    let queue = DispatchQueue(label: "recognition.processing", qos: .userInitiated)
    private let camera: CameraService

    // MARK: Queue-confined
    private let detector = VehicleDetector()
    private let makeClassifier = MakeClassifier()
    /// Persons are counted only once they are on / at the roadway (`PersonSceneResult.relevantIDs`). The per-class
    /// confidence table (`tracker.minConfidence`) is refreshed from the settings slider on every frame.
    private let tracker = ObjectTracker(config: ObjectTracker.Config(deferredCountKinds: [.person]))
    /// Full (YOLO11s) vs lite (YOLO11n) detector, decided from the measured inference time and the thermal state.
    private var qualityGovernor = DetectorQualityGovernor(config: .iOS)
    private var appliedConfidence: Double?
    private var reportedDetectorStatus: ModelStatus = .loading
    private var makeClassifierStatus: ModelStatus = .loading
    private let estimator = MonocularSpeedEstimator()
    private let leadTracker = LeadVehicleTracker()
    private let laneDetector = LaneDetector()
    private let pedestrianDetector = PedestrianHazardDetector()
    private let roadwayEstimator = RoadwayZoneEstimator()
    private var lastLaneUptime: TimeInterval = -.infinity
    private var laneEstimate: LaneEstimate?
    /// Horizon from the lane vanishing point (`settings.autoHorizonEnabled`). `measuredHorizon` is the value in use;
    /// it changes only when the estimator moves by more than `LaneHorizonEstimator.applyDelta`.
    private var horizonEstimator = LaneHorizonEstimator()
    private var measuredHorizon: Double?
    /// Orientation the estimator's samples belong to (nil before the first frame).
    private var horizonIsLandscape: Bool?
    /// Smoothed corridor centre X (follows `LaneEstimate.laneCenterX` when the lane estimate is confident).
    private var corridorCenterX = 0.5
    private var generation = 0
    private var lastFrameTimestamp: TimeInterval?
    private var fpsEstimate: Double = 0
    private var inferenceEstimate: Double = 0
    private var processedFrames = 0
    /// Hard-frame collector for the RoadVis Trainer (runs only while `Inputs.learningEnabled`).
    private let learning = LearningCollector()
    /// "No detector output for 30 s of driving" watchdog of a downloaded model.
    private var modelHealth = ModelHealthMonitor()

    // MARK: Lock-protected
    private let lock = NSLock()
    private var inputs = Inputs()
    private var isActive = false
    private var isBusy = false
    private var detectorReady = false
    private var lastAcceptedUptime: TimeInterval = 0
    private var storedOutputHandler: (@Sendable (Output) -> Void)?
    private var storedStatusHandler: (@Sendable (ModelStatuses) -> Void)?
    private var storedModelFailureHandler: (@Sendable (String, String?) -> Void)?

    private let recordingLock = NSLock()
    private var recording: RecordingState?

    init(camera: CameraService) {
        self.camera = camera
        pedestrianDetector.minConfidence = Self.pedestrianMinConfidence
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

    /// Receives the learning collector's events (on its utility queue).
    var learningEventHandler: (@Sendable (LearningCollector.Event) -> Void)? {
        get { learning.eventHandler }
        set { learning.eventHandler = newValue }
    }

    /// Called (on the processing queue) when the downloaded model was dropped: (version, load error message), the
    /// message is nil for "no detector output for 30 s of driving". The detector is already back on the bundled models.
    var modelFailureHandler: (@Sendable (String, String?) -> Void)? {
        get { locked { storedModelFailureHandler } }
        set { locked { storedModelFailureHandler = newValue } }
    }

    /// Prefers a downloaded detector model (nil = bundled models only) from the next frame on.
    func setDownloadedModel(_ model: DownloadedDetectorModel?) {
        queue.async { [self] in
            detector.downloadedModel = model
            modelHealth.reset()
        }
    }

    /// A trip started: the collector's per-trip counter restarts.
    func resetLearningTrip() {
        queue.async { [self] in
            learning.resetTrip()
        }
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
            // Orientation hint: the rotation applied to the camera output (90° / 270° = upright portrait frames).
            // A wrong guess only costs time — the model for the real frame shape is loaded with the first frame.
            let angle = Int(camera.videoRotationAngle.rounded())
            let detectorStatus = detector.load(landscape: angle % 180 == 0)
            reportedDetectorStatus = detectorStatus
            locked { detectorReady = detectorStatus.isReady }
            // Report the detector right away; the make classifier is optional and may take a moment more.
            statusHandler?(ModelStatuses(detector: detectorStatus, makeClassifier: .loading))
            let makeStatus = makeClassifier.load()
            makeClassifierStatus = makeStatus
            statusHandler?(ModelStatuses(detector: reportedDetectorStatus, makeClassifier: makeStatus))
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
                // Live tracks must not survive the gap: after minutes in the navigator / background the first
                // frame would continue them (confirmed state, hits, make / colour / role votes) with whatever
                // overlaps their old boxes. Unique counters and track IDs are kept (`reset(generation:)` clears those).
                tracker.dropTracks()
                estimator.reset()
                leadTracker.reset()
                laneDetector.reset()
                pedestrianDetector.reset()
                roadwayEstimator.reset()
                laneEstimate = nil
                corridorCenterX = 0.5
                learning.resetMemory()
                modelHealth.reset()
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
            roadwayEstimator.reset()
            laneEstimate = nil
            corridorCenterX = 0.5
            makeClassifier.reset()
            learning.resetMemory()
            modelHealth.reset()
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

        // One horizon for the lane ROI, the lead corridor, the roadway zone and the light selection of this frame.
        let horizon = horizonInUse(inputs: frameInputs, width: width, height: height)
        // Lanes first: independent of the detector, and the lead corridor below follows the fresh lane estimate.
        updateLanes(in: pixelBuffer, width: width, height: height, inputs: frameInputs, horizon: horizon)

        // Frames are rotated upright by the capture connection, so Vision always uses `.up`.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let detectorOutput = detector.detect(handler: handler, imageWidth: width, imageHeight: height,
                                             options: frameInputs.detection)
        // The model in use changes with the frame orientation and the quality level (or fails to load lazily).
        publishDetectorStatusIfChanged()
        watchDownloadedModel(output: detectorOutput, timestamp: timestamp, ownSpeedKmh: frameInputs.ownSpeedKmh)
        guard let result = detectorOutput else {
            learning.disable()
            // No detector: still publish the lane estimate so the lane overlay / departure warning work.
            if frameInputs.laneDetectionEnabled, !detector.status.isReady {
                outputHandler?(Output(generation: generation, tracks: [], visibleCounts: [:],
                                      uniqueCounts: tracker.uniqueCounts, fps: fpsEstimate, inferenceMs: 0,
                                      lightColor: nil, observedLight: nil,
                                      frameSize: CGSize(width: width, height: height),
                                      processedFrames: processedFrames, leadVehicle: nil,
                                      laneEstimate: laneEstimate, pedestrianHazards: [], roadStaff: [],
                                      roadwayZone: nil, corridor: leadTracker.corridor, horizonY: horizon,
                                      measuredHorizon: measuredHorizon,
                                      measuredHorizonIsLandscape: width >= height))
            }
            return
        }
        // Full ↔ lite detector for the next frames, from this frame's inference time and the thermal state.
        let thermal = ProcessInfo.processInfo.thermalState
        detector.preferredLevel = qualityGovernor.record(
            inferenceMs: result.inferenceMs, constrained: thermal == .serious || thermal == .critical,
            timestamp: ProcessInfo.processInfo.systemUptime)
        // One threshold table for the detector floor and the tracker (no second hidden per-class filter).
        let confidence = frameInputs.detection.confidenceThreshold
        if appliedConfidence != confidence {
            tracker.minConfidence = DetectionThresholds.perClass(global: confidence)
            appliedConfidence = confidence
        }

        var detections = result.detections
        classifyTrafficLights(&detections, in: pixelBuffer, width: width, height: height)
        classifyPersonRoles(&detections, in: pixelBuffer, width: width, height: height)

        let countsBeforeUpdate = tracker.uniqueCounts
        var tracks = tracker.update(detections: detections, timestamp: timestamp)
        // The hard-frame selector sees the tracker's own output (before the sidewalk filter below removes persons):
        // a person dropped there must not look like a dead, short-lived track.
        let trackerTracks = tracks
        let geometry = CameraGeometry(horizontalFOVDegrees: camera.horizontalFieldOfView,
                                      imageWidth: Double(width), imageHeight: Double(height))
        tracks = estimator.update(tracks: tracks, ownSpeedKmh: frameInputs.ownSpeedKmh,
                                  geometry: geometry, timestamp: timestamp)
        let leadVehicle = updateLeadVehicle(tracks: tracks, inputs: frameInputs, geometry: geometry,
                                            timestamp: timestamp, horizon: horizon)
        // Roadway / sidewalk split: persons outside the roadway zone (not moving toward it) are dropped here, before
        // drawing, counting and logging.
        let scene = updatePedestrians(tracks: tracks, inputs: frameInputs, geometry: geometry, timestamp: timestamp,
                                      horizon: horizon)
        if !scene.filteredIDs.isEmpty {
            tracks.removeAll { scene.filteredIDs.contains($0.id) }
        }
        tracker.markRelevant(trackIDs: Array(scene.relevantIDs))
        let warningsOn = frameInputs.pedestrianWarningsEnabled
        let pedestrianHazards = warningsOn ? scene.hazards : []
        let roadStaff = warningsOn ? scene.staff : []

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
        let lightThreshold = DetectionThresholds.threshold(for: .trafficLight, global: confidence)
        for track in tracks where track.isConfirmed {
            // Low-score lights without a readable colour are neither drawn (pipeline) nor counted as visible.
            guard TrafficLightSelection.isDisplayable(track, classThreshold: lightThreshold) else { continue }
            visibleCounts[track.kind, default: 0] += 1
        }
        // Indicator / coach: the light that applies to the own lane (stable known colour, ≥ 5 hits), not simply
        // the largest box.
        let observedLight = TrafficLightSelection.ownLane(
            in: tracks, corridorCenterX: corridorCenterX,
            horizonY: horizon, minHits: Self.lightMinHits)
        let lightColor: TrafficLightColor? = observedLight?.color

        let output = Output(generation: generation, tracks: tracks, visibleCounts: visibleCounts,
                            uniqueCounts: uniqueCounts, fps: fpsEstimate, inferenceMs: inferenceEstimate,
                            lightColor: lightColor, observedLight: observedLight,
                            frameSize: CGSize(width: width, height: height),
                            processedFrames: processedFrames, leadVehicle: leadVehicle, laneEstimate: laneEstimate,
                            pedestrianHazards: pedestrianHazards, roadStaff: roadStaff,
                            roadwayZone: frameInputs.detection.trackPedestrians ? roadwayEstimator.zone : nil,
                            corridor: leadTracker.corridor, horizonY: horizon, measuredHorizon: measuredHorizon,
                            measuredHorizonIsLandscape: width >= height)
        outputHandler?(output)

        // Continuous learning, after the snapshot went out (does not delay the UI). Cheap per frame; the quality
        // metrics and the JPEG are made only for kept frames (see `LearningCollector`).
        if frameInputs.learningEnabled {
            let learningFrame = HardExampleFrame(timestamp: timestamp, frameIndex: processedFrames,
                                                 ownSpeedKmh: frameInputs.ownSpeedKmh, tracks: trackerTracks,
                                                 detections: detections, classThresholds: tracker.minConfidence)
            let context = LearningCollector.Context(sendLocation: frameInputs.learningSendLocation,
                                                    latitude: frameInputs.latitude, longitude: frameInputs.longitude,
                                                    modelName: result.modelName,
                                                    storageLimitMB: frameInputs.learningStorageLimitMB)
            learning.process(pixelBuffer: pixelBuffer, frame: learningFrame, context: context)
        } else {
            learning.disable()
        }
    }

    /// Drops a downloaded model that failed to load, or that produced no detection for
    /// `ModelUpdatePolicy.noOutputRevertSeconds` of driving frames (`ModelHealthMonitor`), and reports it.
    private func watchDownloadedModel(output: VehicleDetector.Output?, timestamp: TimeInterval, ownSpeedKmh: Double?) {
        if let failure = detector.takeDownloadedModelFailure() {
            modelHealth.reset()
            detector.downloadedModel = nil
            modelFailureHandler?(failure.version, failure.message)
            return
        }
        guard detector.isUsingDownloadedModel, let version = detector.downloadedModel?.version else {
            if modelHealth.silentSeconds > 0 { modelHealth.reset() }
            return
        }
        let hadOutput: Bool = !(output?.detections.isEmpty ?? true)
        var driving = true
        if let speed = ownSpeedKmh, speed.isFinite {
            driving = speed >= HardExampleSelector.Config().minSpeedKmh
        }
        if modelHealth.record(timestamp: timestamp, hadOutput: hadOutput, driving: driving) {
            modelHealth.reset()
            detector.downloadedModel = nil
            modelFailureHandler?(version, nil)
        }
    }

    /// Picks the lead vehicle (the vehicle strictly ahead in the own-lane corridor, see `LeadVehicleTracker`) and fuses
    /// its distance from the apparent box width and height. The corridor centre follows the lane centre
    /// (`LaneEstimate.laneCenterX`, smoothed, clamped 0.35–0.65) while the lane estimate is confident (≥ 0.5), else
    /// it returns to the frame centre. Resets the tracker while the feature is off so it restarts cleanly.
    private func updateLeadVehicle(tracks: [TrackedObject], inputs: Inputs, geometry: CameraGeometry,
                                   timestamp: TimeInterval, horizon: Double) -> LeadVehicle? {
        guard inputs.followingDistanceEnabled else {
            leadTracker.reset()
            return nil
        }
        corridorCenterX = EgoCorridor.smoothedCenterX(previous: corridorCenterX,
                                                      lane: inputs.laneDetectionEnabled ? laneEstimate : nil)
        let centerX = (corridorCenterX * 1000).rounded() / 1000
        // Aspect-aware corridor (portrait frames need a wider one); the whole struct is compared so a rotation
        // updates it too.
        let corridor = EgoCorridor.forFrame(centerX: centerX, horizonY: horizon, imageWidth: geometry.imageWidth,
                                            imageHeight: geometry.imageHeight)
        if leadTracker.corridor != corridor {
            leadTracker.corridor = corridor
        }
        leadTracker.cameraToBumperMeters = inputs.cameraToBumperMeters
        return leadTracker.update(tracks: tracks, geometry: geometry, timestamp: timestamp)
    }

    /// Persons vs the roadway zone (lane markings extended by the typical number of lanes, or the own-lane corridor
    /// widened, same horizon as the lead tracker): pedestrian hazards, officers / road workers, and the sidewalk
    /// persons to drop. Runs whenever persons are tracked — the sidewalk filter applies even with warnings off.
    private func updatePedestrians(tracks: [TrackedObject], inputs: Inputs, geometry: CameraGeometry,
                                   timestamp: TimeInterval, horizon: Double) -> PersonSceneResult {
        guard inputs.detection.trackPedestrians else {
            pedestrianDetector.reset()
            roadwayEstimator.reset()
            return PersonSceneResult()
        }
        let corridor = EgoCorridor.forFrame(horizonY: horizon, imageWidth: geometry.imageWidth,
                                            imageHeight: geometry.imageHeight)
        if pedestrianDetector.corridor != corridor {
            pedestrianDetector.corridor = corridor
        }
        roadwayEstimator.config.roadWidthFactor = pedestrianDetector.roadWidthFactor
        roadwayEstimator.config.aspectScale = LaneDetector.aspectScale(width: Int(geometry.imageWidth),
                                                                       height: Int(geometry.imageHeight))
        pedestrianDetector.roadway = roadwayEstimator.update(lane: inputs.laneDetectionEnabled ? laneEstimate : nil,
                                                             corridor: pedestrianDetector.corridor)
        return pedestrianDetector.evaluate(tracks: tracks, ownSpeedKmh: inputs.ownSpeedKmh, geometry: geometry,
                                           timestamp: timestamp)
    }

    /// Runs the lane detector at ≈ 5 Hz on a downsampled (≤ 160 px wide) marking-brightness copy of the locked BGRA
    /// buffer (rows above the horizon are skipped). Between runs the previous estimate is repeated.
    ///
    /// Each lane frame also yields the vanishing point of the two raw line fits; while auto horizon is on and the
    /// car drives at least `LaneHorizonEstimator.minSpeedKmh`, it is fed to `horizonEstimator`. A converged estimate
    /// that differs from the horizon in use by more than `LaneHorizonEstimator.applyDelta` becomes `measuredHorizon`
    /// (used from the next frame on by everything that shares the horizon).
    private func updateLanes(in pixelBuffer: CVPixelBuffer, width: Int, height: Int, inputs: Inputs,
                             horizon: Double) {
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
        if laneDetector.config.horizonY != horizon {
            // Keeps the smoothed lines where they are in the picture (their stored top x is tied to the horizon row).
            laneDetector.setHorizon(horizon)
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

        guard inputs.autoHorizonEnabled, let speed = inputs.ownSpeedKmh, speed.isFinite,
              speed >= LaneHorizonEstimator.minSpeedKmh else { return }
        if let estimate: Double = horizonEstimator.add(laneDetector.lastVanishingPoint),
           LaneHorizonEstimator.shouldApply(estimate: estimate, current: horizon) {
            measuredHorizon = estimate
        }
    }

    /// Horizon row for this frame, clamped to 0.1…0.8: the manual setting, or — while auto horizon is on — the
    /// horizon measured in this session, else the one stored from an earlier session for this frame orientation,
    /// else the manual setting. A change of the frame orientation (or switching auto off) discards the estimate:
    /// the horizon row of a portrait frame says nothing about a landscape one.
    private func horizonInUse(inputs: Inputs, width: Int, height: Int) -> Double {
        let landscape = width >= height
        if horizonIsLandscape != landscape || !inputs.autoHorizonEnabled {
            if horizonIsLandscape != nil || measuredHorizon != nil {
                horizonEstimator.reset()
                measuredHorizon = nil
            }
            horizonIsLandscape = landscape
        }
        var value: Double = inputs.corridorHorizon
        if inputs.autoHorizonEnabled {
            let stored: Double? = landscape ? inputs.storedHorizonLandscape : inputs.storedHorizonPortrait
            if let measured = measuredHorizon {
                value = measured
            } else if let stored, stored.isFinite, LaneHorizonEstimator.rowRange.contains(stored) {
                value = stored
            }
        }
        return min(0.8, max(0.1, value))
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
            // The classifier samples about 24 points along the short side (constant cost for near and far lights).
            detections[index].lightColor = TrafficLightColorClassifier.classifyBGRA(
                base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow,
                rectX: rectX, rectY: rectY, rectWidth: rectWidth, rectHeight: rectHeight)
        }
    }

    /// Guesses the role of every person (traffic officer / road worker / pedestrian) from the hi-vis vest colour of the
    /// torso band (`PersonRoleClassifier`, colour heuristic); the tracker votes over the last frames.
    private func classifyPersonRoles(_ detections: inout [Detection], in pixelBuffer: CVPixelBuffer,
                                     width: Int, height: Int) {
        guard detections.contains(where: { $0.kind == .person }),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer) else { return }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for index in detections.indices where detections[index].kind == .person {
            let box = detections[index].box.clamped
            let rectWidth = Int((box.width * Double(width)).rounded(.up))
            let rectHeight = Int((box.height * Double(height)).rounded(.up))
            guard rectWidth >= 8, rectHeight >= PersonRoleClassifier.minBoxHeightPixels else { continue }
            // About 20 samples across the box width keeps the cost constant for near and far persons.
            let step = max(1, rectWidth / 20)
            detections[index].personRole = PersonRoleClassifier.classifyBGRA(
                base: UnsafeRawPointer(base), width: width, height: height, bytesPerRow: bytesPerRow,
                rectX: Int((box.x * Double(width)).rounded(.down)), rectY: Int((box.y * Double(height)).rounded(.down)),
                rectWidth: rectWidth, rectHeight: rectHeight, step: step)
        }
    }

    /// Reports the detector status again when the model in use changed (orientation / quality level / lazy load).
    private func publishDetectorStatusIfChanged() {
        let current = detector.status
        guard current != reportedDetectorStatus else { return }
        reportedDetectorStatus = current
        statusHandler?(ModelStatuses(detector: current, makeClassifier: makeClassifierStatus))
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
        // Coasted tracks (`missed ≥ 1`, predicted box) are not detections: the research log holds measured boxes only.
        for track in tracks where track.missed == 0 {
            recording.log.append(ExperimentRecord(
                timestamp: now, frameIndex: frameIndex, trackID: track.id, kind: track.kind, label: track.label,
                confidence: track.confidence, box: track.box, make: track.make, makeConfidence: track.makeConfidence,
                distanceMeters: track.distanceMeters, estimatedSpeedKmh: track.estimatedSpeedKmh,
                lightColor: track.lightColor, latitude: inputs.latitude, longitude: inputs.longitude,
                ownSpeedKmh: inputs.ownSpeedKmh, isConfirmed: track.isConfirmed, trackHits: track.hits,
                isLead: track.id == leadTrackID, personRole: track.kind == .person ? track.personRole : nil))
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
