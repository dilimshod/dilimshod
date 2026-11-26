package uz.roadvis.core

/**
 * What the app may play: spoken prompts ("voice") and short alert tones ("sounds"). One persisted value
 * ("rv.soundMode") is the source of truth; the older flags "rv.voiceMuted" / "rv.alertSounds" are derived from it.
 * Port of the iOS core `SoundMode` (same raw values).
 */
enum class SoundMode(val raw: String) {
    /** Alert tones and spoken prompts. */
    ALL("all"),
    /** Alert tones only, no voice. */
    SOUNDS_ONLY("soundsOnly"),
    /** Spoken prompts only, no tones. */
    VOICE_ONLY("voiceOnly"),
    /** Neither (haptics stay). */
    SILENT("silent");

    val voiceEnabled: Boolean get() = this == ALL || this == VOICE_ONLY
    val tonesEnabled: Boolean get() = this == ALL || this == SOUNDS_ONLY

    /** The same mode with spoken prompts switched on / off. */
    fun withVoice(enabled: Boolean): SoundMode = of(enabled, tonesEnabled)
    /** The same mode with alert tones switched on / off. */
    fun withTones(enabled: Boolean): SoundMode = of(voiceEnabled, enabled)

    /** Localization key of the mode name. */
    val titleKey: String get() = "sound.mode.$raw"

    companion object {
        const val STORAGE_KEY = "rv.soundMode"
        const val LEGACY_VOICE_MUTED_KEY = "rv.voiceMuted"
        const val LEGACY_ALERT_SOUNDS_KEY = "rv.alertSounds"

        fun of(voiceEnabled: Boolean, tonesEnabled: Boolean): SoundMode = when {
            voiceEnabled && tonesEnabled -> ALL
            tonesEnabled -> SOUNDS_ONLY
            voiceEnabled -> VOICE_ONLY
            else -> SILENT
        }

        fun fromRaw(raw: String?): SoundMode? = entries.firstOrNull { it.raw == raw }

        /**
         * Mode at first read: the stored raw value when valid, otherwise migrated from the legacy flags
         * (voiceMuted default false, alertSounds default true; null = never written).
         */
        fun resolve(stored: String?, legacyVoiceMuted: Boolean?, legacyAlertSounds: Boolean?): SoundMode =
            fromRaw(stored) ?: of(!(legacyVoiceMuted ?: false), legacyAlertSounds ?: true)
    }
}
