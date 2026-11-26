package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.max
import kotlin.math.min

// Port of DriverAssistTests.swift (lane detector, lane departure, signs, coach, camera driving events).

/** Swift `UInt8(clamping:)`. */
private fun clamp8(v: Int): Int = v.coerceIn(0, 255)

/** LCG used by the Swift tests (wrapping UInt64 arithmetic). */
private class Lcg(var state: Long) {
    fun next(): Long {
        state = state * 6364136223846793005L + 1442695040888963407L
        return state ushr 33
    }
}

private object SyntheticRoad {
    const val width = 160
    const val height = 284
    const val horizon = 0.42

    fun image(
        leftBottom: Double?, rightBottom: Double?, vanishingX: Double = 80.0, road: Int = 95,
        marking: Int = 225, dashed: Boolean = true, noise: Int = 6, seed: Long = 1,
    ): LaneImage {
        val img = LaneImage(width, height, road)
        val rng = Lcg(seed)
        fun rand(): Int = (rng.next() % (2 * noise + 1).toLong()).toInt() - noise
        val hy = (height * horizon).toInt()
        for (y in 0 until height) for (x in 0 until width) {
            val base = if (y < hy) 200 else road
            img[x, y] = clamp8(base + (if (noise > 0) rand() else 0))
        }
        val yb = (height - 1).toDouble()
        val yh = height * horizon
        for ((index, bottom) in listOf(leftBottom, rightBottom).withIndex()) {
            if (bottom == null) continue
            for (y in (hy + 1) until height) {
                val t = (y - yh) / (yb - yh)
                if (dashed && index == 1 && ((t * 12).toInt() % 2 == 1)) continue
                val x = vanishingX + (bottom - vanishingX) * t
                val halfWidth = max(0.6, 2.8 * t)
                val x0 = (x - halfWidth).rounded().toInt(); val x1 = (x + halfWidth).rounded().toInt()
                if (!(x0 <= width - 1 && x1 >= 0)) continue
                for (xx in max(0, x0)..min(width - 1, x1)) img[xx, y] = marking
            }
        }
        return img
    }
}

class LaneDetectorTest {
    @Test fun detectsBothLinesCentred() {
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (i in 0 until 6) estimate = detector.process(SyntheticRoad.image(10.0, 150.0, seed = (i + 1).toLong()), i * 0.2)
        val left = estimate.left!!
        val right = estimate.right!!
        val t = (0.96 * 284 - 0.42 * 284) / (283 - 0.42 * 284)
        assertEquals((80 + (10 - 80) * t) / 160, left.x(estimate.referenceY), 0.03)
        assertEquals((80 + (150 - 80) * t) / 160, right.x(estimate.referenceY), 0.03)
        assertTrue(estimate.leftConfidence > 0.5)
        assertTrue(estimate.rightConfidence > 0.3)
        assertEquals(0.0, estimate.egoOffset ?: 99.0, 0.1)
        assertEquals(0.5, estimate.laneCenterX ?: 0.0, 0.03)
        assertTrue(left.topY < 0.5)
    }

    @Test fun offsetTowardLeftLine() {
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (i in 0 until 6) estimate = detector.process(SyntheticRoad.image(55.0, 215.0, seed = (i + 7).toLong()), i * 0.2)
        assertNotNull(estimate.left)
        val offset = estimate.egoOffset!!
        assertTrue(offset < -0.6)
        assertTrue(offset > -1.0)
    }

    @Test fun noMarkingsGivesNoLines() {
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (i in 0 until 5) estimate = detector.process(SyntheticRoad.image(null, null, noise = 10, seed = (i + 3).toLong()), i * 0.2)
        assertNull(estimate.left)
        assertNull(estimate.right)
        assertNull(estimate.egoOffset)
        assertEquals(0.0, estimate.confidence, 0.0)
    }

    @Test fun horizontalStripeIsRejected() {
        val img = SyntheticRoad.image(null, null, noise = 0)
        for (y in 220 until 226) for (x in 0 until 160) img[x, y] = 230
        val fits = LaneDetector.detectLines(img, LaneDetector.Config())
        assertNull(fits.first)
        assertNull(fits.second)
    }

    @Test fun singleLineUsesLaneWidth() {
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (i in 0 until 5) estimate = detector.process(SyntheticRoad.image(10.0, null, seed = (i + 11).toLong()), i * 0.2)
        assertNotNull(estimate.left)
        assertNull(estimate.right)
        assertNotNull(estimate.egoOffset)
        assertTrue(estimate.confidence < estimate.leftConfidence)
    }

