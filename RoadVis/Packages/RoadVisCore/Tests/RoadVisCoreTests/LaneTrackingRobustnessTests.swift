import XCTest
@testable import RoadVisCore

// Tests for the lanes + tracking design: coasting, second (low-score) association, horizon auto-calibration,
// crossing check at the ROI top, adaptive lane thresholds, accumulation of dashed lines.
// The synthetic road generator is the one the design experiments used (uniform pixel noise, straight lines).

private enum Road {
    static let width = 160
    static let height = 284

    /// Grey road with two markings meeting at (`vanishingX`, `horizon`); `left` / `right` are x at the bottom row.
    static func image(horizon: Double = 0.42, left: Double? = 10, right: Double? = 150, vanishingX: Double = 80,
                      road: Int = 95, marking: Int = 225, noise: Int = 6, seed: UInt64 = 1) -> LaneImage {
        var img = LaneImage(width: width, height: height, fill: 0)
        var rng = seed
        func rand() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(2 * noise + 1)) - noise
        }
        let hy = Int(Double(height) * horizon)
        for y in 0..<height {
            for x in 0..<width {
                img[x, y] = UInt8(clamping: (y < hy ? 200 : road) + (noise > 0 ? rand() : 0))
            }
        }
        let yb = Double(height - 1), yh = Double(height) * horizon
        for (index, bottom) in [left, right].enumerated() {
            guard let bottom else { continue }
            for y in (hy + 1)..<height {
                let t = (Double(y) - yh) / (yb - yh)
                if index == 1 && (Int(t * 12) % 2 == 1) { continue }       // right line dashed
                let x = vanishingX + (bottom - vanishingX) * t
                let half = max(0.6, 2.8 * t)
                let x0 = Int((x - half).rounded()), x1 = Int((x + half).rounded())
                guard x0 <= width - 1, x1 >= 0, x0 <= x1 else { continue }
                for xx in max(0, x0)...min(width - 1, x1) {
                    img[xx, y] = UInt8(clamping: marking + (noise > 0 ? rand() : 0))
                }
            }
        }
        return img
    }

    /// Both lines dashed with duty cycle `duty` in ROAD distance (the period shrinks with perspective); `phase`
    /// (metres) moves the dashes toward the car.
    static func dashed(duty: Double, phase: Double, seed: UInt64, period: Double = 12) -> LaneImage {
        var img = image(left: nil, right: nil, seed: seed)
        let yb = Double(height - 1), yh = Double(height) * 0.42
        for bottom in [10.0, 150.0] {
            for y in (Int(yh) + 1)..<height {
                let t = (Double(y) - yh) / (yb - yh)
                let z = 5.0 / max(0.02, t)                 // 5 m at the bottom row
                let ph = ((z + phase) / period).truncatingRemainder(dividingBy: 1)
                if ph > duty { continue }
                let x = 80 + (bottom - 80) * t, half = max(0.6, 2.8 * t)
                let x0 = Int((x - half).rounded()), x1 = Int((x + half).rounded())
                guard x0 <= width - 1, x1 >= 0, x0 <= x1 else { continue }
                for xx in max(0, x0)...min(width - 1, x1) { img[xx, y] = 225 }
            }
        }
        return img
    }

    static func run(_ config: LaneDetector.Config = LaneDetector.Config(), frames: Int = 8,
                    _ make: (UInt64) -> LaneImage) -> LaneEstimate {
        let detector = LaneDetector(config: config)
        var estimate = LaneEstimate.empty()
        for i in 0..<frames { estimate = detector.process(make(UInt64(i + 1)), timestamp: Double(i) * 0.2) }
        return estimate
    }
}

final class LaneHorizonTests: XCTestCase {
    func testCrossingCheckToleratesWrongConfiguredHorizon() {
        // True horizon below the configured 0.42: the two correct lines cross between the two rows. The old check
        // at the configured horizon halved the weaker side every frame (it ended at ≈ 0.23).
        for horizon in [0.48, 0.54, 0.60] {
            let estimate = Road.run { Road.image(horizon: horizon, seed: $0) }
            XCTAssertGreaterThanOrEqual(estimate.leftConfidence, 0.5, "horizon \(horizon)")
            XCTAssertGreaterThanOrEqual(estimate.rightConfidence, 0.5, "horizon \(horizon)")
            XCTAssertNotNil(estimate.left)
            XCTAssertNotNil(estimate.right)
        }
        // And above it (was fine before, must stay fine).
        for horizon in [0.30, 0.36] {
            let estimate = Road.run { Road.image(horizon: horizon, seed: $0) }
            XCTAssertGreaterThanOrEqual(min(estimate.leftConfidence, estimate.rightConfidence), 0.5, "horizon \(horizon)")
        }
    }

