import Foundation

// Camera-based driving events (violations) for the trip report. All of them are HEURISTICS on monocular estimates —
// the app labels them as such. The pipeline feeds `CameraDrivingEventMonitor` once per processed frame and forwards the
// new events (with GPS coordinate and speed) through `RecognitionPipeline.onDrivingEvent`.

/// Detects "drove through a red light": own speed above `minSpeedKmh` while a confirmed red-light track in the
/// upper-centre of the frame disappears off the top edge (the car passed under / beside it while it was red).
public struct RedLightRunningDetector: Sendable {
    public struct Config: Sendable {
        public var minSpeedKmh: Double
        /// The last box must touch this band at the top of the frame (box minY ≤ value).
        public var topEdge: Double
        /// Horizontal range of the box centre treated as "our" light.
        public var minX: Double
        public var maxX: Double
        /// The red track must have been seen at least this long.
        public var minTrackAge: TimeInterval
        /// A track not seen for this long is considered gone.
        public var lostAfter: TimeInterval

        public init(minSpeedKmh: Double = 15, topEdge: Double = 0.06, minX: Double = 0.25, maxX: Double = 0.75,
                    minTrackAge: TimeInterval = 0.8, lostAfter: TimeInterval = 0.3) {
            self.minSpeedKmh = minSpeedKmh
            self.topEdge = topEdge
            self.minX = minX
            self.maxX = maxX
            self.minTrackAge = minTrackAge
            self.lostAfter = lostAfter
        }
    }

    private struct Entry: Sendable {
        var box: BBox
        var color: TrafficLightColor
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var speedAtLastSeen: Double?
    }

    public var config: Config
    private var entries: [Int: Entry] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() { entries.removeAll() }

    /// - Returns: the own speed (km/h) when a red light was just passed, else nil.
    public mutating func update(tracks: [TrackedObject], speedKmh: Double?, timestamp: TimeInterval) -> Double? {
        var seen = Set<Int>()
        for t in tracks where t.kind == .trafficLight && t.isConfirmed && t.missed == 0 {
            let color = t.lightColor ?? .unknown
            if var e = entries[t.id] {
                e.box = t.box
                // No latch here: the tracker already smooths the colour and holds it ≈ 1 s without a readable lamp
                // (`ObjectTracker.lightColorMaxAge`), so a lamp cropped at the top edge in its last frames still
                // counts as red, while a light unreadable for longer no longer yields a red-light event.
                e.color = color
                e.lastSeen = timestamp
                e.speedAtLastSeen = speedKmh
                entries[t.id] = e
                seen.insert(t.id)
            } else if color == .red, t.box.midX >= config.minX, t.box.midX <= config.maxX, t.box.midY < 0.5 {
                entries[t.id] = Entry(box: t.box, color: color, firstSeen: timestamp, lastSeen: timestamp,
                                      speedAtLastSeen: speedKmh)
                seen.insert(t.id)
            }
        }
        var result: Double?
        for (id, e) in entries where !seen.contains(id) && timestamp - e.lastSeen >= config.lostAfter {
            entries[id] = nil
            guard e.color == .red, e.box.minY <= config.topEdge, e.box.midX >= config.minX - 0.05,
                  e.box.midX <= config.maxX + 0.05, e.lastSeen - e.firstSeen >= config.minTrackAge,
                  let speed = e.speedAtLastSeen ?? speedKmh, speed > config.minSpeedKmh else { continue }
            result = max(result ?? 0, speed)
        }
        return result
    }
}

/// Detects "did not stop at a STOP sign": a confirmed STOP sign within `armDistance` metres ahead arms an episode;
/// when the sign has been out of sight for `passTimeout` seconds the episode can end — but it stays open while the
/// driver may still be braking to the line (not yet past the sign by `passMarginMeters`, not speeding up again, at most
/// `maxEpisodeAfterLost` seconds). If the own speed never dropped below `stopSpeedKmh` meanwhile, it is a violation. Distance from the box width with a typical sign width.
public struct StopSignComplianceMonitor: Sendable {
    public struct Config: Sendable {
        public var armDistance: Double
        public var stopSpeedKmh: Double
        public var passTimeout: TimeInterval
        /// Typical STOP sign width (octagon across flats), metres (0.6–0.9 m by road class).
        public var signWidthMeters: Double
        /// Only arm while moving at least this fast (else the car is already stopped), km/h.
        public var minArmSpeedKmh: Double

