import XCTest
@testable import RoadVisCore

/// `docs/TRAINING_API.md` §1–3: frame quality, hard-example selection, sample metadata, retention, model manifest.
final class FrameQualityTests: XCTestCase {
    private func gradient(width: Int = 160, height: Int = 90) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = UInt8(x * 255 / max(1, width - 1))
            }
        }
        return image
    }

    private func checkerboard(width: Int = 160, height: Int = 90, cell: Int = 1) -> GrayImage {
        var image = GrayImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = ((x / cell) + (y / cell)) % 2 == 0 ? 0 : 255
            }
        }
        return image
    }

    func testSharpnessOfFlatImageIsZero() {
        XCTAssertEqual(FrameQuality.sharpness(GrayImage(width: 160, height: 90, fill: 128)), 0, accuracy: 1e-9)
    }

    func testSharpnessOfCheckerboardPassesGate() {
        let config = HardExampleSelector.Config()
        XCTAssertGreaterThanOrEqual(FrameQuality.sharpness(checkerboard()), config.minSharpness)
        XCTAssertGreaterThanOrEqual(FrameQuality.sharpness(checkerboard(cell: 4)), config.minSharpness)
    }

    func testSharpnessOfSmoothGradientIsLow() {
        XCTAssertLessThan(FrameQuality.sharpness(gradient()), 60)
    }

    func testBrightness() {
        XCTAssertEqual(FrameQuality.brightness(GrayImage(width: 10, height: 10, fill: 200)), 200, accuracy: 1e-9)
        XCTAssertEqual(FrameQuality.brightness(checkerboard(width: 10, height: 10)), 127.5, accuracy: 1e-9)
    }

    func testDHashOfIdenticalImagesHasDistanceZero() {
        let a = gradient()
        let b = gradient()
        XCTAssertEqual(FrameQuality.hammingDistance(FrameQuality.dHash(a), FrameQuality.dHash(b)), 0)
    }

    func testDHashOfMirroredGradientDiffers() {
        let image = gradient()
        let distance = FrameQuality.hammingDistance(FrameQuality.dHash(image),
                                                    FrameQuality.dHash(image.mirroredHorizontally()))
        XCTAssertGreaterThan(distance, HardExampleSelector.Config().maxDuplicateHamming)
        // Left-to-right brightening gradient: no "left > right" bit; its mirror: all 64 bits.
        XCTAssertEqual(FrameQuality.dHash(image), 0)
        XCTAssertEqual(FrameQuality.dHash(image.mirroredHorizontally()), UInt64.max)
    }

    func testDHashBitOrderAndHex() {
        // Only the first comparison of row 0 is "left > right" → most significant bit.
        var image = GrayImage(width: 9, height: 8, fill: 10)
        image[0, 0] = 200
        XCTAssertEqual(FrameQuality.dHash(image), 1 << 63)
        XCTAssertEqual(FrameQuality.hexString(1 << 63), "8000000000000000")
        XCTAssertEqual(FrameQuality.hexString(0xf0e1d2c3b4a59687), "f0e1d2c3b4a59687")
        XCTAssertEqual(FrameQuality.hexString(1), "0000000000000001")
        XCTAssertEqual(FrameQuality.hash(fromHex: "f0e1d2c3b4a59687"), 0xf0e1d2c3b4a59687)
    }

    func testGrayFromBGRADownsamplesTo160Wide() {
        let width = 640, height = 360, bytesPerRow = width * 4 + 16
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * bytesPerRow + x * 4
                buffer[p] = 255      // B
                buffer[p + 1] = 0    // G
                buffer[p + 2] = 0    // R
                buffer[p + 3] = 255
            }
        }
        let gray = buffer.withUnsafeBytes { raw in
            FrameQuality.grayFromBGRA(base: raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow)
        }
        XCTAssertEqual(gray.width, 160)
        XCTAssertEqual(gray.height, 90)
        // Pure blue: 0.114 × 255 ≈ 29.
        XCTAssertEqual(Int(gray[80, 45]), 29)
        XCTAssertEqual(FrameQuality.gray(r: 255, g: 255, b: 255), 255)
        XCTAssertEqual(FrameQuality.gray(r: 0, g: 0, b: 0), 0)
    }
}

