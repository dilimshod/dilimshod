package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Per-class detector confidence thresholds — the single source used by the detector (decoder floor) and the tracker
 * (port of iOS `DetectionThresholds`).
 *
 * Every class threshold is `base + (slider − DEFAULT_GLOBAL)`: the settings slider moves all classes together (before,
 * the tracker applied hidden 0.5 / 0.55 floors the slider could not lower).
 *
 * Bases come from a measurement on BDD100K val (300 images, IoU 0.5, COCO-pretrained weights, zero-shot; US dashcam
 * data — nothing was measured on Uzbek roads): the lowest threshold that still gave ≥ 90 % precision was person 0.37 /
 * car 0.33 / traffic light 0.57 for YOLO11s at 544×960, and person 0.47 / car 0.36 / light 0.62 for YOLO11n at 640.
 * Truck / bus / two-wheeler / stop-sign values are reasoning (too few or mislabelled instances).
 */
object DetectionThresholds {
    /** Default of the settings slider (global threshold = threshold of cars / trucks / buses). */
    const val DEFAULT_GLOBAL = 0.30
    /**
     * Slider default of the Android app, which runs the smaller YOLO11n: in the same measurement YOLO11n needed
     * car 0.36 / person 0.47 for ≥ 90 % precision, so the whole table sits 0.05 higher (car 0.35, person 0.45,
     * traffic light 0.55).
     */
    const val DEFAULT_GLOBAL_NANO = 0.35
    /** Per-class thresholds at the default slider position. */
    val classBase: Map<VehicleKind, Double> = mapOf(
        VehicleKind.CAR to 0.30, VehicleKind.TRUCK to 0.30, VehicleKind.BUS to 0.30,
        VehicleKind.MOTORCYCLE to 0.35, VehicleKind.BICYCLE to 0.35,
        VehicleKind.PERSON to 0.40,
        // Traffic lights: 0.30 (was 0.50). Two measurements pull in opposite directions: on BDD100K box precision
        // was only ≈ 50–58 % at 0.25, while on a LISA sample (YOLO11n, 640 input) recall of annotated lights was
        // 36.7 % by day / 0.2 % at night at 0.5 and 53.7 % / 11.9 % at 0.25. Recall wins here because a low-score
        // light box alone drives nothing: the indicator, the coach and the red-light event additionally need a
        // stable KNOWN colour (`TrafficLightColorVote`, `TrafficLightSelection`).
        VehicleKind.TRAFFIC_LIGHT to 0.30,
        VehicleKind.STOP_SIGN to 0.55,
        VehicleKind.OTHER to 0.30,
    )
    /** Bounds of any effective threshold. */
    const val MINIMUM = 0.10
    const val MAXIMUM = 0.90
    /**
     * A confirmed track may be continued by a detection scoring down to `threshold × CONTINUATION_FACTOR` (new tracks
     * always need the full threshold). ByteTrack-style low-score association; a conservative choice by reasoning, not
     * a measurement.
     */
    const val CONTINUATION_FACTOR = 0.7
    /** Lowest value ever handed to the detector's own confidence / NMS stage. */
    const val DETECTOR_FLOOR_MINIMUM = 0.05

    /** Threshold of one class for the given slider value. */
    fun threshold(kind: VehicleKind, global: Double = DEFAULT_GLOBAL): Double {
        val base = classBase[kind] ?: DEFAULT_GLOBAL
        val value = base + ((if (global.isFinite()) global else DEFAULT_GLOBAL) - DEFAULT_GLOBAL)
        return min(MAXIMUM, max(MINIMUM, value))
    }

    /** Thresholds of all classes for the given slider value (what the tracker needs to open a track). */
    fun perClass(global: Double = DEFAULT_GLOBAL): Map<VehicleKind, Double> =
        VehicleKind.entries.associateWith { threshold(it, global) }

    /** Confidence floor for the detector itself: the smallest class threshold times [continuationFactor]. */
    fun detectorFloor(global: Double = DEFAULT_GLOBAL, continuationFactor: Double = CONTINUATION_FACTOR): Double {
        val lowest = perClass(global).values.minOrNull() ?: DEFAULT_GLOBAL
        return max(DETECTOR_FLOOR_MINIMUM, lowest * min(1.0, max(0.0, continuationFactor)))
    }
}

/**
 * Removes boxes that the per-class NMS leaves on one object under two confusable classes (car + truck, car + bus,
 * motorcycle + bicycle). Persons are never merged with vehicles (port of iOS `CrossClassDuplicates`).
 */
