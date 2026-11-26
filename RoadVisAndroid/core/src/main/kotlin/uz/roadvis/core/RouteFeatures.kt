package uz.roadvis.core

import kotlin.math.max

/** Kind of a road feature along the route (from OSM). */
enum class RouteFeatureKind(val raw: String) {
    TRAFFIC_SIGNALS("trafficSignals"), PEDESTRIAN_CROSSING("pedestrianCrossing"), SPEED_CAMERA("speedCamera"),
    TRAFFIC_CALMING("trafficCalming"), RAILWAY_CROSSING("railwayCrossing"), SCHOOL("school"),
    KINDERGARTEN("kindergarten"), CONSTRUCTION("construction"), STOP_SIGN("stopSign"), GIVE_WAY("giveWay"),
    FUEL("fuel"), PARKING("parking");

    /** Russian display name. */
    val displayName: String
        get() = when (this) {
            TRAFFIC_SIGNALS -> "Светофор"
            PEDESTRIAN_CROSSING -> "Пешеходный переход"
            SPEED_CAMERA -> "Камера контроля скорости"
            TRAFFIC_CALMING -> "Искусственная неровность"
            RAILWAY_CROSSING -> "Железнодорожный переезд"
            SCHOOL -> "Школа"
            KINDERGARTEN -> "Детский сад"
            CONSTRUCTION -> "Дорожные работы"
            STOP_SIGN -> "Знак STOP"
            GIVE_WAY -> "Уступите дорогу"
            FUEL -> "АЗС"
            PARKING -> "Парковка"
        }

    /** SF Symbol name (kept from iOS; map to a drawable in the app). */
    val symbolName: String
        get() = when (this) {
            TRAFFIC_SIGNALS -> "light.beacon.max"
            PEDESTRIAN_CROSSING -> "figure.walk"
            SPEED_CAMERA -> "camera.fill"
            TRAFFIC_CALMING -> "exclamationmark.triangle"
            RAILWAY_CROSSING -> "tram.fill"
            SCHOOL -> "graduationcap.fill"
            KINDERGARTEN -> "figure.and.child.holdinghands"
            CONSTRUCTION -> "cone.fill"
            STOP_SIGN -> "octagon.fill"
            GIVE_WAY -> "arrowtriangle.down"
            FUEL -> "fuelpump.fill"
            PARKING -> "parkingsign"
        }

    /** Distance (metres) before the feature at which the driver should be warned. */
    val alertDistance: Double
        get() = when (this) {
            TRAFFIC_SIGNALS -> 300.0
            PEDESTRIAN_CROSSING -> 150.0
            SPEED_CAMERA -> 500.0
            TRAFFIC_CALMING -> 150.0
            RAILWAY_CROSSING -> 400.0
            SCHOOL, KINDERGARTEN -> 300.0
            CONSTRUCTION -> 500.0
            STOP_SIGN -> 200.0
            GIVE_WAY -> 150.0
            FUEL -> 500.0
            PARKING -> 300.0
        }

    /** Points of interest (fuel, parking) — informational, never announced as hazards. */
    val isPointOfInterest: Boolean get() = this == FUEL || this == PARKING

    /** Features of the same kind closer than this along the route are merged into one (metres). */
    val mergeRadius: Double
        get() = when (this) {
            TRAFFIC_SIGNALS -> 60.0   // all signal heads of one intersection
            PEDESTRIAN_CROSSING -> 25.0
            FUEL -> 60.0
            PARKING -> 80.0
            else -> 30.0
        }

    /** Maximum lateral distance from the route at which the feature is still relevant, given the default. */
    fun maxOffset(default: Double): Double = when (this) {
        SCHOOL, KINDERGARTEN -> max(default, 150.0)
        FUEL -> max(default, 100.0)
        PARKING -> max(default, 60.0)
        else -> default
    }

    companion object {
        fun fromRaw(raw: String): RouteFeatureKind? = entries.firstOrNull { it.raw == raw }
    }
}

/** A road feature projected onto the active route. */
data class RouteFeature(
    /**
     * OSM key of the representative element, e.g. `"node/123"` (for a merged cluster: the element with the
     * smallest OSM id, so the identity stays stable between queries).
     */
    val id: String,
    val kind: RouteFeatureKind,
    val coordinate: GeoPoint,
    /** Distance from the route start to the projection of the feature, metres. */
    val distanceAlongRoute: Double,
    /** Lateral distance between the feature and the route, metres. */
    val offsetFromRoute: Double,
    // Defaults (not in Swift) keep call sites of the vision/coach port that only set the leading fields compiling.
    val name: String? = null,
    val tags: Map<String, String> = emptyMap(),
)

