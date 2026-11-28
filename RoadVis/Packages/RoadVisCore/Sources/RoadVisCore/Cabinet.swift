import Foundation

// Driver cabinet (`docs/CABINET_API.md` §1, §2, §4): request / response bodies, the trip upload payload, the QR
// login payload check and the mapping of HTTP status codes. Field names are the contract (shared with the server
// and the Android app): do not rename. Foundation only (built on Linux).

/// Endpoint paths relative to the configured server URL (e.g. `https://trafficcounter.uz/roadvis`).
public enum CabinetAPI {
    public static let registerPath = "api/v1/devices/register"
    public static let mePath = "api/v1/me"
    public static let tripsPath = "api/v1/trips"
    public static let qrApprovePath = "api/v1/auth/qr/approve"
    /// Path of the QR payload below the server URL: `<server>/qr?c=<challengeId>&n=<nonce>`.
    public static let qrPath = "qr"
    /// "ios" / "android".
    public static let platformIOS = "ios"
}

// MARK: - §1 Registration and profile

/// `POST /api/v1/devices/register` body.
public struct CabinetRegisterRequest: Codable, Equatable, Sendable {
    public var platform: String
    public var appVersion: String
    public var deviceName: String
    public var driverName: String
    /// "uz" | "ru" | "en".
    public var language: String

    public init(platform: String, appVersion: String, deviceName: String, driverName: String, language: String) {
        self.platform = platform
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.driverName = driverName
        self.language = language
    }
}

/// `201` answer of the registration.
public struct CabinetRegisterResponse: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var driverId: String
    public var driverName: String

    public init(deviceToken: String, driverId: String, driverName: String) {
        self.deviceToken = deviceToken
        self.driverId = driverId
        self.driverName = driverName
    }
}

/// `PATCH /api/v1/me` body.
public struct CabinetRenameRequest: Codable, Equatable, Sendable {
    public var driverName: String

    public init(driverName: String) {
        self.driverName = driverName
    }
}

/// `GET /api/v1/me` (and `PATCH`) answer. Numbers are decoded leniently (an integer sent as `12.0` is accepted).
public struct CabinetMe: Codable, Equatable, Sendable {
    public var driverId: String
    public var driverName: String
    public var createdAt: String?
    public var tripCount: Int
    public var points: Int
    public var level: Int

    public init(driverId: String, driverName: String, createdAt: String? = nil, tripCount: Int = 0, points: Int = 0,
                level: Int = 1) {
        self.driverId = driverId
        self.driverName = driverName
        self.createdAt = createdAt
        self.tripCount = tripCount
        self.points = points
        self.level = level
    }

    private enum CodingKeys: String, CodingKey {
        case driverId, driverName, createdAt, tripCount, points, level
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        driverId = try container.decode(String.self, forKey: .driverId)
        driverName = try container.decodeIfPresent(String.self, forKey: .driverName) ?? ""
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        tripCount = Self.lenientInt(container, .tripCount) ?? 0
        points = Self.lenientInt(container, .points) ?? 0
        level = Self.lenientInt(container, .level) ?? 1
    }

    private static func lenientInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value.rounded())
        }
        return nil
    }
}

// MARK: - §2 Trip upload

/// Body of `POST /api/v1/trips`, built from a finished `Trip` with `TripStats.compute` and `TripScoring`.
/// Optional values are written as JSON `null` (never omitted), so every key is always present.
public struct CabinetTripPayload: Encodable, Equatable, Sendable {
    /// Trips shorter than this are not uploaded.
    public static let minDistanceMeters: Double = 300
    /// …or shorter than this.
    public static let minDurationSeconds: Double = 60
    /// Douglas–Peucker tolerance of the uploaded track (`Geo.simplify`).
    public static let simplifyToleranceMeters: Double = 5
    /// Track rows after simplification.
    public static let maxTrackPoints = 2000

    public struct Place: Encodable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public var name: String?

