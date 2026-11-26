package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import kotlin.math.roundToLong

/**
 * Metadata of one collected training sample: the `meta` part of `POST /api/v1/samples` and the `<uuid>.json` file
 * next to `<uuid>.jpg` (`docs/TRAINING_API.md` §3). The JSON keys are fixed by the contract.
 */
data class LearningSampleMeta(
    val id: String,
    /** Capture time, milliseconds since 1970 (written as ISO 8601 UTC with seconds). */
    val capturedAtMillis: Long,
    val appVersion: String,
    val modelName: String,
    val modelVersion: String,
    /** Size of the saved JPEG, pixels. */
    val imageWidth: Int,
    val imageHeight: Int,
    val reasons: List<String>,
    val speedKmh: Double? = null,
    /** Only when the user allowed "send location"; both or neither. */
    val lat: Double? = null,
    val lon: Double? = null,
    val detections: List<Detection> = emptyList(),
    val tracks: List<HardExampleSelector.Track> = emptyList(),
    val quality: FrameQuality.Metrics,
    val platform: String = PLATFORM_ANDROID,
) {
    val orientation: String get() = if (imageWidth >= imageHeight) "landscape" else "portrait"

    val capturedAt: String get() = isoTimestamp(capturedAtMillis)

    fun toJson(): JSONObject {
        val o = JSONObject()
        o.put("id", id)
        o.put("capturedAt", capturedAt)
        o.put("platform", platform)
        o.put("appVersion", appVersion)
        o.put("model", JSONObject().put("name", modelName).put("version", modelVersion))
        o.put("image", JSONObject().put("width", imageWidth).put("height", imageHeight).put("orientation", orientation))
        o.put("reasons", JSONArray(reasons))
        speedKmh?.takeIf { it.isFinite() }?.let { o.put("speedKmh", round(it, 1)) }
        if (lat != null && lon != null && lat.isFinite() && lon.isFinite()) {
            o.put("lat", round(lat, 5))
            o.put("lon", round(lon, 5))
        }
        val dets = JSONArray()
        for (d in detections) {
            dets.put(JSONObject().put("label", d.label).put("kind", d.kind.raw)
                .put("confidence", round(d.confidence, 3)).put("box", boxJson(d.box)))
        }
        o.put("detections", dets)
        val trs = JSONArray()
        for (t in tracks) {
            trs.put(JSONObject().put("id", t.id).put("kind", t.kind.raw).put("confidence", round(t.confidence, 3))
                .put("hits", t.hits).put("missed", t.missed).put("confirmed", t.isConfirmed).put("box", boxJson(t.box)))
        }
        o.put("tracks", trs)
        o.put("quality", JSONObject().put("sharpness", round(quality.sharpness, 1))
            .put("brightness", round(quality.brightness, 1)).put("dhash", quality.dhashHex))
        return o
    }

    companion object {
        const val PLATFORM_ANDROID = "android"

        /** Top-level keys of the metadata object (contract §3). */
        val topLevelKeys: Set<String> = setOf("id", "capturedAt", "platform", "appVersion", "model", "image", "reasons",
            "speedKmh", "lat", "lon", "detections", "tracks", "quality")

        /** "2026-11-26T10:00:00Z" (UTC, whole seconds). */
        fun isoTimestamp(millis: Long): String = Instant.ofEpochSecond(Math.floorDiv(millis, 1000L)).toString()

        private fun boxJson(b: BBox): JSONArray {
            val c = b.clamped
            return JSONArray().put(round(c.x, 4)).put(round(c.y, 4)).put(round(c.width, 4)).put(round(c.height, 4))
        }

        private fun round(v: Double, digits: Int): Double {
            if (!v.isFinite()) return 0.0
            var f = 1.0
            repeat(digits) { f *= 10 }
            return (v * f).roundToLong() / f
        }
    }
}
