import Foundation

/// One element of an Overpass API JSON response (`[out:json]`).
///
/// Decoding is deliberately tolerant, because Overpass output differs with the `out` mode:
/// - nodes carry `lat`/`lon` (except with `out tags;`),
/// - ways/relations carry `center` with `out center`, `geometry` with `out geom`
///   (bounded `out geom(bbox)` emits `null` for vertices outside the box — those are skipped),
/// - `nodes` (member node ids) only with `out body`/`out skel`,
/// - `tags` may be absent (an empty dictionary is used then).
/// Unknown element types (`"area"`, `"count"`, …) never fail decoding: a standalone `OSMElement` decodes them
/// as `.relation`, and `OverpassResponse` skips them entirely.
public struct OSMElement: Decodable, Hashable, Sendable {
    /// OSM element type.
    public enum ElementType: String, Decodable, Sendable {
        case node, way, relation
    }

    public let type: ElementType
    public let id: Int64
    /// Node latitude (nodes only).
    public let lat: Double?
    /// Node longitude (nodes only).
    public let lon: Double?
    /// Centre computed by Overpass (`out center`), for ways and relations.
    public let center: GeoPoint?
    /// Vertex coordinates of a way (`out geom`), in drawing order.
    public let geometry: [GeoPoint]?
    /// Member node ids of a way (`out body`).
    public let nodes: [Int64]?
    /// OSM tags; empty when the element has none.
    public let tags: [String: String]

    /// Creates an element directly (tests, synthetic data).
    public init(type: ElementType, id: Int64, lat: Double? = nil, lon: Double? = nil, center: GeoPoint? = nil,
                geometry: [GeoPoint]? = nil, nodes: [Int64]? = nil, tags: [String: String] = [:]) {
        self.type = type
        self.id = id
        self.lat = lat
        self.lon = lon
        self.center = center
        self.geometry = geometry
        self.nodes = nodes
        self.tags = tags
    }

    /// Best available representative coordinate: `lat`/`lon`, else `center`, else a point of `geometry`
    /// (the vertex average for closed rings such as building outlines, otherwise the point halfway along the way).
    public var coordinate: GeoPoint? {
        if let lat, let lon {
            let p = GeoPoint(latitude: lat, longitude: lon)
            if p.isValid { return p }
        }
        if let center, center.isValid { return center }
        guard let geometry, !geometry.isEmpty else { return nil }
        if geometry.count >= 4, geometry.first == geometry.last {
            let ring = geometry.dropLast()
            let lat = ring.reduce(0) { $0 + $1.latitude } / Double(ring.count)
            let lon = ring.reduce(0) { $0 + $1.longitude } / Double(ring.count)
            return GeoPoint(latitude: lat, longitude: lon)
        }
        let cumulative = Geo.cumulativeDistances(geometry)
        return Geo.point(atDistance: (cumulative.last ?? 0) / 2, along: geometry, cumulative: cumulative)
    }

    /// Stable identifier in OSM notation, e.g. `"node/123"`, `"way/456"`.
    public var key: String { "\(type.rawValue)/\(id)" }

    /// Tag value lookup (convenience).
    public subscript(tag key: String) -> String? { tags[key] }

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey {
        case type, id, lat, lon, center, geometry, nodes, tags
    }

    /// `{"lat": .., "lon": ..}` as used by `center` and `geometry`.
    private struct LatLon: Decodable {
        let lat: Double
        let lon: Double
        var point: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
    }

    /// A tag value that tolerates numbers and booleans (e.g. `out count` produces numeric-looking tags).
    private struct TagValue: Decodable {
        let string: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                string = s
            } else if let i = try? c.decode(Int64.self) {
                string = String(i)
            } else if let d = try? c.decode(Double.self) {
                string = String(d)
            } else if let b = try? c.decode(Bool.self) {
                string = b ? "yes" : "no"
            } else {
                string = ""
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = (try? c.decode(String.self, forKey: .type)) ?? ""
        type = ElementType(rawValue: rawType) ?? .relation
        id = try c.decode(Int64.self, forKey: .id)
        lat = try? c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try? c.decodeIfPresent(Double.self, forKey: .lon)
        center = (try? c.decodeIfPresent(LatLon.self, forKey: .center))?.point
        if let raw = try? c.decodeIfPresent([LatLon?].self, forKey: .geometry) {
            let points = raw.compactMap { $0?.point }
            geometry = points.isEmpty ? nil : points
        } else {
            geometry = nil
        }
        nodes = try? c.decodeIfPresent([Int64].self, forKey: .nodes)
        if let raw = try? c.decodeIfPresent([String: TagValue].self, forKey: .tags) {
            tags = raw.mapValues(\.string)
        } else {
            tags = [:]
        }
    }
}

/// Top-level Overpass JSON document.
public struct OverpassResponse: Decodable, Sendable {
    /// Decoded elements. Elements of unknown type or malformed elements are skipped instead of failing the response.
    public let elements: [OSMElement]
    /// Overpass puts runtime errors (timeouts, memory exhaustion) here while still answering HTTP 200.
    /// A non-nil remark means the element list may be incomplete.
    public let remark: String?
    /// `osm3s.timestamp_osm_base` — age of the OSM data on the server, if reported.
    public let timestampOSMBase: String?

    /// True when the server reported a runtime problem, i.e. `elements` may be partial.
    public var isPartial: Bool {
        guard let remark else { return false }
        return !remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(elements: [OSMElement], remark: String? = nil, timestampOSMBase: String? = nil) {
        self.elements = elements
        self.remark = remark
        self.timestampOSMBase = timestampOSMBase
    }

    private enum CodingKeys: String, CodingKey {
        case elements, remark, osm3s
    }

    private struct OSM3S: Decodable {
        let timestamp_osm_base: String?
    }

    /// Wrapper that never throws, so one bad element cannot break the whole array
    /// (and the unkeyed container always advances).
    private struct ElementSlot: Decodable {
        let element: OSMElement?

        private enum TypeKey: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let known: Bool
            if let c = try? decoder.container(keyedBy: TypeKey.self),
               let raw = try? c.decode(String.self, forKey: .type) {
                known = OSMElement.ElementType(rawValue: raw) != nil
            } else {
                known = false
            }
            element = known ? (try? OSMElement(from: decoder)) : nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slots = try c.decodeIfPresent([ElementSlot].self, forKey: .elements) ?? []
        elements = slots.compactMap(\.element)
        remark = try? c.decodeIfPresent(String.self, forKey: .remark)
        timestampOSMBase = (try? c.decodeIfPresent(OSM3S.self, forKey: .osm3s))?.timestamp_osm_base
    }
}
