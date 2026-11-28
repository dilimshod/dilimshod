import Foundation

/// What the app may play: spoken prompts ("voice") and short alert tones ("sounds"). One persisted value
/// ("rv.soundMode") is the source of truth; the two older flags ("rv.voiceMuted", "rv.alertSounds") are derived from it.
public enum SoundMode: String, CaseIterable, Hashable, Sendable {
    /// Alert tones and spoken prompts.
    case all
    /// Alert tones only, no voice.
    case soundsOnly
    /// Spoken prompts only, no tones.
    case voiceOnly
    /// Neither (haptics stay).
    case silent

    /// UserDefaults / SharedPreferences key of the persisted mode.
    public static let storageKey = "rv.soundMode"
    /// Legacy flags the mode replaces (still written so an older build reads a consistent state).
    public static let legacyVoiceMutedKey = "rv.voiceMuted"
    public static let legacyAlertSoundsKey = "rv.alertSounds"

    public init(voiceEnabled: Bool, tonesEnabled: Bool) {
        switch (voiceEnabled, tonesEnabled) {
        case (true, true): self = .all
        case (false, true): self = .soundsOnly
        case (true, false): self = .voiceOnly
        case (false, false): self = .silent
        }
    }

    public var voiceEnabled: Bool { self == .all || self == .voiceOnly }
    public var tonesEnabled: Bool { self == .all || self == .soundsOnly }

    /// The same mode with spoken prompts switched on / off (the "voice prompts" settings toggle).
    public func withVoice(_ enabled: Bool) -> SoundMode { SoundMode(voiceEnabled: enabled, tonesEnabled: tonesEnabled) }
    /// The same mode with alert tones switched on / off (the "alert sounds" settings toggle).
    public func withTones(_ enabled: Bool) -> SoundMode { SoundMode(voiceEnabled: voiceEnabled, tonesEnabled: enabled) }

    /// Mode at first read: the stored raw value when valid, otherwise migrated from the legacy flags
    /// (`voiceMuted` default false, `alertSounds` default true; nil = the flag was never written).
    public static func resolve(stored: String?, legacyVoiceMuted: Bool?, legacyAlertSounds: Bool?) -> SoundMode {
        if let stored, let mode = SoundMode(rawValue: stored) { return mode }
        return SoundMode(voiceEnabled: !(legacyVoiceMuted ?? false), tonesEnabled: legacyAlertSounds ?? true)
    }

    /// Localization key of the mode name.
    public var titleKey: String { "sound.mode." + rawValue }
}

/// Short synthesized alert tones, one distinct pattern per warning (no bundled audio files).
public enum AlertToneKind: String, CaseIterable, Hashable, Sendable {
    /// Forward-collision warning.
    case collision
    /// Pedestrian in the own lane.
    case pedestrian
    /// Red light ahead while driving.
    case redLight
    /// Drifting over a lane marking.
    case laneDeparture
    /// Over the speed limit.
    case speeding
    /// Other spoken warnings (keep distance, pedestrian caution, officer / road workers, STOP sign).
    case attention

    /// One piece of a tone: `frequencyHz` 0 = silence.
    public struct Segment: Equatable, Sendable {
        public let frequencyHz: Double
        public let seconds: Double
        public init(_ frequencyHz: Double, _ seconds: Double) {
            self.frequencyHz = frequencyHz
            self.seconds = seconds
        }
    }

    /// Safety-critical tones accompany the voice; the others only replace it when the voice is off.
    public var isCritical: Bool {
        switch self {
        case .collision, .pedestrian, .redLight: return true
        case .laneDeparture, .speeding, .attention: return false
        }
    }

    /// Whether the tone is played in `mode`: never without tones; critical tones always; the rest only when the
    /// voice is off (so the "all" mode does not beep over every spoken hint).
    public func shouldPlay(in mode: SoundMode) -> Bool {
        guard mode.tonesEnabled else { return false }
        return isCritical || !mode.voiceEnabled
    }

    /// Tone of a coach message; nil = informational message without a tone (signs, speed-limit changes, green light).
    public static func kind(for message: CoachMessage) -> AlertToneKind? {
        switch message {
        case .collisionRisk: return .collision
        case .pedestrianDanger: return .pedestrian
        case .redLightAhead: return .redLight
        case .laneDeparture: return .laneDeparture
        case .overSpeedLimit: return .speeding
        case .keepDistance, .pedestrianCaution, .trafficOfficerAhead, .roadWorkersAhead, .stopSignAhead: return .attention
        case .roadSign, .speedLimit, .speedLimitAhead, .greenLightGo: return nil
        }
    }

    /// Whether a coach message produces any sound in `mode`: its voice phrase, or its tone when the voice is off.
    /// A message that is silent in the current mode must not start the coach's global gap (`CoachRules.next`).
    public static func isAudible(_ message: CoachMessage, in mode: SoundMode) -> Bool {
        if mode.voiceEnabled { return true }
        return kind(for: message)?.shouldPlay(in: mode) ?? false
    }

