package uz.roadvis.app.camera

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.DistanceStatus
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.FollowingDistancePolicy
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.RoadSurfaceCondition

fun RoadSurfaceCondition.icon(): ImageVector = when (this) {
    RoadSurfaceCondition.DRY -> Icons.Filled.WbSunny
    RoadSurfaceCondition.WET -> Icons.Filled.WaterDrop
    RoadSurfaceCondition.SNOW -> Icons.Filled.AcUnit
    RoadSurfaceCondition.ICE -> Icons.Filled.Thermostat
}

/**
 * Gap to the vehicle ahead and the distance requirements (port of iOS `FollowingDistanceHUD`).
 * Collapsed: one slim pill with the status dot and the recommended gap for the current speed ("norm ≥ 52 m" — the
 * measured gap is on the distance line, so the pill adds the NORM instead of repeating the distance), a timer when a
 * collision is possible. Tap expands (remembered); long press → norms sheet.
 * Expanded full (portrait): status, surface chip, info button, gap + norm, progress bar, moving / stopped norms,
 * stopping distance, TTC. Expanded mini (landscape): number, status, norm and the bar.
 */
@Composable
fun FollowingDistanceHud(
    assessment: FollowingDistanceAssessment, lead: LeadVehicle?, policy: FollowingDistancePolicy,
    surfaceSource: RoadSurfaceSource, collisionWarning: Boolean, mini: Boolean, expanded: Boolean,
    onToggle: () -> Unit, onShowNorms: () -> Unit,
) {
    val hasLead = lead != null && assessment.distanceMeters != null
    val status = if (hasLead) assessment.status else DistanceStatus.UNKNOWN
    val color = CamTheme.statusColor(status)
    val gapText = if (hasLead) FollowingDistanceText.gap(assessment.distanceMeters) else "—"
    val a11y = FollowingDistanceText.accessibilitySummary(assessment, policy, hasLead)
    val toggle by rememberUpdatedState(onToggle)
    val norms by rememberUpdatedState(onShowNorms)
    val tapModifier = Modifier.semantics { contentDescription = a11y }.pointerInput(Unit) {
        detectTapGestures(onTap = { toggle() }, onLongPress = { norms() })
    }
    Box(Modifier.animateContentSize()) {
        when {
            !expanded -> Pill(assessment, hasLead, status, color, collisionWarning, tapModifier)
            mini -> MiniCard(assessment, policy, hasLead, status, color, gapText, collisionWarning, tapModifier, onShowNorms)
            else -> FullCard(assessment, policy, surfaceSource, hasLead, status, color, gapText, collisionWarning, tapModifier, onShowNorms)
        }
    }
}

@Composable
private fun Pill(a: FollowingDistanceAssessment, hasLead: Boolean, status: DistanceStatus, color: Color, collision: Boolean, mod: Modifier) {
    val shape = RoundedCornerShape(50)
    val dotAlpha = pulseAlpha(status == DistanceStatus.DANGER || collision, 0.3f, 700)
    val borderAlpha = pulseAlpha(collision, 0.2f, 600)
    Box(Modifier.sizeIn(minHeight = CamTheme.hit).then(mod), contentAlignment = Alignment.CenterStart) {
        Row(
            Modifier.height(CamTheme.pill).glass(shape, if (hasLead) color else null)
                .then(if (collision) Modifier.border(2.dp, RV.danger.copy(alpha = borderAlpha), shape) else Modifier)
                .padding(horizontal = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.size(8.dp).alpha(dotAlpha).background(if (collision) RV.danger else color, CircleShape))
            Text(L("fd.norm", FollowingDistanceText.recommended(a)),
                style = CamTheme.numeric(14.sp, color = Color.White.copy(alpha = if (hasLead) 1f else 0.8f)), maxLines = 1)
            if (hasLead) FollowingDistanceText.timeToCollision(a)?.let { ttc ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    Icon(Icons.Filled.Timer, null, tint = RV.danger, modifier = Modifier.size(12.dp))
                    Text(ttc, style = CamTheme.numeric(12.sp, color = RV.danger), maxLines = 1)
                }
            }
            Icon(Icons.Filled.ExpandMore, null, tint = Color.White.copy(alpha = 0.5f), modifier = Modifier.size(12.dp))
        }
    }
}

