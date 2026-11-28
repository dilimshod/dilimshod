package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import kotlin.math.max
import kotlin.math.min

// Port of VisionAuditTests.swift: regression tests for the core-vision audit (portrait / landscape geometry, lead
// selection, traffic lights, pedestrians / road staff) and for the people-and-lights design changes.

/** Flat-ground pinhole projection used to build realistic boxes (camera 1.2 m high, level). */
private class Scene(val geometry: CameraGeometry, val horizonY: Double = 0.42, val cameraHeight: Double = 1.2) {
    /** Box of an object [width] × [height] metres standing on the ground at lateral offset [x] and depth [z] metres. */
    fun box(x: Double, z: Double, width: Double, height: Double): BBox {
        val f = geometry.focalLengthPixels
        val bottom = horizonY + f * cameraHeight / (z * geometry.imageHeight)
        val cx = 0.5 + f * x / (z * geometry.imageWidth)
        val w = f * width / (z * geometry.imageWidth); val h = f * height / (z * geometry.imageHeight)
        return BBox(cx - w / 2, bottom - h, w, h)
    }
}

private val portrait = CameraGeometry.defaultPortrait
private val landscape = CameraGeometry(65.0, 1920.0, 1080.0)

private fun vehicle(id: Int, box: BBox, kind: VehicleKind = VehicleKind.CAR, t: Double = 0.0) =
    TrackedObject(id = id, kind = kind, label = kind.raw, box = box, confidence = 0.9, hits = 6, firstSeen = 0.0,
        lastSeen = t, isConfirmed = true)

private fun person(id: Int, box: BBox, t: Double = 0.0, role: PersonRole? = null) =
    TrackedObject(id = id, kind = VehicleKind.PERSON, label = "person", box = box, confidence = 0.8, hits = 6,
        firstSeen = 0.0, lastSeen = t, isConfirmed = true, personRole = role)

private fun lightTrack(id: Int, color: TrafficLightColor?, x: Double, y: Double = 0.2, height: Double = 0.08, hits: Int = 6) =
    TrackedObject(id = id, kind = VehicleKind.TRAFFIC_LIGHT, label = "traffic light",
        box = BBox(x - 0.015, y, 0.03, height), confidence = 0.6, hits = hits, firstSeen = 0.0, lastSeen = 0.0,
        isConfirmed = true, lightColor = color)

// Finding 1: aspect-aware own-lane corridor

class EgoCorridorAspectTest {
    @Test fun landscapeCorridorUnchanged() {
        assertEquals(EgoCorridor(), EgoCorridor.forFrame(imageWidth = 1920.0, imageHeight = 1080.0))
        assertEquals(EgoCorridor(centerX = 0.45, horizonY = 0.5),
            EgoCorridor.forFrame(centerX = 0.45, horizonY = 0.5, imageWidth = 1280.0, imageHeight = 720.0))
        assertEquals(1.0, EgoCorridor.aspectScale(0.0, 100.0), 0.0)
        // Wider than 16:9 never narrows the corridor.
        assertEquals(1.0, EgoCorridor.aspectScale(2400.0, 1080.0), 0.0)
    }

    @Test fun portraitCorridorIsWider() {
        val c = EgoCorridor.forFrame(imageWidth = 1080.0, imageHeight = 1920.0)
        assertEquals(3.16, EgoCorridor.aspectScale(1080.0, 1920.0), 0.01)
        assertEquals(0.04 + 0.2 * 3.1605, c.bottomHalfWidth, 0.001)
        assertEquals(0.04, c.horizonHalfWidth, 0.0)
    }

    @Test fun portraitOffCentreLeadIsAheadAndNextLaneIsNot() {
        val scene = Scene(portrait)
        val fixed = EgoCorridor.forFrame(imageWidth = 1080.0, imageHeight = 1920.0)
        for (z in listOf(5.0, 7.0, 10.0)) {
            val offCentre = scene.box(0.5, z, 1.8, 1.5)
            assertTrue("0.5 m off-centre at $z m", fixed.isStrictlyAhead(offCentre))
            val nextLane = scene.box(3.5, z, 1.8, 1.5)
            assertFalse("next lane at $z m", fixed.isStrictlyAhead(nextLane))
        }
        assertFalse(fixed.isStrictlyAhead(scene.box(-3.5, 20.0, 1.8, 1.5)))
        // The defect: with the landscape widths that car was not "strictly ahead" in portrait.
        val old = EgoCorridor()
        assertFalse(old.isStrictlyAhead(scene.box(0.5, 10.0, 1.8, 1.5)))
        assertTrue((old.lateralOffset(scene.box(0.5, 10.0, 1.8, 1.5)) ?: 0.0) > 0.9)
        assertTrue((fixed.lateralOffset(scene.box(0.5, 10.0, 1.8, 1.5)) ?: 9.0) < 0.6)
    }

    @Test fun portraitLeadTrackerPicksOffCentreCar() {
        val scene = Scene(portrait)
        val tracker = LeadVehicleTracker(corridor = EgoCorridor.forFrame(imageWidth = 1080.0, imageHeight = 1920.0))
        val lead = tracker.update(listOf(vehicle(1, scene.box(0.5, 10.0, 1.8, 1.5))), portrait, 0.0)
        assertEquals(1, lead?.trackID)
        assertEquals(10.0, lead?.cameraDistanceMeters ?: 0.0, 0.5)
    }

    @Test fun portraitPedestrianNearCentrelineIsInOwnLane() {
        val scene = Scene(portrait)
        val d = PedestrianHazardDetector(corridor = EgoCorridor.forFrame(imageWidth = 1080.0, imageHeight = 1920.0))
        val r = d.evaluate(listOf(person(1, scene.box(0.5, 6.0, 0.5, 1.7))), 2.0, portrait, 0.0)
        assertEquals(PedestrianHazardLevel.DANGER, r.hazards.firstOrNull()?.level)
        assertEquals(true, r.hazards.firstOrNull()?.inOwnLane)
    }
}

