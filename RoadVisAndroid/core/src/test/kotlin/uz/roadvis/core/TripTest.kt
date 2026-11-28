package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.TimeZone

class TripTest {
    private val t0 = 1_800_000_000_000L
    private fun at(seconds: Double): Long = t0 + Math.round(seconds * 1000)

    /** Straight track northwards at a constant speed, one point per second. */
    private fun straightTrip(seconds: Int, speedKmh: Double, limit: Int? = 60): Trip {
        val points = mutableListOf<TripPoint>()
        var position = GeoPoint(41.3, 69.28)
        for (i in 0..seconds) {
            points.add(TripPoint(at(i.toDouble()), position, speedKmh = speedKmh, speedLimitKmh = limit, horizontalAccuracy = 5.0))
            position = Geo.destination(position, 0.0, speedKmh / 3.6)
        }
        return Trip(startedAtMillis = t0, endedAtMillis = at(seconds.toDouble()), points = points)
    }

    @Test fun statsDistanceDurationSpeed() {
        val stats = TripStats.compute(straightTrip(600, 54.0))
        assertEquals(9_000.0, stats.distanceMeters, 5.0)
        assertEquals(600.0, stats.duration, 1e-9)
        assertEquals(54.0, stats.averageSpeedKmh, 0.1)
        assertEquals(54.0, stats.maxSpeedKmh, 1e-9)
        assertEquals(0.0, stats.timeOverLimit, 1e-9)
        assertEquals(1.0, stats.speedLimitCoverage, 1e-9)
        assertEquals(600.0, stats.timeBySpeedBand[TripSpeedBand.URBAN] ?: 0.0, 1e-9)
    }

    @Test fun timeOverLimitUsesTolerance() {
        var trip = straightTrip(100, 64.0, 60)
        assertEquals(0.0, TripStats.compute(trip).timeOverLimit, 1e-9)
        trip = straightTrip(100, 70.0, 60)
        assertEquals(100.0, TripStats.compute(trip).timeOverLimit, 1e-9)
        trip.thresholds = TripThresholds(speedToleranceKmh = 15.0)
        assertEquals(0.0, TripStats.compute(trip).timeOverLimit, 1e-9)
    }

    @Test fun gapsAreNotIntegrated() {
        val trip = straightTrip(10, 36.0)
        val last = trip.points.last()
        trip.points = trip.points + TripPoint(last.dateMillis + 60_000, last.coordinate, speedKmh = 0.0,
            speedLimitKmh = 60, horizontalAccuracy = 5.0)
        trip.endedAtMillis = trip.points.last().dateMillis
        val stats = TripStats.compute(trip)
        assertEquals(10.0, stats.movingDuration, 1e-9)
        assertEquals(70.0, stats.duration, 1e-9)
    }

    @Test fun eventsPer100kmAndCounts() {
        val trip = straightTrip(600, 60.0)
        trip.events = listOf(DrivingEvent(kind = DrivingEventKind.HARSH_BRAKING, dateMillis = t0),
            DrivingEvent(kind = DrivingEventKind.HARSH_BRAKING, dateMillis = t0),
            DrivingEvent(kind = DrivingEventKind.SPEEDING, dateMillis = t0))
        val stats = TripStats.compute(trip)
        assertEquals(2, stats.eventCounts[DrivingEventKind.HARSH_BRAKING])
        assertEquals(3, stats.totalEvents)
        assertEquals(30.0, stats.eventsPer100km, 0.1)
    }

    @Test fun scoreFormula() {
        assertEquals(100, TripScoring.score(emptyList(), 5_000.0).score)
        val brakes = listOf(DrivingEvent(kind = DrivingEventKind.HARSH_BRAKING), DrivingEvent(kind = DrivingEventKind.HARSH_BRAKING))
        val r = TripScoring.score(brakes, 10_000.0)
        assertEquals(4.0, r.totalPenalty, 1e-9)
        assertEquals(0.4, r.penaltyPerKm, 1e-9)
        assertEquals(96, r.score)
        assertEquals(60, TripScoring.score(brakes, 100.0).score)
        val long = DrivingEvent(kind = DrivingEventKind.SPEEDING, duration = 120.0)
        assertEquals(9.0, TripScoring.penalty(long), 1e-9)
        val many = List(20) { DrivingEvent(kind = DrivingEventKind.RED_LIGHT_RUNNING) }
        assertEquals(0, TripScoring.score(many, 1_000.0).score)
        assertEquals("Отлично", TripScoring.grade(96))
    }

