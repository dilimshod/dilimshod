import Foundation
import XCTest
@testable import RoadVisCore

/// Distance rounding and clip composition for pre-recorded voice clips (VoicePhrase / VoiceComposer / VoiceClipCatalog).
final class VoicePhraseTests: XCTestCase {

    // MARK: Rounding

    func testDistanceRounding() {
        XCTAssertEqual(VoiceDistance.rounded(287), .meters(300))
        XCTAssertEqual(VoiceDistance.rounded(30), .meters(50))
        XCTAssertEqual(VoiceDistance.rounded(120), .meters(100))
        XCTAssertEqual(VoiceDistance.rounded(330), .meters(300))
        XCTAssertEqual(VoiceDistance.rounded(370), .meters(400))
        XCTAssertEqual(VoiceDistance.rounded(940), .meters(900))
        XCTAssertEqual(VoiceDistance.rounded(960), .kilometers(tenths: 10))
        XCTAssertEqual(VoiceDistance.rounded(1_300), .kilometers(tenths: 15))
        XCTAssertEqual(VoiceDistance.rounded(2_200), .kilometers(tenths: 20))
        XCTAssertEqual(VoiceDistance.rounded(2_400), .kilometers(tenths: 25))
        XCTAssertEqual(VoiceDistance.rounded(2_800), .kilometers(tenths: 30))
        XCTAssertEqual(VoiceDistance.rounded(7_400), .kilometers(tenths: 70))
        XCTAssertEqual(VoiceDistance.rounded(10_400), .kilometers(tenths: 100))
        XCTAssertNil(VoiceDistance.rounded(12_000))
        XCTAssertNil(VoiceDistance.rounded(0))
        XCTAssertNil(VoiceDistance.rounded(.nan))
        XCTAssertEqual(VoiceDistance.kilometers(tenths: 15).numberID, "n_1_5")
        XCTAssertEqual(VoiceDistance.kilometers(tenths: 30).numberID, "n_3")
    }

    // MARK: Composition per language

    func testManeuverUzbek() {
        let phrase = VoicePhrase.maneuver(.right, distance: 287)
        XCTAssertEqual(VoiceComposer.clipIDs(for: phrase, language: .uz), ["n_300", "after_meters", "turn_right"])
        XCTAssertEqual(VoiceComposer.composedText(for: phrase, language: .uz), "Uch yuz metrdan keyin o‘ngga buriling")
        XCTAssertEqual(VoiceComposer.resourceNames(for: phrase, language: .uz),
                       ["uz_n_300", "uz_after_meters", "uz_turn_right"])
        let km = VoicePhrase.maneuver(.left, distance: 1_480)
        XCTAssertEqual(VoiceComposer.clipIDs(for: km, language: .uz), ["n_1_5", "after_km", "turn_left"])
    }

    func testManeuverRussianPlurals() {
        func ids(_ meters: Double) -> [String]? {
            VoiceComposer.clipIDs(for: .maneuver(.right, distance: meters), language: .ru)
        }
        XCTAssertEqual(ids(287), ["through", "n_300", "meters", "turn_right"])
        XCTAssertEqual(ids(1_000), ["through", "n_1", "km_one", "turn_right"])
        XCTAssertEqual(ids(1_500), ["through", "n_1_5", "km_few", "turn_right"])
        XCTAssertEqual(ids(2_000), ["through", "n_2", "km_few", "turn_right"])
        XCTAssertEqual(ids(2_500), ["through", "n_2_5", "km_few", "turn_right"])
        XCTAssertEqual(ids(5_000), ["through", "n_5", "km", "turn_right"])
        XCTAssertEqual(VoiceComposer.composedText(for: .maneuver(.right, distance: 1_500), language: .ru),
                       "Через полтора километра поверните направо")
        XCTAssertEqual(VoiceComposer.composedText(for: .maneuver(.left, distance: 4_000), language: .ru),
                       "Через четыре километра поверните налево")
        XCTAssertEqual(VoiceComposer.meterIDs(21, language: .ru), ["n_20", "meters"])
        XCTAssertEqual(VoiceComposer.meterIDs(1, language: .ru), ["n_5", "meters"])
    }

    func testManeuverEnglish() {
        XCTAssertEqual(VoiceComposer.clipIDs(for: .maneuver(.right, distance: 287), language: .en),
                       ["in", "n_300", "meters", "turn_right"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .maneuver(.uTurn, distance: 1_000), language: .en),
                       ["in", "n_1", "km_one", "uturn"])
        XCTAssertEqual(VoiceComposer.composedText(for: .maneuver(.keepLeft, distance: 2_500), language: .en),
                       "In two and a half kilometres keep left")
    }

