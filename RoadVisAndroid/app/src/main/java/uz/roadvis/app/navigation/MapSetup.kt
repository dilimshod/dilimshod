package uz.roadvis.app.navigation

import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import org.maplibre.android.MapLibre
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.offline.OfflineManager

/**
 * MapLibre setup shared by the navigator and the trip map: free OpenFreeMap vector styles (no API key), with an inline
 * CARTO Dark raster style as the fallback when the vector style cannot be loaded (no network, server error).
 */
object MapSetup {
    const val DARK_STYLE = "https://tiles.openfreemap.org/styles/dark"
    const val LIBERTY_STYLE = "https://tiles.openfreemap.org/styles/liberty"
    const val ATTRIBUTION_OPENFREEMAP = "© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors"
    const val ATTRIBUTION_CARTO = "© OpenStreetMap contributors © CARTO"

    /** Ambient tile / style cache: repeat drives reuse it instead of downloading again. */
    private const val CACHE_BYTES = 100L * 1024 * 1024

    private var configured = false

    /** Attribution of the navigator's current basemap (Compose state; changes when the fallback is in use). */
    private var navigatorAttribution by mutableStateOf(ATTRIBUTION_OPENFREEMAP)

    /** Credit line for the navigator map (read in composition, so it follows a switch to the fallback style). */
    val ATTRIBUTION: String get() = navigatorAttribution

    internal fun setNavigatorAttribution(value: String) { navigatorAttribution = value }

    /** Settings value → style URL: "osmStandard" is the light OpenFreeMap Liberty style, anything else dark. */
    fun styleUrl(mapStyle: String): String = if (mapStyle == "osmStandard") LIBERTY_STYLE else DARK_STYLE

    /** MapLibre must be initialised before the first MapView is inflated. Idempotent. */
    fun configure(context: Context) {
        if (configured) return
        configured = true
        val app = context.applicationContext
        MapLibre.getInstance(app)
        OfflineManager.getInstance(app).setMaximumAmbientCacheSize(CACHE_BYTES, null)
        // Free the tile cache of the old osmdroid map (up to 100 MB).
        Thread { runCatching { java.io.File(app.cacheDir, "osmdroid").deleteRecursively() } }.start()
    }

    /** CARTO Dark Matter raster tiles (@2x, shown at 256 dp so they stay sharp), © OpenStreetMap contributors © CARTO. */
    val FALLBACK_STYLE_JSON: String = run {
        val tiles = listOf("a", "b", "c", "d").joinToString(",") {
            "\"https://$it.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png\""
        }
        """{"version":8,"name":"CARTO Dark (fallback)",""" +
            """"sources":{"carto":{"type":"raster","tiles":[$tiles],"tileSize":256,"minzoom":0,"maxzoom":20,""" +
            """"attribution":"$ATTRIBUTION_CARTO"}},""" +
            """"layers":[{"id":"background","type":"background","paint":{"background-color":"#0E0E10"}},""" +
            """{"id":"carto","type":"raster","source":"carto"}]}"""
    }
}

/**
 * Loads a vector style into [map] and falls back to the CARTO raster style when it fails to load. [onStyle] is called
 * after every (re)load: a new style drops all runtime sources, layers and images, so the caller adds them again.
 */
class MapStyleLoader(
    view: MapView,
    private val map: MapLibreMap,
    private val onAttribution: (String) -> Unit,
    private val onStyle: (Style) -> Unit,
) {
    private var url: String? = null
    private var usingFallback = false
    private var failedAt = 0L
    /** The loaded style, or null while a style is loading. */
    var style: Style? = null
        private set

    init {
        view.addOnDidFailLoadingMapListener {
            // Only a failure before the vector style is up switches to the fallback (later tile errors do not).
            if (!usingFallback && style == null) {
                usingFallback = true
                failedAt = SystemClock.elapsedRealtime()
                onAttribution(MapSetup.ATTRIBUTION_CARTO)
                apply(Style.Builder().fromJson(MapSetup.FALLBACK_STYLE_JSON))
            }
        }
    }

    fun load(styleUrl: String) {
        if (styleUrl == url) return
        url = styleUrl
        usingFallback = false
        onAttribution(MapSetup.ATTRIBUTION_OPENFREEMAP)
        apply(Style.Builder().fromUri(styleUrl))
    }

    /** Try the vector style again (e.g. when the screen becomes visible) if the fallback has been on for a while. */
    fun retryIfFallback() {
        val u = url ?: return
        if (usingFallback && SystemClock.elapsedRealtime() - failedAt > 60_000) {
            url = null
            load(u)
        }
    }

    private fun apply(builder: Style.Builder) {
        style = null
        map.setStyle(builder) { s ->
            style = s
            onStyle(s)
        }
    }
}

/**
 * Forwards the screen lifecycle to a MapView (onCreate is called by the owner right after construction). On dispose the
 * view is stopped and destroyed according to how far it got.
 */
@Composable
fun MapViewLifecycle(view: MapView) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, view) {
        var started = false
        var resumed = false
        var destroyed = false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> if (!started && !destroyed) { started = true; view.onStart() }
                Lifecycle.Event.ON_RESUME -> if (!resumed && !destroyed) { resumed = true; view.onResume() }
                Lifecycle.Event.ON_PAUSE -> if (resumed) { resumed = false; view.onPause() }
                Lifecycle.Event.ON_STOP -> if (started) { started = false; view.onStop() }
                Lifecycle.Event.ON_DESTROY -> if (!destroyed) { destroyed = true; view.onDestroy() }
                else -> Unit
            }
        }
        val memory = object : ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) = Unit
            @Deprecated("Deprecated in Java")
            override fun onLowMemory() { if (!destroyed) view.onLowMemory() }
        }
        view.context.registerComponentCallbacks(memory)
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            view.context.unregisterComponentCallbacks(memory)
            if (resumed) view.onPause()
            if (started) view.onStop()
            if (!destroyed) view.onDestroy()
            destroyed = true
        }
    }
}