        public init(lat: Double, lon: Double, name: String?) {
            self.lat = lat
            self.lon = lon
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case lat, lon, name }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lat, forKey: .lat)
            try container.encode(lon, forKey: .lon)
            try container.encode(name, forKey: .name)
        }
    }

    /// One track row: `[lat, lon, secondsFromStart, speedKmh|null, speedLimitKmh|null]`.
    public struct TrackRow: Encodable, Equatable, Sendable {
        public var lat: Double
        public var lon: Double
        public var secondsFromStart: Double
        public var speedKmh: Double?
        public var speedLimitKmh: Int?

        public init(lat: Double, lon: Double, secondsFromStart: Double, speedKmh: Double?, speedLimitKmh: Int?) {
            self.lat = lat
            self.lon = lon
            self.secondsFromStart = secondsFromStart
            self.speedKmh = speedKmh
            self.speedLimitKmh = speedLimitKmh
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(lat)
            try container.encode(lon)
            try container.encode(secondsFromStart)
            if let speedKmh { try container.encode(speedKmh) } else { try container.encodeNil() }
            if let speedLimitKmh { try container.encode(speedLimitKmh) } else { try container.encodeNil() }
        }
    }

    public struct Event: Encodable, Equatable, Sendable {
        /// `DrivingEventKind` raw value.
        public var kind: String
        /// "info" | "warning" | "violation".
        public var severity: String
        /// ISO 8601 UTC.
        public var at: String
        public var lat: Double?
        public var lon: Double?
        public var speedKmh: Double?
        public var value: Double?
        public var limit: Double?
        public var durationSeconds: Double

        private enum CodingKeys: String, CodingKey {
            case kind, severity, at, lat, lon, speedKmh, value, limit, durationSeconds
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(severity, forKey: .severity)
            try container.encode(at, forKey: .at)
            try container.encode(lat, forKey: .lat)
            try container.encode(lon, forKey: .lon)
            try container.encode(speedKmh, forKey: .speedKmh)
            try container.encode(value, forKey: .value)
            try container.encode(limit, forKey: .limit)
            try container.encode(durationSeconds, forKey: .durationSeconds)
        }
    }

    public var id: String
    public var platform: String
    public var appVersion: String
    public var startedAt: String
    public var endedAt: String
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var movingSeconds: Double
    public var avgSpeedKmh: Double
    public var maxSpeedKmh: Double
    public var timeOverLimitSeconds: Double
    public var score: Int
    public var arrived: Bool
    public var startedWithNavigation: Bool
    public var origin: Place?
    public var destination: Place?
    /// `DrivingEventKind` raw value → count (kinds without events are left out).
    public var eventCounts: [String: Int]
    /// `TripSpeedBand` raw value → seconds (every band present).
    public var speedBands: [String: Double]
    public var avgLeadDistanceMeters: Double?
    public var shareBelowRecommendedGap: Double?
    public var track: [TrackRow]
    public var events: [Event]

    private enum CodingKeys: String, CodingKey {
        case id, platform, appVersion, startedAt, endedAt, distanceMeters, durationSeconds, movingSeconds,
             avgSpeedKmh, maxSpeedKmh, timeOverLimitSeconds, score, arrived, startedWithNavigation, origin,
             destination, eventCounts, speedBands, avgLeadDistanceMeters, shareBelowRecommendedGap, track, events
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(platform, forKey: .platform)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(distanceMeters, forKey: .distanceMeters)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(movingSeconds, forKey: .movingSeconds)
        try c.encode(avgSpeedKmh, forKey: .avgSpeedKmh)
        try c.encode(maxSpeedKmh, forKey: .maxSpeedKmh)
        try c.encode(timeOverLimitSeconds, forKey: .timeOverLimitSeconds)
        try c.encode(score, forKey: .score)
        try c.encode(arrived, forKey: .arrived)
        try c.encode(startedWithNavigation, forKey: .startedWithNavigation)
        try c.encode(origin, forKey: .origin)
        try c.encode(destination, forKey: .destination)
        try c.encode(eventCounts, forKey: .eventCounts)
        try c.encode(speedBands, forKey: .speedBands)
        try c.encode(avgLeadDistanceMeters, forKey: .avgLeadDistanceMeters)
        try c.encode(shareBelowRecommendedGap, forKey: .shareBelowRecommendedGap)
        try c.encode(track, forKey: .track)
        try c.encode(events, forKey: .events)
    }

    /// True when the trip is long enough to be uploaded (≥ 300 m and ≥ 60 s).
    public static func isUploadable(distanceMeters: Double, durationSeconds: Double) -> Bool {
        distanceMeters >= minDistanceMeters && durationSeconds >= minDurationSeconds
    }

    /// Builds the payload; nil for trips under 300 m or under 60 s (they are not uploaded).
    public static func make(trip: Trip, platform: String = CabinetAPI.platformIOS,
                            appVersion: String) -> CabinetTripPayload? {
        let stats = TripStats.compute(trip)
        guard isUploadable(distanceMeters: stats.distanceMeters, durationSeconds: stats.duration) else { return nil }
        let scoring = TripScoring.score(events: trip.events, distanceMeters: stats.distanceMeters)

        var counts: [String: Int] = [:]
        for (kind, count) in stats.eventCounts where count > 0 { counts[kind.rawValue] = count }
        var bands: [String: Double] = [:]
        for band in TripSpeedBand.allCases { bands[band.rawValue] = round(stats.timeBySpeedBand[band] ?? 0, 1) }

        return CabinetTripPayload(
            id: trip.id.uuidString.lowercased(),
            platform: platform,
            appVersion: appVersion,
            startedAt: timestamp(trip.startedAt),
            endedAt: timestamp(trip.effectiveEnd),
            distanceMeters: round(stats.distanceMeters, 1),
            durationSeconds: round(stats.duration, 1),
            movingSeconds: round(stats.movingDuration, 1),
            avgSpeedKmh: round(stats.averageSpeedKmh, 1),
            maxSpeedKmh: round(stats.maxSpeedKmh, 1),
            timeOverLimitSeconds: round(stats.timeOverLimit, 1),
            score: scoring.score,
            arrived: trip.arrived,
            startedWithNavigation: trip.startedWithNavigation,
            origin: place(trip.origin),
            destination: trip.destination.flatMap(place),
            eventCounts: counts,
            speedBands: bands,
            avgLeadDistanceMeters: stats.averageLeadDistanceMeters.map { round($0, 1) },
            shareBelowRecommendedGap: stats.shareBelowRecommendedGap.map { round($0, 3) },
            track: track(for: trip),
            events: trip.sortedEvents.map(event)
        )
    }

    /// Simplified track rows (Douglas–Peucker 5 m, at most 2000 rows), time-ordered.
    public static func track(for trip: Trip) -> [TrackRow] {
        let points = trip.points
            .filter { $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite }
            .sorted { $0.date < $1.date }
        let coordinates = points.map(\.coordinate)
        var indices = Geo.simplifiedIndices(coordinates, maxPoints: maxTrackPoints,
                                            initialTolerance: simplifyToleranceMeters)
        if indices.count > maxTrackPoints {
            // Degenerate input the tolerance doubling could not reduce: even subsample, keeping both ends.
            let step = Double(indices.count - 1) / Double(maxTrackPoints - 1)
            indices = (0..<maxTrackPoints).map { indices[Int((Double($0) * step).rounded())] }
        }
        return indices.map { index in
            let point = points[index]
            var speed: Double?
            if let value = point.speedKmh, value.isFinite, value >= 0 { speed = round(value, 1) }
            return TrackRow(lat: round(point.coordinate.latitude, 6), lon: round(point.coordinate.longitude, 6),
                            secondsFromStart: round(max(0, point.date.timeIntervalSince(trip.startedAt)), 1),
                            speedKmh: speed, speedLimitKmh: point.speedLimitKmh)
        }
    }

    /// "info" | "warning" | "violation".
    public static func severityName(_ severity: DrivingEventSeverity) -> String {
        switch severity {
        case .info: return "info"
        case .warning: return "warning"
        case .violation: return "violation"
        }
    }

    /// "2026-11-28T08:00:00Z" (UTC, whole seconds).
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Encoder of the request body (sorted keys, no escaped slashes).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    private static func place(_ endpoint: TripEndpoint) -> Place? {
        guard let coordinate = endpoint.coordinate, coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return nil
        }
        let name = endpoint.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Place(lat: round(coordinate.latitude, 6), lon: round(coordinate.longitude, 6),
                     name: (name?.isEmpty ?? true) ? nil : name)
    }

    private static func event(_ event: DrivingEvent) -> Event {
        Event(kind: event.kind.rawValue, severity: severityName(event.severity), at: timestamp(event.date),
              lat: event.coordinate.map { round($0.latitude, 6) }, lon: event.coordinate.map { round($0.longitude, 6) },
              speedKmh: finite(event.speedKmh, 1), value: finite(event.value, 2), limit: finite(event.limit, 2),
              durationSeconds: round(max(0, event.duration), 1))
    }

    private static func finite(_ value: Double?, _ digits: Int) -> Double? {
        guard let value, value.isFinite else { return nil }
        return round(value, digits)
    }

    static func round(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }
}

