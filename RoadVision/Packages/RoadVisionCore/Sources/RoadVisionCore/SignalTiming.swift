import Foundation

// No public real-time signal timing (SPaT) feed exists for the supported region, so every waiting time
// produced here is an ESTIMATE: a fixed-time signal model, refined by the user's own observed stops.

/// Assumed fixed-time signal plan used when nothing has been learned yet.
public struct SignalTimingAssumptions: Codable, Hashable, Sendable {
    /// Full signal cycle, seconds.
    public var cycleSeconds: Double
    /// Share of the cycle that is green for our approach, 0…1.
    public var greenRatio: Double

    public init(cycleSeconds: Double = 90, greenRatio: Double = 0.45) {
        self.cycleSeconds = cycleSeconds
        self.greenRatio = greenRatio
    }

    /// Red (incl. amber) time per cycle, seconds: `C · (1 − g)` with sanitised inputs.
    public var redSeconds: Double {
        let c = cycleSeconds.isFinite ? max(1, cycleSeconds) : 90
        let g = greenRatio.isFinite ? min(1, max(0, greenRatio)) : 0.45
        return c * (1 - g)
    }

    /// Cycle length with sanitised input, seconds.
    public var sanitizedCycleSeconds: Double {
        cycleSeconds.isFinite ? max(1, cycleSeconds) : 90
    }
}

/// One pass through a signalised intersection, recorded on the phone.
public struct SignalObservation: Codable, Hashable, Sendable {
    public var signalID: String
    /// Time the vehicle entered the signal area.
    public var date: Date
    /// Whether the vehicle had to stop.
    public var stopped: Bool
    /// Time spent (almost) stationary in the signal area, seconds (0 when it did not stop).
    public var waitSeconds: Double

    public init(signalID: String, date: Date, stopped: Bool, waitSeconds: Double) {
        self.signalID = signalID
        self.date = date
        self.stopped = stopped
        self.waitSeconds = waitSeconds
    }
}

/// Estimated waiting time at a signal. Always an estimate — show it with "≈" and "оценка".
public struct SignalWaitEstimate: Hashable, Sendable {
    /// Where the numbers come from.
    public enum Source: String, Sendable {
        /// Only the fixed-time model (no observations).
        case model
        /// Enough own observations (≥ 5) — model no longer used.
        case learned
        /// Model blended with a few own observations.
        case blended
    }

    /// Expected wait including the chance of not stopping at all, seconds.
    public var expectedWaitSeconds: Double
    /// Probability of having to stop, 0…1.
    public var stopProbability: Double
    /// Expected wait when the vehicle has to stop, seconds.
    public var meanWaitIfStopped: Double
    /// Observations that contributed.
    public var observationCount: Int
    public var source: Source

    public init(expectedWaitSeconds: Double, stopProbability: Double, meanWaitIfStopped: Double,
                observationCount: Int, source: Source) {
        self.expectedWaitSeconds = expectedWaitSeconds
        self.stopProbability = stopProbability
        self.meanWaitIfStopped = meanWaitIfStopped
        self.observationCount = observationCount
        self.source = source
    }

    /// Russian label of the data source.
    public var sourceDescription: String {
        switch source {
        case .model: return "оценка по типовому циклу светофора"
        case .learned: return "оценка по вашим поездкам (\(observationCount) набл.)"
        case .blended: return "оценка: типовой цикл + ваши поездки (\(observationCount) набл.)"
        }
    }
}

/// Analytical waiting time at a fixed-time signal for a vehicle arriving at a random moment of the cycle.
public enum SignalWaitModel {
    /// Random arrival, fixed-time signal: P(stop) = r/C, E[wait | stop] = r/2, E[wait] = r²/(2C), r = C·(1−g).
    public static func estimate(_ a: SignalTimingAssumptions) -> SignalWaitEstimate {
        let c = a.sanitizedCycleSeconds
        let r = a.redSeconds
        return SignalWaitEstimate(expectedWaitSeconds: r * r / (2 * c),
                                  stopProbability: r / c,
                                  meanWaitIfStopped: r / 2,
                                  observationCount: 0,
                                  source: .model)
    }
}

/// Per-signal history of the user's own stops, blended with the model. Persist it as JSON (Codable).
/// Not thread-safe: use it from one actor (the app keeps it on the main actor).
public final class SignalStatistics: Codable {
    /// Observations kept per signal (oldest are dropped).
    public static let maxObservationsPerSignal = 50
    /// Observations needed for a fully learned estimate.
    public static let fullConfidenceObservations = 5

    private var bySignal: [String: [SignalObservation]]

    public init() {
        bySignal = [:]
    }

