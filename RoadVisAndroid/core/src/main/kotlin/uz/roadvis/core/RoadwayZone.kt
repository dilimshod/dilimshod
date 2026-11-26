package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

// The drivable roadway in image space (heuristic), used to separate a pedestrian crossing the road from one walking on
// the sidewalk. Sources, best first:
//  1. lanes — the lane detector's own-lane markings, extended outward by the typical number of extra lanes; with one
//     confident line the other one is mirrored through the lane centre.
//  2. corridor — the own-lane `EgoCorridor` widened by `roadWidthFactor`.
// `RoadwayZoneEstimator` smooths the boundaries over time.

/** Drivable roadway area in image space (normalized coordinates). */
data class RoadwayZone(
    /** Left boundary (x at y = 1 is `bottomX`, x at the horizon is `topX`). */
    val left: LaneLine,
    val right: LaneLine,
    val horizonY: Double,
    val source: Source,
) {
    enum class Source(val raw: String) {
        LANES("lanes"), CORRIDOR("corridor");

        companion object {
            fun fromRaw(raw: String): Source? = entries.firstOrNull { it.raw == raw }
        }
    }

    /** Boundaries through (leftBottom, 1)-(leftTop, horizon) and (rightBottom, 1)-(rightTop, horizon). */
    constructor(leftBottom: Double, leftTop: Double, rightBottom: Double, rightTop: Double, horizonY: Double, source: Source) :
        this(LaneLine(leftBottom, 1.0, leftTop, horizonY), LaneLine(rightBottom, 1.0, rightTop, horizonY), horizonY, source)

    /** Left / right x of the zone at row y (first = minX, second = maxX); null at or above the horizon. */
    fun bounds(atY: Double): Pair<Double, Double>? {
        if (atY <= horizonY) return null
        val a = left.x(atY); val b = right.x(atY)
        return Pair(min(a, b), max(a, b))
    }

    /** Half width of the zone at row y (0 at / above the horizon). */
    fun halfWidth(atY: Double): Double {
        val b = bounds(atY) ?: return 0.0
        return (b.second - b.first) / 2
    }

    /** Centre x of the zone at row y. */
    fun centerX(atY: Double): Double? = bounds(atY)?.let { (it.first + it.second) / 2 }

    /** How far the point lies outside the zone, in zone half widths at that row: 0 inside. Infinite above the horizon. */
    fun outsideDistance(x: Double, y: Double): Double {
        val b = bounds(y) ?: return Double.POSITIVE_INFINITY
        val half = max(1e-6, (b.second - b.first) / 2)
        if (x < b.first) return (b.first - x) / half
        if (x > b.second) return (x - b.second) / half
        return 0.0
    }

    /** Point inside the zone or at most [margin] (in half widths) beyond its boundary. */
    fun contains(x: Double, y: Double, margin: Double = 0.0): Boolean = outsideDistance(x, y) <= margin

    /** Boundary end points (x, y) for drawing: bottom-left, top-left (just below the horizon), top-right, bottom-right. */
    fun polygon(topY: Double? = null): List<Pair<Double, Double>> {
        val top = topY ?: min(0.99, horizonY + 0.02)
        return listOf(left.x(1.0) to 1.0, left.x(top) to top, right.x(top) to top, right.x(1.0) to 1.0)
    }

    companion object {
        /** The own-lane corridor widened by [widthFactor] (fallback without lane markings). */
        fun fromCorridor(corridor: EgoCorridor, widthFactor: Double): RoadwayZone {
            val b = corridor.bottomHalfWidth * widthFactor; val t = corridor.horizonHalfWidth * widthFactor
            return RoadwayZone(corridor.centerX - b, corridor.centerX - t, corridor.centerX + b, corridor.centerX + t,
                corridor.horizonY, Source.CORRIDOR)
        }

        /**
         * Zone from the confident own-lane markings, extended outward by [extraLanesLeft] / [extraLanesRight] lane
         * widths. null when no line reaches [minConfidence] or the result is implausible.
         */
        fun fromLanes(
            estimate: LaneEstimate, horizonY: Double, extraLanesLeft: Double,
            extraLanesRight: Double, minConfidence: Double,
        ): RoadwayZone? {
            val l = if (estimate.leftConfidence >= minConfidence) estimate.left else null
            val r = if (estimate.rightConfidence >= minConfidence) estimate.right else null
            val ref = estimate.referenceY
            var lb: Double; var lt: Double; var rb: Double; var rt: Double
            if (l != null && r != null) {
                lb = l.x(1.0); lt = l.x(horizonY)
                rb = r.x(1.0); rt = r.x(horizonY)
            } else if (l != null) {
                val center = estimate.laneCenterX ?: return null
                val half = center - l.x(ref)
                if (half <= 0.02) return null
                val top = l.x(horizonY)
                val other = LaneLine(l.x(ref) + 2 * half, ref, top, horizonY)
                lb = l.x(1.0); lt = top
                rb = other.x(1.0); rt = top
            } else if (r != null) {
                val center = estimate.laneCenterX ?: return null
                val half = r.x(ref) - center
                if (half <= 0.02) return null
                val top = r.x(horizonY)
                val other = LaneLine(r.x(ref) - 2 * half, ref, top, horizonY)
                lb = other.x(1.0); lt = top
                rb = r.x(1.0); rt = top
            } else {
                return null
            }
            val widthBottom = rb - lb
            val widthTop = rt - lt
            if (!(widthBottom > 0.2 && widthBottom < 2.5 && widthTop > -0.05 && lb.isFinite() && rb.isFinite())) return null
            lb -= extraLanesLeft * widthBottom
            lt -= extraLanesLeft * max(0.0, widthTop)
            rb += extraLanesRight * widthBottom
            rt += extraLanesRight * max(0.0, widthTop)
            return RoadwayZone(lb, lt, rb, rt, horizonY, Source.LANES)
        }
    }
}

