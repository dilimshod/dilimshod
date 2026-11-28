package uz.roadvis.app.trips

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Geocoder
import android.location.Location
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.DrivingEventDebouncer
import uz.roadvis.core.FollowingDistanceCalculator
import uz.roadvis.core.FollowingDistancePolicy
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.HarshMotionDetector
import uz.roadvis.core.RoadSurfaceCondition
import uz.roadvis.core.SpeedingDetector
import uz.roadvis.core.Trip
import uz.roadvis.core.TripEndpoint
import uz.roadvis.core.TripPoint
import uz.roadvis.core.TripThresholds
import java.util.UUID
import kotlin.math.sqrt

/** Thresholds from the user settings (port of iOS `AppSettings.tripThresholds`). */
fun AppState.tripThresholds(): TripThresholds = TripThresholds(
    speedToleranceKmh = settings.tripSpeedToleranceKmh,
    speedingMinSeconds = settings.tripSpeedingMinSeconds,
    harshBrakingMps2 = settings.tripHarshBrakingMps2,
    harshAccelerationMps2 = settings.tripHarshAccelerationMps2,
)

/**
 * Records a trip in the background (port of iOS `TripRecorder`): ≈ 1 track point per second (time, position, GPS
 * speed, speed limit, ≈ lead gap), A and B, the route polyline and driving events.
 *
 * Events: speeding ([SpeedingDetector] with `bus.speedLimitKmh`), harsh braking / acceleration (GPS speed derivative,
 * confirmed by the linear-acceleration sensor, [HarshMotionDetector]) and camera events delivered through [ingest]
 * (`bus.events`). Everything goes through [DrivingEventDebouncer]. The in-progress trip is autosaved every 60 s.
 * All methods run on the main thread.
 */
class TripRecorder(private val app: AppState, private val store: TripStore) : SensorEventListener {
    var isRecording by mutableStateOf(false)
        private set
    /** True while [stop] finalises (geocoding B). */
    var isFinishing by mutableStateOf(false)
        private set
    var startedAtMillis by mutableStateOf<Long?>(null)
        private set
    var liveDistanceMeters by mutableStateOf(0.0)
        private set
    var liveEventCount by mutableStateOf(0)
        private set
    var lastEvent by mutableStateOf<DrivingEvent?>(null)
        private set
    /** True when the current recording was started by «Поехали». */
    var startedWithNavigation by mutableStateOf(false)
        private set
    /** Id of the trip being recorded. */
    var currentTripId by mutableStateOf<UUID?>(null)
        private set

