import Foundation

/// A stretch of the selected route drawn in one colour on the map: either a known speed-limit segment
/// (`isGap == false`, colour by `limitKmh`, nil = limit unknown) or a gap between segments (`isGap == true`,
/// plain route colour).
public struct RouteLimitPiece: Equatable, Sendable {
    /// Distance from the route start, metres.
    public var start: Double
    public var end: Double
    public var limitKmh: Int?
    public var isGap: Bool

    public init(start: Double, end: Double, limitKmh: Int?, isGap: Bool) {
        self.start = start
        self.end = end
        self.limitKmh = limitKmh
        self.isGap = isGap
    }
}

public enum RouteLimitPieces {
    /// Splits `0...totalDistance` into consecutive pieces that cover the whole route without holes or overlaps:
    /// the speed-limit segments (sorted, clamped to the route, overlaps cut at the previous segment's end) and gap
    /// pieces before / between / after them. Neighbouring pieces that would get the same colour are merged, and
    /// gaps shorter than `minGap` metres are absorbed by the following segment. Empty when the route has no length.
    public static func pieces(segments: [SpeedLimitSegment], totalDistance: Double,
                              minGap: Double = 0.5) -> [RouteLimitPiece] {
        guard totalDistance.isFinite, totalDistance > 0 else { return [] }
        var result: [RouteLimitPiece] = []
        func append(_ piece: RouteLimitPiece) {
            guard piece.end > piece.start else { return }
            if let last = result.last, last.isGap == piece.isGap, last.limitKmh == piece.limitKmh {
                result[result.count - 1].end = piece.end
            } else {
                result.append(piece)
            }
        }
        var cursor = 0.0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end.isFinite else { continue }
            var start = max(cursor, min(totalDistance, segment.start))
            let end = max(0, min(totalDistance, segment.end))
            guard end > start else { continue }
            if start - cursor >= minGap {
                append(RouteLimitPiece(start: cursor, end: start, limitKmh: nil, isGap: true))
            } else {
                start = cursor
            }
            append(RouteLimitPiece(start: start, end: end, limitKmh: segment.limitKmh, isGap: false))
            cursor = end
        }
        if totalDistance - cursor >= minGap || result.isEmpty {
            append(RouteLimitPiece(start: cursor, end: totalDistance, limitKmh: nil, isGap: true))
        } else if cursor < totalDistance {
            result[result.count - 1].end = totalDistance
        }
        return result
    }
}

extension Geo {
    /// The part of a polyline between `start` and `end` metres along it: an interpolated point at each end and all
    /// vertices strictly between them. Distances are clamped to the polyline; empty when `end <= start` (after
    /// clamping) or the polyline has fewer than two points.
    public static func slice(_ points: [GeoPoint], from start: Double, to end: Double,
                             cumulative: [Double]? = nil) -> [GeoPoint] {
        guard points.count >= 2 else { return [] }
        let cum = cumulative ?? cumulativeDistances(points)
        guard cum.count == points.count, let total = cum.last, total > 0 else { return [] }
        let from = max(0, min(total, start))
        let to = max(0, min(total, end))
        guard to > from,
              let first = point(atDistance: from, along: points, cumulative: cum),
              let last = point(atDistance: to, along: points, cumulative: cum) else { return [] }
        var result: [GeoPoint] = [first]
        // First vertex strictly after `from` (binary search; `cum` is non-decreasing).
        var lo = 0, hi = cum.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cum[mid] <= from { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        while index < cum.count, cum[index] < to {
            result.append(points[index])
            index += 1
        }
        result.append(last)
        return result
    }
}
