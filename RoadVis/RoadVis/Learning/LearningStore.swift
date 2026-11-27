import Foundation

/// Local folder of collected training samples: `Application Support/RoadVisLearning/pending/<uuid>.jpg` +
/// `<uuid>.json` (`docs/TRAINING_API.md` §2). The json is written last and marks a complete sample; a jpg without
/// a json (app killed mid-write) is removed by the next retention pass.
///
/// Thread-safe: every file operation runs under one lock, so the collector (utility queue), the uploader and the
/// settings screen (main actor) can share `LearningStore.shared`. Operations are small file-system calls.
final class LearningStore: @unchecked Sendable {
    /// One complete sample on disk.
    struct Sample: Sendable, Equatable {
        let id: String
        let imageURL: URL
        let metaURL: URL
        let createdAt: Date
        let bytes: Int64
    }

    static let shared = LearningStore()

    /// Application Support/RoadVisLearning/pending
    let directory: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("RoadVisLearning", isDirectory: true)
                .appendingPathComponent("pending", isDirectory: true)
        }
    }

    // MARK: - Writing

    /// Writes one sample (jpg first, json last). Throws on a file-system error (nothing half-written is left).
    func save(id: String, jpeg: Data, meta: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let imageURL = directory.appendingPathComponent("\(id).jpg")
        let metaURL = directory.appendingPathComponent("\(id).json")
        do {
            try jpeg.write(to: imageURL, options: [.atomic])
            try meta.write(to: metaURL, options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: metaURL)
            throw error
        }
    }

    // MARK: - Reading

    /// Complete samples, oldest first.
    func samples() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return listSamples().complete
    }

    /// Number of complete samples and their total size, bytes.
    func summary() -> (count: Int, bytes: Int64) {
        let all = samples()
        return (all.count, all.reduce(0) { $0 + $1.bytes })
    }

    // MARK: - Deleting

    func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        removeFiles(of: id)
    }

    /// Deletes every collected sample; returns how many complete samples there were.
    @discardableResult
    func deleteAll() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = listSamples().complete.count
        try? fileManager.removeItem(at: directory)
        return count
    }

    /// Applies the retention policy (age limit, size cap) and removes orphaned half-written files. Returns what was
    /// deleted by cause.
    @discardableResult
    func applyRetention(_ policy: LearningStorePolicy, now: Date = Date()) -> LearningRetentionPlan {
        lock.lock()
        defer { lock.unlock() }
        let listing = listSamples()
        for orphan in listing.orphans where now.timeIntervalSince(orphan.modified) > 600 {
            try? fileManager.removeItem(at: orphan.url)
        }
        let stored = listing.complete.map { LearningStoredSample(id: $0.id, createdAt: $0.createdAt, bytes: $0.bytes) }
        let plan = policy.plan(for: stored, now: now)
        for id in plan.all {
            removeFiles(of: id)
        }
        return plan
    }

    // MARK: - Private (lock held)

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Training frames are re-collectable and may be large: keep them out of iCloud / iTunes backups.
        var parent = directory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? parent.setResourceValues(values)
    }

    private func removeFiles(of id: String) {
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(id).jpg"))
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    private struct Orphan {
        let url: URL
        let modified: Date
    }

    private func listSamples() -> (complete: [Sample], orphans: [Orphan]) {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else {
            return ([], [])
        }
        var images: [String: (url: URL, bytes: Int64, created: Date)] = [:]
        var metas: [String: (url: URL, bytes: Int64, created: Date)] = [:]
        var orphans: [Orphan] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let bytes = Int64(values?.fileSize ?? 0)
            let created: Date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            let id = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension.lowercased() {
            case "jpg": images[id] = (url, bytes, created)
            case "json": metas[id] = (url, bytes, created)
            default: orphans.append(Orphan(url: url, modified: values?.contentModificationDate ?? Date.distantPast))
            }
        }
        var complete: [Sample] = []
        for (id, meta) in metas {
            guard let image = images[id] else {
                orphans.append(Orphan(url: meta.url, modified: meta.created))
                continue
            }
            complete.append(Sample(id: id, imageURL: image.url, metaURL: meta.url, createdAt: min(image.created, meta.created),
                                   bytes: image.bytes + meta.bytes))
        }
        for (id, image) in images where metas[id] == nil {
            orphans.append(Orphan(url: image.url, modified: image.created))
        }
        complete.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return (complete, orphans)
    }
}
