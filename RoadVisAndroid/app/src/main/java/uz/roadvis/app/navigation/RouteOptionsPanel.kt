package uz.roadvis.app.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.RouteComparison
import uz.roadvis.core.RouteFacts
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.RouteTimelineEvent
import uz.roadvis.core.RouteTimelineKind
import kotlin.math.roundToInt

/** Preview of the route options with «Поехали» (iOS `RouteOptionsView`). */
@Composable
fun RouteOptionsPanel(nav: NavigationController, app: AppState, onGo: () -> Unit) {
    var showsComparison by remember { mutableStateOf(false) }
    val options = nav.routeOptions
    val selected = nav.selectedRouteOption
    Column(Modifier.fillMaxWidth().glass().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                T(L("routes.header", options.size), 12.sp, color = Secondary)
                T(nav.destination?.name ?: L("weather.destination"), 17.sp, FontWeight.SemiBold, maxLines = 1)
            }
            OutlinedButton(onClick = { nav.stopNavigation() }, shape = CircleShape) { Text(L("common.cancel"), fontSize = 13.sp) }
        }
        nav.routingNotice?.let { notice ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Default.Info, null, tint = NavStyle.orange, modifier = Modifier.size(14.dp))
                T(notice, 12.sp, color = NavStyle.orange, maxLines = 3)
            }
        }
        val fastest = options.minOfOrNull { it.expectedTravelTime } ?: 0.0
        Column(Modifier.heightIn(max = 250.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            options.forEach { option ->
                RouteOptionCard(option, nav.facts(option), fastest, option.id == selected?.id) { nav.selectRoute(option.id) }
            }
        }
        if (selected != null) {
            RouteStrip(nav.routeLength, 0.0, nav.speedLimitSegments, nav.timeline, showsPosition = false, height = 6.dp)
            RouteContentSummary(nav.timeline)
        }
        if (nav.isLoadingRouteAttributes || nav.roadInfo.isLoadingRouteFeatures) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                T(L("routes.loadingAttributes"), 11.sp, color = Secondary)
            }
        } else (nav.routeAttributesError ?: nav.roadInfo.routeFeaturesCoverageNote)?.let { T(it, 11.sp, color = Secondary, maxLines = 3) }
        nav.routeWeather.points.forEach { WeatherLine(it.label, it.snapshot, it.error) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedButton(onClick = { showsComparison = true }, modifier = Modifier.heightIn(min = 50.dp), shape = RoundedCornerShape(RV.Radius.control)) {
                Icon(Icons.AutoMirrored.Filled.List, null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(L("routes.compare"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            Button(onClick = onGo, enabled = selected != null, modifier = Modifier.weight(1f).heightIn(min = 50.dp),
                shape = RoundedCornerShape(RV.Radius.control), colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1FA35A))) {
                Icon(Icons.Default.Navigation, null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(6.dp))
                Text(L("routes.go"), fontSize = 19.sp, fontWeight = FontWeight.Bold)
            }
        }
        WazeButton(nav, app, prominent = true)
    }
    if (showsComparison) RouteComparisonSheet(nav) { showsComparison = false }
}