final class HardExampleSelectorTests: XCTestCase {
    private let goodQuality = FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: 0x0123_4567_89ab_cdef)

    private func track(id: Int, kind: VehicleKind = .car, box: BBox = BBox(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
                       hits: Int = 5, missed: Int = 0, confirmed: Bool = true, confidence: Double = 0.8) -> TrackedObject {
        TrackedObject(id: id, kind: kind, label: kind.rawValue, box: box, confidence: confidence, hits: hits,
                      missed: missed, firstSeen: 0, lastSeen: 0, isConfirmed: confirmed)
    }

    private func frame(_ t: Double, index: Int = 1, speed: Double? = 40, tracks: [TrackedObject] = [],
                       detections: [Detection] = [], flips: Set<Int> = []) -> HardExampleFrame {
        HardExampleFrame(timestamp: t, frameIndex: index, ownSpeedKmh: speed, tracks: tracks, detections: detections,
                         classFlipTrackIDs: flips)
    }

    private func reasons(_ f: HardExampleFrame, next: HardExampleFrame? = nil,
                         previousKinds: [Int: VehicleKind] = [:]) -> [String] {
        HardExampleSelector.reasons(of: f, next: next, previousKinds: previousKinds)
    }

    func testNoReasonOnPlainFrame() {
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1)]), next: frame(0.1, tracks: [track(id: 1)])), [])
    }

    func testMissedDetection() {
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1, missed: 1)])), ["missedDetection"])
        // Box partly outside the frame, too small, or not confirmed: no reason.
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1, box: BBox(x: 0.95, y: 0.4, width: 0.1, height: 0.1),
                                                       missed: 1)])), [])
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1, box: BBox(x: 0.4, y: 0.4, width: 0.02, height: 0.03),
                                                       missed: 1)])), [])
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1, missed: 1, confirmed: false)])), [])
        // Exactly 0.04 high counts.
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 1, box: BBox(x: 0.4, y: 0.4, width: 0.02, height: 0.04),
                                                       missed: 1)])), ["missedDetection"])
    }

    func testShortLived() {
        let tentative = track(id: 9, hits: 2, confirmed: false)
        XCTAssertEqual(reasons(frame(0, tracks: [tentative]), next: frame(0.1)), ["shortLived"])
        // Still alive on the next frame, or more hits: no reason.
        XCTAssertEqual(reasons(frame(0, tracks: [tentative]), next: frame(0.1, tracks: [tentative])), [])
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 9, hits: 3, confirmed: false)]), next: frame(0.1)), [])
        // Confirmed tracks that vanish are not short-lived.
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 9)]), next: frame(0.1)), [])
    }

    func testLowConfidence() {
        // Car threshold at the default slider: 0.30 → [0.25, 0.30) is "low confidence".
        let low = Detection(kind: .car, label: "car", confidence: 0.27, box: BBox(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let tooLow = Detection(kind: .car, label: "car", confidence: 0.22, box: low.box)
        let normal = Detection(kind: .car, label: "car", confidence: 0.31, box: low.box)
        XCTAssertEqual(reasons(frame(0, detections: [low])), ["lowConfidence"])
        XCTAssertEqual(reasons(frame(0, detections: [tooLow, normal])), [])
        // Person threshold 0.40: 0.35 is low.
        let person = Detection(kind: .person, label: "person", confidence: 0.35, box: low.box)
        XCTAssertEqual(reasons(frame(0, detections: [person])), ["lowConfidence"])
    }

    func testClassFlip() {
        let truck = track(id: 3, kind: .truck)
        XCTAssertEqual(reasons(frame(0, tracks: [truck]), previousKinds: [3: .car]), ["classFlip"])
        XCTAssertEqual(reasons(frame(0, tracks: [truck]), previousKinds: [3: .truck]), [])
        XCTAssertEqual(reasons(frame(0, tracks: [truck], flips: [3])), ["classFlip"])
        // Unconfirmed tracks do not count.
        XCTAssertEqual(reasons(frame(0, tracks: [track(id: 3, kind: .truck, confirmed: false)]),
                               next: frame(0.1, tracks: [track(id: 3, kind: .truck, confirmed: false)]),
                               previousKinds: [3: .car]), [])
    }

    func testRandom() {
        XCTAssertEqual(reasons(frame(0, index: 37)), ["random"])
        XCTAssertEqual(reasons(frame(0, index: 137)), ["random"])
        XCTAssertEqual(reasons(frame(0, index: 38)), [])
    }

    func testSeveralReasonsInCanonicalOrder() {
        let low = Detection(kind: .car, label: "car", confidence: 0.26, box: BBox(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let f = frame(0, index: 237, tracks: [track(id: 1, missed: 1)], detections: [low])
        XCTAssertEqual(reasons(f), ["missedDetection", "lowConfidence", "random"])
    }

    func testDecisionRefersToPreviousFrameAndShortLivedUsesMemory() {
        var selector = HardExampleSelector()
        let tentative = track(id: 5, hits: 1, confirmed: false)
        XCTAssertEqual(selector.evaluate(frame(10, tracks: [tentative]), quality: { _ in self.goodQuality }), .discard)
        var asked: Double?
        let decision = selector.evaluate(frame(10.1), quality: { f in
            asked = f.timestamp
            return self.goodQuality
        })
        XCTAssertEqual(decision, HardExampleDecision(keep: true, reasons: ["shortLived"]))
        XCTAssertEqual(asked, 10, "quality is computed for the frame being decided")
        XCTAssertEqual(selector.keptThisTrip, 1)
    }

    func testClassFlipThroughMemory() {
        var selector = HardExampleSelector()
        _ = selector.evaluate(frame(0, tracks: [track(id: 1, kind: .car)]), quality: { _ in nil })
        _ = selector.evaluate(frame(0.1, tracks: [track(id: 1, kind: .truck)]), quality: { _ in nil })
        let decision = selector.evaluate(frame(0.2, tracks: [track(id: 1, kind: .truck)]), quality: { _ in self.goodQuality })
        XCTAssertEqual(decision.reasons, ["classFlip"])
        XCTAssertTrue(decision.keep)
    }

    func testQualityOnlyComputedWhenOtherGatesPass() {
        var selector = HardExampleSelector()
        var calls = 0
        let quality: (HardExampleFrame) -> FrameQualityMetrics? = { _ in
            calls += 1
            return self.goodQuality
        }
        _ = selector.evaluate(frame(0, index: 1), quality: quality)
        _ = selector.evaluate(frame(0.1, index: 2), quality: quality)   // decides frame 1: no reason
        XCTAssertEqual(calls, 0)
        _ = selector.evaluate(frame(0.2, index: 37, speed: 2), quality: quality)
        _ = selector.evaluate(frame(0.3, index: 4), quality: quality)   // decides frame 37: too slow
        XCTAssertEqual(calls, 0)
    }

    func testSpeedGate() {
        var selector = HardExampleSelector()
        let slow = frame(0, index: 37, speed: 4.9)
        XCTAssertFalse(selector.passesGates(slow))
        XCTAssertTrue(selector.passesGates(frame(0, index: 37, speed: nil)))
        XCTAssertTrue(selector.passesGates(frame(0, index: 37, speed: 5)))
        _ = selector.evaluate(slow, quality: { _ in self.goodQuality })
        let decision = selector.evaluate(frame(0.1), quality: { _ in self.goodQuality })
        XCTAssertEqual(decision, HardExampleDecision(keep: false, reasons: ["random"]))
    }

    func testMinIntervalBetweenKeptFrames() {
        var selector = HardExampleSelector()
        func feed(_ t: Double, hash: UInt64) -> HardExampleDecision {
            let metrics = FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: hash)
            _ = selector.evaluate(frame(t, index: 37), quality: { _ in metrics })
            return selector.evaluate(frame(t + 0.05, index: 1), quality: { _ in metrics })
        }
        XCTAssertTrue(feed(100, hash: 0).keep)
        selector.resetMemory()
        XCTAssertFalse(feed(101.9, hash: UInt64.max).keep, "1.9 s after the last kept frame")
        selector.resetMemory()
        XCTAssertTrue(feed(102.0, hash: UInt64.max).keep, "2.0 s after the last kept frame")
    }

    func testPerTripCap() {
        var config = HardExampleSelector.Config()
        config.maxPerTrip = 3
        var selector = HardExampleSelector(config: config)
        var kept = 0
        for i in 0..<10 {
            let t = Double(i) * 3
            // Alternate very different hashes so the duplicate gate never fires.
            let metrics = FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: i % 2 == 0 ? 0 : UInt64.max)
            selector.resetMemory()
            _ = selector.evaluate(frame(t, index: 37), quality: { _ in metrics })
            if selector.evaluate(frame(t + 0.1), quality: { _ in metrics }).keep { kept += 1 }
        }
        XCTAssertEqual(kept, 3)
        XCTAssertEqual(HardExampleSelector.Config().maxPerTrip, 300)
        selector.resetTrip()
        XCTAssertEqual(selector.keptThisTrip, 0)
        XCTAssertTrue(selector.passesGates(frame(100, index: 37)))
    }

    func testQualityGates() {
        let selector = HardExampleSelector()
        XCTAssertTrue(selector.passesQuality(FrameQualityMetrics(sharpness: 60, brightness: 35, dhash: 1)))
        XCTAssertFalse(selector.passesQuality(FrameQualityMetrics(sharpness: 59.9, brightness: 100, dhash: 1)))
        XCTAssertFalse(selector.passesQuality(FrameQualityMetrics(sharpness: 100, brightness: 34.9, dhash: 1)))
        XCTAssertTrue(selector.passesQuality(FrameQualityMetrics(sharpness: 100, brightness: 225, dhash: 1)))
        XCTAssertFalse(selector.passesQuality(FrameQualityMetrics(sharpness: 100, brightness: 225.1, dhash: 1)))
    }

    func testNearDuplicateIsDropped() {
        var selector = HardExampleSelector()
        let first = FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: 0)
        _ = selector.evaluate(frame(0, index: 37), quality: { _ in first })
        XCTAssertTrue(selector.evaluate(frame(0.1), quality: { _ in first }).keep)
        // 6 bits different → duplicate; 7 → kept.
        XCTAssertFalse(selector.passesQuality(FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: 0b11_1111)))
        XCTAssertTrue(selector.passesQuality(FrameQualityMetrics(sharpness: 150, brightness: 100, dhash: 0b111_1111)))
    }

    func testPendingMayBeKept() {
        var selector = HardExampleSelector()
        XCTAssertFalse(selector.pendingMayBeKept())
        _ = selector.evaluate(frame(0, index: 1, tracks: [track(id: 1)]), quality: { _ in nil })
        XCTAssertFalse(selector.pendingMayBeKept(), "no reason and no tentative track")
        _ = selector.evaluate(frame(0.1, index: 2, tracks: [track(id: 2, hits: 1, confirmed: false)]), quality: { _ in nil })
        XCTAssertTrue(selector.pendingMayBeKept(), "the tentative track may die on the next frame")
        _ = selector.evaluate(frame(0.2, index: 37, speed: 1), quality: { _ in nil })
        XCTAssertFalse(selector.pendingMayBeKept(), "below the speed gate")
        _ = selector.evaluate(frame(0.3, index: 37), quality: { _ in nil })
        XCTAssertTrue(selector.pendingMayBeKept())
    }

    func testDefaultConstants() {
        let c = HardExampleSelector.Config()
        XCTAssertEqual(c.minIntervalSeconds, 2.0)
        XCTAssertEqual(c.maxPerTrip, 300)
        XCTAssertEqual(c.minSpeedKmh, 5)
        XCTAssertEqual(c.minSharpness, 60)
        XCTAssertEqual(c.minBrightness, 35)
        XCTAssertEqual(c.maxBrightness, 225)
        XCTAssertEqual(c.maxDuplicateHamming, 6)
        XCTAssertEqual(FrameQuality.analysisWidth, 160)
        XCTAssertEqual(HardExampleReason.allCases.map(\.rawValue),
                       ["missedDetection", "shortLived", "lowConfidence", "classFlip", "random"])
    }
}

