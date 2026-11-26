import XCTest
@testable import RoadVisCore

/// Regression tests for the defects found by the post-merge audit (vision, coach, navigation).
final class PostMergeAuditTests: XCTestCase {
    // MARK: Pedestrian crossing intent must not depend on the configured horizon

    /// Pinhole projection of a person standing `lateral` metres right of the lane centre, `depth` metres ahead.
    private func standingPerson(lateral: Double, depth: Double, trueHorizon: Double, geometry: CameraGeometry,
                                t: Double) -> TrackedObject {
        let f = geometry.focalLengthPixels
        let x = 0.5 + f * lateral / (depth * geometry.imageWidth)
        let footY = trueHorizon + f * 1.2 / (depth * geometry.imageHeight)      // camera 1.2 m above the road
        let h = f * 1.7 / (depth * geometry.imageHeight)
        let w = f * 0.5 / (depth * geometry.imageWidth)
        return TrackedObject(id: 1, kind: .person, label: "person",
                             box: BBox(x: x - w / 2, y: footY - h, width: w, height: h),
                             confidence: 0.8, hits: 6, firstSeen: 0, lastSeen: t, isConfirmed: true)
    }

    /// Drives toward a standing person and returns (frames with a danger, frames with an "approaching" hazard,
    /// frames in which the person was relevant).
    private func driveTowardStandingPerson(geometry: CameraGeometry, speedKmh: Double, lateral: Double,
                                           trueHorizon: (Double) -> Double,
                                           depth: (Double) -> Double, frames: Int) -> (danger: Int, approaching: Int, relevant: Int) {
        let detector = PedestrianHazardDetector(
            corridor: EgoCorridor.forFrame(imageWidth: geometry.imageWidth, imageHeight: geometry.imageHeight))
        var danger = 0, approaching = 0, relevant = 0
        for i in 0..<frames {
            let t = Double(i) / 15
            let person = standingPerson(lateral: lateral, depth: depth(t), trueHorizon: trueHorizon(t),
                                        geometry: geometry, t: t)
            let r = detector.evaluate(tracks: [person], ownSpeedKmh: speedKmh, geometry: geometry, timestamp: t)
            if r.hazards.contains(where: { $0.level == .danger }) { danger += 1 }
            if r.hazards.contains(where: { $0.approaching }) { approaching += 1 }
            if r.relevantIDs.contains(1) { relevant += 1 }
        }
        return (danger, approaching, relevant)
    }

