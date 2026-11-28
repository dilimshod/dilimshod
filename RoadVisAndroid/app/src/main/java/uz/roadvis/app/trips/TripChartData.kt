package uz.roadvis.app.trips

import uz.roadvis.core.DrivingEventKind
import uz.roadvis.core.Trip
import uz.roadvis.core.TripPoint
import uz.roadvis.core.TripSpeedBand
import uz.roadvis.core.TripStats
import java.util.UUID
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max

/** Chart data prepared once per trip (downsampled track, contiguous segments, event counts, speed bands). Port of iOS `TripChartData`. */
class TripChartData(trip: Trip, stats: TripStats) {
    data class SpeedSample(val dateMillis: Long, val speedKmh: Double)
    data class SegmentSample(val segment: Int, val dateMillis: Long, val value: Double)
    data class EventMarker(val id: UUID, val dateMillis: Long, val speedKmh: Double, val kind: DrivingEventKind)
    data class KindCount(val kind: DrivingEventKind, val count: Int)
    data class BandShare(val band: TripSpeedBand, val seconds: Double, val share: Double)

    val speed: List<SpeedSample>
    val limits: List<SegmentSample>
    val leads: List<SegmentSample>
    val recommended: List<SegmentSample>
    val markers: List<EventMarker>
    val kindCounts: List<KindCount>
    val bands: List<BandShare>
    val maxSpeed: Double
    val startMillis: Long
    val endMillis: Long

    val hasLeadData: Boolean get() = leads.isNotEmpty()

    companion object {
        /** Maximum number of plotted track samples. */
        const val MAX_SAMPLES = 360

        /** Splits the samples into contiguous runs where [value] is non-null (a gap breaks the line). */
        fun segments(points: List<TripPoint>, value: (TripPoint) -> Double?): List<SegmentSample> {
            val result = mutableListOf<SegmentSample>()
            var segment = 0
            var inRun = false
            for (p in points) {
                val v = value(p)
                if (v != null && v.isFinite()) {
                    if (!inRun) { segment++; inRun = true }
                    result += SegmentSample(segment, p.dateMillis, v)
                } else {
                    inRun = false
                }
            }
            return result
        }
    }

    init {
        val points = trip.points.sortedBy { it.dateMillis }
        val stride = max(1, ceil(points.size.toDouble() / MAX_SAMPLES).toInt())
        val sampled = points.indices.step(stride).map { points[it] }
        limits = segments(sampled) { it.speedLimitKmh?.toDouble() }
        speed = sampled.map { SpeedSample(it.dateMillis, it.speedKmh ?: 0.0) }
        leads = segments(sampled) { it.leadDistanceMeters }
        recommended = segments(sampled) { if (it.leadDistanceMeters == null) null else it.recommendedGapMeters }
        markers = trip.sortedEvents.mapNotNull { e ->
            val s = e.speedKmh ?: points.minByOrNull { abs(it.dateMillis - e.dateMillis) }?.speedKmh ?: return@mapNotNull null
            EventMarker(e.id, e.dateMillis, s, e.kind)
        }
        kindCounts = DrivingEventKind.entries.mapNotNull { k ->
            val c = stats.eventCounts[k] ?: 0
            if (c > 0) KindCount(k, c) else null
        }
        val total = stats.timeBySpeedBand.values.sum()
        bands = TripSpeedBand.entries.mapNotNull { b ->
            val s = stats.timeBySpeedBand[b] ?: 0.0
            if (s > 0 && total > 0) BandShare(b, s, s / total) else null
        }
        maxSpeed = maxOf(stats.maxSpeedKmh, limits.maxOfOrNull { it.value } ?: 0.0, 20.0)
        startMillis = points.firstOrNull()?.dateMillis ?: trip.startedAtMillis
        endMillis = max(startMillis + 1000, points.lastOrNull()?.dateMillis ?: trip.effectiveEndMillis)
    }
}
