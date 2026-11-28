package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class CabinetTest {
    private val t0 = 1_795_852_800_000L // 2026-11-28T08:00:00Z
    private fun at(seconds: Double): Long = t0 + Math.round(seconds * 1000)

    /** Straight track northwards at a constant speed, one point per second. */
    private fun straightTrip(seconds: Int, speedKmh: Double, limit: Int? = 60): Trip {
        val points = mutableListOf<TripPoint>()
        var position = GeoPoint(41.31, 69.28)
        for (i in 0..seconds) {
            points.add(TripPoint(at(i.toDouble()), position, speedKmh = speedKmh, speedLimitKmh = limit, horizontalAccuracy = 5.0))
            position = Geo.destination(position, 0.0, speedKmh / 3.6)
        }
        return Trip(startedAtMillis = t0, endedAtMillis = at(seconds.toDouble()), points = points)
    }

    // CabinetTripPayload

    @Test fun payloadHasContractKeys() {
        val trip = straightTrip(600, 54.0)
        trip.origin = TripEndpoint("Yunusobod", GeoPoint(41.31, 69.28))
        trip.destination = TripEndpoint("TDTU", GeoPoint(41.36, 69.28))
        trip.arrived = true
        trip.startedWithNavigation = true
        trip.events = listOf(
            DrivingEvent(kind = DrivingEventKind.TAILGATING, severity = DrivingEventSeverity.WARNING, dateMillis = at(300.0),
                coordinate = GeoPoint(41.33, 69.28), speedKmh = 45.0, value = 6.5, limit = 25.0, duration = 4.0),
            DrivingEvent(kind = DrivingEventKind.SPEEDING, severity = DrivingEventSeverity.VIOLATION, dateMillis = at(100.0)),
        )
        val o = CabinetTripPayload.build(trip, appVersion = "1.4")!!
        val expected = setOf("id", "platform", "appVersion", "startedAt", "endedAt", "distanceMeters", "durationSeconds",
            "movingSeconds", "avgSpeedKmh", "maxSpeedKmh", "timeOverLimitSeconds", "score", "arrived", "startedWithNavigation",
            "origin", "destination", "eventCounts", "speedBands", "track", "events")
        assertTrue(o.keySet().containsAll(expected))
        // No lead-distance samples: the optional gap fields are omitted.
        assertFalse(o.has("avgLeadDistanceMeters"))
        assertEquals(trip.id.toString(), o.getString("id"))
        assertEquals("android", o.getString("platform"))
        assertEquals("1.4", o.getString("appVersion"))
        assertEquals("2026-11-28T08:00:00Z", o.getString("startedAt"))
        assertEquals("2026-11-28T08:10:00Z", o.getString("endedAt"))
        assertEquals(9000.0, o.getDouble("distanceMeters"), 5.0)
        assertEquals(600.0, o.getDouble("durationSeconds"), 1e-9)
        assertEquals(600.0, o.getDouble("movingSeconds"), 1e-9)
        assertEquals(54.0, o.getDouble("avgSpeedKmh"), 0.2)
        assertEquals(54.0, o.getDouble("maxSpeedKmh"), 1e-9)
        assertEquals(0.0, o.getDouble("timeOverLimitSeconds"), 1e-9)
        assertEquals(TripScoring.score(trip).score, o.getInt("score"))
        assertTrue(o.getBoolean("arrived"))
        assertTrue(o.getBoolean("startedWithNavigation"))
        val origin = o.getJSONObject("origin")
        assertEquals(setOf("lat", "lon", "name"), origin.keySet())
        assertEquals("Yunusobod", origin.getString("name"))
        assertEquals("TDTU", o.getJSONObject("destination").getString("name"))
        val counts = o.getJSONObject("eventCounts")
        assertEquals(1, counts.getInt("tailgating"))
        assertEquals(1, counts.getInt("speeding"))
        // Speed-band keys are the core's TripSpeedBand raw values, all present.
        assertEquals(TripSpeedBand.entries.map { it.raw }.toSet(), o.getJSONObject("speedBands").keySet())
        assertEquals(600.0, o.getJSONObject("speedBands").getDouble("urban"), 1e-9)
        // Events sorted by time, severity as text, timestamps ISO-8601 UTC.
        val events = o.getJSONArray("events")
        assertEquals(2, events.length())
        assertEquals("speeding", events.getJSONObject(0).getString("kind"))
        assertEquals("violation", events.getJSONObject(0).getString("severity"))
        val e = events.getJSONObject(1)
        assertEquals(setOf("kind", "severity", "at", "lat", "lon", "speedKmh", "value", "limit", "durationSeconds"), e.keySet())
        assertEquals("tailgating", e.getString("kind"))
        assertEquals("warning", e.getString("severity"))
        assertEquals("2026-11-28T08:05:00Z", e.getString("at"))
        assertEquals(6.5, e.getDouble("value"), 1e-9)
        assertEquals(4.0, e.getDouble("durationSeconds"), 1e-9)
        // Valid JSON round trip.
        assertEquals(o.getString("id"), JSONObject(o.toString()).getString("id"))
    }

    @Test fun trackRowsAreLatLonSecondsSpeedLimit() {
        val trip = straightTrip(120, 36.0)
        // A point without speed and limit.
        trip.points = trip.points.mapIndexed { i, p -> if (i == 0) p.copy(speedKmh = null, speedLimitKmh = null) else p }
        val track = CabinetTripPayload.build(trip)!!.getJSONArray("track")
        // A straight line simplifies to its two endpoints.
        assertEquals(2, track.length())
        val first = track.getJSONArray(0)
        assertEquals(5, first.length())
        assertEquals(41.31, first.getDouble(0), 1e-9)
        assertEquals(69.28, first.getDouble(1), 1e-9)
        assertEquals(0.0, first.getDouble(2), 1e-9)
        assertTrue(first.isNull(3))
        assertTrue(first.isNull(4))
        val last = track.getJSONArray(1)
        assertEquals(120.0, last.getDouble(2), 1e-9)
        assertEquals(36.0, last.getDouble(3), 1e-9)
        assertEquals(60, last.getInt(4))
    }

    @Test fun trackIsSimplifiedToAtMost2000Points() {
        // Zig-zag (±20 m every second): nothing is removed at 5 m, so the tolerance has to grow until ≤ 2000 remain.
        val points = mutableListOf<TripPoint>()
        var center = GeoPoint(41.31, 69.28)
        for (i in 0..4999) {
            val p = Geo.destination(center, if (i % 2 == 0) 90.0 else 270.0, 20.0)
            points.add(TripPoint(at(i.toDouble()), p, speedKmh = 36.0, speedLimitKmh = 60, horizontalAccuracy = 5.0))
            center = Geo.destination(center, 0.0, 10.0)
        }
        val trip = Trip(startedAtMillis = t0, endedAtMillis = at(4999.0), points = points)
        assertTrue(Geo.simplify(points.map { it.coordinate }, 5.0).size > 2000)
        val kept = CabinetTripPayload.simplifiedTrack(points)
        assertTrue(kept.size in 2..CabinetTripPayload.MAX_TRACK_POINTS)
        assertEquals(points.first(), kept.first())
        assertEquals(points.last(), kept.last())
        val track = CabinetTripPayload.build(trip)!!.getJSONArray("track")
        assertEquals(kept.size, track.length())
        // Rows keep their own time (seconds from start), increasing.
        var previous = -1.0
        for (i in 0 until track.length()) {
            val s = track.getJSONArray(i).getDouble(2)
            assertTrue(s > previous)
            previous = s
        }
    }

    @Test fun shortTripsAreSkipped() {
        // 40 s at 54 km/h = 600 m but shorter than 60 s.
        assertNull(CabinetTripPayload.build(straightTrip(40, 54.0)))
        // 120 s at 7.2 km/h = 240 m, shorter than 300 m.
        assertNull(CabinetTripPayload.build(straightTrip(120, 7.2)))
        // 60 s at 36 km/h = 600 m: uploaded.
        assertNotNull(CabinetTripPayload.build(straightTrip(60, 36.0)))
        assertFalse(CabinetTripPayload.shouldUpload(straightTrip(40, 54.0)))
        assertTrue(CabinetTripPayload.shouldUpload(straightTrip(60, 36.0)))
    }

    @Test fun originFallsBackToTrackEnds() {
        val trip = straightTrip(120, 36.0)
        val o = CabinetTripPayload.build(trip)!!
        assertEquals(41.31, o.getJSONObject("origin").getDouble("lat"), 1e-9)
        assertFalse(o.getJSONObject("origin").has("name"))
        assertTrue(o.getJSONObject("destination").getDouble("lat") > 41.31)
    }

    @Test fun severityRawValues() {
        assertEquals("info", CabinetTripPayload.severityRaw(DrivingEventSeverity.INFO))
        assertEquals("warning", CabinetTripPayload.severityRaw(DrivingEventSeverity.WARNING))
        assertEquals("violation", CabinetTripPayload.severityRaw(DrivingEventSeverity.VIOLATION))
    }

    // CabinetApi

    @Test fun apiUrlsAndBodies() {
        val base = "https://trafficcounter.uz/roadvis/"
        assertEquals("https://trafficcounter.uz/roadvis/api/v1/devices/register", CabinetApi.url(base, CabinetApi.REGISTER_PATH))
        assertEquals("https://trafficcounter.uz/roadvis/api/v1/me", CabinetApi.url(base, CabinetApi.ME_PATH))
        assertEquals("https://trafficcounter.uz/roadvis/api/v1/trips", CabinetApi.url(base, CabinetApi.TRIPS_PATH))
        assertEquals("https://trafficcounter.uz/roadvis/api/v1/auth/qr/approve", CabinetApi.url(base, CabinetApi.QR_APPROVE_PATH))
        assertEquals("https://trafficcounter.uz/roadvis/", CabinetApi.websiteUrl("https://trafficcounter.uz/roadvis"))
        val reg = CabinetApi.registerBody("android", "1.4", "Pixel 8", "Dilshod", "uz")
        assertEquals(setOf("platform", "appVersion", "deviceName", "driverName", "language"), reg.keySet())
        assertEquals(setOf("challengeId", "nonce"), CabinetApi.approveBody("c", "n").keySet())
        assertEquals("Ali", CabinetApi.renameBody("Ali").getString("driverName"))
    }

    @Test fun apiResponsesAndOutcomes() {
        val r = CabinetApi.parseRegistration("""{"deviceToken":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","driverId":"d1","driverName":"Dilshod"}""")!!
        assertEquals("d1", r.driverId)
        assertEquals("Dilshod", r.driverName)
        assertNull(CabinetApi.parseRegistration("""{"driverId":"d1"}"""))
        assertNull(CabinetApi.parseRegistration("not json"))
        val me = CabinetApi.parseProfile("""{"driverId":"d1","driverName":"D","createdAt":"2026-11-28T08:00:00Z","tripCount":3,"points":420,"level":3}""")!!
        assertEquals(3, me.tripCount)
        assertEquals(420, me.points)
        assertEquals(3, me.level)
        assertEquals(CabinetApi.TripUploadOutcome.UPLOADED, CabinetApi.tripUploadOutcome(201))
        assertEquals(CabinetApi.TripUploadOutcome.UPLOADED, CabinetApi.tripUploadOutcome(200))
        assertEquals(CabinetApi.TripUploadOutcome.UNAUTHORIZED, CabinetApi.tripUploadOutcome(401))
        assertEquals(CabinetApi.TripUploadOutcome.REJECTED, CabinetApi.tripUploadOutcome(413))
        assertEquals(CabinetApi.TripUploadOutcome.REJECTED, CabinetApi.tripUploadOutcome(422))
        assertEquals(CabinetApi.TripUploadOutcome.RETRY_LATER, CabinetApi.tripUploadOutcome(429))
        assertEquals(CabinetApi.TripUploadOutcome.RETRY_LATER, CabinetApi.tripUploadOutcome(503))
        assertEquals(CabinetApi.ApproveOutcome.APPROVED, CabinetApi.approveOutcome(200))
        assertEquals(CabinetApi.ApproveOutcome.EXPIRED, CabinetApi.approveOutcome(404))
        assertEquals(CabinetApi.ApproveOutcome.ALREADY_USED, CabinetApi.approveOutcome(409))
        assertEquals(CabinetApi.ApproveOutcome.UNAUTHORIZED, CabinetApi.approveOutcome(401))
        assertEquals(CabinetApi.ApproveOutcome.FAILED, CabinetApi.approveOutcome(500))
    }

    // QRLoginPayload

    private val base = "https://trafficcounter.uz/roadvis"
    private val challenge = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    private val nonce = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"

    private fun failure(url: String, b: String = base): QRLoginPayload.Failure? =
        (QRLoginPayload.check(url, b) as? QRLoginPayload.Result.Invalid)?.failure

    @Test fun qrValid() {
        val p = QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=$challenge&n=$nonce", base)!!
        assertEquals(challenge, p.challengeId)
        assertEquals(nonce, p.nonce)
        assertEquals("trafficcounter.uz", p.host)
        // Trailing slash in the base, upper-case host and UUID, parameter order.
        val q = QRLoginPayload.parse("https://TrafficCounter.uz/roadvis/qr?n=$nonce&c=${challenge.uppercase()}", "$base/")!!
        assertEquals(challenge, q.challengeId)
        assertEquals(nonce, q.nonce)
        // Explicit default port.
        assertNotNull(QRLoginPayload.parse("https://trafficcounter.uz:443/roadvis/qr?c=$challenge&n=$nonce", base))
        // URL-encoded nonce characters are decoded.
        assertEquals("a-b_c", QRLoginPayload.parse("https://trafficcounter.uz/roadvis/qr?c=$challenge&n=a%2Db_c", base)!!.nonce)
    }

    @Test fun qrForeignHost() {
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://evil.example/roadvis/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz.evil.example/roadvis/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz@evil.example/roadvis/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz:8443/roadvis/qr?c=$challenge&n=$nonce"))
        assertNull(QRLoginPayload.parse("https://evil.example/roadvis/qr?c=$challenge&n=$nonce", base))
    }

    @Test fun qrForeignPath() {
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz/other/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz/roadvisX/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz/qr?c=$challenge&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure("https://trafficcounter.uz/roadvis/../evil/qr?c=$challenge&n=$nonce"))
        // A base at the host root accepts any path of that host.
        assertNotNull(QRLoginPayload.parse("https://trafficcounter.uz/qr?c=$challenge&n=$nonce", "https://trafficcounter.uz"))
    }

    @Test fun qrMissingParameters() {
        assertEquals(QRLoginPayload.Failure.INVALID_PARAMETERS, failure("https://trafficcounter.uz/roadvis/qr?n=$nonce"))
        assertEquals(QRLoginPayload.Failure.INVALID_PARAMETERS, failure("https://trafficcounter.uz/roadvis/qr?c=$challenge"))
        assertEquals(QRLoginPayload.Failure.INVALID_PARAMETERS, failure("https://trafficcounter.uz/roadvis/qr?c=$challenge&n="))
        assertEquals(QRLoginPayload.Failure.INVALID_PARAMETERS, failure("https://trafficcounter.uz/roadvis/qr?c=not-a-uuid&n=$nonce"))
        assertEquals(QRLoginPayload.Failure.INVALID_PARAMETERS, failure("https://trafficcounter.uz/roadvis/qr"))
        assertEquals(QRLoginPayload.Failure.NOT_A_LINK, failure("hello world"))
        assertEquals(QRLoginPayload.Failure.NOT_A_LINK, failure("WIFI:S:home;T:WPA;P:secret;;"))
        assertEquals(QRLoginPayload.Failure.NOT_A_LINK, failure("roadvis://qr?c=$challenge&n=$nonce"))
    }

    @Test fun qrHttpOnlyWithHttpBase() {
        val http = "http://trafficcounter.uz/roadvis/qr?c=$challenge&n=$nonce"
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure(http))
        assertNotNull(QRLoginPayload.parse(http, "http://trafficcounter.uz/roadvis"))
        // Local test server.
        val local = "http://192.168.1.5:8000/roadvis/qr?c=$challenge&n=$nonce"
        assertNotNull(QRLoginPayload.parse(local, "http://192.168.1.5:8000/roadvis"))
        assertEquals(QRLoginPayload.Failure.FOREIGN_SITE, failure(local, "http://192.168.1.5:9000/roadvis"))
    }

    @Test fun uuidOfTripIsTheId() {
        val trip = straightTrip(120, 36.0).copy(id = UUID.fromString(challenge))
        assertEquals(challenge, CabinetTripPayload.build(trip)!!.getString("id"))
    }
}
