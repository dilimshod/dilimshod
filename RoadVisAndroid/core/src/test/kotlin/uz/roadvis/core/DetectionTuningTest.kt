package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DetectionTuningTest {
    private fun det(kind: VehicleKind, conf: Double, x: Double = 0.4, y: Double = 0.4, w: Double = 0.1, h: Double = 0.1) =
        Detection(kind = kind, label = kind.raw, confidence = conf, box = BBox(x, y, w, h))

    // Thresholds

    @Test fun classThresholdsAtDefaultSlider() {
        val t = DetectionThresholds.perClass()
        assertEquals(0.30, t[VehicleKind.CAR]!!, 1e-9)
        assertEquals(0.40, t[VehicleKind.PERSON]!!, 1e-9)
        assertEquals(0.30, t[VehicleKind.TRUCK]!!, 1e-9)
        assertEquals(0.30, t[VehicleKind.TRAFFIC_LIGHT]!!, 1e-9)
        assertEquals(0.55, t[VehicleKind.STOP_SIGN]!!, 1e-9)
        assertEquals(VehicleKind.entries.size, t.size)
        assertEquals(t, ObjectTracker.Config().minConfidence)
        // Android default (YOLO11n): the whole table 0.05 higher.
        val nano = DetectionThresholds.perClass(DetectionThresholds.DEFAULT_GLOBAL_NANO)
        assertEquals(0.35, nano[VehicleKind.CAR]!!, 1e-9)
        assertEquals(0.45, nano[VehicleKind.PERSON]!!, 1e-9)
    }

    @Test fun sliderMovesEveryClass() {
        val low = DetectionThresholds.perClass(0.15)
        assertEquals(0.15, low[VehicleKind.CAR]!!, 1e-9)
        assertEquals(0.25, low[VehicleKind.PERSON]!!, 1e-9)
        assertEquals(0.15, low[VehicleKind.TRAFFIC_LIGHT]!!, 1e-9)
        assertEquals(0.40, low[VehicleKind.STOP_SIGN]!!, 1e-9)
        val high = DetectionThresholds.perClass(0.8)
        assertEquals(0.8, high[VehicleKind.CAR]!!, 1e-9)
        assertEquals(0.8, high[VehicleKind.TRAFFIC_LIGHT]!!, 1e-9)
        assertEquals(DetectionThresholds.MAXIMUM, high[VehicleKind.STOP_SIGN]!!, 1e-9)
        assertEquals(DetectionThresholds.MINIMUM, DetectionThresholds.threshold(VehicleKind.CAR, 0.0), 1e-9)
        assertEquals(0.30, DetectionThresholds.threshold(VehicleKind.CAR, Double.NaN), 1e-9)
    }

    @Test fun detectorFloorIsBelowEveryUsableScore() {
        val floor = DetectionThresholds.detectorFloor()
        assertEquals(0.30 * DetectionThresholds.CONTINUATION_FACTOR, floor, 1e-9)
        for (threshold in DetectionThresholds.perClass().values) {
            assertTrue(floor <= threshold * DetectionThresholds.CONTINUATION_FACTOR + 1e-9)
        }
        assertEquals(0.5, DetectionThresholds.detectorFloor(0.5, 1.0), 1e-9)
        assertTrue(DetectionThresholds.detectorFloor(0.0) >= DetectionThresholds.DETECTOR_FLOOR_MINIMUM)
    }

    @Test fun riderLabelIsAPerson() {
        assertEquals(VehicleKind.PERSON, VehicleKind.fromLabel("rider"))
        assertNull(VehicleKind.fromLabel("traffic sign"))
    }

    // Tracker: one threshold table, hysteresis

    @Test fun trackerUsesTheSliderTable() {
        val tracker = ObjectTracker()
        assertEquals(1, tracker.update(listOf(det(VehicleKind.PERSON, 0.42)), 0.0).size)
        assertEquals(0, tracker.update(listOf(det(VehicleKind.PERSON, 0.38, x = 0.8)), 0.1).count { it.box.x > 0.7 })
        tracker.minConfidence = DetectionThresholds.perClass(0.15)
        assertEquals(1, tracker.update(listOf(det(VehicleKind.PERSON, 0.3, x = 0.8)), 0.2).count { it.box.x > 0.7 })
        tracker.minConfidence = DetectionThresholds.perClass(0.5)
        tracker.dropTracks()
        assertTrue(tracker.update(listOf(det(VehicleKind.PERSON, 0.42), det(VehicleKind.CAR, 0.45, x = 0.1)), 0.3).isEmpty())
    }

    @Test fun lowScoreDetectionContinuesConfirmedTrackOnly() {
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 3) tracks = tracker.update(listOf(det(VehicleKind.STOP_SIGN, 0.6)), i * 0.1)
        assertEquals(true, tracks.firstOrNull()?.isConfirmed)
        val id = tracks.first().id
        // 0.40 is below the stop-sign threshold (0.55) but above 0.55 × 0.7: the confirmed track goes on.
        tracks = tracker.update(listOf(det(VehicleKind.STOP_SIGN, 0.40)), 0.3)
        assertEquals(id, tracks.firstOrNull()?.id)
        assertEquals(0, tracks.first().missed)
        // A low-score continuation is not a hit (it must not help confirm or re-vote a track).
        assertEquals(3, tracks.first().hits)
        assertEquals(0.40, tracks.first().confidence, 1e-9)
        assertEquals(0.60, tracks.first().peakConfidence, 1e-9)
        // Below the continuation floor: a miss (the confirmed track is only coasted, missed == 1).
        tracks = tracker.update(listOf(det(VehicleKind.STOP_SIGN, 0.30)), 0.4)
        assertTrue(tracks.none { it.missed == 0 })
        assertEquals(1, tracks.firstOrNull()?.missed)
        // A low score never opens a track and never feeds a tentative one.
        val fresh = ObjectTracker()
        assertTrue(fresh.update(listOf(det(VehicleKind.STOP_SIGN, 0.40)), 0.0).isEmpty())
        fresh.update(listOf(det(VehicleKind.STOP_SIGN, 0.6)), 0.1)
        assertTrue(fresh.update(listOf(det(VehicleKind.STOP_SIGN, 0.40)), 0.2).isEmpty())
        // Hysteresis off: the old strict behaviour.
        val strict = ObjectTracker(ObjectTracker.Config(continuationFactor = 1.0))
        for (i in 0 until 3) strict.update(listOf(det(VehicleKind.STOP_SIGN, 0.6)), i * 0.1)
        assertTrue(strict.update(listOf(det(VehicleKind.STOP_SIGN, 0.45)), 0.3).none { it.missed == 0 })
    }

    @Test fun dropTracksKeepsCountersAndIDs() {
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 4) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8)), i * 0.1)
        assertEquals(true, tracks.first().isConfirmed)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
        val oldID = tracks.first().id
        tracker.dropTracks()
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8)), 0.5)
        assertEquals(1, tracks.size)
        assertTrue(tracks.first().id > oldID)
        assertFalse(tracks.first().isConfirmed)
        assertEquals(1, tracks.first().hits)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
    }

    @Test fun staleTracksAreNotContinuedAfterAGap() {
        val tracker = ObjectTracker()
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 4) tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8)), i * 0.1)
        val oldID = tracks.first().id
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8)), 2.3)
        assertEquals(oldID, tracks.first().id)
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.8)), 200.0)
        assertNotEquals(oldID, tracks.first().id)
        assertFalse(tracks.first().isConfirmed)
    }

    // Cross-class duplicates

    @Test fun carTruckDuplicateIsMerged() {
        val car = det(VehicleKind.CAR, 0.62, 0.30, 0.40, 0.20, 0.20)
        val truck = det(VehicleKind.TRUCK, 0.48, 0.31, 0.40, 0.20, 0.20)
        val bus = det(VehicleKind.BUS, 0.9, 0.70, 0.40, 0.20, 0.20)
        assertEquals(listOf(VehicleKind.CAR, VehicleKind.BUS), CrossClassDuplicates.suppress(listOf(truck, car, bus)).map { it.kind })
    }

    @Test fun duplicateSuppressionLeavesOtherPairsAlone() {
        val rider = det(VehicleKind.PERSON, 0.5, 0.30, 0.30, 0.10, 0.30)
        val moto = det(VehicleKind.MOTORCYCLE, 0.7, 0.30, 0.30, 0.10, 0.30)
        val car = det(VehicleKind.CAR, 0.8, 0.60, 0.40, 0.20, 0.20)
        val truck = det(VehicleKind.TRUCK, 0.6, 0.66, 0.40, 0.20, 0.20)       // IoU ≈ 0.54
        val car2 = det(VehicleKind.CAR, 0.4, 0.60, 0.40, 0.20, 0.20)
        val light = det(VehicleKind.TRAFFIC_LIGHT, 0.6, 0.60, 0.40, 0.20, 0.20)
        val input = listOf(rider, moto, car, truck, car2, light)
        assertEquals(input, CrossClassDuplicates.suppress(input))
        val bike = det(VehicleKind.BICYCLE, 0.45, 0.30, 0.30, 0.10, 0.30)
        assertEquals(listOf(VehicleKind.MOTORCYCLE), CrossClassDuplicates.suppress(listOf(bike, moto)).map { it.kind })
        val carOnMoto = det(VehicleKind.CAR, 0.9, 0.30, 0.30, 0.10, 0.30)
        assertEquals(2, CrossClassDuplicates.suppress(listOf(carOnMoto, moto)).size)
        assertTrue(CrossClassDuplicates.suppress(emptyList()).isEmpty())
    }

    // Input geometry

    @Test fun aspectMatchedInputIsFilled() {
        val g = DetectorInputGeometry(960.0, 544.0, 1920.0, 1080.0)
        assertEquals(0.0074, g.aspectMismatch, 0.0005)
        assertEquals(DetectorInputFit.FILL, g.fit)
        assertEquals(1.0, g.usedInputFraction, 1e-12)
        val same = g.frameBox(BBox(0.2, 0.3, 0.1, 0.4))
        assertEquals(0.2, same.x, 1e-12); assertEquals(0.4, same.height, 1e-12)
        assertTrue(DetectorInputGeometry.isLandscape(1280.0, 720.0))
        assertFalse(DetectorInputGeometry.isLandscape(720.0, 1280.0))
    }

    @Test fun mismatchedInputIsLetterboxedAndUndone() {
        val square = DetectorInputGeometry(640.0, 640.0, 1080.0, 1920.0)
        assertEquals(DetectorInputFit.LETTERBOX, square.fit)
        assertEquals(0.5625, square.usedInputFraction, 1e-9)
        val whole = square.frameBox(BBox(140.0 / 640, 0.0, 360.0 / 640, 1.0))
        assertEquals(0.0, whole.x, 1e-9); assertEquals(1.0, whole.width, 1e-9)
        val mid = square.frameBox(BBox(0.45, 0.5, 0.1, 0.1))
        assertEquals(0.5, mid.midX, 1e-9); assertEquals(0.1 / 0.5625, mid.width, 1e-9)
        // Android lite input: 1280×720 into 640×384 → 12 px bars top and bottom.
        val lite = DetectorInputGeometry(640.0, 384.0, 1280.0, 720.0)
        assertEquals(DetectorInputFit.LETTERBOX, lite.fit)
        assertEquals(360.0 / 384, lite.usedInputFraction, 1e-9)
        val top = lite.frameBox(BBox(0.0, 12.0 / 384, 1.0, 180.0 / 384))
        assertEquals(0.0, top.y, 1e-9); assertEquals(0.5, top.height, 1e-9)
    }

    @Test fun decoderHandlesRectangularInput() {
        // Raw [1, 6, 7] tensor (rows cx, cy, w, h, 2 classes; 7 anchors, 5 of them empty) in 960×544 input pixels.
        fun row(a: Float, b: Float) = floatArrayOf(a, b, 0f, 0f, 0f, 0f, 0f)
        val values = row(480f, 100f) + row(272f, 300f) + row(96f, 50f) + row(54.4f, 100f) + row(0.9f, 0.1f) + row(0.05f, 0.8f)
        // Filled (aspect-matched) frame: plain division by the input size.
        val filled = YOLODecoder.decode(values, listOf(1, 6, 7), 960.0, 544.0, confidenceThreshold = 0.25, iouThreshold = 0.45)
        assertEquals(2, filled.size)
        assertEquals(0.5, filled[0].box.midX, 1e-6)
        assertEquals(0.5, filled[0].box.midY, 1e-6)
        assertEquals(0.1, filled[0].box.width, 1e-6)
        assertEquals(0.1, filled[0].box.height, 1e-6)
        // Letterboxed 1280×720 frame in 960×544: gain 0.75, 2 px bars → y = (300 − 2) / 0.75 / 720.
        val boxed = YOLODecoder.decode(values, listOf(1, 6, 7), 960.0, 544.0, confidenceThreshold = 0.25,
            iouThreshold = 0.45, sourceWidth = 1280.0, sourceHeight = 720.0)
        val second = boxed.firstOrNull { it.classIndex == 1 }
        assertEquals((300.0 - 2) / 0.75 / 720, second?.box?.midY ?: 0.0, 1e-6)
        assertEquals(100.0 / 960, second?.box?.midX ?: 0.0, 1e-6)
        // The decoder and DetectorInputGeometry agree.
        val g = DetectorInputGeometry(640.0, 384.0, 1280.0, 720.0)
        val single = row(320f, 0f) + row(192f, 0f) + row(64f, 0f) + row(96f, 0f) + row(0.9f, 0f)
        val viaDecoder = YOLODecoder.decode(single, listOf(1, 5, 7), 640.0, 384.0, confidenceThreshold = 0.25,
            iouThreshold = 0.45, sourceWidth = 1280.0, sourceHeight = 720.0)
        val viaGeometry = g.frameBox(BBox((320.0 - 32) / 640, (192.0 - 48) / 384, 64.0 / 640, 96.0 / 384))
        assertEquals(viaGeometry.x, viaDecoder.firstOrNull()?.box?.x ?: 0.0, 1e-6)
        assertEquals(viaGeometry.y, viaDecoder.firstOrNull()?.box?.y ?: 0.0, 1e-6)
        assertEquals(viaGeometry.height, viaDecoder.firstOrNull()?.box?.height ?: 0.0, 1e-6)
    }

    // Quality governor

    @Test fun governorDropsToLiteWhenSlowAndComesBack() {
        val g = DetectorQualityGovernor(DetectorQualityGovernor.Config.iOS)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
        var t = feed(g, 30.0, 100, 0.0)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)   // fast enough: stays
        t = feed(g, 80.0, 10, t)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)   // a short hiccup inside one window: no change
        t = feed(g, 80.0, 60, t)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        // Lite is quick (10 ms < 15 ms) but the retry time (30 s) has not passed.
        t = feed(g, 10.0, 100, t)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        feed(g, 10.0, 250, t)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
        // Lite itself too slow for a retry: never upgrades.
        val slow = DetectorQualityGovernor(DetectorQualityGovernor.Config.iOS)
        val ts = feed(slow, 80.0, 40, 0.0)
        feed(slow, 25.0, 2000, ts)
        assertEquals(DetectorQualityGovernor.Level.LITE, slow.level)
    }

    private fun feed(g: DetectorQualityGovernor, ms: Double, frames: Int, from: Double, constrained: Boolean = false): Double {
        var time = from
        repeat(frames) {
            g.record(ms, constrained, time)
            time += 0.1
        }
        return time
    }

    @Test fun androidGovernorStartsSmallAndUpgradesOnFastPhones() {
        val g = DetectorQualityGovernor(DetectorQualityGovernor.Config.android)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        var t = feed(g, 40.0, 300, 0.0)            // 40 ms at 384×640 → 544×960 would be ≈ 88 ms: stay
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        t = feed(g, 20.0, 36, t)                   // quick phone: the first upgrade needs no waiting time
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
        t = feed(g, 60.0, 100, t)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
        t = feed(g, 90.0, 70, t)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        val c = DetectorQualityGovernor.Config.android
        assertTrue(c.upgradeBelowMs * 2.23 < c.downgradeAboveMs)
        assertTrue(DetectorQualityGovernor.Config.iOS.upgradeBelowMs * 3.4 < DetectorQualityGovernor.Config.iOS.downgradeAboveMs)
        feed(g, 20.0, 10, t)
        g.reset()
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
    }

    @Test fun governorBacksOffAfterFailedUpgrade() {
        val g = DetectorQualityGovernor(DetectorQualityGovernor.Config.iOS)
        var t = feed(g, 80.0, 40, 0.0)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        t = feed(g, 10.0, 320, t)                  // 32 s later: upgrade
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
        t = feed(g, 80.0, 70, t)                   // fails within 20 s → retry time doubles to 60 s
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        t = feed(g, 10.0, 400, t)                  // 40 s: still waiting
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        feed(g, 10.0, 300, t)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
    }

    @Test fun governorThermalConstraint() {
        val g = DetectorQualityGovernor(DetectorQualityGovernor.Config.iOS)
        var t = feed(g, 20.0, 3, 0.0, constrained = true)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        t = feed(g, 5.0, 1000, t, constrained = true)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        t = feed(g, 5.0, 200, t)
        assertEquals(DetectorQualityGovernor.Level.LITE, g.level)
        feed(g, 5.0, 200, t)
        assertEquals(DetectorQualityGovernor.Level.FULL, g.level)
    }
}
