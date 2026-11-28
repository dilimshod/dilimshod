package uz.roadvis.core

import java.util.Locale
import kotlin.math.*

/** A WGS-84 coordinate (port of Swift `GeoPoint`). */
data class GeoPoint(val latitude: Double, val longitude: Double) {
    val isValid: Boolean
        get() = latitude.isFinite() && longitude.isFinite() && abs(latitude) <= 90 && abs(longitude) <= 180

    override fun toString(): String = String.format(Locale.US, "%.6f,%.6f", latitude, longitude)
}

/** Bounding box (south, west, north, east). */
data class GeoBounds(val south: Double, val west: Double, val north: Double, val east: Double)

/** Metres per second → km/h. */
val Double.kmh: Double get() = this * 3.6
/** km/h → metres per second. */
val Double.mps: Double get() = this / 3.6

/** Spherical-earth geometry helpers. Distances in metres, angles in degrees. */
object Geo {
    const val EARTH_RADIUS: Double = 6_371_008.8

    internal fun rad(d: Double) = d * PI / 180
    internal fun deg(r: Double) = r * 180 / PI

    /** Great-circle (haversine) distance in metres. */
    fun distance(a: GeoPoint, b: GeoPoint): Double {
        val dLat = rad(b.latitude - a.latitude)
        val dLon = rad(b.longitude - a.longitude)
        val s = sin(dLat / 2) * sin(dLat / 2) +
            cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * EARTH_RADIUS * atan2(sqrt(s), sqrt(max(0.0, 1 - s)))
    }

    /** Initial bearing from a to b, degrees clockwise from north in [0, 360). */
    fun bearing(from: GeoPoint, to: GeoPoint): Double {
        val p1 = rad(from.latitude); val p2 = rad(to.latitude)
        val dl = rad(to.longitude - from.longitude)
        val y = sin(dl) * cos(p2)
        val x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return normalizeDegrees(deg(atan2(y, x)))
    }

    fun normalizeDegrees(d: Double): Double {
        val r = d % 360
        return if (r < 0) r + 360 else r
    }

    /** Smallest absolute difference between two headings, in [0, 180]. */
    fun angleDifference(a: Double, b: Double): Double {
        val d = abs(normalizeDegrees(a) - normalizeDegrees(b))
        return if (d > 180) 360 - d else d
    }

    fun destination(start: GeoPoint, bearing: Double, distance: Double): GeoPoint {
        val delta = distance / EARTH_RADIUS
        val th = rad(bearing)
        val p1 = rad(start.latitude); val l1 = rad(start.longitude)
        val p2 = asin(sin(p1) * cos(delta) + cos(p1) * sin(delta) * cos(th))
        val l2 = l1 + atan2(sin(th) * sin(delta) * cos(p1), cos(delta) - sin(p1) * sin(p2))
        return GeoPoint(deg(p2), normalizeLongitude(deg(l2)))
    }

    internal fun normalizeLongitude(lon: Double): Double {
        var l = lon
        while (l > 180) l -= 360
        while (l < -180) l += 360
        return l
    }

    fun polylineLength(points: List<GeoPoint>): Double = cumulativeDistances(points).lastOrNull() ?: 0.0

    fun cumulativeDistances(points: List<GeoPoint>): List<Double> {
        if (points.isEmpty()) return emptyList()
        val r = DoubleArray(points.size)
        for (i in 1 until points.size) r[i] = r[i - 1] + distance(points[i - 1], points[i])
        return r.toList()
    }

    /** Result of projecting a point onto a polyline. */
    data class Projection(
        val segmentIndex: Int,
        val fraction: Double,
        val point: GeoPoint,
        val distanceFromLine: Double,
        val distanceAlong: Double,
        val segmentBearing: Double,
    )