/** A signalised intersection (cluster of `highway=traffic_signals` nodes). */
data class SignalLocation(
    /** Stable id: OSM key of the node with the smallest id in the cluster. */
    val id: String,
    /** Centroid of the cluster. */
    val coordinate: GeoPoint,
)

/** Converts Overpass elements into route features and signal locations. */
object RouteFeatureExtractor {
    /** Radius within which traffic-signal nodes form one signalised intersection (metres). */
    const val signalClusterRadius: Double = 40.0

    /** Feature kind from OSM tags, null when irrelevant. */
    fun kind(tags: Map<String, String>): RouteFeatureKind? {
        when (tags["highway"]?.lowercase()) {
            "traffic_signals" -> return RouteFeatureKind.TRAFFIC_SIGNALS
            "crossing" -> return if (tags["crossing"]?.lowercase() == "no") null else RouteFeatureKind.PEDESTRIAN_CROSSING
            "speed_camera" -> return RouteFeatureKind.SPEED_CAMERA
            "stop" -> return RouteFeatureKind.STOP_SIGN
            "give_way" -> return RouteFeatureKind.GIVE_WAY
            "construction" -> return RouteFeatureKind.CONSTRUCTION
        }
        if (tags["railway"]?.lowercase() == "level_crossing") return RouteFeatureKind.RAILWAY_CROSSING
        val calming = tags["traffic_calming"]?.lowercase()
        if (!calming.isNullOrEmpty() && calming != "no") return RouteFeatureKind.TRAFFIC_CALMING
        return when (tags["amenity"]?.lowercase()) {
            "school" -> RouteFeatureKind.SCHOOL
            "kindergarten" -> RouteFeatureKind.KINDERGARTEN
            "fuel" -> RouteFeatureKind.FUEL
            "parking" -> {
                val access = tags["access"]?.lowercase() ?: ""
                if (access in listOf("private", "no", "customers")) null else RouteFeatureKind.PARKING
            }
            else -> null
        }
    }


    /**
     * Projects elements onto the route, drops those farther than [maxOffset] (schools / kindergartens: 150 m),
     * merges same-kind features closer than [RouteFeatureKind.mergeRadius] along the route (traffic signals:
     * 60 m → one signalised intersection; also same-named schools within 150 m, e.g. a node and its campus outline).
     * [cumulative]: optional `Geo.cumulativeDistances(route)` (ignored when its count does not match).
     * @return features sorted by `distanceAlongRoute`.
     */
    fun extract(elements: List<OSMElement>, route: List<GeoPoint>, cumulative: List<Double>? = null,
                maxOffset: Double = 40.0): List<RouteFeature> =
        features(candidates(elements, route, cumulative, maxOffset))

    /**
     * Projection phase of [extract]: one candidate per relevant element within its maximum offset of the route.
     * Progressive loaders project each chunk's new elements once, append them and re-cluster with [features].
     */
    fun candidates(elements: List<OSMElement>, route: List<GeoPoint>, cumulative: List<Double>? = null,
                   maxOffset: Double = 40.0): List<RouteFeatureCandidate> {
        if (route.isEmpty()) return emptyList()
        val cum = if (cumulative != null && cumulative.size == route.size) cumulative else Geo.cumulativeDistances(route)

        val candidates = ArrayList<RouteFeatureCandidate>()
        val seen = HashSet<String>()
        for (element in elements) {
            if (seen.contains(element.key)) continue
            val kind = kind(element.tags) ?: continue
            seen.add(element.key)
            // For ways with geometry use the vertex closest to the route (a long construction way's centre
            // may be far from the route even though the way overlaps it).
            val points = ArrayList<GeoPoint>()
            element.coordinate?.let { points.add(it) }
            if (element.type != OSMElement.ElementType.NODE) element.geometry?.let { points.addAll(it) }
            var bestProjection: Geo.Projection? = null
            var bestPoint: GeoPoint? = null
            for (p in points) {
                if (!p.isValid) continue
                val proj = Geo.project(p, route, cum) ?: continue
                if (bestProjection == null || proj.distanceFromLine < bestProjection.distanceFromLine) {
                    bestProjection = proj
                    bestPoint = p
                }
            }
            val projection = bestProjection ?: continue
            val point = bestPoint ?: continue
            if (projection.distanceFromLine > kind.maxOffset(maxOffset)) continue
            val name = element.tags["name:ru"] ?: element.tags["name"]
            candidates.add(RouteFeatureCandidate(element, kind, point, projection.distanceAlong, projection.distanceFromLine,
                if (name?.isEmpty() == true) null else name))
        }
        return candidates
    }

