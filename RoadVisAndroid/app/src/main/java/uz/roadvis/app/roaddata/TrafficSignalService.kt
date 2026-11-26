package uz.roadvis.app.roaddata

import android.location.Location
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.LocationService
import uz.roadvis.app.l10n.L
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.RouteFeature
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.SignalLocation
import uz.roadvis.core.SignalObservation
import uz.roadvis.core.SignalStatistics
import uz.roadvis.core.SignalTimingAssumptions
import uz.roadvis.core.SignalWaitEstimate
import uz.roadvis.core.StopDetector
import java.io.File
import java.util.Date
import kotlin.math.max

/**
 * Signalised intersections along the route with ESTIMATED waits (fixed-cycle model blended with the user's own
 * stops, learned via [StopDetector] and persisted as JSON in `filesDir/RoadVis/`). Port of iOS `TrafficSignalService`.
 * There is no public real-time signal timing for the region — every number here is an estimate.
 */
class TrafficSignalService(
    private val location: LocationService,
    private val roadInfo: RoadInfoService,
    private val settings: AppSettings,
    private val filesDir: File,
    private val scope: CoroutineScope,
) {
    data class UpcomingSignal(val id: String, val feature: RouteFeature, val distanceAhead: Double, val estimate: SignalWaitEstimate)

    companion object {
        const val STATS_FILE = "signal_stats.json"
        const val LOCATIONS_FILE = "signal_locations.json"
        const val MAX_USABLE_ACCURACY = 50.0
        const val DETECTOR_SEARCH_RADIUS = 1_000.0
        const val DUPLICATE_RADIUS = 30.0
        const val CANONICAL_RADIUS = 40.0
        const val PASSED_TOLERANCE = 10.0
        const val SAVE_DEBOUNCE_MS = 1_500L
    }

    var routeSignals by mutableStateOf<List<RouteFeature>>(emptyList()); private set
    var observationCount by mutableIntStateOf(0); private set
    var persistenceError by mutableStateOf<String?>(null); private set

    private val statistics: SignalStatistics
    private val detector = StopDetector()
    private val knownSignals = HashMap<String, GeoPoint>()
    private val canonicalCache = HashMap<String, String>()
    private val recentCandidates = HashMap<String, GeoPoint>()
    private var detectorHasState = false
    private var listenerID: Int? = null
    private var pendingSave: Job? = null

    val assumptions: SignalTimingAssumptions
        get() = SignalTimingAssumptions(settings.signalCycleSeconds, settings.signalGreenRatio)

    init {
        val problems = ArrayList<String>()
        statistics = when (val r = RoadDataPersistence.load(filesDir, STATS_FILE)) {
            is RoadDataPersistence.LoadResult.Loaded -> try {
                SignalStatistics.fromJSON(r.text)
            } catch (e: Exception) {
                problems.add(RoadDataPersistence.quarantine(filesDir, STATS_FILE)); SignalStatistics()
            }
            is RoadDataPersistence.LoadResult.Failed -> { problems.add(r.message); SignalStatistics() }
            RoadDataPersistence.LoadResult.Missing -> SignalStatistics()
        }
        when (val r = RoadDataPersistence.load(filesDir, LOCATIONS_FILE)) {
            is RoadDataPersistence.LoadResult.Loaded -> try {
                val arr = JSONArray(r.text)
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val c = o.getJSONObject("coordinate")
                    knownSignals.putIfAbsent(o.getString("id"), GeoPoint(c.getDouble("latitude"), c.getDouble("longitude")))
                }
            } catch (e: Exception) {
                problems.add(RoadDataPersistence.quarantine(filesDir, LOCATIONS_FILE))
            }
            is RoadDataPersistence.LoadResult.Failed -> problems.add(r.message)
            RoadDataPersistence.LoadResult.Missing -> Unit
        }
        observationCount = statistics.totalObservations
        persistenceError = if (problems.isEmpty()) null else problems.joinToString(" ")
    }

    fun start() {
        if (listenerID != null) return
        listenerID = location.addListener { handleLocation(it) }
    }

    fun stop() {
        listenerID?.let { location.removeListener(it) }
        listenerID = null
        detector.reset()
        detectorHasState = false
        flushPendingSave()
    }

    fun persistNow() = flushPendingSave()

    fun updateRouteSignals(features: List<RouteFeature>) {
        val signals = features.filter { it.kind == RouteFeatureKind.TRAFFIC_SIGNALS }.sortedBy { it.distanceAlongRoute }
        if (signals != routeSignals) routeSignals = signals
    }

    fun upcoming(fromDistance: Double, limit: Int = 3): List<UpcomingSignal> {
        if (limit <= 0) return emptyList()
        val now = Date()
        val result = ArrayList<UpcomingSignal>()
        for (f in routeSignals) {
            val ahead = f.distanceAlongRoute - fromDistance
            if (ahead < -PASSED_TOLERANCE) continue
            result.add(UpcomingSignal(f.id, f, max(0.0, ahead), estimate(f, now)))
            if (result.size >= limit) break
        }
        return result
    }

    /** Count and summed expected wait of the signals still ahead. */
    fun totalExpectedWait(fromDistance: Double): Pair<Int, Double> {
        val now = Date()
        var count = 0
        var seconds = 0.0
        for (f in routeSignals) {
            if (f.distanceAlongRoute - fromDistance < -PASSED_TOLERANCE) continue
            count += 1
            seconds += estimate(f, now).expectedWaitSeconds
        }
        return count to seconds
    }

    fun resetLearnedData() {
        pendingSave?.cancel(); pendingSave = null
        statistics.removeAll()
        knownSignals.clear(); canonicalCache.clear(); recentCandidates.clear()
        detector.reset(); detectorHasState = false
        observationCount = 0
        write()
    }

    private fun handleLocation(fix: Location) {
        if (!settings.learnSignalTimings) {
            if (detectorHasState) { detector.reset(); detectorHasState = false }
            return
        }
        if (fix.hasAccuracy() && fix.accuracy > MAX_USABLE_ACCURACY) return
        if (!fix.hasSpeed() || fix.speed < 0) return
        val position = GeoPoint(fix.latitude, fix.longitude)
        if (!position.isValid) return
        val candidates = detectorCandidates(position)
        detectorHasState = true
        val observation = detector.update(position, fix.speed * 3.6, Date(fix.time), candidates) ?: return
        record(observation)
    }

    private fun detectorCandidates(position: GeoPoint): List<SignalLocation> {
        val result = ArrayList<SignalLocation>()
        fun add(id: String, coordinate: GeoPoint) {
            if (Geo.distance(position, coordinate) > DETECTOR_SEARCH_RADIUS) return
            val canonical = canonicalID(id, coordinate)
            if (result.any { it.id == canonical || Geo.distance(it.coordinate, coordinate) < DUPLICATE_RADIUS }) return
            result.add(SignalLocation(canonical, coordinate))
        }
        routeSignals.forEach { add(it.id, it.coordinate) }
        roadInfo.nearbySignals.forEach { add(it.id, it.coordinate) }
        if (recentCandidates.size > 500) recentCandidates.clear()
        result.forEach { recentCandidates[it.id] = it.coordinate }
        return result
    }

    private fun record(observation: SignalObservation) {
        statistics.record(observation)
        if (knownSignals[observation.signalID] == null) {
            recentCandidates[observation.signalID]?.let {
                knownSignals[observation.signalID] = it
                canonicalCache.clear()
            }
        }
        observationCount = statistics.totalObservations
        scheduleSave()
    }

    private fun estimate(feature: RouteFeature, at: Date): SignalWaitEstimate =
        statistics.estimate(canonicalID(feature.id, feature.coordinate), at, assumptions)

    private fun canonicalID(id: String, coordinate: GeoPoint): String {
        canonicalCache[id]?.let { return it }
        var resolved = id
        if (knownSignals[id] == null) {
            var best = CANONICAL_RADIUS
            for ((knownID, known) in knownSignals) {
                val d = Geo.distance(known, coordinate)
                if (d <= best) { best = d; resolved = knownID }
            }
        }
        canonicalCache[id] = resolved
        return resolved
    }

    private fun scheduleSave() {
        pendingSave?.cancel()
        pendingSave = scope.launch {
            delay(SAVE_DEBOUNCE_MS)
            pendingSave = null
            write()
        }
    }

    private fun flushPendingSave() {
        if (pendingSave == null) return
        pendingSave?.cancel(); pendingSave = null
        write()
    }

    private fun write() {
        val statsJSON = statistics.toJSON()
        val locations = JSONArray()
        knownSignals.entries.sortedBy { it.key }.forEach { (id, c) ->
            locations.put(JSONObject().put("id", id)
                .put("coordinate", JSONObject().put("latitude", c.latitude).put("longitude", c.longitude)))
        }
        val locationsJSON = locations.toString()
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    RoadDataPersistence.write(filesDir, STATS_FILE, statsJSON)
                    RoadDataPersistence.write(filesDir, LOCATIONS_FILE, locationsJSON)
                }
                if (persistenceError != null) persistenceError = null
            } catch (e: Exception) {
                persistenceError = L("signal.saveFailed", e.message ?: "")
            }
        }
    }
}
