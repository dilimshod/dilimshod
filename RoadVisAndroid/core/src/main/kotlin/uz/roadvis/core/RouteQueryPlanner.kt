package uz.roadvis.core

import kotlin.math.ceil
import kotlin.math.max

/**
 * Splits a route into Overpass query chunks that never silently miss features on long or winding routes:
 * the route is simplified only with a small tolerance (so the query line stays within `tolerance` metres of the
 * real route and the query radius can be widened by exactly that), long segments are densified, and every chunk has
 * at most `maxPointsPerChunk` vertices AND covers at most `maxChunkLength` metres.
 */
object RouteQueryPlanner {
    const val defaultMaxPointsPerChunk = 60
    const val defaultMaxChunkLength: Double = 3_000.0
    const val defaultTolerance: Double = 10.0

    data class Plan(
        /** Chunks of the (lightly simplified) route; neighbours share an endpoint. */
        val chunks: List<List<GeoPoint>>,
        /** Maximum distance between the query line and the original route, metres (≤ tolerance). */
        val maxDeviation: Double,
        /** Chunks beyond `maxChunks` that were dropped (0 = the plan covers the whole route). */
        val droppedChunks: Int,
        /** Route length covered by `chunks`, metres. */
        val coveredLength: Double,
        val totalLength: Double,
    ) {
        val isComplete: Boolean get() = droppedChunks == 0
    }

    fun plan(route: List<GeoPoint>, maxPointsPerChunk: Int = defaultMaxPointsPerChunk,
             maxChunkLength: Double = defaultMaxChunkLength, tolerance: Double = defaultTolerance,
             maxChunks: Int = Int.MAX_VALUE): Plan {
        val valid = route.filter { it.isValid }
        val total = Geo.polylineLength(valid)
        if (valid.size < 2) {
            return Plan(if (valid.isEmpty()) emptyList() else listOf(valid), 0.0, 0, 0.0, total)
        }
        val simplified = Geo.simplify(valid, tolerance = tolerance)
        val all = chunks(simplified, max(2, maxPointsPerChunk), max(50.0, maxChunkLength))
        val kept = all.take(max(0, maxChunks))
        val covered = kept.sumOf { Geo.polylineLength(it) }
        return Plan(kept, tolerance, all.size - kept.size, covered, total)
    }

    /**
     * Splits [points] into chunks with ≤ maxPoints vertices and ≤ maxLength metres each (segments longer than
     * maxLength are split by inserted points). Neighbouring chunks share their boundary point.
     */
    fun chunks(points: List<GeoPoint>, maxPoints: Int, maxLength: Double): List<List<GeoPoint>> {
        if (points.size < 2) return if (points.isEmpty()) emptyList() else listOf(points)
        // Densify so that no single segment exceeds maxLength.
        val dense = arrayListOf(points[0])
        for (i in 1 until points.size) {
            val a = points[i - 1]
            val b = points[i]
            val length = Geo.distance(a, b)
            if (length > maxLength) {
                val parts = ceil(length / maxLength).toInt()
                for (k in 1 until parts) {
                    val t = k.toDouble() / parts
                    dense.add(GeoPoint(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t))
                }
            }
            dense.add(b)
        }
        val result = ArrayList<List<GeoPoint>>()
        var current = arrayListOf(dense[0])
        var currentLength = 0.0
        for (i in 1 until dense.size) {
            val step = Geo.distance(dense[i - 1], dense[i])
            if (current.size >= maxPoints || currentLength + step > maxLength) {
                result.add(current)
                current = arrayListOf(dense[i - 1])
                currentLength = 0.0
            }
            current.add(dense[i])
            currentLength += step
        }
        if (current.size >= 2) result.add(current)
        return result
    }
}
