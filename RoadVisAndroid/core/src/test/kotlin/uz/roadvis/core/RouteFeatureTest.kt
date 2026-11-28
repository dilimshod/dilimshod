package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteFeatureTest {
    /** Route used to build `overpass_features.json` (north 556 m, north 557 m, then east 793 m). */
    private val route = listOf(GeoPoint(41.3100, 69.2800), GeoPoint(41.3150, 69.2800),
        GeoPoint(41.3200, 69.2805), GeoPoint(41.3200, 69.2900))

    private fun fixtureElements(): List<OSMElement> = OverpassQuery.decode(RoadFixture.data("overpass_features"))

    private fun kind(vararg tags: Pair<String, String>) = RouteFeatureExtractor.kind(tags.toMap())

    // Kinds

    @Test fun kindFromTags() {
        assertEquals(RouteFeatureKind.TRAFFIC_SIGNALS, kind("highway" to "traffic_signals"))
        assertEquals(RouteFeatureKind.PEDESTRIAN_CROSSING, kind("highway" to "crossing", "crossing" to "zebra"))
        assertEquals(RouteFeatureKind.PEDESTRIAN_CROSSING, kind("highway" to "crossing", "crossing" to "traffic_signals"))
        assertEquals("a raised crossing is announced as a crossing", RouteFeatureKind.PEDESTRIAN_CROSSING,
            kind("highway" to "crossing", "traffic_calming" to "table"))
        assertNull(kind("highway" to "crossing", "crossing" to "no"))
        assertNull("railway=crossing is a footpath over rails", kind("railway" to "crossing"))
        assertEquals(RouteFeatureKind.SPEED_CAMERA, kind("highway" to "speed_camera"))
        assertEquals(RouteFeatureKind.TRAFFIC_CALMING, kind("traffic_calming" to "bump"))
        assertEquals(RouteFeatureKind.TRAFFIC_CALMING, kind("traffic_calming" to "yes"))
        assertNull(kind("traffic_calming" to "no"))
        assertEquals(RouteFeatureKind.RAILWAY_CROSSING, kind("railway" to "level_crossing"))
        assertEquals(RouteFeatureKind.SCHOOL, kind("amenity" to "school"))
        assertEquals(RouteFeatureKind.KINDERGARTEN, kind("amenity" to "kindergarten"))
        assertNull(kind("amenity" to "childcare"))
        assertEquals(RouteFeatureKind.CONSTRUCTION, kind("highway" to "construction"))
        assertEquals(RouteFeatureKind.STOP_SIGN, kind("highway" to "stop"))
        assertEquals(RouteFeatureKind.GIVE_WAY, kind("highway" to "give_way"))
        assertNull(kind("highway" to "primary"))
        assertNull(kind())
    }

    @Test fun kindPresentation() {
        val names = RouteFeatureKind.entries.map { it.displayName }
        assertEquals(names.size, names.toSet().size)
        assertEquals("Светофор", RouteFeatureKind.TRAFFIC_SIGNALS.displayName)
        assertEquals("Пешеходный переход", RouteFeatureKind.PEDESTRIAN_CROSSING.displayName)
        assertEquals("camera.fill", RouteFeatureKind.SPEED_CAMERA.symbolName)
        assertEquals(500.0, RouteFeatureKind.SPEED_CAMERA.alertDistance, 0.0)
        for (k in RouteFeatureKind.entries) {
            assertFalse(k.symbolName.isEmpty())
            assertTrue(k.raw, k.alertDistance > 100)
            assertTrue(k.mergeRadius > 0)
        }
        assertEquals(60.0, RouteFeatureKind.TRAFFIC_SIGNALS.mergeRadius, 0.0)
        assertEquals(25.0, RouteFeatureKind.PEDESTRIAN_CROSSING.mergeRadius, 0.0)
        assertEquals(150.0, RouteFeatureKind.SCHOOL.maxOffset(40.0), 0.0)
        assertEquals(40.0, RouteFeatureKind.SPEED_CAMERA.maxOffset(40.0), 0.0)
    }

    // Extraction from the fixture

    @Test fun extractFromFixture() {
        val features = RouteFeatureExtractor.extract(fixtureElements(), route)
        assertEquals(listOf(
            RouteFeatureKind.TRAFFIC_SIGNALS, RouteFeatureKind.PEDESTRIAN_CROSSING, RouteFeatureKind.TRAFFIC_CALMING,
            RouteFeatureKind.PEDESTRIAN_CROSSING, RouteFeatureKind.PEDESTRIAN_CROSSING, RouteFeatureKind.SPEED_CAMERA,
            RouteFeatureKind.SCHOOL, RouteFeatureKind.TRAFFIC_SIGNALS, RouteFeatureKind.CONSTRUCTION, RouteFeatureKind.GIVE_WAY,
            RouteFeatureKind.STOP_SIGN, RouteFeatureKind.RAILWAY_CROSSING, RouteFeatureKind.TRAFFIC_CALMING,
            RouteFeatureKind.KINDERGARTEN,
        ), features.map { it.kind })
        val expectedAlong = listOf(140.0, 145.0, 300.0, 420.0, 452.0, 500.0, 520.0, 700.0, 900.0, 1000.0, 1100.0, 1400.0, 1600.0, 1800.0)
        for ((feature, along) in features.zip(expectedAlong)) {
            assertEquals("${feature.kind} ${feature.id}", along, feature.distanceAlongRoute, 3.0)
        }
        assertEquals(features.map { it.distanceAlongRoute }.sorted(), features.map { it.distanceAlongRoute })

        // Four signal heads of one intersection → one feature with the smallest OSM id; earliest position.
        val signals = features[0]
        assertEquals("node/2001", signals.id)
        assertEquals(6.0, signals.offsetFromRoute, 1.5)
        assertNull(signals.name)

        // Two crossing nodes 20 m apart merge; two 32 m apart stay separate.
        assertEquals("node/2010", features[1].id)
        assertEquals("node/2012", features[3].id)
        assertEquals("node/2013", features[4].id)
        assertEquals("zebra", features[3].tags["crossing_ref"])

        // School: campus outline (centre 120 m off) + school node with the same name → one feature.
        val school = features[6]
        assertEquals("node/2040", school.id)
        assertEquals("Школа №45", school.name)
        assertEquals(90.0, school.offsetFromRoute, 2.0)

        assertEquals("way/3002", features[8].id)
        assertEquals("Navoiy ko‘chasi", features[8].name)
        assertEquals("way/3003", features[13].id)
        assertEquals("Детский сад №12", features[13].name)
        assertEquals(60.0, features[13].offsetFromRoute, 2.0)

        // Dropped: kindergarten 200 m off, signal 300 m off, crossing=no.
        val ids = features.map { it.id }.toSet()
        assertFalse(ids.contains("node/2041"))
        assertFalse(ids.contains("node/2006"))
        assertFalse(ids.contains("node/2014"))
    }

    @Test fun extractCumulativeAndOffsets() {
        val elements = fixtureElements()
        val plain = RouteFeatureExtractor.extract(elements, route)
        val withCumulative = RouteFeatureExtractor.extract(elements, route, Geo.cumulativeDistances(route))
        assertEquals(plain, withCumulative)
        val wrongCumulative = RouteFeatureExtractor.extract(elements, route, listOf(0.0, 1.0))
        assertEquals("a cumulative array of the wrong size is ignored", plain, wrongCumulative)

        val narrow = RouteFeatureExtractor.extract(elements, route, maxOffset = 10.0)
        val kinds = narrow.map { it.kind }.toSet()
        assertFalse("camera 12 m off is dropped", kinds.contains(RouteFeatureKind.SPEED_CAMERA))
        assertFalse("construction 25 m off is dropped", kinds.contains(RouteFeatureKind.CONSTRUCTION))
        assertTrue("schools keep their 150 m corridor", kinds.contains(RouteFeatureKind.SCHOOL))
        assertTrue(kinds.contains(RouteFeatureKind.KINDERGARTEN))
        assertTrue(kinds.contains(RouteFeatureKind.TRAFFIC_SIGNALS))

        assertEquals(emptyList<RouteFeature>(), RouteFeatureExtractor.extract(elements, emptyList()))
        assertEquals(emptyList<RouteFeature>(), RouteFeatureExtractor.extract(emptyList(), route))
    }

    @Test fun mergeUsesClusterAnchorAndKindsAreIndependent() {
        val line = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.01, 69.0))
        fun node(id: Long, along: Double, tags: Map<String, String>): OSMElement {
            val p = Geo.destination(line[0], 0.0, along)
            return OSMElement(OSMElement.ElementType.NODE, id, lat = p.latitude, lon = p.longitude, tags = tags)
        }
        val signal = mapOf("highway" to "traffic_signals")
        val elements = listOf(
            node(1, 100.0, signal), node(2, 150.0, signal), node(3, 200.0, signal),
            node(4, 105.0, mapOf("highway" to "crossing")),
            node(4, 105.0, mapOf("highway" to "crossing")),   // duplicate element (overlapping query chunks)
            node(5, 400.0, mapOf("highway" to "stop")), node(6, 425.0, mapOf("highway" to "stop")),
            node(7, 460.0, mapOf("highway" to "stop")),
        )
        val features = RouteFeatureExtractor.extract(elements, line)
        val signals = features.filter { it.kind == RouteFeatureKind.TRAFFIC_SIGNALS }
        assertEquals("200 m is 100 m from the anchor at 100 m → new cluster", listOf("node/1", "node/3"), signals.map { it.id })
        assertEquals(1, features.count { it.kind == RouteFeatureKind.PEDESTRIAN_CROSSING })
        assertEquals(listOf("node/5", "node/7"), features.filter { it.kind == RouteFeatureKind.STOP_SIGN }.map { it.id })
        assertEquals(RouteFeatureKind.TRAFFIC_SIGNALS, features.first().kind)
        assertEquals(RouteFeatureKind.PEDESTRIAN_CROSSING, features[1].kind)
    }

    @Test fun constructionWayUsesGeometryClosestToRoute() {
        val line = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.01, 69.0))
        // A long construction way crossing the route: its midpoint is ~300 m away, but one vertex is on the route.
        val far = Geo.destination(line[0], 90.0, 600.0)
        val onRoute = Geo.destination(line[0], 0.0, 500.0)
        val way = OSMElement(OSMElement.ElementType.WAY, 9, geometry = listOf(onRoute, far), tags = mapOf("highway" to "construction"))
        val features = RouteFeatureExtractor.extract(listOf(way), line)
        assertEquals(1, features.size)
        assertEquals(500.0, features.first().distanceAlongRoute, 2.0)
        assertEquals(0.0, features.first().offsetFromRoute, 1.0)
    }

    // Signals

    @Test fun signalsFromFixtures() {
        val features = RouteFeatureExtractor.signals(fixtureElements())
        assertEquals(listOf("node/2001", "node/2005", "node/2006"), features.map { it.id })

        val roadElements = OverpassQuery.decode(RoadFixture.data("overpass_roads_tashkent"))
        val around = RouteFeatureExtractor.signals(roadElements)
        assertEquals(listOf("node/1150000101", "node/1150000105", "node/1150000107"), around.map { it.id })
        // Every member node lies within the cluster radius of its centroid.
        val first = around[0]
        for (member in roadElements.filter { it.id in 1150000101L..1150000104L }) {
            assertTrue(Geo.distance(first.coordinate, member.coordinate!!) <= RouteFeatureExtractor.signalClusterRadius)
        }
        // Shuffled input → identical output (stable ids for learned statistics).
        assertEquals(around, RouteFeatureExtractor.signals(roadElements.reversed()))
    }

    @Test fun signalsIgnoreOtherElements() {
        val a = OSMElement(OSMElement.ElementType.NODE, 10, lat = 41.0, lon = 69.0, tags = mapOf("highway" to "traffic_signals"))
        val crossing = OSMElement(OSMElement.ElementType.NODE, 11, lat = 41.0, lon = 69.0001, tags = mapOf("highway" to "crossing"))
        val noCoordinate = OSMElement(OSMElement.ElementType.NODE, 12, tags = mapOf("highway" to "traffic_signals"))
        val signals = RouteFeatureExtractor.signals(listOf(a, crossing, noCoordinate, a))
        assertEquals(listOf(SignalLocation("node/10", GeoPoint(41.0, 69.0))), signals)
        assertEquals(emptyList<SignalLocation>(), RouteFeatureExtractor.signals(emptyList()))
    }

    @Test fun matchingSignal() {
        val elements = fixtureElements()
        val signals = RouteFeatureExtractor.signals(elements)
        val features = RouteFeatureExtractor.extract(elements, route)
        val intersection = features.first { it.kind == RouteFeatureKind.TRAFFIC_SIGNALS }
        assertEquals("node/2001", RouteFeatureExtractor.matchingSignal(intersection, signals)?.id)

        val single = signals.first { it.id == "node/2005" }
        val nearby = RouteFeature("node/999", RouteFeatureKind.TRAFFIC_SIGNALS, Geo.destination(single.coordinate, 45.0, 20.0),
            700.0, 3.0, null, emptyMap())
        assertEquals("node/2005", RouteFeatureExtractor.matchingSignal(nearby, signals)?.id)
        val far = RouteFeature("node/998", RouteFeatureKind.TRAFFIC_SIGNALS, Geo.destination(single.coordinate, 45.0, 120.0),
            800.0, 3.0, null, emptyMap())
        assertNull(RouteFeatureExtractor.matchingSignal(far, signals))
    }
}
