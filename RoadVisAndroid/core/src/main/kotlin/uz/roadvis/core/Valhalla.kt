package uz.roadvis.core

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.pow

/** Encoded polyline (Google algorithm) with configurable precision (Valhalla and OSRM `polyline6` use 6). */
object Polyline {
    fun decode(encoded: String, precision: Int = 6): List<GeoPoint> {
        val factor = 10.0.pow(precision)
        val bytes = encoded.toByteArray(Charsets.UTF_8)
        var index = 0
        var lat = 0L
        var lon = 0L
        val result = ArrayList<GeoPoint>(bytes.size / 4)

        fun next(): Long? {
            var shift = 0
            var value = 0L
            while (index < bytes.size) {
                val b = (bytes[index].toInt() and 0xFF) - 63
                index++
                value = value or ((b and 0x1F).toLong() shl shift)
                shift += 5
                if (b < 0x20) {
                    return if ((value and 1L) != 0L) (value shr 1).inv() else (value shr 1)
                }
            }
            return null
        }

        while (index < bytes.size) {
            val dLat = next() ?: break
            val dLon = next() ?: break
            lat += dLat
            lon += dLon
            result.add(GeoPoint(lat / factor, lon / factor))
        }
        return result
    }

    fun encode(points: List<GeoPoint>, precision: Int = 6): String {
        val factor = 10.0.pow(precision)
        val out = StringBuilder()
        var prevLat = 0L
        var prevLon = 0L
        fun put(v: Long) {
            var value = if (v < 0) (v shl 1).inv() else (v shl 1)
            while (value >= 0x20) {
                out.append(((0x20 or (value and 0x1F).toInt()) + 63).toChar())
                value = value shr 5
            }
            out.append((value.toInt() + 63).toChar())
        }
        for (p in points) {
            val la = (p.latitude * factor).rounded().toLong()
            val lo = (p.longitude * factor).rounded().toLong()
            put(la - prevLat)
            put(lo - prevLon)
            prevLat = la
            prevLon = lo
        }
        return out.toString()
    }
}

/** Where a route came from. */
enum class RouteSource(val raw: String) {
    APPLE("apple"),
    VALHALLA("valhalla"),
    OSRM("osrm");

    val displayName: String
        get() = when (this) {
            APPLE -> "Apple Maps"
            VALHALLA -> "OpenStreetMap (Valhalla)"
            OSRM -> "OpenStreetMap (OSRM)"
        }

    /** Short badge text ("Apple", "Valhalla", "OSRM"). */
    val badge: String
        get() = when (this) {
            APPLE -> "Apple"
            VALHALLA -> "Valhalla"
            OSRM -> "OSRM"
        }

    /** True when the engine's travel time may include live traffic (only Apple, and only where Apple has data). */
    val mayIncludeTraffic: Boolean get() = this == APPLE

    /** True for engines working on OpenStreetMap data. */
    val usesOpenStreetMap: Boolean get() = this != APPLE

    companion object {
        fun fromRaw(raw: String): RouteSource? = entries.firstOrNull { it.raw == raw }
    }
}

/** Engine-independent route used by the navigator. */
data class NavRoute(
    val source: RouteSource,
    val name: String,
    val polyline: List<GeoPoint>,
    /** Metres. */
    val distance: Double,
    /** Seconds (engine estimate; Valhalla/OSM has no live traffic). */
    val expectedTravelTime: Double,
    val steps: List<RouteStepInfo>,
    val hasTolls: Boolean = false,
    val hasHighways: Boolean = false,
    val advisories: List<String> = emptyList(),
)

