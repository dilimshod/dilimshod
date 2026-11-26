package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import kotlin.math.max
import kotlin.math.min

/**
 * Response of `GET /api/v1/model/latest?platform=…` (`docs/TRAINING_API.md` §3). Only the parts the Android app uses
 * are kept: version, dates, test metrics and the `android` block (ONNX file + input sizes).
 */
data class ModelManifest(
    val version: String,
    val createdAt: String?,
    val baseModel: String?,
    val metrics: Metrics?,
    val android: AndroidModel?,
) {
    data class Metrics(
        val testImages: Int?,
        val map50: Double?,
        val precision: Double?,
        val recall: Double?,
        val previousMap50: Double?,
    )

    data class ModelFile(val path: String, val sha256: String, val size: Long)

    /** Model input in pixels. The manifest lists `[height, width]` pairs (Ultralytics `imgsz` order). */
    data class InputSize(val width: Int, val height: Int)

    data class AndroidModel(val file: ModelFile, val inputs: List<InputSize>)

    companion object {
        /** Parses the manifest; null when it is not a JSON object or has no version. */
        fun parse(text: String): ModelManifest? {
            val o = Json.parseObject(text) ?: return null
            val version = (o.opt("version") as? String)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val metrics = (o.opt("metrics") as? JSONObject)?.let { m ->
                Metrics(
                    testImages = Json.int(m.opt("testImages")),
                    map50 = Json.double(m.opt("map50")),
                    precision = Json.double(m.opt("precision")),
                    recall = Json.double(m.opt("recall")),
                    previousMap50 = (m.opt("previous") as? JSONObject)?.let { Json.double(it.opt("map50")) },
                )
            }
            return ModelManifest(
                version = version,
                createdAt = o.opt("createdAt") as? String,
                baseModel = o.opt("baseModel") as? String,
                metrics = metrics,
                android = (o.opt("android") as? JSONObject)?.let { parseAndroid(it) },
            )
        }

        private fun parseAndroid(a: JSONObject): AndroidModel? {
            val f = a.opt("file") as? JSONObject ?: return null
            val path = (f.opt("path") as? String)?.takeIf { it.isNotEmpty() } ?: return null
            val sha = (f.opt("sha256") as? String)?.lowercase() ?: return null
            val size = Json.long(f.opt("size")) ?: return null
            val inputs = ArrayList<InputSize>()
            (a.opt("inputs") as? JSONArray)?.let { arr ->
                for (i in 0 until arr.length()) {
                    val pair = arr.opt(i) as? JSONArray ?: continue
                    val h = Json.int(pair.opt(0)) ?: continue
                    val w = Json.int(pair.opt(1)) ?: continue
                    if (w > 0 && h > 0) inputs.add(InputSize(width = w, height = h))
                }
            }
            return AndroidModel(ModelFile(path, sha, size), inputs)
        }
    }
}

/** Which model to download and when (`docs/TRAINING_API.md` "App model update rules"). */
object ModelUpdatePolicy {
    /** At most one manifest check per day. */
    const val CHECK_INTERVAL_MILLIS: Long = 24L * 60 * 60 * 1000
    /** Name of the downloaded Android model inside `filesDir/models/<version>/`. */
    const val ANDROID_MODEL_FILE = "yolo-roadvis.onnx"
    const val PLATFORM = "android"
    /** Model name in the upload metadata of a downloaded model. */
    const val DOWNLOADED_MODEL_NAME = "yolo-roadvis"
    /** Upper bound of a model download, bytes (protects storage from a broken manifest). */
    const val MAX_MODEL_BYTES: Long = 200L * 1024 * 1024

    private val versionPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    private val shaPattern = Regex("^[0-9a-f]{64}$")

    fun isCheckDue(nowMillis: Long, lastCheckMillis: Long?): Boolean =
        lastCheckMillis == null || nowMillis < lastCheckMillis || nowMillis - lastCheckMillis >= CHECK_INTERVAL_MILLIS

    /** The version is used as a directory name: letters, digits, `.`, `_`, `-` only. */
    fun isSafeVersion(version: String): Boolean = versionPattern.matches(version) && !version.contains("..")

    /** Relative file path without `..`, a leading `/` or a backslash. */
    fun isSafePath(path: String): Boolean =
        path.isNotEmpty() && !path.startsWith("/") && !path.contains('\\') && path.split('/').none { it.isEmpty() || it == "." || it == ".." }

