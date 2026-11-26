package uz.roadvis.app.app

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.LocalizationManager
import java.util.Locale
import uz.roadvis.core.RVLang
import uz.roadvis.core.SoundMode
import uz.roadvis.core.VoiceComposer
import uz.roadvis.core.VoicePhrase

enum class SpeechPriority { LOW, NORMAL, HIGH }

/** How a language is voiced on this device. */
enum class SpeechVoiceKind { NATURAL_CLIPS, NATIVE, APPROXIMATE_TURKISH, APPROXIMATE_RUSSIAN, SYSTEM_DEFAULT }

/**
 * Voice output: natural Edge-voice clips when installed for the phrase, otherwise Android TextToSpeech in the
 * app language (Uzbek → uz if the engine has it, else Turkish, else Russian). Mute state is derived from the
 * persisted sound mode ("rv.soundMode"). Higher-priority speech interrupts lower; equal/lower priority waits (dropped if stale).
 * Port of iOS `SpeechService`.
 */
class SpeechService(context: Context, private val settings: AppSettings) {
    val clips = ClipVoicePlayer(context)
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var currentPriority = SpeechPriority.LOW
    private var pendingText: String? = null

    var isSpeaking by mutableStateOf(false)
        private set

    var isMuted: Boolean
        get() = settings.voiceMuted
        set(value) {
            settings.voiceMuted = value
            if (value) stop()
        }

    /** Sound mode of the speaker-button menu; a mode without voice stops the current speech at once. */
    var soundMode: SoundMode
        get() = settings.soundMode
        set(value) {
            settings.soundMode = value
            if (!value.voiceEnabled) stop()
        }

    val language: AppLanguage get() = LocalizationManager.language

    init {
        tts = TextToSpeech(context.applicationContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) {
                tts?.setSpeechRate(1.05f)
                applyLanguage()
                pendingText?.let { pendingText = null; speak(it) }
            }
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String?) { isSpeaking = true }
            override fun onDone(id: String?) { finishIfIdle() }
            @Deprecated("Deprecated in Java") override fun onError(id: String?) { finishIfIdle() }
        })
        clips.onFinished = { finishIfIdle() }
        LocalizationManager.addListener { applyLanguage() }
    }

    private fun finishIfIdle() {
        if (tts?.isSpeaking != true && !clips.isPlaying) {
            isSpeaking = false
            currentPriority = SpeechPriority.LOW
        }
    }

    private val busy: Boolean get() = (tts?.isSpeaking == true) || clips.isPlaying

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

    private fun allowed(priority: SpeechPriority): Boolean {
        if (isMuted) return false
        if (busy && priority <= currentPriority) return false
        if (busy) stop()
        currentPriority = priority
        return true
    }

    /**
     * Speaks a phrase: plays [clipNames] (e.g. "uz_turn_left") gaplessly when all are installed,
     * else speaks [text] with TTS.
     */
    fun speak(text: String, priority: SpeechPriority = SpeechPriority.NORMAL, clipNames: List<String>? = null) {
        if (!allowed(priority)) return
        if (clipNames != null && clips.play(clipNames, interrupt = true)) {
            isSpeaking = true
            return
        }
        val t = tts
        if (t == null || !ttsReady) { pendingText = text; return }
        isSpeaking = true
        t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "rv-${System.nanoTime()}")
    }

    /** Speaks a composed phrase: natural clips in the app language when installed, else TTS of its text. */
    fun speak(phrase: VoicePhrase, priority: SpeechPriority = SpeechPriority.NORMAL) {
        val lang = RVLang.fromRaw(language.raw) ?: RVLang.UZ
        speak(VoiceComposer.text(phrase, lang), priority, VoiceComposer.resourceNames(phrase, lang))
    }

    fun stop() {
        tts?.stop()
        clips.stop()
        isSpeaking = false
        currentPriority = SpeechPriority.LOW
    }

    fun shutdown() { stop(); tts?.shutdown(); tts = null }
}
