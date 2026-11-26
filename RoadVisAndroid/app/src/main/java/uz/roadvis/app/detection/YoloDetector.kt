package uz.roadvis.app.detection

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.content.Context
import android.os.SystemClock
import uz.roadvis.core.COCOLabels
import uz.roadvis.core.CrossClassDuplicates
import uz.roadvis.core.Detection
import uz.roadvis.core.DetectionThresholds
import uz.roadvis.core.DetectorInputGeometry
import uz.roadvis.core.DetectorQualityGovernor
import uz.roadvis.core.VehicleKind
import uz.roadvis.core.YOLODecoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/** Load state of an optional model (port of iOS `ModelStatus`). */
sealed class ModelStatus {
    data object Loading : ModelStatus()
    data class Ready(val name: String) : ModelStatus()
    data object Missing : ModelStatus()
    data class Failed(val message: String) : ModelStatus()

    val isReady: Boolean get() = this is Ready
    val modelName: String? get() = (this as? Ready)?.name
}

/**
 * YOLO11n object detector on ONNX Runtime (port of iOS `VehicleDetector` for raw `[1, 84, N]` outputs).
 *
 * One model file with dynamic `batch` / `height` / `width` dimensions serves four rectangular 16:9 inputs:
 * landscape frames 640×384 ([DetectorQualityGovernor.Level.LITE]) and 960×544 (FULL), portrait frames 384×640 and
 * 544×960. A session is created per input with fixed free-dimension overrides (so XNNPACK still sees static shapes),
 * lazily, on the recognition thread; only the sessions of the current frame orientation are kept. The level comes
 * from [preferredLevel], which the worker's [DetectorQualityGovernor] sets from the measured inference time: the app
 * starts at LITE (≈ 0.58× the cost of the old square 640×640 input with the same detections — measured with ONNX
 * Runtime on x86, 1 thread) and moves to FULL (≈ 1.29×) only on phones that are fast enough.
 *
 * Input "images" [1,3,H,W] RGB 0…1 letterboxed ([Letterbox]); output decoded with the core [YOLODecoder] (NMS
 * included), which undoes the letterbox. Thresholds: the decoder runs at [DetectionThresholds.detectorFloor]; the
 * per-class thresholds are applied once, by the tracker.
 *
 * Fallbacks: XNNPACK → plain CPU provider; a FULL session that cannot be created → LITE; a model with a fixed input
 * shape (e.g. an old square 640×640 export) is used at that shape for every frame. Nothing here throws.
 *
 * Not thread-safe: load and use it on the recognition thread only. Input / output buffers are reused.
 */
class YoloDetector(private val context: Context) {
    /** Per-frame detection options (taken from the user settings). */
    data class Options(
        /** Settings slider: threshold of cars / trucks / buses; other classes follow with [DetectionThresholds] offsets. */
        val confidenceThreshold: Double = DetectionThresholds.DEFAULT_GLOBAL_NANO,
        val iouThreshold: Double = 0.45,
        val trackPedestrians: Boolean = true,
        val detectTrafficLights: Boolean = true,
        val maxDetections: Int = 60,
    )

    data class Output(val detections: List<Detection>, val inferenceMs: Double, val inputWidth: Int, val inputHeight: Int)

    /** One ONNX Runtime session with a fixed input size and its reusable input buffer. */
    private class Slot(val session: OrtSession, val inputName: String, val inputW: Int, val inputH: Int) {
        val buffer: FloatBuffer = ByteBuffer.allocateDirect(3 * inputW * inputH * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer()
        val xTable = IntArray(inputW)
        val shape = longArrayOf(1, 3, inputH.toLong(), inputW.toLong())
    }

    var status: ModelStatus = ModelStatus.Loading
        private set

    /** Quality level requested for the next frames (the worker's [DetectorQualityGovernor] decides). */
    var preferredLevel: DetectorQualityGovernor.Level = DetectorQualityGovernor.Level.LITE

