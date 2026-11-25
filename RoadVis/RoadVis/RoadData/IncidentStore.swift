import Foundation
import Observation

/// Road events reported by the user (accident, road works, jam, police, pothole, hazard, closure).
///
/// Reports are stored only on this phone (`Application Support/RoadVis/incidents.json`) and expire after
/// `settings.incidentLifetimeMinutes`. Expired reports are removed on load, on every report and once a minute.
/// They are the user's own notes, not data from a traffic service.
@Observable
@MainActor
final class IncidentStore {
    /// Active (not expired) reports, newest first.
    private(set) var incidents: [RoadIncident] = []
    /// Russian description of a load/save problem; nil when fine.
    private(set) var lastError: String?

    static let fileName = "incidents.json"
    /// A new report of the same kind within this distance of an active one refreshes it instead of adding a duplicate.
    static let duplicateRadius: Double = 80
    /// Period of the expiry check, seconds.
    static let pruneInterval: TimeInterval = 60

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        var loaded: [RoadIncident] = []
        switch RoadDataPersistence.load([RoadIncident].self, from: Self.fileName) {
        case .loaded(let value):
            loaded = value
        case .missing:
            break
        case .failed(let message):
            lastError = message
        }
        let active = IncidentFilter.active(loaded, now: Date(), lifetime: lifetime)
        incidents = active.sorted { $0.date > $1.date }
        if active.count != loaded.count {
            persist()
        }
        startPruneLoop()
    }

    /// Lifetime of a report, seconds (at least one minute).
    var lifetime: TimeInterval {
        max(1, settings.incidentLifetimeMinutes) * 60
    }

    /// Adds a report at `coordinate`. Re-reporting the same kind nearby refreshes the existing report (time, position
    /// and, when given, the note).
    func report(_ kind: RoadIncidentKind, at coordinate: GeoPoint, note: String? = nil) {
        guard coordinate.isValid else { return }
        let now = Date()
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = (trimmed?.isEmpty ?? true) ? nil : trimmed

        var updated = IncidentFilter.active(incidents, now: now, lifetime: lifetime)
        if let index = updated.firstIndex(where: {
            $0.kind == kind && Geo.distance($0.coordinate, coordinate) <= Self.duplicateRadius
        }) {
            var existing = updated.remove(at: index)
            existing.date = now
            existing.coordinate = coordinate
            if let cleanNote { existing.note = cleanNote }
            updated.append(existing)
        } else {
            updated.append(RoadIncident(kind: kind, coordinate: coordinate, date: now, note: cleanNote))
        }
        incidents = updated.sorted { $0.date > $1.date }
        persist()
    }

    /// Deletes a report.
    func remove(_ id: UUID) {
        let updated = incidents.filter { $0.id != id }
        guard updated.count != incidents.count else { return }
        incidents = updated
        persist()
    }

    /// Deletes every report.
    func removeAll() {
        guard !incidents.isEmpty else { return }
        incidents = []
        persist()
    }

    /// Active reports near the route (within 50 m), with their distance along it.
    func along(route: [GeoPoint], cumulative: [Double]?) -> [IncidentOnRoute] {
        let active = IncidentFilter.active(incidents, now: Date(), lifetime: lifetime)
        guard !active.isEmpty, route.count >= 2 else { return [] }
        return IncidentFilter.along(route: route, cumulative: cumulative, incidents: active)
    }

    /// Removes expired reports (also called automatically once a minute).
    func pruneExpired() {
        let active = IncidentFilter.active(incidents, now: Date(), lifetime: lifetime)
        guard active.count != incidents.count else { return }
        incidents = active.sorted { $0.date > $1.date }
        persist()
    }

    // MARK: - Private

    private func startPruneLoop() {
        pruneTask?.cancel()
        let interval = UInt64(Self.pruneInterval * 1_000_000_000)
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.pruneExpired()
            }
        }
    }

    /// Writes the current list; writes are chained so they never reorder.
    private func persist() {
        let data: Data
        do {
            data = try JSONEncoder().encode(incidents)
        } catch {
            lastError = "Не удалось сохранить события: \(error.localizedDescription)"
            return
        }
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            do {
                try await RoadDataPersistence.write(data, to: Self.fileName)
                if self?.lastError != nil { self?.lastError = nil }
            } catch {
                self?.lastError = "Не удалось сохранить события: \(error.localizedDescription)"
            }
        }
    }
}
