import XCTest
@testable import RoadVisionCore

final class ValhallaTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testPolylineRoundTrip() {
        let pts = [GeoPoint(41.311111, 69.279722), GeoPoint(41.338889, 69.334722), GeoPoint(-12.5, 130.25)]
        let enc = Polyline.encode(pts, precision: 6)
        let dec = Polyline.decode(enc, precision: 6)
        XCTAssertEqual(dec.count, 3)
        for (a, b) in zip(pts, dec) {
            XCTAssertEqual(a.latitude, b.latitude, accuracy: 1e-6)
            XCTAssertEqual(a.longitude, b.longitude, accuracy: 1e-6)
        }
        // Known Google example (precision 5).
        let g = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g[0].latitude, 38.5, accuracy: 1e-5)
        XCTAssertEqual(g[0].longitude, -120.2, accuracy: 1e-5)
        XCTAssertEqual(g[2].longitude, -126.453, accuracy: 1e-5)
    }

    func testParseTashkentRoute() throws {
        let routes = try Valhalla.parseRoutes(fixture("valhalla_route_tashkent"))
        XCTAssertEqual(routes.count, 3)
        let r = routes[0]
        XCTAssertEqual(r.source, .valhalla)
        XCTAssertEqual(r.distance, 6609, accuracy: 1)
        XCTAssertEqual(r.expectedTravelTime, 700.243, accuracy: 0.01)
        XCTAssertEqual(r.polyline.count, 197)
        XCTAssertEqual(Geo.polylineLength(r.polyline), 6609, accuracy: 150)
        XCTAssertEqual(r.steps.first?.instruction, "")           // departure is not announced
        XCTAssertEqual(r.steps.first?.maneuver, .depart)
        XCTAssertEqual(r.steps[1].maneuver, .roundabout)
        let left = try XCTUnwrap(r.steps.first { $0.instruction.hasPrefix("Поверните налево") })
        XCTAssertEqual(left.maneuver, .slightLeft)               // type 16 rendered as "налево" in ru-RU
        XCTAssertEqual(left.lanes.count, 3)
        XCTAssertEqual(left.activeLanes.count, 3)
        XCTAssertTrue(left.activeLanes.contains(true))
        XCTAssertEqual(r.steps.last?.maneuver, .arrive)

        // The route works with the progress tracker.
        let tracker = RouteProgressTracker(polyline: r.polyline, steps: r.steps, expectedTravelTime: r.expectedTravelTime)
        let p = tracker.update(position: r.polyline[0])
        XCTAssertEqual(p.nextStepIndex, 1)
        XCTAssertEqual(p.nextManeuver, .roundabout)
        XCTAssertFalse(p.isOffRoute)
    }

    func testLaneMasks() {
        XCTAssertEqual(Valhalla.turns(fromMask: 10), [.left, .through])
        let (lanes, active) = Valhalla.lanes(from: [.init(directions: 8, active: 8), .init(directions: 10, active: 8), .init(directions: 2)])
        XCTAssertEqual(lanes.map(\.turns), [[.left], [.left, .through], [.through]])
        XCTAssertEqual(active, [true, true, false])
    }

    func testManeuverCodes() {
        XCTAssertEqual(Valhalla.maneuverType(10), .right)
        XCTAssertEqual(Valhalla.maneuverType(13), .uTurn)
        XCTAssertEqual(Valhalla.maneuverType(24), .keepLeft)
        XCTAssertEqual(Valhalla.maneuverType(5), .arrive)
    }

    func testTraceAttributes() throws {
        let routes = try Valhalla.parseRoutes(fixture("valhalla_route_tashkent"))
        let edges = try Valhalla.parseTraceAttributes(fixture("valhalla_trace_tashkent"), fallbackPolyline: routes[0].polyline)
        XCTAssertEqual(edges.count, 85)
        XCTAssertGreaterThan(edges.filter { $0.speedLimitKmh != nil }.count, 60)
        XCTAssertTrue(edges.contains { $0.laneCount ?? 0 >= 3 })
        for i in 1..<edges.count { XCTAssertGreaterThanOrEqual(edges[i].startDistance + 1, edges[i - 1].startDistance) }
        let mid = try XCTUnwrap(Valhalla.attributes(at: 3000, in: edges))
        XCTAssertLessThanOrEqual(mid.startDistance, 3000)
        XCTAssertGreaterThanOrEqual(mid.endDistance, 3000)
        XCTAssertFalse(Valhalla.signalDistances(in: edges).isEmpty)
    }

    func testRequestBodyAndErrors() throws {
        let body = try Valhalla.routeRequestBody(from: GeoPoint(41.3, 69.2), to: GeoPoint(41.4, 69.3), heading: 370, avoidTolls: true)
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["costing"] as? String, "auto")
        XCTAssertEqual(obj["turn_lanes"] as? Bool, true)
        let locs = obj["locations"] as! [[String: Any]]
        XCTAssertEqual(locs[0]["heading"] as? Int, 10)
        XCTAssertNotNil((obj["costing_options"] as? [String: Any])?["auto"])
        let err = Data("{\"error_code\":442,\"error\":\"No path could be found for input\",\"status_code\":400}".utf8)
        XCTAssertThrowsError(try Valhalla.parseRoutes(err)) { e in
            XCTAssertEqual((e as? ValhallaError)?.code, 442)
        }
    }

    func testCongestionEstimator() {
        XCTAssertEqual(CongestionEstimator.level(ownSpeedKmh: 8, typicalSpeedKmh: 50), .severe)
        XCTAssertEqual(CongestionEstimator.level(ownSpeedKmh: 45, typicalSpeedKmh: 50), .free)
        XCTAssertNil(CongestionEstimator.level(ownSpeedKmh: 10, typicalSpeedKmh: 10))
        XCTAssertNil(CongestionEstimator.level(ownSpeedKmh: 0, typicalSpeedKmh: 50, stoppedAtSignal: true))
    }
}
