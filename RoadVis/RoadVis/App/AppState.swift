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

    @ObservationIgnored private var started = false
    /// Stops the warm camera after `cameraStandbyTimeout` in the navigator without the camera window.
    @ObservationIgnored private var cameraStandbyTask: Task<Void, Never>?
    /// 1 Hz check that starts / stops the background trip recording (`autoTripTick`).
    @ObservationIgnored private var autoTripTask: Task<Void, Never>?
    @ObservationIgnored private var movingSince: Date?
    @ObservationIgnored private var stationarySince: Date?
    /// True when the current trip recording was started by the driving detector (not «Поехали» / Settings).
    @ObservationIgnored private var autoStartedTrip = false

    /// How long the capture session stays warm (running, no inference) in the navigator without the camera window.
    static let cameraStandbyTimeout: Duration = .seconds(60)
    /// Background trip recording: own speed ≥ `autoTripStartSpeedKmh` for `autoTripStartSeconds` on the camera
    /// screen starts a trip; ≤ `autoTripStationarySpeedKmh` for `autoTripStopSeconds` ends it.
    static let autoTripStartSpeedKmh: Double = 10
    static let autoTripStartSeconds: TimeInterval = 10
    static let autoTripStationarySpeedKmh: Double = 3
    static let autoTripStopSeconds: TimeInterval = 180
    /// Last app-wide lifecycle state handled by `handleScenePhase` (dedupes per-scene / repeated notifications).
    @ObservationIgnored private var handledPhase: ScenePhase?

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

        recognition.weatherProvider = { [weak weather] in weather?.current }
        recognition.speech = speech
        recognition.onDrivingEvent = { [weak tripRecorder] event in
            tripRecorder?.ingest(event)
        }
        navigation.onStateChange = { [weak self] old, new in
            self?.navigationStateChanged(from: old, to: new)
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
    }

    func toggleMode() {
        switchTo(mode == .camera ? .navigator : .camera)
    }

    /// Recognition runs in camera mode, and in navigator mode when the picture-in-picture window is enabled.
    /// In the navigator without the camera window the capture session is kept warm (running, detector paused) for
    /// `cameraStandbyTimeout`, so returning to the camera is instant; after that the camera is stopped. The session
    /// is always stopped in the background (`handleScenePhase`).
    func updateCameraForMode() {
        cameraStandbyTask?.cancel()
        cameraStandbyTask = nil
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
            if started { updateCameraForMode() }
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            cameraStandbyTask?.cancel()
            cameraStandbyTask = nil
            recognition.stop()
            signals.persistNow()
            movingSince = nil
            stationarySince = nil
            // A trip the driving detector started ends when the app leaves the screen (unless guidance runs).
            if tripRecorder.isRecording, autoStartedTrip, navigation.state != .navigating {
                stopTripRecording(presentReport: false)
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
        if settings.tripAutoRecord, !tripRecorder.isRecording {
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
        stationarySince = nil
        Task {
            guard let trip = await tripRecorder.stop(arrived: arrived), presentReport else { return }
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

    /// Own GPS speed, km/h (0 without a fix from the last 10 s).
    private var currentSpeedKmh: Double {
        guard let fix = location.location, Date().timeIntervalSince(fix.timestamp) < 10, fix.speed >= 0 else { return 0 }
        return fix.speed * 3.6
    }

    /// Silent background recording (setting «Фоновая запись поездок», `tripAutoRecord`): driving with the camera screen
    /// open (≥ 10 km/h for 10 s, no trip running) starts a trip; a trip started this way or by «Поехали» ends after
    /// 3 min standing still (not during guidance — arrival ends those). Trips started in Settings stop only there.
    private func autoTripTick() {
        let now = Date()
        guard settings.tripAutoRecord, handledPhase == .active else {
            movingSince = nil
            stationarySince = nil
            return
        }
        let speed = currentSpeedKmh
        if !tripRecorder.isRecording {
            stationarySince = nil
            guard !tripRecorder.isFinishing, mode == .camera, speed >= Self.autoTripStartSpeedKmh else {
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
        guard autoStartedTrip || tripRecorder.startedWithNavigation, navigation.state != .navigating,
              speed <= Self.autoTripStationarySpeedKmh else {
            stationarySince = nil
            return
        }
        let since = stationarySince ?? now
        stationarySince = since
        if now.timeIntervalSince(since) >= Self.autoTripStopSeconds {
            stopTripRecording(presentReport: false)
        }
    }
}
