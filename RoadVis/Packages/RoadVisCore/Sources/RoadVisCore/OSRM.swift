import Foundation

/// Error reported by an OSRM server (`{"code": "NoRoute", "message": "…"}`) or produced while parsing.
public struct OSRMError: Error, CustomStringConvertible, Sendable, Equatable {
    /// OSRM status code ("NoRoute", "NoSegment", "TooBig", "InvalidQuery" …); nil for parse problems.
    public let code: String?
    public let message: String

    public init(code: String?, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    /// Russian explanation for the well-known OSRM codes.
    public var russianDescription: String {
        switch code {
        case "NoRoute": return "OSRM не нашёл маршрут между этими точками."
        case "NoSegment": return "Рядом с точкой старта или назначения нет дорог в OpenStreetMap (OSRM)."
        case "TooBig": return "Запрос слишком большой для сервера OSRM."
        case "InvalidQuery", "InvalidValue", "InvalidOptions", "InvalidUrl", "InvalidService", "InvalidVersion":
            return "Сервер OSRM отклонил запрос (\(code ?? "")): \(message)"
        case nil: return "Ответ OSRM не удалось разобрать: \(message)"
        default: return "Ошибка OSRM (\(code ?? "")): \(message)"
        }
    }
}

/// Request building and response parsing for an OSRM routing server (default: FOSSGIS
/// `https://routing.openstreetmap.de/routed-car` — light use only, ≤ 1 request/s, identifying User-Agent,
/// OSM attribution). OSRM returns no text instructions, so Russian instructions are built here from the maneuver
/// type / modifier / street name.
public enum OSRM {
    public static let defaultEndpoint = "https://routing.openstreetmap.de/routed-car"

    // MARK: Request

    /// `GET {endpoint}/route/v1/driving/{lon},{lat};{lon},{lat}?overview=full&geometries=polyline6&steps=true&alternatives=true&annotations=true`.
    /// Returns nil when the endpoint is not an http(s) URL with a host or a coordinate is invalid.
    public static func routeURL(endpoint: String, from origin: GeoPoint, to destination: GeoPoint,
                                alternatives: Bool = true) -> URL? {
        guard origin.isValid, destination.isValid else { return nil }
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let coordinates = [origin, destination]
            .map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }
            .joined(separator: ";")
        let query = "overview=full&geometries=polyline6&steps=true&alternatives=\(alternatives)&annotations=true"
        guard let url = URL(string: "\(base)/route/v1/driving/\(coordinates)?\(query)"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    // MARK: Response

    /// Parses an OSRM `/route` response into routes (main route first, then alternatives).
    /// - Throws: `OSRMError` for server errors (`code != "Ok"`) and malformed bodies.
    /// `language` selects the instruction text (default Russian; uz / en via `NavInstructionText`).
    public static func parseRoutes(_ data: Data, language: RVLang = .ru) throws -> [NavRoute] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OSRMError(code: nil, message: "ответ не является JSON")
        }
        let code = obj["code"] as? String
        guard code == "Ok" else {
            throw OSRMError(code: code ?? "Unknown", message: (obj["message"] as? String) ?? "неизвестная ошибка")
        }
        guard let routes = obj["routes"] as? [[String: Any]], !routes.isEmpty else {
            throw OSRMError(code: "NoRoute", message: "в ответе нет маршрутов")
        }
        return routes.compactMap { try? parseRoute($0, language: language) }.filter { $0.polyline.count >= 2 }
    }

