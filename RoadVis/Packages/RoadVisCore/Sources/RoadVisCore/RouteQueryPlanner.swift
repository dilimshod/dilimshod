import Foundation

/// Splits a route into Overpass query chunks that never silently miss features on long or winding routes:
/// the route is simplified only with a small tolerance (so the query line stays within `tolerance` metres of the
/// real route and the query radius can be widened by exactly that), long segments are densified, and every chunk has
/// at most `maxPointsPerChunk` vertices AND covers at most `maxChunkLength` metres.
public enum RouteQueryPlanner {
    public static let defaultMaxPointsPerChunk = 60
    public static let defaultMaxChunkLength: Double = 3_000
    public static let defaultTolerance: Double = 10

    public struct Plan: Sendable {
        /// Chunks of the (lightly simplified) route; neighbours share an endpoint.
        public let chunks: [[GeoPoint]]
        /// Maximum distance between the query line and the original route, metres (≤ tolerance).
        public let maxDeviation: Double
        /// Chunks beyond `maxChunks` that were dropped (0 = the plan covers the whole route).
        public let droppedChunks: Int
        /// Route length covered by `chunks`, metres.
        public let coveredLength: Double
        public let totalLength: Double

        public var isComplete: Bool { droppedChunks == 0 }
    }

    public static func plan(route: [GeoPoint], maxPointsPerChunk: Int = defaultMaxPointsPerChunk,
                            maxChunkLength: Double = defaultMaxChunkLength, tolerance: Double = defaultTolerance,
                            maxChunks: Int = .max) -> Plan {
        let valid = route.filter(\.isValid)
        let total = Geo.polylineLength(valid)
        guard valid.count >= 2 else {
            return Plan(chunks: valid.isEmpty ? [] : [valid], maxDeviation: 0, droppedChunks: 0,
                        coveredLength: 0, totalLength: total)
        }
        let simplified = Geo.simplify(valid, tolerance: tolerance)
        let all = chunks(simplified, maxPoints: max(2, maxPointsPerChunk), maxLength: max(50, maxChunkLength))
        let kept = Array(all.prefix(max(0, maxChunks)))
        let covered = kept.reduce(0) { $0 + Geo.polylineLength($1) }
        return Plan(chunks: kept, maxDeviation: tolerance, droppedChunks: all.count - kept.count,
                    coveredLength: covered, totalLength: total)
    }

    /// Splits `points` into chunks with ≤ maxPoints vertices and ≤ maxLength metres each (segments longer than
    /// maxLength are split by inserted points). Neighbouring chunks share their boundary point.
    public static func chunks(_ points: [GeoPoint], maxPoints: Int, maxLength: Double) -> [[GeoPoint]] {
        guard points.count >= 2 else { return points.isEmpty ? [] : [points] }
        // Densify so that no single segment exceeds maxLength.
        var dense: [GeoPoint] = [points[0]]
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let length = Geo.distance(a, b)
            if length > maxLength {
                let parts = Int((length / maxLength).rounded(.up))
                for k in 1..<parts {
                    let t = Double(k) / Double(parts)
                    dense.append(GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                                          a.longitude + (b.longitude - a.longitude) * t))
                }
            }
            dense.append(b)
        }
        var result: [[GeoPoint]] = []
        var current: [GeoPoint] = [dense[0]]
        var currentLength = 0.0
        for i in 1..<dense.count {
            let step = Geo.distance(dense[i - 1], dense[i])
            if current.count >= maxPoints || currentLength + step > maxLength {
                result.append(current)
                current = [dense[i - 1]]
                currentLength = 0
            }
            current.append(dense[i])
            currentLength += step
        }
        if current.count >= 2 { result.append(current) }
        return result
    }
}