    func testVanishingPointOfRawFits() {
        for horizon in [0.30, 0.36, 0.48, 0.54, 0.60] {
            let config = LaneDetector.Config()               // configured 0.42 whatever the truth
            let image = Road.image(horizon: horizon)
            let fits = LaneDetector.detectLines(in: image, config: config)
            let point = LaneDetector.vanishingPoint(left: fits.left, right: fits.right, width: 160, height: 284,
                                                    config: config)
            XCTAssertNotNil(point, "horizon \(horizon)")
            XCTAssertEqual(point?.y ?? 0, horizon, accuracy: 0.02, "horizon \(horizon)")
            XCTAssertEqual(point?.x ?? 0, 0.5, accuracy: 0.04, "horizon \(horizon)")
        }
        let config = LaneDetector.Config()
        let oneLine = LaneDetector.detectLines(in: Road.image(right: nil), config: config)
        XCTAssertNil(LaneDetector.vanishingPoint(left: oneLine.left, right: oneLine.right, width: 160, height: 284,
                                                 config: config))
    }

    func testHorizonEstimatorConverges() {
        for horizon in [0.30, 0.36, 0.48, 0.54, 0.60] {
            let detector = LaneDetector()
            var estimator = LaneHorizonEstimator()
            var convergedAt = -1
            var estimate = LaneEstimate.empty()
            for i in 0..<40 {
                let sway = 6 * sin(Double(i) / 5)
                let image = Road.image(horizon: horizon, left: 10 + sway, right: 150 + sway,
                                       vanishingX: 80 + 3 * sin(Double(i) / 7), seed: UInt64(i + 1))
                estimate = detector.process(image, timestamp: Double(i) * 0.2)
                if let y = estimator.add(detector.lastVanishingPoint) {
                    if LaneHorizonEstimator.shouldApply(estimate: y, current: detector.config.horizonY) {
                        detector.setHorizon(y)
                    }
                    if convergedAt < 0, abs(y - horizon) < 0.015 { convergedAt = i }
                }
            }
            XCTAssertGreaterThanOrEqual(convergedAt, LaneHorizonEstimator.minSamples - 1, "horizon \(horizon)")
            XCTAssertLessThanOrEqual(convergedAt, 20, "horizon \(horizon)")       // ≤ 4 s at 5 Hz
            XCTAssertEqual(detector.config.horizonY, horizon, accuracy: 0.02, "horizon \(horizon)")
            XCTAssertGreaterThanOrEqual(estimate.leftConfidence, 0.6, "horizon \(horizon)")
            XCTAssertGreaterThanOrEqual(estimate.rightConfidence, 0.6, "horizon \(horizon)")
        }
    }

    func testHorizonEstimatorIgnoresSingleLineAndWideSpread() {
        var estimator = LaneHorizonEstimator()
        // No point, weak fits, out-of-range rows / columns: never a sample.
        for _ in 0..<30 {
            XCTAssertNil(estimator.add(nil))
            XCTAssertNil(estimator.add(LaneVanishingPoint(x: 0.5, y: 0.45, confidence: 0.3)))
            XCTAssertNil(estimator.add(LaneVanishingPoint(x: 0.5, y: 0.75, confidence: 0.9)))
            XCTAssertNil(estimator.add(LaneVanishingPoint(x: 0.5, y: 0.15, confidence: 0.9)))
            XCTAssertNil(estimator.add(LaneVanishingPoint(x: 0.9, y: 0.45, confidence: 0.9)))
        }
        XCTAssertEqual(estimator.sampleCount, 0)
        // Widely spread rows (hills / a curve): enough samples but no estimate.
        for i in 0..<25 {
            XCTAssertNil(estimator.add(LaneVanishingPoint(x: 0.5, y: 0.30 + 0.012 * Double(i), confidence: 0.9)))
        }
        // Consistent samples replace the spread ones: an estimate once the window's middle half agrees.
        var result: Double?
        for _ in 0..<25 { result = estimator.add(LaneVanishingPoint(x: 0.5, y: 0.50, confidence: 0.9)) }
        XCTAssertEqual(result ?? 0, 0.50, accuracy: 1e-9)
        // Fewer than `minSamples`: nothing yet.
        var fresh = LaneHorizonEstimator()
        for _ in 0..<(LaneHorizonEstimator.minSamples - 1) {
            XCTAssertNil(fresh.add(LaneVanishingPoint(x: 0.5, y: 0.5, confidence: 0.9)))
        }
        XCTAssertNotNil(fresh.add(LaneVanishingPoint(x: 0.5, y: 0.5, confidence: 0.9)))
        // A stored start value is reported until samples say otherwise; out-of-range start values are ignored.
        XCTAssertEqual(LaneHorizonEstimator(initial: 0.47).horizonY, 0.47)
        XCTAssertNil(LaneHorizonEstimator(initial: 0.05).horizonY)
        fresh.reset()
        XCTAssertNil(fresh.horizonY)
        XCTAssertFalse(LaneHorizonEstimator.shouldApply(estimate: 0.43, current: 0.42))
        XCTAssertTrue(LaneHorizonEstimator.shouldApply(estimate: 0.44, current: 0.42))
    }