    static func parseRoute(_ route: [String: Any], language: RVLang = .ru) throws -> NavRoute {
        let polyline = Polyline.decode(route["geometry"] as? String ?? "", precision: 6)
        guard polyline.count >= 2 else { throw OSRMError(code: nil, message: "маршрут без геометрии") }
        let legs = (route["legs"] as? [[String: Any]]) ?? []
        var steps: [RouteStepInfo] = []
        var summaries: [String] = []
        var nameLengths: [String: Double] = [:]
        var nameOrder: [String] = []
        var hasTolls = false
        var hasHighways = false

        for (legIndex, leg) in legs.enumerated() {
            if let summary = (leg["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty, !summaries.contains(summary) {
                summaries.append(summary)
            }
            let rawSteps = (leg["steps"] as? [[String: Any]]) ?? []
            for (stepIndex, step) in rawSteps.enumerated() {
                let maneuver = (step["maneuver"] as? [String: Any]) ?? [:]
                let type = (maneuver["type"] as? String) ?? "turn"
                // Intermediate depart/arrive between legs are not real maneuvers.
                if legIndex > 0, stepIndex == 0, type == "depart" { continue }
                if legIndex < legs.count - 1, type == "arrive" { continue }
                let modifier = maneuver["modifier"] as? String
                let exit = Valhalla.int(maneuver["exit"])
                let name = nonEmpty(step["name"] as? String)
                let ref = nonEmpty(step["ref"] as? String)
                let rotaryName = nonEmpty(step["rotary_name"] as? String)
                let distance = Valhalla.double(step["distance"]) ?? 0
                let intersections = (step["intersections"] as? [[String: Any]]) ?? []
                for intersection in intersections {
                    let classes = (intersection["classes"] as? [String]) ?? []
                    if classes.contains("toll") { hasTolls = true }
                    if classes.contains("motorway") { hasHighways = true }
                }
                let laneData = (intersections.first?["lanes"] as? [[String: Any]]) ?? []
                let (lanes, valid) = lanes(from: laneData.map {
                    OSRMLane(indications: ($0["indications"] as? [String]) ?? [], valid: ($0["valid"] as? Bool) ?? false)
                })
                let street = name ?? ref
                if let street {
                    if nameLengths[street] == nil { nameOrder.append(street) }
                    nameLengths[street, default: 0] += distance
                }
                let text = NavInstructionText.osrm(type: type, modifier: modifier, name: street, exit: exit,
                                                   rotaryName: rotaryName, language: language)
                steps.append(RouteStepInfo(instruction: text, distance: distance, notice: nil,
                                           maneuver: maneuverType(type: type, modifier: modifier),
                                           lanes: lanes, activeLanes: valid,
                                           streetNames: street.map { [$0] } ?? []))
            }
        }
        // As with MKRoute.Step / Valhalla, a step's maneuver happens at its start; step 0 is the departure and is
        // never announced.
        if !steps.isEmpty, steps[0].maneuver == .depart { steps[0].instruction = "" }

        let distance = Valhalla.double(route["distance"]) ?? Geo.polylineLength(polyline)
        let duration = Valhalla.double(route["duration"]) ?? 0
        let name: String
        if !summaries.isEmpty {
            name = summaries.joined(separator: ", ")
        } else {
            let top = nameOrder.sorted { (nameLengths[$0] ?? 0) > (nameLengths[$1] ?? 0) }.prefix(2)
            name = top.isEmpty ? NavInstructionText.fallbackRouteName(engine: "OSRM", language: language) : top.joined(separator: ", ")
        }
        return NavRoute(source: .osrm, name: name, polyline: polyline,
                        distance: distance > 0 ? distance : Geo.polylineLength(polyline),
                        expectedTravelTime: duration, steps: steps,
                        hasTolls: hasTolls, hasHighways: hasHighways, advisories: [])
    }

    // MARK: Maneuvers

    /// OSRM maneuver type + modifier → ManeuverType.
    public static func maneuverType(type: String, modifier: String?) -> ManeuverType {
        let mod = modifier ?? ""
        let leftward = mod.contains("left")
        let rightward = mod.contains("right")
        switch type {
        case "depart": return .depart
        case "arrive": return .arrive
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary": return .roundabout
        case "merge": return .merge
        case "fork": return leftward ? .keepLeft : (rightward ? .keepRight : .straight)
        case "off ramp": return leftward ? .exitLeft : .exitRight
        default: return turnType(modifier: modifier)
        }
    }

    static func turnType(modifier: String?) -> ManeuverType {
        switch modifier {
        case "uturn": return .uTurn
        case "sharp right": return .sharpRight
        case "right": return .right
        case "slight right": return .slightRight
        case "sharp left": return .sharpLeft
        case "left": return .left
        case "slight left": return .slightLeft
        default: return .straight
        }
    }

    /// Russian instruction for an OSRM step, e.g. turn + left + "Навои" → "Поверните налево на Навои",
    /// roundabout with exit 2 → "На круговом движении — 2-й съезд", arrive → "Пункт назначения".
    public static func instruction(type: String, modifier: String?, name: String?, exit: Int? = nil,
                                   rotaryName: String? = nil) -> String {
        let onto = name.map { " на \($0)" } ?? ""
        let along = name.map { " по \($0)" } ?? ""
        switch type {
        case "depart":
            return "Начните движение" + along
        case "arrive":
            switch modifier {
            case "left", "slight left", "sharp left": return "Пункт назначения слева"
            case "right", "slight right", "sharp right": return "Пункт назначения справа"
            default: return "Пункт назначения"
            }
        case "roundabout", "rotary":
            let circle = rotaryName.map { "На круговом движении «\($0)»" } ?? "На круговом движении"
            if let exit, exit > 0 { return "\(circle) — \(exit)-й съезд" + onto }
            return "Въезжайте на круговое движение" + onto
        case "roundabout turn":
            return "На круговом движении " + turnPhrase(modifier: modifier).rvLowercasedFirst() + onto
        case "exit roundabout", "exit rotary":
            return "Съезжайте с кругового движения" + onto
        case "merge":
            switch modifier {
            case "left", "slight left", "sharp left": return "Перестройтесь левее и влейтесь в поток" + onto
            case "right", "slight right", "sharp right": return "Перестройтесь правее и влейтесь в поток" + onto
            default: return "Влейтесь в поток" + onto
            }
        case "on ramp":
            return "Сверните \(directionWord(modifier)) на въезд" + onto
        case "off ramp":
            return "Сверните \(directionWord(modifier)) на съезд" + onto
        case "fork":
            switch modifier {
            case "left", "slight left", "sharp left": return "На развилке держитесь левее" + onto
            case "right", "slight right", "sharp right": return "На развилке держитесь правее" + onto
            default: return "На развилке двигайтесь прямо" + onto
            }
        case "end of road":
            return "В конце дороги " + turnPhrase(modifier: modifier).rvLowercasedFirst() + onto
        case "new name", "continue", "notification":
            if modifier == nil || modifier == "straight" { return "Продолжайте движение" + (name == nil ? " прямо" : along) }
            return turnPhrase(modifier: modifier) + onto
        default:   // "turn" and unknown types
            if modifier == "straight" { return "Двигайтесь прямо" + along }
            return turnPhrase(modifier: modifier) + onto
        }
    }

    static func turnPhrase(modifier: String?) -> String {
        switch modifier {
        case "uturn": return "Развернитесь"
        case "sharp right": return "Резко поверните направо"
        case "right": return "Поверните направо"
        case "slight right": return "Держитесь правее"
        case "sharp left": return "Резко поверните налево"
        case "left": return "Поверните налево"
        case "slight left": return "Держитесь левее"
        default: return "Двигайтесь прямо"
        }
    }

    static func directionWord(_ modifier: String?) -> String {
        guard let modifier else { return "направо" }
        if modifier.contains("left") { return "налево" }
        if modifier == "straight" { return "прямо" }
        return "направо"
    }

    // MARK: Lanes

    public struct OSRMLane: Hashable, Sendable {
        public var indications: [String]
        public var valid: Bool
        public init(indications: [String], valid: Bool) {
            self.indications = indications
            self.valid = valid
        }
    }

    /// OSRM lane indication → LaneTurn.
    public static func laneTurn(_ indication: String) -> LaneTurn {
        switch indication {
        case "uturn": return .reverse
        case "sharp right": return .sharpRight
        case "right": return .right
        case "slight right": return .slightRight
        case "straight": return .through
        case "slight left": return .slightLeft
        case "left": return .left
        case "sharp left": return .sharpLeft
        default: return .none
        }
    }

    /// Lanes (left → right) and whether each is recommended (`valid`).
    public static func lanes(from raw: [OSRMLane]) -> (lanes: [Lane], valid: [Bool]) {
        guard !raw.isEmpty else { return ([], []) }
        let lanes = raw.map { lane -> Lane in
            let turns = lane.indications.map(laneTurn).filter { $0 != .none }
            return Lane(turns: turns)
        }
        return (lanes, raw.map(\.valid))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

extension String {
    func rvLowercasedFirst() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