@Composable
private fun StatusIcon(status: DistanceStatus, collision: Boolean, color: Color, size: Int) {
    val a = pulseAlpha(status == DistanceStatus.DANGER, 0.4f, 900)
    Icon(if (collision) Icons.Filled.Report else CamTheme.statusIcon(status), null, tint = color,
        modifier = Modifier.size((size + 2).dp).alpha(a))
}

@Composable
private fun InfoButton(onShowNorms: () -> Unit) {
    Box(Modifier.size(36.dp, 32.dp).pressable(onShowNorms).semantics { contentDescription = L("fd.norms.title") },
        contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Info, null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(17.dp))
    }
}

@Composable
private fun NormBlock(a: FollowingDistanceAssessment, size: Int) {
    Column(horizontalAlignment = Alignment.End) {
        Text(if (a.isStopped) L("fd.normStanding") else L("fd.normWord"), style = CamTheme.text(10.sp, color = Color.White.copy(alpha = 0.7f)))
        Text(FollowingDistanceText.recommended(a), style = CamTheme.numeric(size.sp), maxLines = 1)
        val gap = a.recommendedTimeGapSeconds
        if (!a.isStopped && gap != null) {
            Text("${CamFmt.compactNumber(gap)} ${CamFmt.seconds} · ${a.condition.localizedName.lowercase()}",
                style = CamTheme.numeric(10.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.7f)), maxLines = 1)
        }
    }
}

@Composable
private fun FullCard(
    a: FollowingDistanceAssessment, policy: FollowingDistancePolicy, source: RoadSurfaceSource, hasLead: Boolean,
    status: DistanceStatus, color: Color, gapText: String, collision: Boolean, mod: Modifier, onShowNorms: () -> Unit,
) {
    val shape = RoundedCornerShape(18.dp)
    val borderAlpha = pulseAlpha(collision, 0.2f, 600)
    Column(
        Modifier.widthIn(max = 340.dp).glass(shape, if (hasLead) color else null)
            .then(if (collision) Modifier.border(2.dp, RV.danger.copy(alpha = borderAlpha), shape) else Modifier)
            .then(mod).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            StatusIcon(status, collision, color, 13)
            Text(if (collision) L("fd.collision") else status.localizedName,
                style = CamTheme.text(13.sp, FontWeight.Bold, if (collision) RV.danger else Color.White), maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            SurfaceChip(a.condition, source)
            InfoButton(onShowNorms)
            Icon(Icons.Filled.ExpandLess, null, tint = Color.White.copy(alpha = 0.5f), modifier = Modifier.size(12.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(gapText, style = CamTheme.numeric(26.sp, FontWeight.ExtraBold, if (hasLead) color else Color.White.copy(alpha = 0.55f)), maxLines = 1)
                val headway = a.timeHeadwaySeconds
                val caption = when {
                    !hasLead -> L("fd.noLeadFound")
                    !a.isStopped && headway != null -> L("fd.headwayCaption", CamFmt.gapSeconds(headway))
                    else -> L("fd.cameraEstimate")
                }
                Text(caption, style = CamTheme.numeric(11.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.72f)), maxLines = 1)
            }
            Spacer(Modifier.width(8.dp))
            NormBlock(a, 16)
        }
        GapProgressBar(if (hasLead) a.fractionOfRecommended else null, color)
        NormRow(Icons.Filled.Speed, L("fd.row.moving"), FollowingDistanceText.movingNorm(a, policy), !a.isStopped,
            if (hasLead && !a.isStopped) color else Color.White)
        NormRow(Icons.Filled.PanTool, L("fd.row.stopped"), FollowingDistanceText.stoppedNorm(policy), a.isStopped,
            if (hasLead && a.isStopped) color else Color.White)
        FollowingDistanceText.stoppingDistance(a)?.let { NormRow(Icons.Filled.Straighten, L("fd.row.stopping"), it, true, Color.White) }
        if (hasLead) FollowingDistanceText.timeToCollision(a)?.let { NormRow(Icons.Filled.Warning, L("fd.row.ttc"), it, true, RV.danger) }
        if (a.ownSpeedKmh == null) Text(L("fd.noGps"), style = CamTheme.text(10.sp, FontWeight.Medium, RV.caution))
        Text(L("fd.disclaimer"), style = CamTheme.text(10.sp, FontWeight.Medium, Color.White.copy(alpha = 0.55f)))
    }
}

