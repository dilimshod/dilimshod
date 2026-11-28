package uz.roadvis.core

import org.json.JSONObject
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Current weather at a point (Open-Meteo "current" block). Units: °C, mm, cm (snowfall), %, km/h, metres. */
data class WeatherSnapshot(
    val temperatureC: Double? = null,
    val apparentTemperatureC: Double? = null,
    /** Precipitation of the preceding interval, mm. */
    val precipitationMm: Double? = null,
    val rainMm: Double? = null,
    /** Snowfall of the preceding interval, cm. */
    val snowfallCm: Double? = null,
    /** WMO weather interpretation code. */
    val weatherCode: Int? = null,
    /** Cloud cover, %. */
    val cloudCover: Double? = null,
    val windSpeedKmh: Double? = null,
    val windGustsKmh: Double? = null,
    val visibilityMeters: Double? = null,
    val isDay: Boolean = true,
    /** Local time of the observation as sent by Open-Meteo ("2026-11-25T19:30"). */
    val time: String? = null,
) {
    /** Russian description of the WMO code ("Переменная облачность"); "Нет данных" when unknown. */
    val conditionDescription: String
        get() {
            val code = weatherCode ?: return "Нет данных"
            return OpenMeteo.conditionDescription(code)
        }

    /** SF Symbol name for the weather code and time of day (kept from iOS; map to a drawable in the app). */
    val symbolName: String
        get() {
            val code = weatherCode ?: return "thermometer"
            return when (code) {
                0, 1 -> if (isDay) "sun.max.fill" else "moon.stars.fill"
                2 -> if (isDay) "cloud.sun.fill" else "cloud.moon.fill"
                3 -> "cloud.fill"
                45, 48 -> "cloud.fog.fill"
                51, 53, 55 -> "cloud.drizzle.fill"
                56, 57, 66, 67 -> "cloud.sleet.fill"
                61, 63, 80, 81 -> "cloud.rain.fill"
                65, 82 -> "cloud.heavyrain.fill"
                71, 73, 75, 77, 85, 86 -> "cloud.snow.fill"
                95, 97 -> "cloud.bolt.rain.fill"
                96, 99 -> "cloud.hail.fill"
                else -> "thermometer"
            }
        }

    /** Short Russian summary: "+12°, дождь, ветер 18 км/ч" (unknown parts are omitted). */
    val summary: String
        get() {
            val parts = ArrayList<String>()
            val t = temperatureC
            if (t != null && t.isFinite()) parts.add(formatTemperature(t))
            if (weatherCode != null) parts.add(conditionDescription.rvLowercasedFirst())
            val wind = windSpeedKmh
            if (wind != null && wind.isFinite()) parts.add("ветер ${max(0.0, wind).rounded().toInt()} км/ч")
            return if (parts.isEmpty()) "Нет данных о погоде" else parts.joinToString(", ")
        }

    /** Russian driving warnings derived from the current conditions (most important first). */
    val roadWarnings: List<String>
        get() {
            val warnings = ArrayList<String>()
            val code = weatherCode ?: -1
            val temperature = temperatureC?.let { if (it.isFinite()) it else null }
            val precipitation = max(precipitationMm ?: 0.0, 0.0)
            val snowfall = max(snowfallCm ?: 0.0, 0.0)
            val freezingCodes = setOf(56, 57, 66, 67)
            val snowCodes = setOf(71, 73, 75, 77, 85, 86)

            // Ice: freezing drizzle/rain, or near-freezing temperature with precipitation, snow or rime fog.
            val nearFreezing = temperature?.let { it <= 1 } ?: false
            if (code in freezingCodes ||
                (nearFreezing && (precipitation > 0 || snowfall > 0 || code in snowCodes || code == 48))) {
                warnings.add("Возможна гололедица")
            }
            // Visibility.
            if (code == 45 || code == 48 || (visibilityMeters?.let { it.isFinite() && it < 1000 } ?: false)) {
                warnings.add("Плохая видимость (туман)")
            }
            // Snow.
            if (code in snowCodes || snowfall > 0) warnings.add("Снег на дороге")
            // Heavy rain.
            if (code == 65 || code == 82 || precipitation >= 4) warnings.add("Ливень — увеличьте дистанцию")
            // Thunderstorm.
            if (code in 95..99) warnings.add("Гроза")
            // Wind gusts.
            val gusts = windGustsKmh
            if (gusts != null && gusts.isFinite() && gusts >= 50) {
                warnings.add("Сильный ветер — порывы ${gusts.rounded().toInt()} км/ч")
            }
            return warnings
        }

    companion object {
        /** "+12°", "-3°", "0°". */
        internal fun formatTemperature(t: Double): String {
            val value = t.rounded().toInt()
            if (value > 0) return "+$value°"
            if (value < 0) return "-${abs(value)}°"
            return "0°"
        }
    }
}

/** Errors of the Open-Meteo forecast API. */
sealed class OpenMeteoError(msg: String) : Exception(msg) {
    /** `{"error": true, "reason": "…"}` (HTTP 400 / 429). */
    data class Api(val reason: String) : OpenMeteoError(reason)
    /** The response has no `current` block. */
    data object MissingCurrent : OpenMeteoError("missing current")
    /** The body is not valid JSON. */
    data class InvalidJSON(val detail: String) : OpenMeteoError(detail)

