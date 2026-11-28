import Foundation
import Observation

/// Holds the current app language. `@Observable`: any SwiftUI body that calls `L(_:)` reads `language`
/// and therefore re-renders automatically when the user picks another language.
///
/// The choice is persisted in UserDefaults under `AppLanguage.storageKey` ("rv.appLanguage", default "uz").
/// Posts `LocalizationManager.languageDidChange` (object: the new `AppLanguage`) after every change, for
/// non-SwiftUI code (e.g. caches of pre-built phrases).
@Observable
final class LocalizationManager: @unchecked Sendable {
    static let shared = LocalizationManager()
    static let languageDidChange = Notification.Name("rv.appLanguageDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
            NotificationCenter.default.post(name: Self.languageDidChange, object: language)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.language = AppLanguage.stored(in: defaults)
    }

    /// Locale for number / date formatting in the current language.
    var locale: Locale { language.locale }

    /// Localized string for `key` in `language` (falls back to English, then to the key itself).
    func string(_ key: String, in language: AppLanguage? = nil) -> String {
        let lang = language ?? self.language
        if let value = lang.strings[key] { return value }
        if let value = AppLanguage.en.strings[key] { return value }
        return key
    }

    /// Localized format string for `key` filled with `arguments` (`%@`, `%d`, `%.1f` …), using the language's locale.
    func format(_ key: String, in language: AppLanguage? = nil, _ arguments: [CVarArg]) -> String {
        let lang = language ?? self.language
        return String(format: string(key, in: lang), locale: lang.locale, arguments: arguments)
    }
}

/// Localized string for a stable English identifier key, e.g. `L("about.title")`.
/// Reads `LocalizationManager.shared.language`, so calling it inside a SwiftUI `body` keeps the view
/// in sync with the language setting.
func L(_ key: String) -> String {
    LocalizationManager.shared.string(key)
}

/// Localized format string, e.g. `L("voice.inMeters", 300)` with "%d metrdan keyin" in the table.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    LocalizationManager.shared.format(key, arguments)
}

/// Localized string in an explicit language (e.g. to build a spoken phrase for `SpeechService.language`).
func L(_ key: String, in language: AppLanguage) -> String {
    LocalizationManager.shared.string(key, in: language)
}
