package uz.roadvis.app.camera

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.LocalPolice
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.PedalBike
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.TwoWheeler
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.DoNotDisturbOn
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.ui.RV
import uz.roadvis.core.DistanceStatus
import uz.roadvis.core.PedestrianHazardLevel
import uz.roadvis.core.PersonRole
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind

/** Camera HUD tokens (port of the iOS `RVTheme` parts used by the camera screen). */
object CamTheme {
    val glassFill = Color(0xB3101418)
    val glassEdge = Color.White.copy(alpha = 0.18f)
    const val materialOpacity = 0.78f
    val button: Dp = 40.dp
    val pill: Dp = 32.dp
    val hit: Dp = 44.dp
    val gutter: Dp = 12.dp
    val maxLabelWidth: Dp = 170.dp
    val strokeTentative = 1f
    val strokeBox = 1.5f
    val strokeSelected = 2f
    val strokeLead = 2.5f

    fun statusColor(s: DistanceStatus): Color = when (s) {
        DistanceStatus.SAFE -> RV.safe
        DistanceStatus.CAUTION -> RV.caution
        DistanceStatus.DANGER -> RV.danger
        DistanceStatus.UNKNOWN -> RV.neutral
    }

    fun statusIcon(s: DistanceStatus): ImageVector = when (s) {
        DistanceStatus.SAFE -> Icons.Filled.VerifiedUser
        DistanceStatus.CAUTION -> Icons.Filled.Warning
        DistanceStatus.DANGER -> Icons.Filled.Report
        DistanceStatus.UNKNOWN -> Icons.Filled.DirectionsCar
    }

    fun kindColor(k: VehicleKind): Color = when (k) {
        VehicleKind.CAR -> Color(0.25f, 0.85f, 1.0f)
        VehicleKind.TRUCK -> Color(1.0f, 0.6f, 0.15f)
        VehicleKind.BUS -> Color(1.0f, 0.86f, 0.2f)
        VehicleKind.MOTORCYCLE -> Color(1.0f, 0.42f, 0.78f)
        VehicleKind.BICYCLE -> Color(0.45f, 1.0f, 0.55f)
        VehicleKind.PERSON -> Color(0.82f, 0.68f, 1.0f)
        VehicleKind.TRAFFIC_LIGHT -> Color.White
        VehicleKind.STOP_SIGN -> Color(1.0f, 0.35f, 0.35f)
        VehicleKind.OTHER -> Color.Gray
    }

    fun kindIcon(k: VehicleKind): ImageVector = when (k) {
        VehicleKind.CAR -> Icons.Filled.DirectionsCar
        VehicleKind.TRUCK -> Icons.Filled.LocalShipping
        VehicleKind.BUS -> Icons.Filled.DirectionsBus
        VehicleKind.MOTORCYCLE -> Icons.Filled.TwoWheeler
        VehicleKind.BICYCLE -> Icons.Filled.PedalBike
        VehicleKind.PERSON -> Icons.Filled.DirectionsWalk
        VehicleKind.TRAFFIC_LIGHT -> Icons.Filled.Traffic
        VehicleKind.STOP_SIGN -> Icons.Filled.DoNotDisturbOn
        VehicleKind.OTHER -> Icons.Filled.Help
    }

    fun roleColor(role: PersonRole?): Color? = when (role) {
        PersonRole.TRAFFIC_OFFICER -> RV.trafficOfficer
        PersonRole.ROAD_WORKER -> RV.roadWorker
        else -> null
    }

    fun roleIcon(role: PersonRole): ImageVector = when (role) {
        PersonRole.TRAFFIC_OFFICER -> Icons.Filled.LocalPolice
        PersonRole.ROAD_WORKER -> Icons.Filled.Construction
        PersonRole.PEDESTRIAN -> Icons.Filled.DirectionsWalk
    }

    fun pedestrianColor(level: PedestrianHazardLevel): Color =
        if (level == PedestrianHazardLevel.DANGER) RV.danger else RV.pedestrianCaution

    fun lightColor(c: TrafficLightColor): Color = when (c) {
        TrafficLightColor.RED -> Color(1.0f, 0.22f, 0.2f)
        TrafficLightColor.YELLOW -> Color(1.0f, 0.8f, 0.1f)
        TrafficLightColor.GREEN -> Color(0.2f, 0.95f, 0.45f)
        TrafficLightColor.UNKNOWN -> Color.Gray
    }

    /** Rounded-ish HUD text with a soft dark shadow (legible on the camera picture). */
    fun text(size: TextUnit, weight: FontWeight = FontWeight.SemiBold, color: Color = Color.White, shadow: Boolean = true) =
        TextStyle(
            color = color, fontSize = size, fontWeight = weight, fontFamily = FontFamily.SansSerif,
            shadow = if (shadow) Shadow(Color.Black.copy(alpha = 0.65f), Offset(0f, 1.5f), 4f) else null,
        )

    fun numeric(size: TextUnit, weight: FontWeight = FontWeight.Bold, color: Color = Color.White) =
        text(size, weight, color).copy(fontFeatureSettings = "tnum")
}

/** Frosted-glass panel look: translucent dark fill, optional status tint, hairline edge. */
fun Modifier.glass(shape: Shape, tint: Color? = null, fillAlpha: Float = CamTheme.materialOpacity): Modifier = this
    .background(CamTheme.glassFill.copy(alpha = CamTheme.glassFill.alpha * fillAlpha / CamTheme.materialOpacity), shape)
    .then(if (tint != null) Modifier.background(tint.copy(alpha = 0.12f), shape) else Modifier)
    .border(1.dp, tint?.copy(alpha = 0.5f) ?: CamTheme.glassEdge, shape)

fun Modifier.glassCapsule(tint: Color? = null): Modifier = glass(RoundedCornerShape(50), tint)

/** Gentle opacity pulse while [active] (lead bracket, danger line, banners). */
@Composable
fun pulseAlpha(active: Boolean, minOpacity: Float = 0.5f, period: Int = 1100): Float {
    if (!active) return 1f
    val transition = rememberInfiniteTransition(label = "pulse")
    val a by transition.animateFloat(
        initialValue = 1f, targetValue = minOpacity,
        animationSpec = infiniteRepeatable(tween(period / 2, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "pulseAlpha",
    )
    return a
}

/** Click without ripple that shrinks / dims slightly while pressed (iOS `RVPressableButtonStyle`). */
@Composable
fun Modifier.pressable(onClick: () -> Unit): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    return this
        .scale(if (pressed) 0.92f else 1f)
        .alpha(if (pressed) 0.85f else 1f)
        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
}

/** Circular frosted-glass icon button (iOS `GlassIconButton`): visible [size], hit area ≥ 44 dp. */
@Composable
fun GlassIconButton(icon: ImageVector, label: String, size: Dp = CamTheme.button, tint: Color = Color.White, onClick: () -> Unit) {
    Box(
        Modifier.size(maxOf(size, CamTheme.hit)).pressable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(size).shadow(6.dp, CircleShape, clip = false)
                .background(CamTheme.glassFill, CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.22f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = label, tint = tint, modifier = Modifier.size(size * 0.48f))
        }
    }
}

