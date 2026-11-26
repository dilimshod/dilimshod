package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** `docs/TRAINING_API.md` §1–3: hard-example selection, frame quality, metadata, storage and model update rules. */
class ContinuousLearningTest {
    private val goodQuality = FrameQuality.Metrics(sharpness = 150.0, brightness = 100.0, dhash = 0x0F0F0F0F0F0F0F0FL)

    private fun track(
        id: Int, kind: VehicleKind = VehicleKind.CAR, hits: Int = 10, missed: Int = 0, confirmed: Boolean = true,
        box: BBox = BBox(0.4, 0.4, 0.1, 0.1), confidence: Double = 0.8, classFlip: Boolean? = null,
    ) = HardExampleSelector.Track(id, kind, confidence, hits, missed, confirmed, box, classFlip)

    private fun frame(
        index: Long, t: Double, tracks: List<HardExampleSelector.Track> = emptyList(),
        detections: List<Detection> = emptyList(), speed: Double? = 40.0,
    ) = HardExampleSelector.Frame(index, t, speed, tracks, detections, DetectionThresholds.perClass(0.35))

    /** Pushes [first] then a plain follow-up frame and returns the candidate for [first]. */
    private fun candidateFor(
        selector: HardExampleSelector, first: HardExampleSelector.Frame,
        next: HardExampleSelector.Frame = frame(first.frameIndex + 1, first.timestamp + 0.066, first.tracks),
    ): HardExampleSelector.Candidate? {
        selector.push(first)
        return selector.push(next)
    }

    // Reasons

    @Test fun missedDetectionFiresForCoastingConfirmedTrackInsideFrame() {
        val s = HardExampleSelector()
        val c = candidateFor(s, frame(1, 10.0, listOf(track(1, missed = 1, box = BBox(0.3, 0.4, 0.1, 0.05)))))
        assertEquals(listOf(HardExampleReason.MISSED_DETECTION), c?.reasons)
    }

