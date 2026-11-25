import SwiftUI

/// Subtle lane-marking lines from the lane detector (`LaneEstimate`, heuristic): thin, low opacity, fading toward the
/// horizon; the line on the side the car is drifting over turns red. Lines below `minConfidence` are hidden. Uses the
/// same aspect-fill mapping as the boxes; never takes touches.
struct LaneOverlay: View {
    let estimate: LaneEstimate
    let imageSize: CGSize
    var departureSide: LaneSide?
    var minConfidence: Double = 0.3

    var body: some View {
        GeometryReader { proxy in
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: proxy.size)
            ZStack {
                ForEach(LaneSide.allCases, id: \.self) { side in
                    if let line = estimate.line(side), estimate.confidence(side) >= minConfidence {
                        lanePath(line, mapping: mapping, size: proxy.size, side: side)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: departureSide)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lanePath(_ line: LaneLine, mapping: AspectFillMapping, size: CGSize, side: LaneSide) -> some View {
        let bottom = mapping.point(x: line.bottomX, y: line.bottomY)
        let top = mapping.point(x: line.topX, y: line.topY)
        let departing = departureSide == side
        let color = departing ? RVTheme.danger : Color.white
        let confidence = min(1, estimate.confidence(side))
        let opacity = departing ? 0.75 : 0.18 + 0.22 * confidence
        let start = UnitPoint(x: 0.5, y: size.height > 0 ? min(1, max(0, top.y / size.height)) : 0)
        let end = UnitPoint(x: 0.5, y: size.height > 0 ? min(1, max(0, bottom.y / size.height)) : 1)
        Path { path in
            path.move(to: bottom)
            path.addLine(to: top)
        }
        .stroke(LinearGradient(colors: [color.opacity(0), color.opacity(opacity)], startPoint: start, endPoint: end),
                style: StrokeStyle(lineWidth: departing ? 3 : 2, lineCap: .round))
        .shadow(color: departing ? RVTheme.danger.opacity(0.5) : .clear, radius: 4)
    }
}

#Preview {
    ZStack {
        Color(white: 0.25).ignoresSafeArea()
        LaneOverlay(estimate: LaneEstimate(
            left: LaneLine(bottomX: 0.08, bottomY: 0.96, topX: 0.45, topY: 0.44),
            right: LaneLine(bottomX: 0.92, bottomY: 0.96, topX: 0.55, topY: 0.44),
            leftConfidence: 0.9, rightConfidence: 0.6, laneCenterX: 0.5, egoOffset: 0, confidence: 0.75,
            referenceY: 0.96, timestamp: 0),
            imageSize: CGSize(width: 1080, height: 1920), departureSide: .left)
        .ignoresSafeArea()
    }
}
