package uz.roadvis.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Travel-time estimate of another engine for (nearly) the same route. */
data class RouteEstimate(val source: RouteSource, val expectedTravelTime: Double, val distance: Double)

/** One distinct route option after merging the candidates of all engines. */
data class RouteChoice(
    /** Representative route (the fastest of its group). */
    val route: NavRoute,
    /** Other engines that found (nearly) the same route, with their own estimates. */
    val duplicates: List<RouteEstimate> = emptyList(),
) {
    data class TimeRange(val min: Double, val max: Double)

    /** All engines that found this route, representative first. */
    val sources: List<RouteSource>
        get() {
            val result = arrayListOf(route.source)
            for (d in duplicates) if (!result.contains(d.source)) result.add(d.source)
            return result
        }

    /** Range of the engines' travel-time estimates (min, max), seconds. */
    val timeRange: TimeRange
        get() {
            val times = listOf(route.expectedTravelTime) + duplicates.map { it.expectedTravelTime }
            return TimeRange(times.minOrNull() ?: 0.0, times.maxOrNull() ?: 0.0)
        }
}

/** Facts about one route used by the comparison cards. */
data class RouteFacts(
    val distance: Double,
    val expectedTravelTime: Double,
    /** distance / time, km/h. */
    val averageSpeedKmh: Double?,
    /** Signalised intersections (edge attributes, else the given count). */
    val signalCount: Int?,
    val maxSpeedLimitKmh: Int?,
    /** Distance-weighted mean posted limit over the edges that have one, km/h. */
    val averageSpeedLimitKmh: Double?,
    /** Share of the route length with a known speed limit (0…1), null without edges. */
    val speedLimitCoverage: Double?,
    /** Share of the length on motorway / trunk / primary roads (0…1), null without edges. */
    val primaryRoadShare: Double?,
    /** Share of the length on unpaved surfaces (0…1), null without edges. */
    val unpavedShare: Double?,
    val hasTolls: Boolean,
    val hasHighways: Boolean,
    /** Announced maneuvers (steps after the departure with an instruction). */
    val maneuverCount: Int,
    val tunnelCount: Int,
    val bridgeCount: Int,
)

/** Merging, de-duplication and ranking of route candidates from several engines (Apple, Valhalla, OSRM). */
object RouteComparison {
    /** Two routes are "the same" when at least this share of each one's sampled points lies near the other. */
    const val defaultOverlapThreshold = 0.85
    /** Lateral tolerance for overlap sampling, metres. */
    const val defaultTolerance: Double = 30.0
    /** Spacing of the sampled points, metres. */
    const val defaultSpacing: Double = 40.0

    /** Points every [spacing] metres along the polyline (first and last vertex included). */
    fun samples(polyline: List<GeoPoint>, spacing: Double = defaultSpacing): List<GeoPoint> {
        if (polyline.size < 2 || !(spacing > 0)) return polyline
        val result = arrayListOf(polyline[0])
        var carried = 0.0
        for (i in 1 until polyline.size) {
            val a = polyline[i - 1]
            val b = polyline[i]
            val length = Geo.distance(a, b)
            if (!(length > 0)) continue
            var d = spacing - carried
            while (d <= length) {
                val t = d / length
                result.add(GeoPoint(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t))
                d += spacing
            }
            carried = length - (d - spacing)
        }
        val last = polyline.last()
        if (result.last() != last) result.add(last)
        return result
    }

