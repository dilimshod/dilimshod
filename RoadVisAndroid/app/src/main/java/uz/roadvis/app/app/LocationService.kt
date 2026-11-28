package uz.roadvis.app.app

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import uz.roadvis.core.GeoPoint

/** GPS position / speed / course as Compose state (port of iOS `LocationService`). */
class LocationService(private val context: Context) {
    private val client = LocationServices.getFusedLocationProviderClient(context)
    private val listeners = LinkedHashMap<Int, (Location) -> Unit>()
    private var nextId = 1

    var location: Location? by mutableStateOf(null)
        private set
    /** GPS speed, km/h (nil when unknown). */
    var speedKmh: Double? by mutableStateOf(null)
        private set
    /** Course over ground, degrees (nil when not moving / unknown). */
    var course: Double? by mutableStateOf(null)
        private set
    var isRunning by mutableStateOf(false)
        private set

    val coordinate: GeoPoint? get() = location?.let { GeoPoint(it.latitude, it.longitude) }

    val isAuthorized: Boolean
        get() = ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** Course when moving, else null. */
    val travelDirection: Double? get() = if ((speedKmh ?: 0.0) > 3) course else null

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.locations.forEach { handle(it) }
        }
    }

    @SuppressLint("MissingPermission")
    fun start() {
        if (isRunning || !isAuthorized) return
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            .build()
        client.requestLocationUpdates(req, callback, Looper.getMainLooper())
        isRunning = true
        client.lastLocation.addOnSuccessListener { it?.let(::handle) }
    }

    fun stop() {
        if (!isRunning) return
        client.removeLocationUpdates(callback)
        isRunning = false
    }

    fun addListener(handler: (Location) -> Unit): Int {
        val id = nextId++
        listeners[id] = handler
        return id
    }

    fun removeListener(id: Int) { listeners.remove(id) }

    private fun handle(l: Location) {
        // Ignore stale / very inaccurate fixes.
        if (l.hasAccuracy() && l.accuracy > 100) return
        location = l
        speedKmh = if (l.hasSpeed() && l.speed >= 0) l.speed * 3.6 else null
        course = if (l.hasBearing() && (speedKmh ?: 0.0) > 3) l.bearing.toDouble() else course
        listeners.values.toList().forEach { it(l) }
    }
}
