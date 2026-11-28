import Foundation

/// Kind of a road feature along the route (from OSM).
public enum RouteFeatureKind: String, Codable, Hashable, Sendable, CaseIterable {
    case trafficSignals, pedestrianCrossing, speedCamera, trafficCalming, railwayCrossing,
         school, kindergarten, construction, stopSign, giveWay, fuel, parking

    /// Russian display name.
    public var displayName: String {
        switch self {
        case .trafficSignals: return "Светофор"
        case .pedestrianCrossing: return "Пешеходный переход"
        case .speedCamera: return "Камера контроля скорости"
        case .trafficCalming: return "Искусственная неровность"
        case .railwayCrossing: return "Железнодорожный переезд"
        case .school: return "Школа"
        case .kindergarten: return "Детский сад"
        case .construction: return "Дорожные работы"
        case .stopSign: return "Знак STOP"
        case .giveWay: return "Уступите дорогу"
        case .fuel: return "АЗС"
        case .parking: return "Парковка"
        }
    }

    /// SF Symbol (all available in SF Symbols 4+, i.e. iOS 16+).
    public var symbolName: String {
        switch self {
        case .trafficSignals: return "light.beacon.max"
        case .pedestrianCrossing: return "figure.walk"
        case .speedCamera: return "camera.fill"
        case .trafficCalming: return "exclamationmark.triangle"
        case .railwayCrossing: return "tram.fill"
        case .school: return "graduationcap.fill"
        case .kindergarten: return "figure.and.child.holdinghands"
        case .construction: return "cone.fill"
        case .stopSign: return "octagon.fill"
        case .giveWay: return "arrowtriangle.down"
        case .fuel: return "fuelpump.fill"
        case .parking: return "parkingsign"
        }
    }

    /// Distance (metres) before the feature at which the driver should be warned.
    public var alertDistance: Double {
        switch self {
        case .trafficSignals: return 300
        case .pedestrianCrossing: return 150
        case .speedCamera: return 500
        case .trafficCalming: return 150
        case .railwayCrossing: return 400
        case .school, .kindergarten: return 300
        case .construction: return 500
        case .stopSign: return 200
        case .giveWay: return 150
        case .fuel: return 500
        case .parking: return 300
        }
    }

    /// Points of interest (fuel, parking) — informational, never announced as hazards.
    public var isPointOfInterest: Bool {
        self == .fuel || self == .parking
    }

    /// Features of the same kind closer than this along the route are merged into one (metres).
    public var mergeRadius: Double {
        switch self {
        case .trafficSignals: return 60   // all signal heads of one intersection
        case .pedestrianCrossing: return 25
        case .fuel: return 60
        case .parking: return 80
        default: return 30
        }
    }

    /// Maximum lateral distance from the route at which the feature is still relevant, given the default.
    public func maxOffset(default value: Double) -> Double {
        switch self {
        case .school, .kindergarten: return max(value, 150)
        case .fuel: return max(value, 100)
        case .parking: return max(value, 60)
        default: return value
        }
    }
}

/// A road feature projected onto the active route.
public struct RouteFeature: Identifiable, Hashable, Sendable {
    /// OSM key of the representative element, e.g. `"node/123"` (for a merged cluster: the element with the
    /// smallest OSM id, so the identity stays stable between queries).
    public let id: String
    public let kind: RouteFeatureKind
    public let coordinate: GeoPoint
    /// Distance from the route start to the projection of the feature, metres.
    public let distanceAlongRoute: Double
    /// Lateral distance between the feature and the route, metres.
    public let offsetFromRoute: Double
    public let name: String?
    public let tags: [String: String]

    public init(id: String, kind: RouteFeatureKind, coordinate: GeoPoint, distanceAlongRoute: Double,
                offsetFromRoute: Double, name: String?, tags: [String: String]) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.distanceAlongRoute = distanceAlongRoute
        self.offsetFromRoute = offsetFromRoute
        self.name = name
        self.tags = tags
    }
}

/// A signalised intersection (cluster of `highway=traffic_signals` nodes).
public struct SignalLocation: Hashable, Codable, Sendable {
    /// Stable id: OSM key of the node with the smallest id in the cluster.
    public var id: String
    /// Centroid of the cluster.
    public var coordinate: GeoPoint

    public init(id: String, coordinate: GeoPoint) {
        self.id = id
        self.coordinate = coordinate
    }
}

/// Converts Overpass elements into route features and signal locations.
public enum RouteFeatureExtractor {
    /// Radius within which traffic-signal nodes form one signalised intersection (metres).
    public static let signalClusterRadius: Double = 40

