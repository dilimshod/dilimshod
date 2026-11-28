import Foundation

// Road-sign announcements for beginner drivers: OSM features along the active route (from `RouteFeature`s), speed
// limit changes (current road `RoadSegmentInfo.speedLimit`, upcoming `RouteEdgeAttributes.speedLimitKmh`) and STOP
// signs confirmed by the camera (COCO class "stop sign"). Pure logic; texts come from the app's localization.

/// A road feature ahead of the driver with its distance along the route.
public struct FeatureAhead: Hashable, Sendable {
    public var id: String
    public var kind: RouteFeatureKind
    /// Distance from the current position to the feature along the route, metres (negative = already passed).
    public var distanceAhead: Double

    public init(id: String, kind: RouteFeatureKind, distanceAhead: Double) {
        self.id = id
        self.kind = kind
        self.distanceAhead = distanceAhead
    }

    /// Features of `features` between `minAhead` and `lookahead` metres ahead of `distanceAlong`.
    public static func from(features: [RouteFeature], distanceAlong: Double, lookahead: Double = 600,
                            minAhead: Double = -50) -> [FeatureAhead] {
        features.compactMap { f in
            let ahead = f.distanceAlongRoute - distanceAlong
            guard ahead >= minAhead, ahead <= lookahead else { return nil }
            return FeatureAhead(id: f.id, kind: f.kind, distanceAhead: ahead)
        }
    }
}

/// Something the coach may announce about signs / the road.
public enum RoadSignEvent: Hashable, Sendable {
    /// OSM feature ahead (speed camera, crossing, school, …) at about `distance` metres.
    case feature(kind: RouteFeatureKind, distance: Double, id: String)
    /// The posted speed limit changed to `kmh` (current road).
    case speedLimit(kmh: Int)
    /// A different speed limit starts `distance` metres ahead on the route.
    case speedLimitAhead(kmh: Int, distance: Double)
    /// The camera confirmed a STOP sign ahead.
    case cameraStopSign(trackID: Int)
}

public final class SignAnnouncer {
    public struct Config: Sendable {
        /// Kinds that are announced (beginner-relevant hazards and signs).
        public var announcedKinds: Set<RouteFeatureKind>
        /// Below this speed the "urban" (near) thresholds are used.
        public var urbanSpeedKmh: Double
        /// Do not announce a feature closer than this (too late to be useful).
        public var minDistance: Double
        /// A candidate speed limit must stay unchanged this long before it is announced (road matching flaps).
        public var speedLimitStableSeconds: TimeInterval
        /// Look-ahead for upcoming speed-limit changes on the route, metres (urban / rural).
        public var speedLimitAheadUrban: Double
        public var speedLimitAheadRural: Double
        /// Same camera STOP announcement is not repeated within this time even for a new track.
        public var cameraStopCooldown: TimeInterval
        /// A camera STOP is not announced when an OSM STOP was announced within this time.
        public var osmStopSuppression: TimeInterval

        public init(announcedKinds: Set<RouteFeatureKind> = [.speedCamera, .pedestrianCrossing, .school, .kindergarten,
                                                             .railwayCrossing, .stopSign, .giveWay, .trafficCalming,
                                                             .trafficSignals],
                    urbanSpeedKmh: Double = 65, minDistance: Double = 15, speedLimitStableSeconds: TimeInterval = 3,
                    speedLimitAheadUrban: Double = 150, speedLimitAheadRural: Double = 300,
                    cameraStopCooldown: TimeInterval = 20, osmStopSuppression: TimeInterval = 25) {
            self.announcedKinds = announcedKinds
            self.urbanSpeedKmh = urbanSpeedKmh
            self.minDistance = minDistance
            self.speedLimitStableSeconds = speedLimitStableSeconds
            self.speedLimitAheadUrban = speedLimitAheadUrban
            self.speedLimitAheadRural = speedLimitAheadRural
            self.cameraStopCooldown = cameraStopCooldown
            self.osmStopSuppression = osmStopSuppression
        }
    }

    public var config: Config
    private var announcedFeatureIDs = Set<String>()
    private var announcedLimitAheadKeys = Set<String>()
    private var announcedStopTracks = Set<Int>()
    private var lastCameraStop: TimeInterval = -.infinity
    private var lastOSMStop: TimeInterval = -.infinity
    private var announcedLimit: Int?
    private var candidateLimit: Int?
    private var candidateSince: TimeInterval?

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Forgets the announced ids (new route / trip).
    public func reset() {
        announcedFeatureIDs.removeAll()
        announcedLimitAheadKeys.removeAll()
        announcedStopTracks.removeAll()
        announcedLimit = nil
        candidateLimit = nil
        candidateSince = nil
    }

