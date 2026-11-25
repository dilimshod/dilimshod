import XCTest
@testable import RoadVisionCore

final class WeatherTests: XCTestCase {
    func testParseRealOpenMeteoResponse() throws {
        // Real response for Tashkent (41.3111, 69.2797), fetched 2026-11-25.
        let w = try OpenMeteo.parse(RoadFixture.data("open_meteo_current"))
        XCTAssertEqual(w.temperatureC ?? 0, 12.1, accuracy: 1e-9)
        XCTAssertEqual(w.apparentTemperatureC ?? 0, 11.7, accuracy: 1e-9)
        XCTAssertEqual(w.precipitationMm, 0)
        XCTAssertEqual(w.rainMm, 0)
        XCTAssertEqual(w.snowfallCm, 0)
        XCTAssertEqual(w.weatherCode, 2)
        XCTAssertEqual(w.cloudCover, 71)
        XCTAssertEqual(w.windSpeedKmh ?? 0, 2.3, accuracy: 1e-9)
        XCTAssertEqual(w.windGustsKmh ?? 0, 9.0, accuracy: 1e-9)
        XCTAssertEqual(w.visibilityMeters ?? 0, 27080, accuracy: 1e-9)
        XCTAssertFalse(w.isDay)
        XCTAssertEqual(w.time, "2026-11-25T19:30")
        XCTAssertEqual(w.conditionDescription, "Переменная облачность")
        XCTAssertEqual(w.symbolName, "cloud.moon.fill")
        XCTAssertEqual(w.summary, "+12°, переменная облачность, ветер 2 км/ч")
        XCTAssertEqual(w.roadWarnings, [])
    }

