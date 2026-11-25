import Foundation

/// Encoded polyline (Google algorithm) with configurable precision (Valhalla uses 6).
public enum Polyline {
    public static func decode(_ encoded: String, precision: Int = 6) -> [GeoPoint] {
        let factor = pow(10.0, Double(precision))
        let bytes = Array(encoded.utf8)
        var index = 0, lat = 0, lon = 0
        var result: [GeoPoint] = []
        result.reserveCapacity(bytes.count / 4)

        func next() -> Int? {
            var shift = 0, value = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                value |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 {
                    return (value & 1) != 0 ? ~(value >> 1) : (value >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            result.append(GeoPoint(Double(lat) / factor, Double(lon) / factor))
        }
        return result
    }

    public static func encode(_ points: [GeoPoint], precision: Int = 6) -> String {
        let factor = pow(10.0, Double(precision))
        var out = [UInt8]()
        var prevLat = 0, prevLon = 0
        func put(_ v: Int) {
            var value = v < 0 ? ~(v << 1) : (v << 1)
            while value >= 0x20 {
                out.append(UInt8((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            }
            out.append(UInt8(value + 63))
        }
        for p in points {
            let lat = Int((p.latitude * factor).rounded())
            let lon = Int((p.longitude * factor).rounded())
            put(lat - prevLat)
            put(lon - prevLon)
            prevLat = lat
            prevLon = lon
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Where a route came from.
public enum RouteSource: String, Codable, Hashable, Sendable {
    case apple
    case valhalla

    public var displayName: String {
        switch self {
        case .apple: return "Apple Maps"
        case .valhalla: return "OpenStreetMap (Valhalla)"
        }
    }
}

/// Engine-independent route used by the navigator.
public struct NavRoute: Hashable, Sendable {
    public var source: RouteSource
    public var name: String
    public var polyline: [GeoPoint]
    /// Metres.
    public var distance: Double
    /// Seconds (engine estimate; Valhalla/OSM has no live traffic).
    public var expectedTravelTime: Double
    public var steps: [RouteStepInfo]
    public var hasTolls: Bool
    public var hasHighways: Bool
    public var advisories: [String]

    public init(source: RouteSource, name: String, polyline: [GeoPoint], distance: Double, expectedTravelTime: Double,
                steps: [RouteStepInfo], hasTolls: Bool = false, hasHighways: Bool = false, advisories: [String] = []) {
        self.source = source
        self.name = name
        self.polyline = polyline
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.steps = steps
        self.hasTolls = hasTolls
        self.hasHighways = hasHighways
        self.advisories = advisories
    }
}

/// Attributes of one road edge along a route (from Valhalla `/trace_attributes`).
public struct RouteEdgeAttributes: Hashable, Sendable {
    /// Distance from the route start to the edge start / end, metres.
    public var startDistance: Double
    public var endDistance: Double
    public var names: [String]
    /// Posted speed limit (OSM maxspeed), km/h.
    public var speedLimitKmh: Int?
    /// Lanes in the travel direction (Valhalla value; 1 may mean "not tagged").
    public var laneCount: Int?
    /// Typical (free-flow, OSM-derived) speed used by the router, km/h.
    public var typicalSpeedKmh: Double?
    public var roadClass: String?
    public var wayID: Int64?
    /// True when a traffic signal is at this edge or at its end node.
    public var hasTrafficSignal: Bool

    public init(startDistance: Double, endDistance: Double, names: [String] = [], speedLimitKmh: Int? = nil,
                laneCount: Int? = nil, typicalSpeedKmh: Double? = nil, roadClass: String? = nil,
                wayID: Int64? = nil, hasTrafficSignal: Bool = false) {
        self.startDistance = startDistance
        self.endDistance = endDistance
        self.names = names
        self.speedLimitKmh = speedLimitKmh
        self.laneCount = laneCount
        self.typicalSpeedKmh = typicalSpeedKmh
        self.roadClass = roadClass
        self.wayID = wayID
        self.hasTrafficSignal = hasTrafficSignal
    }
}

public struct ValhallaError: Error, CustomStringConvertible, Sendable {
    public let code: Int?
    public let message: String
    public var description: String { message }
}

/// Request building and response parsing for the Valhalla routing engine
/// (default public instance: https://valhalla1.openstreetmap.de, FOSSGIS — light use only, ≤ 1 request/s,
/// identifying User-Agent, OSM attribution required, URL must stay configurable).
public enum Valhalla {
    public static let defaultEndpoint = "https://valhalla1.openstreetmap.de"

    /// Body for `POST /route`.
    public static func routeRequestBody(from origin: GeoPoint, to destination: GeoPoint, heading: Double? = nil,
                                        language: String = "ru-RU", alternates: Int = 2,
                                        avoidTolls: Bool = false, avoidHighways: Bool = false) throws -> Data {
        var start: [String: Any] = ["lat": origin.latitude, "lon": origin.longitude]
        if let heading, heading.isFinite {
            start["heading"] = Int(Geo.normalizeDegrees(heading).rounded()) % 360
            start["heading_tolerance"] = 60
        }
        var auto: [String: Any] = [:]
        if avoidTolls { auto["use_tolls"] = 0.0 }
        if avoidHighways { auto["use_highways"] = 0.0 }
        var body: [String: Any] = [
            "locations": [start, ["lat": destination.latitude, "lon": destination.longitude]],
            "costing": "auto",
            "directions_options": ["language": language, "units": "kilometers"],
            "turn_lanes": true,
        ]
        if alternates > 0 { body["alternates"] = alternates }
        if !auto.isEmpty { body["costing_options"] = ["auto": auto] }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Parses `/route` into the main route followed by alternates.
    public static func parseRoutes(_ data: Data) throws -> [NavRoute] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValhallaError(code: nil, message: "Ответ Valhalla не является JSON")
        }
        if let err = errorFrom(obj) { throw err }
        guard let trip = obj["trip"] as? [String: Any] else {
            throw ValhallaError(code: nil, message: "В ответе Valhalla нет маршрута")
        }
        var routes = [try parseTrip(trip)]
        if let alternates = obj["alternates"] as? [[String: Any]] {
            for alt in alternates {
                if let t = alt["trip"] as? [String: Any], let r = try? parseTrip(t) {
                    routes.append(r)
                }
            }
        }
        return routes
    }

    static func errorFrom(_ obj: [String: Any]) -> ValhallaError? {
        if let message = obj["error"] as? String {
            return ValhallaError(code: obj["error_code"] as? Int, message: message)
        }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    static func parseTrip(_ trip: [String: Any]) throws -> NavRoute {
        guard let legs = trip["legs"] as? [[String: Any]], !legs.isEmpty else {
            throw ValhallaError(code: nil, message: "Маршрут без участков")
        }
        let unitsFactor = (trip["units"] as? String) == "miles" ? 1609.344 : 1000.0
        var polyline: [GeoPoint] = []
        var steps: [RouteStepInfo] = []
        var names: [String] = []
        var anyToll = false, anyHighway = false

        for leg in legs {
            let shape = Polyline.decode(leg["shape"] as? String ?? "", precision: 6)
            let offset = polyline.isEmpty ? 0 : 1   // shared endpoint between legs
            polyline.append(contentsOf: shape.dropFirst(offset))
            for m in (leg["maneuvers"] as? [[String: Any]]) ?? [] {
                let type = int(m["type"]) ?? 0
                let lengthMeters = (double(m["length"]) ?? 0) * unitsFactor
                let street = (m["street_names"] as? [String]) ?? []
                if names.count < 2, let s = street.first, !names.contains(s) { names.append(s) }
                if (m["toll"] as? Bool) == true { anyToll = true }
                if (m["highway"] as? Bool) == true { anyHighway = true }
                let laneData = (m["lanes"] as? [[String: Any]]) ?? []
                let (lanes, active) = lanes(from: laneData.map {
                    ValhallaLane(directions: int($0["directions"]) ?? 0, valid: int($0["valid"]), active: int($0["active"]))
                })
                steps.append(RouteStepInfo(instruction: (m["instruction"] as? String) ?? "",
                                           distance: lengthMeters,
                                           notice: nil,
                                           maneuver: maneuverType(type),
                                           lanes: lanes,
                                           activeLanes: active,
                                           streetNames: street))
            }
        }
        // Valhalla: maneuver i's instruction describes the action at its START and its length is the distance
        // travelled after it — the same convention as MKRoute.Step. The first maneuver (kStart) is the departure:
        // blank its instruction so RouteProgressTracker never announces it.
        if !steps.isEmpty, steps[0].maneuver == .depart {
            steps[0].instruction = ""
        }
        let summary = trip["summary"] as? [String: Any]
        let distance = (double(summary?["length"]) ?? 0) * unitsFactor
        let time = double(summary?["time"]) ?? 0
        if (summary?["has_toll"] as? Bool) == true { anyToll = true }
        if (summary?["has_highway"] as? Bool) == true { anyHighway = true }
        let name = names.isEmpty ? "Маршрут OSM" : names.joined(separator: ", ")
        return NavRoute(source: .valhalla, name: name, polyline: polyline,
                        distance: distance > 0 ? distance : Geo.polylineLength(polyline),
                        expectedTravelTime: time, steps: steps,
                        hasTolls: anyToll, hasHighways: anyHighway, advisories: [])
    }

    /// Valhalla maneuver type code → ManeuverType.
    public static func maneuverType(_ code: Int) -> ManeuverType {
        switch code {
        case 1, 2, 3: return .depart
        case 4, 5, 6: return .arrive
        case 7, 8, 17, 22: return .straight
        case 9: return .slightRight
        case 10: return .right
        case 11: return .sharpRight
        case 12, 13: return .uTurn
        case 14: return .sharpLeft
        case 15: return .left
        case 16: return .slightLeft
        case 18, 20: return .exitRight
        case 19, 21: return .exitLeft
        case 23: return .keepRight
        case 24: return .keepLeft
        case 25, 37, 38: return .merge
        case 26, 27: return .roundabout
        default: return .unknown
        }
    }

    public struct ValhallaLane: Hashable, Sendable {
        public var directions: Int
        public var valid: Int?
        public var active: Int?

        public init(directions: Int, valid: Int? = nil, active: Int? = nil) {
            self.directions = directions
            self.valid = valid
            self.active = active
        }
    }

    /// Valhalla lane bitmask: 1 None, 2 Through, 4 SharpLeft, 8 Left, 16 SlightLeft, 32 SlightRight, 64 Right,
    /// 128 SharpRight, 256 Reverse, 512 MergeToLeft, 1024 MergeToRight.
    public static func turns(fromMask mask: Int) -> [LaneTurn] {
        let table: [(Int, LaneTurn)] = [(256, .reverse), (4, .sharpLeft), (8, .left), (16, .slightLeft),
                                        (2, .through), (32, .slightRight), (64, .right), (128, .sharpRight),
                                        (512, .mergeToLeft), (1024, .mergeToRight), (1, .none)]
        return table.compactMap { mask & $0.0 != 0 ? $0.1 : nil }
    }

    /// Lanes (left → right) and whether each is recommended (`active`, else `valid`).
    public static func lanes(from raw: [ValhallaLane]) -> (lanes: [Lane], active: [Bool]) {
        guard !raw.isEmpty else { return ([], []) }
        let lanes = raw.map { Lane(turns: turns(fromMask: $0.directions)) }
        let anyActive = raw.contains { ($0.active ?? 0) != 0 }
        let active = raw.map { anyActive ? (($0.active ?? 0) != 0) : (($0.valid ?? 0) != 0) }
        return (lanes, active)
    }

    // MARK: trace_attributes

    public static let traceAttributeFilters = [
        "shape", "edge.names", "edge.length", "edge.speed", "edge.speed_limit", "edge.lane_count",
        "edge.road_class", "edge.way_id", "edge.begin_shape_index", "edge.end_shape_index",
        "edge.traffic_signal", "node.traffic_signal",
    ]

    /// Body for `POST /trace_attributes`. Use `edgeWalk: true` only for shapes produced by Valhalla itself;
    /// other polylines (e.g. Apple routes) must use map matching (`map_snap`) and should be simplified first.
    public static func traceAttributesBody(polyline: [GeoPoint], edgeWalk: Bool) throws -> Data {
        let body: [String: Any] = [
            "encoded_polyline": Polyline.encode(polyline, precision: 6),
            "shape_match": edgeWalk ? "edge_walk" : "map_snap",
            "costing": "auto",
            "filters": ["attributes": traceAttributeFilters, "action": "include"],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Parses `/trace_attributes` edges with along-route distances computed on the matched shape
    /// (or on `fallbackPolyline` when the response has no shape).
    public static func parseTraceAttributes(_ data: Data, fallbackPolyline: [GeoPoint]) throws -> [RouteEdgeAttributes] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValhallaError(code: nil, message: "Ответ trace_attributes не является JSON")
        }
        if let err = errorFrom(obj) { throw err }
        let shape = (obj["shape"] as? String).map { Polyline.decode($0, precision: 6) } ?? fallbackPolyline
        let cumulative = Geo.cumulativeDistances(shape)
        let unitsFactor = (obj["units"] as? String) == "miles" ? 1609.344 : 1000.0
        var result: [RouteEdgeAttributes] = []
        var running = 0.0
        for e in (obj["edges"] as? [[String: Any]]) ?? [] {
            let lengthM = (double(e["length"]) ?? 0) * unitsFactor
            var start = running, end = running + lengthM
            if let b = int(e["begin_shape_index"]), let en = int(e["end_shape_index"]),
               cumulative.indices.contains(b), cumulative.indices.contains(en), en >= b {
                start = cumulative[b]
                end = cumulative[en]
            }
            running = end
            let endNode = e["end_node"] as? [String: Any]
            let signal = (e["traffic_signal"] as? Bool) == true || (endNode?["traffic_signal"] as? Bool) == true
            let limit = int(e["speed_limit"]).flatMap { $0 > 0 && $0 < 200 ? $0 : nil }
            let lanes = int(e["lane_count"]).flatMap { $0 > 0 ? $0 : nil }
            let wayID: Int64? = (e["way_id"] as? NSNumber)?.int64Value ?? (e["way_id"] as? Int).map { Int64($0) }
            result.append(RouteEdgeAttributes(startDistance: start, endDistance: end,
                                              names: (e["names"] as? [String]) ?? [],
                                              speedLimitKmh: limit, laneCount: lanes,
                                              typicalSpeedKmh: double(e["speed"]),
                                              roadClass: e["road_class"] as? String,
                                              wayID: wayID, hasTrafficSignal: signal))
        }
        return result
    }

    /// Edge containing `distanceAlong` (binary search over sorted edges).
    public static func attributes(at distanceAlong: Double, in edges: [RouteEdgeAttributes]) -> RouteEdgeAttributes? {
        guard !edges.isEmpty else { return nil }
        var lo = 0, hi = edges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let e = edges[mid]
            if distanceAlong < e.startDistance { hi = mid - 1 }
            else if distanceAlong > e.endDistance { lo = mid + 1 }
            else { return e }
        }
        return nil
    }

    /// Signalised points along the route (end of each edge flagged with a traffic signal), merged within 60 m.
    public static func signalDistances(in edges: [RouteEdgeAttributes]) -> [Double] {
        var result: [Double] = []
        for e in edges where e.hasTrafficSignal {
            if let last = result.last, e.endDistance - last < 60 { continue }
            result.append(e.endDistance)
        }
        return result
    }
}

/// Live congestion estimate on the current road segment from the user's own GPS speed
/// compared with the typical (OSM-derived) speed of the edge. Single-vehicle observation, not traffic data.
public enum CongestionEstimator {
    /// Returns nil when there is not enough information (unknown typical speed or very slow typical roads).
    public static func level(ownSpeedKmh: Double?, typicalSpeedKmh: Double?, stoppedAtSignal: Bool = false) -> CongestionLevel? {
        guard let own = ownSpeedKmh, let typical = typicalSpeedKmh, typical >= 20, !stoppedAtSignal else { return nil }
        let ratio = own / typical
        switch ratio {
        case 0.8...: return .free
        case 0.6..<0.8: return .light
        case 0.4..<0.6: return .moderate
        case 0.2..<0.4: return .heavy
        default: return .severe
        }
    }
}
