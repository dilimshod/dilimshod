import AVFoundation
import Foundation
import Observation

enum SpeechPriority: Int, Comparable {
    case low = 0, normal, high

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Text-to-speech for navigation prompts and driving warnings.
/// All prompts are Russian, so the voice language is fixed to ru-RU (no setting can switch it).
/// The audio session ducks other audio only while speaking and is deactivated after the last utterance.
@Observable
@MainActor
final class SpeechService: NSObject {
    private(set) var isSpeaking = false
    /// Global mute for all speech output.
    var isMuted = false
    /// BCP-47 language of every utterance. Fixed: all prompts in the app are written in Russian.
    static let voiceLanguage = "ru-RU"

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentPriority: SpeechPriority = .low
    @ObservationIgnored private var cachedVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` in Russian. A `.high` priority utterance interrupts whatever is being spoken;
    /// `.low` utterances are dropped while something else is speaking.
    func speak(_ text: String, priority: SpeechPriority = .normal) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMuted, !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            if priority == .low { return }
            if priority >= currentPriority && priority == .high {
                synthesizer.stopSpeaking(at: .word)
            }
        }
        activatePlaybackSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = russianVoice()
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

    /// The Russian voice used for every prompt (cached).
    func russianVoice() -> AVSpeechSynthesisVoice? {
        if let cachedVoice { return cachedVoice }
        let voice = Self.voice(for: Self.voiceLanguage)
        cachedVoice = voice
        return voice
    }

    /// Picks a natural voice for `language`: the system default voice for the language first, then an
    /// enhanced/premium Apple voice, never a novelty or Eloquence voice.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        if let systemDefault = AVSpeechSynthesisVoice(language: normalized), isAcceptable(systemDefault) {
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
