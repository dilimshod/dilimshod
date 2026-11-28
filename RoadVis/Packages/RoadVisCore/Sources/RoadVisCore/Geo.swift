import Foundation

/// A WGS-84 coordinate. Platform-independent replacement for CLLocationCoordinate2D
/// (the app converts with `GeoPoint(coordinate)` / `point.coordinate` in AppBridges.swift).
public struct GeoPoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ latitude: Double, _ longitude: Double) {
        self.init(latitude: latitude, longitude: longitude)
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    public var description: String {
        String(format: "%.6f,%.6f", latitude, longitude)
    }
}

/// Spherical-earth geometry helpers. Distances are in metres, angles in degrees.
public enum Geo {
    public static let earthRadius: Double = 6_371_008.8

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Great-circle (haversine) distance in metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.latitude - a.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(s), sqrt(max(0, 1 - s)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north in [0, 360).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = rad(a.latitude), φ2 = rad(b.latitude)
        let Δλ = rad(b.longitude - a.longitude)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalizeDegrees(deg(atan2(y, x)))
    }

    /// Normalizes an angle to [0, 360).
    public static func normalizeDegrees(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Smallest absolute difference between two headings, in [0, 180].
    public static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalizeDegrees(a) - normalizeDegrees(b))
        return d > 180 ? 360 - d : d
    }

    /// Point reached from `start` travelling `distance` metres on `bearing`.
    public static func destination(from start: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        let δ = distance / earthRadius
        let θ = rad(bearing)
        let φ1 = rad(start.latitude), λ1 = rad(start.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(deg(φ2), normalizeLongitude(deg(λ2)))
    }

    static func normalizeLongitude(_ lon: Double) -> Double {
        var l = lon
        while l > 180 { l -= 360 }
        while l < -180 { l += 360 }
        return l
    }

    /// Total length of a polyline in metres.
    public static func polylineLength(_ points: [GeoPoint]) -> Double {
        cumulativeDistances(points).last ?? 0
    }

    /// Cumulative distance from the first vertex to each vertex (same count as `points`).
    public static func cumulativeDistances(_ points: [GeoPoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var result = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count {
            result[i] = result[i - 1] + distance(points[i - 1], points[i])
        }
        return result
    }

    /// Result of projecting a point onto a polyline.
    public struct Projection: Equatable, Sendable {
        /// Index of the segment (points[segmentIndex] → points[segmentIndex+1]).
        public let segmentIndex: Int
        /// Position inside the segment, 0...1.
        public let fraction: Double
        /// The closest point on the polyline.
        public let point: GeoPoint
        /// Distance from the query point to the polyline (cross-track), metres.
        public let distanceFromLine: Double
        /// Distance from the polyline start to `point`, metres.
        public let distanceAlong: Double
        /// Bearing of the matched segment, degrees.
        public let segmentBearing: Double
    }

    /// Projects `p` onto the polyline. Uses a local equirectangular approximation per segment,
    /// accurate to well under a metre for segments shorter than a few kilometres.
    /// - Parameters:
    ///   - cumulative: optional precomputed `cumulativeDistances(points)`.
    ///   - segmentRange: optional subset of segment indices to search (for incremental tracking).
    public static func project(_ p: GeoPoint,
                               onto points: [GeoPoint],
                               cumulative: [Double]? = nil,
                               segmentRange: Range<Int>? = nil) -> Projection? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 {
            return Projection(segmentIndex: 0, fraction: 0, point: points[0],
                              distanceFromLine: distance(p, points[0]), distanceAlong: 0,
                              segmentBearing: 0)
        }
        let cum = cumulative ?? cumulativeDistances(points)
        let allSegments = 0..<(points.count - 1)
        let range = segmentRange.map { $0.clamped(to: allSegments) } ?? allSegments
        guard !range.isEmpty else { return nil }

        let cosLat = cos(rad(p.latitude))
        let mPerDegLat = earthRadius * .pi / 180
        let mPerDegLon = mPerDegLat * cosLat

        var best: Projection?
        for i in range {
            let a = points[i], b = points[i + 1]
            // Local planar coordinates (metres) relative to p.
            let ax = (a.longitude - p.longitude) * mPerDegLon, ay = (a.latitude - p.latitude) * mPerDegLat
            let bx = (b.longitude - p.longitude) * mPerDegLon, by = (b.latitude - p.latitude) * mPerDegLat
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0
            t = min(1, max(0, t))
            let cx = ax + t * dx, cy = ay + t * dy
            let d = sqrt(cx * cx + cy * cy)
            if best == nil || d < best!.distanceFromLine {
                let point = GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                                     a.longitude + (b.longitude - a.longitude) * t)
                let segLen = cum[i + 1] - cum[i]
                best = Projection(segmentIndex: i, fraction: t, point: point,
                                  distanceFromLine: d, distanceAlong: cum[i] + segLen * t,
                                  segmentBearing: bearing(from: a, to: b))
            }
        }
        return best
    }

    /// Point located `d` metres along the polyline (clamped to its ends).
    public static func point(atDistance d: Double, along points: [GeoPoint], cumulative: [Double]? = nil) -> GeoPoint? {
        guard let first = points.first else { return nil }
        let cum = cumulative ?? cumulativeDistances(points)
        guard let total = cum.last, d > 0 else { return first }
        if d >= total { return points.last }
        // Binary search for the segment.
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cum[mid] <= d { lo = mid } else { hi = mid }
        }
        let segLen = cum[hi] - cum[lo]
        let t = segLen > 0 ? (d - cum[lo]) / segLen : 0
        let a = points[lo], b = points[hi]
        return GeoPoint(a.latitude + (b.latitude - a.latitude) * t,
                        a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Douglas–Peucker simplification with a tolerance in metres. Keeps first and last points.
    public static func simplify(_ points: [GeoPoint], tolerance: Double) -> [GeoPoint] {
        simplifiedIndices(points, tolerance: tolerance).map { points[$0] }
    }

    /// Simplifies until the polyline has at most `maxPoints` vertices (doubling the tolerance).
    public static func simplify(_ points: [GeoPoint], maxPoints: Int, initialTolerance: Double = 5) -> [GeoPoint] {
        simplifiedIndices(points, maxPoints: maxPoints, initialTolerance: initialTolerance).map { points[$0] }
    }

    /// Indices (ascending) of the vertices `simplify(_:tolerance:)` keeps — lets callers carry per-point data along.
    public static func simplifiedIndices(_ points: [GeoPoint], tolerance: Double) -> [Int] {
        guard points.count > 2, tolerance > 0 else { return Array(points.indices) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD = 0.0, idx = s
            let seg = [points[s], points[e]]
            for i in (s + 1)..<e {
                let d = project(points[i], onto: seg)?.distanceFromLine ?? 0
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return points.indices.filter { keep[$0] }
    }

    /// Indices kept by `simplify(_:maxPoints:initialTolerance:)`.
    public static func simplifiedIndices(_ points: [GeoPoint], maxPoints: Int, initialTolerance: Double = 5) -> [Int] {
        guard maxPoints >= 2 else { return Array(points.indices.prefix(max(0, maxPoints))) }
        var tol = initialTolerance
        var result = simplifiedIndices(points, tolerance: tol)
        while result.count > maxPoints && tol < 100_000 {
            tol *= 2
            result = simplifiedIndices(points, tolerance: tol)
        }
        return result
    }

    /// Splits a polyline into consecutive chunks of at most `maxPoints` vertices; neighbouring chunks share an endpoint.
    public static func chunk(_ points: [GeoPoint], maxPoints: Int) -> [[GeoPoint]] {
        guard maxPoints >= 2, points.count > maxPoints else { return points.isEmpty ? [] : [points] }
        var chunks: [[GeoPoint]] = []
        var start = 0
        while start < points.count - 1 {
            let end = min(points.count, start + maxPoints)
            chunks.append(Array(points[start..<end]))
            start = end - 1
        }
        return chunks
    }

    /// Axis-aligned bounding box (south, west, north, east) of points, optionally padded by metres.
    public static func boundingBox(_ points: [GeoPoint], padding: Double = 0) -> (south: Double, west: Double, north: Double, east: Double)? {
        guard let first = points.first else { return nil }
        var s = first.latitude, n = first.latitude, w = first.longitude, e = first.longitude
        for p in points {
            s = min(s, p.latitude); n = max(n, p.latitude)
            w = min(w, p.longitude); e = max(e, p.longitude)
        }
        if padding > 0 {
            let dLat = padding / (earthRadius * .pi / 180)
            let dLon = dLat / max(0.01, cos(rad((s + n) / 2)))
            s -= dLat; n += dLat; w -= dLon; e += dLon
        }
        return (s, w, n, e)
    }
}

public extension Double {
    /// Metres per second → kilometres per hour.
    var kmh: Double { self * 3.6 }
    /// Kilometres per hour → metres per second.
    var mps: Double { self / 3.6 }
}
