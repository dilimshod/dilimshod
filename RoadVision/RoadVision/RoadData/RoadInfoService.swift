import CoreLocation
import Foundation
import Observation

/// Road attributes from OpenStreetMap (Overpass API): the road the user is driving on (name, class, lanes,
/// speed limit), nearby traffic signals, and hazards along the active route.
///
/// Current road
/// - One `roadsAround` query fetches the ways near the user. Between network refreshes the cached ways are re-matched
///   on every GPS fix (cheap), so the current road and lane data follow the user smoothly.
/// - A new query is made when the user leaves the area covered by the cached data (> 120 m from the query centre),
///   after moving ≥ 60 m, or every ≈ 10 s while moving — never with a request already in flight. Standing still does
///   not generate requests. Failed requests are retried with an exponential back-off.
///
/// Route features
/// - `loadRouteFeatures` simplifies the route to ≤ 400 vertices, splits it into chunks of
///   `OverpassQuery.maxPolylinePoints` and runs one query per chunk, sequentially; results are merged by element key and
///   projected onto the full original route. Features are published progressively as chunks arrive. Starting a new
///   load (or `clearRouteFeatures`) cancels the previous one.
///
/// OSM data is community-maintained: lane counts and limits may be missing or outdated (`LaneInfo.isEstimated`,
/// `SpeedLimit.isImplicit` mark inferred values).
@Observable
@MainActor
final class RoadInfoService {
    // MARK: Published state

    /// Best-matching road for the current position and travel direction; nil when unknown.
    private(set) var currentRoad: RoadSegmentInfo?
    /// Traffic signals (clustered) around the user, from the same query as `currentRoad`.
    private(set) var nearbySignals: [SignalLocation] = []
    /// Time of the last successful road query.
    private(set) var lastUpdate: Date?
    /// True while a current-road query is in flight.
    private(set) var isLoading = false
    /// Russian description of the latest unresolved error ("Нет связи с OpenStreetMap (Overpass): …"); nil when fine.
    private(set) var lastError: String?
    /// Hazards and signals along the active route, sorted by distance along the route.
    private(set) var routeFeatures: [RouteFeature] = []
    /// True while route features are being loaded.
    private(set) var isLoadingRouteFeatures = false
    /// True when some route chunks could not be loaded, i.e. `routeFeatures` is incomplete.
    private(set) var routeFeaturesIncomplete = false
    /// True between `start()` and `stop()`.
    private(set) var isRunning = false

    // MARK: Tuning

    /// Distance moved since the last query that triggers a refresh, metres.
    static let refreshDistance: Double = 60
    /// Refresh period while moving, seconds.
    static let refreshInterval: TimeInterval = 10
    /// Minimum spacing between two road queries (except when leaving the covered area), seconds.
    static let minimumRequestSpacing: TimeInterval = 5
    /// Spacing used when the user has left the covered area, seconds.
    static let coverageRequestSpacing: TimeInterval = 3
    /// The cached ways are considered to cover this radius around the query centre, metres.
    static let coverageRadius: Double = 120
    /// Movement below this is treated as GPS jitter of a standing vehicle, metres.
    static let stationaryJitter: Double = 10
    /// Fixes less accurate than this are ignored for matching and querying, metres.
    static let maxUsableAccuracy: Double = 65
    /// The previous road is kept while it is at most this much farther than the best candidate, metres.
    static let matchStickiness: Double = 4
    /// Maximum vertices of the simplified route used for feature queries.
    static let maxRouteQueryPoints = 400
    /// Default and maximum `around` radius for route feature queries, metres.
    static let baseRouteQueryRadius: Double = 35
    static let maxRouteQueryRadius: Double = 120
    /// Prefix of every network error shown to the user.
    static let errorPrefix = "Нет связи с OpenStreetMap (Overpass): "

    // MARK: Internals

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client: OverpassClient
    @ObservationIgnored private var listenerID: UUID?

    @ObservationIgnored private var roadTask: Task<Void, Never>?
    @ObservationIgnored private var roadRequestID = 0
    @ObservationIgnored private var cachedElements: [OSMElement] = []
    @ObservationIgnored private var cacheCenter: GeoPoint?
    @ObservationIgnored private var lastGoodPosition: GeoPoint?
    @ObservationIgnored private var lastRequestPosition: GeoPoint?
    @ObservationIgnored private var lastRequestDate: Date?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var nextRequestAllowed: Date = .distantPast
    @ObservationIgnored private var roadErrorMessage: String?

