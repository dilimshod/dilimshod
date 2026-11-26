package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression tests for the audited navigation defects (mirror of the Swift `NavigationAuditTests`). */
class NavigationAuditTest {
    private val start = GeoPoint(41.3, 69.2)

    private fun straightRoute(length: Double = 1000.0): List<GeoPoint> {
        val pts = ArrayList<GeoPoint>()
        var d = 0.0
        while (d <= length) {
            pts.add(Geo.destination(start, 90.0, d))
            d += 50
        }
        return pts
    }

    private fun tracker(pts: List<GeoPoint>) = RouteProgressTracker(pts, emptyList(), expectedTravelTime = 120.0)

    private fun point(along: Double, offset: Double): GeoPoint =
        Geo.destination(Geo.destination(start, 90.0, along), 0.0, offset)

    @Test fun standingBesideRouteBeforeJoiningIsNotOffRoute() {
        val t = tracker(straightRoute())
        repeat(10) {
            val p = t.update(point(0.0, 70.0))
            assertFalse(p.isOffRoute)
            assertEquals(70.0, p.crossTrackDistance, 2.0)
        }
        assertFalse(t.update(point(0.0, 60.0)).isOffRoute)
        assertFalse(t.update(point(0.0, 55.0)).isOffRoute)
    }

    @Test fun movingAwayBeforeJoiningIsOffRoute() {
        val t = tracker(straightRoute())
        assertFalse(t.update(point(0.0, 70.0)).isOffRoute)
        assertFalse(t.update(point(0.0, 130.0)).isOffRoute)
        assertFalse(t.update(point(0.0, 130.0)).isOffRoute)
        assertTrue(t.update(point(0.0, 130.0)).isOffRoute)
    }

    @Test fun leavingRouteAfterJoiningIsOffRouteAsBefore() {
        val t = tracker(straightRoute())
        assertFalse(t.update(point(100.0, 3.0)).isOffRoute)
        assertFalse(t.update(point(120.0, 70.0)).isOffRoute)
        assertFalse(t.update(point(140.0, 70.0)).isOffRoute)
        val p = t.update(point(160.0, 70.0))
        assertTrue(p.isOffRoute)
        assertEquals(100.0, p.distanceAlong, 2.0)
    }

    @Test fun poorFixesDoNotCountTowardsOffRoute() {
        val poor = tracker(straightRoute())
        assertFalse(poor.update(point(100.0, 0.0)).isOffRoute)
        repeat(3) {
            val p = poor.update(point(100.0, 150.0), 150.0, countsTowardsOffRoute = false)
            assertFalse(p.isOffRoute)
            assertEquals(100.0, p.distanceAlong, 2.0)
        }
        assertEquals(200.0, poor.update(point(200.0, 5.0), 120.0, countsTowardsOffRoute = false).distanceAlong, 2.0)

        val good = tracker(straightRoute())
        assertFalse(good.update(point(100.0, 0.0)).isOffRoute)
        good.update(point(100.0, 150.0), 150.0)
        good.update(point(100.0, 150.0), 150.0)
        assertTrue(good.update(point(100.0, 150.0), 150.0).isOffRoute)
        // A poor fix keeps the confirmed state.
        assertTrue(good.update(point(100.0, 150.0), 150.0, countsTowardsOffRoute = false).isOffRoute)
    }

    @Test fun outAndBackDoesNotJumpToReturnLeg() {
        val pts = ArrayList<GeoPoint>()
        for (i in 0..12) pts.add(Geo.destination(start, 0.0, i * 25.0))
        val westStart = Geo.destination(start, 270.0, 15.0)
        for (i in 12 downTo 0) pts.add(Geo.destination(westStart, 0.0, i * 25.0))
        val steps = listOf(RouteStepInfo("", 0.0), RouteStepInfo("Двигайтесь на север", 300.0),
            RouteStepInfo("Развернитесь", 15.0), RouteStepInfo("Пункт назначения будет справа", 300.0))
        val t = RouteProgressTracker(pts, steps, expectedTravelTime = 120.0)
        var previous = -1.0
        var d = 0.0
        while (d <= 280.0) {
            val fix = Geo.destination(Geo.destination(start, 0.0, d), 270.0, 10.0)
            val p = t.update(fix)
            assertFalse(p.isOffRoute)
            assertEquals("outbound fix at $d m", d, p.distanceAlong, 3.0)
            assertTrue(p.distanceAlong >= previous)
            previous = p.distanceAlong
            assertEquals(2, p.nextStepIndex)
            assertEquals(ManeuverType.U_TURN, p.nextManeuver)
            d += 20
        }
        val withCourse = t.update(Geo.destination(westStart, 0.0, 270.0), course = 2.0)
        assertEquals(270.0, withCourse.distanceAlong, 3.0)
        assertEquals(2, withCourse.nextStepIndex)
        val p = t.update(Geo.destination(westStart, 0.0, 250.0), course = 181.0)
        assertEquals(365.0, p.distanceAlong, 3.0)
        assertEquals(ManeuverType.ARRIVE, p.nextManeuver)
    }

