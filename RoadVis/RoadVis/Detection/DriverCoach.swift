import Foundation
import Observation
import UIKit

/// Per-frame cues the recognition pipeline hands to the coach (`RecognitionPipeline.onAssistFrame`).
struct DriverAssistFrame: Sendable {
    var coach: CoachFrameInput
    /// Confirmed STOP-sign tracks visible on this frame (announced once per track).
    var confirmedStopSignIDs: [Int]
}

/// Voice coach for beginner drivers: following distance, pedestrians on the roadway, traffic police officer / road works
/// ahead (vest-colour heuristic, 20 s per track), red / green traffic light, lane departure and road signs. A pedestrian danger (pedestrian in the own lane ahead) also gives a warning haptic.
///
/// Inputs: camera cues from `RecognitionPipeline` (every processed frame), own speed from `LocationService`, the current
/// road's speed limit (`RoadInfoService`) and — while navigating — the OSM features and speed limits along the route
/// (`NavigationService`). `DriverCoachEngine` + `CoachRules` decide when to speak (priorities, ≈ 3 s global gap,
/// per-topic cooldowns); the phrase is `VoicePhrase.coach(_:)` (natural-voice clips) with `coachText(_:language:)` as
/// the system-voice text in the app language ("rv.appLanguage").
///
/// Creating the coach takes over the distance voice warnings from `DistanceWarningController` (haptics / tone stay
/// there), so nothing is spoken twice. Usage (AppState, after all services exist):
/// ```swift
/// self.coach = DriverCoach(recognition: recognition, location: location, speech: speech,
///                          roadInfo: roadInfo, navigation: navigation, settings: settings)
/// ```
@Observable
@MainActor
final class DriverCoach {
    /// Last spoken message and when (for a HUD hint / debugging).
    private(set) var lastMessage: CoachMessage?
    private(set) var lastMessageDate: Date?

    /// True when the navigator already announces OSM hazards along the route itself (avoids double announcements).
    /// Default: while navigating with voice guidance on. Replace if the navigator stops announcing them.
    @ObservationIgnored var navigationAnnouncesRouteFeatures: (@MainActor () -> Bool)?

    @ObservationIgnored private let recognition: RecognitionPipeline
    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private let roadInfo: RoadInfoService
    @ObservationIgnored private let navigation: NavigationService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let assist: DriverAssistSettings
    @ObservationIgnored private let engine = DriverCoachEngine()
    @ObservationIgnored private let signs = SignAnnouncer()
    @ObservationIgnored private var locationListener: UUID?
    @ObservationIgnored private var lastRouteKey: String?
    /// Last pedestrian-danger haptic per pedestrian track (uptime).
    @ObservationIgnored private var pedestrianHaptics: [Int: TimeInterval] = [:]
    /// Same pedestrian track: at most one haptic per this many seconds.
    static let pedestrianHapticCooldown: TimeInterval = 6

    init(recognition: RecognitionPipeline, location: LocationService, speech: SpeechService,
         roadInfo: RoadInfoService, navigation: NavigationService, settings: AppSettings,
         assist: DriverAssistSettings? = nil) {
        self.recognition = recognition
        self.location = location
        self.speech = speech
        self.roadInfo = roadInfo
        self.navigation = navigation
        self.settings = settings
        self.assist = assist ?? DriverAssistSettings.shared
        navigationAnnouncesRouteFeatures = { [weak navigation, weak settings] in
            guard let navigation, let settings else { return false }
            return navigation.state == .navigating && settings.voiceGuidanceEnabled
        }

        recognition.voiceWarningsHandledByCoach = true
        recognition.onAssistFrame = { [weak self] frame in
            self?.handle(frame)
        }
        locationListener = location.addListener { [weak self] _ in
            self?.handleLocation()
        }
    }

    /// Forgets announced signs (e.g. a new trip).
    func resetAnnouncements() {
        signs.reset()
        engine.reset()
        pedestrianHaptics.removeAll()
    }

    // MARK: - Inputs

    private func handle(_ frame: DriverAssistFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        engine.toggles = currentToggles()
        var input = frame.coach
        input.timestamp = now
        engine.update(input)
        let hazards = assist.pedestrianWarningsEnabled ? recognition.pedestrianHazards : []
        engine.updatePedestrians(hazards, speedKmh: input.speedKmh, now: now)
        engine.updateRoadStaff(assist.pedestrianWarningsEnabled ? recognition.roadStaff : [], now: now)
        pedestrianHaptic(hazards, now: now)
        if engine.toggles.signs {
            for id in frame.confirmedStopSignIDs {
                if let event = signs.cameraStopSign(trackID: id, timestamp: now) {
                    engine.offerSign(event, now: now)
                }
            }
        }
        speakNext(now: now)
    }

