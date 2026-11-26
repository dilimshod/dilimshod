import XCTest
@testable import RoadVisCore

// MARK: - Synthetic road images

private enum SyntheticRoad {
    static let width = 160
    static let height = 284
    static let horizon = 0.42

    /// Grey road with markings converging to (vanishingX, horizon). Lines are given by their x at the bottom row
    /// (pixels). `dashed` leaves gaps on the right line.
    static func image(leftBottom: Double?, rightBottom: Double?, vanishingX: Double = 80, road: UInt8 = 95,
                      marking: UInt8 = 225, dashed: Bool = true, noise: Int = 6, seed: UInt64 = 1) -> LaneImage {
        var img = LaneImage(width: width, height: height, fill: road)
        var rng = seed
        func rand() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(2 * noise + 1)) - noise
        }
        // Sky above the horizon, bright (must be ignored).
        let hy = Int(Double(height) * horizon)
        for y in 0..<height {
            for x in 0..<width {
                let base = y < hy ? 200 : Int(road)
                img[x, y] = UInt8(clamping: base + (noise > 0 ? rand() : 0))
            }
        }
        let yb = Double(height - 1)
        let yh = Double(height) * horizon
        for (index, bottom) in [leftBottom, rightBottom].enumerated() {
            guard let bottom else { continue }
            for y in (hy + 1)..<height {
                let t = (Double(y) - yh) / (yb - yh)          // 0 at horizon, 1 at bottom
                if dashed && index == 1 && (Int(t * 12) % 2 == 1) { continue }
                let x = vanishingX + (bottom - vanishingX) * t
                let halfWidth = max(0.6, 2.8 * t)
                let x0 = Int((x - halfWidth).rounded()), x1 = Int((x + halfWidth).rounded())
                guard x0 <= width - 1, x1 >= 0 else { continue }
                for xx in max(0, x0)...min(width - 1, x1) { img[xx, y] = marking }
            }
        }
        return img
    }
}

final class LaneDetectorTests: XCTestCase {
    func testDetectsBothLinesCentred() {
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for i in 0..<6 {
            estimate = detector.process(SyntheticRoad.image(leftBottom: 10, rightBottom: 150, seed: UInt64(i + 1)),
                                        timestamp: Double(i) * 0.2)
        }
        let left = try! XCTUnwrap(estimate.left)
        let right = try! XCTUnwrap(estimate.right)
        // Expected x at the reference row (0.96 · height).
        let t = (0.96 * 284 - 0.42 * 284) / (283 - 0.42 * 284)
        XCTAssertEqual(left.x(atY: estimate.referenceY), (80 + (10 - 80) * t) / 160, accuracy: 0.03)
        XCTAssertEqual(right.x(atY: estimate.referenceY), (80 + (150 - 80) * t) / 160, accuracy: 0.03)
        XCTAssertGreaterThan(estimate.leftConfidence, 0.5)
        XCTAssertGreaterThan(estimate.rightConfidence, 0.3)   // dashed
        XCTAssertEqual(estimate.egoOffset ?? 99, 0, accuracy: 0.1)
        XCTAssertEqual(estimate.laneCenterX ?? 0, 0.5, accuracy: 0.03)
        // Lines are drawn up toward the horizon.
        XCTAssertLessThan(left.topY, 0.5)
    }

    func testOffsetTowardLeftLine() {
        // Car drifted left: the left line is close to the image centre.
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for i in 0..<6 {
            estimate = detector.process(SyntheticRoad.image(leftBottom: 55, rightBottom: 215, seed: UInt64(i + 7)),
                                        timestamp: Double(i) * 0.2)
        }
        XCTAssertNotNil(estimate.left)
        let offset = try! XCTUnwrap(estimate.egoOffset)
        XCTAssertLessThan(offset, -0.6)
        XCTAssertGreaterThan(offset, -1.0)
    }

    func testNoMarkingsGivesNoLines() {
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for i in 0..<5 {
            estimate = detector.process(SyntheticRoad.image(leftBottom: nil, rightBottom: nil, noise: 10,
                                                            seed: UInt64(i + 3)), timestamp: Double(i) * 0.2)
        }
        XCTAssertNil(estimate.left)
        XCTAssertNil(estimate.right)
        XCTAssertNil(estimate.egoOffset)
        XCTAssertEqual(estimate.confidence, 0)
    }

    func testHorizontalStripeIsRejected() {
        // A stop line / shadow edge across the road must not become a lane line.
        var img = SyntheticRoad.image(leftBottom: nil, rightBottom: nil, noise: 0)
        for y in 220..<226 { for x in 0..<160 { img[x, y] = 230 } }
        let fits = LaneDetector.detectLines(in: img, config: LaneDetector.Config())
        XCTAssertNil(fits.left)
        XCTAssertNil(fits.right)
    }

