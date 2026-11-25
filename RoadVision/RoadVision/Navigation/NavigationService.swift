import CoreLocation
import Foundation
import MapKit
import Observation

/// One route alternative of the route preview (engine-independent).
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

    var name: String { route.name }
    var distance: Double { route.distance }
    var expectedTravelTime: Double { route.expectedTravelTime }
    var source: RouteSource { route.source }
}

/// Values of `AppSettings.routingEngine`.
enum RoutingEngineOption: String, CaseIterable, Identifiable {
    /// MKDirections first; any error or an empty result → Valhalla (OpenStreetMap).
    case auto
    /// MKDirections only.
    case apple
    /// Valhalla (OpenStreetMap) only.
    case valhalla

    var id: String { rawValue }

    /// Russian label for Settings.
    var displayName: String {
        switch self {
        case .auto: return "Авто: Apple, при ошибке OSM"
        case .apple: return "Только Apple Maps"
        case .valhalla: return "Только OpenStreetMap (Valhalla)"
        }
    }
}

/// Errors of the navigator itself (routing engines report their own errors).
enum NavigationError: LocalizedError {
    case noLocation
    case invalidDestination
    case noRoutes
    case allEnginesFailed(apple: String, osm: String)

    var errorDescription: String? {
        switch self {
        case .noLocation:
            return "Нет данных о местоположении. Проверьте доступ к геолокации."
        case .invalidDestination:
            return "У выбранного места нет координат."
        case .noRoutes:
            return "Маршрут не найден."
        case .allEnginesFailed(let apple, let osm):
            return "Маршрут не построен. Apple Maps: \(apple) OpenStreetMap: \(osm)"
        }
    }
}

/// Route planning and turn-by-turn guidance.
///
/// Routing follows `settings.routingEngine` (see `docs/CONTRACTS.md` 2.3): Apple's MKDirections does not work in
/// Uzbekistan, so in "auto" mode ANY Apple error (or an empty result) falls back to Valhalla / OpenStreetMap and
/// `routingNotice` says so.
///
/// For the selected route the service loads (a) per-edge attributes from Valhalla `/trace_attributes` (speed limits,
/// lanes per direction, typical speed, signals) and (b) hazards along the route from Overpass via `RoadInfoService`,
/// which also feed `TrafficSignalService`. Both reload (debounced, previous loads cancelled) when the selection changes.
///
/// During guidance every GPS fix updates `progress` (`RouteProgressTracker`), voice prompts (`VoicePromptScheduler`),
/// the current edge, a live congestion estimate from the user's own speed (`CongestionEstimator` — one vehicle, not
/// traffic data), hazards within 2 km with one-time voice alerts, and user-reported incidents on the route.
/// Off-route triggers `recalculate()` (at most every 15 s); arrival stops background location updates.
@Observable
@MainActor
final class NavigationService {
    enum State: Equatable { case idle, planning, previewing, navigating, arrived }

    // MARK: Published state (contract)

    private(set) var state: State = .idle
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
    /// e.g. "Apple Maps не строит маршруты здесь — маршрут по данным OpenStreetMap (Valhalla)".
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

    /// Destination search (autocompletion, recents) shared by the navigator UI.
    let placeSearch: PlaceSearchService

    // MARK: Tuning

    static let minimumRerouteInterval: TimeInterval = 15
    static let incidentRefreshInterval: TimeInterval = 30
    static let incidentAlertDistance: Double = 700
    static let featureLookahead: Double = 2_000
    static let speedAveragingWindow: TimeInterval = 20
    /// Minimum time span of speed samples before the average is used, seconds.
    static let minimumAveragingSpan: TimeInterval = 8
    static let signalStopRadius: Double = 60
    static let selectionDebounceNanoseconds: UInt64 = 400_000_000
    /// Apple polylines are simplified to this many points before map matching.
    static let attributesMaxPoints = 1_000
    /// trace_attributes is skipped for longer routes (public server limit ≈ 200 km).
    static let attributesMaxRouteLength: Double = 195_000
    static let appleFallbackNotice = "Apple Maps не строит маршруты здесь — маршрут по данным OpenStreetMap (Valhalla)"