    @Test fun confidenceDecaysWhenMarkingsDisappear() {
        val detector = LaneDetector()
        for (i in 0 until 5) detector.process(SyntheticRoad.image(10.0, 150.0, seed = (i + 1).toLong()), i * 0.2)
        val before = detector.process(SyntheticRoad.image(10.0, 150.0), 1.2).leftConfidence
        var after = 1.0
        for (i in 0 until 4) after = detector.process(SyntheticRoad.image(null, null, seed = (i + 50).toLong()), 1.4 + i * 0.2).leftConfidence
        assertTrue(after < before * 0.5)
    }

    @Test fun yellowMarkingFromBGRA() {
        val w = 640; val h = 1136; val bpr = w * 4
        val buffer = ByteArray(bpr * h)
        val hy = h * 0.42
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * bpr + x * 4
                val v = if (y < hy) 190 else 100
                buffer[i] = v.toByte(); buffer[i + 1] = v.toByte(); buffer[i + 2] = v.toByte(); buffer[i + 3] = 255.toByte()
            }
            if (y <= hy) continue
            val t = (y - hy) / ((h - 1) - hy)
            for ((bottom, yellow) in listOf(40.0 to true, 600.0 to false)) {
                val x = 320 + (bottom - 320) * t
                val half = max(2.0, 11 * t)
                for (xx in (x - half).toInt()..(x + half).toInt()) {
                    if (xx < 0 || xx >= w) continue
                    val i = y * bpr + xx * 4
                    if (yellow) { buffer[i] = 30; buffer[i + 1] = 190.toByte(); buffer[i + 2] = 220.toByte() }
                    else { buffer[i] = 235.toByte(); buffer[i + 1] = 235.toByte(); buffer[i + 2] = 235.toByte() }
                }
            }
        }
        val image = LaneImage.fromBGRA(buffer, w, h, bpr, targetWidth = 160, roiTop = 0.4)
        assertEquals(160, image.width)
        assertEquals(284, image.height)
        assertTrue(LaneImage.markingValue(220, 190, 30) > 200)
        assertTrue(LaneImage.markingValue(100, 100, 100) < 110)
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (i in 0 until 4) estimate = detector.process(image, i * 0.2)
        assertNotNull("yellow line should be detected", estimate.left)
        assertNotNull(estimate.right)
        assertEquals(0.0, estimate.egoOffset ?: 99.0, 0.15)
    }

    @Test fun syntheticRoadWithTwoWhiteLinesYieldsConfidentLines() {
        val w = 720; val h = 1280; val bpr = w * 4
        val buffer = ByteArray(bpr * h) { 255.toByte() }
        val rng = Lcg(7)
        val hy = h * 0.42
        for (y in 0 until h) {
            for (x in 0 until w) {
                val noise = (rng.next() % 17).toInt() - 8
                val base = if (y < hy) 185 else 92
                val v = clamp8(base + noise).toByte()
                val i = y * bpr + x * 4
                buffer[i] = v; buffer[i + 1] = v; buffer[i + 2] = v
            }
            if (y <= hy) continue
            val t = (y - hy) / ((h - 1) - hy)
            for (bottom in listOf(0.1 * w, 0.9 * w)) {
                val x = 0.5 * w + (bottom - 0.5 * w) * t
                val half = max(1.5, 10 * t)
                for (xx in (x - half).toInt()..(x + half).toInt()) {
                    if (xx < 0 || xx >= w) continue
                    val i = y * bpr + xx * 4
                    buffer[i] = 232.toByte(); buffer[i + 1] = 232.toByte(); buffer[i + 2] = 232.toByte()
                }
            }
        }
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (frame in 0 until 8) {
            val image = LaneImage.fromBGRA(buffer, w, h, bpr, targetWidth = 160, roiTop = 0.40)
            estimate = detector.process(image, frame * 0.2)
        }
        val left = estimate.left!!
        val right = estimate.right!!
        assertTrue(estimate.leftConfidence >= 0.5)
        assertTrue(estimate.rightConfidence >= 0.5)
        assertTrue(estimate.confidence >= 0.5)
        assertTrue(left.x(0.96) < 0.3)
        assertTrue(right.x(0.96) > 0.7)
        assertEquals(0.5, estimate.laneCenterX ?: 0.0, 0.04)
    }

    @Test fun landscapeYellowSolidAndWhiteDashedLines() {
        val w = 1920; val h = 1080; val bpr = w * 4
        val buffer = ByteArray(bpr * h) { 255.toByte() }
        val rng = Lcg(3)
        val hy = h * 0.42
        for (y in 0 until h) {
            for (x in 0 until w) {
                val noise = (rng.next() % 21).toInt() - 10
                val base = if (y < hy) 200 else 118
                val v = clamp8(base + noise).toByte()
                val i = y * bpr + x * 4
                buffer[i] = v; buffer[i + 1] = v; buffer[i + 2] = v
            }
            if (y <= hy) continue
            val t = (y - hy) / ((h - 1) - hy)
            for ((bottom, yellow, dashed) in listOf(Triple(0.16, true, false), Triple(0.84, false, true), Triple(1.6, false, false))) {
                if (dashed && (t * 14).toInt() % 2 == 1) continue
                val x = 0.5 * w + (bottom - 0.5) * w * t
                val half = max(1.0, 6 * t)
                for (xx in (x - half).toInt()..(x + half).toInt()) {
                    if (xx < 0 || xx >= w) continue
                    val i = y * bpr + xx * 4
                    if (yellow) { buffer[i] = 60; buffer[i + 1] = 175.toByte(); buffer[i + 2] = 210.toByte() }
                    else { buffer[i] = 225.toByte(); buffer[i + 1] = 225.toByte(); buffer[i + 2] = 225.toByte() }
                }
            }
        }
        val detector = LaneDetector()
        var estimate = LaneEstimate.empty()
        for (frame in 0 until 8) {
            val image = LaneImage.fromBGRA(buffer, w, h, bpr, targetWidth = 160, roiTop = 0.40)
            estimate = detector.process(image, frame * 0.2)
        }
        val left = estimate.left
        val right = estimate.right
        assertNotNull("yellow solid line", left)
        assertNotNull("white dashed line", right)
        assertTrue(estimate.leftConfidence >= 0.5)
        assertTrue(estimate.rightConfidence >= 0.3)
        assertTrue(left!!.x(0.96) < 0.35)
        assertTrue(right!!.x(0.96) > 0.65)
    }
}

