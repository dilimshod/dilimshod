package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * JSON / CSV helpers shared by the persisted models (TripModels, DrivingEvents, ExperimentLog).
 *
 * Date convention for the whole vision/coach/trip port: Swift `Date` → `Long` epoch milliseconds (fields named
 * `...Millis`); Swift `TimeInterval` → `Double` seconds. In JSON, dates are stored as epoch-millisecond numbers under
 * the Swift property name without the `Millis` suffix (e.g. `"date"`, `"startedAt"`), UUIDs as strings, enums by raw
 * value, optionals are omitted when null.
 */
internal object TripJson {
    fun geo(p: GeoPoint): JSONObject = JSONObject().put("latitude", p.latitude).put("longitude", p.longitude)
    fun geo(o: JSONObject): GeoPoint = GeoPoint(o.getDouble("latitude"), o.getDouble("longitude"))

    fun optDouble(o: JSONObject, key: String): Double? = if (o.has(key) && !o.isNull(key)) o.getDouble(key) else null
    fun optInt(o: JSONObject, key: String): Int? = if (o.has(key) && !o.isNull(key)) o.getInt(key) else null
    fun optLong(o: JSONObject, key: String): Long? = if (o.has(key) && !o.isNull(key)) o.getLong(key) else null
    fun optString(o: JSONObject, key: String): String? = if (o.has(key) && !o.isNull(key)) o.getString(key) else null
    fun optObject(o: JSONObject, key: String): JSONObject? = if (o.has(key) && !o.isNull(key)) o.getJSONObject(key) else null

    fun putOpt(o: JSONObject, key: String, value: Any?): JSONObject {
        if (value != null) o.put(key, value)
        return o
    }

    fun <T> list(o: JSONObject, key: String, map: (JSONObject) -> T): List<T> {
        val arr = if (o.has(key) && !o.isNull(key)) o.getJSONArray(key) else return emptyList()
        return (0 until arr.length()).map { map(arr.getJSONObject(it)) }
    }

    fun <T> array(items: List<T>, map: (T) -> Any): JSONArray {
        val arr = JSONArray()
        for (i in items) arr.put(map(i))
        return arr
    }

    /** ISO-8601 UTC without fractional seconds, e.g. "2027-01-15T08:00:00Z". */
    fun iso(millis: Long): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(millis).truncatedTo(ChronoUnit.SECONDS))

    private val isoMillisFormatter: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).withZone(ZoneOffset.UTC)

    /** ISO-8601 UTC with milliseconds, e.g. "1970-01-01T00:00:01.000Z". */
    fun isoMillis(millis: Long): String = isoMillisFormatter.format(Instant.ofEpochMilli(millis))

    /** Fixed-point number with '.' decimals, empty for null / non-finite. */
    fun number(value: Double?, digits: Int): String {
        if (value == null || !value.isFinite()) return ""
        return String.format(Locale.US, "%.${digits}f", value)
    }

    /** CSV-escapes a field (quotes when it contains a comma, quote or newline). */
    fun escape(text: String): String {
        if (text.contains(",") || text.contains("\"") || text.contains("\n")) {
            return "\"" + text.replace("\"", "\"\"") + "\""
        }
        return text
    }
}
