package uz.roadvis.app.camera

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.vector.ImageVector
import uz.roadvis.core.SoundMode
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.VideocamOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import uz.roadvis.app.app.AppState
import uz.roadvis.app.detection.ModelStatus
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.LaneInfo
import uz.roadvis.core.PedestrianHazard
import uz.roadvis.core.PedestrianHazardLevel
import uz.roadvis.core.PersonRole
import uz.roadvis.core.RoadSegmentInfo
import uz.roadvis.core.RoadStaffSighting
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind
import kotlin.math.roundToInt

// Speedometer

/** True when the GPS speed is above the limit plus the tolerance. */
fun isOverLimit(speedKmh: Double?, limitKmh: Int?, tolerance: Double): Boolean {
    if (speedKmh == null || limitKmh == null || limitKmh <= 0 || !speedKmh.isFinite()) return false
    return speedKmh > limitKmh + maxOf(0.0, tolerance)
}

/** Compact GPS speed read-out with the current speed-limit sign (iOS `SpeedometerView`). Red + pulsing over the limit. */
@Composable
fun SpeedometerView(speedKmh: Double?, limitKmh: Int?, tolerance: Double, warningEnabled: Boolean) {
    val over = warningEnabled && isOverLimit(speedKmh, limitKmh, tolerance)
    val shape = RoundedCornerShape(16.dp)
    val borderAlpha = pulseAlpha(over, 0.45f, 1200)
    val bg by animateColorAsState(if (over) Color.Red.copy(alpha = 0.28f) else Color.Transparent, label = "overBg")
    val a11y = buildString {
        append(if (speedKmh != null && speedKmh.isFinite()) L("speedo.a11y.speed", CamFmt.speed(speedKmh)) else L("speedo.a11y.unknown"))
        if (limitKmh != null && limitKmh > 0) append(", ").append(L("speedo.a11y.limit", limitKmh))
        if (over) append(", ").append(L("speedo.a11y.over"))
    }
    Row(
        Modifier.semantics { contentDescription = a11y }
            .background(CamTheme.glassFill, shape).background(bg, shape)
            .border(if (over) 2.dp else 0.75.dp, if (over) Color.Red.copy(alpha = borderAlpha) else Color.White.copy(alpha = 0.15f), shape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(min = 46.dp)) {
            Text(CamFmt.speed(speedKmh), style = CamTheme.numeric(32.sp, FontWeight.ExtraBold, if (over) Color.Red else Color.White),
                maxLines = 1)
            Text(CamFmt.kmh, style = CamTheme.text(10.sp, FontWeight.SemiBold, if (over) Color.Red.copy(alpha = 0.9f) else Color.White.copy(alpha = 0.75f)))
        }
        if (limitKmh != null && limitKmh > 0) SpeedLimitSign(limitKmh, 36.dp)
    }
}

/** Round speed-limit sign: white disc, red ring, black number. */
@Composable
fun SpeedLimitSign(kmh: Int, size: Dp) {
    val font = when {
        kmh >= 100 -> size.value * 0.36f
        kmh >= 10 -> size.value * 0.44f
        else -> size.value * 0.5f
    }
    Box(
        Modifier.size(size).shadow(3.dp, CircleShape).background(Color.White, CircleShape)
            .border(maxOf(2.5f, size.value * 0.12f).dp, Color(0.86f, 0.08f, 0.1f), CircleShape)
            .semantics { contentDescription = L("speedo.a11y.limitSign", kmh) },
        contentAlignment = Alignment.Center,
    ) {
        Text("$kmh", style = CamTheme.numeric(font.sp, FontWeight.ExtraBold, Color.Black).copy(shadow = null), maxLines = 1)
    }
}

/** Current road (OpenStreetMap, from the navigation feature) in one small line next to the speedometer. */
@Composable
fun RoadLine(road: RoadSegmentInfo?) {
    road ?: return
    val shape = RoundedCornerShape(50)
    Row(
        Modifier.height(26.dp).widthIn(max = 200.dp).background(Color.Black.copy(alpha = 0.35f), shape).padding(horizontal = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        shortLanesText(road.laneInfo)?.let {
            Text(it, style = CamTheme.numeric(12.sp, FontWeight.SemiBold))
            Text("·", style = CamTheme.text(12.sp, color = Color.White.copy(alpha = 0.6f)))
        }
        Text(road.localizedDisplayName, style = CamTheme.text(12.sp), maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false))
        Text("OSM", style = CamTheme.text(7.sp, FontWeight.Black, Color.White.copy(alpha = 0.6f)))
    }
}

