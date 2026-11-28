import XCTest
@testable import RoadVisCore

// Regression tests for the core-vision audit (portrait / landscape geometry, lead selection, traffic lights,
// pedestrians / road staff) and for the people-and-lights design changes.

/// Flat-ground pinhole projection used to build realistic boxes (camera 1.2 m high, level).
private struct Scene {
    let geometry: CameraGeometry
    var horizonY = 0.42
    var cameraHeight = 1.2

    /// Box of an object `width` × `height` metres standing on the ground at lateral offset `x` and depth `z` metres.
    func box(x: Double, z: Double, width: Double, height: Double) -> BBox {
        let f = geometry.focalLengthPixels
        let bottom = horizonY + f * cameraHeight / (z * geometry.imageHeight)
        let cx = 0.5 + f * x / (z * geometry.imageWidth)
        let w = f * width / (z * geometry.imageWidth), h = f * height / (z * geometry.imageHeight)
        return BBox(x: cx - w / 2, y: bottom - h, width: w, height: h)
    }
}

private let portrait = CameraGeometry.defaultPortrait
private let landscape = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1920, imageHeight: 1080)

private func vehicle(_ id: Int, _ box: BBox, kind: VehicleKind = .car, t: Double = 0) -> TrackedObject {
    TrackedObject(id: id, kind: kind, label: kind.rawValue, box: box, confidence: 0.9, hits: 6, firstSeen: 0,
                  lastSeen: t, isConfirmed: true)
}

private func person(_ id: Int, _ box: BBox, t: Double = 0, role: PersonRole? = nil) -> TrackedObject {
    TrackedObject(id: id, kind: .person, label: "person", box: box, confidence: 0.8, hits: 6, firstSeen: 0,
                  lastSeen: t, isConfirmed: true, personRole: role)
}

private func lightTrack(_ id: Int, _ color: TrafficLightColor?, x: Double, y: Double = 0.2, height: Double = 0.08,
                        hits: Int = 6) -> TrackedObject {
    TrackedObject(id: id, kind: .trafficLight, label: "traffic light",
                  box: BBox(x: x - 0.015, y: y, width: 0.03, height: height), confidence: 0.6, hits: hits,
                  firstSeen: 0, lastSeen: 0, isConfirmed: true, lightColor: color)
}

// MARK: - Finding 1: aspect-aware own-lane corridor

final class EgoCorridorAspectTests: XCTestCase {
    func testLandscapeCorridorUnchanged() {
        XCTAssertEqual(EgoCorridor.forFrame(imageWidth: 1920, imageHeight: 1080), EgoCorridor())
        XCTAssertEqual(EgoCorridor.forFrame(centerX: 0.45, horizonY: 0.5, imageWidth: 1280, imageHeight: 720),
                       EgoCorridor(centerX: 0.45, horizonY: 0.5))
        XCTAssertEqual(EgoCorridor.aspectScale(imageWidth: 0, imageHeight: 100), 1)
        // Wider than 16:9 never narrows the corridor.
        XCTAssertEqual(EgoCorridor.aspectScale(imageWidth: 2400, imageHeight: 1080), 1)
    }

    func testPortraitCorridorIsWider() {
        let c = EgoCorridor.forFrame(imageWidth: 1080, imageHeight: 1920)
        XCTAssertEqual(EgoCorridor.aspectScale(imageWidth: 1080, imageHeight: 1920), 3.16, accuracy: 0.01)
        XCTAssertEqual(c.bottomHalfWidth, 0.04 + 0.2 * 3.1605, accuracy: 0.001)
        XCTAssertEqual(c.horizonHalfWidth, 0.04)
    }

    func testPortraitOffCentreLeadIsAheadAndNextLaneIsNot() {
        let scene = Scene(geometry: portrait)
        let fixed = EgoCorridor.forFrame(imageWidth: 1080, imageHeight: 1920)
        for z in [5.0, 7.0, 10.0] {
            let offCentre = scene.box(x: 0.5, z: z, width: 1.8, height: 1.5)
            XCTAssertTrue(fixed.isStrictlyAhead(offCentre), "0.5 m off-centre at \(z) m")
            let nextLane = scene.box(x: 3.5, z: z, width: 1.8, height: 1.5)
            XCTAssertFalse(fixed.isStrictlyAhead(nextLane), "next lane at \(z) m")
        }
        XCTAssertFalse(fixed.isStrictlyAhead(scene.box(x: -3.5, z: 20, width: 1.8, height: 1.5)))
        // The defect: with the landscape widths that car was not "strictly ahead" in portrait.
        let old = EgoCorridor()
        XCTAssertFalse(old.isStrictlyAhead(scene.box(x: 0.5, z: 10, width: 1.8, height: 1.5)))
        XCTAssertGreaterThan(old.lateralOffset(scene.box(x: 0.5, z: 10, width: 1.8, height: 1.5)) ?? 0, 0.9)
        XCTAssertLessThan(fixed.lateralOffset(scene.box(x: 0.5, z: 10, width: 1.8, height: 1.5)) ?? 9, 0.6)
    }

    func testPortraitLeadTrackerPicksOffCentreCar() {
        let scene = Scene(geometry: portrait)
        let tracker = LeadVehicleTracker(corridor: EgoCorridor.forFrame(imageWidth: 1080, imageHeight: 1920))
        let lead = tracker.update(tracks: [vehicle(1, scene.box(x: 0.5, z: 10, width: 1.8, height: 1.5))],
                                  geometry: portrait, timestamp: 0)
        XCTAssertEqual(lead?.trackID, 1)
        XCTAssertEqual(lead?.cameraDistanceMeters ?? 0, 10, accuracy: 0.5)
    }

