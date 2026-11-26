package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PedestrianHazardTest {
    private val g = CameraGeometry.defaultPortrait

    private fun person(id: Int, x: Double, bottom: Double, h: Double = 0.12, t: Double) =
        TrackedObject(id = id, kind = VehicleKind.PERSON, label = "person", box = BBox(x - 0.02, bottom - h, 0.04, h),
            confidence = 0.8, hits = 6, firstSeen = 0.0, lastSeen = t, isConfirmed = true)

    @Test fun pedestrianInOwnLaneIsDanger() {
        val r = PedestrianHazardDetector().update(listOf(person(1, 0.5, 0.7, t = 0.0)), 40.0, g, 0.0)
        assertEquals(PedestrianHazardLevel.DANGER, r.firstOrNull()?.level)
        assertEquals(true, r.firstOrNull()?.inOwnLane)
        assertNotNull(r.firstOrNull()?.distanceMeters)
    }

    @Test fun pedestrianOnSidewalkIgnored() {
        val r = PedestrianHazardDetector().update(listOf(person(1, 0.02, 0.62, t = 0.0)), 40.0, g, 0.0)
        assertTrue(r.isEmpty())
    }

    @Test fun pedestrianOnRoadEdgeCaution() {
        val r = PedestrianHazardDetector().update(listOf(person(1, 0.25, 0.7, t = 0.0)), 40.0, g, 0.0)
        assertEquals(PedestrianHazardLevel.CAUTION, r.firstOrNull()?.level)
        assertEquals(true, r.firstOrNull()?.onRoadway)
        assertEquals(false, r.firstOrNull()?.inOwnLane)
    }

    @Test fun approachingPedestrianEscalates() {
        val d = PedestrianHazardDetector()
        var r: List<PedestrianHazard> = emptyList()
        for (i in 0 until 8) {
            val t = i * 0.1
            r = d.update(listOf(person(1, 0.24 + 0.012 * i, 0.7, t = t)), 30.0, g, t)
        }
        assertEquals(true, r.firstOrNull()?.approaching)
        assertEquals(PedestrianHazardLevel.DANGER, r.firstOrNull()?.level)
    }

    @Test fun farPedestrianIgnored() {
        val d = PedestrianHazardDetector(maxDistance = 20.0)
        assertTrue(d.update(listOf(person(1, 0.5, 0.5, h = 0.03, t = 0.0)), 40.0, g, 0.0).isEmpty())
    }

    @Test fun handAtBottomEdgeIgnored() {
        val hand = TrackedObject(id = 9, kind = VehicleKind.PERSON, label = "person", box = BBox(0.35, 0.7, 0.3, 0.3),
            confidence = 0.7, hits = 10, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true)
        assertTrue(PedestrianHazardDetector().update(listOf(hand), 40.0, g, 0.0).isEmpty())
    }

    @Test fun lowConfidenceOrShortTrackIgnored() {
        val d = PedestrianHazardDetector()
        val p = person(1, 0.5, 0.7, t = 0.0)
        p.confidence = 0.45
        p.peakConfidence = 0.45
        assertTrue(d.update(listOf(p), 40.0, g, 0.0).isEmpty())
        // A one-frame dip of a track that was solid before does not silence the warning.
        val dip = person(3, 0.5, 0.7, t = 0.0)
        dip.confidence = 0.45
        assertEquals(0.8, dip.peakConfidence, 1e-9)
        assertEquals(PedestrianHazardLevel.DANGER, d.update(listOf(dip), 40.0, g, 0.0).firstOrNull()?.level)
        val q = person(2, 0.5, 0.7, t = 0.0)
        q.hits = 2
        assertTrue(d.update(listOf(q), 40.0, g, 0.0).isEmpty())
    }

    @Test fun wideBoxNotAPedestrian() {
        val wide = TrackedObject(id = 3, kind = VehicleKind.PERSON, label = "person", box = BBox(0.4, 0.55, 0.15, 0.12),
            confidence = 0.9, hits = 10, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true)
        assertTrue(PedestrianHazardDetector().update(listOf(wide), 40.0, g, 0.0).isEmpty())
    }
}