    /** True when the manifest offers a usable Android model that is neither active nor known to be bad. */
    fun shouldDownload(manifest: ModelManifest, activeVersion: String?, badVersions: Set<String>): Boolean {
        val android = manifest.android ?: return false
        if (!isSafeVersion(manifest.version) || !isSafePath(android.file.path)) return false
        if (!shaPattern.matches(android.file.sha256)) return false
        if (android.file.size <= 0 || android.file.size > MAX_MODEL_BYTES) return false
        return manifest.version != activeVersion && manifest.version !in badVersions
    }

    fun sha256Matches(expected: String, actualHex: String): Boolean = expected.equals(actualHex, ignoreCase = true)

    /**
     * The downloaded version the detector should use: the active one, unless it is marked bad, not a safe name, or
     * its file is missing ([fileIsValid]); null = the bundled model.
     */
    fun effectiveVersion(activeVersion: String?, badVersions: Set<String>, fileIsValid: (String) -> Boolean): String? {
        val v = activeVersion?.takeIf { it.isNotEmpty() } ?: return null
        if (v in badVersions || !isSafeVersion(v)) return null
        return if (fileIsValid(v)) v else null
    }

    /** Most bad versions remembered (oldest forgotten first). */
    const val MAX_BAD_VERSIONS = 20

    /** Bad-version list after reverting [version]; the active version becomes none (bundled). */
    fun markBad(badVersions: List<String>, version: String): List<String> =
        (badVersions.filter { it != version } + version).takeLast(MAX_BAD_VERSIONS)

    /** Base URL without trailing slashes. */
    fun normalizedBase(baseUrl: String): String = baseUrl.trim().trimEnd('/')

    fun samplesUrl(baseUrl: String): String = "${normalizedBase(baseUrl)}/api/v1/samples"

    fun latestUrl(baseUrl: String): String = "${normalizedBase(baseUrl)}/api/v1/model/latest?platform=$PLATFORM"

    fun fileUrl(baseUrl: String, version: String, path: String): String {
        val encodedPath = path.split('/').joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }
        return "${normalizedBase(baseUrl)}/api/v1/model/${URLEncoder.encode(version, "UTF-8")}/files/$encodedPath"
    }

    /** `version` of the upload metadata for the bundled model: "bundled-yolo11n-640x384". */
    fun bundledVersionLabel(modelName: String, inputWidth: Int, inputHeight: Int): String =
        "bundled-$modelName-${inputWidth}x$inputHeight"
}

/**
 * Watches a downloaded detector model: if it produces no output (no detections, or inference failed) for
 * [noOutputSeconds] of driving while frames keep arriving, [record] returns true once — the app then reverts to the
 * bundled model and remembers the version as bad. Driving = own speed unknown or ≥ [minSpeedKmh]; gaps between frames
 * longer than [maxFrameGapSeconds] do not count.
 */
class ModelHealthMonitor(
    val noOutputSeconds: Double = 30.0,
    val minSpeedKmh: Double = 5.0,
    val maxFrameGapSeconds: Double = 1.0,
) {
    private var lastTimestamp: Double? = null
    private var silentSeconds = 0.0
    private var tripped = false

    /** Seconds of driving without output so far. */
    val silentDrivingSeconds: Double get() = silentSeconds

    fun reset() {
        lastTimestamp = null
        silentSeconds = 0.0
        tripped = false
    }

    /** Feeds one processed frame; returns true exactly once when the model should be reverted. */
    fun record(timestamp: Double, speedKmh: Double?, hadOutput: Boolean): Boolean {
        val last = lastTimestamp
        lastTimestamp = timestamp
        if (hadOutput) {
            silentSeconds = 0.0
            return false
        }
        if (tripped || last == null) return false
        val dt = timestamp - last
        if (!(dt > 0) || dt > maxFrameGapSeconds) return false
        val driving = speedKmh == null || !speedKmh.isFinite() || speedKmh >= minSpeedKmh
        if (!driving) return false
        silentSeconds = min(noOutputSeconds * 2, max(0.0, silentSeconds + dt))
        if (silentSeconds >= noOutputSeconds) {
            tripped = true
            return true
        }
        return false
    }
}
