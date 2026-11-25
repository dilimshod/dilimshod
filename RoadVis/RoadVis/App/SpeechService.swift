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
/// callers pass text that is already localized. Russian and English use a regular ru-RU / en-US Apple voice.
///
/// Uzbek: iOS 17–26 do not include an Uzbek system voice (Uzbek is not in Apple's VoiceOver / Spoken Content
/// language list). Voice choice for `.uz`, in order:
/// 1. any installed voice whose language starts with "uz" (e.g. from a third-party Speech Synthesis Provider app);
/// 2. a Turkish voice reading `UzbekSpeechText.forTurkishVoice(text)` (approximate pronunciation);
/// 3. a Russian voice reading the Cyrillic transliteration `UzbekSpeechText.forRussianVoice(text)` (approximate).
/// Text that contains Cyrillic letters is always spoken with the Russian voice (prompts not yet translated).
///
/// The audio session ducks other audio only while speaking and is deactivated after the last utterance.
@Observable
@MainActor
final class SpeechService: NSObject {
    private(set) var isSpeaking = false
    /// Global mute for all speech output.
    var isMuted = false

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

    private struct VoiceChoice {
        let voice: AVSpeechSynthesisVoice?
        let kind: SpeechVoiceKind
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        // Voices can be downloaded while the app runs (Settings → Accessibility → Spoken Content → Voices).
        NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearVoiceCache() }
        }
    }

    /// Speaks already-localized `text` in the current `language`. A `.high` priority utterance interrupts whatever
    /// is being spoken; `.low` utterances are dropped while something else is speaking.
    func speak(_ text: String, priority: SpeechPriority = .normal) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMuted, !trimmed.isEmpty else { return }
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
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05
        currentPriority = priority
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
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
    private func prepared(_ text: String) -> (String, AVSpeechSynthesisVoice?) {
        let lang = language
        // Untranslated Russian prompts stay on the Russian voice, whatever the app language.
        if lang != .ru, UzbekSpeechText.containsCyrillic(text) {
            return (text, russianVoice())
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

    /// Picks a natural voice for `language`: the system default voice for the language first, then an
    /// enhanced/premium Apple voice, never a novelty or Eloquence voice.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        if let systemDefault = AVSpeechSynthesisVoice(language: normalized), isAcceptable(systemDefault),
           systemDefault.language.caseInsensitiveCompare(normalized) == .orderedSame {
            return systemDefault
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare(normalized) == .orderedSame && isAcceptable($0)
        }
        let preferred = candidates.filter { $0.quality == .premium || $0.quality == .enhanced }
        return preferred.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? candidates.first
            ?? AVSpeechSynthesisVoice(language: normalized)
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
        isSpeaking = synthesizer.isSpeaking
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
