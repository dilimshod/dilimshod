import XCTest
@testable import RoadVisionCore

/// Loads files from `Tests/RoadVisionCoreTests/Fixtures` (copied as a resource directory).
enum RoadFixture {
    static func data(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
                                "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }
}

/// Local metric frame used by `overpass_roads_tashkent.json` (origin: Amir Temur square).
enum TashkentFrame {
    static let origin = GeoPoint(41.3111, 69.2797)

    /// `x` metres east, `y` metres north of the origin (north/south first, then east/west — like the fixture generator).
    static func xy(_ x: Double, _ y: Double) -> GeoPoint {
        let p = Geo.destination(from: origin, bearing: y >= 0 ? 0 : 180, distance: abs(y))
        return Geo.destination(from: p, bearing: x >= 0 ? 90 : 270, distance: abs(x))
    }
}

final class RoadParsingTests: XCTestCase {
    // MARK: OSMModels

    func testDecodeRoadsFixture() throws {
        let response = try OverpassQuery.decodeResponse(RoadFixture.data("overpass_roads_tashkent"))
        XCTAssertEqual(response.elements.count, 14)
        XCTAssertEqual(response.timestampOSMBase, "2026-11-25T14:20:31Z")
        XCTAssertNil(response.remark)
        XCTAssertFalse(response.isPartial)

        let avenue = try XCTUnwrap(response.elements.first { $0.id == 23710011 })
        XCTAssertEqual(avenue.type, .way)
        XCTAssertEqual(avenue.key, "way/23710011")
        XCTAssertEqual(avenue.geometry?.count, 4)
        XCTAssertNil(avenue.nodes)
        XCTAssertNil(avenue.lat)
        XCTAssertEqual(avenue.tags["name:ru"], "проспект Амира Темура")
        XCTAssertEqual(avenue[tag: "lanes"], "6")
        XCTAssertNotNil(avenue.coordinate)

        let signal = try XCTUnwrap(response.elements.first { $0.id == 1150000101 })
        XCTAssertEqual(signal.type, .node)
        XCTAssertEqual(signal.key, "node/1150000101")
        let c = try XCTUnwrap(signal.coordinate)
        XCTAssertLessThan(Geo.distance(c, TashkentFrame.xy(118, 45)), 0.5)
    }

    func testDecodeRemarkUnknownTypesAndNullGeometry() throws {
        let response = try OverpassQuery.decodeResponse(RoadFixture.data("overpass_remark"))
        // "area" and "count" elements and the element without an id are skipped.
        XCTAssertEqual(response.elements.map(\.key), ["node/1150000101", "way/23710099"])
        XCTAssertTrue(response.isPartial)
        XCTAssertTrue(response.remark?.contains("timed out") == true)
        // A bounded `out geom` emits null for vertices outside the box: they are dropped.
        XCTAssertEqual(response.elements[1].geometry?.count, 2)
        XCTAssertEqual(try OverpassQuery.decode(RoadFixture.data("overpass_remark")).count, 2)
    }