    @Test fun speedingDetectorNeedsFiveSeconds() {
        val detector = SpeedingDetector(TripThresholds(speedToleranceKmh = 5.0, speedingMinSeconds = 5.0))
        val debouncer = DrivingEventDebouncer()
        var emitted = 0
        for (i in 0..12) {
            val e = detector.update(at(i.toDouble()), 72.0, 60, null)
            if (e != null) {
                if (i < 5) fail("event before 5 s")
                emitted += 1
                debouncer.add(e)
            }
        }
        assertEquals(8, emitted)
        assertEquals(1, debouncer.events.size)
        val event = debouncer.events[0]
        assertEquals(t0, event.dateMillis)
        assertEquals(12.0, event.duration, 1e-9)
        assertEquals(12.0, event.value ?: 0.0, 1e-9)
        assertEquals(60.0, event.limit ?: 0.0, 1e-9)

        detector.reset()
        for (i in 0..3) assertNull(detector.update(at(100.0 + i), 80.0, 60, null))
        assertNull(detector.update(at(104.0), 50.0, 60, null))
        for (i in 0..10) assertNull(detector.update(at(200.0 + i), 64.0, 60, null))
        assertNull(detector.update(at(300.0), 150.0, null, null))
        assertEquals(5.0, TripThresholds(speedingMinSeconds = 1.0).speedingMinSeconds, 0.0)
    }

    @Test fun harshBrakingFromGPS() {
        val detector = HarshMotionDetector()
        val events = mutableListOf<DrivingEvent>()
        val speeds = listOf(54.0, 54.0, 54.0, 39.6, 25.2, 10.8, 0.0)
        for ((i, v) in speeds.withIndex()) detector.addSpeed(at(i.toDouble()), v, null)?.let { events.add(it) }
        assertEquals("cooldown keeps one event per manoeuvre", 1, events.size)
        assertEquals(DrivingEventKind.HARSH_BRAKING, events.first().kind)
        assertEquals(4.0, events.first().value ?: 0.0, 0.05)
        assertEquals(3.5, events.first().limit ?: 0.0, 1e-9)
    }

    @Test fun gentleDrivingProducesNoEvents() {
        val detector = HarshMotionDetector()
        for (i in 0 until 30) {
            val v = 20 + i * 3.6 * 1.5
            assertNull(detector.addSpeed(at(i.toDouble()), v, null))
        }
    }

    @Test fun harshAccelerationConfirmedByMotion() {
        val detector = HarshMotionDetector()
        assertNull(detector.addSpeed(t0, 20.0, null))
        detector.addMotion(at(0.5), 3.4)
        val e = detector.addSpeed(at(1.0), 29.0, null)
        assertEquals(DrivingEventKind.HARSH_ACCELERATION, e?.kind)
        assertEquals(3.4, e?.value ?: 0.0, 1e-9)
        val plain = HarshMotionDetector()
        assertNull(plain.addSpeed(t0, 20.0, null))
        assertNull(plain.addSpeed(at(1.0), 29.0, null))
    }

    @Test fun brakingAtLowSpeedIgnored() {
        val detector = HarshMotionDetector()
        assertNull(detector.addSpeed(t0, 8.0, null))
        assertNull(detector.addSpeed(at(1.0), 0.0, null))
    }

    @Test fun jsonRoundTripAndCSV() {
        val trip = straightTrip(5, 36.0)
        trip.origin = TripEndpoint("Дом", GeoPoint(41.3, 69.28))
        trip.destination = TripEndpoint("Работа, офис", GeoPoint(41.31, 69.28))
        trip.events = listOf(DrivingEvent(kind = DrivingEventKind.SPEEDING, dateMillis = t0, coordinate = GeoPoint(41.3, 69.28),
            speedKmh = 72.0, value = 12.0, limit = 60.0, duration = 7.0, note = "ул. \"Тест\", 1"))
        val json = trip.toJson().toString()
        val decoded = Trip.fromJson(org.json.JSONObject(json))
        assertEquals(trip, decoded)

        val events = TripExport.eventsCSV(trip).split("\n").filter { it.isNotEmpty() }
        assertEquals(2, events.size)
        assertTrue(events[1].startsWith("2027-01-15T08:00:00Z,speeding,Превышение скорости,1,41.300000,69.280000,72.0,12.00,60.00,7.0,0,"))
        assertTrue(events[1].endsWith("\"ул. \"\"Тест\"\", 1\""))
        val points = TripExport.pointsCSV(trip).split("\n").filter { it.isNotEmpty() }
        assertEquals(7, points.size)
        assertEquals("2027-01-15T08:00:00Z,41.300000,69.280000,36.0,60,,,5.0", points[1])
        assertEquals("trip_2027-01-15_08-00", TripExport.baseFileName(trip, TimeZone.getTimeZone("UTC")))
    }

    @Test fun speedBands() {
        assertEquals(TripSpeedBand.STANDING, TripSpeedBand.band(0.0))
        assertEquals(TripSpeedBand.SLOW, TripSpeedBand.band(29.9))
        assertEquals(TripSpeedBand.FAST, TripSpeedBand.band(60.0))
        assertEquals(TripSpeedBand.HIGHWAY, TripSpeedBand.band(130.0))
    }
}
