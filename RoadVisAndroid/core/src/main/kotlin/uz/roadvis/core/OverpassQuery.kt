package uz.roadvis.core

import org.json.JSONObject
import java.util.Locale
import kotlin.math.max

/** Errors produced while interpreting an Overpass API response body. */
sealed class OverpassError(msg: String) : Exception(msg) {
    /**
     * The server answered with an HTML page (Overpass reports errors as HTML even for `[out:json]`,
     * proxies return HTML 502/504 pages). [detail] is the extracted error message.
     */
    data class HtmlError(val detail: String) : OverpassError(detail)

    /** The body is not valid Overpass JSON. */
    data class InvalidJSON(val detail: String) : OverpassError(detail)

    /** The body is empty. */
    data object EmptyResponse : OverpassError("empty response")

    /** Russian, user-facing description. */
    val errorDescription: String
        get() = when (this) {
            is HtmlError -> when {
                isRateLimited -> "Сервер OpenStreetMap (Overpass) перегружен или ограничил частоту запросов. Повторим позже."
                isTimeout -> "Сервер OpenStreetMap (Overpass) не ответил вовремя. Повторим позже."
                else -> "Сервер OpenStreetMap (Overpass) вернул ошибку: $detail"
            }
            is InvalidJSON -> "Не удалось разобрать ответ OpenStreetMap: $detail"
            EmptyResponse -> "Сервер OpenStreetMap вернул пустой ответ."
        }

    /** The server asked us to slow down (Overpass `rate_limited`, HTTP 429 page). */
    val isRateLimited: Boolean
        get() {
            val m = (this as? HtmlError)?.detail ?: return false
            val l = m.lowercase()
            return l.contains("rate_limited") || l.contains("too many requests") || l.contains("429")
        }

    /** Gateway / query timeout (HTTP 504 page or Overpass "Query timed out"). */
    val isTimeout: Boolean
        get() {
            val m = (this as? HtmlError)?.detail ?: return false
            val l = m.lowercase()
            return l.contains("timed out") || l.contains("time-out") || l.contains("timeout") || l.contains("504") ||
                l.contains("dispatcher_client")
        }

    /** Whether repeating the request (possibly at another endpoint, after a pause) can help. */
    val isRetryable: Boolean
        get() = when (this) {
            is HtmlError -> {
                if (isRateLimited || isTimeout) true
                else {
                    val l = detail.lowercase()
                    l.contains("502") || l.contains("503") || l.contains("bad gateway") || l.contains("unavailable") ||
                        l.contains("out of memory")
                }
            }
            EmptyResponse -> true
            is InvalidJSON -> false
        }
}

/** Builds Overpass QL queries and decodes their responses. Networking lives in the app layer. */
object OverpassQuery {
    /** Maximum number of polyline vertices passed to one [featuresAlong] query. */
    const val maxPolylinePoints: Int = 100

    /** `highway=*` values that are never driven by cars; excluded from the road selector. */
    val excludedHighwayValues: List<String> = listOf(
        "footway", "path", "cycleway", "steps", "pedestrian", "bridleway", "corridor", "elevator",
        "platform", "proposed", "construction", "abandoned", "disused", "razed", "bus_stop", "services", "rest_area",
    )

    /**
     * Ways with `highway=*` (drivable classes only) within [radius] metres, returned with tags and geometry
     * (`out tags geom`), plus `highway=traffic_signals` nodes within [signalRadius] (`out`, with coordinates).
     */
    fun roadsAround(p: GeoPoint, radius: Double = 30.0, signalRadius: Double = 80.0, timeout: Int = 15): String {
        val point = coordinates(listOf(p))
        return "[out:json][timeout:${max(1, timeout)}];\n" +
            "way(around:${meters(radius)},$point)[highway][highway!~\"$excludedHighwayRegex\"];\n" +
            "out tags geom;\n" +
            "node(around:${meters(signalRadius)},$point)[highway=traffic_signals];\n" +
            "out;"
    }

