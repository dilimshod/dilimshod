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
/// Following distance: the worker also picks the lead vehicle (`LeadVehicleTracker`, own-lane corridor from
/// `settings.corridorHorizon`); the main actor turns it into a `FollowingDistanceAssessment` (own GPS speed, road
/// surface from the weather or the manual setting, `settings.followingDistancePolicy`) and drives the haptic / tone /
/// voice warnings through `DistanceWarningController`. Without a lead the assessment still carries the recommended
/// gap for the current speed (status `.unknown`) so the HUD can show the norm.
///
/// Wording: detector scores are "уверенность" (model confidence), distances/speeds are "≈ оценка".
@Observable
@MainActor
final class RecognitionPipeline {
    let camera: CameraService

    /// Visible tracks (confirmed and tentative) for the overlay. A confirmed track missed on the latest frame is kept
    /// for `trackHoldSeconds` (with `missed ≥ 1`) so boxes do not flicker on single missed detections.
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
    /// Stable colour of the traffic light that applies to the own lane (camera estimate); nil when none / unreadable.
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

    // MARK: Following distance (only while `settings.followingDistanceEnabled`)

    /// Vehicle directly ahead in the own lane with a fused (≈) distance estimate; nil when none.
    private(set) var leadVehicle: LeadVehicle?
    /// Gap to the lead vs the recommendation. Without a lead: recommended gap for the current speed, status `.unknown`.
    /// nil while following distance is switched off.
    private(set) var followingAssessment: FollowingDistanceAssessment?
    /// Road surface used for the recommendation (auto from the app's weather, or the manual setting).
    private(set) var roadSurface: RoadSurfaceCondition = .dry
    /// Where `roadSurface` comes from.
    private(set) var roadSurfaceSource: RoadSurfaceSource = .noWeather
    /// Moving, dangerously close and the time to collision is below `policy.collisionWarningSeconds` (not throttled;
    /// for the visual warning — sound/voice are throttled by `DistanceWarningController`).
    private(set) var isForwardCollisionWarning = false

    /// Current weather for the "auto" road surface (set by `AppState`).
    @ObservationIgnored var weatherProvider: (@MainActor () -> WeatherSnapshot?)?
    /// Voice output for distance warnings (set by `AppState`; nil → haptics and tone only).
    @ObservationIgnored var speech: SpeechService? {
        didSet {
            warnings.speech = voiceWarningsHandledByCoach ? nil : speech
            warnings.tones = speech   // tones stay with the controller even when the coach speaks
        }
    }
    /// Set by `DriverCoach`: the coach speaks the distance warnings (no duplicate speech); the warning controller then
    /// only gives haptics and the alert tone.
    @ObservationIgnored var voiceWarningsHandledByCoach = false {
        didSet { warnings.speech = voiceWarningsHandledByCoach ? nil : speech }
    }

    // MARK: Driver assistant (lanes, coaching cues, driving events)

    /// Latest lane-marking estimate (≈ 5 Hz, heuristic); nil while lane detection is off or the camera is stopped.
    private(set) var laneEstimate: LaneEstimate?
    /// Side whose marking the car is currently drifting over (for the red lane line), nil when inside the lane.
    private(set) var laneDepartureSide: LaneSide?
    /// Pedestrians on / about to enter the roadway ahead, most urgent first (danger, then nearest). Empty while
    /// pedestrian warnings or pedestrian detection are off. Heuristic (monocular, own-lane corridor).
    private(set) var pedestrianHazards: [PedestrianHazard] = []
    /// The most urgent pedestrian hazard (for the banner / PiP badge).
    var topPedestrianHazard: PedestrianHazard? { pedestrianHazards.first }
    /// Traffic officers / road workers (colour heuristic ≈) on or at the roadway, nearest first. Empty while pedestrian
    /// warnings or pedestrian detection are off. They are never pedestrian hazards (blue / orange banner instead).
    private(set) var roadStaff: [RoadStaffSighting] = []
    /// The nearest officer / road worker (for the banner when there is no pedestrian hazard).
    var topRoadStaff: RoadStaffSighting? { roadStaff.first }
    /// Roadway zone that separates the roadway from the sidewalk (persons outside it are not recognised); nil while
    /// persons are not tracked or the camera is stopped.
    private(set) var roadwayZone: RoadwayZone?
    /// Camera-based driving events (tailgating, collision risk, lane departure, red-light running, STOP ignored), with
    /// GPS coordinate and speed. Only NEW events (repeats within 8 s are collapsed). Called on the main actor.
    @ObservationIgnored var onDrivingEvent: ((DrivingEvent) -> Void)?
    /// Per-frame cues for `DriverCoach` (called on the main actor after every processed frame).
    @ObservationIgnored var onAssistFrame: ((DriverAssistFrame) -> Void)?