    private var env: OrtEnvironment? = null
    /** Sessions by input size (`width × 10000 + height`). */
    private val slots = HashMap<Int, Slot>()
    /** Input sizes whose session could not be created (not tried again). */
    private val failedSizes = HashSet<Int>()
    private var slotsLandscape: Boolean? = null
    /** Input size of a model exported with a fixed shape (null for the dynamic model). */
    private var fixedInput: Pair<Int, Int>? = null
    private var outputValues = FloatArray(0)

    /**
     * Loads the model and creates the session for the given frame orientation at [preferredLevel]. The sessions for
     * the other orientation / level are created on first use by [detect].
     */
    fun load(landscape: Boolean = false): ModelStatus {
        if (status.isReady) return status
        try {
            context.assets.open(MODEL_ASSET).use { it.read() }
        } catch (_: Exception) {
            status = ModelStatus.Missing
            return status
        }
        var failure: String? = null
        val slot = try {
            env = OrtEnvironment.getEnvironment()
            slot(landscape, preferredLevel)
        } catch (t: Throwable) {
            failure = t.message ?: t.javaClass.simpleName
            null
        }
        status = if (slot != null) ModelStatus.Ready(displayName(slot)) else ModelStatus.Failed(failure ?: "session")
        return status
    }

    private fun displayName(slot: Slot): String = "$MODEL_NAME ${slot.inputW}×${slot.inputH}"

    /** The session for a frame orientation and level (created on first use); falls back to LITE, then to any slot. */
    private fun slot(landscape: Boolean, level: DetectorQualityGovernor.Level): Slot? {
        if (slotsLandscape != null && slotsLandscape != landscape) closeSlots()   // rotated: free the other sessions
        slotsLandscape = landscape
        fixedInput?.let { (w, h) -> return slots[key(w, h)] }
        val (w, h) = inputSize(landscape, level)
        slotFor(w, h)?.let { return it }
        if (level == DetectorQualityGovernor.Level.FULL) {
            val (lw, lh) = inputSize(landscape, DetectorQualityGovernor.Level.LITE)
            slotFor(lw, lh)?.let { return it }
        }
        return slots.values.firstOrNull()
    }

    private fun slotFor(w: Int, h: Int): Slot? {
        val k = key(w, h)
        slots[k]?.let { return it }
        if (k in failedSizes) return null
        val e = env ?: return null
        val created = try {
            val bytes = context.assets.open(MODEL_ASSET).use { it.readBytes() }
            val session = createSession(e, bytes, w, h)
            val name = session.inputNames.firstOrNull() ?: "images"
            // A model exported with a fixed input shape ignores the requested size: use its own shape for every frame.
            val declared = ((session.inputInfo[name]?.info as? TensorInfo)?.shape ?: longArrayOf())
            val dh = declared.getOrNull(2)?.toInt() ?: -1
            val dw = declared.getOrNull(3)?.toInt() ?: -1
            if (dw > 0 && dh > 0 && (dw != w || dh != h)) {
                fixedInput = dw to dh
                Slot(session, name, dw, dh)
            } else {
                Slot(session, name, w, h)
            }
        } catch (_: Throwable) {
            failedSizes.add(k)
            return null
        }
        slots[key(created.inputW, created.inputH)] = created
        return created
    }

    /**
     * XNNPACK first (fast on ARM CPUs), plain CPU execution provider as the fallback. The dynamic dimensions are
     * pinned to the requested input so the graph is optimised for a static shape.
     */
    private fun createSession(e: OrtEnvironment, bytes: ByteArray, w: Int, h: Int): OrtSession {
        fun options(xnnpack: Boolean) = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setSymbolicDimensionValue("batch", 1)
            setSymbolicDimensionValue("height", h.toLong())
            setSymbolicDimensionValue("width", w.toLong())
            if (xnnpack) {
                setIntraOpNumThreads(1)
                addXnnpack(mapOf("intra_op_num_threads" to "4"))
            } else {
                setIntraOpNumThreads(4)
            }
        }
        try {
            return e.createSession(bytes, options(xnnpack = true))
        } catch (_: Throwable) {
        }
        return e.createSession(bytes, options(xnnpack = false))
    }

