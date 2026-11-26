package uz.roadvis.app.navigation

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.ReportProblem
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppMode
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.RouteTimelineKind

private class IncidentTarget(val coordinate: GeoPoint?)

/**
 * The navigator: osmdroid map with routes and road events, search, route options, guidance HUD (port of iOS
 * `NavigatorView`). Stays mounted while hidden ([isActive] false): the map keeps its state but the camera is not
 * animated; guidance and road info run in the [NavigationController] regardless.
 */
@Composable
fun NavigatorScreen(app: AppState, isActive: Boolean) {
    val nav = Navigation.controller
    if (nav == null) {
        Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        return
    }
    val context = LocalContext.current
    var following by remember { mutableStateOf(true) }
    var showSearch by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var incidentTarget by remember { mutableStateOf<IncidentTarget?>(null) }
    var longPress by remember { mutableStateOf<GeoPoint?>(null) }
    var tapped by remember { mutableStateOf<MapItem?>(null) }
    val state = nav.state

    LaunchedEffect(state) { if (state == NavigationController.State.PREVIEWING || state == NavigationController.State.NAVIGATING) following = true }
    LaunchedEffect(app.location.isRunning) { if (app.location.isRunning) nav.ensureServicesRunning() }

    val mode = when (state) {
        NavigationController.State.PREVIEWING -> CameraMode.OVERVIEW
        NavigationController.State.NAVIGATING -> CameraMode.NAVIGATING
        else -> CameraMode.IDLE
    }
    val selectedID = nav.selectedRouteOption?.id
    val shownOptions = if (nav.isGuiding) listOfNotNull(nav.selectedRouteOption) else nav.routeOptions
    val routes = shownOptions.map { MapRoute(it.id, it.route.polyline, it.id == selectedID) }
    val items = mapItems(nav, app)
    val fix = app.location.location

    fun startPlanning(place: Place, remember: Boolean) {
        if (remember) nav.placeSearch.addRecent(place)
        showSearch = false
        nav.placeSearch.reset()
        nav.planRoutes(place)
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        NavMap(
            modifier = Modifier.fillMaxSize(),
            isActive = isActive,
            mode = mode,
            following = following,
            routes = routes,
            segments = if (state == NavigationController.State.IDLE) emptyList() else nav.speedLimitSegments,
            items = items,
            user = app.location.coordinate,
            accuracy = if (fix?.hasAccuracy() == true) fix.accuracy else 0f,
            course = app.location.course,
            onUserGesture = { if (following) following = false },
            onSelectRoute = { if (state == NavigationController.State.PREVIEWING) nav.selectRoute(it) },
            onLongPress = { longPress = it },
            onTapItem = { tapped = it },
            onTapEmpty = { tapped = null },
        )

        Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = 10.dp, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // Top: maneuver banner, current road, hazard
            val progress = nav.progress
            if (state == NavigationController.State.NAVIGATING && progress != null) {
                ManeuverBanner(progress, nav.isRecalculating, nav.laneGuidance(progress))
            }
            val hasRoadInfo = nav.roadInfo.currentRoad != null || nav.currentEdge != null
            if (hasRoadInfo) CurrentRoadCard(nav, app, if (state == NavigationController.State.NAVIGATING) progress?.nextManeuver else null)
            if (state == NavigationController.State.NAVIGATING && progress != null) HazardChip(nav, progress)
            // Corner row
            Row(verticalAlignment = Alignment.Top) {
                RoundButton(Icons.Default.CameraAlt, L("common.camera")) { app.switchTo(AppMode.CAMERA) }
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End) {
                    if (!hasRoadInfo) Box(Modifier.glass(RV.Radius.panel).padding(horizontal = 10.dp, vertical = 4.dp)) {
                        Speedometer(app.location.speedKmh, null, app.settings.speedWarningTolerance, false)
                    }
                    if (!following) RoundButton(Icons.Default.MyLocation, L("nav.center"), tint = RV.accent) { following = true }
                    RoundButton(Icons.Default.Layers, L("nav.mapLayer")) { showSettings = true }
                    RoundButton(Icons.Default.ReportProblem, L("nav.report")) { incidentTarget = IncidentTarget(null) }
                    val muted = app.speech.isMuted
                    RoundButton(if (muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                        if (muted) L("voice.unmute") else L("voice.mute"), tint = if (muted) RV.danger else Color.White) {
                        app.speech.isMuted = !muted
                    }
                    RoundButton(Icons.Default.Settings, L("common.settings")) { app.showSettings = true }
                }
            }
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 10.dp, vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            tapped?.let { item -> ItemCallout(item, nav) { tapped = null } }
            nav.errorMessage?.let { ErrorBanner(it) { nav.dismissError() } }
            when (state) {
                NavigationController.State.IDLE -> IdlePanel(nav, app, onSearch = { showSearch = true }) { startPlanning(it, true) }
                NavigationController.State.PLANNING -> PlanningPanel(nav)
                NavigationController.State.PREVIEWING -> RouteOptionsPanel(nav, app) { if (nav.startNavigation()) app.startDrive() }
                NavigationController.State.NAVIGATING -> TripInfoPanel(nav, app) { nav.stopNavigation() }
                NavigationController.State.ARRIVED -> ArrivedPanel(nav)
            }
            Attribution(showWeather = nav.weather.current != null || nav.routeWeather.points.isNotEmpty()) {
                try {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.openstreetmap.org/copyright")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {}
            }
        }
    }

    if (showSearch) SearchSheet(nav, onSelect = { startPlanning(it, true) }) { showSearch = false }
    incidentTarget?.let { t -> IncidentReportSheet(nav, app, t.coordinate) { incidentTarget = null } }
    if (showSettings) NavigatorSettingsSheet(nav, app) { showSettings = false }
    longPress?.let { p ->
        AlertDialog(onDismissRequest = { longPress = null },
            title = { Text(L("nav.mapPoint")) },
            text = {
                Column {
                    TextButton(onClick = { longPress = null; startPlanning(Place(L("nav.mapPoint"), null, p), false) }) { Text(L("nav.routeHere")) }
                    TextButton(onClick = { longPress = null; incidentTarget = IncidentTarget(p) }) { Text(L("nav.reportHere")) }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { longPress = null }) { Text(L("common.cancel")) } })
    }
}

