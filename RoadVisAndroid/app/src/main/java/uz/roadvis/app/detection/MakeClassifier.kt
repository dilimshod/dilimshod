package uz.roadvis.app.detection

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import uz.roadvis.core.BBox
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.VehicleKind
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Optional vehicle make (brand) classifier (port of iOS `MakeClassifier`): `VehicleMakeClassifier.onnx` plus
 * `VehicleMakeClassifier.labels.txt` (one label per line) in the app assets. Like on iOS, the app ships WITHOUT such a
 * model (no make-classification model is bundled on either platform), so [status] is [ModelStatus.Missing] and no make
 * is ever shown. When a real make model is added, crops of confirmed car / truck / bus tracks are classified with the
 * same scheduling as iOS: boxes ≥ 12 % high and ≥ 10 % wide, ≤ 2 per frame, each track at most every 0.6 s.
 *
 * Not thread-safe: use on the recognition thread only.
 */
class MakeClassifier(private val context: Context) {
    data class Observation(val trackID: Int, val make: String, val confidence: Double)

    var status: ModelStatus = ModelStatus.Loading
        private set

    private var env: OrtEnvironment? = null
    private var session: OrtSession? = null
    private var labels: List<String> = emptyList()
    private var inputName = ""
    private var inputW = 224
    private var inputH = 224
    private var input: FloatBuffer? = null
    private val lastClassified = HashMap<Int, Double>()

