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

    func testFastMovingObjectKeepsOneTrack() {
        // An oncoming car crossing the frame: its box jumps ~1.3 widths per frame (IoU = 0), growing as it approaches.
        let tracker = ObjectTracker(config: .init(minHits: 3))
        var ids = Set<Int>()
        for i in 0..<8 {
            let w = 0.06 + Double(i) * 0.01
            let box = BBox(x: 0.2 + Double(i) * 0.08, y: 0.5, width: w, height: w * 0.8)
            let t = tracker.update(detections: [Detection(kind: .car, label: "car", confidence: 0.8, box: box)],
                                   timestamp: Double(i) / 15)
            ids.formUnion(t.map(\.id))
        }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(tracker.uniqueCounts[.car], 1)
    }

    func testReacquireAfterShortMiss() {
        let tracker = ObjectTracker(config: .init(minHits: 2))
        var ids = Set<Int>()
        for i in 0..<10 where i != 4 && i != 5 {   // two missed frames
            let box = BBox(x: 0.3 + Double(i) * 0.03, y: 0.5, width: 0.1, height: 0.08)
            let t = tracker.update(detections: [Detection(kind: .car, label: "car", confidence: 0.8, box: box)],
                                   timestamp: Double(i) / 15)
            ids.formUnion(t.map(\.id))
        }
        XCTAssertEqual(ids.count, 1)
    }

    func testTwoNeighboursNotMerged() {
        let tracker = ObjectTracker(config: .init(minHits: 2))
        for i in 0..<6 {
            let a = BBox(x: 0.30, y: 0.5, width: 0.08, height: 0.08)
            let b = BBox(x: 0.45, y: 0.5, width: 0.08, height: 0.08)
            _ = tracker.update(detections: [Detection(kind: .car, label: "car", confidence: 0.8, box: a),
                                            Detection(kind: .car, label: "car", confidence: 0.8, box: b)],
                               timestamp: Double(i) / 15)
        }
        XCTAssertEqual(tracker.uniqueCounts[.car], 2)
    }

    func testPerClassConfidenceFilter() {
        let tracker = ObjectTracker(config: .init(minHits: 1))
        _ = tracker.update(detections: [Detection(kind: .trafficLight, label: "traffic light", confidence: 0.42,
                                                  box: BBox(x: 0.5, y: 0.1, width: 0.02, height: 0.05))], timestamp: 0)
        XCTAssertNil(tracker.uniqueCounts[.trafficLight])
        _ = tracker.update(detections: [Detection(kind: .trafficLight, label: "traffic light", confidence: 0.6,
                                                  box: BBox(x: 0.5, y: 0.1, width: 0.02, height: 0.05))], timestamp: 0.1)
        XCTAssertEqual(tracker.uniqueCounts[.trafficLight], 1)
    }

    func testExperimentLeadAndConfirmedColumns() {
        let log = ExperimentLog(modelName: "m", startedAt: Date(timeIntervalSince1970: 0))
        log.append(ExperimentRecord(timestamp: Date(timeIntervalSince1970: 0), frameIndex: 1, trackID: 1, kind: .car,
                                    label: "car", confidence: 0.9, box: BBox(x: 0, y: 0, width: 0.1, height: 0.1),
                                    distanceMeters: 18, isConfirmed: true, trackHits: 5, isLead: true))
        log.append(ExperimentRecord(timestamp: Date(timeIntervalSince1970: 0), frameIndex: 1, trackID: 2, kind: .car,
                                    label: "car", confidence: 0.5, box: BBox(x: 0.5, y: 0, width: 0.1, height: 0.1),
                                    isConfirmed: false, trackHits: 1))
        let rows = log.detectionsCSV().split(separator: "\n")
        XCTAssertTrue(rows[1].hasSuffix(",1,5,1"))
        XCTAssertTrue(rows[2].hasSuffix(",0,1,0"))
        let s = log.summaryCSV(uniqueCounts: [.car: 1], endedAt: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(s.contains("car,2,1,2,1,0.700"))
        XCTAssertTrue(s.contains("# lead_vehicle_rows,1"))
        XCTAssertTrue(s.contains("# lead_distance_median_m_est,18.0"))
    }
}