class LaneDepartureTest {
    private fun estimate(offset: Double, t: Double, confidence: Double = 0.8): LaneEstimate {
        val line = LaneLine(0.1, 0.96, 0.45, 0.44)
        return LaneEstimate(line, line, confidence, confidence, 0.5, offset, confidence, 0.96, t)
    }

    @Test fun departureAfterHoldAtSpeed() {
        val d = LaneDepartureDetector()
        val fired = mutableListOf<LaneSide>()
        for (i in 0..10) {
            val t = i * 0.1
            d.update(estimate(-0.75, t), 60.0, t)?.let { fired.add(it) }
        }
        assertEquals(listOf(LaneSide.LEFT), fired)
        assertEquals(LaneSide.LEFT, d.activeSide)
    }

    @Test fun noDepartureBelowMinSpeedOrShortDrift() {
        val d = LaneDepartureDetector()
        for (i in 0..10) {
            val t = i * 0.1
            assertNull(d.update(estimate(0.8, t), 30.0, t))
        }
        val d2 = LaneDepartureDetector()
        assertNull(d2.update(estimate(0.8, 0.0), 60.0, 0.0))
        assertNull(d2.update(estimate(0.8, 0.2), 60.0, 0.2))
        assertNull(d2.update(estimate(0.1, 0.3), 60.0, 0.3))
        assertNull(d2.update(estimate(0.8, 0.5), 60.0, 0.5))
    }

    @Test fun lowConfidenceLineIgnored() {
        val d = LaneDepartureDetector()
        for (i in 0..10) {
            val t = i * 0.1
            assertNull(d.update(estimate(-0.8, t, 0.2), 70.0, t))
        }
    }

    @Test fun cooldownAndRearm() {
        val d = LaneDepartureDetector()
        var count = 0
        var t = 0.0
        fun drive(offset: Double, seconds: Double) {
            val end = t + seconds
            while (t < end) {
                if (d.update(estimate(offset, t), 60.0, t) != null) count += 1
                t += 0.1
            }
        }
        drive(0.8, 1.0)
        drive(0.8, 2.0)
        drive(0.0, 1.0)
        drive(0.8, 0.6)
        assertEquals(1, count)
        drive(0.0, 2.0)
        drive(0.8, 1.0)
        assertEquals(2, count)
    }
}

