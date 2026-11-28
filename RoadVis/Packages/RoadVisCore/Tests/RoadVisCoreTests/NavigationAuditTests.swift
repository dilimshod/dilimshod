import XCTest
@testable import RoadVisCore

/// Regression tests for the audited navigation defects (reroute storms, map-matching jumps, poor fixes).
final class NavigationAuditTests: XCTestCase {
    private let start = GeoPoint(41.3, 69.2)

    /// Straight route due east, one vertex every 50 m.
    private func straightRoute(length: Double = 1000) -> [GeoPoint] {
        var pts: [GeoPoint] = []
        var d = 0.0
        while d <= length {
            pts.append(Geo.destination(from: start, bearing: 90, distance: d))
            d += 50
        }
        return pts
    }

    private func tracker(_ pts: [GeoPoint], steps: [RouteStepInfo] = []) -> RouteProgressTracker {
        RouteProgressTracker(polyline: pts, steps: steps, expectedTravelTime: 120)
    }

    /// Point `along` metres down the straight route, `offset` metres to the north of it.
    private func point(along: Double, offset: Double) -> GeoPoint {
        Geo.destination(from: Geo.destination(from: start, bearing: 90, distance: along), bearing: 0, distance: offset)
    }

    // MARK: Reroute storm (never on the route yet)

    func testStandingBesideRouteBeforeJoiningIsNotOffRoute() {
        let t = tracker(straightRoute())
        for _ in 0..<10 {
            let p = t.update(position: point(along: 0, offset: 70))
            XCTAssertFalse(p.isOffRoute)
            XCTAssertEqual(p.crossTrackDistance, 70, accuracy: 2)
        }
        // Approaching the route is not off-route either.
        XCTAssertFalse(t.update(position: point(along: 0, offset: 60)).isOffRoute)
        XCTAssertFalse(t.update(position: point(along: 0, offset: 55)).isOffRoute)
    }

    func testMovingAwayBeforeJoiningIsOffRoute() {
        let t = tracker(straightRoute())
        XCTAssertFalse(t.update(position: point(along: 0, offset: 70)).isOffRoute)
        XCTAssertFalse(t.update(position: point(along: 0, offset: 130)).isOffRoute)
        XCTAssertFalse(t.update(position: point(along: 0, offset: 130)).isOffRoute)
        XCTAssertTrue(t.update(position: point(along: 0, offset: 130)).isOffRoute)
    }

    func testLeavingRouteAfterJoiningIsOffRouteAsBefore() {
        let t = tracker(straightRoute())
        XCTAssertFalse(t.update(position: point(along: 100, offset: 3)).isOffRoute)
        XCTAssertFalse(t.update(position: point(along: 120, offset: 70)).isOffRoute)
        XCTAssertFalse(t.update(position: point(along: 140, offset: 70)).isOffRoute)
        let p = t.update(position: point(along: 160, offset: 70))
        XCTAssertTrue(p.isOffRoute)
        // Progress holds at the last matched position while off the route.
        XCTAssertEqual(p.distanceAlong, 100, accuracy: 2)
    }

    // MARK: Poor fixes

    func testPoorFixesDoNotCountTowardsOffRoute() {
        let poor = tracker(straightRoute())
        XCTAssertFalse(poor.update(position: point(along: 100, offset: 0)).isOffRoute)
        for _ in 0..<3 {
            let p = poor.update(position: point(along: 100, offset: 150), horizontalAccuracy: 150,
                                countsTowardsOffRoute: false)
            XCTAssertFalse(p.isOffRoute)
            XCTAssertEqual(p.distanceAlong, 100, accuracy: 2)
        }
        // A poor fix that matches the route still advances the progress.
        let advanced = poor.update(position: point(along: 200, offset: 5), horizontalAccuracy: 120,
                                   countsTowardsOffRoute: false)
        XCTAssertEqual(advanced.distanceAlong, 200, accuracy: 2)

        let good = tracker(straightRoute())
        XCTAssertFalse(good.update(position: point(along: 100, offset: 0)).isOffRoute)
        var last = good.update(position: point(along: 100, offset: 150), horizontalAccuracy: 150)
        last = good.update(position: point(along: 100, offset: 150), horizontalAccuracy: 150)
        last = good.update(position: point(along: 100, offset: 150), horizontalAccuracy: 150)
        XCTAssertTrue(last.isOffRoute)
    }

