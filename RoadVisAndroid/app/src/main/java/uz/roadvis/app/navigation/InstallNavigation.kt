package uz.roadvis.app.navigation

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import uz.roadvis.app.app.AppState

/**
 * Holder of the app-wide navigation controller (created once in [installNavigation]). The controller keeps running
 * — guidance, road info, signal learning — whichever screen is visible.
 */
object Navigation {
    /** Compose state, so a navigator composed before [installNavigation] picks the controller up. */
    var controller: NavigationController? by mutableStateOf(null)
        internal set
}

/** Called once from [AppState.start] (after permissions): create the controller and start road data / guidance. */
fun installNavigation(app: AppState) {
    if (Navigation.controller != null) return
    MapSetup.configure(app.context)
    val controller = NavigationController(app, app.context.applicationContext)
    Navigation.controller = controller
    controller.start()
    controller.syncBus()
}