    @Test fun missedDetectionNeedsBoxInsideFrameAndMinimumHeight() {
        val tooSmall = candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(track(1, missed = 1, box = BBox(0.3, 0.4, 0.1, 0.03)))))
        assertNull(tooSmall)
        val leaving = candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(track(1, missed = 1, box = BBox(0.95, 0.4, 0.1, 0.1)))))
        assertNull(leaving)
        val unconfirmed = candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(track(1, missed = 1, confirmed = false, hits = 2))))
        assertNull(unconfirmed)
    }

    @Test fun shortLivedReportedOnFrameWhereTrackWasLastDetected() {
        val s = HardExampleSelector()
        val ghost = track(5, hits = 2, confirmed = false)
        val first = frame(1, 10.0, listOf(ghost, track(1)))
        val next = frame(2, 10.066, listOf(track(1)))
        val c = candidateFor(s, first, next)
        assertNotNull(c)
        assertEquals(listOf(HardExampleReason.SHORT_LIVED), c!!.reasons)
        // The candidate is the frame where the ghost was still detected.
        assertEquals(1L, c.frame.frameIndex)
        assertTrue(c.frame.tracks.any { it.id == 5 })
    }

    @Test fun shortLivedNotReportedWhileTrackContinuesOrAfterGap() {
        val ghost = track(5, hits = 2, confirmed = false)
        assertNull(candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(ghost)), frame(2, 10.066, listOf(ghost.copy(hits = 3)))))
        // Next frame 3 s later: no lookahead, no shortLived.
        assertNull(candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(ghost)), frame(2, 13.0)))
        // A track with 3 hits is not short-lived.
        assertNull(candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(track(5, hits = 3, confirmed = false))), frame(2, 10.066)))
    }

    @Test fun lowConfidenceFiresBetweenFloorAndClassThreshold() {
        val low = Detection(VehicleKind.CAR, "car", 0.30, BBox(0.1, 0.5, 0.1, 0.1))
        assertEquals(listOf(HardExampleReason.LOW_CONFIDENCE),
            candidateFor(HardExampleSelector(), frame(1, 10.0, detections = listOf(low)))?.reasons)
        val tooLow = low.copy(confidence = 0.24)
        assertNull(candidateFor(HardExampleSelector(), frame(1, 10.0, detections = listOf(tooLow))))
        val atThreshold = low.copy(confidence = DetectionThresholds.threshold(VehicleKind.CAR, 0.35))
        assertNull(candidateFor(HardExampleSelector(), frame(1, 10.0, detections = listOf(atThreshold))))
        // Person threshold at slider 0.35 is 0.45: 0.40 is a low-confidence person.
        val person = Detection(VehicleKind.PERSON, "person", 0.40, BBox(0.1, 0.5, 0.05, 0.2))
        assertEquals(listOf(HardExampleReason.LOW_CONFIDENCE),
            candidateFor(HardExampleSelector(), frame(1, 10.0, detections = listOf(person)))?.reasons)
    }

    @Test fun classFlipFiresWhenConfirmedTrackChangesClass() {
        val s = HardExampleSelector()
        assertNull(s.push(frame(1, 10.0, listOf(track(3, kind = VehicleKind.CAR)))))
        assertNull(s.push(frame(2, 10.066, listOf(track(3, kind = VehicleKind.TRUCK)))))   // candidate: frame 1, no reason
        val c = s.push(frame(3, 10.133, listOf(track(3, kind = VehicleKind.TRUCK))))       // candidate: frame 2
        assertEquals(listOf(HardExampleReason.CLASS_FLIP), c?.reasons)
        assertEquals(2L, c?.frame?.frameIndex)
        // Explicit flag.
        val flagged = candidateFor(HardExampleSelector(), frame(1, 10.0, listOf(track(4, classFlip = true))))
        assertEquals(listOf(HardExampleReason.CLASS_FLIP), flagged?.reasons)
    }

    @Test fun randomSampleIsDeterministicOnePercent() {
        assertEquals(listOf(HardExampleReason.RANDOM), candidateFor(HardExampleSelector(), frame(37, 10.0))?.reasons)
        assertEquals(listOf(HardExampleReason.RANDOM), candidateFor(HardExampleSelector(), frame(137, 10.0))?.reasons)
        assertNull(candidateFor(HardExampleSelector(), frame(36, 10.0)))
        assertNull(candidateFor(HardExampleSelector(), frame(38, 10.0)))
    }

    @Test fun severalReasonsAreReportedInContractOrder() {
        val low = Detection(VehicleKind.CAR, "car", 0.30, BBox(0.1, 0.5, 0.1, 0.1))
        val c = candidateFor(HardExampleSelector(), frame(37, 10.0, listOf(track(1, missed = 1)), listOf(low)))
        assertEquals(listOf(HardExampleReason.MISSED_DETECTION, HardExampleReason.LOW_CONFIDENCE, HardExampleReason.RANDOM), c?.reasons)
    }

    // Gates

    @Test fun keepsFrameAndEnforcesMinimumInterval() {
        val s = HardExampleSelector()
        val c1 = candidateFor(s, frame(37, 10.0))!!
        assertEquals(HardExampleDecision(true, listOf(HardExampleReason.RANDOM)), s.decide(c1, goodQuality))
        // 1.5 s later: blocked by the 2 s interval before quality is computed.
        s.reset()
        assertNull(candidateFor(s, frame(137, 11.5)))
        // 2.0 s later: allowed again (different image).
        s.reset()
        val c2 = candidateFor(s, frame(237, 12.0))!!
        assertTrue(s.decide(c2, goodQuality.copy(dhash = goodQuality.dhash.inv())).keep)
        assertEquals(2, s.keptThisTrip)
    }

    @Test fun perTripCapAndTripReset() {
        val s = HardExampleSelector(HardExampleSelector.Config(maxPerTrip = 2))
        var hash = 1L
        for (i in 0 until 2) {
            s.reset()
            val c = candidateFor(s, frame(37L + 100 * i, 10.0 + 3 * i))!!
            hash = hash.inv() xor (0xFFFFL shl (16 * i))
            assertTrue(s.decide(c, goodQuality.copy(dhash = hash)).keep)
        }
        s.reset()
        assertNull(candidateFor(s, frame(237, 20.0)))
        s.resetTrip()
        s.reset()
        assertNotNull(candidateFor(s, frame(337, 30.0)))
        assertEquals(300, HardExampleSelector().config.maxPerTrip)
        assertEquals(2.0, HardExampleSelector().config.minIntervalSeconds, 0.0)
    }

    @Test fun speedGateAllowsUnknownSpeedOnly() {
        assertNull(candidateFor(HardExampleSelector(), frame(37, 10.0, speed = 3.0)))
        assertNotNull(candidateFor(HardExampleSelector(), frame(37, 10.0, speed = 5.0)))
        assertNotNull(candidateFor(HardExampleSelector(), frame(37, 10.0, speed = null)))
    }

    @Test fun qualityGatesRejectBlurDarkBrightAndDuplicates() {
        fun decide(q: FrameQuality.Metrics, s: HardExampleSelector = HardExampleSelector()) =
            s.decide(candidateFor(s, frame(37, 10.0))!!, q).keep
        assertFalse(decide(goodQuality.copy(sharpness = 59.9)))
        assertTrue(decide(goodQuality.copy(sharpness = 60.0)))
        assertFalse(decide(goodQuality.copy(brightness = 34.9)))
        assertTrue(decide(goodQuality.copy(brightness = 35.0)))
        assertTrue(decide(goodQuality.copy(brightness = 225.0)))
        assertFalse(decide(goodQuality.copy(brightness = 225.1)))

        val s = HardExampleSelector()
        assertTrue(s.decide(candidateFor(s, frame(37, 10.0))!!, goodQuality).keep)
        s.reset()
        // Hamming distance 6 to the last kept frame: duplicate.
        val near = goodQuality.copy(dhash = goodQuality.dhash xor 0b111111L)
        assertFalse(s.decide(candidateFor(s, frame(137, 20.0))!!, near).keep)
        s.reset()
        val far = goodQuality.copy(dhash = goodQuality.dhash xor 0b1111111L)
        assertTrue(s.decide(candidateFor(s, frame(237, 30.0))!!, far).keep)
        assertEquals(1, s.qualityRejections)
    }

    // Frame quality

    private fun gradient(w: Int = 160, h: Int = 90) = GrayImage(w, h, IntArray(w * h) { i -> (i % w) * 255 / (w - 1) })

    private fun mirrored(g: GrayImage) = GrayImage(g.width, g.height, IntArray(g.width * g.height) { i ->
        val y = i / g.width; val x = i % g.width
        g[g.width - 1 - x, y]
    })

    @Test fun dHashOfIdenticalImagesIsZeroAndMirrorIsFar() {
        val g = gradient()
        assertEquals(0, FrameQuality.hamming(FrameQuality.dHash(g), FrameQuality.dHash(gradient())))
        assertTrue(FrameQuality.hamming(FrameQuality.dHash(g), FrameQuality.dHash(mirrored(g))) > 6)
        assertEquals(16, FrameQuality.hex(FrameQuality.dHash(mirrored(g))).length)
        assertEquals("ffffffffffffffff", FrameQuality.hex(FrameQuality.dHash(mirrored(g))))
        assertEquals("0000000000000000", FrameQuality.hex(FrameQuality.dHash(g)))
    }

    @Test fun sharpnessOfFlatImageIsZeroAndCheckerboardIsSharp() {
        assertEquals(0.0, FrameQuality.sharpness(GrayImage.filled(160, 90, 128)), 1e-9)
        val board = GrayImage(160, 90, IntArray(160 * 90) { i -> if (((i % 160) / 4 + (i / 160) / 4) % 2 == 0) 0 else 255 })
        assertTrue(FrameQuality.sharpness(board) >= 60)
    }

    @Test fun brightnessIsMeanGray() {
        assertEquals(100.0, FrameQuality.brightness(GrayImage.filled(160, 90, 100)), 1e-9)
        assertEquals(127.5, FrameQuality.brightness(GrayImage(2, 1, intArrayOf(0, 255))), 1e-9)
    }

    @Test fun grayFromRGBAScalesTo160Wide() {
        val w = 1280; val h = 720; val stride = w * 4 + 64
        val rgba = ByteArray(stride * h)
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * stride + x * 4
            rgba[i] = 200.toByte(); rgba[i + 1] = 200.toByte(); rgba[i + 2] = 200.toByte(); rgba[i + 3] = 255.toByte()
        }
        val g = FrameQuality.grayFromRGBA(rgba, w, h, stride)
        assertEquals(160, g.width)
        assertEquals(90, g.height)
        assertEquals(199.0, FrameQuality.brightness(g), 1.0)
        assertEquals(0.0, FrameQuality.sharpness(g), 1e-9)
        // Pure red → luma ≈ 0.3 × 255.
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * stride + x * 4
            rgba[i] = 255.toByte(); rgba[i + 1] = 0; rgba[i + 2] = 0
        }
        assertEquals(76.0, FrameQuality.brightness(FrameQuality.grayFromRGBA(rgba, w, h, stride)), 1.0)
        assertEquals(29.0, FrameQuality.brightness(FrameQuality.grayFromRGBA(rgba, w, h, stride, bgra = true)), 1.0)
    }

    // Metadata

    @Test fun sampleMetaUsesContractKeys() {
        val meta = LearningSampleMeta(
            id = "6f1c2e7a-0000-4000-8000-000000000001", capturedAtMillis = 1_795_687_200_123L, appVersion = "1.0",
            modelName = "yolo11n", modelVersion = "bundled-yolo11n-640x384", imageWidth = 960, imageHeight = 540,
            reasons = listOf(HardExampleReason.MISSED_DETECTION), speedKmh = 42.04, lat = 41.311081, lon = 69.279737,
            detections = listOf(Detection(VehicleKind.TRAFFIC_LIGHT, "traffic light", 0.6234, BBox(0.1, 0.2, 0.05, 0.1))),
            tracks = listOf(track(7, missed = 1, confidence = 0.71)),
            quality = FrameQuality.Metrics(140.23, 96.0, 0x0F0E1D2C3B4A5968L),
        )
        val o = meta.toJson()
        assertEquals(LearningSampleMeta.topLevelKeys, o.keySet())
        assertEquals("2026-11-26T10:00:00Z", o.getString("capturedAt"))
        assertEquals("android", o.getString("platform"))
        assertEquals(setOf("name", "version"), o.getJSONObject("model").keySet())
        assertEquals(setOf("width", "height", "orientation"), o.getJSONObject("image").keySet())
        assertEquals("landscape", o.getJSONObject("image").getString("orientation"))
        assertEquals("missedDetection", o.getJSONArray("reasons").getString(0))
        val d = o.getJSONArray("detections").getJSONObject(0)
        assertEquals(setOf("label", "kind", "confidence", "box"), d.keySet())
        assertEquals("trafficLight", d.getString("kind"))
        assertEquals(4, d.getJSONArray("box").length())
        val t = o.getJSONArray("tracks").getJSONObject(0)
        assertEquals(setOf("id", "kind", "confidence", "hits", "missed", "confirmed", "box"), t.keySet())
        assertEquals(true, t.getBoolean("confirmed"))
        val q = o.getJSONObject("quality")
        assertEquals(setOf("sharpness", "brightness", "dhash"), q.keySet())
        assertEquals("0f0e1d2c3b4a5968", q.getString("dhash"))
        // Round trip through text.
        assertEquals(42.0, JSONObject(o.toString()).getDouble("speedKmh"), 1e-9)
    }

    @Test fun sampleMetaOmitsLocationAndSpeedWhenUnknown() {
        val meta = LearningSampleMeta(id = "a", capturedAtMillis = 0, appVersion = "1.0", modelName = "m", modelVersion = "v",
            imageWidth = 540, imageHeight = 960, reasons = listOf("random"), quality = goodQuality)
        val o = meta.toJson()
        assertFalse(o.has("lat")); assertFalse(o.has("lon")); assertFalse(o.has("speedKmh"))
        assertEquals("portrait", o.getJSONObject("image").getString("orientation"))
        assertEquals("1970-01-01T00:00:00Z", o.getString("capturedAt"))
    }

    // Storage policy

    @Test fun retentionDeletesExpiredThenOldestOverLimit() {
        val day = 24L * 3600 * 1000
        val now = 100 * day
        val mb = 1024L * 1024
        val samples = listOf(
            LearningStorePolicy.StoredSample("old", 1 * mb, now - 15 * day),
            LearningStorePolicy.StoredSample("a", 40 * mb, now - 3 * day),
            LearningStorePolicy.StoredSample("b", 40 * mb, now - 2 * day),
            LearningStorePolicy.StoredSample("c", 40 * mb, now - 1 * day),
        )
        val r = LearningStorePolicy.retention(samples, LearningStorePolicy.limitBytes(100), now)
        assertEquals(listOf("old"), r.expired)
        assertEquals(listOf("a"), r.overLimit)
        assertEquals(300, LearningStorePolicy.normalizedLimitMb(123))
        assertEquals(1000, LearningStorePolicy.normalizedLimitMb(1000))
    }

    @Test fun backoffAndOutcomes() {
        assertEquals(listOf(0L, 1L, 2L, 4L, 8L, 16L, 32L, 60L, 60L, 60L), (0..9).map { LearningStorePolicy.backoffMinutes(it) })
        assertEquals(LearningStorePolicy.UploadOutcome.UPLOADED, LearningStorePolicy.outcome(201))
        assertEquals(LearningStorePolicy.UploadOutcome.UPLOADED, LearningStorePolicy.outcome(409))
        assertEquals(LearningStorePolicy.UploadOutcome.UNAUTHORIZED, LearningStorePolicy.outcome(401))
        assertEquals(LearningStorePolicy.UploadOutcome.REJECTED, LearningStorePolicy.outcome(413))
        assertEquals(LearningStorePolicy.UploadOutcome.RETRY_LATER, LearningStorePolicy.outcome(429))
        assertEquals(LearningStorePolicy.UploadOutcome.RETRY_LATER, LearningStorePolicy.outcome(503))
        val batch = LearningStorePolicy.uploadBatch((1..30).map { LearningStorePolicy.StoredSample("s$it", 1, (31 - it).toLong()) })
        assertEquals(20, batch.size)
        assertEquals("s30", batch.first().id)
        assertFalse(LearningStorePolicy.mayUpload(true, wifiOnly = true, onUnmeteredNetwork = false, connected = true, cameraActive = false))
        assertFalse(LearningStorePolicy.mayUpload(true, wifiOnly = false, onUnmeteredNetwork = false, connected = true, cameraActive = true))
        assertTrue(LearningStorePolicy.mayUpload(true, wifiOnly = false, onUnmeteredNetwork = false, connected = true, cameraActive = false))
    }

    // Model manifest and update rules

    private val manifestText = """
        {"version": "2026-12-01-1", "createdAt": "2026-12-01T03:00:00Z", "baseModel": "yolo11s",
         "metrics": {"testImages": 812, "map50": 0.71, "precision": 0.80, "recall": 0.66, "previous": {"map50": 0.68}},
         "ios": {"landscape": {"name": "RoadVisDetector", "files": []}},
         "android": {"file": {"path": "yolo-roadvis.onnx", "sha256": "${"ab".repeat(32)}", "size": 11000000},
                     "inputs": [[544, 960], [960, 544], [384, 640], [640, 384]]}}
    """.trimIndent()

    @Test fun manifestParses() {
        val m = ModelManifest.parse(manifestText)!!
        assertEquals("2026-12-01-1", m.version)
        assertEquals(0.71, m.metrics!!.map50!!, 1e-9)
        assertEquals(0.68, m.metrics!!.previousMap50!!, 1e-9)
        assertEquals(812, m.metrics!!.testImages)
        val a = m.android!!
        assertEquals("yolo-roadvis.onnx", a.file.path)
        assertEquals(11_000_000L, a.file.size)
        assertEquals(ModelManifest.InputSize(width = 960, height = 544), a.inputs[0])
        assertEquals(4, a.inputs.size)
        assertNull(ModelManifest.parse("[]"))
        assertNull(ModelManifest.parse("{\"createdAt\": \"x\"}"))
    }

    @Test fun downloadDecisionAndSwitchRevert() {
        val m = ModelManifest.parse(manifestText)!!
        assertTrue(ModelUpdatePolicy.shouldDownload(m, null, emptySet()))
        assertFalse(ModelUpdatePolicy.shouldDownload(m, "2026-12-01-1", emptySet()))
        assertFalse(ModelUpdatePolicy.shouldDownload(m, null, setOf("2026-12-01-1")))
        assertFalse(ModelUpdatePolicy.shouldDownload(m.copy(version = "../x"), null, emptySet()))
        assertFalse(ModelUpdatePolicy.shouldDownload(m.copy(android = null), null, emptySet()))
        assertTrue(ModelUpdatePolicy.isCheckDue(ModelUpdatePolicy.CHECK_INTERVAL_MILLIS, 0))
        assertFalse(ModelUpdatePolicy.isCheckDue(ModelUpdatePolicy.CHECK_INTERVAL_MILLIS - 1, 0))
        assertTrue(ModelUpdatePolicy.isCheckDue(5, null))
        assertEquals("https://trafficcounter.uz/roadvis/api/v1/model/latest?platform=android",
            ModelUpdatePolicy.latestUrl("https://trafficcounter.uz/roadvis/"))
        assertEquals("https://h/r/api/v1/model/v1/files/yolo-roadvis.onnx", ModelUpdatePolicy.fileUrl("https://h/r", "v1", "yolo-roadvis.onnx"))
        assertEquals("https://h/api/v1/samples", ModelUpdatePolicy.samplesUrl("https://h"))

        assertEquals("v2", ModelUpdatePolicy.effectiveVersion("v2", emptySet()) { true })
        assertNull(ModelUpdatePolicy.effectiveVersion("v2", setOf("v2")) { true })
        assertNull(ModelUpdatePolicy.effectiveVersion("v2", emptySet()) { false })
        assertNull(ModelUpdatePolicy.effectiveVersion(null, emptySet()) { true })
        assertEquals(listOf("a", "b"), ModelUpdatePolicy.markBad(listOf("b", "a"), "b"))
    }

    @Test fun healthMonitorRevertsAfterThirtySecondsOfDrivingWithoutOutput() {
        val m = ModelHealthMonitor()
        var t = 0.0
        var reverted = false
        // 29 s without output while driving: no revert.
        while (t < 29.0) { reverted = reverted || m.record(t, 40.0, false); t += 0.1 }
        assertFalse(reverted)
        // Output resets the timer.
        assertFalse(m.record(t, 40.0, true))
        // Standing still does not count.
        repeat(400) { t += 0.1; assertFalse(m.record(t, 0.0, false)) }
        // Gaps do not count.
        t += 10; assertFalse(m.record(t, null, false))
        var fired = 0
        repeat(320) { t += 0.1; if (m.record(t, null, false)) fired++ }
        assertEquals(1, fired)
    }
}
