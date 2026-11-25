import XCTest
@testable import RoadVisionCore

final class IncidentTests: XCTestCase {
    private let route = [GeoPoint(41.3100, 69.2800), GeoPoint(41.3150, 69.2800), GeoPoint(41.3150, 69.2900)]
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func point(along distance: Double, offsetEast: Double = 0) -> GeoPoint {
        let p = Geo.point(atDistance: distance, along: route)!
        return offsetEast == 0 ? p : Geo.destination(from: p, bearing: offsetEast > 0 ? 90 : 270, distance: abs(offsetEast))
    }

    func testKindPresentation() {
        XCTAssertEqual(RoadIncidentKind.accident.displayName, "ДТП")
        XCTAssertEqual(RoadIncidentKind.roadWork.displayName, "Дорожные работы")
        XCTAssertEqual(RoadIncidentKind.jam.displayName, "Пробка")
        XCTAssertEqual(RoadIncidentKind.police.displayName, "Полиция / пост ДПС")
        XCTAssertEqual(RoadIncidentKind.pothole.displayName, "Яма")
        XCTAssertEqual(RoadIncidentKind.hazard.displayName, "Опасность")
        XCTAssertEqual(RoadIncidentKind.closure.displayName, "Перекрытие")
        let symbols = RoadIncidentKind.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "each kind has its own symbol")
        XCTAssertFalse(symbols.contains(""))
    }

    func testIncidentCodableRoundTrip() throws {
        let incident = RoadIncident(kind: .pothole, coordinate: GeoPoint(41.31, 69.28),
                                    date: Date(timeIntervalSince1970: 1_790_000_000), note: "Глубокая яма в правом ряду")
        let data = try JSONEncoder().encode([incident])
        let decoded = try JSONDecoder().decode([RoadIncident].self, from: data)
        XCTAssertEqual(decoded, [incident])
        XCTAssertNil(RoadIncident(kind: .jam, coordinate: GeoPoint(41, 69)).note)
        XCTAssertNotEqual(RoadIncident(kind: .jam, coordinate: GeoPoint(41, 69)).id,
                          RoadIncident(kind: .jam, coordinate: GeoPoint(41, 69)).id)
    }

    func testActiveFilter() {
        let fresh = RoadIncident(kind: .accident, coordinate: GeoPoint(41.31, 69.28), date: now.addingTimeInterval(-3600))
        let old = RoadIncident(kind: .jam, coordinate: GeoPoint(41.31, 69.28), date: now.addingTimeInterval(-3 * 3600))
        let boundary = RoadIncident(kind: .police, coordinate: GeoPoint(41.31, 69.28), date: now.addingTimeInterval(-2 * 3600))
        let future = RoadIncident(kind: .hazard, coordinate: GeoPoint(41.31, 69.28), date: now.addingTimeInterval(600))
        let active = IncidentFilter.active([old, fresh, boundary, future], now: now, lifetime: 2 * 3600)
        XCTAssertEqual(active.map(\.id), [future.id, fresh.id], "newest first; exactly lifetime old = expired")
        XCTAssertEqual(IncidentFilter.active([fresh], now: now, lifetime: 0), [])
        XCTAssertEqual(IncidentFilter.active([], now: now, lifetime: 3600), [])
    }

    func testAlongRoute() {
        let near = RoadIncident(kind: .accident, coordinate: point(along: 300, offsetEast: 10), date: now)
        let edge = RoadIncident(kind: .roadWork, coordinate: point(along: 100, offsetEast: -45), date: now)
        let far = RoadIncident(kind: .jam, coordinate: point(along: 200, offsetEast: 80), date: now)
        let onSecondLeg = RoadIncident(kind: .closure, coordinate: point(along: 900), date: now)
        let invalid = RoadIncident(kind: .hazard, coordinate: GeoPoint(.nan, .nan), date: now)
        let result = IncidentFilter.along(route: route, cumulative: nil, incidents: [onSecondLeg, far, near, edge, invalid])
        XCTAssertEqual(result.map(\.id), [edge.id, near.id, onSecondLeg.id])
        XCTAssertEqual(result[0].distanceAlongRoute, 100, accuracy: 2)
        XCTAssertEqual(result[0].offsetFromRoute, 45, accuracy: 1)
        XCTAssertEqual(result[1].distanceAlongRoute, 300, accuracy: 2)
        XCTAssertEqual(result[2].distanceAlongRoute, 900, accuracy: 2)
        XCTAssertEqual(result[1].incident, near)

        let strict = IncidentFilter.along(route: route, cumulative: Geo.cumulativeDistances(route),
                                          incidents: [near, edge], maxOffset: 20)
        XCTAssertEqual(strict.map(\.id), [near.id])
        let ignoredCumulative = IncidentFilter.along(route: route, cumulative: [0], incidents: [near])
        XCTAssertEqual(ignoredCumulative.first?.distanceAlongRoute ?? 0, 300, accuracy: 2)
        XCTAssertEqual(IncidentFilter.along(route: [], cumulative: nil, incidents: [near]), [])
    }
}