class SignAnnouncerTest {
    @Test fun featureThresholdsAndDedupe() {
        val a = SignAnnouncer()
        val crossing = FeatureAhead("node/1", RouteFeatureKind.PEDESTRIAN_CROSSING, 150.0)
        assertNull(a.update(listOf(crossing), 40.0, 0.0))
        var near = crossing.copy(distanceAhead = 95.0)
        assertEquals(RoadSignEvent.Feature(RouteFeatureKind.PEDESTRIAN_CROSSING, 95.0, "node/1"), a.update(listOf(near), 40.0, 1.0))
        near = near.copy(distanceAhead = 60.0)
        assertNull("announced once per id", a.update(listOf(near), 40.0, 2.0))
        val cam = FeatureAhead("node/2", RouteFeatureKind.SPEED_CAMERA, 380.0)
        assertEquals(RoadSignEvent.Feature(RouteFeatureKind.SPEED_CAMERA, 380.0, "node/2"), a.update(listOf(cam), 90.0, 3.0))
        assertNull(a.update(listOf(FeatureAhead("node/3", RouteFeatureKind.FUEL, 50.0)), 40.0, 4.0))
        assertNull(a.update(listOf(FeatureAhead("node/4", RouteFeatureKind.SCHOOL, 5.0)), 40.0, 5.0))
    }

    @Test fun featureAheadFromRouteFeatures() {
        val f = RouteFeature(id = "node/9", kind = RouteFeatureKind.STOP_SIGN, coordinate = GeoPoint(41.0, 69.0),
            distanceAlongRoute = 1200.0, offsetFromRoute = 3.0)
        assertEquals(listOf(FeatureAhead("node/9", RouteFeatureKind.STOP_SIGN, 100.0)), FeatureAhead.from(listOf(f), 1100.0))
        assertTrue(FeatureAhead.from(listOf(f), 100.0).isEmpty())
    }

    @Test fun speedLimitNeedsStableValue() {
        val a = SignAnnouncer()
        assertNull(a.update(60, 0.0))
        assertNull(a.update(40, 1.0))
        assertNull(a.update(40, 3.5))
        assertEquals(RoadSignEvent.SpeedLimit(40), a.update(40, 4.1))
        assertNull(a.update(40, 10.0))
        assertNull(a.update(null as Int?, 11.0))
        assertNull(a.update(40, 20.0))
    }

    @Test fun upcomingSpeedLimitChange() {
        val edges = listOf(RouteEdgeAttributes(startDistance = 0.0, endDistance = 500.0, speedLimitKmh = 60),
            RouteEdgeAttributes(startDistance = 500.0, endDistance = 900.0, speedLimitKmh = 60),
            RouteEdgeAttributes(startDistance = 900.0, endDistance = 1500.0, speedLimitKmh = 40))
        val change = SignAnnouncer.nextSpeedLimitChange(edges, 780.0, 200.0)
        assertEquals(40, change?.kmh)
        assertEquals(120.0, change?.distanceAhead ?: 0.0, 0.01)
        val a = SignAnnouncer()
        assertNull(a.update(edges, 600.0, 50.0))
        assertEquals(RoadSignEvent.SpeedLimitAhead(40, 120.0), a.update(edges, 780.0, 50.0))
        assertNull(a.update(edges, 800.0, 50.0))
    }

    @Test fun cameraStopSign() {
        val a = SignAnnouncer()
        assertEquals(RoadSignEvent.CameraStopSign(5), a.cameraStopSign(5, 0.0))
        assertNull(a.cameraStopSign(5, 1.0))
        assertNull(a.cameraStopSign(6, 5.0))
        assertEquals(RoadSignEvent.CameraStopSign(7), a.cameraStopSign(7, 30.0))
        a.update(listOf(FeatureAhead("s", RouteFeatureKind.STOP_SIGN, 80.0)), 30.0, 60.0)
        assertNull(a.cameraStopSign(8, 65.0))
    }
}

class CoachRulesTest {
    @Test fun priorityAndGlobalGap() {
        val r = CoachRules()
        r.offer(CoachMessage.RoadSign(RouteFeatureKind.SCHOOL, 150), 0.0)
        r.offer(CoachMessage.LaneDeparture(LaneSide.LEFT), 0.0)
        r.offer(CoachMessage.GreenLightGo, 0.0)
        assertEquals(CoachMessage.LaneDeparture(LaneSide.LEFT), r.next(0.0))
        assertNull("global gap", r.next(1.0))
        assertEquals(CoachMessage.RoadSign(RouteFeatureKind.SCHOOL, 150), r.next(3.1))
        assertNull("green hint expired (ttl 3 s)", r.next(6.5))
    }

