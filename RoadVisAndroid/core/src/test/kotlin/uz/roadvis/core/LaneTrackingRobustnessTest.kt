package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Port of LaneTrackingRobustnessTests.swift: coasting, second (low-score) association, horizon auto-calibration,
// crossing check at the ROI middle, adaptive lane thresholds, accumulation of dashed lines.
// The synthetic road generator is the Swift one (uniform pixel noise, straight lines, same LCG).

private object Road {
    const val width = 160
    const val height = 284

    /** Grey road with two markings meeting at ([vanishingX], [horizon]); [left] / [right] are x at the bottom row. */
    fun image(
        horizon: Double = 0.42, left: Double? = 10.0, right: Double? = 150.0, vanishingX: Double = 80.0,
        road: Int = 95, marking: Int = 225, noise: Int = 6, seed: Long = 1,
    ): LaneImage {
        val img = LaneImage(width, height, 0)
        var rng = seed
        fun rand(): Int {
            rng = rng * 6364136223846793005L + 1442695040888963407L
            return ((rng ushr 33) % (2 * noise + 1).toLong()).toInt() - noise
        }
        val hy = (height * horizon).toInt()
        for (y in 0 until height) for (x in 0 until width) {
            img[x, y] = ((if (y < hy) 200 else road) + (if (noise > 0) rand() else 0)).coerceIn(0, 255)
        }
        val yb = (height - 1).toDouble(); val yh = height * horizon
        for ((index, bottom) in listOf(left, right).withIndex()) {
            if (bottom == null) continue
            for (y in (hy + 1) until height) {
                val t = (y - yh) / (yb - yh)
                if (index == 1 && ((t * 12).toInt() % 2 == 1)) continue // right line dashed
                val x = vanishingX + (bottom - vanishingX) * t
                val half = max(0.6, 2.8 * t)
                val x0 = (x - half).rounded().toInt(); val x1 = (x + half).rounded().toInt()
                if (!(x0 <= width - 1 && x1 >= 0 && x0 <= x1)) continue
                for (xx in max(0, x0)..min(width - 1, x1)) {
                    img[xx, y] = (marking + (if (noise > 0) rand() else 0)).coerceIn(0, 255)
                }
            }
        }
        return img
    }

    /** Both lines dashed with duty cycle [duty] in ROAD distance; [phase] (metres) moves the dashes toward the car. */
    fun dashed(duty: Double, phase: Double, seed: Long, period: Double = 12.0): LaneImage {
        val img = image(left = null, right = null, seed = seed)
        val yb = (height - 1).toDouble(); val yh = height * 0.42
        for (bottom in listOf(10.0, 150.0)) {
            for (y in (yh.toInt() + 1) until height) {
                val t = (y - yh) / (yb - yh)
                val z = 5.0 / max(0.02, t) // 5 m at the bottom row
                val ph = ((z + phase) / period) % 1.0
                if (ph > duty) continue
                val x = 80 + (bottom - 80) * t; val half = max(0.6, 2.8 * t)
                val x0 = (x - half).rounded().toInt(); val x1 = (x + half).rounded().toInt()
                if (!(x0 <= width - 1 && x1 >= 0 && x0 <= x1)) continue
                for (xx in max(0, x0)..min(width - 1, x1)) img[xx, y] = 225
            }
        }
        return img
    }

    fun run(config: LaneDetector.Config = LaneDetector.Config(), frames: Int = 8, make: (Long) -> LaneImage): LaneEstimate {
        val detector = LaneDetector(config)
        var estimate = LaneEstimate.empty()
        for (i in 0 until frames) estimate = detector.process(make((i + 1).toLong()), i * 0.2)
        return estimate
    }
}

