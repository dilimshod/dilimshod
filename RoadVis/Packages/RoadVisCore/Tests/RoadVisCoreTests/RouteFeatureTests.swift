import XCTest
@testable import RoadVisCore

final class RouteFeatureTests: XCTestCase {
    /// Route used to build `overpass_features.json` (north 556 m, north 557 m, then east 793 m).
    private let route = [GeoPoint(41.3100, 69.2800), GeoPoint(41.3150, 69.2800),
                         GeoPoint(41.3200, 69.2805), GeoPoint(41.3200, 69.2900)]

    private func fixtureElements() throws -> [OSMElement] {
        try OverpassQuery.decode(RoadFixture.data("overpass_features"))
    }

    // MARK: Kinds

    func testKindFromTags() {
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "traffic_signals"]), .trafficSignals)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "crossing", "crossing": "zebra"]), .pedestrianCrossing)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "crossing", "crossing": "traffic_signals"]), .pedestrianCrossing)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "crossing", "traffic_calming": "table"]), .pedestrianCrossing,
                       "a raised crossing is announced as a crossing")
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["highway": "crossing", "crossing": "no"]))
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["railway": "crossing"]), "railway=crossing is a footpath over rails")
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "speed_camera"]), .speedCamera)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["traffic_calming": "bump"]), .trafficCalming)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["traffic_calming": "yes"]), .trafficCalming)
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["traffic_calming": "no"]))
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["railway": "level_crossing"]), .railwayCrossing)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["amenity": "school"]), .school)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["amenity": "kindergarten"]), .kindergarten)
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["amenity": "childcare"]))
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "construction"]), .construction)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "stop"]), .stopSign)
        XCTAssertEqual(RouteFeatureExtractor.kind(for: ["highway": "give_way"]), .giveWay)
        XCTAssertNil(RouteFeatureExtractor.kind(for: ["highway": "primary"]))
        XCTAssertNil(RouteFeatureExtractor.kind(for: [:]))
    }

    func testKindPresentation() {
        let names = RouteFeatureKind.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(RouteFeatureKind.trafficSignals.displayName, "Светофор")
        XCTAssertEqual(RouteFeatureKind.pedestrianCrossing.displayName, "Пешеходный переход")
        XCTAssertEqual(RouteFeatureKind.speedCamera.symbolName, "camera.fill")
        XCTAssertEqual(RouteFeatureKind.speedCamera.alertDistance, 500)
        for kind in RouteFeatureKind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty)
            XCTAssertGreaterThan(kind.alertDistance, 100, kind.rawValue)
            XCTAssertGreaterThan(kind.mergeRadius, 0)
        }
        XCTAssertEqual(RouteFeatureKind.trafficSignals.mergeRadius, 60)
        XCTAssertEqual(RouteFeatureKind.pedestrianCrossing.mergeRadius, 25)
        XCTAssertEqual(RouteFeatureKind.school.maxOffset(default: 40), 150)
        XCTAssertEqual(RouteFeatureKind.speedCamera.maxOffset(default: 40), 40)
    }

    // MARK: Extraction from the fixture

    func testExtractFromFixture() throws {
        let features = RouteFeatureExtractor.extract(elements: try fixtureElements(), route: route)
        XCTAssertEqual(features.map(\.kind), [
            .trafficSignals, .pedestrianCrossing, .trafficCalming, .pedestrianCrossing, .pedestrianCrossing,
            .speedCamera, .school, .trafficSignals, .construction, .giveWay, .stopSign, .railwayCrossing,
            .trafficCalming, .kindergarten,
        ])
        let expectedAlong: [Double] = [140, 145, 300, 420, 452, 500, 520, 700, 900, 1000, 1100, 1400, 1600, 1800]
        for (feature, along) in zip(features, expectedAlong) {
            XCTAssertEqual(feature.distanceAlongRoute, along, accuracy: 3, "\(feature.kind) \(feature.id)")
        }
        XCTAssertEqual(features.map(\.distanceAlongRoute), features.map(\.distanceAlongRoute).sorted())

        // Four signal heads of one intersection → one feature with the smallest OSM id; earliest position.
        let signals = features[0]
        XCTAssertEqual(signals.id, "node/2001")
        XCTAssertEqual(signals.offsetFromRoute, 6, accuracy: 1.5)
        XCTAssertNil(signals.name)

        // Two crossing nodes 20 m apart merge; two 32 m apart stay separate.
        XCTAssertEqual(features[1].id, "node/2010")
        XCTAssertEqual(features[3].id, "node/2012")
        XCTAssertEqual(features[4].id, "node/2013")
        XCTAssertEqual(features[3].tags["crossing_ref"], "zebra")

        // School: campus outline (centre 120 m off) + school node with the same name → one feature.
        let school = features[6]
        XCTAssertEqual(school.id, "node/2040")
        XCTAssertEqual(school.name, "Школа №45")
        XCTAssertEqual(school.offsetFromRoute, 90, accuracy: 2)

        XCTAssertEqual(features[8].id, "way/3002")
        XCTAssertEqual(features[8].name, "Navoiy ko‘chasi")
        XCTAssertEqual(features[13].id, "way/3003")
        XCTAssertEqual(features[13].name, "Детский сад №12")
        XCTAssertEqual(features[13].offsetFromRoute, 60, accuracy: 2)

        // Dropped: kindergarten 200 m off, signal 300 m off, crossing=no.
        let ids = Set(features.map(\.id))
        XCTAssertFalse(ids.contains("node/2041"))
        XCTAssertFalse(ids.contains("node/2006"))
        XCTAssertFalse(ids.contains("node/2014"))
    }

    func testExtractCumulativeAndOffsets() throws {
        let elements = try fixtureElements()
        let plain = RouteFeatureExtractor.extract(elements: elements, route: route)
        let withCumulative = RouteFeatureExtractor.extract(elements: elements, route: route,
                                                           cumulative: Geo.cumulativeDistances(route))
        XCTAssertEqual(plain, withCumulative)
        let wrongCumulative = RouteFeatureExtractor.extract(elements: elements, route: route, cumulative: [0, 1])
        XCTAssertEqual(plain, wrongCumulative, "a cumulative array of the wrong size is ignored")

        let narrow = RouteFeatureExtractor.extract(elements: elements, route: route, maxOffset: 10)
        let kinds = Set(narrow.map(\.kind))
        XCTAssertFalse(kinds.contains(.speedCamera), "camera 12 m off is dropped")
        XCTAssertFalse(kinds.contains(.construction), "construction 25 m off is dropped")
        XCTAssertTrue(kinds.contains(.school), "schools keep their 150 m corridor")
        XCTAssertTrue(kinds.contains(.kindergarten))
        XCTAssertTrue(kinds.contains(.trafficSignals))

        XCTAssertEqual(RouteFeatureExtractor.extract(elements: elements, route: []), [])
        XCTAssertEqual(RouteFeatureExtractor.extract(elements: [], route: route), [])
    }

    func testMergeUsesClusterAnchorAndKindsAreIndependent() {
        let line = [GeoPoint(41.0, 69.0), GeoPoint(41.01, 69.0)]
        func node(_ id: Int64, along: Double, tags: [String: String]) -> OSMElement {
            let p = Geo.destination(from: line[0], bearing: 0, distance: along)
            return OSMElement(type: .node, id: id, lat: p.latitude, lon: p.longitude, tags: tags)
        }
        let signal = ["highway": "traffic_signals"]
        let elements = [
            node(1, along: 100, tags: signal), node(2, along: 150, tags: signal), node(3, along: 200, tags: signal),
            node(4, along: 105, tags: ["highway": "crossing"]),
            node(4, along: 105, tags: ["highway": "crossing"]),   // duplicate element (overlapping query chunks)
            node(5, along: 400, tags: ["highway": "stop"]), node(6, along: 425, tags: ["highway": "stop"]),
            node(7, along: 460, tags: ["highway": "stop"]),
        ]
        let features = RouteFeatureExtractor.extract(elements: elements, route: line)
        let signals = features.filter { $0.kind == .trafficSignals }
        XCTAssertEqual(signals.map(\.id), ["node/1", "node/3"], "200 m is 100 m from the anchor at 100 m → new cluster")
        XCTAssertEqual(features.filter { $0.kind == .pedestrianCrossing }.count, 1)
        XCTAssertEqual(features.filter { $0.kind == .stopSign }.map(\.id), ["node/5", "node/7"])
        XCTAssertEqual(features.first?.kind, .trafficSignals)
        XCTAssertEqual(features[1].kind, .pedestrianCrossing)
    }

    func testConstructionWayUsesGeometryClosestToRoute() {
        let line = [GeoPoint(41.0, 69.0), GeoPoint(41.01, 69.0)]
        // A long construction way crossing the route: its midpoint is ~300 m away, but one vertex is on the route.
        let far = Geo.destination(from: line[0], bearing: 90, distance: 600)
        let onRoute = Geo.destination(from: line[0], bearing: 0, distance: 500)
        let way = OSMElement(type: .way, id: 9, geometry: [onRoute, far], tags: ["highway": "construction"])
        let features = RouteFeatureExtractor.extract(elements: [way], route: line)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features.first?.distanceAlongRoute ?? 0, 500, accuracy: 2)
        XCTAssertEqual(features.first?.offsetFromRoute ?? 99, 0, accuracy: 1)
    }

    // MARK: Signals

    func testSignalsFromFixtures() throws {
        let features = RouteFeatureExtractor.signals(from: try fixtureElements())
        XCTAssertEqual(features.map(\.id), ["node/2001", "node/2005", "node/2006"])

        let roadElements = try OverpassQuery.decode(RoadFixture.data("overpass_roads_tashkent"))
        let around = RouteFeatureExtractor.signals(from: roadElements)
        XCTAssertEqual(around.map(\.id), ["node/1150000101", "node/1150000105", "node/1150000107"])
        // Every member node lies within the cluster radius of its centroid.
        let first = around[0]
        for member in roadElements where (1150000101...1150000104).contains(member.id) {
            XCTAssertLessThanOrEqual(Geo.distance(first.coordinate, member.coordinate!), RouteFeatureExtractor.signalClusterRadius)
        }
        // Shuffled input → identical output (stable ids for learned statistics).
        XCTAssertEqual(RouteFeatureExtractor.signals(from: roadElements.reversed()), around)
    }

    func testSignalsIgnoreOtherElements() {
        let a = OSMElement(type: .node, id: 10, lat: 41.0, lon: 69.0, tags: ["highway": "traffic_signals"])
        let crossing = OSMElement(type: .node, id: 11, lat: 41.0, lon: 69.0001, tags: ["highway": "crossing"])
        let noCoordinate = OSMElement(type: .node, id: 12, tags: ["highway": "traffic_signals"])
        let signals = RouteFeatureExtractor.signals(from: [a, crossing, noCoordinate, a])
        XCTAssertEqual(signals, [SignalLocation(id: "node/10", coordinate: GeoPoint(41.0, 69.0))])
        XCTAssertEqual(RouteFeatureExtractor.signals(from: []), [])
    }

    func testMatchingSignal() throws {
        let elements = try fixtureElements()
        let signals = RouteFeatureExtractor.signals(from: elements)
        let features = RouteFeatureExtractor.extract(elements: elements, route: route)
        let intersection = try XCTUnwrap(features.first { $0.kind == .trafficSignals })
        XCTAssertEqual(RouteFeatureExtractor.matchingSignal(for: intersection, in: signals)?.id, "node/2001")

        let single = try XCTUnwrap(signals.first { $0.id == "node/2005" })
        let nearby = RouteFeature(id: "node/999", kind: .trafficSignals,
                                  coordinate: Geo.destination(from: single.coordinate, bearing: 45, distance: 20),
                                  distanceAlongRoute: 700, offsetFromRoute: 3, name: nil, tags: [:])
        XCTAssertEqual(RouteFeatureExtractor.matchingSignal(for: nearby, in: signals)?.id, "node/2005")
        let far = RouteFeature(id: "node/998", kind: .trafficSignals,
                               coordinate: Geo.destination(from: single.coordinate, bearing: 45, distance: 120),
                               distanceAlongRoute: 800, offsetFromRoute: 3, name: nil, tags: [:])
        XCTAssertNil(RouteFeatureExtractor.matchingSignal(for: far, in: signals))
    }
}