    func testCloseManeuverWithCautionAndSlowDown() {
        let phrase = VoicePhrase.maneuver(.roundabout, distance: 100, roundaboutExit: 2, caution: true, slowDown: true)
        XCTAssertEqual(VoiceComposer.segments(for: phrase, language: .uz),
                       [.clip("n_100"), .clip("after_meters"), .clip("roundabout_exit_2"), .pause,
                        .clip("be_careful"), .pause, .clip("slow_down")])
        XCTAssertEqual(VoiceComposer.composedText(for: phrase, language: .uz),
                       "Yuz metrdan keyin aylanma harakatda ikkinchi chiqishdan chiqing, ehtiyot bo‘ling, tezlikni pasaytiring")
        let near = VoicePhrase.maneuver(.left, distance: nil, caution: true)
        XCTAssertEqual(VoiceComposer.clipIDs(for: near, language: .ru), ["turn_left", "be_careful"])
    }

    func testUnknownManeuverAndFarDistanceFallBack() {
        let unknown = VoicePhrase.maneuver(.unknown, distance: 300, text: "Следуйте по Навои")
        XCTAssertNil(VoiceComposer.clipIDs(for: unknown, language: .ru))
        XCTAssertEqual(VoiceComposer.text(for: unknown, language: .ru), "Следуйте по Навои")
        XCTAssertNil(VoiceComposer.clipIDs(for: .maneuver(.right, distance: 25_000), language: .uz))
    }