    /** Clustering phase of [extract]: merges same-kind candidates; features sorted along the route. */
    fun features(candidates: List<RouteFeatureCandidate>): List<RouteFeature> {
        val features = ArrayList<RouteFeature>()
        val byKind = candidates.groupBy { it.kind }
        for (kind in RouteFeatureKind.entries) {
            val list = byKind[kind] ?: continue
            val sorted = list.sortedWith(compareBy<RouteFeatureCandidate> { it.along }.thenBy { it.element.id })
            val clusters = ArrayList<MutableList<RouteFeatureCandidate>>()
            for (candidate in sorted) {
                val last = clusters.lastOrNull()
                val anchor = last?.firstOrNull()
                if (last != null && anchor != null) {
                    val closeAlong = candidate.along - anchor.along < kind.mergeRadius
                    val sameNamedPlace = (kind == RouteFeatureKind.SCHOOL || kind == RouteFeatureKind.KINDERGARTEN) &&
                        candidate.name != null && candidate.name == anchor.name &&
                        candidate.along - anchor.along < 150
                    if (closeAlong || sameNamedPlace) {
                        last.add(candidate)
                        continue
                    }
                }
                clusters.add(mutableListOf(candidate))
            }
            for (cluster in clusters) {
                val first = cluster.firstOrNull() ?: continue
                var representative = first
                for (c in cluster) {
                    val less = if (c.element.id == representative.element.id) c.element.key < representative.element.key
                    else c.element.id < representative.element.id
                    if (less) representative = c
                }
                val nearest = cluster.minByOrNull { it.offset } ?: first
                features.add(RouteFeature(
                    id = representative.element.key,
                    kind = kind,
                    coordinate = first.coordinate,
                    distanceAlongRoute = first.along,
                    offsetFromRoute = nearest.offset,
                    name = cluster.firstNotNullOfOrNull { it.name },
                    tags = representative.element.tags,
                ))
            }
        }
        return features.sortedWith(compareBy<RouteFeature> { it.distanceAlongRoute }.thenBy { it.id })
    }

    /**
     * `highway=traffic_signals` elements clustered within 40 m into signalised intersections.
     * Deterministic: nodes are processed in OSM id order; each cluster's id is its smallest node key and its
     * coordinate the centroid of the members.
     */
    fun signals(elements: List<OSMElement>): List<SignalLocation> {
        val nodes = elements
            .filter { it.tags["highway"]?.lowercase() == "traffic_signals" }
            .mapNotNull { e -> e.coordinate?.let { e to it } }
            .sortedWith(compareBy<Pair<OSMElement, GeoPoint>> { it.first.id }.thenBy { it.first.key })

        class Cluster(val id: String, val members: MutableList<GeoPoint>, var centroid: GeoPoint)
        val clusters = ArrayList<Cluster>()
        val seen = HashSet<String>()
        for ((element, point) in nodes) {
            if (!seen.add(element.key)) continue
            var bestIndex: Int? = null
            var bestDistance = Double.POSITIVE_INFINITY
            for ((i, cluster) in clusters.withIndex()) {
                val d = Geo.distance(cluster.centroid, point)
                if (d <= signalClusterRadius && d < bestDistance) {
                    bestDistance = d
                    bestIndex = i
                }
            }
            if (bestIndex != null) {
                val c = clusters[bestIndex]
                c.members.add(point)
                c.centroid = GeoPoint(c.members.sumOf { it.latitude } / c.members.size,
                    c.members.sumOf { it.longitude } / c.members.size)
            } else {
                clusters.add(Cluster(element.key, mutableListOf(point), point))
            }
        }
        return clusters.map { SignalLocation(it.id, it.centroid) }
    }

    /**
     * The signal location (e.g. from [signals], used by [StopDetector]) that corresponds to a route feature:
     * the same id, else the nearest within [radius] metres. Lets learned waits recorded under a
     * [SignalLocation.id] be found for a [RouteFeature] even when the two clusterings picked different ids.
     */
    fun matchingSignal(feature: RouteFeature, signals: List<SignalLocation>, radius: Double = 50.0): SignalLocation? {
        signals.firstOrNull { it.id == feature.id }?.let { return it }
        var best: SignalLocation? = null
        var bestDistance = radius
        for (signal in signals) {
            val d = Geo.distance(signal.coordinate, feature.coordinate)
            if (d <= bestDistance) {
                bestDistance = d
                best = signal
            }
        }
        return best
    }
}

/** An OSM element projected onto a route (intermediate result of `RouteFeatureExtractor`). */
class RouteFeatureCandidate(
    val element: OSMElement,
    val kind: RouteFeatureKind,
    val coordinate: GeoPoint,
    val along: Double,
    val offset: Double,
    val name: String?,
)
