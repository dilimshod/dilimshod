package uz.roadvis.app.trips

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.filled.AddRoad
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.DoNotDisturbOn
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Construction
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.GroupBackground
import uz.roadvis.app.settings.SecondaryText
import uz.roadvis.app.settings.SheetNav
import uz.roadvis.app.settings.SheetScaffold
import uz.roadvis.app.settings.TL
import uz.roadvis.app.ui.RV
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.DrivingEventKind
import uz.roadvis.core.DrivingEventSeverity
import uz.roadvis.core.Trip
import uz.roadvis.core.TripScoring
import uz.roadvis.core.TripStats
import java.util.UUID

/**
 * Report of one trip (port of iOS `TripReportView`): map (route, A/B, coloured event markers), driving score with
 * its formula, numbers, colourful charts (speed vs limit, events by kind, ≈ lead gap vs recommended, time per speed
 * band), the list of all events and the export (PDF + CSV via the share sheet).
 */
@Composable
fun TripReportScreen(app: AppState, tripId: String, nav: SheetNav, leadingDone: Boolean) {
    val controller = TripsFeature.get(app)
    val trip = controller.store.trip(tripId)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var files by remember(tripId) { mutableStateOf<TripReportExporter.Files?>(null) }
    var exporting by remember { mutableStateOf(false) }
    var exportError by remember { mutableStateOf<String?>(null) }

    fun prepare(thenShare: Boolean) {
        val t = trip ?: return
        if (exporting) return
        exporting = true
        exportError = null
        scope.launch {
            try {
                val f = withContext(Dispatchers.IO) { TripReportExporter.export(context.applicationContext, t) }
                files = f
                if (thenShare) TripReportExporter.share(context, f.all)
            } catch (e: Exception) {
                exportError = L("report.exportFailed", e.localizedMessage ?: e.toString())
            } finally {
                exporting = false
            }
        }
    }

    SheetScaffold(
        title = L("report.title"),
        nav = nav,
        leadingDone = leadingDone,
        actions = {
            if (trip != null) {
                if (exporting) CircularProgressIndicator(Modifier.size(22.dp).padding(2.dp), strokeWidth = 2.dp)
                else IconButton(onClick = {
                    val f = files
                    if (f != null) TripReportExporter.share(context, f.all) else prepare(thenShare = true)
                }) { Icon(Icons.Filled.Share, L("report.share"), tint = RV.accent) }
            }
        },
    ) {
        if (trip == null) {
            Text(TL("android.report.notFound"), color = SecondaryText, modifier = Modifier.padding(24.dp))
            return@SheetScaffold
        }
        TripReportContent(app, trip, files, exporting, exportError,
            onPrepare = { prepare(thenShare = false) },
            onShare = { TripReportExporter.share(context, it) })
    }
}

