package uz.roadvis.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/** Distance rounding and clip composition for pre-recorded voice clips (VoicePhrase / VoiceComposer / VoiceClipCatalog). */
class VoicePhraseTest {
    private val uz = RVLang.UZ
    private val ru = RVLang.RU
    private val en = RVLang.EN

    @Test fun distanceRounding() {
        assertEquals(VoiceDistance.Meters(300), VoiceDistance.rounded(287.0))
        assertEquals(VoiceDistance.Meters(50), VoiceDistance.rounded(30.0))
        assertEquals(VoiceDistance.Meters(100), VoiceDistance.rounded(120.0))
        assertEquals(VoiceDistance.Meters(300), VoiceDistance.rounded(330.0))
        assertEquals(VoiceDistance.Meters(400), VoiceDistance.rounded(370.0))
        assertEquals(VoiceDistance.Meters(900), VoiceDistance.rounded(940.0))
        assertEquals(VoiceDistance.Kilometers(10), VoiceDistance.rounded(960.0))
        assertEquals(VoiceDistance.Kilometers(15), VoiceDistance.rounded(1_300.0))
        assertEquals(VoiceDistance.Kilometers(20), VoiceDistance.rounded(2_200.0))
        assertEquals(VoiceDistance.Kilometers(25), VoiceDistance.rounded(2_400.0))
        assertEquals(VoiceDistance.Kilometers(30), VoiceDistance.rounded(2_800.0))
        assertEquals(VoiceDistance.Kilometers(70), VoiceDistance.rounded(7_400.0))
        assertEquals(VoiceDistance.Kilometers(100), VoiceDistance.rounded(10_400.0))
        assertNull(VoiceDistance.rounded(12_000.0))
        assertNull(VoiceDistance.rounded(0.0))
        assertNull(VoiceDistance.rounded(Double.NaN))
        assertEquals("n_1_5", VoiceDistance.Kilometers(15).numberID)
        assertEquals("n_3", VoiceDistance.Kilometers(30).numberID)
    }

    @Test fun maneuverUzbek() {
        val phrase = VoicePhrase.maneuver(ManeuverType.RIGHT, 287.0)
        assertEquals(listOf("n_300", "after_meters", "turn_right"), VoiceComposer.clipIDs(phrase, uz))
        assertEquals("Uch yuz metrdan keyin o‘ngga buriling", VoiceComposer.composedText(phrase, uz))
        assertEquals(listOf("uz_n_300", "uz_after_meters", "uz_turn_right"), VoiceComposer.resourceNames(phrase, uz))
        val km = VoicePhrase.maneuver(ManeuverType.LEFT, 1_480.0)
        assertEquals(listOf("n_1_5", "after_km", "turn_left"), VoiceComposer.clipIDs(km, uz))
    }

    @Test fun maneuverRussianPlurals() {
        fun ids(meters: Double) = VoiceComposer.clipIDs(VoicePhrase.maneuver(ManeuverType.RIGHT, meters), ru)
        assertEquals(listOf("through", "n_300", "meters", "turn_right"), ids(287.0))
        assertEquals(listOf("through", "n_1", "km_one", "turn_right"), ids(1_000.0))
        assertEquals(listOf("through", "n_1_5", "km_few", "turn_right"), ids(1_500.0))
        assertEquals(listOf("through", "n_2", "km_few", "turn_right"), ids(2_000.0))
        assertEquals(listOf("through", "n_2_5", "km_few", "turn_right"), ids(2_500.0))
        assertEquals(listOf("through", "n_5", "km", "turn_right"), ids(5_000.0))
        assertEquals("Через полтора километра поверните направо",
            VoiceComposer.composedText(VoicePhrase.maneuver(ManeuverType.RIGHT, 1_500.0), ru))
        assertEquals("Через четыре километра поверните налево",
            VoiceComposer.composedText(VoicePhrase.maneuver(ManeuverType.LEFT, 4_000.0), ru))
        assertEquals(listOf("n_20", "meters"), VoiceComposer.meterIDs(21, ru))
        assertEquals(listOf("n_5", "meters"), VoiceComposer.meterIDs(1, ru))
    }

    @Test fun maneuverEnglish() {
        assertEquals(listOf("in", "n_300", "meters", "turn_right"),
            VoiceComposer.clipIDs(VoicePhrase.maneuver(ManeuverType.RIGHT, 287.0), en))
        assertEquals(listOf("in", "n_1", "km_one", "uturn"),
            VoiceComposer.clipIDs(VoicePhrase.maneuver(ManeuverType.U_TURN, 1_000.0), en))
        assertEquals("In two and a half kilometres keep left",
            VoiceComposer.composedText(VoicePhrase.maneuver(ManeuverType.KEEP_LEFT, 2_500.0), en))
    }

