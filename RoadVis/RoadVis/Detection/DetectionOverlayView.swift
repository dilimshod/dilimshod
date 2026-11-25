import SwiftUI

/// Draws the tracked objects on top of an aspect-fill camera preview.
///
/// Boxes are normalized to the processed camera buffer (`imageSize`, upright). The preview layer shows that buffer
/// with `.resizeAspectFill`, so the same geometry is used here (`AspectFillMapping`).
///
/// Style (minimal dashcam HUD): thin rounded corner brackets (1.5 pt) with a barely visible fill, moving smoothly
/// between processed frames and springing in when a track appears; a tiny single-line frosted capsule above the box
/// (class symbol + class, make only when the classifier is confident). The lead vehicle (own lane, following distance)
/// gets a slightly thicker softly glowing bracket in the status colour that pulses gently when the gap is short — its
/// distance is shown by `LeadDistanceOverlay`, not here. Tentative tracks are faint dashed brackets without a label.
/// Estimates ("≈ 23 м · ≈ 54 км/ч", when enabled) are added to the same line only on large (near) boxes, so far-away
/// traffic stays uncluttered; the tap-to-open detail card always has them. Percentages are detector *confidence*.
///
/// This view never takes touches; `TrackHitLayer` provides the tappable areas.
struct DetectionOverlayView: View {
    let tracks: [TrackedObject]
    let imageSize: CGSize
    let showDistance: Bool
    let showSpeed: Bool
    /// False for compact places (picture-in-picture): thin brackets only.
    let showLabels: Bool
    /// Lead vehicle to highlight (nil = none / following distance off).
    let lead: LeadVehicle?
    /// Status colour of the lead bracket.
    let leadStatus: DistanceStatus
    /// Track whose detail card is open (drawn with a white outline).
    let selectedTrackID: Int?

    init(tracks: [TrackedObject], imageSize: CGSize, showDistance: Bool, showSpeed: Bool, showLabels: Bool = true,
         lead: LeadVehicle? = nil, leadStatus: DistanceStatus = .unknown, selectedTrackID: Int? = nil) {
        self.tracks = tracks
        self.imageSize = imageSize
        self.showDistance = showDistance
        self.showSpeed = showSpeed
        self.showLabels = showLabels
        self.lead = lead
        self.leadStatus = leadStatus
        self.selectedTrackID = selectedTrackID
    }