@Composable
private fun TripReportContent(
    app: AppState,
    trip: Trip,
    files: TripReportExporter.Files?,
    exporting: Boolean,
    exportError: String?,
    onPrepare: () -> Unit,
    onShare: (List<java.io.File>) -> Unit,
) {
    val stats = remember(trip) { TripStats.compute(trip) }
    val score = remember(trip) { TripScoring.score(trip.events, stats.distanceMeters) }
    val data = remember(trip) { TripChartData(trip, stats) }
    var highlighted by remember { mutableStateOf<UUID?>(null) }
    var showsFormula by remember { mutableStateOf(false) }
    val recordingId = TripsFeature.get(app).recorder.currentTripId

    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = RV.gutter).padding(top = 8.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // Header
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(TripStyle.title(trip), color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 3)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(TripStyle.dateText(trip), color = SecondaryText, fontSize = 12.sp)
                if (trip.arrived) Badge(L("report.arrived"), RV.safe, Icons.Filled.Flag)
                else if (trip.endedAtMillis == null && trip.id != recordingId) Badge(L("report.interrupted"), RV.caution, Icons.Filled.Warning)
                trip.routeSource?.let { Badge(it, RV.accent, Icons.Filled.Timeline) }
            }
        }
        TripMap(trip, highlighted, Modifier.fillMaxWidth().height(260.dp).clip18())
        // Map legend
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            LegendDot(RV.accent, L("report.legend.driven"))
            if (trip.routePolyline.isNotEmpty()) LegendDot(Color.Gray, L("report.legend.route"))
            DrivingEventKind.entries.filter { k -> trip.events.any { it.kind == k } }.forEach { LegendDot(TripStyle.color(it), it.localizedTitle) }
        }
        // Score
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ScoreRing(score.score, 92.dp)
                Spacer(Modifier.width(16.dp))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(L("report.score"), color = SecondaryText, fontSize = 12.sp)
                    Text(TripStyle.grade(score.score), color = TripStyle.scoreColor(score.score), fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Text(L("report.penalty", AppFormat.decimal(score.totalPenalty, 1), AppFormat.decimal(score.penaltyPerKm, 2)), color = SecondaryText, fontSize = 12.sp)
                }
            }
            Row(Modifier.fillMaxWidth().clickable { showsFormula = !showsFormula }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(L("report.howScored"), color = RV.accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Icon(if (showsFormula) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null, tint = RV.accent)
            }
            if (showsFormula) {
                Text(TripStyle.formula, color = SecondaryText, fontSize = 12.sp)
                DrivingEventKind.entries.filter { (score.penaltyByKind[it] ?: 0.0) > 0 }.forEach { k ->
                    Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).background(TripStyle.color(k), CircleShape))
                        Spacer(Modifier.width(6.dp))
                        Text(k.localizedTitle, color = Color.White, fontSize = 12.sp, modifier = Modifier.weight(1f))
                        Text(L("report.points", AppFormat.decimal(score.penaltyByKind[k] ?: 0.0, 1)), color = Color.White, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                    }
                }
            }
        }
        StatsGrid(stats)
        ChartCard(L("report.speedAndLimit"), Icons.Filled.Speed) {
            ChartCanvas(200.dp) { c, w, h, p -> TripChartRenderer.drawSpeedChart(c, w, h, data, p) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                LegendLine(RV.accent, L("chart.legend.speed"))
                LegendLine(RV.danger, L("chart.limit"), dashed = true)
                LegendDot(TripStyle.color(DrivingEventKind.SPEEDING), L("chart.events"))
            }
            if (stats.speedLimitCoverage < 0.999) {
                Text(L("report.limitCoverage", Math.round(stats.speedLimitCoverage * 100).toInt()), color = SecondaryText, fontSize = 11.sp)
            }
        }
        ChartCard(L("report.eventsByKind"), Icons.Filled.BarChart) {
            if (data.kindCounts.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = RV.safe)
                    Spacer(Modifier.width(6.dp))
                    Text(L("report.noEventsGreat"), color = RV.safe)
                }
            } else {
                val density = LocalDensity.current
                val h = with(density) { TripChartRenderer.kindBarsHeight(data, uz.roadvis.app.trips.ChartPalette.dark(density.density)).toDp() }
                ChartCanvas(h) { c, w, _, p -> TripChartRenderer.drawKindBars(c, w, data, p) }
            }
        }
        ChartCard(L("report.leadDistance"), Icons.Filled.DirectionsCar) {
            if (data.hasLeadData) {
                ChartCanvas(170.dp) { c, w, h, p -> TripChartRenderer.drawLeadChart(c, w, h, data, p) }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    LegendLine(RV.safe, L("report.legend.lead"))
                    LegendLine(RV.caution, L("report.legend.recommended"), dashed = true)
                }
                stats.shareBelowRecommendedGap?.let {
                    Text(L("report.belowRecommended", Math.round(it * 100).toInt()), color = SecondaryText, fontSize = 11.sp)
                }
            } else {
                Text(L("report.noLeadDataLong"), color = SecondaryText, fontSize = 13.sp)
            }
        }
        ChartCard(L("report.timeBySpeed"), Icons.Filled.PieChart) {
            if (data.bands.isEmpty()) {
                Text(L("report.noSpeedData"), color = SecondaryText, fontSize = 13.sp)
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ChartCanvas(130.dp, Modifier.width(130.dp)) { c, w, h, p -> TripChartRenderer.drawDonut(c, w / 2, h / 2, minOf(w, h) / 2, data, p) }
                    Spacer(Modifier.width(16.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        data.bands.forEach { b ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(Modifier.size(9.dp).background(TripStyle.bandColor(b.band), CircleShape))
                                Spacer(Modifier.width(6.dp))
                                Text(b.band.localizedTitle, color = Color.White, fontSize = 12.sp, modifier = Modifier.weight(1f))
                                Text("${Math.round(b.share * 100)}% · ${AppFormat.duration(b.seconds)}", color = Color.White,
                                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        }
        // Events
        ChartCard(L("report.allEvents", trip.events.size), Icons.AutoMirrored.Filled.List) {
            if (trip.events.isEmpty()) {
                Text(L("report.noEventsTrip"), color = SecondaryText, fontSize = 13.sp)
            } else {
                val sorted = trip.sortedEvents
                sorted.forEachIndexed { i, e ->
                    EventRow(e, e.id == highlighted) { highlighted = if (highlighted == e.id) null else e.id }
                    if (i < sorted.lastIndex) HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                }
            }
        }
        // Export
        ChartCard(L("report.share"), Icons.Filled.Share) {
            Text(L("report.shareDetail"), color = SecondaryText, fontSize = 12.sp)
            if (files != null) {
                Button(onClick = { onShare(files.all) }, Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = RV.accent)) {
                    Icon(Icons.Filled.Share, null); Spacer(Modifier.width(8.dp))
                    Text(L("report.sendFiles"), fontWeight = FontWeight.SemiBold)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    SmallShare("PDF", Icons.Filled.PictureAsPdf) { onShare(listOf(files.pdf)) }
                    SmallShare(L("report.eventsCSV"), Icons.Filled.TableChart) { onShare(listOf(files.eventsCSV)) }
                    SmallShare(L("report.trackCSV"), Icons.Filled.Timeline) { onShare(listOf(files.pointsCSV)) }
                }
            } else {
                Button(onClick = onPrepare, enabled = !exporting, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = RV.accent)) {
                    if (exporting) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White); Spacer(Modifier.width(8.dp)) }
                    Text(if (exporting) L("report.preparing") else L("report.prepare"), fontWeight = FontWeight.SemiBold)
                }
            }
            exportError?.let { Text(it, color = RV.danger, fontSize = 12.sp) }
            if (trip.cameraCSVFiles.isNotEmpty()) {
                Text(L("report.cameraCSV", trip.cameraCSVFiles.joinToString(", ")), color = SecondaryText, fontSize = 11.sp)
            }
        }
        Text(L("report.footer"), color = SecondaryText, fontSize = 11.sp)
    }
}

