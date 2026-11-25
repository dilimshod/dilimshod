import Foundation

// Spoken phrases of the beginner-driver coach (`CoachMessage` → text) in Uzbek (Latin), Russian and English.
// Short, calm, imperative — they are heard while driving. Foundation only.
//
// The language normally comes from the app language (UserDefaults "rv.appLanguage", default "uz"); unknown codes fall
// back to Uzbek. Numbers stay as digits: `SpeechService` / `UzbekSpeechText` spell them for the chosen voice.

/// UserDefaults key of the app language (owned by the localization layer; read here only).
let coachLanguageDefaultsKey = "rv.appLanguage"

/// Current app language code for coach phrases ("uz", "ru" or "en").
func currentCoachLanguage(_ defaults: UserDefaults = .standard) -> String {
    let code = defaults.string(forKey: coachLanguageDefaultsKey)?.lowercased() ?? "uz"
    return ["uz", "ru", "en"].contains(code) ? code : "uz"
}

/// Localized spoken text of a coach message.
func coachText(_ message: CoachMessage, language: String) -> String {
    switch language.lowercased().prefix(2) {
    case "ru": return CoachPhrases.russian(message)
    case "en": return CoachPhrases.english(message)
    default: return CoachPhrases.uzbek(message)
    }
}

enum CoachPhrases {
    // MARK: Uzbek (Latin)

    static func uzbek(_ m: CoachMessage) -> String {
        switch m {
        case .collisionRisk:
            return "Diqqat! Oldingi mashinaga xavfli yaqinlashyapsiz, tormoz bering!"
        case .redLightAhead:
            return "Oldinda qizil chiroq, tezlikni pasaytiring."
        case .laneDeparture(let side):
            return side == .left ? "Chap chiziqdan chiqib ketyapsiz." : "O‘ng chiziqdan chiqib ketyapsiz."
        case .keepDistance(let meters):
            if let meters, meters > 0 { return "Masofani saqlang, kamida \(meters) metr." }
            return "Masofani saqlang."
        case let .roadSign(kind, distance):
            return "\(distance) metrdan keyin \(uzbekName(kind))."
        case .speedLimit(let kmh):
            return "Tezlik chegarasi soatiga \(kmh) kilometr."
        case let .speedLimitAhead(kmh, distance):
            return "\(distance) metrdan keyin tezlik chegarasi soatiga \(kmh) kilometr."
        case .stopSignAhead:
            return "Oldinda STOP belgisi. To‘liq to‘xtang."
        case .overSpeedLimit(let limit):
            return "Tezlikni kamaytiring, chegara soatiga \(limit) kilometr."
        case .greenLightGo:
            return "Yashil chiroq. Atrofga qarab, harakatlanishingiz mumkin."
        }
    }

    static func uzbekName(_ kind: RouteFeatureKind) -> String {
        switch kind {
        case .speedCamera: return "tezlik kamerasi"
        case .pedestrianCrossing: return "piyodalar o‘tish joyi"
        case .school: return "maktab, bolalarga ehtiyot bo‘ling"
        case .kindergarten: return "bolalar bog‘chasi, ehtiyot bo‘ling"
        case .railwayCrossing: return "temir yo‘l kesishmasi"
        case .stopSign: return "STOP belgisi, to‘liq to‘xtang"
        case .giveWay: return "yo‘l bering belgisi"
        case .trafficCalming: return "sun’iy notekislik"
        case .trafficSignals: return "svetofor"
        case .construction: return "yo‘l ta’mirlash ishlari"
        case .fuel: return "yoqilg‘i quyish shoxobchasi"
        case .parking: return "avtoturargoh"
        }
    }

    // MARK: Russian

    static func russian(_ m: CoachMessage) -> String {
        switch m {
        case .collisionRisk:
            return "Внимание! Опасное сближение, тормозите!"
        case .redLightAhead:
            return "Впереди красный, снижайте скорость."
        case .laneDeparture(let side):
            return side == .left ? "Вы выезжаете за левую разметку." : "Вы выезжаете за правую разметку."
        case .keepDistance(let meters):
            if let meters, meters > 0 { return "Держите дистанцию, не меньше \(meters) \(russianMeters(meters))." }
            return "Держите дистанцию."
        case let .roadSign(kind, distance):
            return "Через \(distance) \(russianMeters(distance)) \(russianName(kind))."
        case .speedLimit(let kmh):
            return "Ограничение скорости \(kmh)."
        case let .speedLimitAhead(kmh, distance):
            return "Через \(distance) \(russianMeters(distance)) ограничение скорости \(kmh)."
        case .stopSignAhead:
            return "Впереди знак STOP. Остановитесь полностью."
        case .overSpeedLimit(let limit):
            return "Снизьте скорость, ограничение \(limit)."
        case .greenLightGo:
            return "Зелёный. Убедитесь, что безопасно, и трогайтесь."
        }
    }

    static func russianName(_ kind: RouteFeatureKind) -> String {
        switch kind {
        case .speedCamera: return "камера контроля скорости"
        case .pedestrianCrossing: return "пешеходный переход"
        case .school: return "школа, осторожно, дети"
        case .kindergarten: return "детский сад, осторожно, дети"
        case .railwayCrossing: return "железнодорожный переезд"
        case .stopSign: return "знак STOP, остановитесь полностью"
        case .giveWay: return "знак «Уступите дорогу»"
        case .trafficCalming: return "искусственная неровность"
        case .trafficSignals: return "светофор"
        case .construction: return "дорожные работы"
        case .fuel: return "заправка"
        case .parking: return "парковка"
        }
    }

    /// метр / метра / метров.
    static func russianMeters(_ n: Int) -> String {
        let mod100 = abs(n) % 100, mod10 = abs(n) % 10
        if (11...14).contains(mod100) { return "метров" }
        switch mod10 {
        case 1: return "метр"
        case 2, 3, 4: return "метра"
        default: return "метров"
        }
    }

    // MARK: English

    static func english(_ m: CoachMessage) -> String {
        switch m {
        case .collisionRisk:
            return "Warning! You are closing in fast. Brake!"
        case .redLightAhead:
            return "Red light ahead. Slow down."
        case .laneDeparture(let side):
            return side == .left ? "You are drifting over the left line." : "You are drifting over the right line."
        case .keepDistance(let meters):
            if let meters, meters > 0 { return "Keep your distance, at least \(meters) metres." }
            return "Keep your distance."
        case let .roadSign(kind, distance):
            return "In \(distance) metres, \(englishName(kind))."
        case .speedLimit(let kmh):
            return "Speed limit \(kmh)."
        case let .speedLimitAhead(kmh, distance):
            return "Speed limit \(kmh) in \(distance) metres."
        case .stopSignAhead:
            return "Stop sign ahead. Come to a full stop."
        case .overSpeedLimit(let limit):
            return "Slow down, the limit is \(limit)."
        case .greenLightGo:
            return "Green light. Check it is clear, then go."
        }
    }

    static func englishName(_ kind: RouteFeatureKind) -> String {
        switch kind {
        case .speedCamera: return "speed camera"
        case .pedestrianCrossing: return "pedestrian crossing"
        case .school: return "school, watch for children"
        case .kindergarten: return "kindergarten, watch for children"
        case .railwayCrossing: return "railway crossing"
        case .stopSign: return "stop sign, come to a full stop"
        case .giveWay: return "give way sign"
        case .trafficCalming: return "speed bump"
        case .trafficSignals: return "traffic lights"
        case .construction: return "road works"
        case .fuel: return "fuel station"
        case .parking: return "parking"
        }
    }
}
