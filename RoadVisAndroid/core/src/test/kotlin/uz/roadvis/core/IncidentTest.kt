package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.abs

class IncidentTest {
    private val route = listOf(GeoPoint(41.3100, 69.2800), GeoPoint(41.3150, 69.2800), GeoPoint(41.3150, 69.2900))
    private val now = Date(1_795_000_000_000L)

    private fun ago(seconds: Double) = Date(now.time - (seconds * 1000).toLong())

    private fun point(along: Double, offsetEast: Double = 0.0): GeoPoint {
        val p = Geo.pointAtDistance(along, route)!!
        return if (offsetEast == 0.0) p else Geo.destination(p, if (offsetEast > 0) 90.0 else 270.0, abs(offsetEast))
    }

    @Test fun kindPresentation() {
        assertEquals("ДТП", RoadIncidentKind.ACCIDENT.displayName)
        assertEquals("Дорожные работы", RoadIncidentKind.ROAD_WORK.displayName)
        assertEquals("Пробка", RoadIncidentKind.JAM.displayName)
        assertEquals("Полиция / пост ДПС", RoadIncidentKind.POLICE.displayName)
        assertEquals("Яма", RoadIncidentKind.POTHOLE.displayName)
        assertEquals("Опасность", RoadIncidentKind.HAZARD.displayName)
        assertEquals("Перекрытие", RoadIncidentKind.CLOSURE.displayName)
        assertEquals("Камера", RoadIncidentKind.SPEED_CAMERA.displayName)
        assertEquals("camera.fill", RoadIncidentKind.SPEED_CAMERA.symbolName)
        assertEquals("speedCamera", RoadIncidentKind.SPEED_CAMERA.raw)
        val symbols = RoadIncidentKind.entries.map { it.symbolName }
        assertEquals("each kind has its own symbol", symbols.size, symbols.toSet().size)
        assertFalse(symbols.contains(""))
    }

