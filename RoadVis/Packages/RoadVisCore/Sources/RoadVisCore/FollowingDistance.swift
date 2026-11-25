import Foundation

// MARK: - Road surface

/// Road surface condition used to scale the recommended following distance.
public enum RoadSurfaceCondition: String, Codable, Hashable, Sendable, CaseIterable {
    case dry, wet, snow, ice

    public var displayName: String {
        switch self {
        case .dry: return "Сухо"
        case .wet: return "Мокро"
        case .snow: return "Снег"
        case .ice: return "Гололёд"
        }
    }

    public var symbolName: String {
        switch self {
        case .dry: return "sun.max.fill"
        case .wet: return "cloud.rain.fill"
        case .snow: return "snowflake"
        case .ice: return "thermometer.snowflake"
        }
    }

    /// Typical tyre–road friction coefficient for braking (engineering approximation: dry ≈ 0.7 per the UK Highway Code
    /// stopping-distance table, wet 0.35 per AASHTO's 3.4 m/s² design deceleration, snow ≈ 0.2 and ice ≈ 0.1 per PIARC curves).
    public var frictionCoefficient: Double {
        switch self {
        case .dry: return 0.7
        case .wet: return 0.35
        case .snow: return 0.2
        case .ice: return 0.1
        }
    }

    /// Guesses the surface from Open-Meteo current weather (WMO code, °C, mm of precipitation).
    public static func from(weatherCode: Int?, temperatureC: Double?, precipitationMm: Double?) -> RoadSurfaceCondition {
        let code = weatherCode ?? 0
        let temp = temperatureC ?? 15
        let precip = precipitationMm ?? 0
        let freezing: Set<Int> = [56, 57, 66, 67]
        let snow: Set<Int> = [71, 73, 75, 77, 85, 86]
        let rain: Set<Int> = [51, 53, 55, 61, 63, 65, 80, 81, 82, 95, 96, 97, 99]
        if freezing.contains(code) || (temp <= 0 && rain.contains(code)) || (code == 48 && temp <= 0) {
            return .ice
        }
        if snow.contains(code) { return temp <= -2 ? .ice : .snow }
        if rain.contains(code) || precip > 0.1 { return temp <= 1 ? .ice : .wet }
        return .dry
    }
}

// MARK: - Policy

/// Following-distance settings. Defaults are RECOMMENDATIONS, not legal norms — the Uzbek traffic rules (п.73) require a
/// safe distance without giving a number: 2 s in the dry and at least double (4 s) on wet roads (UK Highway Code rule 126),
/// up to ten times on ice (rule 126: "up to ten times greater"), 6 s on snow (app choice), ≥ 2 m when standing (app choice).
public struct FollowingDistancePolicy: Codable, Hashable, Sendable {
    public var timeGapDry: Double
    public var timeGapWet: Double
    public var timeGapSnow: Double
    public var timeGapIce: Double
    /// Minimum gap to the vehicle ahead when standing (queue, traffic light), metres.
    public var stoppedGapMeters: Double
    /// Driver reaction time used for the stopping-distance estimate, seconds.
    public var reactionTimeSeconds: Double
    /// Below this own speed the car is considered standing, km/h.
    public var stoppedSpeedKmh: Double
    /// Forward-collision warning threshold (time to collision), seconds.
    public var collisionWarningSeconds: Double

    public init(timeGapDry: Double = 2, timeGapWet: Double = 4, timeGapSnow: Double = 6, timeGapIce: Double = 10,
                stoppedGapMeters: Double = 2, reactionTimeSeconds: Double = 1,
                stoppedSpeedKmh: Double = 5, collisionWarningSeconds: Double = 2.5) {
        self.timeGapDry = timeGapDry
        self.timeGapWet = timeGapWet
        self.timeGapSnow = timeGapSnow
        self.timeGapIce = timeGapIce
        self.stoppedGapMeters = stoppedGapMeters
        self.reactionTimeSeconds = reactionTimeSeconds
        self.stoppedSpeedKmh = stoppedSpeedKmh
        self.collisionWarningSeconds = collisionWarningSeconds
    }

