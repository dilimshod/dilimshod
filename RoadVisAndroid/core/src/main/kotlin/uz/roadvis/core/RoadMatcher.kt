package uz.roadvis.core

import kotlin.math.min

/** Attributes of the road the vehicle is currently on (from OSM), for the user's travel direction. */
data class RoadSegmentInfo(
    val wayID: Long,
    /** Road name: the Russian name (`name:ru`) when mapped, else `name`. */
    val name: String?,
    /** Road number (`ref`), e.g. "4Р12". */
    val ref: String?,
    /** OSM road class (`highway=*`). */
    val highway: String,
    val laneInfo: LaneInfo,
    val speedLimit: SpeedLimit?,
    /** OSM `surface` (asphalt, concrete, unpaved …). */
    val surface: String?,
    /** Street lighting (`lit`), null when unknown. */
    val lit: Boolean?,
    /** True when travelling along the way's drawing direction. */
    val travelingForward: Boolean,
    /** Distance from the GPS position to the way, metres. */
    val distanceToRoad: Double,
    val tags: Map<String, String>,
) {
    /** `name ?: ref ?: highwayDisplayName(highway)`. */
    val displayName: String
        get() {
            if (!name.isNullOrEmpty()) return name
            if (!ref.isNullOrEmpty()) return ref
            return OSMRoadParser.highwayDisplayName(highway)
        }

    /** Russian road class name ("Главная дорога", "Жилая улица" …). */
    val roadClassName: String get() = OSMRoadParser.highwayDisplayName(highway)

    /** Russian surface description, null when not mapped. */
    val surfaceDisplayName: String?
        get() {
            val s = surface?.lowercase()
            if (s.isNullOrEmpty()) return null
            return when (s) {
                "asphalt" -> "Асфальт"
                "concrete", "concrete:plates", "concrete:lanes" -> "Бетон"
                "paved" -> "Твёрдое покрытие"
                "paving_stones", "sett", "cobblestone", "unhewn_cobblestone" -> "Брусчатка"
                "compacted", "fine_gravel", "gravel", "pebblestone" -> "Гравий"
                "unpaved", "dirt", "earth", "ground", "mud", "sand", "grass" -> "Грунт"
                else -> s
            }
        }
}

/** Map-matching of a GPS fix onto nearby OSM ways. */
object RoadMatcher {
    /** Extra cost (metres) per degree between the travel heading and the road direction. */
    const val headingWeight = 0.3
    /** Extra cost (metres) for travelling against a one-way road. */
    const val wrongWayPenalty = 60.0
    /** Extra cost (metres) per road-class rank step (prefers major roads on near-ties). */
    const val classWeight = 0.4

    /** A match with its score (distance + penalties, metres; lower is better). */
    data class ScoredMatch(val road: RoadSegmentInfo, val score: Double)

    /**
     * Picks the way best matching the position and travel heading.
     *
     * Only ways with geometry and a drivable `highway=*` are considered. Score = distance to the way
     * + heading penalty (angle between the heading and the nearest segment, either direction for two-way roads)
     * + a large penalty for driving against a one-way road + a small road-class penalty. `heading == null` (or
     * invalid) → nearest way; one-way roads are then assumed to be travelled in their legal direction.
     * @return null when no way is within [maxDistance] metres.
     */
    fun bestMatch(elements: List<OSMElement>, position: GeoPoint, heading: Double?, maxDistance: Double = 35.0): RoadSegmentInfo? =
        scoredMatch(elements, position, heading, maxDistance)?.road

    /**
     * Like [bestMatch], but also returns the match score. Use the score — not the raw distance — to compare
     * candidates (e.g. for stickiness).
     */
    fun scoredMatch(elements: List<OSMElement>, position: GeoPoint, heading: Double?, maxDistance: Double = 35.0): ScoredMatch? {
        if (!position.isValid) return null
        val validHeading = heading?.let { if (it.isFinite() && it >= 0) Geo.normalizeDegrees(it) else null }
        val excluded = OverpassQuery.excludedHighwayValues.toSet()

        var bestScore = 0.0
        var bestElement: OSMElement? = null
        var bestDistance = 0.0
        var bestForward = true
        for (element in elements) {
            if (element.type != OSMElement.ElementType.WAY) continue
            val highway = element.tags["highway"]?.lowercase() ?: continue
            if (excluded.contains(highway)) continue
            if (element.tags["area"]?.lowercase() == "yes") continue
            val geometry = element.geometry ?: continue
            if (geometry.size < 2) continue
            val projection = Geo.project(position, geometry) ?: continue
            val distance = projection.distanceFromLine
            if (distance > maxDistance) continue

            val direction = OSMRoadParser.onewayDirection(element.tags)
            var score = distance
            val forward: Boolean
            if (validHeading != null) {
                val diffForward = Geo.angleDifference(validHeading, projection.segmentBearing)
                val diffBackward = 180 - diffForward
                forward = diffForward <= 90
                when (direction) {
                    1 -> {
                        score += headingWeight * diffForward
                        if (!forward) score += wrongWayPenalty
                    }
                    -1 -> {
                        score += headingWeight * diffBackward
                        if (forward) score += wrongWayPenalty
                    }
                    else -> score += headingWeight * min(diffForward, diffBackward)
                }
            } else {
                forward = direction != -1
            }
            score += classWeight * OSMRoadParser.roadClassRank(highway)

            if (bestElement == null || score < bestScore) {
                bestScore = score
                bestElement = element
                bestDistance = distance
                bestForward = forward
            }
        }

        val match = bestElement ?: return null
        val tags = match.tags
        val name = nonEmpty(tags["name:ru"]) ?: nonEmpty(tags["name"])
        val road = RoadSegmentInfo(
            wayID = match.id,
            name = name,
            ref = nonEmpty(tags["ref"]),
            highway = tags["highway"] ?: "road",
            laneInfo = OSMRoadParser.laneInfo(tags, bestForward),
            speedLimit = MaxSpeedParser.limit(tags, bestForward),
            surface = nonEmpty(tags["surface"]),
            lit = litValue(tags["lit"]),
            travelingForward = bestForward,
            distanceToRoad = bestDistance,
            tags = tags,
        )
        return ScoredMatch(road, bestScore)
    }

    /** `lit=*` → Boolean (yes / 24/7 / automatic / limited / interval → true; no / disused → false). */
    fun litValue(value: String?): Boolean? = when (value?.lowercase()) {
        "yes", "24/7", "automatic", "limited", "interval", "sunset-sunrise", "dusk-dawn" -> true
        "no", "disused" -> false
        else -> null
    }

    private fun nonEmpty(s: String?): String? {
        val t = s?.swiftTrim()
        return if (t.isNullOrEmpty()) null else t
    }
}
