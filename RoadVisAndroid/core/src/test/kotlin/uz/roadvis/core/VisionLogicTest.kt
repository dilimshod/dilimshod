package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VisionLogicTest {
    private fun det(kind: VehicleKind, x: Double, y: Double, w: Double = 0.1, h: Double = 0.1, conf: Double = 0.8) =
        Detection(kind, kind.raw, conf, BBox(x, y, w, h))

    @Test fun labelMapping() {
        assertEquals(VehicleKind.CAR, VehicleKind.fromLabel("car"))
        assertEquals(VehicleKind.TRAFFIC_LIGHT, VehicleKind.fromLabel("traffic light"))
        assertEquals(VehicleKind.MOTORCYCLE, VehicleKind.fromLabel("Motorbike"))
        assertEquals(VehicleKind.TRUCK, VehicleKind.fromCocoIndex(7))
        assertNull(VehicleKind.fromLabel("banana"))
    }

    @Test fun bboxIoUAndVision() {
        val a = BBox(0.0, 0.0, 0.5, 0.5)
        val b = BBox(0.25, 0.25, 0.5, 0.5)
        assertEquals(0.0625 / (0.25 + 0.25 - 0.0625), a.iou(b), 1e-9)
        val v = BBox.fromVision(0.1, 0.2, 0.3, 0.4)
        assertEquals(0.4, v.y, 1e-9)
        assertEquals(0.2, v.visionY, 1e-9)
    }

    @Test fun trackerCountsUniqueOnlyOnce() {
        val tracker = ObjectTracker(ObjectTracker.Config(iouThreshold = 0.3, maxMissed = 3, minHits = 3))
        for (i in 0 until 10) tracker.update(listOf(det(VehicleKind.CAR, 0.1 + i * 0.01, 0.5)), i * 0.1)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
        assertEquals(10, tracker.frameDetectionCount)
        assertEquals(1, tracker.totalUniqueVehicles)
    }

    @Test fun trackerIgnoresFlicker() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 3))
        tracker.update(listOf(det(VehicleKind.BUS, 0.5, 0.5)), 0.0)
        tracker.update(emptyList(), 0.1)
        assertNull(tracker.uniqueCounts[VehicleKind.BUS])
    }

    @Test fun trackerTwoObjectsAndMakeVote() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 2))
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 5) {
            tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.1, 0.5), det(VehicleKind.TRUCK, 0.7, 0.5)), i * 0.1)
        }
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
        assertEquals(1, tracker.uniqueCounts[VehicleKind.TRUCK])
        val car = tracks.first { it.kind == VehicleKind.CAR }
        tracker.addMakeObservation(car.id, "Chevrolet", 0.7)
        tracker.addMakeObservation(car.id, "Chevrolet", 0.6)
        tracker.addMakeObservation(car.id, "Daewoo", 0.9)
        tracks = tracker.update(listOf(det(VehicleKind.CAR, 0.1, 0.5), det(VehicleKind.TRUCK, 0.7, 0.5)), 0.6)
        assertEquals("Chevrolet", tracks.first { it.id == car.id }.make)
    }

    @Test fun trackerCarTruckConfusionKeepsOneTrack() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 2))
        for (i in 0 until 6) {
            val kind = if (i % 3 == 0) VehicleKind.TRUCK else VehicleKind.CAR
            tracker.update(listOf(det(kind, 0.4, 0.4, 0.2, 0.2)), i * 0.1)
        }
        val total = (tracker.uniqueCounts[VehicleKind.CAR] ?: 0) + (tracker.uniqueCounts[VehicleKind.TRUCK] ?: 0)
        assertEquals(1, total)
    }

    @Test fun monocularDistance() {
        val g = CameraGeometry(65.0, 1080.0, 1920.0)
        val z = MonocularDistance.distance(1.5, 0.05, g)!!
        assertEquals(23.5, z, 0.5)
        assertNull(MonocularDistance.distance(1.5, 0.001, g))
    }

    @Test fun monocularSpeedApproaching() {
        val g = CameraGeometry.defaultPortrait
        val est = MonocularSpeedEstimator(windowSeconds = 2.0)
        var out: List<TrackedObject> = emptyList()
        for (i in 0 until 15) {
            val t = i * 0.1
            val z = 30 - 5 * t
            val h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            val obj = TrackedObject(id = 1, kind = VehicleKind.CAR, label = "car", box = BBox(0.45, 0.5, 0.1, h),
                confidence = 0.9, firstSeen = 0.0, lastSeen = t)
            out = est.update(listOf(obj), 60.0, g, t)
        }
        assertEquals(-18.0, out[0].relativeSpeedKmh!!, 1.0)
        assertEquals(42.0, out[0].estimatedSpeedKmh!!, 1.0)
        assertEquals(23.1, out[0].distanceMeters!!, 0.6)
    }

    @Test fun fastMovingObjectKeepsOneTrack() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 3))
        val ids = HashSet<Int>()
        for (i in 0 until 8) {
            val w = 0.06 + i * 0.01
            val box = BBox(0.2 + i * 0.08, 0.5, w, w * 0.8)
            val t = tracker.update(listOf(Detection(VehicleKind.CAR, "car", 0.8, box)), i / 15.0)
            ids.addAll(t.map { it.id })
        }
        assertEquals(1, ids.size)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.CAR])
    }

    @Test fun reacquireAfterShortMiss() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 2))
        val ids = HashSet<Int>()
        for (i in 0 until 10) {
            if (i == 4 || i == 5) continue
            val box = BBox(0.3 + i * 0.03, 0.5, 0.1, 0.08)
            val t = tracker.update(listOf(Detection(VehicleKind.CAR, "car", 0.8, box)), i / 15.0)
            ids.addAll(t.map { it.id })
        }
        assertEquals(1, ids.size)
    }

    @Test fun twoNeighboursNotMerged() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 2))
        for (i in 0 until 6) {
            val a = BBox(0.30, 0.5, 0.08, 0.08)
            val b = BBox(0.45, 0.5, 0.08, 0.08)
            tracker.update(listOf(Detection(VehicleKind.CAR, "car", 0.8, a), Detection(VehicleKind.CAR, "car", 0.8, b)), i / 15.0)
        }
        assertEquals(2, tracker.uniqueCounts[VehicleKind.CAR])
    }

    @Test fun perClassConfidenceFilter() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 1))
        tracker.update(listOf(Detection(VehicleKind.TRAFFIC_LIGHT, "traffic light", 0.42, BBox(0.5, 0.1, 0.02, 0.05))), 0.0)
        assertNull(tracker.uniqueCounts[VehicleKind.TRAFFIC_LIGHT])
        tracker.update(listOf(Detection(VehicleKind.TRAFFIC_LIGHT, "traffic light", 0.6, BBox(0.5, 0.1, 0.02, 0.05))), 0.1)
        assertEquals(1, tracker.uniqueCounts[VehicleKind.TRAFFIC_LIGHT])
    }

    @Test fun experimentLeadAndConfirmedColumns() {
        val log = ExperimentLog("m", 0L)
        log.append(ExperimentRecord(timestampMillis = 0L, frameIndex = 1, trackID = 1, kind = VehicleKind.CAR,
            label = "car", confidence = 0.9, box = BBox(0.0, 0.0, 0.1, 0.1),
            distanceMeters = 18.0, isConfirmed = true, trackHits = 5, isLead = true))
        log.append(ExperimentRecord(timestampMillis = 0L, frameIndex = 1, trackID = 2, kind = VehicleKind.CAR,
            label = "car", confidence = 0.5, box = BBox(0.5, 0.0, 0.1, 0.1), isConfirmed = false, trackHits = 1))
        val rows = log.detectionsCSV().split("\n").filter { it.isNotEmpty() }
        assertTrue(rows[1].endsWith(",1,5,1"))
        assertTrue(rows[2].endsWith(",0,1,0"))
        val s = log.summaryCSV(mapOf(VehicleKind.CAR to 1), 10_000L)
        assertTrue(s.contains("car,2,1,2,1,0.700"))
        assertTrue(s.contains("# lead_vehicle_rows,1"))
        assertTrue(s.contains("# lead_distance_median_m_est,18.0"))
    }
}
