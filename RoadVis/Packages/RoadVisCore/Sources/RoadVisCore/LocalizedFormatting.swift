import Foundation

/// Language of user-facing text produced by RoadVisCore (distances, durations, turn instructions).
/// Mirrors the app language (`AppLanguage` in the app target): Uzbek (Latin script), Russian, English.
/// The existing parameterless APIs (`RVFormat.distance(_:)`, `OSRM.instruction(...)`, …) stay Russian.
public enum RVLang: String, Sendable, CaseIterable, Codable {
    case uz, ru, en

    /// Valhalla `directions_options.language` for this language. Valhalla has no Uzbek narrative, so Uzbek
    /// requests English and the instructions are rebuilt from maneuver types (`NavInstructionText.valhalla`).
    public var valhallaLanguage: String {
        switch self {
        case .ru: return "ru-RU"
        case .en, .uz: return "en-US"
        }
    }

    /// True when the text Valhalla returns can be shown as is (otherwise it is rebuilt from maneuver types).
    public var usesValhallaNarrative: Bool { self != .uz }
}

extension RVFormat {
    /// Decimal with the language's separator: comma for Uzbek / Russian ("1,3"), point for English ("1.3").
    public static func decimal(_ value: Double, digits: Int, language: RVLang) -> String {
        let text = String(format: "%.\(digits)f", value)
        return language == .en ? text : text.replacingOccurrences(of: ".", with: ",")
    }

    /// "350 m" / "1,2 km" (uz), "350 м" / "1,2 км" (ru), "350 m" / "1.2 km" (en).
    public static func distance(_ meters: Double, language: RVLang) -> String {
        if language == .ru { return distance(meters) }
        guard meters.isFinite else { return "—" }
        let m = max(0, meters)
        if m < 1000 {
            let rounded = m < 100 ? (m / 10).rounded() * 10 : (m / 50).rounded() * 50
            if rounded >= 1000 { return "1 km" }
            return "\(Int(rounded)) m"
        }
        if m < 10_000 {
            return decimal(m / 1000, digits: 1, language: language) + " km"
        }
        return "\(Int((m / 1000).rounded())) km"
    }

    /// Spoken distance before a maneuver: "400 metrdan keyin" (uz), "через 400 метров" (ru), "In 400 metres" (en).
    public static func spokenDistance(_ meters: Double, language: RVLang) -> String {
        if language == .ru { return spokenDistance(meters) }
        let m = max(0, meters)
        if m < 1000 {
            let rounded = m < 100 ? max(10, (m / 10).rounded() * 10) : (m / 50).rounded() * 50
            if rounded < 1000 {
                let n = Int(rounded)
                return language == .uz ? "\(n) metrdan keyin" : "In \(n) metres"
            }
        }
        let km = (m / 100).rounded() / 10
        let number = km == km.rounded() ? "\(Int(km))" : decimal(km, digits: 1, language: language)
        if language == .uz { return "\(number) kilometrdan keyin" }
        return km == 1 ? "In 1 kilometre" : "In \(number) kilometres"
    }

    /// "45 s" / "12 daq" / "1 soat 05 daq" (uz), "45 с" / "12 мин" / "1 ч 05 мин" (ru), "45 s" / "12 min" / "1 h 05 min" (en).
    public static func duration(_ seconds: Double, language: RVLang) -> String {
        if language == .ru { return duration(seconds) }
        guard seconds.isFinite else { return "—" }
        let s = max(0, Int(seconds.rounded()))
        let minute = language == .uz ? "daq" : "min"
        let hour = language == .uz ? "soat" : "h"
        if s < 60 { return "\(s) s" }
        let totalMinutes = Int((Double(s) / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) \(minute)" }
        let h = totalMinutes / 60, m = totalMinutes % 60
        return "\(h) \(hour) " + String(format: "%02d", m) + " \(minute)"
    }

    /// Unit labels in the given language.
    public static func unitMeters(_ language: RVLang) -> String { language == .ru ? "м" : "m" }
    public static func unitKilometers(_ language: RVLang) -> String { language == .ru ? "км" : "km" }
    public static func unitSeconds(_ language: RVLang) -> String { language == .ru ? "с" : "s" }
    public static func unitKmh(_ language: RVLang) -> String {
        switch language {
        case .ru: return "км/ч"
        case .uz: return "km/soat"
        case .en: return "km/h"
        }
    }
}
