import XCTest
@testable import RoadVisCore

final class PersonRoleAndRoadwayTests: XCTestCase {
    let g = CameraGeometry.defaultPortrait

    // MARK: - Synthetic person images

    /// BGRA image of `w`×`h` filled with `background`, with a person box: head/legs in `legs`, torso band in `vest`.
    func personImage(w: Int = 60, h: Int = 120, background: RGBPixel, vest: RGBPixel, legs: RGBPixel) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let fy = Double(y) / Double(h), fx = Double(x) / Double(w)
                var p = background
                if fx >= 0.2 && fx < 0.8 {
                    p = fy >= 0.22 && fy < 0.62 ? vest : legs
                }
                let i = (y * w + x) * 4
                bytes[i] = p.b
                bytes[i + 1] = p.g
                bytes[i + 2] = p.r
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    func classify(_ bytes: [UInt8], w: Int = 60, h: Int = 120) -> PersonRole? {
        bytes.withUnsafeBytes { raw in
            PersonRoleClassifier.classifyBGRA(base: raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4,
                                              rectX: 0, rectY: 0, rectWidth: w, rectHeight: h, step: 1)
        }
    }

    let gray = RGBPixel(r: 128, g: 128, b: 128)
    let lime = RGBPixel(r: 200, g: 245, b: 30)       // fluorescent yellow-green, hue ≈ 74°
    let orange = RGBPixel(r: 255, g: 110, b: 20)     // fluorescent orange, hue ≈ 23°
    let darkNavy = RGBPixel(r: 20, g: 25, b: 45)
    let jeans = RGBPixel(r: 70, g: 90, b: 140)

    func testOfficerVestOverDarkUniform() {
        XCTAssertEqual(classify(personImage(background: gray, vest: lime, legs: darkNavy)), .trafficOfficer)
    }

    func testRoadWorkerOrangeVest() {
        XCTAssertEqual(classify(personImage(background: gray, vest: orange, legs: jeans)), .roadWorker)
        XCTAssertEqual(classify(personImage(background: gray, vest: orange, legs: darkNavy)), .roadWorker)
    }

    func testLimeVestWithoutDarkClothesIsWorker() {
        XCTAssertEqual(classify(personImage(background: gray, vest: lime, legs: jeans)), .roadWorker)
    }

    func testOrdinaryClothesArePedestrian() {
        XCTAssertEqual(classify(personImage(background: gray, vest: RGBPixel(r: 180, g: 40, b: 40), legs: darkNavy)),
                       .pedestrian)
        // A pale yellow shirt is not saturated enough for a hi-vis vest.
        XCTAssertEqual(classify(personImage(background: gray, vest: RGBPixel(r: 230, g: 230, b: 170), legs: jeans)),
                       .pedestrian)
    }

    func testSmallBoxNotClassified() {
        let bytes = personImage(w: 20, h: 30, background: gray, vest: lime, legs: darkNavy)
        XCTAssertNil(classify(bytes, w: 20, h: 30))
    }

    func testMinimumVestShare() {
        // 10 % lime torso pixels: below the 12 % minimum.
        var torso = [RGBPixel](repeating: gray, count: 90)
        torso += [RGBPixel](repeating: lime, count: 10)
        let box = torso + [RGBPixel](repeating: darkNavy, count: 50)
        XCTAssertEqual(PersonRoleClassifier.classify(torso: torso, box: box), .pedestrian)
        torso = [RGBPixel](repeating: gray, count: 80) + [RGBPixel](repeating: lime, count: 20)
        XCTAssertEqual(PersonRoleClassifier.classify(torso: torso, box: torso + [RGBPixel](repeating: darkNavy, count: 50)),
                       .trafficOfficer)
    }

    // MARK: - Voting

    func testMajorityVote() {
        let o = PersonRole.trafficOfficer, p = PersonRole.pedestrian
        XCTAssertNil(PersonRoleClassifier.majority([o, o, o, o]))                       // fewer than 5 observations
        XCTAssertEqual(PersonRoleClassifier.majority([o, o, p, o, o]), o)
        XCTAssertEqual(PersonRoleClassifier.majority([o, p, o, p, .roadWorker, p]), .pedestrian)   // no majority, no previous
        // No strict majority: the previous role is kept.
        XCTAssertEqual(PersonRoleClassifier.majority([o, o, p, p, .roadWorker, .roadWorker], previous: o), o)
    }