private fun Modifier.clip18(): Modifier = this.clip(RoundedCornerShape(RV.Radius.panel))

/** Material icon for an event kind (iOS uses SF Symbols, see `DrivingEventKind.symbolName`). */
fun eventIcon(kind: DrivingEventKind): ImageVector = when (kind) {
    DrivingEventKind.SPEEDING -> Icons.Filled.Speed
    DrivingEventKind.TAILGATING -> Icons.Filled.DirectionsCar
    DrivingEventKind.COLLISION_RISK -> Icons.Filled.Warning
    DrivingEventKind.LANE_DEPARTURE -> Icons.Filled.AddRoad
    DrivingEventKind.RED_LIGHT_RUNNING -> Icons.Filled.Traffic
    DrivingEventKind.STOP_SIGN_IGNORED -> Icons.Filled.DoNotDisturbOn
    DrivingEventKind.PEDESTRIAN_NOT_YIELDED -> Icons.AutoMirrored.Filled.DirectionsWalk
    DrivingEventKind.HARSH_BRAKING -> Icons.Filled.ArrowCircleDown
    DrivingEventKind.HARSH_ACCELERATION -> Icons.Filled.ArrowCircleUp
    DrivingEventKind.TRAFFIC_OFFICER_SEEN -> Icons.Filled.Shield
    DrivingEventKind.ROAD_WORKERS_SEEN -> Icons.Filled.Construction
}