    func testSetHorizonKeepsLinesInPlace() {
        let detector = LaneDetector()
        var before = LaneEstimate.empty()
        for i in 0..<6 { before = detector.process(Road.image(seed: UInt64(i + 1)), timestamp: Double(i) * 0.2) }
        detector.setHorizon(0.50)
        let after = detector.process(Road.image(seed: 9), timestamp: 1.2)
        // Same image lines: x at a common row is unchanged although the horizon row moved.
        let row = 0.8
        XCTAssertEqual(after.left?.x(atY: row) ?? 0, before.left?.x(atY: row) ?? 1, accuracy: 0.02)
        XCTAssertEqual(after.right?.x(atY: row) ?? 0, before.right?.x(atY: row) ?? 1, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(min(after.leftConfidence, after.rightConfidence), 0.5)
    }
}

final class LaneAdaptiveThresholdTests: XCTestCase {
    func testNightMarkingsDetected() {
        // Road 30 / marking 70: below the fixed brightness floor of 85, nothing was detected.
        let night = Road.run { Road.image(road: 30, marking: 70, seed: $0) }
        XCTAssertGreaterThanOrEqual(night.leftConfidence, 0.6)
        XCTAssertGreaterThanOrEqual(night.rightConfidence, 0.6)
        let darker = Road.run { Road.image(road: 20, marking: 50, seed: $0) }
        XCTAssertGreaterThanOrEqual(min(darker.leftConfidence, darker.rightConfidence), 0.6)
        // The fixed thresholds really fail here (the reason for the change).
        let fixed = Road.run(LaneDetector.Config(adaptiveThresholds: false)) { Road.image(road: 30, marking: 70, seed: $0) }
        XCTAssertNil(fixed.left)
        XCTAssertNil(fixed.right)
    }

    func testWornMarkingDetected() {
        // Road 95 / marking 108: contrast 13 is below the fixed ridge (14) and local (18) contrasts.
        let worn = Road.run { Road.image(road: 95, marking: 108, seed: $0) }
        XCTAssertGreaterThanOrEqual(min(worn.leftConfidence, worn.rightConfidence), 0.45)
        let fixed = Road.run(LaneDetector.Config(adaptiveThresholds: false)) { Road.image(road: 95, marking: 108, seed: $0) }
        XCTAssertNil(fixed.left)
    }

    func testDayMarkingsUnchanged() {
        let day = Road.run { Road.image(seed: $0) }
        XCTAssertGreaterThanOrEqual(min(day.leftConfidence, day.rightConfidence), 0.7)
        let noisy = Road.run { Road.image(noise: 20, seed: $0) }
        XCTAssertGreaterThanOrEqual(min(noisy.leftConfidence, noisy.rightConfidence), 0.6)
    }

    func testNoFalseLinesOnNoisyEmptyRoad() {
        var falseFits = 0, total = 0
        for road in [30, 60, 95, 150] {
            for noise in [2, 6, 10, 14, 20] {
                for seed in 1...5 {
                    let image = Road.image(left: nil, right: nil, road: road, noise: noise,
                                           seed: UInt64(seed * 31 + noise))
                    let fits = LaneDetector.detectLines(in: image, config: LaneDetector.Config())
                    total += 2
                    falseFits += (fits.left != nil ? 1 : 0) + (fits.right != nil ? 1 : 0)
                }
            }
        }
        XCTAssertEqual(total, 200)
        XCTAssertEqual(falseFits, 0)
    }

