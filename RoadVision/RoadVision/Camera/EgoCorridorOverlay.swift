import SwiftUI

/// Subtle translucent trapezoid of the own-lane corridor (`EgoCorridor.polygon`) that the lead vehicle is picked from:
/// a gradient fill fading toward the horizon, soft edge lines and a dashed centre line. Tinted with the status colour
/// (white when there is no lead). Uses the same aspect-fill mapping as the boxes; never takes touches.
struct EgoCorridorOverlay: View {
    let corridor: EgoCorridor
    let imageSize: CGSize
    var tint: Color = .white

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: size)
            let points = corridor.polygon.map { mapping.point(x: $0.x, y: $0.y) }
            if points.count == 4, size.height > 0 {
                // polygon: bottom-left, top-left (horizon), top-right (horizon), bottom-right
                let top = UnitPoint(x: 0.5, y: min(1, max(0, points[1].y / size.height)))
                let bottom = UnitPoint(x: 0.5, y: min(1, max(0, points[0].y / size.height)))
                ZStack {
                    Path { path in
                        path.addLines(points)
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(stops: [.init(color: tint.opacity(0), location: 0),
                                                 .init(color: tint.opacity(0.07), location: 0.45),
                                                 .init(color: tint.opacity(0.16), location: 1)],
                                         startPoint: top, endPoint: bottom))

                    Path { path in
                        path.move(to: points[0])
                        path.addLine(to: points[1])
                        path.move(to: points[3])
                        path.addLine(to: points[2])
                    }
                    .stroke(LinearGradient(colors: [tint.opacity(0), tint.opacity(0.55)], startPoint: top, endPoint: bottom),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    Path { path in
                        path.move(to: Self.midpoint(points[0], points[3]))
                        path.addLine(to: Self.midpoint(points[1], points[2]))
                    }
                    .stroke(LinearGradient(colors: [tint.opacity(0), tint.opacity(0.28)], startPoint: top, endPoint: bottom),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [8, 12]))
                }
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

#Preview {
    ZStack {
        Color(white: 0.2).ignoresSafeArea()
        EgoCorridorOverlay(corridor: .default, imageSize: CGSize(width: 1080, height: 1920), tint: RVTheme.safe)
            .ignoresSafeArea()
    }
}