    func testSingleLineUsesLaneWidth() {
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for i in 0..<5 {
            estimate = detector.process(SyntheticRoad.image(leftBottom: 10, rightBottom: nil, seed: UInt64(i + 11)),
                                        timestamp: Double(i) * 0.2)
        }
        XCTAssertNotNil(estimate.left)
        XCTAssertNil(estimate.right)
        XCTAssertNotNil(estimate.egoOffset)
        XCTAssertLessThan(estimate.confidence, estimate.leftConfidence)   // one line → reduced overall confidence
    }

    func testConfidenceDecaysWhenMarkingsDisappear() {
        let detector = LaneDetector()
        for i in 0..<5 {
            detector.process(SyntheticRoad.image(leftBottom: 10, rightBottom: 150, seed: UInt64(i + 1)), timestamp: Double(i) * 0.2)
        }
        let before = detector.process(SyntheticRoad.image(leftBottom: 10, rightBottom: 150), timestamp: 1.2).leftConfidence
        var after = 1.0
        for i in 0..<4 {
            after = detector.process(SyntheticRoad.image(leftBottom: nil, rightBottom: nil, seed: UInt64(i + 50)),
                                     timestamp: 1.4 + Double(i) * 0.2).leftConfidence
        }
        XCTAssertLessThan(after, before * 0.5)
    }

    func testYellowMarkingFromBGRA() {
        // 640×1136 BGRA: grey road, a YELLOW left line and a white right line.
        let w = 640, h = 1136, bpr = w * 4
        var buffer = [UInt8](repeating: 0, count: bpr * h)
        let hy = Double(h) * 0.42
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let v: UInt8 = Double(y) < hy ? 190 : 100
                buffer[i] = v; buffer[i + 1] = v; buffer[i + 2] = v; buffer[i + 3] = 255
            }
            guard Double(y) > hy else { continue }
            let t = (Double(y) - hy) / (Double(h - 1) - hy)
            for (bottom, yellow) in [(40.0, true), (600.0, false)] {
                let x = 320 + (bottom - 320) * t
                let half = max(2, 11 * t)
                for xx in Int(x - half)...Int(x + half) where xx >= 0 && xx < w {
                    let i = y * bpr + xx * 4
                    if yellow { buffer[i] = 30; buffer[i + 1] = 190; buffer[i + 2] = 220 }   // B G R
                    else { buffer[i] = 235; buffer[i + 1] = 235; buffer[i + 2] = 235 }
                }
            }
        }
        let image = buffer.withUnsafeBytes { raw in
            LaneImage.fromBGRA(base: raw.baseAddress!, width: w, height: h, bytesPerRow: bpr, targetWidth: 160, roiTop: 0.4)
        }
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 284)
        XCTAssertGreaterThan(LaneImage.markingValue(r: 220, g: 190, b: 30), 200)   // yellow lifted
        XCTAssertLessThan(LaneImage.markingValue(r: 100, g: 100, b: 100), 110)
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for i in 0..<4 { estimate = detector.process(image, timestamp: Double(i) * 0.2) }
        XCTAssertNotNil(estimate.left, "yellow line should be detected")
        XCTAssertNotNil(estimate.right)
        XCTAssertEqual(estimate.egoOffset ?? 99, 0, accuracy: 0.15)
    }
}

extension LaneDetectorTests {
    /// Portrait BGRA road frame (asphalt with noise, bright sky) with two solid white lines converging at the horizon,
    /// through the same path as the app (`fromBGRA` with the horizon ROI → `LaneDetector.process` at ≈ 5 Hz).
    func testSyntheticRoadWithTwoWhiteLinesYieldsConfidentLines() {
        let w = 720, h = 1280, bpr = w * 4
        var buffer = [UInt8](repeating: 255, count: bpr * h)
        var rng: UInt64 = 7
        let hy = Double(h) * 0.42
        for y in 0..<h {
            for x in 0..<w {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int((rng >> 33) % 17) - 8
                let base = Double(y) < hy ? 185 : 92
                let v = UInt8(clamping: base + noise)
                let i = y * bpr + x * 4
                buffer[i] = v; buffer[i + 1] = v; buffer[i + 2] = v
            }
            guard Double(y) > hy else { continue }
            let t = (Double(y) - hy) / (Double(h - 1) - hy)
            for bottom in [0.1 * Double(w), 0.9 * Double(w)] {
                let x = 0.5 * Double(w) + (bottom - 0.5 * Double(w)) * t
                let half = max(1.5, 10 * t)
                for xx in Int(x - half)...Int(x + half) where xx >= 0 && xx < w {
                    let i = y * bpr + xx * 4
                    buffer[i] = 232; buffer[i + 1] = 232; buffer[i + 2] = 232
                }
            }
        }
        let detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for frame in 0..<8 {
            let image = buffer.withUnsafeBytes { raw in
                LaneImage.fromBGRA(base: raw.baseAddress!, width: w, height: h, bytesPerRow: bpr,
                                   targetWidth: 160, roiTop: 0.40)
            }
            estimate = detector.process(image, timestamp: Double(frame) * 0.2)
        }
        let left = try! XCTUnwrap(estimate.left)
        let right = try! XCTUnwrap(estimate.right)
        XCTAssertGreaterThanOrEqual(estimate.leftConfidence, 0.5)
        XCTAssertGreaterThanOrEqual(estimate.rightConfidence, 0.5)
        XCTAssertGreaterThanOrEqual(estimate.confidence, 0.5)
        XCTAssertLessThan(left.x(atY: 0.96), 0.3)
        XCTAssertGreaterThan(right.x(atY: 0.96), 0.7)
        XCTAssertEqual(estimate.laneCenterX ?? 0, 0.5, accuracy: 0.04)
    }
}