/** "3/6" (our direction / total), "≈2" when inferred from the road class; null without data. */
fun shortLanesText(info: LaneInfo): String? {
    val approx = if (info.isEstimated) "≈" else ""
    val dir = info.lanesInDirection
    val total = info.totalLanes
    if (dir != null) {
        if (total != null && !info.isOneway && total != dir) return "$approx$dir/$total"
        return "$approx$dir"
    }
    if (total != null) return "$approx$total"
    return null
}

// Traffic light

/** Small translucent traffic-light housing showing the camera's colour estimate (lampSize 18, housing 0.45). */
@Composable
fun TrafficLightIndicator(color: TrafficLightColor, lampSize: Dp = 18.dp, housingOpacity: Float = 0.45f) {
    val shape = RoundedCornerShape(lampSize * 0.6f)
    val a11y = if (color == TrafficLightColor.UNKNOWN) L("light.a11y.unknown") else L("light.a11y.color", color.localizedName)
    Box(
        Modifier.semantics { contentDescription = a11y }.background(Color.Black.copy(alpha = housingOpacity), shape)
            .border(0.5.dp, Color.White.copy(alpha = 0.18f), shape).padding(lampSize * 0.3f),
        contentAlignment = Alignment.Center,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(lampSize * 0.25f)) {
            for (lamp in listOf(TrafficLightColor.RED, TrafficLightColor.YELLOW, TrafficLightColor.GREEN)) {
                val on = lamp == color
                val base = CamTheme.lightColor(lamp)
                Box(Modifier.size(lampSize).then(if (on) Modifier.shadow(lampSize * 0.35f, CircleShape, ambientColor = base, spotColor = base) else Modifier)
                    .background(if (on) base else base.copy(alpha = 0.18f), CircleShape))
            }
        }
        if (color == TrafficLightColor.UNKNOWN) {
            Text("?", style = CamTheme.text((lampSize.value * 1.1f).sp, FontWeight.ExtraBold, Color.White.copy(alpha = 0.85f)))
        }
    }
}

// Right column buttons

/** Small status dot (green = running, amber = loading / paused, red = no model) — opens the status sheet. */
@Composable
fun StatusDotButton(c: RecognitionController, onClick: () -> Unit) {
    val status = c.detectorStatus
    val dot = when (status) {
        is ModelStatus.Ready -> if (c.isRunning) RV.safe else RV.caution
        ModelStatus.Loading -> RV.caution
        else -> RV.danger
    }
    val text = when (status) {
        is ModelStatus.Ready -> if (!c.isRunning) L("rec.status.cameraOff", status.name)
        else L("recStatus.fps", c.fps.roundToInt()) + " · " + L("recStatus.ms", c.inferenceMs.roundToInt()) + " · " + status.name
        ModelStatus.Loading -> L("rec.status.loading")
        ModelStatus.Missing -> L("rec.status.noModel")
        is ModelStatus.Failed -> L("rec.status.modelError")
    }
    val a = pulseAlpha(status == ModelStatus.Loading, 0.3f, 1200)
    Box(Modifier.size(CamTheme.hit).pressable(onClick).semantics { contentDescription = L("rec.status.a11y", text) },
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(28.dp).background(CamTheme.glassFill, CircleShape).border(0.75.dp, Color.White.copy(alpha = 0.18f), CircleShape),
            contentAlignment = Alignment.Center) {
            Box(Modifier.size(9.dp).alpha(a).shadow(3.dp, CircleShape, ambientColor = dot, spotColor = dot).background(dot, CircleShape))
        }
    }
}

/** Icon of a sound mode (speaker-button and its menu). */
fun soundModeIcon(mode: SoundMode): ImageVector = when (mode) {
    SoundMode.ALL -> Icons.AutoMirrored.Filled.VolumeUp
    SoundMode.SOUNDS_ONLY -> Icons.Filled.Notifications
    SoundMode.VOICE_ONLY -> Icons.Filled.RecordVoiceOver
    SoundMode.SILENT -> Icons.AutoMirrored.Filled.VolumeOff
}

/** Menu with the four sound modes (title, icon per mode, check mark on the current one). */
@Composable
fun SoundModeMenu(app: AppState, expanded: Boolean, onDismiss: () -> Unit) {
    val current = app.settings.soundMode
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        Text(L("sound.mode"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp).alpha(0.7f))
        for (mode in SoundMode.entries) {
            DropdownMenuItem(
                text = { Text(L(mode.titleKey)) },
                leadingIcon = { Icon(soundModeIcon(mode), contentDescription = null) },
                trailingIcon = { if (mode == current) Icon(Icons.Filled.Check, contentDescription = null) },
                onClick = {
                    app.speech.soundMode = mode
                    onDismiss()
                },
            )
        }
    }
}

