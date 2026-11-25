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

    let settings: AppSettings
    let location: LocationService
    let speech: SpeechService
    let roadInfo: RoadInfoService
    let weather: WeatherService
    let signals: TrafficSignalService
    let incidents: IncidentStore
    let navigation: NavigationService
    let recognition: RecognitionPipeline

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

        self.settings = settings
        self.location = location
        self.speech = speech
        self.roadInfo = roadInfo
        self.weather = weather
        self.signals = signals
        self.incidents = incidents
        self.navigation = navigation
        self.recognition = recognition

        recognition.weatherProvider = { [weak weather] in weather?.current }
        recognition.speech = speech
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
            signals.persistNow()
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
}
