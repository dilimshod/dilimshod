import SwiftUI
import UIKit

/// Colours and small shared views of the navigator (on top of `RVTheme`).
enum NavigatorStyle {
    // MARK: Speed limits (route strip, map colouring, legend)

    /// Colour of a posted speed limit: lower limits are warmer (attention), higher ones cooler; unknown = slate.
    static func speedLimitUIColor(_ kmh: Int?) -> UIColor {
        guard let kmh else { return UIColor(red: 0.55, green: 0.6, blue: 0.7, alpha: 1) }
        switch kmh {
        case ...30: return UIColor(red: 0.93, green: 0.26, blue: 0.3, alpha: 1)
        case ...50: return UIColor(red: 1.0, green: 0.58, blue: 0.16, alpha: 1)
        case ...70: return UIColor(red: 0.1, green: 0.48, blue: 1.0, alpha: 1)
        case ...90: return UIColor(red: 0.12, green: 0.72, blue: 0.82, alpha: 1)
        default: return UIColor(red: 0.2, green: 0.78, blue: 0.45, alpha: 1)
        }
    }

    static func speedLimitColor(_ kmh: Int?) -> Color { Color(uiColor: speedLimitUIColor(kmh)) }

    /// Legend entries of the speed-limit palette.
    static var speedLimitLegend: [(label: String, kmh: Int?)] { [
        ("≤30", 30), ("40–50", 50), ("60–70", 70), ("80–90", 90), ("≥100", 100), (L("common.noData"), nil),
    ] }

    // MARK: Features & timeline

    static func featureUIColor(_ kind: RouteFeatureKind) -> UIColor {
        switch kind {
        case .trafficSignals: return .systemOrange
        case .speedCamera: return .systemPurple
        case .school, .kindergarten: return .systemYellow
        case .pedestrianCrossing: return .systemBlue
        case .railwayCrossing: return .systemGray
        case .construction: return .systemOrange
        case .trafficCalming: return .systemBrown
        case .stopSign: return .systemRed
        case .giveWay: return .systemPink
        case .fuel: return .systemTeal
        case .parking: return .systemIndigo
        }
    }

    static func featureGlyphUIColor(_ kind: RouteFeatureKind) -> UIColor {
        kind == .school || kind == .kindergarten ? .black : .white
    }

    static func eventUIColor(_ kind: RouteTimelineKind) -> UIColor {
        switch kind {
        case .maneuver: return UIColor(red: 0.04, green: 0.5, blue: 0.33, alpha: 1)
        case .speedLimit(let kmh): return speedLimitUIColor(kmh)
        case .lanes: return .systemGray
        case .trafficSignal: return .systemOrange
        case .feature(let feature): return featureUIColor(feature)
        case .incident: return .systemRed
        case .destination: return .systemRed
        }
    }

    static func eventColor(_ kind: RouteTimelineKind) -> Color { Color(uiColor: eventUIColor(kind)) }

    static func congestionColor(_ level: CongestionLevel) -> Color {
        switch level {
        case .free: return RVTheme.safe
        case .light: return .yellow
        case .moderate: return RVTheme.caution
        case .heavy: return RVTheme.danger
        case .severe: return Color(red: 0.6, green: 0, blue: 0)
        }
    }

    static func sourceColor(_ source: RouteSource) -> Color {
        switch source {
        case .apple: return RVTheme.accent
        case .valhalla: return RVTheme.safe
        case .osrm: return Color(red: 0.7, green: 0.62, blue: 1.0)
        }
    }
}

/// Tiny outlined source label ("OSM", "Valhalla", "Apple").
struct SourceTag: View {
    let text: String
    var color: Color = .white.opacity(0.7)

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
            .foregroundStyle(color)
            .accessibilityLabel(L("nav.sourceA11y", text))
    }
}

/// Small coloured engine badge for route cards.
struct EngineBadge: View {
    let source: RouteSource

    var body: some View {
        RVBadge(text: source.badge, color: NavigatorStyle.sourceColor(source),
                systemImage: source == .apple ? "applelogo" : "globe")
    }
}

/// Horizontal speed-limit legend.
struct SpeedLimitLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(NavigatorStyle.speedLimitLegend.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(NavigatorStyle.speedLimitColor(entry.kmh))
                        .frame(width: 10, height: 5)
                    Text(entry.label)
                        .font(RVTheme.font(9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("nav.speedLimitColors"))
    }
}