    func testThresholdsFollowNoiseAndBrightness() {
        let config = LaneDetector.Config()
        let quiet = LaneDetector.adaptiveThresholds(in: Road.image(left: nil, right: nil, road: 30, noise: 2), config: config)
        XCTAssertEqual(quiet.ridgeContrast, 8)                       // floors
        XCTAssertEqual(quiet.localContrast, 10)
        XCTAssertLessThan(quiet.minBrightness, 60)                   // dark road → low floor (≥ 30)
        XCTAssertGreaterThanOrEqual(quiet.minBrightness, 30)
        let loud = LaneDetector.adaptiveThresholds(in: Road.image(left: nil, right: nil, road: 150, noise: 20), config: config)
        XCTAssertGreaterThan(loud.ridgeContrast, 14)                 // noisy → stricter than the fixed values
        XCTAssertGreaterThan(loud.localContrast, 18)
        XCTAssertEqual(loud.minBrightness, 85)                       // never above the configured floor
        let off = LaneDetector.adaptiveThresholds(in: Road.image(road: 30), config: LaneDetector.Config(adaptiveThresholds: false))
        XCTAssertEqual(off.minBrightness, 85)
        XCTAssertEqual(off.ridgeContrast, 14)
        XCTAssertEqual(off.localContrast, 18)
        // Tiny image: fallback, no crash.
        let tiny = LaneDetector.adaptiveThresholds(in: LaneImage(width: 8, height: 8, fill: 50), config: config)
        XCTAssertEqual(tiny.ridgeContrast, 14)
    }
}

final class LaneAccumulationTests: XCTestCase {
    /// Share of frames on which both lines reach 0.45, and the mean of the weaker confidence (frames 5…).
    private func score(accumulate: Int, duty: Double) -> (ok: Int, total: Int, mean: Double) {
        let detector = LaneDetector(config: LaneDetector.Config(accumulateFrames: accumulate))
        var ok = 0
        var sum = 0.0
        let frames = 60
        for i in 0..<frames {
            // 50 km/h at 5 Hz = 2.8 m per lane frame.
            let image = Road.dashed(duty: duty, phase: Double(i) * 2.8, seed: UInt64(i + 1))
            let estimate = detector.process(image, timestamp: Double(i) * 0.2)
            if i >= 5 {
                if estimate.leftConfidence >= 0.45 && estimate.rightConfidence >= 0.45 { ok += 1 }
                sum += min(estimate.leftConfidence, estimate.rightConfidence)
            }
        }
        return (ok, frames - 5, sum / Double(frames - 5))
    }

    func testSparseDashedLinesNeedAccumulation() {
        let single = score(accumulate: 1, duty: 0.25)
        let three = score(accumulate: 3, duty: 0.25)
        XCTAssertEqual(three.ok, three.total)                        // every frame
        XCTAssertLessThan(single.ok, single.total * 3 / 4)           // single frames often miss a line
        XCTAssertGreaterThan(three.mean, single.mean + 0.15)
        XCTAssertGreaterThanOrEqual(three.mean, 0.7)
    }

    func testAccumulationIsTheDefaultAndResetsOnGapsAndSizeChanges() {
        XCTAssertEqual(LaneDetector.Config().accumulateFrames, 3)
        // Frames 1 s apart are not mixed: an empty road right after a marked one gives no fits.
        let detector = LaneDetector()
        detector.process(Road.image(seed: 1), timestamp: 0)
        detector.process(Road.image(left: nil, right: nil, seed: 2), timestamp: 1.0)
        XCTAssertNil(detector.lastVanishingPoint)
        let near = LaneDetector()
        near.process(Road.image(seed: 1), timestamp: 0)
        near.process(Road.image(left: nil, right: nil, seed: 2), timestamp: 0.2)
        XCTAssertNotNil(near.lastVanishingPoint)                     // the previous frame's lines are still in
        // Another image size: no crash, no mixing.
        var small = LaneImage(width: 80, height: 142, fill: 95)
        small[40, 100] = 96
        near.process(small, timestamp: 0.4)
        XCTAssertNil(near.lastVanishingPoint)
        // reset() forgets the history.
        let cleared = LaneDetector()
        cleared.process(Road.image(seed: 1), timestamp: 0)
        cleared.reset()
        cleared.process(Road.image(left: nil, right: nil, seed: 2), timestamp: 0.2)
        XCTAssertNil(cleared.lastVanishingPoint)
    }
}

final class TrackCoastingTests: XCTestCase {
    private let geometry = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)

    private func det(_ kind: VehicleKind, _ confidence: Double, x: Double = 0.4, y: Double = 0.5, w: Double = 0.2,
                     h: Double = 0.1) -> Detection {
        Detection(kind: kind, label: kind.rawValue, confidence: confidence, box: BBox(x: x, y: y, width: w, height: h))
    }

