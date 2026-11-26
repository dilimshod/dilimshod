package uz.roadvis.app.trips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.DrivingEventKind
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.Trip
import uz.roadvis.core.TripPoint
import uz.roadvis.core.TripStats

class TripChartDataTest {
    private fun trip(): Trip {
        val t0 = 1_700_000_000_000L
        val points = (0 until 20).map { i ->
            TripPoint(
                dateMillis = t0 + i * 1000L,
                coordinate = GeoPoint(41.3 + i * 0.0001, 69.2),
                speedKmh = 40.0 + i,
                speedLimitKmh = if (i in 5..9) null else 50,
                leadDistanceMeters = if (i < 10) 20.0 else null,
                recommendedGapMeters = 22.0,
                horizontalAccuracy = 5.0,
            )
        }
        val event = DrivingEvent(kind = DrivingEventKind.SPEEDING, dateMillis = t0 + 15_000, speedKmh = null)
        return Trip(startedAtMillis = t0, endedAtMillis = t0 + 20_000, points = points, events = listOf(event))
    }

    @Test
    fun limitGapSplitsSegments() {
        val t = trip()
        val data = TripChartData(t, TripStats.compute(t))
        assertEquals(setOf(1, 2), data.limits.map { it.segment }.toSet())
        assertEquals(15, data.limits.size)
        assertEquals(10, data.leads.size)
        assertEquals(10, data.recommended.size)
        assertTrue(data.hasLeadData)
    }

    @Test
    fun eventMarkerTakesNearestPointSpeed() {
        val t = trip()
        val data = TripChartData(t, TripStats.compute(t))
        assertEquals(1, data.markers.size)
        assertEquals(55.0, data.markers[0].speedKmh, 1e-9)
        assertEquals(listOf(DrivingEventKind.SPEEDING), data.kindCounts.map { it.kind })
        assertTrue(data.maxSpeed >= 59.0)
    }

    @Test
    fun boundsHaveMinimumSizeAndMargin() {
        val t = trip()
        val b = TripMapGeometry.paddedBounds(t)
        assertTrue(b.north - b.south >= 600.0 / 111_320 * 1.3 - 1e-9)
        assertTrue(b.south < 41.3 && b.north > 41.3019)
    }
}