// Finding 2: pedestrian aspect ratio in pixels

class PedestrianAspectTest {
    @Test fun portraitWalkingPedestrianIsPlausible() {
        val d = PedestrianHazardDetector()
        // 0.10 × 0.12 normalized in a 1080×1920 frame = 108 × 230 px, ratio 2.13 (legs apart / carrying a bag).
        val walker = person(1, BBox(0.45, 0.58, 0.10, 0.12))
        assertTrue(d.isPlausible(walker, portrait))
        val r = d.evaluate(listOf(walker), 30.0, portrait, 0.0)
        assertEquals(PedestrianHazardLevel.DANGER, r.hazards.firstOrNull()?.level)
    }

    @Test fun landscapeSquareBlobIsRejected() {
        val d = PedestrianHazardDetector()
        // 0.10 × 0.16 normalized in a 1920×1080 frame = 192 × 173 px, ratio 0.9: not a standing person.
        val blob = person(1, BBox(0.45, 0.5, 0.10, 0.16))
        assertFalse(d.isPlausible(blob, landscape))
        assertTrue(d.evaluate(listOf(blob), 30.0, landscape, 0.0).hazards.isEmpty())
        // A real person in landscape: 0.04 × 0.20 = 77 × 216 px.
        assertTrue(d.isPlausible(person(2, BBox(0.48, 0.45, 0.04, 0.20)), landscape))
    }
}

// Findings 4, 5, 6: lead vehicle

class LeadVehicleAuditTest {
    private val policy = FollowingDistancePolicy()

    @Test fun classVoteFlipDoesNotLookLikeClosing() {
        val tracker = LeadVehicleTracker()
        // A 1.9 × 1.9 m vehicle really at 12 m, constant box; the track's class vote is truck, then flips to car.
        val box = Scene(portrait).box(0.0, 12.0, 1.9, 1.9)
        val distances = ArrayList<Double>()
        for (i in 0 until 40) {
            val t = i / 15.0
            val kind = if (i < 20) VehicleKind.TRUCK else VehicleKind.CAR
            val lead = tracker.update(listOf(vehicle(1, box, kind, t)), portrait, t)
            assertNotNull("lead lost at frame $i", lead)
            lead!!
            distances.add(lead.cameraDistanceMeters)
            if (i == 20) assertNull("history restarts at the class flip", lead.relativeSpeedKmh)
            assertEquals("frame $i", 0.0, lead.relativeSpeedKmh ?: 0.0, 1.0)
            val a = FollowingDistanceCalculator.assess(lead.distanceMeters, 40.0, lead.relativeSpeedKmh, policy,
                RoadSurfaceCondition.DRY)
            assertFalse("frame $i", a.isCollisionWarning)
        }
        // The estimate steps once (typical truck size → typical car size), it does not glide.
        assertEquals(distances[10], distances[19], 1e-6)
        assertEquals(distances[39], distances[21], 1e-6)
        assertTrue(distances[39] < distances[19])
    }

    @Test fun unknownOwnSpeedIsNotStandingStill() {
        val closing = FollowingDistanceCalculator.assess(6.0, null, -40.0, policy, RoadSurfaceCondition.DRY)
        assertFalse(closing.isStopped)
        assertEquals(DistanceStatus.DANGER, closing.status)
        assertTrue(closing.isCollisionWarning)
        assertNull(closing.fractionOfRecommended)
        assertNull(closing.recommendedTimeGapSeconds)
        val steady = FollowingDistanceCalculator.assess(6.0, null, null, policy, RoadSurfaceCondition.DRY)
        assertEquals(DistanceStatus.UNKNOWN, steady.status)
        assertFalse(steady.isStopped)
        // Really stopped: unchanged behaviour.
        val stopped = FollowingDistanceCalculator.assess(6.0, 0.0, -40.0, policy, RoadSurfaceCondition.DRY)
        assertTrue(stopped.isStopped)
        assertEquals(DistanceStatus.SAFE, stopped.status)
    }

    @Test fun muchNearerOffCentreCarBeatsFarCentredCar() {
        val scene = Scene(landscape)
        val near = vehicle(1, scene.box(0.7, 8.0, 1.8, 1.5))
        val far = vehicle(2, scene.box(0.0, 25.0, 1.8, 1.5))
        assertTrue(EgoCorridor.default.isStrictlyAhead(near.box))
        assertEquals(1, LeadVehicleTracker().update(listOf(near, far), landscape, 0.0)?.trackID)
        // Also when the far car already is the lead (cut-in): the hysteresis must not keep it.
        val tracker = LeadVehicleTracker()
        assertEquals(2, tracker.update(listOf(far), landscape, 0.0)?.trackID)
        assertEquals(1, tracker.update(listOf(near, far), landscape, 0.1)?.trackID)
        // Without the dominance rule the far centred car won (the defect).
        val selection = LeadVehicleTracker.SelectionConfig(dominanceRatio = Double.POSITIVE_INFINITY)
        assertEquals(2, LeadVehicleTracker(selection = selection).update(listOf(near, far), landscape, 0.0)?.trackID)
    }
}

// Finding 7 + own-lane light selection

class TrafficLightSelectionTest {
    @Test fun largestOnlyLooksAhead() {
        val red = lightTrack(1, TrafficLightColor.RED, x = 0.5, height = 0.06)
        val bigGreenAtTheSide = lightTrack(2, TrafficLightColor.GREEN, x = 0.9, height = 0.12)
        assertEquals(1, ObservedTrafficLight.largest(listOf(red, bigGreenAtTheSide))?.trackID)
        assertNull(ObservedTrafficLight.largest(listOf(bigGreenAtTheSide)))
    }