    func testPortraitPedestrianNearCentrelineIsInOwnLane() {
        let scene = Scene(geometry: portrait)
        let d = PedestrianHazardDetector(corridor: EgoCorridor.forFrame(imageWidth: 1080, imageHeight: 1920))
        let r = d.evaluate(tracks: [person(1, scene.box(x: 0.5, z: 6, width: 0.5, height: 1.7))], ownSpeedKmh: 2,
                           geometry: portrait, timestamp: 0)
        XCTAssertEqual(r.hazards.first?.level, .danger)
        XCTAssertEqual(r.hazards.first?.inOwnLane, true)
    }
}

// MARK: - Finding 2: pedestrian aspect ratio in pixels

final class PedestrianAspectTests: XCTestCase {
    func testPortraitWalkingPedestrianIsPlausible() {
        let d = PedestrianHazardDetector()
        // 0.10 × 0.12 normalized in a 1080×1920 frame = 108 × 230 px, ratio 2.13 (legs apart / carrying a bag).
        let walker = person(1, BBox(x: 0.45, y: 0.58, width: 0.10, height: 0.12))
        XCTAssertTrue(d.isPlausible(walker, geometry: portrait))
        let r = d.evaluate(tracks: [walker], ownSpeedKmh: 30, geometry: portrait, timestamp: 0)
        XCTAssertEqual(r.hazards.first?.level, .danger)
    }

    func testLandscapeSquareBlobIsRejected() {
        let d = PedestrianHazardDetector()
        // 0.10 × 0.16 normalized in a 1920×1080 frame = 192 × 173 px, ratio 0.9: not a standing person.
        let blob = person(1, BBox(x: 0.45, y: 0.5, width: 0.10, height: 0.16))
        XCTAssertFalse(d.isPlausible(blob, geometry: landscape))
        XCTAssertTrue(d.evaluate(tracks: [blob], ownSpeedKmh: 30, geometry: landscape, timestamp: 0).hazards.isEmpty)
        // A real person in landscape: 0.04 × 0.20 = 77 × 216 px.
        XCTAssertTrue(d.isPlausible(person(2, BBox(x: 0.48, y: 0.45, width: 0.04, height: 0.20)), geometry: landscape))
    }
}

// MARK: - Findings 4, 5, 6: lead vehicle

final class LeadVehicleAuditTests: XCTestCase {
    private let policy = FollowingDistancePolicy()

    func testClassVoteFlipDoesNotLookLikeClosing() {
        let tracker = LeadVehicleTracker()
        // A 1.9 × 1.9 m vehicle really at 12 m, constant box; the track's class vote is truck, then flips to car.
        let box = Scene(geometry: portrait).box(x: 0, z: 12, width: 1.9, height: 1.9)
        var distances: [Double] = []
        for i in 0..<40 {
            let t = Double(i) / 15
            let kind: VehicleKind = i < 20 ? .truck : .car
            guard let lead = tracker.update(tracks: [vehicle(1, box, kind: kind, t: t)], geometry: portrait,
                                            timestamp: t) else { return XCTFail("lead lost at frame \(i)") }
            distances.append(lead.cameraDistanceMeters)
            if i == 20 { XCTAssertNil(lead.relativeSpeedKmh, "history restarts at the class flip") }
            XCTAssertEqual(lead.relativeSpeedKmh ?? 0, 0, accuracy: 1, "frame \(i)")
            let a = FollowingDistanceCalculator.assess(distanceMeters: lead.distanceMeters, ownSpeedKmh: 40,
                                                       relativeSpeedKmh: lead.relativeSpeedKmh, policy: policy,
                                                       condition: .dry)
            XCTAssertFalse(a.isCollisionWarning, "frame \(i)")
        }
        // The estimate steps once (typical truck size → typical car size), it does not glide.
        XCTAssertEqual(distances[19], distances[10], accuracy: 1e-6)
        XCTAssertEqual(distances[21], distances[39], accuracy: 1e-6)
        XCTAssertLessThan(distances[39], distances[19])
    }

    func testUnknownOwnSpeedIsNotStandingStill() {
        let closing = FollowingDistanceCalculator.assess(distanceMeters: 6, ownSpeedKmh: nil, relativeSpeedKmh: -40,
                                                         policy: policy, condition: .dry)
        XCTAssertFalse(closing.isStopped)
        XCTAssertEqual(closing.status, .danger)
        XCTAssertTrue(closing.isCollisionWarning)
        XCTAssertNil(closing.fractionOfRecommended)
        XCTAssertNil(closing.recommendedTimeGapSeconds)
        let steady = FollowingDistanceCalculator.assess(distanceMeters: 6, ownSpeedKmh: nil, relativeSpeedKmh: nil,
                                                        policy: policy, condition: .dry)
        XCTAssertEqual(steady.status, .unknown)
        XCTAssertFalse(steady.isStopped)
        // Really stopped: unchanged behaviour.
        let stopped = FollowingDistanceCalculator.assess(distanceMeters: 6, ownSpeedKmh: 0, relativeSpeedKmh: -40,
                                                         policy: policy, condition: .dry)
        XCTAssertTrue(stopped.isStopped)
        XCTAssertEqual(stopped.status, .safe)
    }

    func testMuchNearerOffCentreCarBeatsFarCentredCar() {
        let scene = Scene(geometry: landscape)
        let near = vehicle(1, scene.box(x: 0.7, z: 8, width: 1.8, height: 1.5))
        let far = vehicle(2, scene.box(x: 0, z: 25, width: 1.8, height: 1.5))
        XCTAssertTrue(EgoCorridor.default.isStrictlyAhead(near.box))
        XCTAssertEqual(LeadVehicleTracker().update(tracks: [near, far], geometry: landscape, timestamp: 0)?.trackID, 1)
        // Also when the far car already is the lead (cut-in): the hysteresis must not keep it.
        let tracker = LeadVehicleTracker()
        XCTAssertEqual(tracker.update(tracks: [far], geometry: landscape, timestamp: 0)?.trackID, 2)
        XCTAssertEqual(tracker.update(tracks: [near, far], geometry: landscape, timestamp: 0.1)?.trackID, 1)
        // Without the dominance rule the far centred car won (the defect).
        var selection = LeadVehicleTracker.SelectionConfig()
        selection.dominanceRatio = .infinity
        XCTAssertEqual(LeadVehicleTracker(selection: selection).update(tracks: [near, far], geometry: landscape,
                                                                      timestamp: 0)?.trackID, 2)
    }
}

