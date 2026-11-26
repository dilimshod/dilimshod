import SwiftUI
import UIKit

/// Hosts the full-screen recognition view and the navigator.
///
/// Both screens stay mounted in a `ZStack` (the hidden one has opacity 0, no hit testing and is hidden from
/// accessibility), so switching never re-creates the `MKMapView`, the OSM tile overlay or the camera preview layers
/// — it is a 0.2 s crossfade. Each screen gets `isActive` and skips its expensive per-frame work while hidden.
/// The navigator is mounted shortly after launch (or on the first switch) so the first camera frame is not delayed.
struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var navigatorMounted = false

    var body: some View {
        @Bindable var app = app
        let cameraActive = app.mode == .camera
        ZStack {
            Color.black.ignoresSafeArea()
            if navigatorMounted || !cameraActive {
                NavigatorView(isActive: !cameraActive)
                    .screenVisibility(!cameraActive)
            }
            RecognitionView(isActive: cameraActive)
                .screenVisibility(cameraActive)
        }
        .task {
            // Warm up the navigator (map view, tiles) in the background once the camera screen is up.
            try? await Task.sleep(for: .seconds(1.5))
            navigatorMounted = true
        }
        .onChange(of: app.mode) { _, _ in
            navigatorMounted = true
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

private extension View {
    /// Keeps a mounted screen alive while hidden: invisible, not tappable, hidden from VoiceOver, below the visible one.
    func screenVisibility(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isVisible ? 1 : 0)
    }
}
