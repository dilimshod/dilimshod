import XCTest
@testable import RoadVisCore

final class RouteLimitPiecesTests: XCTestCase {
    private func assertCovers(_ pieces: [RouteLimitPiece], total: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pieces.first?.start, 0, file: file, line: line)
        XCTAssertEqual(pieces.last?.end, total, file: file, line: line)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(a.end, b.start, file: file, line: line)
            XCTAssertFalse(a.isGap == b.isGap && a.limitKmh == b.limitKmh, "unmerged neighbours", file: file, line: line)
        }
        for piece in pieces {
            XCTAssertGreaterThan(piece.end, piece.start, file: file, line: line)
        }
    }

    func testNoSegmentsGivesOneGapPiece() {
        let pieces = RouteLimitPieces.pieces(segments: [], totalDistance: 1200)
        XCTAssertEqual(pieces, [RouteLimitPiece(start: 0, end: 1200, limitKmh: nil, isGap: true)])
        XCTAssertTrue(RouteLimitPieces.pieces(segments: [], totalDistance: 0).isEmpty)
    }

    func testShortSegmentOnLongRouteKeepsExactBounds() {
        // A 150 m school zone on a 300 km route must keep its exact start / end (no resolution limit).
        let total = 300_000.0
        let segments = [
            SpeedLimitSegment(start: 0, end: 120_000, limitKmh: 100),
            SpeedLimitSegment(start: 120_000, end: 120_150, limitKmh: 30),
            SpeedLimitSegment(start: 120_150, end: total, limitKmh: 100),
        ]
        let pieces = RouteLimitPieces.pieces(segments: segments, totalDistance: total)
        assertCovers(pieces, total: total)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[1], RouteLimitPiece(start: 120_000, end: 120_150, limitKmh: 30, isGap: false))
    }

    func testGapsUnsortedOverlapAndClamp() {
        let segments = [
            SpeedLimitSegment(start: 600, end: 900, limitKmh: 70),
            SpeedLimitSegment(start: 100, end: 400, limitKmh: 50),
            SpeedLimitSegment(start: 350, end: 500, limitKmh: nil),   // overlaps the previous one
            SpeedLimitSegment(start: 950, end: 5000, limitKmh: 70),   // runs past the end
            SpeedLimitSegment(start: 700, end: 700, limitKmh: 20),    // empty
        ]
        let pieces = RouteLimitPieces.pieces(segments: segments, totalDistance: 1000)
        assertCovers(pieces, total: 1000)
        XCTAssertEqual(pieces, [
            RouteLimitPiece(start: 0, end: 100, limitKmh: nil, isGap: true),
            RouteLimitPiece(start: 100, end: 400, limitKmh: 50, isGap: false),
            RouteLimitPiece(start: 400, end: 500, limitKmh: nil, isGap: false),
            RouteLimitPiece(start: 500, end: 600, limitKmh: nil, isGap: true),
            RouteLimitPiece(start: 600, end: 900, limitKmh: 70, isGap: false),
            RouteLimitPiece(start: 900, end: 950, limitKmh: nil, isGap: true),
            RouteLimitPiece(start: 950, end: 1000, limitKmh: 70, isGap: false),
        ])
    }

    func testMergesEqualNeighboursAndAbsorbsTinyGaps() {
        let segments = [
            SpeedLimitSegment(start: 0, end: 300, limitKmh: 60),
            SpeedLimitSegment(start: 300.2, end: 700, limitKmh: 60),   // 0.2 m gap: absorbed, then merged
            SpeedLimitSegment(start: 700, end: 999.8, limitKmh: 40),   // 0.2 m tail: extended to the end
        ]
        let pieces = RouteLimitPieces.pieces(segments: segments, totalDistance: 1000)
        XCTAssertEqual(pieces, [
            RouteLimitPiece(start: 0, end: 700, limitKmh: 60, isGap: false),
            RouteLimitPiece(start: 700, end: 1000, limitKmh: 40, isGap: false),
        ])
    }

    func testSliceInterpolatesEndsAndKeepsInnerVertices() {
        // Straight line east along the equator, vertices about every 111 m.
        let line = (0...10).map { GeoPoint(0, Double($0) * 0.001) }
        let cum = Geo.cumulativeDistances(line)
        let step = cum[1]
        let slice = Geo.slice(line, from: step * 1.5, to: step * 4.25, cumulative: cum)
        XCTAssertEqual(slice.count, 5)   // start, vertices 2, 3, 4, end
        XCTAssertEqual(slice[0].longitude, 0.0015, accuracy: 1e-9)
        XCTAssertEqual(slice[1], line[2])
        XCTAssertEqual(slice[3], line[4])
        XCTAssertEqual(slice[4].longitude, 0.00425, accuracy: 1e-9)
        XCTAssertEqual(Geo.polylineLength(slice), step * 2.75, accuracy: 0.01)
    }

    func testSliceBoundsOnVerticesAndDegenerateInput() {
        let line = (0...4).map { GeoPoint(0, Double($0) * 0.001) }
        let cum = Geo.cumulativeDistances(line)
        // Ends exactly on vertices: no duplicated points.
        XCTAssertEqual(Geo.slice(line, from: cum[1], to: cum[3], cumulative: cum), [line[1], line[2], line[3]])
        // Clamped to the polyline.
        XCTAssertEqual(Geo.slice(line, from: -50, to: 1e9), line)
        XCTAssertTrue(Geo.slice(line, from: 200, to: 200).isEmpty)
        XCTAssertTrue(Geo.slice(line, from: 300, to: 100).isEmpty)
        XCTAssertTrue(Geo.slice([line[0]], from: 0, to: 10).isEmpty)
        XCTAssertTrue(Geo.slice([line[0], line[0]], from: 0, to: 10).isEmpty)
    }

    func testSlicedPiecesAddUpToTheRoute() {
        let line = [GeoPoint(41.30, 69.20), GeoPoint(41.31, 69.22), GeoPoint(41.33, 69.22), GeoPoint(41.34, 69.25)]
        let cum = Geo.cumulativeDistances(line)
        let total = cum.last!
        let segments = [SpeedLimitSegment(start: 500, end: 1800, limitKmh: 50),
                        SpeedLimitSegment(start: 2500, end: 2650, limitKmh: 30)]
        let pieces = RouteLimitPieces.pieces(segments: segments, totalDistance: total)
        assertCovers(pieces, total: total)
        var sum = 0.0
        var previousEnd: GeoPoint?
        for piece in pieces {
            let slice = Geo.slice(line, from: piece.start, to: piece.end, cumulative: cum)
            XCTAssertGreaterThanOrEqual(slice.count, 2)
            if let previousEnd {
                XCTAssertEqual(Geo.distance(previousEnd, slice[0]), 0, accuracy: 0.01)   // pieces join
            }
            previousEnd = slice.last
            let length = Geo.polylineLength(slice)
            XCTAssertEqual(length, piece.end - piece.start, accuracy: 0.5)
            sum += length
        }
        XCTAssertEqual(sum, total, accuracy: 1)
    }
}
