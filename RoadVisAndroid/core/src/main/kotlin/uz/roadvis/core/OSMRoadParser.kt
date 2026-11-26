package uz.roadvis.core

/** Parses OSM `maxspeed` values into km/h. */
object MaxSpeedParser {
    /**
     * Implicit limits for zone codes (`maxspeed=RU:urban` etc.), km/h.
     * Only countries whose defaults are known with certainty are listed; unknown zones yield null.
     */
    val zoneDefaults: Map<String, Int> = mapOf(
        "RU:urban" to 60, "RU:rural" to 90, "RU:living_street" to 20, "RU:motorway" to 110,
        "UZ:urban" to 70, "UZ:rural" to 100, "UZ:living_street" to 30, "UZ:motorway" to 110,
    )

    /**
     * Parses a single `maxspeed` value.
     *
     * Supported forms: `"60"` (km/h), `"60 km/h"`, `"50 mph"`, `"10 knots"`, zone codes (`"RU:urban"`, `"UZ:rural"`,
     * `"RU:zone30"`), `"walk"` (5 km/h, implicit) and multiple values `"60;40"` (the lowest is used, conservative).
     * Returns null for `"none"` (no posted limit), `"signals"`/`"variable"` (electronic signs) and anything unparseable.
     */
    fun parse(value: String?): SpeedLimit? {
        val raw = value?.swiftTrim()
        if (raw.isNullOrEmpty()) return null
        if (raw.contains(";")) {
            val parts = raw.split(";").filter { it.isNotEmpty() }.mapNotNull { parseSingle(it, raw) }
            return parts.minByOrNull { it.kmh }
        }
        return parseSingle(raw, raw)
    }

    /**
     * Speed limit for the travel direction: `maxspeed:forward` / `maxspeed:backward` first, then `maxspeed`,
     * then zone hints without an explicit number (`maxspeed:type`, `source:maxspeed`, `zone:maxspeed`) as implicit limits.
     */
    fun limit(tags: Map<String, String>, travelingForward: Boolean): SpeedLimit? {
        val directional = if (travelingForward) tags["maxspeed:forward"] else tags["maxspeed:backward"]
        parse(directional)?.let { return it }
        parse(tags["maxspeed"])?.let { return it }
        for (key in listOf("maxspeed:type", "source:maxspeed", "zone:maxspeed")) {
            val v = tags[key] ?: continue
            if (v.contains(":")) {
                val zone = parse(v)
                if (zone != null && zone.isImplicit) return zone
            }
        }
        return null
    }

    private fun parseSingle(value: String, raw: String): SpeedLimit? {
        val v = value.swiftTrim()
        val lower = v.lowercase()
        when (lower) {
            "", "none", "signals", "variable", "unknown", "no", "implicit" -> return null
            "walk" -> return SpeedLimit(5, raw, true)
        }

        // Zone code: "RU:urban", "UZ:living_street", "RU:zone30", "DE:zone:30".
        val colon = v.indexOf(':')
        if (colon == 2 && v.substring(0, 2).all { it.isLetter() }) {
            val country = v.substring(0, 2).uppercase()
            val zone = v.substring(colon + 1).lowercase()
            zoneDefaults["$country:$zone"]?.let { return SpeedLimit(it, raw, true) }
            if (zone.startsWith("zone")) {
                val digits = zone.drop(4).filter { it.isDigit() }
                val n = digits.toIntOrNull()
                if (n != null && n in 5..200) return SpeedLimit(n, raw, true)
            }
            return null
        }

        // Number with an optional unit.
        val numberPart = StringBuilder()
        var i = 0
        while (i < lower.length) {
            val ch = lower[i]
            if (!(ch.isDigit() || ch == '.' || ch == ',')) break
            numberPart.append(if (ch == ',') '.' else ch)
            i++
        }
        val number = Json.parseDouble(numberPart.toString()) ?: return null
        if (!(number > 0)) return null
        val unit = lower.substring(i).trim { it == ' ' || it == '\t' }
        val kmh = when (unit) {
            "", "km/h", "kmh", "kph", "км/ч" -> number
            "mph" -> number * 1.609344
            "knots", "knot", "kn" -> number * 1.852
            else -> return null
        }
        val r = kmh.rounded()
        if (!(r >= 1 && r <= 300)) return null
        return SpeedLimit(r.toInt(), raw, false)
    }
}

