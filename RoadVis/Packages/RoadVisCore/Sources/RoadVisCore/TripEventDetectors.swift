import Foundation

/// Speeding episodes: own GPS speed above limit + tolerance for at least `speedingMinSeconds` (≥ 5 s).
///
/// While the episode lasts, every update returns an event that starts at the beginning of the episode with the
/// duration so far and the worst excess (km/h over the limit). Feed the events into `DrivingEventDebouncer`: they merge
/// into one event per episode.
public struct SpeedingDetector: Sendable {
    public var thresholds: TripThresholds
    private var overSince: Date?
    private var startCoordinate: GeoPoint?
    private var startSpeed: Double?
    private var maxExcess: Double = 0
    private var limitAtStart: Int?

    public init(thresholds: TripThresholds = .default) {
        self.thresholds = thresholds
    }

    public mutating func update(date: Date, speedKmh: Double?, limitKmh: Int?, coordinate: GeoPoint?) -> DrivingEvent? {
        guard let speed = speedKmh, speed.isFinite, let limit = limitKmh, limit > 0,
              speed > Double(limit) + thresholds.speedToleranceKmh else {
            reset()
            return nil
        }
        if overSince == nil || limitAtStart != limit {
            overSince = date
            startCoordinate = coordinate
            startSpeed = speed
            maxExcess = 0
            limitAtStart = limit
        }
        maxExcess = max(maxExcess, speed - Double(limit))
        guard let since = overSince else { return nil }
        let held = date.timeIntervalSince(since)
        guard held >= thresholds.speedingMinSeconds else { return nil }
        return DrivingEvent(kind: .speeding, date: since, coordinate: startCoordinate ?? coordinate,
                            speedKmh: max(startSpeed ?? speed, speed), value: maxExcess, limit: Double(limit),
                            duration: held)
    }

    public mutating func reset() {
        overSince = nil
        startCoordinate = nil
        startSpeed = nil
        maxExcess = 0
        limitAtStart = nil
    }
}

/// Harsh braking / acceleration from the GPS speed derivative, optionally confirmed by the motion sensors.
///
/// - GPS: a = Δv / Δt between the newest fix and the oldest fix not more than `derivativeSpan` (2 s) back, with
///   Δt ≥ `minimumSpan` (0.9 s). |a| beyond the threshold → event.
/// - Motion (CMDeviceMotion.userAcceleration magnitude, gravity removed, m/s²; the phone's mounting orientation is
///   unknown, so only the magnitude is used): when |a_GPS| reaches 75 % of the threshold and the peak magnitude of the
///   last `derivativeSpan` seconds reaches the full threshold, the event is recorded too (sign from GPS).
/// - Braking needs ≥ `minimumSpeedKmh` before, acceleration ≥ `minimumSpeedKmh` after; `cooldown` per kind.
public struct HarshMotionDetector: Sendable {
    public var thresholds: TripThresholds
    public var derivativeSpan: TimeInterval = 2
    public var minimumSpan: TimeInterval = 0.9
    public var minimumSpeedKmh: Double = 10
    public var cooldown: TimeInterval = 4
    public var motionConfirmationFactor: Double = 0.75

    private var samples: [(date: Date, mps: Double)] = []
    private var motion: [(date: Date, magnitude: Double)] = []
    private var lastEventDate: [DrivingEventKind: Date] = [:]
    /// Latest GPS derivative, m/s² (for diagnostics / UI).
    public private(set) var lastAcceleration: Double?

    public init(thresholds: TripThresholds = .default) {
        self.thresholds = thresholds
    }

    /// User acceleration magnitude in m/s² (gravity removed).
    public mutating func addMotion(date: Date, magnitude: Double) {
        guard magnitude.isFinite else { return }
        motion.append((date, magnitude))
        let cutoff = date.addingTimeInterval(-max(derivativeSpan, 1) - 0.5)
        if let first = motion.first, first.date < cutoff {
            motion.removeAll { $0.date < cutoff }
        }
    }

    public mutating func addSpeed(date: Date, speedKmh: Double, coordinate: GeoPoint?) -> DrivingEvent? {
        guard speedKmh.isFinite, speedKmh >= 0 else { return nil }
        let mps = speedKmh / 3.6
        samples.append((date, mps))
        samples.removeAll { date.timeIntervalSince($0.date) > derivativeSpan + 0.05 }
        guard let reference = samples.first(where: { date.timeIntervalSince($0.date) >= minimumSpan }) else {
            lastAcceleration = nil
            return nil
        }
        let dt = date.timeIntervalSince(reference.date)
        guard dt > 0 else { return nil }
        let a = (mps - reference.mps) / dt
        lastAcceleration = a

        let peak = motion.filter { date.timeIntervalSince($0.date) <= derivativeSpan }.map(\.magnitude).max()
        let kind: DrivingEventKind
        let threshold: Double
        if a < 0 {
            guard reference.mps * 3.6 >= minimumSpeedKmh else { return nil }
            kind = .harshBraking
            threshold = abs(thresholds.harshBrakingMps2)
        } else {
            guard speedKmh >= minimumSpeedKmh else { return nil }
            kind = .harshAcceleration
            threshold = thresholds.harshAccelerationMps2
        }
        let magnitude = abs(a)
        let byGPS = magnitude >= threshold
        let byMotion = magnitude >= threshold * motionConfirmationFactor && (peak ?? 0) >= threshold
        guard byGPS || byMotion else { return nil }
        if let last = lastEventDate[kind], date.timeIntervalSince(last) < cooldown { return nil }
        lastEventDate[kind] = date
        let value = byGPS ? magnitude : max(magnitude, peak ?? magnitude)
        return DrivingEvent(kind: kind, date: date, coordinate: coordinate, speedKmh: reference.mps * 3.6,
                            value: (value * 100).rounded() / 100, limit: threshold, duration: 0,
                            note: byGPS ? "GPS" : "GPS + датчики движения")
    }

    public mutating func reset() {
        samples.removeAll()
        motion.removeAll()
        lastEventDate.removeAll()
        lastAcceleration = nil
    }
}
