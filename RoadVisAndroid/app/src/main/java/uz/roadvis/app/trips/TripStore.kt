package uz.roadvis.app.trips

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONObject
import uz.roadvis.app.l10n.L
import uz.roadvis.core.Trip
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Recorded trips, one JSON file per trip in `filesDir/trips/<id>.json` (port of iOS `TripStore`).
 * Reading and writing happen on one background thread; [trips] (Compose state) is sorted newest first.
 */
class TripStore(context: Context) {
    private val directory = File(context.filesDir, "trips")
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "TripStore").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private var loadStarted = false

    var trips by mutableStateOf<List<Trip>>(emptyList())
        private set
    var isLoaded by mutableStateOf(false)
        private set
    /** Description of the last load / write problem (non-fatal). */
    var lastError by mutableStateOf<String?>(null)
        private set

    private fun file(id: UUID): File = File(directory, "$id.json")

    /** Reads every trip file once (idempotent). */
    fun load() {
        if (loadStarted) return
        loadStarted = true
        io.execute {
            val loaded = mutableListOf<Trip>()
            var errors = 0
            directory.listFiles { f -> f.isFile && f.name.endsWith(".json", ignoreCase = true) }?.forEach { f ->
                try {
                    loaded += Trip.fromJson(JSONObject(f.readText()))
                } catch (_: Exception) {
                    errors++
                }
            }
            main.post {
                // Trips saved while loading (a just-finished recording) win over their file versions.
                val current = trips
                val merged = loaded.filter { l -> current.none { it.id == l.id } } + current
                trips = merged.sortedByDescending { it.startedAtMillis }
                isLoaded = true
                if (errors > 0) lastError = L("tripStore.readFailed", errors)
            }
        }
    }

    fun trip(id: String): Trip? = trips.firstOrNull { it.id.toString() == id }

    /** Inserts or replaces the trip and writes its file. */
    fun save(trip: Trip) {
        val list = trips.toMutableList()
        val i = list.indexOfFirst { it.id == trip.id }
        if (i >= 0) list[i] = trip else list += trip
        trips = list.sortedByDescending { it.startedAtMillis }
        persist(trip)
    }

    /** Writes the file only (in-progress autosave; the list is not touched). */
    fun persist(trip: Trip) {
        io.execute {
            try {
                directory.mkdirs()
                val target = file(trip.id)
                val tmp = File(directory, "${trip.id}.json.tmp")
                tmp.writeText(trip.toJson().toString())
                if (!tmp.renameTo(target)) {
                    target.delete()
                    if (!tmp.renameTo(target)) throw java.io.IOException("rename failed")
                }
            } catch (e: Exception) {
                main.post { lastError = L("tripStore.saveFailed", e.localizedMessage ?: e.toString()) }
            }
        }
    }

    fun delete(id: UUID) {
        trips = trips.filterNot { it.id == id }
        io.execute { file(id).delete() }
    }
}
