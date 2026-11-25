import Foundation

/// Spoken / shown phrases of turn guidance in the app language (Uzbek Latin, Russian, English).
enum NavigationPhrases {
    /// Appended to the closest maneuver prompt (≤ 150 m).
    static var caution: String { L("voice.caution") }
    /// Appended as well when the own speed is above `slowDownSpeedKmh`.
    static var slowDown: String { L("voice.slowDown") }
    /// Speed above which the closest maneuver prompt asks to slow down, km/h.
    static let slowDownSpeedKmh: Double = 40
    /// Distance of the closest voice threshold, metres (VoicePromptScheduler default 100 m).
    static let closeDistance: Double = 150

    /// "100 metrdan keyin o‘ngga buriling, ehtiyot bo‘ling, tezlikni pasaytiring" (uz) /
    /// "через 100 метров поверните направо, будьте осторожны, снизьте скорость" (ru).
    /// Below 60 m the distance is left out ("O‘ngga buriling, ehtiyot bo‘ling").
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