    private func handleLocation() {
        let now = ProcessInfo.processInfo.systemUptime
        engine.toggles = currentToggles()
        let speed = location.speedKmh
        if engine.toggles.signs {
            if navigation.state == .navigating {
                let routeKey = navigation.selectedRouteID.map(String.init) ?? "-"
                if routeKey != lastRouteKey {
                    lastRouteKey = routeKey
                    signs.reset()
                }
                let along = navigation.distanceAlong
                if !(navigationAnnouncesRouteFeatures?() ?? false) {
                    let ahead = FeatureAhead.from(features: navigation.upcomingFeatures, distanceAlong: along)
                    if let event = signs.update(features: ahead, speedKmh: speed, timestamp: now) {
                        engine.offerSign(event, now: now)
                    }
                }
                if let event = signs.update(edges: navigation.routeEdges, distanceAlong: along, speedKmh: speed) {
                    engine.offerSign(event, now: now)
                }
            } else {
                lastRouteKey = nil
            }
            if let event = signs.update(currentLimitKmh: roadInfo.currentRoad?.speedLimit?.kmh, timestamp: now) {
                engine.offerSign(event, now: now)
            }
        }
        speakNext(now: now)
    }

    private func currentToggles() -> CoachToggles {
        let voice = assist.voiceCoachingEnabled
        return CoachToggles(distance: settings.followingDistanceEnabled && settings.distanceWarningsEnabled,
                            laneDeparture: voice && assist.laneDepartureEnabled,
                            signs: voice && assist.signAnnouncementsEnabled,
                            trafficLights: voice && assist.trafficLightHintsEnabled,
                            pedestrians: voice && assist.pedestrianWarningsEnabled,
                            roadStaff: voice && assist.pedestrianWarningsEnabled)
    }

    /// Warning haptic when a pedestrian danger appears (once per track per `pedestrianHapticCooldown`).
    private func pedestrianHaptic(_ hazards: [PedestrianHazard], now: TimeInterval) {
        pedestrianHaptics = pedestrianHaptics.filter { now - $0.value < Self.pedestrianHapticCooldown }
        guard let danger = hazards.first(where: { $0.level == .danger }),
              pedestrianHaptics[danger.trackID] == nil else { return }
        pedestrianHaptics[danger.trackID] = now
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - Output

    private func speakNext(now: TimeInterval) {
        // A message without any sound in the current mode (e.g. a sign announcement in "sounds only") must not
        // start the global gap: it would delay the tone of the next warning.
        let mode: SoundMode = SoundModeStore.shared.mode
        let next: CoachMessage? = engine.next(now: now, isAudible: { (candidate: CoachMessage) -> Bool in
            AlertToneKind.isAudible(candidate, in: mode)
        })
        guard let message = next else { return }
        let text = coachText(message, language: currentCoachLanguage())
        // Tone first (it also is the whole warning in the "sounds only" mode; `playAlertTone` checks the mode). The
        // distance tones (collision, keep distance) belong to `DistanceWarningController`, which runs on the same
        // frames — a second tone here would double up.
        let distanceOwned: Bool = message.category == .collision || message.category == .tailgating
        if !distanceOwned, let tone = AlertToneKind.kind(for: message) {
            speech.playAlertTone(tone)
        }
        let priority: SpeechPriority = Self.priority(message.urgency)
        // Only advice about the current moment (lane, distance) is stale after a few seconds of waiting; signs, road
        // staff and pedestrian cautions keep the default wait (a navigation prompt of 4–6 s must not swallow them).
        let maxAge: TimeInterval = message.maxSpeechWait(defaultWait: SpeechService.defaultMaxAge)
        speech.speak(VoicePhrase.coach(message, text: text), priority: priority, maxAge: maxAge)
        lastMessage = message
        lastMessageDate = Date()
    }

    static func priority(_ urgency: CoachUrgency) -> SpeechPriority {
        switch urgency {
        case .low: return .low
        case .normal: return .normal
        case .high: return .critical   // collision / pedestrian / red light: never cut off by navigation prompts
        }
    }
}