    func testCoastedTrackIsReturnedWithPredictedBoxThenDropped() {
        let tracker = ObjectTracker()
        XCTAssertEqual(tracker.config.coastFrames, 3)
        var tracks: [TrackedObject] = []
        // Moves right by 0.01 per 0.1 s frame.
        for i in 0..<5 {
            tracks = tracker.update(detections: [det(.car, 0.8, x: 0.40 + 0.01 * Double(i))], timestamp: Double(i) * 0.1)
        }
        let id = tracks.first?.id
        let lastX = tracks.first?.box.midX ?? 0
        for miss in 1...3 {
            tracks = tracker.update(detections: [], timestamp: 0.4 + Double(miss) * 0.1)
            XCTAssertEqual(tracks.count, 1, "miss \(miss)")
            XCTAssertEqual(tracks.first?.id, id)
            XCTAssertEqual(tracks.first?.missed, miss)
            XCTAssertEqual(tracks.first?.hits, 5)
            // Extrapolated along the motion, roughly 0.01 per frame.
            XCTAssertGreaterThan(tracks.first?.box.midX ?? 0, lastX + 0.005 * Double(miss), "miss \(miss)")
            XCTAssertLessThan(tracks.first?.box.midX ?? 1, lastX + 0.02 * Double(miss), "miss \(miss)")
        }
        // Fourth missed frame: no longer returned (the track itself lives on for re-acquisition).
        XCTAssertTrue(tracker.update(detections: [], timestamp: 0.8).isEmpty)
        let again = tracker.update(detections: [det(.car, 0.8, x: 0.49)], timestamp: 0.9)
        XCTAssertEqual(again.first?.id, id)
        XCTAssertEqual(again.first?.missed, 0)
    }

    func testCoastedTrackNotCountedTwice() {
        let tracker = ObjectTracker()
        for i in 0..<4 { _ = tracker.update(detections: [det(.car, 0.8)], timestamp: Double(i) * 0.1) }
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
        _ = tracker.update(detections: [], timestamp: 0.4)
        _ = tracker.update(detections: [], timestamp: 0.5)
        _ = tracker.update(detections: [det(.car, 0.8)], timestamp: 0.6)
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
        XCTAssertEqual(tracker.totalUniqueVehicles, 1)
    }

    func testTentativeTracksAreNotCoastedAndCoastingCanBeSwitchedOff() {
        let tracker = ObjectTracker()
        _ = tracker.update(detections: [det(.car, 0.8)], timestamp: 0)
        XCTAssertTrue(tracker.update(detections: [], timestamp: 0.1).isEmpty)     // 1 hit: not confirmed
        let strict = ObjectTracker(config: ObjectTracker.Config(coastFrames: 0))
        for i in 0..<4 { _ = strict.update(detections: [det(.car, 0.8)], timestamp: Double(i) * 0.1) }
        XCTAssertTrue(strict.update(detections: [], timestamp: 0.4).isEmpty)
    }

    func testCoastedLeadSurvivesTwoMissedFrames() {
        let tracker = ObjectTracker()
        let lead = LeadVehicleTracker()
        var result: LeadVehicle?
        // A car straight ahead, bottom edge at 0.75.
        let car = det(.car, 0.8, x: 0.4, y: 0.65, w: 0.2, h: 0.1)
        for i in 0..<8 {
            let t = Double(i) * 0.1
            result = lead.update(tracks: tracker.update(detections: [car], timestamp: t), geometry: geometry, timestamp: t)
        }
        let id = result?.trackID
        let distance = result?.distanceMeters ?? 0
        XCTAssertNotNil(id)
        for miss in 1...2 {
            let t = 0.7 + Double(miss) * 0.1
            result = lead.update(tracks: tracker.update(detections: [], timestamp: t), geometry: geometry, timestamp: t)
            XCTAssertEqual(result?.trackID, id, "miss \(miss)")
            XCTAssertEqual(result?.distanceMeters ?? 0, distance, accuracy: 1e-9, "miss \(miss)")   // unchanged
        }
        // Detected again: same lead, distance still continuous.
        result = lead.update(tracks: tracker.update(detections: [car], timestamp: 1.0), geometry: geometry, timestamp: 1.0)
        XCTAssertEqual(result?.trackID, id)
        XCTAssertEqual(result?.distanceMeters ?? 0, distance, accuracy: 0.3)
        // Four missed frames: gone.
        for miss in 1...4 {
            let t = 1.0 + Double(miss) * 0.1
            result = lead.update(tracks: tracker.update(detections: [], timestamp: t), geometry: geometry, timestamp: t)
        }
        XCTAssertNil(result)
    }

