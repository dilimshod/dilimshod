package uz.roadvis.app.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** RoadVis colour palette and metrics (port of iOS `RVTheme`). */
object RV {
    val safe = Color(0xFF30EB9E)
    val caution = Color(0xFFFFBD29)
    val danger = Color(0xFFFF4545)
    val neutral = Color(0xFFDBDBDB)
    val accent = Color(0xFF1A7AFF)
    val recording = Color(0xFFFF3B30)
    val pedestrianCaution = Color(0xFFFF8C1A)
    val trafficOfficer = Color(0xFF3885FF)
    val roadWorker = Color(0xFFFF7300)
    val launchBackground = Color(0xFF021941)
    val panel = Color(0xCC101418)
    val panelLight = Color(0x99181C22)

    // Detection kinds (same RGB as iOS kindColor)
    val car = Color(0xFF40D9FF)
    val truck = Color(0xFFFF9926)
    val bus = Color(0xFFFFDB33)
    val motorcycle = Color(0xFFFF6BC7)
    val bicycle = Color(0xFF73FF8C)
    val person = Color(0xFFD1ADFF)
    val stopSign = Color(0xFFFF5959)
    val appSettingNorm = Color(0xFFB39EFF)

    object Radius { val box = 8.dp; val chip = 10.dp; val control = 14.dp; val panel = 18.dp; val card = 22.dp }
    object Size { val button = 40.dp; val pill = 32.dp; val hit = 44.dp }
    val gutter = 16.dp
}

@Composable
fun RoadVisTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = RV.accent,
            secondary = RV.safe,
            error = RV.danger,
            background = Color.Black,
            surface = Color(0xFF15181D),
        ),
        content = content,
    )
}
