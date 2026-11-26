package uz.roadvis.app.camera

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppState
import uz.roadvis.app.app.NavBanner
import uz.roadvis.app.l10n.L
import uz.roadvis.core.ManeuverType
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Minimal next-manoeuvre banner for the camera screen while guidance runs (port of iOS `NavigationMiniBanner`), in the
 * top-LEFT column under the speedometer: a white, vertical, slightly transparent turn arrow (≈ 40 dp, alpha 0.85),
 * the distance underneath, the street in small text and a thin countdown bar for the last 300 m. No heavy plate —
 * only a soft shadow. Tap → navigator. Renders nothing while `bus.navBanner` is null.
 */
@Composable
fun NavigationMiniBanner(app: AppState) {
    val banner = app.bus.navBanner ?: return
    val arrived = banner.maneuver == ManeuverType.ARRIVE
    val street = banner.street?.takeIf { it.isNotBlank() } ?: app.bus.currentRoad?.localizedDisplayName
    val a11y = if (arrived) L("voice.arrived") else CamFmt.distance(banner.distanceMeters) + ", " + banner.instruction.ifBlank { L("mini.continue") }
    Column(
        Modifier.width(96.dp).alpha(0.85f).pressable { app.toggleMode() }.padding(vertical = 6.dp)
            .semantics { contentDescription = a11y },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        ManeuverArrow(banner.maneuver, Modifier.size(52.dp, 46.dp))
        if (arrived) {
            Text(L("voice.arrived"), style = CamTheme.text(13.sp, FontWeight.Bold), maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            Text(CamFmt.distance(banner.distanceMeters), style = CamTheme.numeric(17.sp), maxLines = 1)
        }
        if (street != null) {
            Text(street, style = CamTheme.text(11.sp), textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.alpha(0.85f))
        }
        countdownFraction(banner)?.let { f ->
            val animated by animateFloatAsState(f, tween(400), label = "countdown")
            Box(Modifier.width(44.dp).height(3.dp).background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(50))) {
                Box(Modifier.width(44.dp * animated).fillMaxHeight().background(Color.White, RoundedCornerShape(50)))
            }
        }
    }
}

/** 0…1 over the last 300 m (or the whole step when it is shorter); null outside that window. */
fun countdownFraction(b: NavBanner): Float? {
    if (b.maneuver == ManeuverType.ARRIVE) return null
    val window = min(COUNTDOWN_DISTANCE, b.stepLengthMeters?.takeIf { it > 0 } ?: COUNTDOWN_DISTANCE)
    if (!(b.distanceMeters <= window)) return null
    return (1 - b.distanceMeters / window).toFloat().coerceIn(0f, 1f)
}

private const val COUNTDOWN_DISTANCE = 300.0

/** White turn arrow for [type] drawn with Canvas paths (stem + curve + filled head; mirrored for left turns). */
@Composable
fun ManeuverArrow(type: ManeuverType, modifier: Modifier) {
    Canvas(modifier) {
        val shadow = Color.Black.copy(alpha = 0.45f)
        drawManeuver(type, shadow, Offset(0f, 1.5f * density))
        drawManeuver(type, Color.White, Offset.Zero)
    }
}

