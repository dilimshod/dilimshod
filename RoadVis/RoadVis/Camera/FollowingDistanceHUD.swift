import SwiftUI

/// Gap to the vehicle ahead and the distance requirements — compact by default.
///
/// Collapsed (both styles): one slim pill at a screen edge (≤ 44 pt incl. tap area): status dot, "≈ 18 м", the
/// headway "1,4 с" while moving, a timer when a collision is possible and a small chevron. Tap expands it (the state
/// is remembered).
/// Expanded `.full` (portrait): status line with the road-surface chip and an info button (→ norms sheet), the gap and
/// the recommended gap, a progress bar of distance vs recommended (0…1.5×, tick at 1.0) and the rows
/// "В движении: ≥ 2 с ≈ 33 м (сухо)", "При остановке: ≥ 2 м", "Остановочный путь ≈ 37 м", "До столкновения ≈ 2,1 с".
/// Expanded `.mini` (landscape): number, status, norm and the bar in a narrow card.
///
/// All distances are single-camera estimates ("≈ … оценка"); the numbers are recommendations, not legal norms.
struct FollowingDistanceHUD: View {
    enum Style { case full, mini }

    let assessment: FollowingDistanceAssessment
    let lead: LeadVehicle?
    let policy: FollowingDistancePolicy
    let surfaceSource: RoadSurfaceSource
    let isForwardCollisionWarning: Bool
    var style: Style = .full
    let onShowNorms: () -> Void

    @AppStorage(FollowingDistanceHUD.expandedKey) private var expanded = false

    /// UserDefaults key of the expanded state (also read by `RecognitionView` for the label insets).
    nonisolated static let expandedKey = "rv.distanceHUDExpanded"

    private var hasLead: Bool { lead != nil && assessment.distanceMeters != nil }
    private var status: DistanceStatus { hasLead ? assessment.status : .unknown }
    private var color: Color { RVTheme.statusColor(status) }
    private var gapText: String { hasLead ? FollowingDistanceText.gap(assessment.distanceMeters) : "—" }

