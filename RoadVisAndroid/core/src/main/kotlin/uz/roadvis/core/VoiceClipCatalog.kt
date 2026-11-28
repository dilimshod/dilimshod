package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * Every pre-recorded voice clip: id → text in Uzbek (Latin), Russian and English.
 * A clip that one language does not need (e.g. Russian "через") has no text there and is not recorded for the other
 * languages. File name: `<lang>_<id>.m4a`, e.g. "uz_turn_right.m4a". `RoadVis/tools/voice_phrases.json` is the
 * exported manifest ([manifestJSON]).
 */
object VoiceClipCatalog {
    data class Entry(val id: String, val uz: String?, val ru: String?, val en: String?) {
        fun text(language: RVLang): String? = when (language) {
            RVLang.UZ -> uz
            RVLang.RU -> ru
            RVLang.EN -> en
        }

        fun toJson(): JSONObject {
            val o = JSONObject().put("id", id)
            if (uz != null) o.put("uz", uz)
            if (ru != null) o.put("ru", ru)
            if (en != null) o.put("en", en)
            return o
        }
    }

    /** Default Microsoft Edge neural voices per language (female / male). */
    val defaultVoices: Map<String, List<String>> = mapOf(
        "uz" to listOf("uz-UZ-MadinaNeural", "uz-UZ-SardorNeural"),
        "ru" to listOf("ru-RU-SvetlanaNeural", "ru-RU-DmitryNeural"),
        "en" to listOf("en-US-JennyNeural", "en-US-GuyNeural"),
    )

    /** Resource name (without extension): "uz_turn_right". */
    fun resourceName(id: String, language: RVLang): String = "${language.raw}_$id"

    /** Text of clip [id] in [language]; null when the clip does not exist in that language. */
    fun text(id: String, language: RVLang): String? = index[id]?.text(language)

    /** Clip ids recorded for [language], in catalog order. */
    fun clipIDs(language: RVLang): List<String> = entries.mapNotNull { if (it.text(language) == null) null else it.id }

    /** "pedestrianCrossing" → "pedestrian_crossing". */
    fun snakeCase(camel: String): String {
        val out = StringBuilder()
        for (ch in camel) {
            if (ch.isUpperCase()) out.append("_").append(ch.lowercase()) else out.append(ch)
        }
        return out.toString()
    }

    private fun e(id: String, uz: String?, ru: String?, en: String?) = Entry(id, uz, ru, en)

    internal fun uzbekOrdinal(n: Int): String =
        listOf("", "birinchi", "ikkinchi", "uchinchi", "to‘rtinchi", "beshinchi", "oltinchi", "yettinchi", "sakkizinchi")[n]

    internal fun russianOrdinal(n: Int): String =
        listOf("", "первый", "второй", "третий", "четвёртый", "пятый", "шестой", "седьмой", "восьмой")[n]

