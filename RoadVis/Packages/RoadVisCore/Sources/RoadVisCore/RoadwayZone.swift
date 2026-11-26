import Foundation

// The drivable roadway in image space (heuristic), used to separate a pedestrian crossing the road from one walking on
// the sidewalk: persons whose feet are outside the zone and who are not moving toward it are not recognised at all.
//
// Geometry (normalized, top-left origin): the zone is the trapezoid between a left and a right boundary line, both
// running from the bottom edge (y = 1) to the horizon. Sources, best first:
//  1. lanes — the lane detector's own-lane markings, extended outward by the typical number of extra lanes
//     (`extraLanesLeft` / `extraLanesRight`): the detector only finds the own-lane lines, so the road edge is
//     estimated as k lane widths further out (the lane width shrinks toward the vanishing point, so the shifted
//     line stays a straight line). With one confident line the other one is mirrored through the lane centre.
//  2. corridor — the own-lane `EgoCorridor` widened by `roadWidthFactor` (the previous pedestrian heuristic).
// `RoadwayZoneEstimator` smooths the boundaries over time so the zone does not jump when the source changes.

/// Drivable roadway area in image space (normalized coordinates).
public struct RoadwayZone: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case lanes, corridor
    }

    /// Left boundary (x at y = 1 is `bottomX`, x at the horizon is `topX`).
    public var left: LaneLine
    public var right: LaneLine
    public var horizonY: Double
    public var source: Source

    public init(left: LaneLine, right: LaneLine, horizonY: Double, source: Source) {
        self.left = left
        self.right = right
        self.horizonY = horizonY
        self.source = source
    }

    /// Boundaries through (leftBottom, 1)-(leftTop, horizon) and (rightBottom, 1)-(rightTop, horizon).
    public init(leftBottom: Double, leftTop: Double, rightBottom: Double, rightTop: Double, horizonY: Double,
                source: Source) {
        self.init(left: LaneLine(bottomX: leftBottom, bottomY: 1, topX: leftTop, topY: horizonY),
                  right: LaneLine(bottomX: rightBottom, bottomY: 1, topX: rightTop, topY: horizonY),
                  horizonY: horizonY, source: source)
    }

    /// The own-lane corridor widened by `widthFactor` (fallback without lane markings).
    public static func fromCorridor(_ corridor: EgoCorridor, widthFactor: Double) -> RoadwayZone {
        let b = corridor.bottomHalfWidth * widthFactor, t = corridor.horizonHalfWidth * widthFactor
        return RoadwayZone(leftBottom: corridor.centerX - b, leftTop: corridor.centerX - t,
                           rightBottom: corridor.centerX + b, rightTop: corridor.centerX + t,
                           horizonY: corridor.horizonY, source: .corridor)
    }

    /// Zone from the confident own-lane markings, extended outward by `extraLanesLeft` / `extraLanesRight` lane widths.
    /// nil when no line reaches `minConfidence` or the result is implausible.
    public static func fromLanes(_ estimate: LaneEstimate, horizonY: Double, extraLanesLeft: Double,
                                 extraLanesRight: Double, minConfidence: Double) -> RoadwayZone? {
        let l = estimate.leftConfidence >= minConfidence ? estimate.left : nil
        let r = estimate.rightConfidence >= minConfidence ? estimate.right : nil
        let ref = estimate.referenceY
        var leftLine: (bottom: Double, top: Double)
        var rightLine: (bottom: Double, top: Double)
        switch (l, r) {
        case let (l?, r?):
            leftLine = (l.x(atY: 1), l.x(atY: horizonY))
            rightLine = (r.x(atY: 1), r.x(atY: horizonY))
        case let (l?, nil):
            guard let center = estimate.laneCenterX else { return nil }
            let half = center - l.x(atY: ref)
            guard half > 0.02 else { return nil }
            let top = l.x(atY: horizonY)
            // The mirrored line passes through the same vanishing point.
            let other = LaneLine(bottomX: l.x(atY: ref) + 2 * half, bottomY: ref, topX: top, topY: horizonY)
            leftLine = (l.x(atY: 1), top)
            rightLine = (other.x(atY: 1), top)
        case let (nil, r?):
            guard let center = estimate.laneCenterX else { return nil }
            let half = r.x(atY: ref) - center
            guard half > 0.02 else { return nil }
            let top = r.x(atY: horizonY)
            let other = LaneLine(bottomX: r.x(atY: ref) - 2 * half, bottomY: ref, topX: top, topY: horizonY)
            leftLine = (other.x(atY: 1), top)
            rightLine = (r.x(atY: 1), top)
        case (nil, nil):
            return nil
        }
        let widthBottom = rightLine.bottom - leftLine.bottom
        let widthTop = rightLine.top - leftLine.top
        guard widthBottom > 0.2, widthBottom < 2.5, widthTop > -0.05,
              leftLine.bottom.isFinite, rightLine.bottom.isFinite else { return nil }
        leftLine.bottom -= extraLanesLeft * widthBottom
        leftLine.top -= extraLanesLeft * max(0, widthTop)
        rightLine.bottom += extraLanesRight * widthBottom
        rightLine.top += extraLanesRight * max(0, widthTop)
        return RoadwayZone(leftBottom: leftLine.bottom, leftTop: leftLine.top, rightBottom: rightLine.bottom,
                           rightTop: rightLine.top, horizonY: horizonY, source: .lanes)
    }

    /// Left / right x of the zone at row y; nil at or above the horizon.
    public func bounds(atY y: Double) -> (minX: Double, maxX: Double)? {
        guard y > horizonY else { return nil }
        let a = left.x(atY: y), b = right.x(atY: y)
        return (min(a, b), max(a, b))
    }

    /// Half width of the zone at row y (0 at / above the horizon).
    public func halfWidth(atY y: Double) -> Double {
        guard let b = bounds(atY: y) else { return 0 }
        return (b.maxX - b.minX) / 2
    }

    /// Centre x of the zone at row y.
    public func centerX(atY y: Double) -> Double? {
        bounds(atY: y).map { ($0.minX + $0.maxX) / 2 }
    }

    /// How far the point lies outside the zone, in units of the zone half width at that row: 0 inside, 0.1 = a tenth
    /// of the half width beyond the nearest boundary. Infinite at / above the horizon.
    public func outsideDistance(x: Double, y: Double) -> Double {
        guard let b = bounds(atY: y) else { return .infinity }
        let half = max(1e-6, (b.maxX - b.minX) / 2)
        if x < b.minX { return (b.minX - x) / half }
        if x > b.maxX { return (x - b.maxX) / half }
        return 0
    }

    /// Point inside the zone or at most `margin` (in half widths) beyond its boundary.
    public func contains(x: Double, y: Double, margin: Double = 0) -> Bool {
        outsideDistance(x: x, y: y) <= margin
    }

    /// Boundary end points for drawing: bottom-left, top-left (just below the horizon), top-right, bottom-right.
    public func polygon(topY: Double? = nil) -> [(x: Double, y: Double)] {
        let top = topY ?? min(0.99, horizonY + 0.02)
        return [(left.x(atY: 1), 1), (left.x(atY: top), top), (right.x(atY: top), top), (right.x(atY: 1), 1)]
    }
}

