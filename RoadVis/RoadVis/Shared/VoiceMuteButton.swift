import SwiftUI

/// Small round 🔊 button (camera screen and navigator). Tapping it opens a menu with the four sound modes:
/// all sounds and voice / sounds only / voice only / silent. The icon shows the current mode, the menu marks it
/// with a checkmark. The mode is persisted by `SoundModeStore` ("rv.soundMode") and shared with the two Settings
/// toggles (voice prompts, alert sounds).
struct VoiceMuteButton: View {
    @Environment(AppState.self) private var app
    @Bindable private var store = SoundModeStore.shared
    var size: CGFloat = RVTheme.HUD.button

    var body: some View {
        let mode: SoundMode = store.mode
        Menu {
            Section {
                Picker(selection: selection) {
                    ForEach(SoundMode.allCases) { (item: SoundMode) in
                        Label(L(item.titleKey), systemImage: item.systemImage).tag(item)
                    }
                } label: {
                    Text(verbatim: L("sound.mode"))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(verbatim: L("sound.mode"))
            }
        } label: {
            GlassIconLabel(systemName: mode.systemImage, size: size, tint: mode == .all ? Color.white : Color.orange)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(L("sound.mode"))
        .accessibilityValue(L(mode.titleKey))
        .animation(RVTheme.snappy, value: mode)
    }

    /// Writes through `SpeechService.soundMode` (the store): a mode without voice stops the current speech at once,
    /// a mode without tones stops the current tone.
    private var selection: Binding<SoundMode> {
        Binding(get: { store.mode }, set: { (newValue: SoundMode) in app.speech.soundMode = newValue })
    }
}