    func testTrackerVotesPersonRole() {
        let tracker = ObjectTracker(config: .init(minHits: 1))
        let box = BBox(x: 0.4, y: 0.4, width: 0.05, height: 0.15)
        var tracks: [TrackedObject] = []
        let roles: [PersonRole] = [.trafficOfficer, .pedestrian, .trafficOfficer, .trafficOfficer, .trafficOfficer,
                                   .pedestrian]
        for (i, role) in roles.enumerated() {
            tracks = tracker.update(detections: [Detection(kind: .person, label: "person", confidence: 0.8, box: box,
                                                           personRole: role)], timestamp: Double(i) * 0.07)
            if i < 4 { XCTAssertNil(tracks.first?.personRole, "frame \(i)") }
        }
        XCTAssertEqual(tracks.first?.personRole, .trafficOfficer)   // a single "pedestrian" frame does not flip it
    }

    func testDeferredCounting() {
        let tracker = ObjectTracker(config: .init(minHits: 1, deferredCountKinds: [.person]))
        let tracks = tracker.update(detections: [Detection(kind: .person, label: "person", confidence: 0.8,
                                                           box: BBox(x: 0.4, y: 0.4, width: 0.05, height: 0.15))],
                                    timestamp: 0)
        XCTAssertEqual(tracker.uniqueCounts[.person] ?? 0, 0)
        tracker.markRelevant(trackIDs: tracks.map(\.id))
        tracker.markRelevant(trackIDs: tracks.map(\.id))
        XCTAssertEqual(tracker.uniqueCounts[.person], 1)
    }

    // MARK: - Roadway zone

    func person(_ id: Int, x: Double, bottom: Double, h: Double = 0.12, t: Double,
                role: PersonRole? = nil) -> TrackedObject {
        TrackedObject(id: id, kind: .person, label: "person", box: BBox(x: x - 0.02, y: bottom - h, width: 0.04, height: h),
                      confidence: 0.8, hits: 6, firstSeen: 0, lastSeen: t, isConfirmed: true, personRole: role)
    }

    func testZoneFromLanesExtendsOutward() {
        let estimate = LaneEstimate(left: LaneLine(bottomX: 0.1, bottomY: 1, topX: 0.48, topY: 0.44),
                                    right: LaneLine(bottomX: 0.9, bottomY: 1, topX: 0.52, topY: 0.44),
                                    leftConfidence: 0.8, rightConfidence: 0.8, laneCenterX: 0.5, egoOffset: 0,
                                    confidence: 0.8, referenceY: 0.96, timestamp: 0)
        let zone = RoadwayZone.fromLanes(estimate, horizonY: 0.42, extraLanesLeft: 1, extraLanesRight: 1,
                                         minConfidence: 0.45)
        XCTAssertEqual(zone?.source, .lanes)
        XCTAssertEqual(zone?.left.bottomX ?? 0, -0.7, accuracy: 1e-6)
        XCTAssertEqual(zone?.right.bottomX ?? 0, 1.7, accuracy: 1e-6)
        // One line only: mirrored through the lane centre.
        var one = estimate
        one.rightConfidence = 0.1
        let mirrored = RoadwayZone.fromLanes(one, horizonY: 0.42, extraLanesLeft: 0, extraLanesRight: 0,
                                             minConfidence: 0.45)
        XCTAssertNotNil(mirrored)
        XCTAssertGreaterThan(mirrored?.right.bottomX ?? 0, 0.8)
        // Nothing confident → corridor fallback in the estimator.
        one.leftConfidence = 0.1
        XCTAssertEqual(RoadwayZoneEstimator().update(lane: one, corridor: .default).source, .corridor)
    }

    func testZoneOutsideDistance() {
        let zone = RoadwayZone(leftBottom: 0, leftTop: 0.45, rightBottom: 1, rightTop: 0.55, horizonY: 0.4,
                               source: .corridor)
        XCTAssertEqual(zone.outsideDistance(x: 0.5, y: 0.8), 0)
        XCTAssertGreaterThan(zone.outsideDistance(x: 0.05, y: 0.6), 0.5)
        XCTAssertTrue(zone.outsideDistance(x: 0.5, y: 0.3).isInfinite)
        XCTAssertEqual(zone.polygon().count, 4)
    }