/** Keeps a smoothed [RoadwayZone] from the lane estimate (when confident) or the widened corridor. */
class RoadwayZoneEstimator(var config: Config = Config()) {
    data class Config(
        /** Corridor fallback: roadway width relative to the own-lane corridor. */
        val roadWidthFactor: Double = 2.2,
        /** Typical number of lanes added outside the own lane on the left and on the right. */
        val extraLanesLeft: Double = 1.0,
        val extraLanesRight: Double = 1.0,
        /** A lane line is used from this confidence. */
        val minLaneConfidence: Double = 0.45,
        /** EMA weight of a new zone (1 = no smoothing). */
        val smoothing: Double = 0.25,
    )

    var zone: RoadwayZone? = null
        private set

    fun reset() {
        zone = null
    }

    /** Target zone of this frame (not smoothed). */
    fun target(lane: LaneEstimate?, corridor: EgoCorridor): RoadwayZone {
        if (lane != null) {
            val z = RoadwayZone.fromLanes(lane, corridor.horizonY, config.extraLanesLeft, config.extraLanesRight,
                config.minLaneConfidence)
            if (z != null) return z
        }
        return RoadwayZone.fromCorridor(corridor, config.roadWidthFactor)
    }

    /** Updates and returns the smoothed zone. */
    fun update(lane: LaneEstimate?, corridor: EgoCorridor): RoadwayZone {
        val t = target(lane, corridor)
        val old = zone
        if (old == null || old.horizonY != t.horizonY) {
            zone = t
            return t
        }
        val a = min(1.0, max(0.01, config.smoothing))
        fun mix(o: Double, n: Double) = o + a * (n - o)
        val z = RoadwayZone(
            mix(old.left.bottomX, t.left.bottomX),
            mix(old.left.x(t.horizonY), t.left.x(t.horizonY)),
            mix(old.right.bottomX, t.right.bottomX),
            mix(old.right.x(t.horizonY), t.right.x(t.horizonY)),
            t.horizonY, t.source,
        )
        zone = z
        return z
    }
}