    /// Centre X of the own-lane corridor the worker picked the lead from (follows a confident lane estimate).
    private(set) var corridorCenterX = 0.5
    /// Horizon row the worker used on the latest frame (the manual setting, or the measured one with auto horizon).
    private(set) var horizonInUse: Double?

    /// Own-lane corridor used to pick the lead vehicle (for drawing).
    var egoCorridor: EgoCorridor {
        // Same aspect-aware corridor as the worker uses (portrait frames get a wider one), so the overlay matches.
        EgoCorridor.forFrame(centerX: corridorCenterX,
                             horizonY: min(0.8, max(0.1, horizonInUse ?? settings.corridorHorizon)),
                             imageWidth: Double(frameSize.width), imageHeight: Double(frameSize.height))
    }

    /// The following-distance policy currently in effect (from the settings).
    var followingDistancePolicy: FollowingDistancePolicy { settings.followingDistancePolicy }

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
    /// False while the camera is only kept warm (session running, no inference) — see `start(processing:)`.
    @ObservationIgnored private var wantsProcessing = true
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var isFinishingRecording = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let warnings = DistanceWarningController()
    @ObservationIgnored private let assist: DriverAssistSettings
    @ObservationIgnored private var laneDeparture = LaneDepartureDetector()
    @ObservationIgnored private let eventMonitor = CameraDrivingEventMonitor()
    @ObservationIgnored private var lastLaneTimestamp: TimeInterval?
    @ObservationIgnored private var lastLaneDepartureUptime: TimeInterval = -.infinity
    /// Uptime of the last frame-driven following-distance refresh (location updates skip theirs while frames flow).
    @ObservationIgnored private var lastFrameRefreshUptime: TimeInterval = -.infinity
    /// Last frame each track was seen on (display hold), by track id.
    @ObservationIgnored private var recentTracks: [Int: (track: TrackedObject, seen: TimeInterval)] = [:]
    /// Uptime when the worker last reported a lead vehicle.
    @ObservationIgnored private var lastLeadUptime: TimeInterval = -.infinity
    @ObservationIgnored private var lastPedestrianUptime: TimeInterval = -.infinity
    @ObservationIgnored private var lastRoadStaffUptime: TimeInterval = -.infinity

    /// How long a confirmed track missed by the detector stays on screen, seconds.
    static let trackHoldSeconds: TimeInterval = 0.3
    /// How long the lead vehicle (distance line, HUD number) survives frames without it, seconds.
    static let leadHoldSeconds: TimeInterval = 0.5
    /// Pedestrian hazards are kept this long after they vanish from a frame (no blinking banner on a missed frame).
    static let pedestrianHoldSeconds: TimeInterval = 0.6

