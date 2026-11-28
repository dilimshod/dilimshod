import Foundation

/// The three UI / voice languages of RoadVis. Uzbek (Latin script) is the default.
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case uz, ru, en

    /// The language used on first launch and whenever the stored value is missing or unknown.
    static let defaultLanguage: AppLanguage = .uz
    /// UserDefaults key holding `rawValue` of the chosen language.
    static let storageKey = "rv.appLanguage"

    var id: String { rawValue }

    /// The language's own name (shown in the picker the same way in every UI language).
    var displayName: String {
        switch self {
        case .uz: return "O‘zbekcha"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// Short badge for compact UI ("UZ", "RU", "EN").
    var shortCode: String { rawValue.uppercased() }

    /// BCP-47 language of the spoken prompts. iOS ships no Uzbek system voice (see `SpeechService`),
    /// so for `.uz` this is the *preferred* code; `SpeechService` falls back to an approximate voice.
    var voiceLanguageCode: String {
        switch self {
        case .uz: return "uz-UZ"
        case .ru: return "ru-RU"
        case .en: return "en-US"
        }
    }

    /// Locale for number / date / measurement formatting (`.environment(\.locale, …)`, formatters).
    var localeIdentifier: String {
        switch self {
        case .uz: return "uz_Latn_UZ"
        case .ru: return "ru_RU"
        case .en: return "en_US"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    /// The string table for this language (Localization/Strings+uz/ru/en.swift).
    var strings: [String: String] {
        switch self {
        case .uz: return UzStrings.table
        case .ru: return RuStrings.table
        case .en: return EnStrings.table
        }
    }

    /// Reads the stored choice (default `.uz`).
    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? defaultLanguage
    }
}
