import Foundation
import XCTest
@testable import RoadVisCore

/// Sound mode (4 states over voice / tones), alert tones and the speech admission / pending-queue rules.
final class SoundModeTests: XCTestCase {

    func testModeFlags() {
        XCTAssertEqual(SoundMode.allCases.count, 4)
        XCTAssertTrue(SoundMode.all.voiceEnabled && SoundMode.all.tonesEnabled)
        XCTAssertTrue(!SoundMode.soundsOnly.voiceEnabled && SoundMode.soundsOnly.tonesEnabled)
        XCTAssertTrue(SoundMode.voiceOnly.voiceEnabled && !SoundMode.voiceOnly.tonesEnabled)
        XCTAssertTrue(!SoundMode.silent.voiceEnabled && !SoundMode.silent.tonesEnabled)
        for mode in SoundMode.allCases {
            XCTAssertEqual(SoundMode(voiceEnabled: mode.voiceEnabled, tonesEnabled: mode.tonesEnabled), mode)
            XCTAssertEqual(SoundMode(rawValue: mode.rawValue), mode)
            XCTAssertEqual(mode.titleKey, "sound.mode.\(mode.rawValue)")
        }
    }

    func testSettingsTogglesWriteThrough() {
        XCTAssertEqual(SoundMode.all.withVoice(false), .soundsOnly)
        XCTAssertEqual(SoundMode.all.withTones(false), .voiceOnly)
        XCTAssertEqual(SoundMode.soundsOnly.withTones(false), .silent)
        XCTAssertEqual(SoundMode.silent.withVoice(true), .voiceOnly)
        XCTAssertEqual(SoundMode.silent.withTones(true).withVoice(true), .all)
        XCTAssertEqual(SoundMode.voiceOnly.withVoice(true), .voiceOnly)
    }

    func testMigrationFromLegacyFlags() {
        XCTAssertEqual(SoundMode.resolve(stored: nil, legacyVoiceMuted: nil, legacyAlertSounds: nil), .all)
        XCTAssertEqual(SoundMode.resolve(stored: nil, legacyVoiceMuted: true, legacyAlertSounds: nil), .soundsOnly)
        XCTAssertEqual(SoundMode.resolve(stored: nil, legacyVoiceMuted: false, legacyAlertSounds: false), .voiceOnly)
        XCTAssertEqual(SoundMode.resolve(stored: nil, legacyVoiceMuted: true, legacyAlertSounds: false), .silent)
        // A stored mode wins over the legacy flags; an unknown raw value falls back to them.
        XCTAssertEqual(SoundMode.resolve(stored: "voiceOnly", legacyVoiceMuted: true, legacyAlertSounds: true), .voiceOnly)
        XCTAssertEqual(SoundMode.resolve(stored: "bogus", legacyVoiceMuted: true, legacyAlertSounds: true), .soundsOnly)
        XCTAssertEqual(SoundMode.storageKey, "rv.soundMode")
    }

    func testTonePolicyPerMode() {
        for kind in AlertToneKind.allCases {
            XCTAssertFalse(kind.shouldPlay(in: .silent))
            XCTAssertFalse(kind.shouldPlay(in: .voiceOnly))
            XCTAssertTrue(kind.shouldPlay(in: .soundsOnly), "\(kind) must be audible in sounds-only mode")
            XCTAssertEqual(kind.shouldPlay(in: .all), kind.isCritical)
        }
        XCTAssertTrue(AlertToneKind.collision.isCritical)
        XCTAssertTrue(AlertToneKind.pedestrian.isCritical)
        XCTAssertTrue(AlertToneKind.redLight.isCritical)
        XCTAssertFalse(AlertToneKind.laneDeparture.isCritical)
        XCTAssertFalse(AlertToneKind.speeding.isCritical)
    }

    func testImportantWarningsHaveATone() {
        XCTAssertEqual(AlertToneKind.kind(for: .collisionRisk), .collision)
        XCTAssertEqual(AlertToneKind.kind(for: .pedestrianDanger(trackID: 1)), .pedestrian)
        XCTAssertEqual(AlertToneKind.kind(for: .redLightAhead), .redLight)
        XCTAssertEqual(AlertToneKind.kind(for: .laneDeparture(side: .left)), .laneDeparture)
        XCTAssertEqual(AlertToneKind.kind(for: .overSpeedLimit(limitKmh: 60)), .speeding)
        XCTAssertEqual(AlertToneKind.kind(for: .keepDistance(recommendedMeters: nil)), .attention)
        XCTAssertEqual(AlertToneKind.kind(for: .roadWorkersAhead(trackID: 2)), .attention)
        XCTAssertNil(AlertToneKind.kind(for: .greenLightGo))
        XCTAssertNil(AlertToneKind.kind(for: .speedLimit(kmh: 60)))
        // Every high-urgency coach message has a tone.
        let urgent: [CoachMessage] = [.collisionRisk, .pedestrianDanger(trackID: 3), .redLightAhead]
        for message in urgent {
            XCTAssertEqual(message.urgency, .high)
            XCTAssertEqual(AlertToneKind.kind(for: message)?.isCritical, true)
        }
    }

