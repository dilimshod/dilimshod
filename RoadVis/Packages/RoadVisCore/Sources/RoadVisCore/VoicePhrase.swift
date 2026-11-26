import Foundation

// Structured spoken phrases for pre-recorded voice clips (natural neural voices generated once on a Mac by
// `tools/generate_voice_clips.py` and bundled as `<lang>_<clip id>.m4a`).
//
// A `VoicePhrase` is language-independent: a list of elements (fixed phrase ids, a distance before an action, a
// quantity of metres, a speed). `VoiceComposer` turns it into the clip ids of one language with the right grammar
// ("300 metrdan keyin" = n_300 + after_meters; "через 300 метров" = through + n_300 + meters; "In 300 metres" =
// in + n_300 + meters). Only round values are recorded, so distances are rounded to `VoiceDistance` steps.
// When a phrase cannot be expressed with clips (value outside the recorded set, unknown maneuver) the composer
// returns nil and the app speaks `VoicePhrase.text` (or the composed text) with the system voice instead.
// `VoiceClipCatalog` holds every clip id with its text per language; `tools/voice_phrases.json` is exported from it
// (see `VoiceClipCatalog.manifestJSON()` and VoicePhraseTests).

/// One piece of a composed utterance: a recorded clip or a short pause (punctuation in the text fallback).
public enum VoiceSegment: Hashable, Sendable {
    case clip(String)
    case pause
}

/// A spoken utterance as a sequence of language-independent elements, plus an optional already-localized text for
/// the system voice (it may contain details that are not recorded, such as street names).
public struct VoicePhrase: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        /// A fixed phrase, e.g. "turn_right", "be_careful".
        case clip(String)
        /// Distance before the following action: "300 metrdan keyin" / "через 300 метров" / "In 300 metres".
        case distance(Double)
        /// A quantity of metres: "25 metr" / "25 метров" / "25 metres".
        case meters(Int)
        /// A speed after "speed_limit" / "speeding": "soatiga 60 kilometr" / "60 километров в час" / "60 kilometres per hour".
        case speed(Int)
        /// Sentence / clause break (comma or full stop in the text fallback, nothing between clips).
        case pause
    }

    public var elements: [Element]
    /// Localized text for the system voice; nil → the text composed from the clip texts.
    public var text: String?

    public init(_ elements: [Element], text: String? = nil) {
        self.elements = elements
        self.text = text
    }

    public static func fixed(_ id: String, text: String? = nil) -> VoicePhrase {
        VoicePhrase([.clip(id)], text: text)
    }

    /// The same phrase with another fallback text.
    public func withText(_ text: String?) -> VoicePhrase {
        var copy = self
        copy.text = text
        return copy
    }
}

// MARK: - Distances

/// A distance rounded to a recorded value: 50…900 m or 1, 1.5, 2, 2.5, 3…10 km.
public enum VoiceDistance: Hashable, Sendable {
    case meters(Int)
    /// Kilometres in tenths (15 = 1.5 km).
    case kilometers(tenths: Int)

    public static let meterSteps = [50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 800, 900]
    public static let kilometerTenths = [10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100]

    /// Value in metres.
    public var meters: Double {
        switch self {
        case .meters(let m): return Double(m)
        case .kilometers(let tenths): return Double(tenths) * 100
        }
    }

    /// Nearest recorded distance (287 m → 300 m, 960 m → 1 km, 1.3 km → 1.5 km); nil for ≤ 0, non-finite or > 10.5 km.
    public static func rounded(_ meters: Double) -> VoiceDistance? {
        guard meters.isFinite, meters > 0, meters <= 10_500 else { return nil }
        let candidates: [VoiceDistance] = meterSteps.map { .meters($0) } + kilometerTenths.map { .kilometers(tenths: $0) }
        return candidates.min { abs($0.meters - meters) < abs($1.meters - meters) }
    }

    /// Clip id of the number: "n_300", "n_2", "n_1_5".
    public var numberID: String {
        switch self {
        case .meters(let m): return VoiceComposer.numberID(m)
        case .kilometers(let tenths):
            return tenths % 10 == 0 ? VoiceComposer.numberID(tenths / 10) : "n_\(tenths / 10)_\(tenths % 10)"
        }
    }
}

