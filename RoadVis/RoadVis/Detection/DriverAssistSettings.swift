import Foundation
import Observation
import SwiftUI

/// Settings of the beginner-driver assistant (voice coach, lane departure, sign announcements, traffic-light hints).
/// UserDefaults-backed, keys prefixed "rv.". One shared instance (`DriverAssistSettings.shared`).
///
/// The following-distance voice warnings keep their existing switch (`AppSettings.distanceWarningsEnabled`); the
/// "voice coaching" master switch covers the new topics (lanes, signs, traffic lights).
@Observable
@MainActor
final class DriverAssistSettings {
    static let shared = DriverAssistSettings()

    enum Keys {
        static let voiceCoachingEnabled = "rv.coachVoiceEnabled"
        static let laneDepartureEnabled = "rv.laneDepartureWarnings"
        static let showLaneOverlay = "rv.showLaneOverlay"
        static let signAnnouncementsEnabled = "rv.signAnnouncements"
        static let trafficLightHintsEnabled = "rv.trafficLightHints"
        static let laneWarningMinSpeedKmh = "rv.laneWarningMinSpeedKmh"
    }

    /// Master switch of the spoken coaching (lane, signs, traffic lights).
    var voiceCoachingEnabled: Bool { didSet { defaults.set(voiceCoachingEnabled, forKey: Keys.voiceCoachingEnabled) } }
    /// Lane-departure warnings (voice + red line + trip events).
    var laneDepartureEnabled: Bool { didSet { defaults.set(laneDepartureEnabled, forKey: Keys.laneDepartureEnabled) } }
    /// Draw the detected lane lines over the camera picture.
    var showLaneOverlay: Bool { didSet { defaults.set(showLaneOverlay, forKey: Keys.showLaneOverlay) } }
    /// Announce road signs / hazards (OSM along the route, speed-limit changes, camera STOP sign).
    var signAnnouncementsEnabled: Bool { didSet { defaults.set(signAnnouncementsEnabled, forKey: Keys.signAnnouncementsEnabled) } }
    /// "Red light ahead" / "green, you can go".
    var trafficLightHintsEnabled: Bool { didSet { defaults.set(trafficLightHintsEnabled, forKey: Keys.trafficLightHintsEnabled) } }
    /// Lane-departure warnings only at or above this GPS speed, km/h.
    var laneWarningMinSpeedKmh: Double { didSet { defaults.set(laneWarningMinSpeedKmh, forKey: Keys.laneWarningMinSpeedKmh) } }

    /// The lane detector runs when its result is used.
    var laneDetectionNeeded: Bool { laneDepartureEnabled || showLaneOverlay }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        voiceCoachingEnabled = bool(Keys.voiceCoachingEnabled, true)
        laneDepartureEnabled = bool(Keys.laneDepartureEnabled, true)
        showLaneOverlay = bool(Keys.showLaneOverlay, true)
        signAnnouncementsEnabled = bool(Keys.signAnnouncementsEnabled, true)
        trafficLightHintsEnabled = bool(Keys.trafficLightHintsEnabled, true)
        let speed = defaults.object(forKey: Keys.laneWarningMinSpeedKmh) == nil
            ? 40 : defaults.double(forKey: Keys.laneWarningMinSpeedKmh)
        laneWarningMinSpeedKmh = min(90, max(20, speed))
    }
}

/// Form sections of the driver assistant, to be embedded in the app's settings `Form`.
struct DriverAssistSettingsSection: View {
    @Bindable private var settings = DriverAssistSettings.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.voiceCoachingEnabled) {
                Label(L("assist.voice"), systemImage: "person.wave.2.fill")
            }
            Toggle(isOn: $settings.trafficLightHintsEnabled) {
                Label(L("assist.lights"),
                      systemImage: "light.beacon.max.fill")
            }
            .disabled(!settings.voiceCoachingEnabled)
            Toggle(isOn: $settings.signAnnouncementsEnabled) {
                Label(L("assist.signs"),
                      systemImage: "exclamationmark.triangle.fill")
            }
            .disabled(!settings.voiceCoachingEnabled)
        } header: {
            Text(l: "assist.title")
        } footer: {
            Text(l: "assist.footer")
        }

        Section {
            Toggle(isOn: $settings.laneDepartureEnabled) {
                Label(L("assist.laneWarnings"),
                      systemImage: "road.lanes")
            }
            Toggle(isOn: $settings.showLaneOverlay) {
                Label(L("assist.showLanes"), systemImage: "line.diagonal")
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(l: "assist.minSpeed")
                    Spacer()
                    Text(verbatim: "\(Int(settings.laneWarningMinSpeedKmh)) \(RVFormat.appKmh)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.laneWarningMinSpeedKmh, in: 20...90, step: 5)
            }
            .disabled(!settings.laneDepartureEnabled)
        } header: {
            Text(l: "assist.lanes.title")
        } footer: {
            Text(l: "assist.lanes.footer")
        }
    }
}
