import SwiftUI

/// Compact, glanceable GPS speed read-out (≈ 64 pt tall; `compact` ≈ 50 pt) with the current speed limit sign next to it.
///
/// When the speed exceeds `limitKmh + warningTolerance` (and `warningEnabled` is true) the number and the
/// background turn red and the border pulses. Speaking the warning is the caller's job.
struct SpeedometerView: View {
    let speedKmh: Double?
    let limitKmh: Int?
    let warningTolerance: Double
    let compact: Bool
    let warningEnabled: Bool

    init(speedKmh: Double?, limitKmh: Int?, warningTolerance: Double = 5, compact: Bool = false,
         warningEnabled: Bool = true) {
        self.speedKmh = speedKmh
        self.limitKmh = limitKmh
        self.warningTolerance = warningTolerance
        self.compact = compact
        self.warningEnabled = warningEnabled
    }

    /// True when the GPS speed is above the limit plus the tolerance.
    static func isOverLimit(speedKmh: Double?, limitKmh: Int?, tolerance: Double) -> Bool {
        guard let speedKmh, let limitKmh, limitKmh > 0, speedKmh.isFinite else { return false }
        return speedKmh > Double(limitKmh) + max(0, tolerance)
    }

    private var isOverLimit: Bool {
        warningEnabled && Self.isOverLimit(speedKmh: speedKmh, limitKmh: limitKmh, tolerance: warningTolerance)
    }

    /// Below 1 km/h the GPS speed is mostly noise, so it is shown as 0.
    private var speedText: String {
        guard let speedKmh, speedKmh.isFinite else { return "—" }
        return speedKmh < 1 ? "0" : RVFormat.speed(speedKmh)
    }

    private var numberSize: CGFloat { compact ? 24 : 32 }
    private var signSize: CGFloat { compact ? 30 : 36 }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            VStack(alignment: .center, spacing: -3) {
                Text(speedText)
                    .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isOverLimit ? Color.red : Color.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: compact ? 36 : 46)
                Text(verbatim: RVFormat.appKmh)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOverLimit ? Color.red.opacity(0.9) : Color.white.opacity(0.75))
            }
            if let limitKmh, limitKmh > 0 {
                SpeedLimitSignView(kmh: limitKmh, size: signSize)
            }
        }
        .rvTextShadow()
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 6)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(RVTheme.HUD.materialOpacity)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.red.opacity(isOverLimit ? 0.28 : 0))
                }
        }
        .overlay {
            OverLimitBorder(active: isOverLimit, cornerRadius: cornerRadius)
        }
        .animation(.easeInOut(duration: 0.25), value: isOverLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let speedKmh, speedKmh.isFinite {
            parts.append(L("speedo.a11y.speed", speedKmh < 1 ? "0" : RVFormat.speed(speedKmh)))
        } else {
            parts.append(L("speedo.a11y.unknown"))
        }
        if let limitKmh, limitKmh > 0 {
            parts.append(L("speedo.a11y.limit", limitKmh))
        }
        if isOverLimit {
            parts.append(L("speedo.a11y.over"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Pulsing red border shown while the speed limit is exceeded.
private struct OverLimitBorder: View {
    let active: Bool
    let cornerRadius: CGFloat
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(active ? Color.red : Color.white.opacity(0.15), lineWidth: active ? 2 : 0.75)
            .opacity(active ? (pulse ? 1 : 0.45) : 1)
            .onAppear { updatePulse(active) }
            .onChange(of: active) { _, newValue in updatePulse(newValue) }
    }

    private func updatePulse(_ isActive: Bool) {
        if isActive {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulse = false
            }
        }
    }
}

/// Round speed-limit sign: white disc, red ring, black number — like a real road sign.
struct SpeedLimitSignView: View {
    let kmh: Int
    let size: CGFloat

    init(kmh: Int, size: CGFloat = 44) {
        self.kmh = kmh
        self.size = size
    }

    private var fontSize: CGFloat {
        switch kmh {
        case 100...: return size * 0.36
        case 10..<100: return size * 0.44
        default: return size * 0.5
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .strokeBorder(Color(red: 0.86, green: 0.08, blue: 0.1), lineWidth: max(2.5, size * 0.12))
            Text("\(kmh)")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("speedo.a11y.limitSign", kmh))
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 20) {
            SpeedometerView(speedKmh: 54, limitKmh: 60)
            SpeedometerView(speedKmh: 78, limitKmh: 60)
            SpeedometerView(speedKmh: nil, limitKmh: nil)
            SpeedometerView(speedKmh: 112, limitKmh: 100, compact: true)
            HStack {
                SpeedLimitSignView(kmh: 40)
                SpeedLimitSignView(kmh: 110, size: 64)
            }
        }
    }
}
