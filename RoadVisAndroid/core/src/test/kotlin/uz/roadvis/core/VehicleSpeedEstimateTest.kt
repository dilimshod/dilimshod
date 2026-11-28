package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors the Swift VisionLogicTests speed cases (per-vehicle ground speed, oncoming, standstill, range). */
class VehicleSpeedEstimateTest {
    private fun run(own: Double, x: Double = 0.45, steps: Int = 15,
                    g: CameraGeometry = CameraGeometry.defaultPortrait, z: (Double) -> Double): TrackedObject {
        val est = MonocularSpeedEstimator(windowSeconds = 2.0)
        var out = emptyList<TrackedObject>()
        for (i in 0 until steps) {
            val t = i * 0.1
            val h = g.focalLengthPixels * 1.5 / z(t) / g.imageHeight
            val obj = TrackedObject(id = 1, kind = VehicleKind.CAR, label = "car", box = BBox(x, 0.5, 0.1, h),
                confidence = 0.9, firstSeen = 0.0, lastSeen = t)
            out = est.update(listOf(obj), own, g, t)
        }
        return out[0]
    }

    @Test fun oncomingCarSpeedAndDirection() {
        val t = run(50.0) { 60 - 25 * it }
        assertEquals(40.0, t.estimatedSpeedKmh ?: -1.0, 2.0)
        assertTrue(t.isOncoming)
    }

    @Test fun sideVehicleGetsSpeedToo() {
        val t = run(40.0, x = 0.05) { 20 + 3 * it }
        assertEquals(50.8, t.estimatedSpeedKmh ?: -1.0, 2.0)
        assertFalse(t.isOncoming)
    }

    @Test fun parkedCarShowsZeroWhenWeStand() {
        val t = run(0.0) { 15.0 }
        assertEquals(0.0, t.estimatedSpeedKmh ?: -1.0, 0.01)
        assertFalse(t.isOncoming)
    }

    @Test fun farVehicleHasDistanceButNoSpeed() {
        val landscape = CameraGeometry(horizontalFOVDegrees = 65.0, imageWidth = 1920.0, imageHeight = 1080.0)
        val t = run(60.0, g = landscape) { 92 - 2 * it }
        assertNotNull(t.distanceMeters)
        assertNull(t.estimatedSpeedKmh)
    }

    @Test fun speedNeedsEnoughSamples() {
        val t = run(60.0, steps = 6) { 30 - 5 * it }
        assertNull(t.estimatedSpeedKmh)
    }
}
