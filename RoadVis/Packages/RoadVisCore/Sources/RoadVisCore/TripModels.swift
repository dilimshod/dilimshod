import Foundation

// Trip recording, statistics and scoring for the beginner-driver trip report.
// Foundation only (built on Linux). All camera-based values in a trip are estimates.

/// Start (A) or end (B) of a trip.
public struct TripEndpoint: Codable, Hashable, Sendable {
    /// Human-readable name (destination name, reverse-geocoded address); nil while unknown.
    public var name: String?
    public var coordinate: GeoPoint?

    public init(name: String? = nil, coordinate: GeoPoint? = nil) {
        self.name = name
        self.coordinate = coordinate
    }
}

/// One sample of the track (≈ 1 per second while recording).
public struct TripPoint: Codable, Hashable, Sendable {
    public var date: Date
    public var coordinate: GeoPoint
    /// Own GPS speed, km/h (nil when the fix had no valid speed).
    public var speedKmh: Double?
    /// Posted speed limit at that moment (route edge or OpenStreetMap road), km/h.
    public var speedLimitKmh: Int?
    /// ≈ Distance to the lead vehicle (camera estimate), metres.
    public var leadDistanceMeters: Double?
    /// Recommended following distance for the speed at that moment, metres.
    public var recommendedGapMeters: Double?
    /// GPS horizontal accuracy, metres.
    public var horizontalAccuracy: Double?

    public init(date: Date, coordinate: GeoPoint, speedKmh: Double? = nil, speedLimitKmh: Int? = nil,
                leadDistanceMeters: Double? = nil, recommendedGapMeters: Double? = nil,
                horizontalAccuracy: Double? = nil) {
        self.date = date
        self.coordinate = coordinate
        self.speedKmh = speedKmh
        self.speedLimitKmh = speedLimitKmh
        self.leadDistanceMeters = leadDistanceMeters
        self.recommendedGapMeters = recommendedGapMeters
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Thresholds in force while the trip was recorded (stored with the trip so its report stays reproducible).
public struct TripThresholds: Codable, Hashable, Sendable {
    /// km/h above the limit that still counts as "within the limit".
    public var speedToleranceKmh: Double
    /// Minimum time above limit + tolerance before a speeding event is recorded, seconds (≥ 5).
    public var speedingMinSeconds: Double
    /// Deceleration that counts as harsh braking, m/s² (negative, e.g. −3.5).
    public var harshBrakingMps2: Double
    /// Acceleration that counts as harsh acceleration, m/s² (positive, e.g. 3.0).
    public var harshAccelerationMps2: Double

    public init(speedToleranceKmh: Double = 5, speedingMinSeconds: Double = 5,
                harshBrakingMps2: Double = -3.5, harshAccelerationMps2: Double = 3.0) {
        self.speedToleranceKmh = max(0, speedToleranceKmh)
        self.speedingMinSeconds = max(5, speedingMinSeconds)
        self.harshBrakingMps2 = -abs(harshBrakingMps2)
        self.harshAccelerationMps2 = abs(harshAccelerationMps2)
    }

    public static let `default` = TripThresholds()
}

/// A recorded trip: track, A and B, the planned route and all driving events.
public struct Trip: Identifiable, Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var startedAt: Date
    /// nil while recording (or when the app was killed during recording).
    public var endedAt: Date?
    public var origin: TripEndpoint
    public var destination: TripEndpoint?
    /// Planned route polyline (simplified), empty for trips without navigation.
    public var routePolyline: [GeoPoint]
    /// Routing engine badge of the route ("Valhalla", "Apple", …).
    public var routeSource: String?
    public var points: [TripPoint]
    public var events: [DrivingEvent]
    public var thresholds: TripThresholds
    /// True when navigation reported arrival at B.
    public var arrived: Bool
    /// True when started automatically with «Поехали».
    public var startedWithNavigation: Bool
    /// File names of the camera research CSV recorded during the trip (Documents/Experiments/).
    public var cameraCSVFiles: [String]

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, origin: TripEndpoint = TripEndpoint(),
                destination: TripEndpoint? = nil, routePolyline: [GeoPoint] = [], routeSource: String? = nil,
                points: [TripPoint] = [], events: [DrivingEvent] = [], thresholds: TripThresholds = .default,
                arrived: Bool = false, startedWithNavigation: Bool = false, cameraCSVFiles: [String] = []) {
        self.id = id
        self.formatVersion = Trip.currentFormatVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.origin = origin
        self.destination = destination
        self.routePolyline = routePolyline
        self.routeSource = routeSource
        self.points = points
        self.events = events
        self.thresholds = thresholds
        self.arrived = arrived
        self.startedWithNavigation = startedWithNavigation
        self.cameraCSVFiles = cameraCSVFiles
    }