    @ObservationIgnored private var routeTask: Task<Void, Never>?
    @ObservationIgnored private var routeGeneration = 0
    @ObservationIgnored private var routeErrorMessage: String?

    init(location: LocationService, settings: AppSettings) {
        self.location = location
        self.settings = settings
        self.client = OverpassClient(primaryEndpoint: settings.overpassEndpoint,
                                     fallbacks: AppSettings.overpassEndpoints)
    }

    // MARK: Lifecycle

    /// Starts following location updates. Safe to call repeatedly.
    func start() {
        guard listenerID == nil else { return }
        isRunning = true
        listenerID = location.addListener { [weak self] fix in
            self?.handleLocation(fix)
        }
        if let fix = location.location {
            handleLocation(fix)
        }
    }

    /// Stops following location updates and cancels a running road query. Cached data and route features are kept.
    func stop() {
        if let listenerID {
            location.removeListener(listenerID)
        }
        listenerID = nil
        isRunning = false
        roadTask?.cancel()
        roadTask = nil
        roadRequestID &+= 1
        isLoading = false
    }

    // MARK: Route features

    /// Loads hazards and signals along `polyline` (the full route geometry). Cancels a previous load. Returns when this
    /// load has finished, failed or was cancelled; results are in `routeFeatures`.
    func loadRouteFeatures(polyline: [GeoPoint]) async {
        routeTask?.cancel()
        routeTask = nil
        routeGeneration &+= 1
        let generation = routeGeneration
        routeFeatures = []
        routeFeaturesIncomplete = false
        routeErrorMessage = nil

        let route = polyline.filter { $0.isValid }
        guard settings.roadDataEnabled, route.count >= 2 else {
            isLoadingRouteFeatures = false
            updateLastError()
            return
        }
        isLoadingRouteFeatures = true
        updateLastError()

        let endpoint = settings.overpassEndpoint
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRouteLoad(route: route, endpoint: endpoint, generation: generation)
        }
        routeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Removes route features and cancels a running load (navigation ended).
    func clearRouteFeatures() {
        routeTask?.cancel()
        routeTask = nil
        routeGeneration &+= 1
        routeFeatures = []
        isLoadingRouteFeatures = false
        routeFeaturesIncomplete = false
        routeErrorMessage = nil
        updateLastError()
    }

    // MARK: - Current road

    private func handleLocation(_ fix: CLLocation) {
        guard settings.roadDataEnabled else {
            resetForDisabledRoadData()
            return
        }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxUsableAccuracy else { return }
        let position = GeoPoint(fix.coordinate)
        guard position.isValid else { return }
        lastGoodPosition = position
        rematch(at: position)
        if shouldRefresh(at: position, now: Date()) {
            startRoadRequest(at: position)
        }
    }

    /// Re-runs the matcher on the cached ways. Keeps the previous road while it is nearly as close as the best
    /// candidate, which avoids flicker at junctions and between parallel carriageways.
    private func rematch(at position: GeoPoint) {
        guard !cachedElements.isEmpty else { return }
        let heading = location.travelDirection
        var match = RoadMatcher.bestMatch(elements: cachedElements, position: position, heading: heading)
        if let best = match, let previous = currentRoad, best.wayID != previous.wayID,
           let previousWay = cachedElements.first(where: { $0.type == .way && $0.id == previous.wayID }),
           let sticky = RoadMatcher.bestMatch(elements: [previousWay], position: position, heading: heading),
           sticky.distanceToRoad <= best.distanceToRoad + Self.matchStickiness {
            match = sticky
        }
        if match != currentRoad {
            currentRoad = match
        }
    }