    fun load(): ModelStatus {
        if (status.isReady) return status
        val bytes = try {
            context.assets.open(MODEL_ASSET).use { it.readBytes() }
        } catch (_: Exception) {
            status = ModelStatus.Missing
            return status
        }
        status = try {
            labels = context.assets.open(LABELS_ASSET).bufferedReader().readLines().map { it.trim() }.filter { it.isNotEmpty() }
            val e = OrtEnvironment.getEnvironment()
            val s = e.createSession(bytes, OrtSession.SessionOptions())
            inputName = s.inputNames.first()
            val shape = (s.inputInfo[inputName]?.info as? ai.onnxruntime.TensorInfo)?.shape
            if (shape != null && shape.size == 4 && shape[2] > 0 && shape[3] > 0) {
                inputH = shape[2].toInt(); inputW = shape[3].toInt()
            }
            input = ByteBuffer.allocateDirect(3 * inputW * inputH * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            env = e
            session = s
            ModelStatus.Ready(MODEL_NAME)
        } catch (t: Throwable) {
            ModelStatus.Failed(t.message ?: t.javaClass.simpleName)
        }
        return status
    }

    fun reset() { lastClassified.clear() }

    /** Classifies up to [MAX_PER_FRAME] eligible tracks on the upright RGBA frame. */
    fun classify(tracks: List<TrackedObject>, rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int,
                 timestamp: Double): List<Observation> {
        val s = session ?: return emptyList()
        val e = env ?: return emptyList()
        val buf = input ?: return emptyList()
        if (lastClassified.size > 64) {
            val visible = tracks.map { it.id }.toSet()
            lastClassified.entries.removeAll { it.key !in visible && timestamp - it.value >= 5 }
        }
        val candidates = tracks.filter { t ->
            t.isConfirmed && t.missed == 0 && t.kind in ELIGIBLE && t.box.height >= MIN_BOX_HEIGHT &&
                t.box.width >= MIN_BOX_WIDTH && timestamp - (lastClassified[t.id] ?: Double.NEGATIVE_INFINITY) >= MIN_INTERVAL
        }.sortedWith { a, b ->
            val la = lastClassified[a.id]; val lb = lastClassified[b.id]
            when {
                la == null && lb == null -> b.box.area.compareTo(a.box.area)
                la == null -> -1
                lb == null -> 1
                la == lb -> b.box.area.compareTo(a.box.area)
                else -> la.compareTo(lb)
            }
        }.take(MAX_PER_FRAME)
        val result = mutableListOf<Observation>()
        for (track in candidates) {
            lastClassified[track.id] = timestamp
            fillCrop(enlarged(track.box), rgba, width, height, bytesPerRow, buf)
            try {
                OnnxTensor.createTensor(e, buf, longArrayOf(1, 3, inputH.toLong(), inputW.toLong())).use { tensor ->
                    s.run(mapOf(inputName to tensor)).use { out ->
                        val t = out.get(0) as? OnnxTensor ?: return@use
                        val fb = t.floatBuffer
                        val scores = FloatArray(fb.remaining()).also { fb.get(it) }
                        val probs = probabilities(scores)
                        var best = -1; var bestP = 0.0
                        for (i in probs.indices) if (probs[i] > bestP) { bestP = probs[i]; best = i }
                        if (best >= 0 && bestP >= MIN_CONFIDENCE && best < labels.size) {
                            VehicleMakeNormalizer.make(labels[best])?.let { result.add(Observation(track.id, it, bestP)) }
                        }
                    }
                }
            } catch (_: Throwable) {
            }
        }
        return result
    }

    /** Centre crop of the box (square, aspect kept), resized to the model input, RGB 0…1 CHW. */
    private fun fillCrop(box: BBox, rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, out: FloatBuffer) {
        val bx = box.x * width; val by = box.y * height
        val bw = box.width * width; val bh = box.height * height
        val side = min(bw, bh)
        val cx = bx + bw / 2; val cy = by + bh / 2
        val plane = inputW * inputH
        out.clear()
        for (y in 0 until inputH) {
            val sy = (cy - side / 2 + (y + 0.5) * side / inputH).toInt().coerceIn(0, height - 1)
            for (x in 0 until inputW) {
                val sx = (cx - side / 2 + (x + 0.5) * side / inputW).toInt().coerceIn(0, width - 1)
                val p = sy * bytesPerRow + sx * 4
                val i = y * inputW + x
                out.put(i, (rgba[p].toInt() and 0xFF) / 255f)
                out.put(plane + i, (rgba[p + 1].toInt() and 0xFF) / 255f)
                out.put(2 * plane + i, (rgba[p + 2].toInt() and 0xFF) / 255f)
            }
        }
        out.position(0); out.limit(3 * plane)
    }

    companion object {
        const val MODEL_ASSET = "VehicleMakeClassifier.onnx"
        const val LABELS_ASSET = "VehicleMakeClassifier.labels.txt"
        const val MODEL_NAME = "VehicleMakeClassifier"
        val ELIGIBLE = setOf(VehicleKind.CAR, VehicleKind.TRUCK, VehicleKind.BUS)
        const val MIN_BOX_HEIGHT = 0.12
        const val MIN_BOX_WIDTH = 0.10
        const val MAX_PER_FRAME = 2
        const val MIN_INTERVAL = 0.6
        const val CROP_ENLARGEMENT = 0.05
        const val MIN_CONFIDENCE = 0.15

        fun enlarged(box: BBox): BBox {
            val dx = box.width * CROP_ENLARGEMENT / 2; val dy = box.height * CROP_ENLARGEMENT / 2
            return BBox(box.x - dx, box.y - dy, box.width * (1 + CROP_ENLARGEMENT), box.height * (1 + CROP_ENLARGEMENT)).clamped
        }

        /** Scores as probabilities (softmax unless they already sum to ≈ 1). */
        fun probabilities(scores: FloatArray): DoubleArray {
            val sum = scores.sumOf { it.toDouble() }
            if (scores.all { it >= 0f } && sum in 0.98..1.02) return DoubleArray(scores.size) { scores[it].toDouble() }
            val m = scores.maxOrNull()?.toDouble() ?: 0.0
            val e = DoubleArray(scores.size) { exp(scores[it] - m) }
            val total = max(1e-12, e.sum())
            return DoubleArray(e.size) { e[it] / total }
        }
    }
}

/** Turns classifier labels into a make (brand) name (port of iOS `VehicleMakeNormalizer`). */
object VehicleMakeNormalizer {
    private val multiWordMakes: List<Pair<List<String>, String>> = listOf(
        listOf("lynk", "&", "co") to "Lynk & Co", listOf("land", "rover") to "Land Rover",
        listOf("aston", "martin") to "Aston Martin", listOf("alfa", "romeo") to "Alfa Romeo",
        listOf("rolls", "royce") to "Rolls-Royce", listOf("mercedes", "benz") to "Mercedes-Benz",
        listOf("am", "general") to "AM General", listOf("ram", "c/v") to "Ram", listOf("great", "wall") to "Great Wall",
        listOf("li", "auto") to "Li Auto", listOf("lynk", "co") to "Lynk & Co", listOf("dong", "feng") to "Dongfeng",
        listOf("mini", "cooper") to "Mini",
    )