/// What to do with a queued trip after `POST /api/v1/trips` answered with `statusCode`.
public enum CabinetTripUploadOutcome: Equatable, Sendable {
    /// 200 / 201: done, remove from the queue.
    case uploaded
    /// 413 / 422: the server will never take it, remove from the queue.
    case rejected
    /// 401: the device token is not valid; keep the trip, stop.
    case unauthorized
    /// 429, 5xx, anything else: keep the trip, retry with back-off.
    case retryLater

    public init(statusCode: Int) {
        switch statusCode {
        case 200, 201: self = .uploaded
        case 413, 422: self = .rejected
        case 401, 403: self = .unauthorized
        default: self = .retryLater
        }
    }
}

// MARK: - §4 QR login

/// QR code of the website login: `https://<host><basePath>/qr?c=<challengeId>&n=<nonce>`. Accepted only when the
/// scheme, host (and port) and path prefix equal the configured server URL (no logging in to foreign sites); http
/// only when the configured server itself is http (local testing).
public struct QRLoginPayload: Equatable, Sendable {
    public enum ParseError: Error, Equatable, Sendable {
        /// Not a URL / not http(s).
        case notALink
        /// The configured server URL is not usable.
        case badConfiguredBase
        /// Another host, port or path than the configured server (a foreign site).
        case foreignSite
        /// http while the configured server is https.
        case insecure
        /// `c` (UUID) or `n` (nonce) missing or malformed.
        case missingParameters
    }

