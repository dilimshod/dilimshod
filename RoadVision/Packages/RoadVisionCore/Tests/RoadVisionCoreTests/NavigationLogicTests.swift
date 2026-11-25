import XCTest
@testable import RoadVisionCore

final class NavigationLogicTests: XCTestCase {
    func testManeuverClassifierRussian() {
        XCTAssertEqual(ManeuverClassifier.classify("Поверните направо на улицу Амира Темура"), .right)
        XCTAssertEqual(ManeuverClassifier.classify("Поверните налево"), .left)
        XCTAssertEqual(ManeuverClassifier.classify("Плавно поверните направо"), .slightRight)
        XCTAssertEqual(ManeuverClassifier.classify("Резко поверните налево"), .sharpLeft)
        XCTAssertEqual(ManeuverClassifier.classify("Развернитесь"), .uTurn)
        XCTAssertEqual(ManeuverClassifier.classify("На круговом движении сверните на 2-й съезд"), .roundabout)
        XCTAssertEqual(ManeuverClassifier.classify("Держитесь левее"), .keepLeft)
        XCTAssertEqual(ManeuverClassifier.classify("Пункт назначения будет справа"), .arrive)
        XCTAssertEqual(ManeuverClassifier.classify("Продолжайте движение прямо"), .straight)
        XCTAssertEqual(ManeuverClassifier.classify(""), .depart)
    }

    func testManeuverClassifierEnglishUzbek() {
        XCTAssertEqual(ManeuverClassifier.classify("Turn right onto Main St"), .right)
        XCTAssertEqual(ManeuverClassifier.classify("Make a U-turn"), .uTurn)
        XCTAssertEqual(ManeuverClassifier.classify("Take exit 5 on the right"), .exitRight)
        XCTAssertEqual(ManeuverClassifier.classify("O'ngga buriling"), .right)
        XCTAssertEqual(ManeuverClassifier.classify("Chapga buriling"), .left)
    }

    func testLaneGuidance() {
        let lanes = [Lane(turns: [.left]), Lane(turns: [.through]), Lane(turns: [.through, .right])]
        XCTAssertEqual(LaneGuidance.recommendedLanes(lanes, for: .left), [true, false, false])
        XCTAssertEqual(LaneGuidance.recommendedLanes(lanes, for: .straight), [false, true, true])
        XCTAssertEqual(LaneGuidance.recommendedLanes(lanes, for: .right), [false, false, true])
        XCTAssertEqual(LaneGuidance.recommendedLanes([Lane(turns: []), Lane(turns: [])], for: .right), [false, true])
        XCTAssertEqual(LaneGuidance.recommendedLanes([], for: .left), [])
    }

    func testFormatting() {
        XCTAssertEqual(RVFormat.distance(347), "350 м")
        XCTAssertEqual(RVFormat.distance(1234), "1,2 км")
        XCTAssertEqual(RVFormat.distance(15400), "15 км")
        XCTAssertEqual(RVFormat.duration(45), "45 с")
        XCTAssertEqual(RVFormat.duration(12 * 60), "12 мин")
        XCTAssertEqual(RVFormat.duration(65 * 60), "1 ч 05 мин")
        XCTAssertEqual(RVFormat.spokenDistance(400), "через 400 метров")
        XCTAssertEqual(RVFormat.spokenDistance(1500), "через 1,5 километра")
        XCTAssertEqual(RVFormat.spokenDistance(2000), "через 2 километра")
        XCTAssertEqual(RVFormat.plural(21, "метр", "метра", "метров"), "метр")
        XCTAssertEqual(RVFormat.plural(12, "метр", "метра", "метров"), "метров")
    }

    func makeRoute() -> ([GeoPoint], [RouteStepInfo]) {
        // L-shaped route: east 1000 m, then north 500 m.
        let start = GeoPoint(41.3, 69.2)
        let corner = Geo.destination(from: start, bearing: 90, distance: 1000)
        let end = Geo.destination(from: corner, bearing: 0, distance: 500)
        var pts: [GeoPoint] = []
        for i in 0...10 { pts.append(Geo.destination(from: start, bearing: 90, distance: Double(i) * 100)) }
        for i in 1...5 { pts.append(Geo.destination(from: corner, bearing: 0, distance: Double(i) * 100)) }
        pts[pts.count - 1] = end
        let steps = [RouteStepInfo(instruction: "", distance: 0),
                     RouteStepInfo(instruction: "Двигайтесь на восток", distance: 1000),
                     RouteStepInfo(instruction: "Поверните налево", distance: 500),
                     RouteStepInfo(instruction: "Пункт назначения будет справа", distance: 0)]
        return (pts, steps)
    }

    func testRouteProgress() {
        let (pts, steps) = makeRoute()
        let tracker = RouteProgressTracker(polyline: pts, steps: steps, expectedTravelTime: 300)
        XCTAssertEqual(tracker.totalDistance, 1500, accuracy: 2)
        let p = tracker.update(position: Geo.destination(from: pts[3], bearing: 0, distance: 8))
        XCTAssertEqual(p.distanceAlong, 300, accuracy: 3)
        XCTAssertEqual(p.nextStepIndex, 2)
        XCTAssertEqual(p.nextManeuver, .left)
        XCTAssertEqual(p.distanceToNextManeuver!, 700, accuracy: 3)
        XCTAssertEqual(p.remainingTimeSeconds, 240, accuracy: 2)
        XCTAssertFalse(p.isOffRoute)
        XCTAssertEqual(p.followingInstruction, "Пункт назначения будет справа")
    }

    func testRouteOffRouteAndArrival() {
        let (pts, steps) = makeRoute()
        let tracker = RouteProgressTracker(polyline: pts, steps: steps, expectedTravelTime: 300, offRouteConfirmations: 3)
        let far = Geo.destination(from: pts[5], bearing: 180, distance: 200)
        var last = tracker.update(position: far)
        XCTAssertFalse(last.isOffRoute)
        last = tracker.update(position: far)
        last = tracker.update(position: far)
        XCTAssertTrue(last.isOffRoute)
        let arrived = tracker.update(position: pts.last!)
        XCTAssertTrue(arrived.hasArrived)
        XCTAssertFalse(arrived.isOffRoute)
    }

    func testVoicePromptScheduler() {
        var s = VoicePromptScheduler()
        XCTAssertNil(s.prompt(stepIndex: 2, distance: 1500, instruction: "Поверните налево", speedKmh: 60))
        XCTAssertEqual(s.prompt(stepIndex: 2, distance: 980, instruction: "Поверните налево", speedKmh: 60),
                       "через 1 километр поверните налево")
        XCTAssertNil(s.prompt(stepIndex: 2, distance: 900, instruction: "Поверните налево", speedKmh: 60))
        XCTAssertEqual(s.prompt(stepIndex: 2, distance: 390, instruction: "Поверните налево", speedKmh: 60),
                       "через 400 метров поверните налево")
        XCTAssertEqual(s.prompt(stepIndex: 2, distance: 90, instruction: "Поверните налево", speedKmh: 60), "Поверните налево")
        // Slow traffic: skip the 1 km prompt.
        XCTAssertNil(s.prompt(stepIndex: 3, distance: 950, instruction: "Поверните направо", speedKmh: 20))
        // Jumping straight to 90 m announces only once.
        var s2 = VoicePromptScheduler()
        XCTAssertEqual(s2.prompt(stepIndex: 1, distance: 90, instruction: "Поверните направо", speedKmh: 40), "Поверните направо")
        XCTAssertNil(s2.prompt(stepIndex: 1, distance: 80, instruction: "Поверните направо", speedKmh: 40))
    }
}