final class LaneDepartureTests: XCTestCase {
    private func estimate(offset: Double, t: TimeInterval, confidence: Double = 0.8) -> LaneEstimate {
        let line = LaneLine(bottomX: 0.1, bottomY: 0.96, topX: 0.45, topY: 0.44)
        return LaneEstimate(left: line, right: line, leftConfidence: confidence, rightConfidence: confidence,
                            laneCenterX: 0.5, egoOffset: offset, confidence: confidence, referenceY: 0.96, timestamp: t)
    }

    func testDepartureAfterHoldAtSpeed() {
        var d = LaneDepartureDetector()
        var fired: [LaneSide] = []
        for i in 0...10 {
            let t = Double(i) * 0.1
            if let side = d.update(estimate(offset: -0.75, t: t), speedKmh: 60, timestamp: t) { fired.append(side) }
        }
        XCTAssertEqual(fired, [.left])
        XCTAssertEqual(d.activeSide, .left)
    }

    func testNoDepartureBelowMinSpeedOrShortDrift() {
        var d = LaneDepartureDetector()
        for i in 0...10 {
            let t = Double(i) * 0.1
            XCTAssertNil(d.update(estimate(offset: 0.8, t: t), speedKmh: 30, timestamp: t))
        }
        var d2 = LaneDepartureDetector()
        XCTAssertNil(d2.update(estimate(offset: 0.8, t: 0), speedKmh: 60, timestamp: 0))
        XCTAssertNil(d2.update(estimate(offset: 0.8, t: 0.2), speedKmh: 60, timestamp: 0.2))
        XCTAssertNil(d2.update(estimate(offset: 0.1, t: 0.3), speedKmh: 60, timestamp: 0.3))   // back in lane
        XCTAssertNil(d2.update(estimate(offset: 0.8, t: 0.5), speedKmh: 60, timestamp: 0.5))
    }

    func testLowConfidenceLineIgnored() {
        var d = LaneDepartureDetector()
        for i in 0...10 {
            let t = Double(i) * 0.1
            XCTAssertNil(d.update(estimate(offset: -0.8, t: t, confidence: 0.2), speedKmh: 70, timestamp: t))
        }
    }

    func testCooldownAndRearm() {
        var d = LaneDepartureDetector()
        var count = 0
        var t = 0.0
        func drive(_ offset: Double, seconds: Double) {
            let end = t + seconds
            while t < end {
                if d.update(estimate(offset: offset, t: t), speedKmh: 60, timestamp: t) != nil { count += 1 }
                t += 0.1
            }
        }
        drive(0.8, seconds: 1)     // warn
        drive(0.8, seconds: 2)     // stays over: no repeat (not re-armed)
        drive(0.0, seconds: 1)     // back to centre: re-armed, but cooldown (5 s) still running
        drive(0.8, seconds: 0.6)
        XCTAssertEqual(count, 1)
        drive(0.0, seconds: 2)
        drive(0.8, seconds: 1)     // after cooldown
        XCTAssertEqual(count, 2)
    }
}

final class SignAnnouncerTests: XCTestCase {
    func testFeatureThresholdsAndDedupe() {
        let a = SignAnnouncer()
        let crossing = FeatureAhead(id: "node/1", kind: .pedestrianCrossing, distanceAhead: 150)
        // Urban (40 km/h): 100 m threshold.
        XCTAssertNil(a.update(features: [crossing], speedKmh: 40, timestamp: 0))
        var near = crossing
        near.distanceAhead = 95
        XCTAssertEqual(a.update(features: [near], speedKmh: 40, timestamp: 1),
                       .feature(kind: .pedestrianCrossing, distance: 95, id: "node/1"))
        near.distanceAhead = 60
        XCTAssertNil(a.update(features: [near], speedKmh: 40, timestamp: 2), "announced once per id")
        // Rural speed: 200 m threshold, speed camera 400 m.
        let cam = FeatureAhead(id: "node/2", kind: .speedCamera, distanceAhead: 380)
        XCTAssertEqual(a.update(features: [cam], speedKmh: 90, timestamp: 3),
                       .feature(kind: .speedCamera, distance: 380, id: "node/2"))
        // POIs are never announced.
        XCTAssertNil(a.update(features: [FeatureAhead(id: "node/3", kind: .fuel, distanceAhead: 50)], speedKmh: 40, timestamp: 4))
        // Too close → skipped (not announced late).
        XCTAssertNil(a.update(features: [FeatureAhead(id: "node/4", kind: .school, distanceAhead: 5)], speedKmh: 40, timestamp: 5))
    }

