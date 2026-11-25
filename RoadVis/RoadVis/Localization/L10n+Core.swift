import Foundation

// Bridges the app language to RoadVisCore text (formatting, turn instructions), whose parameterless APIs stay Russian.

extension AppLanguage {
    /// The RoadVisCore language for this app language.
    var core: RVLang {
        switch self {
        case .uz: return .uz
        case .ru: return .ru
        case .en: return .en
        }
    }
}

extension RVLang {
    /// The current app language (`LocalizationManager.shared.language`).
    static var app: RVLang { LocalizationManager.shared.language.core }
}

extension RVFormat {
    /// `distance(_:)` in the app language: "350 m", "1,2 km" / "350 м" / "1.2 km".
    static func appDistance(_ meters: Double) -> String { distance(meters, language: .app) }
    /// `duration(_:)` in the app language: "12 daq" / "12 мин" / "12 min".
    static func appDuration(_ seconds: Double) -> String { duration(seconds, language: .app) }
    /// `spokenDistance(_:)` in the app language: "400 metrdan keyin" / "через 400 метров" / "In 400 metres".
    static func appSpokenDistance(_ meters: Double) -> String { spokenDistance(meters, language: .app) }
    /// Decimal with the app language's separator.
    static func appDecimal(_ value: Double, digits: Int) -> String { decimal(value, digits: digits, language: .app) }
    /// "м" / "m".
    static var appMeters: String { unitMeters(.app) }
    /// "с" / "s".
    static var appSeconds: String { unitSeconds(.app) }
    /// "км/ч" / "km/soat" / "km/h".
    static var appKmh: String { unitKmh(.app) }
}
