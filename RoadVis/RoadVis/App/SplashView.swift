import SwiftUI

/// Animated logo shown at launch before the main interface.
/// The static iOS launch screen shows the same logo on the same navy background (Config/Info.plist → UILaunchScreen),
/// so the hand-off is seamless: the logo "pops", radar rings pulse from the camera lens, then the name fades in.
struct SplashView: View {
    /// Called when the animation is finished.
    var onFinished: () -> Void

    @State private var logoScale: CGFloat = 1.0
    @State private var ringProgress: CGFloat = 0
    @State private var titleVisible = false
    @State private var glow = false

    static let background = Color(red: 0.008, green: 0.098, blue: 0.255)   // asset color "LaunchBackground"
    private let logoSize: CGFloat = 240                                       // SplashLogo.png is 720 px @3x

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // Radar rings around the lens (lens centre ≈ 38 % from the top of the logo).
                    ForEach(0..<3, id: \.self) { i in
                        let p = max(0, min(1, ringProgress - CGFloat(i) * 0.18))
                        Circle()
                            .stroke(Color.cyan.opacity(0.55 * (1 - p)), lineWidth: 2)
                            .frame(width: 60 + 260 * p, height: 60 + 260 * p)
                            .offset(y: -logoSize * 0.12)
                    }
                    Image("SplashLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: logoSize, height: logoSize)
                        .shadow(color: .cyan.opacity(glow ? 0.45 : 0), radius: glow ? 28 : 0)
                        .scaleEffect(logoScale)
                }
                .frame(height: logoSize + 20)

                VStack(spacing: 6) {
                    Text("RoadVis")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text(L("splash.tagline"))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .opacity(titleVisible ? 1 : 0)
                .offset(y: titleVisible ? 0 : 14)
            }
        }
        .task {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { logoScale = 1.08 }
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { logoScale = 1.0 }
            withAnimation(.easeOut(duration: 1.3)) { ringProgress = 1.4 }
            withAnimation(.easeInOut(duration: 0.8).repeatCount(2, autoreverses: true)) { glow = true }
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeOut(duration: 0.5)) { titleVisible = true }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onFinished()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RoadVis")
    }
}
