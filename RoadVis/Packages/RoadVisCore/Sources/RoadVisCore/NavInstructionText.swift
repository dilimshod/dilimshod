import Foundation

/// Turn-by-turn instruction text in Uzbek (Latin) and English, built from engine maneuver data.
/// Russian OSRM text stays in `OSRM.instruction(...)` (unchanged); Valhalla returns its own narrative for ru / en.
///
/// Street names are attached with postpositions that need no suffixes ("Navoiy ko‘chasi tomon",
/// "… bo‘ylab"), so names in any script read correctly. Uzbek ordinals use the written "2-chiqish" form,
/// which `UzbekSpeechText` speaks as "ikkinchi chiqish".
public enum NavInstructionText {

    // MARK: OSRM-style (type + modifier)

    /// Instruction for an OSRM maneuver `type` / `modifier` in `language` (ru delegates to `OSRM.instruction`).
    public static func osrm(type: String, modifier: String?, name: String?, exit: Int? = nil,
                            rotaryName: String? = nil, language: RVLang) -> String {
        switch language {
        case .ru: return OSRM.instruction(type: type, modifier: modifier, name: name, exit: exit, rotaryName: rotaryName)
        case .uz: return uzbek(type: type, modifier: modifier, name: name, exit: exit, rotaryName: rotaryName)
        case .en: return english(type: type, modifier: modifier, name: name, exit: exit, rotaryName: rotaryName)
        }
    }

    static func side(_ modifier: String?) -> Int {   // -1 left, 1 right, 0 straight / none
        guard let modifier else { return 0 }
        if modifier.contains("left") { return -1 }
        if modifier.contains("right") { return 1 }
        return 0
    }

    // MARK: Uzbek

    static func uzbek(type: String, modifier: String?, name: String?, exit: Int?, rotaryName: String?) -> String {
        let onto = name.map { ", \($0) tomon" } ?? ""
        func along(_ verb: String) -> String { name.map { "\($0) bo‘ylab \(verb.rvLowercasedFirst())" } ?? verb }
        switch type {
        case "depart":
            return along("Harakatni boshlang")
        case "arrive":
            switch side(modifier) {
            case -1: return "Manzil chap tomonda"
            case 1: return "Manzil o‘ng tomonda"
            default: return "Manzil"
            }
        case "roundabout", "rotary":
            let circle = rotaryName.map { "«\($0)» aylanma harakatida" } ?? "Aylanma harakatda"
            if let exit, exit > 0 { return "\(circle) \(exit)-chiqishdan chiqing" + onto }
            return "Aylanma harakatga kiring" + onto
        case "roundabout turn":
            return "Aylanma harakatda " + uzbekTurn(modifier).rvLowercasedFirst() + onto
        case "exit roundabout", "exit rotary":
            return "Aylanma harakatdan chiqing" + onto
        case "merge":
            switch side(modifier) {
            case -1: return "Chapga o‘tib, oqimga qo‘shiling" + onto
            case 1: return "O‘ngga o‘tib, oqimga qo‘shiling" + onto
            default: return "Oqimga qo‘shiling" + onto
            }
        case "on ramp":
            return "\(uzbekDirection(modifier)) burilib, kirish yo‘liga chiqing" + onto
        case "off ramp":
            return "\(uzbekDirection(modifier)) burilib, chiqish yo‘liga o‘ting" + onto
        case "fork":
            switch side(modifier) {
            case -1: return "Ayrilishda chap tomonda qoling" + onto
            case 1: return "Ayrilishda o‘ng tomonda qoling" + onto
            default: return "Ayrilishda to‘g‘riga yuring" + onto
            }
        case "end of road":
            return "Yo‘l oxirida " + uzbekTurn(modifier).rvLowercasedFirst() + onto
        case "new name", "continue", "notification":
            if modifier == nil || modifier == "straight" { return name == nil ? "To‘g‘riga davom eting" : along("Davom eting") }
            return uzbekTurn(modifier) + onto
        case "ferry":
            return "Paromga chiqing" + onto
        case "ferry exit":
            return "Paromdan tushing" + onto
        default:
            if modifier == "straight" { return along("To‘g‘riga yuring") }
            return uzbekTurn(modifier) + onto
        }
    }

    static func uzbekTurn(_ modifier: String?) -> String {
        switch modifier {
        case "uturn": return "Orqaga qayriling"
        case "sharp right": return "Keskin o‘ngga buriling"
        case "right": return "O‘ngga buriling"
        case "slight right": return "Biroz o‘ngga buriling"
        case "sharp left": return "Keskin chapga buriling"
        case "left": return "Chapga buriling"
        case "slight left": return "Biroz chapga buriling"
        default: return "To‘g‘riga yuring"
        }
    }

    static func uzbekDirection(_ modifier: String?) -> String {
        switch side(modifier) {
        case -1: return "Chapga"
        case 0 where modifier == "straight": return "To‘g‘riga"
        default: return "O‘ngga"
        }
    }

    // MARK: English

