package uz.roadvis.app.camera

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppState
import uz.roadvis.app.detection.ModelStatus
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.FollowingDistanceCalculator
import uz.roadvis.core.FollowingDistanceNorms
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.RoadSurfaceCondition
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind
import kotlin.math.max
import kotlin.math.roundToInt

private val sheetBg = Color(0xFF15181D)
private val secondary = Color.White.copy(alpha = 0.6f)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CameraSheet(title: String, onDismiss: () -> Unit, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = state, containerColor = sheetBg) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = CamTheme.text(17.sp, FontWeight.Bold, shadow = false), modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text(L("common.done"), color = RV.accent, fontWeight = FontWeight.SemiBold) }
        }
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp)) {
            content()
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text.uppercase(), style = CamTheme.text(12.sp, FontWeight.SemiBold, secondary, shadow = false),
        modifier = Modifier.padding(top = 18.dp, bottom = 6.dp))
}

@Composable
private fun Footer(text: String) {
    Text(text, style = CamTheme.text(12.sp, FontWeight.Normal, secondary, shadow = false), modifier = Modifier.padding(top = 4.dp))
}

@Composable
private fun LabeledRow(label: String, value: String, icon: ImageVector? = null, bold: Boolean = false) {
    Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (icon != null) Icon(icon, null, tint = RV.accent, modifier = Modifier.size(18.dp))
        Text(label, style = CamTheme.text(15.sp, FontWeight.Normal, shadow = false), modifier = Modifier.weight(1f))
        Text(value, style = CamTheme.numeric(15.sp, if (bold) FontWeight.Bold else FontWeight.Normal, Color.White.copy(alpha = 0.85f)).copy(shadow = null))
    }
}

