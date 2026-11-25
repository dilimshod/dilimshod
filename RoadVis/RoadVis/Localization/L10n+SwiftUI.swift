import SwiftUI

extension Text {
    /// `Text(l: "about.title")` — a localized, verbatim (not re-looked-up in a .strings catalog) text.
    init(l key: String) {
        self.init(verbatim: L(key))
    }

    /// `Text(l: "trip.distanceKm", 12.5)` — localized format string.
    init(l key: String, _ arguments: CVarArg...) {
        self.init(verbatim: LocalizationManager.shared.format(key, arguments))
    }
}

/// Applies the app language's locale to the environment (number / date formatting, `Text(date, style:)`,
/// `.formatted()`), and re-applies it when the language changes.
private struct AppLocaleModifier: ViewModifier {
    private let manager = LocalizationManager.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, manager.locale)
    }
}

extension View {
    /// Use once near the root (e.g. on `RootView()` and on sheets) to format numbers / dates in the app language.
    func appLocale() -> some View {
        modifier(AppLocaleModifier())
    }
}
