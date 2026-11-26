package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** A decoded detection before class mapping. */
data class RawDetection(
    /** Normalized box in the source image (top-left origin). */
    val box: BBox,
    val score: Double,
    val classIndex: Int,
)

/** Decoder for raw (non-NMS) Ultralytics YOLO outputs (CoreML / TFLite / ONNX tensors as flat row-major floats). */
object YOLODecoder {
    /**
     * Decodes a raw YOLO output tensor given as contiguous row-major Float values.
     *  - `[1, 4+nc, N]` (YOLOv8 / YOLO11): rows 0–3 = cx, cy, w, h in input pixels, then class scores → NMS.
     *  - `[1, N, 6]` (YOLO26 / YOLOv10 end-to-end): x1, y1, x2, y2, score, class in input pixels → no NMS.
     * The layout is detected from the shape (end-to-end when the last dimension is 6 and smaller than the middle one).
     * [sourceWidth]/[sourceHeight]: size of the image letterboxed into the input; null when it was stretched.
     */
    fun decode(
        values: FloatArray, shape: List<Int>, inputWidth: Double, inputHeight: Double,
        confidenceThreshold: Double, iouThreshold: Double, maxDetections: Int = 100,
        sourceWidth: Double? = null, sourceHeight: Double? = null,
    ): List<RawDetection> {
        var dims = shape.dropWhile { it == 1 }
        if (dims.size < 2) dims = shape
        if (!(dims.size >= 2 && inputWidth > 0 && inputHeight > 0)) return emptyList()
        val a = dims[dims.size - 2]; val b = dims[dims.size - 1]
        if (!(a > 0 && b > 0 && values.size >= a * b)) return emptyList()

        val mapper = CoordinateMapper(inputWidth, inputHeight, sourceWidth, sourceHeight)
        val detections = mutableListOf<RawDetection>()

        if (b == 6 && a > b) {
            for (i in 0 until a) {
                val base = i * 6
                val score = values[base + 4].toDouble()
                if (!(score >= confidenceThreshold && score.isFinite())) continue
                val cls = values[base + 5].toDouble().rounded().toInt()
                val box = mapper.box(values[base].toDouble(), values[base + 1].toDouble(),
                    values[base + 2].toDouble(), values[base + 3].toDouble())
                if (box != null) detections.add(RawDetection(box, score, cls))
            }
            return detections.sortedByDescending { it.score }.take(maxDetections)
        }

        val channelsFirst = a < b
        val channels = if (channelsFirst) a else b
        val count = if (channelsFirst) b else a
        if (channels <= 4) return emptyList()
        fun value(c: Int, i: Int): Float = if (channelsFirst) values[c * count + i] else values[i * channels + c]
        for (i in 0 until count) {
            var bestScore = 0f
            var bestClass = -1
            for (c in 4 until channels) {
                val s = value(c, i)
                if (s > bestScore) { bestScore = s; bestClass = c - 4 }
            }
            val score = bestScore.toDouble()
            if (!(bestClass >= 0 && score >= confidenceThreshold && score.isFinite())) continue
            val cx = value(0, i).toDouble(); val cy = value(1, i).toDouble()
            val w = value(2, i).toDouble(); val h = value(3, i).toDouble()
            val box = mapper.box(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
            if (box != null) detections.add(RawDetection(box, score, bestClass))
        }
        return nonMaxSuppression(detections, iouThreshold, classAware = true, maxDetections = maxDetections)
    }

    /** Greedy non-maximum suppression. */
    fun nonMaxSuppression(
        detections: List<RawDetection>, iouThreshold: Double,
        classAware: Boolean = true, maxDetections: Int = 100,
    ): List<RawDetection> {
        val sorted = detections.sortedByDescending { it.score }
        val kept = mutableListOf<RawDetection>()
        for (d in sorted) {
            if (kept.size >= maxDetections) break
            val suppressed = kept.any { k -> (!classAware || k.classIndex == d.classIndex) && k.box.iou(d.box) > iouThreshold }
            if (!suppressed) kept.add(d)
        }
        return kept
    }

    /** Maps input-pixel coordinates to normalized source-image coordinates (undoing a letterbox if needed). */
    internal class CoordinateMapper(
        val inputWidth: Double, val inputHeight: Double, sourceWidth: Double?, sourceHeight: Double?,
    ) {
        val gain: Double
        val padX: Double
        val padY: Double
        val srcW: Double
        val srcH: Double

        init {
            if (sourceWidth != null && sourceHeight != null && sourceWidth > 0 && sourceHeight > 0) {
                val g = min(inputWidth / sourceWidth, inputHeight / sourceHeight)
                gain = g
                padX = (inputWidth - sourceWidth * g) / 2
                padY = (inputHeight - sourceHeight * g) / 2
                srcW = sourceWidth; srcH = sourceHeight
            } else {
                gain = 0.0; padX = 0.0; padY = 0.0; srcW = 0.0; srcH = 0.0
            }
        }

        fun box(x1: Double, y1: Double, x2: Double, y2: Double): BBox? {
            val nx1: Double; val ny1: Double; val nx2: Double; val ny2: Double
            if (gain > 0) {
                nx1 = (x1 - padX) / gain / srcW
                nx2 = (x2 - padX) / gain / srcW
                ny1 = (y1 - padY) / gain / srcH
                ny2 = (y2 - padY) / gain / srcH
            } else {
                nx1 = x1 / inputWidth; nx2 = x2 / inputWidth
                ny1 = y1 / inputHeight; ny2 = y2 / inputHeight
            }
            val box = BBox(min(nx1, nx2), min(ny1, ny2), abs(nx2 - nx1), abs(ny2 - ny1)).clamped
            return if (box.width > 0.002 && box.height > 0.002) box else null
        }
    }
}

object COCOLabels {
    /** The 80 COCO class names in Ultralytics order (index = class id). */
    val names: List<String> = listOf(
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard",
        "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch",
        "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
        "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
        "scissors", "teddy bear", "hair drier", "toothbrush",
    )

    fun name(index: Int): String = if (index in names.indices) names[index] else "class$index"
}
