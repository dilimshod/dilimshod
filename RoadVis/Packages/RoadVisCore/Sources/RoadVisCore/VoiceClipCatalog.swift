import Foundation

/// Every pre-recorded voice clip: id → text in Uzbek (Latin), Russian and English.
///
/// The texts follow the app's string tables (Localization/Strings+uz/ru/en.swift: "voice.*", "coach.*") where a
/// phrase already exists. A clip that one language does not need (e.g. Russian "через") has no text there and is not
/// recorded for the other languages. Bundle file name: `<lang>_<id>.m4a` (or `.mp3`), e.g. "uz_turn_right.m4a".
///
/// `tools/voice_phrases.json` (read by `tools/generate_voice_clips.py`) is exported from this table:
/// `RV_WRITE_VOICE_JSON=1 swift test --filter VoicePhraseTests` rewrites it, the plain test run checks it is in sync.
public enum VoiceClipCatalog {
    public struct Entry: Hashable, Sendable, Codable {
        public let id: String
        public let uz: String?
        public let ru: String?
        public let en: String?

        public init(id: String, uz: String?, ru: String?, en: String?) {
            self.id = id
            self.uz = uz
            self.ru = ru
            self.en = en
        }

        public func text(_ language: RVLang) -> String? {
            switch language {
            case .uz: return uz
            case .ru: return ru
            case .en: return en
            }
        }
    }

    /// Default Microsoft Edge neural voices per language (female / male).
    public static let defaultVoices: [String: [String]] = [
        "uz": ["uz-UZ-MadinaNeural", "uz-UZ-SardorNeural"],
        "ru": ["ru-RU-SvetlanaNeural", "ru-RU-DmitryNeural"],
        "en": ["en-US-JennyNeural", "en-US-GuyNeural"],
    ]

    /// Bundle resource name (without extension): "uz_turn_right".
    public static func resourceName(_ id: String, _ language: RVLang) -> String { "\(language.rawValue)_\(id)" }

    /// Text of clip `id` in `language`; nil when the clip does not exist in that language.
    public static func text(_ id: String, _ language: RVLang) -> String? {
        index[id]?.text(language)
    }

    /// Clip ids recorded for `language`, in catalog order.
    public static func clipIDs(for language: RVLang) -> [String] {
        entries.compactMap { $0.text(language) == nil ? nil : $0.id }
    }

