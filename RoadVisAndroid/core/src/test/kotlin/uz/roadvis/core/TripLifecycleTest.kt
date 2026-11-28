package uz.roadvis.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TripLifecycleTest {
    private val t0 = 1_800_000_000_000L
    private fun at(seconds: Int): Long = t0 + seconds * 1000L
    private fun point(seconds: Int) = TripPoint(at(seconds), GeoPoint(41.3, 69.28), speedKmh = 30.0)

    @Test fun emptyUnfinishedTripIsPlaceholder() {
        assertTrue(Trip(startedAtMillis = t0).isEmptyPlaceholder)
        assertTrue(Trip(startedAtMillis = t0, points = listOf(point(0))).isEmptyPlaceholder)
    }

    @Test fun interruptedTripWithTrackIsKept() {
        val trip = Trip(startedAtMillis = t0, points = listOf(point(0), point(1)))
        assertFalse(trip.isEmptyPlaceholder)
        assertFalse(trip.isStalePlaceholder(at(86_400)))
    }

    @Test fun finishedTripIsNeverPlaceholder() {
        assertFalse(Trip(startedAtMillis = t0, endedAtMillis = at(5)).isEmptyPlaceholder)
    }

    @Test fun placeholderOfFreshRecordingIsNotStale() {
        val trip = Trip(startedAtMillis = t0)
        assertFalse(trip.isStalePlaceholder(at(30)))
        assertFalse(trip.isStalePlaceholder(at(300)))
        assertTrue(trip.isStalePlaceholder(at(301)))
    }

    @Test fun standingStopsAfterStopTime() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), 0.0))
        assertFalse(timer.update(at(179), 2.0))
        assertTrue(timer.update(at(180), 0.0))
    }

    @Test fun movingResetsStandingTime() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), 0.0))
        assertFalse(timer.update(at(100), 20.0))
        assertNull(timer.stationarySince)
        assertFalse(timer.update(at(200), 0.0))
        assertFalse(timer.update(at(379), 0.0))
        assertTrue(timer.update(at(380), 0.0))
    }

    /** Tunnel: 4 minutes without a usable GPS speed must not end the trip. */
    @Test fun gpsOutageIsNotStanding() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), 60.0))
        for (s in 1..240) assertFalse(timer.update(at(s), null))
        assertNull(timer.stationarySince)
        assertFalse(timer.update(at(241), 55.0))
        assertNull(timer.noSpeedSince)
    }

    @Test fun outageInterruptsStandingTime() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), 0.0))
        assertFalse(timer.update(at(170), null))
        assertFalse(timer.update(at(190), 0.0))
        assertFalse(timer.update(at(369), 0.0))
        assertTrue(timer.update(at(370), 0.0))
    }

    @Test fun longOutageEventuallyStops() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), null))
        assertFalse(timer.update(at(899), null))
        assertTrue(timer.update(at(900), null))
    }

    @Test fun invalidSpeedCountsAsNoSpeed() {
        val timer = TripStandstillTimer()
        assertFalse(timer.update(at(0), -1.0))
        assertFalse(timer.update(at(200), Double.NaN))
        assertNull(timer.stationarySince)
        assertNotNull(timer.noSpeedSince)
    }

    @Test fun resetClearsBothTimers() {
        val timer = TripStandstillTimer()
        timer.update(at(0), 0.0)
        timer.reset()
        assertNull(timer.stationarySince)
        timer.update(at(0), null)
        timer.reset()
        assertNull(timer.noSpeedSince)
        assertFalse(timer.update(at(1000), 0.0))
    }
}
