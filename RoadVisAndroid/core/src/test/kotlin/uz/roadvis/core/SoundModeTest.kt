package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Port of the SoundMode part of SoundModeTests.swift.
class SoundModeTest {
    @Test
    fun modeFlags() {
        assertEquals(4, SoundMode.entries.size)
        assertTrue(SoundMode.ALL.voiceEnabled && SoundMode.ALL.tonesEnabled)
        assertTrue(!SoundMode.SOUNDS_ONLY.voiceEnabled && SoundMode.SOUNDS_ONLY.tonesEnabled)
        assertTrue(SoundMode.VOICE_ONLY.voiceEnabled && !SoundMode.VOICE_ONLY.tonesEnabled)
        assertFalse(SoundMode.SILENT.voiceEnabled || SoundMode.SILENT.tonesEnabled)
        for (mode in SoundMode.entries) {
            assertEquals(mode, SoundMode.of(mode.voiceEnabled, mode.tonesEnabled))
            assertEquals(mode, SoundMode.fromRaw(mode.raw))
            assertEquals("sound.mode.${mode.raw}", mode.titleKey)
        }
        assertNull(SoundMode.fromRaw("bogus"))
    }

    @Test
    fun settingsTogglesWriteThrough() {
        assertEquals(SoundMode.SOUNDS_ONLY, SoundMode.ALL.withVoice(false))
        assertEquals(SoundMode.VOICE_ONLY, SoundMode.ALL.withTones(false))
        assertEquals(SoundMode.SILENT, SoundMode.SOUNDS_ONLY.withTones(false))
        assertEquals(SoundMode.VOICE_ONLY, SoundMode.SILENT.withVoice(true))
        assertEquals(SoundMode.ALL, SoundMode.SILENT.withTones(true).withVoice(true))
    }

    @Test
    fun migrationFromLegacyFlags() {
        assertEquals(SoundMode.ALL, SoundMode.resolve(null, null, null))
        assertEquals(SoundMode.SOUNDS_ONLY, SoundMode.resolve(null, true, null))
        assertEquals(SoundMode.VOICE_ONLY, SoundMode.resolve(null, false, false))
        assertEquals(SoundMode.SILENT, SoundMode.resolve(null, true, false))
        assertEquals(SoundMode.VOICE_ONLY, SoundMode.resolve("voiceOnly", true, true))
        assertEquals(SoundMode.SOUNDS_ONLY, SoundMode.resolve("bogus", true, true))
        assertEquals("rv.soundMode", SoundMode.STORAGE_KEY)
    }

    @Test
    fun tonePolicyPerMode() {
        for (kind in AlertToneKind.entries) {
            assertFalse(kind.shouldPlay(SoundMode.SILENT))
            assertFalse(kind.shouldPlay(SoundMode.VOICE_ONLY))
            assertTrue("$kind must be audible in sounds-only mode", kind.shouldPlay(SoundMode.SOUNDS_ONLY))
            assertEquals(kind.isCritical, kind.shouldPlay(SoundMode.ALL))
        }
        assertTrue(AlertToneKind.COLLISION.isCritical && AlertToneKind.PEDESTRIAN.isCritical && AlertToneKind.RED_LIGHT.isCritical)
        assertFalse(AlertToneKind.LANE_DEPARTURE.isCritical || AlertToneKind.SPEEDING.isCritical || AlertToneKind.ATTENTION.isCritical)
    }

    @Test
    fun importantWarningsHaveATone() {
        assertEquals(AlertToneKind.COLLISION, AlertToneKind.kindFor(CoachMessage.CollisionRisk))
        assertEquals(AlertToneKind.PEDESTRIAN, AlertToneKind.kindFor(CoachMessage.PedestrianDanger(1)))
        assertEquals(AlertToneKind.RED_LIGHT, AlertToneKind.kindFor(CoachMessage.RedLightAhead))
        assertEquals(AlertToneKind.LANE_DEPARTURE, AlertToneKind.kindFor(CoachMessage.LaneDeparture(LaneSide.LEFT)))
        assertEquals(AlertToneKind.SPEEDING, AlertToneKind.kindFor(CoachMessage.OverSpeedLimit(60)))
        assertEquals(AlertToneKind.ATTENTION, AlertToneKind.kindFor(CoachMessage.KeepDistance(null)))
        assertEquals(AlertToneKind.ATTENTION, AlertToneKind.kindFor(CoachMessage.RoadWorkersAhead(2)))
        assertNull(AlertToneKind.kindFor(CoachMessage.GreenLightGo))
        assertNull(AlertToneKind.kindFor(CoachMessage.SpeedLimit(60)))
        // Every high-urgency coach message has a critical tone.
        for (message in listOf(CoachMessage.CollisionRisk, CoachMessage.PedestrianDanger(3), CoachMessage.RedLightAhead)) {
            assertEquals(CoachUrgency.HIGH, message.urgency)
            assertEquals(true, AlertToneKind.kindFor(message)?.isCritical)
        }
    }

