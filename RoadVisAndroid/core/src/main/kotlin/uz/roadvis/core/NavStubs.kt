package uz.roadvis.core

// TEMPORARY STUBS of navigation types that are ported in the navigation worktree (RouteFeatures.swift / Valhalla.swift).
// RoadSignEvents, CoachRules, VoicePhrase and VoiceClipCatalog need them. They mirror the navigation port's API (same names, entry names, raw values,
// parameter names) for the members used here. DELETE THIS FILE when merging with the navigation port.

/** Stub of the navigation port's `RouteFeatureKind` (entries and raw values as in RouteFeatures.swift). */
enum class RouteFeatureKind(val raw: String) {
    TRAFFIC_SIGNALS("trafficSignals"), PEDESTRIAN_CROSSING("pedestrianCrossing"), SPEED_CAMERA("speedCamera"),
    TRAFFIC_CALMING("trafficCalming"), RAILWAY_CROSSING("railwayCrossing"), SCHOOL("school"),
    KINDERGARTEN("kindergarten"), CONSTRUCTION("construction"), STOP_SIGN("stopSign"), GIVE_WAY("giveWay"),
    FUEL("fuel"), PARKING("parking");
}

/** Stub of the navigation port's `RouteFeature` (only the members used by [FeatureAhead]). */
data class RouteFeature(
    val id: String,
    val kind: RouteFeatureKind,
    val coordinate: GeoPoint,
    val distanceAlongRoute: Double,
    val offsetFromRoute: Double = 0.0,
)

/** Stub of the navigation port's `RouteEdgeAttributes` (leading parameters in the same order). */
data class RouteEdgeAttributes(
    val startDistance: Double,
    val endDistance: Double,
    val names: List<String> = emptyList(),
    val speedLimitKmh: Int? = null,
)

/** Stub of the navigation port's `ManeuverType` (Maneuver.swift; entries and raw values identical). */
enum class ManeuverType(val raw: String) {
    DEPART("depart"), STRAIGHT("straight"), SLIGHT_LEFT("slightLeft"), LEFT("left"), SHARP_LEFT("sharpLeft"),
    SLIGHT_RIGHT("slightRight"), RIGHT("right"), SHARP_RIGHT("sharpRight"), U_TURN("uTurn"), ROUNDABOUT("roundabout"),
    MERGE("merge"), KEEP_LEFT("keepLeft"), KEEP_RIGHT("keepRight"), EXIT_LEFT("exitLeft"), EXIT_RIGHT("exitRight"),
    ARRIVE("arrive"), UNKNOWN("unknown");
}

/** Stub of the navigation port's `RoadIncidentKind` (Incidents.swift; entries and raw values identical). */
enum class RoadIncidentKind(val raw: String) {
    ACCIDENT("accident"), ROAD_WORK("roadWork"), JAM("jam"), POLICE("police"), POTHOLE("pothole"),
    HAZARD("hazard"), CLOSURE("closure"), SPEED_CAMERA("speedCamera");
}

/** Stub of the navigation port's `Valhalla` object (only `attributes`). */
object Valhalla {
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
}