/** Interprets OSM road tags: one-way direction, lane counts, turn lanes and Russian road class names. */
object OSMRoadParser {
    /**
     * Parses `turn:lanes` (`"left|through;right|right"`) into lanes ordered left → right as seen by the driver.
     * Empty lane entries and `none` become `[NONE]`; `slide_left/right` are treated as slight turns;
     * unknown values are ignored (a lane with only unknown values has empty `turns` = unknown).
     */
    fun parseTurnLanes(value: String): List<Lane> {
        val trimmed = value.swiftTrim()
        if (trimmed.isEmpty()) return emptyList()
        return trimmed.split("|").map { laneValue ->
            val tokens = laneValue.split(";").map { it.trim { c -> c == ' ' || c == '\t' }.lowercase() }
            val turns = ArrayList<LaneTurn>()
            var hasUnknown = false
            for (token in tokens) {
                val turn: LaneTurn? = when (token) {
                    "", "none" -> LaneTurn.NONE
                    "slide_left" -> LaneTurn.SLIGHT_LEFT
                    "slide_right" -> LaneTurn.SLIGHT_RIGHT
                    else -> LaneTurn.fromRaw(token)
                }
                if (turn != null) {
                    if (!turns.contains(turn)) turns.add(turn)
                } else {
                    hasUnknown = true
                }
            }
            if (turns.size > 1) turns.removeAll { it == LaneTurn.NONE }
            if (turns.isEmpty() && !hasUnknown) turns.add(LaneTurn.NONE)
            Lane(turns.toList())
        }
    }

    /**
     * One-way direction relative to the way's drawing direction:
     * `1` = traffic only along the drawing direction, `-1` = only against it, `0` = both directions
     * (also for `reversible` / `alternating`, whose direction changes over time).
     * `highway=motorway`, `highway=motorway_link` and `junction=roundabout|circular` imply one-way unless tagged otherwise.
     */
    fun onewayDirection(tags: Map<String, String>): Int {
        val explicit = tags["oneway:motor_vehicle"] ?: tags["oneway:vehicle"] ?: tags["oneway"]
        if (explicit != null) {
            when (explicit.trim { it == ' ' || it == '\t' }.lowercase()) {
                "yes", "true", "1" -> return 1
                "-1", "reverse" -> return -1
                "no", "false", "0", "reversible", "alternating" -> return 0
            }
        }
        val junction = tags["junction"]?.lowercase()
        if (junction == "roundabout" || junction == "circular") return 1
        val highway = tags["highway"]?.lowercase()
        if (highway == "motorway" || highway == "motorway_link") return 1
        return 0
    }

    /**
     * Lane information for the user's travel direction.
     *
     * - Uses `lanes`, `lanes:forward` / `lanes:backward`, `lanes:both_ways` (shared centre turn lane, counted in the
     *   total but in neither direction) and `turn:lanes`, `turn:lanes:forward` / `turn:lanes:backward`.
     * - Missing direction split on a two-way road: the remainder after the known direction, else an even split;
     *   an odd total without a split leaves the per-direction counts null (except a single shared lane: 1 / 1).
     * - Missing `lanes`: counts are derived from `turn:lanes*` lengths; if nothing is mapped the count comes from
     *   the road class ([defaultLaneCount]) and `isEstimated` is true.
     * - One-way roads: `lanesInDirection = lanes`, `lanesOpposite = 0`. When travelling against a one-way road
     *   (wrong match or wrong-way driving) the road's lane count is still returned, without turn arrows.
     */
    fun laneInfo(tags: Map<String, String>, travelingForward: Boolean): LaneInfo {
        val direction = onewayDirection(tags)
        val highway = tags["highway"]?.lowercase() ?: ""
        val total = count(tags["lanes"])
        val forward = count(tags["lanes:forward"])
        val backward = count(tags["lanes:backward"])
        val centre = count(tags["lanes:both_ways"]) ?: 0
        val turnLanes = tags["turn:lanes"]?.let(::parseTurnLanes) ?: emptyList()
        val turnForward = tags["turn:lanes:forward"]?.let(::parseTurnLanes) ?: emptyList()
        val turnBackward = tags["turn:lanes:backward"]?.let(::parseTurnLanes) ?: emptyList()

        if (direction != 0) {
            val allowedForward = direction == 1
            val directionalCount = if (allowedForward) forward else backward
            val directionalTurns = if (turnLanes.isEmpty()) (if (allowedForward) turnForward else turnBackward) else turnLanes
            var estimated = false
            var lanesCount = total ?: directionalCount ?: (if (directionalTurns.isEmpty()) null else directionalTurns.size)
            if (lanesCount == null) {
                val fallback = defaultLaneCount(highway, oneway = true)
                if (fallback != null) {
                    lanesCount = fallback
                    estimated = true
                }
            }
            val withTraffic = travelingForward == allowedForward
            return LaneInfo(lanesCount, lanesCount, if (lanesCount == null) null else 0,
                if (withTraffic) directionalTurns else emptyList(), isOneway = true, isEstimated = estimated)
        }

        // Two-way road.
        var fwd = forward
        var bwd = backward
        var estimated = false
        var totalLanes = total

        if (fwd == null && turnForward.isNotEmpty()) fwd = turnForward.size
        if (bwd == null && turnBackward.isNotEmpty()) bwd = turnBackward.size

        if (totalLanes != null) {
            val t = totalLanes
            val f0 = fwd
            if (f0 != null && bwd == null && t - f0 - centre > 0) bwd = t - f0 - centre
            val b0 = bwd
            if (b0 != null && fwd == null && t - b0 - centre > 0) fwd = t - b0 - centre
            if (fwd == null && bwd == null) {
                val remainder = t - centre
                if (remainder == 1) {
                    // A single lane shared by both directions (narrow street).
                    fwd = 1
                    bwd = 1
                } else if (remainder > 0 && remainder % 2 == 0) {
                    fwd = remainder / 2
                    bwd = remainder / 2
                }
            }
        } else if (fwd != null && bwd != null) {
            totalLanes = fwd + bwd + centre
        } else if (fwd == null && bwd == null) {
            val fallback = defaultLaneCount(highway, oneway = false)
            if (fallback != null) {
                estimated = true
                totalLanes = fallback
                if (fallback == 1) {
                    fwd = 1
                    bwd = 1
                } else {
                    fwd = fallback / 2
                    bwd = fallback - fallback / 2
                }
            }
        }

        val ourLanes = if (travelingForward) turnForward else turnBackward
        var inDirection = if (travelingForward) fwd else bwd
        val opposite = if (travelingForward) bwd else fwd
        if (inDirection == null && ourLanes.isNotEmpty()) inDirection = ourLanes.size
        return LaneInfo(totalLanes, inDirection, opposite, ourLanes, isOneway = false, isEstimated = estimated)
    }

