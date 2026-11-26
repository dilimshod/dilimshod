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
}
