import SwiftUI
import UIKit

/// Switches between the full-screen recognition view and the navigator.
struct RootView: View {
    @Environment(AppState.self) private var app

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
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $app.showTripHistory) {
            TripHistorySheet()
        }
        .sheet(isPresented: $app.showAbout) {
            AboutHubView()
                .preferredColorScheme(.dark)
        }
        .sheet(item: $app.presentedTrip) { trip in
            TripReportSheet(trip: trip)
        }
        .task {
            app.start()
        }
        // App-wide lifecycle: UIApplication notifications instead of per-scene scenePhase
        // (AppState dedupes, so multiple scenes don't double-handle a transition).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            app.handleScenePhase(.active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            app.handleScenePhase(.active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            app.handleScenePhase(.background)
        }
        .onChange(of: app.settings.showCameraPiP) { _, _ in
            app.updateCameraForMode()
        }
        .statusBarHidden(app.mode == .camera)
        .persistentSystemOverlays(.hidden)
        .appLocale()
    }
}
