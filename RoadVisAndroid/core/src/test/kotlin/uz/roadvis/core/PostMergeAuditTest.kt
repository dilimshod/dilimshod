package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.min

/** Regression tests for the defects found by the post-merge audit (mirror of the Swift `PostMergeAuditTests`). */
class PostMergeAuditTest {
    // Pedestrian crossing intent must not depend on the configured horizon

    /** Pinhole projection of a person standing [lateral] metres right of the lane centre, [depth] metres ahead. */
    private fun standingPerson(lateral: Double, depth: Double, trueHorizon: Double, geometry: CameraGeometry, t: Double): TrackedObject {
        val f = geometry.focalLengthPixels
        val x = 0.5 + f * lateral / (depth * geometry.imageWidth)
        val footY = trueHorizon + f * 1.2 / (depth * geometry.imageHeight) // camera 1.2 m above the road
        val h = f * 1.7 / (depth * geometry.imageHeight)
        val w = f * 0.5 / (depth * geometry.imageWidth)
        return TrackedObject(id = 1, kind = VehicleKind.PERSON, label = "person", box = BBox(x - w / 2, footY - h, w, h),
            confidence = 0.8, hits = 6, firstSeen = 0.0, lastSeen = t, isConfirmed = true)
    }

    private class Counts(val danger: Int, val approaching: Int)

    private fun driveTowardStandingPerson(
        geometry: CameraGeometry, speedKmh: Double, lateral: Double, trueHorizon: (Double) -> Double,
        depth: (Double) -> Double, frames: Int,
    ): Counts {
        val detector = PedestrianHazardDetector(
            corridor = EgoCorridor.forFrame(imageWidth = geometry.imageWidth, imageHeight = geometry.imageHeight))
        var danger = 0
        var approaching = 0
        for (i in 0 until frames) {
            val t = i / 15.0
            val person = standingPerson(lateral, depth(t), trueHorizon(t), geometry, t)
            val r = detector.evaluate(listOf(person), speedKmh, geometry, t)
            if (r.hazards.any { it.level == PedestrianHazardLevel.DANGER }) danger += 1
            if (r.hazards.any { it.approaching }) approaching += 1
        }
        return Counts(danger, approaching)
    }

    @Test fun standingKerbPedestrianIsNotApproachingWhenHorizonIsOffLandscape() {
        val g = CameraGeometry(65.0, 1920.0, 1080.0)
        val v = 50 / 3.6
        for (horizon in listOf(0.41, 0.40)) for (lateral in listOf(3.0, 4.0, 5.0)) {
            val r = driveTowardStandingPerson(g, 50.0, lateral, { horizon }, { 40 - v * it }, 33)
            assertEquals("horizon $horizon, $lateral m", 0, r.danger)
            assertEquals("horizon $horizon, $lateral m", 0, r.approaching)
        }
    }

    @Test fun standingKerbPedestrianIsNotApproachingWhenHorizonIsOffPortrait() {
        val g = CameraGeometry.defaultPortrait
        val v = 20 / 3.6
        for (horizon in listOf(0.41, 0.40)) for (lateral in listOf(3.0, 4.0, 5.0)) {
            val r = driveTowardStandingPerson(g, 20.0, lateral, { horizon }, { 35 - v * it }, 60)
            assertEquals("horizon $horizon, $lateral m", 0, r.danger)
            assertEquals("horizon $horizon, $lateral m", 0, r.approaching)
        }
    }

    @Test fun brakeNodDoesNotTurnStandingPedestrianIntoDanger() {
        val g = CameraGeometry(65.0, 1920.0, 1080.0)
        // Constant 15 m; the horizon rises by 0.02 over one second (the car nods), holds, and returns.
        val nod: (Double) -> Double = { t ->
            when {
                t < 1 -> 0.42
                t < 2 -> 0.42 - 0.02 * (t - 1)
                t < 3 -> 0.40
                else -> min(0.42, 0.40 + 0.02 * (t - 3))
            }
        }
        val r = driveTowardStandingPerson(g, 30.0, 3.0, nod, { 15.0 }, 75)
        assertEquals(0, r.danger)
        assertEquals(0, r.approaching)
    }

