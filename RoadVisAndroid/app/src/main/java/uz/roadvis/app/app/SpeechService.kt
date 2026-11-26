package uz.roadvis.app.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.LocalizationManager
import java.util.Locale
import uz.roadvis.core.AlertToneKind
import uz.roadvis.core.PendingSpeechQueue
import uz.roadvis.core.RVLang
import uz.roadvis.core.SpeechAdmission
import uz.roadvis.core.SoundMode
import uz.roadvis.core.VoiceComposer
import uz.roadvis.core.VoicePhrase

/**
 * Priority of a spoken prompt — the core type (LOW / NORMAL / HIGH / CRITICAL), see [uz.roadvis.core.SpeechAdmission].
 */
typealias SpeechPriority = uz.roadvis.core.SpeechPriority

/** How a language is voiced on this device. */
enum class SpeechVoiceKind { NATURAL_CLIPS, NATIVE, APPROXIMATE_TURKISH, APPROXIMATE_RUSSIAN, SYSTEM_DEFAULT }

/**
 * Voice output: natural Edge-voice clips when installed for the phrase, otherwise Android TextToSpeech in the
 * app language (Uzbek → uz if the engine has it, else Turkish, else Russian). Port of iOS `SpeechService`.
 *
 * The persisted sound mode ("rv.soundMode": all / sounds only / voice only / silent) is the single source of truth:
 * [isMuted] is derived from it (voice off), alert tones ([playAlertTone]) follow its tone flag.
 *
 * Queueing ([SpeechAdmission]): CRITICAL (safety) interrupts everything, HIGH (navigation) interrupts everything
 * except a CRITICAL utterance, NORMAL waits in a small expiring queue (`maxAge`), LOW is dropped while speaking.
 * A clip phrase that cannot be decoded / played is said with TTS instead of being dropped.
 * All state is confined to the main thread (calls from other threads are re-posted).
 */
class SpeechService(context: Context, private val settings: AppSettings) {
    private class Utterance(val text: String, val clipNames: List<String>?, val priority: SpeechPriority)

    val clips = ClipVoicePlayer(context)
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var currentPriority = SpeechPriority.LOW
    private val pending = PendingSpeechQueue<Utterance>(3)
    /** Utterance waiting for the TTS engine to finish initializing, with its deadline (uptime seconds). */
    private var awaitingEngine: Pair<Utterance, Double>? = null
    /** Id of the TTS utterance being spoken and when it was handed to the engine (uptime seconds). */
    private var ttsActiveId: String? = null
    private var ttsStartedAt = 0.0
    /** Identifies the current clip request: a late callback of a replaced request is ignored. */
    private var clipToken = 0
    private var clipActive = false
    private val toneTracks = HashMap<AlertToneKind, AudioTrack>()
    private var activeTone: AudioTrack? = null
    private var fallbackTone: ToneGenerator? = null

    var isSpeaking by mutableStateOf(false)
        private set

    /** Voice prompts off (derived from the sound mode; setting it keeps the tone half of the mode). */
    var isMuted: Boolean
        get() = settings.voiceMuted
        set(value) { soundMode = settings.soundMode.withVoice(!value) }

    /**
     * Sound mode of the speaker-button menu. A mode without voice stops the current speech at once, a mode without
     * tones stops the current tone.
     */
    var soundMode: SoundMode
        get() = settings.soundMode
        set(value) {
            settings.soundMode = value
            if (!value.voiceEnabled) stop()
            if (!value.tonesEnabled) stopTone()
        }

    val language: AppLanguage get() = LocalizationManager.language