    @Test fun incidentCodableRoundTrip() {
        val incident = RoadIncident(kind = RoadIncidentKind.POTHOLE, coordinate = GeoPoint(41.31, 69.28),
            date = Date(1_790_000_000_000L), note = "Глубокая яма в правом ряду")
        val data = RoadIncident.encodeList(listOf(incident))
        val decoded = RoadIncident.decodeList(data)
        assertEquals(listOf(incident), decoded)
        assertNull(RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.0, 69.0)).note)
        assertNotEquals(RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.0, 69.0)).id,
            RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.0, 69.0)).id)
    }

    @Test fun activeFilter() {
        val fresh = RoadIncident(kind = RoadIncidentKind.ACCIDENT, coordinate = GeoPoint(41.31, 69.28), date = ago(3600.0))
        val old = RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.31, 69.28), date = ago(3 * 3600.0))
        val boundary = RoadIncident(kind = RoadIncidentKind.POLICE, coordinate = GeoPoint(41.31, 69.28), date = ago(2 * 3600.0))
        val future = RoadIncident(kind = RoadIncidentKind.HAZARD, coordinate = GeoPoint(41.31, 69.28), date = ago(-600.0))
        val active = IncidentFilter.active(listOf(old, fresh, boundary, future), now, 2 * 3600.0)
        assertEquals("newest first; exactly lifetime old = expired", listOf(future.id, fresh.id), active.map { it.id })
        assertEquals(emptyList<RoadIncident>(), IncidentFilter.active(listOf(fresh), now, 0.0))
        assertEquals(emptyList<RoadIncident>(), IncidentFilter.active(emptyList(), now, 3600.0))
    }

    @Test fun cameraMarksArePermanent() {
        assertEquals(listOf(RoadIncidentKind.SPEED_CAMERA), RoadIncidentKind.entries.filter { it.isPermanent })
        assertEquals(500.0, RoadIncidentKind.SPEED_CAMERA.alertDistance, 0.0)
        assertEquals(RouteFeatureKind.SPEED_CAMERA.alertDistance, RoadIncidentKind.SPEED_CAMERA.alertDistance, 0.0)
        assertEquals(700.0, RoadIncidentKind.JAM.alertDistance, 0.0)
        assertTrue(RouteTimelineKind.Incident(RoadIncidentKind.SPEED_CAMERA).isSpeedCamera)
        assertTrue(RouteTimelineKind.Feature(RouteFeatureKind.SPEED_CAMERA).isSpeedCamera)
        assertFalse(RouteTimelineKind.Incident(RoadIncidentKind.POLICE).isSpeedCamera)

        val oldCamera = RoadIncident(kind = RoadIncidentKind.SPEED_CAMERA, coordinate = GeoPoint(41.31, 69.28), date = ago(90 * 86_400.0))
        val freshCamera = RoadIncident(kind = RoadIncidentKind.SPEED_CAMERA, coordinate = GeoPoint(41.32, 69.28), date = ago(60.0))
        val oldJam = RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.31, 69.28), date = ago(3 * 3600.0))
        val freshJam = RoadIncident(kind = RoadIncidentKind.JAM, coordinate = GeoPoint(41.31, 69.29), date = ago(600.0))
        val all = listOf(oldCamera, oldJam, freshJam, freshCamera)
        assertEquals("cameras never expire, other kinds keep the lifetime",
            listOf(freshCamera.id, freshJam.id, oldCamera.id), IncidentFilter.active(all, now, 2 * 3600.0).map { it.id })
        assertEquals(listOf(freshCamera.id, oldCamera.id), IncidentFilter.active(all, now, 0.0).map { it.id })
        assertEquals(listOf(freshCamera.id, oldCamera.id), IncidentFilter.active(all, now, Double.NaN).map { it.id })
    }

    @Test fun decodesFilesOfOlderVersions() {
        // incidents.json as written by iOS before the camera kind existed.
        val json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"police","coordinate":{"latitude":41.31,"longitude":69.28},        "date":800000000,"note":"Пост"},        {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"roadWork","coordinate":{"latitude":41.3,"longitude":69.2},        "date":800000100}]
        """
        val decoded = RoadIncident.decodeList(json)
        assertEquals(listOf(RoadIncidentKind.POLICE, RoadIncidentKind.ROAD_WORK), decoded.map { it.kind })
        assertEquals("Пост", decoded[0].note)
        assertNull(decoded[1].note)

        val camera = RoadIncident(kind = RoadIncidentKind.SPEED_CAMERA, coordinate = GeoPoint(41.31, 69.28), date = now)
        val data = RoadIncident.encodeList(listOf(camera))
        assertTrue(data.contains("\"speedCamera\""))
        assertEquals(listOf(camera), RoadIncident.decodeList(data))
    }

    @Test fun wazeLink() {
        assertEquals("https://waze.com/ul?ll=41.311081,69.240562&navigate=yes", ExternalNavigation.wazeURL(GeoPoint(41.311081, 69.240562)))
        assertEquals("https://waze.com/ul?ll=-33.868800,-151.209300&navigate=yes", ExternalNavigation.wazeURL(GeoPoint(-33.8688, -151.2093)))
        assertNull(ExternalNavigation.wazeURL(GeoPoint(Double.NaN, 69.0)))
        assertNull(ExternalNavigation.wazeURL(GeoPoint(95.0, 69.0)))
    }

    @Test fun alongRoute() {
        val near = RoadIncident(kind = RoadIncidentKind.ACCIDENT, coordinate = point(300.0, 10.0), date = now)
        val edge = RoadIncident(kind = RoadIncidentKind.ROAD_WORK, coordinate = point(100.0, -45.0), date = now)
        val far = RoadIncident(kind = RoadIncidentKind.JAM, coordinate = point(200.0, 80.0), date = now)
        val onSecondLeg = RoadIncident(kind = RoadIncidentKind.CLOSURE, coordinate = point(900.0), date = now)
        val invalid = RoadIncident(kind = RoadIncidentKind.HAZARD, coordinate = GeoPoint(Double.NaN, Double.NaN), date = now)
        val result = IncidentFilter.along(route, null, listOf(onSecondLeg, far, near, edge, invalid))
        assertEquals(listOf(edge.id, near.id, onSecondLeg.id), result.map { it.id })
        assertEquals(100.0, result[0].distanceAlongRoute, 2.0)
        assertEquals(45.0, result[0].offsetFromRoute, 1.0)
        assertEquals(300.0, result[1].distanceAlongRoute, 2.0)
        assertEquals(900.0, result[2].distanceAlongRoute, 2.0)
        assertEquals(near, result[1].incident)

        val strict = IncidentFilter.along(route, Geo.cumulativeDistances(route), listOf(near, edge), maxOffset = 20.0)
        assertEquals(listOf(near.id), strict.map { it.id })
        val ignoredCumulative = IncidentFilter.along(route, listOf(0.0), listOf(near))
        assertEquals(300.0, ignoredCumulative.firstOrNull()?.distanceAlongRoute ?: 0.0, 2.0)
        assertEquals(emptyList<IncidentOnRoute>(), IncidentFilter.along(emptyList(), null, listOf(near)))
    }
}

class TrafficDelayTest {
    @Test fun assessmentLevels() {
        fun level(current: Double, free: Double = 600.0) = TrafficAssessment(current, free).level
        assertEquals(CongestionLevel.FREE, level(600.0))
        assertEquals(CongestionLevel.FREE, level(659.0))
        assertEquals(CongestionLevel.LIGHT, level(660.0))       // ratio 1.1
        assertEquals(CongestionLevel.LIGHT, level(749.0))
        assertEquals(CongestionLevel.MODERATE, level(750.0))    // 1.25
        assertEquals(CongestionLevel.MODERATE, level(899.0))
        assertEquals(CongestionLevel.HEAVY, level(900.0))       // 1.5
        assertEquals(CongestionLevel.HEAVY, level(1199.0))
        assertEquals(CongestionLevel.SEVERE, level(1200.0))     // 2.0
        assertEquals("faster than free flow", CongestionLevel.FREE, level(500.0))
        assertEquals("unknown free-flow time", CongestionLevel.FREE, level(900.0, 0.0))
    }

    @Test fun delayAndRatio() {
        val a = TrafficAssessment(1020.0, 600.0)
        assertEquals(420.0, a.delaySeconds, 0.0)
        assertEquals(1.7, a.ratio, 1e-9)
        assertEquals(CongestionLevel.HEAVY, a.level)
        assertTrue(a.summary.contains("≈"))
        assertTrue(a.summary.contains("оценка"))
        assertTrue(a.summary.contains("7 мин"))
        assertEquals(0.0, TrafficAssessment(500.0, 600.0).delaySeconds, 0.0)
        assertEquals("Свободно (оценка)", TrafficAssessment(600.0, 600.0).summary)
        val broken = TrafficAssessment(Double.NaN, 600.0)
        assertEquals(0.0, broken.delaySeconds, 0.0)
        assertEquals(1.0, broken.ratio, 0.0)
    }

    @Test fun congestionLevelPresentation() {
        val names = CongestionLevel.entries.map { it.displayName }
        assertEquals(names.size, names.toSet().size)
        assertEquals("Свободно", CongestionLevel.FREE.displayName)
        assertEquals(listOf(0, 1, 2, 3, 4), CongestionLevel.entries.map { it.severity })
    }

    @Test fun nextOffPeakDate() {
        val tz = TimeZone.getTimeZone("Asia/Tashkent")
        fun date(day: Int, hour: Int, minute: Int = 0, second: Int = 0, month: Int = 11): Date =
            GregorianCalendar(tz).apply { clear(); set(2026, month - 1, day, hour, minute, second) }.time
        assertEquals(date(26, 3), TrafficDelay.nextOffPeakDate(date(25, 14, 35), tz))
        assertEquals(date(25, 3), TrafficDelay.nextOffPeakDate(date(25, 2, 10), tz))
        assertEquals("strictly after", date(26, 3), TrafficDelay.nextOffPeakDate(date(25, 3), tz))
        assertEquals(date(26, 3), TrafficDelay.nextOffPeakDate(date(25, 3, 0, 1), tz))
        assertEquals(date(26, 5), TrafficDelay.nextOffPeakDate(date(25, 14), tz, hour = 5))
        assertEquals(date(25, 23), TrafficDelay.nextOffPeakDate(date(25, 14), tz, hour = 30))
        // Month / year rollover.
        assertEquals(date(1, 3, month = 12), TrafficDelay.nextOffPeakDate(date(30, 22), tz))

        // DST change day (Europe/Berlin, 2026-03-29: 02:00 → 03:00): the result is still in the future and within a day.
        val berlin = TimeZone.getTimeZone("Europe/Berlin")
        val early = GregorianCalendar(berlin).apply { clear(); set(2026, 2, 29, 0, 30, 0) }.time
        val next = TrafficDelay.nextOffPeakDate(early, berlin, hour = 2)
        assertTrue(next.after(early))
        assertTrue(next.time - early.time <= 26 * 3600 * 1000L)
    }
}