    @Test fun collisionBypassesGap() {
        val r = CoachRules()
        r.offer(CoachMessage.SpeedLimit(60), 0.0)
        assertEquals(CoachMessage.SpeedLimit(60), r.next(0.0))
        r.offer(CoachMessage.CollisionRisk, 0.5)
        assertEquals(CoachMessage.CollisionRisk, r.next(0.5))
        r.offer(CoachMessage.CollisionRisk, 1.0)
        assertNull("collision has its own cooldown", r.next(1.0))
        r.offer(CoachMessage.CollisionRisk, 5.6)
        assertEquals(CoachMessage.CollisionRisk, r.next(5.6))
    }

    @Test fun perCategoryCooldown() {
        val r = CoachRules()
        r.offer(CoachMessage.KeepDistance(30), 0.0)
        assertNotNull(r.next(0.0))
        r.offer(CoachMessage.KeepDistance(30), 5.0)
        assertNull(r.next(5.0))
        r.offer(CoachMessage.KeepDistance(30), 12.5)
        assertEquals(CoachMessage.KeepDistance(30), r.next(12.5))
    }

    @Test fun spokenDistanceRounding() {
        assertEquals(90, CoachMessage.spokenDistance(94.0))
        assertEquals(10, CoachMessage.spokenDistance(4.0))
        assertEquals(200, CoachMessage.spokenDistance(176.0))
        assertEquals(400, CoachMessage.spokenDistance(380.0))
    }

    @Test fun urgency() {
        assertEquals(CoachUrgency.HIGH, CoachMessage.CollisionRisk.urgency)
        assertEquals(CoachUrgency.HIGH, CoachMessage.RedLightAhead.urgency)
        assertEquals(CoachUrgency.LOW, CoachMessage.GreenLightGo.urgency)
        assertTrue(CoachCategory.COLLISION > CoachCategory.PEDESTRIAN)
        assertTrue(CoachCategory.PEDESTRIAN > CoachCategory.RED_LIGHT)
        assertTrue(CoachCategory.COLLISION > CoachCategory.RED_LIGHT)
        assertTrue(CoachCategory.RED_LIGHT > CoachCategory.LANE_DEPARTURE)
        assertTrue(CoachCategory.LANE_DEPARTURE > CoachCategory.TAILGATING)
        assertTrue(CoachCategory.TAILGATING > CoachCategory.SIGN)
        assertTrue(CoachCategory.SIGN > CoachCategory.GREEN_LIGHT)
    }
}

class PedestrianCoachTest {
    private fun hazard(id: Int, level: PedestrianHazardLevel, distance: Double = 12.0, inLane: Boolean = true) =
        PedestrianHazard(id, BBox(0.48, 0.5, 0.04, 0.15), level, distance, inLane, onRoadway = true, approaching = false)

    @Test fun pedestrianPriorityBetweenCollisionAndRedLight() {
        val r = CoachRules()
        r.offer(CoachMessage.RedLightAhead, 0.0)
        r.offer(CoachMessage.PedestrianDanger(3), 0.0)
        r.offer(CoachMessage.CollisionRisk, 0.0)
        assertEquals(CoachMessage.CollisionRisk, r.next(0.0))
        assertEquals("pedestrian danger bypasses the global gap", CoachMessage.PedestrianDanger(3), r.next(0.1))
        assertNull("red light waits for the global gap", r.next(0.2))
        assertNull("red light expired (ttl 3 s)", r.next(3.1))

        val q = CoachRules()
        q.offer(CoachMessage.RedLightAhead, 0.0)
        q.offer(CoachMessage.PedestrianCaution(1), 0.0)
        assertEquals(CoachMessage.PedestrianCaution(1), q.next(0.0))
        assertNull("caution does not bypass the global gap", q.next(1.0))
        assertNull(q.next(2.9))
    }

    @Test fun pedestrianUrgencyAndCategory() {
        assertEquals(CoachUrgency.HIGH, CoachMessage.PedestrianDanger(1).urgency)
        assertEquals(CoachUrgency.NORMAL, CoachMessage.PedestrianCaution(1).urgency)
        assertEquals(CoachCategory.PEDESTRIAN, CoachMessage.PedestrianCaution(1).category)
        assertTrue(CoachMessage.PedestrianDanger(1).bypassesGlobalGap)
        assertFalse(CoachMessage.PedestrianCaution(1).bypassesGlobalGap)
    }