// MARK: - Finding 7 + own-lane light selection

final class TrafficLightSelectionTests: XCTestCase {
    func testLargestOnlyLooksAhead() {
        let red = lightTrack(1, .red, x: 0.5, height: 0.06)
        let bigGreenAtTheSide = lightTrack(2, .green, x: 0.9, height: 0.12)
        XCTAssertEqual(ObservedTrafficLight.largest(in: [red, bigGreenAtTheSide])?.trackID, 1)
        XCTAssertNil(ObservedTrafficLight.largest(in: [bigGreenAtTheSide]))
    }

    func testGreenOnAnotherTrackNeverSaysGo() {
        var coach = TrafficLightCoach()
        func observed(_ id: Int, _ color: TrafficLightColor, x: Double = 0.5) -> ObservedTrafficLight {
            ObservedTrafficLight(trackID: id, color: color, box: BBox(x: x - 0.02, y: 0.2, width: 0.04, height: 0.08))
        }
        XCTAssertNil(coach.update(light: observed(1, .red), speedKmh: 0, leadDistanceMeters: nil, timestamp: 0))
        // A pedestrian / cross-street signal (another track) is green for more than the hold time.
        for i in 1...15 {
            XCTAssertNil(coach.update(light: observed(2, .green, x: 0.7), speedKmh: 0, leadDistanceMeters: nil,
                                      timestamp: Double(i) * 0.1))
        }
        // The own light (track 1) turns green.
        XCTAssertNil(coach.update(light: observed(1, .green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 2.0))
        XCTAssertEqual(coach.update(light: observed(1, .green), speedKmh: 0, leadDistanceMeters: nil, timestamp: 3.1),
                       .greenLightGo)
    }

    func testOwnLaneLightBeatsLargerSideLight() {
        let own = lightTrack(1, .red, x: 0.52, height: 0.07)
        let kerb = lightTrack(2, .green, x: 0.80, height: 0.10)      // larger, but 0.30 off the corridor centre
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [own, kerb])?.trackID, 1)
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [own, kerb])?.color, .red)
        // Corridor centre shifted toward the other light.
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [own, kerb], corridorCenterX: 0.75)?.trackID, 2)
    }

    func testSelectionNeedsHitsKnownColourAndPosition() {
        XCTAssertNil(TrafficLightSelection.ownLane(in: [lightTrack(1, .red, x: 0.5, hits: 4)]))
        XCTAssertNil(TrafficLightSelection.ownLane(in: [lightTrack(1, nil, x: 0.5)]))
        XCTAssertNil(TrafficLightSelection.ownLane(in: [lightTrack(1, .unknown, x: 0.5)]))
        XCTAssertNil(TrafficLightSelection.ownLane(in: [lightTrack(1, .red, x: 0.95)]))            // far to the side
        XCTAssertNil(TrafficLightSelection.ownLane(in: [lightTrack(1, .red, x: 0.5, y: 0.5)]))     // below the horizon
        var missed = lightTrack(1, .red, x: 0.5)
        missed.missed = 1
        XCTAssertNil(TrafficLightSelection.ownLane(in: [missed]))
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [lightTrack(1, .green, x: 0.5)])?.color, .green)
    }

    func testFarIntersectionLightsAreDroppedAndRedWinsCloseCalls() {
        let near = lightTrack(1, .green, x: 0.56, height: 0.10)
        let nextIntersection = lightTrack(2, .red, x: 0.50, height: 0.04)     // < 60 % of the tallest
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [near, nextIntersection])?.trackID, 1)
        // Two heads of one intersection with nearly the same score and different colours → the red one.
        let green = lightTrack(3, .green, x: 0.46, height: 0.08)
        let red = lightTrack(4, .red, x: 0.55, height: 0.08)
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [green, red])?.color, .red)
        // A clearly better green is not overruled.
        let sideRed = lightTrack(5, .red, x: 0.72, height: 0.08)
        XCTAssertEqual(TrafficLightSelection.ownLane(in: [lightTrack(6, .green, x: 0.5, height: 0.08), sideRed])?.color,
                       .green)
    }

    func testLowScoreLightWithoutColourIsNotDisplayed() {
        var faint = lightTrack(1, nil, x: 0.5)
        faint.confidence = 0.35
        faint.peakConfidence = 0.38
        XCTAssertFalse(TrafficLightSelection.isDisplayable(faint, classThreshold: 0.30))
        faint.lightColor = .green
        XCTAssertTrue(TrafficLightSelection.isDisplayable(faint, classThreshold: 0.30))
        var solid = lightTrack(2, .unknown, x: 0.5)
        solid.peakConfidence = 0.55
        XCTAssertTrue(TrafficLightSelection.isDisplayable(solid, classThreshold: 0.30))
        XCTAssertTrue(TrafficLightSelection.isDisplayable(vehicle(3, BBox(x: 0.4, y: 0.5, width: 0.2, height: 0.2)),
                                                          classThreshold: 0.30))
        XCTAssertEqual(DetectionThresholds.threshold(for: .trafficLight), 0.30)
    }
}

// MARK: - Finding 9 / time-window colour vote

final class TrafficLightColorVoteTests: XCTestCase {
    private func light(_ color: TrafficLightColor?, confidence: Double = 0.6) -> Detection {
        Detection(kind: .trafficLight, label: "traffic light", confidence: confidence,
                  box: BBox(x: 0.5, y: 0.1, width: 0.03, height: 0.08), lightColor: color)
    }

