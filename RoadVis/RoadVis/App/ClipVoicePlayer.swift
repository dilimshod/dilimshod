import AVFoundation
import Foundation

/// Plays pre-recorded voice clips (Microsoft Edge neural voices, generated on a Mac by
/// `tools/generate_voice_clips.py` into `RoadVis/VoiceClips/` and bundled flat as `<lang>_<id>.m4a` / `.mp3`).
///
/// A `VoicePhrase` is composed into clip ids for the language (`VoiceComposer`); only when every clip exists in the
/// bundle are they played. Otherwise `urls(for:language:)` returns nil and `SpeechService` speaks the text with the
/// system voice.
///
/// Gapless playback: every clip is decoded once into an `AVAudioPCMBuffer` (cached), its leading / trailing silence is
/// trimmed (`AudioSilenceTrimmer`, −40 dBFS, 30 ms padding — edge-tts clips carry several hundred ms of silence at
/// both ends), converted to one common format and scheduled back to back on an `AVAudioPlayerNode`, so the segments of
/// a phrase join without pauses. A short gap (`phraseGap`) separates two queued phrases. The node plays through an
/// `AVAudioUnitTimePitch` at the user's voice speed (`voiceRate`, default 1.1, Settings → Language), pitch unchanged.
///
/// The audio session itself is handled by `SpeechService` (same category / ducking for both); this class stops its
/// engine after the last buffer (so the session can be deactivated) and reports the end via `onFinish`.
@MainActor
final class ClipVoicePlayer {
    /// UserDefaults key: natural-voice clips on / off (Settings → Language). Default on.
    nonisolated static let enabledKey = "rv.voiceClipsEnabled"
    /// UserDefaults key: voice speed factor 0.9…1.4 (clips and the system voice). Default 1.1.
    nonisolated static let rateKey = "rv.voiceRate"

    /// Silence between two queued phrases, seconds.
    static let phraseGap: Double = 0.06
    /// Common sample format of the scheduled buffers (edge-tts delivers 24 kHz mono).
    private static let commonFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    /// Decoded clips kept in memory (≈ 100–200 kB each).
    private static let cacheLimit = 160

    /// True while clips are playing.
    private(set) var isPlaying = false
    /// Called on the main actor after the last queued clip finished (or playback failed / was stopped).
    var onFinish: (@MainActor () -> Void)?

