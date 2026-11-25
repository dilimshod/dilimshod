import SwiftUI

/// Animated distance line from the own car (bottom-centre of the camera picture) to the lead vehicle (bottom-centre of
/// its box): flowing dashes and chevrons that move toward the lead (faster while the gap closes), a gradient in the
/// status colour, a ground marker with a "sonar" ring under the lead car, and a small single-line label placed BESIDE
/// the line below the car ("≈ 18 м · 1,4 с"; standing: "≈ 1,6 м"), so the car itself stays visible.
/// Pulses when the gap is dangerous. Thin strokes: the camera picture stays readable.
///
/// Uses the same aspect-fill mapping as `DetectionOverlayView`; put it in the same full-screen layer
/// (`.ignoresSafeArea()`). The endpoints are eased between processed frames (≤ 15 Hz) so the line glides.
struct LeadDistanceOverlay: View {
    let lead: LeadVehicle
    let assessment: FollowingDistanceAssessment?
    let imageSize: CGSize
    /// Keeps the floating label clear of the HUD (full-screen coordinates).
    var labelInsets = EdgeInsets(top: 120, leading: 16, bottom: 260, trailing: 16)

    @State private var smoother = LeadLineSmoother()

    private var status: DistanceStatus { assessment?.status ?? .unknown }

    /// Dash flow speed, points per second: faster while the gap is closing.
    private var flowSpeed: Double {
        let closing = min(60, max(0, assessment?.closingSpeedKmh ?? 0))
        return 38 + closing * 2.5
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: size)
            let line = LeadLineGeometry(mapping: mapping, viewSize: size, box: lead.box)
            let labelPosition = line.labelPosition(viewSize: size, insets: labelInsets)
            let color = RVTheme.statusColor(status)
            let danger = status == .danger
            let speed = flowSpeed
            let lineSmoother = smoother

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in
                        let eased = lineSmoother.step(start: line.start, end: line.end, markerWidth: line.markerWidth,
                                                  time: time)
                        LeadLineRenderer.draw(in: &context, start: eased.start, end: eased.end,
                                              markerWidth: eased.markerWidth, color: color, danger: danger,
                                              flowSpeed: speed, time: time)
                    }
                }
                LeadDistanceLabel(lead: lead, assessment: assessment)
                    .fixedSize()
                    .position(labelPosition)
                    .animation(.smooth(duration: 0.22), value: labelPosition)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // the HUD carries the spoken summary
    }
}

// MARK: - Geometry

/// Endpoints of the line in view coordinates.
struct LeadLineGeometry: Equatable {
    let start: CGPoint
    let end: CGPoint
    let markerWidth: CGFloat

    init(mapping: AspectFillMapping, viewSize: CGSize, box: BBox) {
        let bottom = mapping.point(x: 0.5, y: 1)
        // The image bottom can be below the screen (aspect-fill crop) → start just below the visible edge.
        start = CGPoint(x: bottom.x, y: min(bottom.y, viewSize.height) + 6)
        end = mapping.point(x: box.midX, y: min(1, box.maxY))
        markerWidth = mapping.rect(for: box).width * 0.9
    }

    /// Approximate half size of the compact label, points.
    static let labelHalfSize = CGSize(width: 54, height: 13)

    /// A point on the line between the own car and the lead (60 % of the way, i.e. below the car), shifted sideways
    /// so the label sits next to the line instead of on top of it or the car; kept inside the insets.
    func labelPosition(viewSize: CGSize, insets: EdgeInsets) -> CGPoint {
        let t: CGFloat = 0.6
        let anchor = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        let half = Self.labelHalfSize
        let gap: CGFloat = 12
        // Right of the line by default; left when the line leans right (more room on the left).
        let side: CGFloat = end.x > start.x + 20 ? -1 : 1
        var x = anchor.x + side * (half.width + gap)
        var y = anchor.y
        let minX = insets.leading + half.width, maxX = viewSize.width - insets.trailing - half.width
        let minY = insets.top + half.height, maxY = viewSize.height - insets.bottom - half.height
        if minX <= maxX {
            if x < minX || x > maxX {
                // No room on this side → try the other side, then clamp.
                let other = anchor.x - side * (half.width + gap)
                x = (minX...maxX).contains(other) ? other : min(max(x, minX), maxX)
            }
        }
        if minY <= maxY { y = min(max(y, minY), maxY) }
        return CGPoint(x: x, y: y)
    }
}

/// Eases the endpoints toward their latest targets (critically damped, τ ≈ 90 ms) so the line glides between
/// processed frames. Mutated from the Canvas renderer only (plain class, no SwiftUI invalidation).
final class LeadLineSmoother {
    private var start: CGPoint?
    private var end: CGPoint?
    private var markerWidth: CGFloat?
    private var lastTime: TimeInterval?
    private let timeConstant: Double = 0.09

    func step(start targetStart: CGPoint, end targetEnd: CGPoint, markerWidth targetWidth: CGFloat,
              time: TimeInterval) -> (start: CGPoint, end: CGPoint, markerWidth: CGFloat) {
        let dt = lastTime.map { min(0.25, max(0, time - $0)) } ?? 1
        lastTime = time
        let k = CGFloat(1 - exp(-dt / timeConstant))

        func ease(_ current: CGPoint?, _ target: CGPoint, snapDistance: CGFloat) -> CGPoint {
            guard let current else { return target }
            let jx = current.x - target.x, jy = current.y - target.y
            guard (jx * jx + jy * jy).squareRoot() < snapDistance else { return target }
            return CGPoint(x: current.x + (target.x - current.x) * k, y: current.y + (target.y - current.y) * k)
        }
        let newStart = ease(start, targetStart, snapDistance: 400)
        let newEnd = ease(end, targetEnd, snapDistance: 220)   // another vehicle became the lead → jump
        let newWidth = markerWidth.map { $0 + (targetWidth - $0) * k } ?? targetWidth
        start = newStart
        end = newEnd
        markerWidth = newWidth
        return (newStart, newEnd, newWidth)
    }
}

