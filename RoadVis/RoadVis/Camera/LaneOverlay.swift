import SwiftUI

/// Live lane-marking highlight from the lane detector (`LaneEstimate`, heuristic, ≈ 5 Hz):
/// - each detected own-lane marking is drawn as a smooth 4.5 pt rounded line (warm white, up to 0.8 opacity) extended
///   from the bottom of the picture up to the horizon, fading toward the horizon, with a soft dark shadow so it stays
///   visible on bright asphalt;
/// - with both lines shown, the own lane between them gets a translucent cyan-green fill (≈ 0.18 at the bottom,
///   fading to 0 at the horizon);
/// - geometry glides between estimates (short ease-out, animatable shapes), lines fade in / out;
/// - lane departure: the line on that side turns red and pulses, the lane fill tints red.
///
/// Lines are shown from `minConfidence` (≈ 0.3) with an opacity scaled by their confidence; the departure warning keeps
/// its own, higher threshold (`LaneDepartureDetector.Config.minLineConfidence`). When only one line is confident only
/// that one is drawn. Uses the same aspect-fill mapping as the boxes; never takes touches.
struct LaneOverlay: View {
    let estimate: LaneEstimate
    let imageSize: CGSize
    var departureSide: LaneSide?
    var minConfidence: Double = 0.3

    /// Line colour (warm white, reads as white or yellow markings).
    static let lineColor = Color(red: 1.0, green: 0.96, blue: 0.84)
    /// Own-lane fill colour.
    static let fillColor = Color(red: 0.16, green: 0.9, blue: 0.78)
    static let lineWidth: CGFloat = 4.5
    /// Duration of the glide between two estimates (the detector runs every 0.2 s).
    static let glide = Animation.easeOut(duration: 0.22)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: size)
            let left = segment(.left, mapping: mapping)
            let right = segment(.right, mapping: mapping)
            ZStack {
                if let left, let right {
                    laneFill(left: left, right: right, size: size)
                        .transition(.opacity)
                }
                if let left {
                    lineView(left, side: .left, size: size)
                        .transition(.opacity)
                }
                if let right {
                    lineView(right, side: .right, size: size)
                        .transition(.opacity)
                }
            }
            .animation(Self.glide, value: left)
            .animation(Self.glide, value: right)
            .animation(.easeInOut(duration: 0.25), value: left == nil)
            .animation(.easeInOut(duration: 0.25), value: right == nil)
        }
        .animation(.easeInOut(duration: 0.3), value: departureSide)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    /// View-space segment of one marking (image bottom → horizon) with its display opacity, or nil when hidden.
    private func segment(_ side: LaneSide, mapping: AspectFillMapping) -> LaneSegment? {
        guard let line = estimate.line(side) else { return nil }
        let confidence = estimate.confidence(side)
        guard confidence >= minConfidence else { return nil }
        let topY = min(line.topY, line.bottomY - 0.05)
        let bottom = mapping.point(x: line.x(atY: 1), y: 1)
        let top = mapping.point(x: line.x(atY: topY), y: topY)
        guard bottom.x.isFinite, top.x.isFinite else { return nil }
        return LaneSegment(bottom: bottom, top: top, strength: Self.strength(confidence: confidence,
                                                                             minConfidence: minConfidence))
    }

    /// 0.35…1 display strength from the confidence (full from ≈ 0.7).
    static func strength(confidence: Double, minConfidence: Double) -> Double {
        let t = (confidence - minConfidence) / max(0.05, 0.7 - minConfidence)
        return 0.35 + 0.65 * min(1, max(0, t))
    }

    private static func unitY(_ y: CGFloat, in size: CGSize) -> CGFloat {
        size.height > 0 ? min(1, max(0, y / size.height)) : 0
    }

    // MARK: - Layers

    private func lineView(_ segment: LaneSegment, side: LaneSide, size: CGSize) -> some View {
        let departing = departureSide == side
        let color = departing ? RVTheme.danger : Self.lineColor
        let opacity = departing ? 0.95 : 0.8 * segment.strength
        let start = UnitPoint(x: 0.5, y: Self.unitY(segment.top.y, in: size))
        let end = UnitPoint(x: 0.5, y: Self.unitY(segment.bottom.y, in: size))
        let gradient = LinearGradient(stops: [.init(color: color.opacity(opacity * 0.12), location: 0),
                                              .init(color: color.opacity(opacity * 0.7), location: 0.35),
                                              .init(color: color.opacity(opacity), location: 1)],
                                      startPoint: start, endPoint: end)
        return LaneSegmentShape(bottom: segment.bottom, top: segment.top)
            .stroke(gradient, style: StrokeStyle(lineWidth: departing ? Self.lineWidth + 1.5 : Self.lineWidth,
                                                 lineCap: .round, lineJoin: .round))
            .shadow(color: departing ? RVTheme.danger.opacity(0.8) : .black.opacity(0.35),
                    radius: departing ? 7 : 2)
            .rvPulse(departing, minOpacity: 0.45, period: 0.6)
    }

    private func laneFill(left: LaneSegment, right: LaneSegment, size: CGSize) -> some View {
        let departing = departureSide != nil
        let color = departing ? RVTheme.danger : Self.fillColor
        let strength = min(left.strength, right.strength)
        let bottomOpacity = departing ? 0.26 : 0.18 * (0.5 + 0.5 * strength)
        let top = UnitPoint(x: 0.5, y: Self.unitY(min(left.top.y, right.top.y), in: size))
        let bottom = UnitPoint(x: 0.5, y: Self.unitY(max(left.bottom.y, right.bottom.y), in: size))
        return LaneAreaShape(leftBottom: left.bottom, leftTop: left.top, rightTop: right.top, rightBottom: right.bottom)
            .fill(LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                                         .init(color: color.opacity(bottomOpacity * 0.45), location: 0.4),
                                         .init(color: color.opacity(bottomOpacity), location: 1)],
                                 startPoint: top, endPoint: bottom))
    }
}