    @Test fun walkerTowardTheRoadIsStillApproaching() {
        // A person 15 m ahead walks 1.4 m/s from 4 m right of the lane centre toward the road; the car stands.
        val g = CameraGeometry.defaultPortrait
        val detector = PedestrianHazardDetector()
        var approachingFrames = 0
        for (i in 0 until 30) {
            val t = i / 15.0
            val person = standingPerson(4 - 1.4 * t, 15.0, 0.42, g, t)
            val r = detector.evaluate(listOf(person), 0.0, g, t)
            if (r.hazards.any { it.approaching }) approachingFrames += 1
        }
        assertTrue("$approachingFrames", approachingFrames > 10)
    }

    // Traffic-light colour vote at low frame rates

    private fun light(c: TrafficLightColor) = Detection(kind = VehicleKind.TRAFFIC_LIGHT, label = "traffic light",
        confidence = 0.6, box = BBox(0.5, 0.1, 0.03, 0.08), lightColor = c)

    @Test fun effectiveWindowFollowsTheFrameInterval() {
        fun history(dt: Double, count: Int) =
            (0 until count).map { TrafficLightColorVote.Observation(it * dt, TrafficLightColor.RED) }
        assertEquals(0.8, TrafficLightColorVote.effectiveWindow(emptyList()), 0.0)
        assertEquals(0.8, TrafficLightColorVote.effectiveWindow(history(1.0 / 15, 10)), 1e-9)
        assertEquals(5.0 / 3, TrafficLightColorVote.effectiveWindow(history(1.0 / 3, 5)), 1e-9)
        assertEquals(2.0, TrafficLightColorVote.effectiveWindow(history(1.0, 5)), 1e-9)
    }

    @Test fun steadyRedAtThreeFramesPerSecondWithUnreadableFrames() {
        val tracker = ObjectTracker()
        val colours = ArrayList<TrafficLightColor?>()
        for (i in 0 until 30) {
            // Every third frame the lamp is unreadable.
            val colour = if (i % 3 == 2) TrafficLightColor.UNKNOWN else TrafficLightColor.RED
            colours.add(tracker.update(listOf(light(colour)), i / 3.0).firstOrNull()?.lightColor)
        }
        // After the first two seconds the colour is red on every frame.
        assertTrue("$colours", colours.drop(6).all { it == TrafficLightColor.RED })
    }

    @Test fun greenIsRecognisedSoonAfterTheChangeAtThreeFramesPerSecond() {
        val tracker = ObjectTracker()
        var t = 0.0
        repeat(12) { tracker.update(listOf(light(TrafficLightColor.RED)), t); t += 1.0 / 3 }
        var switchedAfter: Double? = null
        val change = t
        repeat(12) {
            if (tracker.update(listOf(light(TrafficLightColor.GREEN)), t).firstOrNull()?.lightColor == TrafficLightColor.GREEN &&
                switchedAfter == null) switchedAfter = t - change
            t += 1.0 / 3
        }
        assertNotNull(switchedAfter)
        assertTrue("$switchedAfter", switchedAfter!! <= 1.5)
    }

    // Coach: a silent message does not start the global gap

    @Test fun inaudibleMessageDoesNotConsumeTheGlobalGap() {
        val r = CoachRules()
        val silentSigns: (CoachMessage) -> Boolean = { it.category != CoachCategory.SIGN }
        r.offer(CoachMessage.SpeedLimit(60), 0.0)
        assertEquals(CoachMessage.SpeedLimit(60), r.next(0.0, silentSigns))
        r.offer(CoachMessage.RedLightAhead, 0.5)
        assertEquals(CoachMessage.RedLightAhead, r.next(0.5, silentSigns))
        // An audible message starts the gap as before.
        r.offer(CoachMessage.LaneDeparture(LaneSide.LEFT), 1.0)
        assertNull(r.next(1.0, silentSigns))
        // The category cooldown of the silent message still applies.
        val q = CoachRules()
        q.offer(CoachMessage.GreenLightGo, 0.0)
        assertEquals(CoachMessage.GreenLightGo, q.next(0.0) { false })
        q.offer(CoachMessage.GreenLightGo, 1.0)
        assertNull(q.next(1.0) { false })
    }

