package uz.roadvis.app.navigation

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.ExternalNavigation
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.ManeuverClassifier
import uz.roadvis.core.RouteProgress
import uz.roadvis.core.SignalWaitModel
import kotlin.math.max

/** Opens the Waze universal link: the Waze app when installed, otherwise the browser. */
fun openWaze(context: Context, destination: GeoPoint) {
    val url = ExternalNavigation.wazeURL(destination) ?: return
    val uri = Uri.parse(url)
    val waze = Intent(Intent.ACTION_VIEW, uri).setPackage("com.waze").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        context.startActivity(waze)
    } catch (_: ActivityNotFoundException) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, NavText.x("navx.wazeMissing"), Toast.LENGTH_SHORT).show()
        }
    }
}

@Composable
fun WazeButton(nav: NavigationController, app: AppState, prominent: Boolean) {
    val dest = nav.destination ?: return
    if (!app.settings.showWazeButton) return
    val context = LocalContext.current
    OutlinedButton(onClick = { openWaze(context, dest.coordinate) },
        modifier = (if (prominent) Modifier.fillMaxWidth() else Modifier).heightIn(min = 44.dp),
        shape = RoundedCornerShape(RV.Radius.control),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = NavStyle.cyan)) {
        Icon(Icons.AutoMirrored.Filled.OpenInNew, null, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(L("waze.open"), fontSize = if (prominent) 14.sp else 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Next maneuver with distance, «then …», lanes and the approach bar (iOS `ManeuverBannerView`). */
@Composable
fun ManeuverBanner(progress: RouteProgress, isRerouting: Boolean, lanes: NavigationController.LaneDisplay) {
    val offRoute = progress.isOffRoute
    val bg = if (isRerouting || offRoute) NavStyle.rerouteOrange else NavStyle.maneuverGreen
    val instruction = progress.nextInstruction?.trim()?.ifEmpty { null } ?: L("banner.followRoute")
    val distance = progress.distanceToNextManeuver
    val a11y = when {
        isRerouting -> L("voice.rerouting")
        offRoute -> L("banner.offRoute")
        else -> listOfNotNull(distance?.let { NavText.spokenDistance(it) }, instruction,
            progress.followingInstruction?.takeIf { it.isNotEmpty() }?.let { L("banner.thenWith", it) }).joinToString(", ")
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(RV.Radius.panel)).background(bg.copy(alpha = 0.94f))
        .padding(horizontal = 10.dp, vertical = 8.dp).semantics { contentDescription = a11y },
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(46.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                if (isRerouting) CircularProgressIndicator(Modifier.size(26.dp), color = Color.White, strokeWidth = 3.dp)
                else Icon(if (offRoute) NavStyle.icon("arrow.triangle.branch") else NavStyle.maneuverIcon(progress.nextManeuver),
                    null, tint = Color.White, modifier = Modifier.size(30.dp))
            }
            Column(Modifier.weight(1f)) {
                when {
                    isRerouting -> { T(L("banner.rerouting"), 17.sp, FontWeight.Bold); T(L("banner.reroutingDetail"), 12.sp, color = Color.White.copy(alpha = 0.8f)) }
                    offRoute -> { T(L("banner.offRoute"), 17.sp, FontWeight.Bold); T(L("banner.offRouteDetail"), 12.sp, color = Color.White.copy(alpha = 0.8f)) }
                    else -> {
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (distance != null) T(NavText.distance(distance), 22.sp, FontWeight.Black, maxLines = 1)
                            T(instruction, 14.sp, FontWeight.SemiBold, maxLines = 2)
                        }
                        progress.followingInstruction?.takeIf { it.isNotEmpty() }?.let { following ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                T(L("banner.then"), 12.sp, color = Color.White.copy(alpha = 0.78f))
                                Icon(NavStyle.maneuverIcon(ManeuverClassifier.classify(following)), null,
                                    tint = Color.White.copy(alpha = 0.78f), modifier = Modifier.size(12.dp))
                                T(following, 12.sp, color = Color.White.copy(alpha = 0.78f), maxLines = 1)
                            }
                        }
                    }
                }
            }
        }
        val showsLanes = !isRerouting && !offRoute && lanes.lanes.isNotEmpty() && (distance ?: Double.POSITIVE_INFINITY) <= 1_500
        if (showsLanes) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                LaneGuidance(lanes.lanes, lanes.recommended)
                lanes.source?.let { SourceTag(it) }
            }
        }
        if (!isRerouting && !offRoute && distance != null && distance <= 300) {
            LinearProgressIndicator(progress = { (1 - distance / 300).toFloat().coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().clip(CircleShape), color = Color.White.copy(alpha = 0.85f),
                trackColor = Color.White.copy(alpha = 0.18f), drawStopIndicator = {})
        }
    }
}