    @Test fun startMidRouteStillMatchesWholeRoute() {
        val p = tracker(straightRoute(3000.0)).update(point(2500.0, 4.0))
        assertEquals(2500.0, p.distanceAlong, 3.0)
        assertFalse(p.isOffRoute)
    }

    @Test fun osrmUrlWithHeading() {
        val from = GeoPoint(41.3, 69.24); val to = GeoPoint(41.35, 69.3)
        val plain = OSRM.routeURL(OSRM.defaultEndpoint, from, to)!!
        assertFalse(plain.contains("bearings"))
        assertTrue(OSRM.routeURL(OSRM.defaultEndpoint, from, to, heading = 359.7)!!.endsWith("&annotations=true&bearings=0,45;"))
        assertTrue(OSRM.routeURL(OSRM.defaultEndpoint, from, to, heading = -90.0)!!.endsWith("&bearings=270,45;"))
        assertEquals(plain, OSRM.routeURL(OSRM.defaultEndpoint, from, to, heading = Double.NaN))
    }

    @Test fun reroutePolicy() {
        val north = listOf(start, Geo.destination(start, 0.0, 5.0), Geo.destination(start, 0.0, 200.0))
        val south = listOf(start, Geo.destination(start, 180.0, 200.0))
        assertEquals(0.0, Geo.angleDifference(ReroutePolicy.initialBearing(north)!!, 0.0), 1.0)
        assertNull(ReroutePolicy.initialBearing(listOf(start, Geo.destination(start, 0.0, 5.0))))
        assertEquals(1, ReroutePolicy.preferredIndex(listOf(south, north), 10.0))
        assertEquals(1, ReroutePolicy.preferredIndex(listOf(south, north), 350.0))
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south, north), 170.0))
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south, north), null))
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south), 0.0))
        assertEquals(0, ReroutePolicy.preferredIndex(emptyList(), 0.0))

        assertEquals(15.0, ReroutePolicy.retryInterval(failures = 0), 0.0)
        assertEquals(30.0, ReroutePolicy.retryInterval(failures = 1), 0.0)
        assertEquals(60.0, ReroutePolicy.retryInterval(failures = 2), 0.0)
        assertEquals(120.0, ReroutePolicy.retryInterval(failures = 3), 0.0)
        assertEquals(120.0, ReroutePolicy.retryInterval(failures = 50), 0.0)
        assertEquals(15.0, ReroutePolicy.retryInterval(failures = -1), 0.0)

        assertTrue(ReroutePolicy.isIncidentAtOrBehind(520.0, 500.0))
        assertTrue(ReroutePolicy.isIncidentAtOrBehind(100.0, 500.0))
        assertFalse(ReroutePolicy.isIncidentAtOrBehind(540.0, 500.0))
    }

    @Test fun candidatesThenFeaturesMatchExtractAcrossChunks() {
        val route = straightRoute(2000.0)
        fun node(id: Long, along: Double, offset: Double = 5.0, tags: Map<String, String>): OSMElement {
            val p = point(along, offset)
            return OSMElement(OSMElement.ElementType.NODE, id, lat = p.latitude, lon = p.longitude, tags = tags)
        }
        val signal = mapOf("highway" to "traffic_signals")
        val chunks = listOf(
            listOf(node(1, 100.0, tags = signal), node(2, 130.0, tags = signal), node(3, 400.0, tags = mapOf("highway" to "speed_camera"))),
            listOf(node(4, 150.0, tags = signal), node(5, 900.0, tags = mapOf("highway" to "crossing")), node(6, 1200.0, 400.0, signal)),
            listOf(node(7, 1500.0, tags = mapOf("amenity" to "school", "name" to "1")),
                node(8, 1600.0, 100.0, mapOf("amenity" to "school", "name" to "1"))),
        )
        val cumulative = Geo.cumulativeDistances(route)
        val collected = ArrayList<OSMElement>()
        val candidates = ArrayList<RouteFeatureCandidate>()
        for (chunk in chunks) {
            collected += chunk
            candidates += RouteFeatureExtractor.candidates(chunk, route, cumulative)
            assertEquals(RouteFeatureExtractor.extract(collected, route, cumulative), RouteFeatureExtractor.features(candidates))
        }
        assertEquals(7, candidates.size)
        assertTrue(RouteFeatureExtractor.features(candidates).isNotEmpty())
        assertTrue(RouteFeatureExtractor.candidates(chunks[0], emptyList()).isEmpty())
    }
}