    /**
     * Road features along a polyline (`around:R,lat1,lon1,lat2,lon2,…`): traffic signals, pedestrian crossings,
     * speed cameras, stop / give-way signs, traffic calming, railway level crossings, highway=construction ways
     * (within [radius]), schools / kindergartens (within 150 m), fuel stations (within 100 m) and public parking
     * (within 60 m), all with `out tags center qt`.
     *
     * A polyline longer than [maxPolylinePoints] vertices is simplified (Douglas–Peucker) to fit; split long routes
     * into chunks first ([RouteQueryPlanner]) to keep the detail. An empty polyline yields a valid query with no results.
     */
    fun featuresAlong(polyline: List<GeoPoint>, radius: Double = 35.0, timeout: Int = 25): String {
        val header = "[out:json][timeout:${max(1, timeout)}];"
        val valid = polyline.filter { it.isValid }
        if (valid.isEmpty()) return "$header\nout;"
        var points = if (valid.size > maxPolylinePoints) Geo.simplify(valid, maxPoints = maxPolylinePoints) else valid
        if (points.size > maxPolylinePoints) points = points.take(maxPolylinePoints)
        val poly = coordinates(points)
        val r = meters(radius)
        val schoolRadius = meters(max(radius, 150.0))
        val fuelRadius = meters(max(radius, 100.0))
        val parkingRadius = meters(max(radius, 60.0))
        return "$header\n" +
            "(\n" +
            "  node(around:$r,$poly)[highway~\"^(traffic_signals|crossing|speed_camera|stop|give_way)$\"];\n" +
            "  node(around:$r,$poly)[traffic_calming];\n" +
            "  node(around:$r,$poly)[railway=level_crossing];\n" +
            "  nwr(around:$schoolRadius,$poly)[amenity~\"^(school|kindergarten)$\"];\n" +
            "  way(around:$r,$poly)[highway=construction];\n" +
            "  nwr(around:$fuelRadius,$poly)[amenity=fuel];\n" +
            "  nwr(around:$parkingRadius,$poly)[amenity=parking][access!~\"^(private|no|customers)$\"];\n" +
            ");\n" +
            "out tags center qt;"
    }

    /**
     * Request body for `POST /api/interpreter` with `Content-Type: application/x-www-form-urlencoded`:
     * `data=<query>` where every byte except the RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`)
     * is percent-encoded as UTF-8.
     */
    fun formBody(query: String): ByteArray = ("data=" + percentEncode(query)).toByteArray(Charsets.UTF_8)