    @Test fun closeManeuverWithCautionAndSlowDown() {
        val phrase = VoicePhrase.maneuver(ManeuverType.ROUNDABOUT, 100.0, roundaboutExit = 2, caution = true, slowDown = true)
        assertEquals(listOf(VoiceSegment.Clip("n_100"), VoiceSegment.Clip("after_meters"), VoiceSegment.Clip("roundabout_exit_2"),
            VoiceSegment.Pause, VoiceSegment.Clip("be_careful"), VoiceSegment.Pause, VoiceSegment.Clip("slow_down")),
            VoiceComposer.segments(phrase, uz))
        assertEquals("Yuz metrdan keyin aylanma harakatda ikkinchi chiqishdan chiqing, ehtiyot bo‘ling, tezlikni pasaytiring",
            VoiceComposer.composedText(phrase, uz))
        val near = VoicePhrase.maneuver(ManeuverType.LEFT, null, caution = true)
        assertEquals(listOf("turn_left", "be_careful"), VoiceComposer.clipIDs(near, ru))
    }

    @Test fun unknownManeuverAndFarDistanceFallBack() {
        val unknown = VoicePhrase.maneuver(ManeuverType.UNKNOWN, 300.0, text = "Следуйте по Навои")
        assertNull(VoiceComposer.clipIDs(unknown, ru))
        assertEquals("Следуйте по Навои", VoiceComposer.text(unknown, ru))
        assertNull(VoiceComposer.clipIDs(VoicePhrase.maneuver(ManeuverType.RIGHT, 25_000.0), uz))
    }

    @Test fun coachPhrases() {
        assertEquals(listOf("speed_limit", "n_60", "km"), VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.SpeedLimit(60)), uz))
        assertEquals("Tezlik chegarasi soatiga oltmish kilometr",
            VoiceComposer.composedText(VoicePhrase.coach(CoachMessage.SpeedLimit(60)), uz))
        assertEquals(listOf("speeding", "n_110", "kmh"), VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.OverSpeedLimit(110)), ru))
        assertEquals("Снизьте скорость, ограничение сто десять километров в час",
            VoiceComposer.composedText(VoicePhrase.coach(CoachMessage.OverSpeedLimit(110)), ru))
        assertNull(VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.SpeedLimit(47)), en))
        assertEquals(listOf("n_300", "after_meters", "sign_traffic_signals"),
            VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.RoadSign(RouteFeatureKind.TRAFFIC_SIGNALS, 300)), uz))
        assertEquals(listOf("in", "n_500", "meters", "speed_limit", "n_40", "kmh"),
            VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.SpeedLimitAhead(40, 500)), en))
        assertEquals(listOf("keep_distance_at_least", "n_25", "meters"),
            VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.KeepDistance(23)), uz))
        assertEquals(listOf("keep_distance"), VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.KeepDistance(null)), en))
        assertEquals(listOf("pedestrian_yield"), VoiceComposer.clipIDs(VoicePhrase.coach(CoachMessage.PedestrianDanger(3)), uz))
    }

    @Test fun incidentAndSample() {
        assertEquals(listOf("incident_jam", "through", "n_600", "meters"),
            VoiceComposer.clipIDs(VoicePhrase.incident(RoadIncidentKind.JAM, 580.0), ru))
        assertEquals("own camera marks sound like OSM cameras", listOf("speed_camera_ahead"),
            VoiceComposer.clipIDs(VoicePhrase.incident(RoadIncidentKind.SPEED_CAMERA, null), uz))
        assertEquals("Oldinda tirbandlik, olti yuz metrdan keyin",
            VoiceComposer.composedText(VoicePhrase.incident(RoadIncidentKind.JAM, 580.0), uz))
        assertEquals("In three hundred metres turn right, traffic light ahead", VoiceComposer.composedText(VoicePhrase.sample(), en))
    }

    @Test fun roundaboutExitParsing() {
        assertEquals(2, VoiceComposer.roundaboutExit("Aylanma harakatda 2-chiqishdan chiqing"))
        assertEquals(3, VoiceComposer.roundaboutExit("На круговом движении — 3-й съезд"))
        assertEquals(1, VoiceComposer.roundaboutExit("At the roundabout, take the 1st exit onto Navoiy"))
        assertEquals(2, VoiceComposer.roundaboutExit("На круговом движении сверните на второй съезд"))
        assertEquals(4, VoiceComposer.roundaboutExit("At the roundabout, take the fourth exit"))
        assertNull(VoiceComposer.roundaboutExit("Enter the roundabout"))
    }

    @Test fun numberWords() {
        assertEquals("yuz yigirma besh", VoiceClipCatalog.uzbekNumber(125))
        assertEquals("qirq", VoiceClipCatalog.uzbekNumber(40))
        assertEquals("uch yuz", VoiceClipCatalog.uzbekNumber(300))
        assertEquals("сто пятнадцать", VoiceClipCatalog.russianNumber(115))
        assertEquals("двести пятьдесят", VoiceClipCatalog.russianNumber(250))
        assertEquals("one hundred twenty-five", VoiceClipCatalog.englishNumber(125))
        assertEquals("nine hundred", VoiceClipCatalog.englishNumber(900))
    }

    /** Every phrase the app can build resolves to clips that exist in each language. */
    @Test fun allBuildablePhrasesHaveClips() {
        val phrases = mutableListOf(VoicePhrase.sample(), VoicePhrase.fixed("arrived"), VoicePhrase.fixed("rerouting"),
            VoicePhrase.fixed("route_ready"), VoicePhrase.fixed("collision_alert"), VoicePhrase.fixed("keep_distance"))
        val distances = listOf(40.0, 287.0, 777.0, 1_000.0, 1_600.0, 2_400.0, 6_000.0, 10_000.0)
        for (type in ManeuverType.entries) {
            if (type == ManeuverType.UNKNOWN) continue
            for (distance in distances) {
                phrases.add(VoicePhrase.maneuver(type, distance, roundaboutExit = 3, caution = true, slowDown = true))
            }
        }
        for (kind in RouteFeatureKind.entries) {
            if (VoicePhrase.hazardClipID(kind) != null) phrases.add(VoicePhrase.hazard(kind))
            phrases.add(VoicePhrase.coach(CoachMessage.RoadSign(kind, 350)))
        }
        for (kind in RoadIncidentKind.entries) phrases.add(VoicePhrase.incident(kind, 450.0))
        for (kmh in 5..130 step 5) {
            phrases += listOf(VoicePhrase.coach(CoachMessage.SpeedLimit(kmh)), VoicePhrase.coach(CoachMessage.OverSpeedLimit(kmh)),
                VoicePhrase.coach(CoachMessage.SpeedLimitAhead(kmh, 200)))
        }
        for (meters in listOf(3, 12, 37, 58, 90, 131, 480)) phrases.add(VoicePhrase.coach(CoachMessage.KeepDistance(meters)))
        phrases += listOf(CoachMessage.CollisionRisk, CoachMessage.PedestrianCaution(1), CoachMessage.RedLightAhead,
            CoachMessage.LaneDeparture(LaneSide.LEFT), CoachMessage.LaneDeparture(LaneSide.RIGHT),
            CoachMessage.StopSignAhead, CoachMessage.GreenLightGo, CoachMessage.KeepDistance(null)).map { VoicePhrase.coach(it) }
        for (language in RVLang.entries) {
            val recorded = VoiceClipCatalog.clipIDs(language).toSet()
            for (phrase in phrases) {
                val ids = VoiceComposer.clipIDs(phrase, language) ?: return fail("$phrase not expressible in $language")
                for (id in ids) assertTrue("${language}_$id missing", id in recorded)
                assertFalse(VoiceComposer.text(phrase, language).isEmpty())
            }
        }
    }

    @Test fun catalogIDsUniqueAndUzbekApostrophes() {
        val ids = VoiceClipCatalog.entries.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        for (entry in VoiceClipCatalog.entries) {
            assertTrue(entry.id, entry.id.all { it.code < 128 && (it.isLetter() || it.isDigit() || it == '_') })
            val u = entry.uz
            if (u != null) assertFalse(u, u.contains("o'") || u.contains("g'"))
        }
    }

    /** `RoadVis/tools/voice_phrases.json` (exported by the iOS package) must match the catalog. */
    @Test fun manifestInSync() {
        val file = listOf(File("../../RoadVis/tools/voice_phrases.json"), File("../RoadVis/tools/voice_phrases.json"))
            .firstOrNull { it.exists() }
        assumeTrue("voice_phrases.json not found", file != null)
        val onDisk = JSONObject(file!!.readText(Charsets.UTF_8))
        val catalog = VoiceClipCatalog.manifestJSON()
        assertTrue("tools/voice_phrases.json is out of date", onDisk.similar(catalog))
    }
}

