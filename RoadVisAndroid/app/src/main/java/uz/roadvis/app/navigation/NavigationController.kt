package uz.roadvis.app.navigation

import android.content.Context
import android.location.Location
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.app.ActiveRoute
import uz.roadvis.app.app.AppState
import uz.roadvis.app.app.NavBanner
import uz.roadvis.app.app.SpeechPriority
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.app.roaddata.IncidentStore
import uz.roadvis.app.roaddata.RoadInfoService
import uz.roadvis.app.roaddata.RouteWeatherService
import uz.roadvis.app.roaddata.TrafficSignalService
import uz.roadvis.app.roaddata.WeatherService
import uz.roadvis.core.CongestionEstimator
import uz.roadvis.core.CongestionLevel
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.IncidentOnRoute
import uz.roadvis.core.ManeuverType
import uz.roadvis.core.NavRoute
import uz.roadvis.core.RoadIncidentKind
import uz.roadvis.core.RouteComparison
import uz.roadvis.core.RouteEdgeAttributes
import uz.roadvis.core.RouteEstimate
import uz.roadvis.core.RouteFacts
import uz.roadvis.core.RouteFeature
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.RouteProgress
import uz.roadvis.core.ReroutePolicy
import uz.roadvis.core.RouteProgressTracker
import uz.roadvis.core.RouteSource
import uz.roadvis.core.RouteTimeline
import uz.roadvis.core.RouteTimelineEvent
import uz.roadvis.core.SignAnnouncer
import uz.roadvis.core.SpeedLimitSegment
import uz.roadvis.core.Valhalla
import uz.roadvis.core.VoiceComposer
import uz.roadvis.core.VoicePhrase
import uz.roadvis.core.VoicePromptScheduler
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** One distinct route option of the preview after merging the candidates of all engines. */
data class RouteOption(
    val id: Int,
    val route: NavRoute,
    /** Signalised intersections along the route (Valhalla trace_attributes, else Overpass); null while unknown. */
    val signalCount: Int? = null,
    /** Other engines that found (nearly) the same route, with their own estimates. */
    val alsoFoundBy: List<RouteEstimate> = emptyList(),
) {
    val name: String get() = route.name
    val distance: Double get() = route.distance
    val expectedTravelTime: Double get() = route.expectedTravelTime
    val source: RouteSource get() = route.source
    val sources: List<RouteSource>
        get() = (listOf(route.source) + alsoFoundBy.map { it.source }).distinct()
}

/** Outcome of one routing engine for the last planning request. */
data class RoutingEngineReport(val source: RouteSource, val status: Status) {
    sealed class Status {
        data class Success(val routes: Int) : Status()
        data class Failed(val reason: String) : Status()
        data class NotAttempted(val reason: String) : Status()
    }

    val isSuccess: Boolean get() = status is Status.Success
    val summary: String
        get() = when (status) {
            is Status.Success -> "${source.badge}: " + NavText.quantity(status.routes, "route")
            is Status.Failed -> L("engine.failed", source.badge, status.reason)
            is Status.NotAttempted -> L("engine.notAttempted", source.badge, status.reason)
        }
}

/**
 * Route planning and turn-by-turn guidance from free OSM engines (port of iOS `NavigationService`).
 *
 * Routing (`settings.routingEngine`): "auto" queries Valhalla (with alternates) and OSRM (both FOSSGIS) concurrently,
 * each client keeping ≤ 1 request/s; candidates are merged with [RouteComparison] and ranked by expected time.
 * For the selected route it loads Valhalla `/trace_attributes` (limits, lanes, signals, typical speeds), OSM features
 * along the route (Overpass, via [RoadInfoService]) and weather (Open-Meteo); from these the timeline and the
 * speed-limit segments are built.
 *
 * During guidance every fix updates progress, voice prompts, the current edge, a congestion ESTIMATE from the user's
 * own speed (one vehicle, not traffic data), hazards (one-time voice alerts) and user-reported incidents; off-route
 * triggers a reroute (at most every 15 s). The controller lives for the whole app session, independent of which
 * screen is visible, and publishes the cross-feature state on `app.bus`.
 */
class NavigationController(val app: AppState, context: Context) {
    enum class State { IDLE, PLANNING, PREVIEWING, NAVIGATING, ARRIVED }

    companion object {
        const val MIN_REROUTE_INTERVAL_MS = 15_000L
        /** Fixes less accurate than this (metres) never count towards off-route or start a reroute. */
        const val MAX_REROUTE_ACCURACY = 65f
        const val INCIDENT_REFRESH_MS = 30_000L
        const val CAMERA_MERGE_DISTANCE = 100.0
        const val FEATURE_LOOKAHEAD = 2_000.0
        const val SPEED_WINDOW_MS = 20_000L
        const val MIN_AVERAGING_SPAN_MS = 8_000L
        const val SIGNAL_STOP_RADIUS = 60.0
        const val SELECTION_DEBOUNCE_MS = 400L
        const val ATTRIBUTES_MAX_POINTS = 1_000
        const val ATTRIBUTES_MAX_ROUTE_LENGTH = 195_000.0
        const val CLOSE_DISTANCE = 150.0
        const val SLOW_DOWN_SPEED_KMH = 40.0
        private const val OSRM_ENDPOINT_KEY = "rv.osrmEndpoint"
    }

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val settings = app.settings
    private val location = app.location
    private val prefs = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    val roadInfo = RoadInfoService(location, settings, scope)
    val signals = TrafficSignalService(location, roadInfo, settings, context.filesDir, scope)
    val incidents = IncidentStore(settings, context.filesDir, scope)
    val weather = WeatherService(location, scope)
    val routeWeather = RouteWeatherService(scope)
    val placeSearch = PlaceSearchService(context, location, scope)
    private val valhalla = ValhallaClient(settings.valhallaEndpoint)
    private val osrm = OsrmClient(osrmEndpoint)

