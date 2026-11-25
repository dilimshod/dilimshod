import XCTest
@testable import RoadVisionCore

final class GeoTests: XCTestCase {
    func testDistanceTashkent() {
        // Amir Temur square → Tashkent TV tower, ~4.2 km straight line (approx.)
        let a = GeoPoint(41.3111, 69.2797)
        let b = GeoPoint(41.3456, 69.2853)
        let d = Geo.distance(a, b)
        XCTAssertEqual(d, 3870, accuracy: 120)
    }

    func testBearingNorthEast() {
        let a = GeoPoint(0, 0)
        XCTAssertEqual(Geo.bearing(from: a, to: GeoPoint(1, 0)), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: a, to: GeoPoint(0, 1)), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.angleDifference(350, 10), 20, accuracy: 1e-9)
    }

    func testProjectionOntoPolyline() {
        let line = [GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.01), GeoPoint(41.01, 69.01)]
        let p = GeoPoint(41.0002, 69.005)
        let proj = Geo.project(p, onto: line)!
        XCTAssertEqual(proj.segmentIndex, 0)
        XCTAssertEqual(proj.distanceFromLine, 22.2, accuracy: 1.0)
        let half = Geo.distance(line[0], line[1]) / 2
        XCTAssertEqual(proj.distanceAlong, half, accuracy: 2)
    }

    func testDestinationRoundTrip() {
        let s = GeoPoint(41.3, 69.25)
        let d = Geo.destination(from: s, bearing: 45, distance: 1000)
        XCTAssertEqual(Geo.distance(s, d), 1000, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(from: s, to: d), 45, accuracy: 0.1)
    }

    func testSimplifyAndChunk() {
        var pts: [GeoPoint] = []
        for i in 0..<500 { pts.append(GeoPoint(41.0 + Double(i) * 0.0001, 69.0 + sin(Double(i) / 30) * 0.001)) }
        let s = Geo.simplify(pts, maxPoints: 80)
        XCTAssertLessThanOrEqual(s.count, 80)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        let chunks = Geo.chunk(pts, maxPoints: 100)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(chunks.first?.first, pts.first)
        XCTAssertEqual(chunks.last?.last, pts.last)
        for i in 1..<chunks.count { XCTAssertEqual(chunks[i - 1].last, chunks[i].first) }
    }

    func testPointAtDistance() {
        let line = [GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.01)]
        let total = Geo.polylineLength(line)
        let mid = Geo.point(atDistance: total / 2, along: line)!
        XCTAssertEqual(mid.longitude, 69.005, accuracy: 1e-6)
    }
}