    private val context: Context get() = app.context
    private val bg = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())

    private var trip: Trip? = null
    private val points = ArrayList<TripPoint>()
    private var debouncer = DrivingEventDebouncer()
    private var speeding = SpeedingDetector()
    private var harsh = HarshMotionDetector()
    private var listenerId: Int? = null
    private var smoothedMotion: Double? = null
    private var lastAcceptedPoint: TripPoint? = null
    private var lastAutosave = 0L
    private var routeSignature: Pair<Int, GeoPoint?>? = null
    private val sensorManager: SensorManager? get() = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    companion object {
        /** Minimum interval between stored track points, ms. */
        const val POINT_INTERVAL_MS = 900L
        /** Fixes with a worse horizontal accuracy are ignored, metres. */
        const val MAX_ACCURACY = 65.0
        const val AUTOSAVE_INTERVAL_MS = 60_000L
        /** Simplified route polyline size. */
        const val MAX_ROUTE_POINTS = 600
    }

    // Start / stop

    /** Starts a recording (no-op while one is running). [withNavigation] = started by «Поехали». */
    fun start(withNavigation: Boolean) {
        if (isRecording || isFinishing) return
        val thresholds = app.tripThresholds()
        val now = System.currentTimeMillis()
        val newTrip = Trip(startedAtMillis = now, origin = TripEndpoint(coordinate = app.location.coordinate),
            thresholds = thresholds, startedWithNavigation = withNavigation)
        app.bus.activeRoute?.let { newTrip.destination = TripEndpoint(it.destinationName, it.destination) }
        trip = newTrip
        points.clear()
        debouncer = DrivingEventDebouncer()
        speeding = SpeedingDetector(thresholds)
        harsh = HarshMotionDetector(thresholds)
        smoothedMotion = null
        lastAcceptedPoint = null
        routeSignature = null
        lastAutosave = now
        captureRoute()

        isRecording = true
        startedWithNavigation = withNavigation
        startedAtMillis = now
        currentTripId = newTrip.id
        liveDistanceMeters = 0.0
        liveEventCount = 0
        lastEvent = null
        app.bus.isRecordingTrip = true

        app.location.start()
        listenerId = app.location.addListener { handleFix(it) }
        startMotion()

        app.location.location?.let { fix -> if (now - fix.time < 5000) handleFix(fix) }
        val id = newTrip.id
        app.location.coordinate?.let { origin ->
            bg.launch {
                val name = placeName(origin, 8000)
                main.post {
                    val current = trip
                    if (name != null && current != null && current.id == id && current.origin.name == null) {
                        current.origin = current.origin.copy(name = name)
                    }
                }
            }
        }
        store.persist(snapshot(newTrip))
    }

    /**
     * Stops the recording, finalises B and saves the trip. Returns null when nothing was recorded (fewer than 2 track
     * points); such a trip is discarded. Call from the main thread (suspends for reverse geocoding).
     */
    suspend fun stop(arrived: Boolean = false): Trip? {
        val current = trip
        if (!isRecording || current == null) return null
        isRecording = false
        isFinishing = true
        app.bus.isRecordingTrip = false
        try {
            listenerId?.let { app.location.removeListener(it) }
            listenerId = null
            sensorManager?.unregisterListener(this)
            captureRoute()
            val finished = snapshot(current)
            finished.endedAtMillis = System.currentTimeMillis()
            finished.arrived = arrived
            if (finished.destination == null) finished.points.lastOrNull()?.let { finished.destination = TripEndpoint(coordinate = it.coordinate) }
            if (finished.origin.coordinate == null) finished.origin = finished.origin.copy(coordinate = finished.points.firstOrNull()?.coordinate)
            // The finished state goes to disk before the (up to 8 s) geocoding: the process may be killed meanwhile.
            if (finished.points.size >= 2) store.persist(finished.copy())
            // B gets an address only when it has no name (manual trips); the geocoder is given ≤ 4 s.
            val dest = finished.destination
            if (dest != null && dest.name == null) dest.coordinate?.let { c ->
                finished.destination = dest.copy(name = placeName(c, 4000))
            }
            if (finished.origin.name == null) finished.origin.coordinate?.let { c ->
                finished.origin = finished.origin.copy(name = placeName(c, 4000))
            }
            trip = null
            startedAtMillis = null
            currentTripId = null
            if (finished.points.size < 2) {
                store.delete(finished.id)
                return null
            }
            store.save(finished)
            // Driver cabinet: queue the finished trip for the automatic upload (no-op while the cabinet is off).
            uz.roadvis.app.cabinet.CabinetService.onTripSaved(app.context, finished)
            return finished
        } finally {
            isFinishing = false
        }
    }

    /**
     * «Поехали» pressed while an automatically started recording is running: the trip becomes a navigation trip
     * (arrival / cancelled guidance end it) and takes the route and destination of the navigator.
     */
    fun adoptNavigation() {
        val current = trip
        if (!isRecording || current == null) return
        startedWithNavigation = true
        current.startedWithNavigation = true
        app.bus.activeRoute?.let { current.destination = TripEndpoint(it.destinationName, it.destination) }
        captureRoute()
    }

    /** Adds an event from another source (camera). Missing position / speed are filled from GPS. */
    fun ingest(event: DrivingEvent) {
        if (!isRecording || trip == null) return
        val e = event.copy()
        if (e.coordinate == null) e.coordinate = app.location.coordinate
        if (e.speedKmh == null) e.speedKmh = app.location.speedKmh
        add(e)
    }

    /** Copy of the trip with the current points and events (safe to serialise on another thread). */
    private fun snapshot(t: Trip): Trip = t.copy(origin = t.origin.copy(), destination = t.destination?.copy(),
        points = points.toList(), events = debouncer.events.toList())

    // Samples

    private fun handleFix(fix: Location) {
        val current = trip
        if (!isRecording || current == null) return
        if (!fix.hasAccuracy() || fix.accuracy < 0 || fix.accuracy > MAX_ACCURACY) return
        val position = GeoPoint(fix.latitude, fix.longitude)
        if (!position.isValid) return
        val date = fix.time
        val speed: Double? = if (fix.hasSpeed() && fix.speed >= 0) fix.speed * 3.6 else null
        val limit = app.bus.speedLimitKmh
        val fdOn = app.settings.followingDistanceEnabled
        val lead = if (fdOn) app.bus.leadGapMeters else null
        val recommended = if (fdOn && lead != null) recommendedGap(speed) else null

        val previous = lastAcceptedPoint
        if (previous == null || date - previous.dateMillis >= POINT_INTERVAL_MS) {
            val point = TripPoint(date, position, speed, limit, lead, recommended, fix.accuracy.toDouble())
            if (previous != null) {
                val dt = (point.dateMillis - previous.dateMillis) / 1000.0
                val step = Geo.distance(previous.coordinate, position)
                if (dt > 0 && step / dt < 70) liveDistanceMeters += step
            }
            points += point
            lastAcceptedPoint = point
            if (current.origin.coordinate == null) current.origin = current.origin.copy(coordinate = position)
        }

        speeding.update(date, speed, limit, position)?.let { add(it) }
        if (speed != null) harsh.addSpeed(date, speed, position)?.let { add(it) }
        captureRoute()
        if (date - lastAutosave >= AUTOSAVE_INTERVAL_MS) {
            lastAutosave = date
            store.persist(snapshot(current))
        }
    }

    private fun recommendedGap(speedKmh: Double?): Double {
        val s = app.settings
        val policy = FollowingDistancePolicy(timeGapDry = s.followingTimeGapDry, stoppedGapMeters = s.stoppedGapMeters,
            reactionTimeSeconds = s.reactionTimeSeconds)
        val condition = RoadSurfaceCondition.fromRaw(s.roadSurfaceMode) ?: RoadSurfaceCondition.DRY
        return FollowingDistanceCalculator.recommendedDistance(speedKmh, policy, condition)
    }

    private fun add(event: DrivingEvent) {
        val isNew = debouncer.add(event)
        liveEventCount = debouncer.events.size
        if (isNew) lastEvent = event
    }

    /** Keeps the latest non-empty route polyline of the navigator (simplified), with its engine badge. */
    private fun captureRoute() {
        val current = trip ?: return
        val route = app.bus.activeRoute ?: return
        val polyline = route.polyline
        if (polyline.isEmpty()) return
        val signature = polyline.size to polyline.firstOrNull()
        if (signature == routeSignature) return
        routeSignature = signature
        current.routePolyline = Geo.simplify(polyline, MAX_ROUTE_POINTS)
        current.routeSource = route.source.badge
        if (current.destination == null) current.destination = TripEndpoint(route.destinationName, route.destination)
    }

    // Motion sensors

    private fun startMotion() {
        val sm = sensorManager ?: return
        val sensor = sm.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION) ?: return
        sm.registerListener(this, sensor, 100_000, main)
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (!isRecording) return
        val v = event.values
        val magnitude = sqrt((v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).toDouble())
        // Short low-pass (≈ 0.25 s) against vibration spikes of the phone mount.
        val smoothed = (smoothedMotion ?: magnitude) * 0.6 + magnitude * 0.4
        smoothedMotion = smoothed
        harsh.addMotion(System.currentTimeMillis(), smoothed)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // Geocoding

    /** Street + house, else feature name / locality, else null. Never throws; null after [timeoutMs]. */
    private suspend fun placeName(point: GeoPoint, timeoutMs: Long): String? {
        if (!Geocoder.isPresent()) return null
        val ctx = context
        val deferred = bg.async {
            try {
                @Suppress("DEPRECATION")
                val address = Geocoder(ctx, LocalizationManager.language.locale)
                    .getFromLocation(point.latitude, point.longitude, 1)?.firstOrNull() ?: return@async null
                val street = listOfNotNull(address.thoroughfare, address.subThoroughfare).joinToString(" ")
                street.ifEmpty { address.featureName ?: address.locality }
            } catch (_: Exception) {
                null
            }
        }
        return withTimeoutOrNull(timeoutMs) { deferred.await() }
    }
}
