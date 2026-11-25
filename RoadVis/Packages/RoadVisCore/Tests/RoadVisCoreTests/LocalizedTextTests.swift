import XCTest
@testable import RoadVisCore

/// Uzbek / English variants of formatting and turn instructions (Russian stays the default API).
final class LocalizedTextTests: XCTestCase {
    func testDistanceAllLanguages() {
        XCTAssertEqual(RVFormat.distance(347, language: .ru), RVFormat.distance(347))
        XCTAssertEqual(RVFormat.distance(347, language: .uz), "350 m")
        XCTAssertEqual(RVFormat.distance(347, language: .en), "350 m")
        XCTAssertEqual(RVFormat.distance(1240, language: .uz), "1,2 km")
        XCTAssertEqual(RVFormat.distance(1240, language: .en), "1.2 km")
        XCTAssertEqual(RVFormat.distance(12_400, language: .en), "12 km")
        XCTAssertEqual(RVFormat.distance(.nan, language: .uz), "—")
    }

    func testSpokenDistance() {
        XCTAssertEqual(RVFormat.spokenDistance(400, language: .ru), "через 400 метров")
        XCTAssertEqual(RVFormat.spokenDistance(400, language: .uz), "400 metrdan keyin")
        XCTAssertEqual(RVFormat.spokenDistance(400, language: .en), "In 400 metres")
        XCTAssertEqual(RVFormat.spokenDistance(1000, language: .en), "In 1 kilometre")
        XCTAssertEqual(RVFormat.spokenDistance(1500, language: .en), "In 1.5 kilometres")
        XCTAssertEqual(RVFormat.spokenDistance(1500, language: .uz), "1,5 kilometrdan keyin")
        XCTAssertEqual(RVFormat.spokenDistance(2000, language: .uz), "2 kilometrdan keyin")
    }

    func testDuration() {
        XCTAssertEqual(RVFormat.duration(45, language: .uz), "45 s")
        XCTAssertEqual(RVFormat.duration(720, language: .uz), "12 daq")
        XCTAssertEqual(RVFormat.duration(720, language: .en), "12 min")
        XCTAssertEqual(RVFormat.duration(3900, language: .uz), "1 soat 05 daq")
        XCTAssertEqual(RVFormat.duration(3900, language: .en), "1 h 05 min")
        XCTAssertEqual(RVFormat.duration(3900, language: .ru), "1 ч 05 мин")
    }

    func testOSRMInstructionsUzbekEnglish() {
        XCTAssertEqual(NavInstructionText.osrm(type: "turn", modifier: "left", name: "Navoiy", language: .en),
                       "Turn left onto Navoiy")
        XCTAssertEqual(NavInstructionText.osrm(type: "turn", modifier: "left", name: "Navoiy", language: .uz),
                       "Chapga buriling, Navoiy tomon")
        XCTAssertEqual(NavInstructionText.osrm(type: "turn", modifier: "left", name: "Навои", language: .ru),
                       "Поверните налево на Навои")
        XCTAssertEqual(NavInstructionText.osrm(type: "roundabout", modifier: nil, name: "Bobur", exit: 2, language: .en),
                       "At the roundabout, take the 2nd exit onto Bobur")
        XCTAssertEqual(NavInstructionText.osrm(type: "roundabout", modifier: nil, name: nil, exit: 3, language: .uz),
                       "Aylanma harakatda 3-chiqishdan chiqing")
        XCTAssertEqual(NavInstructionText.osrm(type: "arrive", modifier: "right", name: nil, language: .uz),
                       "Manzil o‘ng tomonda")
        XCTAssertEqual(NavInstructionText.osrm(type: "continue", modifier: "straight", name: "Bobur", language: .uz),
                       "Bobur bo‘ylab davom eting")
        XCTAssertEqual(NavInstructionText.englishOrdinal(11), "11th")
        XCTAssertEqual(NavInstructionText.englishOrdinal(22), "22nd")
        // Rebuilt texts still classify to the same maneuver.
        for (type, modifier, expected) in [("turn", "left", ManeuverType.left), ("turn", "slight right", .slightRight),
                                           ("turn", "uturn", .uTurn), ("arrive", "left", .arrive),
                                           ("roundabout", "right", .roundabout), ("fork", "slight left", .keepLeft)] {
            for lang in [RVLang.uz, .en] {
                let text = NavInstructionText.osrm(type: type, modifier: modifier, name: nil, exit: 1, language: lang)
                XCTAssertEqual(ManeuverClassifier.classify(text), expected, "\(lang) \(text)")
            }
        }
    }

    func testValhallaUzbekRebuild() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "valhalla_route_tashkent", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let ru = try Valhalla.parseRoutes(data)
        let uz = try Valhalla.parseRoutes(data, language: .uz)
        XCTAssertEqual(ru[0].steps.count, uz[0].steps.count)
        XCTAssertEqual(uz[0].steps[0].instruction, "")
        XCTAssertEqual(uz[0].steps[1].instruction, "«Srkver» aylanma harakatida 3-chiqishdan chiqing")
        XCTAssertEqual(uz[0].steps[3].instruction, "Biroz chapga buriling, Mirzo Ulug'bek shoh ko'chasi tomon")
        XCTAssertEqual(uz[0].steps.last?.instruction, "Manzil o‘ng tomonda")
        for step in uz[0].steps {
            XCTAssertFalse(step.instruction.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) },
                           step.instruction)
        }
        XCTAssertEqual(RVLang.uz.valhallaLanguage, "en-US")
        XCTAssertEqual(RVLang.ru.valhallaLanguage, "ru-RU")
    }

    func testOSRMParseEnglish() throws {
        let body: [String: Any] = ["code": "Ok", "routes": [[
            "distance": 500.0, "duration": 60.0,
            "geometry": Polyline.encode([GeoPoint(41.30, 69.24), GeoPoint(41.31, 69.24)]),
            "legs": [["summary": "", "steps": [
                ["maneuver": ["type": "depart"], "name": "", "distance": 300.0],
                ["maneuver": ["type": "turn", "modifier": "right"], "name": "Bobur", "distance": 200.0],
                ["maneuver": ["type": "arrive"], "name": "", "distance": 0.0],
            ]]],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let routes = try OSRM.parseRoutes(data, language: .en)
        XCTAssertEqual(routes[0].steps[1].instruction, "Turn right onto Bobur")
        XCTAssertEqual(routes[0].steps[2].instruction, "Your destination")
    }

    func testSchedulerAndTrackerLanguage() {
        var scheduler = VoicePromptScheduler()
        scheduler.language = .uz
        XCTAssertEqual(scheduler.prompt(stepIndex: 1, distance: 390, instruction: "O‘ngga buriling", speedKmh: 50),
                       "400 metrdan keyin o‘ngga buriling")
        XCTAssertEqual(NavInstructionText.destination(arrived: true, language: .en), "You have arrived")
    }
}
