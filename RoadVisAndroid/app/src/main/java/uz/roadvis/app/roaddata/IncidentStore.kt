package uz.roadvis.app.roaddata

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.l10n.L
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.IncidentFilter
import uz.roadvis.core.IncidentOnRoute
import uz.roadvis.core.RoadIncident
import uz.roadvis.core.RoadIncidentKind
import java.io.File
import java.util.Date
import java.util.UUID
import kotlin.math.max

/**
 * The user's own road events and camera marks, stored only on the phone (`filesDir/RoadVis/incidents.json`, iOS
 * Codable layout). Non-camera reports expire after the lifetime set in Settings; camera marks are permanent.
 * Port of iOS `IncidentStore`. There is no shared incident feed.
 */
class IncidentStore(private val settings: AppSettings, private val filesDir: File, private val scope: CoroutineScope) {
    companion object {
        const val FILE = "incidents.json"
        const val DUPLICATE_RADIUS = 80.0
        const val PRUNE_INTERVAL_MS = 60_000L
    }

    var incidents by mutableStateOf<List<RoadIncident>>(emptyList()); private set
    var lastError by mutableStateOf<String?>(null); private set

    val lifetimeSeconds: Double get() = max(1.0, settings.incidentLifetimeMinutes) * 60

    init {
        var loaded: List<RoadIncident> = emptyList()
        when (val r = RoadDataPersistence.load(filesDir, FILE)) {
            is RoadDataPersistence.LoadResult.Loaded -> try {
                loaded = RoadIncident.decodeList(r.text)
            } catch (e: Exception) {
                lastError = RoadDataPersistence.quarantine(filesDir, FILE)
            }
            is RoadDataPersistence.LoadResult.Failed -> lastError = r.message
            RoadDataPersistence.LoadResult.Missing -> Unit
        }
        val active = IncidentFilter.active(loaded, Date(), lifetimeSeconds)
        incidents = active
        if (active.size != loaded.size) persist()
        scope.launch {
            while (isActive) {
                delay(PRUNE_INTERVAL_MS)
                pruneExpired()
            }
        }
    }

    fun report(kind: RoadIncidentKind, at: GeoPoint, note: String? = null) {
        if (!at.isValid) return
        val now = Date()
        val clean = note?.trim()?.ifEmpty { null }
        val updated = IncidentFilter.active(incidents, now, lifetimeSeconds).toMutableList()
        val index = updated.indexOfFirst { it.kind == kind && Geo.distance(it.coordinate, at) <= DUPLICATE_RADIUS }
        if (index >= 0) {
            val existing = updated.removeAt(index)
            updated.add(existing.copy(date = now, coordinate = at, note = clean ?: existing.note))
        } else {
            updated.add(RoadIncident(kind = kind, coordinate = at, date = now, note = clean))
        }
        incidents = updated.sortedByDescending { it.date.time }
        persist()
    }

    fun remove(id: UUID) {
        val updated = incidents.filter { it.id != id }
        if (updated.size == incidents.size) return
        incidents = updated
        persist()
    }

    fun removeAll() {
        if (incidents.isEmpty()) return
        incidents = emptyList()
        persist()
    }

    fun along(route: List<GeoPoint>, cumulative: List<Double>?): List<IncidentOnRoute> {
        val active = IncidentFilter.active(incidents, Date(), lifetimeSeconds)
        if (active.isEmpty() || route.size < 2) return emptyList()
        return IncidentFilter.along(route, cumulative, active)
    }

    fun pruneExpired() {
        val active = IncidentFilter.active(incidents, Date(), lifetimeSeconds)
        if (active.size == incidents.size) return
        incidents = active
        persist()
    }

    private fun persist() {
        val text = RoadIncident.encodeList(incidents)
        scope.launch {
            try {
                withContext(Dispatchers.IO) { RoadDataPersistence.write(filesDir, FILE, text) }
                if (lastError != null) lastError = null
            } catch (e: Exception) {
                lastError = L("incident.saveFailed", e.message ?: "")
            }
        }
    }
}
