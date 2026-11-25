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
/// - `loadRouteFeatures` plans chunks with `RouteQueryPlanner` (light 10 m simplification, ≤ 60 vertices AND ≤ 3 km
///   per chunk, so long or winding routes are never silently thinned out) and runs one query per chunk, sequentially,
///   with a 45 s client timeout (`[timeout:25]` on the server + queueing); results are merged by element key and
///   projected onto the full original route. Features are published progressively as chunks arrive
///   (`onRouteFeaturesChanged`). Anything not loaded (failed chunks, routes beyond the chunk cap) is reported in
///   `routeFeaturesIncomplete` / `routeFeaturesCoverageNote`. Starting a new load (or `clearRouteFeatures`) cancels
///   the previous one.
///
/// Travel direction (lanes, `maxspeed:forward/backward`): the GPS course while moving ≥ 5 km/h; below that the last
/// valid course (kept for 60 s), and only then the compass, which is unreliable inside a car.
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
    /// Russian explanation of what part of the route has no OSM features loaded; nil when complete.
    private(set) var routeFeaturesCoverageNote: String?
    /// Called (on the main actor) whenever `routeFeatures` changes.
    @ObservationIgnored var onRouteFeaturesChanged: (() -> Void)?
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
    /// The previous road is kept while its match score (distance + heading penalty) is at most this much worse
    /// than the best candidate's score.
    static let matchStickiness: Double = 5
    /// Radius of the current-road query AND the matcher's `maxDistance` (kept consistent), metres.
    static let roadQueryRadius: Double = 40
    /// Radius of the traffic-signal part of the current-road query, metres.
    static let signalQueryRadius: Double = 80
    /// A GPS course older than this is not used below 5 km/h, seconds.
    static let courseMemory: TimeInterval = 60
    /// Below this speed the GPS course is unreliable, km/h.
    static let courseMinimumSpeedKmh: Double = 5
    /// Default `around` radius for route feature queries, metres (widened by the planner tolerance).
    static let baseRouteQueryRadius: Double = 35
    /// Route chunk limits (finding: long routes must not be thinned out silently).
    static let maxRouteChunkPoints = 60
    static let maxRouteChunkLength: Double = 3_000
    static let routeSimplifyTolerance: Double = 10
    /// At most this many chunk queries per route (≈ 300 km); the rest is reported as not loaded.
    static let maxRouteChunks = 100
    /// Prefix of every network error shown to the user.
    static var errorPrefix: String { L("roadInfo.errorPrefix") + " " }

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
    @ObservationIgnored private var lastValidCourse: (degrees: Double, date: Date)?
    @ObservationIgnored private var lastHeading: Double?

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
        setRouteFeatures([])
        routeFeaturesIncomplete = false
        routeFeaturesCoverageNote = nil
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
        setRouteFeatures([])
        isLoadingRouteFeatures = false
        routeFeaturesIncomplete = false
        routeFeaturesCoverageNote = nil
        routeErrorMessage = nil
        updateLastError()
    }

    private func setRouteFeatures(_ features: [RouteFeature]) {
        guard features != routeFeatures else { return }
        routeFeatures = features
        onRouteFeaturesChanged?()
    }

    // MARK: - Travel direction

    /// Direction used for lanes / speed limits: GPS course ≥ 5 km/h, else the last valid course (≤ 60 s old),
    /// else the compass heading.
    var travelHeading: Double? { lastHeading ?? location.travelDirection }

    private func updateHeading(with fix: CLLocation) {
        let speedKmh = fix.speed >= 0 ? fix.speed * 3.6 : 0
        if fix.course >= 0, speedKmh >= Self.courseMinimumSpeedKmh {
            lastValidCourse = (fix.course, fix.timestamp)
            lastHeading = fix.course
            return
        }
        if let course = lastValidCourse, fix.timestamp.timeIntervalSince(course.date) <= Self.courseMemory {
            lastHeading = course.degrees
            return
        }
        lastValidCourse = nil
        lastHeading = location.heading ?? location.course
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
        updateHeading(with: fix)
        lastGoodPosition = position
        rematch(at: position)
        if shouldRefresh(at: position, now: Date()) {
            startRoadRequest(at: position)
        }
    }

    /// Re-runs the matcher on the cached ways. Keeps the previous road while its match SCORE (distance + heading
    /// penalty) is nearly as good as the best candidate's, which avoids flicker at junctions and between parallel
    /// carriageways without sticking to a crossing road that merely happens to be close.
    private func rematch(at position: GeoPoint) {
        guard !cachedElements.isEmpty else { return }
        let heading = travelHeading
        let radius = Self.roadQueryRadius
        let best = RoadMatcher.scoredMatch(elements: cachedElements, position: position, heading: heading,
                                           maxDistance: radius)
        var match = best?.road
        if let best, let previous = currentRoad, best.road.wayID != previous.wayID,
           let previousWay = cachedElements.first(where: { $0.type == .way && $0.id == previous.wayID }),
           let sticky = RoadMatcher.scoredMatch(elements: [previousWay], position: position, heading: heading,
                                                maxDistance: radius),
           sticky.score <= best.score + Self.matchStickiness {
            match = sticky.road
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
        let query = OverpassQuery.roadsAround(position, radius: Self.roadQueryRadius,
                                              signalRadius: Self.signalQueryRadius)
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
        let maxPoints = Self.maxRouteChunkPoints
        let maxLength = Self.maxRouteChunkLength
        let tolerance = Self.routeSimplifyTolerance
        let maxChunks = Self.maxRouteChunks
        let plan = await Task.detached(priority: .userInitiated) {
            RouteQueryPlan(route: route, maxPoints: maxPoints, maxLength: maxLength, tolerance: tolerance,
                           maxChunks: maxChunks)
        }.value
        guard isCurrentRouteLoad(generation) else { return }
        let queryRadius = Self.baseRouteQueryRadius + plan.plan.maxDeviation

        var collected: [OSMElement] = []
        var seenKeys = Set<String>()
        var failedChunks = 0
        var lastFailure: Error?
        let chunks = plan.plan.chunks

        for (index, chunk) in chunks.enumerated() {
            guard isCurrentRouteLoad(generation) else { return }
            guard settings.roadDataEnabled else {
                clearRouteFeatures()
                return
            }
            let query = OverpassQuery.featuresAlong(chunk, radius: queryRadius)
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
                    setRouteFeatures(features)
                }
            } catch {
                if error is CancellationError || !isCurrentRouteLoad(generation) { return }
                failedChunks += 1
                lastFailure = error
                if case OverpassClientError.offline = error {
                    failedChunks += chunks.count - index - 1
                    break
                }
                if case OverpassClientError.noValidEndpoint = error {
                    failedChunks += chunks.count - index - 1
                    break
                }
            }
        }

        guard isCurrentRouteLoad(generation) else { return }
        var notes: [String] = []
        if failedChunks > 0 {
            notes.append(L("roadInfo.chunksFailed", failedChunks, chunks.count))
        }
        if !plan.plan.isComplete {
            notes.append(L("roadInfo.partialCoverage", RVFormat.appDistance(plan.plan.coveredLength),
                           RVFormat.appDistance(plan.plan.totalLength)))
        }
        routeFeaturesIncomplete = !notes.isEmpty
        routeFeaturesCoverageNote = notes.isEmpty ? nil
            : L("roadInfo.incomplete", notes.joined(separator: "; "))
        if let lastFailure {
            routeErrorMessage = Self.describe(lastFailure)
                + " (" + L("roadInfo.chunksFailed", failedChunks, chunks.count) + ")"
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
            return try await client.run(query, timeout: OverpassClient.routeQueryTimeout)
        } catch OverpassClientError.rateLimited(let retryAfter) {
            try await Task.sleep(nanoseconds: UInt64(min(max(retryAfter, 1), 60) * 1_000_000_000))
            return try await client.run(query, timeout: OverpassClient.routeQueryTimeout)
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
        if let overpass = error as? OverpassError { return errorPrefix + Self.describeOverpass(overpass) }
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return errorPrefix + detail
    }

    /// Localized `OverpassError.errorDescription`.
    private static func describeOverpass(_ error: OverpassError) -> String {
        switch error {
        case .htmlError(let message):
            if error.isRateLimited { return L("overpassErr.rateLimited") }
            if error.isTimeout { return L("overpassErr.timeout") }
            return L("overpassErr.html", message)
        case .invalidJSON(let message):
            return L("overpassErr.json", message)
        case .emptyResponse:
            return L("overpassErr.empty")
        }
    }
}

/// Geometry prepared for route feature queries (computed off the main actor).
private struct RouteQueryPlan: Sendable {
    /// Full original route.
    let route: [GeoPoint]
    /// `Geo.cumulativeDistances(route)`.
    let cumulative: [Double]
    /// Chunks (≤ 60 vertices, ≤ 3 km each) of the lightly simplified route.
    let plan: RouteQueryPlanner.Plan

    init(route: [GeoPoint], maxPoints: Int, maxLength: Double, tolerance: Double, maxChunks: Int) {
        self.route = route
        self.cumulative = Geo.cumulativeDistances(route)
        self.plan = RouteQueryPlanner.plan(route: route, maxPointsPerChunk: maxPoints, maxChunkLength: maxLength,
                                           tolerance: tolerance, maxChunks: maxChunks)
    }
}
