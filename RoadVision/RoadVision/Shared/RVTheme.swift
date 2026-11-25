import SwiftUI

/// Design tokens of the camera HUD (also usable elsewhere): status and class colours, radii, strokes, materials,
/// typography and motion. Glanceable in a car: high-contrast colours on frosted glass, rounded digits that do not
/// jump (`monospacedDigit`), short smooth animations.
enum RVTheme {
    // MARK: Status colours (following distance)

    /// Gap OK — mint green.
    static let safe = Color(red: 0.19, green: 0.92, blue: 0.62)
    /// Gap shorter than recommended — amber.
    static let caution = Color(red: 1.0, green: 0.74, blue: 0.16)
    /// Dangerously close / closing fast — red.
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.27)
    /// No estimate.
    static let neutral = Color(white: 0.86)
    /// Brand accent (navigator button, links).
    static let accent = Color(red: 0.1, green: 0.48, blue: 1.0)
    /// Recording indicator.
    static let recording = Color(red: 1.0, green: 0.23, blue: 0.19)

    static func statusColor(_ status: DistanceStatus) -> Color {
        switch status {
        case .safe: return safe
        case .caution: return caution
        case .danger: return danger
        case .unknown: return neutral
        }
    }

    /// Two-tone gradient for fills (progress bar, lead bracket glow).
    static func statusGradient(_ status: DistanceStatus) -> LinearGradient {
        let base = statusColor(status)
        return LinearGradient(colors: [base.opacity(0.75), base], startPoint: .leading, endPoint: .trailing)
    }

    /// SF Symbol for a status.
    static func statusSymbol(_ status: DistanceStatus) -> String {
        switch status {
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        case .unknown: return "car.rear.fill"
        }
    }

    // MARK: Class colours (detection boxes)

    /// Box/label colour per object class (bright, distinguishable on a camera picture).
    static func kindColor(_ kind: VehicleKind) -> Color {
        switch kind {
        case .car: return Color(red: 0.25, green: 0.85, blue: 1.0)
        case .truck: return Color(red: 1.0, green: 0.6, blue: 0.15)
        case .bus: return Color(red: 1.0, green: 0.86, blue: 0.2)
        case .motorcycle: return Color(red: 1.0, green: 0.42, blue: 0.78)
        case .bicycle: return Color(red: 0.45, green: 1.0, blue: 0.55)
        case .person: return Color(red: 0.82, green: 0.68, blue: 1.0)
        case .trafficLight: return Color.white
        case .stopSign: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .other: return Color.gray
        }
    }

    /// Colour for a "Норма / Рекомендация / Настройка приложения" badge.
    static func normColor(_ status: FollowingDistanceNorms.Status) -> Color {
        switch status {
        case .norm: return accent
        case .recommendation: return safe
        case .appSetting: return Color(red: 0.7, green: 0.62, blue: 1.0)
        }
    }

    // MARK: Geometry

    enum Radius {
        static let box: CGFloat = 8
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let panel: CGFloat = 18
        static let card: CGFloat = 22
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let tentative: CGFloat = 1
        static let box: CGFloat = 1.5
        static let selected: CGFloat = 2
        static let lead: CGFloat = 2.5
    }

    enum Spacing {
        static let gutter: CGFloat = 16
        static let stack: CGFloat = 10
        static let tight: CGFloat = 6
    }

    /// Compact HUD metrics (premium dashcam style: small controls at the screen edges, the picture stays free).
    enum HUD {
        /// Visible size of round icon buttons on the camera screen (hit area stays ≥ 44 pt).
        static let button: CGFloat = 40
        /// Height of slim pills (distance, counters, road line).
        static let pill: CGFloat = 32
        /// Minimum tap target.
        static let hit: CGFloat = 44
        /// Edge gutter of the camera HUD.
        static let gutter: CGFloat = 12
        /// Widest box label before it truncates.
        static let maxLabelWidth: CGFloat = 170
        /// Opacity of the frosted material behind HUD elements (lower = more of the picture shows through).
        static let materialOpacity: Double = 0.78
    }

    // MARK: Materials

    /// Frosted glass used for every floating panel.
    static let glass: Material = .ultraThinMaterial
    /// Top-lit glass edge.
    static let glassEdge = LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.06)],
                                          startPoint: .top, endPoint: .bottom)
    static let shadow = Color.black.opacity(0.22)
    /// Shadow behind HUD text drawn without a plate.
    static let textShadow = Color.black.opacity(0.65)

    // MARK: Typography

    /// Rounded system font (all HUD text).
    static func font(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Motion

    /// Box / label movement between processed frames (≤ 15 Hz).
    static let trackMotion: Animation = .smooth(duration: 0.15)
    /// Appearance of a new box.
    static let springIn: Animation = .spring(duration: 0.42, bounce: 0.38)
    /// Changing numbers and panel layout.
    static let snappy: Animation = .snappy(duration: 0.28)
}

// MARK: - View helpers

extension View {
    /// Frosted-glass panel: material, optional status tint, top-lit edge and a soft shadow.
    func rvGlass(cornerRadius: CGFloat = RVTheme.Radius.card, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(RVGlassModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                 tint: tint, shadow: shadow))
    }

    /// Frosted-glass capsule (chips, labels).
    func rvGlassCapsule(tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(RVGlassModifier(shape: Capsule(style: .continuous), tint: tint, shadow: shadow))
    }

    /// Rounded font with non-jumping digits.
    func rvNumeric(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(RVTheme.font(size, weight: weight)).monospacedDigit()
    }

    /// Subtle dark shadow that keeps light text legible on the camera picture without an opaque plate.
    func rvTextShadow() -> some View {
        shadow(color: RVTheme.textShadow, radius: 2, x: 0, y: 1)
    }

    /// Gentle opacity pulse while `active` (lead bracket, danger line, collision vignette).
    func rvPulse(_ active: Bool, minOpacity: Double = 0.5, period: Double = 1.1) -> some View {
        modifier(RVPulseModifier(active: active, minOpacity: minOpacity, period: period))
    }
}

private struct RVGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(RVTheme.glass)
                        .opacity(RVTheme.HUD.materialOpacity)
                    if let tint {
                        shape.fill(tint.opacity(0.12))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(tint.map { AnyShapeStyle($0.opacity(0.5)) } ?? AnyShapeStyle(RVTheme.glassEdge),
                                   lineWidth: RVTheme.Stroke.hairline)
            }
            .shadow(color: shadow ? RVTheme.shadow : .clear, radius: 6, x: 0, y: 2)
    }
}

private struct RVPulseModifier: ViewModifier {
    let active: Bool
    let minOpacity: Double
    let period: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.opacity(phase ? 1 : minOpacity)
            } animation: { _ in
                .easeInOut(duration: period / 2)
            }
        } else {
            content
        }
    }
}

/// Small coloured status capsule ("Норма", "передний автомобиль" …).
struct RVBadge: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(RVTheme.font(11, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }
}
