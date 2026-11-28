package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal

/**
 * One element of an Overpass API JSON response (`[out:json]`).
 *
 * Decoding is deliberately tolerant, because Overpass output differs with the `out` mode:
 * - nodes carry `lat`/`lon` (except with `out tags;`),
 * - ways/relations carry `center` with `out center`, `geometry` with `out geom`
 *   (bounded `out geom(bbox)` emits `null` for vertices outside the box — those are skipped),
 * - `nodes` (member node ids) only with `out body`/`out skel`,
 * - `tags` may be absent (an empty map is used then).
 * Unknown element types (`"area"`, `"count"`, …) never fail decoding: [fromJSON] decodes them as RELATION,
 * and [OverpassResponse] skips them entirely.
 */
data class OSMElement(
    val type: ElementType,
    val id: Long,
    /** Node latitude (nodes only). */
    val lat: Double? = null,
    /** Node longitude (nodes only). */
    val lon: Double? = null,
    /** Centre computed by Overpass (`out center`), for ways and relations. */
    val center: GeoPoint? = null,
    /** Vertex coordinates of a way (`out geom`), in drawing order. */
    val geometry: List<GeoPoint>? = null,
    /** Member node ids of a way (`out body`). */
    val nodes: List<Long>? = null,
    /** OSM tags; empty when the element has none. */
    val tags: Map<String, String> = emptyMap(),
) {
    /** OSM element type. */
    enum class ElementType(val raw: String) {
        NODE("node"), WAY("way"), RELATION("relation");

        companion object {
            fun fromRaw(raw: String): ElementType? = entries.firstOrNull { it.raw == raw }
        }
    }

    /**
     * Best available representative coordinate: `lat`/`lon`, else `center`, else a point of `geometry`
     * (the vertex average for closed rings such as building outlines, otherwise the point halfway along the way).
     */
    val coordinate: GeoPoint?
        get() {
            if (lat != null && lon != null) {
                val p = GeoPoint(lat, lon)
                if (p.isValid) return p
            }
            if (center != null && center.isValid) return center
            val g = geometry
            if (g.isNullOrEmpty()) return null
            if (g.size >= 4 && g.first() == g.last()) {
                val ring = g.dropLast(1)
                val la = ring.sumOf { it.latitude } / ring.size
                val lo = ring.sumOf { it.longitude } / ring.size
                return GeoPoint(la, lo)
            }
            val cumulative = Geo.cumulativeDistances(g)
            return Geo.pointAtDistance((cumulative.lastOrNull() ?: 0.0) / 2, g, cumulative)
        }

    /** Stable identifier in OSM notation, e.g. `"node/123"`, `"way/456"`. */
    val key: String get() = "${type.raw}/$id"

    /** Tag value lookup (convenience; Swift `element[tag:]`). */
    fun tag(key: String): String? = tags[key]

    companion object {
        /**
         * Decodes one element (tolerant, like the Swift `Decodable` implementation).
         * @throws IllegalArgumentException when `id` is missing or not a number.
         */
        fun fromJSON(obj: JSONObject): OSMElement {
            val type = ElementType.fromRaw(obj.opt("type") as? String ?: "") ?: ElementType.RELATION
            val idValue = obj.opt("id") as? Number ?: throw IllegalArgumentException("нет поля id")
            if (!Json.isIntegral(idValue)) throw IllegalArgumentException("неверный тип поля id")
            val id = Json.long(idValue)!!
            val lat = Json.double(obj.opt("lat"))
            val lon = Json.double(obj.opt("lon"))
            val center = latLon(obj.opt("center"))
            var geometry: List<GeoPoint>? = null
            val rawGeometry = obj.opt("geometry")
            if (rawGeometry is JSONArray) {
                val points = ArrayList<GeoPoint>()
                var ok = true
                for (i in 0 until rawGeometry.length()) {
                    val v = rawGeometry.opt(i)
                    if (v == null || v == JSONObject.NULL) continue
                    val p = latLon(v)
                    if (p == null) { ok = false; break }
                    points.add(p)
                }
                geometry = if (ok && points.isNotEmpty()) points else null
            }
            var nodes: List<Long>? = null
            val rawNodes = obj.opt("nodes")
            if (rawNodes is JSONArray) {
                val list = ArrayList<Long>()
                var ok = true
                for (i in 0 until rawNodes.length()) {
                    val n = rawNodes.opt(i) as? Number
                    if (n == null || !Json.isIntegral(n)) { ok = false; break }
                    list.add(Json.long(n)!!)
                }
                nodes = if (ok) list else null
            }
            val tags = LinkedHashMap<String, String>()
            val rawTags = obj.opt("tags")
            if (rawTags is JSONObject) {
                for (k in rawTags.keys()) tags[k] = tagValue(rawTags.opt(k))
            }
            return OSMElement(type, id, lat, lon, center, geometry, nodes, tags)
        }

        /** Decodes a JSON array of elements (every element must have an id). */
        fun decodeArray(json: String): List<OSMElement> {
            val arr = JSONArray(json)
            return (0 until arr.length()).map { i ->
                fromJSON(arr.opt(i) as? JSONObject ?: throw IllegalArgumentException("элемент не является объектом"))
            }
        }

        /** `{"lat": .., "lon": ..}` as used by `center` and `geometry`. */
        private fun latLon(v: Any?): GeoPoint? {
            val o = v as? JSONObject ?: return null
            val la = Json.double(o.opt("lat")) ?: return null
            val lo = Json.double(o.opt("lon")) ?: return null
            return GeoPoint(la, lo)
        }

        /** A tag value that tolerates numbers and booleans (e.g. `out count` produces numeric-looking tags). */
        private fun tagValue(v: Any?): String = when (v) {
            is String -> v
            is Number -> if (Json.isIntegral(v) && (v !is BigDecimal || v.abs() < BigDecimal("9.2e18")))
                Json.long(v).toString() else v.toDouble().toString()
            is Boolean -> if (v) "yes" else "no"
            else -> ""
        }
    }
}