        /// After `passTimeout` the episode stays open while the car may still be braking to the line. It is judged
        /// once the car has travelled the sign's last distance plus this margin, metres (a roadside sign leaves the
        /// field of view ≈ 6–11 m before it is reached).
        public var passMarginMeters: Double
        /// Hard cap of the episode after the sign was lost, seconds.
        public var maxEpisodeAfterLost: TimeInterval
        /// Speeding up by this much above the lowest speed of the episode ends it (the driver is leaving), km/h.
        public var resumeDeltaKmh: Double

        public init(armDistance: Double = 30, stopSpeedKmh: Double = 5, passTimeout: TimeInterval = 2.5,
                    signWidthMeters: Double = 0.7, minArmSpeedKmh: Double = 8, passMarginMeters: Double = 10,
                    maxEpisodeAfterLost: TimeInterval = 10, resumeDeltaKmh: Double = 2) {
            self.passMarginMeters = passMarginMeters
            self.maxEpisodeAfterLost = maxEpisodeAfterLost
            self.resumeDeltaKmh = resumeDeltaKmh
            self.armDistance = armDistance
            self.stopSpeedKmh = stopSpeedKmh
            self.passTimeout = passTimeout
            self.signWidthMeters = signWidthMeters
            self.minArmSpeedKmh = minArmSpeedKmh
        }
    }

    public struct Violation: Hashable, Sendable {
        /// Lowest own speed while passing, km/h.
        public var minSpeedKmh: Double
        /// Distance of the sign when the episode was armed, metres.
        public var armedDistance: Double
        public var duration: TimeInterval
    }

    public var config: Config
    private var armedAt: TimeInterval?
    private var armedDistance: Double = 0
    private var minSpeed: Double = .infinity
    private var lastSignSeen: TimeInterval = -.infinity
    private var speedKnown = true
    private var lastSignDistance: Double = 0
    private var travelledSinceSeen: Double = 0
    private var lastUpdate: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isArmed: Bool { armedAt != nil }

    public mutating func reset() {
        armedAt = nil
        minSpeed = .infinity
        speedKnown = true
        travelledSinceSeen = 0
        lastUpdate = nil
    }

    /// Approximate distance of a STOP sign box, metres.
    public func distance(of box: BBox, geometry: CameraGeometry) -> Double? {
        guard box.width > 0.003, geometry.imageWidth > 0 else { return nil }
        return geometry.focalLengthPixels * config.signWidthMeters / (box.width * geometry.imageWidth)
    }

    public mutating func update(tracks: [TrackedObject], geometry: CameraGeometry, speedKmh: Double?,
                                timestamp: TimeInterval) -> Violation? {
        let signs = tracks.filter { $0.kind == .stopSign && $0.isConfirmed && $0.missed == 0 }
        let nearest = signs.compactMap { distance(of: $0.box, geometry: geometry) }.min()
        if !signs.isEmpty { lastSignSeen = timestamp }
        if armedAt == nil {
            if let d = nearest, d <= config.armDistance, let speed = speedKmh, speed >= config.minArmSpeedKmh {
                armedAt = timestamp
                armedDistance = d
                minSpeed = speed
                speedKnown = true
                lastSignDistance = d
                travelledSinceSeen = 0
                lastUpdate = timestamp
            }
            return nil
        }
        if let speed = speedKmh { minSpeed = min(minSpeed, speed) } else { speedKnown = false }
        let dt = max(0, min(timestamp - (lastUpdate ?? timestamp), 1.0))
        lastUpdate = timestamp
        if !signs.isEmpty {
            travelledSinceSeen = 0
            if let d = nearest { lastSignDistance = d }
            return nil
        }
        travelledSinceSeen += (speedKmh ?? 0) / 3.6 * dt
        let lost = timestamp - lastSignSeen
        guard lost >= config.passTimeout, let start = armedAt else { return nil }
        let stopped = speedKnown && minSpeed < config.stopSpeedKmh
        // Still approaching the line: not yet past the sign, not accelerating again, hard cap not reached.
        let passed = travelledSinceSeen >= lastSignDistance + config.passMarginMeters
        let resumed = speedKmh.map { $0 >= minSpeed + config.resumeDeltaKmh } ?? true
        if !stopped, !passed, !resumed, lost < config.maxEpisodeAfterLost { return nil }
        armedAt = nil
        defer {
            minSpeed = .infinity
            travelledSinceSeen = 0
            lastUpdate = nil
        }
        guard speedKnown, minSpeed.isFinite, minSpeed >= config.stopSpeedKmh else { return nil }
        return Violation(minSpeedKmh: minSpeed, armedDistance: armedDistance, duration: timestamp - start)
    }
}