// MARK: - Drawing

/// Draws the line, chevrons and the ground marker into a Canvas.
enum LeadLineRenderer {
    static let dashLength: CGFloat = 12
    static let dashGap: CGFloat = 10
    static let chevronSpacing: CGFloat = 64

    static func draw(in context: inout GraphicsContext, start: CGPoint, end: CGPoint, markerWidth: CGFloat,
                     color: Color, danger: Bool, flowSpeed: Double, time: Double) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 16 else {
            drawMarker(in: &context, at: end, width: markerWidth, color: color, danger: danger, time: time, pulse: 0)
            return
        }
        let ux = dx / length, uy = dy / length          // direction toward the lead
        let nx = -uy, ny = ux                           // normal
        let pulse: CGFloat = danger ? CGFloat(0.5 + 0.5 * sin(time * 2 * .pi * 1.6)) : 0

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)

        // Soft glow under the dashes.
        let glow = Gradient(stops: [.init(color: color.opacity(0), location: 0),
                                    .init(color: color.opacity(0.14 + 0.2 * Double(pulse)), location: 1)])
        context.stroke(line, with: .linearGradient(glow, startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: 8 + 6 * pulse, lineCap: .round))

        // Dashes flowing toward the lead: a decreasing dash phase moves the pattern toward the path end.
        let period = dashLength + dashGap
        let travelled = CGFloat((time * flowSpeed).truncatingRemainder(dividingBy: Double(period)))
        let dashes = Gradient(stops: [.init(color: color.opacity(0.05), location: 0),
                                      .init(color: color.opacity(0.7), location: 0.4),
                                      .init(color: color.opacity(0.95), location: 1)])
        context.stroke(line, with: .linearGradient(dashes, startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: 2.5 + 1 * pulse, lineCap: .round,
                                          dash: [dashLength, dashGap], dashPhase: period - travelled))

        // Chevrons ">" pointing at the lead, moving with the flow, bigger near the own car (perspective).
        let offset = CGFloat((time * flowSpeed).truncatingRemainder(dividingBy: Double(chevronSpacing)))
        let count = Int(length / chevronSpacing) + 1
        for index in 0...count {
            let d = CGFloat(index) * chevronSpacing + offset
            guard d > 28, d < length - 34 else { continue }
            let t = d / length
            let center = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            let size: CGFloat = 4 + 3 * (1 - t)
            var chevron = Path()
            chevron.move(to: CGPoint(x: center.x - ux * size + nx * size, y: center.y - uy * size + ny * size))
            chevron.addLine(to: center)
            chevron.addLine(to: CGPoint(x: center.x - ux * size - nx * size, y: center.y - uy * size - ny * size))
            let fade = min(1, min((d - 28) / 50, (length - 34 - d) / 50))
            context.stroke(chevron, with: .color(color.opacity(Double(0.75 * fade))),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }

        drawMarker(in: &context, at: end, width: markerWidth, color: color, danger: danger, time: time, pulse: pulse)
    }

    /// Flat ellipse "on the road" under the lead car plus an expanding ring.
    private static func drawMarker(in context: inout GraphicsContext, at point: CGPoint, width: CGFloat,
                                   color: Color, danger: Bool, time: Double, pulse: CGFloat) {
        let w = max(30, width)
        let h = w * 0.18
        let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.12 + 0.15 * Double(pulse))))
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.85)), lineWidth: 1.5)

        let phase = CGFloat((time * (danger ? 1.4 : 0.7)).truncatingRemainder(dividingBy: 1))
        let scale = 1 + 0.6 * phase
        let ring = CGRect(x: point.x - w * scale / 2, y: point.y - h * scale / 2, width: w * scale, height: h * scale)
        context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(Double(0.45 * (1 - phase)))), lineWidth: 1.2)
    }
}

// MARK: - Label

/// Small single-line label next to the line: status symbol, "≈ 18 м · 1,4 с" (~13 pt).
private struct LeadDistanceLabel: View {
    let lead: LeadVehicle
    let assessment: FollowingDistanceAssessment?

    var body: some View {
        let status = assessment?.status ?? .unknown
        let color = RVTheme.statusColor(status)
        let gap = FollowingDistanceText.gap(lead.distanceMeters)
        HStack(spacing: 4) {
            Image(systemName: RVTheme.statusSymbol(status))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .danger)
            Text(Self.text(gap: gap, assessment: assessment))
                .rvNumeric(13, weight: .bold)
                .contentTransition(.numericText())
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .rvTextShadow()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial).opacity(0.65)
                Capsule(style: .continuous).fill(color.opacity(0.12))
            }
        }
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.55), lineWidth: 0.75))
        .animation(RVTheme.snappy, value: gap)
    }

    /// "≈ 18 м · 1,4 с" while moving, "≈ 1,6 м" when standing / without a headway.
    static func text(gap: String, assessment: FollowingDistanceAssessment?) -> String {
        if let assessment, !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
            return gap + " · " + RVFormat.gapSeconds(headway)
        }
        return gap
    }
}
