package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.abs

class SignalTimingTest {
    private val tz: TimeZone = TimeZone.getTimeZone("Asia/Tashkent")

    /** Local Tashkent time. 2026-11-23 is a Monday, 2026-11-28 a Saturday. */
    private fun date(day: Int, hour: Int, minute: Int = 0, month: Int = 11): Date =
        GregorianCalendar(tz).apply { clear(); set(2026, month - 1, day, hour, minute, 0) }.time

    private fun Date.plus(seconds: Double) = Date(time + (seconds * 1000).toLong())

    // Model

    @Test fun fixedTimeModel() {
        val e = SignalWaitModel.estimate(SignalTimingAssumptions())
        assertEquals(0.55, e.stopProbability, 1e-9)
        assertEquals(24.75, e.meanWaitIfStopped, 1e-9)
        assertEquals(13.6125, e.expectedWaitSeconds, 1e-9)
        assertEquals(0, e.observationCount)
        assertEquals(SignalWaitEstimate.Source.MODEL, e.source)
        assertTrue(e.sourceDescription.contains("оценка"))

        val half = SignalWaitModel.estimate(SignalTimingAssumptions(60.0, 0.5))
        assertEquals(0.5, half.stopProbability, 1e-9)
        assertEquals(15.0, half.meanWaitIfStopped, 1e-9)
        assertEquals(7.5, half.expectedWaitSeconds, 1e-9)
        // E[wait] = P(stop) · E[wait | stop]
        assertEquals(half.stopProbability * half.meanWaitIfStopped, half.expectedWaitSeconds, 1e-9)
    }

    @Test fun modelSanitizesInput() {
        val allGreen = SignalWaitModel.estimate(SignalTimingAssumptions(90.0, 1.5))
        assertEquals(0.0, allGreen.expectedWaitSeconds, 0.0)
        assertEquals(0.0, allGreen.stopProbability, 0.0)
        val zeroCycle = SignalWaitModel.estimate(SignalTimingAssumptions(0.0, 0.0))
        assertEquals(1.0, zeroCycle.stopProbability, 1e-9)
        assertTrue(zeroCycle.expectedWaitSeconds.isFinite())
        val nan = SignalWaitModel.estimate(SignalTimingAssumptions(Double.NaN, Double.NaN))
        assertEquals("non-finite input falls back to the defaults", 13.6125, nan.expectedWaitSeconds, 1e-9)
    }

    // Statistics

    @Test fun estimateWithoutObservationsIsModel() {
        val stats = SignalStatistics()
        val a = SignalTimingAssumptions()
        assertEquals(SignalWaitModel.estimate(a), stats.estimate("node/1", date(23, 8), a, tz))
        assertEquals(0, stats.totalObservations)
    }

    @Test fun blendingWithFewObservations() {
        val stats = SignalStatistics()
        stats.record(SignalObservation("node/1", date(23, 8), true, 40.0))
        val e = stats.estimate("node/1", date(24, 8, 30), SignalTimingAssumptions(), tz)
        // n = 1 → w = 0.2
        assertEquals(SignalWaitEstimate.Source.BLENDED, e.source)
        assertEquals(1, e.observationCount)
        assertEquals(0.2 * 40 + 0.8 * 13.6125, e.expectedWaitSeconds, 1e-9)
        assertEquals(0.2 * 1 + 0.8 * 0.55, e.stopProbability, 1e-9)
        assertEquals(0.2 * 40 + 0.8 * 24.75, e.meanWaitIfStopped, 1e-9)
        assertTrue(e.sourceDescription.contains("1 набл."))
    }

    @Test fun learnedWithFiveObservations() {
        val stats = SignalStatistics()
        val waits = listOf(true to 30.0, false to 0.0, true to 40.0, false to 0.0, true to 50.0)
        for ((i, w) in waits.withIndex()) stats.record(SignalObservation("node/7", date(23, 12, i), w.first, w.second))
        val e = stats.estimate("node/7", date(25, 13), SignalTimingAssumptions(), tz)
        assertEquals(SignalWaitEstimate.Source.LEARNED, e.source)
        assertEquals(5, e.observationCount)
        assertEquals(0.6, e.stopProbability, 1e-9)
        assertEquals(40.0, e.meanWaitIfStopped, 1e-9)
        assertEquals(24.0, e.expectedWaitSeconds, 1e-9)
        // Other signals are unaffected.
        assertEquals(SignalWaitEstimate.Source.MODEL, stats.estimate("node/8", date(25, 13), SignalTimingAssumptions(), tz).source)
    }