class LaneHorizonTest {
    @Test fun crossingCheckToleratesWrongConfiguredHorizon() {
        // True horizon below the configured 0.42: the two correct lines cross between the two rows.
        for (horizon in listOf(0.48, 0.54, 0.60)) {
            val estimate = Road.run { Road.image(horizon = horizon, seed = it) }
            assertTrue("horizon $horizon", estimate.leftConfidence >= 0.5)
            assertTrue("horizon $horizon", estimate.rightConfidence >= 0.5)
            assertNotNull(estimate.left)
            assertNotNull(estimate.right)
        }
        // And above it (was fine before, must stay fine).
        for (horizon in listOf(0.30, 0.36)) {
            val estimate = Road.run { Road.image(horizon = horizon, seed = it) }
            assertTrue("horizon $horizon", min(estimate.leftConfidence, estimate.rightConfidence) >= 0.5)
        }
    }

    @Test fun vanishingPointOfRawFits() {
        for (horizon in listOf(0.30, 0.36, 0.48, 0.54, 0.60)) {
            val config = LaneDetector.Config() // configured 0.42 whatever the truth
            val image = Road.image(horizon = horizon)
            val fits = LaneDetector.detectLines(image, config)
            val point = LaneDetector.vanishingPoint(fits.first, fits.second, 160.0, 284.0, config)
            assertNotNull("horizon $horizon", point)
            assertEquals("horizon $horizon", horizon, point?.y ?: 0.0, 0.02)
            assertEquals("horizon $horizon", 0.5, point?.x ?: 0.0, 0.04)
        }
        val config = LaneDetector.Config()
        val oneLine = LaneDetector.detectLines(Road.image(right = null), config)
        assertNull(LaneDetector.vanishingPoint(oneLine.first, oneLine.second, 160.0, 284.0, config))
    }

    @Test fun horizonEstimatorConverges() {
        for (horizon in listOf(0.30, 0.36, 0.48, 0.54, 0.60)) {
            val detector = LaneDetector()
            val estimator = LaneHorizonEstimator()
            var convergedAt = -1
            var estimate = LaneEstimate.empty()
            for (i in 0 until 40) {
                val sway = 6 * sin(i / 5.0)
                val image = Road.image(horizon = horizon, left = 10 + sway, right = 150 + sway,
                    vanishingX = 80 + 3 * sin(i / 7.0), seed = (i + 1).toLong())
                estimate = detector.process(image, i * 0.2)
                val y = estimator.add(detector.lastVanishingPoint)
                if (y != null) {
                    if (LaneHorizonEstimator.shouldApply(y, detector.config.horizonY)) detector.setHorizon(y)
                    if (convergedAt < 0 && abs(y - horizon) < 0.015) convergedAt = i
                }
            }
            assertTrue("horizon $horizon", convergedAt >= LaneHorizonEstimator.minSamples - 1)
            assertTrue("horizon $horizon", convergedAt <= 20) // ≤ 4 s at 5 Hz
            assertEquals("horizon $horizon", horizon, detector.config.horizonY, 0.02)
            assertTrue("horizon $horizon", estimate.leftConfidence >= 0.6)
            assertTrue("horizon $horizon", estimate.rightConfidence >= 0.6)
        }
    }

    @Test fun horizonEstimatorIgnoresSingleLineAndWideSpread() {
        val estimator = LaneHorizonEstimator()
        // No point, weak fits, out-of-range rows / columns: never a sample.
        repeat(30) {
            assertNull(estimator.add(null))
            assertNull(estimator.add(LaneVanishingPoint(0.5, 0.45, 0.3)))
            assertNull(estimator.add(LaneVanishingPoint(0.5, 0.75, 0.9)))
            assertNull(estimator.add(LaneVanishingPoint(0.5, 0.15, 0.9)))
            assertNull(estimator.add(LaneVanishingPoint(0.9, 0.45, 0.9)))
        }
        assertEquals(0, estimator.sampleCount)
        // Widely spread rows (hills / a curve): enough samples but no estimate.
        for (i in 0 until 25) assertNull(estimator.add(LaneVanishingPoint(0.5, 0.30 + 0.012 * i, 0.9)))
        // Consistent samples replace the spread ones: an estimate once the window's middle half agrees.
        var result: Double? = null
        repeat(25) { result = estimator.add(LaneVanishingPoint(0.5, 0.50, 0.9)) }
        assertEquals(0.50, result ?: 0.0, 1e-9)
        // Fewer than `minSamples`: nothing yet.
        val fresh = LaneHorizonEstimator()
        repeat(LaneHorizonEstimator.minSamples - 1) { assertNull(fresh.add(LaneVanishingPoint(0.5, 0.5, 0.9))) }
        assertNotNull(fresh.add(LaneVanishingPoint(0.5, 0.5, 0.9)))
        // A stored start value is reported until samples say otherwise; out-of-range start values are ignored.
        assertEquals(0.47, LaneHorizonEstimator(0.47).horizonY!!, 0.0)
        assertNull(LaneHorizonEstimator(0.05).horizonY)
        fresh.reset()
        assertNull(fresh.horizonY)
        assertFalse(LaneHorizonEstimator.shouldApply(0.43, 0.42))
        assertTrue(LaneHorizonEstimator.shouldApply(0.44, 0.42))
    }

