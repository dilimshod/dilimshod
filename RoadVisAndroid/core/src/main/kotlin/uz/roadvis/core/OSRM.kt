package uz.roadvis.core

import org.json.JSONObject
import java.net.URI
import java.util.Locale

/** Error reported by an OSRM server (`{"code": "NoRoute", "message": "…"}`) or produced while parsing. */
data class OSRMError(
    /** OSRM status code ("NoRoute", "NoSegment", "TooBig", "InvalidQuery" …); null for parse problems. */
    val code: String?,
    override val message: String,
) : Exception(message) {
    override fun toString(): String = message

    /** Russian explanation for the well-known OSRM codes. */
    val russianDescription: String
        get() = when (code) {
            "NoRoute" -> "OSRM не нашёл маршрут между этими точками."
            "NoSegment" -> "Рядом с точкой старта или назначения нет дорог в OpenStreetMap (OSRM)."
            "TooBig" -> "Запрос слишком большой для сервера OSRM."
            "InvalidQuery", "InvalidValue", "InvalidOptions", "InvalidUrl", "InvalidService", "InvalidVersion" ->
                "Сервер OSRM отклонил запрос ($code): $message"
            null -> "Ответ OSRM не удалось разобрать: $message"
            else -> "Ошибка OSRM ($code): $message"
        }
}

/**
 * Request building and response parsing for an OSRM routing server (default: FOSSGIS
 * `https://routing.openstreetmap.de/routed-car` — light use only, ≤ 1 request/s, identifying User-Agent,
 * OSM attribution). OSRM returns no text instructions, so Russian instructions are built here from the maneuver
 * type / modifier / street name.
 */
object OSRM {
    const val defaultEndpoint = "https://routing.openstreetmap.de/routed-car"

    // Request

