import CoreLocation
import Foundation
import MapKit
import Observation

/// One distinct route option of the preview (engine-independent), after merging the candidates of all engines.
struct RouteOption: Identifiable, Hashable {
    let id: Int
    /// Engine-independent geometry, steps, distance, time, flags and advisories.
    var route: NavRoute
    /// The original MapKit route (Apple routes only).
    var mkRoute: MKRoute?
    /// Traffic estimate (Apple ETA now vs. an off-peak departure). nil unless such an estimate exists — never faked.
    var traffic: TrafficAssessment?
    /// Signalised intersections along the route (Valhalla trace_attributes, else Overpass); nil while unknown.
    var signalCount: Int?
    /// Other engines that found (nearly) the same route, with their own estimates.
    var alsoFoundBy: [RouteEstimate] = []

    var name: String { route.name }
    var distance: Double { route.distance }
    var expectedTravelTime: Double { route.expectedTravelTime }
    var source: RouteSource { route.source }
    /// Every engine that found this route (representative first).
    var sources: [RouteSource] {
        var result = [route.source]
        for estimate in alsoFoundBy where !result.contains(estimate.source) { result.append(estimate.source) }
        return result
    }
}

/// Outcome of one routing engine for the last planning request.
struct RoutingEngineReport: Identifiable, Hashable {
    enum Status: Hashable {
        case success(routes: Int)
        case failed(String)
        case notAttempted(String)
    }

    let source: RouteSource
    var status: Status
    var id: String { source.rawValue }

    /// "Valhalla: 2 маршрута", "Apple: ошибка — …", "OSRM: не запрашивался (…)".
    var summary: String {
        switch status {
        case .success(let count):
            return "\(source.badge): " + RVFormat.appQuantity(count, unit: "route")
        case .failed(let reason):
            return L("engine.failed", source.badge, reason)
        case .notAttempted(let reason):
            return L("engine.notAttempted", source.badge, reason)
        }
    }

    var isSuccess: Bool {
        if case .success = status { return true }
        return false
    }
}

/// Errors of the navigator itself (routing engines report their own errors).
enum NavigationError: LocalizedError {
    case noLocation
    case invalidDestination
    case noRoutes
    case allEnginesFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLocation:
            return L("navErr.noLocation")
        case .invalidDestination:
            return L("navErr.invalidDestination")
        case .noRoutes:
            return L("navErr.noRoutes")
        case .allEnginesFailed(let details):
            return L("navErr.allFailed", details)
        }
    }
}

/// Route planning and turn-by-turn guidance from several free sources.
///
/// Routing (`settings.routingEngine`, see `docs/CONTRACTS.md` 2.3): "auto" queries Apple MKDirections (works only
/// where Apple supports directions — not in Uzbekistan), Valhalla and OSRM (both FOSSGIS, OpenStreetMap) concurrently.
/// Each HTTP client enforces its own ≤ 1 request/s spacing. Candidates are merged with `RouteComparison` (routes that
/// overlap ≥ 85 % are folded together, keeping every engine's estimate), ranked by expected time; the fastest is
/// selected. `engineReports` / `routingNotice` state each engine's actual outcome (success, error with reason, not
/// attempted). "apple" / "valhalla" / "osrm" use one engine only.
///
/// For the selected route the service loads (a) per-edge attributes from Valhalla `/trace_attributes` regardless of
/// the route's engine (edge_walk for Valhalla shapes, map_snap otherwise) — afterwards also for the other options so the
/// comparison cards show limits / road classes / signals; (b) OSM features along the route via `RoadInfoService`
/// (also feeding `TrafficSignalService`); (c) weather at the destination (+ midpoint for > 30 km) via
/// `RouteWeatherService`. From all of it `timeline` (ordered events) and `speedLimitSegments` are built.
///
/// During guidance every GPS fix updates `progress`, voice prompts, the current edge, a live congestion estimate from
/// the user's own speed (`CongestionEstimator` — one vehicle, not traffic data), hazards with one-time voice alerts and
/// user-reported incidents. Off-route triggers `recalculate()` (at most every 15 s); arrival stops background updates.
@Observable
@MainActor
final class NavigationService {
    enum State: Equatable { case idle, planning, previewing, navigating, arrived }

    // MARK: Published state (contract)

    private(set) var state: State = .idle {
        didSet {
            if state != oldValue { onStateChange?(oldValue, state) }
        }
    }
    /// Called on every state change (old, new) — the app uses it to stop trip recording on arrival / cancel.
    @ObservationIgnored var onStateChange: ((State, State) -> Void)?
    private(set) var destination: MKMapItem?
    /// Name of the destination, nil when there is none.
    var destinationName: String? { destination.map { PlaceSearchService.displayName(for: $0) } }
    private(set) var routeOptions: [RouteOption] = []
    /// Selected route of the preview. Changing it (while previewing) reloads the route data after a short debounce.
    /// During guidance the selection stays on the active route.
    var selectedRouteID: Int? {
        didSet {
            guard selectedRouteID != oldValue, !isApplyingRoutes else { return }
            selectionDidChange()
        }
    }
    var selectedRouteOption: RouteOption? {
        if let id = selectedRouteID, let match = routeOptions.first(where: { $0.id == id }) { return match }
        return routeOptions.first
    }
    private(set) var progress: RouteProgress?
    private(set) var errorMessage: String?
    /// Actual outcome of engines that did not deliver (e.g. "Apple Maps не построил маршрут: …"), nil when all fine.
    private(set) var routingNotice: String?
    /// Valhalla edge attributes of the selected / active route (empty when unavailable or disabled).
    private(set) var routeEdges: [RouteEdgeAttributes] = []
    /// Edge at the current position (speed limit, lanes per direction, typical speed).
    private(set) var currentEdge: RouteEdgeAttributes?
    /// Live congestion estimate on the current edge from the user's own averaged speed.
    private(set) var congestion: CongestionLevel?
    /// Hazards within 2 km ahead (from `RoadInfoService.routeFeatures`), sorted by distance.
    private(set) var upcomingFeatures: [RouteFeature] = []
    /// User-reported incidents near the selected / active route.
    private(set) var incidentsOnRoute: [IncidentOnRoute] = []