    @Test fun setHorizonKeepsLinesInPlace() {
        val detector = LaneDetector()
        var before = LaneEstimate.empty()
        for (i in 0 until 6) before = detector.process(Road.image(seed = (i + 1).toLong()), i * 0.2)
        detector.setHorizon(0.50)
        val after = detector.process(Road.image(seed = 9), 1.2)
        // Same image lines: x at a common row is unchanged although the horizon row moved.
        val row = 0.8
        assertEquals(before.left?.x(row) ?: 1.0, after.left?.x(row) ?: 0.0, 0.02)
        assertEquals(before.right?.x(row) ?: 1.0, after.right?.x(row) ?: 0.0, 0.02)
        assertTrue(min(after.leftConfidence, after.rightConfidence) >= 0.5)
    }
}

class LaneAdaptiveThresholdTest {
    @Test fun nightMarkingsDetected() {
        // Road 30 / marking 70: below the fixed brightness floor of 85, nothing was detected.
        val night = Road.run { Road.image(road = 30, marking = 70, seed = it) }
        assertTrue(night.leftConfidence >= 0.6)
        assertTrue(night.rightConfidence >= 0.6)
        val darker = Road.run { Road.image(road = 20, marking = 50, seed = it) }
        assertTrue(min(darker.leftConfidence, darker.rightConfidence) >= 0.6)
        // The fixed thresholds really fail here (the reason for the change).
        val fixed = Road.run(LaneDetector.Config(adaptiveThresholds = false)) { Road.image(road = 30, marking = 70, seed = it) }
        assertNull(fixed.left)
        assertNull(fixed.right)
    }

    @Test fun wornMarkingDetected() {
        // Road 95 / marking 108: contrast 13 is below the fixed ridge (14) and local (18) contrasts.
        val worn = Road.run { Road.image(road = 95, marking = 108, seed = it) }
        assertTrue(min(worn.leftConfidence, worn.rightConfidence) >= 0.45)
        val fixed = Road.run(LaneDetector.Config(adaptiveThresholds = false)) { Road.image(road = 95, marking = 108, seed = it) }
        assertNull(fixed.left)
    }

    @Test fun dayMarkingsUnchanged() {
        val day = Road.run { Road.image(seed = it) }
        assertTrue(min(day.leftConfidence, day.rightConfidence) >= 0.7)
        val noisy = Road.run { Road.image(noise = 20, seed = it) }
        assertTrue(min(noisy.leftConfidence, noisy.rightConfidence) >= 0.6)
    }

    @Test fun noFalseLinesOnNoisyEmptyRoad() {
        var falseFits = 0; var total = 0
        for (road in listOf(30, 60, 95, 150)) {
            for (noise in listOf(2, 6, 10, 14, 20)) {
                for (seed in 1..5) {
                    val image = Road.image(left = null, right = null, road = road, noise = noise,
                        seed = (seed * 31 + noise).toLong())
                    val fits = LaneDetector.detectLines(image, LaneDetector.Config())
                    total += 2
                    falseFits += (if (fits.first != null) 1 else 0) + (if (fits.second != null) 1 else 0)
                }
            }
        }
        assertEquals(200, total)
        assertEquals(0, falseFits)
    }

