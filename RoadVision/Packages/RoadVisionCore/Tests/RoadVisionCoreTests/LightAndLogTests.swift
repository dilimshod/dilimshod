import XCTest
@testable import RoadVisionCore

final class LightAndLogTests: XCTestCase {
    func testTrafficLightColors() {
        let dark = Array(repeating: RGBPixel(r: 20, g: 20, b: 20), count: 80)
        let red = Array(repeating: RGBPixel(r: 250, g: 40, b: 30), count: 20)
        let green = Array(repeating: RGBPixel(r: 40, g: 240, b: 160), count: 20)
        let yellow = Array(repeating: RGBPixel(r: 250, g: 190, b: 30), count: 20)
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: dark + red), .red)
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: dark + green), .green)
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: dark + yellow), .yellow)
        XCTAssertEqual(TrafficLightColorClassifier.classify(pixels: dark), .unknown)
    }

    func testBGRASampling() {
        let w = 10, h = 10
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<3 { for x in 0..<w { let i = (y * w + x) * 4; buf[i] = 30; buf[i + 1] = 40; buf[i + 2] = 250; buf[i + 3] = 255 } }
        let color = buf.withUnsafeBytes { raw in
            TrafficLightColorClassifier.classifyBGRA(base: raw.baseAddress!, width: w, height: h, bytesPerRow: w * 4,
                                                     rectX: 0, rectY: 0, rectWidth: w, rectHeight: h, step: 1)
        }
        XCTAssertEqual(color, .red)
    }

    func testExperimentLogCSV() throws {
        let log = ExperimentLog(modelName: "yolo11n", startedAt: Date(timeIntervalSince1970: 0))
        log.markFrame()
        log.append(ExperimentRecord(timestamp: Date(timeIntervalSince1970: 1), frameIndex: 1, trackID: 3, kind: .car,
                                    label: "car", confidence: 0.91, box: BBox(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
                                    make: "Chevrolet, Inc", makeConfidence: 0.5))
        log.append(ExperimentRecord(timestamp: Date(timeIntervalSince1970: 1), frameIndex: 1, kind: .bus,
                                    label: "bus", confidence: 0.6, box: BBox(x: 0.5, y: 0.2, width: 0.3, height: 0.4)))
        let csv = log.detectionsCSV()
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].contains("\"Chevrolet, Inc\""))
        XCTAssertTrue(lines[1].hasPrefix("1970-01-01T00:00:01.000Z,1,3,car,car,0.910"))
        let summary = log.summaryCSV(uniqueCounts: [.car: 1, .bus: 1], endedAt: Date(timeIntervalSince1970: 60))
        XCTAssertTrue(summary.contains("car,1,1,0.910"))
        XCTAssertTrue(summary.contains("vehicles_total,2,2,"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvtest-\(UUID().uuidString)")
        let urls = try log.writeFiles(to: dir, uniqueCounts: [.car: 1], endedAt: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        try? FileManager.default.removeItem(at: dir)
    }
}
