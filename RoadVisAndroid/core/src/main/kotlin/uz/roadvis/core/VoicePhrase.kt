package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max

// Structured spoken phrases for pre-recorded voice clips (`<lang>_<clip id>.m4a`).
//
// A `VoicePhrase` is language-independent: a list of elements (fixed phrase ids, a distance before an action, a
// quantity of metres, a speed). `VoiceComposer` turns it into the clip ids of one language with the right grammar
// ("300 metrdan keyin" = n_300 + after_meters; "через 300 метров" = through + n_300 + meters; "In 300 metres" =
// in + n_300 + meters). Only round values are recorded, so distances are rounded to `VoiceDistance` steps. When a
// phrase cannot be expressed with clips the composer returns null and the app speaks the text with the system voice.

/** One piece of a composed utterance: a recorded clip or a short pause (punctuation in the text fallback). */
sealed class VoiceSegment {
    data class Clip(val id: String) : VoiceSegment()
    data object Pause : VoiceSegment()
}

/**
 * A spoken utterance as a sequence of language-independent elements, plus an optional already-localized text for
 * the system voice (it may contain details that are not recorded, such as street names).
 */
data class VoicePhrase(
    val elements: List<Element>,
    /** Localized text for the system voice; null → the text composed from the clip texts. */
    val text: String? = null,
) {
    sealed class Element {
        /** A fixed phrase, e.g. "turn_right", "be_careful". */
        data class Clip(val id: String) : Element()
        /** Distance before the following action: "300 metrdan keyin" / "через 300 метров" / "In 300 metres". */
        data class Distance(val meters: Double) : Element()
        /** A quantity of metres: "25 metr" / "25 метров" / "25 metres". */
        data class Meters(val count: Int) : Element()
        /** A speed after "speed_limit" / "speeding". */
        data class Speed(val kmh: Int) : Element()
        /** Sentence / clause break. */
        data object Pause : Element()
    }

    /** The same phrase with another fallback text. */
    fun withText(text: String?): VoicePhrase = copy(text = text)

    companion object {
        fun fixed(id: String, text: String? = null): VoicePhrase = VoicePhrase(listOf(Element.Clip(id)), text)

        /** Clip id of a maneuver; null for UNKNOWN (spoken with the system voice). */
        fun maneuverClipID(type: ManeuverType, roundaboutExit: Int? = null): String? = when (type) {
            ManeuverType.DEPART, ManeuverType.STRAIGHT -> "go_straight"
            ManeuverType.LEFT -> "turn_left"
            ManeuverType.RIGHT -> "turn_right"
            ManeuverType.SLIGHT_LEFT -> "bear_left"
            ManeuverType.SLIGHT_RIGHT -> "bear_right"
            ManeuverType.SHARP_LEFT -> "sharp_left"
            ManeuverType.SHARP_RIGHT -> "sharp_right"
            ManeuverType.KEEP_LEFT -> "keep_left"
            ManeuverType.KEEP_RIGHT -> "keep_right"
            ManeuverType.EXIT_LEFT -> "exit_left"
            ManeuverType.EXIT_RIGHT -> "exit_right"
            ManeuverType.U_TURN -> "uturn"
            ManeuverType.MERGE -> "merge"
            ManeuverType.ARRIVE -> "arrive_ahead"
            ManeuverType.ROUNDABOUT ->
                if (roundaboutExit != null && roundaboutExit in 1..8) "roundabout_exit_$roundaboutExit" else "roundabout_enter"
            ManeuverType.UNKNOWN -> null
        }

        /** Turn prompt: [distance] maneuver [, be careful] [, slow down]. An unknown maneuver falls back to [text]. */
        fun maneuver(
            type: ManeuverType, distance: Double?, roundaboutExit: Int? = null,
            caution: Boolean = false, slowDown: Boolean = false, text: String? = null,
        ): VoicePhrase {
            val elements = mutableListOf<Element>()
            if (distance != null) elements.add(Element.Distance(distance))
            elements.add(Element.Clip(maneuverClipID(type, roundaboutExit) ?: "maneuver_unknown"))
            if (caution) elements += listOf(Element.Pause, Element.Clip("be_careful"))
            if (slowDown) elements += listOf(Element.Pause, Element.Clip("slow_down"))
            return VoicePhrase(elements, text)
        }

        /** Navigator alert for an OSM feature ahead; null for kinds that are not announced. */
        fun hazardClipID(kind: RouteFeatureKind): String? = when (kind) {
            RouteFeatureKind.SPEED_CAMERA -> "speed_camera_ahead"
            RouteFeatureKind.SCHOOL -> "school_ahead"
            RouteFeatureKind.KINDERGARTEN -> "kindergarten_ahead"
            RouteFeatureKind.RAILWAY_CROSSING -> "railway_ahead"
            RouteFeatureKind.PEDESTRIAN_CROSSING -> "crossing_ahead"
            RouteFeatureKind.CONSTRUCTION -> "construction_ahead"
            RouteFeatureKind.TRAFFIC_CALMING -> "bump_ahead"
            RouteFeatureKind.TRAFFIC_SIGNALS -> "traffic_light_ahead"
            RouteFeatureKind.STOP_SIGN -> "stop_sign_ahead"
            RouteFeatureKind.GIVE_WAY, RouteFeatureKind.FUEL, RouteFeatureKind.PARKING -> null
        }

        fun hazard(kind: RouteFeatureKind, text: String? = null): VoicePhrase =
            VoicePhrase(listOf(Element.Clip(hazardClipID(kind) ?: "hazard_unknown")), text)

        /** Short name of a road feature for "in 300 m, <sign>" ("sign_traffic_signals"). */
        fun signClipID(kind: RouteFeatureKind): String = "sign_" + VoiceClipCatalog.snakeCase(kind.raw)

        /** "Oldinda tirbandlik, 600 metrdan keyin". The user's own camera mark reuses the OSM camera clip. */
        fun incident(kind: RoadIncidentKind, distance: Double?, text: String? = null): VoicePhrase {
            val clip = if (kind == RoadIncidentKind.SPEED_CAMERA) "speed_camera_ahead" else "incident_" + VoiceClipCatalog.snakeCase(kind.raw)
            val elements = mutableListOf<Element>(Element.Clip(clip))
            if (distance != null) elements += listOf(Element.Pause, Element.Distance(distance))
            return VoicePhrase(elements, text)
        }

        /** The spoken form of a coach message. */
        fun coach(message: CoachMessage, text: String? = null): VoicePhrase {
            val elements: List<Element> = when (message) {
                CoachMessage.CollisionRisk -> listOf(Element.Clip("collision_warning"))
                is CoachMessage.PedestrianDanger -> listOf(Element.Clip("pedestrian_yield"))
                is CoachMessage.PedestrianCaution -> listOf(Element.Clip("pedestrian_caution"))
                CoachMessage.RedLightAhead -> listOf(Element.Clip("red_light_ahead"))
                is CoachMessage.LaneDeparture -> listOf(Element.Clip(if (message.side == LaneSide.LEFT) "lane_left" else "lane_right"))
                is CoachMessage.KeepDistance -> {
                    val m = message.recommendedMeters
                    if (m != null && m > 0) listOf(Element.Clip("keep_distance_at_least"), Element.Meters(m))
                    else listOf(Element.Clip("keep_distance"))
                }
                is CoachMessage.RoadSign -> listOf(Element.Distance(message.distanceMeters.toDouble()), Element.Clip(signClipID(message.kind)))
                is CoachMessage.SpeedLimit -> listOf(Element.Clip("speed_limit"), Element.Speed(message.kmh))
                is CoachMessage.SpeedLimitAhead ->
                    listOf(Element.Distance(message.distanceMeters.toDouble()), Element.Clip("speed_limit"), Element.Speed(message.kmh))
                CoachMessage.StopSignAhead -> listOf(Element.Clip("stop_sign_ahead"))
                is CoachMessage.OverSpeedLimit -> listOf(Element.Clip("speeding"), Element.Speed(message.limitKmh))
                CoachMessage.GreenLightGo -> listOf(Element.Clip("green_go"))
                is CoachMessage.TrafficOfficerAhead -> listOf(Element.Clip("traffic_officer_ahead"))
                is CoachMessage.RoadWorkersAhead -> listOf(Element.Clip("road_workers_ahead"))
            }
            return VoicePhrase(elements, text)
        }

        /** The Settings → Language test phrase: "300 metrdan keyin o‘ngga buriling. Oldinda svetofor." */
        fun sample(text: String? = null): VoicePhrase =
            VoicePhrase(listOf(Element.Distance(300.0), Element.Clip("turn_right"), Element.Pause, Element.Clip("traffic_light_ahead")), text)
    }
}

