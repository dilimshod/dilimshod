import SwiftUI

@main
struct RoadVisApp: App {
    @State private var appState = AppState()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(appState)
                if showSplash {
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.06)))
                    .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