    /** Strict `application/x-www-form-urlencoded` component encoding (spaces become `%20`). */
    fun percentEncode(string: String): String {
        val hex = "0123456789ABCDEF"
        val bytes = string.toByteArray(Charsets.UTF_8)
        val out = StringBuilder(bytes.size * 3)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            val c = v.toChar()
            if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '.' || c == '_' || c == '~') {
                out.append(c)
            } else {
                out.append('%').append(hex[v shr 4]).append(hex[v and 0x0F])
            }
        }
        return out.toString()
    }

    /**
     * Decodes the elements of an Overpass JSON response.
     * @throws OverpassError.HtmlError when the body is an HTML (error) page, [OverpassError.EmptyResponse],
     * [OverpassError.InvalidJSON].
     */
    fun decode(data: ByteArray): List<OSMElement> = decodeResponse(data).elements

    fun decode(text: String): List<OSMElement> = decode(text.toByteArray(Charsets.UTF_8))

    /** Like [decode], but also returns the `remark` (partial result marker) and data timestamp. */
    fun decodeResponse(data: ByteArray): OverpassResponse {
        val start = firstSignificantIndex(data) ?: throw OverpassError.EmptyResponse
        if (data[start] == '<'.code.toByte()) {
            throw OverpassError.HtmlError(htmlErrorMessage(data))
        }
        val bomOffset = if (hasBom(data)) 3 else 0
        val text = String(data, bomOffset, data.size - bomOffset, Charsets.UTF_8)
        val obj: JSONObject = try {
            val v = org.json.JSONTokener(text).nextValue()
            v as? JSONObject ?: throw OverpassError.InvalidJSON("неверный тип: ожидался объект")
        } catch (e: OverpassError) {
            throw e
        } catch (e: Exception) {
            throw OverpassError.InvalidJSON(e.message ?: e.toString())
        }
        return try {
            OverpassResponse.fromJSON(obj)
        } catch (e: IllegalArgumentException) {
            throw OverpassError.InvalidJSON(e.message ?: e.toString())
        }
    }

    fun decodeResponse(text: String): OverpassResponse = decodeResponse(text.toByteArray(Charsets.UTF_8))

    /**
     * Extracts a readable message from an Overpass/nginx HTML error page:
     * `<p>` paragraphs mentioning "Error", else `<title>` / `<h1>`, else the first text of the page.
     */
    fun htmlErrorMessage(data: ByteArray): String {
        val html = String(data, Charsets.UTF_8)
        val paragraphs = elements("p", html).map(::plainText).filter { it.contains("error", ignoreCase = true) }
        if (paragraphs.isNotEmpty()) return truncate(paragraphs.joinToString(" "), 400)
        for (tag in listOf("title", "h1", "h2")) {
            val text = elements(tag, html).map(::plainText).firstOrNull { it.isNotEmpty() }
            if (text != null) return truncate(text, 400)
        }
        val text = plainText(html)
        return if (text.isEmpty()) "HTML-ответ без описания" else truncate(text, 200)
    }

    // Private helpers

    internal val excludedHighwayRegex: String
        get() = "^(" + excludedHighwayValues.joinToString("|") + ")$"

    /** Radius in whole metres (Overpass accepts decimals, but integers keep queries cacheable). */
    internal fun meters(value: Double): String {
        if (!value.isFinite()) return "30"
        return max(1.0, value.rounded()).toLong().toString()
    }

    /** "lat,lon,lat,lon,…" with 6 decimals (≈ 0.1 m) and a '.' separator regardless of locale. */
    internal fun coordinates(points: List<GeoPoint>): String =
        points.joinToString(",") { String.format(Locale.US, "%.6f,%.6f", it.latitude, it.longitude) }

    private fun hasBom(data: ByteArray): Boolean =
        data.size >= 3 && data[0] == 0xEF.toByte() && data[1] == 0xBB.toByte() && data[2] == 0xBF.toByte()

    private fun firstSignificantIndex(data: ByteArray): Int? {
        var index = if (hasBom(data)) 3 else 0
        while (index < data.size) {
            val b = data[index].toInt()
            if (b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) return index
            index++
        }
        return null
    }

    /** Inner HTML of every `<name ...>…</name>` element (case-insensitive, non-nested). */
    private fun elements(name: String, html: String): List<String> {
        val results = ArrayList<String>()
        var from = 0
        while (true) {
            val open = html.indexOf("<$name", from, ignoreCase = true)
            if (open < 0) break
            val upper = open + name.length + 1
            // The tag name must end here (avoid matching <pre> for <p>).
            if (upper >= html.length) break
            val next = html[upper]
            if (!(next == '>' || next == ' ' || next == '\t' || next == '\n' || next == '\r')) {
                from = upper
                continue
            }
            val tagEnd = html.indexOf('>', upper)
            if (tagEnd < 0) break
            val close = html.indexOf("</$name", tagEnd + 1, ignoreCase = true)
            if (close < 0) {
                results.add(html.substring(tagEnd + 1))
                break
            }
            results.add(html.substring(tagEnd + 1, close))
            from = close + name.length + 2
        }
        return results
    }

    /** Removes tags, decodes the common entities and collapses whitespace. */
    private fun plainText(html: String): String {
        val text = StringBuilder()
        var inTag = false
        for (ch in html) {
            if (ch == '<') { inTag = true; text.append(' '); continue }
            if (ch == '>') { inTag = false; continue }
            if (!inTag) text.append(ch)
        }
        var s = text.toString()
        for ((entity, value) in listOf("&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'", "&apos;" to "'",
            "&nbsp;" to " ", "&amp;" to "&")) {
            s = s.replace(entity, value)
        }
        val words = ArrayList<String>()
        val word = StringBuilder()
        for (ch in s) {
            if (ch.isWhitespace()) {
                if (word.isNotEmpty()) { words.add(word.toString()); word.setLength(0) }
            } else word.append(ch)
        }
        if (word.isNotEmpty()) words.add(word.toString())
        var joined = words.joinToString(" ")
        // "Error : line 1" → "Error: line 1" (artefact of removing <strong>…</strong>).
        joined = joined.replace(" :", ":")
        return joined
    }

    private fun truncate(s: String, length: Int): String = if (s.length <= length) s else s.take(length) + "…"
}
