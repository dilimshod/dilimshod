import Foundation
import Observation

/// Recorded trips, one JSON file per trip in `Application Support/RoadVis/Trips/<id>.json`.
/// Loading and writing happen off the main actor; `trips` is sorted newest first.
@Observable
@MainActor
final class TripStore {
    private(set) var trips: [Trip] = []
    private(set) var isLoaded = false
    /// Russian description of the last load / write problem (non-fatal).
    private(set) var lastError: String?

    @ObservationIgnored private let writer = TripFileWriter()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {}

    /// `Application Support/RoadVis/Trips`, created on demand.
    nonisolated static func directoryURL() throws -> URL {
        let directory = try RoadDataPersistence.directoryURL().appendingPathComponent("Trips", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    nonisolated static func fileURL(for id: UUID) throws -> URL {
        try directoryURL().appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Reads every trip file once (idempotent).
    func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (trips: [Trip], errors: Int) in
                Self.readAll()
            }.value
            guard let self else { return }
            // Trips saved while loading (a just-finished recording) win over their file versions.
            var merged = result.trips.filter { loaded in !self.trips.contains { $0.id == loaded.id } }
            merged.append(contentsOf: self.trips)
            self.trips = merged.sorted { $0.startedAt > $1.startedAt }
            self.isLoaded = true
            if result.errors > 0 {
                self.lastError = "Не удалось прочитать файлов поездок: \(result.errors)."
            }
        }
    }

    func trip(id: UUID) -> Trip? {
        trips.first { $0.id == id }
    }

    /// Inserts or replaces the trip and writes its file.
    func save(_ trip: Trip) {
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = trip
        } else {
            trips.append(trip)
            trips.sort { $0.startedAt > $1.startedAt }
        }
        persist(trip)
    }

    /// Writes the file only (in-progress autosave; the list is not touched).
    func persist(_ trip: Trip) {
        Task { [writer, weak self] in
            do {
                try await writer.write(trip)
            } catch {
                self?.lastError = "Поездка не сохранена: \(error.localizedDescription)"
            }
        }
    }

    func delete(_ id: UUID) {
        trips.removeAll { $0.id == id }
        Task { [writer] in
            await writer.delete(id)
        }
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { trips.indices.contains($0) ? trips[$0].id : nil }
        for id in ids { delete(id) }
    }

    private nonisolated static func readAll() -> (trips: [Trip], errors: Int) {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else {
            return ([], 0)
        }
        let decoder = JSONDecoder()
        var trips: [Trip] = []
        var errors = 0
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                trips.append(try decoder.decode(Trip.self, from: Data(contentsOf: url)))
            } catch {
                errors += 1
            }
        }
        return (trips, errors)
    }
}

/// Serialises trip file writes away from the main actor (encoding included).
actor TripFileWriter {
    func write(_ trip: Trip) throws {
        let data = try JSONEncoder().encode(trip)
        try data.write(to: TripStore.fileURL(for: trip.id), options: .atomic)
    }

    func delete(_ id: UUID) {
        if let url = try? TripStore.fileURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
