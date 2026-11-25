import XCTest
@testable import RoadVisionCore

final class YOLODecoderTests: XCTestCase {
    func testChannelsFirstWithNMS() {
        // nc = 3, N = 4 anchors → shape [1, 7, 4]
        let n = 10, c = 7  // nc = 3, N = 10 anchors (real models: N = 8400 > C = 84)
        var v = [Float](repeating: 0, count: c * n)
        func set(_ ch: Int, _ i: Int, _ x: Float) { v[ch * n + i] = x }
        // anchor 0: car-like (class 2) at center (320,320) 100x50, score 0.9
        set(0, 0, 320); set(1, 0, 320); set(2, 0, 100); set(3, 0, 50); set(6, 0, 0.9)
        // anchor 1: overlapping duplicate, score 0.8 → suppressed
        set(0, 1, 322); set(1, 1, 321); set(2, 1, 100); set(3, 1, 50); set(6, 1, 0.8)
        // anchor 2: other object class 0, score 0.5
        set(0, 2, 100); set(1, 2, 100); set(2, 2, 40); set(3, 2, 80); set(4, 2, 0.5)
        // anchor 3: below threshold
        set(0, 3, 500); set(1, 3, 500); set(2, 3, 10); set(3, 3, 10); set(5, 3, 0.1)
        let d = YOLODecoder.decode(values: v, shape: [1, c, n], inputWidth: 640, inputHeight: 640,
                                   confidenceThreshold: 0.25, iouThreshold: 0.45)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].classIndex, 2)
        XCTAssertEqual(d[0].box.x, (320 - 50) / 640.0, accuracy: 1e-6)
        XCTAssertEqual(d[0].box.width, 100 / 640.0, accuracy: 1e-6)
        XCTAssertEqual(d[1].classIndex, 0)
    }

    func testEndToEndLayout() {
        var v = [Float](repeating: 0, count: 300 * 6)
        v[0] = 64; v[1] = 64; v[2] = 192; v[3] = 128; v[4] = 0.8; v[5] = 7
        v[6] = 0; v[7] = 0; v[8] = 10; v[9] = 10; v[10] = 0.1; v[11] = 2
        let d = YOLODecoder.decode(values: v, shape: [1, 300, 6], inputWidth: 640, inputHeight: 640,
                                   confidenceThreshold: 0.25, iouThreshold: 0.45)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].classIndex, 7)
        XCTAssertEqual(VehicleKind(cocoIndex: d[0].classIndex), .truck)
        XCTAssertEqual(d[0].box.height, 64 / 640.0, accuracy: 1e-6)
    }

    func testLetterboxUndo() {
        // Source 1920x1080 letterboxed into 640x640: gain = 1/3, padY = (640 - 360)/2 = 140.
        var v = [Float](repeating: 0, count: 300 * 6)
        v[0] = 0; v[1] = 140; v[2] = 640; v[3] = 500; v[4] = 0.9; v[5] = 2
        let d = YOLODecoder.decode(values: v, shape: [1, 300, 6], inputWidth: 640, inputHeight: 640,
                                   confidenceThreshold: 0.25, iouThreshold: 0.45, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].box.x, 0, accuracy: 1e-6)
        XCTAssertEqual(d[0].box.y, 0, accuracy: 1e-6)
        XCTAssertEqual(d[0].box.width, 1, accuracy: 1e-6)
        XCTAssertEqual(d[0].box.height, 1, accuracy: 1e-6)
    }

    func testCOCO() {
        XCTAssertEqual(COCOLabels.names.count, 80)
        XCTAssertEqual(COCOLabels.names[9], "traffic light")
        XCTAssertEqual(VehicleKind(label: COCOLabels.name(for: 5)), .bus)
    }
}