final class LearningSampleMetaTests: XCTestCase {
    private func sample(lat: Double? = 41.31, lon: Double? = 69.28) -> LearningSampleMeta {
        let detection = Detection(kind: .car, label: "car", confidence: 0.6234,
                                  box: BBox(x: 0.1, y: 0.2, width: 0.3, height: 0.25))
        let track = TrackedObject(id: 7, kind: .car, label: "car", box: BBox(x: 0.1, y: 0.2, width: 0.3, height: 0.25),
                                  confidence: 0.71, hits: 12, missed: 1, firstSeen: 0, lastSeen: 1, isConfirmed: true)
        return LearningSampleMeta.make(
            id: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", capturedAt: Date(timeIntervalSince1970: 1_795_687_200),
            platform: "ios", appVersion: "1.3", modelName: "RoadVisDetector", modelVersion: "bundled-yolo11s-960x544",
            imageWidth: 960, imageHeight: 540, reasons: ["missedDetection"], speedKmh: 42.04, latitude: lat,
            longitude: lon, detections: [detection], tracks: [track],
            quality: FrameQualityMetrics(sharpness: 140.24, brightness: 96, dhash: 0xf0e1d2c3b4a59687))
    }

    func testEncodedKeysMatchContract() throws {
        let data = try sample().encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "capturedAt", "platform", "appVersion", "model", "image", "reasons",
                                          "speedKmh", "lat", "lon", "detections", "tracks", "quality"])
        let model = try XCTUnwrap(object["model"] as? [String: Any])
        XCTAssertEqual(Set(model.keys), ["name", "version"])
        let image = try XCTUnwrap(object["image"] as? [String: Any])
        XCTAssertEqual(Set(image.keys), ["width", "height", "orientation"])
        XCTAssertEqual(image["orientation"] as? String, "landscape")
        let detections = try XCTUnwrap(object["detections"] as? [[String: Any]])
        XCTAssertEqual(Set(detections[0].keys), ["label", "kind", "confidence", "box"])
        XCTAssertEqual((detections[0]["box"] as? [Double])?.count, 4)
        let tracks = try XCTUnwrap(object["tracks"] as? [[String: Any]])
        XCTAssertEqual(Set(tracks[0].keys), ["id", "kind", "confidence", "hits", "missed", "confirmed", "box"])
        XCTAssertEqual(tracks[0]["confirmed"] as? Bool, true)
        let quality = try XCTUnwrap(object["quality"] as? [String: Any])
        XCTAssertEqual(Set(quality.keys), ["sharpness", "brightness", "dhash"])
        XCTAssertEqual(quality["dhash"] as? String, "f0e1d2c3b4a59687")
        XCTAssertEqual(object["capturedAt"] as? String, "2026-11-26T10:00:00Z")
        XCTAssertEqual(object["platform"] as? String, "ios")
        XCTAssertEqual(object["speedKmh"] as? Double, 42.0)
    }

    func testLocationOmittedWhenOff() throws {
        let data = try sample(lat: nil, lon: nil).encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["lat"])
        XCTAssertNil(object["lon"])
        XCTAssertNotNil(object["speedKmh"])
    }

    func testRoundTrip() throws {
        let original = sample()
        XCTAssertEqual(try LearningSampleMeta.decode(original.encoded()), original)
        XCTAssertEqual(LearningSampleMeta.date(fromTimestamp: original.capturedAt), Date(timeIntervalSince1970: 1_795_687_200))
    }

    func testDecodesContractExample() throws {
        let json = """
        {"id": "uuid", "capturedAt": "2026-11-26T10:00:00Z", "platform": "ios", "appVersion": "1.3",
         "model": {"name": "RoadVisDetector", "version": "bundled-yolo11s-960x544"},
         "image": {"width": 960, "height": 540, "orientation": "landscape"},
         "reasons": ["missedDetection"], "speedKmh": 42.0, "lat": 41.31, "lon": 69.28,
         "detections": [{"label": "car", "kind": "car", "confidence": 0.62, "box": [0.1, 0.2, 0.3, 0.4]}],
         "tracks": [{"id": 7, "kind": "car", "confidence": 0.71, "hits": 12, "missed": 1, "confirmed": true, "box": [0.1, 0.2, 0.3, 0.4]}],
         "quality": {"sharpness": 140.2, "brightness": 96.0, "dhash": "f0e1d2c3b4a59687"}}
        """
        let meta = try LearningSampleMeta.decode(Data(json.utf8))
        XCTAssertEqual(meta.tracks.first?.hits, 12)
        XCTAssertEqual(meta.quality.dhash, "f0e1d2c3b4a59687")
    }
}