/// Keeps a smoothed `RoadwayZone` from the lane estimate (when confident) or the widened corridor.
public final class RoadwayZoneEstimator {
    public struct Config: Sendable {
        /// Corridor fallback: roadway width relative to the own-lane corridor.
        public var roadWidthFactor: Double
        /// Typical number of lanes added outside the own lane on the left (oncoming / adjacent) and on the right.
        public var extraLanesLeft: Double
        public var extraLanesRight: Double
        /// A lane line is used from this confidence.
        public var minLaneConfidence: Double
        /// EMA weight of a new zone (1 = no smoothing).
        public var smoothing: Double

        public init(roadWidthFactor: Double = 2.2, extraLanesLeft: Double = 1, extraLanesRight: Double = 1,
                    minLaneConfidence: Double = 0.45, smoothing: Double = 0.25) {
            self.roadWidthFactor = roadWidthFactor
            self.extraLanesLeft = extraLanesLeft
            self.extraLanesRight = extraLanesRight
            self.minLaneConfidence = minLaneConfidence
            self.smoothing = smoothing
        }
    }

    public var config: Config
    public private(set) var zone: RoadwayZone?

    public init(config: Config = Config()) {
        self.config = config
    }

    public func reset() {
        zone = nil
    }

    /// Target zone of this frame (not smoothed).
    public func target(lane: LaneEstimate?, corridor: EgoCorridor) -> RoadwayZone {
        if let lane, let z = RoadwayZone.fromLanes(lane, horizonY: corridor.horizonY,
                                                   extraLanesLeft: config.extraLanesLeft,
                                                   extraLanesRight: config.extraLanesRight,
                                                   minConfidence: config.minLaneConfidence) {
            return z
        }
        return RoadwayZone.fromCorridor(corridor, widthFactor: config.roadWidthFactor)
    }

    /// Updates and returns the smoothed zone.
    @discardableResult
    public func update(lane: LaneEstimate?, corridor: EgoCorridor) -> RoadwayZone {
        let t = target(lane: lane, corridor: corridor)
        guard let old = zone, old.horizonY == t.horizonY else {
            zone = t
            return t
        }
        let a = min(1, max(0.01, config.smoothing))
        func mix(_ o: Double, _ n: Double) -> Double { o + a * (n - o) }
        let z = RoadwayZone(leftBottom: mix(old.left.bottomX, t.left.bottomX),
                            leftTop: mix(old.left.x(atY: t.horizonY), t.left.x(atY: t.horizonY)),
                            rightBottom: mix(old.right.bottomX, t.right.bottomX),
                            rightTop: mix(old.right.x(atY: t.horizonY), t.right.x(atY: t.horizonY)),
                            horizonY: t.horizonY, source: t.source)
        zone = z
        return z
    }
}