    func testCoastedLeadAddsNoDistanceSample() {
        // Stationary gap, then coasted frames with a wildly different (predicted) box: the reported distance and the
        // closing speed must not move.
        let lead = LeadVehicleTracker()
        var result: LeadVehicle?
        func car(_ t: Double, missed: Int = 0, scale: Double = 1) -> TrackedObject {
            let w = 0.2 * scale, h = 0.1 * scale
            return TrackedObject(id: 3, kind: .car, label: "car", box: BBox(x: 0.5 - w / 2, y: 0.75 - h, width: w, height: h),
                                 confidence: 0.9, hits: 6, missed: missed, firstSeen: 0, lastSeen: t, isConfirmed: true)
        }
        for i in 0..<10 {
            result = lead.update(tracks: [car(Double(i) * 0.1)], geometry: geometry, timestamp: Double(i) * 0.1)
        }
        let before = result
        XCTAssertNotNil(before?.relativeSpeedKmh)
        for miss in 1...3 {
            let t = 0.9 + Double(miss) * 0.1
            result = lead.update(tracks: [car(t, missed: miss, scale: 1.3)], geometry: geometry, timestamp: t)
            XCTAssertEqual(result?.distanceMeters ?? 0, before?.distanceMeters ?? 1, accuracy: 1e-9)
            XCTAssertEqual(result?.relativeSpeedKmh ?? 99, before?.relativeSpeedKmh ?? 0, accuracy: 1e-9)
            XCTAssertEqual(result?.method, before?.method)
        }
        // More than `coastMissed` missed frames is not a lead candidate.
        XCTAssertNil(lead.update(tracks: [car(1.3, missed: 4)], geometry: geometry, timestamp: 1.3))
        // A coasted track that never was the lead has no measured distance: no lead.
        let fresh = LeadVehicleTracker()
        XCTAssertNil(fresh.update(tracks: [car(0, missed: 1)], geometry: geometry, timestamp: 0))
    }

    func testCoastedOtherTrackDoesNotHideDetectedLead() {
        // Track 2 is nearer and centred but only coasted (never the lead); track 1 is detected. The detected one wins.
        let lead = LeadVehicleTracker()
        let far = TrackedObject(id: 1, kind: .car, label: "car", box: BBox(x: 0.45, y: 0.58, width: 0.1, height: 0.06),
                                confidence: 0.9, hits: 6, firstSeen: 0, lastSeen: 0, isConfirmed: true)
        let nearCoasted = TrackedObject(id: 2, kind: .car, label: "car", box: BBox(x: 0.35, y: 0.6, width: 0.3, height: 0.2),
                                        confidence: 0.9, hits: 6, missed: 1, firstSeen: 0, lastSeen: 0, isConfirmed: true)
        let result = lead.update(tracks: [far, nearCoasted], geometry: geometry, timestamp: 0)
        XCTAssertEqual(result?.trackID, 1)
    }

    func testLeadKeepsDistanceAcrossIdSwitchWithHighIoU() {
        let lead = LeadVehicleTracker()
        func car(_ id: Int, _ t: Double, x: Double = 0.4, kind: VehicleKind = .car) -> TrackedObject {
            TrackedObject(id: id, kind: kind, label: "car", box: BBox(x: x, y: 0.65, width: 0.2, height: 0.1),
                          confidence: 0.9, hits: 6, firstSeen: 0, lastSeen: t, isConfirmed: true)
        }
        var result: LeadVehicle?
        for i in 0..<10 { result = lead.update(tracks: [car(1, Double(i) * 0.1)], geometry: geometry, timestamp: Double(i) * 0.1) }
        XCTAssertNotNil(result?.relativeSpeedKmh)
        // Same place, new ID: the closing-speed history is kept (it would be nil after a restart).
        result = lead.update(tracks: [car(2, 1.0, x: 0.405)], geometry: geometry, timestamp: 1.0)
        XCTAssertEqual(result?.trackID, 2)
        XCTAssertNotNil(result?.relativeSpeedKmh)
        // A different vehicle elsewhere in the corridor (IoU < 0.5): restart.
        result = lead.update(tracks: [car(3, 1.1, x: 0.30)], geometry: geometry, timestamp: 1.1)
        XCTAssertEqual(result?.trackID, 3)
        XCTAssertNil(result?.relativeSpeedKmh)
        // Same box but another class: restart (typical sizes differ).
        for i in 0..<10 { result = lead.update(tracks: [car(3, 1.2 + Double(i) * 0.1, x: 0.30)], geometry: geometry, timestamp: 1.2 + Double(i) * 0.1) }
        XCTAssertNotNil(result?.relativeSpeedKmh)
        result = lead.update(tracks: [car(4, 2.2, x: 0.30, kind: .truck)], geometry: geometry, timestamp: 2.2)
        XCTAssertNil(result?.relativeSpeedKmh)
    }