private fun DrawScope.drawManeuver(type: ManeuverType, color: Color, shift: Offset) {
    val s = min(size.width, size.height)
    val ox = (size.width - s) / 2 + shift.x; val oy = (size.height - s) / 2 + shift.y
    val mirror = type.isLeftward && type != ManeuverType.U_TURN
    fun p(x: Float, y: Float) = Offset(ox + (if (mirror) 1 - x else x) * s, oy + y * s)
    val stroke = Stroke(width = s * 0.13f, cap = StrokeCap.Round, join = StrokeJoin.Round)
    fun head(tip: Offset, dirX: Float, dirY: Float) {
        val dx = if (mirror) -dirX else dirX
        val len = sqrt(dx * dx + dirY * dirY).takeIf { it > 0 } ?: 1f
        val ux = dx / len; val uy = dirY / len
        val h = s * 0.26f; val w = s * 0.2f
        val base = Offset(tip.x - ux * h, tip.y - uy * h)
        drawPath(Path().apply {
            moveTo(tip.x + ux * s * 0.02f, tip.y + uy * s * 0.02f)
            lineTo(base.x - uy * w, base.y + ux * w)
            lineTo(base.x + uy * w, base.y - ux * w)
            close()
        }, color)
    }
    when (type) {
        ManeuverType.STRAIGHT, ManeuverType.DEPART, ManeuverType.UNKNOWN -> {
            drawLine(color, p(0.5f, 0.95f), p(0.5f, 0.3f), stroke.width, StrokeCap.Round)
            head(p(0.5f, 0.06f), 0f, -1f)
        }
        ManeuverType.LEFT, ManeuverType.RIGHT -> {
            val path = Path().apply {
                val a = p(0.36f, 0.95f); moveTo(a.x, a.y)
                val b = p(0.36f, 0.55f); lineTo(b.x, b.y)
                val c = p(0.36f, 0.34f); val d = p(0.58f, 0.34f); quadraticTo(c.x, c.y, d.x, d.y)
                val e = p(0.7f, 0.34f); lineTo(e.x, e.y)
            }
            drawPath(path, color, style = stroke)
            head(p(0.94f, 0.34f), 1f, 0f)
        }
        ManeuverType.SLIGHT_LEFT, ManeuverType.SLIGHT_RIGHT, ManeuverType.KEEP_LEFT, ManeuverType.KEEP_RIGHT,
        ManeuverType.EXIT_LEFT, ManeuverType.EXIT_RIGHT -> {
            val path = Path().apply {
                val a = p(0.4f, 0.95f); moveTo(a.x, a.y)
                val b = p(0.4f, 0.58f); lineTo(b.x, b.y)
                val e = p(0.66f, 0.3f); lineTo(e.x, e.y)
            }
            drawPath(path, color, style = stroke)
            head(p(0.84f, 0.11f), 1f, -1.05f)
        }
        ManeuverType.SHARP_LEFT, ManeuverType.SHARP_RIGHT -> {
            val path = Path().apply {
                val a = p(0.34f, 0.95f); moveTo(a.x, a.y)
                val b = p(0.34f, 0.22f); lineTo(b.x, b.y)
                val e = p(0.62f, 0.52f); lineTo(e.x, e.y)
            }
            drawPath(path, color, style = stroke)
            head(p(0.8f, 0.72f), 1f, 1.1f)
        }
        ManeuverType.U_TURN -> {
            val path = Path().apply {
                val a = p(0.7f, 0.95f); moveTo(a.x, a.y)
                val b = p(0.7f, 0.42f); lineTo(b.x, b.y)
                arcTo(Rect(p(0.3f, 0.22f), Size(0.4f * s, 0.4f * s)), 0f, -180f, false)
                val e = p(0.3f, 0.62f); lineTo(e.x, e.y)
            }
            drawPath(path, color, style = stroke)
            head(p(0.3f, 0.86f), 0f, 1f)
        }
        ManeuverType.ROUNDABOUT -> {
            drawCircle(color, radius = s * 0.17f, center = p(0.5f, 0.4f), style = Stroke(s * 0.1f))
            drawLine(color, p(0.5f, 0.95f), p(0.5f, 0.6f), stroke.width, StrokeCap.Round)
            drawLine(color, p(0.64f, 0.29f), p(0.74f, 0.19f), stroke.width, StrokeCap.Round)
            head(p(0.9f, 0.04f), 1f, -1f)
        }
        ManeuverType.MERGE -> {
            drawLine(color, p(0.28f, 0.95f), p(0.5f, 0.55f), stroke.width, StrokeCap.Round)
            drawLine(color, p(0.72f, 0.95f), p(0.5f, 0.55f), stroke.width, StrokeCap.Round)
            drawLine(color, p(0.5f, 0.55f), p(0.5f, 0.3f), stroke.width, StrokeCap.Round)
            head(p(0.5f, 0.06f), 0f, -1f)
        }
        ManeuverType.ARRIVE -> {
            drawLine(color, p(0.3f, 0.95f), p(0.3f, 0.08f), s * 0.08f, StrokeCap.Round)
            val cell = 0.11f
            for (row in 0 until 3) for (col in 0 until 5) {
                val x = 0.34f + col * cell; val y = 0.1f + row * cell
                val filled = (row + col) % 2 == 0
                if (filled) drawRect(color, p(x, y), Size(cell * s, cell * s))
                else drawRect(color, p(x, y), Size(cell * s, cell * s), style = Stroke(s * 0.02f))
            }
        }
    }
}
