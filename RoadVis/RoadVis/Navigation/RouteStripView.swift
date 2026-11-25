import SwiftUI

/// Thin horizontal bar of the whole route coloured by speed-limit segments (Valhalla / OSM), with markers for
/// signals, cameras, schools, maneuvers, incidents and the current position; the part already driven is dimmed.
/// Without edge attributes the bar is one neutral colour.
struct RouteStripView: View {
    let totalDistance: Double
    let distanceAlong: Double
    let segments: [SpeedLimitSegment]
    let events: [RouteTimelineEvent]
    var showsPosition: Bool = true
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                bar(width: width)
                    .frame(height: height)
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                ForEach(markerEvents) { event in
                    marker(event)
                        .position(x: x(event.distanceAlongRoute, width: width), y: proxy.size.height / 2)
                }
                if showsPosition, totalDistance > 0 {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(RVTheme.accent, lineWidth: 3))
                        .frame(width: height + 6, height: height + 6)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .position(x: x(distanceAlong, width: width), y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: max(height + 10, 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func x(_ distance: Double, width: CGFloat) -> CGFloat {
        guard totalDistance > 0 else { return 0 }
        return CGFloat(min(1, max(0, distance / totalDistance))) * width
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(NavigatorStyle.speedLimitColor(nil).opacity(0.6))
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Rectangle()
                    .fill(NavigatorStyle.speedLimitColor(segment.limitKmh))
                    .frame(width: max(1, x(segment.end, width: width) - x(segment.start, width: width)))
                    .offset(x: x(segment.start, width: width))
            }
            if showsPosition {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: x(distanceAlong, width: width))
            }
        }
    }

    /// Only kinds that are meaningful at strip scale (limits/lanes are the colours themselves).
    private var markerEvents: [RouteTimelineEvent] {
        events.filter { event in
            switch event.kind {
            case .trafficSignal, .maneuver, .incident: return true
            case .feature(let kind): return [.speedCamera, .school, .kindergarten, .railwayCrossing].contains(kind)
            default: return false
            }
        }
    }

    @ViewBuilder
    private func marker(_ event: RouteTimelineEvent) -> some View {
        switch event.kind {
        case .maneuver:
            Capsule()
                .fill(Color.white)
                .frame(width: 2, height: height + 6)
        case .trafficSignal:
            Circle()
                .fill(NavigatorStyle.eventColor(event.kind))
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                .frame(width: 5, height: 5)
        default:
            Image(systemName: event.symbolName)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 12, height: 12)
                .background(NavigatorStyle.eventColor(event.kind), in: Circle())
        }
    }

    private var accessibilityText: String {
        let signals = events.filter { $0.kind == .trafficSignal && $0.distanceAlongRoute >= distanceAlong }.count
        let cameras = events.filter { $0.kind == .feature(.speedCamera) && $0.distanceAlongRoute >= distanceAlong }.count
        return L("strip.a11y", signals, cameras)
    }
}