/** Attributes of one road edge along a route (from Valhalla `/trace_attributes`). */
data class RouteEdgeAttributes(
    /** Distance from the route start to the edge start / end, metres. */
    val startDistance: Double,
    val endDistance: Double,
    val names: List<String> = emptyList(),
    /** Posted speed limit (OSM maxspeed), km/h. */
    val speedLimitKmh: Int? = null,
    /** Lanes in the travel direction (Valhalla value; 1 may mean "not tagged"). */
    val laneCount: Int? = null,
    /** Typical (free-flow, OSM-derived) speed used by the router, km/h. */
    val typicalSpeedKmh: Double? = null,
    val roadClass: String? = null,
    val wayID: Long? = null,
    /** True when a traffic signal is at this edge or at its end node. */
    val hasTrafficSignal: Boolean = false,
    /** Valhalla surface class ("paved_smooth", "paved", "paved_rough", "compacted", "dirt", "gravel", "path", "impassable"). */
    val surface: String? = null,
    /** Valhalla edge use ("road", "ramp", "turn_channel", "service_road", "living_street" …). */
    val use: String? = null,
    val isToll: Boolean = false,
    val isTunnel: Boolean = false,
    val isBridge: Boolean = false,
) {
    val length: Double get() = max(0.0, endDistance - startDistance)

    /** True for major road classes (motorway, trunk, primary). */
    val isPrimaryRoad: Boolean get() = roadClass in setOf("motorway", "trunk", "primary")

    companion object {
        /** Russian road class name for Valhalla `road_class`. */
        fun roadClassDisplayName(roadClass: String?): String? = when (roadClass) {
            "motorway" -> "Магистраль"
            "trunk" -> "Скоростная дорога"
            "primary" -> "Главная дорога"
            "secondary" -> "Дорога второго класса"
            "tertiary" -> "Дорога третьего класса"
            "unclassified" -> "Местная дорога"
            "residential" -> "Жилая улица"
            "service_other" -> "Служебный проезд"
            null -> null
            else -> roadClass
        }

        /** Russian surface name for Valhalla `surface`. */
        fun surfaceDisplayName(surface: String?): String? = when (surface) {
            "paved_smooth" -> "Ровный асфальт"
            "paved" -> "Асфальт"
            "paved_rough" -> "Неровное покрытие"
            "compacted" -> "Укатанный грунт"
            "dirt" -> "Грунт"
            "gravel" -> "Гравий"
            "path" -> "Тропа"
            "impassable" -> "Непроезжая"
            null -> null
            else -> surface
        }
    }
}

class ValhallaError(val code: Int?, override val message: String) : Exception(message) {
    /** True for the parser's own messages ("not JSON", "no trip") that do not describe a server error. */
    val isGenericParseFailure: Boolean
        get() = code == null && (message.startsWith("Ответ Valhalla") || message.startsWith("В ответе Valhalla"))

    override fun toString(): String = message
}

/**
 * Request building and response parsing for the Valhalla routing engine
 * (default public instance: https://valhalla1.openstreetmap.de, FOSSGIS — light use only, ≤ 1 request/s,
 * identifying User-Agent, OSM attribution required, URL must stay configurable).
 */
object Valhalla {
    const val defaultEndpoint = "https://valhalla1.openstreetmap.de"

    /** JSON body (UTF-8 text, sorted keys) for `POST /route`. */
    fun routeRequestBody(origin: GeoPoint, destination: GeoPoint, heading: Double? = null,
                         language: String = "ru-RU", alternates: Int = 2,
                         avoidTolls: Boolean = false, avoidHighways: Boolean = false): String {
        val start = LinkedHashMap<String, Any>()
        start["lat"] = origin.latitude
        start["lon"] = origin.longitude
        if (heading != null && heading.isFinite()) {
            start["heading"] = Geo.normalizeDegrees(heading).rounded().toInt() % 360
            start["heading_tolerance"] = 60
        }
        val auto = LinkedHashMap<String, Any>()
        if (avoidTolls) auto["use_tolls"] = 0.0
        if (avoidHighways) auto["use_highways"] = 0.0
        val body = LinkedHashMap<String, Any>()
        body["locations"] = listOf(start, mapOf("lat" to destination.latitude, "lon" to destination.longitude))
        body["costing"] = "auto"
        body["directions_options"] = mapOf("language" to language, "units" to "kilometers")
        body["turn_lanes"] = true
        if (alternates > 0) body["alternates"] = alternates
        if (auto.isNotEmpty()) body["costing_options"] = mapOf("auto" to auto)
        return Json.write(body)
    }

    /**
     * Parses `/route` into the main route followed by alternates.
     * [language]: the app language. ru / en keep Valhalla's own narrative (request it with
     * [RVLang.valhallaLanguage]); uz rebuilds every instruction from the maneuver type ([NavInstructionText]).
     * @throws ValhallaError
     */
    fun parseRoutes(json: String, language: RVLang = RVLang.RU): List<NavRoute> {
        val obj = Json.parseObject(json) ?: throw ValhallaError(null, "Ответ Valhalla не является JSON")
        errorFrom(obj)?.let { throw it }
        val trip = obj.opt("trip") as? JSONObject ?: throw ValhallaError(null, "В ответе Valhalla нет маршрута")
        val routes = arrayListOf(parseTrip(trip, language))
        Json.objectList(obj.opt("alternates"))?.forEach { alt ->
            val t = alt.opt("trip") as? JSONObject
            if (t != null) {
                try { routes.add(parseTrip(t, language)) } catch (e: ValhallaError) { /* skipped */ }
            }
        }
        return routes
    }

