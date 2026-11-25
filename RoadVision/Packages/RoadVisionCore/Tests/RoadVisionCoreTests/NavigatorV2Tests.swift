import XCTest
@testable import RoadVisionCore

/// OSRM parsing, multi-engine route comparison, the route timeline and the Overpass chunk planner.
final class NavigatorV2Tests: XCTestCase {
    // MARK: Fixtures (hand-written, OSRM response shape)

    /// A straight-ish line north from (41.300, 69.240), `count` points ~111 m apart, optionally shifted east.
    func line(count: Int = 30, eastShift: Double = 0, start: Double = 41.300) -> [GeoPoint] {
        (0..<count).map { GeoPoint(start + Double($0) * 0.001, 69.240 + eastShift) }
    }

    func osrmFixture() throws -> Data {
        let main = line(count: 30)
        let alt = line(count: 30, eastShift: 0.004)
        func step(_ type: String, _ modifier: String?, name: String, distance: Double, location: GeoPoint,
                  lanes: [[String: Any]]? = nil, exit: Int? = nil, classes: [String]? = nil) -> [String: Any] {
            var maneuver: [String: Any] = ["type": type, "location": [location.longitude, location.latitude],
                                           "bearing_before": 0, "bearing_after": 0]
            if let modifier { maneuver["modifier"] = modifier }
            if let exit { maneuver["exit"] = exit }
            var intersection: [String: Any] = ["location": [location.longitude, location.latitude]]
            if let lanes { intersection["lanes"] = lanes }
            if let classes { intersection["classes"] = classes }
            return ["maneuver": maneuver, "name": name, "distance": distance, "duration": distance / 10,
                    "geometry": "", "intersections": [intersection]]
        }
        let lanes: [[String: Any]] = [
            ["valid": true, "indications": ["left"]],
            ["valid": false, "indications": ["straight"]],
            ["valid": false, "indications": ["straight", "right"]],
        ]
        let steps: [[String: Any]] = [
            step("depart", nil, name: "Амира Темура", distance: 1000, location: main[0]),
            step("turn", "left", name: "Навои", distance: 1200, location: main[9], lanes: lanes),
            step("roundabout", "right", name: "Бабура", distance: 700, location: main[20], exit: 2,
                 classes: ["toll"]),
            step("arrive", "right", name: "", distance: 0, location: main[29]),
        ]
        let route1: [String: Any] = [
            "distance": 3220.0, "duration": 290.0, "geometry": Polyline.encode(main),
            "legs": [["summary": "Амира Темура, Навои", "steps": steps,
                      "annotation": ["distance": [111.0], "duration": [10.0], "speed": [11.1]]]],
        ]
        let route2: [String: Any] = [
            "distance": 3400.0, "duration": 330.0, "geometry": Polyline.encode(alt),
            "legs": [["summary": "", "steps": [
                step("depart", nil, name: "Шота Руставели", distance: 3400, location: alt[0]),
                step("arrive", nil, name: "", distance: 0, location: alt[29]),
            ]]],
        ]
        return try JSONSerialization.data(withJSONObject: ["code": "Ok", "routes": [route1, route2], "waypoints": []])
    }

    // MARK: OSRM

    func testOSRMURL() throws {
        let url = try XCTUnwrap(OSRM.routeURL(endpoint: OSRM.defaultEndpoint + "/", from: GeoPoint(41.3, 69.24),
                                              to: GeoPoint(41.35, 69.3)))
        XCTAssertEqual(url.absoluteString,
                       "https://routing.openstreetmap.de/routed-car/route/v1/driving/69.240000,41.300000;69.300000,41.350000"
                       + "?overview=full&geometries=polyline6&steps=true&alternatives=true&annotations=true")
        XCTAssertNil(OSRM.routeURL(endpoint: "ftp://x", from: GeoPoint(41.3, 69.24), to: GeoPoint(41.35, 69.3)))
        XCTAssertNil(OSRM.routeURL(endpoint: "", from: GeoPoint(41.3, 69.24), to: GeoPoint(41.35, 69.3)))
    }