final class LearningStorePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let mb: Int64 = 1024 * 1024

    func testAgeLimit() {
        let policy = LearningStorePolicy()
        let samples = [
            LearningStoredSample(id: "old", createdAt: now.addingTimeInterval(-15 * 86400), bytes: 1),
            LearningStoredSample(id: "new", createdAt: now.addingTimeInterval(-13 * 86400), bytes: 1),
        ]
        XCTAssertEqual(policy.plan(for: samples, now: now), LearningRetentionPlan(expired: ["old"]))
    }

    func testSizeCapDeletesOldestFirst() {
        let policy = LearningStorePolicy(limitMB: 100)
        let samples = (0..<6).map { i in
            LearningStoredSample(id: "s\(i)", createdAt: now.addingTimeInterval(Double(-i) * 60), bytes: 30 * mb)
        }
        // 180 MB → drop the 3 oldest (s5, s4, s3) to reach 90 MB.
        XCTAssertEqual(policy.plan(for: samples, now: now).overLimit, ["s5", "s4", "s3"])
        XCTAssertTrue(LearningStorePolicy(limitMB: 300).plan(for: samples, now: now).isEmpty)
    }

    func testLimitChoices() {
        XCTAssertEqual(LearningStorePolicy.limitChoicesMB, [100, 300, 1000])
        XCTAssertEqual(LearningStorePolicy.defaultLimitMB, 300)
        XCTAssertEqual(LearningStorePolicy.normalizedLimitMB(42), 300)
        XCTAssertEqual(LearningStorePolicy.normalizedLimitMB(1000), 1000)
        XCTAssertEqual(LearningStorePolicy.defaultMaxAgeSeconds, 14 * 86400)
    }

    func testDeleteAfterUpload() {
        XCTAssertTrue(LearningStorePolicy.deleteAfterUpload(statusCode: 201))
        XCTAssertTrue(LearningStorePolicy.deleteAfterUpload(statusCode: 409))
        XCTAssertFalse(LearningStorePolicy.deleteAfterUpload(statusCode: 500))
        XCTAssertEqual(LearningUploadOutcome(statusCode: 201), .uploaded)
        XCTAssertEqual(LearningUploadOutcome(statusCode: 409), .uploaded)
        XCTAssertEqual(LearningUploadOutcome(statusCode: 401), .unauthorized)
        XCTAssertEqual(LearningUploadOutcome(statusCode: 413), .rejected)
        XCTAssertEqual(LearningUploadOutcome(statusCode: 429), .retryLater)
        XCTAssertTrue(LearningUploadOutcome(statusCode: 422).deletesSample)
        XCTAssertTrue(LearningUploadOutcome(statusCode: 503).stopsRun)
    }

    func testBackoffSchedule() {
        XCTAssertEqual(LearningUploadSchedule.backoffSeconds(failures: 0), 0)
        let minutes = (1...9).map { LearningUploadSchedule.backoffSeconds(failures: $0) / 60 }
        XCTAssertEqual(minutes, [1, 2, 4, 8, 16, 32, 60, 60, 60])
        var schedule = LearningUploadSchedule()
        XCTAssertTrue(schedule.mayRun(now: now))
        schedule.recordFailure(now: now)
        XCTAssertFalse(schedule.mayRun(now: now.addingTimeInterval(59)))
        XCTAssertTrue(schedule.mayRun(now: now.addingTimeInterval(60)))
        schedule.recordFailure(now: now)
        XCTAssertFalse(schedule.mayRun(now: now.addingTimeInterval(119)))
        schedule.recordSuccess()
        XCTAssertTrue(schedule.mayRun(now: now))
        XCTAssertEqual(LearningUploadSchedule.batchSize, 20)
    }
}

