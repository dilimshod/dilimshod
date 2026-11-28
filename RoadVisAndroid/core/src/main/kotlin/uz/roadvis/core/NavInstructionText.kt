package uz.roadvis.core

import kotlin.math.abs

/**
 * Turn-by-turn instruction text in Uzbek (Latin) and English, built from engine maneuver data.
 * Russian OSRM text stays in [OSRM.instruction]; Valhalla returns its own narrative for ru / en.
 *
 * Street names are attached with postpositions that need no suffixes ("Navoiy ko‘chasi tomon",
 * "… bo‘ylab"), so names in any script read correctly. Uzbek ordinals use the written "2-chiqish" form.
 */
object NavInstructionText {

    // OSRM-style (type + modifier)

    /** Instruction for an OSRM maneuver `type` / `modifier` in [language] (ru delegates to [OSRM.instruction]). */
    fun osrm(type: String, modifier: String?, name: String?, exit: Int? = null, rotaryName: String? = null,
             language: RVLang): String = when (language) {
        RVLang.RU -> OSRM.instruction(type, modifier, name, exit, rotaryName)
        RVLang.UZ -> uzbek(type, modifier, name, exit, rotaryName)
        RVLang.EN -> english(type, modifier, name, exit, rotaryName)
    }

    /** -1 left, 1 right, 0 straight / none. */
    internal fun side(modifier: String?): Int {
        if (modifier == null) return 0
        if (modifier.contains("left")) return -1
        if (modifier.contains("right")) return 1
        return 0
    }

    // Uzbek

    internal fun uzbek(type: String, modifier: String?, name: String?, exit: Int?, rotaryName: String?): String {
        val onto = name?.let { ", $it tomon" } ?: ""
        fun along(verb: String): String = name?.let { "$it bo‘ylab ${verb.rvLowercasedFirst()}" } ?: verb
        return when (type) {
            "depart" -> along("Harakatni boshlang")
            "arrive" -> when (side(modifier)) {
                -1 -> "Manzil chap tomonda"
                1 -> "Manzil o‘ng tomonda"
                else -> "Manzil"
            }
            "roundabout", "rotary" -> {
                val circle = rotaryName?.let { "«$it» aylanma harakatida" } ?: "Aylanma harakatda"
                if (exit != null && exit > 0) "$circle $exit-chiqishdan chiqing$onto"
                else "Aylanma harakatga kiring$onto"
            }
            "roundabout turn" -> "Aylanma harakatda " + uzbekTurn(modifier).rvLowercasedFirst() + onto
            "exit roundabout", "exit rotary" -> "Aylanma harakatdan chiqing$onto"
            "merge" -> when (side(modifier)) {
                -1 -> "Chapga o‘tib, oqimga qo‘shiling$onto"
                1 -> "O‘ngga o‘tib, oqimga qo‘shiling$onto"
                else -> "Oqimga qo‘shiling$onto"
            }
            "on ramp" -> "${uzbekDirection(modifier)} burilib, kirish yo‘liga chiqing$onto"
            "off ramp" -> "${uzbekDirection(modifier)} burilib, chiqish yo‘liga o‘ting$onto"
            "fork" -> when (side(modifier)) {
                -1 -> "Ayrilishda chap tomonda qoling$onto"
                1 -> "Ayrilishda o‘ng tomonda qoling$onto"
                else -> "Ayrilishda to‘g‘riga yuring$onto"
            }
            "end of road" -> "Yo‘l oxirida " + uzbekTurn(modifier).rvLowercasedFirst() + onto
            "new name", "continue", "notification" ->
                if (modifier == null || modifier == "straight") {
                    if (name == null) "To‘g‘riga davom eting" else along("Davom eting")
                } else uzbekTurn(modifier) + onto
            "ferry" -> "Paromga chiqing$onto"
            "ferry exit" -> "Paromdan tushing$onto"
            else -> if (modifier == "straight") along("To‘g‘riga yuring") else uzbekTurn(modifier) + onto
        }
    }

    internal fun uzbekTurn(modifier: String?): String = when (modifier) {
        "uturn" -> "Orqaga qayriling"
        "sharp right" -> "Keskin o‘ngga buriling"
        "right" -> "O‘ngga buriling"
        "slight right" -> "Biroz o‘ngga buriling"
        "sharp left" -> "Keskin chapga buriling"
        "left" -> "Chapga buriling"
        "slight left" -> "Biroz chapga buriling"
        else -> "To‘g‘riga yuring"
    }

    internal fun uzbekDirection(modifier: String?): String {
        val s = side(modifier)
        return when {
            s == -1 -> "Chapga"
            s == 0 && modifier == "straight" -> "To‘g‘riga"
            else -> "O‘ngga"
        }
    }

    // English

