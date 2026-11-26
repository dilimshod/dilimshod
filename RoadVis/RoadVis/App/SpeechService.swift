import AVFoundation
import Foundation
import Observation

enum SpeechPriority: Int, Comparable {
    case low = 0, normal, high

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the current language is voiced (shown in Settings → Language).
enum SpeechVoiceKind: Equatable {
    /// A real voice for the language (ru-RU, en-US, or an installed "uz" voice).
    case native
    /// Uzbek read by a Turkish (tr-TR) voice after phonetic respelling — approximate.
    case approximateTurkish
    /// Uzbek transliterated to Cyrillic and read by a Russian voice — approximate (no Turkish voice installed).
    case approximateRussian
    /// No suitable voice: iOS picks its default voice — pronunciation may be wrong.
    case systemDefault

    var isApproximate: Bool { self != .native }
}

/// Text-to-speech for navigation prompts and driving warnings.
///
/// The speaking language follows the app language (`LocalizationManager.shared.language`, Settings → Language);
/// callers pass text that is already localized. Russian and English use a regular ru-RU / en-US Apple voice, the
/// best installed quality first (Premium > Enhanced > default; see `voice(for:)`).
///
/// Uzbek: iOS 17–26 do not include an Uzbek system voice (Uzbek is not in Apple's VoiceOver / Spoken Content
/// language list). Voice choice for `.uz`, in order:
/// 1. any installed voice whose language starts with "uz" (e.g. from a third-party Speech Synthesis Provider app);
/// 2. a Turkish voice reading `UzbekSpeechText.forTurkishVoice(text)` (approximate pronunciation);
/// 3. a Russian voice reading the Cyrillic transliteration `UzbekSpeechText.forRussianVoice(text)` (approximate).
/// Mostly-Cyrillic text (e.g. Apple Maps instructions in a Russian system language) is spoken with the Russian voice;
/// single Cyrillic words inside a localized phrase (OSM street names) are transliterated to Latin for the uz / en voice.
///
/// Natural voice: when pre-recorded Microsoft Edge neural clips are bundled (`ClipVoicePlayer`, generated on a Mac by
/// `tools/generate_voice_clips.py`), `speak(_ phrase: VoicePhrase, …)` plays the phrase from clips; phrases that need
/// a missing clip (or street names) are spoken by the system voice as before.
///
/// The audio session ducks other audio only while speaking and is deactivated after the last utterance / clip.
@Observable
@MainActor
final class SpeechService: NSObject {
    private(set) var isSpeaking = false
    /// Global mute for all speech output (voice prompts and the driver coach). Persisted; toggled by the 🔊 button.
    var isMuted = UserDefaults.standard.bool(forKey: "rv.voiceMuted") {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "rv.voiceMuted")
            if isMuted { stop() }
        }
    }

    /// Language of the spoken prompts. Mirrors the app language: reading it returns
    /// `LocalizationManager.shared.language`, setting it changes the app language too (UI and voice stay in sync).
    var language: AppLanguage {
        get { LocalizationManager.shared.language }
        set { LocalizationManager.shared.language = newValue }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentPriority: SpeechPriority = .low
    @ObservationIgnored private var voiceCache: [AppLanguage: VoiceChoice] = [:]
    @ObservationIgnored private var cachedRussianVoice: AVSpeechSynthesisVoice?
    @ObservationIgnored private let clips = ClipVoicePlayer()
    /// Clip phrases waiting for the system voice to finish (normal priority).
    @ObservationIgnored private var deferredClips: [[URL]] = []
    /// System-voice texts waiting for the clip queue to finish (normal priority).
    @ObservationIgnored private var deferredTexts: [String] = []

    /// Use the bundled natural-voice clips when they cover a phrase (Settings → Language; default on).
    var useNaturalVoice: Bool = ClipVoicePlayer.isEnabled {
        didSet { ClipVoicePlayer.isEnabled = useNaturalVoice }
    }

    /// Voice speed factor 0.9…1.4 (Settings → Language, persisted "rv.voiceRate", default 1.1): time-stretch of the
    /// natural-voice clips and a multiplier of the system voice's default rate.
    var voiceRate: Double = ClipVoicePlayer.voiceRate {
        didSet {
            let clamped = AudioSilenceTrimmer.clampedVoiceRate(voiceRate)
            ClipVoicePlayer.voiceRate = clamped
            clips.rate = clamped
        }
    }

    /// System-voice utterance rate for `factor` × the default rate, clamped to the API range.
    nonisolated static func utteranceRate(factor: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(AudioSilenceTrimmer.clampedVoiceRate(factor))
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
    }

    private struct VoiceChoice {
        let voice: AVSpeechSynthesisVoice?
        let kind: SpeechVoiceKind
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        clips.onFinish = { [weak self] in self?.didFinishClips() }
        clips.rate = voiceRate
        // Voices can be downloaded while the app runs (Settings → Accessibility → Spoken Content → Voices).
        NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearVoiceCache() }
        }
    }

    /// Speaks a structured phrase in the current `language`: from the bundled natural-voice clips when all of them
    /// exist, otherwise its localized text (`phrase.text` or the text composed from the clip texts) with the system
    /// voice. Same priorities as `speak(_ text:)`: `.high` interrupts, `.low` is dropped while something is speaking,
    /// `.normal` waits for the current utterance.
    func speak(_ phrase: VoicePhrase, priority: SpeechPriority = .normal) {
        guard !isMuted else { return }
        let lang = language
        guard useNaturalVoice, let urls = clips.urls(for: phrase, language: lang) else {
            speak(VoiceComposer.text(for: phrase, language: lang.core), priority: priority)
            return
        }
        if isBusy {
            if priority == .low { return }
            if priority == .high { interruptAll() }
        }
        currentPriority = priority
        if synthesizer.isSpeaking {
            // Normal priority while the system voice talks: play right after it.
            deferredClips.append(urls)
            return
        }
        activatePlaybackSession()
        clips.play(urls, interrupt: false)
        isSpeaking = true
    }

    /// Number of bundled natural-voice clips for `language` and the number the catalog defines.
    func naturalVoiceClipCount(for language: AppLanguage? = nil) -> (installed: Int, total: Int) {
        ClipVoicePlayer.installedCount(for: language ?? self.language)
    }

    private var isBusy: Bool { synthesizer.isSpeaking || clips.isPlaying }

    /// Stops the system voice and the clips and forgets everything waiting (a `.high` utterance follows).
    private func interruptAll() {
        deferredClips.removeAll()
        deferredTexts.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        clips.stop()
    }

    /// Speaks already-localized `text` in the current `language`. A `.high` priority utterance interrupts whatever
    /// is being spoken; `.low` utterances are dropped while something else is speaking.
    func speak(_ text: String, priority: SpeechPriority = .normal) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMuted, !trimmed.isEmpty else { return }
        if clips.isPlaying {
            if priority == .low { return }
            if priority == .high {
                interruptAll()
            } else {
                // Normal priority while clips play: speak right after them.
                deferredTexts.append(trimmed)
                return
            }
        }
        if synthesizer.isSpeaking {
            if priority == .low { return }
            if priority >= currentPriority && priority == .high {
                synthesizer.stopSpeaking(at: .word)
            }
        }
        let (spokenText, voice) = prepared(trimmed)
        activatePlaybackSession()
        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(factor: voiceRate)
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        currentPriority = priority
        synthesizer.speak(utterance)
    }

    func stop() {
        deferredClips.removeAll()
        deferredTexts.removeAll()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        clips.stop()
    }

    // MARK: Voice selection

    /// How `language` is voiced on this device (for the note in Settings).
    func voiceKind(for language: AppLanguage? = nil) -> SpeechVoiceKind {
        choice(for: language ?? self.language).kind
    }

    /// Name and BCP-47 language of the voice used for `language`, e.g. ("Yelda", "tr-TR"); nil when iOS picks.
    func voiceDescription(for language: AppLanguage? = nil) -> (name: String, language: String)? {
        guard let voice = choice(for: language ?? self.language).voice else { return nil }
        return (voice.name, voice.language)
    }

    /// Quality of the voice used for `language` (`.default` = compact voice; nil when iOS picks).
    func voiceQuality(for language: AppLanguage? = nil) -> AVSpeechSynthesisVoiceQuality? {
        choice(for: language ?? self.language).voice?.quality
    }

    /// The voice for the current language (cached).
    func currentVoice() -> AVSpeechSynthesisVoice? {
        choice(for: language).voice
    }

    /// The Russian voice (cached). Kept for callers of the previous API; also used for Cyrillic text.
    func russianVoice() -> AVSpeechSynthesisVoice? {
        if let cachedRussianVoice { return cachedRussianVoice }
        let voice = Self.voice(for: AppLanguage.ru.voiceLanguageCode)
        cachedRussianVoice = voice
        return voice
    }

    func clearVoiceCache() {
        voiceCache.removeAll()
        cachedRussianVoice = nil
    }

    /// Text actually spoken and the voice to speak it with.
    private func prepared(_ original: String) -> (String, AVSpeechSynthesisVoice?) {
        let lang = language
        var text = original
        if lang != .ru, UzbekSpeechText.containsCyrillic(text) {
            // Russian sentences (not produced by RoadVis, e.g. Apple Maps steps) stay on the Russian voice.
            if UzbekSpeechText.isMostlyCyrillic(text) { return (text, russianVoice()) }
            // A localized phrase with a Cyrillic street name: read the name in Latin letters.
            text = UzbekSpeechText.latinizingCyrillic(text, english: lang == .en)
        }
        let selected = choice(for: lang)
        switch selected.kind {
        case .native, .systemDefault:
            return (text, selected.voice)
        case .approximateTurkish:
            return (UzbekSpeechText.forTurkishVoice(text), selected.voice)
        case .approximateRussian:
            return (UzbekSpeechText.forRussianVoice(text), selected.voice)
        }
    }

    private func choice(for language: AppLanguage) -> VoiceChoice {
        if let cached = voiceCache[language] { return cached }
        let resolved = Self.resolveVoice(for: language)
        voiceCache[language] = resolved
        return resolved
    }

    private static func resolveVoice(for language: AppLanguage) -> VoiceChoice {
        switch language {
        case .ru, .en:
            let found = voice(for: language.voiceLanguageCode)
            let matches = found.map { languagePrefix($0.language) == language.rawValue } ?? false
            return VoiceChoice(voice: found, kind: matches ? .native : .systemDefault)
        case .uz:
            if let uzbek = installedVoice(languagePrefix: "uz") {
                return VoiceChoice(voice: uzbek, kind: .native)
            }
            if let turkish = voice(for: "tr-TR"), languagePrefix(turkish.language) == "tr" {
                return VoiceChoice(voice: turkish, kind: .approximateTurkish)
            }
            if let russian = voice(for: "ru-RU"), languagePrefix(russian.language) == "ru" {
                return VoiceChoice(voice: russian, kind: .approximateRussian)
            }
            return VoiceChoice(voice: nil, kind: .systemDefault)
        }
    }

    /// Best installed voice of any vendor whose language starts with `languagePrefix` (e.g. "uz" for uz-UZ / uz-Latn).
    /// Third-party Speech Synthesis Provider voices are accepted here; novelty and personal voices are not.
    private static func installedVoice(languagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            languagePrefix($0.language) == prefix && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    private static func languagePrefix(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    /// Picks the most natural voice for `language`: Premium > Enhanced > default quality (only regular Apple voices,
    /// never a novelty or Eloquence voice). Among voices of the same quality the system default voice for the
    /// language wins. Premium / Enhanced voices are downloaded by the user in iPhone Settings → Accessibility →
    /// Spoken Content → Voices; without them the compact default voice is used.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let systemDefault = AVSpeechSynthesisVoice(language: normalized)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare(normalized) == .orderedSame && isAcceptable($0)
        }
        let best = candidates.max { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue { return lhs.quality.rawValue < rhs.quality.rawValue }
            // Same quality: the system default voice ranks higher.
            return lhs.identifier != systemDefault?.identifier && rhs.identifier == systemDefault?.identifier
        }
        return best ?? systemDefault
    }

    /// A regular Apple voice (com.apple.voice.* / com.apple.ttsbundle.*) that is not a novelty or Eloquence voice.
    private static func isAcceptable(_ voice: AVSpeechSynthesisVoice) -> Bool {
        let id = voice.identifier.lowercased()
        guard id.hasPrefix("com.apple.voice.") || id.hasPrefix("com.apple.ttsbundle.") else { return false }
        if id.contains("eloquence") || id.contains("novelty") { return false }
        if voice.voiceTraits.contains(.isNoveltyVoice) { return false }
        return true
    }

    // MARK: Audio session

    /// Audio session for spoken prompts: ducks music while speaking, mixes with other audio.
    func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // Speech still works with the previous category in most cases.
        }
    }

    private func didFinishUtterance() {
        guard !synthesizer.isSpeaking else { return }
        if !clips.isPlaying, !deferredClips.isEmpty {
            let urls = deferredClips.removeFirst()
            activatePlaybackSession()
            clips.play(urls, interrupt: false)
            for more in deferredClips { clips.play(more, interrupt: false) }
            deferredClips.removeAll()
        }
        finishIfIdle()
    }

    /// The clip queue finished: speak texts that waited for it, or release the audio session.
    private func didFinishClips() {
        if !synthesizer.isSpeaking, !deferredTexts.isEmpty {
            let texts = deferredTexts
            deferredTexts.removeAll()
            for text in texts { speak(text, priority: .normal) }
            return
        }
        finishIfIdle()
    }

    private func finishIfIdle() {
        isSpeaking = isBusy
        if !isSpeaking {
            currentPriority = .low
            // Last utterance done: release the session so other apps' audio is un-ducked.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishUtterance() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishUtterance() }
    }
}
