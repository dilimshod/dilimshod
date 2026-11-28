package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sin

/** OSRM parsing, multi-engine route comparison, the route timeline and the Overpass chunk planner. */
class NavigatorV2Test {
    /** A straight-ish line north from (41.300, 69.240), `count` points ~111 m apart, optionally shifted east. */
    private fun line(count: Int = 30, eastShift: Double = 0.0, start: Double = 41.300): List<GeoPoint> =
        (0 until count).map { GeoPoint(start + it * 0.001, 69.240 + eastShift) }

    private fun osrmFixture(): String {
        val main = line(count = 30)
        val alt = line(count = 30, eastShift = 0.004)
        fun step(type: String, modifier: String?, name: String, distance: Double, location: GeoPoint,
                 lanes: List<Map<String, Any>>? = null, exit: Int? = null, classes: List<String>? = null): Map<String, Any> {
            val maneuver = linkedMapOf<String, Any>("type" to type, "location" to listOf(location.longitude, location.latitude),
                "bearing_before" to 0, "bearing_after" to 0)
            if (modifier != null) maneuver["modifier"] = modifier
            if (exit != null) maneuver["exit"] = exit
            val intersection = linkedMapOf<String, Any>("location" to listOf(location.longitude, location.latitude))
            if (lanes != null) intersection["lanes"] = lanes
            if (classes != null) intersection["classes"] = classes
            return mapOf("maneuver" to maneuver, "name" to name, "distance" to distance, "duration" to distance / 10,
                "geometry" to "", "intersections" to listOf(intersection))
        }
        val lanes = listOf(
            mapOf("valid" to true, "indications" to listOf("left")),
            mapOf("valid" to false, "indications" to listOf("straight")),
            mapOf("valid" to false, "indications" to listOf("straight", "right")),
        )
        val steps = listOf(
            step("depart", null, "Амира Темура", 1000.0, main[0]),
            step("turn", "left", "Навои", 1200.0, main[9], lanes = lanes),
            step("roundabout", "right", "Бабура", 700.0, main[20], exit = 2, classes = listOf("toll")),
            step("arrive", "right", "", 0.0, main[29]),
        )
        val route1 = mapOf(
            "distance" to 3220.0, "duration" to 290.0, "geometry" to Polyline.encode(main),
            "legs" to listOf(mapOf("summary" to "Амира Темура, Навои", "steps" to steps,
                "annotation" to mapOf("distance" to listOf(111.0), "duration" to listOf(10.0), "speed" to listOf(11.1)))),
        )
        val route2 = mapOf(
            "distance" to 3400.0, "duration" to 330.0, "geometry" to Polyline.encode(alt),
            "legs" to listOf(mapOf("summary" to "", "steps" to listOf(
                step("depart", null, "Шота Руставели", 3400.0, alt[0]),
                step("arrive", null, "", 0.0, alt[29]),
            ))),
        )
        return JSONObject(mapOf("code" to "Ok", "routes" to listOf(route1, route2), "waypoints" to emptyList<Any>())).toString()
    }

    // OSRM

    @Test fun osrmURL() {
        val url = OSRM.routeURL(OSRM.defaultEndpoint + "/", GeoPoint(41.3, 69.24), GeoPoint(41.35, 69.3))
        assertEquals("https://routing.openstreetmap.de/routed-car/route/v1/driving/69.240000,41.300000;69.300000,41.350000" +
            "?overview=full&geometries=polyline6&steps=true&alternatives=true&annotations=true", url)
        assertNull(OSRM.routeURL("ftp://x", GeoPoint(41.3, 69.24), GeoPoint(41.35, 69.3)))
        assertNull(OSRM.routeURL("", GeoPoint(41.3, 69.24), GeoPoint(41.35, 69.3)))
    }