    /**
     * Share (0…1) of the sampled points of [a] that lie within [tolerance] metres of polyline [b].
     * Uses a local metric grid over densely sampled [b], so it is fast for long routes.
     */
    fun overlap(a: List<GeoPoint>, b: List<GeoPoint>, spacing: Double = defaultSpacing,
                tolerance: Double = defaultTolerance): Double {
        val sa = samples(a, spacing)
        if (sa.isEmpty() || b.size < 2) return 0.0
        // Dense samples of b (≤ tolerance / 3 apart) approximate the line within a few metres.
        val step = max(2.0, tolerance / 3)
        val sb = samples(b, step)
        val origin = sb[0]
        val metersPerDegLat = Geo.EARTH_RADIUS * PI / 180
        val metersPerDegLon = metersPerDegLat * max(0.01, cos(origin.latitude * PI / 180))
        fun localX(p: GeoPoint) = (p.longitude - origin.longitude) * metersPerDegLon
        fun localY(p: GeoPoint) = (p.latitude - origin.latitude) * metersPerDegLat
        val cell = tolerance
        val grid = HashMap<Pair<Int, Int>, MutableList<DoubleArray>>()
        for (p in sb) {
            val x = localX(p)
            val y = localY(p)
            grid.getOrPut(floor(x / cell).toInt() to floor(y / cell).toInt()) { ArrayList() }.add(doubleArrayOf(x, y))
        }
        val limit = tolerance + step / 2
        val limitSquared = limit * limit
        var hits = 0
        for (p in sa) {
            val x = localX(p)
            val y = localY(p)
            val cx = floor(x / cell).toInt()
            val cy = floor(y / cell).toInt()
            var found = false
            outer@ for (dx in -1..1) {
                for (dy in -1..1) {
                    val bucket = grid[(cx + dx) to (cy + dy)] ?: continue
                    for (q in bucket) {
                        val ex = q[0] - x
                        val ey = q[1] - y
                        if (ex * ex + ey * ey <= limitSquared) { found = true; break@outer }
                    }
                }
            }
            if (found) hits += 1
        }
        return hits.toDouble() / sa.size
    }

    /** Symmetric similarity: min(overlap(a, b), overlap(b, a)). */
    fun similarity(a: List<GeoPoint>, b: List<GeoPoint>, tolerance: Double = defaultTolerance): Double =
        min(overlap(a, b, tolerance = tolerance), overlap(b, a, tolerance = tolerance))

    /**
     * Merges candidates from all engines: ranks them by expected travel time, folds near-identical routes
     * (similarity ≥ [threshold]) into the faster one (recording the other engines' estimates) and returns the
     * distinct choices, fastest first.
     */
    fun merge(routes: List<NavRoute>, threshold: Double = defaultOverlapThreshold,
              tolerance: Double = defaultTolerance): List<RouteChoice> {
        val ranked = routes.filter { it.polyline.size >= 2 }.sortedBy { it.expectedTravelTime }
        val choices = ArrayList<RouteChoice>()
        for (route in ranked) {
            val index = choices.indexOfFirst {
                // Cheap pre-check on length before the geometric test.
                val d1 = it.route.distance
                val d2 = route.distance
                if (!(max(d1, d2) > 0) || !(abs(d1 - d2) / max(d1, d2) < 0.2)) false
                else similarity(it.route.polyline, route.polyline, tolerance) >= threshold
            }
            if (index >= 0) {
                val c = choices[index]
                choices[index] = c.copy(duplicates = c.duplicates + RouteEstimate(route.source, route.expectedTravelTime, route.distance))
            } else {
                choices.add(RouteChoice(route))
            }
        }
        return choices
    }

    /** Facts for the comparison card. [edges] are Valhalla trace attributes of this route (may be empty). */
    fun facts(route: NavRoute, edges: List<RouteEdgeAttributes>, signalCount: Int? = null): RouteFacts {
        val average = if (route.expectedTravelTime > 0) route.distance / route.expectedTravelTime * 3.6 else null
        var signals = signalCount
        var maxLimit: Int? = null
        var avgLimit: Double? = null
        var coverage: Double? = null
        var primaryShare: Double? = null
        var unpavedShare: Double? = null
        var tunnels = 0
        var bridges = 0
        var tolls = route.hasTolls
        if (edges.isNotEmpty()) {
            val total = edges.sumOf { it.length }
            var limitLength = 0.0
            var limitSum = 0.0
            var primary = 0.0
            var unpaved = 0.0
            var previousTunnel = false
            var previousBridge = false
            for (e in edges) {
                val limit = e.speedLimitKmh
                if (limit != null) {
                    limitLength += e.length
                    limitSum += limit * e.length
                    maxLimit = max(maxLimit ?: 0, limit)
                }
                if (e.isPrimaryRoad) primary += e.length
                if ((e.surface ?: "") in listOf("compacted", "dirt", "gravel", "path", "impassable")) unpaved += e.length
                if (e.isTunnel && !previousTunnel) tunnels += 1
                if (e.isBridge && !previousBridge) bridges += 1
                if (e.isToll) tolls = true
                previousTunnel = e.isTunnel
                previousBridge = e.isBridge
            }
            if (limitLength > 0) avgLimit = limitSum / limitLength
            if (total > 0) {
                coverage = limitLength / total
                primaryShare = primary / total
                unpavedShare = unpaved / total
            }
            signals = Valhalla.signalDistances(edges).size
        }
        val maneuvers = route.steps.withIndex().count { (index, step) ->
            index > 0 && step.instruction.swiftTrim().isNotEmpty() && step.resolvedManeuver != ManeuverType.ARRIVE
        }
        return RouteFacts(route.distance, route.expectedTravelTime, average, signals, maxLimit, avgLimit, coverage,
            primaryShare, unpavedShare, tolls, route.hasHighways, maneuvers, tunnels, bridges)
    }