object CrossClassDuplicates {
    /**
     * IoU from which two boxes of one confusable group are the same object. Measured on BDD100K val (conf ≥ 0.35):
     * per-class NMS left such pairs in 14 % of frames with YOLO11s at 544×960 (2.5 % of vehicle boxes) and 7 % of
     * frames with YOLO11n at 640.
     */
    const val IOU_THRESHOLD = 0.7

    /** 0 = car / truck / bus, 1 = motorcycle / bicycle, null = never merged across classes. */
    internal fun group(kind: VehicleKind): Int? = when (kind) {
        VehicleKind.CAR, VehicleKind.TRUCK, VehicleKind.BUS -> 0
        VehicleKind.MOTORCYCLE, VehicleKind.BICYCLE -> 1
        else -> null
    }

    /**
     * Returns [detections] (order kept) without the lower-scored box of every cross-class pair of one group whose IoU
     * is at least [iouThreshold]. Same-class pairs are left to the detector's own NMS.
     */
    fun suppress(detections: List<Detection>, iouThreshold: Double = IOU_THRESHOLD): List<Detection> {
        if (detections.size <= 1) return detections
        val order = detections.indices.sortedWith(compareByDescending<Int> { detections[it].confidence }.thenBy { it })
        val kept = ArrayList<Int>(detections.size)
        val removed = BooleanArray(detections.size)
        for (index in order) {
            val candidate = detections[index]
            val group = group(candidate.kind)
            if (group != null && kept.any { k ->
                    val other = detections[k]
                    other.kind != candidate.kind && group(other.kind) == group && other.box.iou(candidate.box) >= iouThreshold
                }) {
                removed[index] = true
                continue
            }
            kept.add(index)
        }
        return detections.filterIndexed { i, _ -> !removed[i] }
    }
}

/** How a camera frame is fitted into a fixed-size detector input. */
enum class DetectorInputFit {
    /** Aspect ratios (almost) match: the frame is stretched over the whole input. */
    FILL,
    /** Aspect kept, centred, padded; boxes must be un-letterboxed. */
    LETTERBOX,
}

/** Geometry of one detector input versus one frame size (port of iOS `DetectorInputGeometry`). */
data class DetectorInputGeometry(
    val inputWidth: Double,
    val inputHeight: Double,
    val sourceWidth: Double,
    val sourceHeight: Double,
) {
    /** |inputAspect / sourceAspect − 1|; infinity for degenerate sizes. */
    val aspectMismatch: Double
        get() = if (inputWidth > 0 && inputHeight > 0 && sourceWidth > 0 && sourceHeight > 0)
            abs((inputWidth / inputHeight) / (sourceWidth / sourceHeight) - 1) else Double.POSITIVE_INFINITY

    val fit: DetectorInputFit get() = if (aspectMismatch < FILL_TOLERANCE) DetectorInputFit.FILL else DetectorInputFit.LETTERBOX

    /** Share of the model input covered by the picture (1 for [DetectorInputFit.FILL]). */
    val usedInputFraction: Double
        get() {
            if (fit != DetectorInputFit.LETTERBOX || !(inputWidth > 0 && inputHeight > 0 && sourceWidth > 0 && sourceHeight > 0)) return 1.0
            val gain = min(inputWidth / sourceWidth, inputHeight / sourceHeight)
            return (sourceWidth * gain) * (sourceHeight * gain) / (inputWidth * inputHeight)
        }

    /** Maps a box normalised to the model input (top-left origin) to a box normalised to the frame. */
    fun frameBox(box: BBox): BBox {
        if (fit != DetectorInputFit.LETTERBOX) return box.clamped
        val gain = min(inputWidth / sourceWidth, inputHeight / sourceHeight)
        val padX = (inputWidth - sourceWidth * gain) / 2
        val padY = (inputHeight - sourceHeight * gain) / 2
        val x1 = (box.minX * inputWidth - padX) / gain / sourceWidth
        val x2 = (box.maxX * inputWidth - padX) / gain / sourceWidth
        val y1 = (box.minY * inputHeight - padY) / gain / sourceHeight
        val y2 = (box.maxY * inputHeight - padY) / gain / sourceHeight
        return BBox(x1, y1, x2 - x1, y2 - y1).clamped
    }

    companion object {
        /** Relative aspect mismatch up to which stretching is used instead of a letterbox. */
        const val FILL_TOLERANCE = 0.05

        /** True for frames at least as wide as high (the landscape input is used). */
        fun isLandscape(width: Double, height: Double): Boolean = width >= height
    }
}