    func testOSRMParse() throws {
        let routes = try OSRM.parseRoutes(osrmFixture())
        XCTAssertEqual(routes.count, 2)
        let r = routes[0]
        XCTAssertEqual(r.source, .osrm)
        XCTAssertEqual(r.name, "Амира Темура, Навои")
        XCTAssertEqual(r.distance, 3220)
        XCTAssertEqual(r.expectedTravelTime, 290)
        XCTAssertEqual(r.polyline.count, 30)
        XCTAssertTrue(r.hasTolls)
        XCTAssertEqual(r.steps.count, 4)
        XCTAssertEqual(r.steps[0].instruction, "")
        XCTAssertEqual(r.steps[0].maneuver, .depart)
        XCTAssertEqual(r.steps[1].instruction, "Поверните налево на Навои")
        XCTAssertEqual(r.steps[1].maneuver, .left)
        XCTAssertEqual(r.steps[1].lanes.map(\.turns), [[.left], [.through], [.through, .right]])
        XCTAssertEqual(r.steps[1].activeLanes, [true, false, false])
        XCTAssertEqual(r.steps[2].instruction, "На круговом движении — 2-й съезд на Бабура")
        XCTAssertEqual(r.steps[2].maneuver, .roundabout)
        XCTAssertEqual(r.steps[3].instruction, "Пункт назначения справа")
        XCTAssertEqual(r.steps[3].maneuver, .arrive)
        XCTAssertEqual(routes[1].name, "Шота Руставели")

        // Usable by the progress tracker: the next maneuver after the start is the left turn.
        let tracker = RouteProgressTracker(polyline: r.polyline, steps: r.steps, expectedTravelTime: r.expectedTravelTime)
        let progress = tracker.update(position: r.polyline[2])
        XCTAssertEqual(progress.nextInstruction, "Поверните налево на Навои")
        XCTAssertEqual(progress.nextActiveLanes, [true, false, false])
    }

    func testOSRMErrors() {
        let data = Data("{\"code\":\"NoRoute\",\"message\":\"Impossible route between points\"}".utf8)
        XCTAssertThrowsError(try OSRM.parseRoutes(data)) { error in
            let e = error as? OSRMError
            XCTAssertEqual(e?.code, "NoRoute")
            XCTAssertEqual(e?.russianDescription, "OSRM не нашёл маршрут между этими точками.")
        }
        XCTAssertThrowsError(try OSRM.parseRoutes(Data("<html>".utf8)))
    }

    func testOSRMInstructionsAndMapping() {
        XCTAssertEqual(OSRM.instruction(type: "turn", modifier: "right", name: nil), "Поверните направо")
        XCTAssertEqual(OSRM.instruction(type: "turn", modifier: "uturn", name: "Навои"), "Развернитесь на Навои")
        XCTAssertEqual(OSRM.instruction(type: "turn", modifier: "sharp left", name: nil), "Резко поверните налево")
        XCTAssertEqual(OSRM.instruction(type: "new name", modifier: "straight", name: "Бабура"), "Продолжайте движение по Бабура")
        XCTAssertEqual(OSRM.instruction(type: "continue", modifier: nil, name: nil), "Продолжайте движение прямо")
        XCTAssertEqual(OSRM.instruction(type: "fork", modifier: "slight right", name: nil), "На развилке держитесь правее")
        XCTAssertEqual(OSRM.instruction(type: "off ramp", modifier: "slight right", name: "М39"), "Сверните направо на съезд на М39")
        XCTAssertEqual(OSRM.instruction(type: "end of road", modifier: "left", name: nil), "В конце дороги поверните налево")
        XCTAssertEqual(OSRM.instruction(type: "roundabout", modifier: nil, name: nil), "Въезжайте на круговое движение")
        XCTAssertEqual(OSRM.instruction(type: "arrive", modifier: nil, name: nil), "Пункт назначения")
        XCTAssertEqual(OSRM.maneuverType(type: "fork", modifier: "slight left"), .keepLeft)
        XCTAssertEqual(OSRM.maneuverType(type: "off ramp", modifier: "right"), .exitRight)
        XCTAssertEqual(OSRM.maneuverType(type: "turn", modifier: "slight right"), .slightRight)
        XCTAssertEqual(OSRM.maneuverType(type: "exit roundabout", modifier: "right"), .roundabout)
        XCTAssertEqual(OSRM.maneuverType(type: "merge", modifier: "left"), .merge)
        XCTAssertEqual(OSRM.laneTurn("uturn"), .reverse)
        XCTAssertEqual(OSRM.lanes(from: [OSRM.OSRMLane(indications: ["none"], valid: true)]).lanes, [Lane(turns: [])])
        XCTAssertEqual(RouteSource.osrm.displayName, "OpenStreetMap (OSRM)")
        XCTAssertEqual(RouteSource.allCases.map(\.badge), ["Apple", "Valhalla", "OSRM"])
    }

    // MARK: Valhalla arrival (finding #2)

