package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.Date
import java.util.UUID

/**
 * Kind of a user-reported road event (stored locally on the phone; there is no shared incident feed).
 * New cases are only ever appended, so files written by older versions keep decoding.
 */
enum class RoadIncidentKind(val raw: String) {
    ACCIDENT("accident"), ROAD_WORK("roadWork"), JAM("jam"), POLICE("police"), POTHOLE("pothole"),
    HAZARD("hazard"), CLOSURE("closure"),
    /** The user's own mark of a (speed) camera. Cameras are fixed, so the mark does not expire. */
    SPEED_CAMERA("speedCamera");

    /** Russian display name. */
    val displayName: String
        get() = when (this) {
            ACCIDENT -> "ДТП"
            ROAD_WORK -> "Дорожные работы"
            JAM -> "Пробка"
            POLICE -> "Полиция / пост ДПС"
            POTHOLE -> "Яма"
            HAZARD -> "Опасность"
            CLOSURE -> "Перекрытие"
            SPEED_CAMERA -> "Камера"
        }

    /** SF Symbol name (kept from iOS; map to a drawable in the app). */
    val symbolName: String
        get() = when (this) {
            ACCIDENT -> "exclamationmark.octagon.fill"
            ROAD_WORK -> "cone.fill"
            JAM -> "car.2.fill"
            POLICE -> "shield.fill"
            POTHOLE -> "exclamationmark.circle.fill"
            HAZARD -> "exclamationmark.triangle.fill"
            CLOSURE -> "nosign"
            SPEED_CAMERA -> "camera.fill"
        }

    /**
     * True for marks of fixed objects (cameras) that are kept until the user deletes them; other reports expire after
     * the incident lifetime set in Settings.
     */
    val isPermanent: Boolean get() = this == SPEED_CAMERA

    /** Distance ahead on the route at which the navigator announces the mark, metres (cameras like OSM cameras). */
    val alertDistance: Double
        get() = if (this == SPEED_CAMERA) RouteFeatureKind.SPEED_CAMERA.alertDistance else 700.0

    companion object {
        fun fromRaw(raw: String): RoadIncidentKind? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * A road event reported by the user.
 * JSON ([toJSON] / [fromJSON]) uses the iOS Codable layout: `{"id": "<UUID>", "kind": "...",
 * "coordinate": {"latitude":…, "longitude":…}, "date": <seconds since 2001-01-01>, "note": "…"}`.
 */
data class RoadIncident(
    val id: UUID = UUID.randomUUID(),
    val kind: RoadIncidentKind,
    val coordinate: GeoPoint,
    val date: Date = Date(),
    val note: String? = null,
) {
    fun toJSON(): JSONObject {
        val o = JSONObject()
        o.put("id", id.toString().uppercase())
        o.put("kind", kind.raw)
        o.put("coordinate", JSONObject().put("latitude", coordinate.latitude).put("longitude", coordinate.longitude))
        o.put("date", Json.dateToJSON(date))
        if (note != null) o.put("note", note)
        return o
    }

    companion object {
        /** @throws IllegalArgumentException for a malformed record. */
        fun fromJSON(o: JSONObject): RoadIncident {
            val id = try { UUID.fromString(o.getString("id")) } catch (e: Exception) { throw IllegalArgumentException("id", e) }
            val kind = RoadIncidentKind.fromRaw(o.optString("kind")) ?: throw IllegalArgumentException("kind")
            val c = o.optJSONObject("coordinate") ?: throw IllegalArgumentException("coordinate")
            val lat = Json.double(c.opt("latitude")) ?: throw IllegalArgumentException("latitude")
            val lon = Json.double(c.opt("longitude")) ?: throw IllegalArgumentException("longitude")
            val date = Json.dateFromJSON(o.opt("date")) ?: throw IllegalArgumentException("date")
            val note = o.opt("note") as? String
            return RoadIncident(id, kind, GeoPoint(lat, lon), date, note)
        }

        fun encodeList(incidents: List<RoadIncident>): String = JSONArray().also { a -> incidents.forEach { a.put(it.toJSON()) } }.toString()

        /** @throws IllegalArgumentException / org.json.JSONException for malformed files. */
        fun decodeList(json: String): List<RoadIncident> {
            val arr = JSONArray(json)
            return (0 until arr.length()).map { fromJSON(arr.getJSONObject(it)) }
        }
    }
}

/** An incident projected onto the active route. */
data class IncidentOnRoute(
    val incident: RoadIncident,
    /** Distance from the route start to the incident's projection, metres. */
    val distanceAlongRoute: Double,
    /** Lateral distance between the incident and the route, metres. */
    val offsetFromRoute: Double = 0.0,
) {
    val id: UUID get() = incident.id
}

object IncidentFilter {
    /**
     * Incidents younger than [lifetime] seconds at [now], plus permanent marks (cameras) of any age, newest first.
     * Incidents dated slightly in the future (clock changes) are kept; `lifetime <= 0` (or not finite) expires every
     * non-permanent incident.
     */
    fun active(incidents: List<RoadIncident>, now: Date, lifetime: Double): List<RoadIncident> {
        val validLifetime = lifetime > 0 && lifetime.isFinite()
        return incidents
            .filter { it.kind.isPermanent || (validLifetime && (now.time - it.date.time) / 1000.0 < lifetime) }
            .sortedByDescending { it.date.time }
    }

    /**
     * Incidents within [maxOffset] metres of the route, sorted by distance along the route.
     * [cumulative]: optional `Geo.cumulativeDistances(route)` (ignored when its count does not match).
     */
    fun along(route: List<GeoPoint>, cumulative: List<Double>?, incidents: List<RoadIncident>,
              maxOffset: Double = 50.0): List<IncidentOnRoute> {
        if (route.isEmpty()) return emptyList()
        val cum = if (cumulative != null && cumulative.size == route.size) cumulative else Geo.cumulativeDistances(route)
        return incidents
            .mapNotNull { incident ->
                if (!incident.coordinate.isValid) return@mapNotNull null
                val projection = Geo.project(incident.coordinate, route, cum) ?: return@mapNotNull null
                if (projection.distanceFromLine > maxOffset) return@mapNotNull null
                IncidentOnRoute(incident, projection.distanceAlong, projection.distanceFromLine)
            }
            .sortedWith(compareBy<IncidentOnRoute> { it.distanceAlongRoute }.thenByDescending { it.incident.date.time })
    }
}