    func testFeatureAheadFromRouteFeatures() {
        let f = RouteFeature(id: "node/9", kind: .stopSign, coordinate: GeoPoint(latitude: 41, longitude: 69),
                             distanceAlongRoute: 1200, offsetFromRoute: 3, name: nil, tags: [:])
        let ahead = FeatureAhead.from(features: [f], distanceAlong: 1100)
        XCTAssertEqual(ahead, [FeatureAhead(id: "node/9", kind: .stopSign, distanceAhead: 100)])
        XCTAssertTrue(FeatureAhead.from(features: [f], distanceAlong: 100).isEmpty)
    }

    func testSpeedLimitNeedsStableValue() {
        let a = SignAnnouncer()
        XCTAssertNil(a.update(currentLimitKmh: 60, timestamp: 0))
        XCTAssertNil(a.update(currentLimitKmh: 40, timestamp: 1))      // flap restarts the timer
        XCTAssertNil(a.update(currentLimitKmh: 40, timestamp: 3.5))
        XCTAssertEqual(a.update(currentLimitKmh: 40, timestamp: 4.1), .speedLimit(kmh: 40))
        XCTAssertNil(a.update(currentLimitKmh: 40, timestamp: 10))
        XCTAssertNil(a.update(currentLimitKmh: nil, timestamp: 11))    // unknown keeps the announced value
        XCTAssertNil(a.update(currentLimitKmh: 40, timestamp: 20))
    }

    func testUpcomingSpeedLimitChange() {
        let edges = [RouteEdgeAttributes(startDistance: 0, endDistance: 500, speedLimitKmh: 60),
                     RouteEdgeAttributes(startDistance: 500, endDistance: 900, speedLimitKmh: 60),
                     RouteEdgeAttributes(startDistance: 900, endDistance: 1500, speedLimitKmh: 40)]
        let change = SignAnnouncer.nextSpeedLimitChange(edges: edges, distanceAlong: 780, lookahead: 200)
        XCTAssertEqual(change?.kmh, 40)
        XCTAssertEqual(change?.distanceAhead ?? 0, 120, accuracy: 0.01)
        let a = SignAnnouncer()
        XCTAssertNil(a.update(edges: edges, distanceAlong: 600, speedKmh: 50))   // 300 m > 150 m urban
        XCTAssertEqual(a.update(edges: edges, distanceAlong: 780, speedKmh: 50), .speedLimitAhead(kmh: 40, distance: 120))
        XCTAssertNil(a.update(edges: edges, distanceAlong: 800, speedKmh: 50))
    }

    func testCameraStopSign() {
        let a = SignAnnouncer()
        XCTAssertEqual(a.cameraStopSign(trackID: 5, timestamp: 0), .cameraStopSign(trackID: 5))
        XCTAssertNil(a.cameraStopSign(trackID: 5, timestamp: 1))
        XCTAssertNil(a.cameraStopSign(trackID: 6, timestamp: 5))      // cooldown
        XCTAssertEqual(a.cameraStopSign(trackID: 7, timestamp: 30), .cameraStopSign(trackID: 7))
        // After an OSM STOP announcement the camera does not repeat it.
        _ = a.update(features: [FeatureAhead(id: "s", kind: .stopSign, distanceAhead: 80)], speedKmh: 30, timestamp: 60)
        XCTAssertNil(a.cameraStopSign(trackID: 8, timestamp: 65))
    }
}

final class CoachRulesTests: XCTestCase {
    func testPriorityAndGlobalGap() {
        var r = CoachRules()
        r.offer(.roadSign(kind: .school, distanceMeters: 150), now: 0)
        r.offer(.laneDeparture(side: .left), now: 0)
        r.offer(.greenLightGo, now: 0)
        XCTAssertEqual(r.next(now: 0), .laneDeparture(side: .left))
        XCTAssertNil(r.next(now: 1), "global gap")
        XCTAssertEqual(r.next(now: 3.1), .roadSign(kind: .school, distanceMeters: 150))
        XCTAssertNil(r.next(now: 6.5), "green hint expired (ttl 3 s)")
    }

