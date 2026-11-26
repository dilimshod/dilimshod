package uz.roadvis.app.camera

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.ui.RV
import uz.roadvis.core.BBox
import uz.roadvis.core.DistanceStatus
import uz.roadvis.core.EgoCorridor
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.LaneEstimate
import uz.roadvis.core.LaneSide
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.PedestrianHazard
import uz.roadvis.core.PedestrianHazardLevel
import uz.roadvis.core.RoadwayZone
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** Area kept free for the floating lead-distance label, in dp (full-screen coordinates). */
data class LabelInsets(val top: Float, val start: Float, val bottom: Float, val end: Float)

/**
 * Everything drawn over the camera picture that follows the processed frames (port of iOS `LiveDetectionLayer`):
 * own-lane corridor, roadway boundary, lane overlay, corner-bracket boxes with the lead highlighted, the animated
 * distance line, and the tap targets (tap a box → detail card). Same aspect-fill mapping as the preview.
 */
@Composable
fun LiveDetectionLayer(
    c: RecognitionController, settings: AppSettings, selectedTrackID: Int?, onSelect: (Int?) -> Unit,
    labelInsets: LabelInsets,
) {
    val following = settings.followingDistanceEnabled
    val lead = if (following) c.leadVehicle else null
    val assessment = if (following) c.followingAssessment else null
    val status = if (lead == null) DistanceStatus.UNKNOWN else (assessment?.status ?: DistanceStatus.UNKNOWN)
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val w = constraints.maxWidth.toFloat(); val h = constraints.maxHeight.toFloat()
        val mapping = AspectFillMapping.of(c.frameWidth.toFloat(), c.frameHeight.toFloat(), w, h)
        if (following && settings.showEgoCorridor) {
            EgoCorridorOverlay(c.egoCorridor, mapping, if (status == DistanceStatus.UNKNOWN) Color.White else CamTheme.statusColor(status))
        }
        val zone = c.roadwayZone
        if (c.assist.showRoadwayBoundary && zone != null) RoadwayBoundaryOverlay(zone, mapping)
        val lane = c.laneEstimate
        if (c.assist.showLaneOverlay && lane != null) LaneOverlay(lane, mapping, c.laneDepartureSide)
        DetectionBoxes(c.tracks, mapping, lead, status, selectedTrackID, hazardLevels(c.pedestrianHazards))
        AnimatedVisibility(lead != null, enter = fadeIn(), exit = fadeOut()) {
            val l = lead ?: c.leadVehicle
            if (l != null) {
                val insetsPx = with(density) {
                    LabelInsets(labelInsets.top.dp.toPx(), labelInsets.start.dp.toPx(), labelInsets.bottom.dp.toPx(), labelInsets.end.dp.toPx())
                }
                LeadDistanceOverlay(l, assessment, mapping, w, h, insetsPx, settings.showDistanceEstimates,
                    settings.showSpeedEstimates, c.tracks.firstOrNull { it.id == l.trackID }?.estimatedSpeedKmh)
            }
        }
        TrackHitLayer(c.tracks, mapping, selectedTrackID, onSelect)
    }
}

/** Hazard level per track (the most urgent level when a track appears twice). */
fun hazardLevels(hazards: List<PedestrianHazard>): Map<Int, PedestrianHazardLevel> {
    val result = HashMap<Int, PedestrianHazardLevel>()
    for (h in hazards) {
        val old = result[h.trackID]
        result[h.trackID] = if (old == null || h.level.rawValue > old.rawValue) h.level else old
    }
    return result
}

// Boxes

/**
 * Thin rounded corner brackets with a barely visible fill and a tiny label chip above the box (class + confident make).
 * The lead vehicle gets a thicker bracket in the status colour that pulses when the gap is short; pedestrian hazards
 * red / orange; officers blue, road workers orange. Tentative tracks: faint dashed brackets without a label.
 */