    val errorDescription: String
        get() = when (this) {
            is Api -> "Сервис погоды Open-Meteo вернул ошибку: $reason"
            MissingCurrent -> "В ответе сервиса погоды нет текущих данных."
            is InvalidJSON -> "Не удалось разобрать ответ сервиса погоды: $detail"
        }
}

/** Open-Meteo forecast API (free, no key; data CC BY 4.0 — show [attribution]). */
object OpenMeteo {
    const val baseURL = "https://api.open-meteo.com/v1/forecast"
    /** Variables requested in the `current` block. */
    val currentVariables: List<String> = listOf(
        "temperature_2m", "apparent_temperature", "precipitation", "rain", "snowfall", "weather_code",
        "cloud_cover", "wind_speed_10m", "wind_gusts_10m", "visibility", "is_day",
    )
    /** Required attribution text. */
    const val attribution = "Погода: Open-Meteo.com (CC BY 4.0)"
    /** Recommended minimum interval between requests for the same place, seconds (the free tier is rate-limited per IP). */
    const val minimumRefreshInterval: Double = 15.0 * 60

    /** `GET` URL for the current weather at a point (coordinates rounded to 4 decimals, ≈ 10 m). */
    fun url(point: GeoPoint): String {
        val lat = if (point.latitude.isFinite()) min(90.0, max(-90.0, point.latitude)) else 0.0
        val lon = if (point.longitude.isFinite()) min(180.0, max(-180.0, point.longitude)) else 0.0
        val query = String.format(Locale.US, "latitude=%.4f&longitude=%.4f", lat, lon) +
            "&current=" + currentVariables.joinToString(",") +
            "&timezone=auto"
        return "$baseURL?$query"
    }

    /**
     * Parses a forecast response into a snapshot.
     * @throws OpenMeteoError.Api for `{"error": true}`, [OpenMeteoError.MissingCurrent], [OpenMeteoError.InvalidJSON].
     */
    fun parse(json: String): WeatherSnapshot {
        val root: JSONObject = try {
            org.json.JSONTokener(json).nextValue() as? JSONObject
                ?: throw OpenMeteoError.InvalidJSON("ожидался объект JSON")
        } catch (e: OpenMeteoError) {
            throw e
        } catch (e: Exception) {
            throw OpenMeteoError.InvalidJSON(e.message ?: e.toString())
        }
        if (flexibleBool(root, "error") == true) {
            throw OpenMeteoError.Api(root.opt("reason") as? String ?: "неизвестная ошибка")
        }
        val c = root.opt("current") as? JSONObject ?: throw OpenMeteoError.MissingCurrent
        return WeatherSnapshot(
            temperatureC = flexibleDouble(c, "temperature_2m"),
            apparentTemperatureC = flexibleDouble(c, "apparent_temperature"),
            precipitationMm = flexibleDouble(c, "precipitation"),
            rainMm = flexibleDouble(c, "rain"),
            snowfallCm = flexibleDouble(c, "snowfall"),
            weatherCode = flexibleDouble(c, "weather_code")?.rounded()?.toInt(),
            cloudCover = flexibleDouble(c, "cloud_cover"),
            windSpeedKmh = flexibleDouble(c, "wind_speed_10m"),
            windGustsKmh = flexibleDouble(c, "wind_gusts_10m"),
            visibilityMeters = flexibleDouble(c, "visibility"),
            isDay = flexibleBool(c, "is_day") ?: true,
            time = c.opt("time") as? String,
        )
    }

    fun parse(data: ByteArray): WeatherSnapshot = parse(String(data, Charsets.UTF_8))

    /** Russian description of a WMO weather interpretation code. */
    fun conditionDescription(code: Int): String = when (code) {
        0 -> "Ясно"
        1 -> "Преимущественно ясно"
        2 -> "Переменная облачность"
        3 -> "Пасмурно"
        45 -> "Туман"
        48 -> "Туман с изморозью"
        51 -> "Слабая морось"
        53 -> "Морось"
        55 -> "Сильная морось"
        56 -> "Слабая ледяная морось"
        57 -> "Сильная ледяная морось"
        61 -> "Небольшой дождь"
        63 -> "Дождь"
        65 -> "Сильный дождь"
        66 -> "Слабый ледяной дождь"
        67 -> "Сильный ледяной дождь"
        71 -> "Небольшой снег"
        73 -> "Снег"
        75 -> "Сильный снег"
        77 -> "Снежная крупа"
        80 -> "Слабый ливень"
        81 -> "Ливень"
        82 -> "Сильный ливень"
        85 -> "Снегопад"
        86 -> "Сильный снегопад"
        95 -> "Гроза"
        96 -> "Гроза с градом"
        97 -> "Сильная гроза"
        99 -> "Гроза с сильным градом"
        else -> "Погодные условия (код $code)"
    }

    // Decoding (tolerant: numbers may be null, booleans may arrive as 0/1)

    private fun flexibleDouble(o: JSONObject, key: String): Double? = when (val v = o.opt(key)) {
        is Number -> v.toDouble().let { if (it.isFinite()) it else null }
        is String -> Json.parseDouble(v)?.let { if (it.isFinite()) it else null }
        else -> null
    }

    private fun flexibleBool(o: JSONObject, key: String): Boolean? = when (val v = o.opt(key)) {
        is Boolean -> v
        is Number -> if (Json.isIntegral(v)) v.toLong() != 0L else null
        is String -> v.lowercase() in listOf("1", "true", "yes")
        else -> null
    }
}
