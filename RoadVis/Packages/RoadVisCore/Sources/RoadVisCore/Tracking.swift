import Foundation

/// A detection followed over several frames.
public struct TrackedObject: Identifiable, Hashable, Sendable {
    public let id: Int
    public var kind: VehicleKind
    public var label: String
    /// Smoothed latest box (normalized, top-left origin).
    public var box: BBox
    /// Latest detector confidence (model score, not accuracy).
    public var confidence: Double
    public var hits: Int
    /// Consecutive frames without a matching detection.
    public var missed: Int
    public var firstSeen: TimeInterval
    public var lastSeen: TimeInterval
    /// True once the object was matched on at least `minHits` frames; only confirmed objects are counted.
    public var isConfirmed: Bool
    /// Majority vote of make classifications (nil until the first observation).
    public var make: String?
    /// Mean confidence of the winning make.
    public var makeConfidence: Double?
    /// Majority of recent traffic-light colour observations.
    public var lightColor: TrafficLightColor?
    /// Rough monocular distance estimate, metres (see MonocularSpeedEstimator).
    public var distanceMeters: Double?
    /// Rate of change of the distance, km/h; positive = moving away from the camera.
    public var relativeSpeedKmh: Double?
    /// Own speed + relative speed, km/h (only when plausible).
    public var estimatedSpeedKmh: Double?

    public init(id: Int, kind: VehicleKind, label: String, box: BBox, confidence: Double,
                hits: Int = 1, missed: Int = 0, firstSeen: TimeInterval, lastSeen: TimeInterval,
                isConfirmed: Bool = false, make: String? = nil, makeConfidence: Double? = nil,
                lightColor: TrafficLightColor? = nil, distanceMeters: Double? = nil,
                relativeSpeedKmh: Double? = nil, estimatedSpeedKmh: Double? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.box = box
        self.confidence = confidence
        self.hits = hits
        self.missed = missed
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isConfirmed = isConfirmed
        self.make = make
        self.makeConfidence = makeConfidence
        self.lightColor = lightColor
        self.distanceMeters = distanceMeters
        self.relativeSpeedKmh = relativeSpeedKmh
        self.estimatedSpeedKmh = estimatedSpeedKmh
    }
}

/// Greedy IoU tracker (SORT-like without a Kalman filter): matches detections to existing tracks by IoU,
/// keeps class votes, make votes and traffic-light colour votes per track, and counts unique confirmed objects.
///
/// Counting rule: an object is counted once, at the moment its track becomes confirmed (`hits >= minHits`).
/// So `uniqueCounts` are tracked objects, while `frameDetectionCount` counts raw per-frame detections.
public final class ObjectTracker {
    public struct Config: Sendable {
        /// IoU above which a detection always matches a predicted track box.
        public var iouThreshold: Double
        /// Confirmed tracks survive this many frames without a detection (predicted meanwhile).
        public var maxMissed: Int
        /// Detections needed before a track is confirmed (and counted).
        public var minHits: Int
        /// Weight of the new box when smoothing (1 = no smoothing).
        public var boxSmoothing: Double
        /// Centre-distance gate for matching fast-moving objects when IoU is low, in units of the box size
        /// (sqrt of the larger box area). 0 disables centre matching (pure IoU tracker).
        public var centerGate: Double
        /// Maximum area ratio between a track box and a detection for a centre-distance match.
        public var maxAreaRatio: Double
        /// Unconfirmed (tentative) tracks are dropped after this many missed frames.
        public var maxMissedTentative: Int
        /// Per-class minimum detector confidence applied before tracking (classes not listed: no extra filter).
        public var minConfidence: [VehicleKind: Double]

        public static let defaultMinConfidence: [VehicleKind: Double] = [.trafficLight: 0.5, .stopSign: 0.55, .person: 0.5]

        public init(iouThreshold: Double = 0.3, maxMissed: Int = 8, minHits: Int = 3, boxSmoothing: Double = 0.6,
                    centerGate: Double = 1.0, maxAreaRatio: Double = 2.5, maxMissedTentative: Int = 2,
                    minConfidence: [VehicleKind: Double] = Config.defaultMinConfidence) {
            self.iouThreshold = iouThreshold
            self.maxMissed = maxMissed
            self.minHits = minHits
            self.boxSmoothing = boxSmoothing
            self.centerGate = centerGate
            self.maxAreaRatio = maxAreaRatio
            self.maxMissedTentative = maxMissedTentative
            self.minConfidence = minConfidence
        }
    }