    static func english(type: String, modifier: String?, name: String?, exit: Int?, rotaryName: String?) -> String {
        let onto = name.map { " onto \($0)" } ?? ""
        let along = name.map { " along \($0)" } ?? ""
        switch type {
        case "depart":
            return "Start driving" + along
        case "arrive":
            switch side(modifier) {
            case -1: return "Your destination is on the left"
            case 1: return "Your destination is on the right"
            default: return "Your destination"
            }
        case "roundabout", "rotary":
            let circle = rotaryName.map { "At \($0) roundabout" } ?? "At the roundabout"
            if let exit, exit > 0 { return "\(circle), take the \(englishOrdinal(exit)) exit" + onto }
            return "Enter the roundabout" + onto
        case "roundabout turn":
            return "At the roundabout, " + englishTurn(modifier).rvLowercasedFirst() + onto
        case "exit roundabout", "exit rotary":
            return "Exit the roundabout" + onto
        case "merge":
            switch side(modifier) {
            case -1: return "Move left and merge" + onto
            case 1: return "Move right and merge" + onto
            default: return "Merge" + onto
            }
        case "on ramp":
            return "Take the ramp \(englishDirection(modifier))" + onto
        case "off ramp":
            return "Take the exit \(englishDirection(modifier))" + onto
        case "fork":
            switch side(modifier) {
            case -1: return "At the fork, keep left" + onto
            case 1: return "At the fork, keep right" + onto
            default: return "At the fork, continue straight" + onto
            }
        case "end of road":
            return "At the end of the road, " + englishTurn(modifier).rvLowercasedFirst() + onto
        case "new name", "continue", "notification":
            if modifier == nil || modifier == "straight" { return name == nil ? "Continue straight" : "Continue" + along }
            return englishTurn(modifier) + onto
        case "ferry":
            return "Take the ferry" + onto
        case "ferry exit":
            return "Leave the ferry" + onto
        default:
            if modifier == "straight" { return "Go straight" + along }
            return englishTurn(modifier) + onto
        }
    }

    static func englishTurn(_ modifier: String?) -> String {
        switch modifier {
        case "uturn": return "Make a U-turn"
        case "sharp right": return "Turn sharp right"
        case "right": return "Turn right"
        case "slight right": return "Bear right"
        case "sharp left": return "Turn sharp left"
        case "left": return "Turn left"
        case "slight left": return "Bear left"
        default: return "Go straight"
        }
    }

    static func englishDirection(_ modifier: String?) -> String {
        switch side(modifier) {
        case -1: return "on the left"
        case 0 where modifier == "straight": return "straight ahead"
        default: return "on the right"
        }
    }

    /// 1 → "1st", 2 → "2nd", 3 → "3rd", 11 → "11th", 22 → "22nd".
    public static func englishOrdinal(_ n: Int) -> String {
        let mod100 = abs(n) % 100, mod10 = abs(n) % 10
        if (11...13).contains(mod100) { return "\(n)th" }
        switch mod10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    // MARK: Valhalla

    /// Valhalla maneuver type code → OSRM-style (type, modifier) used by the builders above.
    public static func osrmEquivalent(valhallaType code: Int) -> (type: String, modifier: String?) {
        switch code {
        case 1: return ("depart", nil)
        case 2: return ("depart", "right")
        case 3: return ("depart", "left")
        case 4: return ("arrive", nil)
        case 5: return ("arrive", "right")
        case 6: return ("arrive", "left")
        case 7: return ("new name", "straight")
        case 8: return ("continue", "straight")
        case 9: return ("turn", "slight right")
        case 10: return ("turn", "right")
        case 11: return ("turn", "sharp right")
        case 12, 13: return ("turn", "uturn")
        case 14: return ("turn", "sharp left")
        case 15: return ("turn", "left")
        case 16: return ("turn", "slight left")
        case 17: return ("on ramp", "straight")
        case 18: return ("on ramp", "right")
        case 19: return ("on ramp", "left")
        case 20: return ("off ramp", "right")
        case 21: return ("off ramp", "left")
        case 22: return ("fork", "straight")
        case 23: return ("fork", "slight right")
        case 24: return ("fork", "slight left")
        case 25: return ("merge", nil)
        case 26: return ("roundabout", nil)
        case 27: return ("exit roundabout", nil)
        case 28: return ("ferry", nil)
        case 29: return ("ferry exit", nil)
        case 37: return ("merge", "slight right")
        case 38: return ("merge", "slight left")
        default: return ("continue", "straight")
        }
    }

    /// Instruction for a Valhalla maneuver rebuilt in `language` from its type code, street names and roundabout
    /// exit count (used for Uzbek, which Valhalla does not narrate).
    /// For a roundabout (type 26) `streetNames` name the circle itself; the exit street comes from
    /// `roundaboutExitStreetNames` when Valhalla provides it.
    public static func valhalla(type code: Int, streetNames: [String], roundaboutExitCount: Int? = nil,
                                roundaboutExitStreetNames: [String] = [], language: RVLang) -> String {
        let (type, modifier) = osrmEquivalent(valhallaType: code)
        func first(_ names: [String]) -> String? {
            names.first.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if type == "roundabout" {
            return osrm(type: type, modifier: modifier, name: first(roundaboutExitStreetNames),
                        exit: roundaboutExitCount, rotaryName: first(streetNames), language: language)
        }
        return osrm(type: type, modifier: modifier, name: type == "arrive" ? nil : first(streetNames),
                    exit: roundaboutExitCount, language: language)
    }

    // MARK: Misc

    /// Next-instruction text when no maneuver is left: "Вы прибыли" / "Пункт назначения" and translations.
    public static func destination(arrived: Bool, language: RVLang) -> String {
        switch language {
        case .ru: return arrived ? "Вы прибыли" : "Пункт назначения"
        case .uz: return arrived ? "Manzilga yetib keldingiz" : "Manzil"
        case .en: return arrived ? "You have arrived" : "Destination"
        }
    }

    /// Fallback route name when the engine gives no street names ("Маршрут OSM" / "Маршрут OSRM").
    public static func fallbackRouteName(engine: String, language: RVLang) -> String {
        switch language {
        case .ru: return "Маршрут \(engine)"
        case .uz: return "\(engine) yo‘nalishi"
        case .en: return "\(engine) route"
        }
    }
}