    /// Announcement distance for a kind: rural (≥ `urbanSpeedKmh`) thresholds ≈ 200 m, urban ≈ 100 m; speed cameras
    /// and railway crossings earlier.
    public func threshold(for kind: RouteFeatureKind, speedKmh: Double?) -> Double {
        let rural = (speedKmh ?? 0) >= config.urbanSpeedKmh
        switch kind {
        case .speedCamera: return rural ? 400 : 200
        case .railwayCrossing: return rural ? 300 : 150
        case .school, .kindergarten: return rural ? 250 : 150
        default: return rural ? 200 : 100
        }
    }

    /// OSM features ahead → at most one new announcement (the nearest), each feature id only once.
    public func update(features: [FeatureAhead], speedKmh: Double?, timestamp: TimeInterval) -> RoadSignEvent? {
        let candidates = features
            .filter { config.announcedKinds.contains($0.kind) && !announcedFeatureIDs.contains($0.id) }
            .sorted { $0.distanceAhead < $1.distanceAhead }
        for f in candidates {
            let limit = threshold(for: f.kind, speedKmh: speedKmh)
            if f.distanceAhead < config.minDistance {
                // Too close to be useful: mark it so it is not announced late.
                if f.distanceAhead > -50 { announcedFeatureIDs.insert(f.id) }
                continue
            }
            guard f.distanceAhead <= limit else { continue }
            announcedFeatureIDs.insert(f.id)
            if f.kind == .stopSign { lastOSMStop = timestamp }
            return .feature(kind: f.kind, distance: f.distanceAhead, id: f.id)
        }
        return nil
    }

    /// Current posted limit (nil = unknown). Returns `.speedLimit` once a changed value has been stable for
    /// `speedLimitStableSeconds`. Unknown values do not reset the announced limit.
    public func update(currentLimitKmh: Int?, timestamp: TimeInterval) -> RoadSignEvent? {
        guard let kmh = currentLimitKmh, kmh > 0 else {
            candidateLimit = nil
            candidateSince = nil
            return nil
        }
        guard kmh != announcedLimit else {
            candidateLimit = nil
            candidateSince = nil
            return nil
        }
        if candidateLimit != kmh {
            candidateLimit = kmh
            candidateSince = timestamp
        }
        guard let since = candidateSince, timestamp - since >= config.speedLimitStableSeconds else { return nil }
        announcedLimit = kmh
        candidateLimit = nil
        candidateSince = nil
        return .speedLimit(kmh: kmh)
    }

    /// Upcoming speed-limit change on the route (from Valhalla edge attributes), announced once per change point.
    public func update(edges: [RouteEdgeAttributes], distanceAlong: Double, speedKmh: Double?) -> RoadSignEvent? {
        let lookahead = (speedKmh ?? 0) >= config.urbanSpeedKmh ? config.speedLimitAheadRural : config.speedLimitAheadUrban
        guard let change = Self.nextSpeedLimitChange(edges: edges, distanceAlong: distanceAlong, lookahead: lookahead),
              change.distanceAhead >= config.minDistance else { return nil }
        let key = "\(Int(change.startDistance.rounded()))-\(change.kmh)"
        guard announcedLimitAheadKeys.insert(key).inserted else { return nil }
        return .speedLimitAhead(kmh: change.kmh, distance: change.distanceAhead)
    }

    /// First edge within `lookahead` metres ahead whose posted limit differs from the limit at `distanceAlong`.
    public static func nextSpeedLimitChange(edges: [RouteEdgeAttributes], distanceAlong: Double,
                                            lookahead: Double) -> (kmh: Int, distanceAhead: Double, startDistance: Double)? {
        guard let current = Valhalla.attributes(at: distanceAlong, in: edges)?.speedLimitKmh else { return nil }
        for edge in edges where edge.startDistance > distanceAlong {
            if edge.startDistance - distanceAlong > lookahead { break }
            if let kmh = edge.speedLimitKmh, kmh != current {
                return (kmh, edge.startDistance - distanceAlong, edge.startDistance)
            }
        }
        return nil
    }

    /// A STOP sign track confirmed by the camera. Announced once per track, rate-limited, and not right after an OSM
    /// STOP announcement (same sign).
    public func cameraStopSign(trackID: Int, timestamp: TimeInterval) -> RoadSignEvent? {
        guard announcedStopTracks.insert(trackID).inserted else { return nil }
        guard timestamp - lastCameraStop >= config.cameraStopCooldown,
              timestamp - lastOSMStop >= config.osmStopSuppression else { return nil }
        lastCameraStop = timestamp
        return .cameraStopSign(trackID: trackID)
    }
}