    func testStandaloneElementDecodingIsTolerant() throws {
        let json = """
        [
          {"type": "area", "id": 3600000001, "tags": {"name": "Toshkent"}},
          {"type": "way", "id": 5, "center": {"lat": 41.3, "lon": 69.2}, "nodes": [1, 2, 3]},
          {"type": "count", "id": 0, "tags": {"nodes": 12, "total": 12.5, "flag": true}}
        ]
        """
        let elements = try JSONDecoder().decode([OSMElement].self, from: Data(json.utf8))
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0].type, .relation, "unknown types decode as relation instead of failing")
        XCTAssertEqual(elements[1].tags, [:])
        XCTAssertEqual(elements[1].nodes, [1, 2, 3])
        XCTAssertEqual(elements[1].coordinate, GeoPoint(41.3, 69.2))
        XCTAssertEqual(elements[2].tags["nodes"], "12")
        XCTAssertEqual(elements[2].tags["flag"], "yes")
    }

    func testCoordinateFallbacks() {
        let node = OSMElement(type: .node, id: 1, lat: 41.0, lon: 69.0)
        XCTAssertEqual(node.coordinate, GeoPoint(41.0, 69.0))

        let centered = OSMElement(type: .way, id: 2, center: GeoPoint(41.5, 69.5),
                                  geometry: [GeoPoint(40, 60), GeoPoint(40, 61)])
        XCTAssertEqual(centered.coordinate, GeoPoint(41.5, 69.5), "center wins over geometry")

        let open = OSMElement(type: .way, id: 3, geometry: [GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.002), GeoPoint(41.0, 69.010)])
        XCTAssertEqual(open.coordinate?.longitude ?? 0, 69.005, accuracy: 0.0001, "half-way point along an open way")

        let ring = OSMElement(type: .way, id: 4, geometry: [GeoPoint(41.0, 69.0), GeoPoint(41.0, 69.002),
                                                             GeoPoint(41.002, 69.002), GeoPoint(41.002, 69.0),
                                                             GeoPoint(41.0, 69.0)])
        XCTAssertEqual(ring.coordinate?.latitude ?? 0, 41.001, accuracy: 1e-9)
        XCTAssertEqual(ring.coordinate?.longitude ?? 0, 69.001, accuracy: 1e-9)

        XCTAssertNil(OSMElement(type: .relation, id: 5).coordinate)
        XCTAssertEqual(OSMElement(type: .relation, id: 5).key, "relation/5")
    }

    // MARK: Overpass errors

    func testDecodeNginx504Page() throws {
        XCTAssertThrowsError(try OverpassQuery.decode(RoadFixture.data("overpass_error_504", "html"))) { error in
            guard let e = error as? OverpassError, case .htmlError(let message) = e else {
                return XCTFail("expected htmlError, got \(error)")
            }
            XCTAssertEqual(message, "504 Gateway Time-out")
            XCTAssertTrue(e.isTimeout)
            XCTAssertTrue(e.isRetryable)
            XCTAssertFalse(e.isRateLimited)
            XCTAssertTrue(e.errorDescription?.contains("не ответил вовремя") == true)
        }
    }

    func testDecodeOverpassParseErrorPage() throws {
        XCTAssertThrowsError(try OverpassQuery.decode(RoadFixture.data("overpass_error_parse", "html"))) { error in
            guard let e = error as? OverpassError, case .htmlError(let message) = e else {
                return XCTFail("expected htmlError, got \(error)")
            }
            XCTAssertTrue(message.hasPrefix("Error: line 2: parse error: ';' expected - ')' found."), message)
            XCTAssertTrue(message.contains("static error"), message)
            XCTAssertFalse(message.contains("ODbL"), "the licence paragraph is not an error")
            XCTAssertFalse(e.isRetryable)
            XCTAssertTrue(e.errorDescription?.hasPrefix("Сервер OpenStreetMap (Overpass) вернул ошибку") == true)
        }
    }

    func testDecodeRateLimitedPage() throws {
        XCTAssertThrowsError(try OverpassQuery.decode(RoadFixture.data("overpass_error_rate_limited", "html"))) { error in
            let e = error as? OverpassError
            XCTAssertEqual(e?.isRateLimited, true)
            XCTAssertEqual(e?.isRetryable, true)
            XCTAssertTrue(e?.errorDescription?.contains("ограничил частоту") == true)
        }
    }

    func testDecodeOtherBodies() throws {
        XCTAssertThrowsError(try OverpassQuery.decode(Data())) { XCTAssertEqual($0 as? OverpassError, .emptyResponse) }
        XCTAssertThrowsError(try OverpassQuery.decode(Data(" \n\t".utf8))) { XCTAssertEqual($0 as? OverpassError, .emptyResponse) }
        XCTAssertThrowsError(try OverpassQuery.decode(Data("{".utf8))) { error in
            guard case .invalidJSON = error as? OverpassError else { return XCTFail("expected invalidJSON, got \(error)") }
        }
        XCTAssertThrowsError(try OverpassQuery.decode(Data("\n  <html><body><p>Error: runtime error: out of memory</p></body></html>".utf8))) { error in
            guard case .htmlError(let m) = error as? OverpassError else { return XCTFail("expected htmlError") }
            XCTAssertEqual(m, "Error: runtime error: out of memory")
            XCTAssertEqual((error as? OverpassError)?.isRetryable, true)
        }
        // UTF-8 BOM before the JSON is tolerated.
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data(#"{"elements":[]}"#.utf8))
        XCTAssertEqual(try OverpassQuery.decode(bom).count, 0)
        XCTAssertEqual(try OverpassQuery.decode(Data(#"{"version":0.6}"#.utf8)).count, 0)
    }

    // MARK: Queries

    func testRoadsAroundQuery() {
        let q = OverpassQuery.roadsAround(GeoPoint(41.3111, 69.2797))
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:15];"))
        XCTAssertTrue(q.contains("way(around:30,41.311100,69.279700)[highway][highway!~\"^("))
        XCTAssertTrue(q.contains("out tags geom;"))
        XCTAssertTrue(q.contains("node(around:80,41.311100,69.279700)[highway=traffic_signals];"))
        XCTAssertTrue(q.hasSuffix("out;"))
        for excluded in ["footway", "path", "cycleway", "steps", "pedestrian", "bridleway", "corridor", "elevator",
                         "platform", "proposed", "construction"] {
            XCTAssertTrue(OverpassQuery.excludedHighwayValues.contains(excluded), excluded)
            XCTAssertTrue(q.contains("|\(excluded)|") || q.contains("(\(excluded)|") || q.contains("|\(excluded))"), excluded)
        }
        XCTAssertFalse(q.contains("|primary"), "drivable classes must not be excluded")

        let custom = OverpassQuery.roadsAround(GeoPoint(-33.8688, 151.2093), radius: 42.4, signalRadius: 120, timeout: 20)
        XCTAssertTrue(custom.contains("[timeout:20]"))
        XCTAssertTrue(custom.contains("way(around:42,-33.868800,151.209300)"))
        XCTAssertTrue(custom.contains("node(around:120,-33.868800,151.209300)"))
    }

    func testFeaturesAlongQuery() throws {
        let line = [GeoPoint(41.31, 69.28), GeoPoint(41.315, 69.28), GeoPoint(41.32, 69.2805)]
        let q = OverpassQuery.featuresAlong(line)
        let poly = "41.310000,69.280000,41.315000,69.280000,41.320000,69.280500"
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:25];"))
        XCTAssertTrue(q.contains("node(around:35,\(poly))[highway~\"^(traffic_signals|crossing|speed_camera|stop|give_way)$\"];"))
        XCTAssertTrue(q.contains("node(around:35,\(poly))[traffic_calming];"))
        XCTAssertTrue(q.contains("node(around:35,\(poly))[railway=level_crossing];"))
        XCTAssertTrue(q.contains("nwr(around:150,\(poly))[amenity~\"^(school|kindergarten)$\"];"))
        XCTAssertTrue(q.contains("way(around:35,\(poly))[highway=construction];"))
        XCTAssertTrue(q.hasSuffix("out tags center qt;"))

        // A long zig-zag polyline is reduced to at most maxPolylinePoints vertices (an even number of values).
        XCTAssertEqual(OverpassQuery.maxPolylinePoints, 100)
        let zigzag = (0..<600).map { i in GeoPoint(41.30 + Double(i) * 0.0005, 69.28 + (i % 2 == 0 ? 0 : 0.003)) }
        let long = OverpassQuery.featuresAlong(zigzag, radius: 40, timeout: 30)
        let clause = try XCTUnwrap(long.components(separatedBy: "node(around:40,").dropFirst().first?
            .components(separatedBy: ")").first)
        let values = clause.split(separator: ",")
        XCTAssertEqual(values.count % 2, 0)
        XCTAssertLessThanOrEqual(values.count / 2, OverpassQuery.maxPolylinePoints)
        XCTAssertGreaterThanOrEqual(values.count / 2, 2)
        XCTAssertTrue(long.contains("[timeout:30]"))

        let single = OverpassQuery.featuresAlong([GeoPoint(41.31, 69.28)])
        XCTAssertTrue(single.contains("node(around:35,41.310000,69.280000)[traffic_calming];"))

        let empty = OverpassQuery.featuresAlong([])
        XCTAssertFalse(empty.contains("around"))
        XCTAssertTrue(empty.hasSuffix("out;"))
    }

    func testFormBodyStrictPercentEncoding() throws {
        let body = OverpassQuery.formBody("a b&c=d/é~._-+;\"")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "data=a%20b%26c%3Dd%2F%C3%A9~._-%2B%3B%22")

        let query = OverpassQuery.roadsAround(GeoPoint(41.3111, 69.2797))
        let encoded = String(decoding: OverpassQuery.formBody(query), as: UTF8.self)
        XCTAssertTrue(encoded.hasPrefix("data="))
        let payload = String(encoded.dropFirst(5))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")
        XCTAssertTrue(payload.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(payload.removingPercentEncoding, query)
    }

    // MARK: Max speed

    func testMaxSpeedParser() {
        XCTAssertEqual(MaxSpeedParser.parse("60"), SpeedLimit(kmh: 60, raw: "60", isImplicit: false))
        XCTAssertEqual(MaxSpeedParser.parse("60 km/h")?.kmh, 60)
        XCTAssertEqual(MaxSpeedParser.parse("50 mph")?.kmh, 80)
        XCTAssertEqual(MaxSpeedParser.parse("50mph")?.kmh, 80)
        XCTAssertEqual(MaxSpeedParser.parse("10 knots")?.kmh, 19)
        XCTAssertEqual(MaxSpeedParser.parse("RU:urban"), SpeedLimit(kmh: 60, raw: "RU:urban", isImplicit: true))
        XCTAssertEqual(MaxSpeedParser.parse("RU:rural")?.kmh, 90)
        XCTAssertEqual(MaxSpeedParser.parse("RU:living_street")?.kmh, 20)
        XCTAssertEqual(MaxSpeedParser.parse("RU:motorway")?.kmh, 110)
        XCTAssertEqual(MaxSpeedParser.parse("UZ:urban")?.kmh, 70)
        XCTAssertEqual(MaxSpeedParser.parse("UZ:rural")?.kmh, 100)
        XCTAssertEqual(MaxSpeedParser.parse("UZ:living_street")?.kmh, 30)
        XCTAssertEqual(MaxSpeedParser.parse("UZ:motorway")?.kmh, 110)
        XCTAssertEqual(MaxSpeedParser.parse("uz:urban")?.kmh, 70)
        XCTAssertEqual(MaxSpeedParser.parse("RU:zone30"), SpeedLimit(kmh: 30, raw: "RU:zone30", isImplicit: true))
        XCTAssertEqual(MaxSpeedParser.parse("walk"), SpeedLimit(kmh: 5, raw: "walk", isImplicit: true))
        XCTAssertEqual(MaxSpeedParser.parse("60;40")?.kmh, 40)
        XCTAssertEqual(MaxSpeedParser.parse(" 70 ")?.raw, "70")
        XCTAssertNil(MaxSpeedParser.parse("none"))
        XCTAssertNil(MaxSpeedParser.parse("signals"))
        XCTAssertNil(MaxSpeedParser.parse("XX:urban"))
        XCTAssertNil(MaxSpeedParser.parse("fast"))
        XCTAssertNil(MaxSpeedParser.parse("0"))
        XCTAssertNil(MaxSpeedParser.parse("60 furlongs"))
        XCTAssertNil(MaxSpeedParser.parse(""))
        XCTAssertNil(MaxSpeedParser.parse(nil))
    }

    func testDirectionalSpeedLimit() {
        let tags = ["maxspeed": "60", "maxspeed:forward": "70", "maxspeed:backward": "50"]
        XCTAssertEqual(MaxSpeedParser.limit(tags: tags, travelingForward: true)?.kmh, 70)
        XCTAssertEqual(MaxSpeedParser.limit(tags: tags, travelingForward: false)?.kmh, 50)
        XCTAssertEqual(MaxSpeedParser.limit(tags: ["maxspeed": "60", "maxspeed:forward": "70"], travelingForward: false)?.kmh, 60)
        XCTAssertEqual(MaxSpeedParser.limit(tags: ["source:maxspeed": "UZ:urban"], travelingForward: true),
                       SpeedLimit(kmh: 70, raw: "UZ:urban", isImplicit: true))
        XCTAssertEqual(MaxSpeedParser.limit(tags: ["maxspeed:type": "RU:rural"], travelingForward: true)?.kmh, 90)
        XCTAssertNil(MaxSpeedParser.limit(tags: ["source:maxspeed": "sign"], travelingForward: true))
        XCTAssertNil(MaxSpeedParser.limit(tags: ["maxspeed": "none"], travelingForward: true))
        XCTAssertNil(MaxSpeedParser.limit(tags: [:], travelingForward: true))
    }

    // MARK: Lanes

    func testParseTurnLanes() {
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("left|through;right|right"),
                       [Lane(turns: [.left]), Lane(turns: [.through, .right]), Lane(turns: [.right])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("left||right"),
                       [Lane(turns: [.left]), Lane(turns: [.none]), Lane(turns: [.right])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("slide_left|through|slide_right"),
                       [Lane(turns: [.slightLeft]), Lane(turns: [.through]), Lane(turns: [.slightRight])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("none;through|none"), [Lane(turns: [.through]), Lane(turns: [.none])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("merge_to_left|reverse;left|sharp_right;slight_right"),
                       [Lane(turns: [.mergeToLeft]), Lane(turns: [.reverse, .left]), Lane(turns: [.sharpRight, .slightRight])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("LEFT| Through ;through"), [Lane(turns: [.left]), Lane(turns: [.through])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("foo|left"), [Lane(turns: []), Lane(turns: [.left])])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes(""), [])
        XCTAssertEqual(OSMRoadParser.parseTurnLanes("   "), [])
    }

    func testOnewayDirection() {
        for value in ["yes", "true", "1", "YES"] {
            XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": value]), 1, value)
        }
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": "-1"]), -1)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": "reverse"]), -1)
        for value in ["no", "false", "0", "reversible", "alternating"] {
            XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": value]), 0, value)
        }
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: [:]), 0)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "primary"]), 0)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "motorway"]), 1)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "motorway_link"]), 1)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "motorway", "oneway": "no"]), 0)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "primary", "junction": "roundabout"]), 1)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["highway": "primary", "junction": "circular"]), 1)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": "yes", "oneway:motor_vehicle": "no"]), 0)
        XCTAssertEqual(OSMRoadParser.onewayDirection(tags: ["oneway": "yes", "oneway:bicycle": "no"]), 1)
    }

    func testLaneInfoTwoWayWithDirectionalTags() {
        let tags = ["highway": "primary", "lanes": "6", "lanes:forward": "3", "lanes:backward": "3",
                    "turn:lanes:forward": "left|through|through;right", "turn:lanes:backward": "left|through|right"]
        let forward = OSMRoadParser.laneInfo(tags: tags, travelingForward: true)
        XCTAssertEqual(forward.totalLanes, 6)
        XCTAssertEqual(forward.lanesInDirection, 3)
        XCTAssertEqual(forward.lanesOpposite, 3)
        XCTAssertEqual(forward.lanes, [Lane(turns: [.left]), Lane(turns: [.through]), Lane(turns: [.through, .right])])
        XCTAssertFalse(forward.isOneway)
        XCTAssertFalse(forward.isEstimated)

        let backward = OSMRoadParser.laneInfo(tags: tags, travelingForward: false)
        XCTAssertEqual(backward.lanes, [Lane(turns: [.left]), Lane(turns: [.through]), Lane(turns: [.right])],
                       ":backward lanes are already listed left→right from the driver's view")
    }

    func testLaneInfoTwoWaySplits() {
        func info(_ tags: [String: String], forward: Bool = true) -> LaneInfo {
            OSMRoadParser.laneInfo(tags: tags, travelingForward: forward)
        }
        // Even split.
        let four = info(["highway": "secondary", "lanes": "4"])
        XCTAssertEqual([four.totalLanes, four.lanesInDirection, four.lanesOpposite], [4, 2, 2])
        XCTAssertEqual(four.lanes, [])
        XCTAssertFalse(four.isEstimated)
        // Remainder after the known direction.
        let five = info(["highway": "primary", "lanes": "5", "lanes:forward": "3"], forward: false)
        XCTAssertEqual([five.lanesInDirection, five.lanesOpposite], [2, 3])
        // Centre turn lane is in the total but in neither direction.
        let centre = info(["highway": "primary", "lanes": "5", "lanes:both_ways": "1"])
        XCTAssertEqual([centre.totalLanes, centre.lanesInDirection, centre.lanesOpposite], [5, 2, 2])
        // Odd total without a split: per-direction counts unknown.
        let three = info(["highway": "tertiary", "lanes": "3"])
        XCTAssertEqual(three.totalLanes, 3)
        XCTAssertNil(three.lanesInDirection)
        XCTAssertNil(three.lanesOpposite)
        // One lane shared by both directions.
        let one = info(["highway": "residential", "lanes": "1"])
        XCTAssertEqual([one.totalLanes, one.lanesInDirection, one.lanesOpposite], [1, 1, 1])
        // Directional counts without a total.
        let split = info(["highway": "primary", "lanes:forward": "2", "lanes:backward": "1"], forward: false)
        XCTAssertEqual([split.totalLanes, split.lanesInDirection, split.lanesOpposite], [3, 1, 2])
        XCTAssertFalse(split.isEstimated)
        // Counts from turn:lanes when lanes is missing.
        let turns = info(["highway": "primary", "turn:lanes:forward": "left|through|through", "turn:lanes:backward": "through|right"])
        XCTAssertEqual([turns.totalLanes, turns.lanesInDirection, turns.lanesOpposite], [5, 3, 2])
        XCTAssertEqual(turns.lanes.count, 3)
        XCTAssertFalse(turns.isEstimated)
        let halfKnown = info(["highway": "primary", "turn:lanes:forward": "left|through"])
        XCTAssertEqual(halfKnown.lanesInDirection, 2)
        XCTAssertNil(halfKnown.lanesOpposite)
        XCTAssertNil(halfKnown.totalLanes)
        // turn:lanes without suffix is ignored on two-way roads.
        XCTAssertEqual(info(["highway": "secondary", "lanes": "4", "turn:lanes": "left|through"]).lanes, [])
    }

    func testLaneInfoEstimatedFromRoadClass() {
        let primary = OSMRoadParser.laneInfo(tags: ["highway": "primary"], travelingForward: true)
        XCTAssertTrue(primary.isEstimated)
        XCTAssertEqual([primary.totalLanes, primary.lanesInDirection, primary.lanesOpposite], [2, 1, 1])

        let unclassified = OSMRoadParser.laneInfo(tags: ["highway": "unclassified"], travelingForward: false)
        XCTAssertTrue(unclassified.isEstimated)
        XCTAssertEqual([unclassified.totalLanes, unclassified.lanesInDirection, unclassified.lanesOpposite], [1, 1, 1])

        let garbage = OSMRoadParser.laneInfo(tags: ["highway": "residential", "lanes": "many"], travelingForward: true)
        XCTAssertTrue(garbage.isEstimated)
        XCTAssertEqual(garbage.totalLanes, 2)

        let unknown = OSMRoadParser.laneInfo(tags: ["highway": "road"], travelingForward: true)
        XCTAssertNil(unknown.totalLanes)
        XCTAssertNil(unknown.lanesInDirection)
        XCTAssertFalse(unknown.isEstimated)
    }

    func testLaneInfoOneway() {
        let tags = ["highway": "secondary", "oneway": "yes", "lanes": "3", "turn:lanes": "left|through|through;right"]
        let legal = OSMRoadParser.laneInfo(tags: tags, travelingForward: true)
        XCTAssertTrue(legal.isOneway)
        XCTAssertEqual([legal.totalLanes, legal.lanesInDirection, legal.lanesOpposite], [3, 3, 0])
        XCTAssertEqual(legal.lanes.count, 3)
        XCTAssertFalse(legal.isEstimated)

        let against = OSMRoadParser.laneInfo(tags: tags, travelingForward: false)
        XCTAssertTrue(against.isOneway)
        XCTAssertEqual([against.lanesInDirection, against.lanesOpposite], [3, 0])
        XCTAssertEqual(against.lanes, [], "turn arrows do not apply when travelling against a one-way road")

        let reversed = ["highway": "tertiary", "oneway": "-1", "lanes": "2", "turn:lanes:backward": "left|through"]
        let reversedLegal = OSMRoadParser.laneInfo(tags: reversed, travelingForward: false)
        XCTAssertEqual([reversedLegal.lanesInDirection, reversedLegal.lanesOpposite], [2, 0])
        XCTAssertEqual(reversedLegal.lanes, [Lane(turns: [.left]), Lane(turns: [.through])])

        let motorway = OSMRoadParser.laneInfo(tags: ["highway": "motorway"], travelingForward: true)
        XCTAssertTrue(motorway.isOneway)
        XCTAssertTrue(motorway.isEstimated)
        XCTAssertEqual([motorway.lanesInDirection, motorway.lanesOpposite], [2, 0])

        let fromTurns = OSMRoadParser.laneInfo(tags: ["highway": "primary", "oneway": "yes", "turn:lanes": "left|through|right"],
                                               travelingForward: true)
        XCTAssertEqual(fromTurns.lanesInDirection, 3)
        XCTAssertFalse(fromTurns.isEstimated)

        let roundabout = OSMRoadParser.laneInfo(tags: ["highway": "primary", "junction": "roundabout", "lanes": "3"], travelingForward: true)
        XCTAssertTrue(roundabout.isOneway)
        XCTAssertEqual(roundabout.lanesInDirection, 3)

        let estimated = OSMRoadParser.laneInfo(tags: ["highway": "secondary", "oneway": "yes"], travelingForward: true)
        XCTAssertTrue(estimated.isEstimated)
        XCTAssertEqual(estimated.lanesInDirection, 1)
    }

    func testDefaultLaneCountsAndDisplayNames() {
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "primary", oneway: false), 2)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "primary", oneway: true), 1)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "residential", oneway: false), 2)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "motorway", oneway: true), 2)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "trunk", oneway: false), 2)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "service", oneway: false), 1)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "track", oneway: true), 1)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "primary_link", oneway: true), 1)
        XCTAssertEqual(OSMRoadParser.defaultLaneCount(highway: "PRIMARY", oneway: false), 2)
        XCTAssertNil(OSMRoadParser.defaultLaneCount(highway: "footway", oneway: false))

        XCTAssertEqual(OSMRoadParser.highwayDisplayName("motorway"), "Автомагистраль")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("trunk"), "Магистраль")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("primary"), "Главная дорога")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("residential"), "Жилая улица")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("living_street"), "Жилая зона")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("service"), "Проезд")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("unclassified"), "Местная дорога")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("trunk_link"), "Съезд")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("motorway_link"), "Съезд")
        XCTAssertEqual(OSMRoadParser.highwayDisplayName("something_new"), "Дорога")
        let classes = ["motorway", "trunk", "primary", "secondary", "tertiary", "residential", "living_street",
                       "service", "unclassified", "track"]
        XCTAssertEqual(Set(classes.map(OSMRoadParser.highwayDisplayName)).count, classes.count, "class names are distinct")
    }

    // MARK: Road matcher on the Tashkent fixture

    func testMatcherOnTashkentFixture() throws {
        let elements = try OverpassQuery.decode(RoadFixture.data("overpass_roads_tashkent"))
        let xy = TashkentFrame.xy

        let north = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(121, 200), heading: 2))
        XCTAssertEqual(north.wayID, 23710011)
        XCTAssertEqual(north.name, "проспект Амира Темура")
        XCTAssertEqual(north.displayName, "проспект Амира Темура")
        XCTAssertTrue(north.travelingForward)
        XCTAssertEqual(north.laneInfo.lanesInDirection, 3)
        XCTAssertEqual(north.laneInfo.totalLanes, 6)
        XCTAssertEqual(north.laneInfo.lanes.count, 3)
        XCTAssertEqual(north.speedLimit, SpeedLimit(kmh: 70, raw: "70", isImplicit: false))
        XCTAssertEqual(north.lit, true)
        XCTAssertEqual(north.surface, "asphalt")
        XCTAssertEqual(north.surfaceDisplayName, "Асфальт")
        XCTAssertEqual(north.roadClassName, "Главная дорога")
        XCTAssertLessThan(north.distanceToRoad, 3)

        let south = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(121, 200), heading: 182))
        XCTAssertEqual(south.wayID, 23710011)
        XCTAssertFalse(south.travelingForward)
        XCTAssertEqual(south.laneInfo.lanes, [Lane(turns: [.left]), Lane(turns: [.through]), Lane(turns: [.right])])

        let nearest = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(121, 200), heading: nil))
        XCTAssertEqual(nearest.wayID, 23710011)

        let oneway = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(-50, 204), heading: 91))
        XCTAssertEqual(oneway.wayID, 48210044)
        XCTAssertEqual(oneway.name, "проспект Мустакиллик")
        XCTAssertTrue(oneway.laneInfo.isOneway)
        XCTAssertEqual([oneway.laneInfo.lanesInDirection, oneway.laneInfo.lanesOpposite], [3, 0])
        XCTAssertEqual(oneway.speedLimit?.kmh, 60)

        // oneway=-1: legal travel is against the drawing direction (southwards).
        let reversed = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(-148.5, 0), heading: 180))
        XCTAssertEqual(reversed.wayID, 48210055)
        XCTAssertFalse(reversed.travelingForward)
        XCTAssertEqual(reversed.speedLimit, SpeedLimit(kmh: 70, raw: "UZ:urban", isImplicit: true))
        XCTAssertEqual(reversed.laneInfo.lanesInDirection, 2)

        let residential = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(-50, -148), heading: 270))
        XCTAssertEqual(residential.wayID, 48210033)
        XCTAssertEqual(residential.displayName, "Shahrisabz tor ko‘chasi", "no name:ru → original name")
        XCTAssertTrue(residential.travelingForward)
        XCTAssertTrue(residential.laneInfo.isEstimated)
        XCTAssertEqual(residential.laneInfo.lanesInDirection, 1)
        XCTAssertNil(residential.speedLimit)
        XCTAssertNil(residential.lit)

        let ring = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(90, 0), heading: 0))
        XCTAssertEqual(ring.wayID, 23710022)
        XCTAssertTrue(ring.laneInfo.isOneway)
        XCTAssertTrue(ring.travelingForward)
        XCTAssertEqual(ring.speedLimit?.isImplicit, true)

        let parking = try XCTUnwrap(RoadMatcher.bestMatch(elements: elements, position: xy(60, -58), heading: 90))
        XCTAssertEqual(parking.wayID, 48210066)
        XCTAssertEqual(parking.displayName, "Проезд")
        XCTAssertEqual(parking.surfaceDisplayName, "Брусчатка")

        XCTAssertNil(RoadMatcher.bestMatch(elements: elements, position: xy(600, 600), heading: 0))
        XCTAssertNil(RoadMatcher.bestMatch(elements: elements, position: xy(-50, -120), heading: 270, maxDistance: 20))
    }

    // MARK: Road matcher, synthetic cases

    private func line(_ id: Int64, _ from: (Double, Double), _ to: (Double, Double), _ tags: [String: String]) -> OSMElement {
        OSMElement(type: .way, id: id, geometry: [TashkentFrame.xy(from.0, from.1), TashkentFrame.xy(to.0, to.1)], tags: tags)
    }

    func testMatcherUsesHeadingAtIntersection() throws {
        let northSouth = line(1, (0, -200), (0, 200), ["highway": "primary"])
        let eastWest = line(2, (-200, 0), (200, 0), ["highway": "residential"])
        let elements = [northSouth, eastWest]
        let p = TashkentFrame.xy(3, 6)   // 3 m from the primary, 6 m from the residential street
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: 90)?.wayID, 2)
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: 270)?.wayID, 2)
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: 1)?.wayID, 1)
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: nil)?.wayID, 1)
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: -1)?.wayID, 1, "invalid heading → nearest")
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: p, heading: 270)?.travelingForward, false)
    }

    func testMatcherPicksCarriagewayOfTravelDirection() throws {
        let northbound = line(10, (-8, -200), (-8, 200), ["highway": "trunk", "oneway": "yes"])
        let southbound = line(11, (8, 200), (8, -200), ["highway": "trunk", "oneway": "yes"])
        let p = TashkentFrame.xy(2, 0)   // closer to the southbound carriageway
        let match = try XCTUnwrap(RoadMatcher.bestMatch(elements: [northbound, southbound], position: p, heading: 0))
        XCTAssertEqual(match.wayID, 10)
        XCTAssertTrue(match.travelingForward)
        XCTAssertEqual(RoadMatcher.bestMatch(elements: [northbound, southbound], position: p, heading: 180)?.wayID, 11)

        // Only the wrong carriageway nearby: still matched (no crash), travelling against it.
        let against = try XCTUnwrap(RoadMatcher.bestMatch(elements: [southbound], position: p, heading: 0))
        XCTAssertFalse(against.travelingForward)
        XCTAssertEqual(against.laneInfo.lanes, [])

        // Without heading a oneway=-1 road is assumed to be travelled legally.
        let reversed = line(12, (0, -100), (0, 100), ["highway": "tertiary", "oneway": "-1"])
        XCTAssertEqual(RoadMatcher.bestMatch(elements: [reversed], position: TashkentFrame.xy(1, 0), heading: nil)?.travelingForward, false)
    }

    func testMatcherFiltersAndTieBreaks() {
        let footway = line(20, (1, -100), (1, 100), ["highway": "footway"])
        let pedestrianArea = line(21, (2, -100), (2, 100), ["highway": "service", "area": "yes"])
        let road = line(22, (10, -100), (10, 100), ["highway": "residential"])
        let node = OSMElement(type: .node, id: 23, lat: TashkentFrame.origin.latitude, lon: TashkentFrame.origin.longitude,
                              tags: ["highway": "traffic_signals"])
        let noGeometry = OSMElement(type: .way, id: 24, tags: ["highway": "primary"])
        let onePoint = OSMElement(type: .way, id: 25, geometry: [TashkentFrame.origin], tags: ["highway": "primary"])
        let elements = [footway, pedestrianArea, road, node, noGeometry, onePoint]
        XCTAssertEqual(RoadMatcher.bestMatch(elements: elements, position: TashkentFrame.origin, heading: 0)?.wayID, 22)

        let service = line(30, (-5, -100), (-5, 100), ["highway": "service"])
        let primary = line(31, (5, -100), (5, 100), ["highway": "primary"])
        XCTAssertEqual(RoadMatcher.bestMatch(elements: [service, primary], position: TashkentFrame.origin, heading: nil)?.wayID, 31,
                       "equal distance → the higher road class wins")

        XCTAssertNil(RoadMatcher.bestMatch(elements: [], position: TashkentFrame.origin, heading: 0))
        XCTAssertNil(RoadMatcher.bestMatch(elements: [road], position: GeoPoint(.nan, 69), heading: 0))
        XCTAssertEqual(RoadMatcher.litValue("24/7"), true)
        XCTAssertEqual(RoadMatcher.litValue("no"), false)
        XCTAssertNil(RoadMatcher.litValue("maybe"))
    }

    func testRoadSegmentDisplayNameFallbacks() {
        var info = RoadSegmentInfo(wayID: 1, name: nil, ref: "4Р12", highway: "trunk", laneInfo: .unknown, speedLimit: nil,
                                   surface: nil, lit: nil, travelingForward: true, distanceToRoad: 2, tags: [:])
        XCTAssertEqual(info.displayName, "4Р12")
        info.ref = nil
        XCTAssertEqual(info.displayName, "Магистраль")
        info.name = ""
        XCTAssertEqual(info.displayName, "Магистраль")
        info.name = "Kichik halqa yo‘li"
        XCTAssertEqual(info.displayName, "Kichik halqa yo‘li")
        XCTAssertNil(info.surfaceDisplayName)
    }
}
