import SwiftUI

/// Draws the tracked objects on top of an aspect-fill camera preview.
///
/// Boxes are normalized to the processed camera buffer (`imageSize`, upright). The preview layer shows that buffer
/// with `.resizeAspectFill`, so the same geometry is used here: `scale = max(viewW / imgW, viewH / imgH)` and the
/// scaled image is centred (the overflowing sides are cropped).
///
/// Confirmed tracks get a solid box and a label chip ("Легковой · Chevrolet 74%" + "≈ 23 м · ≈ 54 км/ч");
/// tentative tracks are drawn faint and dashed without a label. Percentages are detector *confidence*
/// ("уверенность"), distances/speeds are rough monocular estimates ("≈").
struct DetectionOverlayView: View {
    let tracks: [TrackedObject]
    let imageSize: CGSize
    let showDistance: Bool
    let showSpeed: Bool
    /// False for compact places (picture-in-picture): boxes only.
    let showLabels: Bool

    init(tracks: [TrackedObject], imageSize: CGSize, showDistance: Bool, showSpeed: Bool, showLabels: Bool = true) {
        self.tracks = tracks
        self.imageSize = imageSize
        self.showDistance = showDistance
        self.showSpeed = showSpeed
        self.showLabels = showLabels
    }

    var body: some View {
        GeometryReader { proxy in
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(tracks) { track in
                    TrackBoxView(track: track,
                                 rect: mapping.rect(for: track.box),
                                 containerSize: proxy.size,
                                 showLabel: showLabels && track.isConfirmed,
                                 secondaryText: showLabels
                                    ? Self.estimateText(for: track, showDistance: showDistance, showSpeed: showSpeed)
                                    : nil,
                                 thin: !showLabels)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .animation(.linear(duration: 0.08), value: tracks)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Styling and text (also used by other camera views)

    /// Box/label colour per object class (bright, high-contrast on a camera picture).
    static func color(for kind: VehicleKind) -> Color {
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

    /// Make name to show, or nil when the classifier is not confident enough (≥ 0.4; "?" suffix below 0.6).
    static func makeText(for track: TrackedObject) -> String? {
        guard let make = track.make, let confidence = track.makeConfidence, confidence >= 0.4 else { return nil }
        return confidence < 0.6 ? make + "?" : make
    }

    /// "Легковой · Chevrolet 74%" (percentage = detector confidence); traffic lights: "Светофор · Красный".
    static func primaryText(for track: TrackedObject) -> String {
        if track.kind == .trafficLight {
            if let color = track.lightColor, color != .unknown {
                return "\(track.kind.displayName) · \(color.displayName)"
            }
            return track.kind.displayName
        }
        var text = track.kind.displayName
        if let make = makeText(for: track) {
            text += " · " + make
        }
        let percent = Int((min(max(track.confidence, 0), 1) * 100).rounded())
        return text + " \(percent)%"
    }

    /// "≈ 23 м · ≈ 54 км/ч" — only the enabled and available estimates; nil when there is nothing to show.
    static func estimateText(for track: TrackedObject, showDistance: Bool, showSpeed: Bool) -> String? {
        var parts: [String] = []
        if showDistance, let distance = track.distanceMeters, distance.isFinite, distance > 0 {
            parts.append("≈ \(Int(distance.rounded())) м")
        }
        if showSpeed, let speed = track.estimatedSpeedKmh, speed.isFinite, speed >= 0 {
            parts.append("≈ \(Int(speed.rounded())) км/ч")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Maps normalized image coordinates to view coordinates for an aspect-fill, centred image.
private struct AspectFillMapping {
    let displayedWidth: CGFloat
    let displayedHeight: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init(imageSize: CGSize, viewSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            displayedWidth = viewSize.width
            displayedHeight = viewSize.height
            offsetX = 0
            offsetY = 0
            return
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        displayedWidth = imageSize.width * scale
        displayedHeight = imageSize.height * scale
        offsetX = (viewSize.width - displayedWidth) / 2
        offsetY = (viewSize.height - displayedHeight) / 2
    }

    func rect(for box: BBox) -> CGRect {
        CGRect(x: offsetX + CGFloat(box.x) * displayedWidth,
               y: offsetY + CGFloat(box.y) * displayedHeight,
               width: CGFloat(box.width) * displayedWidth,
               height: CGFloat(box.height) * displayedHeight)
    }
}

/// One box with its label chip.
private struct TrackBoxView: View {
    let track: TrackedObject
    let rect: CGRect
    let containerSize: CGSize
    let showLabel: Bool
    let secondaryText: String?
    let thin: Bool

    var body: some View {
        let color = DetectionOverlayView.color(for: track.kind)
        let confirmed = track.isConfirmed
        let lineWidth: CGFloat = thin ? 1.5 : (confirmed ? 3 : 1.5)
        // Chip goes inside the box when there is no room above it, and is right-aligned near the right edge.
        let labelInside = rect.minY < 46
        let alignTrailing = rect.midX > containerSize.width * 0.62

        RoundedRectangle(cornerRadius: thin ? 3 : 6, style: .continuous)
            .strokeBorder(color.opacity(confirmed ? 1 : 0.45),
                          style: StrokeStyle(lineWidth: lineWidth, dash: confirmed ? [] : [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: thin ? 3 : 6, style: .continuous)
                    .fill(color.opacity(confirmed && !thin ? 0.08 : 0))
            )
            .shadow(color: .black.opacity(confirmed ? 0.45 : 0), radius: 2)
            .frame(width: max(rect.width, 4), height: max(rect.height, 4))
            .overlay(alignment: alignTrailing ? .topTrailing : .topLeading) {
                if showLabel {
                    TrackLabelChip(track: track, color: color, secondaryText: secondaryText)
                        .fixedSize()
                        .alignmentGuide(.top) { dimensions in
                            labelInside ? -4 : dimensions[.bottom] + 4
                        }
                }
            }
            .position(x: rect.midX, y: rect.midY)
    }
}

/// Coloured label chip above a box.
private struct TrackLabelChip: View {
    let track: TrackedObject
    let color: Color
    let secondaryText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if track.kind == .trafficLight {
                    TrafficLightDotView(color: track.lightColor ?? .unknown, size: 11)
                } else {
                    Image(systemName: track.kind.symbolName)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(DetectionOverlayView.primaryText(for: track))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            if let secondaryText {
                Text(secondaryText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .foregroundStyle(Color.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
    }
}

#Preview {
    let tracks = [
        TrackedObject(id: 1, kind: .car, label: "car", box: BBox(x: 0.1, y: 0.45, width: 0.35, height: 0.18),
                      confidence: 0.74, hits: 5, firstSeen: 0, lastSeen: 1, isConfirmed: true,
                      make: "Chevrolet", makeConfidence: 0.52, distanceMeters: 23, estimatedSpeedKmh: 54),
        TrackedObject(id: 2, kind: .truck, label: "truck", box: BBox(x: 0.6, y: 0.4, width: 0.3, height: 0.25),
                      confidence: 0.61, hits: 4, firstSeen: 0, lastSeen: 1, isConfirmed: true, distanceMeters: 41),
        TrackedObject(id: 3, kind: .trafficLight, label: "traffic light",
                      box: BBox(x: 0.45, y: 0.02, width: 0.05, height: 0.1), confidence: 0.8, hits: 6,
                      firstSeen: 0, lastSeen: 1, isConfirmed: true, lightColor: .red),
        TrackedObject(id: 4, kind: .person, label: "person", box: BBox(x: 0.05, y: 0.7, width: 0.08, height: 0.2),
                      confidence: 0.4, firstSeen: 0, lastSeen: 1),
    ]
    return ZStack {
        Color(white: 0.2).ignoresSafeArea()
        DetectionOverlayView(tracks: tracks, imageSize: CGSize(width: 1080, height: 1920),
                             showDistance: true, showSpeed: true)
            .ignoresSafeArea()
    }
}
