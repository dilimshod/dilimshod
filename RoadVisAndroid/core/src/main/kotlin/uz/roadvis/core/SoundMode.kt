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

/**
 * Short synthesized alert tones, one per kind of warning (port of the iOS core `AlertToneKind`, same patterns).
 * They are what is left of a warning in the "sounds only" mode.
 */
enum class AlertToneKind {
    /** Forward-collision warning. */
    COLLISION,
    /** Pedestrian in front of the car. */
    PEDESTRIAN,
    /** Red light ahead while still driving. */
    RED_LIGHT,
    /** Drifting over the lane marking. */
    LANE_DEPARTURE,
    /** Over the speed limit. */
    SPEEDING,
    /** Other spoken warnings (keep distance, pedestrian caution, officer / road workers, STOP sign). */
    ATTENTION;

    /** One piece of a tone: [frequencyHz] 0 = silence. */
    data class Segment(val frequencyHz: Double, val seconds: Double)

    /** Safety-critical tones accompany the voice; the others only replace it when the voice is off. */
    val isCritical: Boolean get() = this == COLLISION || this == PEDESTRIAN || this == RED_LIGHT

    /**
     * Whether the tone is played in [mode]: never without tones; critical tones always; the rest only when the
     * voice is off (so the "all" mode does not beep over every spoken hint).
     */
    fun shouldPlay(mode: SoundMode): Boolean = mode.tonesEnabled && (isCritical || !mode.voiceEnabled)

    val segments: List<Segment>
        get() = when (this) {
            COLLISION -> listOf(Segment(1760.0, 0.09), Segment(0.0, 0.05), Segment(1760.0, 0.09), Segment(0.0, 0.05), Segment(1760.0, 0.14))
            PEDESTRIAN -> listOf(Segment(1320.0, 0.12), Segment(0.0, 0.04), Segment(990.0, 0.18))
            RED_LIGHT -> listOf(Segment(880.0, 0.14), Segment(0.0, 0.08), Segment(880.0, 0.14))
            LANE_DEPARTURE -> listOf(Segment(520.0, 0.08), Segment(0.0, 0.04), Segment(520.0, 0.08), Segment(0.0, 0.04), Segment(520.0, 0.08))
            SPEEDING -> listOf(Segment(660.0, 0.12), Segment(0.0, 0.03), Segment(784.0, 0.18))
            ATTENTION -> listOf(Segment(1047.0, 0.16))
        }

    val durationSeconds: Double get() = segments.sumOf { it.seconds }

    /** 16-bit mono PCM samples of the tone: sine segments with a 5 ms fade in / out (no clicks). */
    fun samples(sampleRate: Int = 44_100, amplitude: Double = 0.7): ShortArray {
        val rate = maxOf(8_000, sampleRate).toDouble()
        val level = amplitude.coerceIn(0.0, 1.0) * Short.MAX_VALUE
        val counts = segments.map { maxOf(0, Math.round(it.seconds * rate).toInt()) }
        val result = ShortArray(counts.sum())
        var offset = 0
        for ((segment, count) in segments.zip(counts)) {
            if (segment.frequencyHz > 0) {
                val fade = maxOf(1, minOf(count / 2, (0.005 * rate).toInt()))
                val step = 2 * Math.PI * segment.frequencyHz / rate
                for (index in 0 until count) {
                    var gain = 1.0
                    if (index < fade) gain = index.toDouble() / fade
                    if (index >= count - fade) gain = minOf(gain, (count - 1 - index).toDouble() / fade)
                    result[offset + index] = Math.round(Math.sin(step * index) * level * gain).toInt().toShort()
                }
            }
            offset += count
        }
        return result
    }

    companion object {
        /** Tone of a coach message; null = informational message without a tone (signs, limit changes, green light). */
        fun kindFor(message: CoachMessage): AlertToneKind? = when (message) {
            CoachMessage.CollisionRisk -> COLLISION
            is CoachMessage.PedestrianDanger -> PEDESTRIAN
            CoachMessage.RedLightAhead -> RED_LIGHT
            is CoachMessage.LaneDeparture -> LANE_DEPARTURE
            is CoachMessage.OverSpeedLimit -> SPEEDING
            is CoachMessage.KeepDistance, is CoachMessage.PedestrianCaution, is CoachMessage.TrafficOfficerAhead,
            is CoachMessage.RoadWorkersAhead, CoachMessage.StopSignAhead -> ATTENTION
            is CoachMessage.RoadSign, is CoachMessage.SpeedLimit, is CoachMessage.SpeedLimitAhead, CoachMessage.GreenLightGo -> null
        }
    }
}

/**
 * Priority of a spoken prompt (enum order = priority order).
 * - LOW: dropped while anything is being spoken.
 * - NORMAL: waits (bounded, expiring queue) for the current utterance.
 * - HIGH: interrupts everything except a CRITICAL utterance (navigation manoeuvres).
 * - CRITICAL: safety warning (collision, pedestrian, red light) — interrupts everything.
 */
enum class SpeechPriority { LOW, NORMAL, HIGH, CRITICAL }

/** What to do with a new utterance while another one is being spoken. */
enum class SpeechAdmission {
    /** Nothing is speaking: start now. */
    START,
    /** Stop the current utterance and everything waiting, then start. */
    INTERRUPT,
    /** Wait for the current utterance (expires after its maximum age). */
    ENQUEUE,
    /** Forget it. */
    DROP;

    companion object {
        fun decide(priority: SpeechPriority, current: SpeechPriority, isBusy: Boolean): SpeechAdmission {
            if (!isBusy) return START
            return when (priority) {
                SpeechPriority.LOW -> DROP
                SpeechPriority.NORMAL -> ENQUEUE
                SpeechPriority.HIGH -> if (current < SpeechPriority.CRITICAL) INTERRUPT else ENQUEUE
                SpeechPriority.CRITICAL -> INTERRUPT
            }
        }
    }
}

/**
 * Small queue of utterances waiting for the current one: at most [capacity] items (the oldest is dropped), each
 * with a deadline after which it is no longer worth saying ("you are leaving the lane" 8 s late is wrong).
 */
class PendingSpeechQueue<Item>(capacity: Int = 3) {
    val capacity: Int = maxOf(1, capacity)
    private val items = ArrayDeque<Pair<Item, Double>>()

    val count: Int get() = items.size
    val isEmpty: Boolean get() = items.isEmpty()

    /** Adds [item], valid until [deadline] (same clock as [next]). */
    fun enqueue(item: Item, deadline: Double) {
        while (items.size >= capacity) items.removeFirst()
        items.addLast(item to deadline)
    }

    /** The oldest item that has not expired (removed from the queue together with the expired ones before it). */
    fun next(now: Double): Item? {
        while (items.isNotEmpty()) {
            val first = items.removeFirst()
            if (first.second >= now) return first.first
        }
        return null
    }

    fun removeAll() { items.clear() }
}
