import Foundation

/// Travel-time estimate of another engine for (nearly) the same route.
public struct RouteEstimate: Hashable, Sendable {
    public var source: RouteSource
    public var expectedTravelTime: Double
    public var distance: Double

    public init(source: RouteSource, expectedTravelTime: Double, distance: Double) {
        self.source = source
        self.expectedTravelTime = expectedTravelTime
        self.distance = distance
    }
}

/// One distinct route option after merging the candidates of all engines.
public struct RouteChoice: Hashable, Sendable {
    /// Representative route (the fastest of its group).
    public var route: NavRoute
    /// Other engines that found (nearly) the same route, with their own estimates.
    public var duplicates: [RouteEstimate]

    public init(route: NavRoute, duplicates: [RouteEstimate] = []) {
        self.route = route
        self.duplicates = duplicates
    }

    /// All engines that found this route, representative first.
    public var sources: [RouteSource] {
        var result = [route.source]
        for d in duplicates where !result.contains(d.source) { result.append(d.source) }
        return result
    }

    /// Range of the engines' travel-time estimates (min, max), seconds.
    public var timeRange: (min: Double, max: Double) {
        let times = [route.expectedTravelTime] + duplicates.map(\.expectedTravelTime)
        return (times.min() ?? 0, times.max() ?? 0)
    }
}

/// Facts about one route used by the comparison cards.
public struct RouteFacts: Hashable, Sendable {
    public var distance: Double
    public var expectedTravelTime: Double
    /// distance / time, km/h.
    public var averageSpeedKmh: Double?
    /// Signalised intersections (edge attributes, else the given count).
    public var signalCount: Int?
    public var maxSpeedLimitKmh: Int?
    /// Distance-weighted mean posted limit over the edges that have one, km/h.
    public var averageSpeedLimitKmh: Double?
    /// Share of the route length with a known speed limit (0…1), nil without edges.
    public var speedLimitCoverage: Double?
    /// Share of the length on motorway / trunk / primary roads (0…1), nil without edges.
    public var primaryRoadShare: Double?
    /// Share of the length on unpaved surfaces (0…1), nil without edges.
    public var unpavedShare: Double?
    public var hasTolls: Bool
    public var hasHighways: Bool
    /// Announced maneuvers (steps after the departure with an instruction).
    public var maneuverCount: Int
    public var tunnelCount: Int
    public var bridgeCount: Int
}

/// Merging, de-duplication and ranking of route candidates from several engines (Apple, Valhalla, OSRM).
public enum RouteComparison {
    /// Two routes are "the same" when at least this share of each one's sampled points lies near the other.
    public static let defaultOverlapThreshold = 0.85
    /// Lateral tolerance for overlap sampling, metres.
    public static let defaultTolerance: Double = 30
    /// Spacing of the sampled points, metres.
    public static let defaultSpacing: Double = 40

