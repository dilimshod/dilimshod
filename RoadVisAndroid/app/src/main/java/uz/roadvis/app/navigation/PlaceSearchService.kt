package uz.roadvis.app.navigation

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import uz.roadvis.app.app.LocationService
import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.app.roaddata.Http
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import java.net.URLEncoder
import java.util.Locale

/** A place to drive to (search result, recent, or a map point). */
data class Place(val name: String, val subtitle: String?, val coordinate: GeoPoint) {
    val id: String get() = String.format(Locale.US, "%.5f,%.5f|", coordinate.latitude, coordinate.longitude) + name
}

/**
 * Destination search with the free Photon geocoder (photon.komoot.io, OpenStreetMap data), biased to the user's
 * position, plus recent destinations (SharedPreferences, newest first, ≤ 8). Replaces Apple MKLocalSearch of iOS
 * `PlaceSearchService`. Typing is debounced (450 ms) to stay within Photon's fair-use expectations.
 */
class PlaceSearchService(context: Context, private val location: LocationService, private val scope: CoroutineScope) {
    companion object {
        const val PHOTON = "https://photon.komoot.io/api/"
        const val MAX_RECENTS = 8
        private const val RECENTS_KEY = "rv.recentDestinations"
        private const val DEBOUNCE_MS = 450L
    }

    private val prefs = context.getSharedPreferences("roadvis", Context.MODE_PRIVATE)

    var query by mutableStateOf(""); private set
    var results by mutableStateOf<List<Place>>(emptyList()); private set
    var isSearching by mutableStateOf(false); private set
    var errorMessage by mutableStateOf<String?>(null); private set
    var recents by mutableStateOf(loadRecents()); private set

    private var job: Job? = null

    fun updateQuery(text: String) {
        if (text == query) return
        query = text
        schedule(DEBOUNCE_MS)
    }

    /** Search now (keyboard «search» action). */
    fun submit() = schedule(0)

    fun reset() {
        job?.cancel(); job = null
        query = ""
        results = emptyList()
        isSearching = false
        errorMessage = null
    }

    private fun schedule(delayMs: Long) {
        job?.cancel()
        val text = query.trim()
        errorMessage = null
        if (text.isEmpty()) { results = emptyList(); isSearching = false; return }
        job = scope.launch {
            if (delayMs > 0) delay(delayMs)
            isSearching = true
            try {
                val found = photon(text)
                results = found
                if (found.isEmpty()) errorMessage = L("search.queryNotFound", text)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = when ((e as? Http.NetworkException)?.kind) {
                    Http.NetworkException.Kind.OFFLINE, Http.NetworkException.Kind.HOST_NOT_FOUND -> L("search.err.offline")
                    Http.NetworkException.Kind.TIMEOUT -> L("search.err.timeout")
                    null -> L("search.err.failed", e.message ?: "")
                    else -> L("search.err.network", e.message ?: "")
                }
            } finally {
                isSearching = false
            }
        }
    }

    private suspend fun photon(text: String): List<Place> {
        val sb = StringBuilder(PHOTON).append("?q=").append(URLEncoder.encode(text, "UTF-8")).append("&limit=12")
        location.coordinate?.takeIf { it.isValid }?.let {
            sb.append(String.format(Locale.US, "&lat=%.5f&lon=%.5f", it.latitude, it.longitude))
        }
        // Photon knows only a few languages; others get the local (default) names.
        if (LocalizationManager.language == AppLanguage.EN) sb.append("&lang=en")
        val response = Http.get(sb.toString(), timeoutMs = 15_000)
        if (response.status == 429) throw Exception(L("search.err.throttled"))
        if (response.status != 200) throw Exception(L("search.err.server"))
        val here = location.coordinate
        val features = JSONObject(response.text).optJSONArray("features") ?: return emptyList()
        val list = ArrayList<Place>()
        for (i in 0 until features.length()) {
            val f = features.optJSONObject(i) ?: continue
            val coords = f.optJSONObject("geometry")?.optJSONArray("coordinates") ?: continue
            val point = GeoPoint(coords.optDouble(1), coords.optDouble(0))
            if (!point.isValid) continue
            val p = f.optJSONObject("properties") ?: JSONObject()
            fun s(k: String) = p.optString(k, "").trim().ifEmpty { null }
            val street = listOfNotNull(s("street"), s("housenumber")).joinToString(" ").ifEmpty { null }
            val name = s("name") ?: street ?: s("city") ?: L("nav.mapPoint")
            val subtitle = listOfNotNull(if (street != name) street else null, s("locality"), s("district"), s("city") ?: s("county"), s("state"))
                .distinct().filter { it != name }.joinToString(", ").ifEmpty { null }
            list.add(Place(name, subtitle, point))
        }
        // Photon already biases by position; keep its order but drop exact duplicates.
        val seen = HashSet<String>()
        val unique = list.filter { seen.add(it.name + "|" + (it.subtitle ?: "")) }
        return if (here == null) unique else unique.sortedBy { if (Geo.distance(here, it.coordinate) > 300_000) 1 else 0 }
    }

    // Recents

    fun addRecent(place: Place) {
        if (!place.coordinate.isValid) return
        val list = recents.filterNot { it.name == place.name && Geo.distance(it.coordinate, place.coordinate) < 50 }.toMutableList()
        list.add(0, place)
        recents = list.take(MAX_RECENTS)
        saveRecents()
    }

    fun removeRecent(place: Place) {
        recents = recents.filterNot { it.id == place.id }
        saveRecents()
    }

    fun clearRecents() { recents = emptyList(); saveRecents() }

    private fun saveRecents() {
        val arr = JSONArray()
        recents.forEach {
            arr.put(JSONObject().put("name", it.name).put("subtitle", it.subtitle ?: JSONObject.NULL)
                .put("latitude", it.coordinate.latitude).put("longitude", it.coordinate.longitude)
                .put("date", System.currentTimeMillis()))
        }
        prefs.edit().putString(RECENTS_KEY, arr.toString()).apply()
    }

    private fun loadRecents(): List<Place> = try {
        val arr = JSONArray(prefs.getString(RECENTS_KEY, "[]") ?: "[]")
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.getJSONObject(i)
            val p = GeoPoint(o.getDouble("latitude"), o.getDouble("longitude"))
            if (!p.isValid) null else Place(o.getString("name"), o.optString("subtitle", "").ifEmpty { null }.takeIf { !o.isNull("subtitle") }, p)
        }.take(MAX_RECENTS)
    } catch (_: Exception) { emptyList() }
}