    @Test fun perTrackCooldownAndEscalation() {
        val e = DriverCoachEngine()
        e.updatePedestrians(listOf(hazard(7, PedestrianHazardLevel.CAUTION, inLane = false)), 30.0, 0.0)
        assertEquals(CoachMessage.PedestrianCaution(7), e.next(0.0))
        e.updatePedestrians(listOf(hazard(7, PedestrianHazardLevel.CAUTION, inLane = false)), 30.0, 3.0)
        assertNull("same track, same level within 6 s", e.next(3.0))
        e.updatePedestrians(listOf(hazard(7, PedestrianHazardLevel.DANGER)), 30.0, 3.5)
        assertEquals("escalation to danger is spoken", CoachMessage.PedestrianDanger(7), e.next(3.5))
        e.updatePedestrians(listOf(hazard(7, PedestrianHazardLevel.DANGER)), 30.0, 5.0)
        assertNull(e.next(5.0))
        e.updatePedestrians(listOf(hazard(7, PedestrianHazardLevel.DANGER)), 30.0, 9.6)
        assertEquals("again after the 6 s track cooldown", CoachMessage.PedestrianDanger(7), e.next(9.6))
    }

    @Test fun cautionNeedsMovingDangerAlways() {
        val e = DriverCoachEngine()
        e.updatePedestrians(listOf(hazard(1, PedestrianHazardLevel.CAUTION, inLane = false)), 2.0, 0.0)
        assertNull(e.next(0.0))
        e.updatePedestrians(listOf(hazard(1, PedestrianHazardLevel.DANGER)), 0.0, 0.5)
        assertEquals(CoachMessage.PedestrianDanger(1), e.next(0.5))
        e.toggles = e.toggles.copy(pedestrians = false)
        e.updatePedestrians(listOf(hazard(2, PedestrianHazardLevel.DANGER)), 40.0, 10.0)
        assertNull(e.next(10.0))
    }

    @Test fun pedestrianNotYieldedEvent() {
        val monitor = CameraDrivingEventMonitor()
        val all = mutableListOf<DrivingEvent>()
        for (i in 0..10) {
            val t = i * 0.1
            all += monitor.update(CameraEventInput(timestamp = t, speedKmh = 30.0,
                pedestrianHazards = listOf(hazard(4, PedestrianHazardLevel.DANGER, distance = 14 - i * 0.5))))
        }
        assertEquals(listOf(DrivingEventKind.PEDESTRIAN_NOT_YIELDED), all.map { it.kind })
        assertEquals(DrivingEventSeverity.VIOLATION, all.firstOrNull()?.severity)
        assertTrue((all.firstOrNull()?.value ?: 99.0) <= 12)

        val slow = CameraDrivingEventMonitor()
        val far = CameraDrivingEventMonitor()
        val side = CameraDrivingEventMonitor()
        for (i in 0..10) {
            val t = i * 0.1
            assertTrue(slow.update(CameraEventInput(timestamp = t, speedKmh = 10.0,
                pedestrianHazards = listOf(hazard(1, PedestrianHazardLevel.DANGER)))).isEmpty())
            assertTrue(far.update(CameraEventInput(timestamp = t, speedKmh = 40.0,
                pedestrianHazards = listOf(hazard(1, PedestrianHazardLevel.DANGER, distance = 25.0)))).isEmpty())
            assertTrue(side.update(CameraEventInput(timestamp = t, speedKmh = 40.0,
                pedestrianHazards = listOf(hazard(1, PedestrianHazardLevel.DANGER, inLane = false)))).isEmpty())
        }
        assertEquals("figure.walk", DrivingEventKind.PEDESTRIAN_NOT_YIELDED.symbolName)
    }
}

class TrafficLightCoachTest {
    private fun light(color: TrafficLightColor, id: Int = 1, x: Double = 0.5) =
        ObservedTrafficLight(id, color, BBox(x - 0.02, 0.2, 0.04, 0.08))

    private fun steps(from: Double, through: Double, by: Double): List<Double> {
        val out = mutableListOf<Double>()
        var i = 0
        while (true) {
            val v = from + i * by
            if (v > through + 1e-9) break
            out.add(v); i++
        }
        return out
    }

    @Test fun redAheadWhileMoving() {
        val c = TrafficLightCoach()
        val red = TrafficLightColor.RED
        assertNull(c.update(light(red), 40.0, null, 0.0))
        assertEquals(CoachMessage.RedLightAhead, c.update(light(red), 40.0, null, 0.6))
        assertNull("once per light", c.update(light(red), 40.0, null, 1.5))
        val slow = TrafficLightCoach()
        assertNull(slow.update(light(red, id = 2), 15.0, null, 0.0))
        assertNull(slow.update(light(red, id = 2), 15.0, null, 1.0))
        assertNull(slow.update(light(red, id = 3, x = 0.95), 50.0, null, 2.0))
        assertNull(slow.update(light(red, id = 3, x = 0.95), 50.0, null, 3.0))
    }

