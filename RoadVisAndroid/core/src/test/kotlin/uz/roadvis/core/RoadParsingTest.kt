package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLDecoder

class RoadParsingTest {
    private fun xy(x: Double, y: Double) = TashkentFrame.xy(x, y)

    // OSMModels

    @Test fun decodeRoadsFixture() {
        val response = OverpassQuery.decodeResponse(RoadFixture.data("overpass_roads_tashkent"))
        assertEquals(14, response.elements.size)
        assertEquals("2026-11-25T14:20:31Z", response.timestampOSMBase)
        assertNull(response.remark)
        assertFalse(response.isPartial)

        val avenue = response.elements.first { it.id == 23710011L }
        assertEquals(OSMElement.ElementType.WAY, avenue.type)
        assertEquals("way/23710011", avenue.key)
        assertEquals(4, avenue.geometry?.size)
        assertNull(avenue.nodes)
        assertNull(avenue.lat)
        assertEquals("проспект Амира Темура", avenue.tags["name:ru"])
        assertEquals("6", avenue.tag("lanes"))
        assertNotNull(avenue.coordinate)

        val signal = response.elements.first { it.id == 1150000101L }
        assertEquals(OSMElement.ElementType.NODE, signal.type)
        assertEquals("node/1150000101", signal.key)
        val c = signal.coordinate!!
        assertTrue(Geo.distance(c, xy(118.0, 45.0)) < 0.5)
    }

    @Test fun decodeRemarkUnknownTypesAndNullGeometry() {
        val response = OverpassQuery.decodeResponse(RoadFixture.data("overpass_remark"))
        // "area" and "count" elements and the element without an id are skipped.
        assertEquals(listOf("node/1150000101", "way/23710099"), response.elements.map { it.key })
        assertTrue(response.isPartial)
        assertTrue(response.remark?.contains("timed out") == true)
        // A bounded `out geom` emits null for vertices outside the box: they are dropped.
        assertEquals(2, response.elements[1].geometry?.size)
        assertEquals(2, OverpassQuery.decode(RoadFixture.data("overpass_remark")).size)
    }

    @Test fun standaloneElementDecodingIsTolerant() {
        val json = """
        [
          {"type": "area", "id": 3600000001, "tags": {"name": "Toshkent"}},
          {"type": "way", "id": 5, "center": {"lat": 41.3, "lon": 69.2}, "nodes": [1, 2, 3]},
          {"type": "count", "id": 0, "tags": {"nodes": 12, "total": 12.5, "flag": true}}
        ]
        """
        val elements = OSMElement.decodeArray(json)
        assertEquals(3, elements.size)
        assertEquals("unknown types decode as relation instead of failing", OSMElement.ElementType.RELATION, elements[0].type)
        assertEquals(emptyMap<String, String>(), elements[1].tags)
        assertEquals(listOf(1L, 2L, 3L), elements[1].nodes)
        assertEquals(GeoPoint(41.3, 69.2), elements[1].coordinate)
        assertEquals("12", elements[2].tags["nodes"])
        assertEquals("yes", elements[2].tags["flag"])
    }

