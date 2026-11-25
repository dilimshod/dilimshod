import SwiftUI

/// Switches between the full-screen recognition view and the navigator.
struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        ZStack {
            Color.black.ignoresSafeArea()
            switch app.mode {
            case .camera:
                RecognitionView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            case .navigator:
                NavigatorView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .sheet(isPresented: $app.showAssistant) {
            AssistantView()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
        }
        .task {
            app.start()
        }
        .onChange(of: scenePhase) { _, phase in
            app.handleScenePhase(phase)
        }
        .onChange(of: app.settings.showCameraPiP) { _, _ in
            app.updateCameraForMode()
        }
        .onChange(of: app.settings.speechLocaleIdentifier) { _, newValue in
            app.speech.defaultLanguage = newValue
        }
        .statusBarHidden(app.mode == .camera)
        .persistentSystemOverlays(.hidden)
    }
}
