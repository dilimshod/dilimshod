import Foundation

/// Kind of an event along the route.
public enum RouteTimelineKind: Hashable, Sendable {
    case maneuver(ManeuverType)
    /// Posted speed limit changes to this value (nil = not mapped).
    case speedLimit(Int?)
    /// Lanes in the travel direction change from → to.
    case lanes(from: Int, to: Int)
    case trafficSignal
    case feature(RouteFeatureKind)
    case incident(RoadIncidentKind)
    case destination

    /// Sorting priority for events at (almost) the same place (lower first).
    var priority: Int {
        switch self {
        case .maneuver: return 0
        case .destination: return 1
        case .incident: return 2
        case .trafficSignal: return 3
        case .feature: return 4
        case .speedLimit: return 5
        case .lanes: return 6
        }
    }

    /// Short machine-friendly name ("maneuver", "speedLimit" …) used for filtering and stable ids.
    public var category: String {
        switch self {
        case .maneuver: return "maneuver"
        case .speedLimit: return "speedLimit"
        case .lanes: return "lanes"
        case .trafficSignal: return "signal"
        case .feature(let kind): return kind.isPointOfInterest ? "poi" : "hazard"
        case .incident: return "incident"
        case .destination: return "destination"
        }
    }
}

/// One upcoming event along the route ("Впереди" list, route strip, map markers).
public struct RouteTimelineEvent: Identifiable, Hashable, Sendable {
    public var id: String
    /// Distance from the route start, metres.
    public var distanceAlongRoute: Double
    public var kind: RouteTimelineKind
    /// Russian title ("Поверните налево на …", "Ограничение 60 км/ч", "Светофор").
    public var title: String
    public var detail: String?
    public var symbolName: String
    /// Where the fact comes from ("маршрут Valhalla", "OSM", "Valhalla (OSM)", "ваша отметка").
    public var source: String
    public var coordinate: GeoPoint?

    public init(id: String, distanceAlongRoute: Double, kind: RouteTimelineKind, title: String, detail: String?,
                symbolName: String, source: String, coordinate: GeoPoint?) {
        self.id = id
        self.distanceAlongRoute = distanceAlongRoute
        self.kind = kind
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.source = source
        self.coordinate = coordinate
    }
}

/// A stretch of the route with one posted speed limit (nil = unknown), for the coloured route strip.
public struct SpeedLimitSegment: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var limitKmh: Int?

    public init(start: Double, end: Double, limitKmh: Int?) {
        self.start = start
        self.end = end
        self.limitKmh = limitKmh
    }

    public var length: Double { max(0, end - start) }
}

/// Builds the ordered list of events along a route from all sources: maneuvers (routing engine), speed-limit and
/// lane-count changes and signals (Valhalla trace attributes), OSM features (cameras, schools, crossings, bumps,
/// rail crossings, construction, fuel, parking) and user-reported incidents.
public enum RouteTimeline {
    /// Shorter limit / lane segments are folded into their neighbours (avoids noise at junctions), metres.
    public static let minimumSegmentLength: Double = 120
    /// A Valhalla signal within this distance of an OSM signal is the same intersection, metres.
    public static let signalMergeDistance: Double = 60

    /// Start distance of each step (scaled so the step distances sum to the polyline length) — the same
    /// convention as `RouteProgressTracker.maneuverDistances`.
    public static func maneuverDistances(steps: [RouteStepInfo], totalLength: Double) -> [Double] {
        let stepSum = steps.reduce(0) { $0 + max(0, $1.distance) }
        let scale = stepSum > 0 ? totalLength / stepSum : 1
        var acc = 0.0
        var result: [Double] = []
        for s in steps {
            result.append(min(totalLength, acc * scale))
            acc += max(0, s.distance)
        }
        return result
    }