/**
 * Chooses between the full and the lite detector from the measured inference time (port of iOS
 * `DetectorQualityGovernor`). Nothing in this project was timed on a phone, so the heavier configuration is used only
 * while the app's own `inferenceMs` shows that the device keeps up.
 * Android: FULL = 544×960, LITE = 384×640 input of the same YOLO11n. iOS: FULL = YOLO11s, LITE = YOLO11n.
 */
class DetectorQualityGovernor(val config: Config) {
    enum class Level { FULL, LITE }

    data class Config(
        val startLevel: Level,
        /** FULL mean inference time above which the detector drops to LITE, ms. */
        val downgradeAboveMs: Double,
        /** LITE mean inference time below which FULL is tried, ms (keep under downgradeAboveMs / cost ratio). */
        val upgradeBelowMs: Double,
        /** Frames averaged for a decision. */
        val windowFrames: Int = 30,
        /** Frames ignored after a level change (session creation, warm-up). */
        val settleFrames: Int = 5,
        /** Seconds on LITE after a downgrade before FULL is tried again; doubled after every failed upgrade. */
        val retrySeconds: Double = 30.0,
        val maxRetrySeconds: Double = 480.0,
        /** A downgrade this soon after an upgrade counts as a failed upgrade. */
        val failedUpgradeSeconds: Double = 20.0,
    ) {
        companion object {
            /** YOLO11s ↔ YOLO11n; the way back assumes s ≈ 3.3× n (FLOPs estimate, not a device measurement). */
            val iOS = Config(Level.FULL, downgradeAboveMs = 55.0, upgradeBelowMs = 15.0)
            /**
             * 544×960 ↔ 384×640 of YOLO11n, starting small. Measured cost ratio (ONNX Runtime, 1 CPU thread, x86):
             * 1.29 / 0.58 = 2.2×, so the way up is 70 / 2.2 ≈ 31 ms, rounded down. 70 ms ≈ the 66 ms frame budget of
             * the 15 fps pipeline.
             */
            val android = Config(Level.LITE, downgradeAboveMs = 70.0, upgradeBelowMs = 30.0)
        }
    }

    var level: Level = config.startLevel
        private set
    private var sum = 0.0
    private var count = 0
    private var skip = max(0, config.settleFrames)
    private var lastUpgradeAt: Double? = null
    private var liteSince: Double? = null
    private var currentRetry = config.retrySeconds

    /**
     * Feeds one frame; returns the level to use for the next frames. [constrained] = the device asks for less work
     * (thermal status severe or worse).
     */
    fun record(inferenceMs: Double, constrained: Boolean = false, timestamp: Double): Level {
        if (level == Level.LITE && liteSince == null) liteSince = timestamp
        if (constrained) {
            if (level == Level.FULL) downgrade(timestamp)
            liteSince = timestamp
            resetWindow()
            return level
        }
        if (!inferenceMs.isFinite() || inferenceMs < 0) return level
        if (skip > 0) {
            skip -= 1
            return level
        }
        sum += inferenceMs
        count += 1
        if (count < max(1, config.windowFrames)) return level
        val mean = sum / count
        sum = 0.0
        count = 0
        when (level) {
            Level.FULL -> if (mean > config.downgradeAboveMs) downgrade(timestamp)
            Level.LITE -> {
                val waited = timestamp - (liteSince ?: timestamp)
                val needed = if (config.startLevel == Level.LITE && lastUpgradeAt == null) 0.0 else currentRetry
                if (mean < config.upgradeBelowMs && waited >= needed) {
                    level = Level.FULL
                    lastUpgradeAt = timestamp
                    liteSince = null
                    resetWindow()
                }
            }
        }
        return level
    }

    /** Back to the start level (new drive). */
    fun reset() {
        level = config.startLevel
        lastUpgradeAt = null
        liteSince = null
        currentRetry = config.retrySeconds
        resetWindow()
    }

    private fun downgrade(timestamp: Double) {
        val upgraded = lastUpgradeAt
        currentRetry = if (upgraded != null && timestamp - upgraded <= config.failedUpgradeSeconds)
            min(config.maxRetrySeconds, currentRetry * 2) else config.retrySeconds
        level = Level.LITE
        liteSince = timestamp
        resetWindow()
    }

    private fun resetWindow() {
        sum = 0.0
        count = 0
        skip = max(0, config.settleFrames)
    }
}