    func testColourNeedsThreeVotes() {
        let tracker = ObjectTracker()
        XCTAssertNil(tracker.update(detections: [light(.red)], timestamp: 0).first?.lightColor)
        XCTAssertNil(tracker.update(detections: [light(.red)], timestamp: 1.0 / 15).first?.lightColor)
        XCTAssertEqual(tracker.update(detections: [light(.red)], timestamp: 2.0 / 15).first?.lightColor, .red)
    }

    func testStaleRedExpiresAndFreshGreenWins() {
        let tracker = ObjectTracker()
        var t = 0.0
        var tracks: [TrackedObject] = []
        for _ in 0..<8 {
            tracks = tracker.update(detections: [light(.red)], timestamp: t)
            t += 1.0 / 15
        }
        XCTAssertEqual(tracks.first?.lightColor, .red)
        // The lamp becomes unreadable (classifier answers unknown / box too small → nil): the red must not survive.
        for i in 0..<192 {
            tracks = tracker.update(detections: [light(i % 2 == 0 ? .unknown : nil)], timestamp: t)
            t += 1.0 / 15
            if i == 13 { XCTAssertNil(tracks.first?.lightColor, "no readable lamp for 0.9 s") }
        }
        XCTAssertEqual(tracks.count, 1)
        XCTAssertNil(tracks.first?.lightColor)
        for _ in 0..<3 {
            tracks = tracker.update(detections: [light(.green)], timestamp: t)
            t += 1.0 / 15
        }
        XCTAssertEqual(tracks.first?.lightColor, .green)
    }

    func testPhaseChangeSwitchesWithinTheWindowAndNeverInventsAColour() {
        let tracker = ObjectTracker()
        var t = 0.0
        for _ in 0..<15 {
            _ = tracker.update(detections: [light(.red)], timestamp: t)
            t += 1.0 / 15
        }
        var seen: [TrafficLightColor?] = []
        var switchedAfter: Double?
        let change = t
        for _ in 0..<15 {
            let color = tracker.update(detections: [light(.green)], timestamp: t).first?.lightColor
            seen.append(color)
            if color == .green, switchedAfter == nil { switchedAfter = t - change }
            t += 1.0 / 15
        }
        XCTAssertFalse(seen.contains(.yellow))
        XCTAssertEqual(seen.last, .green)
        XCTAssertLessThanOrEqual(try XCTUnwrap(switchedAfter), TrafficLightColorVote.window)
    }

    func testSingleWrongFrameDoesNotFlipAStableColour() {
        let tracker = ObjectTracker()
        var t = 0.0
        for _ in 0..<10 {
            _ = tracker.update(detections: [light(.red)], timestamp: t)
            t += 1.0 / 15
        }
        XCTAssertEqual(tracker.update(detections: [light(.green)], timestamp: t).first?.lightColor, .red)
        t += 1.0 / 15
        XCTAssertEqual(tracker.update(detections: [light(.unknown)], timestamp: t).first?.lightColor, .red)
    }

    func testVoteRules() {
        typealias O = TrafficLightColorVote.Observation
        func obs(_ colors: [TrafficLightColor], dt: Double = 0.05) -> [O] {
            colors.enumerated().map { O(time: Double($0.offset) * dt, color: $0.element) }
        }
        // Fewer than 3 known votes.
        XCTAssertNil(TrafficLightColorVote.decide(obs([.red, .unknown, .red]), now: 0.1, previous: .red))
        // Winner below 60 % of the known votes.
        XCTAssertNil(TrafficLightColorVote.decide(obs([.red, .green, .red, .green]), now: 0.15, previous: nil))
        // Hysteresis: green has the votes, but the newest known observation is still red → previous kept.
        XCTAssertEqual(TrafficLightColorVote.decide(obs([.green, .green, .green, .green, .red]), now: 0.2, previous: .red),
                       .red)
        XCTAssertEqual(TrafficLightColorVote.decide(obs([.red, .green, .green, .green, .green]), now: 0.2, previous: .red),
                       .green)
        // Observations outside the window do not count.
        var old = obs([.red, .red, .red, .red])
        XCTAssertNil(TrafficLightColorVote.decide(old, now: 1.2, previous: .red))
        TrafficLightColorVote.prune(&old, now: 1.2)
        XCTAssertTrue(old.isEmpty)
    }

    func testNoRedLightEventAfterTheLampBecameUnreadable() {
        func track(_ color: TrafficLightColor?, y: Double) -> TrackedObject {
            TrackedObject(id: 1, kind: .trafficLight, label: "traffic light", box: BBox(x: 0.48, y: y, width: 0.04, height: 0.08),
                          confidence: 0.8, hits: 5, firstSeen: 0, lastSeen: 0, isConfirmed: true, lightColor: color)
        }
        var d = RedLightRunningDetector()
        var result: Double?
        var t = 0.0
        for y in [0.30, 0.28, 0.26, 0.24] {
            result = d.update(tracks: [track(.red, y: y)], speedKmh: 40, timestamp: t) ?? result
            t += 0.3
        }
        // The tracker's colour expired (nil) for well over a second while the light climbs to the top edge.
        for y in [0.20, 0.15, 0.10, 0.06, 0.02] {
            result = d.update(tracks: [track(nil, y: y)], speedKmh: 40, timestamp: t) ?? result
            t += 0.3
        }
        result = d.update(tracks: [], speedKmh: 40, timestamp: t + 0.5) ?? result
        XCTAssertNil(result)
    }
}

// MARK: - Finding 8 / classifier v2 (port of tl/code/v5.py)

