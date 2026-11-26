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

    var mode by mutableStateOf(AppMode.CAMERA)
        private set
    var showSettings by mutableStateOf(false)
    var showTripHistory by mutableStateOf(false)
    var showAbout by mutableStateOf(false)
    /** Id of the trip whose report is shown, or null. */
    var presentedTripId by mutableStateOf<String?>(null)

    fun switchTo(newMode: AppMode) { mode = newMode }
    fun toggleMode() { mode = if (mode == AppMode.CAMERA) AppMode.NAVIGATOR else AppMode.CAMERA }

    fun start() {
        location.start()
    }
}
