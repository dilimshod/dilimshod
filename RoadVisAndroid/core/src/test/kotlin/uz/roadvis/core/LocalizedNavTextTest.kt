package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Uzbek / English variants of formatting and turn instructions (port of LocalizedTextTests.swift; the
 * FollowingDistanceCalculator.methodDisplay assertions belong to the vision port and are not included here).
 */
class LocalizedNavTextTest {
    @Test fun distanceAllLanguages() {
        assertEquals(RVFormat.distance(347.0), RVFormat.distance(347.0, RVLang.RU))
        assertEquals("350 m", RVFormat.distance(347.0, RVLang.UZ))
        assertEquals("350 m", RVFormat.distance(347.0, RVLang.EN))
        assertEquals("1,2 km", RVFormat.distance(1240.0, RVLang.UZ))
        assertEquals("1.2 km", RVFormat.distance(1240.0, RVLang.EN))
        assertEquals("12 km", RVFormat.distance(12_400.0, RVLang.EN))
        assertEquals("—", RVFormat.distance(Double.NaN, RVLang.UZ))
    }

    @Test fun spokenDistance() {
        assertEquals("через 400 метров", RVFormat.spokenDistance(400.0, RVLang.RU))
        assertEquals("400 metrdan keyin", RVFormat.spokenDistance(400.0, RVLang.UZ))
        assertEquals("In 400 metres", RVFormat.spokenDistance(400.0, RVLang.EN))
        assertEquals("In 1 kilometre", RVFormat.spokenDistance(1000.0, RVLang.EN))
        assertEquals("In 1.5 kilometres", RVFormat.spokenDistance(1500.0, RVLang.EN))
        assertEquals("1,5 kilometrdan keyin", RVFormat.spokenDistance(1500.0, RVLang.UZ))
        assertEquals("2 kilometrdan keyin", RVFormat.spokenDistance(2000.0, RVLang.UZ))
    }

    @Test fun duration() {
        assertEquals("45 s", RVFormat.duration(45.0, RVLang.UZ))
        assertEquals("12 daq", RVFormat.duration(720.0, RVLang.UZ))
        assertEquals("12 min", RVFormat.duration(720.0, RVLang.EN))
        assertEquals("1 soat 05 daq", RVFormat.duration(3900.0, RVLang.UZ))
        assertEquals("1 h 05 min", RVFormat.duration(3900.0, RVLang.EN))
        assertEquals("1 ч 05 мин", RVFormat.duration(3900.0, RVLang.RU))
    }

    @Test fun osrmInstructionsUzbekEnglish() {
        assertEquals("Turn left onto Navoiy", NavInstructionText.osrm("turn", "left", "Navoiy", language = RVLang.EN))
        assertEquals("Chapga buriling, Navoiy tomon", NavInstructionText.osrm("turn", "left", "Navoiy", language = RVLang.UZ))
        assertEquals("Поверните налево на Навои", NavInstructionText.osrm("turn", "left", "Навои", language = RVLang.RU))
        assertEquals("At the roundabout, take the 2nd exit onto Bobur",
            NavInstructionText.osrm("roundabout", null, "Bobur", exit = 2, language = RVLang.EN))
        assertEquals("Aylanma harakatda 3-chiqishdan chiqing",
            NavInstructionText.osrm("roundabout", null, null, exit = 3, language = RVLang.UZ))
        assertEquals("Manzil o‘ng tomonda", NavInstructionText.osrm("arrive", "right", null, language = RVLang.UZ))
        assertEquals("Bobur bo‘ylab davom eting", NavInstructionText.osrm("continue", "straight", "Bobur", language = RVLang.UZ))
        assertEquals("11th", NavInstructionText.englishOrdinal(11))
        assertEquals("22nd", NavInstructionText.englishOrdinal(22))
        // Rebuilt texts still classify to the same maneuver.
        val cases = listOf(Triple("turn", "left", ManeuverType.LEFT), Triple("turn", "slight right", ManeuverType.SLIGHT_RIGHT),
            Triple("turn", "uturn", ManeuverType.U_TURN), Triple("arrive", "left", ManeuverType.ARRIVE),
            Triple("roundabout", "right", ManeuverType.ROUNDABOUT), Triple("fork", "slight left", ManeuverType.KEEP_LEFT))
        for ((type, modifier, expected) in cases) {
            for (lang in listOf(RVLang.UZ, RVLang.EN)) {
                val text = NavInstructionText.osrm(type, modifier, null, exit = 1, language = lang)
                assertEquals("$lang $text", expected, ManeuverClassifier.classify(text))
            }
        }
    }

    @Test fun valhallaUzbekRebuild() {
        val data = RoadFixture.data("valhalla_route_tashkent")
        val ru = Valhalla.parseRoutes(data)
        val uz = Valhalla.parseRoutes(data, RVLang.UZ)
        assertEquals(ru[0].steps.size, uz[0].steps.size)
        assertEquals("", uz[0].steps[0].instruction)
        assertEquals("«Srkver» aylanma harakatida 3-chiqishdan chiqing", uz[0].steps[1].instruction)
        assertEquals("Biroz chapga buriling, Mirzo Ulug'bek shoh ko'chasi tomon", uz[0].steps[3].instruction)
        assertEquals("Manzil o‘ng tomonda", uz[0].steps.last().instruction)
        for (step in uz[0].steps) {
            assertFalse(step.instruction, step.instruction.any { it.code in 0x0400..0x04FF })
        }
        assertEquals("en-US", RVLang.UZ.valhallaLanguage)
        assertEquals("ru-RU", RVLang.RU.valhallaLanguage)
    }

    @Test fun osrmParseEnglish() {
        val body = mapOf("code" to "Ok", "routes" to listOf(mapOf(
            "distance" to 500.0, "duration" to 60.0,
            "geometry" to Polyline.encode(listOf(GeoPoint(41.30, 69.24), GeoPoint(41.31, 69.24))),
            "legs" to listOf(mapOf("summary" to "", "steps" to listOf(
                mapOf("maneuver" to mapOf("type" to "depart"), "name" to "", "distance" to 300.0),
                mapOf("maneuver" to mapOf("type" to "turn", "modifier" to "right"), "name" to "Bobur", "distance" to 200.0),
                mapOf("maneuver" to mapOf("type" to "arrive"), "name" to "", "distance" to 0.0),
            ))),
        )))
        val routes = OSRM.parseRoutes(JSONObject(body).toString(), RVLang.EN)
        assertEquals("Turn right onto Bobur", routes[0].steps[1].instruction)
        assertEquals("Your destination", routes[0].steps[2].instruction)
    }

    @Test fun schedulerAndTrackerLanguage() {
        val scheduler = VoicePromptScheduler()
        scheduler.language = RVLang.UZ
        assertEquals("400 metrdan keyin o‘ngga buriling", scheduler.prompt(1, 390.0, "O‘ngga buriling", 50.0))
        assertEquals("You have arrived", NavInstructionText.destination(true, RVLang.EN))
    }

    @Test fun delayText() {
        assertEquals("+5 daq", RouteComparison.delayText(600.0, 300.0, RVLang.UZ))
        assertEquals("+5 min", RouteComparison.delayText(600.0, 300.0, RVLang.EN))
        assertEquals(RouteComparison.delayText(600.0, 300.0), RouteComparison.delayText(600.0, 300.0, RVLang.RU))
        assertNull(RouteComparison.delayText(310.0, 300.0, RVLang.EN))
    }
}
