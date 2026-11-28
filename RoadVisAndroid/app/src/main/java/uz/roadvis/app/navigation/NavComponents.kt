package uz.roadvis.app.navigation

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.Lane
import uz.roadvis.core.LaneTurn
import uz.roadvis.core.RouteSource
import uz.roadvis.core.RouteTimelineEvent
import uz.roadvis.core.RouteTimelineKind
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.SpeedLimitSegment
import uz.roadvis.core.WeatherSnapshot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

val GlassColor = Color(0xE6161A20)
val Secondary = Color.White.copy(alpha = 0.65f)

fun Modifier.glass(radius: Dp = RV.Radius.card): Modifier = this
    .clip(RoundedCornerShape(radius))
    .background(GlassColor)
    .border(BorderStroke(1.dp, Color.White.copy(alpha = 0.10f)), RoundedCornerShape(radius))

@Composable
fun T(text: String, size: TextUnit = 14.sp, weight: FontWeight = FontWeight.Normal, color: Color = Color.White,
      maxLines: Int = Int.MAX_VALUE, modifier: Modifier = Modifier) {
    Text(text, modifier = modifier, fontSize = size, fontWeight = weight, color = color, maxLines = maxLines,
        overflow = TextOverflow.Ellipsis)
}

/** Round glass HUD button (44 dp hit area). */
@Composable
fun RoundButton(icon: ImageVector, label: String, tint: Color = Color.White, background: Color = GlassColor, onClick: () -> Unit) {
    Box(Modifier.size(RV.Size.hit).semantics { contentDescription = label }.clickable(onClick = onClick),
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(RV.Size.button).clip(CircleShape).background(background)
            .border(1.dp, Color.White.copy(alpha = 0.22f), CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
fun Badge(text: String, color: Color, icon: ImageVector? = null) {
    Row(Modifier.clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.18f)).padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Icon(icon, null, tint = color, modifier = Modifier.size(12.dp)); Spacer(Modifier.width(3.dp)) }
        T(text, 11.sp, FontWeight.Bold, color, 1)
    }
}

@Composable
fun EngineBadge(source: RouteSource) = Badge(source.badge, NavStyle.sourceColor(source), androidx.compose.material.icons.Icons.Default.Public)

@Composable
fun SourceTag(text: String, color: Color = Color.White.copy(alpha = 0.7f)) {
    Box(Modifier.border(1.dp, color.copy(alpha = 0.7f), RoundedCornerShape(6.dp)).padding(horizontal = 4.dp, vertical = 0.dp)
        .semantics { contentDescription = L("nav.sourceA11y", text) }) {
        T(text, 8.sp, FontWeight.Bold, color, 1)
    }
}

@Composable
fun SectionTitle(title: String, trailing: String? = null) {
    Row(Modifier.fillMaxWidth()) {
        T(title.uppercase(), 10.sp, FontWeight.Bold, Secondary)
        Spacer(Modifier.weight(1f))
        if (trailing != null) T(trailing, 10.sp, FontWeight.Medium, Secondary)
    }
}

/** Speed with the posted limit sign (red when above limit + tolerance). */
@Composable
fun Speedometer(speedKmh: Double?, limitKmh: Int?, tolerance: Double, warningEnabled: Boolean) {
    val speed = speedKmh?.let { max(0, it.roundToInt()) }
    val over = warningEnabled && limitKmh != null && speed != null && speed > limitKmh + tolerance
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            T(speed?.toString() ?: "—", 22.sp, FontWeight.Black, if (over) RV.danger else Color.White, 1)
            T(NavText.kmh, 9.sp, FontWeight.Medium, Secondary, 1)
        }
        if (limitKmh != null) {
            Box(Modifier.size(42.dp).clip(CircleShape).background(Color.White).border(4.dp, RV.danger, CircleShape),
                contentAlignment = Alignment.Center) {
                T("$limitKmh", 15.sp, FontWeight.Black, Color.Black, 1)
            }
        }
    }
}

/** Lane arrows, recommended lanes highlighted (iOS `LaneGuidanceView`). */
@Composable
fun LaneGuidance(lanes: List<Lane>, recommended: List<Boolean>) {
    if (lanes.isEmpty()) return
    val width = when { lanes.size <= 4 -> 34.dp; lanes.size <= 6 -> 30.dp; else -> 24.dp }
    val good = lanes.indices.filter { recommended.getOrNull(it) == true }.map { (it + 1).toString() }
    val a11y = if (good.isEmpty()) L("lanes.a11y.count", lanes.size) else L("lanes.a11y.recommended", lanes.size, good.joinToString(", "))
    Row(Modifier.clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f)).padding(5.dp)
        .semantics { contentDescription = a11y }, horizontalArrangement = Arrangement.spacedBy(if (lanes.size > 6) 2.dp else 4.dp)) {
        lanes.forEachIndexed { i, lane ->
            val isGood = recommended.getOrNull(i) == true
            val turns = (if (lane.turns.isEmpty()) listOf(LaneTurn.THROUGH) else lane.turns.take(2)).distinctBy { it.symbolName }
            Row(Modifier.width(width).height(38.dp).clip(RoundedCornerShape(6.dp))
                .background(if (isGood) Color(0xFF0A84FF) else Color.White.copy(alpha = 0.08f))
                .border(1.dp, Color.White.copy(alpha = if (isGood) 0.9f else 0.2f), RoundedCornerShape(6.dp)),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                turns.forEach { t ->
                    Icon(NavStyle.laneIcon(t), null, tint = Color.White.copy(alpha = if (isGood) 1f else 0.35f),
                        modifier = Modifier.size(if (turns.size > 1) width * 0.45f else width * 0.6f))
                }
            }
        }
    }
}