    internal fun englishOrdinalWord(n: Int): String =
        listOf("", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth")[n]

    /** 1…999 in Uzbek words: 125 → "yuz yigirma besh", 300 → "uch yuz". */
    fun uzbekNumber(n: Int): String {
        val ones = listOf("", "bir", "ikki", "uch", "to‘rt", "besh", "olti", "yetti", "sakkiz", "to‘qqiz")
        val tens = listOf("", "o‘n", "yigirma", "o‘ttiz", "qirq", "ellik", "oltmish", "yetmish", "sakson", "to‘qson")
        val parts = mutableListOf<String>()
        val h = n / 100; val t = (n % 100) / 10; val o = n % 10
        if (h == 1) parts.add("yuz") else if (h > 1) parts += listOf(ones[h], "yuz")
        if (t > 0) parts.add(tens[t])
        if (o > 0) parts.add(ones[o])
        return parts.joinToString(" ")
    }

    /** 1…999 in Russian words (masculine): 1 → "один", 125 → "сто двадцать пять". */
    fun russianNumber(n: Int): String {
        val ones = listOf("", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять")
        val teens = listOf("десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать",
            "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать")
        val tens = listOf("", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто")
        val hundreds = listOf("", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот")
        val parts = mutableListOf<String>()
        val h = n / 100; val rest = n % 100
        if (h > 0) parts.add(hundreds[h])
        if (rest in 10..19) {
            parts.add(teens[rest - 10])
        } else {
            if (rest / 10 > 0) parts.add(tens[rest / 10])
            if (rest % 10 > 0) parts.add(ones[rest % 10])
        }
        return parts.joinToString(" ")
    }

    /** 1…999 in (US) English words: 125 → "one hundred twenty-five". */
    fun englishNumber(n: Int): String {
        val small = listOf("", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
            "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
        val tens = listOf("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
        val parts = mutableListOf<String>()
        val h = n / 100; val rest = n % 100
        if (h > 0) parts.add("${small[h]} hundred")
        if (rest > 0) {
            if (rest < 20) parts.add(small[rest])
            else parts.add(if (rest % 10 == 0) tens[rest / 10] else "${tens[rest / 10]}-${small[rest % 10]}")
        }
        return parts.joinToString(" ")
    }

    internal val phrases: List<Entry> = listOf(
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
    ) + (1..8).map { n ->
        e("roundabout_exit_$n",
            "Aylanma harakatda ${uzbekOrdinal(n)} chiqishdan chiqing",
            "На круговом движении сверните на ${russianOrdinal(n)} съезд",
            "At the roundabout, take the ${englishOrdinalWord(n)} exit")
    } + listOf(
        e("arrive_ahead", "Manzilga yetib kelasiz", "Вы прибудете к месту назначения", "You will reach your destination"),
        e("arrived", "Manzilga yetib keldingiz", "Вы прибыли", "You have arrived"),
        e("be_careful", "Ehtiyot bo‘ling", "Будьте осторожны", "Be careful"),
        e("slow_down", "Tezlikni pasaytiring", "Снизьте скорость", "Slow down"),
        e("rerouting", "Yo‘nalish qayta tuzilmoqda", "Перестраиваю маршрут", "Recalculating the route"),
        e("route_ready", "Yo‘nalish tayyor", "Маршрут построен", "Route ready"),

        // Navigator alerts
        e("speed_camera_ahead", "Oldinda tezlikni nazorat qilish kamerasi", "Впереди камера контроля скорости", "Speed camera ahead"),
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

        // User-reported incidents
        e("incident_accident", "Oldinda yo‘l-transport hodisasi", "Впереди ДТП", "Accident ahead"),
        e("incident_road_work", "Oldinda yo‘l ta’mirlash ishlari", "Впереди дорожные работы", "Road works ahead"),
        e("incident_jam", "Oldinda tirbandlik", "Впереди пробка", "Traffic jam ahead"),
        e("incident_police", "Oldinda politsiya posti", "Впереди пост полиции", "Police post ahead"),
        e("incident_pothole", "Oldinda chuqur", "Впереди яма", "Pothole ahead"),
        e("incident_hazard", "Oldinda xavf", "Впереди опасность", "Hazard ahead"),
        e("incident_closure", "Oldinda yo‘l yopilgan", "Впереди перекрытие дороги", "Road closed ahead"),

        // Following distance
        e("collision_alert", "Diqqat! Xavfli yaqinlashyapsiz", "Внимание! Опасное сближение", "Warning! You are closing in fast"),
        e("keep_distance", "Masofani saqlang", "Держите дистанцию", "Keep your distance"),
        e("keep_distance_at_least", "Masofani saqlang, kamida", "Держите дистанцию, не меньше", "Keep your distance, at least"),

        // Driver coach
        e("collision_warning", "Diqqat! Oldingi mashinaga xavfli yaqinlashyapsiz, tormoz bering!",
            "Внимание! Опасное сближение, тормозите!", "Warning! You are closing in fast. Brake!"),
        e("pedestrian_yield", "Diqqat! Piyodani o‘tkazing", "Внимание! Пропустите пешехода", "Attention! Yield to the pedestrian"),
        e("pedestrian_caution", "Ehtiyot bo‘ling, yo‘lda piyoda", "Осторожно, пешеход на дороге", "Careful, pedestrian on the road"),
        e("traffic_officer_ahead", "Diqqat, oldinda YHXX xodimi", "Внимание, впереди сотрудник ГАИ", "Attention, traffic police ahead"),
        e("road_workers_ahead", "Oldinda yo‘l ishlari, ehtiyot bo‘ling, tezlikni pasaytiring",
            "Впереди дорожные работы, осторожно, снизьте скорость", "Road works ahead, slow down"),
        e("red_light_ahead", "Oldinda qizil chiroq, tezlikni pasaytiring", "Впереди красный, снижайте скорость", "Red light ahead. Slow down"),
        e("green_go", "Yashil chiroq. Atrofga qarab, harakatlanishingiz mumkin",
            "Зелёный. Убедитесь, что безопасно, и трогайтесь", "Green light. Check it is clear, then go"),
        e("lane_left", "Chap chiziqdan chiqib ketyapsiz", "Вы выезжаете за левую разметку", "You are drifting over the left line"),
        e("lane_right", "O‘ng chiziqdan chiqib ketyapsiz", "Вы выезжаете за правую разметку", "You are drifting over the right line"),
        // Followed by a number and "km" / "kmh".
        e("speed_limit", "Tezlik chegarasi soatiga", "Ограничение скорости", "Speed limit"),
        e("speeding", "Tezlikni kamaytiring, chegara soatiga", "Снизьте скорость, ограничение", "Slow down, the limit is"),

        // Road signs after a distance: "300 metrdan keyin svetofor".
        e("sign_speed_camera", "tezlik kamerasi", "камера контроля скорости", "speed camera"),
        e("sign_pedestrian_crossing", "piyodalar o‘tish joyi", "пешеходный переход", "pedestrian crossing"),
        e("sign_school", "maktab, bolalarga ehtiyot bo‘ling", "школа, осторожно, дети", "school, watch for children"),
        e("sign_kindergarten", "bolalar bog‘chasi, ehtiyot bo‘ling", "детский сад, осторожно, дети", "kindergarten, watch for children"),
        e("sign_railway_crossing", "temir yo‘l kesishmasi", "железнодорожный переезд", "railway crossing"),
        e("sign_stop_sign", "STOP belgisi, to‘liq to‘xtang", "знак STOP, остановитесь полностью", "stop sign, come to a full stop"),
        e("sign_give_way", "yo‘l bering belgisi", "знак «Уступите дорогу»", "give way sign"),
        e("sign_traffic_calming", "sun’iy notekislik", "искусственная неровность", "speed bump"),
        e("sign_traffic_signals", "svetofor", "светофор", "traffic lights"),
        e("sign_construction", "yo‘l ta’mirlash ishlari", "дорожные работы", "road works"),
        e("sign_fuel", "yoqilg‘i quyish shoxobchasi", "заправка", "fuel station"),
        e("sign_parking", "avtoturargoh", "парковка", "parking"),
    )

    /** Distance prepositions / postpositions and units. */
    internal val units: List<Entry> = listOf(
        e("after_meters", "metrdan keyin", null, null),
        e("after_km", "kilometrdan keyin", null, null),
        e("through", null, "через", null),
        e("in", null, null, "In"),
        e("meters", "metr", "метров", "metres"),
        e("meter_one", null, "метр", "metre"),
        e("meter_few", null, "метра", null),
        e("km", "kilometr", "километров", "kilometres"),
        e("km_one", null, "километр", "kilometre"),
        e("km_few", null, "километра", null),
        e("kmh", null, "километров в час", "kilometres per hour"),
    )

    /** Recorded integers: speeds 5…130 (step 5), kilometres 1…10, distance steps 150…900 m. */
    val numbers: List<Int> = ((5..130 step 5).toSet() + (1..10).toSet() + VoiceDistance.meterSteps.toSet()).sorted()

    internal val numberEntries: List<Entry> = numbers.map { n ->
        e(VoiceComposer.numberID(n), uzbekNumber(n), russianNumber(n), englishNumber(n))
    } + listOf(
        e("n_1_5", "bir yarim", "полтора", "one and a half"),
        e("n_2_5", "ikki yarim", "два с половиной", "two and a half"),
    )

    val entries: List<Entry> = phrases + units + numberEntries

    private val index: Map<String, Entry> = entries.associateBy { it.id }

    /** `tools/voice_phrases.json`: every clip with its texts, the default voices and the file-name pattern. */
    fun manifestJSON(): JSONObject {
        val voices = JSONObject()
        for ((k, v) in defaultVoices) voices.put(k, JSONArray(v))
        return JSONObject()
            .put("version", 1)
            .put("languages", JSONArray(RVLang.entries.map { it.raw }))
            .put("voices", voices)
            .put("fileName", "<lang>_<id>.m4a")
            .put("clips", JSONArray(entries.map { it.toJson() }))
    }
}