    @Test
    fun tonesAreDistinctShortAndClickFree() {
        val patterns = HashSet<String>()
        for (kind in AlertToneKind.entries) {
            assertTrue(kind.durationSeconds > 0.1 && kind.durationSeconds <= 0.5)
            patterns.add(kind.segments.joinToString(",") { "${it.frequencyHz}:${it.seconds}" })
            val samples = kind.samples(44_100)
            assertEquals((kind.durationSeconds * 44_100), samples.size.toDouble(), kind.segments.size.toDouble())
            assertEquals(0, samples.first().toInt())
            assertTrue(Math.abs(samples.last().toInt()) < 400)
            val peak = samples.maxOf { Math.abs(it.toInt()) }
            assertTrue(peak > 20_000 && peak <= Short.MAX_VALUE)
        }
        assertEquals(AlertToneKind.entries.size, patterns.size)
    }

    @Test
    fun speechAdmission() {
        for (priority in SpeechPriority.entries) {
            assertEquals(SpeechAdmission.START, SpeechAdmission.decide(priority, SpeechPriority.CRITICAL, false))
        }
        assertEquals(SpeechAdmission.DROP, SpeechAdmission.decide(SpeechPriority.LOW, SpeechPriority.LOW, true))
        assertEquals(SpeechAdmission.ENQUEUE, SpeechAdmission.decide(SpeechPriority.NORMAL, SpeechPriority.LOW, true))
        assertEquals(SpeechAdmission.ENQUEUE, SpeechAdmission.decide(SpeechPriority.NORMAL, SpeechPriority.HIGH, true))
        assertEquals(SpeechAdmission.INTERRUPT, SpeechAdmission.decide(SpeechPriority.HIGH, SpeechPriority.NORMAL, true))
        assertEquals(SpeechAdmission.INTERRUPT, SpeechAdmission.decide(SpeechPriority.HIGH, SpeechPriority.HIGH, true))
        // A navigation prompt (HIGH) never cuts off a safety warning (CRITICAL): it waits.
        assertEquals(SpeechAdmission.ENQUEUE, SpeechAdmission.decide(SpeechPriority.HIGH, SpeechPriority.CRITICAL, true))
        assertEquals(SpeechAdmission.INTERRUPT, SpeechAdmission.decide(SpeechPriority.CRITICAL, SpeechPriority.CRITICAL, true))
        assertEquals(SpeechAdmission.INTERRUPT, SpeechAdmission.decide(SpeechPriority.CRITICAL, SpeechPriority.HIGH, true))
        assertTrue(SpeechPriority.HIGH < SpeechPriority.CRITICAL)
    }

    @Test
    fun pendingQueueExpiresAndIsBounded() {
        val queue = PendingSpeechQueue<String>(2)
        assertNull(queue.next(0.0))
        queue.enqueue("lane", 3.0)
        queue.enqueue("hazard", 8.0)
        assertEquals(2, queue.count)
        // Stale lane warning is skipped, the hazard is still valid.
        assertEquals("hazard", queue.next(5.0))
        assertTrue(queue.isEmpty)

        queue.enqueue("a", 10.0)
        queue.enqueue("b", 10.0)
        queue.enqueue("c", 10.0)   // capacity 2: the oldest is dropped
        assertEquals(2, queue.count)
        assertEquals("b", queue.next(1.0))
        assertEquals("c", queue.next(10.0))   // deadline is inclusive
        assertNull(queue.next(1.0))

        queue.enqueue("x", 1.0)
        assertNull(queue.next(2.0))
        queue.enqueue("y", 5.0)
        queue.removeAll()
        assertTrue(queue.isEmpty)
        assertEquals(1, PendingSpeechQueue<Int>(0).capacity)
    }
}