    @Test fun thresholdsFollowNoiseAndBrightness() {
        val config = LaneDetector.Config()
        val quiet = LaneDetector.adaptiveThresholds(Road.image(left = null, right = null, road = 30, noise = 2), config)
        assertEquals(8, quiet.ridgeContrast) // floors
        assertEquals(10, quiet.localContrast)
        assertTrue(quiet.minBrightness < 60) // dark road → low floor (≥ 30)
        assertTrue(quiet.minBrightness >= 30)
        val loud = LaneDetector.adaptiveThresholds(Road.image(left = null, right = null, road = 150, noise = 20), config)
        assertTrue(loud.ridgeContrast > 14) // noisy → stricter than the fixed values
        assertTrue(loud.localContrast > 18)
        assertEquals(85, loud.minBrightness) // never above the configured floor
        val off = LaneDetector.adaptiveThresholds(Road.image(road = 30), LaneDetector.Config(adaptiveThresholds = false))
        assertEquals(85, off.minBrightness)
        assertEquals(14, off.ridgeContrast)
        assertEquals(18, off.localContrast)
        // Tiny image: fallback, no crash.
        val tiny = LaneDetector.adaptiveThresholds(LaneImage(8, 8, 50), config)
        assertEquals(14, tiny.ridgeContrast)
    }
}

class LaneAccumulationTest {
    private class Score(val ok: Int, val total: Int, val mean: Double)

    /** Frames on which both lines reach 0.45, and the mean of the weaker confidence (frames 5…). */
    private fun score(accumulate: Int, duty: Double): Score {
        val detector = LaneDetector(LaneDetector.Config(accumulateFrames = accumulate))
        var ok = 0
        var sum = 0.0
        val frames = 60
        for (i in 0 until frames) {
            // 50 km/h at 5 Hz = 2.8 m per lane frame.
            val image = Road.dashed(duty, i * 2.8, (i + 1).toLong())
            val estimate = detector.process(image, i * 0.2)
            if (i >= 5) {
                if (estimate.leftConfidence >= 0.45 && estimate.rightConfidence >= 0.45) ok += 1
                sum += min(estimate.leftConfidence, estimate.rightConfidence)
            }
        }
        return Score(ok, frames - 5, sum / (frames - 5))
    }

    @Test fun sparseDashedLinesNeedAccumulation() {
        val single = score(1, 0.25)
        val three = score(3, 0.25)
        assertEquals(three.total, three.ok)                 // every frame
        assertTrue(single.ok < single.total * 3 / 4)        // single frames often miss a line
        assertTrue(three.mean > single.mean + 0.15)
        assertTrue(three.mean >= 0.7)
    }

    @Test fun accumulationIsTheDefaultAndResetsOnGapsAndSizeChanges() {
        assertEquals(3, LaneDetector.Config().accumulateFrames)
        // Frames 1 s apart are not mixed: an empty road right after a marked one gives no fits.
        val detector = LaneDetector()
        detector.process(Road.image(seed = 1), 0.0)
        detector.process(Road.image(left = null, right = null, seed = 2), 1.0)
        assertNull(detector.lastVanishingPoint)
        val near = LaneDetector()
        near.process(Road.image(seed = 1), 0.0)
        near.process(Road.image(left = null, right = null, seed = 2), 0.2)
        assertNotNull(near.lastVanishingPoint) // the previous frame's lines are still in
        // Another image size: no crash, no mixing.
        val small = LaneImage(80, 142, 95)
        small[40, 100] = 96
        near.process(small, 0.4)
        assertNull(near.lastVanishingPoint)
        // reset() forgets the history.
        val cleared = LaneDetector()
        cleared.process(Road.image(seed = 1), 0.0)
        cleared.reset()
        cleared.process(Road.image(left = null, right = null, seed = 2), 0.2)
        assertNull(cleared.lastVanishingPoint)
    }
}