    /** Runs the detector on an upright RGBA_8888 frame. Returns null when the model is not loaded or inference failed. */
    fun detect(rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, options: Options): Output? {
        val e = env ?: return null
        val landscape = DetectorInputGeometry.isLandscape(width.toDouble(), height.toDouble())
        val slot = slot(landscape, preferredLevel) ?: return null
        val name = displayName(slot)
        if ((status as? ModelStatus.Ready)?.name != name) status = ModelStatus.Ready(name)
        val letterbox = Letterbox(slot.inputW, slot.inputH, width, height)
        letterbox.fill(rgba, bytesPerRow, slot.buffer, slot.xTable)
        val start = SystemClock.elapsedRealtimeNanos()
        val shape: List<Int>
        try {
            OnnxTensor.createTensor(e, slot.buffer, slot.shape).use { tensor ->
                slot.session.run(mapOf(slot.inputName to tensor)).use { result ->
                    val out = result.get(0) as? OnnxTensor ?: return null
                    val fb = out.floatBuffer
                    val count = fb.remaining()
                    if (outputValues.size != count) outputValues = FloatArray(count)
                    fb.get(outputValues)
                    shape = out.info.shape.map { it.toInt() }
                }
            }
        } catch (_: Throwable) {
            return null
        }
        val elapsedMs = (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
        val raw = YOLODecoder.decode(
            values = outputValues, shape = shape,
            inputWidth = slot.inputW.toDouble(), inputHeight = slot.inputH.toDouble(),
            confidenceThreshold = DetectionThresholds.detectorFloor(options.confidenceThreshold),
            iouThreshold = options.iouThreshold,
            maxDetections = options.maxDetections * 2,
            sourceWidth = width.toDouble(), sourceHeight = height.toDouble(),
        )
        val detections = ArrayList<Detection>(raw.size)
        for (item in raw) {
            val label = COCOLabels.name(item.classIndex)
            val kind = acceptedKind(item.classIndex, options) ?: continue
            // Scores the tracker cannot use for this class are dropped here (they would only use up maxDetections).
            val usable = DetectionThresholds.threshold(kind, options.confidenceThreshold) * DetectionThresholds.CONTINUATION_FACTOR
            if (item.score < usable) continue
            detections.add(Detection(kind = kind, label = label, confidence = item.score, box = item.box))
        }
        // One object reported as car + truck (per-class NMS) would open two tracks.
        val unique = CrossClassDuplicates.suppress(detections)
        return Output(unique.take(options.maxDetections), elapsedMs, slot.inputW, slot.inputH)
    }

    private fun closeSlots() {
        for (s in slots.values) try { s.session.close() } catch (_: Throwable) {}
        slots.clear()
        fixedInput = null
    }

    fun close() {
        closeSlots()
    }

    companion object {
        const val MODEL_ASSET = "yolo11n.onnx"
        const val MODEL_NAME = "yolo11n"

        /** Long and short side of the FULL / LITE inputs (multiples of 32, ≈ 16:9). */
        const val FULL_LONG = 960
        const val FULL_SHORT = 544
        const val LITE_LONG = 640
        const val LITE_SHORT = 384

        /** Model input (width, height) for a frame orientation and quality level. */
        fun inputSize(landscape: Boolean, level: DetectorQualityGovernor.Level): Pair<Int, Int> {
            val long = if (level == DetectorQualityGovernor.Level.FULL) FULL_LONG else LITE_LONG
            val short = if (level == DetectorQualityGovernor.Level.FULL) FULL_SHORT else LITE_SHORT
            return if (landscape) long to short else short to long
        }

        private fun key(w: Int, h: Int): Int = w * 10000 + h

        /** Maps a COCO class to a [VehicleKind] and applies the class filters from the settings. */
        fun acceptedKind(classIndex: Int, options: Options): VehicleKind? {
            val kind = VehicleKind.fromCocoIndex(classIndex) ?: return null
            return when {
                kind == VehicleKind.PERSON && !options.trackPedestrians -> null
                kind == VehicleKind.TRAFFIC_LIGHT && !options.detectTrafficLights -> null
                else -> kind
            }
        }
    }
}
