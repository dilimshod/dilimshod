import AVFoundation
import Foundation

/// Plays pre-recorded voice clips (Microsoft Edge neural voices, generated on a Mac by
/// `tools/generate_voice_clips.py` into `RoadVis/VoiceClips/` and bundled flat as `<lang>_<id>.m4a` / `.mp3`).
///
/// A `VoicePhrase` is composed into clip ids for the language (`VoiceComposer`); only when every clip exists in the
/// bundle are they played back to back with an `AVQueuePlayer` (no gaps between items). Otherwise `urls(for:language:)`
/// returns nil and `SpeechService` speaks the text with the system voice. The audio session itself is handled by
/// `SpeechService` (same category / ducking for both); this class reports the end of its queue via `onFinish`.
@MainActor
final class ClipVoicePlayer {
    /// UserDefaults key: natural-voice clips on / off (Settings → Language). Default on.
    nonisolated static let enabledKey = "rv.voiceClipsEnabled"

    /// True while clips are playing.
    private(set) var isPlaying = false
    /// Called on the main actor after the last queued clip finished (or playback failed / was stopped).
    var onFinish: (@MainActor () -> Void)?

    private let player = AVQueuePlayer()
    private var observers: [NSObjectProtocol] = []
    /// Last item of the queued phrase(s): its end means the queue is done.
    private var lastItem: AVPlayerItem?
    private var urlCache: [String: URL] = [:]
    private var missing: Set<String> = []

    init() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemFailed(item) }
        })
        observers.append(center.addObserver(forName: LocalizationManager.languageDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.missing.removeAll() }
        })
    }

    /// Natural-voice clips enabled in Settings (default true).
    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
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

    /// Plays `urls` back to back. `interrupt` stops whatever is playing first; otherwise the clips are appended to
    /// the current queue.
    func play(_ urls: [URL], interrupt: Bool) {
        guard !urls.isEmpty else { return }
        if interrupt { player.removeAllItems() }
        var appended: AVPlayerItem?
        for url in urls {
            let item = AVPlayerItem(url: url)
            if player.canInsert(item, after: nil) {
                player.insert(item, after: nil)
                appended = item
            }
        }
        guard let appended else {
            if player.items().isEmpty { finish() }
            return
        }
        lastItem = appended
        isPlaying = true
        player.play()
    }

    /// Stops immediately and drops the queue.
    func stop() {
        guard isPlaying || !player.items().isEmpty else { return }
        player.pause()
        player.removeAllItems()
        finish()
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard isPlaying, let item, item === lastItem else { return }
        finish()
    }

    private func itemFailed(_ item: AVPlayerItem?) {
        guard isPlaying, let item, player.items().contains(where: { $0 === item }) || item === lastItem else { return }
        // A broken clip: drop the rest of the phrase rather than playing it half.
        player.removeAllItems()
        finish()
    }

    private func finish() {
        lastItem = nil
        guard isPlaying else { return }
        isPlaying = false
        onFinish?()
    }
}
