import XCTest
@testable import RoadVisCore

final class FollowingDistanceTests: XCTestCase {
    let policy = FollowingDistancePolicy()

    func testRecommendedDistances() {
        // 60 km/h dry, 2 s → 33.3 m
        XCTAssertEqual(FollowingDistanceCalculator.recommendedDistance(speedKmh: 60, policy: policy, condition: .dry), 33.33, accuracy: 0.05)
        // Wet doubles the gap
        XCTAssertEqual(FollowingDistanceCalculator.recommendedDistance(speedKmh: 60, policy: policy, condition: .wet), 66.67, accuracy: 0.05)
        // Standing → stopped gap
        XCTAssertEqual(FollowingDistanceCalculator.recommendedDistance(speedKmh: 2, policy: policy, condition: .dry), 2)
        XCTAssertEqual(FollowingDistanceCalculator.recommendedDistance(speedKmh: nil, policy: policy, condition: .dry), 2)
    }

    func testStoppingDistance() {
        // 60 km/h, 1 s, μ 0.7 → 16.67 + 277.8/13.73 = 16.67 + 20.23 = 36.9 m
        XCTAssertEqual(FollowingDistanceCalculator.stoppingDistance(speedKmh: 60, reactionTime: 1, friction: 0.7), 36.9, accuracy: 0.2)
    }

    func testAssessStatuses() {
        let safe = FollowingDistanceCalculator.assess(distanceMeters: 40, ownSpeedKmh: 60, relativeSpeedKmh: 0, policy: policy, condition: .dry)
        XCTAssertEqual(safe.status, .safe)
        XCTAssertEqual(safe.timeHeadwaySeconds!, 2.4, accuracy: 0.01)
        let caution = FollowingDistanceCalculator.assess(distanceMeters: 20, ownSpeedKmh: 60, relativeSpeedKmh: 0, policy: policy, condition: .dry)
        XCTAssertEqual(caution.status, .caution)
        let danger = FollowingDistanceCalculator.assess(distanceMeters: 10, ownSpeedKmh: 60, relativeSpeedKmh: 0, policy: policy, condition: .dry)
        XCTAssertEqual(danger.status, .danger)
        // Closing fast: 30 m, closing 50 km/h → TTC 2.16 s < 2.5 → danger even though 30 m ≈ 0.9 of recommended
        let ttc = FollowingDistanceCalculator.assess(distanceMeters: 30, ownSpeedKmh: 60, relativeSpeedKmh: -50, policy: policy, condition: .dry)
        XCTAssertEqual(ttc.status, .danger)
        XCTAssertEqual(ttc.timeToCollisionSeconds!, 2.16, accuracy: 0.01)
        XCTAssertTrue(ttc.isCollisionWarning)
        // Stopped in a queue
        let stopped = FollowingDistanceCalculator.assess(distanceMeters: 1.2, ownSpeedKmh: 0, relativeSpeedKmh: nil, policy: policy, condition: .dry)
        XCTAssertTrue(stopped.isStopped)
        XCTAssertEqual(stopped.status, .caution)
        XCTAssertNil(stopped.stoppingDistanceMeters)
        let unknown = FollowingDistanceCalculator.assess(distanceMeters: nil, ownSpeedKmh: 50, relativeSpeedKmh: nil, policy: policy, condition: .dry)
        XCTAssertEqual(unknown.status, .unknown)
    }

    func testSurfaceFromWeather() {
        XCTAssertEqual(RoadSurfaceCondition.from(weatherCode: 0, temperatureC: 20, precipitationMm: 0), .dry)
        XCTAssertEqual(RoadSurfaceCondition.from(weatherCode: 63, temperatureC: 10, precipitationMm: 2), .wet)
        XCTAssertEqual(RoadSurfaceCondition.from(weatherCode: 73, temperatureC: 0, precipitationMm: 1), .snow)
        XCTAssertEqual(RoadSurfaceCondition.from(weatherCode: 66, temperatureC: -1, precipitationMm: 1), .ice)
        XCTAssertEqual(RoadSurfaceCondition.from(weatherCode: 61, temperatureC: -1, precipitationMm: 0.5), .ice)
    }