    /// End of the trip: `endedAt`, else the last point, else the start.
    public var effectiveEnd: Date { endedAt ?? points.last?.date ?? startedAt }
    public var duration: TimeInterval { max(0, effectiveEnd.timeIntervalSince(startedAt)) }
    /// Events sorted by time.
    public var sortedEvents: [DrivingEvent] { events.sorted { $0.date < $1.date } }
}

/// Speed bands used for the "share of time per speed band" chart.
public enum TripSpeedBand: String, Codable, Hashable, Sendable, CaseIterable {
    case standing, slow, urban, fast, highway

    /// Lower bound, km/h (inclusive).
    public var lowerBoundKmh: Double {
        switch self {
        case .standing: return 0
        case .slow: return 5
        case .urban: return 30
        case .fast: return 60
        case .highway: return 90
        }
    }

    /// "0–5 км/ч", "90+ км/ч".
    public var title: String {
        switch self {
        case .standing: return "0–5 км/ч"
        case .slow: return "5–30 км/ч"
        case .urban: return "30–60 км/ч"
        case .fast: return "60–90 км/ч"
        case .highway: return "90+ км/ч"
        }
    }

    public static func band(for kmh: Double) -> TripSpeedBand {
        var result = TripSpeedBand.standing
        for band in allCases where kmh >= band.lowerBoundKmh { result = band }
        return result
    }
}

/// Aggregated numbers of a trip.
public struct TripStats: Hashable, Sendable {
    /// Track length (sum of distances between accepted points), metres.
    public var distanceMeters: Double
    public var duration: TimeInterval
    /// Time with speed ≥ 5 km/h, seconds.
    public var movingDuration: TimeInterval
    /// distance / duration, km/h.
    public var averageSpeedKmh: Double
    /// distance / moving time, km/h.
    public var averageMovingSpeedKmh: Double
    public var maxSpeedKmh: Double
    /// Time above limit + tolerance, seconds.
    public var timeOverLimit: TimeInterval
    /// Share (0…1) of the time with a known speed limit.
    public var speedLimitCoverage: Double
    public var eventCounts: [DrivingEventKind: Int]
    public var totalEvents: Int
    /// Events per 100 km (distance floored at 1 km so a short trip does not explode the number).
    public var eventsPer100km: Double
    /// Seconds spent in each speed band.
    public var timeBySpeedBand: [TripSpeedBand: TimeInterval]
    /// ≈ Mean camera gap to the lead vehicle while one was measured, metres.
    public var averageLeadDistanceMeters: Double?
    /// Share (0…1) of the time with a measured lead gap below the recommended gap.
    public var shareBelowRecommendedGap: Double?

    /// Gaps between consecutive points longer than this are not integrated (GPS loss, app suspended).
    public static let maxSampleGap: TimeInterval = 10
    /// Fixes worse than this are ignored for distance.
    public static let maxAccuracyForDistance: Double = 50
    /// Below this speed the car counts as standing.
    public static let movingSpeedKmh: Double = 5

