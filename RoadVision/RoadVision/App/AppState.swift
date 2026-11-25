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
    var showAssistant = false
    var showSettings = false

    let settings: AppSettings
    let location: LocationService
    let speech: SpeechService
    let roadInfo: RoadInfoService
    let weather: WeatherService
    let signals: TrafficSignalService
    let incidents: IncidentStore
    let navigation: NavigationService
    let recognition: RecognitionPipeline
    let assistant: AssistantViewModel

    @ObservationIgnored private var started = false

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
        let assistant = AssistantViewModel(settings: settings, speech: speech)

        self.settings = settings
        self.location = location
        self.speech = speech
        self.roadInfo = roadInfo
        self.weather = weather
        self.signals = signals
        self.incidents = incidents
        self.navigation = navigation
        self.recognition = recognition
        self.assistant = assistant

        speech.defaultLanguage = settings.speechLocaleIdentifier
        assistant.contextProvider = { [weak self] in
            self?.drivingContext() ?? DrivingContext()
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
        updateCameraForMode()
    }

    /// Switches between the recognition screen and the navigator.
    func switchTo(_ newMode: AppMode) {
        guard newMode != mode else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            mode = newMode
        }
        updateCameraForMode()
    }

    func toggleMode() {
        switchTo(mode == .camera ? .navigator : .camera)
    }

    /// The camera runs in camera mode, and in navigator mode only when the picture-in-picture window is enabled.
    func updateCameraForMode() {
        let needsCamera = mode == .camera || settings.showCameraPiP
        if needsCamera {
            recognition.start()
        } else {
            recognition.stop()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            location.start()
            if started { updateCameraForMode() }
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            recognition.stop()
            // Keep GPS only while actively navigating (background location mode).
            if navigation.state != .navigating {
                location.stop()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Snapshot of the current driving situation for the AI assistant.
    func drivingContext() -> DrivingContext {
        var ctx = DrivingContext()
        ctx.localTime = Date()
        ctx.speedKmh = location.speedKmh
        if let road = roadInfo.currentRoad {
            ctx.roadName = road.name ?? road.ref
            ctx.speedLimitKmh = road.speedLimit?.kmh
            ctx.lanesInDirection = road.laneInfo.lanesInDirection
            ctx.totalLanes = road.laneInfo.totalLanes
        }
        ctx.destinationName = navigation.destinationName
        if let progress = navigation.progress {
            ctx.remainingDistanceMeters = progress.remainingDistance
            ctx.remainingTimeSeconds = progress.remainingTimeSeconds
            ctx.nextInstruction = progress.nextInstruction
        }
        ctx.trafficDelaySeconds = navigation.selectedRouteOption?.traffic?.delaySeconds
        if let progress = navigation.progress {
            let ahead = signals.totalExpectedWait(fromDistance: progress.distanceAlong)
            ctx.signalsAhead = ahead.count
            ctx.expectedSignalWaitSeconds = ahead.seconds
        }
        ctx.weatherSummary = weather.current?.summary
        ctx.vehiclesInView = recognition.visibleCounts
        ctx.uniqueVehiclesCounted = recognition.totalUniqueVehicles
        return ctx
    }
}
