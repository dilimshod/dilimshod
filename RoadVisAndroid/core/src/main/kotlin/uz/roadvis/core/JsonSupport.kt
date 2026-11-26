package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger
import java.util.Date

/**
 * Internal helpers that mimic the loose `as?` casts the Swift code applies to `JSONSerialization` output
 * (org.json values: JSONObject, JSONArray, String, Boolean, Number, JSONObject.NULL).
 */
internal object Json {
    /** Seconds between 1970-01-01 and Swift's reference date 2001-01-01 (Swift `Date` Codable default). */
    const val REFERENCE_DATE_OFFSET: Double = 978_307_200.0

    /** `v as? Double` / `as? Int` / NSNumber → Double. */
    fun double(v: Any?): Double? = (v as? Number)?.toDouble()

    /** `v as? Int`, else `Int(v as? Double)`. */
    fun int(v: Any?): Int? = (v as? Number)?.let { n ->
        when (n) {
            is Int -> n
            is Long -> n.toInt()
            is BigInteger -> n.toInt()
            else -> n.toDouble().let { d -> if (d.isFinite()) d.toInt() else null }
        }
    }

    fun long(v: Any?): Long? = (v as? Number)?.let { n ->
        when (n) {
            is Int -> n.toLong()
            is Long -> n
            is BigInteger -> n.toLong()
            is BigDecimal -> n.toLong()
            else -> n.toDouble().let { d -> if (d.isFinite()) d.toLong() else null }
        }
    }

    /** True when the number has no fractional part (Swift decodes such JSON numbers as integers). */
    fun isIntegral(n: Number): Boolean = when (n) {
        is Int, is Long, is Short, is Byte, is BigInteger -> true
        is BigDecimal -> n.signum() == 0 || n.stripTrailingZeros().scale() <= 0
        else -> n.toDouble().let { it.isFinite() && it == Math.floor(it) }
    }

    /** `v as? Bool` (an NSNumber 0 / 1 also bridges to Bool). */
    fun bool(v: Any?): Boolean? = when (v) {
        is Boolean -> v
        is Number -> if (isIntegral(v) && (v.toLong() == 0L || v.toLong() == 1L)) v.toLong() != 0L else null
        else -> null
    }

    fun string(v: Any?): String? = v as? String

    fun obj(v: Any?): JSONObject? = v as? JSONObject

    /** `v as? [[String: Any]]`: null unless every element is an object. */
    fun objectList(v: Any?): List<JSONObject>? {
        val arr = v as? JSONArray ?: return null
        val out = ArrayList<JSONObject>(arr.length())
        for (i in 0 until arr.length()) out.add(arr.opt(i) as? JSONObject ?: return null)
        return out
    }

    /** `v as? [String]`: null unless every element is a string. */
    fun stringList(v: Any?): List<String>? {
        val arr = v as? JSONArray ?: return null
        val out = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) out.add(arr.opt(i) as? String ?: return null)
        return out
    }

    /** Parses a top-level JSON object, null when the text is not one. */
    fun parseObject(text: String): JSONObject? = try {
        val tokener = org.json.JSONTokener(text)
        val value = tokener.nextValue()
        value as? JSONObject
    } catch (e: Exception) {
        null
    }

    fun dateToJSON(date: Date): Double = date.time / 1000.0 - REFERENCE_DATE_OFFSET

    fun dateFromJSON(v: Any?): Date? = double(v)?.let { Date(((it + REFERENCE_DATE_OFFSET) * 1000.0).rounded().toLong()) }

    /** Swift-like `Double(String)` (no surrounding whitespace, no Java-only suffixes such as `d` / `f`). */
    fun parseDouble(s: String): Double? {
        if (!SWIFT_DOUBLE.matches(s)) return null
        return s.toDoubleOrNull()
    }

    private val SWIFT_DOUBLE = Regex("^[+-]?((\\d+\\.?\\d*)|(\\.\\d+))([eE][+-]?\\d+)?$|^[+-]?(inf|infinity|nan)$", RegexOption.IGNORE_CASE)

    /**
     * Serialises maps (sorted keys, like `JSONSerialization` with `.sortedKeys`), lists, strings, booleans and
     * numbers. Integral doubles are written without a fraction ("0", not "0.0"), as Foundation does.
     */
    fun write(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Map<*, *> -> {
                out.append('{')
                value.entries.sortedBy { it.key.toString() }.forEachIndexed { i, e ->
                    if (i > 0) out.append(',')
                    out.append(JSONObject.quote(e.key.toString())).append(':')
                    write(e.value, out)
                }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { i, v -> if (i > 0) out.append(','); write(v, out) }
                out.append(']')
            }
            is String -> out.append(JSONObject.quote(value))
            is Boolean -> out.append(if (value) "true" else "false")
            is Int, is Long -> out.append(value.toString())
            is Number -> {
                val d = value.toDouble()
                if (d.isFinite() && d == Math.floor(d) && Math.abs(d) < 1e15) out.append(d.toLong().toString())
                else out.append(d.toString())
            }
            else -> out.append(JSONObject.quote(value.toString()))
        }
    }
}

/** Stable merge sort with a Swift-style `areInIncreasingOrder` predicate (never throws on inconsistent orders). */
internal fun <T> List<T>.swiftSorted(less: (T, T) -> Boolean): List<T> {
    if (size < 2) return toList()
    val mid = size / 2
    val left = subList(0, mid).swiftSorted(less)
    val right = subList(mid, size).swiftSorted(less)
    val out = ArrayList<T>(size)
    var i = 0
    var j = 0
    while (i < left.size && j < right.size) {
        if (less(right[j], left[i])) out.add(right[j++]) else out.add(left[i++])
    }
    while (i < left.size) out.add(left[i++])
    while (j < right.size) out.add(right[j++])
    return out
}

/** Swift `String.trimmingCharacters(in: .whitespacesAndNewlines)`. */
internal fun String.swiftTrim(): String = trim { it.isWhitespace() }

/** Lowercases the first character ("Поверните налево" → "поверните налево"). */
internal fun String.rvLowercasedFirst(): String {
    if (isEmpty()) return this
    return substring(0, 1).lowercase() + substring(1)
}