    @Test fun coachEngineForwardsAudibility() {
        val engine = DriverCoachEngine()
        engine.offer(CoachMessage.SpeedLimit(60), 0.0)
        assertEquals(CoachMessage.SpeedLimit(60), engine.next(0.0) { false })
        engine.offer(CoachMessage.RedLightAhead, 0.2)
        assertEquals(CoachMessage.RedLightAhead, engine.next(0.2))
    }

    @Test fun silentMessagesPerSoundMode() {
        assertTrue(AlertToneKind.isAudible(CoachMessage.SpeedLimit(60), SoundMode.ALL))
        assertTrue(AlertToneKind.isAudible(CoachMessage.GreenLightGo, SoundMode.VOICE_ONLY))
        assertFalse(AlertToneKind.isAudible(CoachMessage.SpeedLimit(60), SoundMode.SOUNDS_ONLY))
        assertFalse(AlertToneKind.isAudible(CoachMessage.RoadSign(RouteFeatureKind.SCHOOL, 150), SoundMode.SOUNDS_ONLY))
        assertFalse(AlertToneKind.isAudible(CoachMessage.GreenLightGo, SoundMode.SOUNDS_ONLY))
        assertTrue(AlertToneKind.isAudible(CoachMessage.RedLightAhead, SoundMode.SOUNDS_ONLY))
        assertTrue(AlertToneKind.isAudible(CoachMessage.LaneDeparture(LaneSide.LEFT), SoundMode.SOUNDS_ONLY))
        assertFalse(AlertToneKind.isAudible(CoachMessage.RedLightAhead, SoundMode.SILENT))

        // "Sounds only": a sign announcement must not delay the red-light tone.
        val r = CoachRules()
        val audible: (CoachMessage) -> Boolean = { AlertToneKind.isAudible(it, SoundMode.SOUNDS_ONLY) }
        r.offer(CoachMessage.SpeedLimit(60), 0.0)
        assertNotNull(r.next(0.0, audible))
        r.offer(CoachMessage.RedLightAhead, 0.3)
        assertEquals(CoachMessage.RedLightAhead, r.next(0.3, audible))
    }

    @Test fun onlyMomentBoundAdviceExpiresQuickly() {
        assertEquals(3.0, CoachMessage.LaneDeparture(LaneSide.LEFT).maxSpeechWait(8.0), 0.0)
        assertEquals(3.0, CoachMessage.KeepDistance(30).maxSpeechWait(8.0), 0.0)
        val lasting = listOf(CoachMessage.SpeedLimit(60), CoachMessage.SpeedLimitAhead(40, 200),
            CoachMessage.RoadSign(RouteFeatureKind.SCHOOL, 150), CoachMessage.StopSignAhead, CoachMessage.OverSpeedLimit(60),
            CoachMessage.TrafficOfficerAhead(1), CoachMessage.RoadWorkersAhead(2), CoachMessage.PedestrianCaution(3),
            CoachMessage.RedLightAhead, CoachMessage.GreenLightGo)
        for (message in lasting) {
            assertFalse("$message", message.isMomentBound)
            assertEquals("$message", 8.0, message.maxSpeechWait(8.0), 0.0)
        }
        assertEquals(2.0, CoachMessage.LaneDeparture(LaneSide.RIGHT).maxSpeechWait(2.0), 0.0)
    }

    // Overpass fallback

    @Test fun thirdServerIsStillTriedAfterTwoTimeouts() {
        assertEquals(25.0, OverpassFallbackPolicy.attemptTimeout(25.0, 0), 0.0)
        assertEquals(25.0, OverpassFallbackPolicy.attemptTimeout(25.0, 1), 0.0)
        assertEquals(10.0, OverpassFallbackPolicy.attemptTimeout(25.0, 2), 0.0)
        assertEquals(10.0, OverpassFallbackPolicy.attemptTimeout(25.0, 3), 0.0)
        assertEquals(8.0, OverpassFallbackPolicy.attemptTimeout(8.0, 2), 0.0)
    }

