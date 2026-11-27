import Foundation

/// Why a frame is worth sending to the RoadVis Trainer (`docs/TRAINING_API.md` §1). Raw values go into the sample
/// metadata (`reasons`) and are shared with the Kotlin core and the server.
public enum HardExampleReason: String, CaseIterable, Codable, Sendable {
    /// A confirmed track coasts (`missed ≥ 1`) while its predicted box is fully inside the frame and ≥ 0.04 high.
    case missedDetection
    /// A track died after ≤ 2 hits without being confirmed (likely hallucination).
    case shortLived
    /// A detection scored in [0.25, its class threshold).
    case lowConfidence
    /// A confirmed track's class vote changed on this frame.
    case classFlip
    /// Deterministic 1 % sample (`frameIndex % 100 == 37`).
    case random
}

/// Verdict for one frame.
public struct HardExampleDecision: Equatable, Sendable {
    public var keep: Bool
    /// Reasons found on the frame (raw values of `HardExampleReason`, in `allCases` order). Non-empty with
    /// `keep == false` when a gate (speed, interval, per-trip cap, quality, duplicate) rejected the frame.
    public var reasons: [String]

    public init(keep: Bool, reasons: [String]) {
        self.keep = keep
        self.reasons = reasons
    }

    public static let discard = HardExampleDecision(keep: false, reasons: [])
}

/// Everything the selector looks at for one processed frame.
public struct HardExampleFrame: Sendable {
    /// Frame timestamp, seconds (any monotonic clock, e.g. the camera presentation time).
    public var timestamp: Double
    /// Index of the processed frame (drives the `random` reason).
    public var frameIndex: Int
    /// Own speed, km/h; nil when unknown.
    public var ownSpeedKmh: Double?
    /// Tracker output of the frame (matched tracks plus coasting confirmed ones).
    public var tracks: [TrackedObject]
    /// Raw detections of the frame (before tracking).
    public var detections: [Detection]
    /// The app's per-class thresholds in effect (`DetectionThresholds.perClass(global:)`); classes not listed use
    /// `DetectionThresholds.threshold(for:)` at the default slider position.
    public var classThresholds: [VehicleKind: Double]
    /// Track IDs whose class vote the tracker reports as changed on this frame (optional; the selector also detects
    /// a changed kind itself from its 1-frame memory).
    public var classFlipTrackIDs: Set<Int>

    public init(timestamp: Double, frameIndex: Int, ownSpeedKmh: Double?, tracks: [TrackedObject],
                detections: [Detection], classThresholds: [VehicleKind: Double] = DetectionThresholds.perClass(),
                classFlipTrackIDs: Set<Int> = []) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.ownSpeedKmh = ownSpeedKmh
        self.tracks = tracks
        self.detections = detections
        self.classThresholds = classThresholds
        self.classFlipTrackIDs = classFlipTrackIDs
    }
}

/// Decides per processed frame whether to keep it as a training sample (`docs/TRAINING_API.md` §1; the Kotlin
/// core has the same rules and constants).
///
/// 1-frame memory. A tentative track that dies is only known to be dead on the NEXT frame, and `shortLived` must be
/// reported on the frame where the track was last detected. So `evaluate(_:quality:)` takes the newest frame and
/// returns the decision for the frame before it (the one it holds in memory); the caller keeps that previous
/// frame's image until the next call. All reasons and gates are judged on that previous frame.
///
/// Cheapness. The frame-quality metrics are requested (closure) only after a reason was found and the speed,
/// interval and per-trip gates passed — i.e. only when the frame would be kept apart from its quality.
public struct HardExampleSelector: Sendable {
    public struct Config: Equatable, Sendable {
        public var minIntervalSeconds: Double = 2.0
        public var maxPerTrip: Int = 300
        /// Frames are kept only at or above this own speed (or with unknown speed): no parked-car floods.
        public var minSpeedKmh: Double = 5
        public var minSharpness: Double = 60
        public var minBrightness: Double = 35
        public var maxBrightness: Double = 225
        public var maxDuplicateHamming: Int = 6
        /// Lower end of the `lowConfidence` band (upper end: the class threshold).
        public var lowConfidenceFloor: Double = 0.25
        /// Minimum box height of a coasting track for `missedDetection`.
        public var minMissedBoxHeight: Double = 0.04
        /// `shortLived`: a dead unconfirmed track had at most this many hits.
        public var shortLivedMaxHits: Int = 2
        public var randomModulus: Int = 100
        public var randomRemainder: Int = 37

        public init() {}
    }

    public let config: Config
    /// Frames kept since the last `resetTrip()`.
    public private(set) var keptThisTrip = 0
    /// Timestamp of the last kept frame.
    public private(set) var lastKeptTimestamp: Double?
    /// dHash of the last kept frame.
    public private(set) var lastKeptHash: UInt64?
    /// The frame awaiting its decision (1-frame memory).
    public private(set) var pending: HardExampleFrame?
    /// Track kinds of the frame before `pending` (class-flip detection).
    private var kindsBeforePending: [Int: VehicleKind] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// A new trip started: the per-trip counter restarts.
    public mutating func resetTrip() {
        keptThisTrip = 0
    }