    private val canonicalNames: Map<String, String> = mapOf(
        "acura" to "Acura", "audi" to "Audi", "bentley" to "Bentley", "bmw" to "BMW", "bugatti" to "Bugatti",
        "buick" to "Buick", "byd" to "BYD", "cadillac" to "Cadillac", "changan" to "Changan", "chery" to "Chery",
        "chevrolet" to "Chevrolet", "chevy" to "Chevrolet", "chrysler" to "Chrysler", "citroen" to "Citroën",
        "citroën" to "Citroën", "daewoo" to "Daewoo", "dodge" to "Dodge", "dongfeng" to "Dongfeng", "exeed" to "Exeed",
        "faw" to "FAW", "ferrari" to "Ferrari", "fiat" to "Fiat", "fisker" to "Fisker", "ford" to "Ford", "gaz" to "GAZ",
        "geely" to "Geely", "genesis" to "Genesis", "gmc" to "GMC", "haval" to "Haval", "honda" to "Honda",
        "hongqi" to "Hongqi", "hummer" to "Hummer", "hyundai" to "Hyundai", "infiniti" to "Infiniti", "isuzu" to "Isuzu",
        "jac" to "JAC", "jaguar" to "Jaguar", "jeep" to "Jeep", "jetour" to "Jetour", "kamaz" to "KAMAZ", "kia" to "Kia",
        "lada" to "Lada", "vaz" to "Lada", "lamborghini" to "Lamborghini", "lexus" to "Lexus", "lincoln" to "Lincoln",
        "lotus" to "Lotus", "man" to "MAN", "maserati" to "Maserati", "maybach" to "Maybach", "mazda" to "Mazda",
        "mclaren" to "McLaren", "mercedes" to "Mercedes-Benz", "mercedes-benz" to "Mercedes-Benz",
        "mercedesbenz" to "Mercedes-Benz", "mg" to "MG", "mini" to "Mini", "mitsubishi" to "Mitsubishi",
        "nissan" to "Nissan", "opel" to "Opel", "peugeot" to "Peugeot", "porsche" to "Porsche", "ram" to "Ram",
        "ravon" to "Ravon", "renault" to "Renault", "rolls-royce" to "Rolls-Royce", "scania" to "Scania",
        "scion" to "Scion", "seat" to "SEAT", "skoda" to "Škoda", "škoda" to "Škoda", "smart" to "Smart",
        "spyker" to "Spyker", "subaru" to "Subaru", "suzuki" to "Suzuki", "tesla" to "Tesla", "toyota" to "Toyota",
        "uaz" to "UAZ", "volkswagen" to "Volkswagen", "vw" to "Volkswagen", "volvo" to "Volvo", "zeekr" to "Zeekr",
        "isuzu-samarkand" to "Isuzu", "samauto" to "SamAuto", "tata" to "Tata", "foton" to "Foton",
        "kaiyi" to "Kaiyi", "omoda" to "Omoda", "tank" to "Tank", "voyah" to "Voyah", "lixiang" to "Li Auto",
        "nio" to "NIO", "xpeng" to "XPeng", "gac" to "GAC", "baic" to "BAIC", "jmc" to "JMC", "howo" to "HOWO",
        "shacman" to "Shacman", "yutong" to "Yutong", "iveco" to "Iveco", "daf" to "DAF",
    )

    fun make(label: String): String? {
        val cleaned = label.replace("_", " ").trim()
        val tokens = cleaned.split(' ', '\t').filter { it.isNotEmpty() }.toMutableList()
        val first = tokens.firstOrNull()
        if (first != null && first.length == 4 && first.toIntOrNull()?.let { it in 1900..2100 } == true) tokens.removeAt(0)
        val firstToken = tokens.firstOrNull() ?: return null
        val lowered = tokens.map { it.lowercase() }
        for ((words, display) in multiWordMakes) {
            if (lowered.size >= words.size && lowered.subList(0, words.size) == words) return display
        }
        canonicalNames[lowered[0]]?.let { return it }
        val initial = firstToken.first()
        if (!initial.isLetterOrDigit()) return null
        return initial.uppercase() + firstToken.drop(1)
    }
}
