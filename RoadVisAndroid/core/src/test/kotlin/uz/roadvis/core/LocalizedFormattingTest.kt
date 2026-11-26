package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Uzbek / English variants of formatting (port of the formatting cases of LocalizedTextTests.swift; the OSRM / Valhalla /
 * scheduler / RouteComparison cases belong to the navigation port).
 */
class LocalizedFormattingTest {
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

    @Test fun valhallaLanguageAndMethodDisplay() {
        assertEquals("en-US", RVLang.UZ.valhallaLanguage)
        assertEquals("ru-RU", RVLang.RU.valhallaLanguage)
        assertEquals("width+height", FollowingDistanceCalculator.methodDisplay("ширина+высота", RVLang.EN))
        assertEquals("eni (kesilgan)", FollowingDistanceCalculator.methodDisplay("ширина (обрезано)", RVLang.UZ))
        assertEquals("ширина", FollowingDistanceCalculator.methodDisplay("ширина", RVLang.RU))
    }
}