/** Current road (OSM / Valhalla), lanes, limit and speedometer, expandable (iOS `CurrentRoadCard`). */
@Composable
fun CurrentRoadCard(nav: NavigationController, app: AppState, nextManeuver: uz.roadvis.core.ManeuverType?) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val road = nav.roadInfo.currentRoad
    val edge = nav.currentEdge
    val name = road?.let { NavText.roadName(it) } ?: edge?.names?.firstOrNull { it.isNotEmpty() } ?: L("highway.road")
    val roadClass = road?.let { NavText.highway(it.highway) } ?: NavText.valhallaRoadClass(edge?.roadClass)
    val laneText: String? = run {
        val osm = road?.laneInfo
        val osmCount = osm?.lanesInDirection
        val osmEstimated = osm?.isEstimated ?: true
        var count: Int? = null
        var estimated = false
        val valhalla = edge?.laneCount
        if (valhalla != null && (valhalla > 1 || osmCount == null || osmEstimated)) { count = valhalla; estimated = valhalla == 1 }
        else if (osmCount != null) { count = osmCount; estimated = osmEstimated }
        count?.let { c ->
            var t = (if (estimated) "≈" else "") + c
            osm?.totalLanes?.let { total -> if (total > c) t += " / $total" }
            t
        }
    }
    Column(Modifier.fillMaxWidth().glass(RV.Radius.panel).padding(start = 12.dp, end = 6.dp, top = 4.dp, bottom = 4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).clickable { expanded = !expanded }.padding(vertical = 4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    T(name, 15.sp, FontWeight.Bold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    val ref = road?.ref
                    if (ref != null && ref != road.name) {
                        Box(Modifier.clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.2f)).padding(horizontal = 4.dp)) {
                            T(ref, 10.sp, FontWeight.Black, maxLines = 1)
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    roadClass?.let { T(it, 11.sp, FontWeight.Medium, Color.White.copy(alpha = 0.75f), 1) }
                    laneText?.let {
                        Icon(NavStyle.icon("road.lanes"), null, tint = Color.White, modifier = Modifier.size(12.dp))
                        T(it, 11.sp, FontWeight.SemiBold, maxLines = 1)
                    }
                    Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        if (expanded) L("road.collapse") else L("road.expand"), tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(14.dp))
                }
            }
            Speedometer(app.location.speedKmh, edge?.speedLimitKmh ?: road?.speedLimit?.kmh,
                app.settings.speedWarningTolerance, app.settings.speedWarningEnabled)
        }
        AnimatedVisibility(expanded) {
            Column(Modifier.padding(end = 8.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (road != null && road.laneInfo.lanes.isNotEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        val lanes = road.laneInfo.lanes
                        LaneGuidance(lanes, uz.roadvis.core.LaneGuidance.recommendedLanes(lanes, nextManeuver ?: uz.roadvis.core.ManeuverType.STRAIGHT))
                        SourceTag("OSM turn:lanes")
                    }
                }
                roadFacts(road, edge).forEach { (symbol, text, source) ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        Icon(NavStyle.icon(symbol), null, tint = Color.White, modifier = Modifier.size(12.dp))
                        T(text, 11.sp, FontWeight.Medium, maxLines = 1)
                        SourceTag(source)
                    }
                }
            }
        }
    }
}