/** Route strip: speed-limit colours, signals / cameras / maneuvers, position (iOS `RouteStripView`). */
@Composable
fun RouteStrip(totalDistance: Double, distanceAlong: Double, segments: List<SpeedLimitSegment>,
               events: List<RouteTimelineEvent>, showsPosition: Boolean = true, height: Dp = 8.dp) {
    val markers = events.filter {
        when (val k = it.kind) {
            RouteTimelineKind.TrafficSignal, is RouteTimelineKind.Maneuver, is RouteTimelineKind.Incident -> true
            is RouteTimelineKind.Feature -> k.kind in setOf(RouteFeatureKind.SPEED_CAMERA, RouteFeatureKind.SCHOOL,
                RouteFeatureKind.KINDERGARTEN, RouteFeatureKind.RAILWAY_CROSSING)
            else -> false
        }
    }
    val signals = events.count { it.kind == RouteTimelineKind.TrafficSignal && it.distanceAlongRoute >= distanceAlong }
    val cameras = events.count { it.kind.isSpeedCamera && it.distanceAlongRoute >= distanceAlong }
    val a11y = L("strip.a11y", signals, cameras)
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().height(max(height.value + 10, 18f).dp).semantics { contentDescription = a11y }) {
        val widthPx = with(density) { maxWidth.toPx() }
        fun x(d: Double): Float = if (totalDistance > 0) (min(1.0, max(0.0, d / totalDistance)) * widthPx).toFloat() else 0f
        Canvas(Modifier.matchParentSize()) {
            val h = height.toPx()
            val top = (size.height - h) / 2
            val r = CornerRadius(h / 2, h / 2)
            drawRoundRect(NavStyle.speedLimitColor(null).copy(alpha = 0.6f), Offset(0f, top), Size(size.width, h), r)
            for (s in segments) {
                val x0 = x(s.start); val x1 = x(s.end)
                drawRect(NavStyle.speedLimitColor(s.limitKmh), Offset(x0, top), Size(max(1f, x1 - x0), h))
            }
            if (showsPosition) drawRect(Color.Black.copy(alpha = 0.45f), Offset(0f, top), Size(x(distanceAlong), h))
            val cy = size.height / 2
            for (e in markers) {
                val cx = x(e.distanceAlongRoute)
                when (e.kind) {
                    is RouteTimelineKind.Maneuver -> drawRect(Color.White, Offset(cx - 1f, top - 3.dp.toPx()), Size(2.dp.toPx(), h + 6.dp.toPx()))
                    RouteTimelineKind.TrafficSignal -> drawCircle(NavStyle.eventColor(e.kind), 2.5.dp.toPx(), Offset(cx, cy))
                    else -> {
                        drawCircle(NavStyle.eventColor(e.kind), 6.dp.toPx(), Offset(cx, cy))
                        drawCircle(Color.White, 2.dp.toPx(), Offset(cx, cy))
                    }
                }
            }
            if (showsPosition && totalDistance > 0) {
                val px = x(distanceAlong)
                drawCircle(RV.accent, h / 2 + 4.dp.toPx(), Offset(px, cy))
                drawCircle(Color.White, h / 2 + 1.5.dp.toPx(), Offset(px, cy))
            }
        }
    }
}

@Composable
fun TimelineRow(event: RouteTimelineEvent, distanceAhead: Double, timeAhead: Double?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(22.dp).clip(RoundedCornerShape(6.dp)).background(NavStyle.eventColor(event.kind)), contentAlignment = Alignment.Center) {
            Icon(NavStyle.icon(event.symbolName), null, tint = Color.White, modifier = Modifier.size(14.dp))
        }
        Column(Modifier.weight(1f)) {
            T(event.title, 12.sp, FontWeight.SemiBold, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                event.detail?.takeIf { it.isNotEmpty() }?.let { T(it, 11.sp, color = Secondary, maxLines = 1, modifier = Modifier.weight(1f, fill = false)) }
                SourceTag(event.source, Secondary)
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            T(NavText.distance(distanceAhead), 12.sp, FontWeight.Bold, maxLines = 1)
            if (timeAhead != null && timeAhead >= 30) T("≈ " + NavText.duration(timeAhead), 11.sp, color = Secondary, maxLines = 1)
        }
    }
}

@Composable
fun WeatherLine(label: String, snapshot: WeatherSnapshot?, error: String?) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(NavStyle.icon(snapshot?.symbolName ?: "cloud.fill"), null, tint = NavStyle.yellow, modifier = Modifier.size(16.dp))
            val value = snapshot?.let { NavText.weatherSummary(it) } ?: error?.let { L("nav.weather.noData", it) } ?: L("status.loading")
            T("$label: $value", 13.sp, maxLines = 2)
        }
        snapshot?.let { NavText.weatherWarnings(it).take(2) }?.forEach { w ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.offset(x = 22.dp)) {
                Icon(NavStyle.icon("exclamationmark.triangle.fill"), null, tint = NavStyle.orange, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(4.dp))
                T(w, 11.sp, FontWeight.SemiBold, NavStyle.orange)
            }
        }
    }
}

@Composable
fun Chip(icon: ImageVector, tint: Color, text: String, a11y: String? = null) {
    Row(Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).padding(horizontal = 8.dp).height(22.dp)
        .let { m -> if (a11y != null) m.semantics { contentDescription = a11y } else m },
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(12.dp))
        Spacer(Modifier.width(4.dp))
        T(text, 11.sp, FontWeight.SemiBold, maxLines = 1)
    }
}
