import SwiftUI

/// The roadway / sidewalk boundary (`RoadwayZone`, heuristic) as two thin, subtle dashed white lines (0.35 opacity)
/// from the bottom of the picture toward the horizon. Persons whose feet are outside it (and who are not moving toward
/// it) are not recognised. Toggle: Settings → "Show roadway boundary" (`DriverAssistSettings.showRoadwayBoundary`).
/// Same aspect-fill mapping as the boxes; never takes touches.
struct RoadwayBoundaryOverlay: View {
    let zone: RoadwayZone
    let imageSize: CGSize

    static let opacity = 0.35
    static let lineWidth: CGFloat = 1.2

    var body: some View {
        GeometryReader { proxy in
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: proxy.size)
            let p = zone.polygon().map { mapping.point(x: $0.x, y: $0.y) }
            if p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), proxy.size.height > 0 {
                let top = UnitPoint(x: 0.5, y: min(1, max(0, p[1].y / proxy.size.height)))
                let bottom = UnitPoint(x: 0.5, y: min(1, max(0, p[0].y / proxy.size.height)))
                Path { path in
                    path.move(to: p[0])
                    path.addLine(to: p[1])
                    path.move(to: p[3])
                    path.addLine(to: p[2])
                }
                .stroke(LinearGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(Self.opacity)],
                                       startPoint: top, endPoint: bottom),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [7, 9]))
                .shadow(color: .black.opacity(0.25), radius: 1)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    ZStack {
        Color(white: 0.25).ignoresSafeArea()
        RoadwayBoundaryOverlay(zone: RoadwayZone(leftBottom: -0.3, leftTop: 0.44, rightBottom: 1.3, rightTop: 0.56,
                                                 horizonY: 0.42, source: .lanes),
                               imageSize: CGSize(width: 1080, height: 1920))
            .ignoresSafeArea()
    }
}
