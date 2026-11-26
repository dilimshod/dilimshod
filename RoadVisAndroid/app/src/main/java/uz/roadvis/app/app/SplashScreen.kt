package uz.roadvis.app.app

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uz.roadvis.app.R
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV

/** Animated logo at launch (port of iOS `SplashView`): logo pop, radar rings from the lens, name + tagline fade-in. */
@Composable
fun SplashScreen(onFinished: () -> Unit) {
    val logoScale = remember { Animatable(1f) }
    val rings = remember { Animatable(0f) }
    val title = remember { Animatable(0f) }
    val glow = rememberInfiniteTransition(label = "glow").animateFloat(
        0f, 1f, infiniteRepeatable(tween(800, easing = LinearEasing), RepeatMode.Reverse), label = "g"
    )
    LaunchedEffect(Unit) {
        launch { logoScale.animateTo(1.08f, spring(dampingRatio = 0.5f, stiffness = Spring.StiffnessMedium)) }
        delay(180)
        launch { logoScale.animateTo(1f, spring(dampingRatio = 0.7f)) }
        launch { rings.animateTo(1.4f, tween(1300)) }
        delay(350)
        launch { title.animateTo(1f, tween(500)) }
        delay(1200)
        onFinished()
    }
    Box(Modifier.fillMaxSize().background(RV.launchBackground), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Box(contentAlignment = Alignment.Center, modifier = Modifier.size(260.dp)) {
                Canvas(Modifier.size(320.dp)) {
                    val c = Offset(size.width / 2, size.height / 2 - 240.dp.toPx() * 0.12f)
                    for (i in 0 until 3) {
                        val p = (rings.value - i * 0.18f).coerceIn(0f, 1f)
                        if (p <= 0f) continue
                        drawCircle(
                            Color.Cyan.copy(alpha = 0.55f * (1 - p)),
                            radius = (60.dp.toPx() + 260.dp.toPx() * p) / 2, center = c, style = Stroke(2.dp.toPx())
                        )
                    }
                }
                Image(
                    painterResource(R.drawable.splash_logo), contentDescription = "RoadVis",
                    modifier = Modifier.size(240.dp).scale(logoScale.value).alpha(0.92f + 0.08f * glow.value)
                )
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.alpha(title.value).offset(y = (14 * (1 - title.value)).dp)
            ) {
                Text("RoadVis", color = Color.White, fontSize = 42.sp, fontWeight = FontWeight.Black)
                Text(L("splash.tagline"), color = Color.White.copy(alpha = 0.7f), fontSize = 15.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}