    private struct State {
        var object: TrackedObject
        var kindVotes: [VehicleKind: Double] = [:]
        var makeVotes: [String: (count: Int, confidenceSum: Double)] = [:]
        var colorHistory: [TrafficLightColor] = []
        /// Rates per second of centre x/y and width/height (constant-velocity motion model).
        var velocity: (dx: Double, dy: Double) = (0, 0)
        var sizeRate: (dw: Double, dh: Double) = (0, 0)
        var counted = false
    }

    public let config: Config
    private var states: [State] = []
    private var nextID = 1
    public private(set) var uniqueCounts: [VehicleKind: Int] = [:]
    public private(set) var frameDetectionCount = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public var totalUniqueVehicles: Int {
        uniqueCounts.reduce(0) { $0 + ($1.key.isVehicle ? $1.value : 0) }
    }

    public func reset() {
        states.removeAll()
        uniqueCounts.removeAll()
        frameDetectionCount = 0
        nextID = 1
    }

    /// Classes that may be confused by the detector (car ↔ truck ↔ bus, motorcycle ↔ bicycle) can still match.
    private static func compatible(_ a: VehicleKind, _ b: VehicleKind) -> Bool {
        if a == b { return true }
        let motor: Set<VehicleKind> = [.car, .truck, .bus]
        let twoWheel: Set<VehicleKind> = [.motorcycle, .bicycle]
        return (motor.contains(a) && motor.contains(b)) || (twoWheel.contains(a) && twoWheel.contains(b))
    }

    @discardableResult
    public func update(detections: [Detection], timestamp: TimeInterval) -> [TrackedObject] {
        frameDetectionCount += detections.count

        // Per-class confidence filter (e.g. traffic lights / stop signs are noisy near the global threshold).
        let detections = detections.filter { d in
            guard let minimum = config.minConfidence[d.kind] else { return true }
            return d.confidence >= minimum
        }

        // Predict current boxes of existing tracks with the constant-velocity model (position and size).
        let predicted: [BBox] = states.map { st in
            let dt = max(0, timestamp - st.object.lastSeen)
            var b = st.object.box
            guard dt > 0, dt < 1.0 else { return b }
            let w = max(0.002, b.width + st.sizeRate.dw * dt)
            let h = max(0.002, b.height + st.sizeRate.dh * dt)
            let cx = b.midX + st.velocity.dx * dt
            let cy = b.midY + st.velocity.dy * dt
            b = BBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            return b
        }

        // Candidate pairs: IoU match, or centre-distance match for fast objects whose boxes no longer overlap.
        var pairs: [(track: Int, det: Int, score: Double)] = []
        for (ti, st) in states.enumerated() {
            let p = predicted[ti]
            for (di, d) in detections.enumerated() where Self.compatible(st.object.kind, d.kind) {
                let iou = p.iou(d.box)
                let penalty = st.object.kind == d.kind ? 0 : 0.05
                var score = -1.0
                if iou - penalty >= config.iouThreshold {
                    score = 1 + iou - penalty
                } else if config.centerGate > 0 {
                    let scale = sqrt(max(p.area, d.box.area))
                    let dx = p.midX - d.box.midX, dy = p.midY - d.box.midY
                    let dist = scale > 0 ? sqrt(dx * dx + dy * dy) / scale : .infinity
                    let ratio = max(p.area, d.box.area) / max(1e-9, min(p.area, d.box.area))
                    // A track without a velocity estimate yet (1 hit) gets a wider gate: its prediction is just the
                    // last box, while a fast object may already have moved more than one box width.
                    let gate = config.centerGate * (st.object.hits < 2 ? 1.6 : 1.0)
                    if dist <= gate, ratio <= config.maxAreaRatio {
                        score = (1 - dist / gate) * 0.9 + iou - penalty
                    }
                }
                if score > 0 { pairs.append((ti, di, score)) }
            }
        }
        pairs.sort { $0.score > $1.score }

        var trackMatched = [Bool](repeating: false, count: states.count)
        var detMatched = [Bool](repeating: false, count: detections.count)
        for p in pairs where !trackMatched[p.track] && !detMatched[p.det] {
            trackMatched[p.track] = true
            detMatched[p.det] = true
            apply(detection: detections[p.det], to: p.track, timestamp: timestamp)
        }

        // Unmatched tracks: age them. Their box stays at the last observation; the prediction above extrapolates
        // from `lastSeen`, so a confirmed track can be re-acquired a few frames later where the object moved.
        for i in states.indices where !trackMatched[i] {
            states[i].object.missed += 1
        }
        states.removeAll { st in
            st.object.missed > (st.object.isConfirmed ? config.maxMissed : config.maxMissedTentative)
        }


        // Unmatched detections: new tracks.
        for (di, d) in detections.enumerated() where !detMatched[di] {
            var st = State(object: TrackedObject(id: nextID, kind: d.kind, label: d.label, box: d.box,
                                                 confidence: d.confidence, firstSeen: timestamp, lastSeen: timestamp))
            nextID += 1
            st.kindVotes[d.kind, default: 0] += d.confidence
            if let make = d.make, let mc = d.makeConfidence {
                st.makeVotes[make] = (1, mc)
                st.object.make = make
                st.object.makeConfidence = mc
            }
            if let c = d.lightColor, c != .unknown {
                st.colorHistory = [c]
                st.object.lightColor = c
            }
            if config.minHits <= 1 {
                confirm(&st)
            }
            states.append(st)
        }

        return states.filter { $0.object.missed == 0 }.map(\.object)
    }

