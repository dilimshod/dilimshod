import Foundation

// Localized names for RoadVisCore enums / codes shown in the UI. RoadVisCore keeps its Russian `displayName`s
// (used by tests and logs); the app shows these `localizedName`s in the current app language instead.

extension RoadSurfaceCondition {
    var localizedName: String { L("surface.\(rawValue)") }
}

extension DistanceStatus {
    var localizedName: String { L("distanceStatus.\(rawValue)") }
}

extension RoadIncidentKind {
    var localizedName: String { L("incident.kind.\(rawValue)") }
}

extension RouteFeatureKind {
    var localizedName: String { L("feature.\(rawValue)") }
}

extension CongestionLevel {
    var localizedName: String { L("congestion.\(rawValue)") }
}

extension TrafficAssessment {
    /// Localized `summary`: "Moderate traffic, delay ≈ 7 min (estimate)".
    var localizedSummary: String {
        let delay = delaySeconds
        if level == .free || delay < 60 { return L("traffic.summary.short", level.localizedName) }
        return L("traffic.summary.delay", level.localizedName, RVFormat.appDuration(delay))
    }
}

extension VehicleKind {
    var localizedName: String { L("vehicle.\(rawValue)") }
}

extension TrafficLightColor {
    var localizedName: String { L("light.\(rawValue)") }
}

extension TripSpeedBand {
    /// "0–5 km/soat" …
    var localizedTitle: String {
        let unit = RVFormat.appKmh
        switch self {
        case .standing: return "0–5 \(unit)"
        case .slow: return "5–30 \(unit)"
        case .urban: return "30–60 \(unit)"
        case .fast: return "60–90 \(unit)"
        case .highway: return "90+ \(unit)"
        }
    }
}

extension DrivingEventKind {
    /// Localized `tripReportTitle`.
    var localizedTitle: String { L("event.\(rawValue)") }

    /// Localized `tripValueUnit`.
    var localizedValueUnit: String {
        switch self {
        case .laneDeparture: return ""
        default: return L("event.unit.\(rawValue)")
        }
    }
}

extension TripScoring {
    /// Localized `grade(_:)`.
    static func localizedGrade(_ score: Int) -> String {
        switch score {
        case 90...: return L("score.grade.excellent")
        case 75..<90: return L("score.grade.good")
        case 55..<75: return L("score.grade.work")
        default: return L("score.grade.dangerous")
        }
    }

    /// Localized `formulaDescription`.
    static var localizedFormulaDescription: String { L("score.formula") }
}

extension SignalWaitEstimate {
    /// Localized `sourceDescription`.
    var localizedSourceDescription: String {
        switch source {
        case .model: return L("signal.source.model")
        case .learned: return L("signal.source.learned", observationCount)
        case .blended: return L("signal.source.blended", observationCount)
        }
    }
}

enum CoreText {
    /// Localized WMO weather description (`OpenMeteo.conditionDescription(code:)`).
    static func weatherCondition(code: Int?) -> String {
        guard let code else { return L("common.noDataCap") }
        let key = "wmo.\(code)"
        let value = L(key)
        return value == key ? L("wmo.other", code) : value
    }

    /// Localized OSM `highway=*` class name (`OSMRoadParser.highwayDisplayName`).
    static func highwayName(_ highway: String) -> String {
        let h = highway.lowercased()
        let normalized: String
        switch h {
        case "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link": normalized = "link"
        case "bus_guideway": normalized = "busway"
        default: normalized = h
        }
        let key = "highway.\(normalized)"
        let value = L(key)
        return value == key ? L("highway.road") : value
    }

    /// Localized Valhalla `road_class` (`RouteEdgeAttributes.roadClassDisplayName`).
    static func valhallaRoadClass(_ roadClass: String?) -> String? {
        guard let roadClass else { return nil }
        let key = "roadClass.\(roadClass)"
        let value = L(key)
        return value == key ? roadClass : value
    }

    /// Localized Valhalla `surface` (`RouteEdgeAttributes.surfaceDisplayName`).
    static func valhallaSurface(_ surface: String?) -> String? {
        guard let surface else { return nil }
        let key = "vsurface.\(surface)"
        let value = L(key)
        return value == key ? surface : value
    }

    /// Localized OSM `surface=*` (`RoadSegment.surfaceDisplayName` / `MatchedRoad.surfaceDisplayName`).
    static func osmSurface(_ surface: String?) -> String? {
        guard let surface = surface?.lowercased(), !surface.isEmpty else { return nil }
        switch surface {
        case "asphalt": return L("osmSurface.asphalt")
        case "concrete", "concrete:plates", "concrete:lanes": return L("osmSurface.concrete")
        case "paved": return L("osmSurface.paved")
        case "paving_stones", "sett", "cobblestone", "unhewn_cobblestone": return L("osmSurface.cobblestone")
        case "compacted", "fine_gravel", "gravel", "pebblestone": return L("osmSurface.gravel")
        case "unpaved", "dirt", "earth", "ground", "mud", "sand", "grass": return L("osmSurface.dirt")
        default: return surface
        }
    }
}

extension RoadSegmentInfo {
    /// Localized `displayName`: name ?? ref ?? localized road class.
    var localizedDisplayName: String {
        if let name, !name.isEmpty { return name }
        if let ref, !ref.isEmpty { return ref }
        return CoreText.highwayName(highway)
    }

    /// Localized `roadClassName`.
    var localizedRoadClassName: String { CoreText.highwayName(highway) }

    /// Localized `surfaceDisplayName`.
    var localizedSurfaceName: String? { CoreText.osmSurface(surface) }
}

extension WeatherSnapshot {
    /// Localized `conditionDescription`.
    var localizedCondition: String { CoreText.weatherCondition(code: weatherCode) }
}

extension FollowingDistanceNorms.Status {
    /// Localized badge text ("Norm", "Recommendation", "App setting").
    var localizedName: String {
        switch self {
        case .norm: return L("norms.status.norm")
        case .recommendation: return L("norms.status.recommendation")
        case .appSetting: return L("norms.status.appSetting")
        }
    }
}

extension FollowingDistanceNorms.Item {
    /// Localized title / text / source (keys `norms.item.<id>.*`); falls back to the Russian core text.
    var localizedTitle: String { CoreText.lookup("norms.item.\(id).title") ?? title }
    var localizedText: String { CoreText.lookup("norms.item.\(id).text") ?? text }
    var localizedSource: String { CoreText.lookup("norms.item.\(id).source") ?? source }
}

extension FollowingDistanceNorms {
    static var localizedRulesDocument: String { L("norms.rulesDocument") }
    static var localizedDisclaimer: String { L("norms.disclaimer") }
}

extension CoreText {
    /// The localized string for `key`, or nil when no table has it.
    static func lookup(_ key: String) -> String? {
        let value = L(key)
        return value == key ? nil : value
    }
}
