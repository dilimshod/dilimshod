import XCTest
@testable import RoadVisCore

final class PedestrianHazardTests: XCTestCase {
    let g = CameraGeometry.defaultPortrait

    func person(_ id: Int, x: Double, bottom: Double, h: Double = 0.12, t: Double) -> TrackedObject {
        TrackedObject(id: id, kind: .person, label: "person", box: BBox(x: x - 0.02, y: bottom - h, width: 0.04, height: h),
                      confidence: 0.8, hits: 6, firstSeen: 0, lastSeen: t, isConfirmed: true)
    }

    func testPedestrianInOwnLaneIsDanger() {
        let d = PedestrianHazardDetector()
        let r = d.update(tracks: [person(1, x: 0.5, bottom: 0.7, t: 0)], ownSpeedKmh: 40, geometry: g, timestamp: 0)
        XCTAssertEqual(r.first?.level, .danger)
        XCTAssertEqual(r.first?.inOwnLane, true)
        XCTAssertNotNil(r.first?.distanceMeters)
    }

    func testPedestrianOnSidewalkIgnored() {
        let d = PedestrianHazardDetector()
        let r = d.update(tracks: [person(1, x: 0.02, bottom: 0.62, t: 0)], ownSpeedKmh: 40, geometry: g, timestamp: 0)
        XCTAssertTrue(r.isEmpty)
    }

    func testPedestrianOnRoadEdgeCaution() {
        let d = PedestrianHazardDetector()
        // Corridor half width at y=0.7 ≈ 0.04 + 0.2*(0.28/0.58) ≈ 0.137; road half ≈ 0.30.
        let r = d.update(tracks: [person(1, x: 0.25, bottom: 0.7, t: 0)], ownSpeedKmh: 40, geometry: g, timestamp: 0)
        XCTAssertEqual(r.first?.level, .caution)
        XCTAssertEqual(r.first?.onRoadway, true)
        XCTAssertEqual(r.first?.inOwnLane, false)
    }

    func testApproachingPedestrianEscalates() {
        let d = PedestrianHazardDetector()
        var r: [PedestrianHazard] = []
        for i in 0..<8 {
            let t = Double(i) * 0.1
            r = d.update(tracks: [person(1, x: 0.24 + 0.012 * Double(i), bottom: 0.7, t: t)], ownSpeedKmh: 30,
                         geometry: g, timestamp: t)
        }
        XCTAssertEqual(r.first?.approaching, true)
        XCTAssertEqual(r.first?.level, .danger)
    }

    func testFarPedestrianIgnored() {
        let d = PedestrianHazardDetector(maxDistance: 20)
        let r = d.update(tracks: [person(1, x: 0.5, bottom: 0.5, h: 0.03, t: 0)], ownSpeedKmh: 40, geometry: g, timestamp: 0)
        XCTAssertTrue(r.isEmpty)
    }

    func testHandAtBottomEdgeIgnored() {
        // A hand: wide box touching the bottom edge, in the middle of the frame.
        let hand = TrackedObject(id: 9, kind: .person, label: "person", box: BBox(x: 0.35, y: 0.7, width: 0.3, height: 0.3),
                                 confidence: 0.7, hits: 10, firstSeen: 0, lastSeen: 0, isConfirmed: true)
        XCTAssertTrue(PedestrianHazardDetector().update(tracks: [hand], ownSpeedKmh: 40, geometry: g, timestamp: 0).isEmpty)
    }

    func testLowConfidenceOrShortTrackIgnored() {
        let d = PedestrianHazardDetector()
        var p = person(1, x: 0.5, bottom: 0.7, t: 0)
        p.confidence = 0.45
        p.peakConfidence = 0.45
        XCTAssertTrue(d.update(tracks: [p], ownSpeedKmh: 40, geometry: g, timestamp: 0).isEmpty)
        // A one-frame dip of a track that was solid before does not silence the warning.
        var dip = person(3, x: 0.5, bottom: 0.7, t: 0)
        dip.confidence = 0.45
        XCTAssertEqual(dip.peakConfidence, 0.8)
        XCTAssertEqual(d.update(tracks: [dip], ownSpeedKmh: 40, geometry: g, timestamp: 0).first?.level, .danger)
        var q = person(2, x: 0.5, bottom: 0.7, t: 0)
        q.hits = 2
        XCTAssertTrue(d.update(tracks: [q], ownSpeedKmh: 40, geometry: g, timestamp: 0).isEmpty)
    }

    func testWideBoxNotAPedestrian() {
        let wide = TrackedObject(id: 3, kind: .person, label: "person", box: BBox(x: 0.4, y: 0.55, width: 0.15, height: 0.12),
                                 confidence: 0.9, hits: 10, firstSeen: 0, lastSeen: 0, isConfirmed: true)
        XCTAssertTrue(PedestrianHazardDetector().update(tracks: [wide], ownSpeedKmh: 40, geometry: g, timestamp: 0).isEmpty)
    }
}
