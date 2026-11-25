import Foundation

/// Current weather at a point (Open-Meteo "current" block). Units: °C, mm, cm (snowfall), %, km/h, metres.
public struct WeatherSnapshot: Hashable, Sendable {
    public var temperatureC: Double?
    public var apparentTemperatureC: Double?
    /// Precipitation of the preceding interval, mm.
    public var precipitationMm: Double?
    public var rainMm: Double?
    /// Snowfall of the preceding interval, cm.
    public var snowfallCm: Double?
    /// WMO weather interpretation code.
    public var weatherCode: Int?
    /// Cloud cover, %.
    public var cloudCover: Double?
    public var windSpeedKmh: Double?
    public var windGustsKmh: Double?
    public var visibilityMeters: Double?
    public var isDay: Bool
    /// Local time of the observation as sent by Open-Meteo ("2026-11-25T19:30").
    public var time: String?

    public init(temperatureC: Double? = nil, apparentTemperatureC: Double? = nil, precipitationMm: Double? = nil,
                rainMm: Double? = nil, snowfallCm: Double? = nil, weatherCode: Int? = nil, cloudCover: Double? = nil,
                windSpeedKmh: Double? = nil, windGustsKmh: Double? = nil, visibilityMeters: Double? = nil,
                isDay: Bool = true, time: String? = nil) {
        self.temperatureC = temperatureC
        self.apparentTemperatureC = apparentTemperatureC
        self.precipitationMm = precipitationMm
        self.rainMm = rainMm
        self.snowfallCm = snowfallCm
        self.weatherCode = weatherCode
        self.cloudCover = cloudCover
        self.windSpeedKmh = windSpeedKmh
        self.windGustsKmh = windGustsKmh
        self.visibilityMeters = visibilityMeters
        self.isDay = isDay
        self.time = time
    }

    /// Russian description of the WMO code ("Переменная облачность"); "Нет данных" when unknown.
    public var conditionDescription: String {
        guard let code = weatherCode else { return "Нет данных" }
        return OpenMeteo.conditionDescription(code: code)
    }

    /// SF Symbol for the weather code and time of day.
    public var symbolName: String {
        guard let code = weatherCode else { return "thermometer" }
        switch code {
        case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 97: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "thermometer"
        }
    }

    /// Short Russian summary: "+12°, дождь, ветер 18 км/ч" (unknown parts are omitted).
    public var summary: String {
        var parts: [String] = []
        if let t = temperatureC, t.isFinite { parts.append(Self.formatTemperature(t)) }
        if weatherCode != nil {
            let description = conditionDescription
            parts.append(description.prefix(1).lowercased() + description.dropFirst())
        }
        if let wind = windSpeedKmh, wind.isFinite {
            parts.append("ветер \(Int(max(0, wind).rounded())) км/ч")
        }
        return parts.isEmpty ? "Нет данных о погоде" : parts.joined(separator: ", ")
    }

    /// Russian driving warnings derived from the current conditions (most important first).
    public var roadWarnings: [String] {
        var warnings: [String] = []
        let code = weatherCode ?? -1
        let temperature = temperatureC.flatMap { $0.isFinite ? $0 : nil }
        let precipitation = max(precipitationMm ?? 0, 0)
        let snowfall = max(snowfallCm ?? 0, 0)
        let freezingCodes: Set<Int> = [56, 57, 66, 67]
        let snowCodes: Set<Int> = [71, 73, 75, 77, 85, 86]

        // Ice: freezing drizzle/rain, or near-freezing temperature with precipitation, snow or rime fog.
        let nearFreezing = temperature.map { $0 <= 1 } ?? false
        if freezingCodes.contains(code)
            || (nearFreezing && (precipitation > 0 || snowfall > 0 || snowCodes.contains(code) || code == 48)) {
            warnings.append("Возможна гололедица")
        }
        // Visibility.
        if code == 45 || code == 48 || (visibilityMeters.map { $0.isFinite && $0 < 1000 } ?? false) {
            warnings.append("Плохая видимость (туман)")
        }
        // Snow.
        if snowCodes.contains(code) || snowfall > 0 {
            warnings.append("Снег на дороге")
        }
        // Heavy rain.
        if code == 65 || code == 82 || precipitation >= 4 {
            warnings.append("Ливень — увеличьте дистанцию")
        }
        // Thunderstorm.
        if (95...99).contains(code) {
            warnings.append("Гроза")
        }
        // Wind gusts.
        if let gusts = windGustsKmh, gusts.isFinite, gusts >= 50 {
            warnings.append("Сильный ветер — порывы \(Int(gusts.rounded())) км/ч")
        }
        return warnings
    }

    /// "+12°", "-3°", "0°".
    static func formatTemperature(_ t: Double) -> String {
        let value = Int(t.rounded())
        if value > 0 { return "+\(value)°" }
        if value < 0 { return "-\(abs(value))°" }
        return "0°"
    }
}

/// Errors of the Open-Meteo forecast API.
public enum OpenMeteoError: Error, Equatable, Sendable, LocalizedError {
    /// `{"error": true, "reason": "…"}` (HTTP 400 / 429).
    case api(String)
    /// The response has no `current` block.
    case missingCurrent
    /// The body is not valid JSON.
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .api(let reason):
            return "Сервис погоды Open-Meteo вернул ошибку: \(reason)"
        case .missingCurrent:
            return "В ответе сервиса погоды нет текущих данных."
        case .invalidJSON(let message):
            return "Не удалось разобрать ответ сервиса погоды: \(message)"
        }
    }
}

