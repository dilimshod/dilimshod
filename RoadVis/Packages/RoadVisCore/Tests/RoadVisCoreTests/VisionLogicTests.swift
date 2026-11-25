import XCTest
@testable import RoadVisCore

final class VisionLogicTests: XCTestCase {
    func det(_ kind: VehicleKind, _ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.1, conf: Double = 0.8) -> Detection {
        Detection(kind: kind, label: kind.rawValue, confidence: conf, box: BBox(x: x, y: y, width: w, height: h))
    }

    func testLabelMapping() {
        XCTAssertEqual(VehicleKind(label: "car"), .car)
        XCTAssertEqual(VehicleKind(label: "traffic light"), .trafficLight)
        XCTAssertEqual(VehicleKind(label: "Motorbike"), .motorcycle)
        XCTAssertEqual(VehicleKind(cocoIndex: 7), .truck)
        XCTAssertNil(VehicleKind(label: "banana"))
    }

    func testBBoxIoUAndVision() {
        let a = BBox(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = BBox(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(a.iou(b), 0.0625 / (0.25 + 0.25 - 0.0625), accuracy: 1e-9)
        let v = BBox(visionX: 0.1, visionY: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(v.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(v.visionY, 0.2, accuracy: 1e-9)
    }

    func testTrackerCountsUniqueOnlyOnce() {
        let tracker = ObjectTracker(config: .init(iouThreshold: 0.3, maxMissed: 3, minHits: 3))
        // One car moving slowly across 10 frames → one unique car.
        for i in 0..<10 {
            _ = tracker.update(detections: [det(.car, 0.1 + Double(i) * 0.01, 0.5)], timestamp: Double(i) * 0.1)
        }
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
        XCTAssertEqual(tracker.frameDetectionCount, 10)
        XCTAssertEqual(tracker.totalUniqueVehicles, 1)
    }

    func testTrackerIgnoresFlicker() {
        let tracker = ObjectTracker(config: .init(minHits: 3))
        _ = tracker.update(detections: [det(.bus, 0.5, 0.5)], timestamp: 0)
        _ = tracker.update(detections: [], timestamp: 0.1)
        XCTAssertNil(tracker.uniqueCounts[.bus])
    }

    func testTrackerTwoObjectsAndMakeVote() {
        let tracker = ObjectTracker(config: .init(minHits: 2))
        var tracks: [TrackedObject] = []
        for i in 0..<5 {
            tracks = tracker.update(detections: [det(.car, 0.1, 0.5), det(.truck, 0.7, 0.5)], timestamp: Double(i) * 0.1)
        }
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
        XCTAssertEqual(tracker.uniqueCounts[.truck], 1)
        let car = tracks.first { $0.kind == .car }!
        tracker.addMakeObservation(trackID: car.id, make: "Chevrolet", confidence: 0.7)
        tracker.addMakeObservation(trackID: car.id, make: "Chevrolet", confidence: 0.6)
        tracker.addMakeObservation(trackID: car.id, make: "Daewoo", confidence: 0.9)
        tracks = tracker.update(detections: [det(.car, 0.1, 0.5), det(.truck, 0.7, 0.5)], timestamp: 0.6)
        XCTAssertEqual(tracks.first { $0.id == car.id }?.make, "Chevrolet")
    }

    func testTrackerCarTruckConfusionKeepsOneTrack() {
        let tracker = ObjectTracker(config: .init(minHits: 2))
        for i in 0..<6 {
            let kind: VehicleKind = i % 3 == 0 ? .truck : .car
            _ = tracker.update(detections: [det(kind, 0.4, 0.4, 0.2, 0.2)], timestamp: Double(i) * 0.1)
        }
        let total = (tracker.uniqueCounts[.car] ?? 0) + (tracker.uniqueCounts[.truck] ?? 0)
        XCTAssertEqual(total, 1)
    }

    func testMonocularDistance() {
        let g = CameraGeometry(horizontalFOVDegrees: 65, imageWidth: 1080, imageHeight: 1920)
        // f = 960 / tan(32.5°) ≈ 1507 px. Car 1.5 m with box height 0.05*1920 = 96 px → ≈ 23.5 m
        let z = MonocularDistance.distance(realHeight: 1.5, normalizedBoxHeight: 0.05, geometry: g)!
        XCTAssertEqual(z, 23.5, accuracy: 0.5)
        XCTAssertNil(MonocularDistance.distance(realHeight: 1.5, normalizedBoxHeight: 0.001, geometry: g))
    }

    func testMonocularSpeedApproaching() {
        let g = CameraGeometry.defaultPortrait
        let est = MonocularSpeedEstimator(windowSeconds: 2)
        var out: [TrackedObject] = []
        // Car ahead getting closer at 5 m/s relative: Z from 30 m down.
        for i in 0..<15 {
            let t = Double(i) * 0.1
            let z = 30 - 5 * t
            let h = g.focalLengthPixels * 1.5 / z / g.imageHeight
            let obj = TrackedObject(id: 1, kind: .car, label: "car", box: BBox(x: 0.45, y: 0.5, width: 0.1, height: h),
                                    confidence: 0.9, firstSeen: 0, lastSeen: t)
            out = est.update(tracks: [obj], ownSpeedKmh: 60, geometry: g, timestamp: t)
        }
        let rel = out[0].relativeSpeedKmh!
        XCTAssertEqual(rel, -18, accuracy: 1.0)
        XCTAssertEqual(out[0].estimatedSpeedKmh!, 42, accuracy: 1.0)
        XCTAssertEqual(out[0].distanceMeters!, 23.1, accuracy: 0.6)
    }
}
