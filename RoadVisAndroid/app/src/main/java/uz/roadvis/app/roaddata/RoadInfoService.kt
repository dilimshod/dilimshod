package uz.roadvis.app.roaddata

import android.location.Location
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.LocationService
import uz.roadvis.app.l10n.L
import uz.roadvis.app.navigation.NavText
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.OSMElement
import uz.roadvis.core.OverpassError
import uz.roadvis.core.OverpassQuery
import uz.roadvis.core.RoadMatcher
import uz.roadvis.core.RoadSegmentInfo
import uz.roadvis.core.RouteFeature
import uz.roadvis.core.RouteFeatureCandidate
import uz.roadvis.core.RouteFeatureExtractor
import uz.roadvis.core.RouteQueryPlanner
import uz.roadvis.core.SignalLocation
import kotlin.math.min
import kotlin.math.pow

/**
 * Road attributes from OpenStreetMap (Overpass): the road the user is on (name, class, lanes, speed limit), nearby
 * traffic signals, and features along the active route. Port of iOS `RoadInfoService` (same tuning).
 *
 * The current road runs whenever location is available and «road data» is on, independent of navigation:
 * one `roadsAround` query fetches the ways near the user, the cached ways are re-matched on every fix, and a new
 * query is made after leaving the covered area (> 120 m), moving ≥ 60 m, or every ≈ 10 s while moving, with
 * exponential back-off after failures.
 */