/** Surface badge "Now", norm status badges (iOS `RVBadge`). */
@Composable
private fun Badge(text: String, color: Color) {
    Text(text, style = CamTheme.text(11.sp, FontWeight.Bold, color, shadow = false),
        modifier = Modifier.background(color.copy(alpha = 0.18f), RoundedCornerShape(50))
            .border(1.dp, color.copy(alpha = 0.45f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
}

fun normColor(s: FollowingDistanceNorms.Status): Color = when (s) {
    FollowingDistanceNorms.Status.NORM -> RV.accent
    FollowingDistanceNorms.Status.RECOMMENDATION -> RV.safe
    FollowingDistanceNorms.Status.APP_SETTING -> RV.appSettingNorm
}

/**
 * «Distance requirements» (port of iOS `DistanceNormsView`): the thresholds the app uses now, the time gap per surface,
 * an example table, what the Uzbek traffic rules say (norms) and recommendations with sources.
 */
@Composable
fun DistanceNormsSheet(c: RecognitionController, onDismiss: () -> Unit) {
    val policy = c.followingDistancePolicy
    val surface = c.roadSurface
    val source = c.roadSurfaceSource
    val context = LocalContext.current
    CameraSheet(L("fd.norms.title"), onDismiss) {
        item {
            SectionHeader(L("norms.current.header"))
            LabeledRow(L("settings.fd.surface"), "${surface.localizedName} · ${source.localizedName}", surface.icon())
            LabeledRow(L("norms.moving"), "≥ ${CamFmt.compactNumber(policy.timeGap(surface))} ${CamFmt.seconds}", Icons.Filled.Speed)
            LabeledRow(L("norms.stopped"), "≥ ${CamFmt.compactNumber(policy.stoppedGapMeters)} ${CamFmt.meters}", Icons.Filled.PanTool)
            LabeledRow(L("settings.fd.reaction"), "${CamFmt.compactNumber(policy.reactionTimeSeconds)} ${CamFmt.seconds}", Icons.Filled.Bolt)
            LabeledRow(L("norms.warning"), L("norms.ttcThreshold", CamFmt.compactNumber(policy.collisionWarningSeconds)), Icons.Filled.Warning)
            LabeledRow(L("norms.standingIf"), "< ${CamFmt.compactNumber(policy.stoppedSpeedKmh)} ${CamFmt.kmh}", Icons.Filled.DirectionsCar)
            Footer(L("norms.current.footer"))
        }
        item {
            SectionHeader(L("norms.gap.header"))
            for (condition in RoadSurfaceCondition.entries) {
                Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(condition.icon(), null, tint = RV.accent, modifier = Modifier.size(18.dp))
                    Text(condition.localizedName, style = CamTheme.text(15.sp, FontWeight.Normal, shadow = false))
                    if (condition == surface) Badge(L("norms.now"), RV.safe)
                    Spacer(Modifier.weight(1f))
                    Text("≥ ${CamFmt.compactNumber(policy.timeGap(condition))} ${CamFmt.seconds}",
                        style = CamTheme.numeric(15.sp, if (condition == surface) FontWeight.Bold else FontWeight.Normal).copy(shadow = null))
                }
            }
            Footer(L("norms.gap.footer"))
        }
        item {
            SectionHeader(L("norms.example", surface.localizedName.lowercase()))
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                for (h in listOf(L("norms.col.speed"), L("norms.col.gap"), L("fd.row.stopping"))) {
                    Text(h, style = CamTheme.text(12.sp, FontWeight.SemiBold, secondary, shadow = false), modifier = Modifier.weight(1f))
                }
            }
            for (speed in listOf(20.0, 40.0, 60.0, 90.0, 110.0)) {
                val gap = FollowingDistanceCalculator.recommendedDistance(speed, policy, surface)
                val stopping = FollowingDistanceCalculator.stoppingDistance(speed, policy.reactionTimeSeconds, surface.frictionCoefficient)
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    for (v in listOf("${speed.toInt()} ${CamFmt.kmh}", "≈ " + CamFmt.gapMeters(gap), "≈ " + CamFmt.gapMeters(stopping))) {
                        Text(v, style = CamTheme.numeric(14.sp, FontWeight.Medium).copy(shadow = null), modifier = Modifier.weight(1f))
                    }
                }
            }
            Footer(L("norms.example.footer"))
        }
        item {
            SectionHeader(L("norms.document"))
            Text(L("norms.rulesDocument"), style = CamTheme.text(14.sp, FontWeight.Normal, shadow = false))
            SectionHeader(L("norms.items.header"))
        }
        items(FollowingDistanceNorms.items.size) { i ->
            val item = FollowingDistanceNorms.items[i]
            Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Badge(item.status.localizedName, normColor(item.status))
                Text(item.localizedTitle, style = CamTheme.text(16.sp, FontWeight.Bold, shadow = false))
                Text(item.localizedText, style = CamTheme.text(14.sp, FontWeight.Normal, shadow = false))
                Text(L("norms.source", item.localizedSource), style = CamTheme.text(12.sp, FontWeight.Medium, secondary, shadow = false))
                item.url?.let { url ->
                    Row(Modifier.pressable {
                        try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
                    }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.OpenInNew, null, tint = RV.accent, modifier = Modifier.size(16.dp))
                        Text(L("norms.openSource"), style = CamTheme.text(14.sp, FontWeight.SemiBold, RV.accent, shadow = false))
                    }
                }
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
        }
        item {
            Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Warning, null, tint = RV.caution, modifier = Modifier.size(18.dp))
                Text(L("norms.disclaimer"), style = CamTheme.text(13.sp, FontWeight.Normal, secondary, shadow = false))
            }
        }
    }
}