    // MARK: Dependencies & private state

    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let speech: SpeechService
    @ObservationIgnored private let roadInfo: RoadInfoService
    @ObservationIgnored private let signals: TrafficSignalService
    @ObservationIgnored private let incidents: IncidentStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let valhalla: ValhallaClient

    @ObservationIgnored private var tracker: RouteProgressTracker?
    @ObservationIgnored private var voiceScheduler = VoicePromptScheduler()
    @ObservationIgnored private var activeOptionID: Int?
    /// Option whose attributes / features are loaded (or loading).
    @ObservationIgnored private var contextOptionID: Int?
    @ObservationIgnored private var contextCumulative: [Double] = []
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var planGeneration = 0
    @ObservationIgnored private var contextGeneration = 0
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
        self.placeSearch = PlaceSearchService(location: location)
    }

    /// The route currently selected (preview) or being followed (guidance).
    var activeRoute: NavRoute? { selectedRouteOption?.route }

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
        var notice: String?
    }

    private func applyPlannedRoutes(_ planned: PlannedRoutes, destination item: MKMapItem, generation: Int) {
        isApplyingRoutes = true
        routeOptions = planned.options
        selectedRouteID = planned.options.first?.id
        isApplyingRoutes = false
        routingNotice = planned.notice
        state = .previewing
        reloadRouteContext()
        startIncidentLoop()
        if planned.options.contains(where: { $0.source == .apple }) {
            loadTrafficAssessment(to: item, generation: generation)
        }
    }

    /// Routes according to `settings.routingEngine` ("auto" | "apple" | "valhalla").
    private func computeRoutes(to item: MKMapItem) async throws -> PlannedRoutes {
        let engine = RoutingEngineOption(rawValue: settings.routingEngine) ?? .auto
        switch engine {
        case .apple:
            let options = try await appleRoutes(to: item)
            guard !options.isEmpty else { throw NavigationError.noRoutes }
            return PlannedRoutes(options: options, notice: nil)
        case .valhalla:
            return PlannedRoutes(options: try await valhallaRoutes(to: item), notice: nil)
        case .auto:
            let appleFailure: Error
            do {
                let options = try await appleRoutes(to: item)
                if !options.isEmpty { return PlannedRoutes(options: options, notice: nil) }
                appleFailure = NavigationError.noRoutes
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                appleFailure = error
            }
            do {
                let options = try await valhallaRoutes(to: item)
                return PlannedRoutes(options: options, notice: Self.appleFallbackNotice)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NavigationError.allEnginesFailed(apple: Self.describe(appleFailure), osm: Self.describe(error))
            }
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

    private func appleRoutes(to item: MKMapItem) async throws -> [RouteOption] {
        let request = makeAppleRequest(to: item)
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        var options: [RouteOption] = []
        for route in response.routes {
            let polyline = route.polyline.geoPoints
            guard polyline.count >= 2 else { continue }
            let steps = route.steps.map {
                RouteStepInfo(instruction: $0.instructions, distance: $0.distance, notice: $0.notice)
            }
            let name = route.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let navRoute = NavRoute(source: .apple, name: name.isEmpty ? "Маршрут Apple Maps" : name,
                                    polyline: polyline, distance: route.distance,
                                    expectedTravelTime: route.expectedTravelTime, steps: steps,
                                    hasTolls: route.hasTolls, hasHighways: route.hasHighways,
                                    advisories: route.advisoryNotices)
            options.append(RouteOption(id: options.count, route: navRoute, mkRoute: route,
                                       traffic: nil, signalCount: nil))
        }
        return options
    }

    private func valhallaRoutes(to item: MKMapItem) async throws -> [RouteOption] {
        guard let origin = location.coordinate, origin.isValid else { throw NavigationError.noLocation }
        let target = GeoPoint(item.placemark.coordinate)
        guard target.isValid, target.latitude != 0 || target.longitude != 0 else {
            throw NavigationError.invalidDestination
        }
        // The heading makes Valhalla start in the direction the car is moving. While standing still only the
        // compass is available, which is unreliable inside a car, so it is passed only when moving (GPS course).
        let heading = (location.speedKmh ?? 0) >= 5 ? location.travelDirection : nil
        await valhalla.setEndpoint(settings.valhallaEndpoint)
        let routes = try await valhalla.routes(from: origin, to: target, heading: heading,
                                               avoidTolls: settings.avoidTolls, avoidHighways: settings.avoidHighways)
        return routes.enumerated().map { index, route in
            RouteOption(id: index, route: route, mkRoute: nil, traffic: nil, signalCount: nil)
        }
    }

    /// Apple only: compares the current ETA with the ETA for the next 03:00 departure (free flow) and stores a
    /// `TrafficAssessment` on the Apple option whose distance matches the ETA response (within 3 %).
    private func loadTrafficAssessment(to item: MKMapItem, generation: Int) {
        trafficTask?.cancel()
        let request = makeAppleRequest(to: item, departure: TrafficDelay.nextOffPeakDate(after: Date()))
        trafficTask = Task { [weak self] in
            guard let eta = try? await MKDirections(request: request).calculateETA() else { return }
            guard let self, !Task.isCancelled, generation == self.planGeneration else { return }
            let freeFlow = eta.expectedTravelTime
            let etaDistance = eta.distance
            guard freeFlow > 0, etaDistance > 0 else { return }
            for index in self.routeOptions.indices where self.routeOptions[index].source == .apple {
                let option = self.routeOptions[index]
                guard abs(option.distance - etaDistance) / etaDistance <= 0.03 else { continue }
                self.routeOptions[index].traffic = TrafficAssessment(currentSeconds: option.expectedTravelTime,
                                                                     freeFlowSeconds: freeFlow)
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

    /// Reloads Valhalla edge attributes, Overpass route features, signals and incidents for the selected route.
    private func reloadRouteContext() {
        selectionTask?.cancel()
        selectionTask = nil
        attributesTask?.cancel()
        attributesTask = nil
        featuresTask?.cancel()
        featuresTask = nil
        contextGeneration &+= 1
        let generation = contextGeneration

        routeEdges = []
        edgeSignalDistances = []
        currentEdge = nil
        congestion = nil
        upcomingFeatures = []
        distanceToNextSignal = nil
        routeAttributesError = nil
        isLoadingRouteAttributes = false
        syncedFeatureCount = -1
        signals.setRouteSignals([])

        guard let option = selectedRouteOption else {
            contextOptionID = nil
            contextCumulative = []
            incidentsOnRoute = []
            roadInfo.clearRouteFeatures()
            return
        }
        let polyline = option.route.polyline
        let optionID = option.id
        contextOptionID = optionID
        contextCumulative = Geo.cumulativeDistances(polyline)
        refreshIncidents()

        if settings.routeAttributesEnabled {
            let routeLength = contextCumulative.last ?? 0
            if routeLength > Self.attributesMaxRouteLength {
                routeAttributesError = "Маршрут длиннее 200 км — полосы и ограничения по маршруту не загружаются."
            } else {
                isLoadingRouteAttributes = true
                let source = option.source
                attributesTask = Task { [weak self] in
                    await self?.loadAttributes(polyline: polyline, source: source, optionID: optionID,
                                               generation: generation)
                }
            }
        }
        featuresTask = Task { [weak self] in
            await self?.loadFeatures(polyline: polyline, optionID: optionID, generation: generation)
        }
    }

    private func loadAttributes(polyline: [GeoPoint], source: RouteSource, optionID: Int, generation: Int) async {
        let edgeWalk = source == .valhalla
        let input = edgeWalk ? polyline : Geo.simplify(polyline, maxPoints: Self.attributesMaxPoints)
        await valhalla.setEndpoint(settings.valhallaEndpoint)
        do {
            let raw = try await valhalla.traceAttributes(polyline: input, edgeWalk: edgeWalk)
            guard generation == contextGeneration, !Task.isCancelled else { return }
            let edges = Self.rescaled(raw, toLength: contextCumulative.last ?? Geo.polylineLength(polyline))
            routeEdges = edges
            edgeSignalDistances = Valhalla.signalDistances(in: edges)
            isLoadingRouteAttributes = false
            if let index = routeOptions.firstIndex(where: { $0.id == optionID }) {
                routeOptions[index].signalCount = edgeSignalDistances.count
            }
            if let progress {
                currentEdge = Valhalla.attributes(at: progress.distanceAlong, in: edges)
            }
        } catch {
            guard generation == contextGeneration else { return }
            isLoadingRouteAttributes = false
            if error is CancellationError || Task.isCancelled { return }
            routeAttributesError = "Полосы, ограничения и светофоры по маршруту (Valhalla) недоступны. "
                + Self.describe(error)
        }
    }

    private func loadFeatures(polyline: [GeoPoint], optionID: Int, generation: Int) async {
        await roadInfo.loadRouteFeatures(polyline: polyline)
        guard generation == contextGeneration, !Task.isCancelled else { return }
        syncRouteSignals(force: true)
        if let index = routeOptions.firstIndex(where: { $0.id == optionID }), routeOptions[index].signalCount == nil {
            let count = roadInfo.routeFeatures.filter { $0.kind == .trafficSignals }.count
            if count > 0 || roadInfo.lastError == nil {
                routeOptions[index].signalCount = count
            }
        }
        if let progress {
            refreshUpcomingFeatures(distanceAlong: progress.distanceAlong)
        }
    }

    /// Stretches edge distances measured on the matched shape to the route polyline length (map matching of a
    /// simplified Apple polyline gives a slightly different length). Only small corrections (± 20 %) are applied.
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

    /// Recomputes `incidentsOnRoute` for the selected / active route (also call after reporting an incident).
    func refreshIncidents() {
        guard state != .idle, let option = selectedRouteOption else {
            incidentsOnRoute = []
            return
        }
        let polyline = option.route.polyline
        let cumulative = contextCumulative.count == polyline.count ? contextCumulative : nil
        incidentsOnRoute = incidents.along(route: polyline, cumulative: cumulative)
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
            let text = "Маршрут построен. Ехать \(Self.spokenDistance(option.distance)), "
                + "примерно \(Self.spokenDuration(option.expectedTravelTime))."
            speech.speak(text, priority: .high)
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
        isRecalculating = true
        defer { isRecalculating = false }
        let generation = planGeneration
        if settings.voiceGuidanceEnabled {
            speech.speak("Перестраиваю маршрут", priority: .high)
        }
        do {
            let planned = try await computeRoutes(to: destination)
            guard generation == planGeneration, state == .navigating, let first = planned.options.first else { return }
            isApplyingRoutes = true
            routeOptions = planned.options
            isApplyingRoutes = false
            routingNotice = planned.notice
            beginGuidance(on: first)
            reloadRouteContext()
            if let fix = location.location {
                handleFix(fix)
            }
        } catch {
            guard generation == planGeneration, state == .navigating, !(error is CancellationError) else { return }
            errorMessage = "Не удалось перестроить маршрут. " + Self.describe(error)
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
        routeEdges = []
        edgeSignalDistances = []
        currentEdge = nil
        congestion = nil
        upcomingFeatures = []
        incidentsOnRoute = []
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
    }

    private func arrive() {
        state = .arrived
        detachLocationListener()
        location.setBackgroundUpdates(false)
        rerouteTask?.cancel()
        rerouteTask = nil
        incidentLoopTask?.cancel()
        incidentLoopTask = nil
        congestion = nil
        isWaitingAtSignal = false
        upcomingFeatures = []
        if settings.voiceGuidanceEnabled {
            speech.speak("Вы прибыли", priority: .high)
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
        currentEdge = Valhalla.attributes(at: along, in: routeEdges)
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
        let ahead = roadInfo.routeFeatures.filter {
            let distance = $0.distanceAlongRoute - along
            return distance >= -5 && distance <= Self.featureLookahead
        }
        if ahead != upcomingFeatures {
            upcomingFeatures = ahead
        }
    }

    private func requestReroute() {
        guard !isRecalculating, rerouteTask == nil else { return }
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < Self.minimumRerouteInterval { return }
        rerouteTask = Task { [weak self] in
            await self?.recalculate()
            self?.rerouteTask = nil
        }
    }

    private func announceManeuver(_ current: RouteProgress, speedKmh: Double?) {
        guard settings.voiceGuidanceEnabled,
              let distance = current.distanceToNextManeuver,
              let instruction = current.nextInstruction else { return }
        let stepIndex = current.nextStepIndex ?? (tracker?.steps.count ?? 0)
        if let prompt = voiceScheduler.prompt(stepIndex: stepIndex, distance: distance,
                                              instruction: instruction, speedKmh: speedKmh) {
            speech.speak(prompt, priority: distance <= 150 ? .high : .normal)
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
            speech.speak(text, priority: .normal)
            break
        }
    }

    /// One-time voice alert for a user-reported incident within 700 m ahead.
    private func announceIncident(_ current: RouteProgress) {
        guard settings.voiceGuidanceEnabled else { return }
        for item in incidentsOnRoute where !announcedIncidentIDs.contains(item.id) {
            let ahead = item.distanceAlongRoute - current.distanceAlong
            guard ahead >= 0, ahead <= Self.incidentAlertDistance else { continue }
            announcedIncidentIDs.insert(item.id)
            speech.speak("Впереди \(Self.spokenName(item.incident.kind)), \(Self.spokenDistance(ahead))",
                         priority: .normal)
            break
        }
    }

    // MARK: - Texts

    /// Spoken hazard warning, nil for kinds that are not announced (or not at this speed).
    static func hazardPrompt(for kind: RouteFeatureKind, speedKmh: Double?) -> String? {
        let speed = speedKmh ?? 0
        switch kind {
        case .speedCamera: return "Впереди камера контроля скорости"
        case .school: return "Впереди школа — будьте внимательны, дети"
        case .kindergarten: return "Впереди детский сад — будьте внимательны, дети"
        case .railwayCrossing: return "Впереди железнодорожный переезд"
        case .pedestrianCrossing: return speed > 40 ? "Пешеходный переход" : nil
        case .construction: return "Впереди дорожные работы"
        case .trafficCalming: return speed > 30 ? "Впереди искусственная неровность" : nil
        case .trafficSignals, .stopSign, .giveWay: return nil
        }
    }

    /// Incident kind in a form that reads naturally after "Впереди …".
    static func spokenName(_ kind: RoadIncidentKind) -> String {
        switch kind {
        case .accident: return "ДТП"
        case .roadWork: return "дорожные работы"
        case .jam: return "пробка"
        case .police: return "пост полиции"
        case .pothole: return "яма"
        case .hazard: return "опасность"
        case .closure: return "перекрытие дороги"
        }
    }

    /// "600 метров", "1,5 километра", "12 километров".
    static func spokenDistance(_ meters: Double) -> String {
        let m = max(0, meters.isFinite ? meters : 0)
        if m < 975 {
            let n = max(50, Int((m / 50).rounded()) * 50)
            return "\(n) \(RVFormat.plural(n, "метр", "метра", "метров"))"
        }
        if m < 9_950 {
            let km = (m / 100).rounded() / 10
            if km == km.rounded() {
                let n = Int(km)
                return "\(n) \(RVFormat.plural(n, "километр", "километра", "километров"))"
            }
            return "\(RVFormat.decimal(km, digits: 1)) километра"
        }
        let n = Int((m / 1000).rounded())
        return "\(n) \(RVFormat.plural(n, "километр", "километра", "километров"))"
    }

    /// "1 минуту", "25 минут", "1 час 5 минут" (accusative, after "примерно").
    static func spokenDuration(_ seconds: Double) -> String {
        let total = max(1, Int(((seconds.isFinite ? seconds : 0) / 60).rounded()))
        func minutes(_ n: Int) -> String { "\(n) \(RVFormat.plural(n, "минуту", "минуты", "минут"))" }
        if total < 60 { return minutes(total) }
        let hours = total / 60, rest = total % 60
        let hoursText = "\(hours) \(RVFormat.plural(hours, "час", "часа", "часов"))"
        return rest == 0 ? hoursText : "\(hoursText) \(minutes(rest))"
    }

    /// Russian description of a routing error.
    static func describe(_ error: Error) -> String {
        if let navigationError = error as? NavigationError {
            return navigationError.errorDescription ?? "Ошибка навигации."
        }
        if let valhallaError = error as? ValhallaClientError {
            return valhallaError.errorDescription ?? "Ошибка Valhalla."
        }
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound, .directionsNotFound:
                return "Apple Maps не строит маршруты в этом регионе."
            case .loadingThrottled:
                return "Apple Maps временно ограничил число запросов маршрутов. Подождите минуту."
            case .serverFailure:
                return "Сервер маршрутов Apple недоступен или нет интернета."
            default:
                return "Apple Maps: \(mkError.localizedDescription)"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return "Нет подключения к интернету."
            case .timedOut:
                return "Сервер не ответил вовремя."
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