    func testPedestrianHazardIgnoresCoastedTrack() {
        let detector = PedestrianHazardDetector()
        func person(_ t: Double, missed: Int, x: Double = 0.5) -> TrackedObject {
            TrackedObject(id: 1, kind: .person, label: "person", box: BBox(x: x - 0.02, y: 0.58, width: 0.04, height: 0.12),
                          confidence: 0.8, hits: 6, missed: missed, firstSeen: 0, lastSeen: t, isConfirmed: true)
        }
        let portrait = CameraGeometry.defaultPortrait
        // Never seen for real: a coasted box alone raises nothing.
        let cold = detector.evaluate(tracks: [person(0, missed: 1)], ownSpeedKmh: 40, geometry: portrait, timestamp: 0)
        XCTAssertTrue(cold.hazards.isEmpty)
        // Seen in the own lane (danger), then coasted: no hazard from the predicted box, but the person stays
        // "relevant" (drawn / counted), not filtered as a sidewalk person.
        let seen = detector.evaluate(tracks: [person(0.1, missed: 0)], ownSpeedKmh: 40, geometry: portrait, timestamp: 0.1)
        XCTAssertEqual(seen.hazards.first?.level, .danger)
        let coasted = detector.evaluate(tracks: [person(0.2, missed: 1)], ownSpeedKmh: 40, geometry: portrait, timestamp: 0.2)
        XCTAssertTrue(coasted.hazards.isEmpty)
        XCTAssertTrue(coasted.relevantIDs.contains(1))
        XCTAssertFalse(coasted.filteredIDs.contains(1))
        // A sidewalk person stays filtered while coasted (does not flash up).
        let other = PedestrianHazardDetector()
        let sidewalk = other.evaluate(tracks: [person(0, missed: 0, x: 0.03)], ownSpeedKmh: 40, geometry: portrait, timestamp: 0)
        XCTAssertTrue(sidewalk.filteredIDs.contains(1))
        let sidewalkCoasted = other.evaluate(tracks: [person(0.1, missed: 1, x: 0.03)], ownSpeedKmh: 40, geometry: portrait,
                                             timestamp: 0.1)
        XCTAssertTrue(sidewalkCoasted.filteredIDs.contains(1))
    }

    func testSpeedEstimatorTakesNoSampleFromCoastedTrack() {
        let estimator = MonocularSpeedEstimator()
        func car(_ t: Double, missed: Int, h: Double) -> TrackedObject {
            TrackedObject(id: 5, kind: .car, label: "car", box: BBox(x: 0.4, y: 0.5, width: 0.2, height: h),
                          confidence: 0.9, hits: 6, missed: missed, firstSeen: 0, lastSeen: t, isConfirmed: true)
        }
        var out: [TrackedObject] = []
        for i in 0..<8 { out = estimator.update(tracks: [car(Double(i) * 0.1, missed: 0, h: 0.05)], ownSpeedKmh: 50, geometry: geometry, timestamp: Double(i) * 0.1) }
        let measured = out.first?.distanceMeters
        XCTAssertNotNil(measured)
        // Coasted with a much larger predicted box: the measured distance is kept, no speed is reported.
        out = estimator.update(tracks: [car(0.8, missed: 1, h: 0.09)], ownSpeedKmh: 50, geometry: geometry, timestamp: 0.8)
        XCTAssertEqual(out.first?.distanceMeters ?? 0, measured ?? 1, accuracy: 1e-9)
        XCTAssertNil(out.first?.relativeSpeedKmh)
        // And the next real frame's speed is not polluted by the predicted box (object did not move: ≈ 0).
        out = estimator.update(tracks: [car(0.9, missed: 0, h: 0.05)], ownSpeedKmh: 50, geometry: geometry, timestamp: 0.9)
        XCTAssertEqual(out.first?.relativeSpeedKmh ?? 99, 0, accuracy: 1)
    }
}