    // MARK: Published state (additional)

    /// Distances along the route of signalised intersections according to Valhalla (merged within 60 m).
    private(set) var edgeSignalDistances: [Double] = []
    /// True while Valhalla trace_attributes for the selected route are loading.
    private(set) var isLoadingRouteAttributes = false
    /// Russian explanation when route attributes could not be loaded (non-fatal).
    private(set) var routeAttributesError: String?
    /// True while a reroute is being computed.
    private(set) var isRecalculating = false
    /// Own speed averaged over the last ≈ 20 s, km/h (nil until enough samples).
    private(set) var averageSpeedKmh: Double?
    /// True while standing (< 5 km/h) within 60 m before a traffic signal (no congestion estimate then).
    private(set) var isWaitingAtSignal = false
    /// Distance to the next signalised intersection (Overpass or Valhalla), metres; nil when unknown.
    private(set) var distanceToNextSignal: Double?
    /// Outcome of every engine for the last planning / reroute.
    private(set) var engineReports: [RoutingEngineReport] = []
    /// Russian notes explaining the comparison of the options.
    private(set) var comparisonNotes: [String] = []
    /// Valhalla edge attributes per option id (selected first, then the others), for the comparison cards.
    private(set) var optionEdges: [Int: [RouteEdgeAttributes]] = [:]
    /// Ordered events along the selected / active route (maneuvers, limits, lanes, signals, OSM features, incidents).
    private(set) var timeline: [RouteTimelineEvent] = []
    /// Speed-limit stretches of the selected / active route (route strip, map colouring).
    private(set) var speedLimitSegments: [SpeedLimitSegment] = []

    /// Destination search (autocompletion, recents) shared by the navigator UI.
    let placeSearch: PlaceSearchService
    /// Weather at the destination (+ midpoint) of the selected route.
    let routeWeather = RouteWeatherService()

    // MARK: Tuning

    static let minimumRerouteInterval: TimeInterval = 15
    static let incidentRefreshInterval: TimeInterval = 30
    /// An own camera mark this close (along the route) to an OSM camera is the same camera: announced once.
    static let cameraMergeDistance: Double = 100
    static let featureLookahead: Double = 2_000
    static let speedAveragingWindow: TimeInterval = 20
    /// Minimum time span of speed samples before the average is used, seconds.
    static let minimumAveragingSpan: TimeInterval = 8
    static let signalStopRadius: Double = 60
    static let selectionDebounceNanoseconds: UInt64 = 400_000_000
    /// Non-Valhalla polylines are simplified to this many points before map matching.
    static let attributesMaxPoints = 1_000
    /// trace_attributes is skipped for longer routes (public server limit ≈ 200 km).
    static let attributesMaxRouteLength: Double = 195_000

    // MARK: Dependencies & private state

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private let roadInfo: RoadInfoService
    @ObservationIgnored private let signals: TrafficSignalService
    @ObservationIgnored private let incidents: IncidentStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let valhalla: ValhallaClient
    @ObservationIgnored private let osrm: OSRMClient

    @ObservationIgnored private var tracker: RouteProgressTracker?
    @ObservationIgnored private var voiceScheduler = VoicePromptScheduler()
    @ObservationIgnored private var activeOptionID: Int?
    /// Option whose attributes / features are loaded (or loading).
    @ObservationIgnored private var contextOptionID: Int?
    @ObservationIgnored private var contextCumulative: [Double] = []
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var planGeneration = 0
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var rerouteGeneration = 0
    @ObservationIgnored private var recalculationGeneration = 0
    @ObservationIgnored private var isApplyingRoutes = false
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var attributesTask: Task<Void, Never>?
    @ObservationIgnored private var featuresTask: Task<Void, Never>?
    @ObservationIgnored private var trafficTask: Task<Void, Never>?
    @ObservationIgnored private var incidentLoopTask: Task<Void, Never>?
    @ObservationIgnored private var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var lastRerouteAt: Date?
    @ObservationIgnored private var speedSamples: [(date: Date, kmh: Double)] = []
    @ObservationIgnored private var announcedFeatureIDs: Set<String> = []
    @ObservationIgnored private var announcedIncidentIDs: Set<UUID> = []
    @ObservationIgnored private var syncedFeatureCount = -1

    init(location: LocationService, speech: SpeechService, roadInfo: RoadInfoService,
         signals: TrafficSignalService, incidents: IncidentStore, settings: AppSettings) {
        self.location = location
        self.speech = speech
        self.roadInfo = roadInfo
        self.signals = signals
        self.incidents = incidents
        self.settings = settings
        self.valhalla = ValhallaClient(endpoint: settings.valhallaEndpoint)
        self.osrm = OSRMClient(endpoint: settings.osrmEndpoint)
        self.placeSearch = PlaceSearchService(location: location)
        roadInfo.onRouteFeaturesChanged = { [weak self] in
            self?.routeFeaturesDidChange()
        }
    }

    /// The route currently selected (preview) or being followed (guidance).
    var activeRoute: NavRoute? { selectedRouteOption?.route }

    /// Facts of an option for the comparison cards (limits / classes / signals once its attributes are loaded).
    func facts(for option: RouteOption) -> RouteFacts {
        RouteComparison.facts(for: option.route, edges: optionEdges[option.id] ?? [], signalCount: option.signalCount)
    }

    /// Distance along the active route (0 before the first fix / in the preview).
    var distanceAlong: Double { progress?.distanceAlong ?? 0 }

    /// Upcoming timeline events from the current position (all when `limit` is nil).
    func upcomingEvents(limit: Int? = nil) -> [RouteTimelineEvent] {
        RouteTimeline.upcoming(timeline, from: distanceAlong, limit: limit)
    }