/** Map markers: timeline events of the selected / active route, own marks, nearby signals (no route), destination. */
@Composable
private fun mapItems(nav: NavigationController, app: AppState): List<MapItem> {
    val items = ArrayList<MapItem>()
    val state = nav.state
    if (state != NavigationController.State.IDLE) {
        for (e in nav.timeline) {
            val c = e.coordinate ?: continue
            if (e.kind == RouteTimelineKind.Destination || e.kind is RouteTimelineKind.Incident) continue
            if (e.kind is RouteTimelineKind.SpeedLimit || e.kind is RouteTimelineKind.Lanes) continue
            val important = e.kind.isSpeedCamera || (e.kind as? RouteTimelineKind.Feature)?.kind in
                setOf(RouteFeatureKind.SCHOOL, RouteFeatureKind.KINDERGARTEN, RouteFeatureKind.RAILWAY_CROSSING)
            items += MapItem("e|${e.id}|${e.title}", c, NavStyle.glyph(e.kind), NavStyle.eventColor(e.kind), e.title,
                listOfNotNull(e.detail, e.source).joinToString(" · "), important, small = e.kind is RouteTimelineKind.Maneuver)
        }
    } else if (app.settings.roadDataEnabled) {
        nav.roadInfo.nearbySignals.forEach {
            items += MapItem("s|${it.id}", it.coordinate, "🚦", NavStyle.orange, L("vehicle.trafficLight"), "OSM")
        }
    }
    if (app.settings.ownMarksEnabled) {
        nav.incidents.incidents.forEach { inc ->
            items += MapItem("i|${inc.id}|${inc.date.time}", inc.coordinate, NavStyle.incidentGlyph(inc.kind), NavStyle.incidentColor(inc.kind),
                NavText.incident(inc.kind), L("map.yourMarker", NavText.clock(inc.date.time)), important = true)
        }
    }
    nav.destination?.let { items += MapItem("dest|${it.id}", it.coordinate, "🏁", NavStyle.red, it.name, it.subtitle, important = true) }
    return items
}

