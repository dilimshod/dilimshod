import CoreLocation
import Foundation
import Observation

/// Expected waiting time at traffic signals ahead.
///
/// No public real-time signal timing (SPaT) exists for the supported region, so every value here is an ESTIMATE:
/// a fixed-time signal model (`SignalWaitModel`, cycle and green share from Settings) blended with the user's own
/// stops, which are learned on the device (`StopDetector` → `SignalStatistics`, persisted as JSON in
/// `Application Support/RoadVision/signal_stats.json`). The UI must label these numbers "≈ … (оценка)".
///
/// Signal identity: OSM signal clusters can get a different representative node depending on the query (route vs.
/// surroundings). Learned data is therefore attached to a canonical id — the first id that received observations
/// within 40 m — whose coordinates are kept in `signal_locations.json`.
@Observable
@MainActor
final class TrafficSignalService {
    /// A traffic-signal intersection ahead on the route with its estimated waiting time.
    struct UpcomingSignal: Identifiable, Hashable {
        let id: String
        let feature: RouteFeature
        /// Distance from the current position along the route, metres (0 when the signal is right here).
        let distanceAhead: Double
        let estimate: SignalWaitEstimate
    }

    /// Signalised intersections of the active route, sorted by distance along the route.
    private(set) var routeSignals: [RouteFeature] = []
    /// Number of learned signal passages (mirrors `SignalStatistics.totalObservations`).
    private(set) var observationCount = 0
    /// Colour of the nearest traffic light seen by the camera (written by `RecognitionPipeline`).
    var cameraLightColor: TrafficLightColor?
    /// The most recently learned passage (stop or pass-through).
    private(set) var lastObservation: SignalObservation?
    /// Russian description of a load/save problem with the learned data; nil when fine.
    private(set) var persistenceError: String?

    /// Explanation to show next to signal waiting times.
    static let estimateDisclaimer =
        "≈ Оценка: модель цикла светофора и ваши прошлые остановки. Реальные фазы светофоров недоступны."