    public func timeGap(for condition: RoadSurfaceCondition) -> Double {
        switch condition {
        case .dry: return timeGapDry
        case .wet: return timeGapWet
        case .snow: return timeGapSnow
        case .ice: return timeGapIce
        }
    }
}

// MARK: - Assessment

public enum DistanceStatus: String, Codable, Hashable, Sendable {
    case safe, caution, danger, unknown

    public var displayName: String {
        switch self {
        case .safe: return "Дистанция в норме"
        case .caution: return "Мала дистанция"
        case .danger: return "Опасно близко"
        case .unknown: return "Нет данных"
        }
    }
}

public struct FollowingDistanceAssessment: Hashable, Sendable {
    public var distanceMeters: Double?
    public var ownSpeedKmh: Double?
    public var isStopped: Bool
    public var condition: RoadSurfaceCondition
    /// Recommended minimum gap for the current state, metres.
    public var recommendedDistanceMeters: Double
    /// Recommended time gap (moving) — nil when stopped.
    public var recommendedTimeGapSeconds: Double?
    /// Estimated stopping distance = reaction distance + braking distance, metres (moving only).
    public var stoppingDistanceMeters: Double?
    /// Time headway = distance / own speed, seconds (moving only).
    public var timeHeadwaySeconds: Double?
    /// Closing speed, km/h; positive = the gap is shrinking.
    public var closingSpeedKmh: Double?
    /// Time to collision at the current closing speed, seconds (only when closing).
    public var timeToCollisionSeconds: Double?
    /// distance / recommended (1 = exactly the recommended gap).
    public var fractionOfRecommended: Double?
    public var status: DistanceStatus

    public var isCollisionWarning: Bool {
        status == .danger && (timeToCollisionSeconds ?? .infinity) < .infinity
    }
}

public enum FollowingDistanceCalculator {
    /// S = v·t_r + v² / (2·μ·g), metres.
    public static func stoppingDistance(speedKmh: Double, reactionTime: Double, friction: Double) -> Double {
        let v = max(0, speedKmh) / 3.6
        let mu = max(0.05, friction)
        return v * max(0, reactionTime) + v * v / (2 * mu * 9.81)
    }

    /// Recommended minimum gap: own speed × time gap while moving (never below the stopped gap), stopped gap otherwise.
    public static func recommendedDistance(speedKmh: Double?, policy: FollowingDistancePolicy,
                                           condition: RoadSurfaceCondition) -> Double {
        let speed = max(0, speedKmh ?? 0)
        guard speed >= policy.stoppedSpeedKmh else { return policy.stoppedGapMeters }
        return max(policy.stoppedGapMeters, speed / 3.6 * policy.timeGap(for: condition))
    }

    /// - Parameter relativeSpeedKmh: rate of change of the gap (positive = lead pulling away), from the lead tracker.
    public static func assess(distanceMeters: Double?, ownSpeedKmh: Double?, relativeSpeedKmh: Double?,
                              policy: FollowingDistancePolicy, condition: RoadSurfaceCondition) -> FollowingDistanceAssessment {
        let speed = ownSpeedKmh.map { max(0, $0) }
        let stopped = (speed ?? 0) < policy.stoppedSpeedKmh
        let recommended = recommendedDistance(speedKmh: speed, policy: policy, condition: condition)
        var a = FollowingDistanceAssessment(distanceMeters: distanceMeters, ownSpeedKmh: speed, isStopped: stopped,
                                            condition: condition, recommendedDistanceMeters: recommended,
                                            recommendedTimeGapSeconds: stopped ? nil : policy.timeGap(for: condition),
                                            stoppingDistanceMeters: nil, timeHeadwaySeconds: nil,
                                            closingSpeedKmh: nil, timeToCollisionSeconds: nil,
                                            fractionOfRecommended: nil, status: .unknown)
        if let s = speed, !stopped {
            a.stoppingDistanceMeters = stoppingDistance(speedKmh: s, reactionTime: policy.reactionTimeSeconds,
                                                        friction: condition.frictionCoefficient)
        }
        guard let d = distanceMeters, d.isFinite, d > 0 else { return a }

        if let s = speed, !stopped { a.timeHeadwaySeconds = d / (s / 3.6) }
        if let rel = relativeSpeedKmh {
            let closing = -rel
            a.closingSpeedKmh = closing
            if closing > 3 {   // ignore noise below 3 km/h
                a.timeToCollisionSeconds = d / (closing / 3.6)
            }
        }
        let fraction = d / max(0.1, recommended)
        a.fractionOfRecommended = fraction

        if let ttc = a.timeToCollisionSeconds, ttc < policy.collisionWarningSeconds, !stopped {
            a.status = .danger
        } else if fraction >= 1 {
            a.status = .safe
        } else if fraction >= 0.5 {
            a.status = .caution
        } else {
            a.status = .danger
        }
        return a
    }
}

