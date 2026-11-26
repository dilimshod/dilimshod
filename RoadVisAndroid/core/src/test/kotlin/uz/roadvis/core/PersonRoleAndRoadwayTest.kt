package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonRoleAndRoadwayTest {
    private val g = CameraGeometry.defaultPortrait

    /** BGRA image of w×h filled with background, with a person box: head/legs in [legs], torso band in [vest]. */
    private fun personImage(w: Int = 60, h: Int = 120, background: RGBPixel, vest: RGBPixel, legs: RGBPixel): ByteArray {
        val bytes = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            val fy = y.toDouble() / h; val fx = x.toDouble() / w
            var p = background
            if (fx >= 0.2 && fx < 0.8) p = if (fy >= 0.22 && fy < 0.62) vest else legs
            val i = (y * w + x) * 4
            bytes[i] = p.b.toByte(); bytes[i + 1] = p.g.toByte(); bytes[i + 2] = p.r.toByte(); bytes[i + 3] = 255.toByte()
        }
        return bytes
    }

    private fun classify(bytes: ByteArray, w: Int = 60, h: Int = 120): PersonRole? =
        PersonRoleClassifier.classifyBGRA(bytes, w, h, w * 4, 0, 0, w, h, step = 1)

    private val gray = RGBPixel(128, 128, 128)
    private val lime = RGBPixel(200, 245, 30)
    private val orange = RGBPixel(255, 110, 20)
    private val darkNavy = RGBPixel(20, 25, 45)
    private val jeans = RGBPixel(70, 90, 140)

    @Test fun officerVestOverDarkUniform() {
        assertEquals(PersonRole.TRAFFIC_OFFICER, classify(personImage(background = gray, vest = lime, legs = darkNavy)))
    }

    @Test fun roadWorkerOrangeVest() {
        assertEquals(PersonRole.ROAD_WORKER, classify(personImage(background = gray, vest = orange, legs = jeans)))
        assertEquals(PersonRole.ROAD_WORKER, classify(personImage(background = gray, vest = orange, legs = darkNavy)))
    }

    @Test fun limeVestWithoutDarkClothesIsWorker() {
        assertEquals(PersonRole.ROAD_WORKER, classify(personImage(background = gray, vest = lime, legs = jeans)))
    }

    @Test fun ordinaryClothesArePedestrian() {
        assertEquals(PersonRole.PEDESTRIAN, classify(personImage(background = gray, vest = RGBPixel(180, 40, 40), legs = darkNavy)))
        assertEquals(PersonRole.PEDESTRIAN, classify(personImage(background = gray, vest = RGBPixel(230, 230, 170), legs = jeans)))
    }

    @Test fun smallBoxNotClassified() {
        val bytes = personImage(w = 20, h = 30, background = gray, vest = lime, legs = darkNavy)
        assertNull(classify(bytes, 20, 30))
    }

    @Test fun minimumVestShare() {
        var torso = List(90) { gray } + List(10) { lime }
        val box = torso + List(50) { darkNavy }
        assertEquals(PersonRole.PEDESTRIAN, PersonRoleClassifier.classify(torso, box))
        torso = List(80) { gray } + List(20) { lime }
        assertEquals(PersonRole.TRAFFIC_OFFICER, PersonRoleClassifier.classify(torso, torso + List(50) { darkNavy }))
    }

    @Test fun majorityVote() {
        val o = PersonRole.TRAFFIC_OFFICER; val p = PersonRole.PEDESTRIAN; val w = PersonRole.ROAD_WORKER
        assertNull(PersonRoleClassifier.majority(listOf(o, o, o, o)))
        assertEquals(o, PersonRoleClassifier.majority(listOf(o, o, p, o, o)))
        assertEquals(p, PersonRoleClassifier.majority(listOf(o, p, o, p, w, p)))
        assertEquals(o, PersonRoleClassifier.majority(listOf(o, o, p, p, w, w), previous = o))
    }

    @Test fun trackerVotesPersonRole() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 1))
        val box = BBox(0.4, 0.4, 0.05, 0.15)
        var tracks: List<TrackedObject> = emptyList()
        val roles = listOf(PersonRole.TRAFFIC_OFFICER, PersonRole.PEDESTRIAN, PersonRole.TRAFFIC_OFFICER,
            PersonRole.TRAFFIC_OFFICER, PersonRole.TRAFFIC_OFFICER, PersonRole.PEDESTRIAN)
        for ((i, role) in roles.withIndex()) {
            tracks = tracker.update(listOf(Detection(VehicleKind.PERSON, "person", 0.8, box, personRole = role)), i * 0.07)
            if (i < 4) assertNull("frame $i", tracks.firstOrNull()?.personRole)
        }
        assertEquals(PersonRole.TRAFFIC_OFFICER, tracks.firstOrNull()?.personRole)
    }

    @Test fun deferredCounting() {
        val tracker = ObjectTracker(ObjectTracker.Config(minHits = 1, deferredCountKinds = setOf(VehicleKind.PERSON)))
        val tracks = tracker.update(listOf(Detection(VehicleKind.PERSON, "person", 0.8, BBox(0.4, 0.4, 0.05, 0.15))), 0.0)
        assertEquals(0, tracker.uniqueCounts[VehicleKind.PERSON] ?: 0)
        tracker.markRelevant(tracks.map { it.id })
        tracker.markRelevant(tracks.map { it.id })
        assertEquals(1, tracker.uniqueCounts[VehicleKind.PERSON])
    }

    private fun person(id: Int, x: Double, bottom: Double, h: Double = 0.12, t: Double, role: PersonRole? = null) =
        TrackedObject(id = id, kind = VehicleKind.PERSON, label = "person", box = BBox(x - 0.02, bottom - h, 0.04, h),
            confidence = 0.8, hits = 6, firstSeen = 0.0, lastSeen = t, isConfirmed = true, personRole = role)

    @Test fun zoneFromLanesExtendsOutward() {
        val estimate = LaneEstimate(LaneLine(0.1, 1.0, 0.48, 0.44), LaneLine(0.9, 1.0, 0.52, 0.44),
            0.8, 0.8, 0.5, 0.0, 0.8, 0.96, 0.0)
        val zone = RoadwayZone.fromLanes(estimate, 0.42, 1.0, 1.0, 0.45)
        assertEquals(RoadwayZone.Source.LANES, zone?.source)
        assertEquals(-0.7, zone?.left?.bottomX ?: 0.0, 1e-6)
        assertEquals(1.7, zone?.right?.bottomX ?: 0.0, 1e-6)
        var one = estimate.copy(rightConfidence = 0.1)
        val mirrored = RoadwayZone.fromLanes(one, 0.42, 0.0, 0.0, 0.45)
        assertNotNull(mirrored)
        assertTrue((mirrored?.right?.bottomX ?: 0.0) > 0.8)
        one = one.copy(leftConfidence = 0.1)
        assertEquals(RoadwayZone.Source.CORRIDOR, RoadwayZoneEstimator().update(one, EgoCorridor.default).source)
    }

    @Test fun zoneOutsideDistance() {
        val zone = RoadwayZone(0.0, 0.45, 1.0, 0.55, 0.4, RoadwayZone.Source.CORRIDOR)
        assertEquals(0.0, zone.outsideDistance(0.5, 0.8), 0.0)
        assertTrue(zone.outsideDistance(0.05, 0.6) > 0.5)
        assertTrue(zone.outsideDistance(0.5, 0.3).isInfinite())
        assertEquals(4, zone.polygon().size)
    }

    @Test fun sidewalkPedestrianFilteredOut() {
        val d = PedestrianHazardDetector()
        d.roadway = RoadwayZone(0.1, 0.47, 0.9, 0.53, 0.42, RoadwayZone.Source.LANES)
        var r = PersonSceneResult()
        for (i in 0 until 6) {
            val t = i * 0.1
            r = d.evaluate(listOf(person(1, 0.08, 0.65, t = t)), 40.0, g, t)
        }
        assertEquals(setOf(1), r.filteredIDs)
        assertTrue(r.relevantIDs.isEmpty())
        assertTrue(r.hazards.isEmpty())
        for (i in 0 until 6) {
            val t = 1 + i * 0.1
            r = d.evaluate(listOf(person(2, 0.08 - 0.005 * i, 0.65, t = t)), 40.0, g, t)
        }
        assertEquals(setOf(2), r.filteredIDs)
    }

    @Test fun crossingPedestrianKept() {
        val d = PedestrianHazardDetector()
        d.roadway = RoadwayZone(0.1, 0.47, 0.9, 0.53, 0.42, RoadwayZone.Source.LANES)
        var r = PersonSceneResult()
        for (i in 0 until 8) {
            val t = i * 0.1
            r = d.evaluate(listOf(person(1, 0.18 + 0.01 * i, 0.65, t = t)), 40.0, g, t)
        }
        assertEquals(setOf(1), r.relevantIDs)
        assertEquals(1, r.hazards.firstOrNull()?.trackID)
        assertEquals(true, r.hazards.firstOrNull()?.approaching)
    }

    @Test fun officerOnRoadIsStaffNotHazard() {
        val d = PedestrianHazardDetector()
        val r = d.evaluate(listOf(person(1, 0.5, 0.7, t = 0.0, role = PersonRole.TRAFFIC_OFFICER),
            person(2, 0.02, 0.62, t = 0.0, role = PersonRole.ROAD_WORKER)), 40.0, g, 0.0)
        assertTrue(r.hazards.isEmpty())
        assertEquals(listOf(1), r.staff.map { it.trackID })
        assertEquals(PersonRole.TRAFFIC_OFFICER, r.staff.firstOrNull()?.role)
        assertEquals(setOf(2), r.filteredIDs)
    }

    @Test fun coachAnnouncesOfficerOncePerCooldown() {
        val engine = DriverCoachEngine()
        val officer = RoadStaffSighting(7, PersonRole.TRAFFIC_OFFICER, BBox(0.5, 0.5, 0.04, 0.12), 30.0, onRoadway = true, inOwnLane = false)
        engine.updateRoadStaff(listOf(officer), 0.0)
        assertEquals(CoachMessage.TrafficOfficerAhead(7), engine.next(0.0))
        engine.updateRoadStaff(listOf(officer), 10.0)
        assertNull(engine.next(10.0))
        engine.updateRoadStaff(listOf(officer), 21.0)
        assertEquals(CoachMessage.TrafficOfficerAhead(7), engine.next(21.0))
        val far = officer.copy(trackID = 8, distanceMeters = 90.0)
        engine.reset()
        engine.updateRoadStaff(listOf(far), 100.0)
        assertNull(engine.next(100.0))
        val worker = RoadStaffSighting(9, PersonRole.ROAD_WORKER, officer.box, 40.0, onRoadway = false, inOwnLane = false)
        engine.updateRoadStaff(listOf(worker), 101.0)
        assertEquals(CoachMessage.RoadWorkersAhead(9), engine.next(101.0))
        assertEquals(listOf("road_workers_ahead"), VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.RoadWorkersAhead(9)), RVLang.UZ))
        assertEquals("Diqqat, oldinda YHXX xodimi",
            VoiceComposer.composedText(VoicePhrase.coach(CoachMessage.TrafficOfficerAhead(1)), RVLang.UZ))
    }

    @Test fun staffEventsAreInfoAndNotScored() {
        val monitor = CameraDrivingEventMonitor()
        val officer = RoadStaffSighting(3, PersonRole.TRAFFIC_OFFICER, BBox(0.5, 0.5, 0.04, 0.12), 25.0, onRoadway = true, inOwnLane = false)
        val events = monitor.update(CameraEventInput(timestamp = 0.0, speedKmh = 40.0, roadStaff = listOf(officer)))
        assertEquals(listOf(DrivingEventKind.TRAFFIC_OFFICER_SEEN), events.map { it.kind })
        assertEquals(DrivingEventSeverity.INFO, events.firstOrNull()?.severity)
        assertTrue(monitor.update(CameraEventInput(timestamp = 0.1, speedKmh = 40.0, roadStaff = listOf(officer))).isEmpty())
        assertEquals(100, TripScoring.score(events, 1000.0).score)
        assertEquals(DrivingEventSeverity.INFO, DrivingEventKind.ROAD_WORKERS_SEEN.defaultSeverity)
    }
}