    public static func compute(_ trip: Trip) -> TripStats {
        let points = trip.points.sorted { $0.date < $1.date }
        let tolerance = trip.thresholds.speedToleranceKmh
        var distance = 0.0
        var moving = 0.0
        var overLimit = 0.0
        var withLimit = 0.0
        var integrated = 0.0
        var maxSpeed = 0.0
        var bands: [TripSpeedBand: TimeInterval] = [:]
        var leadSum = 0.0
        var leadTime = 0.0
        var belowGapTime = 0.0
        var lastAccepted: TripPoint?

        for point in points {
            if let speed = point.speedKmh, speed.isFinite { maxSpeed = max(maxSpeed, speed) }
            if (point.horizontalAccuracy ?? 0) <= maxAccuracyForDistance {
                if let previous = lastAccepted {
                    let dt = point.date.timeIntervalSince(previous.date)
                    let step = Geo.distance(previous.coordinate, point.coordinate)
                    // Plausibility: ignore jumps faster than 250 km/h (GPS glitches).
                    if dt > 0, step / dt < 70 { distance += step }
                }
                lastAccepted = point
            }
        }
        if points.count >= 2 {
            for i in 1..<points.count {
                let a = points[i - 1]
                let b = points[i]
                let dt = b.date.timeIntervalSince(a.date)
                guard dt > 0, dt <= maxSampleGap else { continue }
                integrated += dt
                let speed = a.speedKmh ?? 0
                if speed >= movingSpeedKmh { moving += dt }
                bands[TripSpeedBand.band(for: speed), default: 0] += dt
                if let limit = a.speedLimitKmh {
                    withLimit += dt
                    if speed > Double(limit) + tolerance { overLimit += dt }
                }
                if let lead = a.leadDistanceMeters {
                    leadSum += lead * dt
                    leadTime += dt
                    if let recommended = a.recommendedGapMeters, lead < recommended { belowGapTime += dt }
                }
            }
        }
        let duration = trip.duration
        var counts: [DrivingEventKind: Int] = [:]
        for event in trip.events { counts[event.kind, default: 0] += 1 }
        let km = distance / 1000
        return TripStats(
            distanceMeters: distance,
            duration: duration,
            movingDuration: moving,
            averageSpeedKmh: duration > 0 ? distance / duration * 3.6 : 0,
            averageMovingSpeedKmh: moving > 0 ? distance / moving * 3.6 : 0,
            maxSpeedKmh: maxSpeed,
            timeOverLimit: overLimit,
            speedLimitCoverage: integrated > 0 ? withLimit / integrated : 0,
            eventCounts: counts,
            totalEvents: trip.events.count,
            eventsPer100km: Double(trip.events.count) / max(km, 1) * 100,
            timeBySpeedBand: bands,
            averageLeadDistanceMeters: leadTime > 0 ? leadSum / leadTime : nil,
            shareBelowRecommendedGap: leadTime > 0 ? belowGapTime / leadTime : nil
        )
    }
}

/// Driving score 0…100.
///
/// Formula (documented in the report):
///   penalty(event) = weight(kind) × severityFactor × durationFactor
///     severityFactor: info 0.5, warning 1.0, violation 1.5
///     durationFactor: 1 + min(duration / 30 s, 2)  (a 60 s speeding episode weighs 3× a short one)
///   penaltyPerKm = Σ penalty / max(distance km, 1)
///   score = clamp(100 − 10 × penaltyPerKm, 0, 100), rounded
/// Weights: red light 8, STOP sign 5, collision risk 5, speeding 3, tailgating 2, harsh braking 2,
/// harsh acceleration 1.5, lane departure 1.5.
/// Example: 10 km with two harsh brakings → 4 points / 10 km = 0.4 per km → score 96.
public enum TripScoring {
    public static let scale: Double = 10
    public static let minimumDistanceKm: Double = 1

    public static func weight(_ kind: DrivingEventKind) -> Double {
        switch kind {
        case .redLightRunning: return 8
        case .stopSignIgnored: return 5
        case .collisionRisk: return 5
        case .speeding: return 3
        case .tailgating: return 2
        case .harshBraking: return 2
        case .harshAcceleration: return 1.5
        case .laneDeparture: return 1.5
        }
    }

    public static func severityFactor(_ severity: DrivingEventSeverity) -> Double {
        switch severity {
        case .info: return 0.5
        case .warning: return 1
        case .violation: return 1.5
        }
    }

    public static func penalty(for event: DrivingEvent) -> Double {
        let durationFactor = 1 + min(max(0, event.duration) / 30, 2)
        return weight(event.kind) * severityFactor(event.severity) * durationFactor
    }

    public struct Result: Hashable, Sendable {
        /// 0…100.
        public var score: Int
        public var totalPenalty: Double
        public var penaltyPerKm: Double
        /// Penalty points per event kind.
        public var penaltyByKind: [DrivingEventKind: Double]
    }

    public static func score(events: [DrivingEvent], distanceMeters: Double) -> Result {
        var byKind: [DrivingEventKind: Double] = [:]
        var total = 0.0
        for event in events {
            let p = penalty(for: event)
            byKind[event.kind, default: 0] += p
            total += p
        }
        let perKm = total / max(distanceMeters / 1000, minimumDistanceKm)
        let raw = 100 - scale * perKm
        let score = Int(min(100, max(0, raw)).rounded())
        return Result(score: score, totalPenalty: total, penaltyPerKm: perKm, penaltyByKind: byKind)
    }

