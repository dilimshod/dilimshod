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
    /// Highest detector confidence the track has had so far. Gates that ask "is this a solid object?" use it
    /// instead of the latest frame's score, which dips on single frames (and may sit below the class threshold
    /// while a confirmed track is continued by a low-score detection).
    public var peakConfidence: Double
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
    /// Stable traffic-light colour: time-window vote over the recent observations (`TrafficLightColorVote`); nil
    /// while there are too few readable observations — a colour never outlives ≈ 0.8 s without a readable lamp.
    public var lightColor: TrafficLightColor?
    /// Majority of recent person-role observations (≥ 5 needed; nil before / for non-persons). Colour heuristic (≈).
    public var personRole: PersonRole?
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
                relativeSpeedKmh: Double? = nil, estimatedSpeedKmh: Double? = nil, personRole: PersonRole? = nil,
                peakConfidence: Double? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.box = box
        self.confidence = confidence
        self.peakConfidence = max(confidence, peakConfidence ?? confidence)
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
        self.personRole = personRole
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
        /// Per-class minimum detector confidence needed to open a track (classes not listed: no filter). Initial
        /// value of `ObjectTracker.minConfidence`, which the owner may replace per frame (settings slider).
        public var minConfidence: [VehicleKind: Double]
        /// A detection scoring below its class minimum but at least `minimum × continuationFactor` may still
        /// continue an already confirmed track (it never opens a track). 1 = off.
        public var continuationFactor: Double
        /// Tracks not seen for longer than this are forgotten before matching, seconds (frames may stop without
        /// the owner calling `dropTracks()`, e.g. a capture interruption). Well above `maxMissed` frames at the
        /// lowest processing rate.
        public var maxIdleSeconds: Double
        /// Kinds that are counted only when the owner marks the confirmed track relevant (`markRelevant(trackIDs:)`),
        /// e.g. persons inside the roadway zone (a pedestrian on the sidewalk is not counted).
        public var deferredCountKinds: Set<VehicleKind>
        /// Confirmed tracks without a detection are still RETURNED by `update` for this many frames ("coasting"),
        /// with `missed ≥ 1` and the box extrapolated by the constant-velocity model. 0 = only tracks seen on the
        /// frame are returned (the behaviour before coasting existed).
        public var coastFrames: Int
        /// Minimum IoU (predicted track box vs detection) of the second association stage, in which low-score
        /// detections continue confirmed tracks that no full-score detection matched.
        public var secondIoU: Double

        /// Coasting length. Measured by replaying a real drive log (4778 logged frames, assumed 15 fps; harness
        /// scratchpad/lane/core/Tests/RoadVisCoreTests/ExpTrackerReplay.swift) at the then-default threshold 0.45:
        /// lead vehicle present on 1332 frames with 262 dropouts < 1 s and 62 lead ID switches without coasting;
        /// 1891 / 53 / 32 with 3 frames; 1784 / 80 / 44 with 2; 2034 / 33 / 26 with 5 (0.33 s of pure prediction —
        /// judged too long for a distance readout). 3 frames = 0.2 s at 15 fps.
        public static let defaultCoastFrames: Int = 3
        /// Second-stage IoU. Same replay: 0.3 gave +9 % frames with a matched confirmed vehicle track and fewer
        /// confirmed IDs (191 → 184); 0.5 gave no gain. Method: ByteTrack (arXiv 2110.06864).
        public static let defaultSecondIoU: Double = 0.3

        /// Thresholds at the default slider position, see `DetectionThresholds` for the measurements behind them.
        public static let defaultMinConfidence: [VehicleKind: Double] = DetectionThresholds.perClass()

        public init(iouThreshold: Double = 0.3, maxMissed: Int = 8, minHits: Int = 3, boxSmoothing: Double = 0.6,
                    centerGate: Double = 1.0, maxAreaRatio: Double = 2.5, maxMissedTentative: Int = 2,
                    minConfidence: [VehicleKind: Double] = Config.defaultMinConfidence,
                    deferredCountKinds: Set<VehicleKind> = [],
                    continuationFactor: Double = DetectionThresholds.continuationFactor,
                    maxIdleSeconds: Double = 3.0, coastFrames: Int = Config.defaultCoastFrames,
                    secondIoU: Double = Config.defaultSecondIoU) {
            self.iouThreshold = iouThreshold
            self.maxMissed = maxMissed
            self.minHits = minHits
            self.boxSmoothing = boxSmoothing
            self.centerGate = centerGate
            self.maxAreaRatio = maxAreaRatio
            self.maxMissedTentative = maxMissedTentative
            self.minConfidence = minConfidence
            self.deferredCountKinds = deferredCountKinds
            self.continuationFactor = continuationFactor
            self.maxIdleSeconds = maxIdleSeconds
            self.coastFrames = max(0, coastFrames)
            self.secondIoU = secondIoU
        }
    }

    private struct State {
        var object: TrackedObject
        var kindVotes: [VehicleKind: Double] = [:]
        var makeVotes: [String: (count: Int, confidenceSum: Double)] = [:]
        /// Every colour observation of a traffic-light track, INCLUDING `.unknown` (those age the state out).
        var colorHistory: [TrafficLightColorVote.Observation] = []
        var roleHistory: [PersonRole] = []
        /// Rates per second of centre x/y and width/height (constant-velocity motion model).
        var velocity: (dx: Double, dy: Double) = (0, 0)
        var sizeRate: (dw: Double, dh: Double) = (0, 0)
        var counted = false
    }

    public let config: Config
    /// Per-class confidence needed to open a track. Starts as `config.minConfidence`; the app sets it every frame
    /// from the settings slider (`DetectionThresholds.perClass(global:)`) — the same table the detector floor is
    /// derived from, so there is no second hidden threshold.
    public var minConfidence: [VehicleKind: Double]
    private var states: [State] = []
    private var nextID = 1
    public private(set) var uniqueCounts: [VehicleKind: Int] = [:]
    public private(set) var frameDetectionCount = 0
    /// Number of second-stage (low-score) matches so far (diagnostics / tests).
    public private(set) var lowScoreMatches = 0

    public init(config: Config = Config()) {
        self.config = config
        minConfidence = config.minConfidence
    }

    public var totalUniqueVehicles: Int {
        uniqueCounts.reduce(0) { $0 + ($1.key.isVehicle ? $1.value : 0) }
    }

    public func reset() {
        states.removeAll()
        uniqueCounts.removeAll()
        frameDetectionCount = 0
        lowScoreMatches = 0
        nextID = 1
    }

    /// Forgets the live tracks but keeps the unique counters and the ID sequence. Call it when frames stop for a
    /// while (pause, background, camera error): otherwise the first frame after the gap would continue the old
    /// tracks — confirmed state, hit count, make / colour / role votes — with whatever overlaps their last boxes.
    public func dropTracks() {
        states.removeAll()
    }

    /// Classes that may be confused by the detector (car ↔ truck ↔ bus, motorcycle ↔ bicycle) can still match.
    private static func compatible(_ a: VehicleKind, _ b: VehicleKind) -> Bool {
        if a == b { return true }
        let motor: Set<VehicleKind> = [.car, .truck, .bus]
        let twoWheel: Set<VehicleKind> = [.motorcycle, .bicycle]
        return (motor.contains(a) && motor.contains(b)) || (twoWheel.contains(a) && twoWheel.contains(b))
    }

    /// Feeds the detections of one frame.
    ///
    /// Returns the tracks matched on this frame (`missed == 0`) plus, for at most `Config.coastFrames` frames, the
    /// CONFIRMED tracks that were not matched: those carry `missed ≥ 1` and a box predicted by the constant-velocity
    /// model. Consumers that must not act on a predicted box (pedestrian warnings, traffic-light logic, distance
    /// samples, the research log) filter on `missed == 0`.
    @discardableResult
    public func update(detections: [Detection], timestamp: TimeInterval) -> [TrackedObject] {
        frameDetectionCount += detections.count

        // Tracks whose last observation is too old (frames stopped without `dropTracks()`) are not continued.
        if config.maxIdleSeconds > 0 {
            states.removeAll { timestamp - $0.object.lastSeen > config.maxIdleSeconds }
        }

        // Per-class confidence filter with hysteresis: at or above the class minimum a detection may open a track;
        // between `minimum × continuationFactor` and the minimum it may only continue a confirmed track.
        let factor = min(1, max(0, config.continuationFactor))
        let rawDetections = detections
        var detections: [Detection] = []
        var canSpawn: [Bool] = []
        detections.reserveCapacity(rawDetections.count)
        canSpawn.reserveCapacity(rawDetections.count)
        for d in rawDetections {
            let minimum = minConfidence[d.kind] ?? 0
            if d.confidence >= minimum {
                detections.append(d)
                canSpawn.append(true)
            } else if d.confidence >= minimum * factor {
                detections.append(d)
                canSpawn.append(false)
            }
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
                // Low-score detections take part only in the second stage below (ByteTrack order: a full-score
                // detection is never left without its track because a low-score box overlapped it better).
                if !canSpawn[di] { continue }
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

        // Second association (ByteTrack "BYTE" step): confirmed tracks that no full-score detection matched may be
        // continued by a low-score detection of a compatible class, by IoU on the predicted box only (no centre
        // gate). Such a match refreshes box, velocity and `lastSeen`, but adds no hit and no class vote, and it
        // never opens or confirms a track.
        var lowPairs: [(track: Int, det: Int, score: Double)] = []
        for (di, d) in detections.enumerated() where !canSpawn[di] {
            for (ti, st) in states.enumerated()
            where !trackMatched[ti] && st.object.isConfirmed && Self.compatible(st.object.kind, d.kind) {
                let iou = predicted[ti].iou(d.box)
                if iou >= config.secondIoU { lowPairs.append((ti, di, iou)) }
            }
        }
        lowPairs.sort { $0.score > $1.score }
        for p in lowPairs where !trackMatched[p.track] && !detMatched[p.det] {
            trackMatched[p.track] = true
            detMatched[p.det] = true
            lowScoreMatches += 1
            apply(detection: detections[p.det], to: p.track, timestamp: timestamp, lowScore: true)
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
        for (di, d) in detections.enumerated() where !detMatched[di] && canSpawn[di] {
            var st = State(object: TrackedObject(id: nextID, kind: d.kind, label: d.label, box: d.box,
                                                 confidence: d.confidence, firstSeen: timestamp, lastSeen: timestamp))
            nextID += 1
            st.kindVotes[d.kind, default: 0] += d.confidence
            if let make = d.make, let mc = d.makeConfidence {
                st.makeVotes[make] = (1, mc)
                st.object.make = make
                st.object.makeConfidence = mc
            }
            if d.kind == .trafficLight {
                st.colorHistory = [TrafficLightColorVote.Observation(time: timestamp, color: d.lightColor ?? .unknown)]
                st.object.lightColor = TrafficLightColorVote.decide(st.colorHistory, now: timestamp, previous: nil)
            }
            if let role = d.personRole {
                st.roleHistory = [role]
                st.object.personRole = PersonRoleClassifier.majority(st.roleHistory)
            }
            if config.minHits <= 1 {
                confirm(&st)
            }
            states.append(st)
        }

        return states.compactMap { st -> TrackedObject? in
            if st.object.missed == 0 { return st.object }
            guard st.object.isConfirmed, st.object.missed <= config.coastFrames else { return nil }
            // Coasted: the stored box stays at the last observation (re-acquisition predicts from it); only the
            // returned copy is extrapolated. `dt` is clamped like the matching prediction above.
            var object = st.object
            let dt = max(0, min(1, timestamp - object.lastSeen))
            let w = max(0.002, object.box.width + st.sizeRate.dw * dt)
            let h = max(0.002, object.box.height + st.sizeRate.dh * dt)
            object.box = BBox(x: object.box.midX + st.velocity.dx * dt - w / 2,
                              y: object.box.midY + st.velocity.dy * dt - h / 2, width: w, height: h)
            return object
        }
    }

    private func apply(detection d: Detection, to index: Int, timestamp: TimeInterval, lowScore: Bool = false) {
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
        st.object.peakConfidence = max(st.object.peakConfidence, d.confidence)
        if !lowScore { st.object.hits += 1 }
        st.object.missed = 0
        st.object.lastSeen = timestamp
        if !lowScore {
            st.object.label = d.label
            st.kindVotes[d.kind, default: 0] += d.confidence
        }
        if let best = st.kindVotes.max(by: { $0.value < $1.value })?.key {
            st.object.kind = best
        }
        if let make = d.make, let mc = d.makeConfidence {
            addMake(&st, make: make, confidence: mc)
        }
        if d.kind == .trafficLight || !st.colorHistory.isEmpty || st.object.lightColor != nil {
            // Runs on every matched frame, also when the lamp was unreadable: unknown observations are recorded so
            // an old colour cannot survive (it used to stay red for the life of the track).
            st.colorHistory.append(TrafficLightColorVote.Observation(time: timestamp, color: d.lightColor ?? .unknown))
            TrafficLightColorVote.prune(&st.colorHistory, now: timestamp)
            st.object.lightColor = TrafficLightColorVote.decide(st.colorHistory, now: timestamp,
                                                                previous: st.object.lightColor)
        }
        if let role = d.personRole {
            st.roleHistory.append(role)
            let window = PersonRoleClassifier.voteWindow
            if st.roleHistory.count > window { st.roleHistory.removeFirst(st.roleHistory.count - window) }
            st.object.personRole = PersonRoleClassifier.majority(st.roleHistory, previous: st.object.personRole)
        }
        if !st.counted && st.object.hits >= config.minHits {
            confirm(&st)
        }
        states[index] = st
    }

    private func confirm(_ st: inout State) {
        st.object.isConfirmed = true
        if !st.counted && !config.deferredCountKinds.contains(st.object.kind) {
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

    /// Counts the given confirmed tracks of a deferred kind (`Config.deferredCountKinds`) once.
    public func markRelevant(trackIDs: [Int]) {
        guard !trackIDs.isEmpty else { return }
        let ids = Set(trackIDs)
        for i in states.indices where ids.contains(states[i].object.id) {
            guard states[i].object.isConfirmed, !states[i].counted else { continue }
            states[i].counted = true
            uniqueCounts[states[i].object.kind, default: 0] += 1
        }
    }

    public func addMakeObservation(trackID: Int, make: String, confidence: Double) {
        guard let i = states.firstIndex(where: { $0.object.id == trackID }) else { return }
        addMake(&states[i], make: make, confidence: confidence)
    }
}

/// Time-window vote that turns per-frame traffic-light colour observations into a stable colour.
///
/// Why time based: the old vote kept the last 7 KNOWN colours for the life of the track and ignored `.unknown`
/// frames, so a light that was red and then became unreadable stayed "red" indefinitely (and 7 stale reds outvoted
/// 3 fresh greens). Unknown is a normal answer of the colour classifier: 17–46 % of daytime lamp crops with the
/// previous classifier and ≈ 8 % with the current one (measured on a LISA sample, see
/// `TrafficLightColorClassifier`), whose per-frame wrong-colour rate is 0.4–0.5 %. The vote constants themselves are
/// reasoning — no video sequences were evaluated.
public enum TrafficLightColorVote {
    public struct Observation: Hashable, Sendable {
        public var time: TimeInterval
        public var color: TrafficLightColor

        public init(time: TimeInterval, color: TrafficLightColor) {
            self.time = time
            self.color = color
        }
    }

    /// Observations older than this are forgotten, seconds (≈ 12 frames at 15 fps). This is the MINIMUM window: at
    /// low processing rates it is stretched, see `effectiveWindow`.
    public static let window: TimeInterval = 0.8
    /// Upper bound of the stretched window, seconds.
    public static let maxWindow: TimeInterval = 2.0
    /// The window covers at least this many frame intervals.
    static let windowFrames: Double = 5
    /// Known-colour votes the winner needs inside the window…
    public static let minVotes: Int = 3
    /// …and its share of the known votes.
    public static let minShare: Double = 0.6
    /// Switching to a different colour additionally needs the newest this-many known observations to agree.
    public static let switchAgreement: Int = 2
    /// Hard cap of stored observations (frames arrive at ≤ 30 fps).
    static let maxObservations: Int = 48

    /// 0.8 s at normal rates; stretched to ≈ 5 frame intervals (capped at 2 s) when frames arrive slowly, so a
    /// device that processes 2.5–4 frames per second still collects the votes a stable colour needs.
    public static func effectiveWindow(_ history: [Observation]) -> TimeInterval {
        guard history.count >= 2 else { return window }
        var gaps: [TimeInterval] = []
        for i in 1..<history.count { gaps.append(history[i].time - history[i - 1].time) }
        gaps.sort()
        let median: TimeInterval = gaps[gaps.count / 2]
        return min(maxWindow, max(window, windowFrames * median))
    }

    /// Drops observations outside the window.
    public static func prune(_ history: inout [Observation], now: TimeInterval) {
        let w: TimeInterval = effectiveWindow(history)
        history.removeAll { now - $0.time > w || $0.time > now + 1e-6 }
        if history.count > maxObservations { history.removeFirst(history.count - maxObservations) }
    }

    /// Stable colour for the observations inside the window, or nil (not enough readable evidence).
    /// - Parameter previous: the colour reported so far (hysteresis).
    public static func decide(_ history: [Observation], now: TimeInterval, previous: TrafficLightColor?) -> TrafficLightColor? {
        let w: TimeInterval = effectiveWindow(history)
        var known: [TrafficLightColor] = []
        for o in history where now - o.time <= w && o.color != .unknown { known.append(o.color) }
        guard known.count >= minVotes else { return nil }
        var counts: [TrafficLightColor: Int] = [:]
        for c in known { counts[c, default: 0] += 1 }
        // Most votes; ties → the colour seen most recently.
        var winner = known[known.count - 1]
        var winnerCount = counts[winner] ?? 0
        for color in [TrafficLightColor.red, .yellow, .green] {
            let count = counts[color] ?? 0
            if count > winnerCount {
                winner = color
                winnerCount = count
            }
        }
        guard winnerCount >= minVotes, Double(winnerCount) / Double(known.count) >= minShare else {
            return nil
        }
        if let previous, previous != .unknown, winner != previous {
            // Hysteresis: the newest known observations must already show the new colour.
            let newest = known.suffix(switchAgreement)
            if newest.count < switchAgreement || newest.contains(where: { $0 != winner }) {
                return (counts[previous] ?? 0) > 0 ? previous : nil
            }
        }
        return winner
    }
}