    /// Feature kind from OSM tags, nil when irrelevant.
    public static func kind(for tags: [String: String]) -> RouteFeatureKind? {
        let highway = tags["highway"]?.lowercased()
        switch highway {
        case "traffic_signals": return .trafficSignals
        case "crossing":
            return tags["crossing"]?.lowercased() == "no" ? nil : .pedestrianCrossing
        case "speed_camera": return .speedCamera
        case "stop": return .stopSign
        case "give_way": return .giveWay
        case "construction": return .construction
        default: break
        }
        if tags["railway"]?.lowercased() == "level_crossing" { return .railwayCrossing }
        if let calming = tags["traffic_calming"]?.lowercased(), !calming.isEmpty, calming != "no" {
            return .trafficCalming
        }
        switch tags["amenity"]?.lowercased() {
        case "school": return .school
        case "kindergarten": return .kindergarten
        case "fuel": return .fuel
        case "parking":
            let access = tags["access"]?.lowercased() ?? ""
            return ["private", "no", "customers"].contains(access) ? nil : .parking
        default: return nil
        }
    }

    /// Projects elements onto the route, drops those farther than `maxOffset` (schools / kindergartens: 150 m),
    /// merges same-kind features closer than `RouteFeatureKind.mergeRadius` along the route (traffic signals:
    /// 60 m → one signalised intersection; also same-named schools within 150 m, e.g. a node and its campus outline).
    /// - Parameter cumulative: optional `Geo.cumulativeDistances(route)` (ignored when its count does not match).
    /// - Returns: features sorted by `distanceAlongRoute`.
    public static func extract(elements: [OSMElement], route: [GeoPoint], cumulative: [Double]? = nil,
                               maxOffset: Double = 40) -> [RouteFeature] {
        features(from: candidates(elements: elements, route: route, cumulative: cumulative, maxOffset: maxOffset))
    }

    /// Projection phase of `extract`: one candidate per relevant element within its maximum offset of the route
    /// (elements with a repeated key are taken once). Progressive loaders project each chunk's new elements once,
    /// append the result to the earlier candidates and re-cluster with `features(from:)`.
    public static func candidates(elements: [OSMElement], route: [GeoPoint], cumulative: [Double]? = nil,
                                  maxOffset: Double = 40) -> [RouteFeatureCandidate] {
        guard !route.isEmpty else { return [] }
        let cum = (cumulative?.count == route.count) ? cumulative! : Geo.cumulativeDistances(route)

        typealias Candidate = RouteFeatureCandidate
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for element in elements {
            guard !seen.contains(element.key), let kind = kind(for: element.tags) else { continue }
            seen.insert(element.key)
            // For ways with geometry use the vertex closest to the route (a long construction way's centre
            // may be far from the route even though the way overlaps it).
            var points: [GeoPoint] = []
            if let c = element.coordinate { points.append(c) }
            if element.type != .node, let geometry = element.geometry { points.append(contentsOf: geometry) }
            var bestProjection: Geo.Projection?
            var bestPoint: GeoPoint?
            for p in points where p.isValid {
                guard let proj = Geo.project(p, onto: route, cumulative: cum) else { continue }
                if bestProjection == nil || proj.distanceFromLine < bestProjection!.distanceFromLine {
                    bestProjection = proj
                    bestPoint = p
                }
            }
            guard let projection = bestProjection, let point = bestPoint,
                  projection.distanceFromLine <= kind.maxOffset(default: maxOffset) else { continue }
            let name = element.tags["name:ru"] ?? element.tags["name"]
            candidates.append(Candidate(element: element, kind: kind, coordinate: point,
                                        along: projection.distanceAlong, offset: projection.distanceFromLine,
                                        name: name?.isEmpty == true ? nil : name))
        }
        return candidates
    }

