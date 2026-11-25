import Foundation

/// JSON files of the road-data services, stored in `Application Support/RoadVis/`.
///
/// Reads are synchronous (small files, done once at service start-up); writes go through a single actor so that
/// file I/O never runs on the main thread and two writes never interleave.
enum RoadDataPersistence {
    /// Sub-folder of Application Support used by the app.
    static let folderName = "RoadVis"

    /// Outcome of reading a JSON file.
    enum LoadResult<Value> {
        /// The file does not exist yet (first launch or data reset).
        case missing
        case loaded(Value)
        /// The file could not be read or decoded; `message` is Russian and suitable for display.
        case failed(message: String)
    }

    /// `Application Support/RoadVis`, created on demand.
    static func directoryURL() throws -> URL {
        let fileManager = FileManager.default
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent(folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Full URL of a file inside `Application Support/RoadVis`.
    static func fileURL(_ name: String) throws -> URL {
        try directoryURL().appendingPathComponent(name, isDirectory: false)
    }

    /// Reads and decodes a JSON file. An undecodable file is renamed to `<name>.corrupt-<timestamp>` (kept for
    /// diagnostics, never silently overwritten) and `.failed` is returned so the caller can start with empty data.
    static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> LoadResult<Value> {
        let url: URL
        do {
            url = try fileURL(name)
        } catch {
            return .failed(message: "Не удалось открыть папку данных: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failed(message: "Не удалось прочитать \(name): \(error.localizedDescription)")
        }
        do {
            return .loaded(try JSONDecoder().decode(type, from: data))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(name).corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: backup)
            return .failed(message: "Файл \(name) повреждён и сохранён как \(backup.lastPathComponent); начаты новые данные.")
        }
    }

    /// Atomically writes `data` to `name` off the main thread.
    static func write(_ data: Data, to name: String) async throws {
        let url = try fileURL(name)
        try await writer.write(data, to: url)
    }

    private static let writer = RoadDataFileWriter()
}

/// Serialises file writes of `RoadDataPersistence` away from the main actor.
actor RoadDataFileWriter {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