/** Details of the recognition pipeline (port of iOS `RecognitionStatusView`). */
@Composable
fun RecognitionStatusSheet(app: AppState, c: RecognitionController, onDismiss: () -> Unit) {
    val kinds = listOf(VehicleKind.CAR, VehicleKind.BUS, VehicleKind.TRUCK, VehicleKind.MOTORCYCLE, VehicleKind.BICYCLE,
        VehicleKind.PERSON, VehicleKind.TRAFFIC_LIGHT, VehicleKind.STOP_SIGN)
    CameraSheet(L("recStatus.title"), onDismiss) {
        item {
            SectionHeader(L("recStatus.models"))
            when (val s = c.detectorStatus) {
                is ModelStatus.Ready -> LabeledRow(L("recStatus.detector"), s.name)
                ModelStatus.Loading -> LabeledRow(L("recStatus.detector.loading"), "…")
                ModelStatus.Missing -> Text(L("recStatus.detector.missing"), style = CamTheme.text(15.sp, color = Color(0xFFFF9500), shadow = false))
                is ModelStatus.Failed -> Text(L("recStatus.detector.failed", s.message), style = CamTheme.text(15.sp, color = Color.Red, shadow = false))
            }
            if (!app.settings.makeRecognitionEnabled) {
                Text(L("recStatus.make.off"), style = CamTheme.text(15.sp, color = secondary, shadow = false), modifier = Modifier.padding(vertical = 7.dp))
            } else when (val s = c.makeClassifierStatus) {
                is ModelStatus.Ready -> LabeledRow(L("recStatus.make"), s.name)
                ModelStatus.Loading -> LabeledRow(L("recStatus.make.loading"), "…")
                ModelStatus.Missing -> Text(L("recStatus.make.missing"), style = CamTheme.text(15.sp, color = secondary, shadow = false), modifier = Modifier.padding(vertical = 7.dp))
                is ModelStatus.Failed -> Text(L("recStatus.make.failed", s.message), style = CamTheme.text(15.sp, color = Color.Red, shadow = false))
            }
        }
        item {
            SectionHeader(L("recStatus.performance"))
            LabeledRow(L("recStatus.processing"), if (c.isRunning) L("recStatus.fps", c.fps.roundToInt()) else "—")
            LabeledRow(L("recStatus.inference"), if (c.isRunning) L("recStatus.ms", c.inferenceMs.roundToInt()) else "—")
            LabeledRow(L("recStatus.frame"), "${c.frameWidth} × ${c.frameHeight}")
            LabeledRow(L("recStatus.fov"), "${c.horizontalFov.roundToInt()}°")
            LabeledRow(L("recStatus.frames"), "${c.processedFrames}")
        }
        item {
            SectionHeader(L("common.camera"))
            val state = when {
                c.cameraPermissionDenied -> L("camera.noAccess")
                c.cameraError != null -> L("common.errorWith", c.cameraError)
                else -> if (c.isRunning) L("camera.running") else L("camera.stopped")
            }
            Text(state, style = CamTheme.text(15.sp, FontWeight.Normal, shadow = false), modifier = Modifier.padding(vertical = 7.dp))
        }
        item {
            SectionHeader(L("recStatus.uniqueHeader"))
            for (k in kinds) LabeledRow(k.localizedName, "${c.uniqueCounts[k] ?: 0}", CamTheme.kindIcon(k))
            LabeledRow(L("recStatus.totalVehicles"), "${c.totalUniqueVehicles}", bold = true)
            Row(Modifier.padding(vertical = 8.dp).pressable { c.resetCounters() }, verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(L("counters.reset"), style = CamTheme.text(15.sp, FontWeight.Normal, Color.Red, shadow = false))
            }
            Footer(L("recStatus.uniqueFooter", c.totalVisibleVehicles))
        }
        item {
            SectionHeader(L("recStatus.howToRead"))
            for (k in listOf("recStatus.read.confidence", "recStatus.read.distance", "recStatus.read.lead", "recStatus.read.light", "recStatus.read.osm")) {
                Text(L(k), style = CamTheme.text(14.sp, FontWeight.Normal, secondary, shadow = false), modifier = Modifier.padding(vertical = 4.dp))
            }
        }
    }
}

/**
 * Compact card shown when a box is tapped (port of iOS `TrackDetailCard`): class, make + confidence, ≈ distance,
 * ≈ speed, relative motion, TTC for the lead, track age. Estimates carry "≈ … (estimate)".
 */
