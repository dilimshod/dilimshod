import Foundation

/// Spoken / shown phrases of turn guidance, grouped in one place for the later localization pass (Russian for now).
enum NavigationPhrases {
    /// Appended to the closest maneuver prompt (≤ 150 m).
    static let caution = "будьте осторожны"
    /// Appended as well when the own speed is above `slowDownSpeedKmh`.
    static let slowDown = "снизьте скорость"
    /// Speed above which the closest maneuver prompt asks to slow down, km/h.
    static let slowDownSpeedKmh: Double = 40
    /// Distance of the closest voice threshold, metres (VoicePromptScheduler default 100 m).
    static let closeDistance: Double = 150

    /// "через 100 метров поверните направо, будьте осторожны, снизьте скорость".
    /// Below 60 m the distance is left out ("Поверните направо, будьте осторожны").
    static func closeManeuver(instruction: String, distance: Double, speedKmh: Double?) -> String {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var phrase: String
        if distance >= 60 {
            phrase = "\(RVFormat.appSpokenDistance(distance)) \(VoicePromptScheduler.lowercasingFirst(text))"
        } else {
            phrase = text
        }
        phrase += ", \(caution)"
        if (speedKmh ?? 0) > slowDownSpeedKmh {
            phrase += ", \(slowDown)"
        }
        return phrase
    }
}