    /// Estimated time until `event` is reached, seconds (typical-speed profile, scaled to the remaining time).
    func timeUntil(_ event: RouteTimelineEvent) -> Double {
        guard let option = selectedRouteOption else { return 0 }
        let total = contextCumulative.last ?? option.distance
        let remainingTime = progress?.remainingTimeSeconds ?? option.expectedTravelTime
        return RouteTimeline.timeOffset(to: event.distanceAlongRoute, from: distanceAlong, remainingTime: remainingTime,
                                        totalDistance: total, edges: routeEdges)
    }

    /// Length of the selected / active route polyline, metres.
    var routeLength: Double { contextCumulative.last ?? selectedRouteOption?.distance ?? 0 }

    // MARK: - Planning

    /// Plans routes to `item` with the configured engine policy and shows them as a preview.
    /// Any running guidance is stopped first. On failure the state returns to `.idle` with `errorMessage` set.
    func planRoutes(to item: MKMapItem) async {
        if state == .navigating || state == .arrived {
            endActiveGuidance()
        }
        planGeneration &+= 1
        let generation = planGeneration
        cancelRouteTasks()
        clearRouteState()
        destination = item
        errorMessage = nil
        state = .planning

        do {
            let planned = try await computeRoutes(to: item)
            guard generation == planGeneration, state == .planning else { return }
            applyPlannedRoutes(planned, destination: item, generation: generation)
        } catch {
            guard generation == planGeneration, state == .planning else { return }
            if !(error is CancellationError) {
                errorMessage = Self.describe(error)
            }
            destination = nil
            state = .idle
        }
    }

    private struct PlannedRoutes {
        var options: [RouteOption]
        var reports: [RoutingEngineReport]
        var notes: [String]
        var notice: String?
    }

    private func applyPlannedRoutes(_ planned: PlannedRoutes, destination item: MKMapItem, generation: Int) {
        applyOptions(planned)
        state = .previewing
        reloadRouteContext()
        startIncidentLoop()
        if planned.options.contains(where: { $0.sources.contains(.apple) }) {
            loadTrafficAssessment(to: item, generation: generation)
        }
    }

    /// Replaces the options (selection → the fastest) and the engine reports.
    private func applyOptions(_ planned: PlannedRoutes) {
        isApplyingRoutes = true
        routeOptions = planned.options
        optionEdges = [:]
        selectedRouteID = planned.options.first?.id
        isApplyingRoutes = false
        engineReports = planned.reports
        comparisonNotes = planned.notes
        routingNotice = planned.notice
    }

    private enum EngineOutcome {
        case routes([NavRoute], apple: [NavRoute: MKRoute])
        case failed(Error)
        case skipped(String)
    }

    /// Queries the engines of `settings.routingEngine` concurrently and merges their routes.
    private func computeRoutes(to item: MKMapItem) async throws -> PlannedRoutes {
        let engine = RoutingEngineOption(rawValue: settings.routingEngine) ?? .auto
        let wanted = engine.sources
        let target = GeoPoint(item.placemark.coordinate)
        guard target.isValid, target.latitude != 0 || target.longitude != 0 else {
            throw NavigationError.invalidDestination
        }
        let origin = location.coordinate
        // The heading makes Valhalla start in the direction the car is moving. While standing still only the
        // compass is available, which is unreliable inside a car, so it is passed only when moving (GPS course).
        let heading = (location.speedKmh ?? 0) >= 5 ? location.travelDirection : nil
        await valhalla.setEndpoint(settings.valhallaEndpoint)
        await osrm.setEndpoint(settings.osrmEndpoint)

        async let appleOutcome = runApple(item, enabled: wanted.contains(.apple))
        async let valhallaOutcome = runValhalla(origin: origin, target: target, heading: heading,
                                                enabled: wanted.contains(.valhalla))
        async let osrmOutcome = runOSRM(origin: origin, target: target, enabled: wanted.contains(.osrm))
        let outcomes: [(RouteSource, EngineOutcome)] = [(.apple, await appleOutcome),
                                                         (.valhalla, await valhallaOutcome),
                                                         (.osrm, await osrmOutcome)]
        try Task.checkCancellation()

        var all: [NavRoute] = []
        var appleRoutes: [NavRoute: MKRoute] = [:]
        var reports: [RoutingEngineReport] = []
        var failures: [String] = []
        for (source, outcome) in outcomes {
            switch outcome {
            case .routes(let routes, let apple):
                all.append(contentsOf: routes)
                appleRoutes.merge(apple) { first, _ in first }
                reports.append(RoutingEngineReport(source: source, status: .success(routes: routes.count)))
            case .failed(let error):
                if error is CancellationError { throw CancellationError() }
                let reason = Self.describe(error)
                failures.append("\(source.badge): \(reason)")
                reports.append(RoutingEngineReport(source: source, status: .failed(reason)))
            case .skipped(let reason):
                reports.append(RoutingEngineReport(source: source, status: .notAttempted(reason)))
            }
        }
        guard !all.isEmpty else {
            if failures.count == 1, let only = outcomes.first(where: {
                if case .failed = $0.1 { return true }
                return false
            }), case .failed(let error) = only.1 {
                throw error
            }
            throw NavigationError.allEnginesFailed(failures.joined(separator: " "))
        }

        let candidates = all
        let choices = await Task.detached(priority: .userInitiated) { RouteComparison.merge(candidates) }.value
        let options = choices.enumerated().map { index, choice in
            RouteOption(id: index, route: choice.route, mkRoute: appleRoutes[choice.route], traffic: nil,
                        signalCount: nil, alsoFoundBy: choice.duplicates)
        }
        return PlannedRoutes(options: options, reports: reports, notes: RouteComparison.notes(for: choices, language: .app),
                             notice: Self.notice(for: reports))
    }