    func testCorridor() {
        let c = EgoCorridor.default
        XCTAssertTrue(c.contains(BBox(x: 0.4, y: 0.6, width: 0.2, height: 0.15)))
        XCTAssertFalse(c.contains(BBox(x: 0.0, y: 0.6, width: 0.15, height: 0.15)))   // adjacent lane on the left
        XCTAssertFalse(c.contains(BBox(x: 0.45, y: 0.1, width: 0.1, height: 0.1)))    // above horizon
    }

    func testLeadTrackerDistanceAndClosing() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let lead = LeadVehicleTracker()
        var result: LeadVehicle?
        for i in 0..<12 {
            let t = Double(i) * 0.1
            let z = 25.0 - 5.0 * t                 // approaching at 18 km/h
            let w = g.focalLengthPixels * 1.8 / z / g.imageWidth
            let h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            let box = BBox(x: 0.5 - w / 2, y: 0.75 - h, width: w, height: h)
            let car = TrackedObject(id: 7, kind: .car, label: "car", box: box, confidence: 0.9, hits: 5,
                                    firstSeen: 0, lastSeen: t, isConfirmed: true)
            let side = TrackedObject(id: 8, kind: .car, label: "car", box: BBox(x: 0.0, y: 0.7, width: 0.12, height: 0.1),
                                     confidence: 0.9, hits: 5, firstSeen: 0, lastSeen: t, isConfirmed: true)
            result = lead.update(tracks: [side, car], geometry: g, timestamp: t)
        }
        let r = try! XCTUnwrap(result)
        XCTAssertEqual(r.trackID, 7)
        XCTAssertEqual(r.method, "ширина+высота")
        XCTAssertEqual(r.distanceMeters, 19.5, accuracy: 1.5)     // smoothed lags slightly behind 19.5 m
        XCTAssertLessThan(r.relativeSpeedKmh!, -10)
        let a = FollowingDistanceCalculator.assess(distanceMeters: r.distanceMeters, ownSpeedKmh: 40,
                                                   relativeSpeedKmh: r.relativeSpeedKmh, policy: policy, condition: .dry)
        XCTAssertNotNil(a.timeToCollisionSeconds)
    }

    // MARK: Lead selection: the car directly ahead, not the one on the side

    private func car(_ id: Int, _ box: BBox, t: Double = 0) -> TrackedObject {
        TrackedObject(id: id, kind: .car, label: "car", box: box, confidence: 0.9, hits: 5,
                      firstSeen: 0, lastSeen: t, isConfirmed: true)
    }

    func testCarAheadWinsOverCloserAdjacentLaneCar() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        // Car ahead: centred, farther (bottom at 0.66). Adjacent-lane car: closer (bottom 0.78), centre at x 0.68 —
        // overlapping the loose corridor but not strictly ahead.
        let ahead = car(1, BBox(x: 0.44, y: 0.58, width: 0.12, height: 0.08))
        let side = car(2, BBox(x: 0.55, y: 0.62, width: 0.26, height: 0.16))
        XCTAssertTrue(EgoCorridor.default.contains(side.box))
        XCTAssertFalse(EgoCorridor.default.isStrictlyAhead(side.box))
        var result: LeadVehicle?
        for i in 0..<5 {
            result = tracker.update(tracks: [side, ahead], geometry: g, timestamp: Double(i) * 0.1)
        }
        XCTAssertEqual(result?.trackID, 1)
    }

    func testCentredCarPreferredOverSlightlyCloserOffCentreCar() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        let centred = car(1, BBox(x: 0.45, y: 0.6, width: 0.1, height: 0.07))
        // Strictly-ahead zone, but well off-centre and only a little closer.
        let offCentre = car(2, BBox(x: 0.53, y: 0.64, width: 0.1, height: 0.07))
        let result = tracker.update(tracks: [offCentre, centred], geometry: g, timestamp: 0)
        XCTAssertEqual(result?.trackID, 1)
    }

    func testSideCarTouchingFrameEdgeNeverSelected() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        // Passing car cut by the right frame edge, its box even reaching the corridor centre.
        let passing = car(3, BBox(x: 0.5, y: 0.55, width: 0.5, height: 0.4))
        for i in 0..<5 {
            XCTAssertNil(tracker.update(tracks: [passing], geometry: g, timestamp: Double(i) * 0.1))
        }
        // With a car ahead, the car ahead is the lead.
        let ahead = car(4, BBox(x: 0.45, y: 0.55, width: 0.1, height: 0.07))
        XCTAssertEqual(tracker.update(tracks: [passing, ahead], geometry: g, timestamp: 0.6)?.trackID, 4)
    }

    func testLeadSwitchesWhenItDriftsOutOfStrictZone() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        let far = car(1, BBox(x: 0.45, y: 0.5, width: 0.1, height: 0.06))
        var near = car(2, BBox(x: 0.44, y: 0.6, width: 0.12, height: 0.1))
        XCTAssertEqual(tracker.update(tracks: [far, near], geometry: g, timestamp: 0)?.trackID, 2)
        // The near car changes lanes to the right: its centre leaves the strict zone → switch at once.
        near.box = BBox(x: 0.6, y: 0.6, width: 0.12, height: 0.1)
        XCTAssertEqual(tracker.update(tracks: [far, near], geometry: g, timestamp: 0.1)?.trackID, 1)
    }

    func testLaneCentreShiftMovesCorridor() {
        let box = BBox(x: 0.6, y: 0.62, width: 0.12, height: 0.12)   // centre x 0.66, bottom 0.74
        XCTAssertFalse(EgoCorridor(centerX: 0.5).isStrictlyAhead(box))
        XCTAssertTrue(EgoCorridor(centerX: 0.62).isStrictlyAhead(box))
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        XCTAssertNil(tracker.update(tracks: [car(5, box)], geometry: g, timestamp: 0))
        tracker.corridor = EgoCorridor(centerX: 0.62)
        XCTAssertEqual(tracker.update(tracks: [car(5, box)], geometry: g, timestamp: 0.1)?.trackID, 5)

        // Smoothed corridor centre from the lane estimate: follows a confident estimate (clamped), ignores a weak one.
        let lane = LaneEstimate(left: nil, right: nil, leftConfidence: 0.8, rightConfidence: 0.8, laneCenterX: 0.62,
                                egoOffset: -0.3, confidence: 0.8, referenceY: 0.96, timestamp: 0)
        var center = 0.5
        for _ in 0..<40 { center = EgoCorridor.smoothedCenterX(previous: center, lane: lane) }
        XCTAssertEqual(center, 0.62, accuracy: 0.01)
        var far = lane
        far.laneCenterX = 0.9
        for _ in 0..<40 { center = EgoCorridor.smoothedCenterX(previous: center, lane: far) }
        XCTAssertEqual(center, 0.65, accuracy: 0.001)
        var weak = lane
        weak.confidence = 0.3
        for _ in 0..<60 { center = EgoCorridor.smoothedCenterX(previous: center, lane: weak) }
        XCTAssertEqual(center, 0.5, accuracy: 0.01)
    }
}

final class BonnetOffsetTests: XCTestCase {
    func testGapSubtractsCameraToBumper() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        let tracker = LeadVehicleTracker()
        tracker.cameraToBumperMeters = 2.5
        var lead: LeadVehicle?
        for i in 0..<5 {
            let z = 5.0   // camera to the lead's rear
            let w = g.focalLengthPixels * 1.8 / z / g.imageWidth
            let h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            let car = TrackedObject(id: 1, kind: .car, label: "car", box: BBox(x: 0.5 - w / 2, y: 0.9 - h, width: w, height: h),
                                    confidence: 0.9, hits: 5, firstSeen: 0, lastSeen: Double(i) * 0.1, isConfirmed: true)
            lead = tracker.update(tracks: [car], geometry: g, timestamp: Double(i) * 0.1)
        }
        let l = try! XCTUnwrap(lead)
        XCTAssertEqual(l.cameraDistanceMeters, 5.0, accuracy: 0.3)
        XCTAssertEqual(l.distanceMeters, 2.5, accuracy: 0.3)
    }
}