final class ModelManifestTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)

    private var manifestJSON: String {
        """
        {"version": "2026-12-01-1", "createdAt": "2026-12-01T03:00:00Z", "baseModel": "yolo11s",
         "metrics": {"testImages": 812, "map50": 0.71, "precision": 0.80, "recall": 0.66, "previous": {"map50": 0.68}},
         "ios": {"landscape": {"name": "RoadVisDetector", "files": [
                    {"path": "Manifest.json", "sha256": "\(sha)", "size": 617},
                    {"path": "Data/com.apple.CoreML/model.mlmodel", "sha256": "\(sha)", "size": 1000}]},
                 "portrait": {"name": "RoadVisDetectorPortrait", "files": [
                    {"path": "Manifest.json", "sha256": "\(sha)", "size": 617}]}},
         "android": {"file": {"path": "yolo-roadvis.onnx", "sha256": "\(sha)", "size": 11000000},
                     "inputs": [[544, 960], [960, 544], [384, 640], [640, 384]]},
         "extra": "ignored"}
        """
    }

    func testDecodesContractManifest() throws {
        let manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        XCTAssertEqual(manifest.version, "2026-12-01-1")
        XCTAssertEqual(manifest.metrics?.map50, 0.71)
        XCTAssertEqual(manifest.metrics?.previous?.map50, 0.68)
        XCTAssertEqual(manifest.iosPackage(landscape: true)?.name, "RoadVisDetector")
        XCTAssertEqual(manifest.iosPackage(landscape: false)?.files.count, 1)
        XCTAssertEqual(manifest.android?.inputs?.count, 4)
        XCTAssertTrue(manifest.isUsableForIOS)
    }

    func testUnsafeManifestIsRejected() throws {
        var manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        manifest.ios?.landscape?.files[0].path = "../../etc/passwd"
        XCTAssertFalse(manifest.isUsableForIOS)
        manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        manifest.ios?.portrait = nil
        XCTAssertFalse(manifest.isUsableForIOS)
        manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        manifest.version = "../x"
        XCTAssertFalse(manifest.isUsableForIOS)
        manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        manifest.ios?.landscape?.files[0].sha256 = "xyz"
        XCTAssertFalse(manifest.isUsableForIOS)
    }

    func testPathRules() {
        XCTAssertTrue(ModelUpdatePolicy.isSafeRelativePath("Data/com.apple.CoreML/weights/weight.bin"))
        XCTAssertFalse(ModelUpdatePolicy.isSafeRelativePath("/abs"))
        XCTAssertFalse(ModelUpdatePolicy.isSafeRelativePath("a//b"))
        XCTAssertFalse(ModelUpdatePolicy.isSafeRelativePath("a/./b"))
        XCTAssertFalse(ModelUpdatePolicy.isSafeRelativePath(""))
        XCTAssertEqual(ModelUpdatePolicy.packageRelativePath("RoadVisDetector.mlpackage/Manifest.json",
                                                             packageName: "RoadVisDetector"), "Manifest.json")
        XCTAssertEqual(ModelUpdatePolicy.packageRelativePath("Manifest.json", packageName: "RoadVisDetector"),
                       "Manifest.json")
        XCTAssertEqual(ModelUpdatePolicy.iosFilePath("Manifest.json", packageName: "RoadVisDetector"),
                       "RoadVisDetector.mlpackage/Manifest.json")
        XCTAssertEqual(ModelUpdatePolicy.iosFilePath("RoadVisDetectorPortrait.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                                                     packageName: "RoadVisDetectorPortrait"),
                       "RoadVisDetectorPortrait.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        let url = ModelUpdatePolicy.fileURL(base: URL(string: "https://trafficcounter.uz/roadvis/")!,
                                            version: "2026-12-01-1", path: "Data/com.apple.CoreML/model file.mlmodel")
        XCTAssertEqual(url?.absoluteString,
                       "https://trafficcounter.uz/roadvis/api/v1/model/2026-12-01-1/files/Data/com.apple.CoreML/model%20file.mlmodel")
    }

    func testPublishedClassNamesMapToKinds() {
        let kinds = ModelUpdatePolicy.publishedClassNames.map { VehicleKind(label: $0) }
        XCTAssertEqual(kinds, [.car, .truck, .bus, .motorcycle, .bicycle, .person, .trafficLight, .stopSign])
    }

    func testShouldCheckOncePerDayOnWiFi() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(ModelUpdatePolicy.shouldCheck(enabled: true, onWiFi: true, lastCheck: nil, now: now))
        XCTAssertFalse(ModelUpdatePolicy.shouldCheck(enabled: true, onWiFi: false, lastCheck: nil, now: now))
        XCTAssertFalse(ModelUpdatePolicy.shouldCheck(enabled: false, onWiFi: true, lastCheck: nil, now: now))
        XCTAssertFalse(ModelUpdatePolicy.shouldCheck(enabled: true, onWiFi: true,
                                                     lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(ModelUpdatePolicy.shouldCheck(enabled: true, onWiFi: true,
                                                    lastCheck: now.addingTimeInterval(-86400), now: now))
    }

    func testShouldDownloadSwitchAndRevert() throws {
        let manifest = try ModelManifest.decode(Data(manifestJSON.utf8))
        XCTAssertTrue(ModelUpdatePolicy.shouldDownload(manifest, activeVersion: nil, badVersions: []))
        XCTAssertFalse(ModelUpdatePolicy.shouldDownload(manifest, activeVersion: "2026-12-01-1", badVersions: []))
        XCTAssertFalse(ModelUpdatePolicy.shouldDownload(manifest, activeVersion: nil, badVersions: ["2026-12-01-1"]))
        XCTAssertFalse(ModelUpdatePolicy.shouldDownload(manifest, activeVersion: nil, badVersions: [],
                                                        installedVersions: ["2026-12-01-1"]))
        XCTAssertTrue(ModelUpdatePolicy.shouldSwitch(verifiedFiles: 3, expectedFiles: 3, compiledPackages: 2,
                                                     version: "v1", badVersions: []))
        XCTAssertFalse(ModelUpdatePolicy.shouldSwitch(verifiedFiles: 2, expectedFiles: 3, compiledPackages: 2,
                                                      version: "v1", badVersions: []))
        XCTAssertFalse(ModelUpdatePolicy.shouldSwitch(verifiedFiles: 3, expectedFiles: 3, compiledPackages: 1,
                                                      version: "v1", badVersions: []))
        XCTAssertEqual(ModelUpdatePolicy.activeVersion(stored: "v1", badVersions: [], isInstalled: { _ in true }), "v1")
        XCTAssertNil(ModelUpdatePolicy.activeVersion(stored: "v1", badVersions: ["v1"], isInstalled: { _ in true }))
        XCTAssertNil(ModelUpdatePolicy.activeVersion(stored: "v1", badVersions: [], isInstalled: { _ in false }))
    }

    func testHealthMonitorRevertsAfter30SilentSecondsOfDriving() {
        var monitor = ModelHealthMonitor()
        var reverted = false
        var t: Double = 0
        while t < 29.9 {
            reverted = monitor.record(timestamp: t, hadOutput: false, driving: true)
            XCTAssertFalse(reverted)
            t += 0.1
        }
        // An output resets the clock.
        XCTAssertFalse(monitor.record(timestamp: t, hadOutput: true, driving: true))
        XCTAssertEqual(monitor.silentSeconds, 0)
        // Standing still or long frame gaps do not count.
        var stopped = ModelHealthMonitor()
        for i in 0..<400 { XCTAssertFalse(stopped.record(timestamp: Double(i) * 0.1, hadOutput: false, driving: false)) }
        var gaps = ModelHealthMonitor()
        for i in 0..<40 { XCTAssertFalse(gaps.record(timestamp: Double(i) * 5, hadOutput: false, driving: true)) }
        var silent = ModelHealthMonitor()
        for i in 0...301 { reverted = silent.record(timestamp: Double(i) * 0.1, hadOutput: false, driving: true) }
        XCTAssertTrue(reverted)
    }
}