    /**
     * `GET {endpoint}/route/v1/driving/{lon},{lat};{lon},{lat}?overview=full&geometries=polyline6&steps=true&alternatives=true&annotations=true`.
     * Returns null when the endpoint is not an http(s) URL with a host or a coordinate is invalid.
     */
    fun routeURL(endpoint: String, origin: GeoPoint, destination: GeoPoint, alternatives: Boolean = true): String? {
        if (!origin.isValid || !destination.isValid) return null
        var base = endpoint.swiftTrim()
        while (base.endsWith("/")) base = base.dropLast(1)
        val coordinates = listOf(origin, destination)
            .joinToString(";") { String.format(Locale.US, "%.6f,%.6f", it.longitude, it.latitude) }
        val query = "overview=full&geometries=polyline6&steps=true&alternatives=$alternatives&annotations=true"
        val url = "$base/route/v1/driving/$coordinates?$query"
        val uri = try { URI(url) } catch (e: Exception) { return null }
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "https" && scheme != "http") return null
        if (uri.host == null) return null
        return url
    }

    // Response

    /**
     * Parses an OSRM `/route` response into routes (main route first, then alternatives).
     * @throws OSRMError for server errors (`code != "Ok"`) and malformed bodies.
     * [language] selects the instruction text (default Russian; uz / en via [NavInstructionText]).
     */
    fun parseRoutes(json: String, language: RVLang = RVLang.RU): List<NavRoute> {
        val obj = Json.parseObject(json) ?: throw OSRMError(null, "ответ не является JSON")
        val code = obj.opt("code") as? String
        if (code != "Ok") {
            throw OSRMError(code ?: "Unknown", obj.opt("message") as? String ?: "неизвестная ошибка")
        }
        val routes = Json.objectList(obj.opt("routes"))
        if (routes.isNullOrEmpty()) throw OSRMError("NoRoute", "в ответе нет маршрутов")
        return routes.mapNotNull { r ->
            try { parseRoute(r, language) } catch (e: OSRMError) { null }
        }.filter { it.polyline.size >= 2 }
    }

    fun parseRoutes(data: ByteArray, language: RVLang = RVLang.RU): List<NavRoute> =
        parseRoutes(String(data, Charsets.UTF_8), language)

    internal fun parseRoute(route: JSONObject, language: RVLang = RVLang.RU): NavRoute {
        val polyline = Polyline.decode(route.opt("geometry") as? String ?: "", 6)
        if (polyline.size < 2) throw OSRMError(null, "маршрут без геометрии")
        val legs = Json.objectList(route.opt("legs")) ?: emptyList()
        val steps = ArrayList<RouteStepInfo>()
        val summaries = ArrayList<String>()
        val nameLengths = HashMap<String, Double>()
        val nameOrder = ArrayList<String>()
        var hasTolls = false
        var hasHighways = false

        for ((legIndex, leg) in legs.withIndex()) {
            val summary = (leg.opt("summary") as? String)?.swiftTrim()
            if (!summary.isNullOrEmpty() && !summaries.contains(summary)) summaries.add(summary)
            val rawSteps = Json.objectList(leg.opt("steps")) ?: emptyList()
            for ((stepIndex, step) in rawSteps.withIndex()) {
                val maneuver = step.opt("maneuver") as? JSONObject ?: JSONObject()
                val type = maneuver.opt("type") as? String ?: "turn"
                // Intermediate depart/arrive between legs are not real maneuvers.
                if (legIndex > 0 && stepIndex == 0 && type == "depart") continue
                if (legIndex < legs.size - 1 && type == "arrive") continue
                val modifier = maneuver.opt("modifier") as? String
                val exit = Valhalla.int(maneuver.opt("exit"))
                val name = nonEmpty(step.opt("name") as? String)
                val ref = nonEmpty(step.opt("ref") as? String)
                val rotaryName = nonEmpty(step.opt("rotary_name") as? String)
                val distance = Valhalla.double(step.opt("distance")) ?: 0.0
                val intersections = Json.objectList(step.opt("intersections")) ?: emptyList()
                for (intersection in intersections) {
                    val classes = Json.stringList(intersection.opt("classes")) ?: emptyList()
                    if (classes.contains("toll")) hasTolls = true
                    if (classes.contains("motorway")) hasHighways = true
                }
                val laneData = Json.objectList(intersections.firstOrNull()?.opt("lanes")) ?: emptyList()
                val (lanes, valid) = lanes(laneData.map {
                    OSRMLane(Json.stringList(it.opt("indications")) ?: emptyList(), Json.bool(it.opt("valid")) ?: false)
                })
                val street = name ?: ref
                if (street != null) {
                    if (nameLengths[street] == null) nameOrder.add(street)
                    nameLengths[street] = (nameLengths[street] ?: 0.0) + distance
                }
                val text = NavInstructionText.osrm(type, modifier, street, exit, rotaryName, language)
                steps.add(RouteStepInfo(text, distance, null, maneuverType(type, modifier), lanes, valid,
                    street?.let { listOf(it) } ?: emptyList()))
            }
        }
        // A step's maneuver happens at its start; step 0 is the departure and is never announced.
        if (steps.isNotEmpty() && steps[0].maneuver == ManeuverType.DEPART) steps[0] = steps[0].copy(instruction = "")

        val distance = Valhalla.double(route.opt("distance")) ?: Geo.polylineLength(polyline)
        val duration = Valhalla.double(route.opt("duration")) ?: 0.0
        val name: String = if (summaries.isNotEmpty()) {
            summaries.joinToString(", ")
        } else {
            val top = nameOrder.sortedByDescending { nameLengths[it] ?: 0.0 }.take(2)
            if (top.isEmpty()) NavInstructionText.fallbackRouteName("OSRM", language) else top.joinToString(", ")
        }
        return NavRoute(RouteSource.OSRM, name, polyline,
            if (distance > 0) distance else Geo.polylineLength(polyline),
            duration, steps, hasTolls = hasTolls, hasHighways = hasHighways, advisories = emptyList())
    }

    // Maneuvers

    /** OSRM maneuver type + modifier → ManeuverType. */
    fun maneuverType(type: String, modifier: String?): ManeuverType {
        val mod = modifier ?: ""
        val leftward = mod.contains("left")
        val rightward = mod.contains("right")
        return when (type) {
            "depart" -> ManeuverType.DEPART
            "arrive" -> ManeuverType.ARRIVE
            "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary" -> ManeuverType.ROUNDABOUT
            "merge" -> ManeuverType.MERGE
            "fork" -> if (leftward) ManeuverType.KEEP_LEFT else if (rightward) ManeuverType.KEEP_RIGHT else ManeuverType.STRAIGHT
            "off ramp" -> if (leftward) ManeuverType.EXIT_LEFT else ManeuverType.EXIT_RIGHT
            else -> turnType(modifier)
        }
    }

    internal fun turnType(modifier: String?): ManeuverType = when (modifier) {
        "uturn" -> ManeuverType.U_TURN
        "sharp right" -> ManeuverType.SHARP_RIGHT
        "right" -> ManeuverType.RIGHT
        "slight right" -> ManeuverType.SLIGHT_RIGHT
        "sharp left" -> ManeuverType.SHARP_LEFT
        "left" -> ManeuverType.LEFT
        "slight left" -> ManeuverType.SLIGHT_LEFT
        else -> ManeuverType.STRAIGHT
    }

    /**
     * Russian instruction for an OSRM step, e.g. turn + left + "Навои" → "Поверните налево на Навои",
     * roundabout with exit 2 → "На круговом движении — 2-й съезд", arrive → "Пункт назначения".
     */
    fun instruction(type: String, modifier: String?, name: String?, exit: Int? = null, rotaryName: String? = null): String {
        val onto = name?.let { " на $it" } ?: ""
        val along = name?.let { " по $it" } ?: ""
        return when (type) {
            "depart" -> "Начните движение$along"
            "arrive" -> when (modifier) {
                "left", "slight left", "sharp left" -> "Пункт назначения слева"
                "right", "slight right", "sharp right" -> "Пункт назначения справа"
                else -> "Пункт назначения"
            }
            "roundabout", "rotary" -> {
                val circle = rotaryName?.let { "На круговом движении «$it»" } ?: "На круговом движении"
                if (exit != null && exit > 0) "$circle — $exit-й съезд$onto"
                else "Въезжайте на круговое движение$onto"
            }
            "roundabout turn" -> "На круговом движении " + turnPhrase(modifier).rvLowercasedFirst() + onto
            "exit roundabout", "exit rotary" -> "Съезжайте с кругового движения$onto"
            "merge" -> when (modifier) {
                "left", "slight left", "sharp left" -> "Перестройтесь левее и влейтесь в поток$onto"
                "right", "slight right", "sharp right" -> "Перестройтесь правее и влейтесь в поток$onto"
                else -> "Влейтесь в поток$onto"
            }
            "on ramp" -> "Сверните ${directionWord(modifier)} на въезд$onto"
            "off ramp" -> "Сверните ${directionWord(modifier)} на съезд$onto"
            "fork" -> when (modifier) {
                "left", "slight left", "sharp left" -> "На развилке держитесь левее$onto"
                "right", "slight right", "sharp right" -> "На развилке держитесь правее$onto"
                else -> "На развилке двигайтесь прямо$onto"
            }
            "end of road" -> "В конце дороги " + turnPhrase(modifier).rvLowercasedFirst() + onto
            "new name", "continue", "notification" ->
                if (modifier == null || modifier == "straight") "Продолжайте движение" + (if (name == null) " прямо" else along)
                else turnPhrase(modifier) + onto
            else -> // "turn" and unknown types
                if (modifier == "straight") "Двигайтесь прямо$along" else turnPhrase(modifier) + onto
        }
    }

    internal fun turnPhrase(modifier: String?): String = when (modifier) {
        "uturn" -> "Развернитесь"
        "sharp right" -> "Резко поверните направо"
        "right" -> "Поверните направо"
        "slight right" -> "Держитесь правее"
        "sharp left" -> "Резко поверните налево"
        "left" -> "Поверните налево"
        "slight left" -> "Держитесь левее"
        else -> "Двигайтесь прямо"
    }

    internal fun directionWord(modifier: String?): String {
        if (modifier == null) return "направо"
        if (modifier.contains("left")) return "налево"
        if (modifier == "straight") return "прямо"
        return "направо"
    }

    // Lanes

    data class OSRMLane(val indications: List<String>, val valid: Boolean)

    /** OSRM lane indication → LaneTurn. */
    fun laneTurn(indication: String): LaneTurn = when (indication) {
        "uturn" -> LaneTurn.REVERSE
        "sharp right" -> LaneTurn.SHARP_RIGHT
        "right" -> LaneTurn.RIGHT
        "slight right" -> LaneTurn.SLIGHT_RIGHT
        "straight" -> LaneTurn.THROUGH
        "slight left" -> LaneTurn.SLIGHT_LEFT
        "left" -> LaneTurn.LEFT
        "sharp left" -> LaneTurn.SHARP_LEFT
        else -> LaneTurn.NONE
    }

    /** Lanes (left → right) and whether each is recommended (`valid`). */
    fun lanes(raw: List<OSRMLane>): Pair<List<Lane>, List<Boolean>> {
        if (raw.isEmpty()) return emptyList<Lane>() to emptyList()
        val lanes = raw.map { lane -> Lane(lane.indications.map(::laneTurn).filter { it != LaneTurn.NONE }) }
        return lanes to raw.map { it.valid }
    }

    private fun nonEmpty(s: String?): String? {
        val t = s?.swiftTrim()
        return if (t.isNullOrEmpty()) null else t
    }
}