    /// Playback speed of the clips (time-stretch, pitch kept).
    var rate: Double = ClipVoicePlayer.voiceRate {
        didSet { timePitch.rate = Float(rate) }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var observers: [NSObjectProtocol] = []
    /// Buffers scheduled and not yet played back.
    private var pendingBuffers = 0
    /// Incremented on every stop: completions of older buffers are ignored.
    private var generation = 0
    private var urlCache: [String: URL] = [:]
    private var missing: Set<String> = []
    private var bufferCache: [URL: AVAudioPCMBuffer] = [:]

    init() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: Self.commonFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: Self.commonFormat)
        timePitch.rate = Float(rate)
        engine.prepare()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LocalizationManager.languageDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.missing.removeAll() }
        })
        // Route change / media services reset: the engine stopped by itself — drop the phrase.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.stop() } }
        })
    }

    /// Natural-voice clips enabled in Settings (default true).
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Voice speed factor from Settings (0.9…1.4, default 1.1).
    nonisolated static var voiceRate: Double {
        get { AudioSilenceTrimmer.clampedVoiceRate(UserDefaults.standard.object(forKey: rateKey) as? Double) }
        set { UserDefaults.standard.set(AudioSilenceTrimmer.clampedVoiceRate(newValue), forKey: rateKey) }
    }

    // MARK: Lookup

    /// Bundle URLs of every clip of `phrase` in `language`, nil when the phrase cannot be composed or a clip is missing.
    func urls(for phrase: VoicePhrase, language: AppLanguage) -> [URL]? {
        guard let names = VoiceComposer.resourceNames(for: phrase, language: language.core) else { return nil }
        var result: [URL] = []
        result.reserveCapacity(names.count)
        for name in names {
            guard let url = url(forResource: name) else { return nil }
            result.append(url)
        }
        return result
    }

    private func url(forResource name: String) -> URL? {
        if let cached = urlCache[name] { return cached }
        if missing.contains(name) { return nil }
        let found = Bundle.main.url(forResource: name, withExtension: "m4a")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3")
        if let found { urlCache[name] = found } else { missing.insert(name) }
        return found
    }

    /// Number of bundled clips for `language` and the number the catalog defines (for Settings).
    nonisolated static func installedCount(for language: AppLanguage) -> (installed: Int, total: Int) {
        let ids = VoiceClipCatalog.clipIDs(for: language.core)
        let installed = ids.reduce(0) { count, id in
            let name = VoiceClipCatalog.resourceName(id, language.core)
            let exists = Bundle.main.url(forResource: name, withExtension: "m4a") != nil
                || Bundle.main.url(forResource: name, withExtension: "mp3") != nil
            return count + (exists ? 1 : 0)
        }
        return (installed, ids.count)
    }

    // MARK: Playback

    /// Plays `urls` back to back without gaps. `interrupt` stops whatever is playing first; otherwise the clips are
    /// appended to the current queue (after a short phrase gap). A clip that cannot be decoded drops the whole phrase.
    func play(_ urls: [URL], interrupt: Bool) {
        guard !urls.isEmpty else { return }
        if interrupt { stop() }
        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(urls.count + 1)
        for url in urls {
            guard let buffer = buffer(for: url) else {
                if !isPlaying { finishNow() }
                return
            }
            buffers.append(buffer)
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                if !isPlaying { finishNow() }
                return
            }
        }
        if pendingBuffers > 0, let gap = Self.silence(seconds: Self.phraseGap) {
            buffers.insert(gap, at: 0)
        }
        let current = generation
        for buffer in buffers {
            pendingBuffers += 1
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                      completionHandler: Self.completion(for: self, generation: current))
        }
        isPlaying = true
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Stops immediately and drops the queue.
    func stop() {
        guard isPlaying || pendingBuffers > 0 else { return }
        generation += 1
        pendingBuffers = 0
        playerNode.stop()
        finishNow()
    }

    /// Completion handler created outside the main actor (it is called on an audio thread).
    private nonisolated static func completion(for player: ClipVoicePlayer,
                                               generation: Int) -> AVAudioPlayerNodeCompletionHandler {
        { [weak player] _ in
            DispatchQueue.main.async { [weak player] in
                MainActor.assumeIsolated { player?.bufferPlayed(generation: generation) }
            }
        }
    }

    private func bufferPlayed(generation played: Int) {
        guard played == generation, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        if pendingBuffers == 0 { finishNow() }
    }

    /// Stops the engine (no running I/O, so `SpeechService` can deactivate the session) and reports the end.
    private func finishNow() {
        pendingBuffers = 0
        if playerNode.isPlaying { playerNode.stop() }
        if engine.isRunning { engine.stop() }
        guard isPlaying else { return }
        isPlaying = false
        onFinish?()
    }

    // MARK: Decoding

    /// Decoded, silence-trimmed clip in `commonFormat` (cached).
    private func buffer(for url: URL) -> AVAudioPCMBuffer? {
        if let cached = bufferCache[url] { return cached }
        guard let decoded = Self.decode(url) else { return nil }
        if bufferCache.count >= Self.cacheLimit { bufferCache.removeAll(keepingCapacity: true) }
        bufferCache[url] = decoded
        return decoded
    }

    private static func decode(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(max(0, file.length))
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do { try file.read(into: raw) } catch { return nil }
        guard let converted = convert(raw, to: commonFormat) else { return nil }
        return trimmed(converted)
    }

    /// `buffer` in `format` (unchanged when it already matches).
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let feed = ConverterFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = feed.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Copy of a mono float buffer without its leading / trailing silence (−40 dBFS, 30 ms padding kept).
    private static func trimmed(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return buffer }
        let count = Int(buffer.frameLength)
        let range = AudioSilenceTrimmer.audibleRange(samples: UnsafeBufferPointer(start: data[0], count: count),
                                                     sampleRate: buffer.format.sampleRate)
        guard range.count < count, range.count > 0,
              let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(range.count)),
              let target = output.floatChannelData else { return buffer }
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: data[channel] + range.lowerBound, count: range.count)
        }
        output.frameLength = AVAudioFrameCount(range.count)
        return output
    }

    /// Silent buffer in `commonFormat`.
    private static func silence(seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * commonFormat.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: commonFormat, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(commonFormat.channelCount) {
                data[channel].update(repeating: 0, count: Int(frames))
            }
        }
        return buffer
    }
}

/// Hands the one input buffer to `AVAudioConverter` exactly once (a class, so the input block captures no var).
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