    fun parseRoutes(data: ByteArray, language: RVLang = RVLang.RU): List<NavRoute> =
        parseRoutes(String(data, Charsets.UTF_8), language)

    internal fun errorFrom(obj: JSONObject): ValhallaError? {
        val message = obj.opt("error") as? String ?: return null
        val code = (obj.opt("error_code") as? Number)?.let { if (Json.isIntegral(it)) it.toInt() else null }
        return ValhallaError(code, message)
    }

    internal fun double(v: Any?): Double? = Json.double(v)

    internal fun int(v: Any?): Int? = Json.int(v)

    internal fun parseTrip(trip: JSONObject, language: RVLang = RVLang.RU): NavRoute {
        val legs = Json.objectList(trip.opt("legs"))
        if (legs.isNullOrEmpty()) throw ValhallaError(null, "Маршрут без участков")
        val unitsFactor = if (trip.opt("units") as? String == "miles") 1609.344 else 1000.0
        val polyline = ArrayList<GeoPoint>()
        val steps = ArrayList<RouteStepInfo>()
        val names = ArrayList<String>()
        var anyToll = false
        var anyHighway = false

        for (leg in legs) {
            val shape = Polyline.decode(leg.opt("shape") as? String ?: "", 6)
            val offset = if (polyline.isEmpty()) 0 else 1   // shared endpoint between legs
            polyline.addAll(shape.drop(offset))
            for (m in Json.objectList(leg.opt("maneuvers")) ?: emptyList()) {
                val type = int(m.opt("type")) ?: 0
                val lengthMeters = (double(m.opt("length")) ?: 0.0) * unitsFactor
                val street = Json.stringList(m.opt("street_names")) ?: emptyList()
                if (names.size < 2) {
                    val s = street.firstOrNull()
                    if (s != null && !names.contains(s)) names.add(s)
                }
                if (Json.bool(m.opt("toll")) == true) anyToll = true
                if (Json.bool(m.opt("highway")) == true) anyHighway = true
                val laneData = Json.objectList(m.opt("lanes")) ?: emptyList()
                val (lanes, active) = lanes(laneData.map {
                    ValhallaLane(int(it.opt("directions")) ?: 0, int(it.opt("valid")), int(it.opt("active")))
                })
                var instruction = m.opt("instruction") as? String ?: ""
                if (!language.usesValhallaNarrative) {
                    instruction = NavInstructionText.valhalla(
                        type, street,
                        roundaboutExitCount = int(m.opt("roundabout_exit_count")),
                        roundaboutExitStreetNames = Json.stringList(m.opt("roundabout_exit_street_names")) ?: emptyList(),
                        language = language,
                    )
                } else if (maneuverType(type) == ManeuverType.ARRIVE) {
                    instruction = arrivalInstruction(instruction, m.opt("verbal_transition_alert_instruction") as? String)
                }
                steps.add(RouteStepInfo(instruction, lengthMeters, null, maneuverType(type), lanes, active, street))
            }
        }
        // Valhalla: maneuver i's instruction describes the action at its START and its length is the distance
        // travelled after it. The first maneuver (kStart) is the departure: blank its instruction so
        // RouteProgressTracker never announces it.
        if (steps.isNotEmpty() && steps[0].maneuver == ManeuverType.DEPART) {
            steps[0] = steps[0].copy(instruction = "")
        }
        val summary = trip.opt("summary") as? JSONObject
        val distance = (double(summary?.opt("length")) ?: 0.0) * unitsFactor
        val time = double(summary?.opt("time")) ?: 0.0
        if (Json.bool(summary?.opt("has_toll")) == true) anyToll = true
        if (Json.bool(summary?.opt("has_highway")) == true) anyHighway = true
        val name = if (names.isEmpty()) NavInstructionText.fallbackRouteName("OSM", language) else names.joinToString(", ")
        return NavRoute(RouteSource.VALHALLA, name, polyline,
            if (distance > 0) distance else Geo.polylineLength(polyline),
            time, steps, hasTolls = anyToll, hasHighways = anyHighway, advisories = emptyList())
    }