    /// Frames stopped (camera paused, tracker reset): forgets the frame memory so vanished tracks are not
    /// mistaken for dead ones. Interval, duplicate hash and trip counter are kept.
    public mutating func resetMemory() {
        pending = nil
        kindsBeforePending = [:]
    }

    /// Feeds the newest frame and returns the decision for the PREVIOUS frame (see the type comment); `.discard`
    /// on the first frame after a reset. `quality` is called at most once, with the frame being decided, and only
    /// when all other gates passed; nil from it rejects the frame.
    public mutating func evaluate(_ frame: HardExampleFrame,
                                  quality: (HardExampleFrame) -> FrameQualityMetrics?) -> HardExampleDecision {
        defer {
            if let pending {
                var kinds: [Int: VehicleKind] = [:]
                for track in pending.tracks { kinds[track.id] = track.kind }
                kindsBeforePending = kinds
            } else {
                kindsBeforePending = [:]
            }
            pending = frame
        }
        guard let candidate = pending else { return .discard }
        let found = Self.reasons(of: candidate, next: frame, previousKinds: kindsBeforePending, config: config)
        guard !found.isEmpty else { return .discard }
        let rejected = HardExampleDecision(keep: false, reasons: found)
        guard passesGates(candidate) else { return rejected }
        guard let metrics = quality(candidate), passesQuality(metrics) else { return rejected }
        keptThisTrip += 1
        lastKeptTimestamp = candidate.timestamp
        lastKeptHash = metrics.dhash
        return HardExampleDecision(keep: true, reasons: found)
    }

    /// True when the frame held in memory (the one passed to the last `evaluate`) can still be kept by the next
    /// call: it passes the speed / interval / per-trip gates and has a reason already, or a tentative track that
    /// may turn out short-lived. When false the caller need not hold on to that frame's image.
    public func pendingMayBeKept() -> Bool {
        guard let pending, passesGates(pending) else { return false }
        if pending.tracks.contains(where: { !$0.isConfirmed && $0.missed == 0 && $0.hits <= config.shortLivedMaxHits }) {
            return true
        }
        return !Self.reasons(of: pending, next: nil, previousKinds: kindsBeforePending, config: config).isEmpty
    }

    /// Speed, interval and per-trip gates for a frame (no quality).
    public func passesGates(_ frame: HardExampleFrame) -> Bool {
        if let speed = frame.ownSpeedKmh, speed.isFinite, speed < config.minSpeedKmh { return false }
        // A timestamp before the last kept one means a new clock (session restart): the interval starts over.
        if let last = lastKeptTimestamp, frame.timestamp >= last, frame.timestamp - last < config.minIntervalSeconds {
            return false
        }
        return keptThisTrip < config.maxPerTrip
    }

    /// Sharpness, brightness and near-duplicate gates.
    public func passesQuality(_ metrics: FrameQualityMetrics) -> Bool {
        guard metrics.sharpness.isFinite, metrics.sharpness >= config.minSharpness else { return false }
        guard metrics.brightness >= config.minBrightness, metrics.brightness <= config.maxBrightness else { return false }
        if let last = lastKeptHash, FrameQuality.hammingDistance(last, metrics.dhash) <= config.maxDuplicateHamming {
            return false
        }
        return true
    }

    /// Reasons of `frame`, given the frame after it (`next`, for dead tracks) and the track kinds of the frame
    /// before it (`previousKinds`, for class flips). Raw values in `HardExampleReason.allCases` order.
    public static func reasons(of frame: HardExampleFrame, next: HardExampleFrame?,
                               previousKinds: [Int: VehicleKind], config: Config = Config()) -> [String] {
        var found = Set<HardExampleReason>()
        for track in frame.tracks {
            if track.isConfirmed, track.missed >= 1, track.box.height >= config.minMissedBoxHeight,
               track.box.minX >= 0, track.box.minY >= 0, track.box.maxX <= 1, track.box.maxY <= 1 {
                found.insert(.missedDetection)
            }
            if track.isConfirmed {
                if frame.classFlipTrackIDs.contains(track.id) {
                    found.insert(.classFlip)
                } else if let previous = previousKinds[track.id], previous != track.kind {
                    found.insert(.classFlip)
                }
            }
        }
        if let next {
            let nextIDs = Set(next.tracks.map(\.id))
            for track in frame.tracks
            where !track.isConfirmed && track.missed == 0 && track.hits <= config.shortLivedMaxHits
                && !nextIDs.contains(track.id) {
                found.insert(.shortLived)
                break
            }
        }
        for detection in frame.detections {
            let threshold = frame.classThresholds[detection.kind] ?? DetectionThresholds.threshold(for: detection.kind)
            if detection.confidence >= config.lowConfidenceFloor && detection.confidence < threshold {
                found.insert(.lowConfidence)
                break
            }
        }
        if config.randomModulus > 0, frame.frameIndex >= 0,
           frame.frameIndex % config.randomModulus == config.randomRemainder {
            found.insert(.random)
        }
        return HardExampleReason.allCases.filter { found.contains($0) }.map(\.rawValue)
    }
}