    /// Routing notice stating each failed engine's real reason (nil when every queried engine delivered).
    static func notice(for reports: [RoutingEngineReport]) -> String? {
        let failed = reports.filter {
            if case .failed = $0.status { return true }
            return false
        }
        guard !failed.isEmpty else { return nil }
        let delivered = reports.filter(\.isSuccess).map(\.source.badge)
        var text = failed.map(\.summary).joined(separator: "; ")
        if !delivered.isEmpty {
            text += ". " + L("engine.shown", delivered.joined(separator: ", "))
        }
        return text + "."
    }

    private func runApple(_ item: MKMapItem, enabled: Bool) async -> EngineOutcome {
        guard enabled else { return .skipped(L("engine.disabled")) }
        do {
            let routes = try await appleRoutes(to: item)
            guard !routes.isEmpty else { return .failed(NavigationError.noRoutes) }
            var map: [NavRoute: MKRoute] = [:]
            for (navRoute, mkRoute) in routes { map[navRoute] = mkRoute }
            return .routes(routes.map { $0.0 }, apple: map)
        } catch {
            return .failed(error)
        }
    }

    private func runValhalla(origin: GeoPoint?, target: GeoPoint, heading: Double?, enabled: Bool) async -> EngineOutcome {
        guard enabled else { return .skipped(L("engine.disabled")) }
        guard let origin, origin.isValid else { return .failed(NavigationError.noLocation) }
        do {
            let routes = try await valhalla.routes(from: origin, to: target, heading: heading,
                                                   avoidTolls: settings.avoidTolls, avoidHighways: settings.avoidHighways)
            return .routes(routes, apple: [:])
        } catch {
            return .failed(error)
        }
    }

    private func runOSRM(origin: GeoPoint?, target: GeoPoint, enabled: Bool) async -> EngineOutcome {
        guard enabled else { return .skipped(L("engine.disabled")) }
        guard let origin, origin.isValid else { return .failed(NavigationError.noLocation) }
        do {
            let routes = try await osrm.routes(from: origin, to: target)
            // OSRM's public car profile has no toll / highway avoidance: drop routes that violate the preference.
            let filtered = routes.filter { route in
                !(settings.avoidTolls && route.hasTolls) && !(settings.avoidHighways && route.hasHighways)
            }
            guard !filtered.isEmpty else {
                return .skipped(L("engine.osrmAvoid"))
            }
            return .routes(filtered, apple: [:])
        } catch {
            return .failed(error)
        }
    }