// MARK: - Lead vehicle

/// Trapezoidal region of the image where the own lane is expected (normalized coordinates, y down).
public struct EgoCorridor: Hashable, Codable, Sendable {
    public var centerX: Double
    /// Approximate horizon line (fraction of image height); nothing above it is "in our lane".
    public var horizonY: Double
    /// Half width of the corridor at the bottom edge (fraction of image width).
    public var bottomHalfWidth: Double
    /// Half width at the horizon.
    public var horizonHalfWidth: Double

    public init(centerX: Double = 0.5, horizonY: Double = 0.42, bottomHalfWidth: Double = 0.24, horizonHalfWidth: Double = 0.04) {
        self.centerX = centerX
        self.horizonY = horizonY
        self.bottomHalfWidth = bottomHalfWidth
        self.horizonHalfWidth = horizonHalfWidth
    }

    public static let `default` = EgoCorridor()

    /// Half width of the corridor at image row y.
    public func halfWidth(atY y: Double) -> Double {
        guard y > horizonY else { return 0 }
        let t = min(1, (y - horizonY) / max(0.01, 1 - horizonY))
        return horizonHalfWidth + (bottomHalfWidth - horizonHalfWidth) * t
    }

    /// True when the box's bottom edge overlaps the corridor at its row.
    public func contains(_ box: BBox) -> Bool {
        let y = min(1, box.maxY)
        let hw = halfWidth(atY: y)
        guard hw > 0 else { return false }
        let left = centerX - hw, right = centerX + hw
        let overlap = min(right, box.maxX) - max(left, box.minX)
        // Require the box centre inside, or at least 40 % of the box width overlapping.
        return (box.midX >= left && box.midX <= right) || overlap >= 0.4 * box.width
    }

    /// Corridor polygon (bottom-left, top-left, top-right, bottom-right) for drawing.
    public var polygon: [(x: Double, y: Double)] {
        [(centerX - bottomHalfWidth, 1), (centerX - horizonHalfWidth, horizonY),
         (centerX + horizonHalfWidth, horizonY), (centerX + bottomHalfWidth, 1)]
    }
}

/// The vehicle directly ahead in the own lane, with a fused distance estimate.
public struct LeadVehicle: Hashable, Sendable {
    public var trackID: Int
    public var kind: VehicleKind
    public var box: BBox
    /// Smoothed distance estimate, metres (≈, single camera).
    public var distanceMeters: Double
    /// Rate of change of the gap, km/h (positive = pulling away), nil until enough samples.
    public var relativeSpeedKmh: Double?
    /// Which cues were used: "ширина+высота", "ширина", "высота".
    public var method: String
}

/// Selects the lead vehicle (closest confirmed vehicle inside the ego corridor, with hysteresis) and estimates
/// its distance by fusing the apparent width and height of its box with typical vehicle dimensions.
public final class LeadVehicleTracker {
    public var corridor: EgoCorridor
    private var currentID: Int?
    private var smoothed: Double?
    private var samples: [(t: TimeInterval, d: Double)] = []
    private var lostSince: TimeInterval?