    /** OSRM server (iOS `NavigatorSettingsKeys.osrmEndpoint`; not in the shared AppSettings). */
    var osrmEndpoint: String
        get() = prefs.getString(OSRM_ENDPOINT_KEY, null)?.trim()?.ifEmpty { null } ?: uz.roadvis.core.OSRM.defaultEndpoint
        set(value) { prefs.edit().putString(OSRM_ENDPOINT_KEY, value.trim()).apply(); osrmEditVersion++ }
    var osrmEditVersion by mutableStateOf(0); private set

    // Published state

    var state by mutableStateOf(State.IDLE); private set
    var destination by mutableStateOf<Place?>(null); private set
    var routeOptions by mutableStateOf<List<RouteOption>>(emptyList()); private set
    private var selectedID by mutableStateOf<Int?>(null)
    var progress by mutableStateOf<RouteProgress?>(null); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var routingNotice by mutableStateOf<String?>(null); private set
    var routeEdges by mutableStateOf<List<RouteEdgeAttributes>>(emptyList()); private set
    var currentEdge by mutableStateOf<RouteEdgeAttributes?>(null); private set
    var congestion by mutableStateOf<CongestionLevel?>(null); private set
    var upcomingFeatures by mutableStateOf<List<RouteFeature>>(emptyList()); private set
    var incidentsOnRoute by mutableStateOf<List<IncidentOnRoute>>(emptyList()); private set
    var edgeSignalDistances by mutableStateOf<List<Double>>(emptyList()); private set
    var isLoadingRouteAttributes by mutableStateOf(false); private set
    var routeAttributesError by mutableStateOf<String?>(null); private set
    var isRecalculating by mutableStateOf(false); private set
    var averageSpeedKmh by mutableStateOf<Double?>(null); private set
    var isWaitingAtSignal by mutableStateOf(false); private set
    var distanceToNextSignal by mutableStateOf<Double?>(null); private set
    var engineReports by mutableStateOf<List<RoutingEngineReport>>(emptyList()); private set
    var comparisonNotes by mutableStateOf<List<String>>(emptyList()); private set
    var optionEdges by mutableStateOf<Map<Int, List<RouteEdgeAttributes>>>(emptyMap()); private set
    var timeline by mutableStateOf<List<RouteTimelineEvent>>(emptyList()); private set
    var speedLimitSegments by mutableStateOf<List<SpeedLimitSegment>>(emptyList()); private set

    // Private state

    private var tracker: RouteProgressTracker? = null
    private var voiceScheduler = VoicePromptScheduler()
    private var activeOptionID: Int? = null
    private var contextOptionID: Int? = null
    private var contextCumulative: List<Double> = emptyList()
    private var planGeneration = 0
    private var contextGeneration = 0
    private var recalculationGeneration = 0
    private var planJob: Job? = null
    private var selectionJob: Job? = null
    private var attributesJob: Job? = null
    private var incidentLoopJob: Job? = null
    private var rerouteJob: Job? = null
    private var lastRerouteAt: Long? = null
    /** Consecutive failed reroutes of the current off-route episode (retry interval 15, 30, 60, 120 s). */
    private var rerouteFailureCount = 0
    /** "Rerouting" was already spoken in the current off-route episode. */
    private var rerouteAnnounced = false
    private val currentRerouteIntervalMs: Long
        get() = (ReroutePolicy.retryInterval(MIN_REROUTE_INTERVAL_MS / 1000.0, rerouteFailureCount) * 1000).toLong()
    private val speedSamples = ArrayDeque<Pair<Long, Double>>()
    private val announcedFeatureIDs = HashSet<String>()
    private val announcedIncidentIDs = HashSet<java.util.UUID>()
    private var syncedFeatureCount = -1
    private var started = false

    val selectedRouteOption: RouteOption?
        get() = routeOptions.firstOrNull { it.id == selectedID } ?: routeOptions.firstOrNull()

    val distanceAlong: Double get() = progress?.distanceAlong ?: 0.0
    val routeLength: Double get() = contextCumulative.lastOrNull() ?: selectedRouteOption?.distance ?: 0.0
    val isGuiding: Boolean get() = state == State.NAVIGATING || state == State.ARRIVED

    fun facts(option: RouteOption): RouteFacts =
        RouteComparison.facts(option.route, optionEdges[option.id] ?: emptyList(), option.signalCount)

    fun upcomingEvents(limit: Int? = null): List<RouteTimelineEvent> = RouteTimeline.upcoming(timeline, distanceAlong, limit)

    fun timeUntil(event: RouteTimelineEvent): Double {
        val option = selectedRouteOption ?: return 0.0
        val total = contextCumulative.lastOrNull() ?: option.distance
        val remaining = progress?.remainingTimeSeconds ?: option.expectedTravelTime
        return RouteTimeline.timeOffset(event.distanceAlongRoute, distanceAlong, remaining, total, routeEdges)
    }

