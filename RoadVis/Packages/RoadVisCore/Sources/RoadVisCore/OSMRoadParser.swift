import Foundation

/// Parses OSM `maxspeed` values into km/h.
public enum MaxSpeedParser {
    /// Implicit limits for zone codes (`maxspeed=RU:urban` etc.), km/h.
    /// Only countries whose defaults are known with certainty are listed; unknown zones yield nil.
    public static let zoneDefaults: [String: Int] = [
        "RU:urban": 60, "RU:rural": 90, "RU:living_street": 20, "RU:motorway": 110,
        "UZ:urban": 70, "UZ:rural": 100, "UZ:living_street": 30, "UZ:motorway": 110,
    ]

    /// Parses a single `maxspeed` value.
    ///
    /// Supported forms: `"60"` (km/h), `"60 km/h"`, `"50 mph"`, `"10 knots"`, zone codes (`"RU:urban"`, `"UZ:rural"`,
    /// `"RU:zone30"`), `"walk"` (5 km/h, implicit) and multiple values `"60;40"` (the lowest is used, conservative).
    /// Returns nil for `"none"` (no posted limit), `"signals"`/`"variable"` (electronic signs) and anything unparseable.
    public static func parse(_ value: String?) -> SpeedLimit? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.contains(";") {
            let parts = raw.split(separator: ";").compactMap { parseSingle(String($0), raw: raw) }
            return parts.min { $0.kmh < $1.kmh }
        }
        return parseSingle(raw, raw: raw)
    }

    /// Speed limit for the travel direction: `maxspeed:forward` / `maxspeed:backward` first, then `maxspeed`,
    /// then zone hints without an explicit number (`maxspeed:type`, `source:maxspeed`, `zone:maxspeed`) as implicit limits.
    public static func limit(tags: [String: String], travelingForward: Bool) -> SpeedLimit? {
        let directional = travelingForward ? tags["maxspeed:forward"] : tags["maxspeed:backward"]
        if let d = parse(directional) { return d }
        if let m = parse(tags["maxspeed"]) { return m }
        for key in ["maxspeed:type", "source:maxspeed", "zone:maxspeed"] {
            if let value = tags[key], value.contains(":"), let zone = parse(value), zone.isImplicit {
                return zone
            }
        }
        return nil
    }

    private static func parseSingle(_ value: String, raw: String) -> SpeedLimit? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = v.lowercased()
        switch lower {
        case "", "none", "signals", "variable", "unknown", "no", "implicit": return nil
        case "walk": return SpeedLimit(kmh: 5, raw: raw, isImplicit: true)
        default: break
        }

        // Zone code: "RU:urban", "UZ:living_street", "RU:zone30", "DE:zone:30".
        if let colon = v.firstIndex(of: ":"), v[v.startIndex..<colon].count == 2,
           v[v.startIndex..<colon].allSatisfy({ $0.isLetter }) {
            let country = v[v.startIndex..<colon].uppercased()
            let zone = v[v.index(after: colon)...].lowercased()
            if let kmh = zoneDefaults["\(country):\(zone)"] {
                return SpeedLimit(kmh: kmh, raw: raw, isImplicit: true)
            }
            if zone.hasPrefix("zone") {
                let digits = zone.dropFirst(4).filter { $0.isNumber }
                if let n = Int(digits), (5...200).contains(n) {
                    return SpeedLimit(kmh: n, raw: raw, isImplicit: true)
                }
            }
            return nil
        }

        // Number with an optional unit.
        var numberPart = ""
        var rest = Substring(lower)
        while let ch = rest.first, ch.isNumber || ch == "." || ch == "," {
            numberPart.append(ch == "," ? "." : ch)
            rest = rest.dropFirst()
        }
        guard let number = Double(numberPart), number > 0 else { return nil }
        let unit = rest.trimmingCharacters(in: .whitespaces)
        let kmh: Double
        switch unit {
        case "", "km/h", "kmh", "kph", "км/ч": kmh = number
        case "mph": kmh = number * 1.609344
        case "knots", "knot", "kn": kmh = number * 1.852
        default: return nil
        }
        let rounded = Int(kmh.rounded())
        guard (1...300).contains(rounded) else { return nil }
        return SpeedLimit(kmh: rounded, raw: raw, isImplicit: false)
    }
}

