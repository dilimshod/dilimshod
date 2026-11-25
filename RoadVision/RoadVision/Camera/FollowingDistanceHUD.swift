import SwiftUI

/// Glass card with the gap to the vehicle ahead and the distance requirements.
///
/// `.full` (portrait, above the record button): status line with the road-surface chip and an info button,
/// big "≈ 18 м" (numeric transition), the recommended gap, a progress bar of distance vs recommended (0…1.5×, tick at
/// 1.0) and either a one-line summary of both norms or — tap to expand — the rows
/// "В движении: ≥ 2 с ≈ 33 м (сухо)", "При остановке: ≥ 2 м", "Остановочный путь ≈ 37 м", "До столкновения ≈ 2,1 с".
/// `.mini` (landscape, leading column): number, status, norm and the bar; tap opens the norms sheet.
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
            switch style {
            case .full: fullCard
            case .mini: miniCard
            }
        }
        .animation(RVTheme.snappy, value: gapText)
        .animation(RVTheme.snappy, value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FollowingDistanceText.accessibilitySummary(assessment, policy: policy, hasLead: hasLead))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAction {
            if style == .full {
                withAnimation(RVTheme.snappy) { expanded.toggle() }
            } else {
                onShowNorms()
            }
        }
        .accessibilityAction(named: Text("Требования к дистанции")) { onShowNorms() }
    }

    private var accessibilityHintText: String {
        guard style == .full else { return "Открыть требования к дистанции" }
        return expanded ? "Скрыть подробности" : "Показать подробности"
    }

    // MARK: - Full card

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .center, spacing: 12) {
                gapBlock(size: 38)
                Spacer(minLength: 8)
                normBlock(size: 22)
            }
            GapProgressBar(fraction: hasLead ? assessment.fractionOfRecommended : nil, color: color)
            if expanded {
                detailRows
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                compactFooter
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .rvGlass(cornerRadius: RVTheme.Radius.card, tint: hasLead ? color : nil)
        .overlay { collisionBorder }
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous))
        .onTapGesture {
            withAnimation(RVTheme.snappy) { expanded.toggle() }
        }
        .sensoryFeedback(.selection, trigger: expanded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon(size: 16)
            Text(headerTitle)
                .font(RVTheme.font(15, weight: .bold))
                .foregroundStyle(isForwardCollisionWarning ? RVTheme.danger : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            ViewThatFits(in: .horizontal) {
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .full)
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .condition)
                SurfaceChip(condition: assessment.condition, source: surfaceSource, detail: .icon)
            }
            Button(action: onShowNorms) {
                Image(systemName: "info.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RVPressableButtonStyle())
            .padding(.trailing, -10)
            .accessibilityLabel("Требования к дистанции")
        }
    }

    private var headerTitle: String {
        if isForwardCollisionWarning { return "Опасное сближение!" }
        return status.displayName
    }

    private func statusIcon(size: CGFloat) -> some View {
        Image(systemName: isForwardCollisionWarning ? "exclamationmark.octagon.fill" : RVTheme.statusSymbol(status))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .danger)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size + 6)
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
                .rvNumeric(12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
    }

    private var gapCaption: String {
        guard hasLead else { return "машина впереди не найдена" }
        if !assessment.isStopped, let headway = assessment.timeHeadwaySeconds {
            return RVFormat.gapSeconds(headway) + " до машины · оценка"
        }
        return "оценка по камере"
    }

    private func normBlock(size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(assessment.isStopped ? "норма стоя" : "норма")
                .font(RVTheme.font(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(FollowingDistanceText.recommended(assessment))
                .rvNumeric(size, weight: .bold)
                .contentTransition(.numericText())
                .lineLimit(1)
            if !assessment.isStopped, let gap = assessment.recommendedTimeGapSeconds {
                Text("\(RVFormat.compactNumber(gap)) с · \(assessment.condition.displayName.lowercased())")
                    .rvNumeric(11, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var compactFooter: some View {
        HStack(spacing: 6) {
            Text(FollowingDistanceText.compactNorms(assessment, policy: policy))
                .rvNumeric(13, weight: .semibold)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            if hasLead, let ttc = FollowingDistanceText.timeToCollision(assessment) {
                Label(ttc, systemImage: "timer")
                    .rvNumeric(13, weight: .bold)
                    .foregroundStyle(RVTheme.danger)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            NormRow(symbol: "speedometer", title: "В движении:",
                    value: FollowingDistanceText.movingNorm(assessment, policy: policy),
                    isActive: !assessment.isStopped, tint: hasLead && !assessment.isStopped ? color : .white)
            NormRow(symbol: "hand.raised.fill", title: "При остановке:",
                    value: FollowingDistanceText.stoppedNorm(policy: policy),
                    isActive: assessment.isStopped, tint: hasLead && assessment.isStopped ? color : .white)
            if let stopping = FollowingDistanceText.stoppingDistance(assessment) {
                NormRow(symbol: "ruler", title: "Остановочный путь", value: stopping, isActive: true, tint: .white)
            }
            if hasLead, let ttc = FollowingDistanceText.timeToCollision(assessment) {
                NormRow(symbol: "exclamationmark.triangle.fill", title: "До столкновения", value: ttc,
                        isActive: true, tint: RVTheme.danger)
            }
            if assessment.ownSpeedKmh == nil {
                Text("Нет скорости GPS — показана норма для стоящего автомобиля.")
                    .font(RVTheme.font(11, weight: .medium))
                    .foregroundStyle(RVTheme.caution)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Оценка по одной камере, не заменяет внимание водителя.")
                    .font(RVTheme.font(11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var collisionBorder: some View {
        if isForwardCollisionWarning {
            RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous)
                .strokeBorder(RVTheme.danger, lineWidth: 3)
                .rvPulse(true, minOpacity: 0.2, period: 0.6)
        }
    }

    // MARK: - Mini card

    private var miniCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                statusIcon(size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(gapText)
                        .rvNumeric(28, weight: .heavy)
                        .foregroundStyle(hasLead ? color : .white.opacity(0.55))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(isForwardCollisionWarning ? "Опасное сближение!" : (hasLead ? status.displayName : "нет машины впереди"))
                        .font(RVTheme.font(11, weight: .semibold))
                        .foregroundStyle(isForwardCollisionWarning ? RVTheme.danger : .white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                normBlock(size: 17)
            }
            GapProgressBar(fraction: hasLead ? assessment.fractionOfRecommended : nil, color: color)
        }
        .foregroundStyle(.white)
        .padding(12)
        // Shrinks a little on narrow landscape screens so it never pushes into the counters panel.
        .frame(minWidth: 190, idealWidth: 250, maxWidth: 250, alignment: .leading)
        .rvGlass(cornerRadius: RVTheme.Radius.panel, tint: hasLead ? color : nil)
        .overlay {
            if isForwardCollisionWarning {
                RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous)
                    .strokeBorder(RVTheme.danger, lineWidth: 3)
                    .rvPulse(true, minOpacity: 0.2, period: 0.6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.panel, style: .continuous))
        .onTapGesture(perform: onShowNorms)
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
                .frame(height: 8)
                .clipShape(Capsule())
                if fraction != nil {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, width * filled), height: 8)
                        .shadow(color: color.opacity(0.6), radius: 4)
                }
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2.5, height: 15)
                    .offset(x: tick - 1.25)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .frame(width: width, height: proxy.size.height)
        }
        .frame(height: 15)
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
                Text(condition.displayName)
            }
            if detail == .full {
                Text("· " + source.displayName)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .font(RVTheme.font(11, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.12), in: Capsule())
        .accessibilityLabel("Покрытие: \(condition.displayName), \(source.displayName)")
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
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(RVTheme.font(13, weight: isActive ? .bold : .medium))
            Spacer(minLength: 6)
            Text(value)
                .rvNumeric(13, weight: .bold)
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
                           distanceMeters: 18, relativeSpeedKmh: -12, method: "ширина+высота")
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