    func testCollisionBypassesGap() {
        var r = CoachRules()
        r.offer(.speedLimit(kmh: 60), now: 0)
        XCTAssertEqual(r.next(now: 0), .speedLimit(kmh: 60))
        r.offer(.collisionRisk, now: 0.5)
        XCTAssertEqual(r.next(now: 0.5), .collisionRisk)
        r.offer(.collisionRisk, now: 1)
        XCTAssertNil(r.next(now: 1), "collision has its own cooldown")
        r.offer(.collisionRisk, now: 5.6)
        XCTAssertEqual(r.next(now: 5.6), .collisionRisk)
    }

    func testPerCategoryCooldown() {
        var r = CoachRules()
        r.offer(.keepDistance(recommendedMeters: 30), now: 0)
        XCTAssertNotNil(r.next(now: 0))
        r.offer(.keepDistance(recommendedMeters: 30), now: 5)
        XCTAssertNil(r.next(now: 5))
        r.offer(.keepDistance(recommendedMeters: 30), now: 12.5)
        XCTAssertEqual(r.next(now: 12.5), .keepDistance(recommendedMeters: 30))
    }

    func testSpokenDistanceRounding() {
        XCTAssertEqual(CoachMessage.spokenDistance(94), 90)
        XCTAssertEqual(CoachMessage.spokenDistance(4), 10)
        XCTAssertEqual(CoachMessage.spokenDistance(176), 200)
        XCTAssertEqual(CoachMessage.spokenDistance(380), 400)
    }

    func testUrgency() {
        XCTAssertEqual(CoachMessage.collisionRisk.urgency, .high)
        XCTAssertEqual(CoachMessage.redLightAhead.urgency, .high)
        XCTAssertEqual(CoachMessage.greenLightGo.urgency, .low)
        XCTAssertTrue(CoachCategory.collision > CoachCategory.pedestrian)
        XCTAssertTrue(CoachCategory.pedestrian > CoachCategory.redLight)
        XCTAssertTrue(CoachCategory.collision > CoachCategory.redLight)
        XCTAssertTrue(CoachCategory.redLight > CoachCategory.laneDeparture)
        XCTAssertTrue(CoachCategory.laneDeparture > CoachCategory.tailgating)
        XCTAssertTrue(CoachCategory.tailgating > CoachCategory.sign)
        XCTAssertTrue(CoachCategory.sign > CoachCategory.greenLight)
    }
}

final class PedestrianCoachTests: XCTestCase {
    private func hazard(_ id: Int, _ level: PedestrianHazardLevel, distance: Double = 12,
                        inLane: Bool = true) -> PedestrianHazard {
        PedestrianHazard(trackID: id, box: BBox(x: 0.48, y: 0.5, width: 0.04, height: 0.15), level: level,
                         distanceMeters: distance, inOwnLane: inLane, onRoadway: true, approaching: false)
    }

    func testPedestrianPriorityBetweenCollisionAndRedLight() {
        var r = CoachRules()
        r.offer(.redLightAhead, now: 0)
        r.offer(.pedestrianDanger(trackID: 3), now: 0)
        r.offer(.collisionRisk, now: 0)
        XCTAssertEqual(r.next(now: 0), .collisionRisk)
        XCTAssertEqual(r.next(now: 0.1), .pedestrianDanger(trackID: 3), "pedestrian danger bypasses the global gap")
        XCTAssertNil(r.next(now: 0.2), "red light waits for the global gap")
        XCTAssertEqual(r.next(now: 3.1), nil, "red light expired (ttl 3 s)")

        var q = CoachRules()
        q.offer(.redLightAhead, now: 0)
        q.offer(.pedestrianCaution(trackID: 1), now: 0)
        XCTAssertEqual(q.next(now: 0), .pedestrianCaution(trackID: 1))
        XCTAssertNil(q.next(now: 1), "caution does not bypass the global gap")
        XCTAssertEqual(q.next(now: 2.9), nil)
    }

    func testPedestrianUrgencyAndCategory() {
        XCTAssertEqual(CoachMessage.pedestrianDanger(trackID: 1).urgency, .high)
        XCTAssertEqual(CoachMessage.pedestrianCaution(trackID: 1).urgency, .normal)
        XCTAssertEqual(CoachMessage.pedestrianCaution(trackID: 1).category, .pedestrian)
        XCTAssertTrue(CoachMessage.pedestrianDanger(trackID: 1).bypassesGlobalGap)
        XCTAssertFalse(CoachMessage.pedestrianCaution(trackID: 1).bypassesGlobalGap)
    }