    @Test fun peakBucketIsPreferred() {
        val stats = SignalStatistics()
        for (i in 0 until 5) {
            stats.record(SignalObservation("s", date(23 + i, 8), true, 60.0))      // Mon–Fri peak
            stats.record(SignalObservation("s", date(23 + i, 13), false, 0.0))     // off-peak
        }
        val a = SignalTimingAssumptions()
        val peak = stats.estimate("s", date(24, 8, 30), a, tz)
        assertEquals(5, peak.observationCount)
        assertEquals(1.0, peak.stopProbability, 1e-9)
        assertEquals(60.0, peak.expectedWaitSeconds, 1e-9)

        val saturdayMorning = stats.estimate("s", date(28, 8, 30), a, tz)
        assertEquals(5, saturdayMorning.observationCount)
        assertEquals(0.0, saturdayMorning.stopProbability, 1e-9)
        assertEquals(0.0, saturdayMorning.expectedWaitSeconds, 1e-9)
        assertEquals("no stops observed → model wait if stopped", 24.75, saturdayMorning.meanWaitIfStopped, 1e-9)
        assertEquals(SignalWaitEstimate.Source.LEARNED, saturdayMorning.source)
    }

    @Test fun fallbackToAllObservationsWhenBucketEmpty() {
        val stats = SignalStatistics()
        for (i in 0 until 3) stats.record(SignalObservation("s", date(23 + i, 18), true, 45.0))
        val offPeak = stats.estimate("s", date(25, 23), SignalTimingAssumptions(), tz)
        assertEquals(3, offPeak.observationCount)
        assertEquals(SignalWaitEstimate.Source.BLENDED, offPeak.source)
        assertEquals(0.6 * 1 + 0.4 * 0.55, offPeak.stopProbability, 1e-9)
    }

    @Test fun peakHours() {
        assertTrue(SignalStatistics.isPeak(date(23, 7), tz))
        assertFalse(SignalStatistics.isPeak(date(23, 6, 59), tz))
        assertTrue(SignalStatistics.isPeak(date(23, 9, 59), tz))
        assertFalse(SignalStatistics.isPeak(date(23, 10), tz))
        assertFalse(SignalStatistics.isPeak(date(25, 12), tz))
        assertTrue(SignalStatistics.isPeak(date(27, 17), tz))
        assertTrue(SignalStatistics.isPeak(date(27, 19, 30), tz))
        assertFalse(SignalStatistics.isPeak(date(27, 20), tz))
        assertFalse("Saturday", SignalStatistics.isPeak(date(28, 8), tz))
        assertFalse("Sunday", SignalStatistics.isPeak(date(29, 18), tz))
        // The same instant is off-peak in another time zone (02:00 UTC = 07:00 Tashkent).
        assertFalse(SignalStatistics.isPeak(date(23, 7), TimeZone.getTimeZone("UTC")))
    }

    @Test fun keepsNewestFiftyInDateOrder() {
        val stats = SignalStatistics()
        val start = date(23, 0)
        for (i in 0 until 60) stats.record(SignalObservation("s", start.plus(i * 600.0), i % 2 == 0, i.toDouble()))
        val list = stats.observations("s")
        assertEquals(SignalStatistics.maxObservationsPerSignal, list.size)
        assertEquals(10.0, list.first().waitSeconds, 0.0)
        assertEquals(59.0, list.last().waitSeconds, 0.0)

        // An older observation arriving late is inserted in date order (and is the oldest → dropped first).
        stats.record(SignalObservation("s", start.plus(15 * 600.0 + 1), true, 99.0))
        val after = stats.observations("s")
        assertEquals(50, after.size)
        assertEquals(after.map { it.date }.sorted(), after.map { it.date })
        assertTrue(after.any { it.waitSeconds == 99.0 })
        assertFalse(after.any { it.waitSeconds == 10.0 })

        // Invalid waits are ignored.
        stats.record(SignalObservation("t", start, true, -5.0))
        stats.record(SignalObservation("t", start, true, Double.NaN))
        assertEquals(emptyList<SignalObservation>(), stats.observations("t"))
        assertEquals(listOf("s"), stats.signalIDs)
        assertEquals(50, stats.totalObservations)
        stats.removeAll()
        assertEquals(0, stats.totalObservations)
    }

