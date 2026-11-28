package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import kotlin.math.max
import kotlin.math.roundToLong

// Driver cabinet (`RoadVis/docs/CABINET_API.md`): device registration, automatic trip upload and QR login for the
// website. Identical rules in the Swift `RoadVisCore` and here; field names, endpoints and constants follow the contract.

/** Endpoints, request bodies and response parsing of the cabinet API (contract §1, §2, §4). */
object CabinetApi {
    const val PLATFORM_ANDROID = "android"

    const val REGISTER_PATH = "/api/v1/devices/register"
    const val ME_PATH = "/api/v1/me"
    const val TRIPS_PATH = "/api/v1/trips"
    const val QR_APPROVE_PATH = "/api/v1/auth/qr/approve"

    /** `<base>/<path>` with the base trimmed of whitespace and trailing slashes. */
    fun url(baseUrl: String, path: String): String = ModelUpdatePolicy.normalizedBase(baseUrl) + path

    /** The website root `<base>/` («Открыть кабинет»). */
    fun websiteUrl(baseUrl: String): String = ModelUpdatePolicy.normalizedBase(baseUrl) + "/"

    /** `POST /api/v1/devices/register` body. [language] is `uz|ru|en`. */
    fun registerBody(platform: String, appVersion: String, deviceName: String, driverName: String, language: String): JSONObject =
        JSONObject()
            .put("platform", platform)
            .put("appVersion", appVersion)
            .put("deviceName", deviceName)
            .put("driverName", driverName)
            .put("language", language)

    /** `PATCH /api/v1/me` body. */
    fun renameBody(driverName: String): JSONObject = JSONObject().put("driverName", driverName)

    /** `POST /api/v1/auth/qr/approve` body. */
    fun approveBody(challengeId: String, nonce: String): JSONObject =
        JSONObject().put("challengeId", challengeId).put("nonce", nonce)

    /** `201 {"deviceToken", "driverId", "driverName"}`. */
    data class Registration(val deviceToken: String, val driverId: String, val driverName: String?)

    fun parseRegistration(text: String): Registration? = try {
        val o = JSONObject(text)
        val token = o.optString("deviceToken", "").trim()
        if (token.isEmpty()) null else Registration(token, o.optString("driverId", ""), TripJson.optString(o, "driverName"))
    } catch (_: Exception) {
        null
    }

    /** `GET /api/v1/me` → `{"driverId", "driverName", "createdAt", "tripCount", "points", "level"}`. */
    data class Profile(
        val driverId: String,
        val driverName: String?,
        val createdAt: String?,
        val tripCount: Int,
        val points: Int,
        val level: Int,
    )

    fun parseProfile(text: String): Profile? = try {
        val o = JSONObject(text)
        Profile(
            driverId = o.optString("driverId", ""),
            driverName = TripJson.optString(o, "driverName"),
            createdAt = TripJson.optString(o, "createdAt"),
            tripCount = o.optInt("tripCount", 0),
            points = o.optInt("points", 0),
            level = o.optInt("level", 1),
        )
    } catch (_: Exception) {
        null
    }

    /** What the app does after `POST /api/v1/trips`. */
    enum class TripUploadOutcome {
        /** 200 / 201: remove from the pending list. */
        UPLOADED,
        /** 413 / 422 / other 4xx: the server will never accept this payload; remove it from the list. */
        REJECTED,
        /** 401: the token is not valid (any more). */
        UNAUTHORIZED,
        /** 429, 5xx, network: keep it and retry later. */
        RETRY_LATER,
    }

    fun tripUploadOutcome(status: Int): TripUploadOutcome = when {
        status == 200 || status == 201 -> TripUploadOutcome.UPLOADED
        status == 401 -> TripUploadOutcome.UNAUTHORIZED
        status == 408 || status == 429 || status >= 500 -> TripUploadOutcome.RETRY_LATER
        status in 400..499 -> TripUploadOutcome.REJECTED
        else -> TripUploadOutcome.RETRY_LATER
    }

    /** Result of `POST /api/v1/auth/qr/approve` (contract §4). */
    enum class ApproveOutcome { APPROVED, EXPIRED, ALREADY_USED, UNAUTHORIZED, FAILED }

    fun approveOutcome(status: Int): ApproveOutcome = when (status) {
        200 -> ApproveOutcome.APPROVED
        404 -> ApproveOutcome.EXPIRED
        409 -> ApproveOutcome.ALREADY_USED
        401 -> ApproveOutcome.UNAUTHORIZED
        else -> ApproveOutcome.FAILED
    }
}

/**
 * The trip upload JSON of contract §2 (`POST /api/v1/trips`), built from a finished [Trip] with [TripStats] and
 * [TripScoring]. Trips shorter than [MIN_DISTANCE_METERS] or [MIN_DURATION_SECONDS] are not uploaded ([build] → null).
 */
object CabinetTripPayload {
    const val MIN_DISTANCE_METERS = 300.0
    const val MIN_DURATION_SECONDS = 60.0
    /** `track` holds at most this many rows (Douglas–Peucker, starting at [SIMPLIFY_TOLERANCE_METERS]). */
    const val MAX_TRACK_POINTS = 2000
    const val SIMPLIFY_TOLERANCE_METERS = 5.0

