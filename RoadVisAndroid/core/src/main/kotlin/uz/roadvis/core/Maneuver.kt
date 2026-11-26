package uz.roadvis.core

/** Maneuver type derived from a turn-by-turn instruction text or an engine maneuver code. */
enum class ManeuverType(val raw: String) {
    DEPART("depart"), STRAIGHT("straight"), SLIGHT_LEFT("slightLeft"), LEFT("left"), SHARP_LEFT("sharpLeft"),
    SLIGHT_RIGHT("slightRight"), RIGHT("right"), SHARP_RIGHT("sharpRight"), U_TURN("uTurn"), ROUNDABOUT("roundabout"),
    MERGE("merge"), KEEP_LEFT("keepLeft"), KEEP_RIGHT("keepRight"), EXIT_LEFT("exitLeft"), EXIT_RIGHT("exitRight"),
    ARRIVE("arrive"), UNKNOWN("unknown");

    /** SF Symbol name for the maneuver banner (kept from iOS; map to a drawable in the app). */
    val symbolName: String
        get() = when (this) {
            DEPART -> "location.north.line.fill"
            STRAIGHT, UNKNOWN -> "arrow.up"
            SLIGHT_LEFT, KEEP_LEFT, EXIT_LEFT -> "arrow.up.left"
            LEFT, SHARP_LEFT -> "arrow.turn.up.left"
            SLIGHT_RIGHT, KEEP_RIGHT, EXIT_RIGHT -> "arrow.up.right"
            RIGHT, SHARP_RIGHT -> "arrow.turn.up.right"
            U_TURN -> "arrow.uturn.down"
            ROUNDABOUT -> "arrow.triangle.turn.up.right.circle"
            MERGE -> "arrow.merge"
            ARRIVE -> "flag.checkered"
        }

    /** Lane arrows that are suitable for this maneuver. */
    val compatibleLaneTurns: Set<LaneTurn>
        get() = when (this) {
            DEPART, STRAIGHT, MERGE, UNKNOWN -> setOf(LaneTurn.THROUGH, LaneTurn.NONE)
            LEFT -> setOf(LaneTurn.LEFT, LaneTurn.SHARP_LEFT, LaneTurn.SLIGHT_LEFT)
            SHARP_LEFT -> setOf(LaneTurn.SHARP_LEFT, LaneTurn.LEFT)
            SLIGHT_LEFT, KEEP_LEFT, EXIT_LEFT -> setOf(LaneTurn.SLIGHT_LEFT, LaneTurn.LEFT)
            RIGHT -> setOf(LaneTurn.RIGHT, LaneTurn.SHARP_RIGHT, LaneTurn.SLIGHT_RIGHT)
            SHARP_RIGHT -> setOf(LaneTurn.SHARP_RIGHT, LaneTurn.RIGHT)
            SLIGHT_RIGHT, KEEP_RIGHT, EXIT_RIGHT -> setOf(LaneTurn.SLIGHT_RIGHT, LaneTurn.RIGHT)
            U_TURN -> setOf(LaneTurn.REVERSE, LaneTurn.LEFT, LaneTurn.SHARP_LEFT)
            ROUNDABOUT, ARRIVE -> emptySet()
        }

    val isLeftward: Boolean
        get() = this in setOf(SLIGHT_LEFT, LEFT, SHARP_LEFT, KEEP_LEFT, EXIT_LEFT, U_TURN)

    val isRightward: Boolean
        get() = this in setOf(SLIGHT_RIGHT, RIGHT, SHARP_RIGHT, KEEP_RIGHT, EXIT_RIGHT)

    companion object {
        fun fromRaw(raw: String): ManeuverType? = entries.firstOrNull { it.raw == raw }
    }
}

