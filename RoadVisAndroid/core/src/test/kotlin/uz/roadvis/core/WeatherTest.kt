package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

class WeatherTest {
    @Test fun parseRealOpenMeteoResponse() {
        // Real response for Tashkent (41.3111, 69.2797), fetched 2026-11-25.
        val w = OpenMeteo.parse(RoadFixture.data("open_meteo_current"))
        assertEquals(12.1, w.temperatureC ?: 0.0, 1e-9)
        assertEquals(11.7, w.apparentTemperatureC ?: 0.0, 1e-9)
        assertEquals(0.0, w.precipitationMm!!, 0.0)
        assertEquals(0.0, w.rainMm!!, 0.0)
        assertEquals(0.0, w.snowfallCm!!, 0.0)
        assertEquals(2, w.weatherCode)
        assertEquals(71.0, w.cloudCover!!, 0.0)
        assertEquals(2.3, w.windSpeedKmh ?: 0.0, 1e-9)
        assertEquals(9.0, w.windGustsKmh ?: 0.0, 1e-9)
        assertEquals(27080.0, w.visibilityMeters ?: 0.0, 1e-9)
        assertFalse(w.isDay)
        assertEquals("2026-11-25T19:30", w.time)
        assertEquals("Переменная облачность", w.conditionDescription)
        assertEquals("cloud.moon.fill", w.symbolName)
        assertEquals("+12°, переменная облачность, ветер 2 км/ч", w.summary)
        assertEquals(emptyList<String>(), w.roadWarnings)
    }

    @Test fun parseErrors() {
        val error = assertThrows(OpenMeteoError::class.java) { OpenMeteo.parse(RoadFixture.data("open_meteo_error")) }
        val reason = (error as? OpenMeteoError.Api)?.reason ?: throw AssertionError("expected api error, got $error")
        assertTrue(reason.startsWith("Latitude must be in range"))
        assertTrue(error.errorDescription.contains("Open-Meteo"))
        assertEquals(OpenMeteoError.Api("неизвестная ошибка"), assertThrows(OpenMeteoError::class.java) { OpenMeteo.parse("{\"error\":true}") })
        assertEquals(OpenMeteoError.MissingCurrent, assertThrows(OpenMeteoError::class.java) { OpenMeteo.parse("{\"latitude\":41.3}") })
        val invalid = assertThrows(OpenMeteoError::class.java) { OpenMeteo.parse("<html>") }
        assertTrue("expected invalidJSON, got $invalid", invalid is OpenMeteoError.InvalidJSON)
        assertThrows(OpenMeteoError::class.java) { OpenMeteo.parse("[1,2]") }
    }

    @Test fun parseToleratesNullsAndAlternativeTypes() {
        val json = """
        {"error": false, "current": {"time": "2026-01-10T08:00", "temperature_2m": null, "weather_code": 61.0,
         "is_day": true, "visibility": "800", "wind_speed_10m": 14}}
        """
        val w = OpenMeteo.parse(json)
        assertNull(w.temperatureC)
        assertNull(w.precipitationMm)
        assertEquals(61, w.weatherCode)
        assertTrue(w.isDay)
        assertEquals(800.0, w.visibilityMeters!!, 0.0)
        assertEquals(14.0, w.windSpeedKmh!!, 0.0)
        assertEquals("небольшой дождь, ветер 14 км/ч", w.summary)
        assertEquals(listOf("Плохая видимость (туман)"), w.roadWarnings)

        val missingIsDay = OpenMeteo.parse("{\"current\":{\"is_day\":0}}")
        assertFalse(missingIsDay.isDay)
        assertEquals("Нет данных о погоде", missingIsDay.summary)
        assertEquals("Нет данных", missingIsDay.conditionDescription)
        assertEquals("thermometer", missingIsDay.symbolName)
    }

    @Test fun url() {
        val url = OpenMeteo.url(GeoPoint(41.3111, 69.2797))
        assertEquals("https://api.open-meteo.com/v1/forecast?latitude=41.3111&longitude=69.2797" +
            "&current=temperature_2m,apparent_temperature,precipitation,rain,snowfall,weather_code," +
            "cloud_cover,wind_speed_10m,wind_gusts_10m,visibility,is_day&timezone=auto", url)
        val items = URI(url).query.split("&").associate { it.substringBefore("=") to it.substringAfter("=") }
        assertEquals("auto", items["timezone"])
        assertEquals(OpenMeteo.currentVariables.size, items["current"]?.split(",")?.size)

        val south = OpenMeteo.url(GeoPoint(-33.86882, 151.20929))
        assertTrue(south, south.contains("latitude=-33.8688&longitude=151.2093"))
        assertEquals("Погода: Open-Meteo.com (CC BY 4.0)", OpenMeteo.attribution)
    }

    @Test fun conditionDescriptions() {
        val documented = listOf(0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 97, 99)
        for (code in documented) {
            val text = OpenMeteo.conditionDescription(code)
            assertFalse("code $code has a proper description", text.contains("код"))
        }
        assertEquals("Ясно", OpenMeteo.conditionDescription(0))
        assertEquals("Пасмурно", OpenMeteo.conditionDescription(3))
        assertEquals("Туман", OpenMeteo.conditionDescription(45))
        assertEquals("Дождь", OpenMeteo.conditionDescription(63))
        assertEquals("Гроза", OpenMeteo.conditionDescription(95))
        assertTrue(OpenMeteo.conditionDescription(42).contains("42"))
    }

