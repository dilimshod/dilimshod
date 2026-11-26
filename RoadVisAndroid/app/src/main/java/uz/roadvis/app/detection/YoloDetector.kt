package uz.roadvis.app.detection

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.os.SystemClock
import uz.roadvis.core.COCOLabels
import uz.roadvis.core.Detection
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
 * YOLO11n object detector on ONNX Runtime (port of iOS `VehicleDetector` for raw `[1, 84, 8400]` outputs).
 * Input "images" [1,3,640,640] RGB 0…1 letterboxed; output decoded with the core [YOLODecoder] (NMS included).
 *
 * Not thread-safe: load and use it on the recognition thread only. Input / output buffers are reused.
 */
class YoloDetector(private val context: Context) {
    /** Per-frame detection options (taken from the user settings), same defaults as iOS. */
    data class Options(
        val confidenceThreshold: Double = 0.35,
        val iouThreshold: Double = 0.45,
        val trackPedestrians: Boolean = true,
        val detectTrafficLights: Boolean = true,
        val maxDetections: Int = 60,
    )

    data class Output(val detections: List<Detection>, val inferenceMs: Double)

    var status: ModelStatus = ModelStatus.Loading
        private set

    private var env: OrtEnvironment? = null
    private var session: OrtSession? = null
    private var inputName = "images"
    private val inputSize = INPUT_SIZE
    private val inputBuffer: FloatBuffer = ByteBuffer.allocateDirect(3 * INPUT_SIZE * INPUT_SIZE * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer()
    private val xTable = IntArray(INPUT_SIZE)
    private var outputValues = FloatArray(0)
    private val inputShape = longArrayOf(1, 3, INPUT_SIZE.toLong(), INPUT_SIZE.toLong())

    fun load(): ModelStatus {
        if (status.isReady) return status
        val bytes = try {
            context.assets.open(MODEL_ASSET).use { it.readBytes() }
        } catch (_: Exception) {
            status = ModelStatus.Missing
            return status
        }
        status = try {
            val e = OrtEnvironment.getEnvironment()
            val s = createSession(e, bytes)
            env = e
            session = s
            inputName = s.inputNames.firstOrNull() ?: "images"
            ModelStatus.Ready(MODEL_NAME)
        } catch (t: Throwable) {
            ModelStatus.Failed(t.message ?: t.javaClass.simpleName)
        }
        return status
    }

    /** XNNPACK first (fast on ARM CPUs), plain CPU execution provider as the fallback. */
    private fun createSession(e: OrtEnvironment, bytes: ByteArray): OrtSession {
        try {
            val opts = OrtSession.SessionOptions().apply {
                setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                setIntraOpNumThreads(1)
                addXnnpack(mapOf("intra_op_num_threads" to "4"))
            }
            return e.createSession(bytes, opts)
        } catch (_: Throwable) {
        }
        val opts = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(4)
        }
        return e.createSession(bytes, opts)
    }

    /** Runs the detector on an upright RGBA_8888 frame. Returns null when the model is not loaded or inference failed. */
    fun detect(rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, options: Options): Output? {
        val s = session ?: return null
        val e = env ?: return null
        val letterbox = Letterbox(inputSize, width, height)
        letterbox.fill(rgba, bytesPerRow, inputBuffer, xTable)
        val start = SystemClock.elapsedRealtimeNanos()
        val shape: List<Int>
        try {
            OnnxTensor.createTensor(e, inputBuffer, inputShape).use { tensor ->
                s.run(mapOf(inputName to tensor)).use { result ->
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
            inputWidth = inputSize.toDouble(), inputHeight = inputSize.toDouble(),
            confidenceThreshold = options.confidenceThreshold,
            iouThreshold = options.iouThreshold,
            maxDetections = options.maxDetections * 2,
            sourceWidth = width.toDouble(), sourceHeight = height.toDouble(),
        )
        val detections = ArrayList<Detection>(raw.size)
        for (item in raw) {
            val label = COCOLabels.name(item.classIndex)
            val kind = acceptedKind(item.classIndex, options) ?: continue
            detections.add(Detection(kind = kind, label = label, confidence = item.score, box = item.box))
        }
        return Output(detections.take(options.maxDetections), elapsedMs)
    }

    fun close() {
        try { session?.close() } catch (_: Throwable) {}
        session = null
    }

    companion object {
        const val MODEL_ASSET = "yolo11n.onnx"
        const val MODEL_NAME = "yolo11n"
        const val INPUT_SIZE = 640

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
