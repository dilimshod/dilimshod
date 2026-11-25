import Foundation

/// Attributes of the road the vehicle is currently on (from OSM), for the user's travel direction.
public struct RoadSegmentInfo: Hashable, Sendable {
    public var wayID: Int64
    /// Road name: the Russian name (`name:ru`) when mapped, else `name`.
    public var name: String?
    /// Road number (`ref`), e.g. "4Р12".
    public var ref: String?
    /// OSM road class (`highway=*`).
    public var highway: String
    public var laneInfo: LaneInfo
    public var speedLimit: SpeedLimit?
    /// OSM `surface` (asphalt, concrete, unpaved …).
    public var surface: String?
    /// Street lighting (`lit`), nil when unknown.
    public var lit: Bool?
    /// True when travelling along the way's drawing direction.
    public var travelingForward: Bool
    /// Distance from the GPS position to the way, metres.
    public var distanceToRoad: Double
    public var tags: [String: String]

    public init(wayID: Int64, name: String?, ref: String?, highway: String, laneInfo: LaneInfo,
                speedLimit: SpeedLimit?, surface: String?, lit: Bool?, travelingForward: Bool,
                distanceToRoad: Double, tags: [String: String]) {
        self.wayID = wayID
        self.name = name
        self.ref = ref
        self.highway = highway
        self.laneInfo = laneInfo
        self.speedLimit = speedLimit
        self.surface = surface
        self.lit = lit
        self.travelingForward = travelingForward
        self.distanceToRoad = distanceToRoad
        self.tags = tags
    }

    /// `name ?? ref ?? highwayDisplayName(highway)`.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let ref, !ref.isEmpty { return ref }
        return OSMRoadParser.highwayDisplayName(highway)
    }

    /// Russian road class name ("Главная дорога", "Жилая улица" …).
    public var roadClassName: String { OSMRoadParser.highwayDisplayName(highway) }

    /// Russian surface description, nil when not mapped.
    public var surfaceDisplayName: String? {
        guard let surface = surface?.lowercased(), !surface.isEmpty else { return nil }
        switch surface {
        case "asphalt": return "Асфальт"
        case "concrete", "concrete:plates", "concrete:lanes": return "Бетон"
        case "paved": return "Твёрдое покрытие"
        case "paving_stones", "sett", "cobblestone", "unhewn_cobblestone": return "Брусчатка"
        case "compacted", "fine_gravel", "gravel", "pebblestone": return "Гравий"
        case "unpaved", "dirt", "earth", "ground", "mud", "sand", "grass": return "Грунт"
        default: return surface
        }
    }
}

/// Map-matching of a GPS fix onto nearby OSM ways.
public enum RoadMatcher {
    /// Extra cost (metres) per degree between the travel heading and the road direction.
    static let headingWeight = 0.3
    /// Extra cost (metres) for travelling against a one-way road.
    static let wrongWayPenalty = 60.0
    /// Extra cost (metres) per road-class rank step (prefers major roads on near-ties).
    static let classWeight = 0.4

    /// Picks the way best matching the position and travel heading.
    ///
    /// Only ways with geometry and a drivable `highway=*` are considered. Score = distance to the way
    /// + heading penalty (angle between the heading and the nearest segment, either direction for two-way roads)
    /// + a large penalty for driving against a one-way road + a small road-class penalty. `heading == nil` (or
    /// invalid) → nearest way; one-way roads are then assumed to be travelled in their legal direction.
    /// - Returns: nil when no way is within `maxDistance` metres.
    public static func bestMatch(elements: [OSMElement], position: GeoPoint, heading: Double?,
                                 maxDistance: Double = 35) -> RoadSegmentInfo? {
        guard position.isValid else { return nil }
        let validHeading = heading.flatMap { $0.isFinite && $0 >= 0 ? Geo.normalizeDegrees($0) : nil }
        let excluded = Set(OverpassQuery.excludedHighwayValues)

        var best: (score: Double, element: OSMElement, distance: Double, forward: Bool)?
        for element in elements where element.type == .way {
            guard let highway = element.tags["highway"]?.lowercased(), !excluded.contains(highway),
                  element.tags["area"]?.lowercased() != "yes",
                  let geometry = element.geometry, geometry.count >= 2,
                  let projection = Geo.project(position, onto: geometry) else { continue }
            let distance = projection.distanceFromLine
            guard distance <= maxDistance else { continue }

            let direction = OSMRoadParser.onewayDirection(tags: element.tags)
            var score = distance
            let forward: Bool
            if let h = validHeading {
                let diffForward = Geo.angleDifference(h, projection.segmentBearing)
                let diffBackward = 180 - diffForward
                forward = diffForward <= 90
                switch direction {
                case 1:
                    score += headingWeight * diffForward
                    if !forward { score += wrongWayPenalty }
                case -1:
                    score += headingWeight * diffBackward
                    if forward { score += wrongWayPenalty }
                default:
                    score += headingWeight * min(diffForward, diffBackward)
                }
            } else {
                forward = direction != -1
            }
            score += classWeight * Double(OSMRoadParser.roadClassRank(highway))

            if best == nil || score < best!.score {
                best = (score, element, distance, forward)
            }
        }

        guard let match = best else { return nil }
        let tags = match.element.tags
        let name = nonEmpty(tags["name:ru"]) ?? nonEmpty(tags["name"])
        return RoadSegmentInfo(wayID: match.element.id,
                               name: name,
                               ref: nonEmpty(tags["ref"]),
                               highway: tags["highway"] ?? "road",
                               laneInfo: OSMRoadParser.laneInfo(tags: tags, travelingForward: match.forward),
                               speedLimit: MaxSpeedParser.limit(tags: tags, travelingForward: match.forward),
                               surface: nonEmpty(tags["surface"]),
                               lit: litValue(tags["lit"]),
                               travelingForward: match.forward,
                               distanceToRoad: match.distance,
                               tags: tags)
    }

    /// `lit=*` → Bool (yes / 24/7 / automatic / limited / interval → true; no / disused → false).
    static func litValue(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "yes", "24/7", "automatic", "limited", "interval", "sunset-sunrise", "dusk-dawn": return true
        case "no", "disused": return false
        default: return nil
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