    private func makeAppleRequest(to item: MKMapItem, departure: Date? = nil) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = item
        request.transportType = .automobile
        request.tollPreference = settings.avoidTolls ? .avoid : .any
        request.highwayPreference = settings.avoidHighways ? .avoid : .any
        if let departure { request.departureDate = departure }
        return request
    }

    private func appleRoutes(to item: MKMapItem) async throws -> [(NavRoute, MKRoute)] {
        let request = makeAppleRequest(to: item)
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        var result: [(NavRoute, MKRoute)] = []
        for route in response.routes {
            let polyline = route.polyline.geoPoints
            guard polyline.count >= 2 else { continue }
            let steps = route.steps.map {
                RouteStepInfo(instruction: $0.instructions, distance: $0.distance, notice: $0.notice)
            }
            let name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let navRoute = NavRoute(source: .apple, name: name.isEmpty ? L("route.appleName") : name,
                                    polyline: polyline, distance: route.distance,
                                    expectedTravelTime: route.expectedTravelTime, steps: steps,
                                    hasTolls: route.hasTolls, hasHighways: route.hasHighways,
                                    advisories: route.advisoryNotices)
            result.append((navRoute, route))
        }
        return result
    }

    /// Apple only: two `calculateETA()` requests from separate `MKDirections` objects — departure now and at the next
    /// 03:00 (free flow) — and a `TrafficAssessment` on each Apple option whose distance matches BOTH responses within
    /// 3 %. Nothing is stored when either request fails (never faked).
    private func loadTrafficAssessment(to item: MKMapItem, generation: Int) {
        trafficTask?.cancel()
        let nowRequest = makeAppleRequest(to: item, departure: Date())
        let offPeakRequest = makeAppleRequest(to: item, departure: TrafficDelay.nextOffPeakDate(after: Date()))
        trafficTask = Task { [weak self] in
            guard let now = try? await MKDirections(request: nowRequest).calculateETA(),
                  !Task.isCancelled,
                  let offPeak = try? await MKDirections(request: offPeakRequest).calculateETA() else { return }
            guard let self, !Task.isCancelled, generation == self.planGeneration else { return }
            let current = now.expectedTravelTime, freeFlow = offPeak.expectedTravelTime
            guard current > 0, freeFlow > 0, now.distance > 0, offPeak.distance > 0 else { return }
            for index in self.routeOptions.indices where self.routeOptions[index].source == .apple {
                let distance = self.routeOptions[index].distance
                guard abs(distance - now.distance) / now.distance <= 0.03,
                      abs(distance - offPeak.distance) / offPeak.distance <= 0.03 else { continue }
                self.routeOptions[index].traffic = TrafficAssessment(currentSeconds: current, freeFlowSeconds: freeFlow)
            }
        }
    }

    // MARK: - Selection & route context

    private func selectionDidChange() {
        switch state {
        case .previewing:
            selectionTask?.cancel()
            selectionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: NavigationService.selectionDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                self?.reloadRouteContext()
            }
        case .navigating, .arrived:
            // The active route is fixed during guidance.
            if selectedRouteID != activeOptionID {
                isApplyingRoutes = true
                selectedRouteID = activeOptionID
                isApplyingRoutes = false
            }
        case .idle, .planning:
            break
        }
    }

    /// Reloads edge attributes, OSM features, signals, incidents, weather and the timeline for the selected route.
    /// The previous route's features and signals are cleared synchronously, so a fix processed right after a reroute
    /// never runs against the old route's data.
    private func reloadRouteContext() {
        selectionTask?.cancel()
        selectionTask = nil
        attributesTask?.cancel()
        attributesTask = nil
        featuresTask?.cancel()
        featuresTask = nil
        contextGeneration &+= 1
        let generation = contextGeneration

        currentEdge = nil
        congestion = nil
        upcomingFeatures = []
        distanceToNextSignal = nil
        routeAttributesError = nil
        isLoadingRouteAttributes = false
        syncedFeatureCount = -1
        roadInfo.clearRouteFeatures()
        signals.setRouteSignals([])

        guard let option = selectedRouteOption else {
            contextOptionID = nil
            contextCumulative = []
            incidentsOnRoute = []
            routeEdges = []
            edgeSignalDistances = []
            routeWeather.clear()
            rebuildTimeline()
            return
        }
        let polyline = option.route.polyline
        let optionID = option.id
        contextOptionID = optionID
        contextCumulative = Geo.cumulativeDistances(polyline)
        let cached = optionEdges[optionID] ?? []
        routeEdges = cached
        edgeSignalDistances = Valhalla.signalDistances(in: cached)
        refreshIncidents()
        routeWeather.load(route: option.route)
        rebuildTimeline()

        if settings.routeAttributesEnabled {
            if (contextCumulative.last ?? 0) > Self.attributesMaxRouteLength {
                routeAttributesError = L("route.attrs.tooLong")
            } else {
                isLoadingRouteAttributes = cached.isEmpty
                attributesTask = Task { [weak self] in
                    await self?.loadAttributes(selectedID: optionID, generation: generation)
                }
            }
        }
        featuresTask = Task { [weak self] in
            await self?.loadFeatures(polyline: polyline, generation: generation)
        }
    }

    /// Valhalla trace_attributes for the selected option first, then for the other options (comparison cards).
    private func loadAttributes(selectedID: Int, generation: Int) async {
        let order = [selectedID] + routeOptions.map(\.id).filter { $0 != selectedID }
        for id in order {
            guard generation == contextGeneration, !Task.isCancelled else { return }
            guard optionEdges[id] == nil, let option = routeOptions.first(where: { $0.id == id }) else { continue }
            let polyline = option.route.polyline
            let length = Geo.polylineLength(polyline)
            guard length <= Self.attributesMaxRouteLength else { continue }
            let edgeWalk = option.source == .valhalla
            let input = edgeWalk ? polyline : Geo.simplify(polyline, maxPoints: Self.attributesMaxPoints)
            await valhalla.setEndpoint(settings.valhallaEndpoint)
            do {
                let raw = try await valhalla.traceAttributes(polyline: input, edgeWalk: edgeWalk)
                guard generation == contextGeneration, !Task.isCancelled else { return }
                let edges = Self.rescaled(raw, toLength: length)
                optionEdges[id] = edges
                if let index = routeOptions.firstIndex(where: { $0.id == id }) {
                    routeOptions[index].signalCount = Valhalla.signalDistances(in: edges).count
                }
                if id == selectedRouteOption?.id {
                    routeEdges = edges
                    edgeSignalDistances = Valhalla.signalDistances(in: edges)
                    isLoadingRouteAttributes = false
                    if let progress {
                        currentEdge = Valhalla.attributes(at: progress.distanceAlong, in: edges)
                    }
                    rebuildTimeline()
                }
            } catch {
                guard generation == contextGeneration else { return }
                if error is CancellationError || Task.isCancelled { return }
                if id == selectedRouteOption?.id {
                    isLoadingRouteAttributes = false
                    routeAttributesError = L("route.attrs.unavailable") + " "
                        + Self.describe(error)
                }
            }
        }
    }

    private func loadFeatures(polyline: [GeoPoint], generation: Int) async {
        await roadInfo.loadRouteFeatures(polyline: polyline)
        guard generation == contextGeneration, !Task.isCancelled else { return }
        routeFeaturesDidChange()
    }

    /// Called whenever `roadInfo.routeFeatures` changes (progressively while loading).
    private func routeFeaturesDidChange() {
        guard state != .idle, state != .planning else { return }
        syncRouteSignals(force: true)
        if let index = routeOptions.firstIndex(where: { $0.id == contextOptionID }),
           optionEdges[routeOptions[index].id] == nil, !roadInfo.isLoadingRouteFeatures {
            let count = roadInfo.routeFeatures.filter { $0.kind == .trafficSignals }.count
            if count > 0 || roadInfo.lastError == nil {
                routeOptions[index].signalCount = count
            }
        }
        refreshUpcomingFeatures(distanceAlong: distanceAlong)
        rebuildTimeline()
    }

    private func rebuildTimeline() {
        guard state != .idle, let option = selectedRouteOption else {
            if !timeline.isEmpty { timeline = [] }
            if !speedLimitSegments.isEmpty { speedLimitSegments = [] }
            return
        }
        let events = RouteTimeline.build(route: option.route, edges: routeEdges, features: visibleRouteFeatures,
                                         incidents: incidentsOnRoute, text: .app)
        if events != timeline { timeline = events }
        let segments = RouteTimeline.speedLimitSegments(edges: routeEdges, totalDistance: contextCumulative.last)
        if segments != speedLimitSegments { speedLimitSegments = segments }
    }

    /// Stretches edge distances measured on the matched shape to the route polyline length (map matching of a
    /// simplified polyline gives a slightly different length). Only small corrections (± 20 %) are applied.
    static func rescaled(_ edges: [RouteEdgeAttributes], toLength length: Double) -> [RouteEdgeAttributes] {
        guard let end = edges.last?.endDistance, end > 0, length > 0 else { return edges }
        let factor = length / end
        guard factor > 0.8, factor < 1.25, abs(factor - 1) > 0.002 else { return edges }
        return edges.map { edge in
            var scaled = edge
            scaled.startDistance *= factor
            scaled.endDistance *= factor
            return scaled
        }
    }

    /// Passes the (progressively loaded) route features to the signal service when they changed.
    private func syncRouteSignals(force: Bool = false) {
        let features = roadInfo.routeFeatures
        guard force || features.count != syncedFeatureCount else { return }
        syncedFeatureCount = features.count
        signals.setRouteSignals(features)
    }

    /// OSM route features the user wants to see: speed cameras are dropped when «Cameras from OpenStreetMap» is off.
    /// Everything shown or announced from OSM features (timeline, map markers, `upcomingFeatures` → voice alerts and
    /// the driver coach) goes through this list; traffic signals still use the full `roadInfo.routeFeatures`.
    private var visibleRouteFeatures: [RouteFeature] {
        let features = roadInfo.routeFeatures
        return settings.osmCamerasEnabled ? features : features.filter { $0.kind != .speedCamera }
    }

    /// Re-applies the camera / event source settings (OSM cameras, own marks) to the timeline, upcoming features and
    /// incidents on the route. Call after one of these toggles changed.
    func applyDataSourceSettings() {
        refreshIncidents()
        refreshUpcomingFeatures(distanceAlong: distanceAlong)
        rebuildTimeline()
    }

    /// Recomputes `incidentsOnRoute` for the selected / active route (also call after reporting an incident).
    /// Empty when the user turned off «My marks of cameras and events».
    func refreshIncidents() {
        guard state != .idle, settings.ownMarksEnabled, let option = selectedRouteOption else {
            if !incidentsOnRoute.isEmpty {
                incidentsOnRoute = []
                rebuildTimeline()
            }
            return
        }
        let polyline = option.route.polyline
        let cumulative = contextCumulative.count == polyline.count ? contextCumulative : nil
        let items = incidents.along(route: polyline, cumulative: cumulative)
        if items != incidentsOnRoute {
            incidentsOnRoute = items
            rebuildTimeline()
        }
    }

    private func startIncidentLoop() {
        incidentLoopTask?.cancel()
        incidentLoopTask = Task { [weak self] in
            let interval = UInt64(NavigationService.incidentRefreshInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshIncidents()
                self.syncRouteSignals()
            }
        }
    }

    // MARK: - Guidance

    /// Starts turn-by-turn guidance on the selected route.
    func startNavigation() {
        guard state == .previewing, let option = selectedRouteOption else { return }
        selectionTask?.cancel()
        selectionTask = nil
        beginGuidance(on: option)
        announcedFeatureIDs = []
        announcedIncidentIDs = []
        speedSamples = []
        averageSpeedKmh = nil
        lastRerouteAt = nil
        errorMessage = nil
        state = .navigating
        if contextOptionID != option.id {
            reloadRouteContext()
        }
        location.start()
        location.setBackgroundUpdates(true)
        attachLocationListener()
        if incidentLoopTask == nil { startIncidentLoop() }
        if settings.voiceGuidanceEnabled {
            let text = L("voice.routeReady", Self.spokenDistance(option.distance), Self.spokenDuration(option.expectedTravelTime))
            // Clips: only "Route ready" (distance and time are on screen); the system voice reads the full text.
            speech.speak(VoicePhrase.fixed("route_ready", text: text), priority: .high)
        }
        if let fix = location.location {
            handleFix(fix)
        }
    }

    /// Ends guidance / preview and resets everything to `.idle` (no destination).
    func stopNavigation() {
        planGeneration &+= 1
        endActiveGuidance()
        cancelRouteTasks()
        clearRouteState()
        destination = nil
        errorMessage = nil
        state = .idle
    }

    /// Reroutes from the current position to the same destination with the same engine policy
    /// (used when off-route; calls less than 15 s after the previous reroute are ignored).
    func recalculate() async {
        guard state == .navigating, let destination, !isRecalculating else { return }
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < Self.minimumRerouteInterval { return }
        lastRerouteAt = Date()
        recalculationGeneration &+= 1
        let token = recalculationGeneration
        isRecalculating = true
        // A stale run (guidance ended / restarted meanwhile) must not clear the flag of a newer one.
        defer {
            if token == recalculationGeneration { isRecalculating = false }
        }
        let generation = planGeneration
        if settings.voiceGuidanceEnabled {
            speech.speak(VoicePhrase.fixed("rerouting", text: L("voice.rerouting")), priority: .high)
        }
        do {
            let planned = try await computeRoutes(to: destination)
            guard generation == planGeneration, token == recalculationGeneration, state == .navigating,
                  let first = planned.options.first else { return }
            applyOptions(planned)
            beginGuidance(on: first)
            // Clears the old route's features / signals synchronously before the first fix on the new route.
            reloadRouteContext()
            if let fix = location.location {
                handleFix(fix)
            }
        } catch {
            guard generation == planGeneration, token == recalculationGeneration, state == .navigating,
                  !(error is CancellationError) else { return }
            errorMessage = L("route.rerouteFailed") + " " + Self.describe(error)
        }
    }

    /// Clears the error banner.
    func dismissError() {
        errorMessage = nil
    }

    private func beginGuidance(on option: RouteOption) {
        activeOptionID = option.id
        isApplyingRoutes = true
        selectedRouteID = option.id
        isApplyingRoutes = false
        tracker = RouteProgressTracker(polyline: option.route.polyline, steps: option.route.steps,
                                       expectedTravelTime: option.route.expectedTravelTime)
        tracker?.language = .app
        voiceScheduler = VoicePromptScheduler()
        progress = nil
    }

    private func attachLocationListener() {
        guard listenerID == nil else { return }
        listenerID = location.addListener { [weak self] fix in
            self?.handleFix(fix)
        }
    }

    private func detachLocationListener() {
        if let listenerID {
            location.removeListener(listenerID)
        }
        listenerID = nil
    }

    /// Stops location-driven guidance (listener, background updates, reroute) without touching route data.
    private func endActiveGuidance() {
        detachLocationListener()
        location.setBackgroundUpdates(false)
        rerouteTask?.cancel()
        rerouteTask = nil
        rerouteGeneration &+= 1
        recalculationGeneration &+= 1
        isRecalculating = false
        tracker = nil
        activeOptionID = nil
    }

    private func cancelRouteTasks() {
        selectionTask?.cancel()
        selectionTask = nil
        attributesTask?.cancel()
        attributesTask = nil
        featuresTask?.cancel()
        featuresTask = nil
        trafficTask?.cancel()
        trafficTask = nil
        incidentLoopTask?.cancel()
        incidentLoopTask = nil
    }

    private func clearRouteState() {
        isApplyingRoutes = true
        routeOptions = []
        selectedRouteID = nil
        isApplyingRoutes = false
        contextGeneration &+= 1
        contextOptionID = nil
        contextCumulative = []
        progress = nil
        routingNotice = nil
        engineReports = []
        comparisonNotes = []
        optionEdges = [:]
        routeEdges = []
        edgeSignalDistances = []
        currentEdge = nil
        congestion = nil
        upcomingFeatures = []
        incidentsOnRoute = []
        timeline = []
        speedLimitSegments = []
        isLoadingRouteAttributes = false
        routeAttributesError = nil
        averageSpeedKmh = nil
        isWaitingAtSignal = false
        distanceToNextSignal = nil
        speedSamples = []
        announcedFeatureIDs = []
        announcedIncidentIDs = []
        syncedFeatureCount = -1
        roadInfo.clearRouteFeatures()
        signals.setRouteSignals([])
        routeWeather.clear()
    }

    private func arrive() {
        state = .arrived
        detachLocationListener()
        location.setBackgroundUpdates(false)
        rerouteTask?.cancel()
        rerouteTask = nil
        rerouteGeneration &+= 1
        incidentLoopTask?.cancel()
        incidentLoopTask = nil
        congestion = nil
        isWaitingAtSignal = false
        upcomingFeatures = []
        if settings.voiceGuidanceEnabled {
            speech.speak(VoicePhrase.fixed("arrived", text: L("voice.arrived")), priority: .high)
        }
    }

    // MARK: - Per-fix processing

    private func handleFix(_ fix: CLLocation) {
        guard state == .navigating, let tracker else { return }
        let position = GeoPoint(fix.coordinate)
        guard position.isValid else { return }
        let speed: Double? = fix.speed >= 0 ? fix.speed * 3.6 : nil
        recordSpeed(speed, at: fix.timestamp)

        let accuracy: Double? = fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil
        let current = tracker.update(position: position, horizontalAccuracy: accuracy)
        progress = current
        if current.hasArrived {
            arrive()
            return
        }
        syncRouteSignals()
        updateRoadContext(current, speedKmh: speed)
        if current.isOffRoute {
            requestReroute()
            return
        }
        announceManeuver(current, speedKmh: speed)
        announceHazard(current, speedKmh: speed)
        announceIncident(current)
    }

    private func recordSpeed(_ kmh: Double?, at date: Date) {
        if let kmh, kmh.isFinite {
            speedSamples.append((date: date, kmh: kmh))
        }
        let cutoff = date.addingTimeInterval(-Self.speedAveragingWindow)
        speedSamples.removeAll { $0.date < cutoff }
        if let first = speedSamples.first, let last = speedSamples.last,
           last.date.timeIntervalSince(first.date) >= Self.minimumAveragingSpan {
            averageSpeedKmh = speedSamples.reduce(0) { $0 + $1.kmh } / Double(speedSamples.count)
        } else {
            averageSpeedKmh = nil
        }
    }

    private func updateRoadContext(_ current: RouteProgress, speedKmh: Double?) {
        let along = current.distanceAlong
        let edge = Valhalla.attributes(at: along, in: routeEdges)
        if edge != currentEdge { currentEdge = edge }
        refreshUpcomingFeatures(distanceAlong: along)

        var nextSignal = signals.upcoming(fromDistance: along, limit: 1).first?.distanceAhead
        if let edgeSignal = edgeSignalDistances.first(where: { $0 >= along - 10 }) {
            nextSignal = min(nextSignal ?? .infinity, max(0, edgeSignal - along))
        }
        distanceToNextSignal = nextSignal
        isWaitingAtSignal = (nextSignal ?? .infinity) <= Self.signalStopRadius && (speedKmh ?? 0) < 5

        if current.isOffRoute {
            congestion = nil
        } else {
            congestion = CongestionEstimator.level(ownSpeedKmh: averageSpeedKmh,
                                                   typicalSpeedKmh: currentEdge?.typicalSpeedKmh,
                                                   stoppedAtSignal: isWaitingAtSignal)
        }
    }

    private func refreshUpcomingFeatures(distanceAlong along: Double) {
        let ahead = visibleRouteFeatures.filter {
            let distance = $0.distanceAlongRoute - along
            return distance >= -5 && distance <= Self.featureLookahead
        }
        if ahead != upcomingFeatures {
            upcomingFeatures = ahead
        }
    }

    /// Starts a reroute task. The task clears `rerouteTask` only if it is still the current one (a stale task finishing
    /// after guidance was restarted must not clear the newer task).
    private func requestReroute() {
        guard !isRecalculating, rerouteTask == nil else { return }
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < Self.minimumRerouteInterval { return }
        rerouteGeneration &+= 1
        let generation = rerouteGeneration
        rerouteTask = Task { [weak self] in
            await self?.recalculate()
            guard let self, self.rerouteGeneration == generation else { return }
            self.rerouteTask = nil
        }
    }

    private func announceManeuver(_ current: RouteProgress, speedKmh: Double?) {
        guard settings.voiceGuidanceEnabled,
              let distance = current.distanceToNextManeuver,
              let instruction = current.nextInstruction else { return }
        let stepIndex = current.nextStepIndex ?? (tracker?.steps.count ?? 0)
        voiceScheduler.language = .app
        if let prompt = voiceScheduler.prompt(stepIndex: stepIndex, distance: distance,
                                              instruction: instruction, speedKmh: speedKmh) {
            // The closest threshold gets the distance back plus a caution (and slow-down) phrase.
            let phrase = distance <= NavigationPhrases.closeDistance
                ? NavigationPhrases.closeManeuverPhrase(maneuver: current.nextManeuver, instruction: instruction,
                                                        distance: distance, speedKmh: speedKmh)
                : NavigationPhrases.maneuverPhrase(maneuver: current.nextManeuver, instruction: instruction,
                                                   distance: distance, text: prompt)
            speech.speak(phrase, priority: distance <= 150 ? .high : .normal)
        }
    }

    /// One-time voice alert for the nearest relevant hazard within its alert distance (one per fix).
    private func announceHazard(_ current: RouteProgress, speedKmh: Double?) {
        guard settings.voiceGuidanceEnabled else { return }
        for feature in upcomingFeatures where !announcedFeatureIDs.contains(feature.id) {
            let ahead = feature.distanceAlongRoute - current.distanceAlong
            guard ahead >= 0, ahead <= feature.kind.alertDistance,
                  let text = Self.hazardPrompt(for: feature.kind, speedKmh: speedKmh) else { continue }
            announcedFeatureIDs.insert(feature.id)
            speech.speak(VoicePhrase.hazard(feature.kind, text: text), priority: .normal)
            break
        }
    }

    /// One-time voice alert for a user-reported incident ahead (700 m; own camera marks 500 m, announced like OSM
    /// cameras — and skipped when a visible OSM camera is within `cameraMergeDistance` of the mark).
    private func announceIncident(_ current: RouteProgress) {
        guard settings.voiceGuidanceEnabled else { return }
        for item in incidentsOnRoute where !announcedIncidentIDs.contains(item.id) {
            let kind = item.incident.kind
            let ahead = item.distanceAlongRoute - current.distanceAlong
            guard ahead >= 0, ahead <= kind.alertDistance else { continue }
            announcedIncidentIDs.insert(item.id)
            if kind == .speedCamera {
                let duplicatesOSMCamera = upcomingFeatures.contains {
                    $0.kind == .speedCamera && abs($0.distanceAlongRoute - item.distanceAlongRoute) <= Self.cameraMergeDistance
                }
                if duplicatesOSMCamera { continue }
                speech.speak(VoicePhrase.hazard(.speedCamera, text: L("voice.hazard.speedCamera")), priority: .normal)
                break
            }
            let text = L("voice.incidentAhead", Self.spokenName(kind), Self.spokenDistance(ahead))
            speech.speak(VoicePhrase.incident(kind, distance: ahead, text: text), priority: .normal)
            break
        }
    }

    // MARK: - Texts

    /// Spoken hazard warning, nil for kinds that are not announced (or not at this speed).
    static func hazardPrompt(for kind: RouteFeatureKind, speedKmh: Double?) -> String? {
        let speed = speedKmh ?? 0
        switch kind {
        case .speedCamera: return L("voice.hazard.speedCamera")
        case .school: return L("voice.hazard.school")
        case .kindergarten: return L("voice.hazard.kindergarten")
        case .railwayCrossing: return L("voice.hazard.railway")
        case .pedestrianCrossing: return speed > 40 ? L("voice.hazard.crossing") : nil
        case .construction: return L("voice.hazard.construction")
        case .trafficCalming: return speed > 30 ? L("voice.hazard.bump") : nil
        case .trafficSignals, .stopSign, .giveWay, .fuel, .parking: return nil
        }
    }

    /// Incident kind in a form that reads naturally after "Впереди …".
    static func spokenName(_ kind: RoadIncidentKind) -> String {
        L("voice.incident.\(kind.rawValue)")
    }

    /// "600 метров", "1,5 километра", "12 километров".
    static func spokenDistance(_ meters: Double) -> String {
        let m = max(0, meters.isFinite ? meters : 0)
        if m < 975 {
            let n = max(50, Int((m / 50).rounded()) * 50)
            return RVFormat.appQuantity(n, unit: "meter")
        }
        if m < 9_950 {
            let km = (m / 100).rounded() / 10
            if km == km.rounded() {
                let n = Int(km)
                return RVFormat.appQuantity(n, unit: "km")
            }
            return RVFormat.appFractionQuantity(km, unit: "km")
        }
        let n = Int((m / 1000).rounded())
        return RVFormat.appQuantity(n, unit: "km")
    }

    /// "1 минуту", "25 минут", "1 час 5 минут" (accusative, after "примерно").
    static func spokenDuration(_ seconds: Double) -> String {
        let total = max(1, Int(((seconds.isFinite ? seconds : 0) / 60).rounded()))
        func minutes(_ n: Int) -> String { RVFormat.appQuantity(n, unit: "minuteAcc") }
        if total < 60 { return minutes(total) }
        let hours = total / 60, rest = total % 60
        let hoursText = RVFormat.appQuantity(hours, unit: "hour")
        return rest == 0 ? hoursText : "\(hoursText) \(minutes(rest))"
    }

    /// Localized description of a routing error.
    static func describe(_ error: Error) -> String {
        if let navigationError = error as? NavigationError {
            return navigationError.errorDescription ?? L("navErr.generic")
        }
        if let valhallaError = error as? ValhallaClientError {
            return valhallaError.errorDescription ?? L("navErr.valhalla")
        }
        if let osrmError = error as? OSRMClientError {
            return osrmError.errorDescription ?? L("navErr.osrm")
        }
        if let mkError = error as? MKError {
            // State the actual error (code + system text) instead of guessing the cause.
            let code = mkError.code.rawValue
            let text = mkError.localizedDescription
            switch mkError.code {
            case .directionsNotFound:
                return L("mkErr.notFound", code, text)
            case .placemarkNotFound:
                return L("mkErr.placemark", code, text)
            case .loadingThrottled:
                return L("mkErr.throttled", code)
            case .serverFailure:
                return L("mkErr.server", code, text)
            default:
                return L("mkErr.other", code, text)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return L("net.noInternetFull")
            case .timedOut:
                return L("net.timeoutFull")
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