    /** False for trips the contract says are not uploaded (< 300 m or < 60 s). */
    fun shouldUpload(trip: Trip, stats: TripStats = TripStats.compute(trip)): Boolean =
        stats.distanceMeters >= MIN_DISTANCE_METERS && stats.duration >= MIN_DURATION_SECONDS

    /** The upload body, or null when the trip is too short to upload. */
    fun build(trip: Trip, appVersion: String = "1.0", platform: String = CabinetApi.PLATFORM_ANDROID): JSONObject? {
        val stats = TripStats.compute(trip)
        if (!shouldUpload(trip, stats)) return null
        val score = TripScoring.score(trip.events, stats.distanceMeters).score
        val sorted = trip.points.sortedBy { it.dateMillis }

        val o = JSONObject()
            .put("id", trip.id.toString())
            .put("platform", platform)
            .put("appVersion", appVersion)
            .put("startedAt", TripJson.iso(trip.startedAtMillis))
            .put("endedAt", TripJson.iso(trip.effectiveEndMillis))
            .put("distanceMeters", round(stats.distanceMeters, 1))
            .put("durationSeconds", round(stats.duration, 1))
            .put("movingSeconds", round(stats.movingDuration, 1))
            .put("avgSpeedKmh", round(stats.averageSpeedKmh, 1))
            .put("maxSpeedKmh", round(stats.maxSpeedKmh, 1))
            .put("timeOverLimitSeconds", round(stats.timeOverLimit, 1))
            .put("score", score)
            .put("arrived", trip.arrived)
            .put("startedWithNavigation", trip.startedWithNavigation)

        endpoint(trip.origin.coordinate ?: sorted.firstOrNull()?.coordinate, trip.origin.name)?.let { o.put("origin", it) }
        val destination = trip.destination
        endpoint(destination?.coordinate ?: sorted.lastOrNull()?.coordinate, destination?.name)?.let { o.put("destination", it) }

        val counts = JSONObject()
        for ((kind, n) in stats.eventCounts) counts.put(kind.raw, n)
        o.put("eventCounts", counts)

        val bands = JSONObject()
        for (band in TripSpeedBand.entries) bands.put(band.raw, round(stats.timeBySpeedBand[band] ?: 0.0, 1))
        o.put("speedBands", bands)

        finite(stats.averageLeadDistanceMeters)?.let { o.put("avgLeadDistanceMeters", round(it, 1)) }
        finite(stats.shareBelowRecommendedGap)?.let { o.put("shareBelowRecommendedGap", round(it, 3)) }

        val track = JSONArray()
        for (p in simplifiedTrack(sorted)) track.put(trackRow(p, trip.startedAtMillis))
        o.put("track", track)

        val events = JSONArray()
        for (e in trip.sortedEvents) events.put(event(e))
        o.put("events", events)
        return o
    }

    /**
     * Track points kept by `Geo.simplify` (5 m, doubling until ≤ [MAX_TRACK_POINTS]); invalid coordinates are dropped.
     * The points keep their own time, speed and limit.
     */
    fun simplifiedTrack(points: List<TripPoint>): List<TripPoint> {
        val valid = points.filter { it.coordinate.isValid }
        if (valid.size <= 2) return valid
        val coordinates = valid.map { it.coordinate }
        val kept = Geo.simplify(coordinates, MAX_TRACK_POINTS, SIMPLIFY_TOLERANCE_METERS)
        // `Geo.simplify` returns a subsequence of the same GeoPoint instances: walk both lists in order.
        val result = ArrayList<TripPoint>(kept.size)
        var j = 0
        for (i in valid.indices) {
            if (j >= kept.size) break
            if (coordinates[i] === kept[j]) {
                result.add(valid[i])
                j++
            }
        }
        return result
    }

    /** `[lat, lon, secondsFromStart, speedKmh|null, speedLimitKmh|null]`. */
    fun trackRow(p: TripPoint, startedAtMillis: Long): JSONArray = JSONArray()
        .put(round(p.coordinate.latitude, 6))
        .put(round(p.coordinate.longitude, 6))
        .put(round(max(0.0, (p.dateMillis - startedAtMillis) / 1000.0), 1))
        .put(finite(p.speedKmh)?.let { round(it, 1) } ?: JSONObject.NULL)
        .put(p.speedLimitKmh ?: JSONObject.NULL)

    /** `info|warning|violation`. */
    fun severityRaw(severity: DrivingEventSeverity): String = when (severity) {
        DrivingEventSeverity.INFO -> "info"
        DrivingEventSeverity.WARNING -> "warning"
        DrivingEventSeverity.VIOLATION -> "violation"
    }

