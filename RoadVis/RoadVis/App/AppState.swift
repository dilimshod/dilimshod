import Foundation
import Observation
import SwiftUI
import UIKit

enum AppMode: String {
    /// Full-screen camera with vehicle recognition.
    case camera
    /// Full-screen map navigator.
    case navigator
}

/// Root object graph: creates every service once and wires them together.
@Observable
@MainActor
final class AppState {
    var mode: AppMode = .camera
    var showSettings = false
    /// Trip report shown over everything (after a recording stops, or opened from the history).
    var presentedTrip: Trip?
    /// Trip history sheet (navigator idle screen).
    var showTripHistory = false
    /// About / offer / developers sheet (navigator idle screen).
    var showAbout = false
    /// QR login on the RoadVis website, opened from the navigator idle screen (`QRLoginFlowView`).
    var showQRLogin = false

    let settings: AppSettings
    let location: LocationService
    let speech: SpeechService
    let roadInfo: RoadInfoService
    let weather: WeatherService
    let signals: TrafficSignalService
    let incidents: IncidentStore
    let navigation: NavigationService
    let recognition: RecognitionPipeline
    let trips: TripStore
    let tripRecorder: TripRecorder
    /// Voice coach for beginner drivers (distance, lights, signs, lane departure).
    let coach: DriverCoach
    /// Continuous learning: hard-frame collection, uploads to the RoadVis Trainer, improved-model downloads.
    let learning: LearningCoordinator
    /// Driver cabinet: registration, automatic trip upload, QR login on the website (`docs/CABINET_API.md`).
    let cabinet: CabinetService

    @ObservationIgnored private var started = false
    /// Stops the warm camera after `cameraStandbyTimeout` in the navigator without the camera window.
    @ObservationIgnored private var cameraStandbyTask: Task<Void, Never>?
    /// 1 Hz check that starts / stops the background trip recording (`autoTripTick`).
    @ObservationIgnored private var autoTripTask: Task<Void, Never>?
    @ObservationIgnored private var movingSince: Date?
    /// Standing-still / GPS-outage timers of the automatic trip stop (thresholds: `TripStandstillTimer` defaults —
    /// ≤ 3 km/h for 180 s, or 900 s without any valid GPS speed).
    @ObservationIgnored private var standstill = TripStandstillTimer()
    /// True when the current trip recording was started by the driving detector (not «Поехали» / Settings).
    @ObservationIgnored private var autoStartedTrip = false

    /// How long the capture session stays warm (running, no inference) in the navigator without the camera window.
    static let cameraStandbyTimeout: Duration = .seconds(60)
    /// Background trip recording: own speed ≥ `autoTripStartSpeedKmh` for `autoTripStartSeconds` on the camera
    /// screen starts a trip; standing still ends it (`TripStandstillTimer`).
    static let autoTripStartSpeedKmh: Double = 10
    static let autoTripStartSeconds: TimeInterval = 10
    /// Last app-wide lifecycle state handled by `handleScenePhase` (dedupes per-scene / repeated notifications).
    @ObservationIgnored private var handledPhase: ScenePhase?
    /// > 0 while another camera user (the QR scanner) needs the back camera: the recognition session stays stopped.
    @ObservationIgnored private var cameraSuspensions = 0

    init() {
        let settings = AppSettings()
        let location = LocationService()
        let speech = SpeechService()
        let roadInfo = RoadInfoService(location: location, settings: settings)
        let weather = WeatherService(location: location)
        let signals = TrafficSignalService(location: location, roadInfo: roadInfo, settings: settings)
        let incidents = IncidentStore(settings: settings)
        let navigation = NavigationService(location: location, speech: speech, roadInfo: roadInfo,
                                           signals: signals, incidents: incidents, settings: settings)
        let recognition = RecognitionPipeline(location: location, settings: settings, signals: signals)
        let trips = TripStore()
        let tripRecorder = TripRecorder(location: location, roadInfo: roadInfo, navigation: navigation,
                                        recognition: recognition, settings: settings, store: trips)

        self.settings = settings
        self.location = location
        self.speech = speech
        self.roadInfo = roadInfo
        self.weather = weather
        self.signals = signals
        self.incidents = incidents
        self.navigation = navigation
        self.recognition = recognition
        self.trips = trips
        self.tripRecorder = tripRecorder
        self.coach = DriverCoach(recognition: recognition, location: location, speech: speech,
                                 roadInfo: roadInfo, navigation: navigation, settings: settings)
        let learning = LearningCoordinator(recognition: recognition, location: location)
        self.learning = learning
        tripRecorder.onStarted = { [weak learning] in
            learning?.tripStarted()
        }
        let cabinet = CabinetService(learningSettings: learning.settings, trips: trips)
        self.cabinet = cabinet
        tripRecorder.onFinished = { [weak cabinet] trip in
            cabinet?.tripFinished(trip)
        }

        recognition.weatherProvider = { [weak weather] in weather?.current }
        recognition.speech = speech
        recognition.onDrivingEvent = { [weak tripRecorder] event in
            tripRecorder?.ingest(event)
        }
        navigation.onStateChange = { [weak self] old, new in
            self?.navigationStateChanged(from: old, to: new)
        }
        // Uploads never run while the camera screen is on screen in the foreground.
        learning.isCameraActive = { [weak self] in
            guard let self else { return false }
            return self.mode == .camera && UIApplication.shared.applicationState != .background
        }
    }