    /// Adds an observation (keeps the newest `maxObservationsPerSignal` per signal, ordered by date).
    public func record(_ observation: SignalObservation) {
        guard observation.waitSeconds.isFinite, observation.waitSeconds >= 0 else { return }
        var list = bySignal[observation.signalID] ?? []
        if let last = list.last, last.date > observation.date {
            let index = list.firstIndex { $0.date > observation.date } ?? list.endIndex
            list.insert(observation, at: index)
        } else {
            list.append(observation)
        }
        if list.count > Self.maxObservationsPerSignal {
            list.removeFirst(list.count - Self.maxObservationsPerSignal)
        }
        bySignal[observation.signalID] = list
    }

    /// Blends the model with learned observations (same peak/off-peak bucket preferred, else all).
    /// n = observations used, w = min(1, n/5): expected = w·learned + (1−w)·model (likewise for the stop
    /// probability and the wait if stopped). Source: `.model` for n = 0, `.learned` for n ≥ 5, else `.blended`.
    public func estimate(for signalID: String, at date: Date, assumptions: SignalTimingAssumptions,
                         calendar: Calendar = .current) -> SignalWaitEstimate {
        let model = SignalWaitModel.estimate(assumptions)
        let all = bySignal[signalID] ?? []
        guard !all.isEmpty else { return model }

        let peak = Self.isPeak(date, calendar: calendar)
        let sameBucket = all.filter { Self.isPeak($0.date, calendar: calendar) == peak }
        let used = sameBucket.isEmpty ? all : sameBucket
        let n = used.count

        let stops = used.filter(\.stopped)
        let learnedProbability = Double(stops.count) / Double(n)
        let learnedMeanIfStopped = stops.isEmpty
            ? model.meanWaitIfStopped
            : stops.reduce(0) { $0 + $1.waitSeconds } / Double(stops.count)
        let learnedExpected = used.reduce(0) { $0 + ($1.stopped ? $1.waitSeconds : 0) } / Double(n)

        let w = min(1, Double(n) / Double(Self.fullConfidenceObservations))
        return SignalWaitEstimate(
            expectedWaitSeconds: w * learnedExpected + (1 - w) * model.expectedWaitSeconds,
            stopProbability: w * learnedProbability + (1 - w) * model.stopProbability,
            meanWaitIfStopped: w * learnedMeanIfStopped + (1 - w) * model.meanWaitIfStopped,
            observationCount: n,
            source: n >= Self.fullConfidenceObservations ? .learned : .blended)
    }

    /// Observations of one signal, oldest first.
    public func observations(for signalID: String) -> [SignalObservation] {
        bySignal[signalID] ?? []
    }

    /// Ids of all signals with observations.
    public var signalIDs: [String] { bySignal.keys.sorted() }

    public var totalObservations: Int {
        bySignal.values.reduce(0) { $0 + $1.count }
    }

    public func removeAll() {
        bySignal.removeAll()
    }

    /// Peak hours: Monday–Friday 07:00–10:00 and 17:00–20:00 local time (per `calendar`'s time zone).
    public static func isPeak(_ date: Date, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = c.weekday, let hour = c.hour else { return false }
        let isWorkday = (2...6).contains(weekday)   // 1 = Sunday, 7 = Saturday
        return isWorkday && ((7..<10).contains(hour) || (17..<20).contains(hour))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, observations
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decodeIfPresent([SignalObservation].self, forKey: .observations) ?? []
        bySignal = [:]
        for observation in list.sorted(by: { $0.date < $1.date }) {
            record(observation)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version)
        let flat = bySignal.keys.sorted().flatMap { bySignal[$0] ?? [] }
        try c.encode(flat, forKey: .observations)
    }
}

/// Detects passes through signalised intersections from GPS fixes and measures how long the vehicle stood.
///
/// A pass starts when the vehicle comes within `signalRadius` of a `SignalLocation` and ends when it is more
/// than `signalRadius + 15 m` away from it. Inside the area the vehicle is "halted" from the moment its speed
/// drops below `stopSpeedKmh` until it exceeds `resumeSpeedKmh` (so creeping forward in the queue still counts
/// as waiting); halted time is accumulated, and if it reaches `minStopSeconds` the pass counts as a stop with
/// that waiting time. Exactly one
/// observation is emitted per pass. Passes are discarded when the GPS jumps more than 200 m between fixes,
/// when fixes are missing for over 5 minutes, or when the vehicle stood longer than 5 minutes (parking, not a signal).
public final class StopDetector {
    public let stopSpeedKmh: Double
    public let resumeSpeedKmh: Double
    public let minStopSeconds: Double
    public let signalRadius: Double