@Composable
private fun ItemCallout(item: MapItem, nav: NavigationController, onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().glass(RV.Radius.panel).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(28.dp).clip(CircleShape).background(item.color), contentAlignment = Alignment.Center) { T(item.glyph, 13.sp, FontWeight.Bold, maxLines = 1) }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            T(item.title, 14.sp, FontWeight.SemiBold, maxLines = 2)
            item.subtitle?.takeIf { it.isNotEmpty() }?.let { T(it, 12.sp, color = Secondary, maxLines = 2) }
        }
        if (item.key.startsWith("i|")) {
            val id = item.key.split("|").getOrNull(1)
            TextButton(onClick = { id?.let { runCatching { java.util.UUID.fromString(it) }.getOrNull() }?.let { nav.incidents.remove(it); nav.refreshIncidents() }; onClose() }) {
                Text(L("common.delete"), color = NavStyle.red)
            }
        }
        IconButton(onClick = onClose) { Icon(Icons.Default.Close, L("common.close"), tint = Color.White) }
    }
}

@Composable
private fun IdlePanel(nav: NavigationController, app: AppState, onSearch: () -> Unit, onRecent: (Place) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val recents = nav.placeSearch.recents.take(4)
        if (recents.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                recents.forEach { r ->
                    Row(Modifier.heightIn(min = 44.dp).glass(22.dp).clickable { onRecent(r) }.padding(horizontal = 14.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.History, null, tint = Color.White, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        T(r.name, 13.sp, FontWeight.SemiBold, maxLines = 1)
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.heightIn(min = 44.dp).glass(22.dp).clickable { app.showTripHistory = true }.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.List, null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                T(L("common.trips"), 13.sp, FontWeight.SemiBold, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
            RoundButton(Icons.Default.Info, L("about.title")) { app.showAbout = true }
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).glass(26.dp).clickable(onClick = onSearch).padding(horizontal = 18.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Search, null, tint = Color.White)
            Spacer(Modifier.width(10.dp))
            T(L("nav.whereTo"), 17.sp, FontWeight.SemiBold)
        }
    }
}

@Composable
private fun PlanningPanel(nav: NavigationController) {
    Row(Modifier.fillMaxWidth().glass(26.dp).padding(14.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(Modifier.size(32.dp))
        Column(Modifier.weight(1f)) {
            T(L("nav.planning"), 17.sp, FontWeight.SemiBold)
            nav.destination?.let { T(it.name, 13.sp, color = Secondary, maxLines = 1) }
        }
        OutlinedButton(onClick = { nav.stopNavigation() }, modifier = Modifier.heightIn(min = 52.dp), shape = CircleShape) { Text(L("common.cancel")) }
    }
}

@Composable
private fun ArrivedPanel(nav: NavigationController) {
    Column(Modifier.fillMaxWidth().glass(26.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Default.Flag, null, tint = RV.safe, modifier = Modifier.size(36.dp))
            Column {
                T(L("voice.arrived"), 22.sp, FontWeight.Bold)
                nav.destination?.let { T(it.name, 13.sp, color = Secondary, maxLines = 2) }
            }
        }
        Button(onClick = { nav.stopNavigation() }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            shape = RoundedCornerShape(18.dp), colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1FA35A))) {
            Text(L("common.done"), fontSize = 19.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onClose: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color(0xEB731F14)).padding(start = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.WarningAmber, null, tint = NavStyle.yellow)
        Spacer(Modifier.width(10.dp))
        T(message, 14.sp, maxLines = 5, modifier = Modifier.weight(1f).padding(vertical = 10.dp))
        IconButton(onClick = onClose, modifier = Modifier.size(52.dp)) { Icon(Icons.Default.Close, L("nav.closeMessage"), tint = Color.White) }
    }
}

/** Required tile / data credits (OSM tile usage policy, CARTO terms, Open-Meteo CC BY 4.0). */
@Composable
private fun Attribution(showWeather: Boolean, onOpenCopyright: () -> Unit) {
    Row(Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 8.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        T(MapSetup.ATTRIBUTION, 10.sp, FontWeight.Medium, Color.White.copy(alpha = 0.9f), 1, Modifier.clickable(onClick = onOpenCopyright))
        if (showWeather) T(L("nav.weatherCredit"), 10.sp, FontWeight.Medium, Color.White.copy(alpha = 0.9f), 1)
    }
}