final class SecondAssociationTests: XCTestCase {
    private func det(_ kind: VehicleKind, _ confidence: Double, x: Double = 0.4, y: Double = 0.4, w: Double = 0.1,
                     h: Double = 0.1) -> Detection {
        Detection(kind: kind, label: kind.rawValue, confidence: confidence, box: BBox(x: x, y: y, width: w, height: h))
    }

    func testLowConfidenceDetectionKeepsConfirmedTrack() {
        // Car threshold 0.30; 0.25 is in the continuation band (≥ 0.30 × 0.7).
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<3 { tracks = tracker.update(detections: [det(.car, 0.6)], timestamp: Double(i) * 0.1) }
        let id = tracks.first?.id
        tracks = tracker.update(detections: [det(.car, 0.25, x: 0.41)], timestamp: 0.3)
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.missed, 0)
        XCTAssertEqual(tracks.first?.hits, 3)                              // no hit from a low-score match
        XCTAssertEqual(tracks.first?.peakConfidence ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(tracker.lowScoreMatches, 1)
        XCTAssertGreaterThan(tracks.first?.box.x ?? 0, 0.4)                // the box follows the low detection
    }

    func testLowConfidenceNeverStartsOrConfirmsTrack() {
        let tracker = ObjectTracker()
        XCTAssertTrue(tracker.update(detections: [det(.car, 0.25)], timestamp: 0).isEmpty)
        // Two full-score frames (tentative), then only low scores: never confirmed, never counted.
        _ = tracker.update(detections: [det(.car, 0.6)], timestamp: 0.1)
        _ = tracker.update(detections: [det(.car, 0.6)], timestamp: 0.2)
        for i in 0..<5 {
            let tracks = tracker.update(detections: [det(.car, 0.25)], timestamp: 0.3 + Double(i) * 0.1)
            XCTAssertFalse(tracks.contains { $0.isConfirmed })
        }
        XCTAssertNil(tracker.uniqueCounts[.car])
        XCTAssertEqual(tracker.lowScoreMatches, 0)
    }

    func testLowDetectionDoesNotStealFromHighMatch() {
        // One confirmed track; a low-score box sits exactly on its prediction and a full-score box is slightly off.
        // The single-stage matcher gave the track to the low box (higher IoU) and opened a duplicate track for the
        // full-score one.
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<3 { tracks = tracker.update(detections: [det(.car, 0.6)], timestamp: Double(i) * 0.1) }
        let id = tracks.first?.id
        tracks = tracker.update(detections: [det(.car, 0.25), det(.car, 0.7, x: 0.42)], timestamp: 0.3)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.hits, 4)
        XCTAssertEqual(tracks.first?.confidence ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(tracker.lowScoreMatches, 0)
    }

    func testLowScoreMatchNeedsIoUNotJustACloseCentre() {
        // The first stage may match by centre distance; the second (low-score) stage is IoU only (0.3).
        let tracker = ObjectTracker()
        for i in 0..<3 { _ = tracker.update(detections: [det(.car, 0.6)], timestamp: Double(i) * 0.1) }
        // Shifted by 0.07 of a 0.1-wide box: IoU ≈ 0.18.
        let tracks = tracker.update(detections: [det(.car, 0.25, x: 0.47)], timestamp: 0.3)
        XCTAssertEqual(tracks.first?.missed, 1)                            // only coasted
        XCTAssertEqual(tracker.lowScoreMatches, 0)
    }

    func testLowScoreMatchAddsNoClassVote() {
        // Car track; low-score "truck" boxes on it must not flip the class however many arrive.
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<3 { tracks = tracker.update(detections: [det(.car, 0.5)], timestamp: Double(i) * 0.1) }
        for i in 0..<12 { tracks = tracker.update(detections: [det(.truck, 0.25)], timestamp: 0.3 + Double(i) * 0.1) }
        XCTAssertEqual(tracks.first?.kind, .car)
        XCTAssertEqual(tracks.first?.missed, 0)
    }

    func testPersonTrackSurvivesConfidenceDip() {
        // Person threshold 0.40; a 0.30 frame used to be a miss. The pedestrian check needs hits ≥ 5: the count
        // goes on after the dip instead of the track restarting.
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<4 { tracks = tracker.update(detections: [det(.person, 0.6)], timestamp: Double(i) * 0.1) }
        let id = tracks.first?.id
        tracks = tracker.update(detections: [det(.person, 0.30)], timestamp: 0.4)
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.missed, 0)
        XCTAssertEqual(tracks.first?.hits, 4)
        tracks = tracker.update(detections: [det(.person, 0.6)], timestamp: 0.5)
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.hits, 5)
        XCTAssertEqual(tracks.count, 1)
    }
}