/// Detects "did not give way to a pedestrian": a `.danger` pedestrian hazard in the own lane within `maxDistance`
/// metres while the own speed stays above `minSpeedKmh` for at least `minDuration` seconds (same track). Reported once
/// per pedestrian track; `value` = closest distance (≈ m).
public struct PedestrianYieldMonitor: Sendable {
    public struct Config: Sendable {
        public var minSpeedKmh: Double
        public var maxDistance: Double
        public var minDuration: TimeInterval

        public init(minSpeedKmh: Double = 15, maxDistance: Double = 15, minDuration: TimeInterval = 0.4) {
            self.minSpeedKmh = minSpeedKmh
            self.maxDistance = maxDistance
            self.minDuration = minDuration
        }
    }

    public struct Violation: Hashable, Sendable {
        public var trackID: Int
        /// Closest distance to the pedestrian during the episode, metres (≈).
        public var closestDistance: Double
        /// Lowest own speed during the episode, km/h.
        public var minSpeedKmh: Double
        public var duration: TimeInterval
    }

    private struct Episode: Sendable {
        var start: TimeInterval
        var closest: Double
        var minSpeed: Double
    }

    public var config: Config
    private var episodes: [Int: Episode] = [:]
    private var reported = Set<Int>()

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        episodes.removeAll()
        reported.removeAll()
    }

    public mutating func update(hazards: [PedestrianHazard], speedKmh: Double?, timestamp: TimeInterval) -> [Violation] {
        var result: [Violation] = []
        var active = Set<Int>()
        if let speed = speedKmh, speed > config.minSpeedKmh {
            for h in hazards where h.level == .danger && h.inOwnLane {
                guard let d = h.distanceMeters, d <= config.maxDistance else { continue }
                active.insert(h.trackID)
                var e = episodes[h.trackID] ?? Episode(start: timestamp, closest: d, minSpeed: speed)
                e.closest = min(e.closest, d)
                e.minSpeed = min(e.minSpeed, speed)
                episodes[h.trackID] = e
                if timestamp - e.start >= config.minDuration, reported.insert(h.trackID).inserted {
                    result.append(Violation(trackID: h.trackID, closestDistance: e.closest, minSpeedKmh: e.minSpeed,
                                            duration: timestamp - e.start))
                }
            }
        }
        for id in episodes.keys where !active.contains(id) { episodes[id] = nil }
        if reported.count > 256 { reported = reported.intersection(active) }
        return result
    }
}

/// Inputs of one processed frame for the event monitor.
public struct CameraEventInput: Sendable {
    public var timestamp: TimeInterval
    public var date: Date
    public var speedKmh: Double?
    public var coordinate: GeoPoint?
    public var assessment: FollowingDistanceAssessment?
    public var hasLead: Bool
    public var collisionWarning: Bool
    /// Collision TTC threshold of the policy, seconds (for `DrivingEvent.limit`).
    public var collisionThresholdSeconds: Double
    /// NEW lane departure on this frame (from `LaneDepartureDetector`).
    public var laneDeparture: LaneSide?
    /// Lane offset at the departure (for `DrivingEvent.value`).
    public var laneOffset: Double?
    public var tracks: [TrackedObject]
    public var geometry: CameraGeometry?
    /// Pedestrians on / about to enter the roadway (from `PedestrianHazardDetector`; empty when the feature is off).
    public var pedestrianHazards: [PedestrianHazard]
    /// Traffic officers / road workers on or at the roadway (colour heuristic).
    public var roadStaff: [RoadStaffSighting]

    public init(timestamp: TimeInterval, date: Date = Date(), speedKmh: Double?, coordinate: GeoPoint? = nil,
                assessment: FollowingDistanceAssessment? = nil, hasLead: Bool = false, collisionWarning: Bool = false,
                collisionThresholdSeconds: Double = 2.5, laneDeparture: LaneSide? = nil, laneOffset: Double? = nil,
                tracks: [TrackedObject] = [], geometry: CameraGeometry? = nil,
                pedestrianHazards: [PedestrianHazard] = [], roadStaff: [RoadStaffSighting] = []) {
        self.timestamp = timestamp
        self.date = date
        self.speedKmh = speedKmh
        self.coordinate = coordinate
        self.assessment = assessment
        self.hasLead = hasLead
        self.collisionWarning = collisionWarning
        self.collisionThresholdSeconds = collisionThresholdSeconds
        self.laneDeparture = laneDeparture
        self.laneOffset = laneOffset
        self.tracks = tracks
        self.geometry = geometry
        self.pedestrianHazards = pedestrianHazards
        self.roadStaff = roadStaff
    }
}