    @Test fun greenGoAfterWaitingAtRed() {
        val c = TrafficLightCoach()
        assertNull(c.update(light(TrafficLightColor.RED), 0.0, null, 0.0))
        assertNull(c.update(light(TrafficLightColor.GREEN), 0.0, null, 10.0))
        assertNull(c.update(light(TrafficLightColor.GREEN), 0.0, null, 10.5))
        assertEquals(CoachMessage.GreenLightGo, c.update(light(TrafficLightColor.GREEN), 0.0, null, 11.1))
        assertNull(c.update(light(TrafficLightColor.GREEN), 0.0, null, 12.0))
    }

    @Test fun noGreenHintWithCloseLeadOrWithoutRed() {
        val c = TrafficLightCoach()
        c.update(light(TrafficLightColor.RED), 1.0, 2.5, 0.0)
        for (t in steps(5.0, 8.0, 0.5)) assertNull(c.update(light(TrafficLightColor.GREEN), 1.0, 2.5, t))
        val d = TrafficLightCoach()
        for (t in steps(0.0, 3.0, 0.5)) assertNull(d.update(light(TrafficLightColor.GREEN), 0.0, null, t))
    }
}

class DriverCoachEngineTest {
    private val policy = FollowingDistancePolicy()

    @Test fun tooCloseNeedsPersistenceAndCollisionSuppressesKeepDistance() {
        val engine = DriverCoachEngine()
        val close = FollowingDistanceCalculator.assess(10.0, 60.0, 0.0, policy, RoadSurfaceCondition.DRY)
        assertEquals(DistanceStatus.DANGER, close.status)
        engine.update(CoachFrameInput(timestamp = 0.0, speedKmh = 60.0, assessment = close, hasLead = true))
        assertNull(engine.next(0.0))
        engine.update(CoachFrameInput(timestamp = 1.1, speedKmh = 60.0, assessment = close, hasLead = true))
        assertEquals(CoachMessage.KeepDistance(null), engine.next(1.1))

        val engine2 = DriverCoachEngine()
        val closing = FollowingDistanceCalculator.assess(20.0, 60.0, -40.0, policy, RoadSurfaceCondition.DRY)
        engine2.update(CoachFrameInput(timestamp = 0.0, speedKmh = 60.0, assessment = closing, hasLead = true, collisionWarning = true))
        engine2.update(CoachFrameInput(timestamp = 0.3, speedKmh = 60.0, assessment = closing, hasLead = true, collisionWarning = true))
        assertEquals(CoachMessage.CollisionRisk, engine2.next(0.3))
        engine2.update(CoachFrameInput(timestamp = 4.0, speedKmh = 60.0, assessment = close, hasLead = true))
        engine2.update(CoachFrameInput(timestamp = 5.2, speedKmh = 60.0, assessment = close, hasLead = true))
        assertNull("keep-distance suppressed right after the collision warning", engine2.next(5.2))
    }

    @Test fun togglesAndSigns() {
        val engine = DriverCoachEngine(toggles = CoachToggles(laneDeparture = false, signs = false))
        engine.update(CoachFrameInput(timestamp = 0.0, speedKmh = 60.0, laneDeparture = LaneSide.RIGHT))
        engine.offerSign(RoadSignEvent.SpeedLimit(50), 0.0)
        assertNull(engine.next(0.0))
        engine.toggles = CoachToggles()
        engine.offerSign(RoadSignEvent.Feature(RouteFeatureKind.RAILWAY_CROSSING, 176.0, "x"), 1.0)
        assertEquals(CoachMessage.RoadSign(RouteFeatureKind.RAILWAY_CROSSING, 200), engine.next(1.0))
    }
}

class CameraDrivingEventTest {
    private val policy = FollowingDistancePolicy()
    private val geometry = CameraGeometry(65.0, 1080.0, 1920.0)

    private fun light(id: Int, color: TrafficLightColor, y: Double, x: Double = 0.48) =
        TrackedObject(id = id, kind = VehicleKind.TRAFFIC_LIGHT, label = "traffic light", box = BBox(x, y, 0.04, 0.08),
            confidence = 0.8, hits = 5, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true, lightColor = color)

    @Test fun redLightRunning() {
        val d = RedLightRunningDetector()
        var result: Double? = null
        for ((i, y) in listOf(0.3, 0.22, 0.14, 0.07, 0.02).withIndex()) {
            result = d.update(listOf(light(1, TrafficLightColor.RED, y)), 40.0, i * 0.3) ?: result
        }
        assertNull(result)
        result = d.update(emptyList(), 40.0, 1.6)
        assertEquals(40.0, result ?: 0.0, 0.01)
    }