    /// Points every `spacing` metres along the polyline (first and last vertex included).
    public static func samples(_ polyline: [GeoPoint], spacing: Double = defaultSpacing) -> [GeoPoint] {
        guard polyline.count >= 2, spacing > 0 else { return polyline }
        var result = [polyline[0]]
        var carried = 0.0
        for i in 1..<polyline.count {
            let a = polyline[i - 1], b = polyline[i]
            let length = Geo.distance(a, b)
            guard length > 0 else { continue }
            var d = spacing - carried
            while d <= length {
                let t = d / length
                result.append(GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                                       a.longitude + (b.longitude - a.longitude) * t))
                d += spacing
            }
            carried = length - (d - spacing)
        }
        if let last = polyline.last, result.last != last { result.append(last) }
        return result
    }

    /// Share (0…1) of the sampled points of `a` that lie within `tolerance` metres of polyline `b`.
    /// Uses a local metric grid over densely sampled `b`, so it is fast for long routes.
    public static func overlap(_ a: [GeoPoint], _ b: [GeoPoint], spacing: Double = defaultSpacing,
                               tolerance: Double = defaultTolerance) -> Double {
        let sa = samples(a, spacing: spacing)
        guard !sa.isEmpty, b.count >= 2 else { return 0 }
        // Dense samples of b (≤ tolerance / 3 apart) approximate the line within a few metres.
        let step = max(2, tolerance / 3)
        let sb = samples(b, spacing: step)
        let origin = sb[0]
        let metersPerDegLat = Geo.earthRadius * .pi / 180
        let metersPerDegLon = metersPerDegLat * max(0.01, cos(origin.latitude * .pi / 180))
        func local(_ p: GeoPoint) -> (x: Double, y: Double) {
            ((p.longitude - origin.longitude) * metersPerDegLon, (p.latitude - origin.latitude) * metersPerDegLat)
        }
        let cell = tolerance
        struct Key: Hashable { let x: Int; let y: Int }
        var grid: [Key: [(Double, Double)]] = [:]
        for p in sb {
            let l = local(p)
            grid[Key(x: Int(floor(l.x / cell)), y: Int(floor(l.y / cell))), default: []].append(l)
        }
        let limit = tolerance + step / 2
        let limitSquared = limit * limit
        var hits = 0
        for p in sa {
            let l = local(p)
            let cx = Int(floor(l.x / cell)), cy = Int(floor(l.y / cell))
            var found = false
            outer: for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = grid[Key(x: cx + dx, y: cy + dy)] else { continue }
                    for q in bucket {
                        let ex = q.0 - l.x, ey = q.1 - l.y
                        if ex * ex + ey * ey <= limitSquared { found = true; break outer }
                    }
                }
            }
            if found { hits += 1 }
        }
        return Double(hits) / Double(sa.count)
    }

    /// Symmetric similarity: min(overlap(a, b), overlap(b, a)).
    public static func similarity(_ a: [GeoPoint], _ b: [GeoPoint], tolerance: Double = defaultTolerance) -> Double {
        min(overlap(a, b, tolerance: tolerance), overlap(b, a, tolerance: tolerance))
    }

    /// Merges candidates from all engines: ranks them by expected travel time, folds near-identical routes
    /// (similarity ≥ `threshold`) into the faster one (recording the other engines' estimates) and returns the
    /// distinct choices, fastest first.
    public static func merge(_ routes: [NavRoute], threshold: Double = defaultOverlapThreshold,
                             tolerance: Double = defaultTolerance) -> [RouteChoice] {
        let ranked = routes
            .filter { $0.polyline.count >= 2 }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.expectedTravelTime != rhs.element.expectedTravelTime {
                    return lhs.element.expectedTravelTime < rhs.element.expectedTravelTime
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        var choices: [RouteChoice] = []
        for route in ranked {
            if let index = choices.firstIndex(where: {
                // Cheap pre-check on length before the geometric test.
                let d1 = $0.route.distance, d2 = route.distance
                guard max(d1, d2) > 0, abs(d1 - d2) / max(d1, d2) < 0.2 else { return false }
                return similarity($0.route.polyline, route.polyline, tolerance: tolerance) >= threshold
            }) {
                choices[index].duplicates.append(RouteEstimate(source: route.source,
                                                               expectedTravelTime: route.expectedTravelTime,
                                                               distance: route.distance))
            } else {
                choices.append(RouteChoice(route: route))
            }
        }
        return choices
    }

    /// Facts for the comparison card. `edges` are Valhalla trace attributes of this route (may be empty).
    public static func facts(for route: NavRoute, edges: [RouteEdgeAttributes], signalCount: Int? = nil) -> RouteFacts {
        let average = route.expectedTravelTime > 0 ? route.distance / route.expectedTravelTime * 3.6 : nil
        var signals = signalCount
        var maxLimit: Int?
        var avgLimit: Double?
        var coverage: Double?
        var primaryShare: Double?
        var unpavedShare: Double?
        var tunnels = 0, bridges = 0
        var tolls = route.hasTolls
        if !edges.isEmpty {
            let total = edges.reduce(0) { $0 + $1.length }
            var limitLength = 0.0, limitSum = 0.0, primary = 0.0, unpaved = 0.0
            var previousTunnel = false, previousBridge = false
            for e in edges {
                if let limit = e.speedLimitKmh {
                    limitLength += e.length
                    limitSum += Double(limit) * e.length
                    maxLimit = max(maxLimit ?? 0, limit)
                }
                if e.isPrimaryRoad { primary += e.length }
                if ["compacted", "dirt", "gravel", "path", "impassable"].contains(e.surface ?? "") { unpaved += e.length }
                if e.isTunnel && !previousTunnel { tunnels += 1 }
                if e.isBridge && !previousBridge { bridges += 1 }
                if e.isToll { tolls = true }
                previousTunnel = e.isTunnel
                previousBridge = e.isBridge
            }
            if limitLength > 0 { avgLimit = limitSum / limitLength }
            if total > 0 {
                coverage = limitLength / total
                primaryShare = primary / total
                unpavedShare = unpaved / total
            }
            signals = Valhalla.signalDistances(in: edges).count
        }
        let maneuvers = route.steps.enumerated().filter { index, step in
            index > 0 && !step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && step.resolvedManeuver != .arrive
        }.count
        return RouteFacts(distance: route.distance, expectedTravelTime: route.expectedTravelTime,
                          averageSpeedKmh: average, signalCount: signals, maxSpeedLimitKmh: maxLimit,
                          averageSpeedLimitKmh: avgLimit, speedLimitCoverage: coverage,
                          primaryRoadShare: primaryShare, unpavedShare: unpavedShare,
                          hasTolls: tolls, hasHighways: route.hasHighways, maneuverCount: maneuvers,
                          tunnelCount: tunnels, bridgeCount: bridges)
    }

    /// "+4 мин", "+30 с", nil for the fastest (or when not slower).
    public static func delayText(_ seconds: Double, comparedTo fastest: Double) -> String? {
        let delta = seconds - fastest
        guard delta >= 30 else { return nil }
        return "+" + RVFormat.duration(delta)
    }

    /// Russian notes explaining the comparison (differences between engines, duplicates, time spread).
    public static func notes(for choices: [RouteChoice]) -> [String] {
        guard !choices.isEmpty else { return [] }
        var notes: [String] = []
        let allSources = Set(choices.flatMap(\.sources))
        if allSources.contains(.apple) && allSources.count > 1 {
            notes.append("Время Apple может учитывать пробки (где у Apple есть данные), время Valhalla и OSRM — "
                         + "по типичным скоростям OpenStreetMap, без пробок.")
        } else if !allSources.contains(.apple) {
            notes.append("Время рассчитано по типичным скоростям OpenStreetMap, без учёта пробок (≈ оценка).")
        }
        if choices.count >= 2 {
            let gap = choices[1].route.expectedTravelTime - choices[0].route.expectedTravelTime
            if gap >= 60 {
                notes.append("Самый быстрый вариант выигрывает ≈ \(RVFormat.duration(gap)) у следующего (оценка).")
            } else {
                notes.append("Первые варианты почти равны по времени (разница < 1 мин) — выбирайте по удобству.")
            }
        }
        for choice in choices {
            let range = choice.timeRange
            if !choice.duplicates.isEmpty, range.max - range.min >= 120 {
                let names = choice.sources.map(\.badge).joined(separator: ", ")
                notes.append("Маршрут «\(choice.route.name)» нашли \(names); оценки времени расходятся: "
                             + "\(RVFormat.duration(range.min))–\(RVFormat.duration(range.max)).")
            }
        }
        return notes
    }
}
