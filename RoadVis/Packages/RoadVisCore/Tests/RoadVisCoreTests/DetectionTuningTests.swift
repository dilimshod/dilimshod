import XCTest
@testable import RoadVisCore

final class DetectionTuningTests: XCTestCase {
    func det(_ kind: VehicleKind, _ conf: Double, x: Double = 0.4, y: Double = 0.4, w: Double = 0.1,
             h: Double = 0.1) -> Detection {
        Detection(kind: kind, label: kind.rawValue, confidence: conf, box: BBox(x: x, y: y, width: w, height: h))
    }

    // MARK: - Thresholds

    func testClassThresholdsAtDefaultSlider() {
        let t = DetectionThresholds.perClass()
        XCTAssertEqual(t[.car], 0.30)
        XCTAssertEqual(t[.truck], 0.30)
        XCTAssertEqual(t[.person], 0.40)
        XCTAssertEqual(t[.trafficLight], 0.30)
        XCTAssertEqual(t[.stopSign], 0.55)
        XCTAssertEqual(t.count, VehicleKind.allCases.count)
        XCTAssertEqual(ObjectTracker.Config().minConfidence, t)
    }

    func testSliderMovesEveryClass() {
        // The old defect: the slider could not lower persons / lights / stop signs below 0.5 / 0.55.
        let low = DetectionThresholds.perClass(global: 0.15)
        XCTAssertEqual(low[.car] ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(low[.person] ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(low[.trafficLight] ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(low[.stopSign] ?? 0, 0.40, accuracy: 1e-9)
        let high = DetectionThresholds.perClass(global: 0.8)
        XCTAssertEqual(high[.car] ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(high[.trafficLight] ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(high[.stopSign] ?? 0, DetectionThresholds.maximum, accuracy: 1e-9)
        XCTAssertEqual(DetectionThresholds.threshold(for: .car, global: 0), DetectionThresholds.minimum)
        XCTAssertEqual(DetectionThresholds.threshold(for: .car, global: .nan), 0.30)
    }

    func testDetectorFloorIsBelowEveryUsableScore() {
        let floor = DetectionThresholds.detectorFloor()
        XCTAssertEqual(floor, 0.30 * DetectionThresholds.continuationFactor, accuracy: 1e-9)
        for (_, threshold) in DetectionThresholds.perClass() {
            XCTAssertLessThanOrEqual(floor, threshold * DetectionThresholds.continuationFactor + 1e-9)
        }
        XCTAssertEqual(DetectionThresholds.detectorFloor(global: 0.5, continuationFactor: 1), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(DetectionThresholds.detectorFloor(global: 0), DetectionThresholds.detectorFloorMinimum)
    }

    func testRiderLabelIsAPerson() {
        XCTAssertEqual(VehicleKind(label: "rider"), .person)
        XCTAssertNil(VehicleKind(label: "traffic sign"))
    }

    // MARK: - Tracker: one threshold table, hysteresis

    func testTrackerUsesTheSliderTable() {
        // Person at 0.42: tracked at the default slider, dropped when the slider is raised, and a 0.3 person is
        // tracked once the slider is lowered (the hidden 0.5 floor is gone).
        let tracker = ObjectTracker()
        XCTAssertEqual(tracker.update(detections: [det(.person, 0.42)], timestamp: 0).count, 1)
        XCTAssertEqual(tracker.update(detections: [det(.person, 0.38, x: 0.8)], timestamp: 0.1).filter { $0.box.x > 0.7 }.count, 0)
        tracker.minConfidence = DetectionThresholds.perClass(global: 0.15)
        XCTAssertEqual(tracker.update(detections: [det(.person, 0.3, x: 0.8)], timestamp: 0.2).filter { $0.box.x > 0.7 }.count, 1)
        tracker.minConfidence = DetectionThresholds.perClass(global: 0.5)
        tracker.dropTracks()
        XCTAssertTrue(tracker.update(detections: [det(.person, 0.42), det(.car, 0.45, x: 0.1)], timestamp: 0.3).isEmpty)
    }

    func testLowScoreDetectionContinuesConfirmedTrackOnly() {
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<3 {
            tracks = tracker.update(detections: [det(.stopSign, 0.6)], timestamp: Double(i) * 0.1)
        }
        XCTAssertEqual(tracks.first?.isConfirmed, true)
        let id = tracks.first?.id
        // 0.40 is below the stop-sign threshold (0.55) but above 0.55 × 0.7: the confirmed track goes on.
        tracks = tracker.update(detections: [det(.stopSign, 0.40)], timestamp: 0.3)
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.missed, 0)
        XCTAssertEqual(tracks.first?.hits, 4)
        XCTAssertEqual(tracks.first?.confidence ?? 0, 0.40, accuracy: 1e-9)
        XCTAssertEqual(tracks.first?.peakConfidence ?? 0, 0.60, accuracy: 1e-9)
        // Below the continuation floor: a miss.
        tracks = tracker.update(detections: [det(.stopSign, 0.30)], timestamp: 0.4)
        XCTAssertTrue(tracks.isEmpty)
        // A low score never opens a track and never feeds a tentative one.
        let fresh = ObjectTracker()
        XCTAssertTrue(fresh.update(detections: [det(.stopSign, 0.40)], timestamp: 0).isEmpty)
        _ = fresh.update(detections: [det(.stopSign, 0.6)], timestamp: 0.1)
        let tentative = fresh.update(detections: [det(.stopSign, 0.40)], timestamp: 0.2)
        XCTAssertTrue(tentative.isEmpty)
        // Hysteresis off: the old strict behaviour.
        let strict = ObjectTracker(config: ObjectTracker.Config(continuationFactor: 1))
        for i in 0..<3 { _ = strict.update(detections: [det(.stopSign, 0.6)], timestamp: Double(i) * 0.1) }
        XCTAssertTrue(strict.update(detections: [det(.stopSign, 0.45)], timestamp: 0.3).isEmpty)
    }

    func testDropTracksKeepsCountersAndIDs() {
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<4 { tracks = tracker.update(detections: [det(.car, 0.8)], timestamp: Double(i) * 0.1) }
        XCTAssertEqual(tracks.first?.isConfirmed, true)
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
        let oldID = tracks.first?.id ?? -1
        tracker.dropTracks()
        tracks = tracker.update(detections: [det(.car, 0.8)], timestamp: 0.5)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(tracks.first?.id ?? -1, oldID)          // a new track, not the old one continued
        XCTAssertEqual(tracks.first?.isConfirmed, false)
        XCTAssertEqual(tracks.first?.hits, 1)
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)                // counters untouched
    }

    func testStaleTracksAreNotContinuedAfterAGap() {
        let tracker = ObjectTracker()
        var tracks: [TrackedObject] = []
        for i in 0..<4 { tracks = tracker.update(detections: [det(.car, 0.8)], timestamp: Double(i) * 0.1) }
        let oldID = tracks.first?.id ?? -1
        // Two seconds without frames: still the same track (short interruption).
        tracks = tracker.update(detections: [det(.car, 0.8)], timestamp: 2.3)
        XCTAssertEqual(tracks.first?.id, oldID)
        // Minutes later the same screen area holds another car: new, unconfirmed track.
        tracks = tracker.update(detections: [det(.car, 0.8)], timestamp: 200)
        XCTAssertNotEqual(tracks.first?.id, oldID)
        XCTAssertEqual(tracks.first?.isConfirmed, false)
    }

    // MARK: - Cross-class duplicates

    func testCarTruckDuplicateIsMerged() {
        let car = det(.car, 0.62, x: 0.30, y: 0.40, w: 0.20, h: 0.20)
        let truck = det(.truck, 0.48, x: 0.31, y: 0.40, w: 0.20, h: 0.20)      // IoU ≈ 0.90
        let bus = det(.bus, 0.9, x: 0.70, y: 0.40, w: 0.20, h: 0.20)
        let result = CrossClassDuplicates.suppress([truck, car, bus])
        XCTAssertEqual(result.map(\.kind), [.car, .bus])                     // order kept, weaker box gone
    }

    func testDuplicateSuppressionLeavesOtherPairsAlone() {
        // Person on a motorcycle, a partly hidden car (IoU < 0.7), two cars (same class → detector NMS).
        let rider = det(.person, 0.5, x: 0.30, y: 0.30, w: 0.10, h: 0.30)
        let moto = det(.motorcycle, 0.7, x: 0.30, y: 0.30, w: 0.10, h: 0.30)
        let car = det(.car, 0.8, x: 0.60, y: 0.40, w: 0.20, h: 0.20)
        let truck = det(.truck, 0.6, x: 0.66, y: 0.40, w: 0.20, h: 0.20)       // IoU ≈ 0.54
        let car2 = det(.car, 0.4, x: 0.60, y: 0.40, w: 0.20, h: 0.20)
        let light = det(.trafficLight, 0.6, x: 0.60, y: 0.40, w: 0.20, h: 0.20)
        let input = [rider, moto, car, truck, car2, light]
        XCTAssertEqual(CrossClassDuplicates.suppress(input), input)
        // Bicycle + motorcycle on one object: merged; car vs motorcycle: different groups.
        let bike = det(.bicycle, 0.45, x: 0.30, y: 0.30, w: 0.10, h: 0.30)
        XCTAssertEqual(CrossClassDuplicates.suppress([bike, moto]).map(\.kind), [.motorcycle])
        let carOnMoto = det(.car, 0.9, x: 0.30, y: 0.30, w: 0.10, h: 0.30)
        XCTAssertEqual(CrossClassDuplicates.suppress([carOnMoto, moto]).count, 2)
        XCTAssertTrue(CrossClassDuplicates.suppress([]).isEmpty)
    }

    // MARK: - Input geometry

    func testAspectMatchedInputIsFilled() {
        // 1920×1080 into 960×544: 0.7 % stretch → fill, boxes pass through.
        let g = DetectorInputGeometry(inputWidth: 960, inputHeight: 544, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(g.aspectMismatch, 0.0074, accuracy: 0.0005)
        XCTAssertEqual(g.fit, .fill)
        XCTAssertEqual(g.usedInputFraction, 1)
        let box = BBox(x: 0.2, y: 0.3, width: 0.1, height: 0.4)
        let same = g.frameBox(fromInputNormalized: box)
        XCTAssertEqual(same.x, box.x, accuracy: 1e-12)
        XCTAssertEqual(same.y, box.y, accuracy: 1e-12)
        XCTAssertEqual(same.width, box.width, accuracy: 1e-12)
        XCTAssertEqual(same.height, box.height, accuracy: 1e-12)
        // Portrait pair.
        XCTAssertEqual(DetectorInputGeometry(inputWidth: 544, inputHeight: 960, sourceWidth: 1080, sourceHeight: 1920).fit, .fill)
        XCTAssertTrue(DetectorInputGeometry.isLandscape(width: 1920, height: 1080))
        XCTAssertFalse(DetectorInputGeometry.isLandscape(width: 1080, height: 1920))
    }

    func testMismatchedInputIsLetterboxedAndUndone() {
        // Old situation: portrait 1080×1920 in a square 640 input → picture is 360×640, 56 % of the input.
        let square = DetectorInputGeometry(inputWidth: 640, inputHeight: 640, sourceWidth: 1080, sourceHeight: 1920)
        XCTAssertEqual(square.fit, .letterbox)
        XCTAssertEqual(square.usedInputFraction, 0.5625, accuracy: 1e-9)
        // A box covering the whole picture inside the input (x 140…500 px) maps to the whole frame.
        let whole = square.frameBox(fromInputNormalized: BBox(x: 140.0 / 640, y: 0, width: 360.0 / 640, height: 1))
        XCTAssertEqual(whole.x, 0, accuracy: 1e-9)
        XCTAssertEqual(whole.width, 1, accuracy: 1e-9)
        // Centre stays the centre, widths grow by 1 / 0.5625 (the squeeze the app used to leave in).
        let mid = square.frameBox(fromInputNormalized: BBox(x: 0.45, y: 0.5, width: 0.1, height: 0.1))
        XCTAssertEqual(mid.midX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.width, 0.1 / 0.5625, accuracy: 1e-9)
        XCTAssertEqual(mid.height, 0.1, accuracy: 1e-9)
        // Android lite input: 1280×720 into 640×384 → 12 px bars top and bottom.
        let lite = DetectorInputGeometry(inputWidth: 640, inputHeight: 384, sourceWidth: 1280, sourceHeight: 720)
        XCTAssertEqual(lite.fit, .letterbox)
        XCTAssertEqual(lite.usedInputFraction, 360.0 / 384, accuracy: 1e-9)
        let top = lite.frameBox(fromInputNormalized: BBox(x: 0, y: 12.0 / 384, width: 1, height: 180.0 / 384))
        XCTAssertEqual(top.y, 0, accuracy: 1e-9)
        XCTAssertEqual(top.height, 0.5, accuracy: 1e-9)
    }

    func testDecoderHandlesRectangularInput() {
        // Raw [1, 6, 7] tensor (rows cx, cy, w, h, 2 classes; 7 anchors, 5 of them empty) in 960×544 input pixels.
        func row(_ a: Float, _ b: Float) -> [Float] { [a, b, 0, 0, 0, 0, 0] }
        let values: [Float] = row(480, 100) + row(272, 300) + row(96, 50) + row(54.4, 100) + row(0.9, 0.1) + row(0.05, 0.8)
        // Filled (aspect-matched) frame: plain division by the input size.
        let filled = YOLODecoder.decode(values: values, shape: [1, 6, 7], inputWidth: 960, inputHeight: 544,
                                        confidenceThreshold: 0.25, iouThreshold: 0.45)
        XCTAssertEqual(filled.count, 2)
        XCTAssertEqual(filled[0].box.midX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(filled[0].box.midY, 0.5, accuracy: 1e-6)
        XCTAssertEqual(filled[0].box.width, 0.1, accuracy: 1e-6)
        XCTAssertEqual(filled[0].box.height, 0.1, accuracy: 1e-6)
        // Letterboxed 1280×720 frame in 960×544: gain 0.75, 2 px bars → y = (300 − 2) / 0.75 / 720.
        let boxed = YOLODecoder.decode(values: values, shape: [1, 6, 7], inputWidth: 960, inputHeight: 544,
                                       confidenceThreshold: 0.25, iouThreshold: 0.45, sourceWidth: 1280, sourceHeight: 720)
        let second = boxed.first { $0.classIndex == 1 }
        XCTAssertEqual(second?.box.midY ?? 0, (300.0 - 2) / 0.75 / 720, accuracy: 1e-6)
        XCTAssertEqual(second?.box.midX ?? 0, 100.0 / 960, accuracy: 1e-6)
        // The decoder and DetectorInputGeometry agree.
        let g = DetectorInputGeometry(inputWidth: 640, inputHeight: 384, sourceWidth: 1280, sourceHeight: 720)
        let single: [Float] = row(320, 0) + row(192, 0) + row(64, 0) + row(96, 0) + row(0.9, 0)
        let viaDecoder = YOLODecoder.decode(values: single, shape: [1, 5, 7], inputWidth: 640,
                                            inputHeight: 384, confidenceThreshold: 0.25, iouThreshold: 0.45,
                                            sourceWidth: 1280, sourceHeight: 720)
        let viaGeometry = g.frameBox(fromInputNormalized: BBox(x: (320.0 - 32) / 640, y: (192.0 - 48) / 384,
                                                               width: 64.0 / 640, height: 96.0 / 384))
        XCTAssertEqual(viaDecoder.first?.box.x ?? 0, viaGeometry.x, accuracy: 1e-6)
        XCTAssertEqual(viaDecoder.first?.box.y ?? 0, viaGeometry.y, accuracy: 1e-6)
        XCTAssertEqual(viaDecoder.first?.box.height ?? 0, viaGeometry.height, accuracy: 1e-6)
    }

    // MARK: - Quality governor

    /// Feeds `frames` frames of `ms` at 10 fps starting at `t`; returns the time after the last frame.
    func feed(_ g: inout DetectorQualityGovernor, ms: Double, frames: Int, from t: Double, constrained: Bool = false) -> Double {
        var time = t
        for _ in 0..<frames {
            g.record(inferenceMs: ms, constrained: constrained, timestamp: time)
            time += 0.1
        }
        return time
    }

    func testGovernorDropsToLiteWhenSlowAndComesBack() {
        var g = DetectorQualityGovernor(config: .iOS)
        XCTAssertEqual(g.level, .full)
        var t = feed(&g, ms: 30, frames: 100, from: 0)
        XCTAssertEqual(g.level, .full)                     // fast enough: stays
        t = feed(&g, ms: 80, frames: 10, from: t)
        XCTAssertEqual(g.level, .full)                     // a short hiccup inside one 30-frame window: no change
        t = feed(&g, ms: 80, frames: 60, from: t)
        XCTAssertEqual(g.level, .lite)
        // Lite is quick (10 ms < 15 ms) but the retry time (30 s) has not passed.
        t = feed(&g, ms: 10, frames: 100, from: t)
        XCTAssertEqual(g.level, .lite)
        t = feed(&g, ms: 10, frames: 250, from: t)
        XCTAssertEqual(g.level, .full)
    }

    func testGovernorBacksOffAfterFailedUpgrade() {
        var g = DetectorQualityGovernor(config: .iOS)
        var t = feed(&g, ms: 80, frames: 40, from: 0)
        XCTAssertEqual(g.level, .lite)
        t = feed(&g, ms: 10, frames: 320, from: t)         // 32 s later: upgrade
        XCTAssertEqual(g.level, .full)
        t = feed(&g, ms: 80, frames: 70, from: t)          // fails within 20 s → retry time doubles to 60 s
        XCTAssertEqual(g.level, .lite)
        t = feed(&g, ms: 10, frames: 400, from: t)         // 40 s: still waiting
        XCTAssertEqual(g.level, .lite)
        t = feed(&g, ms: 10, frames: 300, from: t)
        XCTAssertEqual(g.level, .full)
        // Lite itself too slow for a retry: never upgrades.
        var slow = DetectorQualityGovernor(config: .iOS)
        var ts = feed(&slow, ms: 80, frames: 40, from: 0)
        ts = feed(&slow, ms: 25, frames: 2000, from: ts)
        XCTAssertEqual(slow.level, .lite)
    }

    func testGovernorThermalConstraint() {
        var g = DetectorQualityGovernor(config: .iOS)
        var t = feed(&g, ms: 20, frames: 3, from: 0, constrained: true)
        XCTAssertEqual(g.level, .lite)                     // immediately
        t = feed(&g, ms: 5, frames: 1000, from: t, constrained: true)
        XCTAssertEqual(g.level, .lite)                     // never while constrained
        t = feed(&g, ms: 5, frames: 200, from: t)
        XCTAssertEqual(g.level, .lite)                     // 20 s after it cooled: still waiting
        t = feed(&g, ms: 5, frames: 200, from: t)
        XCTAssertEqual(g.level, .full)
        g.reset()
        XCTAssertEqual(g.level, .full)
    }

    func testAndroidGovernorStartsSmall() {
        var g = DetectorQualityGovernor(config: .android)
        XCTAssertEqual(g.level, .lite)
        var t = feed(&g, ms: 40, frames: 300, from: 0)     // 40 ms at 384×640 → 544×960 would be ≈ 88 ms: stay
        XCTAssertEqual(g.level, .lite)
        t = feed(&g, ms: 20, frames: 36, from: t)          // quick phone: first upgrade needs no waiting time
        XCTAssertEqual(g.level, .full)
        t = feed(&g, ms: 60, frames: 100, from: t)
        XCTAssertEqual(g.level, .full)
        t = feed(&g, ms: 90, frames: 70, from: t)
        XCTAssertEqual(g.level, .lite)
        // The thresholds cannot alternate: lite below the upgrade limit times the cost ratio stays under the downgrade limit.
        XCTAssertLessThan(DetectorQualityGovernor.Config.android.upgradeBelowMs * 2.23,
                          DetectorQualityGovernor.Config.android.downgradeAboveMs)
        XCTAssertLessThan(DetectorQualityGovernor.Config.iOS.upgradeBelowMs * 3.4,
                          DetectorQualityGovernor.Config.iOS.downgradeAboveMs)
    }
}