    func testPerTrackCooldownAndEscalation() {
        let e = DriverCoachEngine()
        e.updatePedestrians([hazard(7, .caution, inLane: false)], speedKmh: 30, now: 0)
        XCTAssertEqual(e.next(now: 0), .pedestrianCaution(trackID: 7))
        e.updatePedestrians([hazard(7, .caution, inLane: false)], speedKmh: 30, now: 3)
        XCTAssertNil(e.next(now: 3), "same track, same level within 6 s")
        e.updatePedestrians([hazard(7, .danger)], speedKmh: 30, now: 3.5)
        XCTAssertEqual(e.next(now: 3.5), .pedestrianDanger(trackID: 7), "escalation to danger is spoken")
        e.updatePedestrians([hazard(7, .danger)], speedKmh: 30, now: 5)
        XCTAssertNil(e.next(now: 5))
        e.updatePedestrians([hazard(7, .danger)], speedKmh: 30, now: 9.6)
        XCTAssertEqual(e.next(now: 9.6), .pedestrianDanger(trackID: 7), "again after the 6 s track cooldown")
    }

    func testCautionNeedsMovingDangerAlways() {
        let e = DriverCoachEngine()
        e.updatePedestrians([hazard(1, .caution, inLane: false)], speedKmh: 2, now: 0)
        XCTAssertNil(e.next(now: 0))
        e.updatePedestrians([hazard(1, .danger)], speedKmh: 0, now: 0.5)
        XCTAssertEqual(e.next(now: 0.5), .pedestrianDanger(trackID: 1))
        e.toggles.pedestrians = false
        e.updatePedestrians([hazard(2, .danger)], speedKmh: 40, now: 10)
        XCTAssertNil(e.next(now: 10))
    }

    func testPedestrianNotYieldedEvent() {
        let monitor = CameraDrivingEventMonitor()
        var all: [DrivingEvent] = []
        for i in 0...10 {
            let t = Double(i) * 0.1
            all += monitor.update(CameraEventInput(timestamp: t, speedKmh: 30,
                                                   pedestrianHazards: [hazard(4, .danger, distance: 14 - Double(i) * 0.5)]))
        }
        XCTAssertEqual(all.map(\.kind), [.pedestrianNotYielded])
        XCTAssertEqual(all.first?.severity, .violation)
        XCTAssertLessThanOrEqual(all.first?.value ?? 99, 12)

        let slow = CameraDrivingEventMonitor()
        let far = CameraDrivingEventMonitor()
        let side = CameraDrivingEventMonitor()
        for i in 0...10 {
            let t = Double(i) * 0.1
            XCTAssertTrue(slow.update(CameraEventInput(timestamp: t, speedKmh: 10,
                                                       pedestrianHazards: [hazard(1, .danger)])).isEmpty)
            XCTAssertTrue(far.update(CameraEventInput(timestamp: t, speedKmh: 40,
                                                      pedestrianHazards: [hazard(1, .danger, distance: 25)])).isEmpty)
            XCTAssertTrue(side.update(CameraEventInput(timestamp: t, speedKmh: 40,
                                                       pedestrianHazards: [hazard(1, .danger, inLane: false)])).isEmpty)
        }
        XCTAssertEqual(DrivingEventKind.pedestrianNotYielded.symbolName, "figure.walk")
    }
}

final class TrafficLightCoachTests: XCTestCase {
    private func light(_ color: TrafficLightColor, id: Int = 1, x: Double = 0.5) -> ObservedTrafficLight {
        ObservedTrafficLight(trackID: id, color: color, box: BBox(x: x - 0.02, y: 0.2, width: 0.04, height: 0.08))
    }

    func testRedAheadWhileMoving() {
        var c = TrafficLightCoach()
        XCTAssertNil(c.update(light: light(.red), speedKmh: 40, leadDistanceMeters: nil, timestamp: 0))
        XCTAssertEqual(c.update(light: light(.red), speedKmh: 40, leadDistanceMeters: nil, timestamp: 0.6), .redLightAhead)
        XCTAssertNil(c.update(light: light(.red), speedKmh: 40, leadDistanceMeters: nil, timestamp: 1.5), "once per light")
        // Slow or off to the side: no warning.
        var slow = TrafficLightCoach()
        XCTAssertNil(slow.update(light: light(.red, id: 2), speedKmh: 15, leadDistanceMeters: nil, timestamp: 0))
        XCTAssertNil(slow.update(light: light(.red, id: 2), speedKmh: 15, leadDistanceMeters: nil, timestamp: 1))
        XCTAssertNil(slow.update(light: light(.red, id: 3, x: 0.95), speedKmh: 50, leadDistanceMeters: nil, timestamp: 2))
        XCTAssertNil(slow.update(light: light(.red, id: 3, x: 0.95), speedKmh: 50, leadDistanceMeters: nil, timestamp: 3))
    }