    @Test fun osrmParse() {
        val routes = OSRM.parseRoutes(osrmFixture())
        assertEquals(2, routes.size)
        val r = routes[0]
        assertEquals(RouteSource.OSRM, r.source)
        assertEquals("Амира Темура, Навои", r.name)
        assertEquals(3220.0, r.distance, 0.0)
        assertEquals(290.0, r.expectedTravelTime, 0.0)
        assertEquals(30, r.polyline.size)
        assertTrue(r.hasTolls)
        assertEquals(4, r.steps.size)
        assertEquals("", r.steps[0].instruction)
        assertEquals(ManeuverType.DEPART, r.steps[0].maneuver)
        assertEquals("Поверните налево на Навои", r.steps[1].instruction)
        assertEquals(ManeuverType.LEFT, r.steps[1].maneuver)
        assertEquals(listOf(listOf(LaneTurn.LEFT), listOf(LaneTurn.THROUGH), listOf(LaneTurn.THROUGH, LaneTurn.RIGHT)),
            r.steps[1].lanes.map { it.turns })
        assertEquals(listOf(true, false, false), r.steps[1].activeLanes)
        assertEquals("На круговом движении — 2-й съезд на Бабура", r.steps[2].instruction)
        assertEquals(ManeuverType.ROUNDABOUT, r.steps[2].maneuver)
        assertEquals("Пункт назначения справа", r.steps[3].instruction)
        assertEquals(ManeuverType.ARRIVE, r.steps[3].maneuver)
        assertEquals("Шота Руставели", routes[1].name)

        // Usable by the progress tracker: the next maneuver after the start is the left turn.
        val tracker = RouteProgressTracker(r.polyline, r.steps, r.expectedTravelTime)
        val progress = tracker.update(r.polyline[2])
        assertEquals("Поверните налево на Навои", progress.nextInstruction)
        assertEquals(listOf(true, false, false), progress.nextActiveLanes)
    }

    @Test fun osrmErrors() {
        val data = "{\"code\":\"NoRoute\",\"message\":\"Impossible route between points\"}"
        val e = assertThrows(OSRMError::class.java) { OSRM.parseRoutes(data) }
        assertEquals("NoRoute", e.code)
        assertEquals("OSRM не нашёл маршрут между этими точками.", e.russianDescription)
        assertThrows(OSRMError::class.java) { OSRM.parseRoutes("<html>") }
    }

    @Test fun osrmInstructionsAndMapping() {
        assertEquals("Поверните направо", OSRM.instruction("turn", "right", null))
        assertEquals("Развернитесь на Навои", OSRM.instruction("turn", "uturn", "Навои"))
        assertEquals("Резко поверните налево", OSRM.instruction("turn", "sharp left", null))
        assertEquals("Продолжайте движение по Бабура", OSRM.instruction("new name", "straight", "Бабура"))
        assertEquals("Продолжайте движение прямо", OSRM.instruction("continue", null, null))
        assertEquals("На развилке держитесь правее", OSRM.instruction("fork", "slight right", null))
        assertEquals("Сверните направо на съезд на М39", OSRM.instruction("off ramp", "slight right", "М39"))
        assertEquals("В конце дороги поверните налево", OSRM.instruction("end of road", "left", null))
        assertEquals("Въезжайте на круговое движение", OSRM.instruction("roundabout", null, null))
        assertEquals("Пункт назначения", OSRM.instruction("arrive", null, null))
        assertEquals(ManeuverType.KEEP_LEFT, OSRM.maneuverType("fork", "slight left"))
        assertEquals(ManeuverType.EXIT_RIGHT, OSRM.maneuverType("off ramp", "right"))
        assertEquals(ManeuverType.SLIGHT_RIGHT, OSRM.maneuverType("turn", "slight right"))
        assertEquals(ManeuverType.ROUNDABOUT, OSRM.maneuverType("exit roundabout", "right"))
        assertEquals(ManeuverType.MERGE, OSRM.maneuverType("merge", "left"))
        assertEquals(LaneTurn.REVERSE, OSRM.laneTurn("uturn"))
        assertEquals(listOf(Lane(emptyList())), OSRM.lanes(listOf(OSRM.OSRMLane(listOf("none"), true))).first)
        assertEquals("OpenStreetMap (OSRM)", RouteSource.OSRM.displayName)
        assertEquals(listOf("Apple", "Valhalla", "OSRM"), RouteSource.entries.map { it.badge })
    }

    // Valhalla arrival