    @Test fun greenOnAnotherTrackNeverSaysGo() {
        val coach = TrafficLightCoach()
        fun observed(id: Int, color: TrafficLightColor, x: Double = 0.5) =
            ObservedTrafficLight(id, color, BBox(x - 0.02, 0.2, 0.04, 0.08))
        assertNull(coach.update(observed(1, TrafficLightColor.RED), 0.0, null, 0.0))
        // A pedestrian / cross-street signal (another track) is green for more than the hold time.
        for (i in 1..15) assertNull(coach.update(observed(2, TrafficLightColor.GREEN, x = 0.7), 0.0, null, i * 0.1))
        // The own light (track 1) turns green.
        assertNull(coach.update(observed(1, TrafficLightColor.GREEN), 0.0, null, 2.0))
        assertEquals(CoachMessage.GreenLightGo, coach.update(observed(1, TrafficLightColor.GREEN), 0.0, null, 3.1))
    }

    @Test fun ownLaneLightBeatsLargerSideLight() {
        val own = lightTrack(1, TrafficLightColor.RED, x = 0.52, height = 0.07)
        val kerb = lightTrack(2, TrafficLightColor.GREEN, x = 0.80, height = 0.10) // larger, but 0.30 off the centre
        assertEquals(1, TrafficLightSelection.ownLane(listOf(own, kerb))?.trackID)
        assertEquals(TrafficLightColor.RED, TrafficLightSelection.ownLane(listOf(own, kerb))?.color)
        // Corridor centre shifted toward the other light.
        assertEquals(2, TrafficLightSelection.ownLane(listOf(own, kerb), corridorCenterX = 0.75)?.trackID)
    }

    @Test fun selectionNeedsHitsKnownColourAndPosition() {
        assertNull(TrafficLightSelection.ownLane(listOf(lightTrack(1, TrafficLightColor.RED, x = 0.5, hits = 4))))
        assertNull(TrafficLightSelection.ownLane(listOf(lightTrack(1, null, x = 0.5))))
        assertNull(TrafficLightSelection.ownLane(listOf(lightTrack(1, TrafficLightColor.UNKNOWN, x = 0.5))))
        assertNull(TrafficLightSelection.ownLane(listOf(lightTrack(1, TrafficLightColor.RED, x = 0.95))))          // far to the side
        assertNull(TrafficLightSelection.ownLane(listOf(lightTrack(1, TrafficLightColor.RED, x = 0.5, y = 0.5)))) // below the horizon
        val missed = lightTrack(1, TrafficLightColor.RED, x = 0.5)
        missed.missed = 1
        assertNull(TrafficLightSelection.ownLane(listOf(missed)))
        assertEquals(TrafficLightColor.GREEN,
            TrafficLightSelection.ownLane(listOf(lightTrack(1, TrafficLightColor.GREEN, x = 0.5)))?.color)
    }

    @Test fun farIntersectionLightsAreDroppedAndRedWinsCloseCalls() {
        val near = lightTrack(1, TrafficLightColor.GREEN, x = 0.56, height = 0.10)
        val nextIntersection = lightTrack(2, TrafficLightColor.RED, x = 0.50, height = 0.04) // < 60 % of the tallest
        assertEquals(1, TrafficLightSelection.ownLane(listOf(near, nextIntersection))?.trackID)
        // Two heads of one intersection with nearly the same score and different colours → the red one.
        val green = lightTrack(3, TrafficLightColor.GREEN, x = 0.46, height = 0.08)
        val red = lightTrack(4, TrafficLightColor.RED, x = 0.55, height = 0.08)
        assertEquals(TrafficLightColor.RED, TrafficLightSelection.ownLane(listOf(green, red))?.color)
        // A clearly better green is not overruled.
        val sideRed = lightTrack(5, TrafficLightColor.RED, x = 0.72, height = 0.08)
        assertEquals(TrafficLightColor.GREEN,
            TrafficLightSelection.ownLane(listOf(lightTrack(6, TrafficLightColor.GREEN, x = 0.5, height = 0.08), sideRed))?.color)
    }

    @Test fun lowScoreLightWithoutColourIsNotDisplayed() {
        val faint = lightTrack(1, null, x = 0.5)
        faint.confidence = 0.35
        faint.peakConfidence = 0.38
        assertFalse(TrafficLightSelection.isDisplayable(faint, 0.30))
        faint.lightColor = TrafficLightColor.GREEN
        assertTrue(TrafficLightSelection.isDisplayable(faint, 0.30))
        val solid = lightTrack(2, TrafficLightColor.UNKNOWN, x = 0.5)
        solid.peakConfidence = 0.55
        assertTrue(TrafficLightSelection.isDisplayable(solid, 0.30))
        assertTrue(TrafficLightSelection.isDisplayable(vehicle(3, BBox(0.4, 0.5, 0.2, 0.2)), 0.30))
        assertEquals(0.30, DetectionThresholds.threshold(VehicleKind.TRAFFIC_LIGHT), 1e-9)
    }
}

// Finding 9 / time-window colour vote

class TrafficLightColorVoteTest {
    private fun light(color: TrafficLightColor?, confidence: Double = 0.6) =
        Detection(kind = VehicleKind.TRAFFIC_LIGHT, label = "traffic light", confidence = confidence,
            box = BBox(0.5, 0.1, 0.03, 0.08), lightColor = color)

    @Test fun colourNeedsThreeVotes() {
        val tracker = ObjectTracker()
        assertNull(tracker.update(listOf(light(TrafficLightColor.RED)), 0.0).firstOrNull()?.lightColor)
        assertNull(tracker.update(listOf(light(TrafficLightColor.RED)), 1.0 / 15).firstOrNull()?.lightColor)
        assertEquals(TrafficLightColor.RED, tracker.update(listOf(light(TrafficLightColor.RED)), 2.0 / 15).firstOrNull()?.lightColor)
    }