    private fun event(e: DrivingEvent): JSONObject {
        val o = JSONObject()
            .put("kind", e.kind.raw)
            .put("severity", severityRaw(e.severity))
            .put("at", TripJson.iso(e.dateMillis))
        e.coordinate?.takeIf { it.isValid }?.let {
            o.put("lat", round(it.latitude, 6))
            o.put("lon", round(it.longitude, 6))
        }
        finite(e.speedKmh)?.let { o.put("speedKmh", round(it, 1)) }
        finite(e.value)?.let { o.put("value", round(it, 2)) }
        finite(e.limit)?.let { o.put("limit", round(it, 2)) }
        o.put("durationSeconds", round(finite(e.duration) ?: 0.0, 1))
        return o
    }

    private fun endpoint(coordinate: GeoPoint?, name: String?): JSONObject? {
        val c = coordinate?.takeIf { it.isValid } ?: return null
        val o = JSONObject().put("lat", round(c.latitude, 6)).put("lon", round(c.longitude, 6))
        name?.trim()?.takeIf { it.isNotEmpty() }?.let { o.put("name", it) }
        return o
    }

    private fun finite(v: Double?): Double? = v?.takeIf { it.isFinite() }

    private fun round(v: Double, digits: Int): Double {
        if (!v.isFinite()) return 0.0
        var f = 1.0
        repeat(digits) { f *= 10 }
        return (v * f).roundToLong() / f
    }
}

/**
 * A website login QR (contract §4): `<base>/qr?c=<challengeId>&n=<nonce>`. Accepted only when its scheme, host, port
 * and path prefix equal the configured server URL (no logging in to foreign sites); `https` always, `http` only when
 * the configured base itself is `http`. `c` must be a UUID, `n` must be present.
 */
data class QRLoginPayload(val challengeId: String, val nonce: String, val host: String) {
    enum class Failure {
        /** Not an http(s) link at all (some other QR code). */
        NOT_A_LINK,
        /** A link to another site, or to this site outside the configured base, or http while the base is https. */
        FOREIGN_SITE,
        /** The right site but `c` (UUID) or `n` is missing / malformed. */
        INVALID_PARAMETERS,
    }

    sealed class Result {
        data class Valid(val payload: QRLoginPayload) : Result()
        data class Invalid(val failure: Failure) : Result()
    }

    companion object {
        private val UUID_RE = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

        /** The payload, or null when [url] is not a login QR of [configuredBase]. */
        fun parse(url: String, configuredBase: String): QRLoginPayload? = (check(url, configuredBase) as? Result.Valid)?.payload

        /** Like [parse], with the reason of a rejection (for the error message). */
        fun check(url: String, configuredBase: String): Result {
            val target = uri(url.trim()) ?: return Result.Invalid(Failure.NOT_A_LINK)
            val scheme = target.scheme?.lowercase()
            val host = target.host?.lowercase()
            if ((scheme != "https" && scheme != "http") || host.isNullOrEmpty()) return Result.Invalid(Failure.NOT_A_LINK)

            val base = uri(ModelUpdatePolicy.normalizedBase(configuredBase))
            val baseScheme = base?.scheme?.lowercase()
            val baseHost = base?.host?.lowercase()
            if (base == null || (baseScheme != "https" && baseScheme != "http") || baseHost.isNullOrEmpty()) {
                return Result.Invalid(Failure.FOREIGN_SITE)
            }
            if (scheme == "http" && baseScheme != "http") return Result.Invalid(Failure.FOREIGN_SITE)
            if (target.rawUserInfo != null) return Result.Invalid(Failure.FOREIGN_SITE)
            if (host != baseHost || port(target, scheme) != port(base, baseScheme)) return Result.Invalid(Failure.FOREIGN_SITE)
            val basePath = (base.rawPath ?: "").trimEnd('/')
            val path = target.rawPath ?: ""
            if (basePath.isNotEmpty() && path != basePath && !path.startsWith("$basePath/")) {
                return Result.Invalid(Failure.FOREIGN_SITE)
            }

            val query = queryParameters(target.rawQuery)
            val c = query["c"]?.trim().orEmpty()
            val n = query["n"]?.trim().orEmpty()
            if (!UUID_RE.matches(c) || n.isEmpty()) return Result.Invalid(Failure.INVALID_PARAMETERS)
            return Result.Valid(QRLoginPayload(c.lowercase(), n, host))
        }

        private fun uri(text: String): URI? = try {
            URI(text).normalize()
        } catch (_: Exception) {
            null
        }

        private fun port(u: URI, scheme: String): Int = if (u.port >= 0) u.port else if (scheme == "https") 443 else 80

        /** First value of each parameter, URL-decoded. */
        private fun queryParameters(raw: String?): Map<String, String> {
            val result = LinkedHashMap<String, String>()
            if (raw.isNullOrEmpty()) return result
            for (part in raw.split('&')) {
                if (part.isEmpty()) continue
                val i = part.indexOf('=')
                val key = decode(if (i >= 0) part.substring(0, i) else part) ?: continue
                val value = decode(if (i >= 0) part.substring(i + 1) else "") ?: continue
                if (key !in result) result[key] = value
            }
            return result
        }

        private fun decode(s: String): String? = try {
            URLDecoder.decode(s, "UTF-8")
        } catch (_: Exception) {
            null
        }
    }
}
