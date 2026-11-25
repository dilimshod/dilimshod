import Foundation

// Spoken phrases of the beginner-driver coach (`CoachMessage` → text) in Uzbek (Latin), Russian and English.
// Short, calm, imperative — they are heard while driving. The texts live in the string tables
// (Localization/Strings+uz/ru/en.swift, keys "coach.*").
//
// The language normally comes from the app language (UserDefaults "rv.appLanguage", default "uz"); unknown codes fall
// back to Uzbek. Numbers stay as digits: `SpeechService` / `UzbekSpeechText` spell them for the chosen voice.

/// UserDefaults key of the app language (owned by the localization layer; read here only).
let coachLanguageDefaultsKey = AppLanguage.storageKey

/// Current app language code for coach phrases ("uz", "ru" or "en").
func currentCoachLanguage(_ defaults: UserDefaults = .standard) -> String {
    let code = defaults.string(forKey: coachLanguageDefaultsKey)?.lowercased() ?? "uz"
    return ["uz", "ru", "en"].contains(code) ? code : "uz"
}

/// Localized spoken text of a coach message.
func coachText(_ message: CoachMessage, language: String) -> String {
    let lang = AppLanguage(rawValue: String(language.lowercased().prefix(2))) ?? .uz
    return CoachPhrases.phrase(message, in: lang)
}

enum CoachPhrases {
    static func uzbek(_ m: CoachMessage) -> String { phrase(m, in: .uz) }
    static func russian(_ m: CoachMessage) -> String { phrase(m, in: .ru) }
    static func english(_ m: CoachMessage) -> String { phrase(m, in: .en) }

    /// The spoken text of `m` in `language`.
    static func phrase(_ m: CoachMessage, in language: AppLanguage) -> String {
        func text(_ key: String) -> String { L(key, in: language) }
        func format(_ key: String, _ args: CVarArg...) -> String {
            LocalizationManager.shared.format(key, in: language, args)
        }
        switch m {
        case .collisionRisk:
            return text("coach.collision")
        case .pedestrianDanger:
            return text("coach.pedestrian.danger")
        case .pedestrianCaution:
            return text("coach.pedestrian.caution")
        case .redLightAhead:
            return text("coach.redLight")
        case .laneDeparture(let side):
            return text(side == .left ? "coach.lane.left" : "coach.lane.right")
        case .keepDistance(let meters):
            if let meters, meters > 0 { return format("coach.keepDistance.meters", meterQuantity(meters, language)) }
            return text("coach.keepDistance")
        case let .roadSign(kind, distance):
            return format("coach.roadSign", meterQuantity(distance, language), name(kind, in: language))
        case .speedLimit(let kmh):
            return format("coach.speedLimit", kmh)
        case let .speedLimitAhead(kmh, distance):
            return format("coach.speedLimitAhead", meterQuantity(distance, language), kmh)
        case .stopSignAhead:
            return text("coach.stopSign")
        case .overSpeedLimit(let limit):
            return format("coach.overLimit", limit)
        case .greenLightGo:
            return text("coach.green")
        }
    }

    /// Spoken name of a road feature ("coach.sign.<kind>").
    static func name(_ kind: RouteFeatureKind, in language: AppLanguage) -> String {
        L("coach.sign.\(kind.rawValue)", in: language)
    }

    static func uzbekName(_ kind: RouteFeatureKind) -> String { name(kind, in: .uz) }
    static func russianName(_ kind: RouteFeatureKind) -> String { name(kind, in: .ru) }
    static func englishName(_ kind: RouteFeatureKind) -> String { name(kind, in: .en) }

    /// "300 metr" / "300 метров" / "300 metres" (unit word from `unit.meter.one/few/many`).
    static func meterQuantity(_ n: Int, _ language: AppLanguage) -> String {
        let one = L("unit.meter.one", in: language), few = L("unit.meter.few", in: language)
        let many = L("unit.meter.many", in: language)
        if language == .ru { return "\(n) " + RVFormat.plural(n, one, few, many) }
        return "\(n) " + (n == 1 ? one : many)
    }

    /// Russian form of "metre" for `n` (метр / метра / метров).
    static func russianMeters(_ n: Int) -> String {
        RVFormat.plural(n, L("unit.meter.one", in: .ru), L("unit.meter.few", in: .ru), L("unit.meter.many", in: .ru))
    }
}