    public static func build(route: NavRoute, edges: [RouteEdgeAttributes], features: [RouteFeature],
                             incidents: [IncidentOnRoute]) -> [RouteTimelineEvent] {
        let cumulative = Geo.cumulativeDistances(route.polyline)
        let total = cumulative.last ?? route.distance
        func point(_ d: Double) -> GeoPoint? {
            Geo.point(atDistance: d, along: route.polyline, cumulative: cumulative)
        }
        var events: [RouteTimelineEvent] = []
        let engine = route.source == .apple ? "маршрут Apple" : "маршрут \(route.source.badge)"

        // Maneuvers.
        let starts = maneuverDistances(steps: route.steps, totalLength: total)
        for (i, step) in route.steps.enumerated() where i >= 1 {
            let text = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let maneuver = step.resolvedManeuver
            if maneuver == .arrive { continue }
            var detail: String?
            if !step.lanes.isEmpty {
                let good = step.activeLanes.filter { $0 }.count
                detail = good > 0 ? "полос: \(step.lanes.count), подходят: \(good)" : "полос: \(step.lanes.count)"
            }
            events.append(RouteTimelineEvent(id: "m\(i)", distanceAlongRoute: starts[i], kind: .maneuver(maneuver),
                                             title: text, detail: detail, symbolName: maneuver.symbolName,
                                             source: engine, coordinate: point(starts[i])))
        }
        events.append(RouteTimelineEvent(id: "dest", distanceAlongRoute: total, kind: .destination,
                                         title: "Пункт назначения", detail: nil, symbolName: "flag.checkered",
                                         source: engine, coordinate: route.polyline.last))

        // Speed-limit changes.
        let limits = speedLimitSegments(edges: edges, totalDistance: total)
        var previousLimit: Int?? = .none
        for segment in limits {
            if case .some(let prev) = previousLimit, prev == segment.limitKmh { continue }
            let isFirst = previousLimit == nil
            previousLimit = .some(segment.limitKmh)
            if isFirst && segment.limitKmh == nil { continue }
            let title = segment.limitKmh.map { "Ограничение \($0) км/ч" } ?? "Ограничение не указано в OSM"
            let detail = isFirst ? "в начале маршрута" : "на \(RVFormat.distance(segment.length))"
            events.append(RouteTimelineEvent(id: "sl\(Int(segment.start))", distanceAlongRoute: segment.start,
                                             kind: .speedLimit(segment.limitKmh), title: title, detail: detail,
                                             symbolName: "speedometer", source: "Valhalla (OSM)",
                                             coordinate: point(segment.start)))
        }

        // Lane-count changes (Valhalla's 1 often means "not tagged" → ignored).
        for change in laneChanges(edges: edges) {
            let title = change.to > change.from ? "Расширение до \(change.to) полос" : "Сужение до \(change.to) полос"
            events.append(RouteTimelineEvent(id: "ln\(Int(change.distance))", distanceAlongRoute: change.distance,
                                             kind: .lanes(from: change.from, to: change.to), title: title,
                                             detail: "было \(change.from)", symbolName: "road.lanes",
                                             source: "Valhalla (OSM)", coordinate: point(change.distance)))
        }

        // Traffic signals: OSM features first, then Valhalla signals that are not near any of them.
        let osmSignals = features.filter { $0.kind == .trafficSignals }
        for f in osmSignals {
            events.append(RouteTimelineEvent(id: "s|" + f.id, distanceAlongRoute: f.distanceAlongRoute,
                                             kind: .trafficSignal, title: "Светофор", detail: f.name,
                                             symbolName: RouteFeatureKind.trafficSignals.symbolName, source: "OSM",
                                             coordinate: f.coordinate))
        }
        for d in Valhalla.signalDistances(in: edges)
        where !osmSignals.contains(where: { abs($0.distanceAlongRoute - d) < signalMergeDistance }) {
            events.append(RouteTimelineEvent(id: "vs\(Int(d))", distanceAlongRoute: d, kind: .trafficSignal,
                                             title: "Светофор", detail: nil,
                                             symbolName: RouteFeatureKind.trafficSignals.symbolName,
                                             source: "Valhalla (OSM)", coordinate: point(d)))
        }

        // Other OSM features.
        for f in features where f.kind != .trafficSignals {
            var detail = f.name
            if f.kind == .speedCamera, let limit = f.tags["maxspeed"].flatMap({ MaxSpeedParser.parse($0)?.kmh }) {
                detail = [detail, "контроль \(limit) км/ч"].compactMap { $0 }.joined(separator: " · ")
            }
            if f.kind == .fuel, let brand = f.tags["brand"], brand != f.name {
                detail = [detail, brand].compactMap { $0 }.joined(separator: " · ")
            }
            events.append(RouteTimelineEvent(id: "f|" + f.id, distanceAlongRoute: f.distanceAlongRoute,
                                             kind: .feature(f.kind), title: f.kind.displayName, detail: detail,
                                             symbolName: f.kind.symbolName, source: "OSM", coordinate: f.coordinate))
        }

        // User-reported incidents.
        for item in incidents {
            events.append(RouteTimelineEvent(id: "i|" + item.id.uuidString, distanceAlongRoute: item.distanceAlongRoute,
                                             kind: .incident(item.incident.kind), title: item.incident.kind.displayName,
                                             detail: item.incident.note, symbolName: item.incident.kind.symbolName,
                                             source: "ваша отметка, " + RVFormat.clock(item.incident.date),
                                             coordinate: item.incident.coordinate))
        }

        return events.sorted { lhs, rhs in
            if abs(lhs.distanceAlongRoute - rhs.distanceAlongRoute) > 0.5 {
                return lhs.distanceAlongRoute < rhs.distanceAlongRoute
            }
            if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority < rhs.kind.priority }
            return lhs.id < rhs.id
        }
    }

    /// Events ahead of `distanceAlong` (a few metres behind are kept so a passing event does not flicker away).
    public static func upcoming(_ events: [RouteTimelineEvent], from distanceAlong: Double,
                                limit: Int? = nil) -> [RouteTimelineEvent] {
        let ahead = events.filter { $0.distanceAlongRoute >= distanceAlong - 5 }
        if let limit { return Array(ahead.prefix(limit)) }
        return ahead
    }

    /// Consecutive edges with the same limit merged; segments shorter than `minimumSegmentLength` take the limit of
    /// the previous segment; gaps (no edges) are nil. Empty without edges.
    public static func speedLimitSegments(edges: [RouteEdgeAttributes], totalDistance: Double? = nil) -> [SpeedLimitSegment] {
        guard !edges.isEmpty else { return [] }
        var raw: [SpeedLimitSegment] = []
        for e in edges where e.endDistance > e.startDistance {
            if let last = raw.last, last.limitKmh == e.speedLimitKmh, e.startDistance - last.end < 1 {
                raw[raw.count - 1].end = max(last.end, e.endDistance)
            } else {
                if let last = raw.last, e.startDistance - last.end >= 1 {
                    raw.append(SpeedLimitSegment(start: last.end, end: e.startDistance, limitKmh: nil))
                }
                raw.append(SpeedLimitSegment(start: e.startDistance, end: e.endDistance, limitKmh: e.speedLimitKmh))
            }
        }
        // Fold short segments into the previous one, then re-merge equal neighbours.
        var folded: [SpeedLimitSegment] = []
        for segment in raw {
            if let last = folded.last, segment.length < minimumSegmentLength || last.limitKmh == segment.limitKmh {
                folded[folded.count - 1].end = segment.end
            } else {
                folded.append(segment)
            }
        }
        if let total = totalDistance, let last = folded.last, total > last.end + 1 {
            folded.append(SpeedLimitSegment(start: last.end, end: total, limitKmh: nil))
        }
        return folded
    }

    /// Lane-count changes ≥ `minimumSegmentLength` long; transitions to or from 1 lane are skipped (Valhalla
    /// reports 1 for untagged roads).
    static func laneChanges(edges: [RouteEdgeAttributes]) -> [(distance: Double, from: Int, to: Int)] {
        var runs: [(start: Double, end: Double, count: Int?)] = []
        for e in edges {
            if let last = runs.last, last.count == e.laneCount {
                runs[runs.count - 1].end = e.endDistance
            } else {
                runs.append((e.startDistance, e.endDistance, e.laneCount))
            }
        }
        var result: [(Double, Int, Int)] = []
        var current: Int?
        for run in runs where run.end - run.start >= minimumSegmentLength {
            guard let count = run.count, count > 1 else { continue }
            if let previous = current, previous != count {
                result.append((run.start, previous, count))
            }
            current = count
        }
        return result
    }

    /// Time to travel from `distanceAlong` to `target` (metres along the route), seconds, proportional to the
    /// typical edge speeds and scaled so that the time to the end equals `remainingTime`. Linear without edges.
    public static func timeOffset(to target: Double, from distanceAlong: Double, remainingTime: Double,
                                  totalDistance: Double, edges: [RouteEdgeAttributes]) -> Double {
        let remaining = max(0, totalDistance - distanceAlong)
        guard target > distanceAlong, remaining > 0, remainingTime > 0 else { return 0 }
        let linear = remainingTime * min(1, (target - distanceAlong) / remaining)
        guard !edges.isEmpty else { return linear }
        func typicalTime(_ a: Double, _ b: Double) -> Double? {
            var t = 0.0
            var covered = 0.0
            for e in edges where e.endDistance > a && e.startDistance < b {
                let length = min(b, e.endDistance) - max(a, e.startDistance)
                guard length > 0, let speed = e.typicalSpeedKmh, speed > 1 else { continue }
                t += length / (speed / 3.6)
                covered += length
            }
            guard covered > 0.5 * (b - a) else { return nil }
            return t * (b - a) / covered
        }
        guard let part = typicalTime(distanceAlong, min(target, totalDistance)),
              let whole = typicalTime(distanceAlong, totalDistance), whole > 0 else { return linear }
        return remainingTime * min(1, part / whole)
    }
}