    @Test fun staleRedExpiresAndFreshGreenWins() {
        val tracker = ObjectTracker()
        var t = 0.0
        var tracks: List<TrackedObject> = emptyList()
        repeat(8) {
            tracks = tracker.update(listOf(light(TrafficLightColor.RED)), t)
            t += 1.0 / 15
        }
        assertEquals(TrafficLightColor.RED, tracks.firstOrNull()?.lightColor)
        // The lamp becomes unreadable (classifier answers unknown / box too small → null): the red must not survive.
        for (i in 0 until 192) {
            tracks = tracker.update(listOf(light(if (i % 2 == 0) TrafficLightColor.UNKNOWN else null)), t)
            t += 1.0 / 15
            if (i == 13) assertNull("no readable lamp for 0.9 s", tracks.firstOrNull()?.lightColor)
        }
        assertEquals(1, tracks.size)
        assertNull(tracks.firstOrNull()?.lightColor)
        repeat(3) {
            tracks = tracker.update(listOf(light(TrafficLightColor.GREEN)), t)
            t += 1.0 / 15
        }
        assertEquals(TrafficLightColor.GREEN, tracks.firstOrNull()?.lightColor)
    }

    @Test fun phaseChangeSwitchesWithinTheWindowAndNeverInventsAColour() {
        val tracker = ObjectTracker()
        var t = 0.0
        repeat(15) {
            tracker.update(listOf(light(TrafficLightColor.RED)), t)
            t += 1.0 / 15
        }
        val seen = ArrayList<TrafficLightColor?>()
        var switchedAfter: Double? = null
        val change = t
        repeat(15) {
            val color = tracker.update(listOf(light(TrafficLightColor.GREEN)), t).firstOrNull()?.lightColor
            seen.add(color)
            if (color == TrafficLightColor.GREEN && switchedAfter == null) switchedAfter = t - change
            t += 1.0 / 15
        }
        assertFalse(TrafficLightColor.YELLOW in seen)
        assertEquals(TrafficLightColor.GREEN, seen.last())
        assertTrue(switchedAfter!! <= TrafficLightColorVote.window)
    }

    @Test fun singleWrongFrameDoesNotFlipAStableColour() {
        val tracker = ObjectTracker()
        var t = 0.0
        repeat(10) {
            tracker.update(listOf(light(TrafficLightColor.RED)), t)
            t += 1.0 / 15
        }
        assertEquals(TrafficLightColor.RED, tracker.update(listOf(light(TrafficLightColor.GREEN)), t).firstOrNull()?.lightColor)
        t += 1.0 / 15
        assertEquals(TrafficLightColor.RED, tracker.update(listOf(light(TrafficLightColor.UNKNOWN)), t).firstOrNull()?.lightColor)
    }

    @Test fun voteRules() {
        val r = TrafficLightColor.RED; val g = TrafficLightColor.GREEN; val u = TrafficLightColor.UNKNOWN
        fun obs(colors: List<TrafficLightColor>, dt: Double = 0.05) =
            colors.mapIndexed { i, c -> TrafficLightColorVote.Observation(i * dt, c) }
        // Fewer than 3 known votes.
        assertNull(TrafficLightColorVote.decide(obs(listOf(r, u, r)), 0.1, r))
        // Winner below 60 % of the known votes.
        assertNull(TrafficLightColorVote.decide(obs(listOf(r, g, r, g)), 0.15, null))
        // Hysteresis: green has the votes, but the newest known observation is still red → previous kept.
        assertEquals(r, TrafficLightColorVote.decide(obs(listOf(g, g, g, g, r)), 0.2, r))
        assertEquals(g, TrafficLightColorVote.decide(obs(listOf(r, g, g, g, g)), 0.2, r))
        // Observations outside the window do not count.
        val old = obs(listOf(r, r, r, r)).toMutableList()
        assertNull(TrafficLightColorVote.decide(old, 1.2, r))
        TrafficLightColorVote.prune(old, 1.2)
        assertTrue(old.isEmpty())
    }

    @Test fun noRedLightEventAfterTheLampBecameUnreadable() {
        fun track(color: TrafficLightColor?, y: Double) =
            TrackedObject(id = 1, kind = VehicleKind.TRAFFIC_LIGHT, label = "traffic light", box = BBox(0.48, y, 0.04, 0.08),
                confidence = 0.8, hits = 5, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true, lightColor = color)
        val d = RedLightRunningDetector()
        var result: Double? = null
        var t = 0.0
        for (y in listOf(0.30, 0.28, 0.26, 0.24)) {
            result = d.update(listOf(track(TrafficLightColor.RED, y)), 40.0, t) ?: result
            t += 0.3
        }
        // The tracker's colour expired (null) for well over a second while the light climbs to the top edge.
        for (y in listOf(0.20, 0.15, 0.10, 0.06, 0.02)) {
            result = d.update(listOf(track(null, y)), 40.0, t) ?: result
            t += 0.3
        }
        result = d.update(emptyList(), 40.0, t + 0.5) ?: result
        assertNull(result)
    }
}

// Finding 8 / classifier v2 (port of the evaluated prototype)

class TrafficLightClassifierV2Test {
    /** RGB triples (0…255) → BGRA bytes. */
    private fun bgra(rgb: IntArray, width: Int, height: Int): ByteArray {
        val out = ByteArray(width * height * 4) { 255.toByte() }
        for (i in 0 until width * height) {
            out[i * 4] = rgb[i * 3 + 2].toByte()
            out[i * 4 + 1] = rgb[i * 3 + 1].toByte()
            out[i * 4 + 2] = rgb[i * 3].toByte()
        }
        return out
    }

    private fun classify(rgb: IntArray, width: Int, height: Int): TrafficLightColor =
        TrafficLightColorClassifier.classifyBGRA(bgra(rgb, width, height), width, height, width * 4, 0, 0, width, height)