@Composable
private fun RouteOptionCard(option: RouteOption, facts: RouteFacts, fastest: Double, isSelected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(RV.Radius.control)
    Column(Modifier.fillMaxWidth().clip(shape)
        .background(if (isSelected) RV.accent.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.06f))
        .border(2.dp, if (isSelected) RV.accent else Color.Transparent, shape)
        .clickable(onClick = onClick).padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            T(NavText.duration(option.expectedTravelTime), 22.sp, FontWeight.Bold, maxLines = 1)
            val delta = RouteComparison.delayText(option.expectedTravelTime, fastest, NavText.lang)
            if (delta != null) T(delta, 12.sp, FontWeight.Bold, RV.caution, 1) else T(L("routes.fastest"), 11.sp, FontWeight.Bold, RV.safe, 1)
            T(NavText.distance(option.distance), 14.sp, color = Secondary, maxLines = 1)
            Spacer(Modifier.weight(1f))
            T(NavText.clock(System.currentTimeMillis() + (option.expectedTravelTime * 1000).toLong()), 14.sp, FontWeight.SemiBold, maxLines = 1)
            Icon(if (isSelected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                if (isSelected) L("routes.selected") else null, tint = if (isSelected) RV.accent else Secondary, modifier = Modifier.size(20.dp))
        }
        // Range of the engines' estimates when several found the same route.
        if (option.alsoFoundBy.isNotEmpty()) {
            val times = listOf(option.expectedTravelTime) + option.alsoFoundBy.map { it.expectedTravelTime }
            val lo = times.min(); val hi = times.max()
            if (hi - lo >= 60) T("≈ ${NavText.duration(lo)}–${NavText.duration(hi)}", 12.sp, FontWeight.SemiBold, Secondary, 1)
        }
        T(option.name, 12.sp, color = Secondary, maxLines = 1)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            option.sources.forEach { EngineBadge(it) }
            facts.signalCount?.let { Badge("$it", NavStyle.orange, NavStyle.icon("light.beacon.max")) }
            facts.maxSpeedLimitKmh?.let { Badge(L("routes.upTo", it), NavStyle.speedLimitColor(it), NavStyle.icon("speedometer")) }
            facts.primaryRoadShare?.let { Badge(L("routes.mainShare", NavText.percent(it)), NavStyle.teal, NavStyle.icon("road.lanes")) }
            if (facts.hasTolls) Badge(L("routes.toll"), NavStyle.yellow)
            if (facts.hasHighways) Badge(L("routes.highways"), NavStyle.teal)
            facts.unpavedShare?.let { if (it >= 0.05) Badge(L("routes.unpavedShare", NavText.percent(it)), NavStyle.brown, NavStyle.icon("exclamationmark.triangle")) }
        }
        if (!option.source.mayIncludeTraffic) T(L("routes.osmTimeNote"), 11.sp, color = Secondary)
        option.route.advisories.take(2).forEach { T(it, 11.sp, color = NavStyle.yellow, maxLines = 2) }
    }
}

