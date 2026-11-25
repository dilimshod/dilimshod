import Foundation

// Voice coaching for beginner drivers: decides WHAT to say and WHEN. No texts here — the app turns a `CoachMessage`
// into a phrase of the current language (`coachText(_:language:)` in the app).
//
// Priorities (highest first): collision risk > red light ahead > lane departure > tailgating > signs > green light hint.
// A global minimum gap between utterances (≈ 3 s) keeps the coach calm; a collision warning bypasses it. Every
// category additionally has its own cooldown, and pending messages expire when they are no longer relevant.

/// One thing the coach wants to say (parameters only; localized by the app).
public enum CoachMessage: Hashable, Sendable {
    /// Forward-collision warning (closing fast on the lead vehicle).
    case collisionRisk
    /// A red traffic light ahead while still driving.
    case redLightAhead
    /// Drifting over the lane marking on `side`.
    case laneDeparture(side: LaneSide)
    /// Too close to the lead vehicle; `recommendedMeters` = recommended minimum gap (rounded), when known.
    case keepDistance(recommendedMeters: Int?)
    /// OSM road feature / sign ahead at about `distanceMeters`.
    case roadSign(kind: RouteFeatureKind, distanceMeters: Int)
    /// The speed limit of the current road changed.
    case speedLimit(kmh: Int)
    /// A new speed limit starts ahead.
    case speedLimitAhead(kmh: Int, distanceMeters: Int)
    /// The camera sees a STOP sign ahead.
    case stopSignAhead
    /// Driving over the posted limit.
    case overSpeedLimit(limitKmh: Int)
    /// Stopped at a light that turned green, nobody close ahead: gentle "you can go".
    case greenLightGo

    public var category: CoachCategory {
        switch self {
        case .collisionRisk: return .collision
        case .redLightAhead: return .redLight
        case .laneDeparture: return .laneDeparture
        case .keepDistance: return .tailgating
        case .roadSign, .speedLimit, .speedLimitAhead, .stopSignAhead, .overSpeedLimit: return .sign
        case .greenLightGo: return .greenLight
        }
    }

    /// How urgent the utterance is (the app maps it to its speech priority: high interrupts).
    public var urgency: CoachUrgency {
        switch category {
        case .collision, .redLight: return .high
        case .laneDeparture, .tailgating, .sign: return .normal
        case .greenLight: return .low
        }
    }

    /// Rounds a distance for speech: 10 m steps below 100 m, 50 m steps above.
    public static func spokenDistance(_ meters: Double) -> Int {
        guard meters.isFinite, meters > 0 else { return 0 }
        if meters < 100 { return max(10, Int((meters / 10).rounded()) * 10) }
        return Int((meters / 50).rounded()) * 50
    }
}

/// Priority order of coach messages (higher raw value = more important).
public enum CoachCategory: Int, Hashable, Sendable, Comparable, CaseIterable {
    case greenLight = 0, sign, tailgating, laneDeparture, redLight, collision