    @Test fun symbols() {
        fun symbol(code: Int, day: Boolean = true) = WeatherSnapshot(weatherCode = code, isDay = day).symbolName
        assertEquals("sun.max.fill", symbol(0))
        assertEquals("moon.stars.fill", symbol(0, day = false))
        assertEquals("cloud.sun.fill", symbol(2))
        assertEquals("cloud.fill", symbol(3))
        assertEquals("cloud.fog.fill", symbol(45))
        assertEquals("cloud.drizzle.fill", symbol(53))
        assertEquals("cloud.sleet.fill", symbol(66))
        assertEquals("cloud.rain.fill", symbol(61))
        assertEquals("cloud.heavyrain.fill", symbol(82))
        assertEquals("cloud.snow.fill", symbol(75))
        assertEquals("cloud.bolt.rain.fill", symbol(95))
        assertEquals("cloud.hail.fill", symbol(99))
        assertEquals("thermometer", symbol(1234))
    }

    @Test fun summaryTemperatureFormatting() {
        assertEquals("-3°, небольшой снег, ветер 18 км/ч", WeatherSnapshot(temperatureC = -3.4, weatherCode = 71, windSpeedKmh = 18.4).summary)
        assertEquals("0°", WeatherSnapshot(temperatureC = 0.4).summary)
        assertEquals("0°", WeatherSnapshot(temperatureC = -0.4).summary)
        assertEquals("+13°, дождь, ветер 18 км/ч", WeatherSnapshot(temperatureC = 12.5, weatherCode = 63, windSpeedKmh = 18.0).summary)
    }

    @Test fun roadWarnings() {
        assertEquals(listOf("Возможна гололедица"), WeatherSnapshot(temperatureC = 0.5, precipitationMm = 0.2, weatherCode = 61).roadWarnings)
        assertEquals(listOf("Возможна гололедица", "Снег на дороге"), WeatherSnapshot(temperatureC = 0.0, weatherCode = 71).roadWarnings)
        assertEquals(listOf("Снег на дороге"), WeatherSnapshot(temperatureC = 3.0, weatherCode = 71).roadWarnings)
        assertEquals(listOf("Возможна гололедица", "Плохая видимость (туман)"), WeatherSnapshot(temperatureC = -2.0, weatherCode = 48).roadWarnings)
        assertEquals("freezing rain", listOf("Возможна гололедица"), WeatherSnapshot(temperatureC = 2.0, weatherCode = 66).roadWarnings)
        assertEquals(listOf("Возможна гололедица", "Снег на дороге"), WeatherSnapshot(temperatureC = 1.0, snowfallCm = 0.3, weatherCode = 3).roadWarnings)
        assertEquals("dry frost", emptyList<String>(), WeatherSnapshot(temperatureC = -5.0, precipitationMm = 0.0, weatherCode = 0).roadWarnings)
        assertEquals(listOf("Плохая видимость (туман)"), WeatherSnapshot(temperatureC = 8.0, weatherCode = 45).roadWarnings)
        assertEquals(listOf("Плохая видимость (туман)"), WeatherSnapshot(temperatureC = 8.0, weatherCode = 3, visibilityMeters = 600.0).roadWarnings)
        assertEquals(emptyList<String>(), WeatherSnapshot(temperatureC = 8.0, weatherCode = 3, visibilityMeters = 1500.0).roadWarnings)
        assertEquals(listOf("Ливень — увеличьте дистанцию"), WeatherSnapshot(temperatureC = 15.0, weatherCode = 82).roadWarnings)
        assertEquals(listOf("Ливень — увеличьте дистанцию"), WeatherSnapshot(temperatureC = 15.0, precipitationMm = 4.5, weatherCode = 63).roadWarnings)
        assertEquals(emptyList<String>(), WeatherSnapshot(temperatureC = 15.0, precipitationMm = 3.0, weatherCode = 63).roadWarnings)
        assertEquals(listOf("Гроза"), WeatherSnapshot(temperatureC = 25.0, weatherCode = 95).roadWarnings)
        assertEquals(listOf("Гроза"), WeatherSnapshot(temperatureC = 25.0, weatherCode = 99).roadWarnings)
        assertEquals(listOf("Сильный ветер — порывы 63 км/ч"), WeatherSnapshot(temperatureC = 20.0, weatherCode = 1, windGustsKmh = 63.4).roadWarnings)
        assertEquals(emptyList<String>(), WeatherSnapshot(temperatureC = 20.0, weatherCode = 1, windGustsKmh = 49.0).roadWarnings)
        assertEquals("no temperature: freezing codes still warn", listOf("Возможна гололедица"), WeatherSnapshot(weatherCode = 67).roadWarnings)
        assertEquals(emptyList<String>(), WeatherSnapshot().roadWarnings)
    }
}
