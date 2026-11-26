import SwiftUI

/// Small round button that mutes / unmutes all voice prompts (navigation and the driver coach).
struct VoiceMuteButton: View {
    @Environment(AppState.self) private var app
    var size: CGFloat = RVTheme.HUD.button

    var body: some View {
        let muted = app.speech.isMuted
        GlassIconButton(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        label: muted ? L("voice.unmute") : L("voice.mute"),
                        size: size,
                        tint: muted ? .orange : .white) {
            app.speech.isMuted.toggle()
        }
        .animation(RVTheme.snappy, value: muted)
    }
}