    /** Starts the always-on services (road info, signal learning, weather) and the location listener. */
    fun start() {
        if (started) return
        started = true
        roadInfo.onRouteFeaturesChanged = { routeFeaturesDidChange() }
        roadInfo.onCurrentRoadChanged = { syncBus() }
        roadInfo.start()
        signals.start()
        weather.start()
        location.addListener { fix ->
            if (state == State.NAVIGATING) handleFix(fix)
            syncBus()
        }
        LocalizationManager.addListener {
            tracker?.language = NavText.lang
            rebuildTimeline()
            syncBus()
        }
    }

    /** The location service may start only after permissions are granted; call again then. */
    fun ensureServicesRunning() {
        roadInfo.start()
        weather.start()
    }

    // Planning

    fun planRoutes(place: Place) {
        if (state == State.NAVIGATING || state == State.ARRIVED) endActiveGuidance(notifyDriveEnd = state == State.NAVIGATING)
        planGeneration += 1
        val generation = planGeneration
        cancelRouteTasks()
        clearRouteState()
        app.bus.activeRoute = null
        destination = place
        errorMessage = null
        state = State.PLANNING
        syncBus()
        planJob = scope.launch {
            try {
                val planned = computeRoutes(place)
                if (generation != planGeneration || state != State.PLANNING) return@launch
                applyOptions(planned)
                state = State.PREVIEWING
                reloadRouteContext()
                startIncidentLoop()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != planGeneration || state != State.PLANNING) return@launch
                errorMessage = e.message ?: L("navErr.generic")
                destination = null
                state = State.IDLE
            }
            syncBus()
        }
    }

    private class Planned(val options: List<RouteOption>, val reports: List<RoutingEngineReport>,
                          val notes: List<String>, val notice: String?)

    private fun applyOptions(planned: Planned) {
        routeOptions = planned.options
        optionEdges = emptyMap()
        selectedID = planned.options.firstOrNull()?.id
        engineReports = planned.reports
        comparisonNotes = planned.notes
        routingNotice = planned.notice
    }

    private sealed class Outcome {
        class Routes(val routes: List<NavRoute>) : Outcome()
        class Failed(val reason: String) : Outcome()
        class Skipped(val reason: String) : Outcome()
    }

    private suspend fun computeRoutes(place: Place): Planned = coroutineScope {
        val engine = settings.routingEngine
        val wantValhalla = engine != "osrm"
        val wantOSRM = engine != "valhalla"
        val target = place.coordinate
        if (!target.isValid || (target.latitude == 0.0 && target.longitude == 0.0)) throw Exception(L("navErr.invalidDestination"))
        val origin = location.coordinate
        val heading = if ((location.speedKmh ?: 0.0) >= 5) location.travelDirection else null
        val lang = NavText.lang
        valhalla.endpoint = settings.valhallaEndpoint
        osrm.endpoint = osrmEndpoint
        val avoidTolls = settings.avoidTolls
        val avoidHighways = settings.avoidHighways

        val valhallaJob = async {
            when {
                !wantValhalla -> Outcome.Skipped(L("engine.disabled"))
                origin == null || !origin.isValid -> Outcome.Failed(L("navErr.noLocation"))
                else -> try {
                    Outcome.Routes(valhalla.routes(origin, target, heading, avoidTolls, avoidHighways, lang))
                } catch (e: CancellationException) { throw e } catch (e: Exception) { Outcome.Failed(e.message ?: L("navErr.valhalla")) }
            }
        }
        val osrmJob = async {
            when {
                !wantOSRM -> Outcome.Skipped(L("engine.disabled"))
                origin == null || !origin.isValid -> Outcome.Failed(L("navErr.noLocation"))
                else -> try {
                    // OSRM's public car profile has no toll / highway avoidance: drop routes violating the preference.
                    val found = if (heading != null) {
                        // OSRM answers "NoSegment" when no road matches the bearing: retry once without it.
                        try { osrm.routes(origin, target, lang, heading) }
                        catch (e: CancellationException) { throw e }
                        catch (e: OsrmServerException) { osrm.routes(origin, target, lang, null) }
                    } else osrm.routes(origin, target, lang, null)
                    val filtered = found.filter { !(avoidTolls && it.hasTolls) && !(avoidHighways && it.hasHighways) }
                    if (filtered.isEmpty()) Outcome.Skipped(L("engine.osrmAvoid")) else Outcome.Routes(filtered)
                } catch (e: CancellationException) { throw e } catch (e: Exception) { Outcome.Failed(e.message ?: L("navErr.osrm")) }
            }
        }
        val outcomes = listOf(RouteSource.VALHALLA to valhallaJob.await(), RouteSource.OSRM to osrmJob.await())
        val all = ArrayList<NavRoute>()
        val reports = ArrayList<RoutingEngineReport>()
        val failures = ArrayList<String>()
        for ((source, outcome) in outcomes) {
            when (outcome) {
                is Outcome.Routes -> { all += outcome.routes; reports += RoutingEngineReport(source, RoutingEngineReport.Status.Success(outcome.routes.size)) }
                is Outcome.Failed -> { failures += "${source.badge}: ${outcome.reason}"; reports += RoutingEngineReport(source, RoutingEngineReport.Status.Failed(outcome.reason)) }
                is Outcome.Skipped -> reports += RoutingEngineReport(source, RoutingEngineReport.Status.NotAttempted(outcome.reason))
            }
        }
        if (all.isEmpty()) {
            val failed = outcomes.mapNotNull { it.second as? Outcome.Failed }
            if (failed.size == 1) throw Exception(failed[0].reason)
            if (failures.isEmpty()) throw Exception(L("navErr.noRoutes"))
            throw Exception(L("navErr.allFailed", failures.joinToString(" ")))
        }
        val choices = withContext(Dispatchers.Default) { RouteComparison.merge(all) }
        val options = choices.mapIndexed { i, c -> RouteOption(i, c.route, null, c.duplicates) }
        Planned(options, reports, RouteComparison.notes(choices, lang), notice(reports))
    }

    private fun notice(reports: List<RoutingEngineReport>): String? {
        val failed = reports.filter { it.status is RoutingEngineReport.Status.Failed }
        if (failed.isEmpty()) return null
        val delivered = reports.filter { it.isSuccess }.map { it.source.badge }
        var text = failed.joinToString("; ") { it.summary }
        if (delivered.isNotEmpty()) text += ". " + L("engine.shown", delivered.joinToString(", "))
        return "$text."
    }

    // Selection & route context

    fun selectRoute(id: Int) {
        if (id == selectedID) return
        when (state) {
            State.PREVIEWING -> {
                selectedID = id
                selectionJob?.cancel()
                selectionJob = scope.launch {
                    delay(SELECTION_DEBOUNCE_MS)
                    reloadRouteContext()
                }
            }
            else -> Unit   // the active route is fixed during guidance
        }
    }

    private fun reloadRouteContext() {
        selectionJob?.cancel(); selectionJob = null
        attributesJob?.cancel(); attributesJob = null
        contextGeneration += 1
        val generation = contextGeneration
        currentEdge = null
        congestion = null
        upcomingFeatures = emptyList()
        distanceToNextSignal = null
        routeAttributesError = null
        isLoadingRouteAttributes = false
        syncedFeatureCount = -1
        roadInfo.clearRouteFeatures()
        signals.updateRouteSignals(emptyList())

        val option = selectedRouteOption
        if (option == null) {
            contextOptionID = null
            contextCumulative = emptyList()
            incidentsOnRoute = emptyList()
            routeEdges = emptyList()
            edgeSignalDistances = emptyList()
            routeWeather.clear()
            rebuildTimeline()
            return
        }
        val polyline = option.route.polyline
        contextOptionID = option.id
        contextCumulative = Geo.cumulativeDistances(polyline)
        val cached = optionEdges[option.id] ?: emptyList()
        routeEdges = cached
        edgeSignalDistances = Valhalla.signalDistances(cached)
        refreshIncidents()
        routeWeather.load(option.route)
        rebuildTimeline()

        if (settings.routeAttributesEnabled) {
            if ((contextCumulative.lastOrNull() ?: 0.0) > ATTRIBUTES_MAX_ROUTE_LENGTH) {
                routeAttributesError = L("route.attrs.tooLong")
            } else {
                isLoadingRouteAttributes = cached.isEmpty()
                attributesJob = scope.launch { loadAttributes(option.id, generation) }
            }
        }
        roadInfo.loadRouteFeatures(polyline)
    }

    /** Valhalla trace_attributes for the selected option first, then, in the preview only, the others (comparison cards). */
    private suspend fun loadAttributes(selectedId: Int, generation: Int) {
        val order = listOf(selectedId) + routeOptions.map { it.id }.filter { it != selectedId }
        for (id in order) {
            if (generation != contextGeneration) return
            // Alternatives only feed the comparison cards, which exist only in the preview.
            if (id != selectedId && state != State.PREVIEWING) return
            if (optionEdges[id] != null) continue
            val option = routeOptions.firstOrNull { it.id == id } ?: continue
            val polyline = option.route.polyline
            val (length, input) = withContext(Dispatchers.Default) {
                val len = Geo.polylineLength(polyline)
                len to if (option.source == RouteSource.VALHALLA) polyline else Geo.simplify(polyline, ATTRIBUTES_MAX_POINTS)
            }
            if (length > ATTRIBUTES_MAX_ROUTE_LENGTH) continue
            valhalla.endpoint = settings.valhallaEndpoint
            try {
                val raw = valhalla.traceAttributes(input, option.source == RouteSource.VALHALLA)
                if (generation != contextGeneration) return
                val edges = rescaled(raw, length)
                optionEdges = optionEdges + (id to edges)
                val count = Valhalla.signalDistances(edges).size
                routeOptions = routeOptions.map { if (it.id == id) it.copy(signalCount = count) else it }
                if (id == selectedRouteOption?.id) {
                    routeEdges = edges
                    edgeSignalDistances = Valhalla.signalDistances(edges)
                    isLoadingRouteAttributes = false
                    progress?.let { if (state == State.NAVIGATING) currentEdge = if (isMatchedToRoute(it)) Valhalla.attributes(it.distanceAlong, edges) else null }
                    rebuildTimeline()
                    syncBus()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != contextGeneration) return
                if (id == selectedRouteOption?.id) {
                    isLoadingRouteAttributes = false
                    routeAttributesError = L("route.attrs.unavailable") + " " + (e.message ?: "")
                }
            }
        }
    }

    private fun rescaled(edges: List<RouteEdgeAttributes>, length: Double): List<RouteEdgeAttributes> {
        val end = edges.lastOrNull()?.endDistance ?: return edges
        if (!(end > 0) || !(length > 0)) return edges
        val factor = length / end
        if (!(factor > 0.8 && factor < 1.25 && abs(factor - 1) > 0.002)) return edges
        return edges.map { it.copy(startDistance = it.startDistance * factor, endDistance = it.endDistance * factor) }
    }

    private fun routeFeaturesDidChange() {
        if (state == State.IDLE || state == State.PLANNING) return
        syncRouteSignals(force = true)
        val ctx = contextOptionID
        if (ctx != null && optionEdges[ctx] == null && !roadInfo.isLoadingRouteFeatures) {
            val count = roadInfo.routeFeatures.count { it.kind == RouteFeatureKind.TRAFFIC_SIGNALS }
            if (count > 0 || roadInfo.lastError == null) {
                routeOptions = routeOptions.map { if (it.id == ctx) it.copy(signalCount = count) else it }
            }
        }
        refreshUpcomingFeatures(distanceAlong)
        rebuildTimeline()
    }

    private fun rebuildTimeline() {
        val option = selectedRouteOption
        if (state == State.IDLE || option == null) {
            if (timeline.isNotEmpty()) timeline = emptyList()
            if (speedLimitSegments.isNotEmpty()) speedLimitSegments = emptyList()
            return
        }
        val events = RouteTimeline.build(option.route, routeEdges, visibleRouteFeatures, incidentsOnRoute, NavText.timelineText())
        if (events != timeline) timeline = events
        val segments = RouteTimeline.speedLimitSegments(routeEdges, contextCumulative.lastOrNull())
        if (segments != speedLimitSegments) speedLimitSegments = segments
    }

    private fun syncRouteSignals(force: Boolean = false) {
        val features = roadInfo.routeFeatures
        if (!force && features.size == syncedFeatureCount) return
        syncedFeatureCount = features.size
        signals.updateRouteSignals(features)
    }

    /** OSM route features the user wants: speed cameras are dropped when «Cameras from OpenStreetMap» is off. */
    val visibleRouteFeatures: List<RouteFeature>
        get() {
            val features = roadInfo.routeFeatures
            return if (settings.osmCamerasEnabled) features else features.filter { it.kind != RouteFeatureKind.SPEED_CAMERA }
        }

    /** Re-applies the camera / event source toggles (OSM cameras, own marks). */
    fun applyDataSourceSettings() {
        refreshIncidents()
        refreshUpcomingFeatures(distanceAlong)
        rebuildTimeline()
    }

    fun refreshIncidents() {
        val option = selectedRouteOption
        if (state == State.IDLE || !settings.ownMarksEnabled || option == null) {
            if (incidentsOnRoute.isNotEmpty()) { incidentsOnRoute = emptyList(); rebuildTimeline() }
            return
        }
        val polyline = option.route.polyline
        val cumulative = if (contextCumulative.size == polyline.size) contextCumulative else null
        val items = incidents.along(polyline, cumulative)
        if (items != incidentsOnRoute) {
            if (state == State.NAVIGATING) {
                // A mark the driver just made at the current position is not "ahead": never voice it back.
                val known = incidentsOnRoute.map { it.id }.toSet()
                for (item in items) {
                    if (item.id !in known && ReroutePolicy.isIncidentAtOrBehind(item.distanceAlongRoute, distanceAlong)) {
                        announcedIncidentIDs.add(item.id)
                    }
                }
            }
            incidentsOnRoute = items
            rebuildTimeline()
        }
    }

    private fun startIncidentLoop() {
        incidentLoopJob?.cancel()
        incidentLoopJob = scope.launch {
            while (isActive) {
                delay(INCIDENT_REFRESH_MS)
                refreshIncidents()
                syncRouteSignals()
            }
        }
    }

    fun dismissError() { errorMessage = null }

    // Guidance

    /** «Поехали»: starts turn-by-turn guidance on the selected route. Returns true when guidance started. */
    fun startNavigation(): Boolean {
        val option = selectedRouteOption
        if (state != State.PREVIEWING || option == null) return false
        selectionJob?.cancel(); selectionJob = null
        beginGuidance(option)
        announcedFeatureIDs.clear()
        announcedIncidentIDs.clear()
        speedSamples.clear()
        averageSpeedKmh = null
        lastRerouteAt = null
        rerouteFailureCount = 0
        rerouteAnnounced = false
        errorMessage = null
        state = State.NAVIGATING
        if (contextOptionID != option.id) reloadRouteContext()
        location.start()
        if (incidentLoopJob == null) startIncidentLoop()
        if (settings.voiceGuidanceEnabled) {
            val text = L("voice.routeReady", NavText.spokenQuantityDistance(option.distance), NavText.spokenDuration(option.expectedTravelTime))
            app.speech.speak(VoicePhrase.fixed("route_ready", text), SpeechPriority.HIGH)
        }
        publishActiveRoute(option)
        location.location?.let { handleFix(it) }
        syncBus()
        return true
    }

    /** Ends guidance / preview and resets to idle. Fires `app.endDrive(false)` when a drive was in progress. */
    fun stopNavigation() {
        val wasNavigating = state == State.NAVIGATING
        planGeneration += 1
        endActiveGuidance(notifyDriveEnd = false)
        cancelRouteTasks()
        clearRouteState()
        destination = null
        errorMessage = null
        state = State.IDLE
        syncBus()
        app.bus.activeRoute = null
        if (wasNavigating) app.endDrive(arrived = false)
    }

    private fun publishActiveRoute(option: RouteOption) {
        val dest = destination ?: return
        app.bus.activeRoute = ActiveRoute(location.coordinate, dest.coordinate, dest.name, option.route.polyline, option.source)
    }

    private fun beginGuidance(option: RouteOption) {
        activeOptionID = option.id
        selectedID = option.id
        tracker = RouteProgressTracker(option.route.polyline, option.route.steps, option.route.expectedTravelTime).also {
            it.language = NavText.lang
        }
        voiceScheduler = VoicePromptScheduler()
        progress = null
    }

    private fun endActiveGuidance(notifyDriveEnd: Boolean) {
        rerouteJob?.cancel(); rerouteJob = null
        recalculationGeneration += 1
        isRecalculating = false
        rerouteFailureCount = 0
        rerouteAnnounced = false
        tracker = null
        activeOptionID = null
        if (notifyDriveEnd) app.endDrive(arrived = false)
    }

    private fun cancelRouteTasks() {
        planJob?.cancel(); planJob = null
        selectionJob?.cancel(); selectionJob = null
        attributesJob?.cancel(); attributesJob = null
        incidentLoopJob?.cancel(); incidentLoopJob = null
    }

    private fun clearRouteState() {
        routeOptions = emptyList()
        selectedID = null
        contextGeneration += 1
        contextOptionID = null
        contextCumulative = emptyList()
        progress = null
        routingNotice = null
        engineReports = emptyList()
        comparisonNotes = emptyList()
        optionEdges = emptyMap()
        routeEdges = emptyList()
        edgeSignalDistances = emptyList()
        currentEdge = null
        congestion = null
        upcomingFeatures = emptyList()
        incidentsOnRoute = emptyList()
        timeline = emptyList()
        speedLimitSegments = emptyList()
        isLoadingRouteAttributes = false
        routeAttributesError = null
        averageSpeedKmh = null
        isWaitingAtSignal = false
        distanceToNextSignal = null
        speedSamples.clear()
        announcedFeatureIDs.clear()
        announcedIncidentIDs.clear()
        syncedFeatureCount = -1
        roadInfo.clearRouteFeatures()
        signals.updateRouteSignals(emptyList())
        routeWeather.clear()
    }

    private fun arrive() {
        state = State.ARRIVED
        rerouteJob?.cancel(); rerouteJob = null
        incidentLoopJob?.cancel(); incidentLoopJob = null
        congestion = null
        // The road card falls back to the live OSM road (and its limit) once the route is finished.
        currentEdge = null
        isWaitingAtSignal = false
        upcomingFeatures = emptyList()
        if (settings.voiceGuidanceEnabled) {
            app.speech.speak(VoicePhrase.fixed("arrived", L("voice.arrived")), SpeechPriority.HIGH)
        }
        syncBus()
        signals.persistNow()
        app.endDrive(arrived = true)
    }

    /** Reroutes from the current position to the same destination (ignored < 15 s after the previous reroute). */
    private suspend fun recalculate() {
        val dest = destination ?: return
        if (state != State.NAVIGATING || isRecalculating) return
        val now = System.currentTimeMillis()
        lastRerouteAt?.let { if (now - it < currentRerouteIntervalMs) return }
        lastRerouteAt = now
        recalculationGeneration += 1
        val token = recalculationGeneration
        isRecalculating = true
        val generation = planGeneration
        // Spoken once per off-route episode: retries after a failure stay silent.
        if (settings.voiceGuidanceEnabled && !rerouteAnnounced) {
            rerouteAnnounced = true
            app.speech.speak(VoicePhrase.fixed("rerouting", L("voice.rerouting")), SpeechPriority.HIGH)
        }
        try {
            val planned = computeRoutes(dest)
            val first = planned.options.firstOrNull()
            if (generation != planGeneration || token != recalculationGeneration || state != State.NAVIGATING || first == null) return
            rerouteFailureCount = 0
            rerouteAnnounced = false
            // A retried OSRM route ignores the travel direction: prefer the fastest option that starts the way the
            // car is moving, so the new route does not begin with a U-turn the driver is not making.
            val heading = if ((location.speedKmh ?: 0.0) >= 5) location.travelDirection else null
            val chosen = planned.options.getOrNull(
                ReroutePolicy.preferredIndex(planned.options.map { it.route.polyline }, heading)) ?: first
            applyOptions(planned)
            beginGuidance(chosen)
            reloadRouteContext()
            publishActiveRoute(chosen)
            location.location?.let { handleFix(it) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (generation != planGeneration || token != recalculationGeneration || state != State.NAVIGATING) return
            rerouteFailureCount += 1
            // Only the first failure of the episode shows the banner, so a dismissed banner does not come back.
            if (rerouteFailureCount == 1) errorMessage = L("route.rerouteFailed") + " " + (e.message ?: "")
        } finally {
            if (token == recalculationGeneration) isRecalculating = false
        }
    }

    private fun requestReroute() {
        if (isRecalculating || rerouteJob != null) return
        lastRerouteAt?.let { if (System.currentTimeMillis() - it < currentRerouteIntervalMs) return }
        rerouteJob = scope.launch {
            try { recalculate() } finally { rerouteJob = null }
        }
    }

    // Per-fix processing

    private fun handleFix(fix: Location) {
        val tracker = tracker ?: return
        if (state != State.NAVIGATING) return
        val position = GeoPoint(fix.latitude, fix.longitude)
        if (!position.isValid) return
        val speed = if (fix.hasSpeed() && fix.speed >= 0) fix.speed * 3.6 else null
        recordSpeed(speed, fix.time)
        val accuracy = if (fix.hasAccuracy()) fix.accuracy.toDouble() else null
        // Poor fixes still advance the progress when they match the route but never count towards off-route.
        val reliable = fix.hasAccuracy() && fix.accuracy <= MAX_REROUTE_ACCURACY
        // The GPS course is only meaningful while moving.
        val course = if (fix.hasBearing() && (speed ?: 0.0) >= 10) fix.bearing.toDouble() else null
        val current = tracker.update(position, accuracy, countsTowardsOffRoute = reliable, course = course)
        progress = current
        if (current.hasArrived) { arrive(); return }
        syncRouteSignals()
        updateRoadContext(current, speed)
        if (current.isOffRoute) {
            // The reroute waits for a trustworthy fix so the new route starts from the real position.
            if (reliable) requestReroute()
            return
        }
        if (rerouteFailureCount != 0 || rerouteAnnounced) {
            rerouteFailureCount = 0
            rerouteAnnounced = false
        }
        announceManeuver(current, speed)
        announceHazard(current, speed)
        announceIncident(current)
    }

    private fun recordSpeed(kmh: Double?, time: Long) {
        if (kmh != null && kmh.isFinite()) speedSamples.addLast(time to kmh)
        val cutoff = time - SPEED_WINDOW_MS
        while (speedSamples.isNotEmpty() && speedSamples.first().first < cutoff) speedSamples.removeFirst()
        val first = speedSamples.firstOrNull(); val last = speedSamples.lastOrNull()
        averageSpeedKmh = if (first != null && last != null && last.first - first.first >= MIN_AVERAGING_SPAN_MS) {
            speedSamples.sumOf { it.second } / speedSamples.size
        } else null
    }

    private fun updateRoadContext(current: RouteProgress, speedKmh: Double?) {
        val along = current.distanceAlong
        // The route edge (speed limit) applies only while the fix is matched to the route: off it the progress is
        // frozen at the last matched point and the live OSM road must be used instead.
        val edge = if (isMatchedToRoute(current)) Valhalla.attributes(along, routeEdges) else null
        if (edge != currentEdge) currentEdge = edge
        refreshUpcomingFeatures(along)
        var next = signals.upcoming(along, 1).firstOrNull()?.distanceAhead
        edgeSignalDistances.firstOrNull { it >= along - 10 }?.let { next = min(next ?: Double.POSITIVE_INFINITY, max(0.0, it - along)) }
        distanceToNextSignal = next
        isWaitingAtSignal = (next ?: Double.POSITIVE_INFINITY) <= SIGNAL_STOP_RADIUS && (speedKmh ?: 0.0) < 5
        congestion = if (current.isOffRoute) null
        else CongestionEstimator.level(averageSpeedKmh, currentEdge?.typicalSpeedKmh, isWaitingAtSignal)
    }

    /** True while the latest fix lies on the route line (not merely "not yet confirmed off-route"). */
    private fun isMatchedToRoute(current: RouteProgress): Boolean =
        !current.isOffRoute && current.crossTrackDistance <= (tracker?.offRouteThreshold ?: 50.0)

    private fun refreshUpcomingFeatures(along: Double) {
        val ahead = visibleRouteFeatures.filter {
            val d = it.distanceAlongRoute - along
            d >= -5 && d <= FEATURE_LOOKAHEAD
        }
        if (ahead != upcomingFeatures) upcomingFeatures = ahead
    }

    private fun announceManeuver(current: RouteProgress, speedKmh: Double?) {
        if (!settings.voiceGuidanceEnabled) return
        val distance = current.distanceToNextManeuver ?: return
        val instruction = current.nextInstruction ?: return
        val stepIndex = current.nextStepIndex ?: (tracker?.steps?.size ?: 0)
        voiceScheduler.language = NavText.lang
        val prompt = voiceScheduler.prompt(stepIndex, distance, instruction, speedKmh) ?: return
        val roundabout = VoiceComposer.roundaboutExit(instruction)
        val phrase = if (distance <= CLOSE_DISTANCE) {
            val slow = (speedKmh ?: 0.0) > SLOW_DOWN_SPEED_KMH
            VoicePhrase.maneuver(current.nextManeuver, if (distance >= 60) distance else null, roundabout,
                caution = true, slowDown = slow, text = closeManeuverText(instruction, distance, slow))
        } else {
            VoicePhrase.maneuver(current.nextManeuver, if (distance >= 60) distance else null, roundabout, text = prompt)
        }
        app.speech.speak(phrase, if (distance <= 150) SpeechPriority.HIGH else SpeechPriority.NORMAL)
    }

    /** "100 metrdan keyin o‘ngga buriling, ehtiyot bo‘ling, tezlikni pasaytiring" (iOS `NavigationPhrases`). */
    private fun closeManeuverText(instruction: String, distance: Double, slowDown: Boolean): String {
        val text = instruction.trim()
        var phrase = if (distance >= 60) "${NavText.spokenDistance(distance)} ${lowercaseFirst(text)}" else text
        phrase += ", " + L("voice.caution")
        if (slowDown) phrase += ", " + L("voice.slowDown")
        return phrase
    }

    private fun lowercaseFirst(s: String): String {
        if (s.isEmpty()) return s
        // Keep proper names (all-caps abbreviations) intact.
        if (s.length > 1 && s[1].isUpperCase()) return s
        return s.substring(0, 1).lowercase(LocalizationManager.language.locale) + s.substring(1)
    }

    private fun announceHazard(current: RouteProgress, speedKmh: Double?) {
        if (!settings.voiceGuidanceEnabled) return
        for (feature in upcomingFeatures) {
            if (feature.id in announcedFeatureIDs) continue
            val ahead = feature.distanceAlongRoute - current.distanceAlong
            if (ahead < 0 || ahead > feature.kind.alertDistance) continue
            val text = hazardPrompt(feature.kind, speedKmh) ?: continue
            announcedFeatureIDs.add(feature.id)
            app.speech.speak(VoicePhrase.hazard(feature.kind, text), SpeechPriority.NORMAL)
            break
        }
    }

    private fun announceIncident(current: RouteProgress) {
        if (!settings.voiceGuidanceEnabled) return
        for (item in incidentsOnRoute) {
            if (item.id in announcedIncidentIDs) continue
            val kind = item.incident.kind
            val ahead = item.distanceAlongRoute - current.distanceAlong
            if (ahead < 0 || ahead > kind.alertDistance) continue
            announcedIncidentIDs.add(item.id)
            if (kind == RoadIncidentKind.SPEED_CAMERA) {
                val duplicate = upcomingFeatures.any {
                    it.kind == RouteFeatureKind.SPEED_CAMERA && abs(it.distanceAlongRoute - item.distanceAlongRoute) <= CAMERA_MERGE_DISTANCE
                }
                if (duplicate) continue
                app.speech.speak(VoicePhrase.hazard(RouteFeatureKind.SPEED_CAMERA, L("voice.hazard.speedCamera")), SpeechPriority.NORMAL)
                break
            }
            val text = L("voice.incidentAhead", L("voice.incident.${kind.raw}"), NavText.spokenQuantityDistance(ahead))
            app.speech.speak(VoicePhrase.incident(kind, ahead, text), SpeechPriority.NORMAL)
            break
        }
    }

    private fun hazardPrompt(kind: RouteFeatureKind, speedKmh: Double?): String? {
        val speed = speedKmh ?: 0.0
        return when (kind) {
            RouteFeatureKind.SPEED_CAMERA -> L("voice.hazard.speedCamera")
            RouteFeatureKind.SCHOOL -> L("voice.hazard.school")
            RouteFeatureKind.KINDERGARTEN -> L("voice.hazard.kindergarten")
            RouteFeatureKind.RAILWAY_CROSSING -> L("voice.hazard.railway")
            RouteFeatureKind.PEDESTRIAN_CROSSING -> if (speed > 40) L("voice.hazard.crossing") else null
            RouteFeatureKind.CONSTRUCTION -> L("voice.hazard.construction")
            RouteFeatureKind.TRAFFIC_CALMING -> if (speed > 30) L("voice.hazard.bump") else null
            else -> null
        }
    }

    // Lane guidance shown in the banner (engine lanes near the maneuver, else OSM turn:lanes of the current road)

    data class LaneDisplay(val lanes: List<uz.roadvis.core.Lane>, val recommended: List<Boolean>, val source: String?)

    fun laneGuidance(p: RouteProgress): LaneDisplay {
        val distance = p.distanceToNextManeuver ?: Double.POSITIVE_INFINITY
        if (p.isOffRoute) return LaneDisplay(emptyList(), emptyList(), null)
        if (p.nextLanes.isNotEmpty() && distance <= 1_500) return LaneDisplay(p.nextLanes, p.nextActiveLanes, selectedRouteOption?.source?.badge)
        val info = roadInfo.currentRoad?.laneInfo
        if (info != null && info.lanes.isNotEmpty() && distance <= 600) {
            return LaneDisplay(info.lanes, uz.roadvis.core.LaneGuidance.recommendedLanes(info.lanes, p.nextManeuver), "OSM")
        }
        return LaneDisplay(emptyList(), emptyList(), null)
    }

    // Cross-feature bus

    /** Publishes navigation / road state on `app.bus` (works with or without an active route). */
    fun syncBus() {
        val bus = app.bus
        val navigating = state == State.NAVIGATING
        if (bus.isNavigating != navigating) bus.isNavigating = navigating
        val road = roadInfo.currentRoad
        if (bus.currentRoad != road) bus.currentRoad = road
        val edge = if (navigating) currentEdge else null
        val limit = edge?.speedLimitKmh ?: road?.speedLimit?.kmh
        if (bus.speedLimitKmh != limit) bus.speedLimitKmh = limit
        val p = progress
        val ahead = if (navigating && p != null && !p.isOffRoute && routeEdges.isNotEmpty()) {
            val lookahead = if ((location.speedKmh ?: 0.0) >= 65) 300.0 else 150.0
            SignAnnouncer.nextSpeedLimitChange(routeEdges, p.distanceAlong, lookahead)?.kmh
        } else null
        if (bus.speedLimitAheadKmh != ahead) bus.speedLimitAheadKmh = ahead
        bus.navBanner = if (navigating && p != null) banner(p, road) else null
    }

    private fun banner(p: RouteProgress, road: uz.roadvis.core.RoadSegmentInfo?): NavBanner {
        val option = selectedRouteOption
        val steps = option?.route?.steps ?: emptyList()
        val index = p.nextStepIndex
        val street = index?.let { steps.getOrNull(it)?.streetNames?.firstOrNull { s -> s.isNotBlank() } }
            ?: road?.let { NavText.roadName(it) }
        val starts = tracker?.maneuverDistances
        val stepLength = if (index != null && starts != null && index >= 1 && index < starts.size) {
            max(0.0, starts[index] - starts[index - 1])
        } else null
        val instruction = when {
            isRecalculating -> L("banner.rerouting")
            p.isOffRoute -> L("banner.offRoute")
            else -> p.nextInstruction?.trim()?.ifEmpty { null } ?: L("banner.followRoute")
        }
        return NavBanner(
            maneuver = if (p.isOffRoute) ManeuverType.UNKNOWN else p.nextManeuver,
            distanceMeters = p.distanceToNextManeuver ?: p.remainingDistance,
            instruction = instruction,
            street = street,
            stepLengthMeters = stepLength,
        )
    }
}