final class TrafficLightClassifierV2Tests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let w: Int
            let h: Int
            let rgb: String
            let expected: String
        }
        let cases: [Case]
    }

    private func bgra(_ rgb: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            out[i * 4] = rgb[i * 3 + 2]
            out[i * 4 + 1] = rgb[i * 3 + 1]
            out[i * 4 + 2] = rgb[i * 3]
        }
        return out
    }

    private func classify(_ rgb: [UInt8], width: Int, height: Int) -> TrafficLightColor {
        bgra(rgb, width: width, height: height).withUnsafeBytes { raw in
            TrafficLightColorClassifier.classifyBGRA(base: raw.baseAddress!, width: width, height: height,
                                                     bytesPerRow: width * 4, rectX: 0, rectY: 0, rectWidth: width,
                                                     rectHeight: height)
        }
    }

    /// 292 synthetic crops (housings on sky / foliage / grey, dim lamps, bloomed night lamps with halo, red + amber,
    /// horizontal heads, arrows, colour noise) with the answers of the Python prototype `v5.v3`: the Swift port must
    /// give the same answer on every one. (The LISA crops the prototype was evaluated on are CC BY-NC-SA and are not
    /// shipped.)
    func testPortMatchesPythonPrototypeOnSyntheticCrops() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "traffic_light_v5_cases", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.cases.count, 292)
        var perAnswer: [String: Int] = [:]
        var mismatches: [String] = []
        for (index, c) in fixture.cases.enumerated() {
            let rgb = [UInt8](try XCTUnwrap(Data(base64Encoded: c.rgb)))
            XCTAssertEqual(rgb.count, c.w * c.h * 3)
            let got = classify(rgb, width: c.w, height: c.h)
            perAnswer[c.expected, default: 0] += 1
            if got.rawValue != c.expected { mismatches.append("#\(index) \(c.name) \(c.w)x\(c.h): \(got.rawValue) != \(c.expected)") }
            // The grid entry point gives the same answer when every pixel is a sample.
            if min(c.w, c.h) < 2 * TrafficLightColorClassifier.samplesAlongShortSide {
                var pixels: [RGBPixel] = []
                for i in 0..<(c.w * c.h) { pixels.append(RGBPixel(r: rgb[i * 3], g: rgb[i * 3 + 1], b: rgb[i * 3 + 2])) }
                XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: pixels, width: c.w, height: c.h), got,
                               "grid entry, case #\(index)")
            }
        }
        XCTAssertEqual(mismatches, [])
        // The fixture covers every answer.
        for answer in ["red", "yellow", "green", "unknown"] { XCTAssertGreaterThan(perAnswer[answer] ?? 0, 20, answer) }
    }

    /// Crop of a vertical housing (dark) on `background` with one lamp at `lampY` (fraction of the height).
    private func housing(width: Int = 24, height: Int = 60, background: (UInt8, UInt8, UInt8),
                         lamp: (UInt8, UInt8, UInt8)?, lampY: Double, border: Int = 2) -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let radius = Double(width) * 0.28
        for y in 0..<height {
            for x in 0..<width {
                var p = background
                if x >= border, x < width - border, y >= border, y < height - border { p = (25, 25, 28) }
                if let lamp {
                    let dx = Double(x) - Double(width) / 2, dy = Double(y) - Double(height) * lampY
                    if dx * dx + dy * dy <= radius * radius { p = lamp }
                }
                let i = (y * width + x) * 3
                rgb[i] = p.0; rgb[i + 1] = p.1; rgb[i + 2] = p.2
            }
        }
        return rgb
    }

    func testLampColoursInAVerticalHousing() {
        let grey: (UInt8, UInt8, UInt8) = (120, 120, 120)
        XCTAssertEqual(classify(housing(background: grey, lamp: (255, 40, 30), lampY: 0.2), width: 24, height: 60), .red)
        XCTAssertEqual(classify(housing(background: grey, lamp: (255, 200, 30), lampY: 0.5), width: 24, height: 60), .yellow)
        XCTAssertEqual(classify(housing(background: grey, lamp: (40, 240, 160), lampY: 0.8), width: 24, height: 60), .green)
        XCTAssertEqual(classify(housing(background: grey, lamp: nil, lampY: 0.5), width: 24, height: 60), .unknown)
    }

    /// The audit's defect: sky-blue (hue 197) and sunlit foliage around the housing voted green, so a red light
    /// against the sky was reported GREEN. Now the background alone is unknown and never turns a red lamp green.
    func testSkyAndFoliageBackgroundNeverReadAsGreen() {
        for background in [(135, 206, 235), (110, 200, 240), (120, 180, 60)] as [(UInt8, UInt8, UInt8)] {
            let empty = housing(background: background, lamp: nil, lampY: 0.2, border: 4)
            XCTAssertEqual(classify(empty, width: 24, height: 60), .unknown, "\(background)")
            let plain = housing(background: background, lamp: nil, lampY: 0.2, border: 30)
            XCTAssertEqual(classify(plain, width: 24, height: 60), .unknown, "\(background) only")
            let red = housing(background: background, lamp: (255, 30, 30), lampY: 0.2, border: 4)
            XCTAssertNotEqual(classify(red, width: 24, height: 60), .green, "\(background)")
            XCTAssertNotEqual(classify(red, width: 24, height: 60), .yellow, "\(background)")
        }
        // With a tight box (thin sky border) the red lamp is read.
        let tight = housing(background: (135, 206, 235), lamp: (255, 30, 30), lampY: 0.2, border: 1)
        XCTAssertEqual(classify(tight, width: 24, height: 60), .red)
    }

    /// Overexposed red core (hue 28, "amber") in the top section of a vertical housing reads red (position prior),
    /// the same colour in the middle section reads yellow.
    func testOverexposedRedCoreUsesThePositionPrior() {
        let grey: (UInt8, UInt8, UInt8) = (120, 120, 120)
        XCTAssertEqual(classify(housing(background: grey, lamp: (255, 150, 60), lampY: 0.2), width: 24, height: 60), .red)
        XCTAssertEqual(classify(housing(background: grey, lamp: (255, 150, 60), lampY: 0.5), width: 24, height: 60), .yellow)
    }

    /// A dim lamp in daylight (V ≈ 0.4, below the old absolute 0.55) is still read thanks to the relative threshold.
    func testDimLampIsReadRelativeToTheCrop() {
        let dimGreen = housing(background: (70, 70, 70), lamp: (20, 105, 70), lampY: 0.8)
        XCTAssertEqual(classify(dimGreen, width: 24, height: 60), .green)
    }

    func testPercentileMatchesNumpyDefinition() {
        var histogram = [Int](repeating: 0, count: 256)
        for level in [0, 51, 102, 255] { histogram[level] += 1 }             // values 0, 0.2, 0.4, 1.0
        XCTAssertEqual(TrafficLightColorClassifier.percentile(histogram, count: 4, fraction: 0.9), 0.82, accuracy: 1e-9)
        XCTAssertEqual(TrafficLightColorClassifier.percentile(histogram, count: 4, fraction: 0.25), 0.15, accuracy: 1e-9)
        XCTAssertEqual(TrafficLightColorClassifier.percentile(histogram, count: 4, fraction: 1), 1, accuracy: 1e-9)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: []), .unknown)
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: [RGBPixel(r: 255, g: 0, b: 0)], width: 2, height: 2),
                       .unknown)
        XCTAssertEqual(TrafficLightColorClassifier.samplingStep(rectWidth: 100, rectHeight: 260), 4)
        XCTAssertEqual(TrafficLightColorClassifier.samplingStep(rectWidth: 5, rectHeight: 12), 1)
    }
}