    func testPoorFixKeepsConfirmedOffRouteState() {
        let t = tracker(straightRoute())
        _ = t.update(position: point(along: 100, offset: 0))
        for _ in 0..<3 { _ = t.update(position: point(along: 100, offset: 150)) }
        let p = t.update(position: point(along: 100, offset: 150), horizontalAccuracy: 150, countsTowardsOffRoute: false)
        XCTAssertTrue(p.isOffRoute)
    }

    // MARK: Out-and-back section (U-turn at a median break)

    func testOutAndBackDoesNotJumpToReturnLeg() {
        // 300 m north, U-turn, back south on a carriageway 15 m to the west, vertices every 25 m.
        var pts: [GeoPoint] = []
        for i in 0...12 { pts.append(Geo.destination(from: start, bearing: 0, distance: Double(i) * 25)) }
        let westStart = Geo.destination(from: start, bearing: 270, distance: 15)
        for i in stride(from: 12, through: 0, by: -1) {
            pts.append(Geo.destination(from: westStart, bearing: 0, distance: Double(i) * 25))
        }
        let steps = [RouteStepInfo(instruction: "", distance: 0),
                     RouteStepInfo(instruction: "Двигайтесь на север", distance: 300),
                     RouteStepInfo(instruction: "Развернитесь", distance: 15),
                     RouteStepInfo(instruction: "Пункт назначения будет справа", distance: 300)]
        let t = RouteProgressTracker(polyline: pts, steps: steps, expectedTravelTime: 120)
        var previous = -1.0
        // Outbound fixes 10 m west of the outbound leg, i.e. nearer to the return leg (5 m) than to the true one.
        for d in stride(from: 0.0, through: 280.0, by: 20.0) {
            let fix = Geo.destination(from: Geo.destination(from: start, bearing: 0, distance: d),
                                      bearing: 270, distance: 10)
            let p = t.update(position: fix)
            XCTAssertFalse(p.isOffRoute)
            XCTAssertEqual(p.distanceAlong, d, accuracy: 3, "outbound fix at \(d) m")
            XCTAssertGreaterThanOrEqual(p.distanceAlong, previous)
            previous = p.distanceAlong
            XCTAssertEqual(p.nextStepIndex, 2, "the U-turn must stay the next maneuver at \(d) m")
            XCTAssertEqual(p.nextManeuver, .uTurn)
        }
        // With the GPS course the outbound leg is kept even when the fix lies on the return carriageway.
        let onReturnLine = Geo.destination(from: westStart, bearing: 0, distance: 270)
        let withCourse = t.update(position: onReturnLine, course: 2)
        XCTAssertEqual(withCourse.distanceAlong, 270, accuracy: 3)
        XCTAssertEqual(withCourse.nextStepIndex, 2)
        // After the U-turn the return leg is followed normally.
        let back = Geo.destination(from: westStart, bearing: 0, distance: 250)
        let p = t.update(position: back, course: 181)
        XCTAssertEqual(p.distanceAlong, 300 + 15 + 50, accuracy: 3)
        XCTAssertEqual(p.nextManeuver, .arrive)
    }

    func testStartMidRouteStillMatchesWholeRoute() {
        // A fresh tracker far along the route (no continuous candidate) falls back to the whole-route search.
        let t = tracker(straightRoute(length: 3000))
        let p = t.update(position: point(along: 2500, offset: 4))
        XCTAssertEqual(p.distanceAlong, 2500, accuracy: 3)
        XCTAssertFalse(p.isOffRoute)
    }

    // MARK: Reroute policy