/** Counts of signals, cameras, schools … on the selected route (iOS `RouteContentSummary`). */
@Composable
private fun RouteContentSummary(events: List<RouteTimelineEvent>) {
    fun count(p: (RouteTimelineKind) -> Boolean) = events.count { p(it.kind) }
    val items = ArrayList<Triple<String, Int, Color>>()
    count { it == RouteTimelineKind.TrafficSignal }.let { if (it > 0) items += Triple("light.beacon.max", it, NavStyle.orange) }
    val kinds = listOf(RouteFeatureKind.SPEED_CAMERA, RouteFeatureKind.SCHOOL, RouteFeatureKind.KINDERGARTEN,
        RouteFeatureKind.PEDESTRIAN_CROSSING, RouteFeatureKind.TRAFFIC_CALMING, RouteFeatureKind.RAILWAY_CROSSING,
        RouteFeatureKind.CONSTRUCTION, RouteFeatureKind.FUEL, RouteFeatureKind.PARKING)
    for (k in kinds) {
        val n = if (k == RouteFeatureKind.SPEED_CAMERA) count { it.isSpeedCamera } else count { it == RouteTimelineKind.Feature(k) }
        if (n > 0) items += Triple(k.symbolName, n, NavStyle.featureColor(k))
    }
    count { it is RouteTimelineKind.Maneuver }.let { if (it > 0) items += Triple("arrow.triangle.branch", it, Color.White) }
    if (items.isEmpty()) return
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        items.forEach { (symbol, n, color) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(NavStyle.icon(symbol), null, tint = color, modifier = Modifier.size(13.dp))
                Spacer(Modifier.width(2.dp))
                T("$n", 11.sp, FontWeight.SemiBold, color, 1)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RouteComparisonSheet(nav: NavigationController, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF15181D)) {
        val fastest = nav.routeOptions.minOfOrNull { it.expectedTravelTime } ?: 0.0
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { T(L("routes.comparison"), 18.sp, FontWeight.Bold) }
            item { SectionTitle(L("routes.options")) }
            nav.routeOptions.forEach { option ->
                item(key = "o${option.id}") {
                    val facts = nav.facts(option)
                    val isSelected = option.id == nav.selectedRouteOption?.id
                    Column(Modifier.fillMaxWidth().clickable { nav.selectRoute(option.id) }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            T(option.name, 14.sp, FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f))
                            if (isSelected) Icon(Icons.Default.CheckCircle, null, tint = RV.accent, modifier = Modifier.size(18.dp))
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) { option.sources.forEach { EngineBadge(it) } }
                        val rows = ArrayList<Pair<String, String>>()
                        rows += L("routes.row.time") to (NavText.duration(option.expectedTravelTime) +
                            (RouteComparison.delayText(option.expectedTravelTime, fastest, NavText.lang)?.let { " ($it)" } ?: ""))
                        option.alsoFoundBy.forEach { rows += "  ${it.source.badge}" to "≈ ${NavText.duration(it.expectedTravelTime)}, ${NavText.distance(it.distance)}" }
                        rows += L("routes.row.distance") to NavText.distance(option.distance)
                        facts.averageSpeedKmh?.let { rows += L("routes.row.avgSpeed") to L("routes.kmhEstimate", it.roundToInt()) }
                        rows += L("settings.signal.title") to (facts.signalCount?.toString() ?: L("status.loading"))
                        facts.maxSpeedLimitKmh?.let { rows += L("routes.row.maxLimit") to "$it ${NavText.kmh}" }
                        facts.averageSpeedLimitKmh?.let { rows += L("routes.row.avgLimit") to "≈ ${it.roundToInt()} ${NavText.kmh}" }
                        facts.speedLimitCoverage?.let { rows += L("routes.row.limitCoverage") to L("routes.ofLength", NavText.percent(it)) }
                        facts.primaryRoadShare?.let { rows += L("routes.row.mainRoads") to "${NavText.percent(it)}%" }
                        facts.unpavedShare?.let { if (it > 0) rows += L("routes.row.unpaved") to "${NavText.percent(it)}%" }
                        rows += L("routes.row.maneuvers") to "${facts.maneuverCount}"
                        if (facts.tunnelCount > 0 || facts.bridgeCount > 0) rows += L("routes.row.bridges") to "${facts.bridgeCount} / ${facts.tunnelCount}"
                        rows += L("routes.row.tollsHighways") to ((if (facts.hasTolls) L("common.yesLower") else L("common.noLower")) + " / " +
                            (if (facts.hasHighways) L("common.yesLower") else L("common.noLower")))
                        rows.forEach { (k, v) ->
                            Row { T(k, 12.sp, color = Secondary, modifier = Modifier.weight(1f)); T(v, 12.sp, modifier = Modifier.weight(1f)) }
                        }
                    }
                }
            }
            if (nav.comparisonNotes.isNotEmpty()) {
                item { SectionTitle(L("routes.notes")) }
                nav.comparisonNotes.forEach { note -> item { T(note, 13.sp) } }
            }
            item { SectionTitle(L("routes.sources")) }
            nav.engineReports.forEach { report ->
                item {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(if (report.isSuccess) Icons.Default.CheckCircle else Icons.Default.Cancel, null,
                            tint = if (report.isSuccess) RV.safe else Secondary, modifier = Modifier.size(16.dp))
                        T(report.summary, 13.sp, color = if (report.isSuccess) Color.White else Secondary)
                    }
                }
            }
            item { T(L("routes.sources.footer"), 11.sp, color = Secondary) }
            item {
                SectionTitle(L("nav.speedLimitColors"))
                Spacer(Modifier.size(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    NavStyle.speedLimitLegend.forEach { (label, kmh) ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Spacer(Modifier.size(10.dp, 5.dp).clip(RoundedCornerShape(2.dp)).background(NavStyle.speedLimitColor(kmh)))
                            Spacer(Modifier.width(3.dp))
                            T(label, 9.sp, color = Secondary, maxLines = 1)
                        }
                    }
                }
            }
            item { Spacer(Modifier.size(24.dp)) }
        }
    }
}