/** Top-level Overpass JSON document. */
data class OverpassResponse(
    /** Decoded elements. Elements of unknown type or malformed elements are skipped instead of failing the response. */
    val elements: List<OSMElement>,
    /**
     * Overpass puts runtime errors (timeouts, memory exhaustion) here while still answering HTTP 200.
     * A non-null remark means the element list may be incomplete.
     */
    val remark: String? = null,
    /** `osm3s.timestamp_osm_base` — age of the OSM data on the server, if reported. */
    val timestampOSMBase: String? = null,
) {
    /** True when the server reported a runtime problem, i.e. `elements` may be partial. */
    val isPartial: Boolean get() = remark != null && remark.swiftTrim().isNotEmpty()

    companion object {
        /** @throws IllegalArgumentException when `elements` is present but not an array. */
        fun fromJSON(obj: JSONObject): OverpassResponse {
            val elements = ArrayList<OSMElement>()
            val raw = obj.opt("elements")
            if (raw != null && raw != JSONObject.NULL) {
                val arr = raw as? JSONArray ?: throw IllegalArgumentException("неверный тип: elements не является массивом")
                for (i in 0 until arr.length()) {
                    val o = arr.opt(i) as? JSONObject ?: continue
                    val t = o.opt("type") as? String ?: continue
                    if (OSMElement.ElementType.fromRaw(t) == null) continue
                    try { elements.add(OSMElement.fromJSON(o)) } catch (e: IllegalArgumentException) { /* skipped */ }
                }
            }
            val remark = obj.opt("remark") as? String
            val ts = (obj.opt("osm3s") as? JSONObject)?.opt("timestamp_osm_base") as? String
            return OverpassResponse(elements, remark, ts)
        }
    }
}