// MARK: - Finding 10: STOP sign episode

final class StopSignEpisodeTests: XCTestCase {
    private func sign(distance: Double) -> TrackedObject {
        // f ≈ 1507 px in the default portrait geometry: width = f · 0.7 / (d · 1080).
        let width = portrait.focalLengthPixels * 0.7 / (distance * 1080)
        return TrackedObject(id: 3, kind: .stopSign, label: "stop sign", box: BBox(x: 0.7, y: 0.3, width: width, height: width),
                             confidence: 0.8, hits: 5, firstSeen: 0, lastSeen: 0, isConfirmed: true)
    }

    func testGentleBrakingAfterTheSignLeftTheFrameIsNotAViolation() {
        var m = StopSignComplianceMonitor()
        var violations: [StopSignComplianceMonitor.Violation] = []
        var t = 0.0
        // Approach at 15 km/h: sign at 20 m … 6.4 m, then it leaves the field of view.
        var d = 20.0
        while d > 6.4 {
            if let v = m.update(tracks: [sign(distance: d)], geometry: portrait, speedKmh: 15, timestamp: t) { violations.append(v) }
            d -= 15 / 3.6 * 0.1
            t += 0.1
        }
        XCTAssertTrue(m.isArmed)
        // Smooth braking to a full stop in 4 s (the old monitor judged at +2.5 s, at ≈ 5.7 km/h → violation).
        let lost = t
        while t < lost + 14 {
            let speed = max(0, 15 * (1 - (t - lost) / 4))
            if let v = m.update(tracks: [], geometry: portrait, speedKmh: speed, timestamp: t) { violations.append(v) }
            t += 0.1
        }
        XCTAssertTrue(violations.isEmpty)
        XCTAssertFalse(m.isArmed)
    }

    func testDrivingThroughIsStillAViolation() {
        var m = StopSignComplianceMonitor()
        var violations: [(Double, StopSignComplianceMonitor.Violation)] = []
        var t = 0.0
        var d = 20.0
        while d > 6.4 {
            _ = m.update(tracks: [sign(distance: d)], geometry: portrait, speedKmh: 15, timestamp: t)
            d -= 15 / 3.6 * 0.1
            t += 0.1
        }
        let lost = t
        while t < lost + 12 {
            if let v = m.update(tracks: [], geometry: portrait, speedKmh: 15, timestamp: t) { violations.append((t - lost, v)) }
            t += 0.1
        }
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.1.minSpeedKmh ?? 0, 15, accuracy: 0.01)
        // Judged once the car is ≈ 10 m past the sign (16.4 m at 4.17 m/s ≈ 3.9 s), not at the 10 s cap.
        XCTAssertEqual(violations.first?.0 ?? 0, 4.0, accuracy: 0.4)
    }

    func testCreepingForeverEndsAtTheCap() {
        var m = StopSignComplianceMonitor()
        _ = m.update(tracks: [sign(distance: 8)], geometry: portrait, speedKmh: 10, timestamp: 0)
        var violation: StopSignComplianceMonitor.Violation?
        var at = 0.0
        var t = 0.1
        while t < 15, violation == nil {
            violation = m.update(tracks: [], geometry: portrait, speedKmh: 6, timestamp: t)
            at = t
            t += 0.1
        }
        XCTAssertEqual(violation?.minSpeedKmh ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(at, 10, accuracy: 0.3)       // 6 km/h for 10 s = 16.7 m < 8 + 10 m → the hard cap decides
    }
}

// MARK: - Findings 11, 12

final class DetectorHardeningTests: XCTestCase {
    func testSameVehicleAsCarAndTruckIsCountedOnce() {
        let tracker = ObjectTracker()
        let box = BBox(x: 0.4, y: 0.5, width: 0.2, height: 0.2)
        var tracks: [TrackedObject] = []
        for i in 0..<6 {
            let detections = CrossClassDuplicates.suppress([
                Detection(kind: .car, label: "car", confidence: 0.6, box: box),
                Detection(kind: .truck, label: "truck", confidence: 0.45,
                          box: BBox(x: 0.405, y: 0.5, width: 0.2, height: 0.2)),
            ])
            tracks = tracker.update(detections: detections, timestamp: Double(i) / 15)
        }
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracker.totalUniqueVehicles, 1)
    }

    func testEndToEndDecoderSkipsNonFiniteRows() {
        var v = [Float](repeating: 0, count: 300 * 6)
        func row(_ index: Int, _ values: [Float]) { for (k, value) in values.enumerated() { v[index * 6 + k] = value } }
        row(0, [64, 64, 192, 128, 0.9, .nan])
        row(1, [64, 64, 192, 128, 0.9, .infinity])
        row(2, [64, 64, 192, 128, 0.9, -1])
        row(3, [64, 64, 192, 128, 0.9, 1e30])
        row(4, [.nan, 64, 192, 128, 0.9, 2])
        row(5, [64, 64, .infinity, 128, 0.9, 2])
        row(6, [100, 100, 200, 200, 0.8, 2])
        let d = YOLODecoder.decode(values: v, shape: [1, 300, 6], inputWidth: 640, inputHeight: 640,
                                   confidenceThreshold: 0.25, iouThreshold: 0.45)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.classIndex, 2)
        XCTAssertEqual(d.first?.score ?? 0, 0.8, accuracy: 1e-6)
    }
}