    func testCoachPhrases() {
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.speedLimit(kmh: 60)), language: .uz),
                       ["speed_limit", "n_60", "km"])
        XCTAssertEqual(VoiceComposer.composedText(for: .coach(.speedLimit(kmh: 60)), language: .uz),
                       "Tezlik chegarasi soatiga oltmish kilometr")
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.overSpeedLimit(limitKmh: 110)), language: .ru),
                       ["speeding", "n_110", "kmh"])
        XCTAssertEqual(VoiceComposer.composedText(for: .coach(.overSpeedLimit(limitKmh: 110)), language: .ru),
                       "Снизьте скорость, ограничение сто десять километров в час")
        XCTAssertNil(VoiceComposer.clipIDs(for: .coach(.speedLimit(kmh: 47)), language: .en))
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.roadSign(kind: .trafficSignals, distanceMeters: 300)),
                                             language: .uz),
                       ["n_300", "after_meters", "sign_traffic_signals"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.speedLimitAhead(kmh: 40, distanceMeters: 500)),
                                             language: .en),
                       ["in", "n_500", "meters", "speed_limit", "n_40", "kmh"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.keepDistance(recommendedMeters: 23)), language: .uz),
                       ["keep_distance_at_least", "n_25", "meters"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.keepDistance(recommendedMeters: nil)), language: .en),
                       ["keep_distance"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .coach(.pedestrianDanger(trackID: 3)), language: .uz),
                       ["pedestrian_yield"])
    }

    func testIncidentAndSample() {
        XCTAssertEqual(VoiceComposer.clipIDs(for: .incident(.jam, distance: 580), language: .ru),
                       ["incident_jam", "through", "n_600", "meters"])
        XCTAssertEqual(VoiceComposer.clipIDs(for: .incident(.speedCamera, distance: nil), language: .uz),
                       ["speed_camera_ahead"], "own camera marks sound like OSM cameras")
        XCTAssertEqual(VoiceComposer.composedText(for: .incident(.jam, distance: 580), language: .uz),
                       "Oldinda tirbandlik, olti yuz metrdan keyin")
        XCTAssertEqual(VoiceComposer.composedText(for: .sample(), language: .en),
                       "In three hundred metres turn right, traffic light ahead")
    }

    func testRoundaboutExitParsing() {
        XCTAssertEqual(VoiceComposer.roundaboutExit(in: "Aylanma harakatda 2-chiqishdan chiqing"), 2)
        XCTAssertEqual(VoiceComposer.roundaboutExit(in: "На круговом движении — 3-й съезд"), 3)
        XCTAssertEqual(VoiceComposer.roundaboutExit(in: "At the roundabout, take the 1st exit onto Navoiy"), 1)
        XCTAssertEqual(VoiceComposer.roundaboutExit(in: "На круговом движении сверните на второй съезд"), 2)
        XCTAssertEqual(VoiceComposer.roundaboutExit(in: "At the roundabout, take the fourth exit"), 4)
        XCTAssertNil(VoiceComposer.roundaboutExit(in: "Enter the roundabout"))
    }

    // MARK: Catalog

    func testNumberWords() {
        XCTAssertEqual(VoiceClipCatalog.uzbekNumber(125), "yuz yigirma besh")
        XCTAssertEqual(VoiceClipCatalog.uzbekNumber(40), "qirq")
        XCTAssertEqual(VoiceClipCatalog.uzbekNumber(300), "uch yuz")
        XCTAssertEqual(VoiceClipCatalog.russianNumber(115), "сто пятнадцать")
        XCTAssertEqual(VoiceClipCatalog.russianNumber(250), "двести пятьдесят")
        XCTAssertEqual(VoiceClipCatalog.englishNumber(125), "one hundred twenty-five")
        XCTAssertEqual(VoiceClipCatalog.englishNumber(900), "nine hundred")
    }

    /// Every phrase the app can build resolves to clips that exist in each language.
    func testAllBuildablePhrasesHaveClips() {
        var phrases: [VoicePhrase] = [.sample(), .fixed("arrived"), .fixed("rerouting"), .fixed("route_ready"),
                                      .fixed("collision_alert"), .fixed("keep_distance")]
        let distances: [Double] = [40, 287, 777, 1_000, 1_600, 2_400, 6_000, 10_000]
        for type in ManeuverType.allCases where type != .unknown {
            for distance in distances {
                phrases.append(.maneuver(type, distance: distance, roundaboutExit: 3, caution: true, slowDown: true))
            }
        }
        for kind in RouteFeatureKind.allCases {
            if VoicePhrase.hazardClipID(kind) != nil { phrases.append(.hazard(kind)) }
            phrases.append(.coach(.roadSign(kind: kind, distanceMeters: 350)))
        }
        for kind in RoadIncidentKind.allCases { phrases.append(.incident(kind, distance: 450)) }
        for kmh in stride(from: 5, through: 130, by: 5) {
            phrases += [.coach(.speedLimit(kmh: kmh)), .coach(.overSpeedLimit(limitKmh: kmh)),
                        .coach(.speedLimitAhead(kmh: kmh, distanceMeters: 200))]
        }
        for meters in [3, 12, 37, 58, 90, 131, 480] {
            phrases.append(.coach(.keepDistance(recommendedMeters: meters)))
        }
        phrases += [.coach(.collisionRisk), .coach(.pedestrianCaution(trackID: 1)), .coach(.redLightAhead),
                    .coach(.laneDeparture(side: .left)), .coach(.laneDeparture(side: .right)),
                    .coach(.stopSignAhead), .coach(.greenLightGo), .coach(.keepDistance(recommendedMeters: nil))]
        for language in RVLang.allCases {
            let recorded = Set(VoiceClipCatalog.clipIDs(for: language))
            for phrase in phrases {
                guard let ids = VoiceComposer.clipIDs(for: phrase, language: language) else {
                    return XCTFail("\(phrase) not expressible in \(language)")
                }
                for id in ids { XCTAssertTrue(recorded.contains(id), "\(language)_\(id) missing") }
                XCTAssertFalse(VoiceComposer.text(for: phrase, language: language).isEmpty)
            }
        }
    }

    func testCatalogIDsUniqueAndUzbekApostrophes() {
        let ids = VoiceClipCatalog.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for entry in VoiceClipCatalog.entries {
            XCTAssertTrue(entry.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }, entry.id)
            if let uz = entry.uz {
                // o‘ / g‘ use U+2018, never an ASCII apostrophe.
                XCTAssertFalse(uz.contains("o'") || uz.contains("g'"), uz)
            }
        }
    }

    /// `tools/voice_phrases.json` is exported from the catalog. `RV_WRITE_VOICE_JSON=1 swift test --filter
    /// VoicePhraseTests` rewrites it; otherwise the file must match the catalog.
    func testManifestInSync() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/voice_phrases.json")
        let data = try VoiceClipCatalog.manifestJSON()
        if ProcessInfo.processInfo.environment["RV_WRITE_VOICE_JSON"] == "1" {
            try (data + Data("\n".utf8)).write(to: url)
        }
        let onDisk = try Data(contentsOf: url)
        let decodedDisk = try JSONSerialization.jsonObject(with: onDisk) as? NSDictionary
        let decodedCatalog = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(decodedDisk, decodedCatalog, "tools/voice_phrases.json is out of date")
    }
}