    internal fun english(type: String, modifier: String?, name: String?, exit: Int?, rotaryName: String?): String {
        val onto = name?.let { " onto $it" } ?: ""
        val along = name?.let { " along $it" } ?: ""
        return when (type) {
            "depart" -> "Start driving$along"
            "arrive" -> when (side(modifier)) {
                -1 -> "Your destination is on the left"
                1 -> "Your destination is on the right"
                else -> "Your destination"
            }
            "roundabout", "rotary" -> {
                val circle = rotaryName?.let { "At $it roundabout" } ?: "At the roundabout"
                if (exit != null && exit > 0) "$circle, take the ${englishOrdinal(exit)} exit$onto"
                else "Enter the roundabout$onto"
            }
            "roundabout turn" -> "At the roundabout, " + englishTurn(modifier).rvLowercasedFirst() + onto
            "exit roundabout", "exit rotary" -> "Exit the roundabout$onto"
            "merge" -> when (side(modifier)) {
                -1 -> "Move left and merge$onto"
                1 -> "Move right and merge$onto"
                else -> "Merge$onto"
            }
            "on ramp" -> "Take the ramp ${englishDirection(modifier)}$onto"
            "off ramp" -> "Take the exit ${englishDirection(modifier)}$onto"
            "fork" -> when (side(modifier)) {
                -1 -> "At the fork, keep left$onto"
                1 -> "At the fork, keep right$onto"
                else -> "At the fork, continue straight$onto"
            }
            "end of road" -> "At the end of the road, " + englishTurn(modifier).rvLowercasedFirst() + onto
            "new name", "continue", "notification" ->
                if (modifier == null || modifier == "straight") {
                    if (name == null) "Continue straight" else "Continue$along"
                } else englishTurn(modifier) + onto
            "ferry" -> "Take the ferry$onto"
            "ferry exit" -> "Leave the ferry$onto"
            else -> if (modifier == "straight") "Go straight$along" else englishTurn(modifier) + onto
        }
    }

    internal fun englishTurn(modifier: String?): String = when (modifier) {
        "uturn" -> "Make a U-turn"
        "sharp right" -> "Turn sharp right"
        "right" -> "Turn right"
        "slight right" -> "Bear right"
        "sharp left" -> "Turn sharp left"
        "left" -> "Turn left"
        "slight left" -> "Bear left"
        else -> "Go straight"
    }

    internal fun englishDirection(modifier: String?): String {
        val s = side(modifier)
        return when {
            s == -1 -> "on the left"
            s == 0 && modifier == "straight" -> "straight ahead"
            else -> "on the right"
        }
    }

    /** 1 → "1st", 2 → "2nd", 3 → "3rd", 11 → "11th", 22 → "22nd". */
    fun englishOrdinal(n: Int): String {
        val mod100 = abs(n) % 100
        val mod10 = abs(n) % 10
        if (mod100 in 11..13) return "${n}th"
        return when (mod10) {
            1 -> "${n}st"
            2 -> "${n}nd"
            3 -> "${n}rd"
            else -> "${n}th"
        }
    }

    // Valhalla

    /** Valhalla maneuver type code → OSRM-style (type, modifier) used by the builders above. */
    fun osrmEquivalent(valhallaType: Int): Pair<String, String?> = when (valhallaType) {
        1 -> "depart" to null
        2 -> "depart" to "right"
        3 -> "depart" to "left"
        4 -> "arrive" to null
        5 -> "arrive" to "right"
        6 -> "arrive" to "left"
        7 -> "new name" to "straight"
        8 -> "continue" to "straight"
        9 -> "turn" to "slight right"
        10 -> "turn" to "right"
        11 -> "turn" to "sharp right"
        12, 13 -> "turn" to "uturn"
        14 -> "turn" to "sharp left"
        15 -> "turn" to "left"
        16 -> "turn" to "slight left"
        17 -> "on ramp" to "straight"
        18 -> "on ramp" to "right"
        19 -> "on ramp" to "left"
        20 -> "off ramp" to "right"
        21 -> "off ramp" to "left"
        22 -> "fork" to "straight"
        23 -> "fork" to "slight right"
        24 -> "fork" to "slight left"
        25 -> "merge" to null
        26 -> "roundabout" to null
        27 -> "exit roundabout" to null
        28 -> "ferry" to null
        29 -> "ferry exit" to null
        37 -> "merge" to "slight right"
        38 -> "merge" to "slight left"
        else -> "continue" to "straight"
    }

    /**
     * Instruction for a Valhalla maneuver rebuilt in [language] from its type code, street names and roundabout
     * exit count (used for Uzbek, which Valhalla does not narrate).
     * For a roundabout (type 26) [streetNames] name the circle itself; the exit street comes from
     * [roundaboutExitStreetNames] when Valhalla provides it.
     */
    fun valhalla(type: Int, streetNames: List<String>, roundaboutExitCount: Int? = null,
                 roundaboutExitStreetNames: List<String> = emptyList(), language: RVLang): String {
        val (t, modifier) = osrmEquivalent(type)
        fun first(names: List<String>): String? = names.firstOrNull()?.let { if (it.swiftTrim().isEmpty()) null else it }
        if (t == "roundabout") {
            return osrm(t, modifier, first(roundaboutExitStreetNames), roundaboutExitCount, first(streetNames), language)
        }
        return osrm(t, modifier, if (t == "arrive") null else first(streetNames), roundaboutExitCount, null, language)
    }

    // Misc

    /** Next-instruction text when no maneuver is left: "Вы прибыли" / "Пункт назначения" and translations. */
    fun destination(arrived: Boolean, language: RVLang): String = when (language) {
        RVLang.RU -> if (arrived) "Вы прибыли" else "Пункт назначения"
        RVLang.UZ -> if (arrived) "Manzilga yetib keldingiz" else "Manzil"
        RVLang.EN -> if (arrived) "You have arrived" else "Destination"
    }

    /** Fallback route name when the engine gives no street names ("Маршрут OSM" / "Маршрут OSRM"). */
    fun fallbackRouteName(engine: String, language: RVLang): String = when (language) {
        RVLang.RU -> "Маршрут $engine"
        RVLang.UZ -> "$engine yo‘nalishi"
        RVLang.EN -> "$engine route"
    }
}