    func testSidewalkPedestrianFilteredOut() {
        let d = PedestrianHazardDetector()
        d.roadway = RoadwayZone(leftBottom: 0.1, leftTop: 0.47, rightBottom: 0.9, rightTop: 0.53, horizonY: 0.42,
                                source: .lanes)
        // Zone at y = 0.65: x ≈ 0.323…0.677; a person standing at x = 0.08 (sidewalk), not moving.
        var r = PersonSceneResult()
        for i in 0..<6 {
            let t = Double(i) * 0.1
            r = d.evaluate(tracks: [person(1, x: 0.08, bottom: 0.65, t: t)], ownSpeedKmh: 40, geometry: g, timestamp: t)
        }
        XCTAssertEqual(r.filteredIDs, [1])
        XCTAssertTrue(r.relevantIDs.isEmpty)
        XCTAssertTrue(r.hazards.isEmpty)
        // Walking along the sidewalk (away from the road) is filtered too.
        for i in 0..<6 {
            let t = 1 + Double(i) * 0.1
            r = d.evaluate(tracks: [person(2, x: 0.08 - 0.005 * Double(i), bottom: 0.65, t: t)], ownSpeedKmh: 40,
                           geometry: g, timestamp: t)
        }
        XCTAssertEqual(r.filteredIDs, [2])
    }

    func testCrossingPedestrianKept() {
        let d = PedestrianHazardDetector()
        d.roadway = RoadwayZone(leftBottom: 0.1, leftTop: 0.47, rightBottom: 0.9, rightTop: 0.53, horizonY: 0.42,
                                source: .lanes)
        // Starts outside the left boundary (≈ 0.323 at y = 0.65) and walks toward the road.
        var r = PersonSceneResult()
        for i in 0..<8 {
            let t = Double(i) * 0.1
            r = d.evaluate(tracks: [person(1, x: 0.18 + 0.01 * Double(i), bottom: 0.65, t: t)], ownSpeedKmh: 40,
                           geometry: g, timestamp: t)
        }
        XCTAssertEqual(r.relevantIDs, [1])
        XCTAssertEqual(r.hazards.first?.trackID, 1)
        XCTAssertEqual(r.hazards.first?.approaching, true)
    }

    func testOfficerOnRoadIsStaffNotHazard() {
        let d = PedestrianHazardDetector()
        let r = d.evaluate(tracks: [person(1, x: 0.5, bottom: 0.7, t: 0, role: .trafficOfficer),
                                    person(2, x: 0.02, bottom: 0.62, t: 0, role: .roadWorker)],
                           ownSpeedKmh: 40, geometry: g, timestamp: 0)
        XCTAssertTrue(r.hazards.isEmpty)
        XCTAssertEqual(r.staff.map(\.trackID), [1])
        XCTAssertEqual(r.staff.first?.role, .trafficOfficer)
        XCTAssertEqual(r.filteredIDs, [2])   // the worker far out on the sidewalk is not kept
    }

