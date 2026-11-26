package uz.roadvis.app.navigation

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.OSRM
import uz.roadvis.core.RoadIncidentKind
import uz.roadvis.core.Valhalla

private val SheetColor = Color(0xFF15181D)

/** Destination search (Photon) with recents (iOS `SearchView`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchSheet(nav: NavigationController, onSelect: (Place) -> Unit, onDismiss: () -> Unit) {
    val search = nav.placeSearch
    val focus = remember { FocusRequester() }
    ModalBottomSheet(onDismissRequest = { search.reset(); onDismiss() }, containerColor = SheetColor,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).imePadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T(L("nav.whereTo"), 18.sp, FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClick = { search.reset(); onDismiss() }) { Text(L("common.close")) }
            }
            OutlinedTextField(
                value = search.query,
                onValueChange = { search.updateQuery(it) },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                placeholder = { Text(L("search.placeholder")) },
                leadingIcon = { Icon(Icons.Default.Search, null) },
                trailingIcon = {
                    if (search.query.isNotEmpty()) IconButton(onClick = { search.updateQuery("") }) { Icon(Icons.Default.Clear, L("search.clear")) }
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { search.submit() }),
                shape = RoundedCornerShape(16.dp),
            )
            LaunchedEffect(Unit) { try { focus.requestFocus() } catch (_: Exception) {} }
            Spacer(Modifier.size(8.dp))
            LazyColumn(Modifier.fillMaxWidth().heightIn(min = 200.dp, max = 520.dp)) {
                if (search.isSearching) item {
                    Row(Modifier.heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(12.dp))
                        T(L("search.searching"), 15.sp, FontWeight.SemiBold)
                    }
                } else search.errorMessage?.let { msg ->
                    item {
                        Row(Modifier.heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.WarningAmber, null, tint = NavStyle.orange)
                            Spacer(Modifier.width(8.dp))
                            T(msg, 14.sp, color = NavStyle.orange)
                        }
                    }
                }
                if (search.query.isBlank()) {
                    if (search.recents.isEmpty()) item { T(L("search.empty"), 14.sp, color = Secondary, modifier = Modifier.padding(vertical = 14.dp)) }
                    else {
                        item { SectionTitle(L("search.recents")) }
                        items(search.recents, key = { "r" + it.id }) { place ->
                            PlaceRow(place, Icons.Default.History, onRemove = { search.removeRecent(place) }) { onSelect(place) }
                        }
                    }
                } else {
                    if (search.results.isNotEmpty()) item { SectionTitle(L("search.results")) }
                    items(search.results, key = { "s" + it.id }) { place -> PlaceRow(place, Icons.Default.LocationOn, null) { onSelect(place) } }
                }
                item { T(NavText.x("navx.searchProvider"), 10.sp, color = Secondary, modifier = Modifier.padding(vertical = 12.dp)) }
            }
        }
    }
}

@Composable
private fun PlaceRow(place: Place, icon: androidx.compose.ui.graphics.vector.ImageVector, onRemove: (() -> Unit)?, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClick = onClick).padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Secondary, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            T(place.name, 15.sp, FontWeight.SemiBold, maxLines = 1)
            place.subtitle?.let { T(it, 12.sp, color = Secondary, maxLines = 1) }
        }
        if (onRemove != null) IconButton(onClick = onRemove) { Icon(Icons.Default.Close, L("common.delete"), tint = Secondary) }
    }
    HorizontalDivider(color = Color.White.copy(alpha = 0.06f))
}

/** Report a road event / camera mark at a point or the current position (iOS `IncidentReportView`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IncidentReportSheet(nav: NavigationController, app: AppState, coordinate: GeoPoint?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val target = coordinate?.takeIf { it.isValid } ?: app.location.coordinate
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = SheetColor) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T(L("incident.title"), 18.sp, FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text(L("common.close")) }
            }
            T(when {
                coordinate != null -> L("incident.mapPoint")
                app.location.coordinate == null -> L("incident.noLocation")
                else -> L("incident.currentLocation")
            }, 14.sp, color = Secondary)
            LazyVerticalGrid(GridCells.Fixed(2), Modifier.heightIn(max = 520.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(RoadIncidentKind.entries) { kind ->
                    Column(Modifier.heightIn(min = 96.dp).clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.08f))
                        .clickable(enabled = target != null) {
                            target?.let {
                                nav.incidents.report(kind, it)
                                nav.refreshIncidents()
                                Toast.makeText(context, NavText.incident(kind), Toast.LENGTH_SHORT).show()
                                onDismiss()
                            }
                        }.padding(8.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                        Icon(NavStyle.icon(kind.symbolName), null, tint = NavStyle.incidentTint(kind), modifier = Modifier.size(32.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(NavText.incident(kind), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                            textAlign = TextAlign.Center, maxLines = 2)
                    }
                }
            }
            T(L("incident.footer", NavText.duration(app.settings.incidentLifetimeMinutes * 60)), 12.sp, color = Secondary)
            T(L("incident.cameraNote"), 12.sp, color = Secondary)
            Spacer(Modifier.size(16.dp))
        }
    }
}

/** Navigator settings: map style, routing, data sources, signals (iOS `NavigationSettingsSection`). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NavigatorSettingsSheet(nav: NavigationController, app: AppState, onDismiss: () -> Unit) {
    val s = app.settings
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmResetSignals by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = SheetColor,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T(L("settings.nav.title"), 18.sp, FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text(L("common.done")) }
            }
            // Map
            SectionTitle(L("navset.map"))
            Choice("OpenStreetMap (CARTO Dark)", true) { s.mapStyle = "cartoDark" }
            Footer(NavText.x("navx.map.cartoOnly"))
            // Guidance
            SectionTitle(L("settings.nav.title"))
            Toggle(L("settings.nav.voice"), s.voiceGuidanceEnabled) { s.voiceGuidanceEnabled = it }
            Toggle(L("settings.nav.avoidTolls"), s.avoidTolls) { s.avoidTolls = it }
            Toggle(L("settings.nav.avoidHighways"), s.avoidHighways) { s.avoidHighways = it }
            Toggle(L("settings.nav.speedWarning"), s.speedWarningEnabled) { s.speedWarningEnabled = it }
            // Routing
            SectionTitle(L("navset.routing"))
            Choice(NavText.x("navx.engine.auto"), s.routingEngine == "auto" || s.routingEngine == "apple") { s.routingEngine = "auto" }
            Choice(L("engine.option.valhalla"), s.routingEngine == "valhalla") { s.routingEngine = "valhalla" }
            Choice(L("engine.option.osrm"), s.routingEngine == "osrm") { s.routingEngine = "osrm" }
            EndpointField(L("navset.valhallaServer"), s.valhallaEndpoint, Valhalla.defaultEndpoint,
                ValhallaClient.url(s.valhallaEndpoint, "route") == null, L("navset.badURL"), L("navset.resetValhalla")) { s.valhallaEndpoint = it }
            val osrmEndpoint = nav.osrmEndpoint.also { nav.osrmEditVersion }
            EndpointField(L("navset.osrmServer"), osrmEndpoint, OSRM.defaultEndpoint,
                OSRM.routeURL(osrmEndpoint, GeoPoint(41.3, 69.2), GeoPoint(41.31, 69.21)) == null, L("navset.badOSRMURL"),
                L("navset.resetOSRM")) { nav.osrmEndpoint = it }
            Toggle(L("navset.routeAttributes"), s.routeAttributesEnabled) { s.routeAttributesEnabled = it }
            Footer(NavText.x("navx.routing.footer"))
            // Road data
            SectionTitle(L("settings.road.title"))
            Toggle(L("settings.road.osm"), s.roadDataEnabled) { s.roadDataEnabled = it }
            T(L("settings.road.server"), 13.sp, FontWeight.SemiBold)
            AppSettings.OVERPASS_ENDPOINTS.forEach { e -> Choice(java.net.URI(e).host ?: e, s.overpassEndpoint == e) { s.overpassEndpoint = e } }
            Footer(L("settings.road.footer"))
            // Camera & event sources
            SectionTitle(L("navset.sources"))
            Toggle(L("navset.sources.waze"), s.showWazeButton) { s.showWazeButton = it }
            Toggle(L("navset.sources.osmCameras"), s.osmCamerasEnabled) { s.osmCamerasEnabled = it; nav.applyDataSourceSettings() }
            Toggle(L("navset.sources.ownMarks"), s.ownMarksEnabled) { s.ownMarksEnabled = it; nav.applyDataSourceSettings() }
            val marks = nav.incidents.incidents.size
            if (marks > 0) TextButton(onClick = { confirmDelete = true }) { Text(L("navset.sources.deleteMarks", marks), color = NavStyle.red) }
            Footer(L("navset.sources.footer"))
            // Signals
            SectionTitle(L("settings.signal.title"))
            Toggle(L("settings.signal.learn"), s.learnSignalTimings) { s.learnSignalTimings = it }
            T(L("settings.signal.observations", nav.signals.observationCount), 13.sp, color = Secondary)
            if (nav.signals.observationCount > 0) TextButton(onClick = { confirmResetSignals = true }) { Text(L("settings.signal.reset"), color = NavStyle.red) }
            nav.signals.persistenceError?.let { T(it, 12.sp, color = NavStyle.orange) }
            Footer(L("settings.signal.footer"))
            Spacer(Modifier.size(24.dp))
        }
    }
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false },
        text = { Text(L("navset.sources.deleteMarks.confirm")) },
        confirmButton = { TextButton(onClick = { nav.incidents.removeAll(); nav.refreshIncidents(); confirmDelete = false }) { Text(L("navset.sources.deleteMarks.action"), color = NavStyle.red) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("common.cancel")) } })
    if (confirmResetSignals) AlertDialog(onDismissRequest = { confirmResetSignals = false },
        text = { Text(L("settings.signal.resetConfirm")) },
        confirmButton = { TextButton(onClick = { nav.signals.resetLearnedData(); confirmResetSignals = false }) { Text(L("common.reset"), color = NavStyle.red) } },
        dismissButton = { TextButton(onClick = { confirmResetSignals = false }) { Text(L("common.cancel")) } })
}

@Composable
private fun Toggle(title: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { onChange(!value) }, verticalAlignment = Alignment.CenterVertically) {
        T(title, 15.sp, modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onChange)
    }
}

@Composable
private fun Choice(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected = selected, onClick = onClick)
        T(title, 14.sp)
    }
}

@Composable
private fun Footer(text: String) = T(text, 11.sp, color = Secondary, modifier = Modifier.padding(bottom = 8.dp))

@Composable
private fun EndpointField(title: String, value: String, default: String, invalid: Boolean, invalidText: String,
                          resetText: String, onChange: (String) -> Unit) {
    var text by remember(value) { mutableStateOf(value) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        T(title, 13.sp, FontWeight.SemiBold)
        OutlinedTextField(value = text, onValueChange = { text = it; onChange(it) }, singleLine = true,
            modifier = Modifier.fillMaxWidth(), placeholder = { Text(default) },
            textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = Color.White),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        if (invalid) T(invalidText, 12.sp, color = NavStyle.orange)
        if (value != default) TextButton(onClick = { text = default; onChange(default) }) { Text(resetText, fontSize = 13.sp) }
    }
}