    func testStandingKerbPedestrianIsNotApproachingWhenHorizonIsOffLandscape() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1920, imageHeight: 1080)
        let v = 50 / 3.6
        for horizon in [0.41, 0.40] {
            for lateral in [3.0, 4.0, 5.0] {
                let r = driveTowardStandingPerson(geometry: g, speedKmh: 50, lateral: lateral,
                                                  trueHorizon: { _ in horizon }, depth: { 40 - v * $0 }, frames: 33)
                XCTAssertEqual(r.danger, 0, "horizon \(horizon), \(lateral) m")
                XCTAssertEqual(r.approaching, 0, "horizon \(horizon), \(lateral) m")
            }
        }
    }

    func testStandingKerbPedestrianIsNotApproachingWhenHorizonIsOffPortrait() {
        let g = CameraGeometry.defaultPortrait
        let v = 20 / 3.6
        for horizon in [0.41, 0.40] {
            for lateral in [3.0, 4.0, 5.0] {
                let r = driveTowardStandingPerson(geometry: g, speedKmh: 20, lateral: lateral,
                                                  trueHorizon: { _ in horizon }, depth: { 35 - v * $0 }, frames: 60)
                XCTAssertEqual(r.danger, 0, "horizon \(horizon), \(lateral) m")
                XCTAssertEqual(r.approaching, 0, "horizon \(horizon), \(lateral) m")
            }
        }
    }

    func testBrakeNodDoesNotTurnStandingPedestrianIntoDanger() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1920, imageHeight: 1080)
        // Constant 15 m; the horizon rises by 0.02 over one second (the car nods), holds, and returns.
        let nod: (Double) -> Double = { t in
            if t < 1 { return 0.42 }
            if t < 2 { return 0.42 - 0.02 * (t - 1) }
            if t < 3 { return 0.40 }
            return min(0.42, 0.40 + 0.02 * (t - 3))
        }
        let r = driveTowardStandingPerson(geometry: g, speedKmh: 30, lateral: 3, trueHorizon: nod,
                                          depth: { _ in 15 }, frames: 75)
        XCTAssertEqual(r.danger, 0)
        XCTAssertEqual(r.approaching, 0)
    }

    func testWalkerTowardTheRoadIsStillApproaching() {
        // A person 15 m ahead walks 1.4 m/s from 4 m right of the lane centre toward the road; the car stands.
        let g = CameraGeometry.defaultPortrait
        let detector = PedestrianHazardDetector()
        var approachingFrames = 0
        for i in 0..<30 {
            let t = Double(i) / 15
            let person = standingPerson(lateral: 4 - 1.4 * t, depth: 15, trueHorizon: 0.42, geometry: g, t: t)
            let r = detector.evaluate(tracks: [person], ownSpeedKmh: 0, geometry: g, timestamp: t)
            if r.hazards.contains(where: { $0.approaching }) { approachingFrames += 1 }
        }
        XCTAssertGreaterThan(approachingFrames, 10)
    }

    // MARK: Traffic-light colour vote at low frame rates

    func testEffectiveWindowFollowsTheFrameInterval() {
        func history(dt: Double, count: Int) -> [TrafficLightColorVote.Observation] {
            (0..<count).map { TrafficLightColorVote.Observation(time: Double($0) * dt, color: .red) }
        }
        XCTAssertEqual(TrafficLightColorVote.effectiveWindow([]), 0.8)
        XCTAssertEqual(TrafficLightColorVote.effectiveWindow(history(dt: 1.0 / 15, count: 10)), 0.8, accuracy: 1e-9)
        XCTAssertEqual(TrafficLightColorVote.effectiveWindow(history(dt: 1.0 / 3, count: 5)), 5.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(TrafficLightColorVote.effectiveWindow(history(dt: 1.0, count: 5)), 2.0, accuracy: 1e-9)
    }

    func testSteadyRedAtThreeFramesPerSecondWithUnreadableFrames() {
        let tracker = ObjectTracker()
        var colours: [TrafficLightColor?] = []
        for i in 0..<30 {
            // Every third frame the lamp is unreadable.
            let colour: TrafficLightColor = i % 3 == 2 ? .unknown : .red
            let detection = Detection(kind: .trafficLight, label: "traffic light", confidence: 0.6,
                                      box: BBox(x: 0.5, y: 0.1, width: 0.03, height: 0.08), lightColor: colour)
            colours.append(tracker.update(detections: [detection], timestamp: Double(i) / 3).first?.lightColor)
        }
        // After the first two seconds the colour is red on every frame.
        XCTAssertTrue(colours.dropFirst(6).allSatisfy { $0 == .red }, "\(colours)")
    }

    func testGreenIsRecognisedSoonAfterTheChangeAtThreeFramesPerSecond() {
        let tracker = ObjectTracker()
        func light(_ c: TrafficLightColor) -> Detection {
            Detection(kind: .trafficLight, label: "traffic light", confidence: 0.6,
                      box: BBox(x: 0.5, y: 0.1, width: 0.03, height: 0.08), lightColor: c)
        }
        var t = 0.0
        for _ in 0..<12 { _ = tracker.update(detections: [light(.red)], timestamp: t); t += 1.0 / 3 }
        var switchedAfter: Double?
        let change = t
        for _ in 0..<12 {
            if tracker.update(detections: [light(.green)], timestamp: t).first?.lightColor == .green, switchedAfter == nil {
                switchedAfter = t - change
            }
            t += 1.0 / 3
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(switchedAfter), 1.5)
    }

    // MARK: Coach: a silent message does not start the global gap

    func testInaudibleMessageDoesNotConsumeTheGlobalGap() {
        var r = CoachRules()
        let silentSigns: (CoachMessage) -> Bool = { $0.category != .sign }
        r.offer(.speedLimit(kmh: 60), now: 0)
        XCTAssertEqual(r.next(now: 0, isAudible: silentSigns), .speedLimit(kmh: 60), "still returned (on-screen use)")
        r.offer(.redLightAhead, now: 0.5)
        XCTAssertEqual(r.next(now: 0.5, isAudible: silentSigns), .redLightAhead, "no gap after a silent message")
        // An audible message starts the gap as before.
        r.offer(.laneDeparture(side: .left), now: 1)
        XCTAssertNil(r.next(now: 1, isAudible: silentSigns))
        // The category cooldown of the silent message still applies.
        var q = CoachRules()
        q.offer(.greenLightGo, now: 0)
        XCTAssertEqual(q.next(now: 0, isAudible: { _ in false }), .greenLightGo)
        q.offer(.greenLightGo, now: 1)
        XCTAssertNil(q.next(now: 1, isAudible: { _ in false }))
    }

    func testCoachEngineForwardsAudibility() {
        let engine = DriverCoachEngine()
        engine.offer(.speedLimit(kmh: 60), now: 0)
        XCTAssertEqual(engine.next(now: 0, isAudible: { _ in false }), .speedLimit(kmh: 60))
        engine.offer(.redLightAhead, now: 0.2)
        XCTAssertEqual(engine.next(now: 0.2), .redLightAhead)
    }

    func testSilentMessagesPerSoundMode() {
        // Voice on: everything is audible.
        XCTAssertTrue(AlertToneKind.isAudible(.speedLimit(kmh: 60), in: .all))
        XCTAssertTrue(AlertToneKind.isAudible(.greenLightGo, in: .voiceOnly))
        // Sounds only: only messages with a tone.
        XCTAssertFalse(AlertToneKind.isAudible(.speedLimit(kmh: 60), in: .soundsOnly))
        XCTAssertFalse(AlertToneKind.isAudible(.roadSign(kind: .school, distanceMeters: 150), in: .soundsOnly))
        XCTAssertFalse(AlertToneKind.isAudible(.greenLightGo, in: .soundsOnly))
        XCTAssertTrue(AlertToneKind.isAudible(.redLightAhead, in: .soundsOnly))
        XCTAssertTrue(AlertToneKind.isAudible(.laneDeparture(side: .left), in: .soundsOnly))
        XCTAssertFalse(AlertToneKind.isAudible(.redLightAhead, in: .silent))

        // "Sounds only": a sign announcement must not delay the red-light tone.
        var r = CoachRules()
        let audible: (CoachMessage) -> Bool = { AlertToneKind.isAudible($0, in: .soundsOnly) }
        r.offer(.speedLimit(kmh: 60), now: 0)
        XCTAssertNotNil(r.next(now: 0, isAudible: audible))
        r.offer(.redLightAhead, now: 0.3)
        XCTAssertEqual(r.next(now: 0.3, isAudible: audible), .redLightAhead)
    }

    func testOnlyMomentBoundAdviceExpiresQuickly() {
        XCTAssertEqual(CoachMessage.laneDeparture(side: .left).maxSpeechWait(defaultWait: 8), 3)
        XCTAssertEqual(CoachMessage.keepDistance(recommendedMeters: 30).maxSpeechWait(defaultWait: 8), 3)
        // Signs, road staff and pedestrian cautions keep the default wait (a 4–6 s navigation prompt must not
        // swallow them).
        let lasting: [CoachMessage] = [.speedLimit(kmh: 60), .speedLimitAhead(kmh: 40, distanceMeters: 200),
                                       .roadSign(kind: .school, distanceMeters: 150), .stopSignAhead,
                                       .overSpeedLimit(limitKmh: 60), .trafficOfficerAhead(trackID: 1),
                                       .roadWorkersAhead(trackID: 2), .pedestrianCaution(trackID: 3), .redLightAhead,
                                       .greenLightGo]
        for message in lasting {
            XCTAssertFalse(message.isMomentBound, "\(message)")
            XCTAssertEqual(message.maxSpeechWait(defaultWait: 8), 8, "\(message)")
        }
        XCTAssertEqual(CoachMessage.laneDeparture(side: .right).maxSpeechWait(defaultWait: 2), 2)
    }

    // MARK: Overpass fallback

    func testThirdServerIsStillTriedAfterTwoTimeouts() {
        XCTAssertEqual(OverpassFallbackPolicy.attemptTimeout(base: 25, timeoutsSoFar: 0), 25)
        XCTAssertEqual(OverpassFallbackPolicy.attemptTimeout(base: 25, timeoutsSoFar: 1), 25)
        // Still an attempt (not an abort), with a short timeout.
        XCTAssertEqual(OverpassFallbackPolicy.attemptTimeout(base: 25, timeoutsSoFar: 2), 10)
        XCTAssertEqual(OverpassFallbackPolicy.attemptTimeout(base: 25, timeoutsSoFar: 3), 10)
        XCTAssertEqual(OverpassFallbackPolicy.attemptTimeout(base: 8, timeoutsSoFar: 2), 8)
    }

    // MARK: Navigation

    private let start = GeoPoint(41.3, 69.2)

    private func straightRoute(length: Double) -> [GeoPoint] {
        var pts: [GeoPoint] = []
        var d = 0.0
        while d <= length {
            pts.append(Geo.destination(from: start, bearing: 90, distance: d))
            d += 50
        }
        return pts
    }

    private func point(along: Double, offset: Double) -> GeoPoint {
        Geo.destination(from: Geo.destination(from: start, bearing: 90, distance: along), bearing: 0, distance: offset)
    }

    func testParallelStreetBesideNeverMatchedRouteBecomesOffRoute() {
        for direction in [1.0, -1.0] {
            let t = RouteProgressTracker(polyline: straightRoute(length: 3000), steps: [], expectedTravelTime: 300)
            var offRouteAt: Double?
            var along = 1500.0
            for _ in 0..<40 {
                if t.update(position: point(along: along, offset: 120)).isOffRoute {
                    offRouteAt = abs(along - 1500)
                    break
                }
                along += 15 * direction
            }
            let travelled = try? XCTUnwrap(offRouteAt)
            XCTAssertNotNil(travelled)
            XCTAssertGreaterThan(travelled ?? 0, 150)
            XCTAssertLessThanOrEqual(travelled ?? .infinity, 200)
        }
    }

    func testStandingOrApproachingNeverMatchedRouteStaysOnRoute() {
        let standing = RouteProgressTracker(polyline: straightRoute(length: 3000), steps: [], expectedTravelTime: 300)
        for _ in 0..<20 {
            XCTAssertFalse(standing.update(position: point(along: 500, offset: 120)).isOffRoute)
        }
        // Driving 400 m to a route that is 400 m away (heading for it at 45°): never off-route.
        let approaching = RouteProgressTracker(polyline: straightRoute(length: 3000), steps: [], expectedTravelTime: 300)
        var offset = 400.0, along = 500.0
        while offset > 0 {
            XCTAssertFalse(approaching.update(position: point(along: along, offset: offset)).isOffRoute)
            offset -= 10
            along += 10
        }
    }

    func testLastMatchThresholdFollowsFixAccuracy() {
        let t = RouteProgressTracker(polyline: straightRoute(length: 1000), steps: [], expectedTravelTime: 100)
        XCTAssertEqual(t.lastMatchThreshold, 50)
        // Accuracy 60 m widens the threshold to 100 m: a fix 70 m beside the line still advances the progress.
        let p = t.update(position: point(along: 200, offset: 70), horizontalAccuracy: 60)
        XCTAssertEqual(t.lastMatchThreshold, 100)
        XCTAssertEqual(p.distanceAlong, 200, accuracy: 2)
        XCTAssertLessThanOrEqual(p.crossTrackDistance, t.lastMatchThreshold)
        _ = t.update(position: point(along: 220, offset: 3), horizontalAccuracy: 5)
        XCTAssertEqual(t.lastMatchThreshold, 50)
    }

    func testReroutePreferenceIsBoundedByTravelTime() {
        let north = [start, Geo.destination(from: start, bearing: 0, distance: 200)]
        let south = [start, Geo.destination(from: start, bearing: 180, distance: 200)]
        // Fastest (6 min) starts with a U-turn; the forward one takes 25 min: the fastest is kept.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0, travelTimes: [360, 1500]), 0)
        // Within max(120 s, 15 %): the forward start wins.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0, travelTimes: [360, 470]), 1)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0, travelTimes: [360, 481]), 0)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0, travelTimes: [3600, 4100]), 1)
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0, travelTimes: [3600, 4200]), 0)
        // A too-slow forward option is skipped, a later acceptable one is taken.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north, north], heading: 0,
                                                    travelTimes: [360, 1500, 400]), 2)
        // No times: unbounded, as before.
        XCTAssertEqual(ReroutePolicy.preferredIndex(polylines: [south, north], heading: 0), 1)
    }
}