    public init(corridor: EgoCorridor = .default) {
        self.corridor = corridor
    }

    public func reset() {
        currentID = nil
        smoothed = nil
        samples.removeAll()
        lostSince = nil
    }

    /// Raw (unsmoothed) distance for a box, or nil when no cue is usable.
    public static func rawDistance(for kind: VehicleKind, box: BBox, geometry: CameraGeometry) -> (Double, String)? {
        let f = geometry.focalLengthPixels
        var estimates: [Double] = []
        var cues: [String] = []
        let widthTruncated = box.minX <= 0.005 || box.maxX >= 0.995
        let heightTruncated = box.maxY >= 0.985 || box.minY <= 0.005
        if let w = kind.typicalWidthMeters, !widthTruncated, box.width > 0.01, geometry.imageWidth > 0 {
            estimates.append(f * w / (box.width * geometry.imageWidth))
            cues.append("ширина")
        }
        if let h = kind.typicalHeightMeters, !heightTruncated, box.height > 0.01, geometry.imageHeight > 0 {
            estimates.append(f * h / (box.height * geometry.imageHeight))
            cues.append("высота")
        }
        guard !estimates.isEmpty else {
            // Box fills the frame (very close): use the width cue even if truncated as an upper bound.
            if let w = kind.typicalWidthMeters, box.width > 0.01, geometry.imageWidth > 0 {
                return (f * w / (box.width * geometry.imageWidth), "ширина (обрезано)")
            }
            return nil
        }
        let d = estimates.reduce(0, +) / Double(estimates.count)
        return (d, cues.joined(separator: "+"))
    }

    public func update(tracks: [TrackedObject], geometry: CameraGeometry, timestamp: TimeInterval) -> LeadVehicle? {
        let candidates = tracks.filter {
            $0.isConfirmed && $0.missed == 0 && $0.kind.isVehicle && $0.kind != .bicycle && corridor.contains($0.box)
        }
        // Keep the previous lead while it stays in the corridor unless another vehicle is clearly closer.
        let closest = candidates.max { $0.box.maxY < $1.box.maxY }
        var chosen = closest
        if let id = currentID, let previous = candidates.first(where: { $0.id == id }) {
            if let c = closest, c.id != id, c.box.maxY > previous.box.maxY + 0.05 {
                chosen = c
            } else {
                chosen = previous
            }
        }
        guard let lead = chosen, let (raw, method) = Self.rawDistance(for: lead.kind, box: lead.box, geometry: geometry),
              raw.isFinite, raw > 0.3, raw < 150 else {
            if lostSince == nil { lostSince = timestamp }
            if let since = lostSince, timestamp - since > 0.8 { reset() }
            return nil
        }
        lostSince = nil
        if lead.id != currentID {
            currentID = lead.id
            smoothed = nil
            samples.removeAll()
        }
        let alpha = 0.35
        let value = smoothed.map { $0 + alpha * (raw - $0) } ?? raw
        smoothed = value
        samples.append((timestamp, value))
        samples.removeAll { timestamp - $0.t > 1.2 }

        var rel: Double?
        if samples.count >= 4, let first = samples.first, timestamp - first.t >= 0.5 {
            let n = Double(samples.count)
            let mt = samples.reduce(0) { $0 + $1.t } / n
            let md = samples.reduce(0) { $0 + $1.d } / n
            var num = 0.0, den = 0.0
            for s in samples {
                num += (s.t - mt) * (s.d - md)
                den += (s.t - mt) * (s.t - mt)
            }
            if den > 1e-9 {
                let kmh = num / den * 3.6
                if abs(kmh) < 150 { rel = kmh }
            }
        }
        return LeadVehicle(trackID: lead.id, kind: lead.kind, box: lead.box, distanceMeters: value,
                           relativeSpeedKmh: rel, method: method)
    }
}
