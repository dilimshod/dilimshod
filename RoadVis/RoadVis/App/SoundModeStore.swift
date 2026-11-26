import Foundation
import Observation

/// The persisted sound mode (all / sounds only / voice only / silent) — the one source of truth for what the app
/// may play. `SpeechService.isMuted` and `DriverAssistSettings.alertSoundsEnabled` are derived from it and write
/// through to it, so the 🔊 button menu and the two Settings toggles always show the same state.
///
/// Stored under "rv.soundMode". On first read the mode is migrated from the older flags "rv.voiceMuted" and
/// "rv.alertSounds"; both are still written on every change so they stay consistent with the mode.
@Observable
@MainActor
final class SoundModeStore {
    static let shared = SoundModeStore()

    /// Posted on the main thread after `mode` changed (`SpeechService` stops speech / tones the new mode forbids).
    static let didChange = Notification.Name("rv.soundModeDidChange")

    var mode: SoundMode {
        didSet {
            guard mode != oldValue else { return }
            persist()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored: String? = defaults.string(forKey: SoundMode.storageKey)
        let legacyMuted: Bool? = defaults.object(forKey: SoundMode.legacyVoiceMutedKey) == nil
            ? nil : defaults.bool(forKey: SoundMode.legacyVoiceMutedKey)
        let legacyTones: Bool? = defaults.object(forKey: SoundMode.legacyAlertSoundsKey) == nil
            ? nil : defaults.bool(forKey: SoundMode.legacyAlertSoundsKey)
        let resolved: SoundMode = SoundMode.resolve(stored: stored, legacyVoiceMuted: legacyMuted,
                                                    legacyAlertSounds: legacyTones)
        mode = resolved
        if stored != resolved.rawValue {
            // First launch with the new key (or an unknown stored value): write the migrated mode.
            defaults.set(resolved.rawValue, forKey: SoundMode.storageKey)
        }
    }

    private func persist() {
        defaults.set(mode.rawValue, forKey: SoundMode.storageKey)
        defaults.set(!mode.voiceEnabled, forKey: SoundMode.legacyVoiceMutedKey)
        defaults.set(mode.tonesEnabled, forKey: SoundMode.legacyAlertSoundsKey)
    }
}

extension SoundMode: Identifiable {
    public var id: String { rawValue }

    /// SF Symbol of the mode (all exist on iOS 17).
    var systemImage: String {
        switch self {
        case .all: return "speaker.wave.2.fill"
        case .soundsOnly: return "bell.fill"
        case .voiceOnly: return "person.wave.2.fill"
        case .silent: return "speaker.slash.fill"
        }
    }
}
