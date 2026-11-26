package uz.roadvis.core

// Road-sign announcements for beginner drivers: OSM features along the active route (from `RouteFeature`s), speed
// limit changes (current road limit, upcoming `RouteEdgeAttributes.speedLimitKmh`) and STOP signs confirmed by the
// camera. Pure logic; texts come from the app's localization. `timestamp` values are seconds.

/** A road feature ahead of the driver with its distance along the route. */
data class FeatureAhead(
    val id: String,
    val kind: RouteFeatureKind,
    /** Distance from the current position to the feature along the route, metres (negative = already passed). */
    val distanceAhead: Double,
) {
    companion object {
        /** Features between [minAhead] and [lookahead] metres ahead of [distanceAlong]. */
        fun from(features: List<RouteFeature>, distanceAlong: Double, lookahead: Double = 600.0, minAhead: Double = -50.0): List<FeatureAhead> =
            features.mapNotNull { f ->
                val ahead = f.distanceAlongRoute - distanceAlong
                if (ahead < minAhead || ahead > lookahead) null else FeatureAhead(f.id, f.kind, ahead)
            }
    }
}

/** Something the coach may announce about signs / the road. */
sealed class RoadSignEvent {
    /** OSM feature ahead (speed camera, crossing, school, …) at about [distance] metres. */
    data class Feature(val kind: RouteFeatureKind, val distance: Double, val id: String) : RoadSignEvent()
    /** The posted speed limit changed to [kmh] (current road). */
    data class SpeedLimit(val kmh: Int) : RoadSignEvent()
    /** A different speed limit starts [distance] metres ahead on the route. */
    data class SpeedLimitAhead(val kmh: Int, val distance: Double) : RoadSignEvent()
    /** The camera confirmed a STOP sign ahead. */
    data class CameraStopSign(val trackID: Int) : RoadSignEvent()
}

/** An upcoming speed-limit change on the route. */
data class SpeedLimitChange(val kmh: Int, val distanceAhead: Double, val startDistance: Double)

class SignAnnouncer(var config: Config = Config()) {
    data class Config(
        /** Kinds that are announced (beginner-relevant hazards and signs). */
        val announcedKinds: Set<RouteFeatureKind> = setOf(
            RouteFeatureKind.SPEED_CAMERA, RouteFeatureKind.PEDESTRIAN_CROSSING, RouteFeatureKind.SCHOOL,
            RouteFeatureKind.KINDERGARTEN, RouteFeatureKind.RAILWAY_CROSSING, RouteFeatureKind.STOP_SIGN,
            RouteFeatureKind.GIVE_WAY, RouteFeatureKind.TRAFFIC_CALMING, RouteFeatureKind.TRAFFIC_SIGNALS,
        ),
        /** Below this speed the "urban" (near) thresholds are used. */
        val urbanSpeedKmh: Double = 65.0,
        /** Do not announce a feature closer than this (too late to be useful). */
        val minDistance: Double = 15.0,
        /** A candidate speed limit must stay unchanged this long before it is announced, seconds. */
        val speedLimitStableSeconds: Double = 3.0,
        /** Look-ahead for upcoming speed-limit changes on the route, metres (urban / rural). */
        val speedLimitAheadUrban: Double = 150.0,
        val speedLimitAheadRural: Double = 300.0,
        /** Same camera STOP announcement is not repeated within this time even for a new track. */
        val cameraStopCooldown: Double = 20.0,
        /** A camera STOP is not announced when an OSM STOP was announced within this time. */
        val osmStopSuppression: Double = 25.0,
    )

    private val announcedFeatureIDs = HashSet<String>()
    private val announcedLimitAheadKeys = HashSet<String>()
    private val announcedStopTracks = HashSet<Int>()
    private var lastCameraStop = Double.NEGATIVE_INFINITY
    private var lastOSMStop = Double.NEGATIVE_INFINITY
    private var announcedLimit: Int? = null
    private var candidateLimit: Int? = null
    private var candidateSince: Double? = null

    /** Forgets the announced ids (new route / trip). */
    fun reset() {
        announcedFeatureIDs.clear()
        announcedLimitAheadKeys.clear()
        announcedStopTracks.clear()
        announcedLimit = null
        candidateLimit = null
        candidateSince = null
    }

