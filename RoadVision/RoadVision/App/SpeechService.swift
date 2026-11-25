import AVFoundation
import Foundation
import Observation

enum SpeechPriority: Int, Comparable {
    case low = 0, normal, high

    static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Text-to-speech shared by navigation prompts and the AI assistant.
/// Also owns the audio-session switching between playback (prompts) and recording (speech input).
@Observable
@MainActor
final class SpeechService: NSObject {
    private(set) var isSpeaking = false
    /// Global mute for all speech output.
    var isMuted = false
    /// Default BCP-47 language for utterances.
    var defaultLanguage = "ru-RU"
    /// True while the microphone is in use (set by the speech recognizer).
    private(set) var isRecordingSessionActive = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var currentPriority: SpeechPriority = .low
    @ObservationIgnored private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`. A `.high` priority utterance interrupts whatever is being spoken;
    /// `.low` utterances are dropped while something else is speaking.
    func speak(_ text: String, priority: SpeechPriority = .normal, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isMuted, !trimmed.isEmpty, !isRecordingSessionActive else { return }
        if synthesizer.isSpeaking {
            if priority == .low { return }
            if priority >= currentPriority && priority == .high {
                synthesizer.stopSpeaking(at: .word)
            }
        }
        activatePlaybackSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice(for: language ?? defaultLanguage)
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

    /// Picks the highest-quality installed voice for the language, falling back to Russian, then the system default.
    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        let prefix = String(normalized.prefix(2)).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language.caseInsensitiveCompare(normalized) == .orderedSame }
        let sameLanguage = exact.isEmpty ? voices.filter { $0.language.lowercased().hasPrefix(prefix) } : exact
        let best = sameLanguage.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: normalized)
            ?? AVSpeechSynthesisVoice(language: "ru-RU")
        if let best { voiceCache[language] = best }
        return best
    }

    /// Audio session for spoken prompts: ducks music, mixes with other audio.
    func activatePlaybackSession() {
        guard !isRecordingSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            // Speech still works with the previous category in most cases.
        }
    }

    /// Called by the speech recognizer before starting the microphone.
    func prepareForRecording() throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isRecordingSessionActive = true
    }

    /// Called by the speech recognizer after the microphone has been stopped.
    func finishRecording() {
        isRecordingSessionActive = false
        activatePlaybackSession()
    }

    private func didFinishUtterance() {
        isSpeaking = synthesizer.isSpeaking
        if !isSpeaking {
            currentPriority = .low
            if !isRecordingSessionActive {
                // Give the audio focus back to music / other apps.
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
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
