import XCTest
@testable import RoadVisCore

final class SignalTimingTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return c
    }()

    /// Local Tashkent time. 2026-11-23 is a Monday, 2026-11-28 a Saturday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Model

    func testFixedTimeModel() {
        let e = SignalWaitModel.estimate(SignalTimingAssumptions())
        XCTAssertEqual(e.stopProbability, 0.55, accuracy: 1e-9)
        XCTAssertEqual(e.meanWaitIfStopped, 24.75, accuracy: 1e-9)
        XCTAssertEqual(e.expectedWaitSeconds, 13.6125, accuracy: 1e-9)
        XCTAssertEqual(e.observationCount, 0)
        XCTAssertEqual(e.source, .model)
        XCTAssertTrue(e.sourceDescription.contains("оценка"))

        let half = SignalWaitModel.estimate(SignalTimingAssumptions(cycleSeconds: 60, greenRatio: 0.5))
        XCTAssertEqual(half.stopProbability, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.meanWaitIfStopped, 15, accuracy: 1e-9)
        XCTAssertEqual(half.expectedWaitSeconds, 7.5, accuracy: 1e-9)
        // E[wait] = P(stop) · E[wait | stop]
        XCTAssertEqual(half.expectedWaitSeconds, half.stopProbability * half.meanWaitIfStopped, accuracy: 1e-9)
    }

    func testModelSanitizesInput() {
        let allGreen = SignalWaitModel.estimate(SignalTimingAssumptions(cycleSeconds: 90, greenRatio: 1.5))
        XCTAssertEqual(allGreen.expectedWaitSeconds, 0)
        XCTAssertEqual(allGreen.stopProbability, 0)
        let zeroCycle = SignalWaitModel.estimate(SignalTimingAssumptions(cycleSeconds: 0, greenRatio: 0))
        XCTAssertEqual(zeroCycle.stopProbability, 1, accuracy: 1e-9)
        XCTAssertTrue(zeroCycle.expectedWaitSeconds.isFinite)
        let nan = SignalWaitModel.estimate(SignalTimingAssumptions(cycleSeconds: .nan, greenRatio: .nan))
        XCTAssertEqual(nan.expectedWaitSeconds, 13.6125, accuracy: 1e-9, "non-finite input falls back to the defaults")
    }

    // MARK: Statistics

    func testEstimateWithoutObservationsIsModel() {
        let stats = SignalStatistics()
        let a = SignalTimingAssumptions()
        XCTAssertEqual(stats.estimate(for: "node/1", at: date(23, 8), assumptions: a, calendar: calendar),
                       SignalWaitModel.estimate(a))
        XCTAssertEqual(stats.totalObservations, 0)
    }

    func testBlendingWithFewObservations() {
        let stats = SignalStatistics()
        stats.record(SignalObservation(signalID: "node/1", date: date(23, 8), stopped: true, waitSeconds: 40))
        let e = stats.estimate(for: "node/1", at: date(24, 8, 30), assumptions: SignalTimingAssumptions(), calendar: calendar)
        // n = 1 → w = 0.2
        XCTAssertEqual(e.source, .blended)
        XCTAssertEqual(e.observationCount, 1)
        XCTAssertEqual(e.expectedWaitSeconds, 0.2 * 40 + 0.8 * 13.6125, accuracy: 1e-9)
        XCTAssertEqual(e.stopProbability, 0.2 * 1 + 0.8 * 0.55, accuracy: 1e-9)
        XCTAssertEqual(e.meanWaitIfStopped, 0.2 * 40 + 0.8 * 24.75, accuracy: 1e-9)
        XCTAssertTrue(e.sourceDescription.contains("1 набл."))
    }

    func testLearnedWithFiveObservations() {
        let stats = SignalStatistics()
        let waits: [(Bool, Double)] = [(true, 30), (false, 0), (true, 40), (false, 0), (true, 50)]
        for (i, w) in waits.enumerated() {
            stats.record(SignalObservation(signalID: "node/7", date: date(23, 12, i), stopped: w.0, waitSeconds: w.1))
        }
        let e = stats.estimate(for: "node/7", at: date(25, 13), assumptions: SignalTimingAssumptions(), calendar: calendar)
        XCTAssertEqual(e.source, .learned)
        XCTAssertEqual(e.observationCount, 5)
        XCTAssertEqual(e.stopProbability, 0.6, accuracy: 1e-9)
        XCTAssertEqual(e.meanWaitIfStopped, 40, accuracy: 1e-9)
        XCTAssertEqual(e.expectedWaitSeconds, 24, accuracy: 1e-9)
        // Other signals are unaffected.
        XCTAssertEqual(stats.estimate(for: "node/8", at: date(25, 13), assumptions: SignalTimingAssumptions(), calendar: calendar).source, .model)
    }

    func testPeakBucketIsPreferred() {
        let stats = SignalStatistics()
        for i in 0..<5 {
            stats.record(SignalObservation(signalID: "s", date: date(23 + i, 8), stopped: true, waitSeconds: 60))      // Mon–Fri peak
            stats.record(SignalObservation(signalID: "s", date: date(23 + i, 13), stopped: false, waitSeconds: 0))     // off-peak
        }
        let a = SignalTimingAssumptions()
        let peak = stats.estimate(for: "s", at: date(24, 8, 30), assumptions: a, calendar: calendar)
        XCTAssertEqual(peak.observationCount, 5)
        XCTAssertEqual(peak.stopProbability, 1, accuracy: 1e-9)
        XCTAssertEqual(peak.expectedWaitSeconds, 60, accuracy: 1e-9)

        let saturdayMorning = stats.estimate(for: "s", at: date(28, 8, 30), assumptions: a, calendar: calendar)
        XCTAssertEqual(saturdayMorning.observationCount, 5)
        XCTAssertEqual(saturdayMorning.stopProbability, 0, accuracy: 1e-9)
        XCTAssertEqual(saturdayMorning.expectedWaitSeconds, 0, accuracy: 1e-9)
        XCTAssertEqual(saturdayMorning.meanWaitIfStopped, 24.75, accuracy: 1e-9, "no stops observed → model wait if stopped")
        XCTAssertEqual(saturdayMorning.source, .learned)
    }

    func testFallbackToAllObservationsWhenBucketEmpty() {
        let stats = SignalStatistics()
        for i in 0..<3 {
            stats.record(SignalObservation(signalID: "s", date: date(23 + i, 18), stopped: true, waitSeconds: 45))
        }
        let offPeak = stats.estimate(for: "s", at: date(25, 23), assumptions: SignalTimingAssumptions(), calendar: calendar)
        XCTAssertEqual(offPeak.observationCount, 3)
        XCTAssertEqual(offPeak.source, .blended)
        XCTAssertEqual(offPeak.stopProbability, 0.6 * 1 + 0.4 * 0.55, accuracy: 1e-9)
    }

    func testPeakHours() {
        XCTAssertTrue(SignalStatistics.isPeak(date(23, 7), calendar: calendar))
        XCTAssertFalse(SignalStatistics.isPeak(date(23, 6, 59), calendar: calendar))
        XCTAssertTrue(SignalStatistics.isPeak(date(23, 9, 59), calendar: calendar))
        XCTAssertFalse(SignalStatistics.isPeak(date(23, 10), calendar: calendar))
        XCTAssertFalse(SignalStatistics.isPeak(date(25, 12), calendar: calendar))
        XCTAssertTrue(SignalStatistics.isPeak(date(27, 17), calendar: calendar))
        XCTAssertTrue(SignalStatistics.isPeak(date(27, 19, 30), calendar: calendar))
        XCTAssertFalse(SignalStatistics.isPeak(date(27, 20), calendar: calendar))
        XCTAssertFalse(SignalStatistics.isPeak(date(28, 8), calendar: calendar), "Saturday")
        XCTAssertFalse(SignalStatistics.isPeak(date(29, 18), calendar: calendar), "Sunday")
        // The same instant is off-peak in another time zone (02:00 UTC = 07:00 Tashkent).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertFalse(SignalStatistics.isPeak(date(23, 7), calendar: utc))
    }

    func testKeepsNewestFiftyInDateOrder() {
        let stats = SignalStatistics()
        let start = date(23, 0)
        for i in 0..<60 {
            stats.record(SignalObservation(signalID: "s", date: start.addingTimeInterval(Double(i) * 600),
                                           stopped: i % 2 == 0, waitSeconds: Double(i)))
        }
        let list = stats.observations(for: "s")
        XCTAssertEqual(list.count, SignalStatistics.maxObservationsPerSignal)
        XCTAssertEqual(list.first?.waitSeconds, 10)
        XCTAssertEqual(list.last?.waitSeconds, 59)

        // An older observation arriving late is inserted in date order (and is the oldest → dropped first).
        stats.record(SignalObservation(signalID: "s", date: start.addingTimeInterval(15 * 600 + 1), stopped: true, waitSeconds: 99))
        let after = stats.observations(for: "s")
        XCTAssertEqual(after.count, 50)
        XCTAssertEqual(after.map(\.date), after.map(\.date).sorted())
        XCTAssertTrue(after.contains { $0.waitSeconds == 99 })
        XCTAssertFalse(after.contains { $0.waitSeconds == 10 })

        // Invalid waits are ignored.
        stats.record(SignalObservation(signalID: "t", date: start, stopped: true, waitSeconds: -5))
        stats.record(SignalObservation(signalID: "t", date: start, stopped: true, waitSeconds: .nan))
        XCTAssertEqual(stats.observations(for: "t"), [])
        XCTAssertEqual(stats.signalIDs, ["s"])
        XCTAssertEqual(stats.totalObservations, 50)
        stats.removeAll()
        XCTAssertEqual(stats.totalObservations, 0)
    }

    func testCodableRoundTrip() throws {
        let stats = SignalStatistics()
        stats.record(SignalObservation(signalID: "node/1", date: date(23, 8), stopped: true, waitSeconds: 35))
        stats.record(SignalObservation(signalID: "node/1", date: date(24, 8), stopped: false, waitSeconds: 0))
        stats.record(SignalObservation(signalID: "node/2", date: date(24, 9), stopped: true, waitSeconds: 20))
        let data = try JSONEncoder().encode(stats)
        let restored = try JSONDecoder().decode(SignalStatistics.self, from: data)
        XCTAssertEqual(restored.totalObservations, 3)
        XCTAssertEqual(restored.observations(for: "node/1"), stats.observations(for: "node/1"))
        let a = SignalTimingAssumptions()
        XCTAssertEqual(restored.estimate(for: "node/1", at: date(25, 8), assumptions: a, calendar: calendar),
                       stats.estimate(for: "node/1", at: date(25, 8), assumptions: a, calendar: calendar))
        let empty = try JSONDecoder().decode(SignalStatistics.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.totalObservations, 0)
    }

    // MARK: Stop detector

    private let signal = SignalLocation(id: "node/42", coordinate: GeoPoint(41.3, 69.28))
    private let base = Date(timeIntervalSince1970: 1_795_000_000)

    /// Point `y` metres north (negative: south) of the signal.
    private func at(_ y: Double) -> GeoPoint {
        Geo.destination(from: signal.coordinate, bearing: y >= 0 ? 0 : 180, distance: abs(y))
    }

    /// Feeds (seconds, metres north of the signal, km/h) samples and collects observations.
    private func run(_ detector: StopDetector, _ samples: [(t: Double, y: Double, v: Double)],
                     signals: [SignalLocation]? = nil) -> [(index: Int, observation: SignalObservation)] {
        var result: [(index: Int, observation: SignalObservation)] = []
        for (i, s) in samples.enumerated() {
            if let o = detector.update(position: at(s.y), speedKmh: s.v, timestamp: base.addingTimeInterval(s.t),
                                       nearbySignals: signals ?? [signal]) {
                result.append((index: i, observation: o))
            }
        }
        return result
    }

    private func approach(to y: Double, from start: Double = -200, speed: Double = 36) -> [(t: Double, y: Double, v: Double)] {
        let step = speed / 3.6
        var samples: [(t: Double, y: Double, v: Double)] = []
        var t = 0.0
        var pos = start
        while pos < y {
            samples.append((t, pos, speed))
            t += 1
            pos += step
        }
        return samples
    }

    private func depart(from y: Double, at t0: Double, until end: Double = 200, speed: Double = 36) -> [(t: Double, y: Double, v: Double)] {
        let step = speed / 3.6
        var samples: [(t: Double, y: Double, v: Double)] = []
        var t = t0
        var pos = y
        while pos <= end {
            samples.append((t, pos, speed))
            t += 1
            pos += step
        }
        return samples
    }

    func testStopAtRedLight() {
        var samples = approach(to: -10)                         // t = 0…18, y = -200…-20
        for t in 19...48 { samples.append((Double(t), -10, 0)) } // standing 30 s
        samples += depart(from: 0, at: 49)
        let detector = StopDetector()
        let observations = run(detector, samples)
        XCTAssertEqual(observations.count, 1)
        let o = observations[0].observation
        XCTAssertEqual(o.signalID, "node/42")
        XCTAssertTrue(o.stopped)
        XCTAssertEqual(o.waitSeconds, 30, accuracy: 1e-6)
        XCTAssertEqual(o.date, base.addingTimeInterval(16), "entered the 45 m area at y = -40")
        let leftAt = samples[observations[0].index].y
        XCTAssertGreaterThanOrEqual(leftAt, 60)
        XCTAssertLessThanOrEqual(leftAt, 71)
        XCTAssertNil(detector.currentSignalID)
    }

    func testPassingOnGreen() {
        let observations = run(StopDetector(), approach(to: 200))
        XCTAssertEqual(observations.count, 1)
        XCTAssertFalse(observations[0].observation.stopped)
        XCTAssertEqual(observations[0].observation.waitSeconds, 0)
    }

    func testShortHaltIsNotAStop() {
        var samples = approach(to: -10)
        samples.append((19, -10, 0))
        samples += depart(from: -10, at: 20)
        let observations = run(StopDetector(), samples)
        XCTAssertEqual(observations.count, 1)
        XCTAssertFalse(observations[0].observation.stopped, "1 s < minStopSeconds")
    }

    func testCreepingInQueueCountsAsWaiting() {
        var samples = approach(to: -20)                                   // t = 0…17
        var y = -20.0
        for t in 18...27 { samples.append((Double(t), y, 0)) }           // standing 10 s
        for t in 28...37 { y += 5 / 3.6; samples.append((Double(t), y, 5)) }   // creeping at 5 km/h (still "halted")
        for t in 38...42 { samples.append((Double(t), y, 0)) }           // standing 5 s
        samples += depart(from: y + 10, at: 43)
        let detector = StopDetector()
        let observations = run(detector, samples)
        XCTAssertEqual(observations.count, 1)
        XCTAssertTrue(observations[0].observation.stopped)
        XCTAssertEqual(observations[0].observation.waitSeconds, 25, accuracy: 1e-6)
    }

    func testWaitWhileWaitingIsExposed() {
        let detector = StopDetector()
        var samples = approach(to: -10)
        for t in 19...29 { samples.append((Double(t), -10, 0)) }
        _ = run(detector, samples)
        XCTAssertEqual(detector.currentSignalID, "node/42")
        XCTAssertEqual(detector.currentWaitSeconds, 10, accuracy: 1e-6)
    }

    func testGPSJumpDiscardsPass() {
        var samples = approach(to: -25)                 // inside the area
        samples.append((20, 500, 36))                   // jump of > 500 m
        samples.append((21, -20, 0))                    // and back
        for t in 22...40 { samples.append((Double(t), -20, 0)) }
        samples += depart(from: -10, at: 41)
        XCTAssertEqual(run(StopDetector(), samples).count, 0, "a pass with a GPS jump is ignored entirely")
    }

    func testTwoSignalsInARow() {
        let second = SignalLocation(id: "node/43", coordinate: at(100))
        let observations = run(StopDetector(), approach(to: 300), signals: [signal, second])
        XCTAssertEqual(observations.map { $0.observation.signalID }, ["node/42", "node/43"])
        XCTAssertTrue(observations.allSatisfy { !$0.observation.stopped })
    }

    func testNoSignalsAndReset() {
        let detector = StopDetector()
        XCTAssertEqual(run(detector, approach(to: 200), signals: []).count, 0)

        let resetting = StopDetector()
        let samples = approach(to: 0)
        _ = run(resetting, samples)
        XCTAssertEqual(resetting.currentSignalID, "node/42")
        resetting.reset()
        XCTAssertNil(resetting.currentSignalID)
        // After reset the next fixes start a new pass (no stale observation is emitted for the old one).
        let rest = depart(from: 10, at: 30)
        let observations = run(resetting, rest)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].observation.date, base.addingTimeInterval(30))
    }

    func testInvalidSpeedIsDerivedFromMovement() {
        var samples = approach(to: -10).map { (t: $0.t, y: $0.y, v: -1.0) }   // ends at t = 18, y = -20
        samples.append((19, -10, -1))                                          // still moving (10 m/s)
        for t in 20...29 { samples.append((Double(t), -10, -1)) }             // stationary → derived 0 km/h
        samples += depart(from: 0, at: 30).map { (t: $0.t, y: $0.y, v: -1.0) }
        let observations = run(StopDetector(), samples)
        XCTAssertEqual(observations.count, 1)
        XCTAssertTrue(observations[0].observation.stopped)
        XCTAssertEqual(observations[0].observation.waitSeconds, 10, accuracy: 1e-6)
    }

    func testPausedLocationUpdatesWhileStanding() {
        var samples = approach(to: -10)
        samples.append((19, -10, 0))
        samples.append((59, -5, 20))      // next fix only 40 s later (distance filter while stationary)
        samples += depart(from: 5, at: 60)
        let observations = run(StopDetector(), samples)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].observation.waitSeconds, 40, accuracy: 1e-6)
    }

    func testVeryLongStandIsDiscarded() {
        var samples = approach(to: -10)
        var t = 19.0
        while t < 19 + 400 { samples.append((t, -10, 0)); t += 10 }
        samples += depart(from: 0, at: t)
        XCTAssertEqual(run(StopDetector(), samples).count, 0, "standing > 5 min is parking, not a signal")
    }
}