    @Test fun valhallaArrivalUsesFutureTense() {
        val route = Valhalla.parseRoutes(RoadFixture.data("valhalla_route_tashkent")).first()
        assertEquals("Пункт назначения будет справа.", route.steps.last().instruction)
        assertEquals("Вы прибудете в пункт назначения.", Valhalla.arrivalInstruction("Вы прибыли в пункт назначения.", null))
        assertEquals("x", Valhalla.arrivalInstruction("x", "  "))
    }

    // Route comparison

    @Test fun overlapAndMerge() {
        val a = line()
        val aPrime = a.map { GeoPoint(it.latitude, it.longitude + 0.0001) }   // ≈ 8 m east
        val far = line(eastShift = 0.004)                                      // ≈ 330 m east
        assertEquals(1.0, RouteComparison.overlap(a, a), 1e-9)
        assertTrue(RouteComparison.similarity(a, aPrime) > 0.99)
        assertEquals(0.0, RouteComparison.overlap(a, far), 1e-9)
        // Half of the route shared.
        val half = a.take(15) + line(count = 15, eastShift = 0.004, start = 41.315)
        val partial = RouteComparison.overlap(a, half)
        assertTrue(partial > 0.4)
        assertTrue(partial < 0.7)

        val valhalla = NavRoute(RouteSource.VALHALLA, "V", a, 3220.0, 300.0, emptyList())
        val osrm = NavRoute(RouteSource.OSRM, "O", aPrime, 3225.0, 290.0, emptyList())
        val apple = NavRoute(RouteSource.APPLE, "A", far, 3300.0, 420.0, emptyList())
        val choices = RouteComparison.merge(listOf(valhalla, apple, osrm))
        assertEquals(2, choices.size)
        assertEquals(RouteSource.OSRM, choices[0].route.source)            // fastest of the duplicate group
        assertEquals(listOf(RouteSource.VALHALLA), choices[0].duplicates.map { it.source })
        assertEquals(listOf(RouteSource.OSRM, RouteSource.VALHALLA), choices[0].sources)
        assertEquals(RouteSource.APPLE, choices[1].route.source)
        assertEquals("+2 мин", RouteComparison.delayText(420.0, 290.0))
        assertNull(RouteComparison.delayText(300.0, 290.0))
        val notes = RouteComparison.notes(choices)
        assertTrue(notes.any { it.contains("пробки") })
        assertTrue(notes.any { it.contains("выигрывает") })
    }

    @Test fun facts() {
        val route = NavRoute(RouteSource.VALHALLA, "R", line(), 3000.0, 300.0,
            listOf(RouteStepInfo("", 1000.0, maneuver = ManeuverType.DEPART),
                RouteStepInfo("Налево", 2000.0, maneuver = ManeuverType.LEFT),
                RouteStepInfo("Пункт назначения", 0.0, maneuver = ManeuverType.ARRIVE)))
        val edges = listOf(
            RouteEdgeAttributes(0.0, 1000.0, speedLimitKmh = 60, roadClass = "primary"),
            RouteEdgeAttributes(1000.0, 2000.0, speedLimitKmh = 80, roadClass = "trunk", hasTrafficSignal = true, isBridge = true),
            RouteEdgeAttributes(2000.0, 3000.0, roadClass = "residential", surface = "dirt"),
        )
        val facts = RouteComparison.facts(route, edges)
        assertEquals(36.0, facts.averageSpeedKmh ?: 0.0, 0.01)
        assertEquals(80, facts.maxSpeedLimitKmh)
        assertEquals(70.0, facts.averageSpeedLimitKmh ?: 0.0, 0.01)
        assertEquals(2.0 / 3, facts.speedLimitCoverage ?: 0.0, 0.01)
        assertEquals(2.0 / 3, facts.primaryRoadShare ?: 0.0, 0.01)
        assertEquals(1.0 / 3, facts.unpavedShare ?: 0.0, 0.01)
        assertEquals(1, facts.signalCount)
        assertEquals(1, facts.maneuverCount)
        assertEquals(1, facts.bridgeCount)
        val bare = RouteComparison.facts(route, emptyList(), signalCount = 4)
        assertEquals(4, bare.signalCount)
        assertNull(bare.primaryRoadShare)
    }

    // Timeline