    func testTonesAreDistinctShortAndClickFree() {
        var patterns: Set<String> = []
        for kind in AlertToneKind.allCases {
            XCTAssertGreaterThan(kind.durationSeconds, 0.1)
            XCTAssertLessThanOrEqual(kind.durationSeconds, 0.5)
            patterns.insert(kind.segments.map { "\($0.frequencyHz):\($0.seconds)" }.joined(separator: ","))
            let samples = kind.samples(sampleRate: 44_100)
            XCTAssertEqual(samples.count, Int((kind.durationSeconds * 44_100).rounded()), accuracy: kind.segments.count)
            XCTAssertEqual(samples.first, 0)
            XCTAssertLessThan(abs(Int(samples.last ?? 1)), 400)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 20_000)
            XCTAssertLessThanOrEqual(peak, Int(Int16.max))
        }
        XCTAssertEqual(patterns.count, AlertToneKind.allCases.count)
    }

    func testWavHeader() {
        let kind = AlertToneKind.collision
        let samples = kind.samples(sampleRate: 22_050)
        let wav = [UInt8](kind.wavData(sampleRate: 22_050))
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        func u32(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 | Int(wav[at + 2]) << 16 | Int(wav[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 }
        XCTAssertEqual(u32(4), wav.count - 8)
        XCTAssertEqual(u16(20), 1)          // PCM
        XCTAssertEqual(u16(22), 1)          // mono
        XCTAssertEqual(u32(24), 22_050)
        XCTAssertEqual(u32(28), 44_100)     // byte rate
        XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(u32(40), samples.count * 2)
        // Second sample round-trips (little endian, signed).
        XCTAssertEqual(Int16(bitPattern: UInt16(u16(46))), samples[1])
    }

    func testSpeechAdmission() {
        for priority in [SpeechPriority.low, .normal, .high, .critical] {
            XCTAssertEqual(SpeechAdmission.decide(priority: priority, current: .critical, isBusy: false), .start)
        }
        XCTAssertEqual(SpeechAdmission.decide(priority: .low, current: .low, isBusy: true), .drop)
        XCTAssertEqual(SpeechAdmission.decide(priority: .normal, current: .low, isBusy: true), .enqueue)
        XCTAssertEqual(SpeechAdmission.decide(priority: .normal, current: .high, isBusy: true), .enqueue)
        XCTAssertEqual(SpeechAdmission.decide(priority: .high, current: .normal, isBusy: true), .interrupt)
        XCTAssertEqual(SpeechAdmission.decide(priority: .high, current: .high, isBusy: true), .interrupt)
        // A navigation prompt (.high) never cuts off a safety warning (.critical): it waits.
        XCTAssertEqual(SpeechAdmission.decide(priority: .high, current: .critical, isBusy: true), .enqueue)
        XCTAssertEqual(SpeechAdmission.decide(priority: .critical, current: .critical, isBusy: true), .interrupt)
        XCTAssertEqual(SpeechAdmission.decide(priority: .critical, current: .high, isBusy: true), .interrupt)
        XCTAssertTrue(SpeechPriority.high < SpeechPriority.critical)
    }

    func testPendingQueueExpiresAndIsBounded() {
        var queue = PendingSpeechQueue<String>(capacity: 2)
        XCTAssertNil(queue.next(now: 0))
        queue.enqueue("lane", deadline: 3)
        queue.enqueue("hazard", deadline: 8)
        XCTAssertEqual(queue.count, 2)
        // Stale lane warning is skipped, the hazard is still valid.
        XCTAssertEqual(queue.next(now: 5), "hazard")
        XCTAssertTrue(queue.isEmpty)

        queue.enqueue("a", deadline: 10)
        queue.enqueue("b", deadline: 10)
        queue.enqueue("c", deadline: 10)   // capacity 2: the oldest is dropped
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.next(now: 1), "b")
        XCTAssertEqual(queue.next(now: 10), "c")   // deadline is inclusive
        XCTAssertNil(queue.next(now: 1))

        queue.enqueue("x", deadline: 1)
        XCTAssertNil(queue.next(now: 2))
        queue.enqueue("y", deadline: 5)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
    }
}