/**
 * Speaker button: opens the sound-mode menu (all / sounds only / voice only / silent) — same state as
 * Settings → voice prompts + alert sounds.
 */
@Composable
fun VoiceMuteButton(app: AppState) {
    val mode = app.settings.soundMode
    var expanded by remember { mutableStateOf(false) }
    Box {
        GlassIconButton(soundModeIcon(mode), L("sound.mode") + ": " + L(mode.titleKey),
            tint = if (mode == SoundMode.ALL) Color.White else Color(0xFFFF9500)) {
            expanded = true
        }
        SoundModeMenu(app, expanded) { expanded = false }
    }
}

@Composable
fun SettingsButton(app: AppState) {
    GlassIconButton(Icons.Filled.Settings, L("common.settings")) { app.showSettings = true }
}

/** Small capsule with the total of unique vehicles; tap shows / hides the per-kind counters. */
@Composable
fun CountersButton(total: Int, expanded: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Box(Modifier.sizeIn(minWidth = CamTheme.hit, minHeight = CamTheme.hit).pressable(onClick)
        .semantics { contentDescription = L("rec.totalVehicles.a11y", total) }, contentAlignment = Alignment.Center) {
        Row(
            Modifier.sizeIn(minWidth = 28.dp, minHeight = 24.dp).background(CamTheme.glassFill, shape)
                .then(if (expanded) Modifier.background(Color.White.copy(alpha = 0.18f), shape) else Modifier)
                .border(0.75.dp, Color.White.copy(alpha = 0.18f), shape).padding(horizontal = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Icon(Icons.Filled.DirectionsCar, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(10.dp))
            Text("$total", style = CamTheme.numeric(12.sp))
        }
    }
}

/** Unique vehicles counted since the last reset, one compact row (shown on demand), with a reset button. */
@Composable
fun CountersPanel(c: RecognitionController, showPedestrians: Boolean) {
    val kinds = listOf(VehicleKind.CAR, VehicleKind.BUS, VehicleKind.TRUCK, VehicleKind.MOTORCYCLE, VehicleKind.BICYCLE)
    Row(
        Modifier.height(CamTheme.pill).glassCapsule().padding(start = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for (k in kinds) CounterChip(k, c.uniqueCounts[k] ?: 0)
        if (showPedestrians) CounterChip(VehicleKind.PERSON, c.uniqueCounts[VehicleKind.PERSON] ?: 0)
        Text("Σ ${c.totalUniqueVehicles}", style = CamTheme.numeric(12.sp), modifier = Modifier.padding(start = 2.dp))
        Box(Modifier.size(36.dp, 32.dp).pressable { c.resetCounters() }.semantics { contentDescription = L("counters.reset") },
            contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Refresh, null, tint = Color.White, modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun CounterChip(kind: VehicleKind, count: Int) {
    Row(Modifier.sizeIn(minWidth = 32.dp, minHeight = 24.dp).padding(horizontal = 4.dp)
        .semantics { contentDescription = "${kind.localizedName}: $count" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        Icon(CamTheme.kindIcon(kind), null, tint = CamTheme.kindColor(kind), modifier = Modifier.size(11.dp))
        Text("$count", style = CamTheme.numeric(12.sp, color = if (count > 0) Color.White else Color.White.copy(alpha = 0.5f)))
    }
}

/** Round accent button in the bottom-right corner that switches to the navigator (48 dp, translucent). */
@Composable
fun NavigatorCornerButton(onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).pressable(onClick).shadow(5.dp, CircleShape)
            .background(Brush.verticalGradient(listOf(RV.accent.copy(alpha = 0.95f), RV.accent.copy(alpha = 0.75f))), CircleShape)
            .border(1.dp, Color.White.copy(alpha = 0.3f), CircleShape)
            .semantics { contentDescription = L("common.navigator") },
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Map, null, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

// Banners

/** Compact capsule: red "Yield to the pedestrian!" (danger) or orange "Caution, pedestrian" (caution) + ≈ distance. */
@Composable
fun PedestrianHazardBanner(hazard: PedestrianHazard) {
    val danger = hazard.level == PedestrianHazardLevel.DANGER
    val color = CamTheme.pedestrianColor(hazard.level)
    val title = L(if (danger) "ped.banner.danger" else "ped.banner.caution")
    val a = pulseAlpha(danger, 0.75f, 900)
    WarningCapsule(Icons.Filled.DirectionsWalk, title, hazard.distanceMeters, color.copy(alpha = if (danger) 0.92f else 0.88f), Modifier.alpha(a))
}

/** Blue (traffic police officer) or orange (road workers) capsule; the role is a colour heuristic, hence "≈". */
@Composable
fun RoadStaffBanner(sighting: RoadStaffSighting) {
    val color = CamTheme.roleColor(sighting.role) ?: RV.pedestrianCaution
    val title = L(if (sighting.role == PersonRole.TRAFFIC_OFFICER) "staff.banner.officer" else "staff.banner.workers")
    WarningCapsule(CamTheme.roleIcon(sighting.role), "≈ $title", sighting.distanceMeters, color.copy(alpha = 0.9f), Modifier)
}

@Composable
private fun WarningCapsule(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, distance: Double?, fill: Color, modifier: Modifier) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier.shadow(8.dp, shape, ambientColor = fill, spotColor = fill).background(fill, shape)
            .border(1.dp, Color.White.copy(alpha = 0.45f), shape).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Icon(icon, null, tint = Color.White, modifier = Modifier.size(17.dp))
        Text(title, style = CamTheme.text(15.sp, FontWeight.Black, shadow = false), maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false))
        if (distance != null && distance.isFinite() && distance > 0) {
            Text("≈ " + CamFmt.gapMeters(distance), style = CamTheme.numeric(13.sp).copy(shadow = null), maxLines = 1,
                modifier = Modifier.background(Color.Black.copy(alpha = 0.22f), shape).padding(horizontal = 6.dp, vertical = 1.5.dp))
        }
    }
}

/** Compact banner with an icon, a title, an optional message and an optional close button. */
@Composable
fun InfoBanner(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, message: String?, onClose: (() -> Unit)?) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier.glass(shape, tint.copy(alpha = 0.7f)).padding(start = 10.dp, end = if (onClose == null) 10.dp else 0.dp, top = 7.dp, bottom = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp).padding(top = 1.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = CamTheme.text(13.sp, FontWeight.Bold), maxLines = 2)
            if (message != null) Text(message, style = CamTheme.text(11.sp, FontWeight.Normal, Color.White.copy(alpha = 0.8f)), maxLines = 3)
        }
        if (onClose != null) {
            Box(Modifier.size(36.dp).pressable(onClose).semantics { contentDescription = L("common.hide") }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, null, tint = Color.White, modifier = Modifier.size(12.dp))
            }
        }
    }
}

