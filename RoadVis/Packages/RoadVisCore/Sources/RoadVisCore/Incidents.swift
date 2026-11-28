import Foundation

/// Kind of a user-reported road event (stored locally on the phone; there is no shared incident feed).
///
/// New cases are only ever appended, so files written by older versions (which contain a subset of the raw values)
/// keep decoding.
public enum RoadIncidentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case accident, roadWork, jam, police, pothole, hazard, closure
    /// The user's own mark of a (speed) camera. Cameras are fixed, so the mark does not expire.
    case speedCamera

    /// Russian display name.
    public var displayName: String {
        switch self {
        case .accident: return "ДТП"
        case .roadWork: return "Дорожные работы"
        case .jam: return "Пробка"
        case .police: return "Полиция / пост ДПС"
        case .pothole: return "Яма"
        case .hazard: return "Опасность"
        case .closure: return "Перекрытие"
        case .speedCamera: return "Камера"
        }
    }

    /// SF Symbol (all available since iOS 16 or earlier).
    public var symbolName: String {
        switch self {
        case .accident: return "exclamationmark.octagon.fill"
        case .roadWork: return "cone.fill"
        case .jam: return "car.2.fill"
        case .police: return "shield.fill"
        case .pothole: return "exclamationmark.circle.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .closure: return "nosign"
        case .speedCamera: return "camera.fill"
        }
    }

    /// True for marks of fixed objects (cameras) that are kept until the user deletes them; other reports expire after
    /// the incident lifetime set in Settings.
    public var isPermanent: Bool {
        self == .speedCamera
    }

    /// Distance ahead on the route at which the navigator announces the mark, metres (cameras like OSM cameras).
    public var alertDistance: Double {
        self == .speedCamera ? RouteFeatureKind.speedCamera.alertDistance : 700
    }
}

/// A road event reported by the user.
public struct RoadIncident: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: RoadIncidentKind
    public var coordinate: GeoPoint
    public var date: Date
    public var note: String?

    public init(id: UUID = UUID(), kind: RoadIncidentKind, coordinate: GeoPoint, date: Date = Date(), note: String? = nil) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.date = date
        self.note = note
    }
}

/// An incident projected onto the active route.
public struct IncidentOnRoute: Identifiable, Hashable, Sendable {
    public var incident: RoadIncident
    /// Distance from the route start to the incident's projection, metres.
    public var distanceAlongRoute: Double
    /// Lateral distance between the incident and the route, metres.
    public var offsetFromRoute: Double

    public var id: UUID { incident.id }

    public init(incident: RoadIncident, distanceAlongRoute: Double, offsetFromRoute: Double = 0) {
        self.incident = incident
        self.distanceAlongRoute = distanceAlongRoute
        self.offsetFromRoute = offsetFromRoute
    }
}

public enum IncidentFilter {
    /// Incidents younger than `lifetime` seconds at `now`, plus permanent marks (cameras, `RoadIncidentKind.isPermanent`)
    /// of any age, newest first. Incidents dated slightly in the future (clock changes) are kept; `lifetime <= 0` (or
    /// not finite) expires every non-permanent incident.
    public static func active(_ incidents: [RoadIncident], now: Date, lifetime: TimeInterval) -> [RoadIncident] {
        let validLifetime = lifetime > 0 && lifetime.isFinite
        return incidents
            .filter { $0.kind.isPermanent || (validLifetime && now.timeIntervalSince($0.date) < lifetime) }
            .sorted { $0.date > $1.date }
    }

    /// Incidents within `maxOffset` metres of the route, sorted by distance along the route.
    /// - Parameter cumulative: optional `Geo.cumulativeDistances(route)` (ignored when its count does not match).
    public static func along(route: [GeoPoint], cumulative: [Double]?, incidents: [RoadIncident],
                             maxOffset: Double = 50) -> [IncidentOnRoute] {
        guard !route.isEmpty else { return [] }
        let cum = (cumulative?.count == route.count) ? cumulative! : Geo.cumulativeDistances(route)
        return incidents
            .compactMap { incident -> IncidentOnRoute? in
                guard incident.coordinate.isValid,
                      let projection = Geo.project(incident.coordinate, onto: route, cumulative: cum),
                      projection.distanceFromLine <= maxOffset else { return nil }
                return IncidentOnRoute(incident: incident, distanceAlongRoute: projection.distanceAlong,
                                       offsetFromRoute: projection.distanceFromLine)
            }
            .sorted { lhs, rhs in
                if lhs.distanceAlongRoute != rhs.distanceAlongRoute { return lhs.distanceAlongRoute < rhs.distanceAlongRoute }
                return lhs.incident.date > rhs.incident.date
            }
    }
}
