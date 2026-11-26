import SwiftUI

/// Circular frosted-glass icon button used on top of the camera picture and the map.
///
/// The visible circle has the requested `size`; the tappable area is never smaller than 52 pt so the
/// button stays easy to hit while driving.
struct GlassIconButton: View {
    let systemName: String
    let label: String
    let size: CGFloat
    let tint: Color
    let action: () -> Void

    /// Minimum hit area for in-car use.
    static let minimumHitSize: CGFloat = 52

    init(systemName: String, label: String, size: CGFloat = 52, tint: Color = .white, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            GlassIconLabel(systemName: systemName, size: size, tint: tint)
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// The visuals of `GlassIconButton` (frosted circle with an SF Symbol and the minimum hit area) without the
/// button — also the label of a `Menu` (e.g. the sound-mode menu of `VoiceMuteButton`).
struct GlassIconLabel: View {
    let systemName: String
    var size: CGFloat = 52
    var tint: Color = .white

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
            .frame(width: max(size, GlassIconButton.minimumHitSize), height: max(size, GlassIconButton.minimumHitSize))
            .contentShape(Rectangle())
    }
}

/// Button style that slightly shrinks and dims its label while pressed (no colour change, works on any background).
struct RVPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        Color.gray
        HStack(spacing: 20) {
            GlassIconButton(systemName: "gearshape.fill", label: L("common.settings")) {}
            GlassIconButton(systemName: "map.fill", label: L("common.navigator"), size: 68) {}
            GlassIconButton(systemName: "arrow.counterclockwise", label: L("common.reset"), size: 36, tint: .orange) {}
        }
    }
}