    private func shouldRefresh(at position: GeoPoint, now: Date) -> Bool {
        guard roadTask == nil, now >= nextRequestAllowed else { return false }
        guard let lastDate = lastRequestDate, let lastPosition = lastRequestPosition else { return true }
        // Retry after a failure as soon as the back-off allows.
        if consecutiveFailures > 0 || cacheCenter == nil { return true }

        let elapsed = now.timeIntervalSince(lastDate)
        let moved = Geo.distance(position, lastPosition)
        if let center = cacheCenter, Geo.distance(position, center) > Self.coverageRadius {
            return elapsed >= Self.coverageRequestSpacing
        }
        if moved >= Self.refreshDistance {
            return elapsed >= Self.minimumRequestSpacing
        }
        // On a road that is not in the cached data (e.g. just turned into a side street).
        if currentRoad == nil, moved >= 2 * Self.stationaryJitter {
            return elapsed >= Self.minimumRequestSpacing
        }
        return elapsed >= Self.refreshInterval && moved >= Self.stationaryJitter
    }

    private func startRoadRequest(at position: GeoPoint) {
        let query = OverpassQuery.roadsAround(position)
        let endpoint = settings.overpassEndpoint
        let client = self.client
        roadRequestID &+= 1
        let requestID = roadRequestID
        lastRequestDate = Date()
        lastRequestPosition = position
        isLoading = true
        roadTask = Task { [weak self] in
            let result: Result<[OSMElement], Error>
            do {
                await client.setPrimaryEndpoint(endpoint)
                result = .success(try await client.run(query))
            } catch {
                result = .failure(error)
            }
            self?.finishRoadRequest(result, center: position, requestID: requestID)
        }
    }

    private func finishRoadRequest(_ result: Result<[OSMElement], Error>, center: GeoPoint, requestID: Int) {
        guard requestID == roadRequestID else { return }   // superseded by stop() / a newer request
        roadTask = nil
        isLoading = false
        switch result {
        case .success(let elements):
            guard settings.roadDataEnabled else { return }
            cachedElements = elements
            cacheCenter = center
            consecutiveFailures = 0
            nextRequestAllowed = .distantPast
            roadErrorMessage = nil
            lastUpdate = Date()
            let signals = RouteFeatureExtractor.signals(from: elements)
            if signals != nearbySignals {
                nearbySignals = signals
            }
            rematch(at: lastGoodPosition ?? center)
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { return }
            consecutiveFailures += 1
            nextRequestAllowed = Date().addingTimeInterval(retryDelay(after: error))
            roadErrorMessage = Self.describe(error)
        }
        updateLastError()
    }

    /// Exponential back-off: 10, 20, 40, 80, 120 s …; at least the server's rate-limit wait.
    private func retryDelay(after error: Error) -> TimeInterval {
        let exponent = Double(min(consecutiveFailures - 1, 4))
        let backoff = min(120, Self.refreshInterval * pow(2, max(0, exponent)))
        if case OverpassClientError.rateLimited(let retryAfter) = error {
            return max(backoff, retryAfter)
        }
        return backoff
    }

    private func resetForDisabledRoadData() {
        if roadTask != nil {
            roadTask?.cancel()
            roadTask = nil
            roadRequestID &+= 1
            isLoading = false
        }
        cachedElements = []
        cacheCenter = nil
        lastRequestDate = nil
        lastRequestPosition = nil
        consecutiveFailures = 0
        nextRequestAllowed = .distantPast
        roadErrorMessage = nil
        if currentRoad != nil { currentRoad = nil }
        if !nearbySignals.isEmpty { nearbySignals = [] }
        updateLastError()
    }

    // MARK: - Route loading