    public var challengeId: String
    public var nonce: String
    /// Host of the site that will be logged in (shown in the confirmation).
    public var host: String

    public init(challengeId: String, nonce: String, host: String) {
        self.challengeId = challengeId
        self.nonce = nonce
        self.host = host
    }

    /// Nonce: url-safe characters (`A–Z a–z 0–9 - _`), 16…256 long (the server issues 32).
    public static let nonceLengthRange = 16...256

    public static func parse(_ text: String, configuredBase: String) -> Result<QRLoginPayload, ParseError> {
        guard let base = URLComponents(string: configuredBase.trimmingCharacters(in: .whitespacesAndNewlines)),
              let baseScheme = base.scheme?.lowercased(), baseScheme == "https" || baseScheme == "http",
              let baseHost = base.host?.lowercased(), !baseHost.isEmpty else {
            return .failure(.badConfiguredBase)
        }
        guard let link = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = link.host?.lowercased(), !host.isEmpty else {
            return .failure(.notALink)
        }
        if link.user != nil || link.password != nil { return .failure(.foreignSite) }
        guard host == baseHost else { return .failure(.foreignSite) }
        // Same scheme: the effective ports must match. An https link for an http server (allowed): explicit ports
        // must match.
        let samePort = scheme == baseScheme
            ? effectivePort(link.port, scheme: scheme) == effectivePort(base.port, scheme: baseScheme)
            : link.port == base.port
        guard samePort else { return .failure(.foreignSite) }
        if scheme == "http" && baseScheme != "http" { return .failure(.insecure) }
        var basePath = base.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let expected = basePath + "/" + CabinetAPI.qrPath
        guard link.path == expected || link.path == expected + "/" else { return .failure(.foreignSite) }

        let items = link.queryItems ?? []
        guard let challenge = items.first(where: { $0.name == "c" })?.value, UUID(uuidString: challenge) != nil,
              let nonce = items.first(where: { $0.name == "n" })?.value, isValidNonce(nonce) else {
            return .failure(.missingParameters)
        }
        return .success(QRLoginPayload(challengeId: challenge, nonce: nonce, host: host))
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        guard nonceLengthRange.contains(nonce.count) else { return false }
        return nonce.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
            default: return false
            }
        }
    }

    private static func effectivePort(_ port: Int?, scheme: String) -> Int {
        if let port { return port }
        return scheme == "https" ? 443 : 80
    }
}

/// `POST /api/v1/auth/qr/approve` body.
public struct QRApproveRequest: Codable, Equatable, Sendable {
    public var challengeId: String
    public var nonce: String

    public init(challengeId: String, nonce: String) {
        self.challengeId = challengeId
        self.nonce = nonce
    }
}

/// Meaning of the approve answer.
public enum QRApproveOutcome: Equatable, Sendable {
    /// 200: the website is logged in.
    case approved
    /// 404: unknown or expired challenge (the page shows a new QR).
    case expired
    /// 409: the QR was already used.
    case alreadyUsed
    /// 401: the device token is not valid.
    case unauthorized
    /// Anything else (429, 5xx…).
    case serverError(Int)

    public init(statusCode: Int) {
        switch statusCode {
        case 200, 201, 204: self = .approved
        case 404, 410: self = .expired
        case 409: self = .alreadyUsed
        case 401, 403: self = .unauthorized
        default: self = .serverError(statusCode)
        }
    }
}