    /**
     * 292 synthetic crops with the answers of the Python prototype: the Kotlin port must give the same answer on
     * every one (same fixture file as the Swift test).
     */
    @Test fun portMatchesPythonPrototypeOnSyntheticCrops() {
        val stream = javaClass.getResourceAsStream("/fixtures/traffic_light_v5_cases.json")
        assertNotNull(stream)
        val cases = JSONObject(stream!!.bufferedReader(Charsets.UTF_8).use { it.readText() }).getJSONArray("cases")
        assertEquals(292, cases.length())
        val perAnswer = HashMap<String, Int>()
        val mismatches = ArrayList<String>()
        for (index in 0 until cases.length()) {
            val c = cases.getJSONObject(index)
            val w = c.getInt("w"); val h = c.getInt("h")
            val expected = c.getString("expected")
            val bytes = Base64.getDecoder().decode(c.getString("rgb"))
            assertEquals(w * h * 3, bytes.size)
            val rgb = IntArray(bytes.size) { bytes[it].toInt() and 0xFF }
            val got = classify(rgb, w, h)
            perAnswer[expected] = (perAnswer[expected] ?: 0) + 1
            if (got.raw != expected) mismatches.add("#$index ${c.getString("name")} ${w}x$h: ${got.raw} != $expected")
            // The grid entry point gives the same answer when every pixel is a sample.
            if (min(w, h) < 2 * TrafficLightColorClassifier.samplesAlongShortSide) {
                val pixels = ArrayList<RGBPixel>(w * h)
                for (i in 0 until w * h) pixels.add(RGBPixel(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]))
                assertEquals("grid entry, case #$index", got, TrafficLightColorClassifier.classify(pixels, w, h))
            }
        }
        assertEquals(emptyList<String>(), mismatches)
        // The fixture covers every answer.
        for (answer in listOf("red", "yellow", "green", "unknown")) assertTrue(answer, (perAnswer[answer] ?: 0) > 20)
    }

    private class Rgb(val r: Int, val g: Int, val b: Int)

    /** Crop of a vertical housing (dark) on [background] with one lamp at [lampY] (fraction of the height). */
    private fun housing(
        width: Int = 24, height: Int = 60, background: Rgb, lamp: Rgb?, lampY: Double, border: Int = 2,
    ): IntArray {
        val rgb = IntArray(width * height * 3)
        val radius = width * 0.28
        for (y in 0 until height) for (x in 0 until width) {
            var p = background
            if (x >= border && x < width - border && y >= border && y < height - border) p = Rgb(25, 25, 28)
            if (lamp != null) {
                val dx = x - width / 2.0; val dy = y - height * lampY
                if (dx * dx + dy * dy <= radius * radius) p = lamp
            }
            val i = (y * width + x) * 3
            rgb[i] = p.r; rgb[i + 1] = p.g; rgb[i + 2] = p.b
        }
        return rgb
    }

    @Test fun lampColoursInAVerticalHousing() {
        val grey = Rgb(120, 120, 120)
        assertEquals(TrafficLightColor.RED, classify(housing(background = grey, lamp = Rgb(255, 40, 30), lampY = 0.2), 24, 60))
        assertEquals(TrafficLightColor.YELLOW, classify(housing(background = grey, lamp = Rgb(255, 200, 30), lampY = 0.5), 24, 60))
        assertEquals(TrafficLightColor.GREEN, classify(housing(background = grey, lamp = Rgb(40, 240, 160), lampY = 0.8), 24, 60))
        assertEquals(TrafficLightColor.UNKNOWN, classify(housing(background = grey, lamp = null, lampY = 0.5), 24, 60))
    }

    /** Sky-blue and sunlit foliage around the housing must never turn a red lamp green. */
    @Test fun skyAndFoliageBackgroundNeverReadAsGreen() {
        for (background in listOf(Rgb(135, 206, 235), Rgb(110, 200, 240), Rgb(120, 180, 60))) {
            val empty = housing(background = background, lamp = null, lampY = 0.2, border = 4)
            assertEquals(TrafficLightColor.UNKNOWN, classify(empty, 24, 60))
            val plain = housing(background = background, lamp = null, lampY = 0.2, border = 30)
            assertEquals(TrafficLightColor.UNKNOWN, classify(plain, 24, 60))
            val red = housing(background = background, lamp = Rgb(255, 30, 30), lampY = 0.2, border = 4)
            assertNotEquals(TrafficLightColor.GREEN, classify(red, 24, 60))
            assertNotEquals(TrafficLightColor.YELLOW, classify(red, 24, 60))
        }
        // With a tight box (thin sky border) the red lamp is read.
        val tight = housing(background = Rgb(135, 206, 235), lamp = Rgb(255, 30, 30), lampY = 0.2, border = 1)
        assertEquals(TrafficLightColor.RED, classify(tight, 24, 60))
    }

    /** Overexposed red core (hue 28, "amber") in the top section reads red (position prior), in the middle yellow. */
    @Test fun overexposedRedCoreUsesThePositionPrior() {
        val grey = Rgb(120, 120, 120)
        assertEquals(TrafficLightColor.RED, classify(housing(background = grey, lamp = Rgb(255, 150, 60), lampY = 0.2), 24, 60))
        assertEquals(TrafficLightColor.YELLOW, classify(housing(background = grey, lamp = Rgb(255, 150, 60), lampY = 0.5), 24, 60))
    }

    /** A dim lamp in daylight (V ≈ 0.4, below the old absolute 0.55) is still read thanks to the relative threshold. */
    @Test fun dimLampIsReadRelativeToTheCrop() {
        val dimGreen = housing(background = Rgb(70, 70, 70), lamp = Rgb(20, 105, 70), lampY = 0.8)
        assertEquals(TrafficLightColor.GREEN, classify(dimGreen, 24, 60))
    }

    @Test fun percentileMatchesNumpyDefinition() {
        val histogram = IntArray(256)
        for (level in listOf(0, 51, 102, 255)) histogram[level] += 1 // values 0, 0.2, 0.4, 1.0
        assertEquals(0.82, TrafficLightColorClassifier.percentile(histogram, 4, 0.9), 1e-9)
        assertEquals(0.15, TrafficLightColorClassifier.percentile(histogram, 4, 0.25), 1e-9)
        assertEquals(1.0, TrafficLightColorClassifier.percentile(histogram, 4, 1.0), 1e-9)
    }

    @Test fun degenerateInputs() {
        assertEquals(TrafficLightColor.UNKNOWN, TrafficLightColorClassifier.classify(emptyList()))
        assertEquals(TrafficLightColor.UNKNOWN, TrafficLightColorClassifier.classify(listOf(RGBPixel(255, 0, 0)), 2, 2))
        assertEquals(4, TrafficLightColorClassifier.samplingStep(100, 260))
        assertEquals(1, TrafficLightColorClassifier.samplingStep(5, 12))
    }
}

