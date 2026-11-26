package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

/** Object classes the recognizer cares about. Raw values are stable identifiers (used in CSV logs). */
enum class VehicleKind(val raw: String) {
    CAR("car"),
    TRUCK("truck"),
    BUS("bus"),
    MOTORCYCLE("motorcycle"),
    BICYCLE("bicycle"),
    PERSON("person"),
    TRAFFIC_LIGHT("trafficLight"),
    STOP_SIGN("stopSign"),
    OTHER("other");

    /** Russian display name used in the UI. */
    val displayName: String
        get() = when (this) {
            CAR -> "Легковой"
            TRUCK -> "Грузовик"
            BUS -> "Автобус"
            MOTORCYCLE -> "Мотоцикл"
            BICYCLE -> "Велосипед"
            PERSON -> "Пешеход"
            TRAFFIC_LIGHT -> "Светофор"
            STOP_SIGN -> "Знак STOP"
            OTHER -> "Объект"
        }

    /** SF Symbol name (iOS); kept for reference, the Android UI maps kinds to its own icons. */
    val symbolName: String
        get() = when (this) {
            CAR -> "car.fill"
            TRUCK -> "truck.box.fill"
            BUS -> "bus.fill"
            MOTORCYCLE -> "motorcycle"
            BICYCLE -> "bicycle"
            PERSON -> "figure.walk"
            TRAFFIC_LIGHT -> "light.beacon.max.fill"
            STOP_SIGN -> "octagon.fill"
            OTHER -> "questionmark.square"
        }

    /** True for road vehicles that are counted and tracked. */
    val isVehicle: Boolean
        get() = this == CAR || this == TRUCK || this == BUS || this == MOTORCYCLE || this == BICYCLE

    /** Typical physical height in metres (generic assumption) for rough monocular distance estimation. */
    val typicalHeightMeters: Double?
        get() = when (this) {
            CAR -> 1.5
            TRUCK -> 3.2
            BUS -> 3.1
            MOTORCYCLE -> 1.3
            BICYCLE -> 1.1
            PERSON -> 1.7
            else -> null
        }

    /** Typical rear-view width in metres (generic assumption) for the lead-vehicle distance estimate. */
    val typicalWidthMeters: Double?
        get() = when (this) {
            CAR -> 1.8
            TRUCK -> 2.5
            BUS -> 2.55
            MOTORCYCLE -> 0.8
            BICYCLE -> 0.6
            PERSON -> 0.5
            else -> null
        }

    companion object {
        fun fromRaw(raw: String): VehicleKind? = entries.firstOrNull { it.raw == raw }

        /**
         * Maps a detector label (Swift `init?(label:)`). Accepts COCO names ("car", "traffic light"), snake/camel
         * case, and common custom-dataset names ("van", "minibus", "lorry", "motorbike", "scooter").
         */
        fun fromLabel(label: String): VehicleKind? {
            val l = label.lowercase().replace("_", " ").replace("-", " ").trim()
            return when (l) {
                "car", "sedan", "suv", "hatchback", "taxi", "pickup", "pickup truck", "van", "minivan", "jeep" -> CAR
                "truck", "lorry", "trailer", "tractor", "heavy truck", "light truck" -> TRUCK
                "bus", "minibus", "coach", "trolleybus" -> BUS
                "motorcycle", "motorbike", "moped", "scooter", "motor" -> MOTORCYCLE
                "bicycle", "bike", "cyclist" -> BICYCLE
                "person", "pedestrian", "people", "rider" -> PERSON // "rider": BDD100K class
                "traffic light", "trafficlight", "traffic signal" -> TRAFFIC_LIGHT
                "stop sign", "stopsign" -> STOP_SIGN
                else -> null
            }
        }

        /** COCO-80 class index (as used by Ultralytics YOLO models trained on COCO). */
        fun fromCocoIndex(cocoIndex: Int): VehicleKind? = when (cocoIndex) {
            0 -> PERSON
            1 -> BICYCLE
            2 -> CAR
            3 -> MOTORCYCLE
            5 -> BUS
            7 -> TRUCK
            9 -> TRAFFIC_LIGHT
            11 -> STOP_SIGN
            else -> null
        }
    }
}

/**
 * Normalized bounding box in image space: origin top-left, x to the right, y down, all values 0...1.
 * (Bottom-left-origin rects convert with [BBox.fromVision].)
 */
data class BBox(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val minY: Double get() = y
    val maxX: Double get() = x + width
    val maxY: Double get() = y + height
    val midX: Double get() = x + width / 2
    val midY: Double get() = y + height / 2
    val area: Double get() = max(0.0, width) * max(0.0, height)

    /** Vision-style rect origin y (bottom-left origin). */
    val visionY: Double get() = 1 - y - height

    fun intersection(o: BBox): BBox? {
        val x0 = max(minX, o.minX); val y0 = max(minY, o.minY)
        val x1 = min(maxX, o.maxX); val y1 = min(maxY, o.maxY)
        if (!(x1 > x0 && y1 > y0)) return null
        return BBox(x0, y0, x1 - x0, y1 - y0)
    }

    /** Intersection over union, 0...1. */
    fun iou(o: BBox): Double {
        val i = intersection(o) ?: return 0.0
        val u = area + o.area - i.area
        return if (u > 0) i.area / u else 0.0
    }

    /** Clamps the box into the unit square. */
    val clamped: BBox
        get() {
            val x0 = min(1.0, max(0.0, minX)); val y0 = min(1.0, max(0.0, minY))
            val x1 = min(1.0, max(0.0, maxX)); val y1 = min(1.0, max(0.0, maxY))
            return BBox(x0, y0, max(0.0, x1 - x0), max(0.0, y1 - y0))
        }

    /** Linear interpolation between two boxes (t = 0 → this, t = 1 → other). */
    fun lerp(o: BBox, t: Double): BBox =
        BBox(x + (o.x - x) * t, y + (o.y - y) * t, width + (o.width - width) * t, height + (o.height - height) * t)

    companion object {
        /** Creates a box from Vision-style normalized coordinates (origin bottom-left). */
        fun fromVision(visionX: Double, visionY: Double, width: Double, height: Double): BBox =
            BBox(visionX, 1 - visionY - height, width, height)
    }
}

/** Colour state of a detected traffic light, estimated from pixel colours (heuristic). */
enum class TrafficLightColor(val raw: String) {
    RED("red"), YELLOW("yellow"), GREEN("green"), UNKNOWN("unknown");

    val displayName: String
        get() = when (this) {
            RED -> "Красный"
            YELLOW -> "Жёлтый"
            GREEN -> "Зелёный"
            UNKNOWN -> "Не определён"
        }

    companion object {
        fun fromRaw(raw: String): TrafficLightColor? = entries.firstOrNull { it.raw == raw }
    }
}

/** One detection on one frame (before tracking). */
data class Detection(
    val kind: VehicleKind,
    /** Detector label as returned by the model (e.g. "car"). */
    val label: String,
    /** Detector confidence 0...1 (model confidence, NOT accuracy). */
    val confidence: Double,
    val box: BBox,
    /** Optional per-frame make/brand classification of the crop. */
    val make: String? = null,
    val makeConfidence: Double? = null,
    /** Optional traffic light colour (only for TRAFFIC_LIGHT). */
    val lightColor: TrafficLightColor? = null,
    /** Optional per-frame person role (only for PERSON; colour heuristic, see [PersonRoleClassifier]). */
    val personRole: PersonRole? = null,
)