    @Test fun timeline() {
        val polyline = line()   // ≈ 3225 m
        val total = Geo.polylineLength(polyline)
        val route = NavRoute(RouteSource.VALHALLA, "R", polyline, total, 300.0,
            listOf(RouteStepInfo("", 1000.0, maneuver = ManeuverType.DEPART),
                RouteStepInfo("Поверните налево", 2000.0, maneuver = ManeuverType.LEFT,
                    lanes = listOf(Lane(listOf(LaneTurn.LEFT)), Lane(listOf(LaneTurn.THROUGH))), activeLanes = listOf(true, false)),
                RouteStepInfo("Пункт назначения будет справа.", 0.0, maneuver = ManeuverType.ARRIVE)))
        val edges = listOf(
            RouteEdgeAttributes(0.0, 800.0, speedLimitKmh = 60, laneCount = 3, typicalSpeedKmh = 50.0),
            RouteEdgeAttributes(800.0, 850.0, speedLimitKmh = 40, laneCount = 3, typicalSpeedKmh = 50.0),
            RouteEdgeAttributes(850.0, 2000.0, speedLimitKmh = 60, laneCount = 2, typicalSpeedKmh = 50.0, hasTrafficSignal = true),
            RouteEdgeAttributes(2000.0, total, speedLimitKmh = 40, laneCount = 2, typicalSpeedKmh = 25.0),
        )
        val segments = RouteTimeline.speedLimitSegments(edges, total)
        assertEquals(listOf(60, 40), segments.map { it.limitKmh })        // the 50 m "40" blip is folded
        assertEquals(2000.0, segments[0].end, 0.001)

        val camera = RouteFeature("node/1", RouteFeatureKind.SPEED_CAMERA, polyline[25], 2700.0, 5.0, null, mapOf("maxspeed" to "40"))
        val osmSignal = RouteFeature("node/2", RouteFeatureKind.TRAFFIC_SIGNALS, polyline[18], 1990.0, 3.0, null, emptyMap())
        val fuel = RouteFeature("node/3", RouteFeatureKind.FUEL, polyline[5], 500.0, 40.0, "UzGasOil", mapOf("brand" to "UNG"))
        val incident = IncidentOnRoute(RoadIncident(kind = RoadIncidentKind.POTHOLE, coordinate = polyline[12]), 1300.0)
        val events = RouteTimeline.build(route, edges, listOf(camera, osmSignal, fuel), listOf(incident))
        val categories = events.map { it.kind.category }
        assertEquals(1, categories.count { it == "signal" })   // Valhalla signal merged with the OSM one
        assertEquals(RouteTimelineKind.SpeedLimit(60), events.first().kind)
        assertTrue(events.any { it.kind == RouteTimelineKind.Maneuver(ManeuverType.LEFT) && it.detail == "полос: 2, подходят: 1" })
        assertTrue(events.any { it.kind == RouteTimelineKind.Lanes(3, 2) && it.title == "Сужение до 2 полос" })
        assertTrue(events.any { it.kind == RouteTimelineKind.Feature(RouteFeatureKind.SPEED_CAMERA) && it.detail == "контроль 40 км/ч" })
        assertTrue(events.any { it.kind == RouteTimelineKind.Feature(RouteFeatureKind.FUEL) && it.detail == "UzGasOil · UNG" })
        assertTrue(events.any { it.kind == RouteTimelineKind.Incident(RoadIncidentKind.POTHOLE) })
        assertEquals(RouteTimelineKind.Destination, events.last().kind)
        assertFalse(events.any { it.kind == RouteTimelineKind.Maneuver(ManeuverType.ARRIVE) })
        for (i in 1 until events.size) {
            assertTrue(events[i - 1].distanceAlongRoute <= events[i].distanceAlongRoute + 0.5)
        }
        assertEquals(RouteTimelineKind.TrafficSignal, RouteTimeline.upcoming(events, 1500.0, limit = 2).first().kind)

        // Time offsets follow typical speeds: the slow last part (25 km/h) takes proportionally longer.
        val half = RouteTimeline.timeOffset(2000.0, 0.0, 300.0, total, edges)
        assertTrue(half < 300 * 2000 / total)
        assertEquals(300.0, RouteTimeline.timeOffset(total, 0.0, 300.0, total, edges), 0.01)
        assertEquals(150.0, RouteTimeline.timeOffset(1000.0, 0.0, 300.0, 2000.0, emptyList()), 0.01)
    }