    func testValhallaArrivalUsesFutureTense() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "valhalla_route_tashkent", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let route = try XCTUnwrap(Valhalla.parseRoutes(Data(contentsOf: url)).first)
        XCTAssertEqual(route.steps.last?.instruction, "Пункт назначения будет справа.")
        XCTAssertEqual(Valhalla.arrivalInstruction(instruction: "Вы прибыли в пункт назначения.", alert: nil),
                       "Вы прибудете в пункт назначения.")
        XCTAssertEqual(Valhalla.arrivalInstruction(instruction: "x", alert: "  "), "x")
    }

    // MARK: Route comparison

    func testOverlapAndMerge() throws {
        let a = line()
        let aPrime = a.map { GeoPoint($0.latitude, $0.longitude + 0.0001) }   // ≈ 8 m east
        let far = line(eastShift: 0.004)                                        // ≈ 330 m east
        XCTAssertEqual(RouteComparison.overlap(a, a), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(RouteComparison.similarity(a, aPrime), 0.99)
        XCTAssertEqual(RouteComparison.overlap(a, far), 0, accuracy: 1e-9)
        // Half of the route shared.
        let half = Array(a.prefix(15)) + line(count: 15, eastShift: 0.004, start: 41.315)
        let partial = RouteComparison.overlap(a, half)
        XCTAssertGreaterThan(partial, 0.4)
        XCTAssertLessThan(partial, 0.7)

        let valhalla = NavRoute(source: .valhalla, name: "V", polyline: a, distance: 3220, expectedTravelTime: 300, steps: [])
        let osrm = NavRoute(source: .osrm, name: "O", polyline: aPrime, distance: 3225, expectedTravelTime: 290, steps: [])
        let apple = NavRoute(source: .apple, name: "A", polyline: far, distance: 3300, expectedTravelTime: 420, steps: [])
        let choices = RouteComparison.merge([valhalla, apple, osrm])
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices[0].route.source, .osrm)            // fastest of the duplicate group
        XCTAssertEqual(choices[0].duplicates.map(\.source), [.valhalla])
        XCTAssertEqual(choices[0].sources, [.osrm, .valhalla])
        XCTAssertEqual(choices[1].route.source, .apple)
        XCTAssertEqual(RouteComparison.delayText(420, comparedTo: 290), "+2 мин")
        XCTAssertNil(RouteComparison.delayText(300, comparedTo: 290))
        let notes = RouteComparison.notes(for: choices)
        XCTAssertTrue(notes.contains { $0.contains("пробки") })
        XCTAssertTrue(notes.contains { $0.contains("выигрывает") })
    }

    func testFacts() {
        let route = NavRoute(source: .valhalla, name: "R", polyline: line(), distance: 3000, expectedTravelTime: 300,
                             steps: [RouteStepInfo(instruction: "", distance: 1000, maneuver: .depart),
                                     RouteStepInfo(instruction: "Налево", distance: 2000, maneuver: .left),
                                     RouteStepInfo(instruction: "Пункт назначения", distance: 0, maneuver: .arrive)])
        let edges = [
            RouteEdgeAttributes(startDistance: 0, endDistance: 1000, speedLimitKmh: 60, roadClass: "primary"),
            RouteEdgeAttributes(startDistance: 1000, endDistance: 2000, speedLimitKmh: 80, roadClass: "trunk",
                                hasTrafficSignal: true, isBridge: true),
            RouteEdgeAttributes(startDistance: 2000, endDistance: 3000, roadClass: "residential", surface: "dirt"),
        ]
        let facts = RouteComparison.facts(for: route, edges: edges)
        XCTAssertEqual(facts.averageSpeedKmh ?? 0, 36, accuracy: 0.01)
        XCTAssertEqual(facts.maxSpeedLimitKmh, 80)
        XCTAssertEqual(facts.averageSpeedLimitKmh ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(facts.speedLimitCoverage ?? 0, 2.0 / 3, accuracy: 0.01)
        XCTAssertEqual(facts.primaryRoadShare ?? 0, 2.0 / 3, accuracy: 0.01)
        XCTAssertEqual(facts.unpavedShare ?? 0, 1.0 / 3, accuracy: 0.01)
        XCTAssertEqual(facts.signalCount, 1)
        XCTAssertEqual(facts.maneuverCount, 1)
        XCTAssertEqual(facts.bridgeCount, 1)
        let bare = RouteComparison.facts(for: route, edges: [], signalCount: 4)
        XCTAssertEqual(bare.signalCount, 4)
        XCTAssertNil(bare.primaryRoadShare)
    }

    // MARK: Timeline

    func testTimeline() throws {
        let polyline = line()   // ≈ 3225 m
        let total = Geo.polylineLength(polyline)
        let route = NavRoute(source: .valhalla, name: "R", polyline: polyline, distance: total, expectedTravelTime: 300,
                             steps: [RouteStepInfo(instruction: "", distance: 1000, maneuver: .depart),
                                     RouteStepInfo(instruction: "Поверните налево", distance: 2000, maneuver: .left,
                                                   lanes: [Lane(turns: [.left]), Lane(turns: [.through])],
                                                   activeLanes: [true, false]),
                                     RouteStepInfo(instruction: "Пункт назначения будет справа.", distance: 0,
                                                   maneuver: .arrive)])
        let edges = [
            RouteEdgeAttributes(startDistance: 0, endDistance: 800, speedLimitKmh: 60, laneCount: 3, typicalSpeedKmh: 50),
            RouteEdgeAttributes(startDistance: 800, endDistance: 850, speedLimitKmh: 40, laneCount: 3, typicalSpeedKmh: 50),
            RouteEdgeAttributes(startDistance: 850, endDistance: 2000, speedLimitKmh: 60, laneCount: 2,
                                typicalSpeedKmh: 50, hasTrafficSignal: true),
            RouteEdgeAttributes(startDistance: 2000, endDistance: total, speedLimitKmh: 40, laneCount: 2, typicalSpeedKmh: 25),
        ]
        let segments = RouteTimeline.speedLimitSegments(edges: edges, totalDistance: total)
        XCTAssertEqual(segments.map(\.limitKmh), [60, 40])        // the 50 m "40" blip is folded
        XCTAssertEqual(segments[0].end, 2000, accuracy: 0.001)

        let camera = RouteFeature(id: "node/1", kind: .speedCamera, coordinate: polyline[25], distanceAlongRoute: 2700,
                                  offsetFromRoute: 5, name: nil, tags: ["maxspeed": "40"])
        let osmSignal = RouteFeature(id: "node/2", kind: .trafficSignals, coordinate: polyline[18],
                                     distanceAlongRoute: 1990, offsetFromRoute: 3, name: nil, tags: [:])
        let fuel = RouteFeature(id: "node/3", kind: .fuel, coordinate: polyline[5], distanceAlongRoute: 500,
                                offsetFromRoute: 40, name: "UzGasOil", tags: ["brand": "UNG"])
        let incident = IncidentOnRoute(incident: RoadIncident(kind: .pothole, coordinate: polyline[12]),
                                       distanceAlongRoute: 1300)
        let events = RouteTimeline.build(route: route, edges: edges, features: [camera, osmSignal, fuel],
                                         incidents: [incident])
        let categories = events.map(\.kind.category)
        XCTAssertEqual(categories.filter { $0 == "signal" }.count, 1)   // Valhalla signal merged with the OSM one
        XCTAssertEqual(events.first?.kind, .speedLimit(60))
        XCTAssertTrue(events.contains { $0.kind == .maneuver(.left) && $0.detail == "полос: 2, подходят: 1" })
        XCTAssertTrue(events.contains { $0.kind == .lanes(from: 3, to: 2) && $0.title == "Сужение до 2 полос" })
        XCTAssertTrue(events.contains { $0.kind == .feature(.speedCamera) && $0.detail == "контроль 40 км/ч" })
        XCTAssertTrue(events.contains { $0.kind == .feature(.fuel) && $0.detail == "UzGasOil · UNG" })
        XCTAssertTrue(events.contains { $0.kind == .incident(.pothole) })
        XCTAssertEqual(events.last?.kind, .destination)
        XCTAssertFalse(events.contains { $0.kind == .maneuver(.arrive) })
        for i in 1..<events.count {
            XCTAssertLessThanOrEqual(events[i - 1].distanceAlongRoute, events[i].distanceAlongRoute + 0.5)
        }
        XCTAssertEqual(RouteTimeline.upcoming(events, from: 1500, limit: 2).first?.kind, .trafficSignal)

        // Time offsets follow typical speeds: the slow last part (25 km/h) takes proportionally longer.
        let half = RouteTimeline.timeOffset(to: 2000, from: 0, remainingTime: 300, totalDistance: total, edges: edges)
        XCTAssertLessThan(half, 300 * 2000 / total)
        XCTAssertEqual(RouteTimeline.timeOffset(to: total, from: 0, remainingTime: 300, totalDistance: total, edges: edges),
                       300, accuracy: 0.01)
        XCTAssertEqual(RouteTimeline.timeOffset(to: 1000, from: 0, remainingTime: 300, totalDistance: 2000, edges: []),
                       150, accuracy: 0.01)
    }

    // MARK: Overpass chunk plan (finding #18)

    func testRouteQueryPlanner() {
        // 40 km winding route with 4000 vertices.
        let route = (0..<4000).map { i in
            GeoPoint(41.2 + Double(i) * 0.00009, 69.2 + 0.002 * sin(Double(i) / 15))
        }
        let plan = RouteQueryPlanner.plan(route: route)
        XCTAssertTrue(plan.isComplete)
        XCTAssertGreaterThanOrEqual(plan.chunks.count, Int(plan.totalLength / 3000))
        for chunk in plan.chunks {
            XCTAssertLessThanOrEqual(chunk.count, 60)
            XCTAssertLessThanOrEqual(Geo.polylineLength(chunk), 3000 + 1)
        }
        XCTAssertEqual(plan.chunks.first?.first, route.first)
        XCTAssertEqual(plan.chunks.last?.last, route.last)
        for i in 1..<plan.chunks.count { XCTAssertEqual(plan.chunks[i].first, plan.chunks[i - 1].last) }
        // Every original vertex lies within the tolerance of some chunk.
        for p in stride(from: 0, to: route.count, by: 97).map({ route[$0] }) {
            let near = plan.chunks.contains { (Geo.project(p, onto: $0)?.distanceFromLine ?? .infinity) <= 10.5 }
            XCTAssertTrue(near)
        }
        // A long straight segment is densified.
        let straight = [GeoPoint(41.0, 69.0), GeoPoint(41.1, 69.0)]   // ≈ 11 km
        let chunks = RouteQueryPlanner.chunks(straight, maxPoints: 60, maxLength: 3000)
        XCTAssertEqual(chunks.count, 4)
        // Capped plans report what was dropped.
        let capped = RouteQueryPlanner.plan(route: route, maxChunks: 3)
        XCTAssertFalse(capped.isComplete)
        XCTAssertEqual(capped.chunks.count, 3)
        XCTAssertLessThan(capped.coveredLength, capped.totalLength)
    }

    // MARK: Matcher score (finding #19) & new feature kinds

    func testScoredMatchAndPOIKinds() throws {
        func way(_ id: Int64, _ points: [GeoPoint], _ tags: [String: String]) throws -> OSMElement {
            let geometry = points.map { "{\"lat\":\($0.latitude),\"lon\":\($0.longitude)}" }.joined(separator: ",")
            let tagJSON = tags.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
            let json = "{\"type\":\"way\",\"id\":\(id),\"geometry\":[\(geometry)],\"tags\":{\(tagJSON)}}"
            return try JSONDecoder().decode(OSMElement.self, from: Data(json.utf8))
        }
        let northSouth = try way(1, [GeoPoint(41.300, 69.2400), GeoPoint(41.310, 69.2400)], ["highway": "primary"])
        let eastWest = try way(2, [GeoPoint(41.3049, 69.235), GeoPoint(41.3049, 69.245)], ["highway": "primary"])
        let position = GeoPoint(41.3050, 69.24005)
        let match = try XCTUnwrap(RoadMatcher.scoredMatch(elements: [northSouth, eastWest], position: position, heading: 0))
        XCTAssertEqual(match.road.wayID, 1)
        XCTAssertGreaterThanOrEqual(match.score, match.road.distanceToRoad)
        let crossing = try XCTUnwrap(RoadMatcher.scoredMatch(elements: [eastWest], position: position, heading: 0))
        XCTAssertGreaterThan(crossing.score, match.score)   // heading penalty, although the raw distance is similar

        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["amenity": "fuel"]), .fuel)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["amenity": "parking"]), .parking)
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["amenity": "parking", "access": "private"]))
        XCTAssertTrue(RouteFeatureKind.fuel.isPointOfInterest)
        XCTAssertFalse(RouteFeatureKind.speedCamera.isPointOfInterest)
        let q = OverpassQuery.featuresAlong([GeoPoint(41.31, 69.28), GeoPoint(41.32, 69.28)])
        XCTAssertTrue(q.contains("[amenity=fuel]"))
        XCTAssertTrue(q.contains("nwr(around:60,41.310000,69.280000,41.320000,69.280000)[amenity=parking]"))
    }
}
