package uz.roadvis.app.roaddata

import android.location.Location
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import uz.roadvis.app.l10n.L
import uz.roadvis.app.app.LocationService
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.NavRoute
import uz.roadvis.core.OpenMeteo
import uz.roadvis.core.OpenMeteoError
import uz.roadvis.core.WeatherSnapshot
import java.util.Locale

/** Fetches one Open-Meteo snapshot (free, no key; CC BY 4.0). Cached per ≈ 1 km cell for 15 minutes. */
object OpenMeteoFetcher {
    private val cache = HashMap<String, Pair<WeatherSnapshot, Long>>()
    private const val CACHE_MS = 15 * 60 * 1000L

    suspend fun fetch(point: GeoPoint): WeatherSnapshot {
        val cell = String.format(Locale.US, "%.2f,%.2f", point.latitude, point.longitude)
        synchronized(cache) {
            cache[cell]?.let { if (System.currentTimeMillis() - it.second < CACHE_MS) return it.first }
        }
        val response = Http.get(OpenMeteo.url(point), timeoutMs = 20_000)
        if (response.status != 200) {
            val reason = try { OpenMeteo.parse(response.body); null } catch (e: OpenMeteoError.Api) { e.reason } catch (_: Exception) { null }
            throw Exception(reason?.let { L("weather.updateFailed", it) } ?: "HTTP ${response.status}")
        }
        val snapshot = try { OpenMeteo.parse(response.body) } catch (e: Exception) { throw Exception(L("net.invalidResponse")) }
        synchronized(cache) { cache[cell] = snapshot to System.currentTimeMillis() }
        return snapshot
    }
}

/** Current weather at the user's position (refresh every 15 min or after 10 km). Port of iOS `WeatherService`. */
class WeatherService(private val location: LocationService, private val scope: CoroutineScope) {
    var current by mutableStateOf<WeatherSnapshot?>(null); private set
    var lastError by mutableStateOf<String?>(null); private set

    private var listenerID: Int? = null
    private var inFlight: Job? = null
    private var lastUpdate = 0L
    private var lastPosition: GeoPoint? = null
    private var nextAttempt = 0L
    private var failures = 0

    fun start() {
        if (listenerID != null) return
        listenerID = location.addListener { handle(it) }
        location.location?.let { handle(it) }
    }

    fun stop() {
        listenerID?.let { location.removeListener(it) }
        listenerID = null
    }

    private fun handle(fix: Location) {
        if (inFlight != null) return
        val now = System.currentTimeMillis()
        if (now < nextAttempt) return
        val p = GeoPoint(fix.latitude, fix.longitude)
        val last = lastPosition
        val due = last == null || now - lastUpdate >= 15 * 60_000L || Geo.distance(p, last) > 10_000
        if (!p.isValid || !due) return
        inFlight = scope.launch {
            try {
                current = OpenMeteoFetcher.fetch(p)
                lastUpdate = System.currentTimeMillis()
                lastPosition = p
                lastError = null
                failures = 0
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failures += 1
                nextAttempt = System.currentTimeMillis() + minOf(30 * 60_000L, 60_000L shl minOf(failures, 5))
                lastError = Http.describe(e)
            } finally {
                inFlight = null
            }
        }
    }
}

/** Weather at the destination (+ the midpoint for routes ≥ 30 km). Port of iOS `RouteWeatherService`. */
class RouteWeatherService(private val scope: CoroutineScope) {
    data class Point(val label: String, val coordinate: GeoPoint, val distanceAlongRoute: Double,
                     val snapshot: WeatherSnapshot? = null, val error: String? = null)

    var points by mutableStateOf<List<Point>>(emptyList()); private set
    var isLoading by mutableStateOf(false); private set

    private var job: Job? = null
    private var routeKey = ""

    fun load(route: NavRoute) {
        val last = route.polyline.lastOrNull()
        if (last == null || !last.isValid) { clear(); return }
        val key = String.format(Locale.US, "%.3f,%.3f|%d", last.latitude, last.longitude, (route.distance / 1000).toInt())
        if (key == routeKey) return
        routeKey = key
        job?.cancel()
        val cumulative = Geo.cumulativeDistances(route.polyline)
        val total = cumulative.lastOrNull() ?: route.distance
        val targets = ArrayList<Point>()
        if (total >= 30_000) {
            Geo.pointAtDistance(total / 2, route.polyline, cumulative)?.let {
                targets.add(Point(L("weather.midRoute"), it, total / 2))
            }
        }
        targets.add(Point(L("weather.destination"), last, total))
        points = targets
        isLoading = true
        job = scope.launch {
            for (index in targets.indices) {
                val result = try {
                    Result.success(OpenMeteoFetcher.fetch(targets[index].coordinate))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
                if (routeKey != key || index !in points.indices) return@launch
                val updated = points.toMutableList()
                updated[index] = result.fold({ updated[index].copy(snapshot = it) }, { updated[index].copy(error = Http.describe(it)) })
                points = updated
            }
            isLoading = false
        }
    }

    fun clear() {
        job?.cancel(); job = null
        routeKey = ""
        points = emptyList()
        isLoading = false
    }
}