    func testGreenGoAfterWaitingAtRed() {
        var c = TrafficLightCoach()
        XCTAssertNil(c.update(light: light(.red), speedKmh: 0, leadDistanceMeters: nil, timestamp: 0))
        XCTAssertNil(c.update(light: light(.green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 10))
        XCTAssertNil(c.update(light: light(.green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 10.5))
        XCTAssertEqual(c.update(light: light(.green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 11.1), .greenLightGo)
        XCTAssertNil(c.update(light: light(.green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 12))
    }

    func testNoGreenHintWithCloseLeadOrWithoutRed() {
        var c = TrafficLightCoach()
        _ = c.update(light: light(.red), speedKmh: 1, leadDistanceMeters: 2.5, timestamp: 0)
        for t in stride(from: 5.0, through: 8.0, by: 0.5) {
            XCTAssertNil(c.update(light: light(.green), speedKmh: 1, leadDistanceMeters: 2.5, timestamp: t))
        }
        var d = TrafficLightCoach()   // only ever green while standing (queue at a green light)
        for t in stride(from: 0.0, through: 3.0, by: 0.5) {
            XCTAssertNil(d.update(light: light(.green), speedKmh: 0, leadDistanceMeters: nil, timestamp: t))
        }
    }
}

final class DriverCoachEngineTests: XCTestCase {
    private let policy = FollowingDistancePolicy()

    func testTooCloseNeedsPersistenceAndCollisionSuppressesKeepDistance() {
        let engine = DriverCoachEngine()
        let close = FollowingDistanceCalculator.assess(distanceMeters: 10, ownSpeedKmh: 60, relativeSpeedKmh: 0,
                                                       policy: policy, condition: .dry)
        XCTAssertEqual(close.status, .danger)
        engine.update(CoachFrameInput(timestamp: 0, speedKmh: 60, assessment: close, hasLead: true))
        XCTAssertNil(engine.next(now: 0))
        engine.update(CoachFrameInput(timestamp: 1.1, speedKmh: 60, assessment: close, hasLead: true))
        XCTAssertEqual(engine.next(now: 1.1), .keepDistance(recommendedMeters: 30))

        let engine2 = DriverCoachEngine()
        let closing = FollowingDistanceCalculator.assess(distanceMeters: 20, ownSpeedKmh: 60, relativeSpeedKmh: -40,
                                                         policy: policy, condition: .dry)
        engine2.update(CoachFrameInput(timestamp: 0, speedKmh: 60, assessment: closing, hasLead: true, collisionWarning: true))
        engine2.update(CoachFrameInput(timestamp: 0.3, speedKmh: 60, assessment: closing, hasLead: true, collisionWarning: true))
        XCTAssertEqual(engine2.next(now: 0.3), .collisionRisk)
        engine2.update(CoachFrameInput(timestamp: 4, speedKmh: 60, assessment: close, hasLead: true))
        engine2.update(CoachFrameInput(timestamp: 5.2, speedKmh: 60, assessment: close, hasLead: true))
        XCTAssertNil(engine2.next(now: 5.2), "keep-distance suppressed right after the collision warning")
    }

    func testTogglesAndSigns() {
        let engine = DriverCoachEngine(toggles: CoachToggles(laneDeparture: false, signs: false))
        engine.update(CoachFrameInput(timestamp: 0, speedKmh: 60, laneDeparture: .right))
        engine.offerSign(.speedLimit(kmh: 50), now: 0)
        XCTAssertNil(engine.next(now: 0))
        engine.toggles = CoachToggles()
        engine.offerSign(.feature(kind: .railwayCrossing, distance: 176, id: "x"), now: 1)
        XCTAssertEqual(engine.next(now: 1), .roadSign(kind: .railwayCrossing, distanceMeters: 200))
    }
}

final class CameraDrivingEventTests: XCTestCase {
    private let policy = FollowingDistancePolicy()
    private let geometry = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)

    private func light(id: Int, color: TrafficLightColor, y: Double, x: Double = 0.48) -> TrackedObject {
        TrackedObject(id: id, kind: .trafficLight, label: "traffic light", box: BBox(x: x, y: y, width: 0.04, height: 0.08),
                      confidence: 0.8, hits: 5, firstSeen: 0, lastSeen: 0, isConfirmed: true, lightColor: color)
    }

    func testRedLightRunning() {
        var d = RedLightRunningDetector()
        var result: Double?
        // Light moves up while the car drives at 40 km/h, then leaves the frame through the top.
        for (i, y) in [0.3, 0.22, 0.14, 0.07, 0.02].enumerated() {
            result = d.update(tracks: [light(id: 1, color: .red, y: y)], speedKmh: 40, timestamp: Double(i) * 0.3) ?? result
        }
        XCTAssertNil(result)
        result = d.update(tracks: [], speedKmh: 40, timestamp: 1.6)
        XCTAssertEqual(result ?? 0, 40, accuracy: 0.01)
    }

    func testNoRedLightRunningWhenGreenOrStopped() {
        var d = RedLightRunningDetector()
        for (i, y) in [0.3, 0.2, 0.1, 0.02].enumerated() {
            let color: TrafficLightColor = i < 2 ? .red : .green
            _ = d.update(tracks: [light(id: 1, color: color, y: y)], speedKmh: 40, timestamp: Double(i) * 0.3)
        }
        XCTAssertNil(d.update(tracks: [], speedKmh: 40, timestamp: 2))
        var s = RedLightRunningDetector()
        for (i, y) in [0.3, 0.2, 0.1, 0.02].enumerated() {
            _ = s.update(tracks: [light(id: 1, color: .red, y: y)], speedKmh: 8, timestamp: Double(i) * 0.3)
        }
        XCTAssertNil(s.update(tracks: [], speedKmh: 8, timestamp: 2))
        // Disappearing in the middle of the frame (occlusion) is not a violation.
        var m = RedLightRunningDetector()
        for i in 0..<5 { _ = m.update(tracks: [light(id: 1, color: .red, y: 0.3)], speedKmh: 40, timestamp: Double(i) * 0.3) }
        XCTAssertNil(m.update(tracks: [], speedKmh: 40, timestamp: 2))
    }

    private func stopSign(width: Double) -> TrackedObject {
        TrackedObject(id: 3, kind: .stopSign, label: "stop sign", box: BBox(x: 0.7, y: 0.3, width: width, height: width),
                      confidence: 0.8, hits: 5, firstSeen: 0, lastSeen: 0, isConfirmed: true)
    }

    func testStopSignIgnoredAndObeyed() {
        var m = StopSignComplianceMonitor()
        // f ≈ 1507 px → width 0.04·1080 = 43 px → ≈ 24 m.
        XCTAssertEqual(m.distance(of: stopSign(width: 0.04).box, geometry: geometry) ?? 0, 24.4, accuracy: 1)
        XCTAssertNil(m.update(tracks: [stopSign(width: 0.02)], geometry: geometry, speedKmh: 30, timestamp: 0))   // 49 m
        XCTAssertFalse(m.isArmed)
        XCTAssertNil(m.update(tracks: [stopSign(width: 0.04)], geometry: geometry, speedKmh: 30, timestamp: 1))
        XCTAssertTrue(m.isArmed)
        XCTAssertNil(m.update(tracks: [stopSign(width: 0.08)], geometry: geometry, speedKmh: 20, timestamp: 2))
        XCTAssertNil(m.update(tracks: [], geometry: geometry, speedKmh: 18, timestamp: 3))
        let v = m.update(tracks: [], geometry: geometry, speedKmh: 25, timestamp: 4.6)
        XCTAssertEqual(v?.minSpeedKmh ?? 0, 18, accuracy: 0.01)

        var ok = StopSignComplianceMonitor()
        _ = ok.update(tracks: [stopSign(width: 0.04)], geometry: geometry, speedKmh: 30, timestamp: 0)
        _ = ok.update(tracks: [stopSign(width: 0.08)], geometry: geometry, speedKmh: 2, timestamp: 2)
        XCTAssertNil(ok.update(tracks: [], geometry: geometry, speedKmh: 20, timestamp: 5))
    }

    func testTailgatingAndCollisionEvents() {
        let monitor = CameraDrivingEventMonitor()
        let close = FollowingDistanceCalculator.assess(distanceMeters: 12, ownSpeedKmh: 60, relativeSpeedKmh: 0,
                                                       policy: policy, condition: .dry)
        var all: [DrivingEvent] = []
        for i in 0...25 {
            let t = Double(i) * 0.1
            all += monitor.update(CameraEventInput(timestamp: t, speedKmh: 60, assessment: close, hasLead: true))
        }
        XCTAssertEqual(all.map(\.kind), [.tailgating])
        XCTAssertEqual(all.first?.value ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(all.first?.limit ?? 0, 33.3, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(all.first?.duration ?? 0, 2)

        let collision = monitor.update(CameraEventInput(timestamp: 3, speedKmh: 60, assessment: close, hasLead: true,
                                                        collisionWarning: true))
        XCTAssertEqual(collision.map(\.kind), [.collisionRisk])
        XCTAssertTrue(monitor.update(CameraEventInput(timestamp: 3.1, speedKmh: 60, assessment: close, hasLead: true,
                                                      collisionWarning: true)).isEmpty)
        let lane = monitor.update(CameraEventInput(timestamp: 4, speedKmh: 60, laneDeparture: .left, laneOffset: -0.7))
        XCTAssertEqual(lane.map(\.kind), [.laneDeparture])
        XCTAssertEqual(lane.first?.note, "heuristic; side=left")
    }

    func testNoTailgatingWhenStopped() {
        let monitor = CameraDrivingEventMonitor()
        let stopped = FollowingDistanceCalculator.assess(distanceMeters: 0.8, ownSpeedKmh: 0, relativeSpeedKmh: 0,
                                                         policy: policy, condition: .dry)
        for i in 0...30 {
            XCTAssertTrue(monitor.update(CameraEventInput(timestamp: Double(i) * 0.1, speedKmh: 0, assessment: stopped,
                                                          hasLead: true)).isEmpty)
        }
    }
}