// MARK: - Composition

public enum VoiceComposer {
    /// "n_300".
    public static func numberID(_ n: Int) -> String { "n_\(n)" }

    /// Speeds that are recorded (5…130 km/h in steps of 5).
    public static func isRecordedSpeed(_ kmh: Int) -> Bool { kmh >= 5 && kmh <= 130 && kmh % 5 == 0 }

    /// Clip segments of `phrase` in `language`; nil when some element has no recording.
    public static func segments(for phrase: VoicePhrase, language: RVLang) -> [VoiceSegment]? {
        var result: [VoiceSegment] = []
        for element in phrase.elements {
            switch element {
            case .clip(let id):
                guard VoiceClipCatalog.text(id, language) != nil else { return nil }
                result.append(.clip(id))
            case .pause:
                if !result.isEmpty, result.last != .pause { result.append(.pause) }
            case .distance(let meters):
                guard let ids = distanceIDs(meters, language: language) else { return nil }
                result += ids.map { .clip($0) }
            case .meters(let n):
                guard let ids = meterIDs(n, language: language) else { return nil }
                result += ids.map { .clip($0) }
            case .speed(let kmh):
                guard isRecordedSpeed(kmh) else { return nil }
                result += [.clip(numberID(kmh)), .clip(language == .uz ? "km" : "kmh")]
            }
        }
        while result.last == .pause { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// Only the clip ids (pauses dropped), in playback order; nil when some element has no recording.
    public static func clipIDs(for phrase: VoicePhrase, language: RVLang) -> [String]? {
        segments(for: phrase, language: language)?.compactMap {
            if case .clip(let id) = $0 { return id }
            return nil
        }
    }

    /// Bundle resource names ("uz_turn_right") of the clips, nil when not expressible.
    public static func resourceNames(for phrase: VoicePhrase, language: RVLang) -> [String]? {
        clipIDs(for: phrase, language: language)?.map { VoiceClipCatalog.resourceName($0, language) }
    }

    /// Text for the system voice: `phrase.text` if set, otherwise the clip texts joined into a sentence.
    public static func text(for phrase: VoicePhrase, language: RVLang) -> String {
        if let text = phrase.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return composedText(for: phrase, language: language) ?? ""
    }

    /// The clip texts joined into one sentence ("300 metrdan keyin o‘ngga buriling, ehtiyot bo‘ling").
    public static func composedText(for phrase: VoicePhrase, language: RVLang) -> String? {
        guard let segments = segments(for: phrase, language: language) else { return nil }
        var text = ""
        for segment in segments {
            switch segment {
            case .pause:
                text += ","
            case .clip(let id):
                guard let part = VoiceClipCatalog.text(id, language) else { return nil }
                text += text.isEmpty ? part : " " + lowercasingFirst(part)
            }
        }
        return capitalizingFirst(text)
    }

    /// "300 metrdan keyin" → ["n_300", "after_meters"], "через 1,5 км" → ["through", "n_1_5", "km_few"].
    public static func distanceIDs(_ meters: Double, language: RVLang) -> [String]? {
        guard let distance = VoiceDistance.rounded(meters) else { return nil }
        let number = distance.numberID
        switch (language, distance) {
        case (.uz, .meters): return [number, "after_meters"]
        case (.uz, .kilometers): return [number, "after_km"]
        case (.ru, .meters(let m)): return ["through", number, russianPlural(m, "meter_one", "meter_few", "meters")]
        case (.ru, .kilometers(let tenths)):
            // A fractional number takes the genitive singular: "полтора километра", "два с половиной километра".
            let unit = tenths % 10 == 0 ? russianPlural(tenths / 10, "km_one", "km_few", "km") : "km_few"
            return ["through", number, unit]
        case (.en, .meters(let m)): return ["in", number, m == 1 ? "meter_one" : "meters"]
        case (.en, .kilometers(let tenths)): return ["in", number, tenths == 10 ? "km_one" : "km"]
        }
    }

    /// "25 metr" / "25 метров" / "25 metres"; the number is rounded to a recorded one (multiples of 5 up to 130,
    /// then the distance steps up to 900). nil for ≤ 0 or > 900.
    public static func meterIDs(_ n: Int, language: RVLang) -> [String]? {
        guard n > 0, n <= 950 else { return nil }
        let value: Int
        if n <= 130 {
            value = max(5, Int((Double(n) / 5).rounded()) * 5)
        } else {
            value = VoiceDistance.meterSteps.min { abs($0 - n) < abs($1 - n) } ?? n
        }
        switch language {
        case .uz: return [numberID(value), "meters"]
        case .ru: return [numberID(value), russianPlural(value, "meter_one", "meter_few", "meters")]
        case .en: return [numberID(value), value == 1 ? "meter_one" : "meters"]
        }
    }

    static func russianPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        RVFormat.plural(n, one, few, many)
    }

    static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        // Keep acronyms ("STOP", "YTH") as they are.
        let second = s.dropFirst().first
        if let second, second.isUppercase { return s }
        return first.lowercased() + s.dropFirst()
    }