class RoadInfoService(
    private val location: LocationService,
    private val settings: AppSettings,
    private val scope: CoroutineScope,
) {
    var currentRoad by mutableStateOf<RoadSegmentInfo?>(null); private set
    var nearbySignals by mutableStateOf<List<SignalLocation>>(emptyList()); private set
    var isLoading by mutableStateOf(false); private set
    var lastError by mutableStateOf<String?>(null); private set
    var routeFeatures by mutableStateOf<List<RouteFeature>>(emptyList()); private set
    var isLoadingRouteFeatures by mutableStateOf(false); private set
    var routeFeaturesCoverageNote by mutableStateOf<String?>(null); private set

    /** Called whenever [routeFeatures] changes (progressively while loading). */
    var onRouteFeaturesChanged: (() -> Unit)? = null
    /** Called whenever [currentRoad] changes. */
    var onCurrentRoadChanged: (() -> Unit)? = null

    companion object {
        const val REFRESH_DISTANCE = 60.0
        const val REFRESH_INTERVAL_S = 10.0
        const val MIN_REQUEST_SPACING_S = 5.0
        const val COVERAGE_REQUEST_SPACING_S = 3.0
        const val COVERAGE_RADIUS = 120.0
        const val STATIONARY_JITTER = 10.0
        const val MAX_USABLE_ACCURACY = 65.0
        const val MATCH_STICKINESS = 5.0
        const val ROAD_QUERY_RADIUS = 40.0
        const val SIGNAL_QUERY_RADIUS = 80.0
        const val COURSE_MEMORY_MS = 60_000L
        const val COURSE_MIN_SPEED_KMH = 5.0
        const val BASE_ROUTE_QUERY_RADIUS = 35.0
        const val MAX_ROUTE_CHUNK_POINTS = 60
        const val MAX_ROUTE_CHUNK_LENGTH = 3_000.0
        const val ROUTE_SIMPLIFY_TOLERANCE = 10.0
        const val MAX_ROUTE_CHUNKS = 100
    }

    val client = OverpassClient(settings.overpassEndpoint, AppSettings.OVERPASS_ENDPOINTS)

    private var listenerID: Int? = null
    private var roadJob: Job? = null
    private var roadRequestID = 0
    private var cachedElements: List<OSMElement> = emptyList()
    private var cacheCenter: GeoPoint? = null
    private var lastGoodPosition: GeoPoint? = null
    private var lastRequestPosition: GeoPoint? = null
    private var lastRequestAt: Long? = null
    private var consecutiveFailures = 0
    private var nextRequestAllowed = 0L
    private var roadErrorMessage: String? = null
    private var lastValidCourse: Pair<Double, Long>? = null
    private var lastHeading: Double? = null

    private var routeJob: Job? = null
    private var routeGeneration = 0
    private var routeErrorMessage: String? = null

    fun start() {
        if (listenerID != null) return
        listenerID = location.addListener { handleLocation(it) }
        location.location?.let { handleLocation(it) }
    }

    fun stop() {
        listenerID?.let { location.removeListener(it) }
        listenerID = null
        roadJob?.cancel(); roadJob = null
        roadRequestID += 1
        isLoading = false
    }

    // Travel direction

    val travelHeading: Double? get() = lastHeading ?: location.travelDirection

    private fun updateHeading(fix: Location) {
        val speedKmh = if (fix.hasSpeed() && fix.speed >= 0) fix.speed * 3.6 else 0.0
        if (fix.hasBearing() && speedKmh >= COURSE_MIN_SPEED_KMH) {
            lastValidCourse = fix.bearing.toDouble() to fix.time
            lastHeading = fix.bearing.toDouble()
            return
        }
        val course = lastValidCourse
        if (course != null && fix.time - course.second <= COURSE_MEMORY_MS) { lastHeading = course.first; return }
        lastValidCourse = null
        lastHeading = location.course
    }

    // Current road

    private fun handleLocation(fix: Location) {
        if (!settings.roadDataEnabled) { resetForDisabledRoadData(); return }
        if (fix.hasAccuracy() && fix.accuracy > MAX_USABLE_ACCURACY) return
        val position = GeoPoint(fix.latitude, fix.longitude)
        if (!position.isValid) return
        updateHeading(fix)
        lastGoodPosition = position
        rematch(position)
        if (shouldRefresh(position, System.currentTimeMillis())) startRoadRequest(position)
    }

    private fun setRoad(road: RoadSegmentInfo?) {
        if (road == currentRoad) return
        currentRoad = road
        onCurrentRoadChanged?.invoke()
    }

    private fun rematch(position: GeoPoint) {
        if (cachedElements.isEmpty()) return
        val heading = travelHeading
        val best = RoadMatcher.scoredMatch(cachedElements, position, heading, ROAD_QUERY_RADIUS)
        var match = best?.road
        val previous = currentRoad
        if (best != null && previous != null && best.road.wayID != previous.wayID) {
            val previousWay = cachedElements.firstOrNull { it.type == OSMElement.ElementType.WAY && it.id == previous.wayID }
            if (previousWay != null) {
                val sticky = RoadMatcher.scoredMatch(listOf(previousWay), position, heading, ROAD_QUERY_RADIUS)
                if (sticky != null && sticky.score <= best.score + MATCH_STICKINESS) match = sticky.road
            }
        }
        setRoad(match)
    }

    private fun shouldRefresh(position: GeoPoint, now: Long): Boolean {
        if (roadJob != null || now < nextRequestAllowed) return false
        val lastDate = lastRequestAt ?: return true
        val lastPosition = lastRequestPosition ?: return true
        if (consecutiveFailures > 0 || cacheCenter == null) return true
        val elapsed = (now - lastDate) / 1000.0
        val moved = Geo.distance(position, lastPosition)
        val center = cacheCenter
        if (center != null && Geo.distance(position, center) > COVERAGE_RADIUS) return elapsed >= COVERAGE_REQUEST_SPACING_S
        if (moved >= REFRESH_DISTANCE) return elapsed >= MIN_REQUEST_SPACING_S
        if (currentRoad == null && moved >= 2 * STATIONARY_JITTER) return elapsed >= MIN_REQUEST_SPACING_S
        return elapsed >= REFRESH_INTERVAL_S && moved >= STATIONARY_JITTER
    }

    private fun startRoadRequest(position: GeoPoint) {
        val query = OverpassQuery.roadsAround(position, ROAD_QUERY_RADIUS, SIGNAL_QUERY_RADIUS)
        client.setPrimaryEndpoint(settings.overpassEndpoint)
        roadRequestID += 1
        val requestID = roadRequestID
        lastRequestAt = System.currentTimeMillis()
        lastRequestPosition = position
        isLoading = true
        roadJob = scope.launch {
            val result = try {
                Result.success(client.run(query))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
            finishRoadRequest(result, position, requestID)
        }
    }

    private suspend fun finishRoadRequest(result: Result<List<OSMElement>>, center: GeoPoint, requestID: Int) {
        if (requestID != roadRequestID) return
        roadJob = null
        isLoading = false
        result.onSuccess { elements ->
            if (!settings.roadDataEnabled) return
            cachedElements = elements
            cacheCenter = center
            consecutiveFailures = 0
            nextRequestAllowed = 0
            roadErrorMessage = null
            val signals = withContext(Dispatchers.Default) { RouteFeatureExtractor.signals(elements) }
            if (signals != nearbySignals) nearbySignals = signals
            rematch(lastGoodPosition ?: center)
        }.onFailure { error ->
            consecutiveFailures += 1
            nextRequestAllowed = System.currentTimeMillis() + (retryDelay(error) * 1000).toLong()
            roadErrorMessage = describe(error)
        }
        updateLastError()
    }

    /** Exponential back-off: 10, 20, 40, 80, 120 s …; at least the server's rate-limit wait. */
    private fun retryDelay(error: Throwable): Double {
        val exponent = min(consecutiveFailures - 1, 4).coerceAtLeast(0).toDouble()
        val backoff = min(120.0, REFRESH_INTERVAL_S * 2.0.pow(exponent))
        return if (error is OverpassClientError.RateLimited) maxOf(backoff, error.retryAfterSeconds) else backoff
    }

    private fun resetForDisabledRoadData() {
        if (roadJob != null) { roadJob?.cancel(); roadJob = null; roadRequestID += 1; isLoading = false }
        cachedElements = emptyList()
        cacheCenter = null
        lastRequestAt = null
        lastRequestPosition = null
        consecutiveFailures = 0
        nextRequestAllowed = 0
        roadErrorMessage = null
        setRoad(null)
        if (nearbySignals.isNotEmpty()) nearbySignals = emptyList()
        updateLastError()
    }

    // Route features

    private fun publishRouteFeatures(features: List<RouteFeature>) {
        if (features == routeFeatures) return
        routeFeatures = features
        onRouteFeaturesChanged?.invoke()
    }

    /** Loads hazards and signals along [polyline]; cancels a previous load. Results arrive progressively. */
    fun loadRouteFeatures(polyline: List<GeoPoint>) {
        routeJob?.cancel(); routeJob = null
        routeGeneration += 1
        val generation = routeGeneration
        publishRouteFeatures(emptyList())
        routeFeaturesCoverageNote = null
        routeErrorMessage = null
        val route = polyline.filter { it.isValid }
        if (!settings.roadDataEnabled || route.size < 2) {
            isLoadingRouteFeatures = false
            updateLastError()
            return
        }
        isLoadingRouteFeatures = true
        updateLastError()
        client.setPrimaryEndpoint(settings.overpassEndpoint)
        routeJob = scope.launch { performRouteLoad(route, generation) }
    }

    fun clearRouteFeatures() {
        routeJob?.cancel(); routeJob = null
        routeGeneration += 1
        publishRouteFeatures(emptyList())
        isLoadingRouteFeatures = false
        routeFeaturesCoverageNote = null
        routeErrorMessage = null
        updateLastError()
    }

    private suspend fun performRouteLoad(route: List<GeoPoint>, generation: Int) {
        val (cumulative, plan) = withContext(Dispatchers.Default) {
            Geo.cumulativeDistances(route) to RouteQueryPlanner.plan(route, MAX_ROUTE_CHUNK_POINTS,
                MAX_ROUTE_CHUNK_LENGTH, ROUTE_SIMPLIFY_TOLERANCE, MAX_ROUTE_CHUNKS)
        }
        if (generation != routeGeneration) return
        val queryRadius = BASE_ROUTE_QUERY_RADIUS + plan.maxDeviation
        // Each element is projected onto the route once; only the cheap clustering is redone per chunk.
        var candidates: List<RouteFeatureCandidate> = emptyList()
        val seen = HashSet<String>()
        var failed = 0
        var consecutiveUnreachable = 0
        var lastFailure: Throwable? = null
        val chunks = plan.chunks
        for ((index, chunk) in chunks.withIndex()) {
            if (generation != routeGeneration) return
            if (!settings.roadDataEnabled) { clearRouteFeatures(); return }
            val query = OverpassQuery.featuresAlong(chunk, queryRadius)
            try {
                val elements = runRouteQuery(query)
                if (generation != routeGeneration) return
                consecutiveUnreachable = 0
                val fresh = elements.filter { seen.add(it.key) }
                if (fresh.isNotEmpty()) {
                    val existing = candidates
                    val (all, features) = withContext(Dispatchers.Default) {
                        val merged = existing + RouteFeatureExtractor.candidates(fresh, route, cumulative)
                        merged to RouteFeatureExtractor.features(merged)
                    }
                    if (generation != routeGeneration) return
                    candidates = all
                    publishRouteFeatures(features)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != routeGeneration) return
                failed += 1
                lastFailure = e
                if (e is OverpassClientError.Offline || e is OverpassClientError.NoValidEndpoint) {
                    failed += chunks.size - index - 1
                    break
                }
                // Two chunks in a row with no reachable server (stalled link): stop instead of holding the shared
                // Overpass queue for every remaining chunk; the rest counts as failed.
                if (e is OverpassClientError.AllEndpointsFailed) {
                    consecutiveUnreachable += 1
                    if (consecutiveUnreachable >= 2) {
                        failed += chunks.size - index - 1
                        break
                    }
                } else {
                    consecutiveUnreachable = 0
                }
            }
        }
        if (generation != routeGeneration) return
        val notes = ArrayList<String>()
        if (failed > 0) notes.add(L("roadInfo.chunksFailed", failed, chunks.size))
        if (!plan.isComplete) {
            notes.add(L("roadInfo.partialCoverage", NavText.distance(plan.coveredLength), NavText.distance(plan.totalLength)))
        }
        routeFeaturesCoverageNote = if (notes.isEmpty()) null else L("roadInfo.incomplete", notes.joinToString("; "))
        routeErrorMessage = lastFailure?.let { describe(it) + " (" + L("roadInfo.chunksFailed", failed, chunks.size) + ")" }
        isLoadingRouteFeatures = false
        routeJob = null
        updateLastError()
    }

    private suspend fun runRouteQuery(query: String): List<OSMElement> = try {
        client.run(query, OverpassClient.ROUTE_QUERY_TIMEOUT_MS)
    } catch (e: OverpassClientError.RateLimited) {
        delay((e.retryAfterSeconds.coerceIn(1.0, 60.0) * 1000).toLong())
        client.run(query, OverpassClient.ROUTE_QUERY_TIMEOUT_MS)
    }

    private fun updateLastError() {
        val message = roadErrorMessage ?: routeErrorMessage
        if (message != lastError) lastError = message
    }

    private fun describe(error: Throwable): String {
        val prefix = L("roadInfo.errorPrefix") + " "
        if (error is OverpassError) {
            return prefix + when (error) {
                is OverpassError.HtmlError -> when {
                    error.isRateLimited -> L("overpassErr.rateLimited")
                    error.isTimeout -> L("overpassErr.timeout")
                    else -> L("overpassErr.html", error.detail)
                }
                is OverpassError.InvalidJSON -> L("overpassErr.json", error.detail)
                OverpassError.EmptyResponse -> L("overpassErr.empty")
            }
        }
        return prefix + Http.describe(error)
    }
}