    init(location: LocationService, settings: AppSettings, signals: TrafficSignalService) {
        self.location = location
        self.settings = settings
        self.signals = signals
        self.assist = DriverAssistSettings.shared
        let camera = CameraService()
        self.camera = camera
        self.worker = RecognitionWorker(camera: camera)

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
            guard let self else { return }
            self.pushLocation()
            // Keeps the recommended gap current without camera frames (no model, camera paused); while frames flow
            // the next frame picks up the new speed, so observable updates stay ≤ 15 Hz.
            if ProcessInfo.processInfo.systemUptime - self.lastFrameRefreshUptime > 0.5 {
                self.refreshFollowingDistance(fromFrame: false)
            }
        }
        observeSettings()
        refreshFollowingDistance(fromFrame: false)
        // Compile/load the models in the background right away so they are ready when the camera starts.
        worker.loadModels()
    }

    // MARK: - Start / stop

    /// Starts the camera and recognition (asks for camera permission on first use).
    /// Calling it again while running is harmless (the app calls it on every mode switch and foreground).
    ///
    /// `processing: false` keeps the capture session running ("warm") without running the detector and clears the
    /// visible objects — used while the navigator is shown without the camera window, so switching back to the
    /// camera is instant. A later `start()` resumes the recognition on the next frame.
    ///
    /// The research CSV is not started here: it follows the trip recording (`TripRecorder`).
    func start(processing: Bool = true) {
        let wasProcessing = wantsRunning && wantsProcessing
        wantsRunning = true
        wantsProcessing = processing
        if wasProcessing && !processing {
            pauseProcessing()
        }
        switch CameraService.authorizationStatus {
        case .authorized:
            cameraPermissionDenied = false
            startCamera()
        case .notDetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            Task { [weak self] in
                let granted = await CameraService.requestAccess()
                guard let self else { return }
                self.isRequestingPermission = false
                self.cameraPermissionDenied = !granted
                if granted && self.wantsRunning {
                    self.startCamera()
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

    /// Detector off, in-flight results dropped, visible objects cleared; the capture session keeps running.
    private func pauseProcessing() {
        worker.setActive(false)
        generation += 1
        worker.setGeneration(generation)
        clearVisibleState()
    }

    private func startCamera() {
        cameraError = nil
        pushSettings()
        pushLocation()
        worker.setActive(wantsProcessing)
        camera.start { [weak self] error in
            let message = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.cameraDidStart(errorMessage: message)
                }
            }
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
        worker.startRecording(modelName: detectorStatus.modelName ?? "no model", startedAt: started)
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
        guard output.generation == generation, wantsRunning, wantsProcessing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let displayed = displayTracks(from: output.tracks, now: now)
        // Avoid invalidating the overlay when nothing changed (e.g. an empty road).
        if tracks != displayed { tracks = displayed }
        if visibleCounts != output.visibleCounts { visibleCounts = output.visibleCounts }
        if uniqueCounts != output.uniqueCounts { uniqueCounts = output.uniqueCounts }
        if abs(fps - output.fps) >= 0.5 { fps = output.fps }
        if abs(inferenceMs - output.inferenceMs) >= 1 { inferenceMs = output.inferenceMs }
        if frameSize != output.frameSize { frameSize = output.frameSize }
        if abs(corridorCenterX - output.corridor.centerX) >= 0.003 { corridorCenterX = output.corridor.centerX }
        if horizonInUse != output.horizonY { horizonInUse = output.horizonY }
        // Remember the measured horizon for the next start (per frame orientation; 0 = none stored).
        if settings.autoHorizonEnabled, let measured = output.measuredHorizon {
            if output.measuredHorizonIsLandscape {
                if abs(settings.autoHorizonLandscape - measured) > 0.005 { settings.autoHorizonLandscape = measured }
            } else if abs(settings.autoHorizonPortrait - measured) > 0.005 {
                settings.autoHorizonPortrait = measured
            }
        }
        if currentLightColor != output.lightColor {
            currentLightColor = output.lightColor
            signals.cameraLightColor = output.lightColor
        }
        processedFrames = output.processedFrames
        var lead = settings.followingDistanceEnabled ? output.leadVehicle : nil
        if lead != nil {
            lastLeadUptime = now
        } else if settings.followingDistanceEnabled, let held = leadVehicle, now - lastLeadUptime < Self.leadHoldSeconds {
            lead = held   // bridge a few frames without the lead (missed detection) instead of blinking the line/HUD
        }
        if leadVehicle != lead { leadVehicle = lead }
        var hazards = assist.pedestrianWarningsEnabled ? output.pedestrianHazards : []
        if !hazards.isEmpty {
            lastPedestrianUptime = now
        } else if assist.pedestrianWarningsEnabled, now - lastPedestrianUptime < Self.pedestrianHoldSeconds {
            hazards = pedestrianHazards
        }
        if pedestrianHazards != hazards { pedestrianHazards = hazards }
        var staff = assist.pedestrianWarningsEnabled ? output.roadStaff : []
        if !staff.isEmpty {
            lastRoadStaffUptime = now
        } else if assist.pedestrianWarningsEnabled, now - lastRoadStaffUptime < Self.pedestrianHoldSeconds {
            staff = roadStaff
        }
        if roadStaff != staff { roadStaff = staff }
        if roadwayZone != output.roadwayZone { roadwayZone = output.roadwayZone }
        refreshFollowingDistance(fromFrame: true)
        updateDriverAssist(output, now: now)
    }

    /// Lane departure, coaching cues and camera-based driving events for one processed frame.
    private func updateDriverAssist(_ output: RecognitionWorker.Output, now: TimeInterval) {
        let speed = location.speedKmh
        let estimate = assist.laneDetectionNeeded ? output.laneEstimate : nil
        if laneEstimate != estimate { laneEstimate = estimate }

        // Lane departure: evaluated once per new lane estimate.
        var departure: LaneSide?
        if assist.laneDepartureEnabled, let estimate {
            if estimate.timestamp != lastLaneTimestamp {
                lastLaneTimestamp = estimate.timestamp
                laneDeparture.config.minSpeedKmh = assist.laneWarningMinSpeedKmh
                departure = laneDeparture.update(estimate, speedKmh: speed, timestamp: now)
                if departure != nil { lastLaneDepartureUptime = now }
            }
        } else {
            laneDeparture.reset()
            lastLaneTimestamp = nil
        }
        // Keep the red line visible a moment after the warning even if the estimate jitters back.
        let side = laneDeparture.activeSide
            ?? (now - lastLaneDepartureUptime < 1.5 ? laneDepartureSide : nil)
        if laneDepartureSide != side { laneDepartureSide = side }

        let following = settings.followingDistanceEnabled
        let assessment = following ? followingAssessment : nil
        let fresh = output.tracks.filter { $0.missed == 0 }

        if let onAssistFrame {
            let coach = CoachFrameInput(timestamp: now, speedKmh: speed, assessment: assessment,
                                        hasLead: leadVehicle != nil, collisionWarning: isForwardCollisionWarning,
                                        laneDeparture: departure, light: output.observedLight)
            let stopIDs = fresh.filter { $0.kind == .stopSign && $0.isConfirmed }.map(\.id)
            onAssistFrame(DriverAssistFrame(coach: coach, confirmedStopSignIDs: stopIDs))
        }

        let geometry = CameraGeometry(horizontalFOVDegrees: camera.horizontalFieldOfView,
                                      imageWidth: Double(frameSize.width), imageHeight: Double(frameSize.height))
        let input = CameraEventInput(timestamp: now, date: Date(), speedKmh: speed, coordinate: location.coordinate,
                                     assessment: assessment, hasLead: leadVehicle != nil,
                                     collisionWarning: isForwardCollisionWarning,
                                     collisionThresholdSeconds: settings.followingDistancePolicy.collisionWarningSeconds,
                                     laneDeparture: departure, laneOffset: estimate?.egoOffset,
                                     tracks: fresh, geometry: geometry,
                                     pedestrianHazards: assist.pedestrianWarningsEnabled ? output.pedestrianHazards : [],
                                     roadStaff: assist.pedestrianWarningsEnabled ? output.roadStaff : [])
        let events = eventMonitor.update(input)
        if let onDrivingEvent {
            for event in events { onDrivingEvent(event) }
        }
    }

    /// Current tracks plus confirmed tracks missed for at most `trackHoldSeconds` (marked `missed ≥ 1`).
    /// Low-score traffic lights without a readable colour are not drawn (`TrafficLightSelection.isDisplayable`).
    private func displayTracks(from all: [TrackedObject], now: TimeInterval) -> [TrackedObject] {
        let lightThreshold = DetectionThresholds.threshold(for: .trafficLight, global: settings.detectionConfidence)
        let fresh = all.filter { TrafficLightSelection.isDisplayable($0, classThreshold: lightThreshold) }
        var result = fresh
        var freshIDs = Set<Int>()
        for track in fresh {
            freshIDs.insert(track.id)
            // Tracks coasted by the tracker (`missed ≥ 1`, predicted box) are drawn as they come but do not restart
            // the hold time: the hold runs from the last real detection.
            if track.missed == 0 { recentTracks[track.id] = (track, now) }
        }
        for (id, entry) in recentTracks where !freshIDs.contains(id) {
            if entry.track.isConfirmed, now - entry.seen <= Self.trackHoldSeconds {
                var held = entry.track
                held.missed = max(1, held.missed)
                result.append(held)
            } else {
                recentTracks[id] = nil
            }
        }
        return result
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
        recentTracks.removeAll()
        lastLeadUptime = -.infinity
        lastPedestrianUptime = -.infinity
        lastRoadStaffUptime = -.infinity
        if !tracks.isEmpty { tracks = [] }
        if !visibleCounts.isEmpty { visibleCounts = [:] }
        if fps != 0 { fps = 0 }
        if currentLightColor != nil {
            currentLightColor = nil
            signals.cameraLightColor = nil
        }
        if leadVehicle != nil { leadVehicle = nil }
        if corridorCenterX != 0.5 { corridorCenterX = 0.5 }
        if laneEstimate != nil { laneEstimate = nil }
        if laneDepartureSide != nil { laneDepartureSide = nil }
        if !pedestrianHazards.isEmpty { pedestrianHazards = [] }
        if !roadStaff.isEmpty { roadStaff = [] }
        if roadwayZone != nil { roadwayZone = nil }
        laneDeparture.reset()
        lastLaneTimestamp = nil
        eventMonitor.reset()
        warnings.reset()
        refreshFollowingDistance(fromFrame: false)
    }

    // MARK: - Following distance

    /// Recomputes the assessment (and, for camera frames, feeds the warning controller).
    private func refreshFollowingDistance(fromFrame: Bool) {
        guard settings.followingDistanceEnabled else {
            if leadVehicle != nil { leadVehicle = nil }
            if followingAssessment != nil { followingAssessment = nil }
            if isForwardCollisionWarning { isForwardCollisionWarning = false }
            warnings.reset()
            return
        }
        let surface = resolveRoadSurface()
        if roadSurface != surface.condition { roadSurface = surface.condition }
        if roadSurfaceSource != surface.source { roadSurfaceSource = surface.source }

        let policy = settings.followingDistancePolicy
        let lead = leadVehicle
        let assessment = FollowingDistanceCalculator.assess(
            distanceMeters: lead?.distanceMeters, ownSpeedKmh: location.speedKmh,
            relativeSpeedKmh: lead?.relativeSpeedKmh, policy: policy, condition: surface.condition)
        if followingAssessment != assessment { followingAssessment = assessment }

        let collision = lead != nil && DistanceWarningController.isForwardCollision(assessment, policy: policy)
        if isForwardCollisionWarning != collision { isForwardCollisionWarning = collision }

        if fromFrame {
            lastFrameRefreshUptime = ProcessInfo.processInfo.systemUptime
            warnings.evaluate(assessment, leadID: lead?.trackID, policy: policy,
                              enabled: settings.distanceWarningsEnabled)
        }
    }

    /// "auto" → guessed from the current weather (dry when unknown); otherwise the manual surface.
    private func resolveRoadSurface() -> (condition: RoadSurfaceCondition, source: RoadSurfaceSource) {
        let mode = settings.roadSurfaceMode
        if mode != "auto", let manual = RoadSurfaceCondition(rawValue: mode) {
            return (manual, .manual)
        }
        guard let weather = weatherProvider?() else { return (.dry, .noWeather) }
        let condition = RoadSurfaceCondition.from(weatherCode: weather.weatherCode, temperatureC: weather.temperatureC,
                                                  precipitationMm: weather.precipitationMm)
        return (condition, .weather)
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
        let followingEnabled = settings.followingDistanceEnabled
        let horizon = settings.corridorHorizon
        let autoHorizon = settings.autoHorizonEnabled
        let storedPortrait: Double? = settings.autoHorizonPortrait > 0 ? settings.autoHorizonPortrait : nil
        let storedLandscape: Double? = settings.autoHorizonLandscape > 0 ? settings.autoHorizonLandscape : nil
        let hood = settings.hoodLengthMeters
        let lanes = assist.laneDetectionNeeded
        let pedestrians = assist.pedestrianWarningsEnabled
        worker.update { inputs in
            inputs.laneDetectionEnabled = lanes
            inputs.pedestrianWarningsEnabled = pedestrians
            inputs.detection = options
            inputs.makeRecognitionEnabled = makeEnabled
            inputs.followingDistanceEnabled = followingEnabled
            inputs.corridorHorizon = horizon
            inputs.autoHorizonEnabled = autoHorizon
            inputs.storedHorizonPortrait = storedPortrait
            inputs.storedHorizonLandscape = storedLandscape
            inputs.cameraToBumperMeters = hood
        }
    }

    /// Re-pushes the recognition settings whenever one of them changes. Following-distance settings refresh the
    /// assessment right away. ("Record experiment log" no longer starts a recording here: the CSV follows the trip
    /// recording, see `TripRecorder`.)
    private func observeSettings() {
        withObservationTracking {
            _ = settings.detectionConfidence
            _ = settings.nmsIoUThreshold
            _ = settings.trackPedestrians
            _ = settings.detectTrafficLights
            _ = settings.makeRecognitionEnabled
            _ = settings.followingDistanceEnabled
            _ = settings.corridorHorizon
            _ = settings.autoHorizonEnabled
            _ = settings.hoodLengthMeters
            _ = settings.followingTimeGapDry
            _ = settings.stoppedGapMeters
            _ = settings.reactionTimeSeconds
            _ = settings.roadSurfaceMode
            _ = assist.laneDepartureEnabled
            _ = assist.showLaneOverlay
            _ = assist.pedestrianWarningsEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pushSettings()
                self.refreshFollowingDistance(fromFrame: false)
                self.observeSettings()
            }
        }
    }
}

/// Origin of `RecognitionPipeline.roadSurface`.
enum RoadSurfaceSource: String, Sendable {
    /// "auto": guessed from the current Open-Meteo weather.
    case weather
    /// "auto", but no weather is available yet → dry is assumed.
    case noWeather
    /// Chosen in Settings.
    case manual

    /// Short localized label for the surface chip.
    var localizedName: String {
        switch self {
        case .weather: return L("surfaceSource.auto")
        case .noWeather: return L("surfaceSource.noWeather")
        case .manual: return L("surfaceSource.manual")
        }
    }
}

/// A finished research log handed to a background queue for writing (exclusive ownership transfer).
private struct FinishedRecording: @unchecked Sendable {
    let log: ExperimentLog
    let uniqueCounts: [VehicleKind: Int]
}