private fun roadFacts(road: uz.roadvis.core.RoadSegmentInfo?, edge: uz.roadvis.core.RouteEdgeAttributes?): List<Triple<String, String, String>> {
    val r = ArrayList<Triple<String, String, String>>()
    road?.speedLimit?.let { r += Triple("speedometer", if (it.isImplicit) L("road.limit.implicit", it.kmh) else L("road.limit", it.kmh), "OSM") }
    edge?.speedLimitKmh?.let { if (it != road?.speedLimit?.kmh) r += Triple("speedometer", L("road.limit", it), "Valhalla") }
    road?.laneInfo?.let { info ->
        val parts = ArrayList<String>()
        info.lanesInDirection?.let { parts += L("road.lanes.mine", (if (info.isEstimated) "≈" else "") + it) }
        info.lanesOpposite?.let { if (it > 0) parts += L("road.lanes.opposite", it) }
        info.totalLanes?.let { parts += L("road.lanes.total", it) }
        if (parts.isNotEmpty()) r += Triple("road.lanes", L("road.lanes", parts.joinToString(", ")), if (info.isEstimated) L("road.estimatedByClass") else "OSM")
        r += Triple("arrow.up", if (info.isOneway) L("road.oneway") else L("road.twoway"), "OSM")
    }
    edge?.laneCount?.let { if (it > 1) r += Triple("road.lanes", L("road.lanesForward", it), "Valhalla") }
    val osmSurface = NavText.osmSurface(road?.surface)
    if (osmSurface != null) r += Triple("road.lanes", osmSurface, "OSM")
    else NavText.valhallaSurface(edge?.surface)?.let { r += Triple("road.lanes", it, "Valhalla") }
    road?.lit?.let { r += Triple("sun.max.fill", if (it) L("road.lit") else L("road.unlit"), "OSM") }
    edge?.typicalSpeedKmh?.let { if (it > 0) r += Triple("speedometer", L("road.typicalSpeed", Math.round(it).toInt()), "Valhalla") }
    if (edge?.isTunnel == true) r += Triple("road.lanes", L("road.tunnel"), "Valhalla")
    if (edge?.isBridge == true) r += Triple("road.lanes", L("road.bridge"), "Valhalla")
    if (edge?.isToll == true) r += Triple("road.lanes", L("road.toll"), "Valhalla")
    if (r.isEmpty()) r += Triple("questionmark", L("road.noOSM"), "OSM")
    return r
}

/** Hazard chip for the nearest relevant OSM feature ahead within its alert distance. */
@Composable
fun HazardChip(nav: NavigationController, progress: RouteProgress) {
    val hazard = nav.upcomingFeatures.firstOrNull {
        val ahead = it.distanceAlongRoute - progress.distanceAlong
        it.kind != uz.roadvis.core.RouteFeatureKind.TRAFFIC_SIGNALS && !it.kind.isPointOfInterest && ahead >= 0 && ahead <= it.kind.alertDistance
    } ?: return
    Row(Modifier.clip(CircleShape).background(NavStyle.featureColor(hazard.kind).copy(alpha = 0.9f)).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(NavStyle.icon(hazard.kind.symbolName), null, tint = Color.White, modifier = Modifier.size(14.dp))
        T(NavText.feature(hazard.kind), 13.sp, FontWeight.Bold, maxLines = 1)
        T(NavText.distance(max(0.0, hazard.distanceAlongRoute - progress.distanceAlong)), 13.sp, FontWeight.Bold, maxLines = 1)
    }
}