    func testParseErrors() throws {
        XCTAssertThrowsError(try OpenMeteo.parse(RoadFixture.data("open_meteo_error"))) { error in
            guard case .api(let reason) = error as? OpenMeteoError else { return XCTFail("expected api error, got \(error)") }
            XCTAssertTrue(reason.hasPrefix("Latitude must be in range"))
            XCTAssertTrue((error as? OpenMeteoError)?.errorDescription?.contains("Open-Meteo") == true)
        }
        XCTAssertThrowsError(try OpenMeteo.parse(Data(#"{"error":true}"#.utf8))) {
            XCTAssertEqual($0 as? OpenMeteoError, .api("неизвестная ошибка"))
        }
        XCTAssertThrowsError(try OpenMeteo.parse(Data(#"{"latitude":41.3}"#.utf8))) {
            XCTAssertEqual($0 as? OpenMeteoError, .missingCurrent)
        }
        XCTAssertThrowsError(try OpenMeteo.parse(Data("<html>".utf8))) { error in
            guard case .invalidJSON = error as? OpenMeteoError else { return XCTFail("expected invalidJSON, got \(error)") }
        }
        XCTAssertThrowsError(try OpenMeteo.parse(Data("[1,2]".utf8)))
    }

    func testParseToleratesNullsAndAlternativeTypes() throws {
        let json = """
        {"error": false, "current": {"time": "2026-01-10T08:00", "temperature_2m": null, "weather_code": 61.0,
         "is_day": true, "visibility": "800", "wind_speed_10m": 14}}
        """
        let w = try OpenMeteo.parse(Data(json.utf8))
        XCTAssertNil(w.temperatureC)
        XCTAssertNil(w.precipitationMm)
        XCTAssertEqual(w.weatherCode, 61)
        XCTAssertTrue(w.isDay)
        XCTAssertEqual(w.visibilityMeters, 800)
        XCTAssertEqual(w.windSpeedKmh, 14)
        XCTAssertEqual(w.summary, "небольшой дождь, ветер 14 км/ч")
        XCTAssertEqual(w.roadWarnings, ["Плохая видимость (туман)"])

        let missingIsDay = try OpenMeteo.parse(Data(#"{"current":{"is_day":0}}"#.utf8))
        XCTAssertFalse(missingIsDay.isDay)
        XCTAssertEqual(missingIsDay.summary, "Нет данных о погоде")
        XCTAssertEqual(missingIsDay.conditionDescription, "Нет данных")
        XCTAssertEqual(missingIsDay.symbolName, "thermometer")
    }

    func testURL() throws {
        let url = OpenMeteo.url(for: GeoPoint(41.3111, 69.2797))
        XCTAssertEqual(url.absoluteString,
                       "https://api.open-meteo.com/v1/forecast?latitude=41.3111&longitude=69.2797"
                       + "&current=temperature_2m,apparent_temperature,precipitation,rain,snowfall,weather_code,"
                       + "cloud_cover,wind_speed_10m,wind_gusts_10m,visibility,is_day&timezone=auto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["timezone"], "auto")
        XCTAssertEqual(items["current"]?.split(separator: ",").count, OpenMeteo.currentVariables.count)

        let south = OpenMeteo.url(for: GeoPoint(-33.86882, 151.20929)).absoluteString
        XCTAssertTrue(south.contains("latitude=-33.8688&longitude=151.2093"), south)
        XCTAssertEqual(OpenMeteo.attribution, "Погода: Open-Meteo.com (CC BY 4.0)")
    }

    func testConditionDescriptions() {
        let documented = [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 97, 99]
        for code in documented {
            let text = OpenMeteo.conditionDescription(code: code)
            XCTAssertFalse(text.contains("код"), "code \(code) has a proper description")
        }
        XCTAssertEqual(OpenMeteo.conditionDescription(code: 0), "Ясно")
        XCTAssertEqual(OpenMeteo.conditionDescription(code: 3), "Пасмурно")
        XCTAssertEqual(OpenMeteo.conditionDescription(code: 45), "Туман")
        XCTAssertEqual(OpenMeteo.conditionDescription(code: 63), "Дождь")
        XCTAssertEqual(OpenMeteo.conditionDescription(code: 95), "Гроза")
        XCTAssertTrue(OpenMeteo.conditionDescription(code: 42).contains("42"))
    }

    func testSymbols() {
        func symbol(_ code: Int, day: Bool = true) -> String { WeatherSnapshot(weatherCode: code, isDay: day).symbolName }
        XCTAssertEqual(symbol(0), "sun.max.fill")
        XCTAssertEqual(symbol(0, day: false), "moon.stars.fill")
        XCTAssertEqual(symbol(2), "cloud.sun.fill")
        XCTAssertEqual(symbol(3), "cloud.fill")
        XCTAssertEqual(symbol(45), "cloud.fog.fill")
        XCTAssertEqual(symbol(53), "cloud.drizzle.fill")
        XCTAssertEqual(symbol(66), "cloud.sleet.fill")
        XCTAssertEqual(symbol(61), "cloud.rain.fill")
        XCTAssertEqual(symbol(82), "cloud.heavyrain.fill")
        XCTAssertEqual(symbol(75), "cloud.snow.fill")
        XCTAssertEqual(symbol(95), "cloud.bolt.rain.fill")
        XCTAssertEqual(symbol(99), "cloud.hail.fill")
        XCTAssertEqual(symbol(1234), "thermometer")
    }

    func testSummaryTemperatureFormatting() {
        XCTAssertEqual(WeatherSnapshot(temperatureC: -3.4, weatherCode: 71, windSpeedKmh: 18.4).summary, "-3°, небольшой снег, ветер 18 км/ч")
        XCTAssertEqual(WeatherSnapshot(temperatureC: 0.4).summary, "0°")
        XCTAssertEqual(WeatherSnapshot(temperatureC: -0.4).summary, "0°")
        XCTAssertEqual(WeatherSnapshot(temperatureC: 12.5, weatherCode: 63, windSpeedKmh: 18).summary, "+13°, дождь, ветер 18 км/ч")
    }

    func testRoadWarnings() {
        XCTAssertEqual(WeatherSnapshot(temperatureC: 0.5, precipitationMm: 0.2, weatherCode: 61).roadWarnings, ["Возможна гололедица"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 0, weatherCode: 71).roadWarnings, ["Возможна гололедица", "Снег на дороге"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 3, weatherCode: 71).roadWarnings, ["Снег на дороге"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: -2, weatherCode: 48).roadWarnings, ["Возможна гололедица", "Плохая видимость (туман)"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 2, weatherCode: 66).roadWarnings, ["Возможна гололедица"], "freezing rain")
        XCTAssertEqual(WeatherSnapshot(temperatureC: 1, snowfallCm: 0.3, weatherCode: 3).roadWarnings, ["Возможна гололедица", "Снег на дороге"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: -5, precipitationMm: 0, weatherCode: 0).roadWarnings, [], "dry frost")
        XCTAssertEqual(WeatherSnapshot(temperatureC: 8, weatherCode: 45).roadWarnings, ["Плохая видимость (туман)"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 8, weatherCode: 3, visibilityMeters: 600).roadWarnings, ["Плохая видимость (туман)"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 8, weatherCode: 3, visibilityMeters: 1500).roadWarnings, [])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 15, weatherCode: 82).roadWarnings, ["Ливень — увеличьте дистанцию"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 15, precipitationMm: 4.5, weatherCode: 63).roadWarnings, ["Ливень — увеличьте дистанцию"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 15, precipitationMm: 3, weatherCode: 63).roadWarnings, [])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 25, weatherCode: 95).roadWarnings, ["Гроза"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 25, weatherCode: 99).roadWarnings, ["Гроза"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 20, weatherCode: 1, windGustsKmh: 63.4).roadWarnings, ["Сильный ветер — порывы 63 км/ч"])
        XCTAssertEqual(WeatherSnapshot(temperatureC: 20, weatherCode: 1, windGustsKmh: 49).roadWarnings, [])
        XCTAssertEqual(WeatherSnapshot(weatherCode: 67).roadWarnings, ["Возможна гололедица"], "no temperature: freezing codes still warn")
        XCTAssertEqual(WeatherSnapshot().roadWarnings, [])
    }
}