    /// "pedestrianCrossing" → "pedestrian_crossing".
    public static func snakeCase(_ camel: String) -> String {
        var out = ""
        for ch in camel {
            if ch.isUppercase {
                out += "_" + ch.lowercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static let index: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in entries { map[entry.id] = entry }
        return map
    }()

    // MARK: Table

    public static let entries: [Entry] = phrases + units + numberEntries

    private static func e(_ id: String, _ uz: String?, _ ru: String?, _ en: String?) -> Entry {
        Entry(id: id, uz: uz, ru: ru, en: en)
    }

    static let phrases: [Entry] = [
        // Turn guidance
        e("go_straight", "To‘g‘riga yuring", "Двигайтесь прямо", "Go straight"),
        e("turn_left", "Chapga buriling", "Поверните налево", "Turn left"),
        e("turn_right", "O‘ngga buriling", "Поверните направо", "Turn right"),
        e("bear_left", "Biroz chapga buriling", "Плавно поверните налево", "Bear left"),
        e("bear_right", "Biroz o‘ngga buriling", "Плавно поверните направо", "Bear right"),
        e("sharp_left", "Keskin chapga buriling", "Резко поверните налево", "Turn sharp left"),
        e("sharp_right", "Keskin o‘ngga buriling", "Резко поверните направо", "Turn sharp right"),
        e("keep_left", "Chap tomonda qoling", "Держитесь левее", "Keep left"),
        e("keep_right", "O‘ng tomonda qoling", "Держитесь правее", "Keep right"),
        e("exit_left", "Chapdagi chiqish yo‘liga o‘ting", "Сверните на съезд слева", "Take the exit on the left"),
        e("exit_right", "O‘ngdagi chiqish yo‘liga o‘ting", "Сверните на съезд справа", "Take the exit on the right"),
        e("uturn", "Orqaga qayriling", "Развернитесь", "Make a U-turn"),
        e("merge", "Oqimga qo‘shiling", "Перестройтесь в поток", "Merge"),
        e("roundabout_enter", "Aylanma harakatga kiring", "Въезжайте на круговое движение", "Enter the roundabout"),
    ] + (1...8).map { n in
        e("roundabout_exit_\(n)",
          "Aylanma harakatda \(uzbekOrdinal(n)) chiqishdan chiqing",
          "На круговом движении сверните на \(russianOrdinal(n)) съезд",
          "At the roundabout, take the \(englishOrdinalWord(n)) exit")
    } + [
        e("arrive_ahead", "Manzilga yetib kelasiz", "Вы прибудете к месту назначения", "You will reach your destination"),
        e("arrived", "Manzilga yetib keldingiz", "Вы прибыли", "You have arrived"),
        e("be_careful", "Ehtiyot bo‘ling", "Будьте осторожны", "Be careful"),
        e("slow_down", "Tezlikni pasaytiring", "Снизьте скорость", "Slow down"),
        e("rerouting", "Yo‘nalish qayta tuzilmoqda", "Перестраиваю маршрут", "Recalculating the route"),
        e("route_ready", "Yo‘nalish tayyor", "Маршрут построен", "Route ready"),

        // Navigator alerts (voice.hazard.*)
        e("speed_camera_ahead", "Oldinda tezlikni nazorat qilish kamerasi", "Впереди камера контроля скорости",
          "Speed camera ahead"),
        e("school_ahead", "Oldinda maktab, ehtiyot bo‘ling, bolalar", "Впереди школа, будьте внимательны, дети",
          "School ahead, watch for children"),
        e("kindergarten_ahead", "Oldinda bolalar bog‘chasi, ehtiyot bo‘ling, bolalar",
          "Впереди детский сад, будьте внимательны, дети", "Kindergarten ahead, watch for children"),
        e("railway_ahead", "Oldinda temir yo‘l kesishmasi", "Впереди железнодорожный переезд", "Railway crossing ahead"),
        e("crossing_ahead", "Oldinda piyodalar o‘tish joyi", "Впереди пешеходный переход", "Pedestrian crossing ahead"),
        e("construction_ahead", "Oldinda yo‘l ta’mirlash ishlari", "Впереди дорожные работы", "Road works ahead"),
        e("bump_ahead", "Oldinda sun’iy notekislik", "Впереди искусственная неровность", "Speed bump ahead"),
        e("traffic_light_ahead", "Oldinda svetofor", "Впереди светофор", "Traffic light ahead"),
        e("stop_sign_ahead", "Oldinda STOP belgisi. To‘liq to‘xtang", "Впереди знак STOP. Остановитесь полностью",
          "Stop sign ahead. Come to a full stop"),

        // User-reported incidents (voice.incident.*)
        e("incident_accident", "Oldinda yo‘l-transport hodisasi", "Впереди ДТП", "Accident ahead"),
        e("incident_road_work", "Oldinda yo‘l ta’mirlash ishlari", "Впереди дорожные работы", "Road works ahead"),
        e("incident_jam", "Oldinda tirbandlik", "Впереди пробка", "Traffic jam ahead"),
        e("incident_police", "Oldinda politsiya posti", "Впереди пост полиции", "Police post ahead"),
        e("incident_pothole", "Oldinda chuqur", "Впереди яма", "Pothole ahead"),
        e("incident_hazard", "Oldinda xavf", "Впереди опасность", "Hazard ahead"),
        e("incident_closure", "Oldinda yo‘l yopilgan", "Впереди перекрытие дороги", "Road closed ahead"),

        // Following distance (voice.collision / voice.keepDistance / coach.keepDistance*)
        e("collision_alert", "Diqqat! Xavfli yaqinlashyapsiz", "Внимание! Опасное сближение",
          "Warning! You are closing in fast"),
        e("keep_distance", "Masofani saqlang", "Держите дистанцию", "Keep your distance"),
        e("keep_distance_at_least", "Masofani saqlang, kamida", "Держите дистанцию, не меньше",
          "Keep your distance, at least"),

        // Driver coach (coach.*)
        e("collision_warning", "Diqqat! Oldingi mashinaga xavfli yaqinlashyapsiz, tormoz bering!",
          "Внимание! Опасное сближение, тормозите!", "Warning! You are closing in fast. Brake!"),
        e("pedestrian_yield", "Diqqat! Piyodani o‘tkazing", "Внимание! Пропустите пешехода",
          "Attention! Yield to the pedestrian"),
        e("pedestrian_caution", "Ehtiyot bo‘ling, yo‘lda piyoda", "Осторожно, пешеход на дороге",
          "Careful, pedestrian on the road"),
        e("traffic_officer_ahead", "Diqqat, oldinda YHXX xodimi", "Внимание, впереди сотрудник ГАИ",
          "Attention, traffic police ahead"),
        e("road_workers_ahead", "Oldinda yo‘l ishlari, ehtiyot bo‘ling, tezlikni pasaytiring",
          "Впереди дорожные работы, осторожно, снизьте скорость", "Road works ahead, slow down"),
        e("red_light_ahead", "Oldinda qizil chiroq, tezlikni pasaytiring", "Впереди красный, снижайте скорость",
          "Red light ahead. Slow down"),
        e("green_go", "Yashil chiroq. Atrofga qarab, harakatlanishingiz mumkin",
          "Зелёный. Убедитесь, что безопасно, и трогайтесь", "Green light. Check it is clear, then go"),
        e("lane_left", "Chap chiziqdan chiqib ketyapsiz", "Вы выезжаете за левую разметку",
          "You are drifting over the left line"),
        e("lane_right", "O‘ng chiziqdan chiqib ketyapsiz", "Вы выезжаете за правую разметку",
          "You are drifting over the right line"),
        // Followed by a number and "km" / "kmh": "Tezlik chegarasi soatiga oltmish kilometr".
        e("speed_limit", "Tezlik chegarasi soatiga", "Ограничение скорости", "Speed limit"),
        e("speeding", "Tezlikni kamaytiring, chegara soatiga", "Снизьте скорость, ограничение",
          "Slow down, the limit is"),

        // Road signs after a distance (coach.sign.*): "300 metrdan keyin svetofor".
        e("sign_speed_camera", "tezlik kamerasi", "камера контроля скорости", "speed camera"),
        e("sign_pedestrian_crossing", "piyodalar o‘tish joyi", "пешеходный переход", "pedestrian crossing"),
        e("sign_school", "maktab, bolalarga ehtiyot bo‘ling", "школа, осторожно, дети", "school, watch for children"),
        e("sign_kindergarten", "bolalar bog‘chasi, ehtiyot bo‘ling", "детский сад, осторожно, дети",
          "kindergarten, watch for children"),
        e("sign_railway_crossing", "temir yo‘l kesishmasi", "железнодорожный переезд", "railway crossing"),
        e("sign_stop_sign", "STOP belgisi, to‘liq to‘xtang", "знак STOP, остановитесь полностью",
          "stop sign, come to a full stop"),
        e("sign_give_way", "yo‘l bering belgisi", "знак «Уступите дорогу»", "give way sign"),
        e("sign_traffic_calming", "sun’iy notekislik", "искусственная неровность", "speed bump"),
        e("sign_traffic_signals", "svetofor", "светофор", "traffic lights"),
        e("sign_construction", "yo‘l ta’mirlash ishlari", "дорожные работы", "road works"),
        e("sign_fuel", "yoqilg‘i quyish shoxobchasi", "заправка", "fuel station"),
        e("sign_parking", "avtoturargoh", "парковка", "parking"),
    ]

    /// Distance prepositions / postpositions and units.
    static let units: [Entry] = [
        e("after_meters", "metrdan keyin", nil, nil),
        e("after_km", "kilometrdan keyin", nil, nil),
        e("through", nil, "через", nil),
        e("in", nil, nil, "In"),
        e("meters", "metr", "метров", "metres"),
        e("meter_one", nil, "метр", "metre"),
        e("meter_few", nil, "метра", nil),
        e("km", "kilometr", "километров", "kilometres"),
        e("km_one", nil, "километр", "kilometre"),
        e("km_few", nil, "километра", nil),
        e("kmh", nil, "километров в час", "kilometres per hour"),
    ]

    // MARK: Numbers

    /// Recorded integers: speeds 5…130 (step 5), kilometres 1…10, distance steps 150…900 m.
    public static let numbers: [Int] = {
        var set = Set(stride(from: 5, through: 130, by: 5))
        set.formUnion(1...10)
        set.formUnion(VoiceDistance.meterSteps)
        return set.sorted()
    }()

    static let numberEntries: [Entry] = numbers.map { n in
        e(VoiceComposer.numberID(n), uzbekNumber(n), russianNumber(n), englishNumber(n))
    } + [
        e("n_1_5", "bir yarim", "полтора", "one and a half"),
        e("n_2_5", "ikki yarim", "два с половиной", "two and a half"),
    ]

    /// 1…999 in Uzbek words: 125 → "yuz yigirma besh", 300 → "uch yuz".
    public static func uzbekNumber(_ n: Int) -> String {
        let ones = ["", "bir", "ikki", "uch", "to‘rt", "besh", "olti", "yetti", "sakkiz", "to‘qqiz"]
        let tens = ["", "o‘n", "yigirma", "o‘ttiz", "qirq", "ellik", "oltmish", "yetmish", "sakson", "to‘qson"]
        var parts: [String] = []
        let h = n / 100, t = (n % 100) / 10, o = n % 10
        if h == 1 { parts.append("yuz") } else if h > 1 { parts += [ones[h], "yuz"] }
        if t > 0 { parts.append(tens[t]) }
        if o > 0 { parts.append(ones[o]) }
        return parts.joined(separator: " ")
    }

    /// 1…999 in Russian words (masculine): 1 → "один", 125 → "сто двадцать пять".
    public static func russianNumber(_ n: Int) -> String {
        let ones = ["", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
        let teens = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать",
                     "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
        let tens = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят",
                    "девяносто"]
        let hundreds = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот",
                        "девятьсот"]
        var parts: [String] = []
        let h = n / 100, rest = n % 100
        if h > 0 { parts.append(hundreds[h]) }
        if (10...19).contains(rest) {
            parts.append(teens[rest - 10])
        } else {
            if rest / 10 > 0 { parts.append(tens[rest / 10]) }
            if rest % 10 > 0 { parts.append(ones[rest % 10]) }
        }
        return parts.joined(separator: " ")
    }

    /// 1…999 in (US) English words: 125 → "one hundred twenty-five".
    public static func englishNumber(_ n: Int) -> String {
        let small = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                     "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        var parts: [String] = []
        let h = n / 100, rest = n % 100
        if h > 0 { parts.append("\(small[h]) hundred") }
        if rest > 0 {
            if rest < 20 {
                parts.append(small[rest])
            } else {
                parts.append(rest % 10 == 0 ? tens[rest / 10] : "\(tens[rest / 10])-\(small[rest % 10])")
            }
        }
        return parts.joined(separator: " ")
    }

    static func uzbekOrdinal(_ n: Int) -> String {
        ["", "birinchi", "ikkinchi", "uchinchi", "to‘rtinchi", "beshinchi", "oltinchi", "yettinchi", "sakkizinchi"][n]
    }

    static func russianOrdinal(_ n: Int) -> String {
        ["", "первый", "второй", "третий", "четвёртый", "пятый", "шестой", "седьмой", "восьмой"][n]
    }

    static func englishOrdinalWord(_ n: Int) -> String {
        ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth"][n]
    }

    // MARK: Manifest

    private struct Manifest: Codable {
        let version: Int
        let languages: [String]
        let voices: [String: [String]]
        let fileName: String
        let clips: [Entry]
    }

    /// `tools/voice_phrases.json`: every clip with its texts, the default voices and the file-name pattern.
    public static func manifestJSON() throws -> Data {
        let manifest = Manifest(version: 1, languages: RVLang.allCases.map(\.rawValue), voices: defaultVoices,
                                fileName: "<lang>_<id>.m4a", clips: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}