    /// Clustering phase of `extract`: merges same-kind candidates and returns the features sorted along the route.
    public static func features(from candidates: [RouteFeatureCandidate]) -> [RouteFeature] {
        typealias Candidate = RouteFeatureCandidate
        var features: [RouteFeature] = []
        let byKind = Dictionary(grouping: candidates, by: \.kind)
        for kind in RouteFeatureKind.allCases {
            guard let list = byKind[kind] else { continue }
            let sorted = list.sorted { ($0.along, $0.element.id) < ($1.along, $1.element.id) }
            var clusters: [[Candidate]] = []
            for candidate in sorted {
                if var last = clusters.last, let anchor = last.first {
                    let closeAlong = candidate.along - anchor.along < kind.mergeRadius
                    let sameNamedPlace = (kind == .school || kind == .kindergarten)
                        && candidate.name != nil && candidate.name == anchor.name
                        && candidate.along - anchor.along < 150
                    if closeAlong || sameNamedPlace {
                        last.append(candidate)
                        clusters[clusters.count - 1] = last
                        continue
                    }
                }
                clusters.append([candidate])
            }
            for cluster in clusters {
                guard let first = cluster.first else { continue }
                let representative = cluster.min { lhs, rhs in
                    lhs.element.id == rhs.element.id ? lhs.element.key < rhs.element.key : lhs.element.id < rhs.element.id
                } ?? first
                let nearest = cluster.min { $0.offset < $1.offset } ?? first
                features.append(RouteFeature(id: representative.element.key,
                                             kind: kind,
                                             coordinate: first.coordinate,
                                             distanceAlongRoute: first.along,
                                             offsetFromRoute: nearest.offset,
                                             name: cluster.lazy.compactMap(\.name).first,
                                             tags: representative.element.tags))
            }
        }
        return features.sorted { lhs, rhs in
            if lhs.distanceAlongRoute != rhs.distanceAlongRoute { return lhs.distanceAlongRoute < rhs.distanceAlongRoute }
            return lhs.id < rhs.id
        }
    }

    /// `highway=traffic_signals` elements clustered within 40 m into signalised intersections.
    /// Deterministic: nodes are processed in OSM id order; each cluster's id is its smallest node key and its
    /// coordinate the centroid of the members.
    public static func signals(from elements: [OSMElement]) -> [SignalLocation] {
        let nodes = elements
            .filter { $0.tags["highway"]?.lowercased() == "traffic_signals" }
            .compactMap { element -> (OSMElement, GeoPoint)? in
                guard let c = element.coordinate else { return nil }
                return (element, c)
            }
            .sorted { ($0.0.id, $0.0.key) < ($1.0.id, $1.0.key) }

        var clusters: [(id: String, members: [GeoPoint], centroid: GeoPoint)] = []
        var seen = Set<String>()
        for (element, point) in nodes {
            guard seen.insert(element.key).inserted else { continue }
            var bestIndex: Int?
            var bestDistance = Double.infinity
            for (i, cluster) in clusters.enumerated() {
                let d = Geo.distance(cluster.centroid, point)
                if d <= signalClusterRadius && d < bestDistance {
                    bestDistance = d
                    bestIndex = i
                }
            }
            if let i = bestIndex {
                clusters[i].members.append(point)
                let members = clusters[i].members
                clusters[i].centroid = GeoPoint(
                    latitude: members.reduce(0) { $0 + $1.latitude } / Double(members.count),
                    longitude: members.reduce(0) { $0 + $1.longitude } / Double(members.count))
            } else {
                clusters.append((element.key, [point], point))
            }
        }
        return clusters.map { SignalLocation(id: $0.id, coordinate: $0.centroid) }
    }

    /// The signal location (e.g. from `signals(from:)`, used by `StopDetector`) that corresponds to a
    /// route feature: the same id, else the nearest within `radius` metres. Lets learned waits recorded under
    /// a `SignalLocation.id` be found for a `RouteFeature` even when the two clusterings picked different ids.
    public static func matchingSignal(for feature: RouteFeature, in signals: [SignalLocation],
                                      radius: Double = 50) -> SignalLocation? {
        if let same = signals.first(where: { $0.id == feature.id }) { return same }
        var best: SignalLocation?
        var bestDistance = radius
        for signal in signals {
            let d = Geo.distance(signal.coordinate, feature.coordinate)
            if d <= bestDistance {
                bestDistance = d
                best = signal
            }
        }
        return best
    }
}

/// An OSM element projected onto a route (intermediate result of `RouteFeatureExtractor`).
public struct RouteFeatureCandidate: Sendable {
    public let element: OSMElement
    public let kind: RouteFeatureKind
    public let coordinate: GeoPoint
    /// Distance along the route of the element's closest point.
    public let along: Double
    /// Distance from the route line, metres.
    public let offset: Double
    public let name: String?

    public init(element: OSMElement, kind: RouteFeatureKind, coordinate: GeoPoint, along: Double, offset: Double,
                name: String?) {
        self.element = element
        self.kind = kind
        self.coordinate = coordinate
        self.along = along
        self.offset = offset
        self.name = name
    }
}