    static let statisticsFileName = "signal_stats.json"
    static let locationsFileName = "signal_locations.json"
    /// Fixes less accurate than this are not fed to the stop detector, metres.
    static let maxUsableAccuracy: Double = 50
    /// Only signals within this distance are passed to the stop detector, metres.
    static let detectorSearchRadius: Double = 1_000
    /// Two signal entries closer than this are the same intersection, metres.
    static let duplicateRadius: Double = 30
    /// A signal id is mapped to a known (learned) signal within this distance, metres.
    static let canonicalRadius: Double = 40
    /// A signal stays "upcoming" until the user is this far past it (GPS snapping noise), metres.
    static let passedTolerance: Double = 10
    /// Delay before learned data is written after a change, seconds.
    static let saveDebounce: TimeInterval = 1.5

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let roadInfo: RoadInfoService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let statistics: SignalStatistics
    @ObservationIgnored private let detector = StopDetector()
    /// Canonical signal ids that have learned data → their coordinates.
    @ObservationIgnored private var knownSignals: [String: GeoPoint]
    /// Memoised `canonicalID(for:at:)` results; cleared whenever `knownSignals` changes.
    @ObservationIgnored private var canonicalCache: [String: String] = [:]
    /// Coordinates of recently fed detector candidates (to locate the signal of a returned observation).
    @ObservationIgnored private var recentCandidates: [String: GeoPoint] = [:]
    @ObservationIgnored private var detectorHasState = false
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    init(location: LocationService, roadInfo: RoadInfoService, settings: AppSettings) {
        self.location = location
        self.roadInfo = roadInfo
        self.settings = settings

        var problems: [String] = []
        switch RoadDataPersistence.load(SignalStatistics.self, from: Self.statisticsFileName) {
        case .loaded(let value):
            statistics = value
        case .missing:
            statistics = SignalStatistics()
        case .failed(let message):
            statistics = SignalStatistics()
            problems.append(message)
        }
        switch RoadDataPersistence.load([SignalLocation].self, from: Self.locationsFileName) {
        case .loaded(let list):
            knownSignals = Dictionary(list.map { ($0.id, $0.coordinate) }, uniquingKeysWith: { first, _ in first })
        case .missing:
            knownSignals = [:]
        case .failed(let message):
            knownSignals = [:]
            problems.append(message)
        }
        observationCount = statistics.totalObservations
        persistenceError = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    // MARK: Lifecycle

    /// Starts learning from location updates (only while `settings.learnSignalTimings` is on). Safe to call repeatedly.
    func start() {
        guard listenerID == nil else { return }
        listenerID = location.addListener { [weak self] fix in
            self?.handleLocation(fix)
        }
    }

    /// Stops learning and writes pending data.
    func stop() {
        if let listenerID {
            location.removeListener(listenerID)
        }
        listenerID = nil
        detector.reset()
        detectorHasState = false
        flushPendingSave()
    }

    /// Writes pending learned data immediately (called when the app goes to the background,
    /// so the last stops are not lost if the system terminates the app).
    func persistNow() {
        flushPendingSave()
    }

    // MARK: Route

    /// Sets the signals of the active route (pass all route features; only `.trafficSignals` are kept).
    func setRouteSignals(_ features: [RouteFeature]) {
        let signals = features
            .filter { $0.kind == .trafficSignals }
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        if signals != routeSignals {
            routeSignals = signals
        }
    }

    /// The next `limit` signals ahead of `distanceAlong` (metres along the route) with their wait estimates.
    func upcoming(fromDistance distanceAlong: Double, limit: Int = 3) -> [UpcomingSignal] {
        guard limit > 0 else { return [] }
        let now = Date()
        var result: [UpcomingSignal] = []
        for feature in routeSignals {
            let ahead = feature.distanceAlongRoute - distanceAlong
            guard ahead >= -Self.passedTolerance else { continue }
            result.append(UpcomingSignal(id: feature.id, feature: feature, distanceAhead: max(0, ahead),
                                         estimate: estimate(for: feature, at: now)))
            if result.count >= limit { break }
        }
        return result
    }

    /// Number of signals ahead of `distanceAlong` and the sum of their expected waits (estimate), seconds.
    func totalExpectedWait(fromDistance distanceAlong: Double) -> (count: Int, seconds: Double) {
        let now = Date()
        var count = 0
        var seconds = 0.0
        for feature in routeSignals where feature.distanceAlongRoute - distanceAlong >= -Self.passedTolerance {
            count += 1
            seconds += estimate(for: feature, at: now).expectedWaitSeconds
        }
        return (count, seconds)
    }

    /// Wait estimate for a signal id (route feature id, nearby signal id or a learned id).
    func estimate(for signalID: String) -> SignalWaitEstimate {
        let coordinate = routeSignals.first(where: { $0.id == signalID })?.coordinate
            ?? roadInfo.nearbySignals.first(where: { $0.id == signalID })?.coordinate
            ?? knownSignals[signalID]
            ?? recentCandidates[signalID]
        let canonical = coordinate.map { canonicalID(for: signalID, at: $0) } ?? signalID
        return statistics.estimate(for: canonical, at: Date(), assumptions: settings.signalAssumptions)
    }

    /// Deletes all learned stops (Settings → "Сбросить статистику светофоров").
    func resetLearnedData() {
        pendingSave?.cancel()
        pendingSave = nil
        statistics.removeAll()
        knownSignals.removeAll()
        canonicalCache.removeAll()
        recentCandidates.removeAll()
        detector.reset()
        detectorHasState = false
        observationCount = 0
        lastObservation = nil
        enqueueWrite()
    }

    // MARK: - Learning

    private func handleLocation(_ fix: CLLocation) {
        guard settings.learnSignalTimings else {
            if detectorHasState {
                detector.reset()
                detectorHasState = false
            }
            return
        }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxUsableAccuracy, fix.speed >= 0 else {
            return
        }
        let position = GeoPoint(fix.coordinate)
        guard position.isValid else { return }
        let candidates = detectorCandidates(near: position)
        detectorHasState = true
        guard let observation = detector.update(position: position, speedKmh: fix.speed * 3.6,
                                                timestamp: fix.timestamp, nearbySignals: candidates) else { return }
        record(observation)
    }

    /// Union of route signals and nearby OSM signals within `detectorSearchRadius`, with canonical ids and without
    /// duplicates of the same intersection (route entries win).
    private func detectorCandidates(near position: GeoPoint) -> [SignalLocation] {
        var result: [SignalLocation] = []
        func add(id: String, coordinate: GeoPoint) {
            guard Geo.distance(position, coordinate) <= Self.detectorSearchRadius else { return }
            let canonical = canonicalID(for: id, at: coordinate)
            let duplicate = result.contains {
                $0.id == canonical || Geo.distance($0.coordinate, coordinate) < Self.duplicateRadius
            }
            guard !duplicate else { return }
            result.append(SignalLocation(id: canonical, coordinate: coordinate))
        }
        for feature in routeSignals {
            add(id: feature.id, coordinate: feature.coordinate)
        }
        for signal in roadInfo.nearbySignals {
            add(id: signal.id, coordinate: signal.coordinate)
        }
        if recentCandidates.count > 500 {
            recentCandidates.removeAll(keepingCapacity: true)
        }
        for candidate in result {
            recentCandidates[candidate.id] = candidate.coordinate
        }
        return result
    }

    private func record(_ observation: SignalObservation) {
        statistics.record(observation)
        if knownSignals[observation.signalID] == nil, let coordinate = recentCandidates[observation.signalID] {
            knownSignals[observation.signalID] = coordinate
            canonicalCache.removeAll()
        }
        observationCount = statistics.totalObservations
        lastObservation = observation
        scheduleSave()
    }

    private func estimate(for feature: RouteFeature, at date: Date) -> SignalWaitEstimate {
        statistics.estimate(for: canonicalID(for: feature.id, at: feature.coordinate), at: date,
                            assumptions: settings.signalAssumptions)
    }

    /// The id under which learned data for the signal at `coordinate` is stored.
    private func canonicalID(for id: String, at coordinate: GeoPoint) -> String {
        if let cached = canonicalCache[id] { return cached }
        var resolved = id
        if knownSignals[id] == nil {
            var bestDistance = Self.canonicalRadius
            for (knownID, knownCoordinate) in knownSignals {
                let distance = Geo.distance(knownCoordinate, coordinate)
                if distance <= bestDistance {
                    bestDistance = distance
                    resolved = knownID
                }
            }
        }
        canonicalCache[id] = resolved
        return resolved
    }

    // MARK: - Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.saveDebounce * 1_000_000_000))
            } catch {
                return
            }
            self?.pendingSave = nil
            self?.enqueueWrite()
        }
    }

    private func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        enqueueWrite()
    }

    /// Encodes the current state now and appends the file write to a serial chain (writes never reorder).
    private func enqueueWrite() {
        let encoder = JSONEncoder()
        let statisticsData: Data
        let locationsData: Data
        do {
            statisticsData = try encoder.encode(statistics)
            let locations = knownSignals
                .map { SignalLocation(id: $0.key, coordinate: $0.value) }
                .sorted { $0.id < $1.id }
            locationsData = try encoder.encode(locations)
        } catch {
            persistenceError = "Не удалось сохранить статистику светофоров: \(error.localizedDescription)"
            return
        }
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            do {
                try await RoadDataPersistence.write(statisticsData, to: Self.statisticsFileName)
                try await RoadDataPersistence.write(locationsData, to: Self.locationsFileName)
                if self?.persistenceError != nil { self?.persistenceError = nil }
            } catch {
                self?.persistenceError = "Не удалось сохранить статистику светофоров: \(error.localizedDescription)"
            }
        }
    }
}
