package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FollowingDistanceTest {
    private val policy = FollowingDistancePolicy()
    private val g = CameraGeometry(65.0, 1080.0, 1920.0)

    @Test fun recommendedDistances() {
        assertEquals(33.33, FollowingDistanceCalculator.recommendedDistance(60.0, policy, RoadSurfaceCondition.DRY), 0.05)
        assertEquals(66.67, FollowingDistanceCalculator.recommendedDistance(60.0, policy, RoadSurfaceCondition.WET), 0.05)
        assertEquals(2.0, FollowingDistanceCalculator.recommendedDistance(2.0, policy, RoadSurfaceCondition.DRY), 0.0)
        assertEquals(2.0, FollowingDistanceCalculator.recommendedDistance(null, policy, RoadSurfaceCondition.DRY), 0.0)
    }

    @Test fun stoppingDistance() {
        assertEquals(36.9, FollowingDistanceCalculator.stoppingDistance(60.0, 1.0, 0.7), 0.2)
    }

    @Test fun assessStatuses() {
        val dry = RoadSurfaceCondition.DRY
        val safe = FollowingDistanceCalculator.assess(40.0, 60.0, 0.0, policy, dry)
        assertEquals(DistanceStatus.SAFE, safe.status)
        assertEquals(2.4, safe.timeHeadwaySeconds!!, 0.01)
        assertEquals(DistanceStatus.CAUTION, FollowingDistanceCalculator.assess(20.0, 60.0, 0.0, policy, dry).status)
        assertEquals(DistanceStatus.DANGER, FollowingDistanceCalculator.assess(10.0, 60.0, 0.0, policy, dry).status)
        val ttc = FollowingDistanceCalculator.assess(30.0, 60.0, -50.0, policy, dry)
        assertEquals(DistanceStatus.DANGER, ttc.status)
        assertEquals(2.16, ttc.timeToCollisionSeconds!!, 0.01)
        assertTrue(ttc.isCollisionWarning)
        val stopped = FollowingDistanceCalculator.assess(1.2, 0.0, null, policy, dry)
        assertTrue(stopped.isStopped)
        assertEquals(DistanceStatus.CAUTION, stopped.status)
        assertNull(stopped.stoppingDistanceMeters)
        assertEquals(DistanceStatus.UNKNOWN, FollowingDistanceCalculator.assess(null, 50.0, null, policy, dry).status)
    }

    @Test fun surfaceFromWeather() {
        assertEquals(RoadSurfaceCondition.DRY, RoadSurfaceCondition.from(0, 20.0, 0.0))
        assertEquals(RoadSurfaceCondition.WET, RoadSurfaceCondition.from(63, 10.0, 2.0))
        assertEquals(RoadSurfaceCondition.SNOW, RoadSurfaceCondition.from(73, 0.0, 1.0))
        assertEquals(RoadSurfaceCondition.ICE, RoadSurfaceCondition.from(66, -1.0, 1.0))
        assertEquals(RoadSurfaceCondition.ICE, RoadSurfaceCondition.from(61, -1.0, 0.5))
    }

    @Test fun corridor() {
        val c = EgoCorridor.default
        assertTrue(c.contains(BBox(0.4, 0.6, 0.2, 0.15)))
        assertFalse(c.contains(BBox(0.0, 0.6, 0.15, 0.15)))
        assertFalse(c.contains(BBox(0.45, 0.1, 0.1, 0.1)))
    }

    @Test fun leadTrackerDistanceAndClosing() {
        val lead = LeadVehicleTracker()
        var result: LeadVehicle? = null
        for (i in 0 until 12) {
            val t = i * 0.1
            val z = 25.0 - 5.0 * t
            val w = g.focalLengthPixels * 1.8 / z / g.imageWidth
            val h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            val box = BBox(0.5 - w / 2, 0.75 - h, w, h)
            val car = TrackedObject(id = 7, kind = VehicleKind.CAR, label = "car", box = box, confidence = 0.9, hits = 5,
                firstSeen = 0.0, lastSeen = t, isConfirmed = true)
            val side = TrackedObject(id = 8, kind = VehicleKind.CAR, label = "car", box = BBox(0.0, 0.7, 0.12, 0.1),
                confidence = 0.9, hits = 5, firstSeen = 0.0, lastSeen = t, isConfirmed = true)
            result = lead.update(listOf(side, car), g, t)
        }
        val r = result!!
        assertEquals(7, r.trackID)
        assertEquals("ширина+высота", r.method)
        assertEquals(19.5, r.distanceMeters, 1.5)
        assertTrue(r.relativeSpeedKmh!! < -10)
        val a = FollowingDistanceCalculator.assess(r.distanceMeters, 40.0, r.relativeSpeedKmh, policy, RoadSurfaceCondition.DRY)
        assertNotNull(a.timeToCollisionSeconds)
    }

    private fun car(id: Int, box: BBox, t: Double = 0.0) = TrackedObject(id = id, kind = VehicleKind.CAR, label = "car", box = box,
        confidence = 0.9, hits = 5, firstSeen = 0.0, lastSeen = t, isConfirmed = true)

    @Test fun carAheadWinsOverCloserAdjacentLaneCar() {
        val tracker = LeadVehicleTracker()
        val ahead = car(1, BBox(0.44, 0.58, 0.12, 0.08))
        val side = car(2, BBox(0.55, 0.62, 0.26, 0.16))
        assertTrue(EgoCorridor.default.contains(side.box))
        assertFalse(EgoCorridor.default.isStrictlyAhead(side.box))
        var result: LeadVehicle? = null
        for (i in 0 until 5) result = tracker.update(listOf(side, ahead), g, i * 0.1)
        assertEquals(1, result?.trackID)
    }

    @Test fun centredCarPreferredOverSlightlyCloserOffCentreCar() {
        val tracker = LeadVehicleTracker()
        val centred = car(1, BBox(0.45, 0.6, 0.1, 0.07))
        val offCentre = car(2, BBox(0.53, 0.64, 0.1, 0.07))
        assertEquals(1, tracker.update(listOf(offCentre, centred), g, 0.0)?.trackID)
    }

    @Test fun sideCarTouchingFrameEdgeNeverSelected() {
        val tracker = LeadVehicleTracker()
        val passing = car(3, BBox(0.5, 0.55, 0.5, 0.4))
        for (i in 0 until 5) assertNull(tracker.update(listOf(passing), g, i * 0.1))
        val ahead = car(4, BBox(0.45, 0.55, 0.1, 0.07))
        assertEquals(4, tracker.update(listOf(passing, ahead), g, 0.6)?.trackID)
    }

    @Test fun leadSwitchesWhenItDriftsOutOfStrictZone() {
        val tracker = LeadVehicleTracker()
        val far = car(1, BBox(0.45, 0.5, 0.1, 0.06))
        val near = car(2, BBox(0.44, 0.6, 0.12, 0.1))
        assertEquals(2, tracker.update(listOf(far, near), g, 0.0)?.trackID)
        near.box = BBox(0.6, 0.6, 0.12, 0.1)
        assertEquals(1, tracker.update(listOf(far, near), g, 0.1)?.trackID)
    }

    @Test fun laneCentreShiftMovesCorridor() {
        val box = BBox(0.6, 0.62, 0.12, 0.12)
        assertFalse(EgoCorridor(centerX = 0.5).isStrictlyAhead(box))
        assertTrue(EgoCorridor(centerX = 0.62).isStrictlyAhead(box))
        val tracker = LeadVehicleTracker()
        assertNull(tracker.update(listOf(car(5, box)), g, 0.0))
        tracker.corridor = EgoCorridor(centerX = 0.62)
        assertEquals(5, tracker.update(listOf(car(5, box)), g, 0.1)?.trackID)

        val lane = LaneEstimate(null, null, 0.8, 0.8, 0.62, -0.3, 0.8, 0.96, 0.0)
        var center = 0.5
        repeat(40) { center = EgoCorridor.smoothedCenterX(center, lane) }
        assertEquals(0.62, center, 0.01)
        val far = lane.copy(laneCenterX = 0.9)
        repeat(40) { center = EgoCorridor.smoothedCenterX(center, far) }
        assertEquals(0.65, center, 0.001)
        val weak = lane.copy(confidence = 0.3)
        repeat(60) { center = EgoCorridor.smoothedCenterX(center, weak) }
        assertEquals(0.5, center, 0.01)
    }

    @Test fun gapSubtractsCameraToBumper() {
        val tracker = LeadVehicleTracker()
        tracker.cameraToBumperMeters = 2.5
        var lead: LeadVehicle? = null
        for (i in 0 until 5) {
            val z = 5.0
            val w = g.focalLengthPixels * 1.8 / z / g.imageWidth
            val h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            val car = TrackedObject(id = 1, kind = VehicleKind.CAR, label = "car", box = BBox(0.5 - w / 2, 0.9 - h, w, h),
                confidence = 0.9, hits = 5, firstSeen = 0.0, lastSeen = i * 0.1, isConfirmed = true)
            lead = tracker.update(listOf(car), g, i * 0.1)
        }
        val l = lead!!
        assertEquals(5.0, l.cameraDistanceMeters, 0.3)
        assertEquals(2.5, l.distanceMeters, 0.3)
    }
}
