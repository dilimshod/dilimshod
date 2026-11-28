package uz.roadvis.app.app

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.zIndex
import kotlinx.coroutines.delay
import uz.roadvis.app.camera.CameraScreen
import uz.roadvis.app.navigation.NavigatorScreen
import uz.roadvis.app.ui.RoadVisTheme

/**
 * Hosts the full-screen camera and the navigator. Both stay mounted (the hidden one is transparent and
 * receives `isActive = false`), so switching is a 0.2 s crossfade without re-creating the map or camera.
 */
@Composable
fun RootScreen(app: AppState) {
    RoadVisTheme {
        var splashDone by rememberSaveable { mutableStateOf(false) }
        var navigatorMounted by remember { mutableStateOf(false) }
        val cameraActive = app.mode == AppMode.CAMERA
        val camAlpha by animateFloatAsState(if (cameraActive) 1f else 0f, tween(200), label = "cam")
        LaunchedEffect(Unit) { delay(1500); navigatorMounted = true }
        LaunchedEffect(app.mode) { if (!cameraActive) navigatorMounted = true }

        Box(Modifier.fillMaxSize().background(Color.Black)) {
            if (navigatorMounted || !cameraActive) {
                Box(Modifier.fillMaxSize().alpha(1f - camAlpha).zIndex(if (cameraActive) 0f else 1f)) {
                    NavigatorScreen(app, isActive = !cameraActive)
                }
            }
            Box(Modifier.fillMaxSize().alpha(camAlpha).zIndex(if (cameraActive) 1f else 0f)) {
                CameraScreen(app, isActive = cameraActive)
            }
            FeatureSheets(app)
            if (!splashDone) Box(Modifier.zIndex(10f)) { SplashScreen { splashDone = true } }
        }
    }
}