// Distances

/** A distance rounded to a recorded value: 50…900 m or 1, 1.5, 2, 2.5, 3…10 km. */
sealed class VoiceDistance {
    data class Meters(val value: Int) : VoiceDistance()
    /** Kilometres in tenths (15 = 1.5 km). */
    data class Kilometers(val tenths: Int) : VoiceDistance()

    /** Value in metres. */
    val meters: Double
        get() = when (this) {
            is Meters -> value.toDouble()
            is Kilometers -> tenths * 100.0
        }

    /** Clip id of the number: "n_300", "n_2", "n_1_5". */
    val numberID: String
        get() = when (this) {
            is Meters -> VoiceComposer.numberID(value)
            is Kilometers -> if (tenths % 10 == 0) VoiceComposer.numberID(tenths / 10) else "n_${tenths / 10}_${tenths % 10}"
        }

    companion object {
        val meterSteps = listOf(50, 100, 150, 200, 250, 300, 400, 500, 600, 700, 800, 900)
        val kilometerTenths = listOf(10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100)

        /** Nearest recorded distance (287 m → 300 m, 960 m → 1 km, 1.3 km → 1.5 km); null for ≤ 0, non-finite or > 10.5 km. */
        fun rounded(meters: Double): VoiceDistance? {
            if (!(meters.isFinite() && meters > 0 && meters <= 10_500)) return null
            val candidates: List<VoiceDistance> = meterSteps.map { Meters(it) } + kilometerTenths.map { Kilometers(it) }
            return candidates.minByOrNull { abs(it.meters - meters) }
        }
    }
}

