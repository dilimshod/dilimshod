package uz.roadvis.app.app

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class AppMode { CAMERA, NAVIGATOR }

/**
 * App-wide state shared by all screens (port of iOS `AppState`). Feature controllers are attached in
 * [RoadVisApp.onCreate] / feature packages; screens read Compose state from here.
 */
class AppState(val context: Context) {
    val settings = AppSettings(context)
    val location = LocationService(context)
    val speech = SpeechService(context, settings)
    val bus = DriveBus()

    var mode by mutableStateOf(AppMode.CAMERA)
        private set
    var showSettings by mutableStateOf(false)
    var showTripHistory by mutableStateOf(false)
    var showAbout by mutableStateOf(false)
    /** Id of the trip whose report is shown, or null. */
    var presentedTripId by mutableStateOf<String?>(null)

    fun switchTo(newMode: AppMode) { mode = newMode }
    fun toggleMode() { mode = if (mode == AppMode.CAMERA) AppMode.NAVIGATOR else AppMode.CAMERA }

    private var started = false

    fun start() {
        location.start()
        if (started) return
        started = true
        uz.roadvis.app.camera.installCamera(this)
        uz.roadvis.app.navigation.installNavigation(this)
        uz.roadvis.app.trips.installTrips(this)
    }

    /** «Поехали»: collapse the navigator to the camera and start the drive (trip recording if enabled). */
    fun startDrive() {
        mode = AppMode.CAMERA
        bus.onDriveStarted.toList().forEach { it() }
    }

    /** End of a drive (arrival or user stop). */
    fun endDrive(arrived: Boolean) {
        bus.onDriveEnded.toList().forEach { it(arrived) }
    }
}
