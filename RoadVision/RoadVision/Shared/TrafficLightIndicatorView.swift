import SwiftUI

/// Small traffic-light housing showing the colour estimated from the camera picture.
///
/// The colour comes from a pixel-hue heuristic smoothed over several frames, so it is an estimate:
/// `.unknown` lights are drawn with all lamps dimmed and a question mark.
struct TrafficLightIndicatorView: View {
    let color: TrafficLightColor
    /// Height of one lamp; the housing scales with it.
    let lampSize: CGFloat
    let showsCaption: Bool

    init(color: TrafficLightColor, lampSize: CGFloat = 16, showsCaption: Bool = true) {
        self.color = color
        self.lampSize = lampSize
        self.showsCaption = showsCaption
    }

    /// Display colour for a traffic-light state (unknown → grey).
    static func displayColor(for color: TrafficLightColor) -> Color {
        switch color {
        case .red: return Color(red: 1.0, green: 0.22, blue: 0.2)
        case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.1)
        case .green: return Color(red: 0.2, green: 0.95, blue: 0.45)
        case .unknown: return Color.gray
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: lampSize * 0.25) {
                lamp(.red)
                lamp(.yellow)
                lamp(.green)
            }
            .padding(lampSize * 0.3)
            .background(
                RoundedRectangle(cornerRadius: lampSize * 0.6, style: .continuous)
                    .fill(Color.black.opacity(0.75))
            )
            .overlay {
                if color == .unknown {
                    Text("?")
                        .font(.system(size: lampSize * 1.1, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            if showsCaption {
                Text(color.displayName)
                    .font(.system(size: max(10, lampSize * 0.7), weight: .semibold, design: .rounded))
                    .foregroundStyle(color == .unknown ? Color.white.opacity(0.7) : Self.displayColor(for: color))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Светофор: \(color.displayName.lowercased()) (оценка по камере)")
    }

    private func lamp(_ lampColor: TrafficLightColor) -> some View {
        let isOn = lampColor == color
        let base = Self.displayColor(for: lampColor)
        return Circle()
            .fill(isOn ? base : base.opacity(0.18))
            .frame(width: lampSize, height: lampSize)
            .shadow(color: isOn ? base.opacity(0.9) : .clear, radius: isOn ? lampSize * 0.45 : 0)
    }
}

/// Single coloured dot for very compact places (picture-in-picture, overlay chips).
struct TrafficLightDotView: View {
    let color: TrafficLightColor
    let size: CGFloat

    init(color: TrafficLightColor, size: CGFloat = 14) {
        self.color = color
        self.size = size
    }

    var body: some View {
        let fill = TrafficLightIndicatorView.displayColor(for: color)
        Circle()
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: max(1, size * 0.1)))
            .shadow(color: color == .unknown ? .clear : fill.opacity(0.9), radius: size * 0.4)
            .accessibilityLabel("Светофор: \(color.displayName.lowercased())")
    }
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()
        HStack(spacing: 24) {
            TrafficLightIndicatorView(color: .red)
            TrafficLightIndicatorView(color: .yellow)
            TrafficLightIndicatorView(color: .green, lampSize: 22)
            TrafficLightIndicatorView(color: .unknown)
            TrafficLightDotView(color: .green)
        }
    }
}
