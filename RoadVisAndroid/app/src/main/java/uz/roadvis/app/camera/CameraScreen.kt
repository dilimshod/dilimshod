package uz.roadvis.app.camera

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import uz.roadvis.app.app.AppState

/** Placeholder — replaced by the camera feature. */
@Composable
fun CameraScreen(app: AppState, isActive: Boolean) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Camera", color = Color.White) }
}