/// Interprets OSM road tags: one-way direction, lane counts, turn lanes and Russian road class names.
public enum OSMRoadParser {
    /// Parses `turn:lanes` (`"left|through;right|right"`) into lanes ordered left → right as seen by the driver.
    /// Empty lane entries and `none` become `[.none]`; `slide_left/right` are treated as slight turns;
    /// unknown values are ignored (a lane with only unknown values has empty `turns` = unknown).
    public static func parseTurnLanes(_ value: String) -> [Lane] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map { laneValue in
            let tokens = laneValue.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            var turns: [LaneTurn] = []
            var hasUnknown = false
            for token in tokens {
                let turn: LaneTurn?
                switch token {
                case "", "none": turn = LaneTurn.none
                case "slide_left": turn = .slightLeft
                case "slide_right": turn = .slightRight
                default: turn = LaneTurn(rawValue: token)
                }
                if let turn {
                    if !turns.contains(turn) { turns.append(turn) }
                } else {
                    hasUnknown = true
                }
            }
            if turns.count > 1 { turns.removeAll { $0 == .none } }
            if turns.isEmpty && !hasUnknown { turns = [.none] }
            return Lane(turns: turns)
        }
    }

    /// One-way direction relative to the way's drawing direction:
    /// `1` = traffic only along the drawing direction, `-1` = only against it, `0` = both directions
    /// (also for `reversible` / `alternating`, whose direction changes over time).
    /// `highway=motorway`, `highway=motorway_link` and `junction=roundabout|circular` imply one-way unless tagged otherwise.
    public static func onewayDirection(tags: [String: String]) -> Int {
        let explicit = tags["oneway:motor_vehicle"] ?? tags["oneway:vehicle"] ?? tags["oneway"]
        if let value = explicit?.trimmingCharacters(in: .whitespaces).lowercased() {
            switch value {
            case "yes", "true", "1": return 1
            case "-1", "reverse": return -1
            case "no", "false", "0", "reversible", "alternating": return 0
            default: break
            }
        }
        let junction = tags["junction"]?.lowercased()
        if junction == "roundabout" || junction == "circular" { return 1 }
        let highway = tags["highway"]?.lowercased()
        if highway == "motorway" || highway == "motorway_link" { return 1 }
        return 0
    }

    /// Lane information for the user's travel direction.
    ///
    /// - Uses `lanes`, `lanes:forward` / `lanes:backward`, `lanes:both_ways` (shared centre turn lane, counted in the
    ///   total but in neither direction) and `turn:lanes`, `turn:lanes:forward` / `turn:lanes:backward`.
    /// - Missing direction split on a two-way road: the remainder after the known direction, else an even split;
    ///   an odd total without a split leaves the per-direction counts nil (except a single shared lane: 1 / 1).
    /// - Missing `lanes`: counts are derived from `turn:lanes*` lengths; if nothing is mapped the count comes from
    ///   the road class (`defaultLaneCount`) and `isEstimated` is true.
    /// - One-way roads: `lanesInDirection = lanes`, `lanesOpposite = 0`. When travelling against a one-way road
    ///   (wrong match or wrong-way driving) the road's lane count is still returned, without turn arrows.
    public static func laneInfo(tags: [String: String], travelingForward: Bool) -> LaneInfo {
        let direction = onewayDirection(tags: tags)
        let highway = tags["highway"]?.lowercased() ?? ""
        let total = count(tags["lanes"])
        let forward = count(tags["lanes:forward"])
        let backward = count(tags["lanes:backward"])
        let centre = count(tags["lanes:both_ways"]) ?? 0
        let turnLanes = tags["turn:lanes"].map(parseTurnLanes) ?? []
        let turnForward = tags["turn:lanes:forward"].map(parseTurnLanes) ?? []
        let turnBackward = tags["turn:lanes:backward"].map(parseTurnLanes) ?? []

        if direction != 0 {
            let allowedForward = direction == 1
            let directionalCount = allowedForward ? forward : backward
            let directionalTurns = turnLanes.isEmpty ? (allowedForward ? turnForward : turnBackward) : turnLanes
            var estimated = false
            var lanesCount = total ?? directionalCount ?? (directionalTurns.isEmpty ? nil : directionalTurns.count)
            if lanesCount == nil, let fallback = defaultLaneCount(highway: highway, oneway: true) {
                lanesCount = fallback
                estimated = true
            }
            let withTraffic = travelingForward == allowedForward
            return LaneInfo(totalLanes: lanesCount, lanesInDirection: lanesCount, lanesOpposite: lanesCount == nil ? nil : 0,
                            lanes: withTraffic ? directionalTurns : [], isOneway: true, isEstimated: estimated)
        }

        // Two-way road.
        var fwd = forward
        var bwd = backward
        var estimated = false
        var totalLanes = total

        if fwd == nil, let n = turnForward.isEmpty ? nil : turnForward.count { fwd = n }
        if bwd == nil, let n = turnBackward.isEmpty ? nil : turnBackward.count { bwd = n }

        if let t = totalLanes {
            if let f = fwd, bwd == nil, t - f - centre > 0 { bwd = t - f - centre }
            if let b = bwd, fwd == nil, t - b - centre > 0 { fwd = t - b - centre }
            if fwd == nil && bwd == nil {
                let remainder = t - centre
                if remainder == 1 {
                    // A single lane shared by both directions (narrow street).
                    fwd = 1
                    bwd = 1
                } else if remainder > 0 && remainder % 2 == 0 {
                    fwd = remainder / 2
                    bwd = remainder / 2
                }
            }
        } else if let f = fwd, let b = bwd {
            totalLanes = f + b + centre
        } else if fwd == nil && bwd == nil, let fallback = defaultLaneCount(highway: highway, oneway: false) {
            estimated = true
            totalLanes = fallback
            if fallback == 1 {
                fwd = 1
                bwd = 1
            } else {
                fwd = fallback / 2
                bwd = fallback - fallback / 2
            }
        }

        let ourLanes = travelingForward ? turnForward : turnBackward
        var inDirection = travelingForward ? fwd : bwd
        let opposite = travelingForward ? bwd : fwd
        if inDirection == nil && !ourLanes.isEmpty { inDirection = ourLanes.count }
        return LaneInfo(totalLanes: totalLanes, lanesInDirection: inDirection, lanesOpposite: opposite,
                        lanes: ourLanes, isOneway: false, isEstimated: estimated)
    }

    /// Typical lane count when `lanes` is not mapped: lanes in the one direction for one-way roads,
    /// both directions together otherwise. nil for unknown / non-drivable classes.
    public static func defaultLaneCount(highway: String, oneway: Bool) -> Int? {
        switch highway.lowercased() {
        case "motorway", "trunk":
            return 2   // usually separate one-way carriageways with 2 lanes each
        case "primary", "secondary", "tertiary", "residential":
            return oneway ? 1 : 2
        case "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link":
            return oneway ? 1 : 2
        case "living_street", "unclassified", "service", "track":
            return 1
        default:
            return nil
        }
    }

    /// Russian name of a road class (`highway=*`), used when a road has no name or ref.
    public static func highwayDisplayName(_ highway: String) -> String {
        switch highway.lowercased() {
        case "motorway": return "Автомагистраль"
        case "trunk": return "Магистраль"
        case "primary": return "Главная дорога"
        case "secondary": return "Дорога районного значения"
        case "tertiary": return "Улица местного значения"
        case "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link": return "Съезд"
        case "residential": return "Жилая улица"
        case "living_street": return "Жилая зона"
        case "service": return "Проезд"
        case "unclassified": return "Местная дорога"
        case "track": return "Грунтовая дорога"
        case "road": return "Дорога"
        case "busway", "bus_guideway": return "Выделенная дорога для автобусов"
        case "escape": return "Аварийный съезд"
        case "raceway": return "Гоночная трасса"
        case "pedestrian": return "Пешеходная улица"
        case "footway": return "Пешеходная дорожка"
        case "path": return "Тропа"
        case "cycleway": return "Велодорожка"
        case "steps": return "Лестница"
        case "bridleway": return "Конная тропа"
        case "construction": return "Строящаяся дорога"
        case "proposed": return "Проектируемая дорога"
        default: return "Дорога"
        }
    }

    /// Road class rank used for tie-breaking (0 = most important). Unknown classes rank last.
    public static func roadClassRank(_ highway: String) -> Int {
        switch highway.lowercased() {
        case "motorway": return 0
        case "trunk": return 1
        case "primary": return 2
        case "secondary": return 3
        case "tertiary": return 4
        case "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link": return 5
        case "unclassified", "residential": return 6
        case "living_street": return 7
        case "service", "road", "busway": return 8
        case "track": return 9
        default: return 10
        }
    }

    /// First positive integer in a lane-count tag ("2", "2;3", " 3 ").
    private static func count(_ value: String?) -> Int? {
        guard let value else { return nil }
        let first = value.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let n = Int(first), n > 0, n < 50 else { return nil }
        return n
    }
}
