package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class GeoTest {
    @Test fun distanceTashkentDegree() {
        val d = Geo.distance(GeoPoint(41.0, 69.0), GeoPoint(42.0, 69.0))
        assertEquals(111_195.0, d, 50.0)
    }
    @Test fun bearingEast() {
        assertEquals(90.0, Geo.bearing(GeoPoint(0.0, 0.0), GeoPoint(0.0, 1.0)), 1e-6)
    }
    @Test fun projectOntoLine() {
        val line = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.01))
        val pr = Geo.project(GeoPoint(41.0005, 69.005), line)
        assertNotNull(pr)
        assertEquals(55.6, pr!!.distanceFromLine, 1.0)
        assertEquals(0.5, pr.fraction, 0.01)
    }
    @Test fun formatting() {
        assertEquals("350 м", RVFormat.distance(348.0))
        assertEquals("1,2 км", RVFormat.distance(1234.0))
        assertEquals("1 ч 05 мин", RVFormat.duration(3900.0))
        assertEquals("через 2 километра", RVFormat.spokenDistance(2000.0))
    }
}
