import SwiftUI

/// Large, glanceable GPS speed read-out with the current speed limit sign next to it.
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

    private var numberSize: CGFloat { compact ? 34 : 56 }
    private var signSize: CGFloat { compact ? 38 : 52 }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            VStack(alignment: .center, spacing: compact ? -2 : -4) {
                Text(speedText)
                    .font(.system(size: numberSize, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isOverLimit ? Color.red : Color.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: compact ? 48 : 78)
                Text("км/ч")
                    .font(.system(size: compact ? 11 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOverLimit ? Color.red.opacity(0.9) : Color.white.opacity(0.75))
            }
            if let limitKmh, limitKmh > 0 {
                SpeedLimitSignView(kmh: limitKmh, size: signSize)
            }
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 6 : 8)
        .background {
            RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                        .fill(Color.red.opacity(isOverLimit ? 0.28 : 0))
                }
        }
        .overlay {
            OverLimitBorder(active: isOverLimit, cornerRadius: compact ? 16 : 22)
        }
        .animation(.easeInOut(duration: 0.25), value: isOverLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let speedKmh, speedKmh.isFinite {
            parts.append("Скорость \(speedKmh < 1 ? "0" : RVFormat.speed(speedKmh)) км/ч")
        } else {
            parts.append("Скорость неизвестна")
        }
        if let limitKmh, limitKmh > 0 {
            parts.append("ограничение \(limitKmh) км/ч")
        }
        if isOverLimit {
            parts.append("превышение скорости")
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
            .strokeBorder(active ? Color.red : Color.white.opacity(0.15), lineWidth: active ? 3 : 1)
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
                .strokeBorder(Color(red: 0.86, green: 0.08, blue: 0.1), lineWidth: max(3, size * 0.12))
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
        .accessibilityLabel("Ограничение скорости \(kmh) км/ч")
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