    // Overpass chunk plan

    @Test fun routeQueryPlanner() {
        // 40 km winding route with 4000 vertices.
        val route = (0 until 4000).map { i -> GeoPoint(41.2 + i * 0.00009, 69.2 + 0.002 * sin(i / 15.0)) }
        val plan = RouteQueryPlanner.plan(route)
        assertTrue(plan.isComplete)
        assertTrue(plan.chunks.size >= (plan.totalLength / 3000).toInt())
        for (chunk in plan.chunks) {
            assertTrue(chunk.size <= 60)
            assertTrue(Geo.polylineLength(chunk) <= 3000 + 1)
        }
        assertEquals(route.first(), plan.chunks.first().first())
        assertEquals(route.last(), plan.chunks.last().last())
        for (i in 1 until plan.chunks.size) assertEquals(plan.chunks[i - 1].last(), plan.chunks[i].first())
        // Every original vertex lies within the tolerance of some chunk.
        for (p in (0 until route.size step 97).map { route[it] }) {
            val near = plan.chunks.any { (Geo.project(p, it)?.distanceFromLine ?: Double.POSITIVE_INFINITY) <= 10.5 }
            assertTrue(near)
        }
        // A long straight segment is densified.
        val straight = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.1, 69.0))   // ≈ 11 km
        val chunks = RouteQueryPlanner.chunks(straight, 60, 3000.0)
        assertEquals(4, chunks.size)
        // Capped plans report what was dropped.
        val capped = RouteQueryPlanner.plan(route, maxChunks = 3)
        assertFalse(capped.isComplete)
        assertEquals(3, capped.chunks.size)
        assertTrue(capped.coveredLength < capped.totalLength)
    }

    // Matcher score & new feature kinds

    @Test fun scoredMatchAndPOIKinds() {
        fun way(id: Long, points: List<GeoPoint>, tags: Map<String, String>): OSMElement {
            val geometry = points.joinToString(",") { "{\"lat\":${it.latitude},\"lon\":${it.longitude}}" }
            val tagJSON = tags.entries.joinToString(",") { "\"${it.key}\":\"${it.value}\"" }
            val json = "{\"type\":\"way\",\"id\":$id,\"geometry\":[$geometry],\"tags\":{$tagJSON}}"
            return OSMElement.fromJSON(JSONObject(json))
        }
        val northSouth = way(1, listOf(GeoPoint(41.300, 69.2400), GeoPoint(41.310, 69.2400)), mapOf("highway" to "primary"))
        val eastWest = way(2, listOf(GeoPoint(41.3049, 69.235), GeoPoint(41.3049, 69.245)), mapOf("highway" to "primary"))
        val position = GeoPoint(41.3050, 69.24005)
        val match = RoadMatcher.scoredMatch(listOf(northSouth, eastWest), position, 0.0)!!
        assertEquals(1L, match.road.wayID)
        assertTrue(match.score >= match.road.distanceToRoad)
        val crossing = RoadMatcher.scoredMatch(listOf(eastWest), position, 0.0)!!
        assertTrue(crossing.score > match.score)   // heading penalty, although the raw distance is similar

        assertEquals(RouteFeatureKind.FUEL, RouteFeatureExtractor.kind(mapOf("amenity" to "fuel")))
        assertEquals(RouteFeatureKind.PARKING, RouteFeatureExtractor.kind(mapOf("amenity" to "parking")))
        assertNull(RouteFeatureExtractor.kind(mapOf("amenity" to "parking", "access" to "private")))
        assertTrue(RouteFeatureKind.FUEL.isPointOfInterest)
        assertFalse(RouteFeatureKind.SPEED_CAMERA.isPointOfInterest)
        val q = OverpassQuery.featuresAlong(listOf(GeoPoint(41.31, 69.28), GeoPoint(41.32, 69.28)))
        assertTrue(q.contains("[amenity=fuel]"))
        assertTrue(q.contains("nwr(around:60,41.310000,69.280000,41.320000,69.280000)[amenity=parking]"))
    }
}