@Composable
private fun DetectionBoxes(
    tracks: List<TrackedObject>, mapping: AspectFillMapping, lead: LeadVehicle?, leadStatus: DistanceStatus,
    selectedTrackID: Int?, hazards: Map<Int, PedestrianHazardLevel>,
) {
    val anyPulse = hazards.isNotEmpty() || (lead != null && (leadStatus == DistanceStatus.CAUTION || leadStatus == DistanceStatus.DANGER))
    val pulse = pulseAlpha(anyPulse, 0.55f, if (leadStatus == DistanceStatus.DANGER || hazards.values.any { it == PedestrianHazardLevel.DANGER }) 800 else 1300)
    val density = LocalDensity.current
    val dp = density.density
    Canvas(Modifier.fillMaxSize()) {
        for (t in tracks) {
            val style = boxStyle(t, lead, leadStatus, hazards[t.id], selectedTrackID == t.id)
            val r = mapping.rect(t.box)
            val rw = max(r.width, 6 * dp); val rh = max(r.height, 6 * dp)
            val left = r.centerX - rw / 2; val top = r.centerY - rh / 2
            val alphaMul = (if (t.missed > 0) 0.6f else 1f) * (if (style.pulses) pulse else 1f)
            val radius = 8 * dp
            if (t.isConfirmed) {
                drawRoundRect(style.color.copy(alpha = style.fillAlpha * (if (t.missed > 0) 0.6f else 1f)), Offset(left, top), Size(rw, rh), CornerRadius(radius))
                drawRoundRect(style.color.copy(alpha = (if (style.emphasized) 0.75f else 0.35f) * (if (t.missed > 0) 0.6f else 1f)),
                    Offset(left, top), Size(rw, rh), CornerRadius(radius), style = Stroke((if (style.emphasized) 1.5f else 1f) * dp))
            }
            val bracket = cornerBrackets(left, top, rw, rh, if (t.isConfirmed) 0.22f else 0.16f, radius, 7 * dp)
            if (style.emphasized) {
                drawPath(bracket, style.color.copy(alpha = 0.3f * alphaMul), style = Stroke((style.lineWidth + 5) * dp, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            drawPath(bracket, style.color.copy(alpha = (if (t.isConfirmed) 0.95f else 0.4f) * alphaMul),
                style = Stroke(style.lineWidth * dp, cap = StrokeCap.Round, join = StrokeJoin.Round,
                    pathEffect = if (t.isConfirmed) null else PathEffect.dashPathEffect(floatArrayOf(3 * dp, 4 * dp))))
            if (style.selected) {
                drawRoundRect(Color.White.copy(alpha = 0.85f), Offset(left - 3 * dp, top - 3 * dp), Size(rw + 6 * dp, rh + 6 * dp),
                    CornerRadius(radius + 3 * dp), style = Stroke(1 * dp))
            }
        }
    }
    // Label chips (confirmed tracks only)
    Box(Modifier.fillMaxSize()) {
        for (t in tracks) {
            if (!t.isConfirmed) continue
            val style = boxStyle(t, lead, leadStatus, hazards[t.id], selectedTrackID == t.id)
            val r = mapping.rect(t.box)
            val labelInside = r.top < 28 * dp
            TrackLabelChip(t, style.color, lead?.trackID == t.id, style.emphasized,
                Modifier.alpha(if (t.missed > 0) 0.6f else 1f).layout { measurable, constraints ->
                    val maxW = (CamTheme.maxLabelWidth.toPx()).roundToInt()
                    val p = measurable.measure(constraints.copy(minWidth = 0, maxWidth = maxW, minHeight = 0))
                    layout(p.width, p.height) {
                        val alignTrailing = r.centerX > constraints.maxWidth * 0.62f
                        val x = if (alignTrailing) r.right - p.width else r.left
                        val y = if (labelInside) r.top + 4 * dp else r.top - p.height - 4 * dp
                        p.place(x.roundToInt(), y.roundToInt())
                    }
                })
        }
    }
}

private data class BoxStyle(
    val color: Color, val lineWidth: Float, val emphasized: Boolean, val pulses: Boolean, val fillAlpha: Float, val selected: Boolean,
)

private fun boxStyle(t: TrackedObject, lead: LeadVehicle?, leadStatus: DistanceStatus, hazard: PedestrianHazardLevel?, selected: Boolean): BoxStyle {
    val isLead = lead?.trackID == t.id
    val role = t.roadStaffRole
    val emphasized = isLead || hazard != null || role != null
    val color = when {
        hazard != null -> CamTheme.pedestrianColor(hazard)
        role != null -> CamTheme.roleColor(role) ?: CamTheme.kindColor(t.kind)
        isLead && leadStatus != DistanceStatus.UNKNOWN -> CamTheme.statusColor(leadStatus)
        else -> CamTheme.kindColor(t.kind)
    }
    val lineWidth = when {
        hazard != null -> CamTheme.strokeLead + 1
        isLead -> CamTheme.strokeLead + 0.5f
        selected -> CamTheme.strokeSelected + 0.5f
        t.isConfirmed -> CamTheme.strokeBox + 0.5f
        else -> CamTheme.strokeTentative
    }
    val pulses = hazard != null || (isLead && (leadStatus == DistanceStatus.CAUTION || leadStatus == DistanceStatus.DANGER))
    val fill = if (hazard == PedestrianHazardLevel.DANGER) 0.14f else if (emphasized) 0.1f else 0.04f
    return BoxStyle(color, lineWidth, emphasized, pulses, fill, selected)
}

/** Four rounded corner brackets ("viewfinder" style) inside the rect (iOS `CornerBracketShape`). */
private fun cornerBrackets(x: Float, y: Float, w: Float, h: Float, armFraction: Float, cornerRadius: Float, minArm: Float): Path {
    val path = Path()
    if (w <= 0 || h <= 0) return path
    val arm = min(min(max(minArm, min(w, h) * armFraction), w / 2), h / 2)
    val r = min(cornerRadius, arm * 0.7f)
    val maxX = x + w; val maxY = y + h
    path.moveTo(x, y + arm); path.lineTo(x, y + r); path.quadraticTo(x, y, x + r, y); path.lineTo(x + arm, y)
    path.moveTo(maxX - arm, y); path.lineTo(maxX - r, y); path.quadraticTo(maxX, y, maxX, y + r); path.lineTo(maxX, y + arm)
    path.moveTo(maxX, maxY - arm); path.lineTo(maxX, maxY - r); path.quadraticTo(maxX, maxY, maxX - r, maxY); path.lineTo(maxX - arm, maxY)
    path.moveTo(x + arm, maxY); path.lineTo(x + r, maxY); path.quadraticTo(x, maxY, x, maxY - r); path.lineTo(x, maxY - arm)
    return path
}

/** Tiny single-line capsule above a box: class symbol, class (+ confident make), lead marker. */
@Composable
private fun TrackLabelChip(t: TrackedObject, color: Color, isLead: Boolean, emphasized: Boolean, modifier: Modifier) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier.background(Color.Black.copy(alpha = 0.45f), shape)
            .border(0.5.dp, color.copy(alpha = if (emphasized) 0.7f else 0.35f), shape)
            .padding(horizontal = 6.dp, vertical = 2.5.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        if (t.kind == VehicleKind.TRAFFIC_LIGHT) {
            TrafficLightDot(t.lightColor ?: TrafficLightColor.UNKNOWN, 8.dp)
        } else {
            val icon = when {
                isLead -> Icons.Filled.DirectionsCar
                t.roadStaffRole != null -> CamTheme.roleIcon(t.roadStaffRole!!)
                else -> CamTheme.kindIcon(t.kind)
            }
            Icon(icon, null, tint = color, modifier = Modifier.size(10.dp))
        }
        Text(TrackText.compactTitle(t), style = CamTheme.text(11.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Coloured dot for compact places (overlay chips, detail card). */
@Composable
fun TrafficLightDot(color: TrafficLightColor, size: androidx.compose.ui.unit.Dp) {
    val fill = CamTheme.lightColor(color)
    Box(Modifier.size(size).background(fill, CircleShape).border(max(1f, size.value * 0.1f).dp, Color.White.copy(alpha = 0.85f), CircleShape))
}

/**
 * Transparent tap targets over the confirmed boxes (≥ 44 dp). Tapping a box selects it (again → deselects); while
 * something is selected, tapping the picture deselects. Smaller boxes win over the big ones that contain them.
 */
@Composable
private fun TrackHitLayer(tracks: List<TrackedObject>, mapping: AspectFillMapping, selectedTrackID: Int?, onSelect: (Int?) -> Unit) {
    val current by rememberUpdatedState(Triple(tracks, mapping, selectedTrackID))
    val select by rememberUpdatedState(onSelect)
    val minHit = with(LocalDensity.current) { 44.dp.toPx() }
    Box(Modifier.fillMaxSize().pointerInput(Unit) {
        detectTapGestures { p ->
            val (ts, m, sel) = current
            val hit = ts.filter { it.isConfirmed }.sortedBy { it.box.area }.firstOrNull { t ->
                val r = m.rect(t.box)
                val hw = max(r.width, minHit) / 2; val hh = max(r.height, minHit) / 2
                p.x in (r.centerX - hw)..(r.centerX + hw) && p.y in (r.centerY - hh)..(r.centerY + hh)
            }
            when {
                hit != null -> select(if (sel == hit.id) null else hit.id)
                sel != null -> select(null)
            }
        }
    })
}

// Lead distance line

/** Eases the line endpoints toward their targets (critically damped, τ ≈ 90 ms) so the line glides between frames. */
private class LeadLineSmoother {
    var start: Offset? = null; var end: Offset? = null; var markerWidth: Float? = null
    private var lastTime: Double? = null

    fun step(targetStart: Offset, targetEnd: Offset, targetWidth: Float, time: Double): Triple<Offset, Offset, Float> {
        val dt = lastTime?.let { min(0.25, max(0.0, time - it)) } ?: 1.0
        lastTime = time
        val k = (1 - exp(-dt / 0.09)).toFloat()
        fun ease(cur: Offset?, target: Offset, snap: Float): Offset {
            if (cur == null) return target
            val d = (cur - target).getDistance()
            if (d >= snap) return target
            return Offset(cur.x + (target.x - cur.x) * k, cur.y + (target.y - cur.y) * k)
        }
        val s = ease(start, targetStart, 400f * densityHint); val e = ease(end, targetEnd, 220f * densityHint)
        val w = markerWidth?.let { it + (targetWidth - it) * k } ?: targetWidth
        start = s; end = e; markerWidth = w
        return Triple(s, e, w)
    }

    var densityHint = 1f
}

/**
 * Animated distance line from the own car (bottom centre) to the lead (bottom centre of its box): flowing dashes and
 * chevrons toward the lead (faster while closing), status-colour gradient, a ground marker with a "sonar" ring and a
 * small label beside the line ("≈ 18 m · 1,4 s"). This is the only place a distance is drawn on the picture.
 */
@Composable
private fun LeadDistanceOverlay(
    lead: LeadVehicle, assessment: FollowingDistanceAssessment?, mapping: AspectFillMapping, viewW: Float, viewH: Float,
    insets: LabelInsets, showDistance: Boolean, showSpeed: Boolean, leadSpeedKmh: Double?,
) {
    val status = assessment?.status ?: DistanceStatus.UNKNOWN
    val color = CamTheme.statusColor(status)
    val danger = status == DistanceStatus.DANGER
    val closing = min(60.0, max(0.0, assessment?.closingSpeedKmh ?: 0.0))
    val density = LocalDensity.current.density
    val flowSpeed = (38 + closing * 2.5) * density
    val smoother = remember { LeadLineSmoother() }
    smoother.densityHint = density
    val time by produceState(0.0) {
        while (true) withFrameNanos { value = it / 1_000_000_000.0 }
    }
    val bottomY = mapping.y(1.0)
    val start = Offset(mapping.x(0.5), min(bottomY, viewH) + 6 * density)
    val end = Offset(mapping.x(lead.box.midX), mapping.y(min(1.0, lead.box.maxY)))
    val markerWidth = mapping.rect(lead.box).width * 0.9f
    Canvas(Modifier.fillMaxSize()) {
        val (s, e, mw) = smoother.step(start, end, markerWidth, time)
        drawLeadLine(s, e, mw, color, danger, flowSpeed, time, density)
    }
    if (showDistance || (showSpeed && leadSpeedKmh != null)) {
        val labelPos = labelPosition(start, end, viewW, viewH, insets, density)
        LeadDistanceLabel(lead, assessment, showDistance, if (showSpeed) leadSpeedKmh else null, Modifier.layout { m, cons ->
            val p = m.measure(cons.copy(minWidth = 0, minHeight = 0))
            layout(p.width, p.height) { p.place((labelPos.x - p.width / 2).roundToInt(), (labelPos.y - p.height / 2).roundToInt()) }
        })
    }
}

/** 60 % of the way from the car to the lead, shifted sideways next to the line, kept inside the insets. */
private fun labelPosition(start: Offset, end: Offset, w: Float, h: Float, insets: LabelInsets, d: Float): Offset {
    val t = 0.6f
    val anchor = Offset(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t)
    val halfW = 54 * d; val halfH = 13 * d; val gap = 12 * d
    val side = if (end.x > start.x + 20 * d) -1f else 1f
    var x = anchor.x + side * (halfW + gap)
    var y = anchor.y
    val minX = insets.start + halfW; val maxX = w - insets.end - halfW
    val minY = insets.top + halfH; val maxY = h - insets.bottom - halfH
    if (minX <= maxX && (x < minX || x > maxX)) {
        val other = anchor.x - side * (halfW + gap)
        x = if (other in minX..maxX) other else x.coerceIn(minX, maxX)
    }
    if (minY <= maxY) y = y.coerceIn(minY, maxY)
    return Offset(x, y)
}

private fun DrawScope.drawLeadLine(start: Offset, end: Offset, markerWidth: Float, color: Color, danger: Boolean,
                                   flowSpeed: Double, time: Double, d: Float) {
    val dx = end.x - start.x; val dy = end.y - start.y
    val length = sqrt(dx * dx + dy * dy)
    val pulse = if (danger) (0.5 + 0.5 * sin(time * 2 * PI * 1.6)).toFloat() else 0f
    if (length > 16 * d) {
        val ux = dx / length; val uy = dy / length
        val nx = -uy; val ny = ux
        // Soft glow under the dashes.
        drawLine(Brush.linearGradient(listOf(color.copy(alpha = 0f), color.copy(alpha = 0.14f + 0.2f * pulse)), start, end),
            start, end, (8 + 6 * pulse) * d, StrokeCap.Round)
        // Dashes flowing toward the lead.
        val dash = 12 * d; val gapLen = 10 * d; val period = dash + gapLen
        val travelled = ((time * flowSpeed) % period).toFloat()
        drawLine(Brush.linearGradient(listOf(color.copy(alpha = 0.05f), color.copy(alpha = 0.7f), color.copy(alpha = 0.95f)), start, end),
            start, end, (2.5f + pulse) * d, StrokeCap.Round, PathEffect.dashPathEffect(floatArrayOf(dash, gapLen), period - travelled))
        // Chevrons pointing at the lead, bigger near the own car.
        val spacing = 64 * d
        val offset = ((time * flowSpeed) % spacing).toFloat()
        val count = (length / spacing).toInt() + 1
        for (i in 0..count) {
            val dd = i * spacing + offset
            if (dd <= 28 * d || dd >= length - 34 * d) continue
            val tt = dd / length
            val cx = start.x + dx * tt; val cy = start.y + dy * tt
            val size = (4 + 3 * (1 - tt)) * d
            val p = Path().apply {
                moveTo(cx - ux * size + nx * size, cy - uy * size + ny * size)
                lineTo(cx, cy)
                lineTo(cx - ux * size - nx * size, cy - uy * size - ny * size)
            }
            val fade = min(1f, min((dd - 28 * d) / (50 * d), (length - 34 * d - dd) / (50 * d)))
            drawPath(p, color.copy(alpha = 0.75f * fade), style = Stroke(1.8f * d, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
    }
    // Ground marker + sonar ring.
    val mw = max(30 * d, markerWidth); val mh = mw * 0.18f
    drawOval(color.copy(alpha = 0.12f + 0.15f * pulse), Offset(end.x - mw / 2, end.y - mh / 2), Size(mw, mh))
    drawOval(color.copy(alpha = 0.85f), Offset(end.x - mw / 2, end.y - mh / 2), Size(mw, mh), style = Stroke(1.5f * d))
    val phase = ((time * (if (danger) 1.4 else 0.7)) % 1.0).toFloat()
    val sc = 1 + 0.6f * phase
    drawOval(color.copy(alpha = 0.45f * (1 - phase)), Offset(end.x - mw * sc / 2, end.y - mh * sc / 2), Size(mw * sc, mh * sc), style = Stroke(1.2f * d))
}

/** "≈ 18 m · 1,4 s" while moving, "≈ 1,6 m" when standing; optional ≈ lead speed below. */
@Composable
private fun LeadDistanceLabel(lead: LeadVehicle, assessment: FollowingDistanceAssessment?, showDistance: Boolean,
                              speedKmh: Double?, modifier: Modifier) {
    val status = assessment?.status ?: DistanceStatus.UNKNOWN
    val color = CamTheme.statusColor(status)
    val gap = FollowingDistanceText.gap(lead.distanceMeters)
    val headway = assessment?.timeHeadwaySeconds
    val text = if (assessment != null && !assessment.isStopped && headway != null) gap + " · " + CamFmt.gapSeconds(headway) else gap
    val shape = RoundedCornerShape(50)
    val iconAlpha = pulseAlpha(status == DistanceStatus.DANGER, 0.4f, 900)
    Row(
        modifier.background(Color.Black.copy(alpha = 0.5f), shape).background(color.copy(alpha = 0.12f), shape)
            .border(0.75.dp, color.copy(alpha = 0.55f), shape).padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Icon(CamTheme.statusIcon(status), null, tint = color, modifier = Modifier.size(11.dp).alpha(iconAlpha))
        Column {
            if (showDistance) Text(text, style = CamTheme.numeric(13.sp), maxLines = 1)
            if (speedKmh != null && speedKmh.isFinite() && speedKmh >= 0) {
                Text("≈ ${speedKmh.roundToInt()} ${CamFmt.kmh}", style = CamTheme.numeric(if (showDistance) 10.sp else 13.sp, androidx.compose.ui.text.font.FontWeight.SemiBold),
                    modifier = Modifier.alpha(if (showDistance) 0.8f else 1f), maxLines = 1)
            }
        }
    }
}

// Lanes, corridor, roadway

/**
 * Lane markings from the lane detector: thick (4.5 dp) warm-white lines from the bottom up to the horizon, fading
 * toward it, with a translucent cyan-green fill between both lines. Departure: that side red and pulsing, fill red.
 */
@Composable
private fun LaneOverlay(estimate: LaneEstimate, mapping: AspectFillMapping, departureSide: LaneSide?) {
    val pulse = pulseAlpha(departureSide != null, 0.45f, 600)
    val minConfidence = 0.3
    Canvas(Modifier.fillMaxSize()) {
        val d = density
        fun segment(side: LaneSide): Triple<Offset, Offset, Float>? {
            val line = estimate.line(side) ?: return null
            val conf = estimate.confidence(side)
            if (conf < minConfidence) return null
            val topY = min(line.topY, line.bottomY - 0.05)
            val b = Offset(mapping.x(line.x(1.0)), mapping.y(1.0))
            val t = Offset(mapping.x(line.x(topY)), mapping.y(topY))
            if (!b.x.isFinite() || !t.x.isFinite()) return null
            val strength = 0.35 + 0.65 * ((conf - minConfidence) / max(0.05, 0.7 - minConfidence)).coerceIn(0.0, 1.0)
            return Triple(b, t, strength.toFloat())
        }
        val left = segment(LaneSide.LEFT); val right = segment(LaneSide.RIGHT)
        if (left != null && right != null) {
            val departing = departureSide != null
            val color = if (departing) RV.danger else LANE_FILL
            val strength = min(left.third, right.third)
            val bottomOpacity = if (departing) 0.26f else 0.18f * (0.5f + 0.5f * strength)
            val top = min(left.second.y, right.second.y); val bottom = max(left.first.y, right.first.y)
            val path = Path().apply { moveTo(left.first.x, left.first.y); lineTo(left.second.x, left.second.y); lineTo(right.second.x, right.second.y); lineTo(right.first.x, right.first.y); close() }
            drawPath(path, Brush.verticalGradient(0f to color.copy(alpha = 0f), 0.4f to color.copy(alpha = bottomOpacity * 0.45f), 1f to color.copy(alpha = bottomOpacity), startY = top, endY = bottom))
        }
        for ((side, seg) in listOf(LaneSide.LEFT to left, LaneSide.RIGHT to right)) {
            if (seg == null) continue
            val departing = departureSide == side
            val color = if (departing) RV.danger else LANE_LINE
            val opacity = (if (departing) 0.95f else 0.8f * seg.third) * (if (departing) pulse else 1f)
            val width = (if (departing) 6f else 4.5f) * d
            // Soft shadow / glow so the line stays visible on bright asphalt.
            drawLine(if (departing) RV.danger.copy(alpha = 0.35f * opacity) else Color.Black.copy(alpha = 0.25f), seg.first, seg.second, width + 4 * d, StrokeCap.Round)
            drawLine(Brush.verticalGradient(0f to color.copy(alpha = opacity * 0.12f), 0.35f to color.copy(alpha = opacity * 0.7f), 1f to color.copy(alpha = opacity),
                startY = seg.second.y, endY = seg.first.y), seg.first, seg.second, width, StrokeCap.Round)
        }
    }
}

private val LANE_LINE = Color(1.0f, 0.96f, 0.84f)
private val LANE_FILL = Color(0.16f, 0.9f, 0.78f)

/** Very subtle trapezoid of the own-lane corridor the lead is picked from (tinted with the status colour). */
@Composable
private fun EgoCorridorOverlay(corridor: EgoCorridor, mapping: AspectFillMapping, tint: Color) {
    Canvas(Modifier.fillMaxSize()) {
        val p = corridor.polygon.map { Offset(mapping.x(it.first), mapping.y(it.second)) }
        if (p.size != 4) return@Canvas
        val top = p[1].y; val bottom = p[0].y
        val path = Path().apply { moveTo(p[0].x, p[0].y); p.drop(1).forEach { lineTo(it.x, it.y) }; close() }
        drawPath(path, Brush.verticalGradient(0f to tint.copy(alpha = 0f), 0.45f to tint.copy(alpha = 0.04f), 1f to tint.copy(alpha = 0.08f), startY = top, endY = bottom))
        val edge = Brush.verticalGradient(listOf(tint.copy(alpha = 0f), tint.copy(alpha = 0.12f)), startY = top, endY = bottom)
        drawLine(edge, p[0], p[1], 1.5f * density, StrokeCap.Round)
        drawLine(edge, p[3], p[2], 1.5f * density, StrokeCap.Round)
        val mid0 = Offset((p[0].x + p[3].x) / 2, (p[0].y + p[3].y) / 2); val mid1 = Offset((p[1].x + p[2].x) / 2, (p[1].y + p[2].y) / 2)
        drawLine(Brush.verticalGradient(listOf(tint.copy(alpha = 0f), tint.copy(alpha = 0.08f)), startY = top, endY = bottom), mid0, mid1,
            1f * density, StrokeCap.Round, PathEffect.dashPathEffect(floatArrayOf(6 * density, 12 * density)))
    }
}

/** The roadway / sidewalk boundary as two thin subtle dashed white lines (0.35 opacity). */
@Composable
private fun RoadwayBoundaryOverlay(zone: RoadwayZone, mapping: AspectFillMapping) {
    Canvas(Modifier.fillMaxSize()) {
        val p = zone.polygon().map { Offset(mapping.x(it.first), mapping.y(it.second)) }
        if (p.size != 4 || p.any { !it.x.isFinite() || !it.y.isFinite() }) return@Canvas
        val brush = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.05f), Color.White.copy(alpha = 0.35f)), startY = p[1].y, endY = p[0].y)
        val effect = PathEffect.dashPathEffect(floatArrayOf(7 * density, 9 * density))
        drawLine(Color.Black.copy(alpha = 0.12f), p[0], p[1], 2.4f * density, StrokeCap.Round, effect)
        drawLine(Color.Black.copy(alpha = 0.12f), p[3], p[2], 2.4f * density, StrokeCap.Round, effect)
        drawLine(brush, p[0], p[1], 1.2f * density, StrokeCap.Round, effect)
        drawLine(brush, p[3], p[2], 1.2f * density, StrokeCap.Round, effect)
    }
}

/** Pulsing red glow around the screen edges during a forward-collision warning. */
@Composable
fun CollisionWarningGlow(active: Boolean) {
    AnimatedVisibility(active, enter = fadeIn(), exit = fadeOut()) {
        val a = pulseAlpha(true, 0.3f, 550)
        Canvas(Modifier.fillMaxSize().alpha(a)) {
            val w = 28 * density
            for (i in 0 until 6) {
                val inset = i * w / 6
                drawRect(RV.danger.copy(alpha = 0.22f * (1 - i / 6f)), Offset(inset, inset), Size(size.width - 2 * inset, size.height - 2 * inset),
                    style = Stroke(w / 6))
            }
        }
    }
}

@Suppress("unused")
private fun BBox.isValid(): Boolean = width > 0 && height > 0