    public static func score(for trip: Trip) -> Result {
        score(events: trip.events, distanceMeters: TripStats.compute(trip).distanceMeters)
    }

    /// Russian grade for the score.
    public static func grade(_ score: Int) -> String {
        switch score {
        case 90...: return "Отлично"
        case 75..<90: return "Хорошо"
        case 55..<75: return "Есть над чем поработать"
        default: return "Опасный стиль"
        }
    }

    /// One-line description of the formula (Russian, for the report).
    public static let formulaDescription =
        "Балл = 100 − 10 × (штрафные очки на 1 км, не меньше 1 км). Очки события = вес вида × тяжесть (0,5 / 1 / 1,5) × (1 + длительность/30 с, макс. 3). Веса: красный свет 8, STOP 5, риск столкновения 5, превышение 3, дистанция 2, резкое торможение 2, резкий разгон 1,5, выезд из полосы 1,5."
}

extension DrivingEventKind {
    /// Russian name used in the trip report.
    public var tripReportTitle: String {
        switch self {
        case .speeding: return "Превышение скорости"
        case .tailgating: return "Малая дистанция"
        case .collisionRisk: return "Риск столкновения"
        case .laneDeparture: return "Выезд из полосы"
        case .redLightRunning: return "Проезд на красный"
        case .stopSignIgnored: return "Без остановки у STOP"
        case .harshBraking: return "Резкое торможение"
        case .harshAcceleration: return "Резкий разгон"
        }
    }

    /// Whether the event comes from the camera (an estimate) rather than GPS / sensors.
    public var isCameraBased: Bool {
        switch self {
        case .tailgating, .collisionRisk, .laneDeparture, .redLightRunning, .stopSignIgnored: return true
        case .speeding, .harshBraking, .harshAcceleration: return false
        }
    }

    /// Unit of `DrivingEvent.value` for this kind (Russian).
    public var tripValueUnit: String {
        switch self {
        case .speeding: return "км/ч сверх"
        case .tailgating: return "м"
        case .collisionRisk: return "с до столкн."
        case .laneDeparture: return ""
        case .redLightRunning, .stopSignIgnored: return "км/ч"
        case .harshBraking, .harshAcceleration: return "м/с²"
        }
    }
}

/// CSV export of a trip (UTF-8, ',' separator, '.' decimals, ISO-8601 UTC timestamps).
public enum TripExport {
    public static func eventsCSV(_ trip: Trip) -> String {
        var lines = ["timestamp,kind,title,severity,latitude,longitude,speed_kmh,value,limit,duration_s,camera_estimate,note"]
        for event in trip.sortedEvents {
            let fields: [String] = [
                iso(event.date),
                event.kind.rawValue,
                escape(event.kind.tripReportTitle),
                String(event.severity.rawValue),
                number(event.coordinate?.latitude, digits: 6),
                number(event.coordinate?.longitude, digits: 6),
                number(event.speedKmh, digits: 1),
                number(event.value, digits: 2),
                number(event.limit, digits: 2),
                number(event.duration, digits: 1),
                event.kind.isCameraBased ? "1" : "0",
                escape(event.note ?? ""),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func pointsCSV(_ trip: Trip) -> String {
        var lines = ["timestamp,latitude,longitude,speed_kmh,speed_limit_kmh,lead_distance_m_estimate,recommended_gap_m,accuracy_m"]
        for p in trip.points {
            let fields: [String] = [
                iso(p.date),
                number(p.coordinate.latitude, digits: 6),
                number(p.coordinate.longitude, digits: 6),
                number(p.speedKmh, digits: 1),
                p.speedLimitKmh.map(String.init) ?? "",
                number(p.leadDistanceMeters, digits: 1),
                number(p.recommendedGapMeters, digits: 1),
                number(p.horizontalAccuracy, digits: 1),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "trip_2026-11-25_14-35" (local time).
    public static func baseFileName(_ trip: Trip, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: trip.startedAt)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        return "trip_\(c.year ?? 0)-\(two(c.month))-\(two(c.day))_\(two(c.hour))-\(two(c.minute))"
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func escape(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }
}
