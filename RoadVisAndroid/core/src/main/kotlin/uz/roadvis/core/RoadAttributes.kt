package uz.roadvis.core

/** One arrow value of an OSM `turn:lanes` entry. */
enum class LaneTurn(val raw: String) {
    LEFT("left"),
    SLIGHT_LEFT("slight_left"),
    SHARP_LEFT("sharp_left"),
    THROUGH("through"),
    RIGHT("right"),
    SLIGHT_RIGHT("slight_right"),
    SHARP_RIGHT("sharp_right"),
    REVERSE("reverse"),
    MERGE_TO_LEFT("merge_to_left"),
    MERGE_TO_RIGHT("merge_to_right"),
    NONE("none");

    /** SF Symbol name of the lane arrow (kept from iOS; map to a drawable in the app). */
    val symbolName: String
        get() = when (this) {
            LEFT, SHARP_LEFT -> "arrow.turn.up.left"
            SLIGHT_LEFT -> "arrow.up.left"
            THROUGH, NONE -> "arrow.up"
            RIGHT, SHARP_RIGHT -> "arrow.turn.up.right"
            SLIGHT_RIGHT -> "arrow.up.right"
            REVERSE -> "arrow.uturn.down"
            MERGE_TO_LEFT -> "arrow.up.left"
            MERGE_TO_RIGHT -> "arrow.up.right"
        }

    companion object {
        fun fromRaw(raw: String): LaneTurn? = entries.firstOrNull { it.raw == raw }
    }
}

/** One lane with its allowed turn directions (from `turn:lanes`). Empty `turns` = unknown / any. */
data class Lane(val turns: List<LaneTurn>)

/** Lane configuration of a road for the travel direction of the user. */
data class LaneInfo(
    /** Value of the OSM `lanes` tag (both directions together). */
    val totalLanes: Int?,
    /** Lanes available in the user's travel direction. */
    val lanesInDirection: Int?,
    /** Lanes of the opposite direction. */
    val lanesOpposite: Int?,
    /** Per-lane arrows for the user's direction, ordered left → right. May be empty when `turn:lanes` is not mapped. */
    val lanes: List<Lane>,
    val isOneway: Boolean,
    /** True when the lane count is inferred from the road class because no `lanes` tag exists. */
    val isEstimated: Boolean,
) {
    companion object {
        val unknown = LaneInfo(null, null, null, emptyList(), isOneway = false, isEstimated = true)
    }
}

/** A speed limit parsed from OSM `maxspeed`. */
data class SpeedLimit(
    val kmh: Int,
    /** Raw tag value, e.g. "60", "RU:urban". */
    val raw: String,
    /** True for zone codes ("RU:urban") resolved through the national default table. */
    val isImplicit: Boolean,
)