/// Open-Meteo forecast API (free, no key; data CC BY 4.0 — show `attribution`).
public enum OpenMeteo {
    public static let baseURL = "https://api.open-meteo.com/v1/forecast"
    /// Variables requested in the `current` block.
    public static let currentVariables = [
        "temperature_2m", "apparent_temperature", "precipitation", "rain", "snowfall", "weather_code",
        "cloud_cover", "wind_speed_10m", "wind_gusts_10m", "visibility", "is_day",
    ]
    /// Required attribution text.
    public static let attribution = "Погода: Open-Meteo.com (CC BY 4.0)"
    /// Recommended minimum interval between requests for the same place, seconds (the free tier is rate-limited per IP).
    public static let minimumRefreshInterval: TimeInterval = 15 * 60

    /// `GET` URL for the current weather at a point (coordinates rounded to 4 decimals, ≈ 10 m).
    public static func url(for point: GeoPoint) -> URL {
        let lat = point.latitude.isFinite ? min(90, max(-90, point.latitude)) : 0
        let lon = point.longitude.isFinite ? min(180, max(-180, point.longitude)) : 0
        let query = String(format: "latitude=%.4f&longitude=%.4f", lat, lon)
            + "&current=" + currentVariables.joined(separator: ",")
            + "&timezone=auto"
        // The string contains only URL-safe characters, so this initializer cannot fail.
        return URL(string: baseURL + "?" + query) ?? URL(fileURLWithPath: "/")
    }

    /// Parses a forecast response into a snapshot.
    /// - Throws: `OpenMeteoError.api` for `{"error": true}`, `.missingCurrent`, `.invalidJSON`.
    public static func parse(_ data: Data) throws -> WeatherSnapshot {
        let root: Root
        do {
            root = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            throw OpenMeteoError.invalidJSON(String(describing: error))
        }
        if root.error == true {
            throw OpenMeteoError.api(root.reason ?? "неизвестная ошибка")
        }
        guard let c = root.current else { throw OpenMeteoError.missingCurrent }
        return WeatherSnapshot(
            temperatureC: c.temperature_2m,
            apparentTemperatureC: c.apparent_temperature,
            precipitationMm: c.precipitation,
            rainMm: c.rain,
            snowfallCm: c.snowfall,
            weatherCode: c.weather_code.map { Int($0.rounded()) },
            cloudCover: c.cloud_cover,
            windSpeedKmh: c.wind_speed_10m,
            windGustsKmh: c.wind_gusts_10m,
            visibilityMeters: c.visibility,
            isDay: c.is_day ?? true,
            time: c.time)
    }

    /// Russian description of a WMO weather interpretation code.
    public static func conditionDescription(code: Int) -> String {
        switch code {
        case 0: return "Ясно"
        case 1: return "Преимущественно ясно"
        case 2: return "Переменная облачность"
        case 3: return "Пасмурно"
        case 45: return "Туман"
        case 48: return "Туман с изморозью"
        case 51: return "Слабая морось"
        case 53: return "Морось"
        case 55: return "Сильная морось"
        case 56: return "Слабая ледяная морось"
        case 57: return "Сильная ледяная морось"
        case 61: return "Небольшой дождь"
        case 63: return "Дождь"
        case 65: return "Сильный дождь"
        case 66: return "Слабый ледяной дождь"
        case 67: return "Сильный ледяной дождь"
        case 71: return "Небольшой снег"
        case 73: return "Снег"
        case 75: return "Сильный снег"
        case 77: return "Снежная крупа"
        case 80: return "Слабый ливень"
        case 81: return "Ливень"
        case 82: return "Сильный ливень"
        case 85: return "Снегопад"
        case 86: return "Сильный снегопад"
        case 95: return "Гроза"
        case 96: return "Гроза с градом"
        case 97: return "Сильная гроза"
        case 99: return "Гроза с сильным градом"
        default: return "Погодные условия (код \(code))"
        }
    }

    // MARK: Decoding (tolerant: numbers may be null, booleans may arrive as 0/1)

    private struct Root: Decodable {
        let error: Bool?
        let reason: String?
        let current: Current?

        private enum CodingKeys: String, CodingKey { case error, reason, current }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            error = flexibleBool(c, .error)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            current = try? c.decodeIfPresent(Current.self, forKey: .current)
        }
    }

    private struct Current: Decodable {
        let time: String?
        let temperature_2m, apparent_temperature, precipitation, rain, snowfall: Double?
        let weather_code, cloud_cover, wind_speed_10m, wind_gusts_10m, visibility: Double?
        let is_day: Bool?

        private enum CodingKeys: String, CodingKey {
            case time, temperature_2m, apparent_temperature, precipitation, rain, snowfall,
                 weather_code, cloud_cover, wind_speed_10m, wind_gusts_10m, visibility, is_day
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try? c.decodeIfPresent(String.self, forKey: .time)
            temperature_2m = flexibleDouble(c, .temperature_2m)
            apparent_temperature = flexibleDouble(c, .apparent_temperature)
            precipitation = flexibleDouble(c, .precipitation)
            rain = flexibleDouble(c, .rain)
            snowfall = flexibleDouble(c, .snowfall)
            weather_code = flexibleDouble(c, .weather_code)
            cloud_cover = flexibleDouble(c, .cloud_cover)
            wind_speed_10m = flexibleDouble(c, .wind_speed_10m)
            wind_gusts_10m = flexibleDouble(c, .wind_gusts_10m)
            visibility = flexibleDouble(c, .visibility)
            is_day = flexibleBool(c, .is_day)
        }
    }
}

private func flexibleDouble<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
    if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d.isFinite ? d : nil }
    if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s), d.isFinite { return d }
    return nil
}

private func flexibleBool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
    if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return ["1", "true", "yes"].contains(s.lowercased()) }
    return nil
}