// MARK: - People: own-lane danger regardless of role, road-relative crossing intent, hi-vis rules

final class PeopleDesignTests: XCTestCase {
    func testPersonInOwnLaneIsAlwaysDangerWhateverTheRole() {
        for role in [PersonRole.trafficOfficer, .roadWorker, .pedestrian] {
            let d = PedestrianHazardDetector()
            let r = d.evaluate(tracks: [person(1, BBox(x: 0.48, y: 0.58, width: 0.04, height: 0.12), role: role)],
                               ownSpeedKmh: 40, geometry: portrait, timestamp: 0)
            XCTAssertEqual(r.hazards.map(\.trackID), [1], "\(role)")
            XCTAssertEqual(r.hazards.first?.level, .danger, "\(role)")
            XCTAssertEqual(r.hazards.first?.inOwnLane, true)
            // Staff keep their sighting too (banner / overlay colour).
            XCTAssertEqual(r.staff.map(\.trackID), role.isRoadStaff ? [1] : [], "\(role)")
            XCTAssertEqual(r.staff.first?.inOwnLane, role.isRoadStaff ? true : nil)
        }
    }

    func testStaffOnTheShoulderOrInAnotherLaneIsNotAHazard() {
        let d = PedestrianHazardDetector()
        // On the roadway outside the own lane, standing: sighting only.
        let other = d.evaluate(tracks: [person(1, BBox(x: 0.70, y: 0.58, width: 0.04, height: 0.12), role: .roadWorker)],
                               ownSpeedKmh: 40, geometry: portrait, timestamp: 0)
        XCTAssertTrue(other.hazards.isEmpty)
        XCTAssertEqual(other.staff.map(\.trackID), [1])
        // On the shoulder (outside the zone, inside `staffEdgeMargin`): kept by the sidewalk filter, sighting only.
        let zone = d.effectiveRoadway
        let edge = zone.bounds(atY: 0.7)!.maxX, half = zone.halfWidth(atY: 0.7)
        let shoulder = person(2, BBox(x: edge + 0.5 * half - 0.02, y: 0.58, width: 0.04, height: 0.12), role: .trafficOfficer)
        let r = d.evaluate(tracks: [shoulder], ownSpeedKmh: 40, geometry: portrait, timestamp: 0)
        XCTAssertEqual(r.relevantIDs, [2])
        XCTAssertTrue(r.filteredIDs.isEmpty)
        XCTAssertTrue(r.hazards.isEmpty)
        XCTAssertEqual(r.staff.first?.onRoadway, false)
        // The same spot without a staff role is the sidewalk.
        var plain = shoulder
        plain.personRole = nil
        XCTAssertEqual(PedestrianHazardDetector().evaluate(tracks: [plain], ownSpeedKmh: 40, geometry: portrait,
                                                           timestamp: 0).filteredIDs, [2])
    }

    func testWorkerWalkingIntoTheLaneIsDanger() {
        let d = PedestrianHazardDetector()
        var r = PersonSceneResult()
        for i in 0..<8 {
            let t = Double(i) * 0.1
            // On the roadway (zone), outside the corridor, walking toward the centre.
            r = d.evaluate(tracks: [person(1, BBox(x: 0.72 - 0.012 * Double(i), y: 0.58, width: 0.04, height: 0.12),
                                           t: t, role: .roadWorker)],
                           ownSpeedKmh: 40, geometry: portrait, timestamp: t)
        }
        XCTAssertEqual(r.hazards.first?.level, .danger)
        XCTAssertEqual(r.hazards.first?.approaching, true)
        XCTAssertEqual(r.staff.count, 1)
    }

    /// Car driving forward at 8 m/s; frames at 15 fps; landscape camera. A pedestrian STANDING 6 m to the side drifts
    /// outward in the image and must not count as approaching; one WALKING toward the road at 1.4 m/s hardly moves in
    /// image x (perspective expansion cancels the walking) and must count.
    func testCrossingIntentIsRoadRelative() {
        let scene = Scene(geometry: landscape)
        func run(walkSpeed: Double) -> (result: PersonSceneResult, imageDX: Double) {
            let d = PedestrianHazardDetector()
            var r = PersonSceneResult()
            var firstX = 0.0, lastX = 0.0
            for i in 0...15 {
                let t = Double(i) / 15
                let box = scene.box(x: 6.0 - walkSpeed * t, z: 25 - 8 * t, width: 0.5, height: 1.7)
                if i == 0 { firstX = box.midX }
                lastX = box.midX
                r = d.evaluate(tracks: [person(1, box, t: t)], ownSpeedKmh: 29, geometry: landscape, timestamp: t)
            }
            return (r, lastX - firstX)
        }
        let standing = run(walkSpeed: 0)
        XCTAssertGreaterThan(standing.imageDX, 0.04)                 // drifts outward (away from the centre) in the image
        XCTAssertTrue(standing.result.hazards.isEmpty)
        XCTAssertEqual(standing.result.filteredIDs, [1])             // sidewalk: not shown at all

        let walking = run(walkSpeed: 1.4)
        XCTAssertGreaterThan(walking.imageDX, 0)                     // image x still moves OUTWARD: the old test missed it
        XCTAssertEqual(walking.result.relevantIDs, [1])
        XCTAssertEqual(walking.result.hazards.first?.approaching, true)
        XCTAssertEqual(walking.result.hazards.first?.level, .caution)
    }