    /**
     * Typical lane count when `lanes` is not mapped: lanes in the one direction for one-way roads,
     * both directions together otherwise. null for unknown / non-drivable classes.
     */
    fun defaultLaneCount(highway: String, oneway: Boolean): Int? = when (highway.lowercase()) {
        "motorway", "trunk" -> 2   // usually separate one-way carriageways with 2 lanes each
        "primary", "secondary", "tertiary", "residential" -> if (oneway) 1 else 2
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link" -> if (oneway) 1 else 2
        "living_street", "unclassified", "service", "track" -> 1
        else -> null
    }

    /** Russian name of a road class (`highway=*`), used when a road has no name or ref. */
    fun highwayDisplayName(highway: String): String = when (highway.lowercase()) {
        "motorway" -> "Автомагистраль"
        "trunk" -> "Магистраль"
        "primary" -> "Главная дорога"
        "secondary" -> "Дорога районного значения"
        "tertiary" -> "Улица местного значения"
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link" -> "Съезд"
        "residential" -> "Жилая улица"
        "living_street" -> "Жилая зона"
        "service" -> "Проезд"
        "unclassified" -> "Местная дорога"
        "track" -> "Грунтовая дорога"
        "road" -> "Дорога"
        "busway", "bus_guideway" -> "Выделенная дорога для автобусов"
        "escape" -> "Аварийный съезд"
        "raceway" -> "Гоночная трасса"
        "pedestrian" -> "Пешеходная улица"
        "footway" -> "Пешеходная дорожка"
        "path" -> "Тропа"
        "cycleway" -> "Велодорожка"
        "steps" -> "Лестница"
        "bridleway" -> "Конная тропа"
        "construction" -> "Строящаяся дорога"
        "proposed" -> "Проектируемая дорога"
        else -> "Дорога"
    }

    /** Road class rank used for tie-breaking (0 = most important). Unknown classes rank last. */
    fun roadClassRank(highway: String): Int = when (highway.lowercase()) {
        "motorway" -> 0
        "trunk" -> 1
        "primary" -> 2
        "secondary" -> 3
        "tertiary" -> 4
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link" -> 5
        "unclassified", "residential" -> 6
        "living_street" -> 7
        "service", "road", "busway" -> 8
        "track" -> 9
        else -> 10
    }

    /** First positive integer in a lane-count tag ("2", "2;3", " 3 "). */
    private fun count(value: String?): Int? {
        if (value == null) return null
        val first = value.split(";").firstOrNull { it.isNotEmpty() }?.trim { it == ' ' || it == '\t' } ?: ""
        val n = first.toIntOrNull() ?: return null
        return if (n in 1..49) n else null
    }
}