class TrackCoastingTest {
    private val geometry = CameraGeometry(65.0, 1080.0, 1920.0)

    private fun det(kind: VehicleKind, confidence: Double, x: Double = 0.4, y: Double = 0.5, w: Double = 0.2, h: Double = 0.1) =
        Detection(kind = kind, label = kind.raw, confidence = confidence, box = BBox(x, y, w, h))

    private fun track(
        id: Int, kind: VehicleKind, box: BBox, t: Double, missed: Int = 0, confidence: Double = 0.9,
    ) = TrackedObject(id = id, kind = kind, label = if (kind == VehicleKind.PERSON) "person" else "car", box = box,
        confidence = confidence, hits = 6, missed = missed, firstSeen = 0.0, lastSeen = t, isConfirmed = true)

    @Test fun coastedTrackIsReturnedWithPredictedBoxThenDropped() {
        val tracker = ObjectTracker()
        assertEquals(3, tracker.config.coastFrames)
        var tracks: List<TrackedObject> = emptyList()
        // Moves right by 0.01 per 0.1 s frame.
        for (i in 0 until 5) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8, x = 0.40 + 0.01 * i)), i * 0.1)
        val id = tracks.first().id
        val lastX = tracks.first().box.midX
        for (miss in 1..3) {
            tracks = tracker.update(emptyList(), 0.4 + miss * 0.1)
            assertEquals("miss $miss", 1, tracks.size)
            assertEquals(id, tracks.first().id)
            assertEquals(miss, tracks.first().missed)
            assertEquals(5, tracks.first().hits)
            // Extrapolated along the motion, roughly 0.01 per frame.
            assertTrue("miss $miss", tracks.first().box.midX > lastX + 0.005 * miss)
            assertTrue("miss $miss", tracks.first().box.midX < lastX + 0.02 * miss)
        }
        // Fourth missed frame: no longer returned (the track itself lives on for re-acquisition).
        assertTrue(tracker.update(emptyList(), 0.8).isEmpty())
        val again = tracker.update(listOf(det(VehicleKind.CAR, 0.8, x = 0.49)), 0.9)
        assertEquals(id, again.firstOrNull()?.id)
        assertEquals(0, again.firstOrNull()?.missed)
    }

    @Test fun coastedTrackNotCountedTwice() {
        val tracker = ObjectTracker()
        for (i in 0 until 4) tracker.update(listOf(det(VehicleKind.CAR, 0.8)), i * 0.1)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
        tracker.update(emptyList(), 0.4)
        tracker.update(emptyList(), 0.5)
        tracker.update(listOf(det(VehicleKind.CAR, 0.8)), 0.6)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
        assertEquals(1, tracker.totalUniqueVehicles)
    }

    @Test fun tentativeTracksAreNotCoastedAndCoastingCanBeSwitchedOff() {
        val tracker = ObjectTracker()
        tracker.update(listOf(det(VehicleKind.CAR, 0.8)), 0.0)
        assertTrue(tracker.update(emptyList(), 0.1).isEmpty()) // 1 hit: not confirmed
        val strict = ObjectTracker(ObjectTracker.Config(coastFrames = 0))
        for (i in 0 until 4) strict.update(listOf(det(VehicleKind.CAR, 0.8)), i * 0.1)
        assertTrue(strict.update(emptyList(), 0.4).isEmpty())
    }

    @Test fun coastedLeadSurvivesTwoMissedFrames() {
        val tracker = ObjectTracker()
        val lead = LeadVehicleTracker()
        var result: LeadVehicle? = null
        // A car straight ahead, bottom edge at 0.75.
        val car = det(VehicleKind.CAR, 0.8, x = 0.4, y = 0.65, w = 0.2, h = 0.1)
        for (i in 0 until 8) {
            val t = i * 0.1
            result = lead.update(tracker.update(listOf(car), t), geometry, t)
        }
        val id = result?.trackID
        val distance = result?.distanceMeters ?: 0.0
        assertNotNull(id)
        for (miss in 1..2) {
            val t = 0.7 + miss * 0.1
            result = lead.update(tracker.update(emptyList(), t), geometry, t)
            assertEquals("miss $miss", id, result?.trackID)
            assertEquals("miss $miss", distance, result?.distanceMeters ?: 0.0, 1e-9) // unchanged
        }
        // Detected again: same lead, distance still continuous.
        result = lead.update(tracker.update(listOf(car), 1.0), geometry, 1.0)
        assertEquals(id, result?.trackID)
        assertEquals(distance, result?.distanceMeters ?: 0.0, 0.3)
        // Four missed frames: gone.
        for (miss in 1..4) {
            val t = 1.0 + miss * 0.1
            result = lead.update(tracker.update(emptyList(), t), geometry, t)
        }
        assertNull(result)
    }

    @Test fun coastedLeadAddsNoDistanceSample() {
        // Stationary gap, then coasted frames with a wildly different (predicted) box: the reported distance and the
        // closing speed must not move.
        val lead = LeadVehicleTracker()
        var result: LeadVehicle? = null
        fun car(t: Double, missed: Int = 0, scale: Double = 1.0): TrackedObject {
            val w = 0.2 * scale; val h = 0.1 * scale
            return track(3, VehicleKind.CAR, BBox(0.5 - w / 2, 0.75 - h, w, h), t, missed)
        }
        for (i in 0 until 10) result = lead.update(listOf(car(i * 0.1)), geometry, i * 0.1)
        val before = result
        assertNotNull(before?.relativeSpeedKmh)
        for (miss in 1..3) {
            val t = 0.9 + miss * 0.1
            result = lead.update(listOf(car(t, missed = miss, scale = 1.3)), geometry, t)
            assertEquals(before?.distanceMeters ?: 1.0, result?.distanceMeters ?: 0.0, 1e-9)
            assertEquals(before?.relativeSpeedKmh ?: 0.0, result?.relativeSpeedKmh ?: 99.0, 1e-9)
            assertEquals(before?.method, result?.method)
        }
        // More than `coastMissed` missed frames is not a lead candidate.
        assertNull(lead.update(listOf(car(1.3, missed = 4)), geometry, 1.3))
        // A coasted track that never was the lead has no measured distance: no lead.
        val fresh = LeadVehicleTracker()
        assertNull(fresh.update(listOf(car(0.0, missed = 1)), geometry, 0.0))
    }

    @Test fun coastedOtherTrackDoesNotHideDetectedLead() {
        // Track 2 is nearer and centred but only coasted (never the lead); track 1 is detected. The detected one wins.
        val lead = LeadVehicleTracker()
        val far = track(1, VehicleKind.CAR, BBox(0.45, 0.58, 0.1, 0.06), 0.0)
        val nearCoasted = track(2, VehicleKind.CAR, BBox(0.35, 0.6, 0.3, 0.2), 0.0, missed = 1)
        val result = lead.update(listOf(far, nearCoasted), geometry, 0.0)
        assertEquals(1, result?.trackID)
    }

    @Test fun leadKeepsDistanceAcrossIdSwitchWithHighIoU() {
        val lead = LeadVehicleTracker()
        fun car(id: Int, t: Double, x: Double = 0.4, kind: VehicleKind = VehicleKind.CAR) =
            track(id, kind, BBox(x, 0.65, 0.2, 0.1), t)
        var result: LeadVehicle? = null
        for (i in 0 until 10) result = lead.update(listOf(car(1, i * 0.1)), geometry, i * 0.1)
        assertNotNull(result?.relativeSpeedKmh)
        // Same place, new ID: the closing-speed history is kept (it would be null after a restart).
        result = lead.update(listOf(car(2, 1.0, x = 0.405)), geometry, 1.0)
        assertEquals(2, result?.trackID)
        assertNotNull(result?.relativeSpeedKmh)
        // A different vehicle elsewhere in the corridor (IoU < 0.5): restart.
        result = lead.update(listOf(car(3, 1.1, x = 0.30)), geometry, 1.1)
        assertEquals(3, result?.trackID)
        assertNull(result?.relativeSpeedKmh)
        // Same box but another class: restart (typical sizes differ).
        for (i in 0 until 10) result = lead.update(listOf(car(3, 1.2 + i * 0.1, x = 0.30)), geometry, 1.2 + i * 0.1)
        assertNotNull(result?.relativeSpeedKmh)
        result = lead.update(listOf(car(4, 2.2, x = 0.30, kind = VehicleKind.TRUCK)), geometry, 2.2)
        assertNull(result?.relativeSpeedKmh)
    }

    @Test fun pedestrianHazardIgnoresCoastedTrack() {
        val detector = PedestrianHazardDetector()
        fun person(t: Double, missed: Int, x: Double = 0.5) =
            track(1, VehicleKind.PERSON, BBox(x - 0.02, 0.58, 0.04, 0.12), t, missed, confidence = 0.8)
        val portrait = CameraGeometry.defaultPortrait
        // Never seen for real: a coasted box alone raises nothing.
        val cold = detector.evaluate(listOf(person(0.0, 1)), 40.0, portrait, 0.0)
        assertTrue(cold.hazards.isEmpty())
        // Seen in the own lane (danger), then coasted: no hazard from the predicted box, but the person stays
        // "relevant" (drawn / counted), not filtered as a sidewalk person.
        val seen = detector.evaluate(listOf(person(0.1, 0)), 40.0, portrait, 0.1)
        assertEquals(PedestrianHazardLevel.DANGER, seen.hazards.firstOrNull()?.level)
        val coasted = detector.evaluate(listOf(person(0.2, 1)), 40.0, portrait, 0.2)
        assertTrue(coasted.hazards.isEmpty())
        assertTrue(1 in coasted.relevantIDs)
        assertFalse(1 in coasted.filteredIDs)
        // A sidewalk person stays filtered while coasted (does not flash up).
        val other = PedestrianHazardDetector()
        val sidewalk = other.evaluate(listOf(person(0.0, 0, x = 0.03)), 40.0, portrait, 0.0)
        assertTrue(1 in sidewalk.filteredIDs)
        val sidewalkCoasted = other.evaluate(listOf(person(0.1, 1, x = 0.03)), 40.0, portrait, 0.1)
        assertTrue(1 in sidewalkCoasted.filteredIDs)
    }

    @Test fun speedEstimatorTakesNoSampleFromCoastedTrack() {
        val estimator = MonocularSpeedEstimator()
        fun car(t: Double, missed: Int, h: Double) = track(5, VehicleKind.CAR, BBox(0.4, 0.5, 0.2, h), t, missed)
        var out: List<TrackedObject> = emptyList()
        for (i in 0 until 8) out = estimator.update(listOf(car(i * 0.1, 0, 0.05)), 50.0, geometry, i * 0.1)
        val measured = out.firstOrNull()?.distanceMeters
        assertNotNull(measured)
        // Coasted with a much larger predicted box: the measured distance is kept, no speed is reported.
        out = estimator.update(listOf(car(0.8, 1, 0.09)), 50.0, geometry, 0.8)
        assertEquals(measured ?: 1.0, out.firstOrNull()?.distanceMeters ?: 0.0, 1e-9)
        assertNull(out.firstOrNull()?.relativeSpeedKmh)
        // And the next real frame's speed is not polluted by the predicted box (object did not move: ≈ 0).
        out = estimator.update(listOf(car(0.9, 0, 0.05)), 50.0, geometry, 0.9)
        assertEquals(0.0, out.firstOrNull()?.relativeSpeedKmh ?: 99.0, 1.0)
    }
}

