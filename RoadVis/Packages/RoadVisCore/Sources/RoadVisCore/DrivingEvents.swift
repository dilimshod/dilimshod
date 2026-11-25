import Foundation

/// Kinds of driving events recorded for the trip report (driver-coaching for beginners).
public enum DrivingEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Own GPS speed above the posted limit (+ tolerance).
    case speeding
    /// Gap to the lead vehicle below the recommended following distance.
    case tailgating
    /// Time to collision with the lead vehicle below the warning threshold.
    case collisionRisk
    /// Vehicle crossed a lane marking (camera, heuristic).
    case laneDeparture
    /// Moved through an intersection while the camera saw a red light (heuristic).
    case redLightRunning
    /// Did not stop at a STOP sign (camera/OSM, heuristic).
    case stopSignIgnored
    /// Strong deceleration (GPS / motion sensors).
    case harshBraking
    /// Strong acceleration (GPS / motion sensors).
    case harshAcceleration

    /// Default severity used when an event is created without an explicit one.
    public var defaultSeverity: DrivingEventSeverity {
        switch self {
        case .speeding, .tailgating, .laneDeparture, .harshBraking, .harshAcceleration: return .warning
        case .collisionRisk, .redLightRunning, .stopSignIgnored: return .violation
        }
    }

    /// SF Symbol for charts and lists.
    public var symbolName: String {
        switch self {
        case .speeding: return "gauge.with.dots.needle.67percent"
        case .tailgating: return "car.2.fill"
        case .collisionRisk: return "exclamationmark.triangle.fill"
        case .laneDeparture: return "road.lanes"
        case .redLightRunning: return "light.beacon.max.fill"
        case .stopSignIgnored: return "octagon.fill"
        case .harshBraking: return "arrow.down.circle.fill"
        case .harshAcceleration: return "arrow.up.circle.fill"
        }
    }
}

public enum DrivingEventSeverity: Int, Codable, Hashable, Sendable, Comparable, CaseIterable {
    case info = 0, warning = 1, violation = 2

    public static func < (lhs: DrivingEventSeverity, rhs: DrivingEventSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One event of a trip. All camera-based values are estimates.
public struct DrivingEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: DrivingEventKind
    public var severity: DrivingEventSeverity
    public var date: Date
    public var coordinate: GeoPoint?
    /// Own speed at the event, km/h.
    public var speedKmh: Double?
    /// Measured value: km/h over the limit, gap in metres, time to collision in s, deceleration in m/s², offset…
    public var value: Double?
    /// Reference value: speed limit km/h, recommended gap m, threshold…
    public var limit: Double?
    /// How long the condition lasted, seconds (0 for instantaneous events).
    public var duration: TimeInterval
    /// Free text (e.g. road name), not localized.
    public var note: String?

    public init(id: UUID = UUID(), kind: DrivingEventKind, severity: DrivingEventSeverity? = nil, date: Date = Date(),
                coordinate: GeoPoint? = nil, speedKmh: Double? = nil, value: Double? = nil, limit: Double? = nil,
                duration: TimeInterval = 0, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity ?? kind.defaultSeverity
        self.date = date
        self.coordinate = coordinate
        self.speedKmh = speedKmh
        self.value = value
        self.limit = limit
        self.duration = duration
        self.note = note
    }
}

/// Collapses repeated events: a new event of the same kind within `cooldown` seconds extends the previous one
/// (duration, worst value) instead of creating a duplicate. Used by both the camera and the trip recorder.
public struct DrivingEventDebouncer: Sendable {
    public var cooldown: TimeInterval
    private var lastIndexByKind: [DrivingEventKind: Int] = [:]
    public private(set) var events: [DrivingEvent] = []

    public init(cooldown: TimeInterval = 8) {
        self.cooldown = cooldown
    }

    /// Adds or merges the event. Returns true when a NEW event was created (callers announce only new ones).
    @discardableResult
    public mutating func add(_ event: DrivingEvent) -> Bool {
        if let i = lastIndexByKind[event.kind] {
            let previous = events[i]
            let end = previous.date.addingTimeInterval(previous.duration)
            if event.date.timeIntervalSince(end) <= cooldown {
                var merged = previous
                merged.duration = max(previous.duration, event.date.timeIntervalSince(previous.date) + event.duration)
                merged.severity = max(previous.severity, event.severity)
                if let v = event.value {
                    // Keep the worst value: larger for "over" quantities, smaller for gaps / TTC.
                    let smallerIsWorse: Set<DrivingEventKind> = [.tailgating, .collisionRisk]
                    if let old = merged.value {
                        merged.value = smallerIsWorse.contains(event.kind) ? min(old, v) : max(old, v)
                    } else {
                        merged.value = v
                    }
                }
                events[i] = merged
                return false
            }
        }
        events.append(event)
        lastIndexByKind[event.kind] = events.count - 1
        return true
    }

    public mutating func reset() {
        events.removeAll()
        lastIndexByKind.removeAll()
    }
}