    /// Hysteresis added to `signalRadius` before a pass ends, metres.
    public static let exitMargin: Double = 15
    /// A jump between consecutive fixes larger than this invalidates the current pass, metres.
    public static let maxJumpMeters: Double = 200
    /// Longest plausible stand at a signal / longest gap between fixes, seconds.
    public static let maxWaitSeconds: Double = 300

    private struct Pass {
        let signal: SignalLocation
        let enteredAt: Date
        var lowSpeedSeconds: Double
        /// Halted at the previous fix (below `stopSpeedKmh` and not yet above `resumeSpeedKmh`).
        var halted: Bool
        var valid: Bool
    }

    private struct Fix {
        let position: GeoPoint
        let timestamp: Date
    }

    private var pass: Pass?
    private var lastFix: Fix?

    public init(stopSpeedKmh: Double = 3, resumeSpeedKmh: Double = 10, minStopSeconds: Double = 2,
                signalRadius: Double = 45) {
        self.stopSpeedKmh = stopSpeedKmh
        self.resumeSpeedKmh = max(stopSpeedKmh, resumeSpeedKmh)
        self.minStopSeconds = max(0, minStopSeconds)
        self.signalRadius = max(5, signalRadius)
    }

    /// Id of the signal area the vehicle is currently in, if any.
    public var currentSignalID: String? { pass?.signal.id }

    /// Low-speed time accumulated in the current signal area, seconds.
    public var currentWaitSeconds: Double { pass?.lowSpeedSeconds ?? 0 }

    /// Feed every GPS fix. Returns an observation once the vehicle leaves a signal area
    /// (stopped = true with the stop duration, or stopped = false when it passed without stopping).
    /// A negative / non-finite `speedKmh` (invalid Core Location speed) is replaced by the speed derived
    /// from the previous fix when possible.
    public func update(position: GeoPoint, speedKmh: Double, timestamp: Date,
                       nearbySignals: [SignalLocation]) -> SignalObservation? {
        guard position.isValid else { return nil }
        var emitted: SignalObservation?

        // Speed sanity: derive from displacement when the reported speed is invalid.
        var speed: Double? = speedKmh.isFinite && speedKmh >= 0 ? speedKmh : nil
        var jumped = false
        var gapTooLong = false
        var dt: Double = 0
        if let last = lastFix {
            dt = timestamp.timeIntervalSince(last.timestamp)
            let moved = Geo.distance(last.position, position)
            jumped = moved > Self.maxJumpMeters
            gapTooLong = dt > Self.maxWaitSeconds
            if speed == nil, dt > 0 { speed = (moved / dt).kmh }
        }

        if var current = pass {
            if jumped || gapTooLong {
                current.valid = false
            } else if dt > 0, current.halted {
                // The interval since the previous fix counts as waiting when the vehicle was halted at that fix
                // (also covers location updates paused while stationary).
                current.lowSpeedSeconds += dt
            }
            if current.lowSpeedSeconds > Self.maxWaitSeconds { current.valid = false }
            current.halted = nextHalted(current.halted, speed: speed)

            let distance = Geo.distance(position, current.signal.coordinate)
            if distance > signalRadius + Self.exitMargin || !current.valid {
                if current.valid {
                    let stopped = current.lowSpeedSeconds >= minStopSeconds
                    emitted = SignalObservation(signalID: current.signal.id, date: current.enteredAt,
                                                stopped: stopped,
                                                waitSeconds: stopped ? current.lowSpeedSeconds : 0)
                }
                pass = nil
            } else {
                pass = current
            }
        }

        // Enter a (new) signal area. After an invalidated pass, wait for a clean fix first.
        if pass == nil && !jumped && !gapTooLong {
            let justLeft = emitted?.signalID
            var nearest: SignalLocation?
            var nearestDistance = signalRadius
            for signal in nearbySignals where signal.id != justLeft && signal.coordinate.isValid {
                let d = Geo.distance(position, signal.coordinate)
                if d <= nearestDistance {
                    nearestDistance = d
                    nearest = signal
                }
            }
            if let signal = nearest {
                pass = Pass(signal: signal, enteredAt: timestamp, lowSpeedSeconds: 0,
                            halted: nextHalted(false, speed: speed), valid: true)
            }
        }

        lastFix = Fix(position: position, timestamp: timestamp)
        return emitted
    }

    /// Halted-state hysteresis: halt below `stopSpeedKmh`, resume above `resumeSpeedKmh`, otherwise keep.
    /// Unknown speed keeps the previous state.
    private func nextHalted(_ halted: Bool, speed: Double?) -> Bool {
        guard let speed else { return halted }
        if speed < stopSpeedKmh { return true }
        if speed > resumeSpeedKmh { return false }
        return halted
    }

    /// Forgets the current pass and the last fix.
    public func reset() {
        pass = nil
        lastFix = nil
    }
}
