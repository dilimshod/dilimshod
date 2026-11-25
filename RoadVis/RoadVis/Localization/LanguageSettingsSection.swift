import SwiftUI

/// Settings section: app language (uz / ru / en) + which voice speaks it. Embed in a `Form`
/// (e.g. `SettingsView`). Changing the language re-renders every view that uses `L(_:)` and switches the
/// voice of `SpeechService` (it reads the same `LocalizationManager.shared.language`).
struct LanguageSettingsSection: View {
    @Environment(AppState.self) private var app
    private var localization = LocalizationManager.shared

    var body: some View {
        @Bindable var localization = localization
        Section {
            Picker(selection: $localization.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            } label: {
                Label {
                    Text(l: "language.picker")
                } icon: {
                    Image(systemName: "globe")
                }
            }
            voiceRow
            Button {
                app.speech.speak(L("language.voice.sample"), priority: .high)
            } label: {
                Label {
                    Text(l: "language.voice.test")
                } icon: {
                    Image(systemName: "speaker.wave.2")
                }
            }
            .disabled(app.speech.isMuted)
        } header: {
            Text(verbatim: "\(L("language.title")) · Til · Язык · Language")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(l: "language.footer")
                if localization.language == .uz, voiceKind != .native {
                    Text(l: "language.voice.uzNote")
                }
            }
        }
    }

    private var voiceKind: SpeechVoiceKind {
        app.speech.voiceKind(for: localization.language)
    }

    @ViewBuilder
    private var voiceRow: some View {
        let description = app.speech.voiceDescription(for: localization.language)
        let voiceName = description.map { "\($0.name), \($0.language)" } ?? "—"
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l: "language.voice.label")
                Spacer()
                if voiceKind.isApproximate {
                    Text(l: "language.voice.approxBadge")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                        .foregroundStyle(.orange)
                }
            }
            Group {
                switch voiceKind {
                case .native:
                    Text(l: "language.voice.native", voiceName)
                case .approximateTurkish:
                    Text(l: "language.voice.approxTurkish", voiceName)
                case .approximateRussian:
                    Text(l: "language.voice.approxRussian", voiceName)
                case .systemDefault:
                    Text(l: "language.voice.systemDefault")
                }
            }
            .font(.footnote)
            .foregroundStyle(voiceKind.isApproximate ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