    func testStaffOnShoulderIsKeptButPedestrianThereIsNot() {
        let d = PedestrianHazardDetector()
        d.roadway = RoadwayZone(leftBottom: 0.1, leftTop: 0.47, rightBottom: 0.9, rightTop: 0.53, horizonY: 0.42,
                                source: .lanes)
        // Zone at y = 0.65: x ≈ 0.323…0.677 (half width ≈ 0.177). x = 0.25 is ≈ 0.41 half widths outside the left
        // boundary: the shoulder. An officer standing there is kept as staff beside the road; a pedestrian is not.
        let outside = d.effectiveRoadway.outsideDistance(x: 0.25, y: 0.65)
        XCTAssertGreaterThan(outside, 0.3)
        XCTAssertLessThan(outside, 0.5)
        var r = PersonSceneResult()
        for i in 0..<6 {
            let t = Double(i) * 0.1
            r = d.evaluate(tracks: [person(1, x: 0.25, bottom: 0.65, t: t, role: .trafficOfficer),
                                    person(2, x: 0.75, bottom: 0.65, t: t),
                                    person(3, x: 0.75, bottom: 0.65, t: t, role: .pedestrian)],
                           ownSpeedKmh: 40, geometry: g, timestamp: t)
        }
        XCTAssertEqual(r.relevantIDs, [1])
        XCTAssertEqual(r.filteredIDs, [2, 3])
        XCTAssertEqual(r.staff.map(\.trackID), [1])
        XCTAssertEqual(r.staff.first?.onRoadway, false)
        XCTAssertEqual(r.staff.first?.inOwnLane, false)
        XCTAssertTrue(r.hazards.isEmpty)
        // Beyond the staff margin (one roadway half width) even staff are filtered.
        let far = d.evaluate(tracks: [person(4, x: 0.05, bottom: 0.65, t: 1, role: .roadWorker)], ownSpeedKmh: 40,
                             geometry: g, timestamp: 1)
        XCTAssertGreaterThan(d.effectiveRoadway.outsideDistance(x: 0.05, y: 0.65), d.staffEdgeMargin)
        XCTAssertEqual(far.filteredIDs, [4])
        // Margin switched off: the old behaviour.
        d.reset()
        d.staffEdgeMargin = 0
        let strict = d.evaluate(tracks: [person(5, x: 0.25, bottom: 0.65, t: 2, role: .trafficOfficer)], ownSpeedKmh: 40,
                                geometry: g, timestamp: 2)
        XCTAssertEqual(strict.filteredIDs, [5])
    }

    // MARK: - Coach and trip events

    func testCoachAnnouncesOfficerOncePerCooldown() {
        let engine = DriverCoachEngine()
        let officer = RoadStaffSighting(trackID: 7, role: .trafficOfficer, box: BBox(x: 0.5, y: 0.5, width: 0.04, height: 0.12),
                                        distanceMeters: 30, onRoadway: true, inOwnLane: false)
        engine.updateRoadStaff([officer], now: 0)
        XCTAssertEqual(engine.next(now: 0), .trafficOfficerAhead(trackID: 7))
        engine.updateRoadStaff([officer], now: 10)
        XCTAssertNil(engine.next(now: 10))
        engine.updateRoadStaff([officer], now: 21)
        XCTAssertEqual(engine.next(now: 21), .trafficOfficerAhead(trackID: 7))
        var far = officer
        far.trackID = 8
        far.distanceMeters = 90
        engine.reset()
        engine.updateRoadStaff([far], now: 100)
        XCTAssertNil(engine.next(now: 100))
        let worker = RoadStaffSighting(trackID: 9, role: .roadWorker, box: officer.box, distanceMeters: 40,
                                       onRoadway: false, inOwnLane: false)
        engine.updateRoadStaff([worker], now: 101)
        XCTAssertEqual(engine.next(now: 101), .roadWorkersAhead(trackID: 9))
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.roadWorkersAhead(trackID: 9)), language: .uz),
                       ["road_workers_ahead"])
        XCTAssertEqual(VoiceComposer.composedText(for: .coach(.trafficOfficerAhead(trackID: 1)), language: .uz),
                       "Diqqat, oldinda YHXX xodimi")
    }

    func testStaffEventsAreInfoAndNotScored() {
        let monitor = CameraDrivingEventMonitor()
        let officer = RoadStaffSighting(trackID: 3, role: .trafficOfficer, box: BBox(x: 0.5, y: 0.5, width: 0.04, height: 0.12),
                                        distanceMeters: 25, onRoadway: true, inOwnLane: false)
        let events = monitor.update(CameraEventInput(timestamp: 0, speedKmh: 40, roadStaff: [officer]))
        XCTAssertEqual(events.map(\.kind), [.trafficOfficerSeen])
        XCTAssertEqual(events.first?.severity, .info)
        XCTAssertTrue(monitor.update(CameraEventInput(timestamp: 0.1, speedKmh: 40, roadStaff: [officer])).isEmpty)
        XCTAssertEqual(TripScoring.score(events: events, distanceMeters: 1000).score, 100)
        XCTAssertEqual(DrivingEventKind.roadWorkersSeen.defaultSeverity, .info)
    }
}