// Finding 10: STOP sign episode

class StopSignEpisodeTest {
    private fun sign(distance: Double): TrackedObject {
        // f ≈ 1507 px in the default portrait geometry: width = f · 0.7 / (d · 1080).
        val width = portrait.focalLengthPixels * 0.7 / (distance * 1080)
        return TrackedObject(id = 3, kind = VehicleKind.STOP_SIGN, label = "stop sign", box = BBox(0.7, 0.3, width, width),
            confidence = 0.8, hits = 5, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true)
    }

    @Test fun gentleBrakingAfterTheSignLeftTheFrameIsNotAViolation() {
        val m = StopSignComplianceMonitor()
        val violations = ArrayList<StopSignComplianceMonitor.Violation>()
        var t = 0.0
        // Approach at 15 km/h: sign at 20 m … 6.4 m, then it leaves the field of view.
        var d = 20.0
        while (d > 6.4) {
            m.update(listOf(sign(d)), portrait, 15.0, t)?.let { violations.add(it) }
            d -= 15 / 3.6 * 0.1
            t += 0.1
        }
        assertTrue(m.isArmed)
        // Smooth braking to a full stop in 4 s (the old monitor judged at +2.5 s, at ≈ 5.7 km/h → violation).
        val lost = t
        while (t < lost + 14) {
            val speed = max(0.0, 15 * (1 - (t - lost) / 4))
            m.update(emptyList(), portrait, speed, t)?.let { violations.add(it) }
            t += 0.1
        }
        assertTrue(violations.isEmpty())
        assertFalse(m.isArmed)
    }

    @Test fun drivingThroughIsStillAViolation() {
        val m = StopSignComplianceMonitor()
        val violations = ArrayList<Pair<Double, StopSignComplianceMonitor.Violation>>()
        var t = 0.0
        var d = 20.0
        while (d > 6.4) {
            m.update(listOf(sign(d)), portrait, 15.0, t)
            d -= 15 / 3.6 * 0.1
            t += 0.1
        }
        val lost = t
        while (t < lost + 12) {
            m.update(emptyList(), portrait, 15.0, t)?.let { violations.add((t - lost) to it) }
            t += 0.1
        }
        assertEquals(1, violations.size)
        assertEquals(15.0, violations.first().second.minSpeedKmh, 0.01)
        // Judged once the car is ≈ 10 m past the sign (16.4 m at 4.17 m/s ≈ 3.9 s), not at the 10 s cap.
        assertEquals(4.0, violations.first().first, 0.4)
    }

    @Test fun creepingForeverEndsAtTheCap() {
        val m = StopSignComplianceMonitor()
        m.update(listOf(sign(8.0)), portrait, 10.0, 0.0)
        var violation: StopSignComplianceMonitor.Violation? = null
        var at = 0.0
        var t = 0.1
        while (t < 15 && violation == null) {
            violation = m.update(emptyList(), portrait, 6.0, t)
            at = t
            t += 0.1
        }
        assertEquals(6.0, violation?.minSpeedKmh ?: 0.0, 0.01)
        assertEquals(10.0, at, 0.3) // 6 km/h for 10 s = 16.7 m < 8 + 10 m → the hard cap decides
    }
}

// Findings 11, 12

class DetectorHardeningTest {
    @Test fun sameVehicleAsCarAndTruckIsCountedOnce() {
        val tracker = ObjectTracker()
        val box = BBox(0.4, 0.5, 0.2, 0.2)
        var tracks: List<TrackedObject> = emptyList()
        for (i in 0 until 6) {
            val detections = CrossClassDuplicates.suppress(listOf(
                Detection(VehicleKind.CAR, "car", 0.6, box),
                Detection(VehicleKind.TRUCK, "truck", 0.45, BBox(0.405, 0.5, 0.2, 0.2)),
            ))
            tracks = tracker.update(detections, i / 15.0)
        }
        assertEquals(1, tracks.size)
        assertEquals(1, tracker.totalUniqueVehicles)
    }

    @Test fun endToEndDecoderSkipsNonFiniteRows() {
        val v = FloatArray(300 * 6)
        fun row(index: Int, vararg values: Float) { for ((k, value) in values.withIndex()) v[index * 6 + k] = value }
        row(0, 64f, 64f, 192f, 128f, 0.9f, Float.NaN)
        row(1, 64f, 64f, 192f, 128f, 0.9f, Float.POSITIVE_INFINITY)
        row(2, 64f, 64f, 192f, 128f, 0.9f, -1f)
        row(3, 64f, 64f, 192f, 128f, 0.9f, 1e30f)
        row(4, Float.NaN, 64f, 192f, 128f, 0.9f, 2f)
        row(5, 64f, 64f, Float.POSITIVE_INFINITY, 128f, 0.9f, 2f)
        row(6, 100f, 100f, 200f, 200f, 0.8f, 2f)
        val d = YOLODecoder.decode(v, listOf(1, 300, 6), 640.0, 640.0, confidenceThreshold = 0.25, iouThreshold = 0.45)
        assertEquals(1, d.size)
        assertEquals(2, d.firstOrNull()?.classIndex)
        assertEquals(0.8, d.firstOrNull()?.score ?: 0.0, 1e-6)
    }
}