class SecondAssociationTest {
    private fun det(kind: VehicleKind, confidence: Double, x: Double = 0.4, y: Double = 0.4, w: Double = 0.1, h: Double = 0.1) =
        Detection(kind = kind, label = kind.raw, confidence = confidence, box = BBox(x, y, w, h))

    @Test fun lowConfidenceDetectionKeepsConfirmedTrack() {
        // Car threshold 0.30; 0.25 is in the continuation band (≥ 0.30 × 0.7).
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 3) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.6)), i * 0.1)
        val id = tracks.first().id
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.25, x = 0.41)), 0.3)
        assertEquals(id, tracks.firstOrNull()?.id)
        assertEquals(0, tracks.first().missed)
        assertEquals(3, tracks.first().hits) // no hit from a low-score match
        assertEquals(0.6, tracks.first().peakConfidence, 1e-9)
        assertEquals(1, tracker.lowScoreMatches)
        assertTrue(tracks.first().box.x > 0.4) // the box follows the low detection
    }

    @Test fun lowConfidenceNeverStartsOrConfirmsTrack() {
        val tracker = ObjectTracker()
        assertTrue(tracker.update(listOf(det(VehicleKind.CAR, 0.25)), 0.0).isEmpty())
        // Two full-score frames (tentative), then only low scores: never confirmed, never counted.
        tracker.update(listOf(det(VehicleKind.CAR, 0.6)), 0.1)
        tracker.update(listOf(det(VehicleKind.CAR, 0.6)), 0.2)
        for (i in 0 until 5) {
            val tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.25)), 0.3 + i * 0.1)
            assertFalse(tracks.any { it.isConfirmed })
        }
        assertNull(tracker.uniqueCounts[VehicleKind.CAR])
        assertEquals(0, tracker.lowScoreMatches)
    }

    @Test fun lowDetectionDoesNotStealFromHighMatch() {
        // One confirmed track; a low-score box sits exactly on its prediction and a full-score box is slightly off.
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 3) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.6)), i * 0.1)
        val id = tracks.first().id
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.25), det(VehicleKind.CAR, 0.7, x = 0.42)), 0.3)
        assertEquals(1, tracks.size)
        assertEquals(id, tracks.first().id)
        assertEquals(4, tracks.first().hits)
        assertEquals(0.7, tracks.first().confidence, 1e-9)
        assertEquals(0, tracker.lowScoreMatches)
    }

    @Test fun lowScoreMatchNeedsIoUNotJustACloseCentre() {
        // The first stage may match by centre distance; the second (low-score) stage is IoU only (0.3).
        val tracker = ObjectTracker()
        for (i in 0 until 3) tracker.update(listOf(det(VehicleKind.CAR, 0.6)), i * 0.1)
        // Shifted by 0.07 of a 0.1-wide box: IoU ≈ 0.18.
        val tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.25, x = 0.47)), 0.3)
        assertEquals(1, tracks.firstOrNull()?.missed) // only coasted
        assertEquals(0, tracker.lowScoreMatches)
    }

    @Test fun lowScoreMatchAddsNoClassVote() {
        // Car track; low-score "truck" boxes on it must not flip the class however many arrive.
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 3) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.5)), i * 0.1)
        for (i in 0 until 12) tracks = tracker.update(listOf(det(VehicleKind.TRUCK, 0.25)), 0.3 + i * 0.1)
        assertEquals(VehicleKind.CAR, tracks.firstOrNull()?.kind)
        assertEquals(0, tracks.firstOrNull()?.missed)
    }

    @Test fun personTrackSurvivesConfidenceDip() {
        // Person threshold 0.40; a 0.30 frame used to be a miss. The count goes on after the dip.
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 4) tracks = tracker.update(listOf(det(VehicleKind.PERSON, 0.6)), i * 0.1)
        val id = tracks.first().id
        tracks = tracker.update(listOf(det(VehicleKind.PERSON, 0.30)), 0.4)
        assertEquals(id, tracks.firstOrNull()?.id)
        assertEquals(0, tracks.first().missed)
        assertEquals(4, tracks.first().hits)
        tracks = tracker.update(listOf(det(VehicleKind.PERSON, 0.6)), 0.5)
        assertEquals(id, tracks.firstOrNull()?.id)
        assertEquals(5, tracks.first().hits)
        assertEquals(1, tracks.size)
    }
}