class AudioSilenceTrimmerTest {
    @Test fun trimsLeadingAndTrailingSilenceWithPadding() {
        val rate = 24_000.0
        val samples = FloatArray(9_600) { 0.0008f } +
            FloatArray(12_000) { (0.3 * Math.sin(it * 0.1)).toFloat() + 0.02f } +
            FloatArray(14_400) { -0.0005f }
        val range = AudioSilenceTrimmer.audibleRange(samples, rate)
        assertEquals(9_600 - 720, range.first)
        assertEquals(9_600 + 12_000 + 720, range.last + 1)
    }

    @Test fun silentClipKeepsShortPieceAndBoundsAreClamped() {
        assertEquals(0 until 720, AudioSilenceTrimmer.audibleRange(FloatArray(5_000), 24_000.0))
        assertEquals(0 until 100, AudioSilenceTrimmer.audibleRange(FloatArray(100) { 0.5f }, 24_000.0))
        assertEquals(0.01f, AudioSilenceTrimmer.amplitude(-40.0), 1e-6f)
    }

    @Test fun voiceRateClamp() {
        assertEquals(1.1, AudioSilenceTrimmer.clampedVoiceRate(null), 0.0)
        assertEquals(1.4, AudioSilenceTrimmer.clampedVoiceRate(2.0), 0.0)
        assertEquals(0.9, AudioSilenceTrimmer.clampedVoiceRate(0.5), 0.0)
        assertEquals(1.2, AudioSilenceTrimmer.clampedVoiceRate(1.2), 0.0)
    }
}