/** Model / camera problems. Model banners hide themselves after 8 s; camera banners stay while the problem lasts. */
@Composable
fun BannerStack(c: RecognitionController, hideModelBanner: Boolean, onHide: () -> Unit) {
    val problem = c.detectorStatus is ModelStatus.Missing || c.detectorStatus is ModelStatus.Failed
    LaunchedEffect(problem, hideModelBanner) {
        if (problem && !hideModelBanner) { delay(8000); onHide() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.widthIn(max = 420.dp)) {
        if (!hideModelBanner) {
            when (val s = c.detectorStatus) {
                ModelStatus.Missing -> InfoBanner(Icons.Filled.Warning, Color(0xFFFF9500), L("rec.banner.noModel.title"), L("rec.banner.noModel.message"), onHide)
                is ModelStatus.Failed -> InfoBanner(Icons.Filled.Warning, Color.Red, L("rec.banner.modelFailed"), s.message, onHide)
                else -> {}
            }
        }
        c.cameraError?.let { InfoBanner(Icons.Filled.VideocamOff, Color.Red, L("rec.banner.cameraUnavailable"), it, null) }
    }
}

/** Shown instead of the camera picture when camera access is denied. */
@Composable
fun CameraPermissionCard(onOpenSettings: () -> Unit) {
    val shape = RoundedCornerShape(24.dp)
    Column(
        Modifier.widthIn(max = 420.dp).padding(32.dp).glass(shape).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Icons.Filled.VideocamOff, null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(44.dp))
        Text(L("camera.noAccess"), style = CamTheme.text(22.sp, FontWeight.Bold, shadow = false))
        Text(L("rec.allowCamera"), style = CamTheme.text(16.sp, FontWeight.Normal, Color.White.copy(alpha = 0.8f), shadow = false), textAlign = TextAlign.Center)
        Row(
            Modifier.sizeIn(minHeight = 52.dp).background(RV.accent, RoundedCornerShape(14.dp)).pressable(onOpenSettings).padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.Settings, null, tint = Color.White, modifier = Modifier.size(18.dp))
            Text(L("rec.openSettings"), style = CamTheme.text(17.sp, FontWeight.Bold, shadow = false))
        }
    }
}