    @Test fun codableRoundTrip() {
        val stats = SignalStatistics()
        stats.record(SignalObservation("node/1", date(23, 8), true, 35.0))
        stats.record(SignalObservation("node/1", date(24, 8), false, 0.0))
        stats.record(SignalObservation("node/2", date(24, 9), true, 20.0))
        val data = stats.toJSON()
        val restored = SignalStatistics.fromJSON(data)
        assertEquals(3, restored.totalObservations)
        assertEquals(stats.observations("node/1"), restored.observations("node/1"))
        val a = SignalTimingAssumptions()
        assertEquals(stats.estimate("node/1", date(25, 8), a, tz), restored.estimate("node/1", date(25, 8), a, tz))
        val empty = SignalStatistics.fromJSON("{}")
        assertEquals(0, empty.totalObservations)
    }

    // Stop detector

    private val signal = SignalLocation("node/42", GeoPoint(41.3, 69.28))
    private val base = Date(1_795_000_000_000L)

    private data class Sample(val t: Double, val y: Double, val v: Double)

    /** Point `y` metres north (negative: south) of the signal. */
    private fun at(y: Double): GeoPoint = Geo.destination(signal.coordinate, if (y >= 0) 0.0 else 180.0, abs(y))

    /** Feeds (seconds, metres north of the signal, km/h) samples and collects observations. */
    private fun run(detector: StopDetector, samples: List<Sample>, signals: List<SignalLocation>? = null): List<Pair<Int, SignalObservation>> {
        val result = ArrayList<Pair<Int, SignalObservation>>()
        for ((i, s) in samples.withIndex()) {
            val o = detector.update(at(s.y), s.v, base.plus(s.t), signals ?: listOf(signal))
            if (o != null) result.add(i to o)
        }
        return result
    }

    private fun approach(to: Double, start: Double = -200.0, speed: Double = 36.0): MutableList<Sample> {
        val step = speed / 3.6
        val samples = ArrayList<Sample>()
        var t = 0.0
        var pos = start
        while (pos < to) {
            samples.add(Sample(t, pos, speed))
            t += 1
            pos += step
        }
        return samples
    }

    private fun depart(from: Double, at: Double, until: Double = 200.0, speed: Double = 36.0): List<Sample> {
        val step = speed / 3.6
        val samples = ArrayList<Sample>()
        var t = at
        var pos = from
        while (pos <= until) {
            samples.add(Sample(t, pos, speed))
            t += 1
            pos += step
        }
        return samples
    }

    @Test fun stopAtRedLight() {
        val samples = approach(-10.0)                                   // t = 0…18, y = -200…-20
        for (t in 19..48) samples.add(Sample(t.toDouble(), -10.0, 0.0))  // standing 30 s
        samples += depart(0.0, 49.0)
        val detector = StopDetector()
        val observations = run(detector, samples)
        assertEquals(1, observations.size)
        val o = observations[0].second
        assertEquals("node/42", o.signalID)
        assertTrue(o.stopped)
        assertEquals(30.0, o.waitSeconds, 1e-6)
        assertEquals("entered the 45 m area at y = -40", base.plus(16.0), o.date)
        val leftAt = samples[observations[0].first].y
        assertTrue(leftAt >= 60)
        assertTrue(leftAt <= 71)
        assertNull(detector.currentSignalID)
    }

    @Test fun passingOnGreen() {
        val observations = run(StopDetector(), approach(200.0))
        assertEquals(1, observations.size)
        assertFalse(observations[0].second.stopped)
        assertEquals(0.0, observations[0].second.waitSeconds, 0.0)
    }

    @Test fun shortHaltIsNotAStop() {
        val samples = approach(-10.0)
        samples.add(Sample(19.0, -10.0, 0.0))
        samples += depart(-10.0, 20.0)
        val observations = run(StopDetector(), samples)
        assertEquals(1, observations.size)
        assertFalse("1 s < minStopSeconds", observations[0].second.stopped)
    }

