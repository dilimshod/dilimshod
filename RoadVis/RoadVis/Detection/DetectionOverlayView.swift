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
/// No distance / speed estimates are drawn on non-lead boxes (they confused which car the distance belongs to): the
/// distance appears only on the lead (`LeadDistanceOverlay` label, governed by the "show estimates" settings); the
/// tap-to-open detail card still has the estimates of any track. Percentages are detector *confidence*.
///
/// A pedestrian on / about to enter the roadway (`pedestrianHazards`) gets a thicker glowing bracket in red (danger)
/// or orange (caution) that pulses gently. Persons the colour heuristic takes for a traffic police officer (blue, shield
/// badge, "≈ YHXX xodimi") or a road worker (orange, hammer, "≈ Yo‘l ishchisi") get their own colour and label — they
/// are never drawn as a pedestrian hazard. Pedestrians on the sidewalk are not in `tracks` at all (filtered by the
/// worker with the roadway zone).
///
/// This view never takes touches; `TrackHitLayer` provides the tappable areas.
struct DetectionOverlayView: View {
    let tracks: [TrackedObject]
    let imageSize: CGSize
    /// False for compact places (picture-in-picture): thin brackets only.
    let showLabels: Bool
    /// Lead vehicle to highlight (nil = none / following distance off).
    let lead: LeadVehicle?
    /// Status colour of the lead bracket.
    let leadStatus: DistanceStatus
    /// Track whose detail card is open (drawn with a white outline).
    let selectedTrackID: Int?
    /// Pedestrian hazard level per track ID (pedestrians on / about to enter the roadway).
    let pedestrianHazards: [Int: PedestrianHazardLevel]
    /// Show each vehicle's ≈ ground speed on its label chip (`AppSettings.showSpeedEstimates`).
    let showSpeed: Bool

    init(tracks: [TrackedObject], imageSize: CGSize, showLabels: Bool = true,
         lead: LeadVehicle? = nil, leadStatus: DistanceStatus = .unknown, selectedTrackID: Int? = nil,
         pedestrianHazards: [Int: PedestrianHazardLevel] = [:], showSpeed: Bool = false) {
        self.showSpeed = showSpeed
        self.tracks = tracks
        self.imageSize = imageSize
        self.showLabels = showLabels
        self.lead = lead
        self.leadStatus = leadStatus
        self.selectedTrackID = selectedTrackID
        self.pedestrianHazards = pedestrianHazards
    }

    /// Hazard level per track of `hazards` (the most urgent level when a track appears twice).
    static func hazardLevels(_ hazards: [PedestrianHazard]) -> [Int: PedestrianHazardLevel] {
        var result: [Int: PedestrianHazardLevel] = [:]
        for hazard in hazards {
            result[hazard.trackID] = max(result[hazard.trackID] ?? hazard.level, hazard.level)
        }
        return result
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
                                 hazard: pedestrianHazards[track.id],
                                 isSelected: selectedTrackID == track.id,
                                 showLabel: showLabels && track.isConfirmed,
                                 showSpeed: showSpeed)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Styling and text (also used by other camera views)

    /// Make shown on the compact box label: only when the classifier is confident (≥ 0.6).
    static func confidentMakeText(for track: TrackedObject) -> String? {
        guard let make = track.make, let confidence = track.makeConfidence, confidence >= 0.6 else { return nil }
        return make
    }