    /** "+4 мин", "+30 с", null for the fastest (or when not slower). */
    fun delayText(seconds: Double, comparedTo: Double): String? {
        val delta = seconds - comparedTo
        if (!(delta >= 30)) return null
        return "+" + RVFormat.duration(delta)
    }

    /** [delayText] in [language]. */
    fun delayText(seconds: Double, comparedTo: Double, language: RVLang): String? {
        val delta = seconds - comparedTo
        if (!(delta >= 30)) return null
        return "+" + RVFormat.duration(delta, language)
    }

    /** Russian notes explaining the comparison (differences between engines, duplicates, time spread). */
    fun notes(choices: List<RouteChoice>): List<String> = notes(choices, RVLang.RU)

    /** Notes explaining the comparison in [language]. */
    fun notes(choices: List<RouteChoice>, language: RVLang): List<String> {
        if (choices.isEmpty()) return emptyList()
        fun duration(s: Double) = RVFormat.duration(s, language)
        val notes = ArrayList<String>()
        val allSources = choices.flatMap { it.sources }.toSet()
        if (allSources.contains(RouteSource.APPLE) && allSources.size > 1) {
            notes.add(when (language) {
                RVLang.RU -> "Время Apple может учитывать пробки (где у Apple есть данные), время Valhalla и OSRM — " +
                    "по типичным скоростям OpenStreetMap, без пробок."
                RVLang.UZ -> "Apple vaqti tirbandlikni hisobga olishi mumkin (Apple’da ma’lumot bor joylarda), Valhalla va " +
                    "OSRM vaqti esa OpenStreetMap’ning odatiy tezliklari bo‘yicha, tirbandliksiz."
                RVLang.EN -> "Apple’s time may include traffic (where Apple has data); Valhalla and OSRM times use " +
                    "typical OpenStreetMap speeds, without traffic."
            })
        } else if (!allSources.contains(RouteSource.APPLE)) {
            notes.add(when (language) {
                RVLang.RU -> "Время рассчитано по типичным скоростям OpenStreetMap, без учёта пробок (≈ оценка)."
                RVLang.UZ -> "Vaqt OpenStreetMap’ning odatiy tezliklari bo‘yicha, tirbandliksiz hisoblangan (≈ taxmin)."
                RVLang.EN -> "Times are based on typical OpenStreetMap speeds, without traffic (≈ estimate)."
            })
        }
        if (choices.size >= 2) {
            val gap = choices[1].route.expectedTravelTime - choices[0].route.expectedTravelTime
            if (gap >= 60) {
                notes.add(when (language) {
                    RVLang.RU -> "Самый быстрый вариант выигрывает ≈ ${duration(gap)} у следующего (оценка)."
                    RVLang.UZ -> "Eng tez variant keyingisidan ≈ ${duration(gap)} yutadi (taxmin)."
                    RVLang.EN -> "The fastest option saves ≈ ${duration(gap)} over the next one (estimate)."
                })
            } else {
                notes.add(when (language) {
                    RVLang.RU -> "Первые варианты почти равны по времени (разница < 1 мин) — выбирайте по удобству."
                    RVLang.UZ -> "Birinchi variantlar vaqt bo‘yicha deyarli teng (farq < 1 daq) — qulayini tanlang."
                    RVLang.EN -> "The top options take almost the same time (difference < 1 min) — choose the most convenient."
                })
            }
        }
        for (choice in choices) {
            val range = choice.timeRange
            if (choice.duplicates.isNotEmpty() && range.max - range.min >= 120) {
                val names = choice.sources.joinToString(", ") { it.badge }
                val spread = "${duration(range.min)}–${duration(range.max)}"
                notes.add(when (language) {
                    RVLang.RU -> "Маршрут «${choice.route.name}» нашли $names; оценки времени расходятся: $spread."
                    RVLang.UZ -> "«${choice.route.name}» yo‘nalishini $names topdi; vaqt baholari farq qiladi: $spread."
                    RVLang.EN -> "Route “${choice.route.name}” was found by $names; time estimates differ: $spread."
                })
            }
        }
        return notes
    }
}