    @Test fun noRedLightRunningWhenGreenOrStopped() {
        val d = RedLightRunningDetector()
        for ((i, y) in listOf(0.3, 0.2, 0.1, 0.02).withIndex()) {
            val color = if (i < 2) TrafficLightColor.RED else TrafficLightColor.GREEN
            d.update(listOf(light(1, color, y)), 40.0, i * 0.3)
        }
        assertNull(d.update(emptyList(), 40.0, 2.0))
        val s = RedLightRunningDetector()
        for ((i, y) in listOf(0.3, 0.2, 0.1, 0.02).withIndex()) s.update(listOf(light(1, TrafficLightColor.RED, y)), 8.0, i * 0.3)
        assertNull(s.update(emptyList(), 8.0, 2.0))
        val m = RedLightRunningDetector()
        for (i in 0 until 5) m.update(listOf(light(1, TrafficLightColor.RED, 0.3)), 40.0, i * 0.3)
        assertNull(m.update(emptyList(), 40.0, 2.0))
    }

    private fun stopSign(width: Double) = TrackedObject(id = 3, kind = VehicleKind.STOP_SIGN, label = "stop sign",
        box = BBox(0.7, 0.3, width, width), confidence = 0.8, hits = 5, firstSeen = 0.0, lastSeen = 0.0, isConfirmed = true)

    @Test fun stopSignIgnoredAndObeyed() {
        val m = StopSignComplianceMonitor()
        assertEquals(24.4, m.distance(stopSign(0.04).box, geometry) ?: 0.0, 1.0)
        assertNull(m.update(listOf(stopSign(0.02)), geometry, 30.0, 0.0))
        assertFalse(m.isArmed)
        assertNull(m.update(listOf(stopSign(0.04)), geometry, 30.0, 1.0))
        assertTrue(m.isArmed)
        assertNull(m.update(listOf(stopSign(0.08)), geometry, 20.0, 2.0))
        assertNull(m.update(emptyList(), geometry, 18.0, 3.0))
        val v = m.update(emptyList(), geometry, 25.0, 4.6)
        assertEquals(18.0, v?.minSpeedKmh ?: 0.0, 0.01)

        val ok = StopSignComplianceMonitor()
        ok.update(listOf(stopSign(0.04)), geometry, 30.0, 0.0)
        ok.update(listOf(stopSign(0.08)), geometry, 2.0, 2.0)
        assertNull(ok.update(emptyList(), geometry, 20.0, 5.0))
    }

    @Test fun tailgatingAndCollisionEvents() {
        val monitor = CameraDrivingEventMonitor()
        val close = FollowingDistanceCalculator.assess(12.0, 60.0, 0.0, policy, RoadSurfaceCondition.DRY)
        val all = mutableListOf<DrivingEvent>()
        for (i in 0..25) {
            val t = i * 0.1
            all += monitor.update(CameraEventInput(timestamp = t, speedKmh = 60.0, assessment = close, hasLead = true))
        }
        assertEquals(listOf(DrivingEventKind.TAILGATING), all.map { it.kind })
        assertEquals(12.0, all.firstOrNull()?.value ?: 0.0, 0.01)
        assertEquals(33.3, all.firstOrNull()?.limit ?: 0.0, 0.1)
        assertTrue((all.firstOrNull()?.duration ?: 0.0) >= 2)

        val collision = monitor.update(CameraEventInput(timestamp = 3.0, speedKmh = 60.0, assessment = close, hasLead = true,
            collisionWarning = true))
        assertEquals(listOf(DrivingEventKind.COLLISION_RISK), collision.map { it.kind })
        assertTrue(monitor.update(CameraEventInput(timestamp = 3.1, speedKmh = 60.0, assessment = close, hasLead = true,
            collisionWarning = true)).isEmpty())
        val lane = monitor.update(CameraEventInput(timestamp = 4.0, speedKmh = 60.0, laneDeparture = LaneSide.LEFT, laneOffset = -0.7))
        assertEquals(listOf(DrivingEventKind.LANE_DEPARTURE), lane.map { it.kind })
        assertEquals("heuristic; side=left", lane.firstOrNull()?.note)
    }

    @Test fun noTailgatingWhenStopped() {
        val monitor = CameraDrivingEventMonitor()
        val stopped = FollowingDistanceCalculator.assess(0.8, 0.0, 0.0, policy, RoadSurfaceCondition.DRY)
        for (i in 0..30) {
            assertTrue(monitor.update(CameraEventInput(timestamp = i * 0.1, speedKmh = 0.0, assessment = stopped, hasLead = true)).isEmpty())
        }
    }
}