    // Navigation

    private val start = GeoPoint(41.3, 69.2)

    private fun straightRoute(length: Double): List<GeoPoint> {
        val pts = ArrayList<GeoPoint>()
        var d = 0.0
        while (d <= length) {
            pts.add(Geo.destination(start, 90.0, d))
            d += 50
        }
        return pts
    }

    private fun point(along: Double, offset: Double): GeoPoint =
        Geo.destination(Geo.destination(start, 90.0, along), 0.0, offset)

    @Test fun parallelStreetBesideNeverMatchedRouteBecomesOffRoute() {
        for (direction in listOf(1.0, -1.0)) {
            val t = RouteProgressTracker(straightRoute(3000.0), emptyList(), expectedTravelTime = 300.0)
            var offRouteAt: Double? = null
            var along = 1500.0
            for (i in 0 until 40) {
                if (t.update(point(along, 120.0)).isOffRoute) {
                    offRouteAt = abs(along - 1500)
                    break
                }
                along += 15 * direction
            }
            assertNotNull(offRouteAt)
            assertTrue("$offRouteAt", offRouteAt!! > 150 && offRouteAt <= 200)
        }
    }

    @Test fun standingOrApproachingNeverMatchedRouteStaysOnRoute() {
        val standing = RouteProgressTracker(straightRoute(3000.0), emptyList(), expectedTravelTime = 300.0)
        repeat(20) { assertFalse(standing.update(point(500.0, 120.0)).isOffRoute) }
        // Driving 400 m to a route that is 400 m away (heading for it at 45°): never off-route.
        val approaching = RouteProgressTracker(straightRoute(3000.0), emptyList(), expectedTravelTime = 300.0)
        var offset = 400.0
        var along = 500.0
        while (offset > 0) {
            assertFalse(approaching.update(point(along, offset)).isOffRoute)
            offset -= 10
            along += 10
        }
    }

    @Test fun lastMatchThresholdFollowsFixAccuracy() {
        val t = RouteProgressTracker(straightRoute(1000.0), emptyList(), expectedTravelTime = 100.0)
        assertEquals(50.0, t.lastMatchThreshold, 0.0)
        // Accuracy 60 m widens the threshold to 100 m: a fix 70 m beside the line still advances the progress.
        val p = t.update(point(200.0, 70.0), horizontalAccuracy = 60.0)
        assertEquals(100.0, t.lastMatchThreshold, 0.0)
        assertEquals(200.0, p.distanceAlong, 2.0)
        assertTrue(p.crossTrackDistance <= t.lastMatchThreshold)
        t.update(point(220.0, 3.0), horizontalAccuracy = 5.0)
        assertEquals(50.0, t.lastMatchThreshold, 0.0)
    }

    @Test fun reroutePreferenceIsBoundedByTravelTime() {
        val north = listOf(start, Geo.destination(start, 0.0, 200.0))
        val south = listOf(start, Geo.destination(start, 180.0, 200.0))
        // Fastest (6 min) starts with a U-turn; the forward one takes 25 min: the fastest is kept.
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south, north), 0.0, travelTimes = listOf(360.0, 1500.0)))
        // Within max(120 s, 15 %): the forward start wins.
        assertEquals(1, ReroutePolicy.preferredIndex(listOf(south, north), 0.0, travelTimes = listOf(360.0, 470.0)))
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south, north), 0.0, travelTimes = listOf(360.0, 481.0)))
        assertEquals(1, ReroutePolicy.preferredIndex(listOf(south, north), 0.0, travelTimes = listOf(3600.0, 4100.0)))
        assertEquals(0, ReroutePolicy.preferredIndex(listOf(south, north), 0.0, travelTimes = listOf(3600.0, 4200.0)))
        // A too-slow forward option is skipped, a later acceptable one is taken.
        assertEquals(2, ReroutePolicy.preferredIndex(listOf(south, north, north), 0.0, travelTimes = listOf(360.0, 1500.0, 400.0)))
        // No times: unbounded, as before.
        assertEquals(1, ReroutePolicy.preferredIndex(listOf(south, north), 0.0))
    }
}
