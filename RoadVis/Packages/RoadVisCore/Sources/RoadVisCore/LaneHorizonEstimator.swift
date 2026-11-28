import Foundation

/// Vanishing point of the two raw lane-line fits of one frame, normalized image coordinates (top-left origin).
public struct LaneVanishingPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// The lower of the two raw fit confidences.
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

/// Estimates the horizon row from the vanishing point of the own-lane markings.
///
/// The horizon (`EgoCorridor.horizonY`) is shared by the lane detector, the lead-vehicle corridor, the pedestrian
/// roadway zone and the traffic-light selection, and used to be a hand-set value (0.42 by default). On a straight
/// flat road the two lane lines meet on the horizon, so the median of their intersections is the horizon of the
/// phone as it is mounted.
///
/// EVIDENCE (synthetic 160×284 images only, no real video — scratchpad/lane/core/Tests/RoadVisCoreTests/ExpLane.swift):
/// the intersection of the two fitted lines was within 0.01 of the true horizon for true horizons 0.30…0.60 with the
/// detector configured at 0.42; with this estimator all five cases converged at lane frame 11 (≈ 2.2 s at 5 Hz).
/// Hills, curves and roads with one visible line give no or biased samples; the caller's speed gate, the spread
/// gate and the range limit are the mitigations. All gate values are reasoning unless stated otherwise.
public struct LaneHorizonEstimator: Sendable {
    /// Both raw fits need at least this confidence for a sample.
    public static let minFitConfidence: Double = 0.5
    /// Samples kept (25 lane frames ≈ 5 s at 5 Hz).
    public static let window: Int = 25
    /// Samples needed before an estimate is given (12 ≈ 2.4 s of good frames).
    public static let minSamples: Int = 12
    /// Accepted vanishing-point rows / columns (fractions of the frame).
    public static let rowRange: ClosedRange<Double> = 0.20...0.70
    public static let columnRange: ClosedRange<Double> = 0.25...0.75
    /// The interquartile range (p75 − p25) of the window must be at most this for an estimate.
    public static let maxSpread: Double = 0.04
    /// Samples should be fed only at or above this own speed, km/h (straight driving; no samples from manoeuvring,
    /// queues and turns at junctions).
    public static let minSpeedKmh: Double = 30
    /// A new estimate replaces the horizon in use only when it differs by more than this (no jitter in the
    /// corridor / ROI).
    public static let applyDelta: Double = 0.015

    private var samples: [Double] = []
    /// Latest estimate (nil until enough consistent samples).
    public private(set) var horizonY: Double?

    public init(initial: Double? = nil) {
        if let initial, initial.isFinite, Self.rowRange.contains(initial) {
            horizonY = initial
        }
    }

    public var sampleCount: Int { samples.count }

    /// Forgets the samples and the estimate (frame shape changed: the horizon row is a different one).
    public mutating func reset() {
        samples.removeAll()
        horizonY = nil
    }

    /// Feeds the vanishing point of one lane frame (`LaneDetector.lastVanishingPoint`; nil = no usable pair of
    /// lines). Returns the current estimate.
    @discardableResult
    public mutating func add(_ point: LaneVanishingPoint?) -> Double? {
        guard let point, point.confidence >= Self.minFitConfidence, point.x.isFinite, point.y.isFinite,
              Self.rowRange.contains(point.y), Self.columnRange.contains(point.x) else { return horizonY }
        samples.append(point.y)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
        guard samples.count >= Self.minSamples else { return horizonY }
        let sorted = samples.sorted()
        guard sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4] <= Self.maxSpread else { return horizonY }
        horizonY = sorted[sorted.count / 2]
        return horizonY
    }

    /// True when `estimate` should replace the horizon currently in use.
    public static func shouldApply(estimate: Double, current: Double) -> Bool {
        abs(estimate - current) > applyDelta
    }
}