    /// Called once when the root view appears.
    func start() {
        guard !started else { return }
        started = true
        location.requestPermission()
        location.start()
        roadInfo.start()
        weather.start()
        signals.start()
        trips.load()
        updateCameraForMode()
        startAutoTripMonitor()
        learning.start()
        cabinet.start()
        // The first didBecomeActive notification can fire before the root view subscribes.
        if UIApplication.shared.applicationState != .background {
            handleScenePhase(.active)
        }
    }

    /// Switches between the recognition screen and the navigator. Both screens stay mounted in `RootView`, so this
    /// is only a 0.2 s crossfade plus (un)pausing the detector — the camera session keeps running.
    func switchTo(_ newMode: AppMode) {
        guard newMode != mode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = newMode
        }
        updateCameraForMode()
        if newMode == .navigator {
            learning.enteredNavigator()
        } else {
            learning.enteredCamera()
        }
    }

    func toggleMode() {
        switchTo(mode == .camera ? .navigator : .camera)
    }

    /// Hands the back camera to another capture session (the QR scanner): the recognition session is stopped until
    /// the matching `resumeRecognitionCamera()`. Calls nest.
    func suspendRecognitionCamera() {
        cameraSuspensions += 1
        updateCameraForMode()
    }

    /// Ends a `suspendRecognitionCamera()`; the recognition camera comes back as the current mode requires.
    func resumeRecognitionCamera() {
        guard cameraSuspensions > 0 else { return }
        cameraSuspensions -= 1
        guard cameraSuspensions == 0, handledPhase != .background else { return }
        updateCameraForMode()
    }

    /// True while the recognition capture session is still running (the scanner waits for it to stop).
    var isRecognitionCameraRunning: Bool { recognition.camera.isRunning }

    /// Recognition runs in camera mode, and in navigator mode when the picture-in-picture window is enabled.
    /// In the navigator without the camera window the capture session is kept warm (running, detector paused) for
    /// `cameraStandbyTimeout`, so returning to the camera is instant; after that the camera is stopped. The session
    /// is always stopped in the background (`handleScenePhase`).
    func updateCameraForMode() {
        cameraStandbyTask?.cancel()
        cameraStandbyTask = nil
        if cameraSuspensions > 0 {
            recognition.stop()
            return
        }
        let needsRecognition = mode == .camera || settings.showCameraPiP
        if needsRecognition {
            recognition.start()
            return
        }
        recognition.start(processing: false)
        cameraStandbyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cameraStandbyTimeout)
            guard !Task.isCancelled, let self else { return }
            if self.mode == .navigator && !self.settings.showCameraPiP {
                self.recognition.stop()
            }
        }
    }

    /// App-wide lifecycle (camera, GPS, idle timer). Driven by UIApplication notifications, not per-scene
    /// `scenePhase`, and deduplicated so several scenes / repeated notifications act only once per change.
    func handleScenePhase(_ phase: ScenePhase) {
        guard phase != .inactive, phase != handledPhase else { return }
        handledPhase = phase
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            location.start()
            if started {
                updateCameraForMode()
                learning.appBecameActive()
                cabinet.appBecameActive()
            }
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            cameraStandbyTask?.cancel()
            cameraStandbyTask = nil
            recognition.stop()
            signals.persistNow()
            learning.appEnteredBackground()
            movingSince = nil
            standstill.reset()
            // A trip the driving detector started ends when the app leaves the screen (unless guidance runs).
            if tripRecorder.isRecording, autoStartedTrip, navigation.state != .navigating {
                stopTripRecording(presentReport: false)
            } else {
                // A recording that goes on in the background must have background GPS (no-op when not recording).
                tripRecorder.keepBackgroundUpdatesIfNeeded()
            }
            // Keep GPS only while actively navigating or recording a trip (background location mode).
            if navigation.state != .navigating && !tripRecorder.isRecording {
                location.stop()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Drive & trips

    /// «Поехали»: starts guidance on the selected route, collapses the navigator to the camera screen (guidance
    /// continues by voice + the mini banner) and, when «Фоновая запись поездок» is on, starts a trip recording.
    func startDrive() {
        navigation.startNavigation()
        guard navigation.state == .navigating else { return }
        if tripRecorder.isRecording {
            // A trip the driving detector started becomes the trip of this navigation (arrival ends it and opens
            // the report); a manual recording from Settings stays independent.
            if autoStartedTrip {
                tripRecorder.adoptNavigation()
                autoStartedTrip = false
            }
        } else if settings.tripAutoRecord {
            tripRecorder.start(withNavigation: true)
            autoStartedTrip = false
        }
        switchTo(.camera)
    }

    /// Manual trip recording (Settings → Поездки, trip history).
    func startTripRecording() {
        tripRecorder.start(withNavigation: navigation.state == .navigating)
        autoStartedTrip = false
    }

    /// Stops the recording and saves it to the trip history. `presentReport` opens its report (only after an
    /// arrival or an explicit stop in Settings — automatic stops are silent; nothing is shown without a track).
    func stopTripRecording(arrived: Bool = false, presentReport: Bool = true) {
        autoStartedTrip = false
        standstill.reset()
        guard tripRecorder.isRecording else { return }
        // Finalisation is asynchronous (CSV files, geocoding, file write) and often starts when the app goes to the
        // background: a UIKit background task keeps the process alive until the trip file is on disk.
        let background = BackgroundTaskHolder(name: "trip.finish")
        Task {
            let finished: Trip? = await tripRecorder.stop(arrived: arrived)
            await trips.flush()
            background.end()
            guard let trip = finished, presentReport else { return }
            showSettings = false
            showTripHistory = false
            presentedTrip = trip
        }
    }

    /// Arrival or cancelled guidance ends a recording that «Поехали» started (the report opens once after an
    /// arrival); a manual one keeps running.
    private func navigationStateChanged(from old: NavigationService.State, to new: NavigationService.State) {
        guard tripRecorder.isRecording else { return }
        switch new {
        case .arrived where tripRecorder.startedWithNavigation:
            stopTripRecording(arrived: true, presentReport: true)
        case .idle where old == .navigating && tripRecorder.startedWithNavigation:
            stopTripRecording(arrived: false, presentReport: false)
        default:
            tripRecorder.keepBackgroundUpdatesIfNeeded()
        }
    }

    // MARK: - Background trip recording

    private func startAutoTripMonitor() {
        autoTripTask?.cancel()
        autoTripTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.autoTripTick()
            }
        }
    }

    /// Own GPS speed, km/h; nil without a fix from the last 10 s or without a valid speed (GPS outage).
    private var currentSpeedKmh: Double? {
        guard let fix = location.location, Date().timeIntervalSince(fix.timestamp) < 10, fix.speed >= 0 else { return nil }
        return fix.speed * 3.6
    }

    /// Silent background recording (setting «Фоновая запись поездок», `tripAutoRecord`): driving with the camera screen
    /// open (≥ 10 km/h for 10 s, no trip running) starts a trip; a trip started this way or by «Поехали» ends after
    /// 3 min standing still (not during guidance — arrival ends those). A GPS outage is not "standing": without a
    /// valid speed the trip ends only after 15 min. Trips started in Settings stop only there.
    private func autoTripTick() {
        let now = Date()
        guard settings.tripAutoRecord, handledPhase == .active else {
            movingSince = nil
            standstill.reset()
            return
        }
        let speed: Double? = currentSpeedKmh
        if !tripRecorder.isRecording {
            standstill.reset()
            guard !tripRecorder.isFinishing, mode == .camera, let speed, speed >= Self.autoTripStartSpeedKmh else {
                movingSince = nil
                return
            }
            let since = movingSince ?? now
            movingSince = since
            if now.timeIntervalSince(since) >= Self.autoTripStartSeconds {
                movingSince = nil
                tripRecorder.start(withNavigation: navigation.state == .navigating)
                autoStartedTrip = tripRecorder.isRecording
            }
            return
        }
        movingSince = nil
        guard autoStartedTrip || tripRecorder.startedWithNavigation, navigation.state != .navigating else {
            standstill.reset()
            return
        }
        if standstill.update(now: now, speedKmh: speed) {
            stopTripRecording(presentReport: false)
        }
    }

    /// The app is about to be terminated (force-quit while not suspended): the running trip is written at once.
    func handleWillTerminate() {
        tripRecorder.flushOnTerminate()
    }
}

/// One UIKit background task (`beginBackgroundTask`): keeps the app running for a short piece of work after it went
/// to the background. `end()` is idempotent; the system's expiration handler ends it too.
@MainActor
final class BackgroundTaskHolder {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let finished: UIBackgroundTaskIdentifier = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(finished)
    }
}