    var body: some View {
        Group {
            if expanded {
                switch style {
                case .full: fullCard
                case .mini: miniCard
                }
            } else {
                pill
            }
        }
        .animation(RVTheme.snappy, value: gapText)
        .animation(RVTheme.snappy, value: status)
        .sensoryFeedback(.selection, trigger: expanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FollowingDistanceText.accessibilitySummary(assessment, policy: policy, hasLead: hasLead))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? L("common.collapse") : L("common.showDetails"))
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text(l: "fd.norms.title")) { onShowNorms() }
    }

    private func toggle() {
        withAnimation(RVTheme.snappy) { expanded.toggle() }
    }

    // MARK: - Collapsed pill

    private var pill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isForwardCollisionWarning ? RVTheme.danger : color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(hasLead ? 0.8 : 0), radius: 3)
                .rvPulse(status == .danger || isForwardCollisionWarning, minOpacity: 0.3, period: 0.7)
            Image(systemName: "car.rear.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Text(gapText)
                .rvNumeric(15, weight: .bold)
                .foregroundStyle(hasLead ? Color.white : .white.opacity(0.55))
                .contentTransition(.numericText())
            if hasLead, !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
                Text(RVFormat.gapSeconds(headway))
                    .rvNumeric(12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.72))
                    .contentTransition(.numericText())
            }
            if hasLead, let ttc = FollowingDistanceText.timeToCollision(assessment) {
                Label(ttc, systemImage: "timer")
                    .rvNumeric(12, weight: .bold)
                    .foregroundStyle(RVTheme.danger)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .rvTextShadow()
        .padding(.horizontal, 11)
        .frame(height: RVTheme.HUD.pill)
        .rvGlassCapsule(tint: hasLead ? color : nil, shadow: false)
        .overlay {
            if isForwardCollisionWarning {
                Capsule(style: .continuous)
                    .strokeBorder(RVTheme.danger, lineWidth: 2)
                    .rvPulse(true, minOpacity: 0.2, period: 0.6)
            }
        }
        .frame(minHeight: RVTheme.HUD.hit)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onShowNorms() })
    }

    // MARK: - Expanded full card

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .center, spacing: 10) {
                gapBlock(size: 26)
                Spacer(minLength: 8)
                normBlock(size: 16)
            }
            GapProgressBar(fraction: hasLead ? assessment.fractionOfRecommended : nil, color: color)
            detailRows
                .transition(.opacity)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 340, alignment: .leading)
        .rvGlass(cornerRadius: RVTheme.Radius.panel, tint: hasLead ? color : nil)
        .overlay { collisionBorder(cornerRadius: RVTheme.Radius.panel) }
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
        .onTapGesture(perform: toggle)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            statusIcon(size: 13)
            Text(headerTitle)
                .font(RVTheme.font(13, weight: .bold))
                .foregroundStyle(isForwardCollisionWarning ? RVTheme.danger : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .full)
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .condition)
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .icon)
            }
            infoButton
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var infoButton: some View {
        Button(action: onShowNorms) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(RVPressableButtonStyle())
        .accessibilityLabel(L("fd.norms.title"))
    }

    private var headerTitle: String {
        if isForwardCollisionWarning { return L("fd.collision") }
        return status.localizedName
    }

    private func statusIcon(size: CGFloat) -> some View {
        Image(systemName: isForwardCollisionWarning ? "exclamationmark.octagon.fill" : RVTheme.statusSymbol(status))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .danger)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size + 4)
    }

    private func gapBlock(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(gapText)
                .rvNumeric(size, weight: .heavy)
                .foregroundStyle(hasLead ? color : .white.opacity(0.55))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(gapCaption)
                .rvNumeric(11, weight: .semibold)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
    }

    private var gapCaption: String {
        guard hasLead else { return L("fd.noLeadFound") }
        if !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
            return L("fd.headwayCaption", RVFormat.gapSeconds(headway))
        }
        return L("fd.cameraEstimate")
    }

    private func normBlock(size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: assessment.isStopped ? L("fd.normStanding") : L("fd.normWord"))
                .font(RVTheme.font(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(FollowingDistanceText.recommended(assessment))
                .rvNumeric(size, weight: .bold)
                .contentTransition(.numericText())
                .lineLimit(1)
            if !assessment.isStopped, let gap = assessment.recommendedTimeGapSeconds {
                Text(verbatim: "\(RVFormat.compactNumber(gap)) \(RVFormat.appSeconds) · \(assessment.condition.localizedName.lowercased())")
                    .rvNumeric(10, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            NormRow(symbol: "speedometer", title: L("fd.row.moving"),
                    value: FollowingDistanceText.movingNorm(assessment, policy: policy),
                    isActive: !assessment.isStopped, tint: hasLead && !assessment.isStopped ? color : .white)
            NormRow(symbol: "hand.raised.fill", title: L("fd.row.stopped"),
                    value: FollowingDistanceText.stoppedNorm(policy: policy),
                    isActive: assessment.isStopped, tint: hasLead && assessment.isStopped ? color : .white)
            if let stopping = FollowingDistanceText.stoppingDistance(assessment) {
                NormRow(symbol: "ruler", title: L("fd.row.stopping"), value: stopping, isActive: true, tint: .white)
            }
            if hasLead, let ttc = FollowingDistanceText.timeToCollision(assessment) {
                NormRow(symbol: "exclamationmark.triangle.fill", title: L("fd.row.ttc"), value: ttc,
                        isActive: true, tint: RVTheme.danger)
            }
            if assessment.ownSpeedKmh == nil {
                Text(l: "fd.noGps")
                    .font(RVTheme.font(10, weight: .medium))
                    .foregroundStyle(RVTheme.caution)
            }
            Text(l: "fd.disclaimer")
                .font(RVTheme.font(10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private func collisionBorder(cornerRadius: CGFloat) -> some View {
        if isForwardCollisionWarning {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(RVTheme.danger, lineWidth: 2)
                .rvPulse(true, minOpacity: 0.2, period: 0.6)
        }
    }

    // MARK: - Expanded mini card (landscape)

    private var miniCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusIcon(size: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(gapText)
                        .rvNumeric(20, weight: .heavy)
                        .foregroundStyle(hasLead ? color : .white.opacity(0.55))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: isForwardCollisionWarning ? L("fd.collision") : (hasLead ? status.localizedName : L("fd.noLead")))
                        .font(RVTheme.font(10, weight: .semibold))
                        .foregroundStyle(isForwardCollisionWarning ? RVTheme.danger : .white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                normBlock(size: 14)
                infoButton
            }
            GapProgressBar(fraction: hasLead ? assessment.fractionOfRecommended : nil, color: color)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(minWidth: 180, idealWidth: 230, maxWidth: 230, alignment: .leading)
        .rvGlass(cornerRadius: RVTheme.Radius.control, tint: hasLead ? color : nil)
        .overlay { collisionBorder(cornerRadius: RVTheme.Radius.control) }
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.control, style: .continuous))
        .onTapGesture(perform: toggle)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
    }
}

// MARK: - Pieces

/// Distance vs recommended on a 0…1.5× scale with danger / caution / safe zones and a tick at 1.0.
struct GapProgressBar: View {
    /// distance / recommended; nil → empty track.
    let fraction: Double?
    let color: Color

    static let maxFraction: Double = 1.5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filled = CGFloat(min(Self.maxFraction, max(0, fraction ?? 0)) / Self.maxFraction)
            let zone = width * CGFloat(0.5 / Self.maxFraction)     // 0.5× of the recommended gap
            let tick = width * CGFloat(1 / Self.maxFraction)       // exactly the recommended gap
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    RVTheme.danger.opacity(0.22).frame(width: zone)
                    RVTheme.caution.opacity(0.22).frame(width: zone)
                    RVTheme.safe.opacity(0.22)
                }
                .frame(height: 5)
                .clipShape(Capsule())
                if fraction != nil {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(5, width * filled), height: 5)
                        .shadow(color: color.opacity(0.5), radius: 3)
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: 10)
                    .offset(x: tick - 1)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: 10)
        .animation(.smooth(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// "Сухо · авто" chip.
private struct SurfaceChip: View {
    enum Detail { case full, condition, icon }

    let condition: RoadSurfaceCondition
    let source: RoadSurfaceSource
    let detail: Detail

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: condition.symbolName)
                .symbolRenderingMode(.multicolor)
            if detail != .icon {
                Text(condition.localizedName)
            }
            if detail == .full {
                Text(verbatim: "· " + source.localizedName)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .font(RVTheme.font(10, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.12), in: Capsule())
        .accessibilityLabel(L("fd.surface.a11y", condition.localizedName, source.localizedName))
    }
}

/// One requirement row in the expanded HUD.
private struct NormRow: View {
    let symbol: String
    let title: String
    let value: String
    let isActive: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(title)
                .font(RVTheme.font(11, weight: isActive ? .bold : .medium))
            Spacer(minLength: 6)
            Text(value)
                .rvNumeric(11, weight: .bold)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
        }
        .opacity(isActive ? 1 : 0.62)
    }
}

#Preview {
    let policy = FollowingDistancePolicy()
    let moving = FollowingDistanceCalculator.assess(distanceMeters: 18, ownSpeedKmh: 60, relativeSpeedKmh: -12,
                                                    policy: policy, condition: .dry)
    let standing = FollowingDistanceCalculator.assess(distanceMeters: 1.6, ownSpeedKmh: 0, relativeSpeedKmh: nil,
                                                      policy: policy, condition: .wet)
    let lead = LeadVehicle(trackID: 1, kind: .car, box: BBox(x: 0.4, y: 0.5, width: 0.2, height: 0.1),
                           distanceMeters: 18, relativeSpeedKmh: -12, method: "width+height")
    return ZStack {
        Color(white: 0.3).ignoresSafeArea()
        VStack(spacing: 16) {
            FollowingDistanceHUD(assessment: moving, lead: lead, policy: policy, surfaceSource: .weather,
                                 isForwardCollisionWarning: false) {}
            FollowingDistanceHUD(assessment: standing, lead: lead, policy: policy, surfaceSource: .manual,
                                 isForwardCollisionWarning: false, style: .mini) {}
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
