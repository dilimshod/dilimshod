import XCTest
@testable import RoadVisCore

final class TripTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Straight track northwards at a constant speed, one point per second.
    private func straightTrip(seconds: Int, speedKmh: Double, limit: Int? = 60) -> Trip {
        var points: [TripPoint] = []
        var position = GeoPoint(41.3, 69.28)
        for i in 0...seconds {
            points.append(TripPoint(date: t0.addingTimeInterval(Double(i)), coordinate: position,
                                    speedKmh: speedKmh, speedLimitKmh: limit, horizontalAccuracy: 5))
            position = Geo.destination(from: position, bearing: 0, distance: speedKmh / 3.6)
        }
        return Trip(startedAt: t0, endedAt: t0.addingTimeInterval(Double(seconds)), points: points)
    }

    func testStatsDistanceDurationSpeed() {
        let trip = straightTrip(seconds: 600, speedKmh: 54)   // 15 m/s × 600 s = 9 km
        let stats = TripStats.compute(trip)
        XCTAssertEqual(stats.distanceMeters, 9_000, accuracy: 5)
        XCTAssertEqual(stats.duration, 600, accuracy: 1e-9)
        XCTAssertEqual(stats.averageSpeedKmh, 54, accuracy: 0.1)
        XCTAssertEqual(stats.maxSpeedKmh, 54, accuracy: 1e-9)
        XCTAssertEqual(stats.timeOverLimit, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.speedLimitCoverage, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.timeBySpeedBand[.urban] ?? 0, 600, accuracy: 1e-9)
    }

    func testTimeOverLimitUsesTolerance() {
        var trip = straightTrip(seconds: 100, speedKmh: 64, limit: 60)   // within +5
        XCTAssertEqual(TripStats.compute(trip).timeOverLimit, 0, accuracy: 1e-9)
        trip = straightTrip(seconds: 100, speedKmh: 70, limit: 60)
        XCTAssertEqual(TripStats.compute(trip).timeOverLimit, 100, accuracy: 1e-9)
        trip.thresholds = TripThresholds(speedToleranceKmh: 15)
        XCTAssertEqual(TripStats.compute(trip).timeOverLimit, 0, accuracy: 1e-9)
    }

    func testGapsAreNotIntegrated() {
        var trip = straightTrip(seconds: 10, speedKmh: 36)
        // A 60 s GPS gap at the end.
        let last = trip.points.last!
        trip.points.append(TripPoint(date: last.date.addingTimeInterval(60), coordinate: last.coordinate, speedKmh: 0,
                                     speedLimitKmh: 60, horizontalAccuracy: 5))
        trip.endedAt = trip.points.last!.date
        let stats = TripStats.compute(trip)
        XCTAssertEqual(stats.movingDuration, 10, accuracy: 1e-9)
        XCTAssertEqual(stats.duration, 70, accuracy: 1e-9)
    }

    func testEventsPer100kmAndCounts() {
        var trip = straightTrip(seconds: 600, speedKmh: 60)   // 10 km
        trip.events = [DrivingEvent(kind: .harshBraking, date: t0), DrivingEvent(kind: .harshBraking, date: t0),
                       DrivingEvent(kind: .speeding, date: t0)]
        let stats = TripStats.compute(trip)
        XCTAssertEqual(stats.eventCounts[.harshBraking], 2)
        XCTAssertEqual(stats.totalEvents, 3)
        XCTAssertEqual(stats.eventsPer100km, 30, accuracy: 0.1)
    }

    func testScoreFormula() {
        // No events → 100.
        XCTAssertEqual(TripScoring.score(events: [], distanceMeters: 5_000).score, 100)
        // Two harsh brakings (weight 2, warning) on 10 km → 0.4 points/km → 96.
        let brakes = [DrivingEvent(kind: .harshBraking), DrivingEvent(kind: .harshBraking)]
        let r = TripScoring.score(events: brakes, distanceMeters: 10_000)
        XCTAssertEqual(r.totalPenalty, 4, accuracy: 1e-9)
        XCTAssertEqual(r.penaltyPerKm, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.score, 96)
        // Short trip: distance floored at 1 km.
        XCTAssertEqual(TripScoring.score(events: brakes, distanceMeters: 100).score, 60)
        // Long speeding episode weighs more (duration factor capped at 3).
        let long = DrivingEvent(kind: .speeding, duration: 120)
        XCTAssertEqual(TripScoring.penalty(for: long), 9, accuracy: 1e-9)
        // Clamped at 0.
        let many = Array(repeating: DrivingEvent(kind: .redLightRunning), count: 20)
        XCTAssertEqual(TripScoring.score(events: many, distanceMeters: 1_000).score, 0)
        XCTAssertEqual(TripScoring.grade(96), "Отлично")
    }

    func testSpeedingDetectorNeedsFiveSeconds() {
        var detector = SpeedingDetector(thresholds: TripThresholds(speedToleranceKmh: 5, speedingMinSeconds: 5))
        var debouncer = DrivingEventDebouncer()
        var emitted = 0
        for i in 0...12 {
            if let e = detector.update(date: t0.addingTimeInterval(Double(i)), speedKmh: 72, limitKmh: 60, coordinate: nil) {
                if i < 5 { XCTFail("event before 5 s") }
                emitted += 1
                debouncer.add(e)
            }
        }
        XCTAssertEqual(emitted, 8)
        XCTAssertEqual(debouncer.events.count, 1)
        let event = debouncer.events[0]
        XCTAssertEqual(event.date, t0)
        XCTAssertEqual(event.duration, 12, accuracy: 1e-9)
        XCTAssertEqual(event.value ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(event.limit ?? 0, 60, accuracy: 1e-9)

        // Short episode (3 s) → nothing; within tolerance → nothing.
        detector.reset()
        for i in 0...3 {
            XCTAssertNil(detector.update(date: t0.addingTimeInterval(100 + Double(i)), speedKmh: 80, limitKmh: 60, coordinate: nil))
        }
        XCTAssertNil(detector.update(date: t0.addingTimeInterval(104), speedKmh: 50, limitKmh: 60, coordinate: nil))
        for i in 0...10 {
            XCTAssertNil(detector.update(date: t0.addingTimeInterval(200 + Double(i)), speedKmh: 64, limitKmh: 60, coordinate: nil))
        }
        // Unknown limit → nothing.
        XCTAssertNil(detector.update(date: t0.addingTimeInterval(300), speedKmh: 150, limitKmh: nil, coordinate: nil))
        // The tolerance floor of the minimum duration is 5 s.
        XCTAssertEqual(TripThresholds(speedingMinSeconds: 1).speedingMinSeconds, 5)
    }

    func testHarshBrakingFromGPS() {
        var detector = HarshMotionDetector()
        // 54 km/h steady, then −4 m/s² (−14.4 km/h per s).
        var events: [DrivingEvent] = []
        let speeds: [Double] = [54, 54, 54, 39.6, 25.2, 10.8, 0]
        for (i, v) in speeds.enumerated() {
            if let e = detector.addSpeed(date: t0.addingTimeInterval(Double(i)), speedKmh: v, coordinate: nil) {
                events.append(e)
            }
        }
        XCTAssertEqual(events.count, 1, "cooldown keeps one event per manoeuvre")
        XCTAssertEqual(events.first?.kind, .harshBraking)
        XCTAssertEqual(events.first?.value ?? 0, 4, accuracy: 0.05)
        XCTAssertEqual(events.first?.limit ?? 0, 3.5, accuracy: 1e-9)
    }

    func testGentleDrivingProducesNoEvents() {
        var detector = HarshMotionDetector()
        for i in 0..<30 {
            let v = 20 + Double(i) * 3.6 * 1.5   // +1.5 m/s²
            XCTAssertNil(detector.addSpeed(date: t0.addingTimeInterval(Double(i)), speedKmh: v, coordinate: nil))
        }
    }

    func testHarshAccelerationConfirmedByMotion() {
        var detector = HarshMotionDetector()
        // GPS shows +2.5 m/s² (below 3.0 but above 75 %), motion peak 3.4 m/s² → event.
        XCTAssertNil(detector.addSpeed(date: t0, speedKmh: 20, coordinate: nil))
        detector.addMotion(date: t0.addingTimeInterval(0.5), magnitude: 3.4)
        let e = detector.addSpeed(date: t0.addingTimeInterval(1), speedKmh: 29, coordinate: nil)
        XCTAssertEqual(e?.kind, .harshAcceleration)
        XCTAssertEqual(e?.value ?? 0, 3.4, accuracy: 1e-9)
        // Without motion confirmation the same GPS change is ignored.
        var plain = HarshMotionDetector()
        XCTAssertNil(plain.addSpeed(date: t0, speedKmh: 20, coordinate: nil))
        XCTAssertNil(plain.addSpeed(date: t0.addingTimeInterval(1), speedKmh: 29, coordinate: nil))
    }

    func testBrakingAtLowSpeedIgnored() {
        var detector = HarshMotionDetector()
        XCTAssertNil(detector.addSpeed(date: t0, speedKmh: 8, coordinate: nil))
        XCTAssertNil(detector.addSpeed(date: t0.addingTimeInterval(1), speedKmh: 0, coordinate: nil))
    }

    func testJSONRoundTripAndCSV() throws {
        var trip = straightTrip(seconds: 5, speedKmh: 36)
        trip.origin = TripEndpoint(name: "Дом", coordinate: GeoPoint(41.3, 69.28))
        trip.destination = TripEndpoint(name: "Работа, офис", coordinate: GeoPoint(41.31, 69.28))
        trip.events = [DrivingEvent(kind: .speeding, date: t0, coordinate: GeoPoint(41.3, 69.28), speedKmh: 72,
                                    value: 12, limit: 60, duration: 7, note: "ул. \"Тест\", 1")]
        let data = try JSONEncoder().encode(trip)
        let decoded = try JSONDecoder().decode(Trip.self, from: data)
        XCTAssertEqual(decoded, trip)

        let events = TripExport.eventsCSV(trip).split(separator: "\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[1].hasPrefix("2027-01-15T08:00:00Z,speeding,Превышение скорости,1,41.300000,69.280000,72.0,12.00,60.00,7.0,0,"))
        XCTAssertTrue(events[1].hasSuffix("\"ул. \"\"Тест\"\", 1\""))
        let points = TripExport.pointsCSV(trip).split(separator: "\n")
        XCTAssertEqual(points.count, 7)
        XCTAssertEqual(points[1], "2027-01-15T08:00:00Z,41.300000,69.280000,36.0,60,,,5.0")
        XCTAssertEqual(TripExport.baseFileName(trip, timeZone: TimeZone(identifier: "UTC")!), "trip_2027-01-15_08-00")
    }

    func testSpeedBands() {
        XCTAssertEqual(TripSpeedBand.band(for: 0), .standing)
        XCTAssertEqual(TripSpeedBand.band(for: 29.9), .slow)
        XCTAssertEqual(TripSpeedBand.band(for: 60), .fast)
        XCTAssertEqual(TripSpeedBand.band(for: 130), .highway)
    }
}