    public static func < (lhs: CoachCategory, rhs: CoachCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum CoachUrgency: Int, Hashable, Sendable, Comparable {
    case low = 0, normal, high

    public static func < (lhs: CoachUrgency, rhs: CoachUrgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Gatekeeper: queue of offered messages → at most one utterance at a time, by priority, with a global gap,
/// per-category cooldowns and expiry.
public struct CoachRules: Sendable {
    public struct Config: Sendable {
        /// Minimum time between two utterances, seconds (collision bypasses).
        public var minGap: TimeInterval
        /// Minimum time between two utterances of the same category.
        public var cooldowns: [CoachCategory: TimeInterval]
        /// An offered message is dropped when it could not be spoken within this time.
        public var timeToLive: [CoachCategory: TimeInterval]

        public init(minGap: TimeInterval = 3,
                    cooldowns: [CoachCategory: TimeInterval] = [.collision: 5, .redLight: 10, .laneDeparture: 6,
                                                                .tailgating: 12, .sign: 2, .greenLight: 20],
                    timeToLive: [CoachCategory: TimeInterval] = [.collision: 1.5, .redLight: 3, .laneDeparture: 2,
                                                                 .tailgating: 3, .sign: 8, .greenLight: 3]) {
            self.minGap = minGap
            self.cooldowns = cooldowns
            self.timeToLive = timeToLive
        }
    }

    public var config: Config
    private var pending: [(message: CoachMessage, offeredAt: TimeInterval)] = []
    private var lastSpoken: [CoachCategory: TimeInterval] = [:]
    private var lastUtterance: TimeInterval = -.infinity

    public init(config: Config = Config()) {
        self.config = config
    }

    public var pendingMessages: [CoachMessage] { pending.map(\.message) }

    public mutating func reset() {
        pending.removeAll()
    }

    /// Queues a message (an identical pending message is refreshed instead of duplicated; a newer message of the same
    /// non-sign category replaces the older one).
    public mutating func offer(_ message: CoachMessage, now: TimeInterval) {
        pending.removeAll { $0.message == message || ($0.message.category == message.category && message.category != .sign) }
        pending.append((message, now))
    }

    /// Marks a category as just spoken without speaking (e.g. suppress "keep distance" right after a collision warning).
    public mutating func markSpoken(_ category: CoachCategory, now: TimeInterval) {
        lastSpoken[category] = now
    }

    /// The message to speak now, if any (removes it from the queue).
    public mutating func next(now: TimeInterval) -> CoachMessage? {
        pending.removeAll { now - $0.offeredAt > (config.timeToLive[$0.message.category] ?? 3) }
        let ready = pending.enumerated().filter { _, item in
            let category = item.message.category
            if let last = lastSpoken[category], now - last < (config.cooldowns[category] ?? 0) { return false }
            return category == .collision || now - lastUtterance >= config.minGap
        }
        guard let best = ready.max(by: { a, b in
            a.element.message.category == b.element.message.category
                ? a.element.offeredAt > b.element.offeredAt    // same category: oldest first
                : a.element.message.category < b.element.message.category
        }) else { return nil }
        pending.remove(at: best.offset)
        let category = best.element.message.category
        lastSpoken[category] = now
        lastUtterance = now
        return best.element.message
    }
}

// MARK: - Traffic-light coaching (camera)

/// The traffic light the coach looks at (largest confirmed light of the frame).
public struct ObservedTrafficLight: Hashable, Sendable {
    public var trackID: Int
    public var color: TrafficLightColor
    public var box: BBox

    public init(trackID: Int, color: TrafficLightColor, box: BBox) {
        self.trackID = trackID
        self.color = color
        self.box = box
    }

    /// Largest confirmed, currently seen traffic light of `tracks`.
    public static func largest(in tracks: [TrackedObject]) -> ObservedTrafficLight? {
        tracks.filter { $0.kind == .trafficLight && $0.isConfirmed && $0.missed == 0 }
            .max { $0.box.area < $1.box.area }
            .map { ObservedTrafficLight(trackID: $0.id, color: $0.lightColor ?? .unknown, box: $0.box) }
    }
}

/// "Red light ahead" while driving and the gentle "green, you can go" after waiting at a red light.
public struct TrafficLightCoach: Sendable {
    public struct Config: Sendable {
        /// "Red ahead" only above this speed, km/h.
        public var redMinSpeedKmh: Double
        /// The red light must be seen this long (same track) before warning.
        public var redHold: TimeInterval
        /// Standing below this speed, km/h.
        public var stoppedSpeedKmh: Double
        /// Green must be seen this long while standing.
        public var greenHold: TimeInterval
        /// No "go" hint while a lead vehicle is closer than this, metres.
        public var minLeadGapMeters: Double
        /// Horizontal range (normalized x of the box centre) treated as "ahead".
        public var aheadMinX: Double
        public var aheadMaxX: Double
        /// Above this speed the waiting episode is over, km/h.
        public var movingSpeedKmh: Double

        public init(redMinSpeedKmh: Double = 20, redHold: TimeInterval = 0.5, stoppedSpeedKmh: Double = 3,
                    greenHold: TimeInterval = 1, minLeadGapMeters: Double = 4, aheadMinX: Double = 0.2,
                    aheadMaxX: Double = 0.8, movingSpeedKmh: Double = 8) {
            self.redMinSpeedKmh = redMinSpeedKmh
            self.redHold = redHold
            self.stoppedSpeedKmh = stoppedSpeedKmh
            self.greenHold = greenHold
            self.minLeadGapMeters = minLeadGapMeters
            self.aheadMinX = aheadMinX
            self.aheadMaxX = aheadMaxX
            self.movingSpeedKmh = movingSpeedKmh
        }
    }

    public var config: Config
    private var redTrack: Int?
    private var redSince: TimeInterval?
    private var warnedRedTracks = Set<Int>()
    private var sawRedWhileStopped = false
    private var greenSince: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        redTrack = nil
        redSince = nil
        sawRedWhileStopped = false
        greenSince = nil
    }

    public mutating func update(light: ObservedTrafficLight?, speedKmh: Double?, leadDistanceMeters: Double?,
                                timestamp: TimeInterval) -> CoachMessage? {
        let speed = speedKmh ?? 0
        let ahead = light.map { $0.box.midX >= config.aheadMinX && $0.box.midX <= config.aheadMaxX } ?? false

        // Red ahead while driving.
        if let light, ahead, light.color == .red, speedKmh != nil, speed > config.redMinSpeedKmh {
            if redTrack != light.trackID {
                redTrack = light.trackID
                redSince = timestamp
            }
            if let since = redSince, timestamp - since >= config.redHold, warnedRedTracks.insert(light.trackID).inserted {
                if warnedRedTracks.count > 64 { warnedRedTracks = [light.trackID] }
                return .redLightAhead
            }
        } else {
            redTrack = nil
            redSince = nil
        }

        // Waiting at a red light → green.
        guard speedKmh != nil else { return nil }
        if speed >= config.movingSpeedKmh {
            sawRedWhileStopped = false
            greenSince = nil
            return nil
        }
        guard speed < config.stoppedSpeedKmh, let light, ahead else {
            greenSince = nil
            return nil
        }
        switch light.color {
        case .red, .yellow:
            if light.color == .red { sawRedWhileStopped = true }
            greenSince = nil
        case .green:
            guard sawRedWhileStopped else { return nil }
            let since = greenSince ?? timestamp
            greenSince = since
            let leadOK = (leadDistanceMeters ?? .infinity) >= config.minLeadGapMeters
            if timestamp - since >= config.greenHold, leadOK {
                sawRedWhileStopped = false
                greenSince = nil
                return .greenLightGo
            }
        case .unknown:
            break
        }
        return nil
    }
}

// MARK: - Engine

/// Everything the coach needs from one camera frame (or a location update without camera).
public struct CoachFrameInput: Sendable {
    public var timestamp: TimeInterval
    public var speedKmh: Double?
    /// Following-distance assessment (nil when the feature is off).
    public var assessment: FollowingDistanceAssessment?
    /// A lead vehicle is currently tracked.
    public var hasLead: Bool
    public var collisionWarning: Bool
    /// A NEW lane departure was detected on this frame.
    public var laneDeparture: LaneSide?
    /// Largest confirmed traffic light of the frame.
    public var light: ObservedTrafficLight?

    public init(timestamp: TimeInterval, speedKmh: Double?, assessment: FollowingDistanceAssessment? = nil,
                hasLead: Bool = false, collisionWarning: Bool = false, laneDeparture: LaneSide? = nil,
                light: ObservedTrafficLight? = nil) {
        self.timestamp = timestamp
        self.speedKmh = speedKmh
        self.assessment = assessment
        self.hasLead = hasLead
        self.collisionWarning = collisionWarning
        self.laneDeparture = laneDeparture
        self.light = light
    }
}

/// Which coaching topics are switched on.
public struct CoachToggles: Hashable, Sendable {
    public var distance: Bool
    public var laneDeparture: Bool
    public var signs: Bool
    public var trafficLights: Bool

    public init(distance: Bool = true, laneDeparture: Bool = true, signs: Bool = true, trafficLights: Bool = true) {
        self.distance = distance
        self.laneDeparture = laneDeparture
        self.signs = signs
        self.trafficLights = trafficLights
    }
}

/// Combines the camera cues, sign events and `CoachRules` into utterances. Pure logic, one owner (main actor in the app).
public final class DriverCoachEngine {
    /// Collision condition must hold this long before the voice warning, seconds.
    public var collisionPersistence: TimeInterval = 0.2
    /// "Too close" (moving, < ½ recommended, no imminent collision) must hold this long, seconds.
    public var tooClosePersistence: TimeInterval = 1.0

    public var toggles: CoachToggles
    public private(set) var rules: CoachRules
    public private(set) var lights: TrafficLightCoach
    private var collisionSince: TimeInterval?
    private var tooCloseSince: TimeInterval?

    public init(toggles: CoachToggles = CoachToggles(), rules: CoachRules = CoachRules(),
                lights: TrafficLightCoach = TrafficLightCoach()) {
        self.toggles = toggles
        self.rules = rules
        self.lights = lights
    }

    public func reset() {
        collisionSince = nil
        tooCloseSince = nil
        lights.reset()
        rules.reset()
    }

    /// Feeds one camera frame; offers the resulting messages to the rules.
    public func update(_ input: CoachFrameInput) {
        let now = input.timestamp
        if toggles.distance, input.hasLead, let a = input.assessment, !a.isStopped {
            if input.collisionWarning {
                tooCloseSince = nil
                let since = collisionSince ?? now
                collisionSince = since
                if now - since >= collisionPersistence {
                    rules.offer(.collisionRisk, now: now)
                }
            } else if a.status == .danger {
                collisionSince = nil
                let since = tooCloseSince ?? now
                tooCloseSince = since
                if now - since >= tooClosePersistence {
                    let rec = a.recommendedDistanceMeters
                    rules.offer(.keepDistance(recommendedMeters: rec.isFinite ? CoachMessage.spokenDistance(rec) : nil),
                                now: now)
                }
            } else {
                collisionSince = nil
                tooCloseSince = nil
            }
        } else {
            collisionSince = nil
            tooCloseSince = nil
        }
        if toggles.laneDeparture, let side = input.laneDeparture {
            rules.offer(.laneDeparture(side: side), now: now)
        }
        if toggles.trafficLights {
            let leadDistance = input.hasLead ? input.assessment?.distanceMeters : nil
            if let message = lights.update(light: input.light, speedKmh: input.speedKmh,
                                           leadDistanceMeters: leadDistance, timestamp: now) {
                rules.offer(message, now: now)
            }
        }
    }

    /// Offers a sign event (ignored while sign announcements are off).
    public func offerSign(_ event: RoadSignEvent, now: TimeInterval) {
        guard toggles.signs else { return }
        switch event {
        case let .feature(kind, distance, _):
            rules.offer(.roadSign(kind: kind, distanceMeters: CoachMessage.spokenDistance(distance)), now: now)
        case let .speedLimit(kmh):
            rules.offer(.speedLimit(kmh: kmh), now: now)
        case let .speedLimitAhead(kmh, distance):
            rules.offer(.speedLimitAhead(kmh: kmh, distanceMeters: CoachMessage.spokenDistance(distance)), now: now)
        case .cameraStopSign:
            rules.offer(.stopSignAhead, now: now)
        }
    }

    /// Offers any message directly (e.g. `.overSpeedLimit`).
    public func offer(_ message: CoachMessage, now: TimeInterval) {
        rules.offer(message, now: now)
    }

    /// The message to speak now, if any.
    public func next(now: TimeInterval) -> CoachMessage? {
        guard let message = rules.next(now: now) else { return nil }
        if message == .collisionRisk {
            rules.markSpoken(.tailgating, now: now)   // no "keep distance" right after the collision warning
        }
        return message
    }
}