    @Test fun creepingInQueueCountsAsWaiting() {
        val samples = approach(-20.0)                                         // t = 0…17
        var y = -20.0
        for (t in 18..27) samples.add(Sample(t.toDouble(), y, 0.0))            // standing 10 s
        for (t in 28..37) { y += 5 / 3.6; samples.add(Sample(t.toDouble(), y, 5.0)) }   // creeping at 5 km/h (still "halted")
        for (t in 38..42) samples.add(Sample(t.toDouble(), y, 0.0))            // standing 5 s
        samples += depart(y + 10, 43.0)
        val observations = run(StopDetector(), samples)
        assertEquals(1, observations.size)
        assertTrue(observations[0].second.stopped)
        assertEquals(25.0, observations[0].second.waitSeconds, 1e-6)
    }

    @Test fun waitWhileWaitingIsExposed() {
        val detector = StopDetector()
        val samples = approach(-10.0)
        for (t in 19..29) samples.add(Sample(t.toDouble(), -10.0, 0.0))
        run(detector, samples)
        assertEquals("node/42", detector.currentSignalID)
        assertEquals(10.0, detector.currentWaitSeconds, 1e-6)
    }

    @Test fun gpsJumpDiscardsPass() {
        val samples = approach(-25.0)                 // inside the area
        samples.add(Sample(20.0, 500.0, 36.0))        // jump of > 500 m
        samples.add(Sample(21.0, -20.0, 0.0))         // and back
        for (t in 22..40) samples.add(Sample(t.toDouble(), -20.0, 0.0))
        samples += depart(-10.0, 41.0)
        assertEquals("a pass with a GPS jump is ignored entirely", 0, run(StopDetector(), samples).size)
    }

    @Test fun twoSignalsInARow() {
        val second = SignalLocation("node/43", at(100.0))
        val observations = run(StopDetector(), approach(300.0), listOf(signal, second))
        assertEquals(listOf("node/42", "node/43"), observations.map { it.second.signalID })
        assertTrue(observations.all { !it.second.stopped })
    }

    @Test fun noSignalsAndReset() {
        val detector = StopDetector()
        assertEquals(0, run(detector, approach(200.0), emptyList()).size)

        val resetting = StopDetector()
        val samples = approach(0.0)
        run(resetting, samples)
        assertEquals("node/42", resetting.currentSignalID)
        resetting.reset()
        assertNull(resetting.currentSignalID)
        // After reset the next fixes start a new pass (no stale observation is emitted for the old one).
        val rest = depart(10.0, 30.0)
        val observations = run(resetting, rest)
        assertEquals(1, observations.size)
        assertEquals(base.plus(30.0), observations[0].second.date)
    }

    @Test fun invalidSpeedIsDerivedFromMovement() {
        val samples = approach(-10.0).map { Sample(it.t, it.y, -1.0) }.toMutableList()   // ends at t = 18, y = -20
        samples.add(Sample(19.0, -10.0, -1.0))                                            // still moving (10 m/s)
        for (t in 20..29) samples.add(Sample(t.toDouble(), -10.0, -1.0))                  // stationary → derived 0 km/h
        samples += depart(0.0, 30.0).map { Sample(it.t, it.y, -1.0) }
        val observations = run(StopDetector(), samples)
        assertEquals(1, observations.size)
        assertTrue(observations[0].second.stopped)
        assertEquals(10.0, observations[0].second.waitSeconds, 1e-6)
    }

    @Test fun pausedLocationUpdatesWhileStanding() {
        val samples = approach(-10.0)
        samples.add(Sample(19.0, -10.0, 0.0))
        samples.add(Sample(59.0, -5.0, 20.0))      // next fix only 40 s later (distance filter while stationary)
        samples += depart(5.0, 60.0)
        val observations = run(StopDetector(), samples)
        assertEquals(1, observations.size)
        assertEquals(40.0, observations[0].second.waitSeconds, 1e-6)
    }

    @Test fun veryLongStandIsDiscarded() {
        val samples = approach(-10.0)
        var t = 19.0
        while (t < 19 + 400) { samples.add(Sample(t, -10.0, 0.0)); t += 10 }
        samples += depart(0.0, t)
        assertEquals("standing > 5 min is parking, not a signal", 0, run(StopDetector(), samples).size)
    }
}