/** Bottom panel while navigating: ETA, strip, chips; expandable details (iOS `TripInfoPanel`). */
@Composable
fun TripInfoPanel(nav: NavigationController, app: AppState, onStop: () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    var wholeRoute by rememberSaveable { mutableStateOf(false) }
    val progress = nav.progress
    val along = nav.distanceAlong
    val summary = signalSummary(nav, app, along)
    Column(Modifier.fillMaxWidth().glass().padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.weight(1f).heightIn(min = 44.dp).clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (progress != null) {
                    T(NavText.clock(System.currentTimeMillis() + (progress.remainingTimeSeconds * 1000).toLong()), 20.sp, FontWeight.Bold, maxLines = 1)
                    T(NavText.duration(progress.remainingTimeSeconds), 14.sp, FontWeight.SemiBold, maxLines = 1)
                    T(NavText.distance(progress.remainingDistance), 14.sp, color = Secondary, maxLines = 1)
                } else {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    T(L("nav.waitingGPS"), 14.sp, FontWeight.SemiBold, maxLines = 1)
                }
                Spacer(Modifier.weight(1f))
                Icon(if (expanded) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                    if (expanded) L("nav.collapseDetails") else L("common.showDetails"), tint = Secondary, modifier = Modifier.size(18.dp))
            }
            Button(onClick = onStop, colors = ButtonDefaults.buttonColors(containerColor = RV.danger), shape = CircleShape) {
                Text(L("nav.end"), fontWeight = FontWeight.SemiBold)
            }
        }
        if (progress != null) {
            RouteStrip(nav.routeLength, along, nav.speedLimitSegments, nav.timeline)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (summary.first > 0) Chip(NavStyle.icon("light.beacon.max"), NavStyle.orange,
                    "${summary.first} · ≈ ${NavText.duration(summary.second)}", L("nav.signals.a11y", summary.first, NavText.duration(summary.second)))
                val level = nav.congestion
                if (level != null) Chip(Icons.Default.DirectionsCar, NavStyle.congestionColor(level), NavText.congestion(level) + " ≈")
                else if (nav.isWaitingAtSignal) Chip(Icons.Default.PauseCircle, Secondary, L("nav.atSignal"))
                nav.upcomingEvents().firstOrNull { it.kind.isSpeedCamera }?.let { cam ->
                    val d = max(0.0, cam.distanceAlongRoute - along)
                    Chip(NavStyle.icon("camera.fill"), NavStyle.purple, NavText.distance(d), L("nav.cameraIn.a11y", NavText.distance(d)))
                }
                nav.weather.current?.let { w ->
                    Chip(NavStyle.icon(w.symbolName), if (NavText.weatherWarnings(w).isEmpty()) Secondary else NavStyle.orange,
                        w.temperatureC?.let { "${Math.round(it)}°" } ?: NavText.weatherCondition(w.weatherCode))
                }
                nav.routeWeather.points.lastOrNull()?.snapshot?.let { d ->
                    d.temperatureC?.let { t ->
                        Chip(NavStyle.icon("flag.checkered"), if (NavText.weatherWarnings(d).isEmpty()) Secondary else NavStyle.orange,
                            "${Math.round(t)}°", L("nav.destWeather.a11y", Math.round(t).toInt()))
                    }
                }
            }
        }
        AnimatedVisibility(expanded && progress != null) {
            Column(Modifier.heightIn(max = 300.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                WazeButton(nav, app, prominent = false)
                // Timeline
                val all = nav.upcomingEvents()
                val shown = if (wholeRoute) all else all.take(10)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    SectionTitle(L("nav.ahead"), if (all.isEmpty()) null else L("nav.eventsCount", all.size))
                    if (shown.isEmpty()) T(if (nav.isLoadingRouteAttributes || nav.roadInfo.isLoadingRouteFeatures) L("nav.loadingRouteData") else L("nav.noEventsAhead"), 12.sp, color = Secondary)
                    shown.forEach { TimelineRow(it, max(0.0, it.distanceAlongRoute - along), nav.timeUntil(it)) }
                    if (all.size > 10) TextButton(onClick = { wholeRoute = !wholeRoute }) {
                        Text(if (wholeRoute) L("nav.nearestOnly") else L("nav.wholeRoute", all.size), fontSize = 12.sp)
                    }
                }
                // Signals (estimates)
                if (summary.first > 0 || nav.distanceToNextSignal != null) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        SectionTitle(L("settings.signal.title"))
                        if (summary.first > 0) T(L("nav.signals.total", summary.first, NavText.duration(summary.second)), 13.sp, FontWeight.SemiBold)
                        val next = nav.signals.upcoming(along, 1).firstOrNull()
                        if (next != null) {
                            T(L("nav.nextSignal", NavText.distance(next.distanceAhead), L("common.approxEstimate", NavText.duration(next.estimate.expectedWaitSeconds))), 13.sp)
                            T(L("nav.signalSource", NavText.signalSource(next.estimate.source), Math.round(next.estimate.stopProbability * 100).toInt()), 11.sp, color = Secondary)
                        } else nav.distanceToNextSignal?.let { d ->
                            val model = SignalWaitModel.estimate(nav.signals.assumptions)
                            T(L("nav.nextSignal", NavText.distance(d), L("common.approxEstimate", NavText.duration(model.expectedWaitSeconds))), 13.sp)
                            T(L("nav.signalSource", NavText.signalSource(model.source), Math.round(model.stopProbability * 100).toInt()), 11.sp, color = Secondary)
                        }
                        T(L("signal.disclaimer"), 11.sp, color = Secondary)
                    }
                }
                // Congestion (own-speed estimate, never traffic data)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    SectionTitle(L("nav.congestion"))
                    val level = nav.congestion
                    when {
                        level != null -> {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(Modifier.size(10.dp).clip(CircleShape).background(NavStyle.congestionColor(level)))
                                T(L("nav.congestion.level", NavText.congestion(level)), 13.sp, FontWeight.SemiBold)
                            }
                            val own = nav.averageSpeedKmh; val typical = nav.currentEdge?.typicalSpeedKmh
                            if (own != null && typical != null) T(L("nav.congestion.speeds", Math.round(own).toInt(), Math.round(typical).toInt()), 11.sp, color = Secondary)
                        }
                        nav.isWaitingAtSignal -> T(L("nav.congestion.paused"), 13.sp)
                        else -> T(L("nav.congestion.noData"), 13.sp, color = Secondary)
                    }
                    T(L("nav.congestion.note"), 11.sp, color = Secondary)
                }
                // Weather
                if (nav.weather.current != null || nav.routeWeather.points.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        SectionTitle(L("sources.weather.title"), "Open-Meteo")
                        nav.weather.current?.let { WeatherLine(L("nav.weatherHere"), it, null) }
                        nav.routeWeather.points.forEach { WeatherLine(it.label, it.snapshot, it.error) }
                    }
                }
                // Sources & notes
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    SectionTitle(L("nav.sources"))
                    nav.selectedRouteOption?.let { T(L("nav.sources.text", it.sources.joinToString(", ") { s -> s.badge }), 11.sp, color = Secondary) }
                    listOfNotNull(nav.routeAttributesError, nav.roadInfo.routeFeaturesCoverageNote).forEach { T(it, 11.sp, color = NavStyle.orange) }
                }
            }
        }
    }
}

/** Signals ahead and their summed ESTIMATED wait (Overpass signals with learned waits, else Valhalla signals × model). */
fun signalSummary(nav: NavigationController, app: AppState, along: Double): Pair<Int, Double> {
    val fromService = nav.signals.totalExpectedWait(along)
    if (fromService.first > 0) return fromService
    val count = nav.edgeSignalDistances.count { it >= along - 10 }
    if (count == 0) return 0 to 0.0
    val model = SignalWaitModel.estimate(nav.signals.assumptions)
    return count to count * model.expectedWaitSeconds
}