// Composition

object VoiceComposer {
    /** "n_300". */
    fun numberID(n: Int): String = "n_$n"

    /** Speeds that are recorded (5…130 km/h in steps of 5). */
    fun isRecordedSpeed(kmh: Int): Boolean = kmh in 5..130 && kmh % 5 == 0

    /** Clip segments of [phrase] in [language]; null when some element has no recording. */
    fun segments(phrase: VoicePhrase, language: RVLang): List<VoiceSegment>? {
        val result = mutableListOf<VoiceSegment>()
        for (element in phrase.elements) {
            when (element) {
                is VoicePhrase.Element.Clip -> {
                    if (VoiceClipCatalog.text(element.id, language) == null) return null
                    result.add(VoiceSegment.Clip(element.id))
                }
                VoicePhrase.Element.Pause -> if (result.isNotEmpty() && result.last() != VoiceSegment.Pause) result.add(VoiceSegment.Pause)
                is VoicePhrase.Element.Distance -> {
                    val ids = distanceIDs(element.meters, language) ?: return null
                    result += ids.map { VoiceSegment.Clip(it) }
                }
                is VoicePhrase.Element.Meters -> {
                    val ids = meterIDs(element.count, language) ?: return null
                    result += ids.map { VoiceSegment.Clip(it) }
                }
                is VoicePhrase.Element.Speed -> {
                    if (!isRecordedSpeed(element.kmh)) return null
                    result += listOf(VoiceSegment.Clip(numberID(element.kmh)), VoiceSegment.Clip(if (language == RVLang.UZ) "km" else "kmh"))
                }
            }
        }
        while (result.lastOrNull() == VoiceSegment.Pause) result.removeAt(result.size - 1)
        return if (result.isEmpty()) null else result
    }

    /** Only the clip ids (pauses dropped), in playback order; null when some element has no recording. */
    fun clipIDs(phrase: VoicePhrase, language: RVLang): List<String>? =
        segments(phrase, language)?.mapNotNull { (it as? VoiceSegment.Clip)?.id }

    /** Resource names ("uz_turn_right") of the clips, null when not expressible. */
    fun resourceNames(phrase: VoicePhrase, language: RVLang): List<String>? =
        clipIDs(phrase, language)?.map { VoiceClipCatalog.resourceName(it, language) }

    /** Text for the system voice: `phrase.text` if set, otherwise the clip texts joined into a sentence. */
    fun text(phrase: VoicePhrase, language: RVLang): String {
        val t = phrase.text
        if (t != null && t.isNotBlank()) return t
        return composedText(phrase, language) ?: ""
    }

    /** The clip texts joined into one sentence ("300 metrdan keyin o‘ngga buriling, ehtiyot bo‘ling"). */
    fun composedText(phrase: VoicePhrase, language: RVLang): String? {
        val segments = segments(phrase, language) ?: return null
        val text = StringBuilder()
        for (segment in segments) {
            when (segment) {
                VoiceSegment.Pause -> text.append(",")
                is VoiceSegment.Clip -> {
                    val part = VoiceClipCatalog.text(segment.id, language) ?: return null
                    if (text.isEmpty()) text.append(part) else text.append(" ").append(lowercasingFirst(part))
                }
            }
        }
        return capitalizingFirst(text.toString())
    }

