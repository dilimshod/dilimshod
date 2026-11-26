package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NavigationLogicTest {
    @Test fun maneuverClassifierRussian() {
        assertEquals(ManeuverType.RIGHT, ManeuverClassifier.classify("Поверните направо на улицу Амира Темура"))
        assertEquals(ManeuverType.LEFT, ManeuverClassifier.classify("Поверните налево"))
        assertEquals(ManeuverType.SLIGHT_RIGHT, ManeuverClassifier.classify("Плавно поверните направо"))
        assertEquals(ManeuverType.SHARP_LEFT, ManeuverClassifier.classify("Резко поверните налево"))
        assertEquals(ManeuverType.U_TURN, ManeuverClassifier.classify("Развернитесь"))
        assertEquals(ManeuverType.ROUNDABOUT, ManeuverClassifier.classify("На круговом движении сверните на 2-й съезд"))
        assertEquals(ManeuverType.KEEP_LEFT, ManeuverClassifier.classify("Держитесь левее"))
        assertEquals(ManeuverType.ARRIVE, ManeuverClassifier.classify("Пункт назначения будет справа"))
        assertEquals(ManeuverType.STRAIGHT, ManeuverClassifier.classify("Продолжайте движение прямо"))
        assertEquals(ManeuverType.DEPART, ManeuverClassifier.classify(""))
    }

    @Test fun maneuverClassifierEnglishUzbek() {
        assertEquals(ManeuverType.RIGHT, ManeuverClassifier.classify("Turn right onto Main St"))
        assertEquals(ManeuverType.U_TURN, ManeuverClassifier.classify("Make a U-turn"))
        assertEquals(ManeuverType.EXIT_RIGHT, ManeuverClassifier.classify("Take exit 5 on the right"))
        assertEquals(ManeuverType.RIGHT, ManeuverClassifier.classify("O'ngga buriling"))
        assertEquals(ManeuverType.LEFT, ManeuverClassifier.classify("Chapga buriling"))
    }

    @Test fun laneGuidance() {
        val lanes = listOf(Lane(listOf(LaneTurn.LEFT)), Lane(listOf(LaneTurn.THROUGH)), Lane(listOf(LaneTurn.THROUGH, LaneTurn.RIGHT)))
        assertEquals(listOf(true, false, false), LaneGuidance.recommendedLanes(lanes, ManeuverType.LEFT))
        assertEquals(listOf(false, true, true), LaneGuidance.recommendedLanes(lanes, ManeuverType.STRAIGHT))
        assertEquals(listOf(false, false, true), LaneGuidance.recommendedLanes(lanes, ManeuverType.RIGHT))
        assertEquals(listOf(false, true), LaneGuidance.recommendedLanes(listOf(Lane(emptyList()), Lane(emptyList())), ManeuverType.RIGHT))
        assertEquals(emptyList<Boolean>(), LaneGuidance.recommendedLanes(emptyList(), ManeuverType.LEFT))
    }

    @Test fun formatting() {
        assertEquals("350 м", RVFormat.distance(347.0))
        assertEquals("1,2 км", RVFormat.distance(1234.0))
        assertEquals("15 км", RVFormat.distance(15400.0))
        assertEquals("45 с", RVFormat.duration(45.0))
        assertEquals("12 мин", RVFormat.duration(12 * 60.0))
        assertEquals("1 ч 05 мин", RVFormat.duration(65 * 60.0))
        assertEquals("через 400 метров", RVFormat.spokenDistance(400.0))
        assertEquals("через 1,5 километра", RVFormat.spokenDistance(1500.0))
        assertEquals("через 2 километра", RVFormat.spokenDistance(2000.0))
        assertEquals("метр", RVFormat.plural(21, "метр", "метра", "метров"))
        assertEquals("метров", RVFormat.plural(12, "метр", "метра", "метров"))
    }

    private fun makeRoute(): Pair<List<GeoPoint>, List<RouteStepInfo>> {
        // L-shaped route: east 1000 m, then north 500 m.
        val start = GeoPoint(41.3, 69.2)
        val corner = Geo.destination(start, 90.0, 1000.0)
        val end = Geo.destination(corner, 0.0, 500.0)
        val pts = ArrayList<GeoPoint>()
        for (i in 0..10) pts.add(Geo.destination(start, 90.0, i * 100.0))
        for (i in 1..5) pts.add(Geo.destination(corner, 0.0, i * 100.0))
        pts[pts.size - 1] = end
        val steps = listOf(RouteStepInfo("", 0.0),
            RouteStepInfo("Двигайтесь на восток", 1000.0),
            RouteStepInfo("Поверните налево", 500.0),
            RouteStepInfo("Пункт назначения будет справа", 0.0))
        return pts to steps
    }

    @Test fun routeProgress() {
        val (pts, steps) = makeRoute()
        val tracker = RouteProgressTracker(pts, steps, expectedTravelTime = 300.0)
        assertEquals(1500.0, tracker.totalDistance, 2.0)
        val p = tracker.update(Geo.destination(pts[3], 0.0, 8.0))
        assertEquals(300.0, p.distanceAlong, 3.0)
        assertEquals(2, p.nextStepIndex)
        assertEquals(ManeuverType.LEFT, p.nextManeuver)
        assertEquals(700.0, p.distanceToNextManeuver!!, 3.0)
        assertEquals(240.0, p.remainingTimeSeconds, 2.0)
        assertFalse(p.isOffRoute)
        assertEquals("Пункт назначения будет справа", p.followingInstruction)
    }

    @Test fun routeOffRouteAndArrival() {
        val (pts, steps) = makeRoute()
        val tracker = RouteProgressTracker(pts, steps, expectedTravelTime = 300.0, offRouteConfirmations = 3)
        val far = Geo.destination(pts[5], 180.0, 200.0)
        var last = tracker.update(far)
        assertFalse(last.isOffRoute)
        last = tracker.update(far)
        last = tracker.update(far)
        assertTrue(last.isOffRoute)
        val arrived = tracker.update(pts.last())
        assertTrue(arrived.hasArrived)
        assertFalse(arrived.isOffRoute)
    }

    @Test fun voicePromptScheduler() {
        val s = VoicePromptScheduler()
        assertNull(s.prompt(2, 1500.0, "Поверните налево", 60.0))
        assertEquals("через 1 километр поверните налево", s.prompt(2, 980.0, "Поверните налево", 60.0))
        assertNull(s.prompt(2, 900.0, "Поверните налево", 60.0))
        assertEquals("через 400 метров поверните налево", s.prompt(2, 390.0, "Поверните налево", 60.0))
        assertEquals("Поверните налево", s.prompt(2, 90.0, "Поверните налево", 60.0))
        // Slow traffic: skip the 1 km prompt.
        assertNull(s.prompt(3, 950.0, "Поверните направо", 20.0))
        // Jumping straight to 90 m announces only once.
        val s2 = VoicePromptScheduler()
        assertEquals("Поверните направо", s2.prompt(1, 90.0, "Поверните направо", 40.0))
        assertNull(s2.prompt(1, 80.0, "Поверните направо", 40.0))
    }
}