    /**
     * Text of the arrival step shown/spoken BEFORE arriving: the future-tense alert ("Пункт назначения будет
     * справа.") when Valhalla provides it, else the instruction with "Вы прибыли" → "Вы прибудете".
     */
    fun arrivalInstruction(instruction: String, alert: String?): String {
        val a = alert?.swiftTrim()
        if (!a.isNullOrEmpty()) return a
        return instruction
            .replace("Вы прибыли", "Вы прибудете")
            .replace("вы прибыли", "вы прибудете")
    }

    /** Valhalla maneuver type code → ManeuverType. */
    fun maneuverType(code: Int): ManeuverType = when (code) {
        1, 2, 3 -> ManeuverType.DEPART
        4, 5, 6 -> ManeuverType.ARRIVE
        7, 8, 17, 22 -> ManeuverType.STRAIGHT
        9 -> ManeuverType.SLIGHT_RIGHT
        10 -> ManeuverType.RIGHT
        11 -> ManeuverType.SHARP_RIGHT
        12, 13 -> ManeuverType.U_TURN
        14 -> ManeuverType.SHARP_LEFT
        15 -> ManeuverType.LEFT
        16 -> ManeuverType.SLIGHT_LEFT
        18, 20 -> ManeuverType.EXIT_RIGHT
        19, 21 -> ManeuverType.EXIT_LEFT
        23 -> ManeuverType.KEEP_RIGHT
        24 -> ManeuverType.KEEP_LEFT
        25, 37, 38 -> ManeuverType.MERGE
        26, 27 -> ManeuverType.ROUNDABOUT
        else -> ManeuverType.UNKNOWN
    }

    data class ValhallaLane(val directions: Int, val valid: Int? = null, val active: Int? = null)

    /**
     * Valhalla lane bitmask: 1 None, 2 Through, 4 SharpLeft, 8 Left, 16 SlightLeft, 32 SlightRight, 64 Right,
     * 128 SharpRight, 256 Reverse, 512 MergeToLeft, 1024 MergeToRight.
     */
    fun turns(fromMask: Int): List<LaneTurn> {
        val table = listOf(256 to LaneTurn.REVERSE, 4 to LaneTurn.SHARP_LEFT, 8 to LaneTurn.LEFT,
            16 to LaneTurn.SLIGHT_LEFT, 2 to LaneTurn.THROUGH, 32 to LaneTurn.SLIGHT_RIGHT, 64 to LaneTurn.RIGHT,
            128 to LaneTurn.SHARP_RIGHT, 512 to LaneTurn.MERGE_TO_LEFT, 1024 to LaneTurn.MERGE_TO_RIGHT, 1 to LaneTurn.NONE)
        return table.mapNotNull { if (fromMask and it.first != 0) it.second else null }
    }

    /** Lanes (left → right) and whether each is recommended (`active`, else `valid`). */
    fun lanes(raw: List<ValhallaLane>): Pair<List<Lane>, List<Boolean>> {
        if (raw.isEmpty()) return emptyList<Lane>() to emptyList()
        val lanes = raw.map { Lane(turns(it.directions)) }
        val anyActive = raw.any { (it.active ?: 0) != 0 }
        val active = raw.map { if (anyActive) (it.active ?: 0) != 0 else (it.valid ?: 0) != 0 }
        return lanes to active
    }

    // trace_attributes

    val traceAttributeFilters: List<String> = listOf(
        "shape", "edge.names", "edge.length", "edge.speed", "edge.speed_limit", "edge.lane_count",
        "edge.road_class", "edge.way_id", "edge.begin_shape_index", "edge.end_shape_index",
        "edge.traffic_signal", "node.traffic_signal", "edge.surface", "edge.use", "edge.toll", "edge.tunnel",
        "edge.bridge",
    )

    /**
     * JSON body for `POST /trace_attributes`. Use `edgeWalk = true` only for shapes produced by Valhalla itself;
     * other polylines must use map matching (`map_snap`) and should be simplified first.
     */
    fun traceAttributesBody(polyline: List<GeoPoint>, edgeWalk: Boolean): String {
        val body = mapOf(
            "encoded_polyline" to Polyline.encode(polyline, 6),
            "shape_match" to if (edgeWalk) "edge_walk" else "map_snap",
            "costing" to "auto",
            "filters" to mapOf("attributes" to traceAttributeFilters, "action" to "include"),
        )
        return Json.write(body)
    }