@Composable
fun TrackDetailCard(track: TrackedObject, lead: LeadVehicle?, assessment: FollowingDistanceAssessment?, onClose: () -> Unit, modifier: Modifier) {
    val role = track.roadStaffRole
    val kindColor = CamTheme.roleColor(role) ?: CamTheme.kindColor(track.kind)
    val leadColor = CamTheme.statusColor(assessment?.status ?: uz.roadvis.core.DistanceStatus.UNKNOWN)
    val shape = RoundedCornerShape(18.dp)
    Column(
        modifier.width(TRACK_CARD_WIDTH.dp).glass(shape, if (lead != null) leadColor else kindColor.copy(alpha = 0.6f), fillAlpha = 0.92f)
            .padding(11.dp).semantics { contentDescription = L("track.details") },
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(30.dp).background(kindColor.copy(alpha = 0.18f), CircleShape), contentAlignment = Alignment.Center) {
                if (track.kind == VehicleKind.TRAFFIC_LIGHT) TrafficLightDot(track.lightColor ?: TrafficLightColor.UNKNOWN, 14.dp)
                else Icon(role?.let { CamTheme.roleIcon(it) } ?: CamTheme.kindIcon(track.kind), null, tint = kindColor, modifier = Modifier.size(15.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(role?.approximateName ?: track.kind.localizedName, style = CamTheme.text(15.sp, FontWeight.Bold))
                val make = track.make; val mc = track.makeConfidence
                when {
                    role != null -> Text(L("role.heuristic"), style = CamTheme.text(11.sp, FontWeight.Medium, secondary))
                    make != null && mc != null -> Text("$make · " + L("track.makeConfidence", (mc.coerceIn(0.0, 1.0) * 100).roundToInt()),
                        style = CamTheme.numeric(11.sp, FontWeight.SemiBold, Color.White.copy(alpha = 0.8f)), maxLines = 2)
                    track.kind.isVehicle && track.kind != VehicleKind.BICYCLE -> Text(L("track.noMake"), style = CamTheme.text(11.sp, FontWeight.Medium, secondary))
                }
            }
            Box(Modifier.size(32.dp).pressable(onClose).semantics { contentDescription = L("common.close") }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(26.dp).background(Color.White.copy(alpha = 0.14f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, null, tint = Color.White, modifier = Modifier.size(12.dp))
                }
            }
        }
        if (lead != null) Badge(L("track.lead"), leadColor)
        Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.14f)))
        if (track.kind == VehicleKind.TRAFFIC_LIGHT) {
            val color = track.lightColor ?: TrafficLightColor.UNKNOWN
            CardRow(L("track.color"), color.localizedName + " (" + L("common.estimate") + ")")
        }
        CardRow(L("track.confidence"), "${TrackText.confidencePercent(track)}%")
        val meters = lead?.distanceMeters ?: track.distanceMeters
        if (meters != null && meters.isFinite() && meters > 0) {
            CardRow(L("routes.row.distance"), FollowingDistanceText.gap(meters) + " (" + L("common.estimate") + ")", if (lead != null) leadColor else Color.White)
        }
        if (lead != null) CardRow(L("track.cues"), FollowingDistanceCalculator.methodDisplay(lead.method, appLang))
        val speed = track.estimatedSpeedKmh
        if (speed != null && speed.isFinite() && speed >= 0) CardRow(L("chart.speed"), L("routes.kmhEstimate", speed.roundToInt()))
        FollowingDistanceText.relativeMotion(lead?.relativeSpeedKmh ?: track.relativeSpeedKmh)?.let { CardRow(L("track.relative"), "≈ $it") }
        if (assessment != null && lead != null) FollowingDistanceText.timeToCollision(assessment)?.let { CardRow(L("fd.row.ttc"), it, RV.danger) }
        val age = max(0.0, track.lastSeen - track.firstSeen)
        CardRow(L("track.inFrame"), if (age < 60) CamFmt.gapSeconds(age) else CamFmt.duration(age))
    }
}

const val TRACK_CARD_WIDTH = 236
const val TRACK_CARD_HEIGHT = 180

@Composable
private fun CardRow(title: String, value: String, color: Color = Color.White) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = CamTheme.text(11.sp, FontWeight.Medium, Color.White.copy(alpha = 0.65f)), modifier = Modifier.weight(0.45f))
        Text(value, style = CamTheme.numeric(12.sp, FontWeight.SemiBold, color), maxLines = 1, modifier = Modifier.weight(0.55f))
    }
}