@Composable
private fun SmallShare(text: String, icon: ImageVector, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Icon(icon, null, Modifier.size(18.dp), tint = RV.accent)
        Spacer(Modifier.width(4.dp))
        Text(text, color = RV.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth().background(GroupBackground, RoundedCornerShape(RV.Radius.panel)).padding(14.dp).animateContentSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}

@Composable
private fun ChartCard(title: String, icon: ImageVector, content: @Composable ColumnScope.() -> Unit) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = RV.accent, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(title, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        content()
    }
}

/** Compose host for the `android.graphics` chart renderer. */
@Composable
private fun ChartCanvas(height: Dp, modifier: Modifier = Modifier.fillMaxWidth(),
                        draw: (android.graphics.Canvas, Float, Float, ChartPalette) -> Unit) {
    val density = LocalDensity.current.density
    val palette = remember(density) { ChartPalette.dark(density) }
    Canvas(modifier.height(height)) {
        drawIntoCanvas { draw(it.nativeCanvas, size.width, size.height, palette) }
    }
}

@Composable
private fun Badge(text: String, color: Color, icon: ImageVector? = null) {
    Row(
        Modifier.background(color.copy(alpha = 0.18f), RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Icon(icon, null, Modifier.size(11.dp), tint = color); Spacer(Modifier.width(3.dp)) }
        Text(text, color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun LegendDot(color: Color, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Spacer(Modifier.width(4.dp))
        Text(text, color = SecondaryText, fontSize = 11.sp)
    }
}

@Composable
private fun LegendLine(color: Color, text: String, dashed: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.width(16.dp).height(4.dp)) {
            drawLine(color, androidx.compose.ui.geometry.Offset(0f, size.height / 2), androidx.compose.ui.geometry.Offset(size.width, size.height / 2),
                strokeWidth = 2.dp.toPx(), pathEffect = if (dashed) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx())) else null)
        }
        Spacer(Modifier.width(4.dp))
        Text(text, color = SecondaryText, fontSize = 11.sp)
    }
}

/** Circular score gauge 0…100 in the score colour. */
@Composable
fun ScoreRing(score: Int, size: Dp) {
    val density = LocalDensity.current.density
    val palette = remember(density) { ChartPalette.dark(density) }
    val label = L("report.score.a11y", score)
    Canvas(Modifier.size(size).semantics { contentDescription = label }) {
        drawIntoCanvas { TripChartRenderer.drawScoreRing(it.nativeCanvas, this.size.width / 2, this.size.height / 2, this.size.minDimension, score, palette) }
    }
}

@Composable
private fun StatsGrid(stats: TripStats) {
    val tiles = TripStatsTiles.tiles(stats)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { tile ->
                    Column(
                        Modifier.weight(1f).background(tile.color.copy(alpha = 0.12f), RoundedCornerShape(12.dp)).padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(tile.icon, null, Modifier.size(13.dp), tint = tile.color)
                            Spacer(Modifier.width(4.dp))
                            Text(tile.title, color = tile.color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Text(tile.value, color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** One event in the report list: icon, title, time, value, place. */
@Composable
private fun EventRow(event: DrivingEvent, highlighted: Boolean, onClick: () -> Unit) {
    val color = TripStyle.color(event.kind)
    Row(
        Modifier.fillMaxWidth()
            .background(if (highlighted) color.copy(alpha = 0.15f) else Color.Transparent, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick).padding(vertical = 6.dp, horizontal = if (highlighted) 6.dp else 0.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.size(30.dp).background(color, CircleShape).border(1.5.dp, TripStyle.severityColor(event.severity), CircleShape),
            contentAlignment = Alignment.Center) {
            Icon(eventIcon(event.kind), null, Modifier.size(16.dp), tint = Color.White)
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(event.kind.localizedTitle, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (event.severity == DrivingEventSeverity.VIOLATION) { Spacer(Modifier.width(6.dp)); Badge(L("report.violation"), RV.danger) }
                Spacer(Modifier.weight(1f))
                Text(TripStyle.timeText(event.dateMillis), color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            Text(TripStyle.valueText(event), color = Color.White, fontSize = 12.sp)
            Text(TripStyle.placeText(event), color = SecondaryText, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