    static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Roundabout exit number (1…8) mentioned in an instruction: digits ("2-chiqish", "2-й съезд", "2nd exit") or an
    /// ordinal word (Russian / English / Uzbek). nil when none is found.
    public static func roundaboutExit(in instruction: String) -> Int? {
        let s = instruction.lowercased()
        var digits = ""
        for ch in s {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        if let n = Int(digits), (1...8).contains(n) { return n }
        let words: [(Int, [String])] = [
            (1, ["перв", "first", "birinchi"]), (2, ["втор", "second", "ikkinchi"]),
            (3, ["трет", "third", "uchinchi"]), (4, ["четв", "fourth", "to‘rtinchi", "to'rtinchi"]),
            (5, ["пят", "fifth", "beshinchi"]), (6, ["шест", "sixth", "oltinchi"]),
            (7, ["седьм", "seventh", "yettinchi"]), (8, ["восьм", "eighth", "sakkizinchi"]),
        ]
        // "пят" also matches "пятиэтажный"; only look at ordinal words before "съезд" / "exit" / "chiqish".
        for (n, stems) in words {
            for stem in stems {
                if let range = s.range(of: stem) {
                    let tail = s[range.upperBound...]
                    if tail.contains("съезд") || tail.contains("выезд") || tail.contains("exit") || tail.contains("chiqish") {
                        return n
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Phrase builders

extension VoicePhrase {
    /// Clip id of a maneuver; nil for `.unknown` (spoken with the system voice).
    public static func maneuverClipID(_ type: ManeuverType, roundaboutExit: Int? = nil) -> String? {
        switch type {
        case .depart, .straight: return "go_straight"
        case .left: return "turn_left"
        case .right: return "turn_right"
        case .slightLeft: return "bear_left"
        case .slightRight: return "bear_right"
        case .sharpLeft: return "sharp_left"
        case .sharpRight: return "sharp_right"
        case .keepLeft: return "keep_left"
        case .keepRight: return "keep_right"
        case .exitLeft: return "exit_left"
        case .exitRight: return "exit_right"
        case .uTurn: return "uturn"
        case .merge: return "merge"
        case .arrive: return "arrive_ahead"
        case .roundabout:
            if let exit = roundaboutExit, (1...8).contains(exit) { return "roundabout_exit_\(exit)" }
            return "roundabout_enter"
        case .unknown: return nil
        }
    }

    /// Turn prompt: [distance] maneuver [, be careful] [, slow down]. Street names are not recorded (shown on screen).
    /// An unknown maneuver gives a phrase with a missing clip, so the fallback `text` is spoken.
    public static func maneuver(_ type: ManeuverType, distance: Double?, roundaboutExit: Int? = nil,
                                caution: Bool = false, slowDown: Bool = false, text: String? = nil) -> VoicePhrase {
        var elements: [Element] = []
        if let distance { elements.append(.distance(distance)) }
        elements.append(.clip(maneuverClipID(type, roundaboutExit: roundaboutExit) ?? "maneuver_unknown"))
        if caution { elements += [.pause, .clip("be_careful")] }
        if slowDown { elements += [.pause, .clip("slow_down")] }
        return VoicePhrase(elements, text: text)
    }

    /// Navigator alert for an OSM feature ahead; nil for kinds that are not announced.
    public static func hazardClipID(_ kind: RouteFeatureKind) -> String? {
        switch kind {
        case .speedCamera: return "speed_camera_ahead"
        case .school: return "school_ahead"
        case .kindergarten: return "kindergarten_ahead"
        case .railwayCrossing: return "railway_ahead"
        case .pedestrianCrossing: return "crossing_ahead"
        case .construction: return "construction_ahead"
        case .trafficCalming: return "bump_ahead"
        case .trafficSignals: return "traffic_light_ahead"
        case .stopSign: return "stop_sign_ahead"
        case .giveWay, .fuel, .parking: return nil
        }
    }

    public static func hazard(_ kind: RouteFeatureKind, text: String? = nil) -> VoicePhrase {
        VoicePhrase([.clip(hazardClipID(kind) ?? "hazard_unknown")], text: text)
    }

    /// Short name of a road feature for "in 300 m, <sign>" ("sign_traffic_signals").
    public static func signClipID(_ kind: RouteFeatureKind) -> String {
        "sign_" + VoiceClipCatalog.snakeCase(kind.rawValue)
    }

    /// "Oldinda tirbandlik, 600 metrdan keyin".
    /// The user's own camera mark reuses the OSM camera clip ("Speed camera ahead").
    public static func incident(_ kind: RoadIncidentKind, distance: Double?, text: String? = nil) -> VoicePhrase {
        let clip = kind == .speedCamera ? "speed_camera_ahead" : "incident_" + VoiceClipCatalog.snakeCase(kind.rawValue)
        var elements: [Element] = [.clip(clip)]
        if let distance { elements += [.pause, .distance(distance)] }
        return VoicePhrase(elements, text: text)
    }

    /// The spoken form of a coach message.
    public static func coach(_ message: CoachMessage, text: String? = nil) -> VoicePhrase {
        let elements: [Element]
        switch message {
        case .collisionRisk: elements = [.clip("collision_warning")]
        case .pedestrianDanger: elements = [.clip("pedestrian_yield")]
        case .pedestrianCaution: elements = [.clip("pedestrian_caution")]
        case .redLightAhead: elements = [.clip("red_light_ahead")]
        case .laneDeparture(let side): elements = [.clip(side == .left ? "lane_left" : "lane_right")]
        case .keepDistance(let meters):
            if let meters, meters > 0 {
                elements = [.clip("keep_distance_at_least"), .meters(meters)]
            } else {
                elements = [.clip("keep_distance")]
            }
        case let .roadSign(kind, distance):
            elements = [.distance(Double(distance)), .clip(signClipID(kind))]
        case .speedLimit(let kmh): elements = [.clip("speed_limit"), .speed(kmh)]
        case let .speedLimitAhead(kmh, distance):
            elements = [.distance(Double(distance)), .clip("speed_limit"), .speed(kmh)]
        case .stopSignAhead: elements = [.clip("stop_sign_ahead")]
        case .overSpeedLimit(let limit): elements = [.clip("speeding"), .speed(limit)]
        case .greenLightGo: elements = [.clip("green_go")]
        case .trafficOfficerAhead: elements = [.clip("traffic_officer_ahead")]
        case .roadWorkersAhead: elements = [.clip("road_workers_ahead")]
        }
        return VoicePhrase(elements, text: text)
    }

    /// The Settings → Language test phrase: "300 metrdan keyin o‘ngga buriling. Oldinda svetofor."
    public static func sample(text: String? = nil) -> VoicePhrase {
        VoicePhrase([.distance(300), .clip("turn_right"), .pause, .clip("traffic_light_ahead")], text: text)
    }
}