// People: own-lane danger regardless of role, road-relative crossing intent, hi-vis rules

class PeopleDesignTest {
    @Test fun personInOwnLaneIsAlwaysDangerWhateverTheRole() {
        for (role in listOf(PersonRole.TRAFFIC_OFFICER, PersonRole.ROAD_WORKER, PersonRole.PEDESTRIAN)) {
            val d = PedestrianHazardDetector()
            val r = d.evaluate(listOf(person(1, BBox(0.48, 0.58, 0.04, 0.12), role = role)), 40.0, portrait, 0.0)
            assertEquals("$role", listOf(1), r.hazards.map { it.trackID })
            assertEquals("$role", PedestrianHazardLevel.DANGER, r.hazards.firstOrNull()?.level)
            assertEquals(true, r.hazards.firstOrNull()?.inOwnLane)
            // Staff keep their sighting too (banner / overlay colour).
            assertEquals("$role", if (role.isRoadStaff) listOf(1) else emptyList(), r.staff.map { it.trackID })
            assertEquals(if (role.isRoadStaff) true else null, r.staff.firstOrNull()?.inOwnLane)
        }
    }

    @Test fun staffOnTheShoulderOrInAnotherLaneIsNotAHazard() {
        val d = PedestrianHazardDetector()
        // On the roadway outside the own lane, standing: sighting only.
        val other = d.evaluate(listOf(person(1, BBox(0.70, 0.58, 0.04, 0.12), role = PersonRole.ROAD_WORKER)), 40.0, portrait, 0.0)
        assertTrue(other.hazards.isEmpty())
        assertEquals(listOf(1), other.staff.map { it.trackID })
        // On the shoulder (outside the zone, inside `staffEdgeMargin`): kept by the sidewalk filter, sighting only.
        val zone = d.effectiveRoadway
        val edge = zone.bounds(0.7)!!.second; val half = zone.halfWidth(0.7)
        val shoulder = person(2, BBox(edge + 0.5 * half - 0.02, 0.58, 0.04, 0.12), role = PersonRole.TRAFFIC_OFFICER)
        val r = d.evaluate(listOf(shoulder), 40.0, portrait, 0.0)
        assertEquals(setOf(2), r.relevantIDs)
        assertTrue(r.filteredIDs.isEmpty())
        assertTrue(r.hazards.isEmpty())
        assertEquals(false, r.staff.firstOrNull()?.onRoadway)
        // The same spot without a staff role is the sidewalk.
        val plain = shoulder.copy(personRole = null)
        assertEquals(setOf(2), PedestrianHazardDetector().evaluate(listOf(plain), 40.0, portrait, 0.0).filteredIDs)
    }

    @Test fun workerWalkingIntoTheLaneIsDanger() {
        val d = PedestrianHazardDetector()
        var r = PersonSceneResult()
        for (i in 0 until 8) {
            val t = i * 0.1
            // On the roadway (zone), outside the corridor, walking toward the centre.
            r = d.evaluate(listOf(person(1, BBox(0.72 - 0.012 * i, 0.58, 0.04, 0.12), t, PersonRole.ROAD_WORKER)), 40.0, portrait, t)
        }
        assertEquals(PedestrianHazardLevel.DANGER, r.hazards.firstOrNull()?.level)
        assertEquals(true, r.hazards.firstOrNull()?.approaching)
        assertEquals(1, r.staff.size)
    }

    /**
     * Car driving forward at 8 m/s; frames at 15 fps; landscape camera. A pedestrian STANDING 6 m to the side drifts
     * outward in the image and must not count as approaching; one WALKING toward the road at 1.4 m/s hardly moves in
     * image x (perspective expansion cancels the walking) and must count.
     */
    @Test fun crossingIntentIsRoadRelative() {
        val scene = Scene(landscape)
        fun run(walkSpeed: Double): Pair<PersonSceneResult, Double> {
            val d = PedestrianHazardDetector()
            var r = PersonSceneResult()
            var firstX = 0.0; var lastX = 0.0
            for (i in 0..15) {
                val t = i / 15.0
                val box = scene.box(6.0 - walkSpeed * t, 25 - 8 * t, 0.5, 1.7)
                if (i == 0) firstX = box.midX
                lastX = box.midX
                r = d.evaluate(listOf(person(1, box, t)), 29.0, landscape, t)
            }
            return r to (lastX - firstX)
        }
        val standing = run(0.0)
        assertTrue(standing.second > 0.04) // drifts outward (away from the centre) in the image
        assertTrue(standing.first.hazards.isEmpty())
        assertEquals(setOf(1), standing.first.filteredIDs) // sidewalk: not shown at all

        val walking = run(1.4)
        assertTrue(walking.second > 0) // image x still moves OUTWARD: the old test missed it
        assertEquals(setOf(1), walking.first.relevantIDs)
        assertEquals(true, walking.first.hazards.firstOrNull()?.approaching)
        assertEquals(PedestrianHazardLevel.CAUTION, walking.first.hazards.firstOrNull()?.level)
    }

    /** Driving straight past a person standing on the sidewalk never makes them "approaching", whatever the depth. */
    @Test fun standingPersonIsConstantInRoadRelativeCoordinates() {
        val scene = Scene(landscape)
        val d = PedestrianHazardDetector()
        for (i in 0..40) {
            val t = i / 15.0
            val box = scene.box(-8.0, 40 - 10 * t, 0.5, 1.7)
            val r = d.evaluate(listOf(person(1, box, t)), 36.0, landscape, t)
            assertTrue("frame $i", r.hazards.isEmpty())
        }
    }

