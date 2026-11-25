import SwiftUI

/// Animated distance line from the own car (bottom-centre of the camera picture) to the lead vehicle (bottom-centre of
/// its box): flowing dashes and chevrons that move toward the lead (faster while the gap closes), a gradient in the
/// status colour, a ground marker with a "sonar" ring under the lead car, and a floating glass label at the midpoint
/// ("≈ 18 м" + "1,4 с · норма ≥ 33 м"; standing: "≈ 1,6 м" + "норма ≥ 2 м"). Pulses when the gap is dangerous.
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
            let smoother = smoother

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in
                        let eased = smoother.step(start: line.start, end: line.end, markerWidth: line.markerWidth,
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

    /// Midpoint of the line, kept inside the area between the insets (falls back to the midpoint when it cannot).
    func labelPosition(viewSize: CGSize, insets: EdgeInsets) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let halfWidth: CGFloat = 80, halfHeight: CGFloat = 28
        let minX = insets.leading + halfWidth, maxX = viewSize.width - insets.trailing - halfWidth
        let minY = insets.top + halfHeight, maxY = viewSize.height - insets.bottom - halfHeight
        let x = minX <= maxX ? min(max(mid.x, minX), maxX) : mid.x
        let y = minY <= maxY ? min(max(mid.y, minY), maxY) : mid.y
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
            guard let current, hypot(current.x - target.x, current.y - target.y) < snapDistance else { return target }
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
    static let dashLength: CGFloat = 16
    static let dashGap: CGFloat = 11
    static let chevronSpacing: CGFloat = 58

    static func draw(in context: inout GraphicsContext, start: CGPoint, end: CGPoint, markerWidth: CGFloat,
                     color: Color, danger: Bool, flowSpeed: Double, time: Double) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
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
                                    .init(color: color.opacity(0.22 + 0.25 * Double(pulse)), location: 1)])
        context.stroke(line, with: .linearGradient(glow, startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: 14 + 8 * pulse, lineCap: .round))

        // Dashes flowing toward the lead: a decreasing dash phase moves the pattern toward the path end.
        let period = dashLength + dashGap
        let travelled = CGFloat((time * flowSpeed).truncatingRemainder(dividingBy: Double(period)))
        let dashes = Gradient(stops: [.init(color: color.opacity(0.08), location: 0),
                                      .init(color: color.opacity(0.9), location: 0.4),
                                      .init(color: color, location: 1)])
        context.stroke(line, with: .linearGradient(dashes, startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: 4.5 + 1.5 * pulse, lineCap: .round,
                                          dash: [dashLength, dashGap], dashPhase: period - travelled))

        // Chevrons ">" pointing at the lead, moving with the flow, bigger near the own car (perspective).
        let offset = CGFloat((time * flowSpeed).truncatingRemainder(dividingBy: Double(chevronSpacing)))
        let count = Int(length / chevronSpacing) + 1
        for index in 0...count {
            let d = CGFloat(index) * chevronSpacing + offset
            guard d > 28, d < length - 34 else { continue }
            let t = d / length
            let center = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            let size: CGFloat = 6 + 4 * (1 - t)
            var chevron = Path()
            chevron.move(to: CGPoint(x: center.x - ux * size + nx * size, y: center.y - uy * size + ny * size))
            chevron.addLine(to: center)
            chevron.addLine(to: CGPoint(x: center.x - ux * size - nx * size, y: center.y - uy * size - ny * size))
            let fade = min(1, min((d - 28) / 50, (length - 34 - d) / 50))
            context.stroke(chevron, with: .color(color.opacity(Double(0.9 * fade))),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        drawMarker(in: &context, at: end, width: markerWidth, color: color, danger: danger, time: time, pulse: pulse)
    }

    /// Flat ellipse "on the road" under the lead car plus an expanding ring.
    private static func drawMarker(in context: inout GraphicsContext, at point: CGPoint, width: CGFloat,
                                   color: Color, danger: Bool, time: Double, pulse: CGFloat) {
        let w = max(36, width)
        let h = w * 0.2
        let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.2 + 0.18 * Double(pulse))))
        context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.95)), lineWidth: 2.5)

        let phase = CGFloat((time * (danger ? 1.4 : 0.7)).truncatingRemainder(dividingBy: 1))
        let scale = 1 + 0.6 * phase
        let ring = CGRect(x: point.x - w * scale / 2, y: point.y - h * scale / 2, width: w * scale, height: h * scale)
        context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(Double(0.6 * (1 - phase)))), lineWidth: 2)
    }
}

// MARK: - Label

/// Floating glass label at the middle of the line.
private struct LeadDistanceLabel: View {
    let lead: LeadVehicle
    let assessment: FollowingDistanceAssessment?

    var body: some View {
        let status = assessment?.status ?? .unknown
        let color = RVTheme.statusColor(status)
        let gap = FollowingDistanceText.gap(lead.distanceMeters)
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: RVTheme.statusSymbol(status))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .danger)
                Text(gap)
                    .rvNumeric(24, weight: .heavy)
                    .contentTransition(.numericText())
            }
            if let assessment {
                Text(FollowingDistanceText.lineCaption(assessment))
                    .rvNumeric(12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .rvGlass(cornerRadius: 16, tint: color)
        .animation(RVTheme.snappy, value: gap)
    }
}