    /** Announcement distance for a kind: rural thresholds ≈ 200 m, urban ≈ 100 m; cameras and railways earlier. */
    fun threshold(kind: RouteFeatureKind, speedKmh: Double?): Double {
        val rural = (speedKmh ?: 0.0) >= config.urbanSpeedKmh
        return when (kind) {
            RouteFeatureKind.SPEED_CAMERA -> if (rural) 400.0 else 200.0
            RouteFeatureKind.RAILWAY_CROSSING -> if (rural) 300.0 else 150.0
            RouteFeatureKind.SCHOOL, RouteFeatureKind.KINDERGARTEN -> if (rural) 250.0 else 150.0
            else -> if (rural) 200.0 else 100.0
        }
    }

    /** OSM features ahead → at most one new announcement (the nearest), each feature id only once. */
    fun update(features: List<FeatureAhead>, speedKmh: Double?, timestamp: Double): RoadSignEvent? {
        val candidates = features
            .filter { it.kind in config.announcedKinds && it.id !in announcedFeatureIDs }
            .sortedBy { it.distanceAhead }
        for (f in candidates) {
            val limit = threshold(f.kind, speedKmh)
            if (f.distanceAhead < config.minDistance) {
                if (f.distanceAhead > -50) announcedFeatureIDs.add(f.id)
                continue
            }
            if (f.distanceAhead > limit) continue
            announcedFeatureIDs.add(f.id)
            if (f.kind == RouteFeatureKind.STOP_SIGN) lastOSMStop = timestamp
            return RoadSignEvent.Feature(f.kind, f.distanceAhead, f.id)
        }
        return null
    }

    /**
     * Current posted limit (null = unknown). Returns [RoadSignEvent.SpeedLimit] once a changed value has been stable
     * for `speedLimitStableSeconds`. Unknown values do not reset the announced limit.
     */
    fun update(currentLimitKmh: Int?, timestamp: Double): RoadSignEvent? {
        if (currentLimitKmh == null || currentLimitKmh <= 0 || currentLimitKmh == announcedLimit) {
            candidateLimit = null
            candidateSince = null
            return null
        }
        val kmh = currentLimitKmh
        if (candidateLimit != kmh) {
            candidateLimit = kmh
            candidateSince = timestamp
        }
        val since = candidateSince
        if (since == null || timestamp - since < config.speedLimitStableSeconds) return null
        announcedLimit = kmh
        candidateLimit = null
        candidateSince = null
        return RoadSignEvent.SpeedLimit(kmh)
    }

    /** Upcoming speed-limit change on the route (from Valhalla edge attributes), announced once per change point. */
    fun update(edges: List<RouteEdgeAttributes>, distanceAlong: Double, speedKmh: Double?): RoadSignEvent? {
        val lookahead = if ((speedKmh ?: 0.0) >= config.urbanSpeedKmh) config.speedLimitAheadRural else config.speedLimitAheadUrban
        val change = nextSpeedLimitChange(edges, distanceAlong, lookahead) ?: return null
        if (change.distanceAhead < config.minDistance) return null
        val key = "${change.startDistance.rounded().toInt()}-${change.kmh}"
        if (!announcedLimitAheadKeys.add(key)) return null
        return RoadSignEvent.SpeedLimitAhead(change.kmh, change.distanceAhead)
    }

    /**
     * A STOP sign track confirmed by the camera. Announced once per track, rate-limited, and not right after an OSM
     * STOP announcement (same sign).
     */
    fun cameraStopSign(trackID: Int, timestamp: Double): RoadSignEvent? {
        if (!announcedStopTracks.add(trackID)) return null
        if (!(timestamp - lastCameraStop >= config.cameraStopCooldown && timestamp - lastOSMStop >= config.osmStopSuppression)) return null
        lastCameraStop = timestamp
        return RoadSignEvent.CameraStopSign(trackID)
    }

    companion object {
        /** First edge within [lookahead] metres ahead whose posted limit differs from the limit at [distanceAlong]. */
        fun nextSpeedLimitChange(edges: List<RouteEdgeAttributes>, distanceAlong: Double, lookahead: Double): SpeedLimitChange? {
            val current = Valhalla.attributes(distanceAlong, edges)?.speedLimitKmh ?: return null
            for (edge in edges) {
                if (edge.startDistance <= distanceAlong) continue
                if (edge.startDistance - distanceAlong > lookahead) break
                val kmh = edge.speedLimitKmh
                if (kmh != null && kmh != current) {
                    return SpeedLimitChange(kmh, edge.startDistance - distanceAlong, edge.startDistance)
                }
            }
            return null
        }
    }
}