    init {
        tts = TextToSpeech(context.applicationContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                tts?.setSpeechRate(1.05f)
                applyLanguage()
                val waiting = awaitingEngine
                awaitingEngine = null
                if (waiting != null && !isMuted && !isVoiceBusy && waiting.second >= now()) {
                    currentPriority = waiting.first.priority
                    startTts(waiting.first)
                }
            }
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) {}
            override fun onDone(id: String?) { main.post { ttsEnded(id) } }
            @Deprecated("Deprecated in Java") override fun onError(id: String?) { main.post { ttsEnded(id) } }
            override fun onError(id: String?, errorCode: Int) { main.post { ttsEnded(id) } }
        })
        LocalizationManager.addListener { applyLanguage() }
    }

    private fun now(): Double = SystemClock.elapsedRealtime() / 1000.0

    /**
     * TTS or the clips are speaking (alert tones do not count: speech never waits for a tone). A TTS utterance whose
     * end callback never arrived stops counting once the engine reports it is silent, so the service cannot get stuck.
     */
    private val isVoiceBusy: Boolean
        get() {
            if (clipActive && clips.isPlaying) return true
            if (ttsActiveId == null) return false
            return now() - ttsStartedAt < TTS_START_GRACE || tts?.isSpeaking == true
        }

    private fun ttsEnded(id: String?) {
        if (id == null || id != ttsActiveId) return   // flushed / replaced utterance
        ttsActiveId = null
        drainPending()
    }

    /** Starts the oldest waiting utterance that has not expired, or marks the service idle. */
    private fun drainPending() {
        if (isVoiceBusy) return
        val next = if (isMuted) null else pending.next(now())
        if (next == null) {
            if (isMuted) pending.removeAll()
            isSpeaking = false
            currentPriority = SpeechPriority.LOW
            return
        }
        currentPriority = next.priority
        start(next)
    }

    var voiceKind: SpeechVoiceKind = SpeechVoiceKind.SYSTEM_DEFAULT
        private set

    private fun applyLanguage() {
        val t = tts ?: return
        if (!ttsReady) return
        val lang = language
        fun ok(l: Locale) = t.isLanguageAvailable(l) >= TextToSpeech.LANG_AVAILABLE
        voiceKind = when (lang) {
            AppLanguage.UZ -> when {
                ok(Locale.forLanguageTag("uz-UZ")) -> { t.language = Locale.forLanguageTag("uz-UZ"); SpeechVoiceKind.NATIVE }
                ok(Locale.forLanguageTag("tr-TR")) -> { t.language = Locale.forLanguageTag("tr-TR"); SpeechVoiceKind.APPROXIMATE_TURKISH }
                ok(Locale.forLanguageTag("ru-RU")) -> { t.language = Locale.forLanguageTag("ru-RU"); SpeechVoiceKind.APPROXIMATE_RUSSIAN }
                else -> SpeechVoiceKind.SYSTEM_DEFAULT
            }
            else -> {
                val l = Locale.forLanguageTag(lang.voiceLanguageCode)
                if (ok(l)) { t.language = l; SpeechVoiceKind.NATIVE } else SpeechVoiceKind.SYSTEM_DEFAULT
            }
        }
    }

    /** Stops TTS and the clips and forgets everything waiting (an urgent utterance follows). */
    private fun interruptAll() {
        pending.removeAll()
        awaitingEngine = null
        clipToken++
        clipActive = false
        ttsActiveId = null
        tts?.stop()
        clips.stop()
    }

    private fun start(utterance: Utterance) {
        val names = utterance.clipNames
        if (names != null) {
            val token = ++clipToken
            val started = clips.play(names, interrupt = true) { played ->
                main.post { clipEnded(token, played, utterance) }
            }
            if (started) {
                ttsActiveId = null
                clipActive = true
                isSpeaking = true
                return
            }
        }
        startTts(utterance)
    }

    private fun clipEnded(token: Int, played: Boolean, utterance: Utterance) {
        if (token != clipToken) return   // interrupted / replaced meanwhile
        clipActive = false
        if (!played && !isMuted && utterance.text.isNotBlank() && !isVoiceBusy) {
            // Clip undecodable / audio track failed: say the phrase with TTS instead of dropping it.
            startTts(utterance)
            return
        }
        drainPending()
    }

    private fun startTts(utterance: Utterance) {
        val t = tts
        if (t == null || !ttsReady) {
            // Engine still initializing: keep the newest phrase for a few seconds (dropped if init fails).
            awaitingEngine = utterance to (now() + DEFAULT_MAX_AGE)
            isSpeaking = false
            currentPriority = SpeechPriority.LOW
            return
        }
        val id = "rv-${System.nanoTime()}"
        if (t.speak(utterance.text, TextToSpeech.QUEUE_FLUSH, null, id) == TextToSpeech.SUCCESS) {
            ttsActiveId = id
            ttsStartedAt = now()
            isSpeaking = true
        } else {
            ttsActiveId = null
            drainPending()
        }
    }

    /**
     * Speaks a phrase: plays [clipNames] (e.g. "uz_turn_left") gaplessly when all are installed, else speaks [text]
     * with TTS (also when a clip turns out to be unplayable).
     * - CRITICAL (safety warning) interrupts whatever is being spoken and drops everything waiting;
     * - HIGH does the same unless a CRITICAL utterance is being spoken — then it waits for it;
     * - NORMAL waits for the current utterance, at most [maxAge] seconds (then it is dropped as stale);
     * - LOW is dropped while something else is speaking.
     */
    fun speak(text: String, priority: SpeechPriority = SpeechPriority.NORMAL, clipNames: List<String>? = null,
              maxAge: Double = DEFAULT_MAX_AGE) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { speak(text, priority, clipNames, maxAge) }
            return
        }
        if (isMuted || (text.isBlank() && clipNames.isNullOrEmpty())) return
        val utterance = Utterance(text, clipNames?.takeIf { it.isNotEmpty() }, priority)
        when (SpeechAdmission.decide(priority, currentPriority, isVoiceBusy)) {
            SpeechAdmission.START -> {
                currentPriority = priority
                start(utterance)
            }
            SpeechAdmission.INTERRUPT -> {
                interruptAll()
                currentPriority = priority
                start(utterance)
            }
            SpeechAdmission.ENQUEUE -> pending.enqueue(utterance, now() + maxOf(0.0, maxAge))
            SpeechAdmission.DROP -> {}
        }
    }

    /** Speaks a composed phrase: natural clips in the app language when installed, else TTS of its text. */
    fun speak(phrase: VoicePhrase, priority: SpeechPriority = SpeechPriority.NORMAL, maxAge: Double = DEFAULT_MAX_AGE) {
        val lang = RVLang.fromRaw(language.raw) ?: RVLang.UZ
        speak(VoiceComposer.text(phrase, lang), priority, VoiceComposer.resourceNames(phrase, lang), maxAge)
    }

    fun stop() {
        interruptAll()
        isSpeaking = false
        currentPriority = SpeechPriority.LOW
    }

    // Alert tones

    /**
     * Plays the short alert tone of [kind] when the sound mode allows it ([AlertToneKind.shouldPlay]); independent of
     * [isMuted]. Safety-critical tones use the alarm stream (as the collision beep always did: audible with the media
     * volume down), the others the navigation-guidance stream like the voice. Returns false when no tone was started.
     */
    fun playAlertTone(kind: AlertToneKind): Boolean {
        if (!kind.shouldPlay(settings.soundMode)) return false
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { playAlertTone(kind) }
            return true
        }
        try {
            val track = toneTracks[kind] ?: buildToneTrack(kind).also { toneTracks[kind] = it }
            activeTone?.let { if (it !== track && it.playState == AudioTrack.PLAYSTATE_PLAYING) it.pause() }
            if (track.playState != AudioTrack.PLAYSTATE_STOPPED) track.stop()
            track.reloadStaticData()
            track.play()
            activeTone = track
            return true
        } catch (_: Exception) {
            toneTracks.remove(kind)?.let { runCatching { it.release() } }
        }
        // Synthesized tone unavailable: plain system beep for the critical warnings.
        if (!kind.isCritical) return false
        return try {
            val t = fallbackTone ?: ToneGenerator(AudioManager.STREAM_ALARM, 85).also { fallbackTone = it }
            t.startTone(ToneGenerator.TONE_PROP_BEEP2, 220)
        } catch (_: RuntimeException) {
            fallbackTone = null
            false
        }
    }

    private fun buildToneTrack(kind: AlertToneKind): AudioTrack {
        val samples = kind.samples(TONE_SAMPLE_RATE)
        val usage = if (kind.isCritical) AudioAttributes.USAGE_ALARM else AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(TONE_SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        if (track.write(samples, 0, samples.size) != samples.size) {
            track.release()
            throw IllegalStateException("tone buffer not written")
        }
        return track
    }

    private fun stopTone() {
        activeTone?.let { runCatching { if (it.playState == AudioTrack.PLAYSTATE_PLAYING) it.pause() } }
        activeTone = null
        runCatching { fallbackTone?.stopTone() }
    }

    fun shutdown() {
        stop()
        tts?.shutdown(); tts = null
        stopTone()
        toneTracks.values.forEach { runCatching { it.release() } }
        toneTracks.clear()
        fallbackTone?.release(); fallbackTone = null
    }

    companion object {
        /** Default time an utterance may wait before it is no longer worth saying, seconds. */
        const val DEFAULT_MAX_AGE = 8.0
        /** After handing text to the engine, `isSpeaking` may lag: treat it as speaking for this long, seconds. */
        private const val TTS_START_GRACE = 1.0
        private const val TONE_SAMPLE_RATE = 44_100
    }
}