final class TrafficDelayTests: XCTestCase {
    func testAssessmentLevels() {
        func level(_ current: Double, _ free: Double = 600) -> CongestionLevel {
            TrafficAssessment(currentSeconds: current, freeFlowSeconds: free).level
        }
        XCTAssertEqual(level(600), .free)
        XCTAssertEqual(level(659), .free)
        XCTAssertEqual(level(660), .light)       // ratio 1.1
        XCTAssertEqual(level(749), .light)
        XCTAssertEqual(level(750), .moderate)    // 1.25
        XCTAssertEqual(level(899), .moderate)
        XCTAssertEqual(level(900), .heavy)       // 1.5
        XCTAssertEqual(level(1199), .heavy)
        XCTAssertEqual(level(1200), .severe)     // 2.0
        XCTAssertEqual(level(500), .free, "faster than free flow")
        XCTAssertEqual(level(900, 0), .free, "unknown free-flow time")
    }

    func testDelayAndRatio() {
        let a = TrafficAssessment(currentSeconds: 1020, freeFlowSeconds: 600)
        XCTAssertEqual(a.delaySeconds, 420)
        XCTAssertEqual(a.ratio, 1.7, accuracy: 1e-9)
        XCTAssertEqual(a.level, .heavy)
        XCTAssertTrue(a.summary.contains("≈"))
        XCTAssertTrue(a.summary.contains("оценка"))
        XCTAssertTrue(a.summary.contains("7 мин"))
        XCTAssertEqual(TrafficAssessment(currentSeconds: 500, freeFlowSeconds: 600).delaySeconds, 0)
        XCTAssertEqual(TrafficAssessment(currentSeconds: 600, freeFlowSeconds: 600).summary, "Свободно (оценка)")
        let broken = TrafficAssessment(currentSeconds: .nan, freeFlowSeconds: 600)
        XCTAssertEqual(broken.delaySeconds, 0)
        XCTAssertEqual(broken.ratio, 1)
    }

    func testCongestionLevelPresentation() {
        let names = CongestionLevel.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(CongestionLevel.free.displayName, "Свободно")
        XCTAssertEqual(CongestionLevel.allCases.map(\.severity), [0, 1, 2, 3, 4])
    }

    func testNextOffPeakDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
        }
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 14, 35), calendar: calendar), date(26, 3))
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 2, 10), calendar: calendar), date(25, 3))
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 3), calendar: calendar), date(26, 3), "strictly after")
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 3, 0, 1), calendar: calendar), date(26, 3))
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 14), calendar: calendar, hour: 5), date(26, 5))
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(25, 14), calendar: calendar, hour: 30), date(25, 23))
        // Month / year rollover.
        XCTAssertEqual(TrafficDelay.nextOffPeakDate(after: date(30, 22), calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 3))!)

        // DST change day (Europe/Berlin, 2026-03-29: 02:00 → 03:00): the result is still in the future and within a day.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let early = berlin.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 30))!
        let next = TrafficDelay.nextOffPeakDate(after: early, calendar: berlin, hour: 2)
        XCTAssertGreaterThan(next, early)
        XCTAssertLessThanOrEqual(next.timeIntervalSince(early), 26 * 3600)
    }
}