/// Produces camera-based `DrivingEvent`s: tailgating (moving, gap < ½ recommended for ≥ 2 s), collision risk
/// (forward-collision warning), lane departure, red-light running, STOP sign ignored and pedestrian not given way. Repeats are collapsed with
/// `DrivingEventDebouncer`, so only NEW events are returned.
public final class CameraDrivingEventMonitor {
    /// Tailgating: gap below this fraction of the recommended gap…
    public var tailgatingFraction: Double = 0.5
    /// …for at least this long, seconds.
    public var tailgatingDuration: TimeInterval = 2
    /// Note attached to heuristic events.
    public static let heuristicNote = "heuristic"

    public var redLight = RedLightRunningDetector()
    public var stopSign = StopSignComplianceMonitor()
    public var pedestrians = PedestrianYieldMonitor()
    /// Officer / road-worker tracks already logged (each track once; the debouncer merges repeats within the cooldown).
    private var loggedStaffTracks = Set<Int>()
    public private(set) var debouncer: DrivingEventDebouncer
    private var tailgatingSince: TimeInterval?
    private var tailgatingReported = false
    private var worstGap: Double = .infinity
    private var collisionActive = false

    public init(cooldown: TimeInterval = 8) {
        debouncer = DrivingEventDebouncer(cooldown: cooldown)
    }

    public func reset() {
        tailgatingSince = nil
        tailgatingReported = false
        worstGap = .infinity
        collisionActive = false
        redLight.reset()
        stopSign.reset()
        pedestrians.reset()
        loggedStaffTracks.removeAll()
    }

    /// New events of this frame.
    public func update(_ input: CameraEventInput) -> [DrivingEvent] {
        var events: [DrivingEvent] = []
        func make(_ kind: DrivingEventKind, value: Double? = nil, limit: Double? = nil, duration: TimeInterval = 0,
                  heuristic: Bool = true) -> DrivingEvent {
            DrivingEvent(kind: kind, date: input.date, coordinate: input.coordinate, speedKmh: input.speedKmh,
                         value: value, limit: limit, duration: duration, note: heuristic ? Self.heuristicNote : nil)
        }

        // Tailgating.
        if input.hasLead, let a = input.assessment, !a.isStopped, let d = a.distanceMeters,
           let fraction = a.fractionOfRecommended, fraction < tailgatingFraction {
            let since = tailgatingSince ?? input.timestamp
            tailgatingSince = since
            worstGap = min(worstGap, d)
            if !tailgatingReported, input.timestamp - since >= tailgatingDuration {
                tailgatingReported = true
                events.append(make(.tailgating, value: worstGap, limit: a.recommendedDistanceMeters,
                                   duration: input.timestamp - since))
            }
        } else {
            tailgatingSince = nil
            tailgatingReported = false
            worstGap = .infinity
        }

        // Collision risk (rising edge of the forward-collision warning).
        if input.collisionWarning {
            if !collisionActive {
                collisionActive = true
                events.append(make(.collisionRisk, value: input.assessment?.timeToCollisionSeconds,
                                   limit: input.collisionThresholdSeconds))
            }
        } else {
            collisionActive = false
        }

        if let side = input.laneDeparture {
            var e = make(.laneDeparture, value: input.laneOffset)
            e.note = "\(Self.heuristicNote); side=\(side.rawValue)"
            events.append(e)
        }

        if let speed = redLight.update(tracks: input.tracks, speedKmh: input.speedKmh, timestamp: input.timestamp) {
            var e = make(.redLightRunning, value: speed)
            e.speedKmh = speed
            events.append(e)
        }

        if let geometry = input.geometry,
           let v = stopSign.update(tracks: input.tracks, geometry: geometry, speedKmh: input.speedKmh,
                                   timestamp: input.timestamp) {
            events.append(make(.stopSignIgnored, value: v.minSpeedKmh, limit: stopSign.config.stopSpeedKmh,
                               duration: v.duration))
        }

        for v in pedestrians.update(hazards: input.pedestrianHazards, speedKmh: input.speedKmh,
                                    timestamp: input.timestamp) {
            events.append(make(.pedestrianNotYielded, value: v.closestDistance, limit: pedestrians.config.maxDistance,
                               duration: v.duration))
        }

        // Observations (info, not violations): traffic officer / road workers seen, once per track.
        for s in input.roadStaff where loggedStaffTracks.insert(s.trackID).inserted {
            if loggedStaffTracks.count > 256 { loggedStaffTracks = [s.trackID] }
            let kind: DrivingEventKind = s.role == .trafficOfficer ? .trafficOfficerSeen : .roadWorkersSeen
            events.append(make(kind, value: s.distanceMeters))
        }

        return events.filter { debouncer.add($0) }
    }
}