    @Test fun perspectiveHalfWidth() {
        val zone = RoadwayZone.fromCorridor(EgoCorridor(), 2.2)
        assertEquals(2.2 * 0.2, PedestrianHazardDetector.perspectiveHalfWidth(zone, 1.0), 1e-4)
        assertEquals(2.2 * 0.1, PedestrianHazardDetector.perspectiveHalfWidth(zone, 0.71), 1e-4)
        assertEquals(0.0, PedestrianHazardDetector.perspectiveHalfWidth(zone, 0.3), 0.0)
    }

    // Hi-vis colour gates and vote

    @Test fun relaxedVestGates() {
        val pc = PersonRoleClassifier
        // Lime vest in shade (S 0.4, V 0.5): missed by the old gates (S ≥ 0.5, V ≥ 0.6).
        assertEquals(PersonRoleClassifier.PixelClass.LIME, pc.pixelClass(RGBPixel(102, 128, 77)))
        assertEquals(PersonRoleClassifier.PixelClass.LIME, pc.pixelClass(RGBPixel(200, 255, 0)))
        // Saturated orange vest.
        assertEquals(PersonRoleClassifier.PixelClass.ORANGE, pc.pixelClass(RGBPixel(255, 100, 10)))
        // Skin tone (hue ≈ 25°, S ≈ 0.45) is not a vest any more (orange needs S ≥ 0.70).
        assertEquals(PersonRoleClassifier.PixelClass.OTHER, pc.pixelClass(RGBPixel(220, 170, 120)))
        // Navy uniform cloth vs ordinary blue.
        assertEquals(PersonRoleClassifier.PixelClass.NAVY, pc.pixelClass(RGBPixel(30, 40, 100)))
        assertEquals(PersonRoleClassifier.PixelClass.OTHER, pc.pixelClass(RGBPixel(60, 90, 220)))
        assertEquals(PersonRoleClassifier.PixelClass.DARK, pc.pixelClass(RGBPixel(20, 20, 30)))
        assertEquals(0.15, PersonRoleClassifier.minVestShare, 0.0)
    }

    @Test fun officerNeedsDarkLowerBodyAndNoOrange() {
        fun sample(lime: Double, orange: Double, lower: Double?) =
            PersonRoleSample(limeShare = lime, orangeShare = orange, darkShare = 0.3, torsoPixels = 100, lowerDarkShare = lower)
        assertEquals(PersonRole.TRAFFIC_OFFICER, PersonRoleClassifier.classify(sample(0.3, 0.0, 0.85)))
        assertEquals(PersonRole.ROAD_WORKER, PersonRoleClassifier.classify(sample(0.3, 0.0, 0.2)))      // jeans / light trousers
        assertEquals(PersonRole.ROAD_WORKER, PersonRoleClassifier.classify(sample(0.3, 0.1, 0.85)))     // lime + orange
        assertEquals(PersonRole.ROAD_WORKER, PersonRoleClassifier.classify(sample(0.05, 0.3, 0.85)))
        assertEquals(PersonRole.PEDESTRIAN, PersonRoleClassifier.classify(sample(0.14, 0.1, 0.85)))     // below 0.15
        // Without the lower-body measurement the whole-box dark share decides, as before.
        assertEquals(PersonRole.TRAFFIC_OFFICER, PersonRoleClassifier.classify(sample(0.3, 0.0, null)))
    }

    @Test fun bgraSampleMeasuresTheLowerBody() {
        // 60 × 120 person: lime torso band, navy legs.
        val w = 60; val h = 120
        val bytes = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            val fy = y.toDouble() / h
            val lime = fy >= 0.22 && fy < 0.62
            val r = if (lime) 200 else 30; val g = if (lime) 255 else 40; val b = if (lime) 0 else 100
            val i = (y * w + x) * 4
            bytes[i] = b.toByte(); bytes[i + 1] = g.toByte(); bytes[i + 2] = r.toByte(); bytes[i + 3] = 255.toByte()
        }
        val sample = PersonRoleClassifier.sampleBGRA(bytes, w, h, w * 4, 0, 0, w, h, step = 2)
        assertTrue((sample?.lowerDarkShare ?: 0.0) > 0.9)
        assertTrue((sample?.limeShare ?: 0.0) > 0.9)
        assertEquals(PersonRole.TRAFFIC_OFFICER, sample?.let { PersonRoleClassifier.classify(it) })
    }

    @Test fun roleVoteHysteresis() {
        val p = PersonRole.PEDESTRIAN; val o = PersonRole.TRAFFIC_OFFICER; val w = PersonRole.ROAD_WORKER
        assertEquals(15, PersonRoleClassifier.voteWindow)
        // Fewer than 5 observations: nothing yet.
        assertNull(PersonRoleClassifier.majority(listOf(o, o, o, o)))
        // Enter at 60 % staff (officer + worker pooled), the more frequent names the role.
        assertEquals(o, PersonRoleClassifier.majority(listOf(o, o, w, p, p, o, o, w, p, p)))  // 6 of 10
        assertEquals(p, PersonRoleClassifier.majority(listOf(o, o, w, p, p, p, o, w, p, p)))  // 5 of 10
        // A pedestrian in a yellow jacket with a few false frames never becomes staff.
        assertEquals(p, PersonRoleClassifier.majority(listOf(p, p, w, p, p, p, p, p, o, p, p, p, p, p, p)))
        // Keep down to 30 %, drop below.
        assertEquals(w, PersonRoleClassifier.majority(listOf(w, p, p, w, p, p, w, p, p, p), previous = w))
        assertEquals(p, PersonRoleClassifier.majority(listOf(w, p, p, p, p, p, w, p, p, p), previous = w))
        // A tie keeps the previous staff role.
        assertEquals(w, PersonRoleClassifier.majority(listOf(o, w, o, w, p), previous = w))
    }
}