    /** "300 metrdan keyin" → ["n_300", "after_meters"], "через 1,5 км" → ["through", "n_1_5", "km_few"]. */
    fun distanceIDs(meters: Double, language: RVLang): List<String>? {
        val distance = VoiceDistance.rounded(meters) ?: return null
        val number = distance.numberID
        return when (language) {
            RVLang.UZ -> when (distance) {
                is VoiceDistance.Meters -> listOf(number, "after_meters")
                is VoiceDistance.Kilometers -> listOf(number, "after_km")
            }
            RVLang.RU -> when (distance) {
                is VoiceDistance.Meters -> listOf("through", number, russianPlural(distance.value, "meter_one", "meter_few", "meters"))
                is VoiceDistance.Kilometers -> {
                    // A fractional number takes the genitive singular: "полтора километра", "два с половиной километра".
                    val unit = if (distance.tenths % 10 == 0) russianPlural(distance.tenths / 10, "km_one", "km_few", "km") else "km_few"
                    listOf("through", number, unit)
                }
            }
            RVLang.EN -> when (distance) {
                is VoiceDistance.Meters -> listOf("in", number, if (distance.value == 1) "meter_one" else "meters")
                is VoiceDistance.Kilometers -> listOf("in", number, if (distance.tenths == 10) "km_one" else "km")
            }
        }
    }

    /**
     * "25 metr" / "25 метров" / "25 metres"; the number is rounded to a recorded one (multiples of 5 up to 130,
     * then the distance steps up to 900). null for ≤ 0 or > 950.
     */
    fun meterIDs(n: Int, language: RVLang): List<String>? {
        if (!(n > 0 && n <= 950)) return null
        val value = if (n <= 130) max(5, (n / 5.0).rounded().toInt() * 5)
        else VoiceDistance.meterSteps.minByOrNull { abs(it - n) } ?: n
        return when (language) {
            RVLang.UZ -> listOf(numberID(value), "meters")
            RVLang.RU -> listOf(numberID(value), russianPlural(value, "meter_one", "meter_few", "meters"))
            RVLang.EN -> listOf(numberID(value), if (value == 1) "meter_one" else "meters")
        }
    }

    internal fun russianPlural(n: Int, one: String, few: String, many: String): String = RVFormat.plural(n, one, few, many)

    internal fun lowercasingFirst(s: String): String {
        if (s.isEmpty()) return s
        // Keep acronyms ("STOP", "YTH") as they are.
        if (s.length >= 2 && s[1].isUpperCase()) return s
        return s[0].lowercase() + s.substring(1)
    }

    internal fun capitalizingFirst(s: String): String {
        if (s.isEmpty()) return s
        return s[0].uppercase() + s.substring(1)
    }

    /**
     * Roundabout exit number (1…8) mentioned in an instruction: digits ("2-chiqish", "2-й съезд", "2nd exit") or an
     * ordinal word (Russian / English / Uzbek). null when none is found.
     */
    fun roundaboutExit(instruction: String): Int? {
        val s = instruction.lowercase()
        val digits = StringBuilder()
        for (ch in s) {
            if (ch in '0'..'9') digits.append(ch)
            else if (digits.isNotEmpty()) break
        }
        val n = digits.toString().toIntOrNull()
        if (n != null && n in 1..8) return n
        val words: List<Pair<Int, List<String>>> = listOf(
            1 to listOf("перв", "first", "birinchi"), 2 to listOf("втор", "second", "ikkinchi"),
            3 to listOf("трет", "third", "uchinchi"), 4 to listOf("четв", "fourth", "to‘rtinchi", "to'rtinchi"),
            5 to listOf("пят", "fifth", "beshinchi"), 6 to listOf("шест", "sixth", "oltinchi"),
            7 to listOf("седьм", "seventh", "yettinchi"), 8 to listOf("восьм", "eighth", "sakkizinchi"),
        )
        // Only look at ordinal words before "съезд" / "exit" / "chiqish".
        for ((num, stems) in words) {
            for (stem in stems) {
                val idx = s.indexOf(stem)
                if (idx >= 0) {
                    val tail = s.substring(idx + stem.length)
                    if (tail.contains("съезд") || tail.contains("выезд") || tail.contains("exit") || tail.contains("chiqish")) return num
                }
            }
        }
        return null
    }
}