/// One marking in view coordinates.
private struct LaneSegment: Equatable {
    var bottom: CGPoint
    var top: CGPoint
    var strength: Double
}

/// A straight segment whose endpoints animate.
private struct LaneSegmentShape: Shape {
    var bottom: CGPoint
    var top: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(bottom.animatableData, top.animatableData) }
        set {
            bottom.animatableData = newValue.first
            top.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: bottom)
        path.addLine(to: top)
        return path
    }
}

/// The own-lane quadrilateral between the two markings; corners animate.
private struct LaneAreaShape: Shape {
    var leftBottom: CGPoint
    var leftTop: CGPoint
    var rightTop: CGPoint
    var rightBottom: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
                                       AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>> {
        get {
            AnimatablePair(AnimatablePair(leftBottom.animatableData, leftTop.animatableData),
                           AnimatablePair(rightTop.animatableData, rightBottom.animatableData))
        }
        set {
            leftBottom.animatableData = newValue.first.first
            leftTop.animatableData = newValue.first.second
            rightTop.animatableData = newValue.second.first
            rightBottom.animatableData = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines([leftBottom, leftTop, rightTop, rightBottom])
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color(white: 0.25).ignoresSafeArea()
        LaneOverlay(estimate: LaneEstimate(
            left: LaneLine(bottomX: 0.08, bottomY: 0.96, topX: 0.45, topY: 0.44),
            right: LaneLine(bottomX: 0.92, bottomY: 0.96, topX: 0.55, topY: 0.44),
            leftConfidence: 0.9, rightConfidence: 0.45, laneCenterX: 0.5, egoOffset: 0, confidence: 0.67,
            referenceY: 0.96, timestamp: 0),
            imageSize: CGSize(width: 1080, height: 1920), departureSide: nil)
        .ignoresSafeArea()
    }
}