    /**
     * Parses `/trace_attributes` edges with along-route distances computed on the matched shape
     * (or on [fallbackPolyline] when the response has no shape).
     * @throws ValhallaError
     */
    fun parseTraceAttributes(json: String, fallbackPolyline: List<GeoPoint>): List<RouteEdgeAttributes> {
        val obj = Json.parseObject(json) ?: throw ValhallaError(null, "Ответ trace_attributes не является JSON")
        errorFrom(obj)?.let { throw it }
        val shape = (obj.opt("shape") as? String)?.let { Polyline.decode(it, 6) } ?: fallbackPolyline
        val cumulative = Geo.cumulativeDistances(shape)
        val unitsFactor = if (obj.opt("units") as? String == "miles") 1609.344 else 1000.0
        val result = ArrayList<RouteEdgeAttributes>()
        var running = 0.0
        for (e in Json.objectList(obj.opt("edges")) ?: emptyList()) {
            val lengthM = (double(e.opt("length")) ?: 0.0) * unitsFactor
            var start = running
            var end = running + lengthM
            val b = int(e.opt("begin_shape_index"))
            val en = int(e.opt("end_shape_index"))
            if (b != null && en != null && b in cumulative.indices && en in cumulative.indices && en >= b) {
                start = cumulative[b]
                end = cumulative[en]
            }
            running = end
            val endNode = e.opt("end_node") as? JSONObject
            val signal = Json.bool(e.opt("traffic_signal")) == true || Json.bool(endNode?.opt("traffic_signal")) == true
            val limit = int(e.opt("speed_limit"))?.let { if (it in 1..199) it else null }
            val lanes = int(e.opt("lane_count"))?.let { if (it > 0) it else null }
            val wayID = Json.long(e.opt("way_id"))
            result.add(RouteEdgeAttributes(
                startDistance = start, endDistance = end,
                names = Json.stringList(e.opt("names")) ?: emptyList(),
                speedLimitKmh = limit, laneCount = lanes,
                typicalSpeedKmh = double(e.opt("speed")),
                roadClass = e.opt("road_class") as? String,
                wayID = wayID, hasTrafficSignal = signal,
                surface = e.opt("surface") as? String, use = e.opt("use") as? String,
                isToll = Json.bool(e.opt("toll")) == true,
                isTunnel = Json.bool(e.opt("tunnel")) == true,
                isBridge = Json.bool(e.opt("bridge")) == true,
            ))
        }
        return result
    }

    fun parseTraceAttributes(data: ByteArray, fallbackPolyline: List<GeoPoint>): List<RouteEdgeAttributes> =
        parseTraceAttributes(String(data, Charsets.UTF_8), fallbackPolyline)

    /** Edge containing [distanceAlong] (binary search over sorted edges). */
    fun attributes(distanceAlong: Double, edges: List<RouteEdgeAttributes>): RouteEdgeAttributes? {
        if (edges.isEmpty()) return null
        var lo = 0
        var hi = edges.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) / 2
            val e = edges[mid]
            if (distanceAlong < e.startDistance) hi = mid - 1
            else if (distanceAlong > e.endDistance) lo = mid + 1
            else return e
        }
        return null
    }

    /** Signalised points along the route (end of each edge flagged with a traffic signal), merged within 60 m. */
    fun signalDistances(edges: List<RouteEdgeAttributes>): List<Double> {
        val result = ArrayList<Double>()
        for (e in edges) {
            if (!e.hasTrafficSignal) continue
            val last = result.lastOrNull()
            if (last != null && e.endDistance - last < 60) continue
            result.add(e.endDistance)
        }
        return result
    }
}

/**
 * Live congestion estimate on the current road segment from the user's own GPS speed
 * compared with the typical (OSM-derived) speed of the edge. Single-vehicle observation, not traffic data.
 */
object CongestionEstimator {
    /** Returns null when there is not enough information (unknown typical speed or very slow typical roads). */
    fun level(ownSpeedKmh: Double?, typicalSpeedKmh: Double?, stoppedAtSignal: Boolean = false): CongestionLevel? {
        if (ownSpeedKmh == null || typicalSpeedKmh == null || !(typicalSpeedKmh >= 20) || stoppedAtSignal) return null
        val ratio = ownSpeedKmh / typicalSpeedKmh
        return when {
            ratio >= 0.8 -> CongestionLevel.FREE
            ratio >= 0.6 && ratio < 0.8 -> CongestionLevel.LIGHT
            ratio >= 0.4 && ratio < 0.6 -> CongestionLevel.MODERATE
            ratio >= 0.2 && ratio < 0.4 -> CongestionLevel.HEAVY
            else -> CongestionLevel.SEVERE
        }
    }
}