    @Test fun coordinateFallbacks() {
        val node = OSMElement(OSMElement.ElementType.NODE, 1, lat = 41.0, lon = 69.0)
        assertEquals(GeoPoint(41.0, 69.0), node.coordinate)

        val centered = OSMElement(OSMElement.ElementType.WAY, 2, center = GeoPoint(41.5, 69.5),
            geometry = listOf(GeoPoint(40.0, 60.0), GeoPoint(40.0, 61.0)))
        assertEquals("center wins over geometry", GeoPoint(41.5, 69.5), centered.coordinate)

        val open = OSMElement(OSMElement.ElementType.WAY, 3,
            geometry = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.002), GeoPoint(41.0, 69.010)))
        assertEquals("half-way point along an open way", 69.005, open.coordinate?.longitude ?: 0.0, 0.0001)

        val ring = OSMElement(OSMElement.ElementType.WAY, 4, geometry = listOf(GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.002),
            GeoPoint(41.002, 69.002), GeoPoint(41.002, 69.0), GeoPoint(41.0, 69.0)))
        assertEquals(41.001, ring.coordinate?.latitude ?: 0.0, 1e-9)
        assertEquals(69.001, ring.coordinate?.longitude ?: 0.0, 1e-9)

        assertNull(OSMElement(OSMElement.ElementType.RELATION, 5).coordinate)
        assertEquals("relation/5", OSMElement(OSMElement.ElementType.RELATION, 5).key)
    }

    // Overpass errors

    @Test fun decodeNginx504Page() {
        val e = assertThrows(OverpassError::class.java) { OverpassQuery.decode(RoadFixture.data("overpass_error_504", "html")) }
        val message = (e as? OverpassError.HtmlError)?.detail ?: throw AssertionError("expected htmlError, got $e")
        assertEquals("504 Gateway Time-out", message)
        assertTrue(e.isTimeout)
        assertTrue(e.isRetryable)
        assertFalse(e.isRateLimited)
        assertTrue(e.errorDescription.contains("не ответил вовремя"))
    }

    @Test fun decodeOverpassParseErrorPage() {
        val e = assertThrows(OverpassError::class.java) { OverpassQuery.decode(RoadFixture.data("overpass_error_parse", "html")) }
        val message = (e as? OverpassError.HtmlError)?.detail ?: throw AssertionError("expected htmlError, got $e")
        assertTrue(message, message.startsWith("Error: line 2: parse error: ';' expected - ')' found."))
        assertTrue(message, message.contains("static error"))
        assertFalse("the licence paragraph is not an error", message.contains("ODbL"))
        assertFalse(e.isRetryable)
        assertTrue(e.errorDescription.startsWith("Сервер OpenStreetMap (Overpass) вернул ошибку"))
    }

    @Test fun decodeRateLimitedPage() {
        val e = assertThrows(OverpassError::class.java) {
            OverpassQuery.decode(RoadFixture.data("overpass_error_rate_limited", "html"))
        }
        assertTrue(e.isRateLimited)
        assertTrue(e.isRetryable)
        assertTrue(e.errorDescription.contains("ограничил частоту"))
    }

    @Test fun decodeOtherBodies() {
        assertEquals(OverpassError.EmptyResponse, assertThrows(OverpassError::class.java) { OverpassQuery.decode(ByteArray(0)) })
        assertEquals(OverpassError.EmptyResponse, assertThrows(OverpassError::class.java) { OverpassQuery.decode(" \n\t") })
        val invalid = assertThrows(OverpassError::class.java) { OverpassQuery.decode("{") }
        assertTrue("expected invalidJSON, got $invalid", invalid is OverpassError.InvalidJSON)
        val html = assertThrows(OverpassError::class.java) {
            OverpassQuery.decode("\n  <html><body><p>Error: runtime error: out of memory</p></body></html>")
        }
        assertEquals("Error: runtime error: out of memory", (html as OverpassError.HtmlError).detail)
        assertTrue(html.isRetryable)
        // UTF-8 BOM before the JSON is tolerated.
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "{\"elements\":[]}".toByteArray()
        assertEquals(0, OverpassQuery.decode(bom).size)
        assertEquals(0, OverpassQuery.decode("{\"version\":0.6}").size)
    }

    // Queries

    @Test fun roadsAroundQuery() {
        val q = OverpassQuery.roadsAround(GeoPoint(41.3111, 69.2797))
        assertTrue(q.startsWith("[out:json][timeout:15];"))
        assertTrue(q.contains("way(around:30,41.311100,69.279700)[highway][highway!~\"^("))
        assertTrue(q.contains("out tags geom;"))
        assertTrue(q.contains("node(around:80,41.311100,69.279700)[highway=traffic_signals];"))
        assertTrue(q.endsWith("out;"))
        for (excluded in listOf("footway", "path", "cycleway", "steps", "pedestrian", "bridleway", "corridor", "elevator",
            "platform", "proposed", "construction")) {
            assertTrue(excluded, OverpassQuery.excludedHighwayValues.contains(excluded))
            assertTrue(excluded, q.contains("|$excluded|") || q.contains("($excluded|") || q.contains("|$excluded)"))
        }
        assertFalse("drivable classes must not be excluded", q.contains("|primary"))

        val custom = OverpassQuery.roadsAround(GeoPoint(-33.8688, 151.2093), radius = 42.4, signalRadius = 120.0, timeout = 20)
        assertTrue(custom.contains("[timeout:20]"))
        assertTrue(custom.contains("way(around:42,-33.868800,151.209300)"))
        assertTrue(custom.contains("node(around:120,-33.868800,151.209300)"))
    }

    @Test fun featuresAlongQuery() {
        val line = listOf(GeoPoint(41.31, 69.28), GeoPoint(41.315, 69.28), GeoPoint(41.32, 69.2805))
        val q = OverpassQuery.featuresAlong(line)
        val poly = "41.310000,69.280000,41.315000,69.280000,41.320000,69.280500"
        assertTrue(q.startsWith("[out:json][timeout:25];"))
        assertTrue(q.contains("node(around:35,$poly)[highway~\"^(traffic_signals|crossing|speed_camera|stop|give_way)$\"];"))
        assertTrue(q.contains("node(around:35,$poly)[traffic_calming];"))
        assertTrue(q.contains("node(around:35,$poly)[railway=level_crossing];"))
        assertTrue(q.contains("nwr(around:150,$poly)[amenity~\"^(school|kindergarten)$\"];"))
        assertTrue(q.contains("way(around:35,$poly)[highway=construction];"))
        assertTrue(q.endsWith("out tags center qt;"))

        // A long zig-zag polyline is reduced to at most maxPolylinePoints vertices (an even number of values).
        assertEquals(100, OverpassQuery.maxPolylinePoints)
        val zigzag = (0 until 600).map { i -> GeoPoint(41.30 + i * 0.0005, 69.28 + (if (i % 2 == 0) 0.0 else 0.003)) }
        val long = OverpassQuery.featuresAlong(zigzag, radius = 40.0, timeout = 30)
        val clause = long.split("node(around:40,").drop(1).first().split(")").first()
        val values = clause.split(",").filter { it.isNotEmpty() }
        assertEquals(0, values.size % 2)
        assertTrue(values.size / 2 <= OverpassQuery.maxPolylinePoints)
        assertTrue(values.size / 2 >= 2)
        assertTrue(long.contains("[timeout:30]"))

        val single = OverpassQuery.featuresAlong(listOf(GeoPoint(41.31, 69.28)))
        assertTrue(single.contains("node(around:35,41.310000,69.280000)[traffic_calming];"))

        val empty = OverpassQuery.featuresAlong(emptyList())
        assertFalse(empty.contains("around"))
        assertTrue(empty.endsWith("out;"))
    }

    @Test fun formBodyStrictPercentEncoding() {
        val body = OverpassQuery.formBody("a b&c=d/é~._-+;\"")
        assertEquals("data=a%20b%26c%3Dd%2F%C3%A9~._-%2B%3B%22", String(body, Charsets.UTF_8))

        val query = OverpassQuery.roadsAround(GeoPoint(41.3111, 69.2797))
        val encoded = String(OverpassQuery.formBody(query), Charsets.UTF_8)
        assertTrue(encoded.startsWith("data="))
        val payload = encoded.drop(5)
        val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%".toSet()
        assertTrue(payload.all { allowed.contains(it) })
        // URLDecoder treats '+' as space; the strict encoder never emits a raw '+'.
        assertEquals(query, URLDecoder.decode(payload, "UTF-8"))
    }

    // Max speed

    @Test fun maxSpeedParser() {
        assertEquals(SpeedLimit(60, "60", false), MaxSpeedParser.parse("60"))
        assertEquals(60, MaxSpeedParser.parse("60 km/h")?.kmh)
        assertEquals(80, MaxSpeedParser.parse("50 mph")?.kmh)
        assertEquals(80, MaxSpeedParser.parse("50mph")?.kmh)
        assertEquals(19, MaxSpeedParser.parse("10 knots")?.kmh)
        assertEquals(SpeedLimit(60, "RU:urban", true), MaxSpeedParser.parse("RU:urban"))
        assertEquals(90, MaxSpeedParser.parse("RU:rural")?.kmh)
        assertEquals(20, MaxSpeedParser.parse("RU:living_street")?.kmh)
        assertEquals(110, MaxSpeedParser.parse("RU:motorway")?.kmh)
        assertEquals(70, MaxSpeedParser.parse("UZ:urban")?.kmh)
        assertEquals(100, MaxSpeedParser.parse("UZ:rural")?.kmh)
        assertEquals(30, MaxSpeedParser.parse("UZ:living_street")?.kmh)
        assertEquals(110, MaxSpeedParser.parse("UZ:motorway")?.kmh)
        assertEquals(70, MaxSpeedParser.parse("uz:urban")?.kmh)
        assertEquals(SpeedLimit(30, "RU:zone30", true), MaxSpeedParser.parse("RU:zone30"))
        assertEquals(SpeedLimit(5, "walk", true), MaxSpeedParser.parse("walk"))
        assertEquals(40, MaxSpeedParser.parse("60;40")?.kmh)
        assertEquals("70", MaxSpeedParser.parse(" 70 ")?.raw)
        assertNull(MaxSpeedParser.parse("none"))
        assertNull(MaxSpeedParser.parse("signals"))
        assertNull(MaxSpeedParser.parse("XX:urban"))
        assertNull(MaxSpeedParser.parse("fast"))
        assertNull(MaxSpeedParser.parse("0"))
        assertNull(MaxSpeedParser.parse("60 furlongs"))
        assertNull(MaxSpeedParser.parse(""))
        assertNull(MaxSpeedParser.parse(null))
    }

    @Test fun directionalSpeedLimit() {
        val tags = mapOf("maxspeed" to "60", "maxspeed:forward" to "70", "maxspeed:backward" to "50")
        assertEquals(70, MaxSpeedParser.limit(tags, true)?.kmh)
        assertEquals(50, MaxSpeedParser.limit(tags, false)?.kmh)
        assertEquals(60, MaxSpeedParser.limit(mapOf("maxspeed" to "60", "maxspeed:forward" to "70"), false)?.kmh)
        assertEquals(SpeedLimit(70, "UZ:urban", true), MaxSpeedParser.limit(mapOf("source:maxspeed" to "UZ:urban"), true))
        assertEquals(90, MaxSpeedParser.limit(mapOf("maxspeed:type" to "RU:rural"), true)?.kmh)
        assertNull(MaxSpeedParser.limit(mapOf("source:maxspeed" to "sign"), true))
        assertNull(MaxSpeedParser.limit(mapOf("maxspeed" to "none"), true))
        assertNull(MaxSpeedParser.limit(emptyMap(), true))
    }

    // Lanes

    private fun lane(vararg t: LaneTurn) = Lane(t.toList())

    @Test fun parseTurnLanes() {
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH, LaneTurn.RIGHT), lane(LaneTurn.RIGHT)),
            OSMRoadParser.parseTurnLanes("left|through;right|right"))
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.NONE), lane(LaneTurn.RIGHT)), OSMRoadParser.parseTurnLanes("left||right"))
        assertEquals(listOf(lane(LaneTurn.SLIGHT_LEFT), lane(LaneTurn.THROUGH), lane(LaneTurn.SLIGHT_RIGHT)),
            OSMRoadParser.parseTurnLanes("slide_left|through|slide_right"))
        assertEquals(listOf(lane(LaneTurn.THROUGH), lane(LaneTurn.NONE)), OSMRoadParser.parseTurnLanes("none;through|none"))
        assertEquals(listOf(lane(LaneTurn.MERGE_TO_LEFT), lane(LaneTurn.REVERSE, LaneTurn.LEFT), lane(LaneTurn.SHARP_RIGHT, LaneTurn.SLIGHT_RIGHT)),
            OSMRoadParser.parseTurnLanes("merge_to_left|reverse;left|sharp_right;slight_right"))
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH)), OSMRoadParser.parseTurnLanes("LEFT| Through ;through"))
        assertEquals(listOf(lane(), lane(LaneTurn.LEFT)), OSMRoadParser.parseTurnLanes("foo|left"))
        assertEquals(emptyList<Lane>(), OSMRoadParser.parseTurnLanes(""))
        assertEquals(emptyList<Lane>(), OSMRoadParser.parseTurnLanes("   "))
    }

    @Test fun onewayDirection() {
        for (value in listOf("yes", "true", "1", "YES")) assertEquals(value, 1, OSMRoadParser.onewayDirection(mapOf("oneway" to value)))
        assertEquals(-1, OSMRoadParser.onewayDirection(mapOf("oneway" to "-1")))
        assertEquals(-1, OSMRoadParser.onewayDirection(mapOf("oneway" to "reverse")))
        for (value in listOf("no", "false", "0", "reversible", "alternating")) {
            assertEquals(value, 0, OSMRoadParser.onewayDirection(mapOf("oneway" to value)))
        }
        assertEquals(0, OSMRoadParser.onewayDirection(emptyMap()))
        assertEquals(0, OSMRoadParser.onewayDirection(mapOf("highway" to "primary")))
        assertEquals(1, OSMRoadParser.onewayDirection(mapOf("highway" to "motorway")))
        assertEquals(1, OSMRoadParser.onewayDirection(mapOf("highway" to "motorway_link")))
        assertEquals(0, OSMRoadParser.onewayDirection(mapOf("highway" to "motorway", "oneway" to "no")))
        assertEquals(1, OSMRoadParser.onewayDirection(mapOf("highway" to "primary", "junction" to "roundabout")))
        assertEquals(1, OSMRoadParser.onewayDirection(mapOf("highway" to "primary", "junction" to "circular")))
        assertEquals(0, OSMRoadParser.onewayDirection(mapOf("oneway" to "yes", "oneway:motor_vehicle" to "no")))
        assertEquals(1, OSMRoadParser.onewayDirection(mapOf("oneway" to "yes", "oneway:bicycle" to "no")))
    }

    @Test fun laneInfoTwoWayWithDirectionalTags() {
        val tags = mapOf("highway" to "primary", "lanes" to "6", "lanes:forward" to "3", "lanes:backward" to "3",
            "turn:lanes:forward" to "left|through|through;right", "turn:lanes:backward" to "left|through|right")
        val forward = OSMRoadParser.laneInfo(tags, true)
        assertEquals(6, forward.totalLanes)
        assertEquals(3, forward.lanesInDirection)
        assertEquals(3, forward.lanesOpposite)
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH), lane(LaneTurn.THROUGH, LaneTurn.RIGHT)), forward.lanes)
        assertFalse(forward.isOneway)
        assertFalse(forward.isEstimated)

        val backward = OSMRoadParser.laneInfo(tags, false)
        assertEquals(":backward lanes are already listed left→right from the driver's view",
            listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH), lane(LaneTurn.RIGHT)), backward.lanes)
    }

    @Test fun laneInfoTwoWaySplits() {
        fun info(tags: Map<String, String>, forward: Boolean = true) = OSMRoadParser.laneInfo(tags, forward)
        // Even split.
        val four = info(mapOf("highway" to "secondary", "lanes" to "4"))
        assertEquals(listOf(4, 2, 2), listOf(four.totalLanes, four.lanesInDirection, four.lanesOpposite))
        assertEquals(emptyList<Lane>(), four.lanes)
        assertFalse(four.isEstimated)
        // Remainder after the known direction.
        val five = info(mapOf("highway" to "primary", "lanes" to "5", "lanes:forward" to "3"), forward = false)
        assertEquals(listOf(2, 3), listOf(five.lanesInDirection, five.lanesOpposite))
        // Centre turn lane is in the total but in neither direction.
        val centre = info(mapOf("highway" to "primary", "lanes" to "5", "lanes:both_ways" to "1"))
        assertEquals(listOf(5, 2, 2), listOf(centre.totalLanes, centre.lanesInDirection, centre.lanesOpposite))
        // Odd total without a split: per-direction counts unknown.
        val three = info(mapOf("highway" to "tertiary", "lanes" to "3"))
        assertEquals(3, three.totalLanes)
        assertNull(three.lanesInDirection)
        assertNull(three.lanesOpposite)
        // One lane shared by both directions.
        val one = info(mapOf("highway" to "residential", "lanes" to "1"))
        assertEquals(listOf(1, 1, 1), listOf(one.totalLanes, one.lanesInDirection, one.lanesOpposite))
        // Directional counts without a total.
        val split = info(mapOf("highway" to "primary", "lanes:forward" to "2", "lanes:backward" to "1"), forward = false)
        assertEquals(listOf(3, 1, 2), listOf(split.totalLanes, split.lanesInDirection, split.lanesOpposite))
        assertFalse(split.isEstimated)
        // Counts from turn:lanes when lanes is missing.
        val turns = info(mapOf("highway" to "primary", "turn:lanes:forward" to "left|through|through", "turn:lanes:backward" to "through|right"))
        assertEquals(listOf(5, 3, 2), listOf(turns.totalLanes, turns.lanesInDirection, turns.lanesOpposite))
        assertEquals(3, turns.lanes.size)
        assertFalse(turns.isEstimated)
        val halfKnown = info(mapOf("highway" to "primary", "turn:lanes:forward" to "left|through"))
        assertEquals(2, halfKnown.lanesInDirection)
        assertNull(halfKnown.lanesOpposite)
        assertNull(halfKnown.totalLanes)
        // turn:lanes without suffix is ignored on two-way roads.
        assertEquals(emptyList<Lane>(), info(mapOf("highway" to "secondary", "lanes" to "4", "turn:lanes" to "left|through")).lanes)
    }

    @Test fun laneInfoEstimatedFromRoadClass() {
        val primary = OSMRoadParser.laneInfo(mapOf("highway" to "primary"), true)
        assertTrue(primary.isEstimated)
        assertEquals(listOf(2, 1, 1), listOf(primary.totalLanes, primary.lanesInDirection, primary.lanesOpposite))

        val unclassified = OSMRoadParser.laneInfo(mapOf("highway" to "unclassified"), false)
        assertTrue(unclassified.isEstimated)
        assertEquals(listOf(1, 1, 1), listOf(unclassified.totalLanes, unclassified.lanesInDirection, unclassified.lanesOpposite))

        val garbage = OSMRoadParser.laneInfo(mapOf("highway" to "residential", "lanes" to "many"), true)
        assertTrue(garbage.isEstimated)
        assertEquals(2, garbage.totalLanes)

        val unknown = OSMRoadParser.laneInfo(mapOf("highway" to "road"), true)
        assertNull(unknown.totalLanes)
        assertNull(unknown.lanesInDirection)
        assertFalse(unknown.isEstimated)
    }

    @Test fun laneInfoOneway() {
        val tags = mapOf("highway" to "secondary", "oneway" to "yes", "lanes" to "3", "turn:lanes" to "left|through|through;right")
        val legal = OSMRoadParser.laneInfo(tags, true)
        assertTrue(legal.isOneway)
        assertEquals(listOf(3, 3, 0), listOf(legal.totalLanes, legal.lanesInDirection, legal.lanesOpposite))
        assertEquals(3, legal.lanes.size)
        assertFalse(legal.isEstimated)

        val against = OSMRoadParser.laneInfo(tags, false)
        assertTrue(against.isOneway)
        assertEquals(listOf(3, 0), listOf(against.lanesInDirection, against.lanesOpposite))
        assertEquals("turn arrows do not apply when travelling against a one-way road", emptyList<Lane>(), against.lanes)

        val reversed = mapOf("highway" to "tertiary", "oneway" to "-1", "lanes" to "2", "turn:lanes:backward" to "left|through")
        val reversedLegal = OSMRoadParser.laneInfo(reversed, false)
        assertEquals(listOf(2, 0), listOf(reversedLegal.lanesInDirection, reversedLegal.lanesOpposite))
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH)), reversedLegal.lanes)

        val motorway = OSMRoadParser.laneInfo(mapOf("highway" to "motorway"), true)
        assertTrue(motorway.isOneway)
        assertTrue(motorway.isEstimated)
        assertEquals(listOf(2, 0), listOf(motorway.lanesInDirection, motorway.lanesOpposite))

        val fromTurns = OSMRoadParser.laneInfo(mapOf("highway" to "primary", "oneway" to "yes", "turn:lanes" to "left|through|right"), true)
        assertEquals(3, fromTurns.lanesInDirection)
        assertFalse(fromTurns.isEstimated)

        val roundabout = OSMRoadParser.laneInfo(mapOf("highway" to "primary", "junction" to "roundabout", "lanes" to "3"), true)
        assertTrue(roundabout.isOneway)
        assertEquals(3, roundabout.lanesInDirection)

        val estimated = OSMRoadParser.laneInfo(mapOf("highway" to "secondary", "oneway" to "yes"), true)
        assertTrue(estimated.isEstimated)
        assertEquals(1, estimated.lanesInDirection)
    }

    @Test fun defaultLaneCountsAndDisplayNames() {
        assertEquals(2, OSMRoadParser.defaultLaneCount("primary", false))
        assertEquals(1, OSMRoadParser.defaultLaneCount("primary", true))
        assertEquals(2, OSMRoadParser.defaultLaneCount("residential", false))
        assertEquals(2, OSMRoadParser.defaultLaneCount("motorway", true))
        assertEquals(2, OSMRoadParser.defaultLaneCount("trunk", false))
        assertEquals(1, OSMRoadParser.defaultLaneCount("service", false))
        assertEquals(1, OSMRoadParser.defaultLaneCount("track", true))
        assertEquals(1, OSMRoadParser.defaultLaneCount("primary_link", true))
        assertEquals(2, OSMRoadParser.defaultLaneCount("PRIMARY", false))
        assertNull(OSMRoadParser.defaultLaneCount("footway", false))

        assertEquals("Автомагистраль", OSMRoadParser.highwayDisplayName("motorway"))
        assertEquals("Магистраль", OSMRoadParser.highwayDisplayName("trunk"))
        assertEquals("Главная дорога", OSMRoadParser.highwayDisplayName("primary"))
        assertEquals("Жилая улица", OSMRoadParser.highwayDisplayName("residential"))
        assertEquals("Жилая зона", OSMRoadParser.highwayDisplayName("living_street"))
        assertEquals("Проезд", OSMRoadParser.highwayDisplayName("service"))
        assertEquals("Местная дорога", OSMRoadParser.highwayDisplayName("unclassified"))
        assertEquals("Съезд", OSMRoadParser.highwayDisplayName("trunk_link"))
        assertEquals("Съезд", OSMRoadParser.highwayDisplayName("motorway_link"))
        assertEquals("Дорога", OSMRoadParser.highwayDisplayName("something_new"))
        val classes = listOf("motorway", "trunk", "primary", "secondary", "tertiary", "residential", "living_street",
            "service", "unclassified", "track")
        assertEquals("class names are distinct", classes.size, classes.map(OSMRoadParser::highwayDisplayName).toSet().size)
    }

    // Road matcher on the Tashkent fixture

    @Test fun matcherOnTashkentFixture() {
        val elements = OverpassQuery.decode(RoadFixture.data("overpass_roads_tashkent"))

        val north = RoadMatcher.bestMatch(elements, xy(121.0, 200.0), 2.0)!!
        assertEquals(23710011L, north.wayID)
        assertEquals("проспект Амира Темура", north.name)
        assertEquals("проспект Амира Темура", north.displayName)
        assertTrue(north.travelingForward)
        assertEquals(3, north.laneInfo.lanesInDirection)
        assertEquals(6, north.laneInfo.totalLanes)
        assertEquals(3, north.laneInfo.lanes.size)
        assertEquals(SpeedLimit(70, "70", false), north.speedLimit)
        assertEquals(true, north.lit)
        assertEquals("asphalt", north.surface)
        assertEquals("Асфальт", north.surfaceDisplayName)
        assertEquals("Главная дорога", north.roadClassName)
        assertTrue(north.distanceToRoad < 3)

        val south = RoadMatcher.bestMatch(elements, xy(121.0, 200.0), 182.0)!!
        assertEquals(23710011L, south.wayID)
        assertFalse(south.travelingForward)
        assertEquals(listOf(lane(LaneTurn.LEFT), lane(LaneTurn.THROUGH), lane(LaneTurn.RIGHT)), south.laneInfo.lanes)

        val nearest = RoadMatcher.bestMatch(elements, xy(121.0, 200.0), null)!!
        assertEquals(23710011L, nearest.wayID)

        val oneway = RoadMatcher.bestMatch(elements, xy(-50.0, 204.0), 91.0)!!
        assertEquals(48210044L, oneway.wayID)
        assertEquals("проспект Мустакиллик", oneway.name)
        assertTrue(oneway.laneInfo.isOneway)
        assertEquals(listOf(3, 0), listOf(oneway.laneInfo.lanesInDirection, oneway.laneInfo.lanesOpposite))
        assertEquals(60, oneway.speedLimit?.kmh)

        // oneway=-1: legal travel is against the drawing direction (southwards).
        val reversed = RoadMatcher.bestMatch(elements, xy(-148.5, 0.0), 180.0)!!
        assertEquals(48210055L, reversed.wayID)
        assertFalse(reversed.travelingForward)
        assertEquals(SpeedLimit(70, "UZ:urban", true), reversed.speedLimit)
        assertEquals(2, reversed.laneInfo.lanesInDirection)

        val residential = RoadMatcher.bestMatch(elements, xy(-50.0, -148.0), 270.0)!!
        assertEquals(48210033L, residential.wayID)
        assertEquals("no name:ru → original name", "Shahrisabz tor ko‘chasi", residential.displayName)
        assertTrue(residential.travelingForward)
        assertTrue(residential.laneInfo.isEstimated)
        assertEquals(1, residential.laneInfo.lanesInDirection)
        assertNull(residential.speedLimit)
        assertNull(residential.lit)

        val ring = RoadMatcher.bestMatch(elements, xy(90.0, 0.0), 0.0)!!
        assertEquals(23710022L, ring.wayID)
        assertTrue(ring.laneInfo.isOneway)
        assertTrue(ring.travelingForward)
        assertEquals(true, ring.speedLimit?.isImplicit)

        val parking = RoadMatcher.bestMatch(elements, xy(60.0, -58.0), 90.0)!!
        assertEquals(48210066L, parking.wayID)
        assertEquals("Проезд", parking.displayName)
        assertEquals("Брусчатка", parking.surfaceDisplayName)

        assertNull(RoadMatcher.bestMatch(elements, xy(600.0, 600.0), 0.0))
        assertNull(RoadMatcher.bestMatch(elements, xy(-50.0, -120.0), 270.0, maxDistance = 20.0))
    }

    // Road matcher, synthetic cases

    private fun line(id: Long, from: Pair<Double, Double>, to: Pair<Double, Double>, tags: Map<String, String>) =
        OSMElement(OSMElement.ElementType.WAY, id, geometry = listOf(xy(from.first, from.second), xy(to.first, to.second)), tags = tags)

    @Test fun matcherUsesHeadingAtIntersection() {
        val northSouth = line(1, 0.0 to -200.0, 0.0 to 200.0, mapOf("highway" to "primary"))
        val eastWest = line(2, -200.0 to 0.0, 200.0 to 0.0, mapOf("highway" to "residential"))
        val elements = listOf(northSouth, eastWest)
        val p = xy(3.0, 6.0)   // 3 m from the primary, 6 m from the residential street
        assertEquals(2L, RoadMatcher.bestMatch(elements, p, 90.0)?.wayID)
        assertEquals(2L, RoadMatcher.bestMatch(elements, p, 270.0)?.wayID)
        assertEquals(1L, RoadMatcher.bestMatch(elements, p, 1.0)?.wayID)
        assertEquals(1L, RoadMatcher.bestMatch(elements, p, null)?.wayID)
        assertEquals("invalid heading → nearest", 1L, RoadMatcher.bestMatch(elements, p, -1.0)?.wayID)
        assertEquals(false, RoadMatcher.bestMatch(elements, p, 270.0)?.travelingForward)
    }

    @Test fun matcherPicksCarriagewayOfTravelDirection() {
        val northbound = line(10, -8.0 to -200.0, -8.0 to 200.0, mapOf("highway" to "trunk", "oneway" to "yes"))
        val southbound = line(11, 8.0 to 200.0, 8.0 to -200.0, mapOf("highway" to "trunk", "oneway" to "yes"))
        val p = xy(2.0, 0.0)   // closer to the southbound carriageway
        val match = RoadMatcher.bestMatch(listOf(northbound, southbound), p, 0.0)!!
        assertEquals(10L, match.wayID)
        assertTrue(match.travelingForward)
        assertEquals(11L, RoadMatcher.bestMatch(listOf(northbound, southbound), p, 180.0)?.wayID)

        // Only the wrong carriageway nearby: still matched (no crash), travelling against it.
        val against = RoadMatcher.bestMatch(listOf(southbound), p, 0.0)!!
        assertFalse(against.travelingForward)
        assertEquals(emptyList<Lane>(), against.laneInfo.lanes)

        // Without heading a oneway=-1 road is assumed to be travelled legally.
        val reversed = line(12, 0.0 to -100.0, 0.0 to 100.0, mapOf("highway" to "tertiary", "oneway" to "-1"))
        assertEquals(false, RoadMatcher.bestMatch(listOf(reversed), xy(1.0, 0.0), null)?.travelingForward)
    }

    @Test fun matcherFiltersAndTieBreaks() {
        val footway = line(20, 1.0 to -100.0, 1.0 to 100.0, mapOf("highway" to "footway"))
        val pedestrianArea = line(21, 2.0 to -100.0, 2.0 to 100.0, mapOf("highway" to "service", "area" to "yes"))
        val road = line(22, 10.0 to -100.0, 10.0 to 100.0, mapOf("highway" to "residential"))
        val node = OSMElement(OSMElement.ElementType.NODE, 23, lat = TashkentFrame.origin.latitude, lon = TashkentFrame.origin.longitude,
            tags = mapOf("highway" to "traffic_signals"))
        val noGeometry = OSMElement(OSMElement.ElementType.WAY, 24, tags = mapOf("highway" to "primary"))
        val onePoint = OSMElement(OSMElement.ElementType.WAY, 25, geometry = listOf(TashkentFrame.origin), tags = mapOf("highway" to "primary"))
        val elements = listOf(footway, pedestrianArea, road, node, noGeometry, onePoint)
        assertEquals(22L, RoadMatcher.bestMatch(elements, TashkentFrame.origin, 0.0)?.wayID)

        val service = line(30, -5.0 to -100.0, -5.0 to 100.0, mapOf("highway" to "service"))
        val primary = line(31, 5.0 to -100.0, 5.0 to 100.0, mapOf("highway" to "primary"))
        assertEquals("equal distance → the higher road class wins", 31L,
            RoadMatcher.bestMatch(listOf(service, primary), TashkentFrame.origin, null)?.wayID)

        assertNull(RoadMatcher.bestMatch(emptyList(), TashkentFrame.origin, 0.0))
        assertNull(RoadMatcher.bestMatch(listOf(road), GeoPoint(Double.NaN, 69.0), 0.0))
        assertEquals(true, RoadMatcher.litValue("24/7"))
        assertEquals(false, RoadMatcher.litValue("no"))
        assertNull(RoadMatcher.litValue("maybe"))
    }

    @Test fun roadSegmentDisplayNameFallbacks() {
        var info = RoadSegmentInfo(1, null, "4Р12", "trunk", LaneInfo.unknown, null, null, null, true, 2.0, emptyMap())
        assertEquals("4Р12", info.displayName)
        info = info.copy(ref = null)
        assertEquals("Магистраль", info.displayName)
        info = info.copy(name = "")
        assertEquals("Магистраль", info.displayName)
        info = info.copy(name = "Kichik halqa yo‘li")
        assertEquals("Kichik halqa yo‘li", info.displayName)
        assertNull(info.surfaceDisplayName)
    }
}
