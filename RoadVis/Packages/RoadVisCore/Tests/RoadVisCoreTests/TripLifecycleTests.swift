import XCTest
@testable import RoadVisCore

final class TripLifecycleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ offset: TimeInterval) -> TripPoint {
        TripPoint(date: t0.addingTimeInterval(offset), coordinate: GeoPoint(41.3, 69.28),
                  speedKmh: 30, speedLimitKmh: 60, horizontalAccuracy: 5)
    }

    // MARK: - Placeholder trips

    func testEmptyUnfinishedTripIsPlaceholder() {
        XCTAssertTrue(Trip(startedAt: t0).isEmptyPlaceholder)
        XCTAssertTrue(Trip(startedAt: t0, points: [point(0)]).isEmptyPlaceholder)
    }

    func testInterruptedTripWithTrackIsKept() {
        let trip = Trip(startedAt: t0, points: [point(0), point(1)])
        XCTAssertFalse(trip.isEmptyPlaceholder)
        XCTAssertFalse(trip.isStalePlaceholder(now: t0.addingTimeInterval(86_400)))
    }

    func testFinishedTripIsNeverPlaceholder() {
        let trip = Trip(startedAt: t0, endedAt: t0.addingTimeInterval(5))
        XCTAssertFalse(trip.isEmptyPlaceholder)
    }

    func testPlaceholderOfFreshRecordingIsNotStale() {
        let trip = Trip(startedAt: t0)
        XCTAssertFalse(trip.isStalePlaceholder(now: t0.addingTimeInterval(30)))
        XCTAssertFalse(trip.isStalePlaceholder(now: t0.addingTimeInterval(300)))
        XCTAssertTrue(trip.isStalePlaceholder(now: t0.addingTimeInterval(301)))
    }

    // MARK: - Standstill timer

    func testStandingStopsAfterStopSeconds() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: 0))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(179), speedKmh: 2))
        XCTAssertTrue(timer.update(now: t0.addingTimeInterval(180), speedKmh: 0))
    }

    func testMovingResetsStandingTime() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: 0))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(100), speedKmh: 20))
        XCTAssertNil(timer.stationarySince)
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(200), speedKmh: 0))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(379), speedKmh: 0))
        XCTAssertTrue(timer.update(now: t0.addingTimeInterval(380), speedKmh: 0))
    }

    /// Tunnel: 4 minutes without a usable GPS speed must not end the trip.
    func testGPSOutageIsNotStanding() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: 60))
        for second in stride(from: 1.0, through: 240.0, by: 1.0) {
            XCTAssertFalse(timer.update(now: t0.addingTimeInterval(second), speedKmh: nil))
        }
        XCTAssertNil(timer.stationarySince)
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(241), speedKmh: 55))
        XCTAssertNil(timer.noSpeedSince)
    }

    /// Standing time collected before an outage does not carry over it.
    func testOutageInterruptsStandingTime() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: 0))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(170), speedKmh: nil))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(190), speedKmh: 0))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(369), speedKmh: 0))
        XCTAssertTrue(timer.update(now: t0.addingTimeInterval(370), speedKmh: 0))
    }

    func testLongOutageEventuallyStops() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: nil))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(899), speedKmh: nil))
        XCTAssertTrue(timer.update(now: t0.addingTimeInterval(900), speedKmh: nil))
    }

    func testInvalidSpeedCountsAsNoSpeed() {
        var timer = TripStandstillTimer()
        XCTAssertFalse(timer.update(now: t0, speedKmh: -1))
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(200), speedKmh: .nan))
        XCTAssertNil(timer.stationarySince)
        XCTAssertNotNil(timer.noSpeedSince)
    }

    func testResetClearsBothTimers() {
        var timer = TripStandstillTimer()
        _ = timer.update(now: t0, speedKmh: 0)
        timer.reset()
        XCTAssertNil(timer.stationarySince)
        _ = timer.update(now: t0, speedKmh: nil)
        timer.reset()
        XCTAssertNil(timer.noSpeedSince)
        XCTAssertFalse(timer.update(now: t0.addingTimeInterval(1_000), speedKmh: 0))
    }
}
