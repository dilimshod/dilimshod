package uz.roadvis.app.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.ManeuverType
import uz.roadvis.core.RoadSegmentInfo
import uz.roadvis.core.RouteSource

/** Next manoeuvre shown on the camera screen while navigating (written by navigation, read by camera). */
data class NavBanner(
    val maneuver: ManeuverType,
    val distanceMeters: Double,
    val instruction: String,
    /** Street of the next step (fallback: current road name), may be null. */
    val street: String?,
    /** Distance of the whole step, for the countdown bar. */
    val stepLengthMeters: Double?,
)

/** Active route summary (written by navigation, read by trips for the report). */
data class ActiveRoute(
    val origin: GeoPoint?,
    val destination: GeoPoint,
    val destinationName: String?,
    val polyline: List<GeoPoint>,
    val source: RouteSource,
)

/**
 * Cross-feature live state. Each feature package writes only its own fields:
 *  - navigation: [navBanner], [activeRoute], [isNavigating], [currentRoad], [speedLimitKmh], [speedLimitAheadKmh];
 *  - camera: [leadCameraDistanceMeters], [leadGapMeters], [emitEvent] (camera driving events);
 *  - trips: [isRecordingTrip].
 * Lifecycle hooks (`onDriveStarted`, `onDriveEnded`) are registered by features in their install function.
 */
class DriveBus {
    var navBanner by mutableStateOf<NavBanner?>(null)
    var activeRoute by mutableStateOf<ActiveRoute?>(null)
    var isNavigating by mutableStateOf(false)
    var currentRoad by mutableStateOf<RoadSegmentInfo?>(null)
    var speedLimitKmh by mutableStateOf<Int?>(null)
    var speedLimitAheadKmh by mutableStateOf<Int?>(null)

    /** Raw camera → lead vehicle distance (before bonnet offset), metres; used by the bonnet calibration. */
    var leadCameraDistanceMeters by mutableStateOf<Double?>(null)
    /** Bumper-to-bumper gap to the lead vehicle, metres. */
    var leadGapMeters by mutableStateOf<Double?>(null)

    var isRecordingTrip by mutableStateOf(false)

    private val _events = MutableSharedFlow<DrivingEvent>(extraBufferCapacity = 64)
    /** Driving events detected by the camera (tailgating, lane departure, red light…), consumed by the trip recorder. */
    val events: SharedFlow<DrivingEvent> = _events
    fun emitEvent(e: DrivingEvent) { _events.tryEmit(e) }

    val onDriveStarted = mutableListOf<() -> Unit>()
    val onDriveEnded = mutableListOf<(arrived: Boolean) -> Unit>()
}