object ManeuverClassifier {
    /** Classifies a step instruction (Russian, English or Uzbek Latin) by keywords. */
    fun classify(instruction: String): ManeuverType {
        val s = instruction.lowercase()
            .replace("ё", "е")
            .replace("ʻ", "'")
            .replace("’", "'")
            .replace("‘", "'")
        if (s.swiftTrim().isEmpty()) return ManeuverType.DEPART

        fun has(vararg words: String): Boolean = words.any { s.contains(it) }

        val left = has("налево", "левее", "влево", "слева", "left", "chapga", "chap ")
        val right = has("направо", "правее", "вправо", "справа", "right", "o'ngga", "ongga", "o'ng ")

        // Arrival
        if (has("пункт назначения", "прибыт", "место назначения", "вы на месте", "destination", "arrive",
                "manzil", "yetib keld")) {
            return ManeuverType.ARRIVE
        }
        // U-turn
        if (has("развернитесь", "разворот", "u-turn", "u turn", "make a u", "orqaga qayril", "burilib qayt", "qayriling")) {
            return ManeuverType.U_TURN
        }
        // Roundabout
        if (has("кругов", "кольц", "roundabout", "traffic circle", "rotary", "aylanma", "halqa")) {
            return ManeuverType.ROUNDABOUT
        }
        // Exits / ramps
        if (has("съезд", "exit", "ramp", "chiqish", "сверните на выезд")) {
            if (left) return ManeuverType.EXIT_LEFT
            return ManeuverType.EXIT_RIGHT
        }
        // Keep left / right at forks
        if (has("держитесь", "keep ", "keep left", "keep right", "перестройтесь", "ushlang", "tomonda qoling")) {
            if (left) return ManeuverType.KEEP_LEFT
            if (right) return ManeuverType.KEEP_RIGHT
        }
        // Merge
        if (has("merge", "влейтесь", "вливайтесь", "примкните", "qo'shiling")) {
            return ManeuverType.MERGE
        }
        // Sharp / slight turns
        val sharp = has("резко", "круто", "sharp", "keskin")
        val slight = has("плавно", "немного", "slight", "bear ", "sekin", "biroz")
        if (left) {
            if (sharp) return ManeuverType.SHARP_LEFT
            if (slight) return ManeuverType.SLIGHT_LEFT
            return ManeuverType.LEFT
        }
        if (right) {
            if (sharp) return ManeuverType.SHARP_RIGHT
            if (slight) return ManeuverType.SLIGHT_RIGHT
            return ManeuverType.RIGHT
        }
        // Straight
        if (has("прямо", "продолжайте", "двигайтесь", "следуйте", "continue", "straight", "head ", "proceed",
                "to'g'ri", "davom et")) {
            return ManeuverType.STRAIGHT
        }
        // Departure ("Начните движение…", "Выезжайте на …")
        if (has("начните", "выезжайте", "start", "depart", "harakatni boshlang")) {
            return ManeuverType.DEPART
        }
        return ManeuverType.UNKNOWN
    }
}

object LaneGuidance {
    /**
     * For each lane (left → right) whether it suits the maneuver.
     * Lanes without arrows count as "through". If no lane has a matching arrow, a turn falls back to the
     * outermost lane on that side; straight maneuvers fall back to all lanes without turn-only arrows.
     */
    fun recommendedLanes(lanes: List<Lane>, maneuver: ManeuverType): List<Boolean> {
        if (lanes.isEmpty()) return emptyList()
        val wanted = maneuver.compatibleLaneTurns
        if (wanted.isEmpty()) return lanes.map { false }

        val effective = lanes.map { if (it.turns.isEmpty()) listOf(LaneTurn.THROUGH) else it.turns }
        var result = effective.map { turns -> turns.any { wanted.contains(it) } }
        if (result.contains(true)) return result

        val out = MutableList(lanes.size) { false }
        if (maneuver.isLeftward) {
            out[0] = true
        } else if (maneuver.isRightward) {
            out[lanes.size - 1] = true
        } else {
            val turnOnly = setOf(LaneTurn.LEFT, LaneTurn.SHARP_LEFT, LaneTurn.RIGHT, LaneTurn.SHARP_RIGHT, LaneTurn.REVERSE)
            result = effective.map { turns -> !turns.all { turnOnly.contains(it) } }
            return result
        }
        return out
    }
}