    /**
     * Projects [p] onto the polyline (local equirectangular approximation per segment).
     * [segmentRange] is an optional subset of segment indices (`IntRange`, inclusive) to search.
     */
    fun project(
        p: GeoPoint,
        points: List<GeoPoint>,
        cumulative: List<Double>? = null,
        segmentRange: IntRange? = null,
    ): Projection? {
        if (points.isEmpty()) return null
        if (points.size == 1) {
            return Projection(0, 0.0, points[0], distance(p, points[0]), 0.0, 0.0)
        }
        val cum = cumulative ?: cumulativeDistances(points)
        val lastSeg = points.size - 2
        val range = if (segmentRange != null) {
            max(0, segmentRange.first)..min(lastSeg, segmentRange.last)
        } else 0..lastSeg
        if (range.isEmpty()) return null
        val cosLat = cos(rad(p.latitude))
        val mLat = EARTH_RADIUS * PI / 180
        val mLon = mLat * cosLat
        var best: Projection? = null
        for (i in range) {
            val a = points[i]; val b = points[i + 1]
            val ax = (a.longitude - p.longitude) * mLon; val ay = (a.latitude - p.latitude) * mLat
            val bx = (b.longitude - p.longitude) * mLon; val by = (b.latitude - p.latitude) * mLat
            val dx = bx - ax; val dy = by - ay
            val len2 = dx * dx + dy * dy
            var t = if (len2 > 0) -(ax * dx + ay * dy) / len2 else 0.0
            t = min(1.0, max(0.0, t))
            val cx = ax + t * dx; val cy = ay + t * dy
            val d = sqrt(cx * cx + cy * cy)
            if (best == null || d < best.distanceFromLine) {
                val pt = GeoPoint(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)
                val segLen = cum[i + 1] - cum[i]
                best = Projection(i, t, pt, d, cum[i] + segLen * t, bearing(a, b))
            }
        }
        return best
    }

    /** Point located [d] metres along the polyline (clamped to its ends). */
    fun pointAtDistance(d: Double, points: List<GeoPoint>, cumulative: List<Double>? = null): GeoPoint? {
        val first = points.firstOrNull() ?: return null
        val cum = cumulative ?: cumulativeDistances(points)
        val total = cum.lastOrNull() ?: return first
        if (d <= 0) return first
        if (d >= total) return points.last()
        var lo = 0; var hi = cum.size - 1
        while (hi - lo > 1) {
            val mid = (lo + hi) / 2
            if (cum[mid] <= d) lo = mid else hi = mid
        }
        val segLen = cum[hi] - cum[lo]
        val t = if (segLen > 0) (d - cum[lo]) / segLen else 0.0
        val a = points[lo]; val b = points[hi]
        return GeoPoint(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)
    }

    /** Douglas–Peucker simplification, tolerance in metres. Keeps first and last points. */
    fun simplify(points: List<GeoPoint>, tolerance: Double): List<GeoPoint> {
        if (points.size <= 2 || tolerance <= 0) return points
        val keep = BooleanArray(points.size)
        keep[0] = true; keep[points.size - 1] = true
        val stack = ArrayDeque<Pair<Int, Int>>()
        stack.addLast(0 to points.size - 1)
        while (stack.isNotEmpty()) {
            val (s, e) = stack.removeLast()
            if (e <= s + 1) continue
            var maxD = 0.0; var idx = s
            val seg = listOf(points[s], points[e])
            for (i in (s + 1) until e) {
                val d = project(points[i], seg)?.distanceFromLine ?: 0.0
                if (d > maxD) { maxD = d; idx = i }
            }
            if (maxD > tolerance) {
                keep[idx] = true
                stack.addLast(s to idx); stack.addLast(idx to e)
            }
        }
        return points.filterIndexed { i, _ -> keep[i] }
    }

    /** Simplifies until at most [maxPoints] vertices remain (doubling the tolerance). */
    fun simplify(points: List<GeoPoint>, maxPoints: Int, initialTolerance: Double = 5.0): List<GeoPoint> {
        if (maxPoints < 2) return points.take(max(0, maxPoints))
        var tol = initialTolerance
        var result = simplify(points, tol)
        while (result.size > maxPoints && tol < 100_000) {
            tol *= 2
            result = simplify(points, tol)
        }
        return result
    }

    /** Splits into consecutive chunks of at most [maxPoints]; neighbours share an endpoint. */
    fun chunk(points: List<GeoPoint>, maxPoints: Int): List<List<GeoPoint>> {
        if (maxPoints < 2 || points.size <= maxPoints) return if (points.isEmpty()) emptyList() else listOf(points)
        val chunks = mutableListOf<List<GeoPoint>>()
        var start = 0
        while (start < points.size - 1) {
            val end = min(points.size, start + maxPoints)
            chunks.add(points.subList(start, end).toList())
            start = end - 1
        }
        return chunks
    }

    fun boundingBox(points: List<GeoPoint>, padding: Double = 0.0): GeoBounds? {
        val first = points.firstOrNull() ?: return null
        var s = first.latitude; var n = first.latitude; var w = first.longitude; var e = first.longitude
        for (p in points) {
            s = min(s, p.latitude); n = max(n, p.latitude)
            w = min(w, p.longitude); e = max(e, p.longitude)
        }
        if (padding > 0) {
            val dLat = padding / (EARTH_RADIUS * PI / 180)
            val dLon = dLat / max(0.01, cos(rad((s + n) / 2)))
            s -= dLat; n += dLat; w -= dLon; e += dLon
        }
        return GeoBounds(s, w, n, e)
    }
}
