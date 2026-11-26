package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ValhallaTest {
    private fun fixture(name: String) = RoadFixture.data(name)

    @Test fun polylineRoundTrip() {
        val pts = listOf(GeoPoint(41.311111, 69.279722), GeoPoint(41.338889, 69.334722), GeoPoint(-12.5, 130.25))
        val enc = Polyline.encode(pts, 6)
        val dec = Polyline.decode(enc, 6)
        assertEquals(3, dec.size)
        for ((a, b) in pts.zip(dec)) {
            assertEquals(a.latitude, b.latitude, 1e-6)
            assertEquals(a.longitude, b.longitude, 1e-6)
        }
        // Known Google example (precision 5).
        val g = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", 5)
        assertEquals(3, g.size)
        assertEquals(38.5, g[0].latitude, 1e-5)
        assertEquals(-120.2, g[0].longitude, 1e-5)
        assertEquals(-126.453, g[2].longitude, 1e-5)
    }

    @Test fun parseTashkentRoute() {
        val routes = Valhalla.parseRoutes(fixture("valhalla_route_tashkent"))
        assertEquals(3, routes.size)
        val r = routes[0]
        assertEquals(RouteSource.VALHALLA, r.source)
        assertEquals(6609.0, r.distance, 1.0)
        assertEquals(700.243, r.expectedTravelTime, 0.01)
        assertEquals(197, r.polyline.size)
        assertEquals(6609.0, Geo.polylineLength(r.polyline), 150.0)
        assertEquals("", r.steps.first().instruction)            // departure is not announced
        assertEquals(ManeuverType.DEPART, r.steps.first().maneuver)
        assertEquals(ManeuverType.ROUNDABOUT, r.steps[1].maneuver)
        val left = r.steps.first { it.instruction.startsWith("Поверните налево") }
        assertEquals(ManeuverType.SLIGHT_LEFT, left.maneuver)    // type 16 rendered as "налево" in ru-RU
        assertEquals(3, left.lanes.size)
        assertEquals(3, left.activeLanes.size)
        assertTrue(left.activeLanes.contains(true))
        assertEquals(ManeuverType.ARRIVE, r.steps.last().maneuver)

        // The route works with the progress tracker.
        val tracker = RouteProgressTracker(r.polyline, r.steps, r.expectedTravelTime)
        val p = tracker.update(r.polyline[0])
        assertEquals(1, p.nextStepIndex)
        assertEquals(ManeuverType.ROUNDABOUT, p.nextManeuver)
        assertFalse(p.isOffRoute)
    }

    @Test fun laneMasks() {
        assertEquals(listOf(LaneTurn.LEFT, LaneTurn.THROUGH), Valhalla.turns(10))
        val (lanes, active) = Valhalla.lanes(listOf(Valhalla.ValhallaLane(8, active = 8),
            Valhalla.ValhallaLane(10, active = 8), Valhalla.ValhallaLane(2)))
        assertEquals(listOf(listOf(LaneTurn.LEFT), listOf(LaneTurn.LEFT, LaneTurn.THROUGH), listOf(LaneTurn.THROUGH)),
            lanes.map { it.turns })
        assertEquals(listOf(true, true, false), active)
    }

    @Test fun maneuverCodes() {
        assertEquals(ManeuverType.RIGHT, Valhalla.maneuverType(10))
        assertEquals(ManeuverType.U_TURN, Valhalla.maneuverType(13))
        assertEquals(ManeuverType.KEEP_LEFT, Valhalla.maneuverType(24))
        assertEquals(ManeuverType.ARRIVE, Valhalla.maneuverType(5))
    }

    @Test fun traceAttributes() {
        val routes = Valhalla.parseRoutes(fixture("valhalla_route_tashkent"))
        val edges = Valhalla.parseTraceAttributes(fixture("valhalla_trace_tashkent"), routes[0].polyline)
        assertEquals(85, edges.size)
        assertTrue(edges.count { it.speedLimitKmh != null } > 60)
        assertTrue(edges.any { (it.laneCount ?: 0) >= 3 })
        for (i in 1 until edges.size) assertTrue(edges[i].startDistance + 1 >= edges[i - 1].startDistance)
        val mid = Valhalla.attributes(3000.0, edges)
        assertNotNull(mid)
        assertTrue(mid!!.startDistance <= 3000)
        assertTrue(mid.endDistance >= 3000)
        assertFalse(Valhalla.signalDistances(edges).isEmpty())
    }

    @Test fun requestBodyAndErrors() {
        val body = Valhalla.routeRequestBody(GeoPoint(41.3, 69.2), GeoPoint(41.4, 69.3), heading = 370.0, avoidTolls = true)
        val obj = JSONObject(body)
        assertEquals("auto", obj.opt("costing"))
        assertEquals(true, obj.opt("turn_lanes"))
        val locs = obj.getJSONArray("locations")
        assertEquals(10, locs.getJSONObject(0).opt("heading"))
        assertNotNull(obj.optJSONObject("costing_options")?.opt("auto"))
        val err = "{\"error_code\":442,\"error\":\"No path could be found for input\",\"status_code\":400}"
        val e = assertThrows(ValhallaError::class.java) { Valhalla.parseRoutes(err) }
        assertEquals(442, e.code)
    }

    @Test fun congestionEstimator() {
        assertEquals(CongestionLevel.SEVERE, CongestionEstimator.level(8.0, 50.0))
        assertEquals(CongestionLevel.FREE, CongestionEstimator.level(45.0, 50.0))
        assertNull(CongestionEstimator.level(10.0, 10.0))
        assertNull(CongestionEstimator.level(0.0, 50.0, stoppedAtSignal = true))
    }
}
