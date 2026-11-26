import AVFoundation
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
            naturalVoiceRow
            Button {
                app.speech.speak(VoicePhrase.sample(text: L("language.voice.sample")), priority: .high)
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
                if let hint = downloadHint {
                    Text(verbatim: hint)
                }
            }
        }
    }

    private var voiceKind: SpeechVoiceKind {
        app.speech.voiceKind(for: localization.language)
    }

    /// Localized quality of the voice in use ("Premium" / "Enhanced" / "Standard"); nil when iOS picks the voice.
    private var qualityText: String? {
        guard let quality = app.speech.voiceQuality(for: localization.language) else { return nil }
        switch quality {
        case .premium: return L("language.voice.quality.premium")
        case .enhanced: return L("language.voice.quality.enhanced")
        default: return L("language.voice.quality.default")
        }
    }

    /// How to download a natural-sounding voice, shown unless a Premium voice is already used. Names the language
    /// of the voice actually speaking (e.g. Turkish for the approximate Uzbek voice).
    private var downloadHint: String? {
        let quality = app.speech.voiceQuality(for: localization.language)
        if quality == .premium { return nil }
        let code = app.speech.voiceDescription(for: localization.language)?.language
            ?? localization.language.voiceLanguageCode
        let base = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? code
        let name = Locale(identifier: localization.language.rawValue).localizedString(forLanguageCode: base) ?? code
        return L("language.voice.downloadHint", name)
    }

    /// Pre-recorded Microsoft Edge neural clips: how many phrases are bundled for the language, or how to add them.
    @ViewBuilder
    private var naturalVoiceRow: some View {
        let count = app.speech.naturalVoiceClipCount(for: localization.language)
        VStack(alignment: .leading, spacing: 4) {
            Text(l: "language.natural.title")
            Group {
                if count.installed > 0 {
                    Text(l: "language.natural.installed", count.installed, count.total)
                    Text(l: "language.natural.partial")
                } else {
                    Text(l: "language.natural.missing")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        if count.installed > 0 {
            Toggle(isOn: Binding(get: { app.speech.useNaturalVoice },
                                 set: { app.speech.useNaturalVoice = $0 })) {
                Text(l: "language.natural.toggle")
            }
        }
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
            if let qualityText {
                Text(l: "language.voice.quality", qualityText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
