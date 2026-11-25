import Foundation

/// Congestion level of a route or road.
public enum CongestionLevel: String, Codable, Sendable, CaseIterable {
    case free, light, moderate, heavy, severe

    /// Russian display name.
    public var displayName: String {
        switch self {
        case .free: return "Свободно"
        case .light: return "Небольшие затруднения"
        case .moderate: return "Умеренные пробки"
        case .heavy: return "Сильные пробки"
        case .severe: return "Очень сильные пробки"
        }
    }

    /// 0 (free) … 4 (severe), e.g. for colouring.
    public var severity: Int {
        switch self {
        case .free: return 0
        case .light: return 1
        case .moderate: return 2
        case .heavy: return 3
        case .severe: return 4
        }
    }
}

/// Traffic on a route, derived by comparing the current ETA with a free-flow ETA
/// (e.g. MapKit ETA now vs. for a 03:00 departure). An estimate, not measured traffic data.
public struct TrafficAssessment: Hashable, Sendable {
    /// Travel time with current traffic, seconds.
    public var currentSeconds: Double
    /// Travel time without traffic, seconds.
    public var freeFlowSeconds: Double

    public init(currentSeconds: Double, freeFlowSeconds: Double) {
        self.currentSeconds = currentSeconds
        self.freeFlowSeconds = freeFlowSeconds
    }

    /// `max(0, current − freeFlow)` seconds (0 for invalid input).
    public var delaySeconds: Double {
        guard currentSeconds.isFinite, freeFlowSeconds.isFinite else { return 0 }
        return max(0, currentSeconds - freeFlowSeconds)
    }

    /// `current / freeFlow` (1 when the free-flow time is unknown or not positive).
    public var ratio: Double {
        guard currentSeconds.isFinite, freeFlowSeconds.isFinite, freeFlowSeconds > 0, currentSeconds >= 0 else { return 1 }
        return currentSeconds / freeFlowSeconds
    }

    /// < 1.1 free, < 1.25 light, < 1.5 moderate, < 2 heavy, otherwise severe.
    public var level: CongestionLevel {
        let r = ratio
        if r < 1.1 { return .free }
        if r < 1.25 { return .light }
        if r < 1.5 { return .moderate }
        if r < 2 { return .heavy }
        return .severe
    }

    /// Russian one-liner, marked as an estimate: "Умеренные пробки, задержка ≈ 7 мин (оценка)".
    public var summary: String {
        let delay = delaySeconds
        if level == .free || delay < 60 { return "\(level.displayName) (оценка)" }
        return "\(level.displayName), задержка ≈ \(RVFormat.duration(delay)) (оценка)"
    }
}

public enum TrafficDelay {
    /// Next `hour`:00 local time strictly after `date` (used as a low-traffic departure for the free-flow ETA).
    /// `hour` is clamped to 0…23. Handles days where that hour is skipped by a DST change.
    public static func nextOffPeakDate(after date: Date, calendar: Calendar = .current, hour: Int = 3) -> Date {
        let h = min(23, max(0, hour))
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            var components = calendar.dateComponents([.era, .year, .month, .day], from: day)
            components.hour = h
            components.minute = 0
            components.second = 0
            if let candidate = calendar.date(from: components), candidate > date {
                return candidate
            }
        }
        // Unreachable for real calendars; keep a sane fallback.
        return date.addingTimeInterval(24 * 3600)
    }
}
