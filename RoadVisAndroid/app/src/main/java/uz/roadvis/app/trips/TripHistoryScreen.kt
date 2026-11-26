package uz.roadvis.app.trips

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.Route
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import uz.roadvis.app.app.AppState
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.FormSection
import uz.roadvis.app.settings.GroupBackground
import uz.roadvis.app.settings.SecondaryText
import uz.roadvis.app.settings.SheetNav
import uz.roadvis.app.settings.SheetRoute
import uz.roadvis.app.settings.SheetScaffold
import uz.roadvis.app.settings.TL
import uz.roadvis.app.ui.RV
import uz.roadvis.core.Trip
import uz.roadvis.core.TripScoring
import uz.roadvis.core.TripStats
import java.util.Locale

/**
 * List of recorded trips (newest first) with score, A → B, distance and events; tap → report, swipe → delete.
 * On top: the running recording (with stop) or a button to start one manually. Port of iOS `TripHistoryView`.
 */
@Composable
fun TripHistoryScreen(app: AppState, nav: SheetNav) {
    val controller = TripsFeature.get(app)
    val store = controller.store
    LaunchedEffect(Unit) { store.load() }
    SheetScaffold(L("history.title"), nav) {
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                FormSection(footer = L("history.autoNote")) { RecordingRow(controller) }
            }
            if (store.trips.isEmpty()) {
                item {
                    FormSection {
                        if (store.isLoaded) Text(L("history.empty"), color = SecondaryText, fontSize = 13.sp, modifier = Modifier.padding(16.dp))
                        else Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                    }
                }
            } else {
                item {
                    Text(L("history.count", store.trips.size).uppercase(), fontSize = 12.sp, color = SecondaryText,
                        modifier = Modifier.padding(start = 28.dp, top = 8.dp, bottom = 6.dp))
                }
                items(store.trips, key = { it.id.toString() }) { trip ->
                    val isRecording = trip.id == controller.recorder.currentTripId
                    SwipeToDelete(onDelete = { store.delete(trip.id) }, enabled = !isRecording) {
                        Box(
                            Modifier.padding(horizontal = 16.dp, vertical = 3.dp).fillMaxWidth()
                                .background(GroupBackground, RoundedCornerShape(RV.Radius.control))
                                .clickable(enabled = !isRecording) { nav.push(SheetRoute.Report(trip.id.toString())) }
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                        ) { TripHistoryRow(trip, isRecording) }
                    }
                }
            }
            store.lastError?.let { error ->
                item {
                    FormSection {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Warning, null, tint = TripStyle.orange)
                            Spacer(Modifier.width(8.dp))
                            Text(error, color = TripStyle.orange, fontSize = 14.sp)
                        }
                    }
                }
            }
            item { Spacer(Modifier.size(24.dp)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeToDelete(onDelete: () -> Unit, enabled: Boolean, content: @Composable () -> Unit) {
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        if (value == SwipeToDismissBoxValue.EndToStart) { onDelete(); true } else false
    })
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = enabled,
        backgroundContent = {
            Box(
                Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 3.dp).background(RV.danger, RoundedCornerShape(RV.Radius.control))
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(TL("android.history.delete"), color = Color.White, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.width(6.dp))
                    Icon(Icons.Filled.Delete, null, tint = Color.White)
                }
            }
        },
    ) { content() }
}

/** Running recording with timer and stop, «saving…», or the manual start button. */
@Composable
fun RecordingRow(controller: TripsController) {
    val recorder = controller.recorder
    val started = recorder.startedAtMillis
    when {
        recorder.isFinishing -> Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(10.dp))
            Text(L("trip.saving"), color = Color.White)
        }
        recorder.isRecording && started != null -> Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            val pulse by rememberInfiniteTransition(label = "rec").animateFloat(0.4f, 1f,
                infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "recAlpha")
            Icon(Icons.Filled.FiberManualRecord, null, tint = RV.recording, modifier = Modifier.size(26.dp).alpha(pulse))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(L("trip.recording"), color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
                LaunchedEffect(started) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
                Text(timerText(now - started) + " " + L("history.live", AppFormat.distance(recorder.liveDistanceMeters), recorder.liveEventCount),
                    color = SecondaryText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            OutlinedButton(onClick = { controller.stopTripRecording() }) { Text(L("history.stop"), color = RV.danger) }
        }
        else -> uz.roadvis.app.settings.ButtonRow(L("trip.record.start"), Icons.Filled.FiberManualRecord) { controller.startTripRecording() }
    }
}

private fun timerText(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) String.format(Locale.US, "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    else String.format(Locale.US, "%d:%02d", s / 60, s % 60)
}

@Composable
fun TripHistoryRow(trip: Trip, isRecording: Boolean) {
    val stats = remember(trip) { TripStats.compute(trip) }
    val score = remember(trip) { TripScoring.score(trip.events, stats.distanceMeters).score }
    Row(verticalAlignment = Alignment.CenterVertically) {
        ScoreRing(score, 46.dp)
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(TripStyle.title(trip), color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 2)
            Text(TripStyle.dateText(trip), color = SecondaryText, fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconLabel(Icons.Filled.Route, AppFormat.distance(stats.distanceMeters), SecondaryText)
                IconLabel(Icons.Filled.Schedule, AppFormat.duration(stats.duration), SecondaryText)
                if (stats.totalEvents > 0) IconLabel(Icons.Filled.Warning, "${stats.totalEvents}", RV.caution)
                if (isRecording) Text(L("history.recordingLower"), color = RV.recording, fontSize = 11.sp)
                else if (trip.endedAtMillis == null) Text(L("history.interrupted"), color = RV.caution, fontSize = 11.sp)
            }
        }
    }
}

@Composable
private fun IconLabel(icon: ImageVector, text: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(12.dp), tint = color)
        Spacer(Modifier.width(3.dp))
        Text(text, color = color, fontSize = 11.sp)
    }
}