    var body: some View {
        GeometryReader { proxy in
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(tracks) { track in
                    let isLead = lead?.trackID == track.id
                    TrackBoxView(track: track,
                                 rect: mapping.rect(for: track.box),
                                 containerSize: proxy.size,
                                 thin: !showLabels,
                                 isLead: isLead,
                                 leadStatus: leadStatus,
                                 isSelected: selectedTrackID == track.id,
                                 showLabel: showLabels && track.isConfirmed,
                                 secondaryText: showLabels && !isLead && Self.showsInlineEstimate(for: mapping.rect(for: track.box))
                                    ? Self.estimateText(for: track, showDistance: showDistance, showSpeed: showSpeed)
                                    : nil)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Styling and text (also used by other camera views)

    /// Boxes at least this wide (points) — i.e. near vehicles — get their enabled estimates on the label line.
    static let inlineEstimateMinWidth: CGFloat = 120

    static func showsInlineEstimate(for rect: CGRect) -> Bool {
        rect.width >= inlineEstimateMinWidth
    }

    /// Make shown on the compact box label: only when the classifier is confident (≥ 0.6).
    static func confidentMakeText(for track: TrackedObject) -> String? {
        guard let make = track.make, let confidence = track.makeConfidence, confidence >= 0.6 else { return nil }
        return make
    }

    /// Single-line label text: "Легковой · Chevrolet" (confident make only); traffic lights: "Светофор · Красный".
    static func compactTitleText(for track: TrackedObject) -> String {
        if track.kind == .trafficLight { return titleText(for: track) }
        if let make = confidentMakeText(for: track) {
            return track.kind.localizedName + " · " + make
        }
        return track.kind.localizedName
    }

    /// Box/label colour per object class (see `RVTheme.kindColor`).
    static func color(for kind: VehicleKind) -> Color {
        RVTheme.kindColor(kind)
    }

    /// Make name to show, or nil when the classifier is not confident enough (≥ 0.4; "?" suffix below 0.6).
    static func makeText(for track: TrackedObject) -> String? {
        guard let make = track.make, let confidence = track.makeConfidence, confidence >= 0.4 else { return nil }
        return confidence < 0.6 ? make + "?" : make
    }

    /// Detector confidence in percent (0…100).
    static func confidencePercent(for track: TrackedObject) -> Int {
        Int((min(max(track.confidence, 0), 1) * 100).rounded())
    }

    /// "Легковой · Chevrolet"; traffic lights: "Светофор · Красный".
    static func titleText(for track: TrackedObject) -> String {
        if track.kind == .trafficLight {
            if let color = track.lightColor, color != .unknown {
                return "\(track.kind.localizedName) · \(color.localizedName)"
            }
            return track.kind.localizedName
        }
        if let make = makeText(for: track) {
            return track.kind.localizedName + " · " + make
        }
        return track.kind.localizedName
    }

    /// "Легковой · Chevrolet 74%" (percentage = detector confidence); traffic lights: "Светофор · Красный".
    static func primaryText(for track: TrackedObject) -> String {
        if track.kind == .trafficLight { return titleText(for: track) }
        return titleText(for: track) + " \(confidencePercent(for: track))%"
    }

    /// "≈ 23 м · ≈ 54 км/ч" — only the enabled and available estimates; nil when there is nothing to show.
    static func estimateText(for track: TrackedObject, showDistance: Bool, showSpeed: Bool) -> String? {
        var parts: [String] = []
        if showDistance, let distance = track.distanceMeters, distance.isFinite, distance > 0 {
            parts.append("≈ " + RVFormat.gapMeters(distance))
        }
        if showSpeed, let speed = track.estimatedSpeedKmh, speed.isFinite, speed >= 0 {
            parts.append("≈ \(Int(speed.rounded())) км/ч")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Corner brackets

/// Four rounded corner brackets ("viewfinder" style) inside the rect.
struct CornerBracketShape: Shape {
    /// Arm length as a fraction of the shorter side.
    var armFraction: CGFloat = 0.26
    var cornerRadius: CGFloat = RVTheme.Radius.box

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let shortSide = min(rect.width, rect.height)
        let arm = min(max(7, shortSide * armFraction), rect.width / 2, rect.height / 2)
        let r = min(cornerRadius, arm * 0.7)

        // top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // top-right
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // bottom-left
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return path
    }
}

// MARK: - One box

/// One tracked object: brackets, subtle fill and its label.
private struct TrackBoxView: View {
    let track: TrackedObject
    let rect: CGRect
    let containerSize: CGSize
    let thin: Bool
    let isLead: Bool
    let leadStatus: DistanceStatus
    let isSelected: Bool
    let showLabel: Bool
    let secondaryText: String?

    /// False until the spring-in has run. Tracks that come back after a short gap (hits > 3) skip the spring-in.
    @State private var appeared: Bool

    init(track: TrackedObject, rect: CGRect, containerSize: CGSize, thin: Bool, isLead: Bool,
         leadStatus: DistanceStatus, isSelected: Bool, showLabel: Bool, secondaryText: String?) {
        self.track = track
        self.rect = rect
        self.containerSize = containerSize
        self.thin = thin
        self.isLead = isLead
        self.leadStatus = leadStatus
        self.isSelected = isSelected
        self.showLabel = showLabel
        self.secondaryText = secondaryText
        _appeared = State(initialValue: track.hits > 3)
    }

    private var color: Color {
        isLead && leadStatus != .unknown ? RVTheme.statusColor(leadStatus) : RVTheme.kindColor(track.kind)
    }

    private var lineWidth: CGFloat {
        if thin { return isLead ? 2 : RVTheme.Stroke.tentative }
        if isLead { return RVTheme.Stroke.lead }
        if isSelected { return RVTheme.Stroke.selected }
        return track.isConfirmed ? RVTheme.Stroke.box : RVTheme.Stroke.tentative
    }

    private var pulses: Bool {
        isLead && (leadStatus == .caution || leadStatus == .danger)
    }

    var body: some View {
        let confirmed = track.isConfirmed
        let radius = thin ? 4 : RVTheme.Radius.box
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The label goes inside the box when there is no room above it, right-aligned near the right edge.
        let labelInside = rect.minY < 28
        let alignTrailing = rect.midX > containerSize.width * 0.62

        ZStack {
            if confirmed && !thin {
                shape.fill(color.opacity(isLead ? 0.07 : 0.03))
                shape.stroke(color.opacity(isLead ? 0.3 : 0.12), lineWidth: 0.5)
            }
            CornerBracketShape(armFraction: confirmed ? 0.22 : 0.16, cornerRadius: radius)
                .stroke(color.opacity(confirmed ? 0.95 : 0.4),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                                           dash: confirmed ? [] : [3, 4]))
                .shadow(color: isLead ? color.opacity(0.7) : .black.opacity(confirmed ? 0.35 : 0),
                        radius: isLead ? (thin ? 3 : 5) : 1.5)
                .rvPulse(pulses, minOpacity: 0.55, period: leadStatus == .danger ? 0.7 : 1.3)
            if isSelected && !thin {
                shape.stroke(Color.white.opacity(0.85), lineWidth: 1)
                    .padding(-3)
            }
        }
        .frame(width: max(rect.width, 6), height: max(rect.height, 6))
        .overlay(alignment: alignTrailing ? .topTrailing : .topLeading) {
            if showLabel {
                // Fixed-width slot: the chip hugs its text and truncates beyond the maximum width.
                TrackLabelChip(track: track, color: color, isLead: isLead, secondaryText: secondaryText)
                    .frame(width: RVTheme.HUD.maxLabelWidth, alignment: alignTrailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.top) { dimensions in
                        labelInside ? -4 : dimensions[.bottom] + 4
                    }
            }
        }
        .scaleEffect(appeared ? 1 : 1.22)
        .opacity(appeared ? (track.missed > 0 ? 0.6 : 1) : 0)   // held for a moment after a missed detection
        .position(x: rect.midX, y: rect.midY)
        .animation(RVTheme.trackMotion, value: rect)
        .onAppear {
            guard !appeared else { return }
            withAnimation(RVTheme.springIn) {
                appeared = true
            }
        }
    }
}

/// Tiny single-line frosted capsule above a box: class symbol, class (+ confident make), lead marker and — on near
/// boxes only — the enabled estimates. Truncates instead of growing.
private struct TrackLabelChip: View {
    let track: TrackedObject
    let color: Color
    let isLead: Bool
    let secondaryText: String?

    var body: some View {
        HStack(spacing: 4) {
            if track.kind == .trafficLight {
                TrafficLightDotView(color: track.lightColor ?? .unknown, size: 8)
            } else {
                Image(systemName: isLead ? "car.rear.fill" : track.kind.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(DetectionOverlayView.compactTitleText(for: track))
                .layoutPriority(1)
            if let secondaryText {
                Text(secondaryText)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(RVTheme.font(11, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.white)
        .rvTextShadow()
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background {
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial).opacity(0.6)
                Capsule(style: .continuous).fill(Color.black.opacity(0.18))
            }
        }
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(isLead ? 0.7 : 0.35), lineWidth: 0.5))
    }
}

// MARK: - Tappable areas

/// Transparent tap targets over the confirmed boxes (same aspect-fill mapping as the drawing). Put it BELOW the HUD:
/// only the boxes themselves take touches, so the buttons on top and the empty camera picture keep working.
/// Tapping a box selects it (again → deselects); while something is selected, tapping the picture deselects.
struct TrackHitLayer: View {
    let tracks: [TrackedObject]
    let imageSize: CGSize
    @Binding var selectedTrackID: Int?

    /// Smallest tap target, points.
    static let minimumHitSize: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let mapping = AspectFillMapping(imageSize: imageSize, viewSize: proxy.size)
            ZStack(alignment: .topLeading) {
                if selectedTrackID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTrackID = nil }
                        .accessibilityHidden(true)
                }
                // Larger boxes first, so a small box inside a big one stays tappable.
                ForEach(tracks.filter(\.isConfirmed).sorted { $0.box.area > $1.box.area }) { track in
                    let rect = mapping.rect(for: track.box)
                    Color.clear
                        .frame(width: max(rect.width, Self.minimumHitSize), height: max(rect.height, Self.minimumHitSize))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTrackID = selectedTrackID == track.id ? nil : track.id
                        }
                        .position(x: rect.midX, y: rect.midY)
                        .accessibilityElement()
                        .accessibilityLabel(Self.accessibilityText(for: track))
                        .accessibilityHint("Показать подробности")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .sensoryFeedback(.selection, trigger: selectedTrackID)
    }

    static func accessibilityText(for track: TrackedObject) -> String {
        var text = DetectionOverlayView.titleText(for: track)
        if let estimate = DetectionOverlayView.estimateText(for: track, showDistance: true, showSpeed: false) {
            text += ", " + estimate.replacingOccurrences(of: "≈ ", with: "примерно ") + " (оценка)"
        }
        return text
    }
}

#Preview {
    let tracks = [
        TrackedObject(id: 1, kind: .car, label: "car", box: BBox(x: 0.3, y: 0.48, width: 0.32, height: 0.17),
                      confidence: 0.74, hits: 5, firstSeen: 0, lastSeen: 1, isConfirmed: true,
                      make: "Chevrolet", makeConfidence: 0.52, distanceMeters: 23, estimatedSpeedKmh: 54),
        TrackedObject(id: 2, kind: .truck, label: "truck", box: BBox(x: 0.68, y: 0.4, width: 0.28, height: 0.22),
                      confidence: 0.61, hits: 4, firstSeen: 0, lastSeen: 1, isConfirmed: true, distanceMeters: 41),
        TrackedObject(id: 3, kind: .trafficLight, label: "traffic light",
                      box: BBox(x: 0.45, y: 0.02, width: 0.05, height: 0.1), confidence: 0.8, hits: 6,
                      firstSeen: 0, lastSeen: 1, isConfirmed: true, lightColor: .red),
        TrackedObject(id: 4, kind: .person, label: "person", box: BBox(x: 0.05, y: 0.7, width: 0.08, height: 0.2),
                      confidence: 0.4, firstSeen: 0, lastSeen: 1),
    ]
    let lead = LeadVehicle(trackID: 1, kind: .car, box: tracks[0].box, distanceMeters: 18,
                           relativeSpeedKmh: -6, method: "ширина+высота")
    return ZStack {
        Color(white: 0.2).ignoresSafeArea()
        DetectionOverlayView(tracks: tracks, imageSize: CGSize(width: 1080, height: 1920),
                             showDistance: true, showSpeed: true, lead: lead, leadStatus: .caution)
            .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
}