    private func performRouteLoad(route: [GeoPoint], endpoint: String, generation: Int) async {
        await client.setPrimaryEndpoint(endpoint)
        let maxPoints = Self.maxRouteQueryPoints
        let baseRadius = Self.baseRouteQueryRadius
        let maxRadius = Self.maxRouteQueryRadius
        let chunkSize = OverpassQuery.maxPolylinePoints
        let plan = await Task.detached(priority: .userInitiated) {
            RouteQueryPlan(route: route, maxPoints: maxPoints, chunkSize: chunkSize,
                           baseRadius: baseRadius, maxRadius: maxRadius)
        }.value
        guard isCurrentRouteLoad(generation) else { return }

        var collected: [OSMElement] = []
        var seenKeys = Set<String>()
        var failedChunks = 0
        var lastFailure: Error?

        for (index, chunk) in plan.chunks.enumerated() {
            guard isCurrentRouteLoad(generation) else { return }
            guard settings.roadDataEnabled else {
                clearRouteFeatures()
                return
            }
            let query = OverpassQuery.featuresAlong(chunk, radius: plan.queryRadius)
            do {
                let elements = try await runRouteQuery(query)
                guard isCurrentRouteLoad(generation) else { return }
                let before = collected.count
                for element in elements where seenKeys.insert(element.key).inserted {
                    collected.append(element)
                }
                if collected.count != before {
                    let snapshot = collected
                    let features = await Task.detached(priority: .userInitiated) {
                        RouteFeatureExtractor.extract(elements: snapshot, route: plan.route, cumulative: plan.cumulative)
                    }.value
                    guard isCurrentRouteLoad(generation) else { return }
                    routeFeatures = features
                }
            } catch {
                if error is CancellationError || !isCurrentRouteLoad(generation) { return }
                failedChunks += 1
                lastFailure = error
                if case OverpassClientError.offline = error {
                    failedChunks += plan.chunks.count - index - 1
                    break
                }
                if case OverpassClientError.noValidEndpoint = error {
                    failedChunks += plan.chunks.count - index - 1
                    break
                }
            }
        }

        guard isCurrentRouteLoad(generation) else { return }
        routeFeaturesIncomplete = failedChunks > 0
        if let lastFailure {
            routeErrorMessage = Self.describe(lastFailure)
                + " (не загружено частей маршрута: \(failedChunks) из \(plan.chunks.count))"
        } else {
            routeErrorMessage = nil
        }
        isLoadingRouteFeatures = false
        routeTask = nil
        updateLastError()
    }

    /// Runs one route chunk query; when every server is rate limiting, waits (cancellably) and retries once.
    private func runRouteQuery(_ query: String) async throws -> [OSMElement] {
        do {
            return try await client.run(query)
        } catch OverpassClientError.rateLimited(let retryAfter) {
            try await Task.sleep(nanoseconds: UInt64(min(max(retryAfter, 1), 60) * 1_000_000_000))
            return try await client.run(query)
        }
    }

    private func isCurrentRouteLoad(_ generation: Int) -> Bool {
        generation == routeGeneration && !Task.isCancelled
    }

    // MARK: - Errors

    private func updateLastError() {
        let message = roadErrorMessage ?? routeErrorMessage
        if message != lastError {
            lastError = message
        }
    }

    private static func describe(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return errorPrefix + detail
    }
}

/// Geometry prepared for route feature queries (computed off the main actor).
private struct RouteQueryPlan: Sendable {
    /// Full original route.
    let route: [GeoPoint]
    /// `Geo.cumulativeDistances(route)`.
    let cumulative: [Double]
    /// Chunks of the simplified route, one Overpass query each.
    let chunks: [[GeoPoint]]
    /// `around` radius large enough to cover the original route despite simplification.
    let queryRadius: Double

    init(route: [GeoPoint], maxPoints: Int, chunkSize: Int, baseRadius: Double, maxRadius: Double) {
        self.route = route
        self.cumulative = Geo.cumulativeDistances(route)
        let simplified = Geo.simplify(route, maxPoints: maxPoints)
        self.chunks = Geo.chunk(simplified, maxPoints: max(2, chunkSize))
        // Simplification moves the query line away from the real route by up to `deviation` metres; widen the search
        // radius by that amount so features next to the real route are still found (the extractor filters by the
        // distance to the full route afterwards).
        let deviation = Self.maxDeviation(of: route, from: simplified)
        self.queryRadius = min(maxRadius, max(baseRadius, (baseRadius + deviation).rounded(.up)))
    }

    /// Largest distance of an original vertex from the simplified line. Douglas–Peucker keeps a subsequence of the
    /// original vertices, so each original vertex belongs to the simplified segment between the surrounding kept ones.
    private static func maxDeviation(of route: [GeoPoint], from simplified: [GeoPoint]) -> Double {
        guard simplified.count >= 2, route.count > simplified.count else { return 0 }
        var segment = 0
        var maximum = 0.0
        for point in route {
            if segment + 1 < simplified.count - 1, point == simplified[segment + 1] {
                segment += 1
                continue
            }
            let line = [simplified[segment], simplified[segment + 1]]
            if let projection = Geo.project(point, onto: line) {
                maximum = max(maximum, projection.distanceFromLine)
            }
        }
        return maximum
    }
}