    /// Driving straight past a person standing on the sidewalk never makes them "approaching", whatever the depth.
    func testStandingPersonIsConstantInRoadRelativeCoordinates() {
        let scene = Scene(geometry: landscape)
        let d = PedestrianHazardDetector()
        for i in 0...40 {
            let t = Double(i) / 15
            let box = scene.box(x: -8, z: 40 - 10 * t, width: 0.5, height: 1.7)
            let r = d.evaluate(tracks: [person(1, box, t: t)], ownSpeedKmh: 36, geometry: landscape, timestamp: t)
            XCTAssertTrue(r.hazards.isEmpty, "frame \(i)")
        }
    }

    func testPerspectiveHalfWidth() {
        let zone = RoadwayZone.fromCorridor(EgoCorridor(), widthFactor: 2.2)
        XCTAssertEqual(PedestrianHazardDetector.perspectiveHalfWidth(of: zone, atY: 1), 2.2 * 0.2, accuracy: 1e-4)
        XCTAssertEqual(PedestrianHazardDetector.perspectiveHalfWidth(of: zone, atY: 0.71), 2.2 * 0.1, accuracy: 1e-4)
        XCTAssertEqual(PedestrianHazardDetector.perspectiveHalfWidth(of: zone, atY: 0.3), 0)
    }

    // MARK: Hi-vis colour gates and vote

    func testRelaxedVestGates() {
        // Lime vest in shade (S 0.4, V 0.5): missed by the old gates (S ≥ 0.5, V ≥ 0.6).
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 102, g: 128, b: 77)), .lime)
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 200, g: 255, b: 0)), .lime)
        // Saturated orange vest.
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 255, g: 100, b: 10)), .orange)
        // Skin tone (hue ≈ 25°, S ≈ 0.45) is not a vest any more (orange needs S ≥ 0.70).
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 220, g: 170, b: 120)), .other)
        // Navy uniform cloth vs ordinary blue.
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 30, g: 40, b: 100)), .navy)
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 60, g: 90, b: 220)), .other)
        XCTAssertEqual(PersonRoleClassifier.pixelClass(RGBPixel(r: 20, g: 20, b: 30)), .dark)
        XCTAssertEqual(PersonRoleClassifier.minVestShare, 0.15)
    }

    func testOfficerNeedsDarkLowerBodyAndNoOrange() {
        func sample(lime: Double, orange: Double, lower: Double?) -> PersonRoleSample {
            PersonRoleSample(limeShare: lime, orangeShare: orange, darkShare: 0.3, torsoPixels: 100, lowerDarkShare: lower)
        }
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.3, orange: 0, lower: 0.85)), .trafficOfficer)
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.3, orange: 0, lower: 0.2)), .roadWorker)     // jeans / light trousers
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.3, orange: 0.1, lower: 0.85)), .roadWorker)  // lime + orange
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.05, orange: 0.3, lower: 0.85)), .roadWorker)
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.14, orange: 0.1, lower: 0.85)), .pedestrian) // below 0.15
        // Without the lower-body measurement the whole-box dark share decides, as before.
        XCTAssertEqual(PersonRoleClassifier.classify(sample(lime: 0.3, orange: 0, lower: nil)), .trafficOfficer)
    }

    func testBGRASampleMeasuresTheLowerBody() {
        // 60 × 120 person: lime torso band, navy legs.
        let w = 60, h = 120
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let fy = Double(y) / Double(h)
                let p: (UInt8, UInt8, UInt8) = fy >= 0.22 && fy < 0.62 ? (200, 255, 0) : (30, 40, 100)     // r g b
                let i = (y * w + x) * 4
                bytes[i] = p.2; bytes[i + 1] = p.1; bytes[i + 2] = p.0; bytes[i + 3] = 255
            }
        }
        let sample = bytes.withUnsafeBytes { raw in
            PersonRoleClassifier.sampleBGRA(base: raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4, rectX: 0,
                                            rectY: 0, rectWidth: w, rectHeight: h, step: 2)
        }
        XCTAssertGreaterThan(sample?.lowerDarkShare ?? 0, 0.9)
        XCTAssertGreaterThan(sample?.limeShare ?? 0, 0.9)
        XCTAssertEqual(sample.map(PersonRoleClassifier.classify), .trafficOfficer)
    }

    func testRoleVoteHysteresis() {
        let p = PersonRole.pedestrian, o = PersonRole.trafficOfficer, w = PersonRole.roadWorker
        XCTAssertEqual(PersonRoleClassifier.voteWindow, 15)
        // Fewer than 5 observations: nothing yet.
        XCTAssertNil(PersonRoleClassifier.majority([o, o, o, o]))
        // Enter at 60 % staff (officer + worker pooled), the more frequent names the role.
        XCTAssertEqual(PersonRoleClassifier.majority([o, o, w, p, p, o, o, w, p, p]), .trafficOfficer)       // 6 of 10
        XCTAssertEqual(PersonRoleClassifier.majority([o, o, w, p, p, p, o, w, p, p]), .pedestrian)           // 5 of 10
        // A pedestrian in a yellow jacket with a few false frames (≈ 7 % per frame measured) never becomes staff.
        XCTAssertEqual(PersonRoleClassifier.majority([p, p, w, p, p, p, p, p, o, p, p, p, p, p, p]), .pedestrian)
        // Keep down to 30 %, drop below.
        XCTAssertEqual(PersonRoleClassifier.majority([w, p, p, w, p, p, w, p, p, p], previous: .roadWorker), .roadWorker)
        XCTAssertEqual(PersonRoleClassifier.majority([w, p, p, p, p, p, w, p, p, p], previous: .roadWorker), .pedestrian)
        // A tie keeps the previous staff role.
        XCTAssertEqual(PersonRoleClassifier.majority([o, w, o, w, p], previous: .roadWorker), .roadWorker)
    }
}