    /// Single-line label text: "Легковой · Chevrolet" (confident make only); traffic lights: "Светофор · Красный".
    static func compactTitleText(for track: TrackedObject) -> String {
        if track.kind == .trafficLight { return titleText(for: track) }
        if let role = track.roadStaffRole { return role.approximateName }
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
        if let role = track.roadStaffRole {
            return role.approximateName + " (" + L("role.heuristic") + ")"
        }
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

    /// "≈54 км/ч" for the box chip of a vehicle with a ground-speed estimate; nil otherwise.
    static func chipSpeedText(for track: TrackedObject) -> String? {
        guard track.kind.isVehicle, track.isConfirmed, track.missed == 0,
              let speed = track.estimatedSpeedKmh, speed.isFinite, speed >= 0 else { return nil }
        return "≈\(Int(speed.rounded())) \(RVFormat.appKmh)"
    }

    /// "≈ 23 м · ≈ 54 км/ч" — only the enabled and available estimates; nil when there is nothing to show.
    static func estimateText(for track: TrackedObject, showDistance: Bool, showSpeed: Bool) -> String? {
        var parts: [String] = []
        if showDistance, let distance = track.distanceMeters, distance.isFinite, distance > 0 {
            parts.append("≈ " + RVFormat.gapMeters(distance))
        }
        if showSpeed, let speed = track.estimatedSpeedKmh, speed.isFinite, speed >= 0 {
            parts.append("≈ \(Int(speed.rounded())) \(RVFormat.appKmh)")
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
    /// Pedestrian hazard of this track (red / orange highlighted bracket).
    let hazard: PedestrianHazardLevel?
    let isSelected: Bool
    let showLabel: Bool
    let showSpeed: Bool

    /// False until the spring-in has run. Tracks that come back after a short gap (hits > 3) skip the spring-in.
    @State private var appeared: Bool

    init(track: TrackedObject, rect: CGRect, containerSize: CGSize, thin: Bool, isLead: Bool,
         leadStatus: DistanceStatus, hazard: PedestrianHazardLevel?, isSelected: Bool, showLabel: Bool,
         showSpeed: Bool = false) {
        self.showSpeed = showSpeed
        self.track = track
        self.rect = rect
        self.containerSize = containerSize
        self.thin = thin
        self.isLead = isLead
        self.leadStatus = leadStatus
        self.hazard = hazard
        self.isSelected = isSelected
        self.showLabel = showLabel
        // Confirmed tracks are visible at once (no dependence on onAppear while the layer re-renders at 15 Hz).
        _appeared = State(initialValue: track.hits > 3 || track.isConfirmed)
    }

    /// Highlighted like the lead vehicle (thicker glowing bracket, stronger fill).
    private var isEmphasized: Bool { isLead || hazard != nil || track.roadStaffRole != nil }

    private var color: Color {
        if let hazard { return RVTheme.pedestrianColor(hazard) }
        if let roleColor = RVTheme.roleColor(track.roadStaffRole) { return roleColor }
        return isLead && leadStatus != .unknown ? RVTheme.statusColor(leadStatus) : RVTheme.kindColor(track.kind)
    }

    private var lineWidth: CGFloat {
        if thin { return isEmphasized ? 2.5 : 1.5 }
        if hazard != nil { return RVTheme.Stroke.lead + 1 }
        if isLead { return RVTheme.Stroke.lead + 0.5 }
        if isSelected { return RVTheme.Stroke.selected + 0.5 }
        return track.isConfirmed ? RVTheme.Stroke.box + 0.5 : RVTheme.Stroke.tentative
    }

    private var pulses: Bool {
        hazard != nil || (isLead && (leadStatus == .caution || leadStatus == .danger))
    }

    private var pulsePeriod: Double {
        if let hazard { return hazard == .danger ? 0.8 : 1.3 }
        return leadStatus == .danger ? 0.7 : 1.3
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
                // Lead / hazard: clearly visible full outline in the status colour; others: subtle but visible.
                shape.fill(color.opacity(hazard == .danger ? 0.14 : (isEmphasized ? 0.1 : 0.04)))
                shape.stroke(color.opacity(isEmphasized ? 0.75 : 0.35), lineWidth: isEmphasized ? 1.5 : 1)
            } else if confirmed && isEmphasized {
                shape.stroke(color.opacity(0.7), lineWidth: 1)
            }
            CornerBracketShape(armFraction: confirmed ? 0.22 : 0.16, cornerRadius: radius)
                .stroke(color.opacity(confirmed ? 0.95 : 0.4),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                                           dash: confirmed ? [] : [3, 4]))
                .shadow(color: isEmphasized ? color.opacity(0.7) : .black.opacity(confirmed ? 0.35 : 0),
                        radius: isEmphasized ? (thin ? 3 : 5) : 1.5)
                .rvPulse(pulses, minOpacity: 0.55, period: pulsePeriod)
            if isSelected && !thin {
                shape.stroke(Color.white.opacity(0.85), lineWidth: 1)
                    .padding(-3)
            }
        }
        .frame(width: max(rect.width, 6), height: max(rect.height, 6))
        .overlay(alignment: alignTrailing ? .topTrailing : .topLeading) {
            if showLabel {
                // Fixed-width slot: the chip hugs its text and truncates beyond the maximum width.
                TrackLabelChip(track: track, color: color, isLead: isLead, isEmphasized: isEmphasized,
                               speedText: showSpeed ? DetectionOverlayView.chipSpeedText(for: track) : nil)
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

/// Tiny single-line frosted capsule above a box: class symbol, class (+ confident make) and lead marker (no estimates —
/// the lead's distance is on its distance line). Truncates instead of growing.
private struct TrackLabelChip: View {
    let track: TrackedObject
    let color: Color
    let isLead: Bool
    /// Lead vehicle or pedestrian hazard: stronger outline.
    let isEmphasized: Bool
    /// "54" (km/h) of a moving vehicle; nil hides the speed part.
    var speedText: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if track.kind == .trafficLight {
                TrafficLightDotView(color: track.lightColor ?? .unknown, size: 8)
            } else {
                Image(systemName: isLead ? "car.rear.fill" : (track.roadStaffRole?.symbolName ?? track.kind.symbolName))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(DetectionOverlayView.compactTitleText(for: track))
            if let speedText {
                // Speed first priority: the class name truncates before the speed does.
                HStack(spacing: 2) {
                    if track.isOncoming {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .heavy))
                    }
                    Text(speedText)
                        .font(RVTheme.font(11, weight: .bold))
                }
                .padding(.leading, 2)
                .layoutPriority(2)
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
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(isEmphasized ? 0.7 : 0.35), lineWidth: 0.5))
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
                        .accessibilityHint(L("common.showDetails"))
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
            text += ", " + estimate.replacingOccurrences(of: "≈ ", with: L("common.approxWord") + " ") + " (" + L("common.estimate") + ")"
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
                           relativeSpeedKmh: -6, method: "width+height")
    return ZStack {
        Color(white: 0.2).ignoresSafeArea()
        DetectionOverlayView(tracks: tracks, imageSize: CGSize(width: 1080, height: 1920),
                             lead: lead, leadStatus: .caution)
            .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
}