@Composable
private fun MiniCard(
    a: FollowingDistanceAssessment, policy: FollowingDistancePolicy, hasLead: Boolean, status: DistanceStatus, color: Color,
    gapText: String, collision: Boolean, mod: Modifier, onShowNorms: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    val borderAlpha = pulseAlpha(collision, 0.2f, 600)
    Column(
        Modifier.width(230.dp).glass(shape, if (hasLead) color else null)
            .then(if (collision) Modifier.border(2.dp, RV.danger.copy(alpha = borderAlpha), shape) else Modifier)
            .then(mod).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusIcon(status, collision, color, 14)
            Column(Modifier.weight(1f)) {
                Text(gapText, style = CamTheme.numeric(20.sp, FontWeight.ExtraBold, if (hasLead) color else Color.White.copy(alpha = 0.55f)), maxLines = 1)
                Text(if (collision) L("fd.collision") else if (hasLead) status.localizedName else L("fd.noLead"),
                    style = CamTheme.text(10.sp, color = if (collision) RV.danger else Color.White.copy(alpha = 0.75f)), maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
            NormBlock(a, 14)
            InfoButton(onShowNorms)
        }
        GapProgressBar(if (hasLead) a.fractionOfRecommended else null, color)
    }
}

/** Distance vs recommended on a 0…1.5× scale with danger / caution / safe zones and a tick at 1.0. */
@Composable
fun GapProgressBar(fraction: Double?, color: Color) {
    BoxWithConstraints(Modifier.fillMaxWidth().height(10.dp)) {
        val w = maxWidth
        val maxFraction = 1.5f
        Row(Modifier.fillMaxWidth().height(5.dp).align(Alignment.CenterStart).background(Color.Transparent, RoundedCornerShape(50))) {
            Box(Modifier.width(w * (0.5f / maxFraction)).height(5.dp).background(RV.danger.copy(alpha = 0.22f), RoundedCornerShape(topStart = 3.dp, bottomStart = 3.dp)))
            Box(Modifier.width(w * (0.5f / maxFraction)).height(5.dp).background(RV.caution.copy(alpha = 0.22f)))
            Box(Modifier.weight(1f).height(5.dp).background(RV.safe.copy(alpha = 0.22f), RoundedCornerShape(topEnd = 3.dp, bottomEnd = 3.dp)))
        }
        if (fraction != null) {
            val filled = (fraction.toFloat().coerceIn(0f, maxFraction) / maxFraction)
            Box(Modifier.width(maxOf(5.dp, w * filled)).height(5.dp).align(Alignment.CenterStart)
                .background(Brush.horizontalGradient(listOf(color.copy(alpha = 0.7f), color)), RoundedCornerShape(50)))
        }
        Box(Modifier.offset(x = w * (1f / maxFraction) - 1.dp).width(2.dp).height(10.dp).background(Color.White, RoundedCornerShape(50)))
    }
}

/** "Dry · auto" chip. */
@Composable
private fun SurfaceChip(condition: RoadSurfaceCondition, source: RoadSurfaceSource) {
    Row(
        Modifier.background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(50)).padding(horizontal = 6.dp, vertical = 3.dp)
            .semantics { contentDescription = L("fd.surface.a11y", condition.localizedName, source.localizedName) },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(condition.icon(), null, tint = Color.White, modifier = Modifier.size(11.dp))
        Text(condition.localizedName, style = CamTheme.text(10.sp), maxLines = 1)
        Text("· " + source.localizedName, style = CamTheme.text(10.sp, color = Color.White.copy(alpha = 0.65f)), maxLines = 1)
    }
}

@Composable
private fun NormRow(icon: ImageVector, title: String, value: String, active: Boolean, tint: Color) {
    Row(Modifier.fillMaxWidth().alpha(if (active) 1f else 0.62f), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(12.dp))
        Text(title, style = CamTheme.text(11.sp, if (active) FontWeight.Bold else FontWeight.Medium), modifier = Modifier.weight(1f), maxLines = 1)
        Text(value, style = CamTheme.numeric(11.sp, color = tint), maxLines = 1)
    }
}