    func testOSRMURLWithHeading() throws {
        let from = GeoPoint(41.3, 69.24), to = GeoPoint(41.35, 69.3)
        let plain = try XCTUnwrap(OSRM.routeURL(endpoint: OSRM.defaultEndpoint, from: from, to: to))
        XCTAssertFalse(plain.absoluteString.contains("bearings"))
        let url = try XCTUnwrap(OSRM.routeURL(endpoint: OSRM.defaultEndpoint, from: from, to: to, heading: 359.7))
        XCTAssertTrue(url.absoluteString.hasSuffix("&annotations=true&bearings=0,45;"), url.absoluteString)
        let west = try XCTUnwrap(OSRM.routeURL(endpoint: OSRM.defaultEndpoint, from: from, to: to, heading: -90))
        XCTAssertTrue(west.absoluteString.hasSuffix("&bearings=270,45;"), west.absoluteString)
        let invalid = try XCTUnwrap(OSRM.routeURL(endpoint: OSRM.defaultEndpoint, from: from, to: to, heading: .nan))
        XCTAssertEqual(invalid, plain)
    }

    func testReroutePreferredIndexFollowsHeading() {
        let north = [start, Geo.destination(from: start, bearing: 0, distance: 5),
                     Geo.destination(from: start, bearing: 0, distance: 200)]
        let south = [start, Geo.destination(from: start, bearing: 180, distance: 200)]
        XCTAssertEqual(Geo.angleDifference(ReroutePolicy.initialBearing(of: north)!, 0), 0, accuracy: 1)
        XCTAssertNil(ReroutePolicy.initialBearing(of: [start, Geo.destination(from: start, bearing: 0, distance: 5)]))
        // Fastest route starts backwards: the second one is taken while driving north.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 10), 1)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 350), 1)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 170), 0)
        // Unknown heading or no matching route: the fastest.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: nil), 0)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south], heading: 0), 0)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [], heading: 0), 0)
    }

    func testRerouteRetryIntervalBacksOff() {
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: 0), 15)
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: 1), 30)
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: 2), 60)
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: 3), 120)
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: 50), 120)
        XCTAssertEqual(ReroutePolicy.retryInterval(failures: -1), 15)
    }

    func testIncidentAtOrBehindCar() {
        XCTAssertTrue(ReroutePolicy.isIncidentAtOrBehind(distanceAlongRoute: 500, carDistanceAlong: 500))
        XCTAssertTrue(ReroutePolicy.isIncidentAtOrBehind(distanceAlongRoute: 520, carDistanceAlong: 500))
        XCTAssertTrue(ReroutePolicy.isIncidentAtOrBehind(distanceAlongRoute: 100, carDistanceAlong: 500))
        XCTAssertFalse(ReroutePolicy.isIncidentAtOrBehind(distanceAlongRoute: 540, carDistanceAlong: 500))
    }

    // MARK: Route features in two phases

    func testCandidatesThenFeaturesMatchExtractAcrossChunks() {
        let route = straightRoute(length: 2000)
        func node(_ id: Int64, along: Double, offset: Double = 5, tags: [String: String]) -> OSMElement {
            let p = point(along: along, offset: offset)
            return OSMElement(type: .node, id: id, lat: p.latitude, lon: p.longitude, tags: tags)
        }
        let signal = ["highway": "traffic_signals"]
        let chunk1 = [node(1, along: 100, tags: signal), node(2, along: 130, tags: signal),
                      node(3, along: 400, tags: ["highway": "speed_camera"])]
        let chunk2 = [node(4, along: 150, tags: signal), node(5, along: 900, tags: ["highway": "crossing"]),
                      node(6, along: 1200, offset: 400, tags: signal)]
        let chunk3 = [node(7, along: 1500, tags: ["amenity": "school", "name": "1"]),
                      node(8, along: 1600, offset: 100, tags: ["amenity": "school", "name": "1"])]
        let cumulative = Geo.cumulativeDistances(route)
        var collected: [OSMElement] = []
        var candidates: [RouteFeatureCandidate] = []
        for chunk in [chunk1, chunk2, chunk3] {
            collected.append(contentsOf: chunk)
            candidates += RouteFeatureExtractor.candidates(elements: chunk, route: route, cumulative: cumulative)
            XCTAssertEqual(RouteFeatureExtractor.features(from: candidates),
                           RouteFeatureExtractor.extract(elements: collected, route: route, cumulative: cumulative))
        }
        XCTAssertEqual(candidates.count, 7)   // the signal 400 m beside the route is dropped
        XCTAssertFalse(RouteFeatureExtractor.features(from: candidates).isEmpty)
        XCTAssertTrue(RouteFeatureExtractor.candidates(elements: chunk1, route: []).isEmpty)
    }
}