    private func apply(detection d: Detection, to index: Int, timestamp: TimeInterval) {
        var st = states[index]
        let old = st.object.box
        let dt = timestamp - st.object.lastSeen
        let w = min(1, max(0, config.boxSmoothing))
        let newBox = old.lerp(to: d.box, t: w)
        if dt > 0, dt < 1.5 {
            // Alpha-beta style velocity update from the raw detection (not the smoothed box) for responsiveness.
            let vx = (d.box.midX - old.midX) / dt
            let vy = (d.box.midY - old.midY) / dt
            let vw = (d.box.width - old.width) / dt
            let vh = (d.box.height - old.height) / dt
            let beta = st.object.hits < 2 ? 1.0 : 0.4
            st.velocity = (st.velocity.dx + beta * (vx - st.velocity.dx), st.velocity.dy + beta * (vy - st.velocity.dy))
            st.sizeRate = (st.sizeRate.dw + beta * (vw - st.sizeRate.dw), st.sizeRate.dh + beta * (vh - st.sizeRate.dh))
        }
        st.object.box = newBox
        st.object.confidence = d.confidence
        st.object.hits += 1
        st.object.missed = 0
        st.object.lastSeen = timestamp
        st.object.label = d.label

        st.kindVotes[d.kind, default: 0] += d.confidence
        if let best = st.kindVotes.max(by: { $0.value < $1.value })?.key {
            st.object.kind = best
        }
        if let make = d.make, let mc = d.makeConfidence {
            addMake(&st, make: make, confidence: mc)
        }
        if let c = d.lightColor, c != .unknown {
            st.colorHistory.append(c)
            if st.colorHistory.count > 7 { st.colorHistory.removeFirst(st.colorHistory.count - 7) }
            st.object.lightColor = Self.majority(st.colorHistory)
        }
        if !st.counted && st.object.hits >= config.minHits {
            confirm(&st)
        }
        states[index] = st
    }

    private func confirm(_ st: inout State) {
        st.object.isConfirmed = true
        if !st.counted {
            st.counted = true
            uniqueCounts[st.object.kind, default: 0] += 1
        }
    }

    private func addMake(_ st: inout State, make: String, confidence: Double) {
        var entry = st.makeVotes[make] ?? (0, 0)
        entry.count += 1
        entry.confidenceSum += confidence
        st.makeVotes[make] = entry
        // Winner: highest summed confidence (ties → more votes).
        if let best = st.makeVotes.max(by: { a, b in
            a.value.confidenceSum == b.value.confidenceSum ? a.value.count < b.value.count
                : a.value.confidenceSum < b.value.confidenceSum
        }) {
            st.object.make = best.key
            st.object.makeConfidence = best.value.confidenceSum / Double(max(1, best.value.count))
        }
    }

    public func addMakeObservation(trackID: Int, make: String, confidence: Double) {
        guard let i = states.firstIndex(where: { $0.object.id == trackID }) else { return }
        addMake(&states[i], make: make, confidence: confidence)
    }

    private static func majority(_ colors: [TrafficLightColor]) -> TrafficLightColor? {
        var counts: [TrafficLightColor: Int] = [:]
        for c in colors { counts[c, default: 0] += 1 }
        // Prefer the most recent colour on ties.
        return counts.max { a, b in
            a.value == b.value
                ? (colors.lastIndex(of: a.key) ?? 0) < (colors.lastIndex(of: b.key) ?? 0)
                : a.value < b.value
        }?.key
    }
}