    public var segments: [Segment] {
        switch self {
        case .collision:
            return [Segment(1760, 0.09), Segment(0, 0.05), Segment(1760, 0.09), Segment(0, 0.05), Segment(1760, 0.14)]
        case .pedestrian:
            return [Segment(1320, 0.12), Segment(0, 0.04), Segment(990, 0.18)]
        case .redLight:
            return [Segment(880, 0.14), Segment(0, 0.08), Segment(880, 0.14)]
        case .laneDeparture:
            return [Segment(520, 0.08), Segment(0, 0.04), Segment(520, 0.08), Segment(0, 0.04), Segment(520, 0.08)]
        case .speeding:
            return [Segment(660, 0.12), Segment(0, 0.03), Segment(784, 0.18)]
        case .attention:
            return [Segment(1047, 0.16)]
        }
    }

    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// 16-bit mono PCM samples of the tone: sine segments with a 5 ms fade in / out (no clicks).
    public func samples(sampleRate: Int = 44_100, amplitude: Double = 0.7) -> [Int16] {
        let rate = Double(max(8_000, sampleRate))
        let level = min(1, max(0, amplitude)) * Double(Int16.max)
        var result: [Int16] = []
        result.reserveCapacity(Int(durationSeconds * rate) + 16)
        for segment in segments {
            let count = max(0, Int((segment.seconds * rate).rounded()))
            guard segment.frequencyHz > 0 else {
                result.append(contentsOf: [Int16](repeating: 0, count: count))
                continue
            }
            let fade = max(1, min(count / 2, Int(0.005 * rate)))
            let step = 2 * Double.pi * segment.frequencyHz / rate
            for index in 0..<count {
                var gain = 1.0
                if index < fade { gain = Double(index) / Double(fade) }
                if index >= count - fade { gain = min(gain, Double(count - 1 - index) / Double(fade)) }
                result.append(Int16((sin(step * Double(index)) * level * gain).rounded()))
            }
        }
        return result
    }

    /// The tone as an in-memory RIFF / WAVE file (PCM 16-bit mono), playable by AVAudioPlayer / SoundPool.
    public func wavData(sampleRate: Int = 44_100, amplitude: Double = 0.7) -> Data {
        let pcm = samples(sampleRate: sampleRate, amplitude: amplitude)
        let rate = UInt32(max(8_000, sampleRate))
        let dataBytes = UInt32(pcm.count * 2)
        var data = Data()
        data.reserveCapacity(44 + pcm.count * 2)
        func append32(_ value: UInt32) { for shift in [0, 8, 16, 24] { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        func append16(_ value: UInt16) { data.append(UInt8(value & 0xFF)); data.append(UInt8(value >> 8)) }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)            // fmt chunk size
        append16(1)             // PCM
        append16(1)             // mono
        append32(rate)
        append32(rate * 2)      // byte rate
        append16(2)             // block align
        append16(16)            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataBytes)
        for sample in pcm { append16(UInt16(bitPattern: sample)) }
        return data
    }
}

/// Priority of a spoken prompt.
/// - `low`: dropped while anything is being spoken.
/// - `normal`: waits (bounded, expiring queue) for the current utterance.
/// - `high`: interrupts everything except a `critical` utterance (navigation manoeuvres).
/// - `critical`: safety warning (collision, pedestrian, red light) — interrupts everything.
public enum SpeechPriority: Int, Comparable, Hashable, Sendable {
    case low = 0, normal, high, critical

    public static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What to do with a new utterance while another one is being spoken.
public enum SpeechAdmission: Equatable, Sendable {
    /// Nothing is speaking: start now.
    case start
    /// Stop the current utterance and everything waiting, then start.
    case interrupt
    /// Wait for the current utterance (expires after its maximum age).
    case enqueue
    /// Forget it.
    case drop

    public static func decide(priority: SpeechPriority, current: SpeechPriority, isBusy: Bool) -> SpeechAdmission {
        guard isBusy else { return .start }
        switch priority {
        case .low: return .drop
        case .normal: return .enqueue
        case .high: return current < .critical ? .interrupt : .enqueue
        case .critical: return .interrupt
        }
    }
}

/// Small queue of utterances waiting for the current one: at most `capacity` items (the oldest is dropped), each
/// with a deadline after which it is no longer worth saying ("you are leaving the lane" 8 s late is wrong).
public struct PendingSpeechQueue<Item> {
    public let capacity: Int
    private var items: [(item: Item, deadline: TimeInterval)] = []

    public init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Adds `item`, valid until `deadline` (same clock as `next(now:)`).
    public mutating func enqueue(_ item: Item, deadline: TimeInterval) {
        if items.count >= capacity { items.removeFirst(items.count - capacity + 1) }
        items.append((item, deadline))
    }

    /// The oldest item that has not expired (removed from the queue together with the expired ones before it).
    public mutating func next(now: TimeInterval) -> Item? {
        while !items.isEmpty {
            let first = items.removeFirst()
            if first.deadline >= now { return first.item }
        }
        return nil
    }

    public mutating func removeAll() { items.removeAll() }
}
