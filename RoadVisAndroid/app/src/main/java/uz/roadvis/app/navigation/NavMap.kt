package uz.roadvis.app.navigation

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Point
import android.view.MotionEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import org.osmdroid.config.Configuration
import org.osmdroid.events.MapEventsReceiver
import org.osmdroid.tileprovider.tilesource.XYTileSource
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.MapTileIndex
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.Projection
import org.osmdroid.views.overlay.MapEventsOverlay
import org.osmdroid.views.overlay.Overlay
import org.osmdroid.views.overlay.Polyline
import uz.roadvis.app.roaddata.Http
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.SpeedLimitSegment
import java.io.File
import kotlin.math.max
import org.osmdroid.util.GeoPoint as OGeoPoint

/** osmdroid configuration and the CARTO Dark tile source (free basemap, © OpenStreetMap contributors © CARTO). */
object MapSetup {
    const val ATTRIBUTION = "© OpenStreetMap contributors © CARTO"
    private var configured = false

    fun configure(context: Context) {
        if (configured) return
        configured = true
        val c = Configuration.getInstance()
        c.userAgentValue = Http.USER_AGENT
        val base = File(context.cacheDir, "osmdroid")
        c.osmdroidBasePath = base
        c.osmdroidTileCache = File(base, "tiles")
        c.tileFileSystemCacheMaxBytes = 100L * 1024 * 1024
        c.tileFileSystemCacheTrimBytes = 80L * 1024 * 1024
        c.expirationOverrideDuration = 7L * 24 * 3600 * 1000
    }

    /** `https://{a-d}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{scale}.png`; @2x on dense screens. */
    fun cartoDark(retina: Boolean) = object : XYTileSource(
        if (retina) "CartoDark@2x" else "CartoDark", 0, 20, 256, ".png",
        arrayOf("a", "b", "c", "d").map { "https://$it.basemaps.cartocdn.com/dark_all/" }.toTypedArray(),
        ATTRIBUTION,
    ) {
        override fun getTileURLString(pMapTileIndex: Long): String =
            baseUrl + MapTileIndex.getZoom(pMapTileIndex) + "/" + MapTileIndex.getX(pMapTileIndex) + "/" +
                MapTileIndex.getY(pMapTileIndex) + (if (retina) "@2x" else "") + mImageFilenameEnding
    }
}

/** One point drawn on the map (timeline event, own mark, nearby signal, destination). */
data class MapItem(
    val key: String,
    val point: GeoPoint,
    val glyph: String,
    val color: Color,
    val title: String,
    val subtitle: String?,
    /** Shown already at low zoom (destination, cameras, incidents). */
    val important: Boolean = false,
    /** Small dot instead of a badge (maneuver points). */
    val small: Boolean = false,
)

enum class CameraMode { IDLE, OVERVIEW, NAVIGATING }

/** Route polyline to draw. */
data class MapRoute(val id: Int, val polyline: List<GeoPoint>, val selected: Boolean)

private fun GeoPoint.o() = OGeoPoint(latitude, longitude)

/** Draws [MapItem]s as coloured badges with a glyph; tap → [onTap]. */
private class ItemsOverlay(private val density: Float) : Overlay() {
    var items: List<MapItem> = emptyList()
    var onTap: ((MapItem) -> Unit)? = null
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = android.graphics.Color.WHITE; strokeWidth = 1.5f * density }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textAlign = Paint.Align.CENTER; isFakeBoldText = true }
    private val pt = Point()

    private fun radius(item: MapItem) = (if (item.small) 5f else 12f) * density

    override fun draw(canvas: Canvas, projection: Projection) {
        val zoom = projection.zoomLevel
        val w = canvas.width; val h = canvas.height
        for (item in visible(zoom)) {
            projection.toPixels(item.point.o(), pt)
            val r = radius(item)
            if (pt.x < -r || pt.y < -r || pt.x > w + r || pt.y > h + r) continue
            fill.color = item.color.toArgb()
            canvas.drawCircle(pt.x.toFloat(), pt.y.toFloat(), r, fill)
            canvas.drawCircle(pt.x.toFloat(), pt.y.toFloat(), r, stroke)
            if (!item.small) {
                text.textSize = (if (item.glyph.length > 2) 9f else 12f) * density
                val y = pt.y - (text.descent() + text.ascent()) / 2
                canvas.drawText(item.glyph, pt.x.toFloat(), y, text)
            }
        }
    }

    private fun visible(zoom: Double): List<MapItem> = when {
        zoom >= 14.5 -> items
        zoom >= 12.5 -> items.filter { it.important || !it.small }
        else -> items.filter { it.important }
    }

    override fun onSingleTapConfirmed(e: MotionEvent, mapView: MapView): Boolean {
        val projection = mapView.projection
        var best: MapItem? = null
        var bestD = Float.MAX_VALUE
        for (item in visible(projection.zoomLevel)) {
            projection.toPixels(item.point.o(), pt)
            val dx = pt.x - e.x; val dy = pt.y - e.y
            val d = dx * dx + dy * dy
            val r = max(radius(item), 18f * density)
            if (d <= r * r && d < bestD) { bestD = d; best = item }
        }
        val hit = best ?: return false
        onTap?.invoke(hit)
        return true
    }
}

/** User position (blue dot with accuracy halo) and travel direction arrow. */
private class UserOverlay(private val density: Float) : Overlay() {
    var position: GeoPoint? = null
    var accuracy: Float = 0f
    var course: Double? = null
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF1A7AFF.toInt() }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 3f * density }
    private val halo = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x331A7AFF }
    private val arrow = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF1A7AFF.toInt() }
    private val pt = Point()

    override fun draw(canvas: Canvas, projection: Projection) {
        val p = position ?: return
        projection.toPixels(p.o(), pt)
        val x = pt.x.toFloat(); val y = pt.y.toFloat()
        if (accuracy > 15) {
            val r = projection.metersToPixels(accuracy)
            if (r > 0) canvas.drawCircle(x, y, r, halo)
        }
        course?.let { c ->
            // Arrow ahead of the dot, rotated with the map orientation.
            val angle = Math.toRadians(c + projection.orientation)
            val tip = 22f * density; val side = 8f * density
            val path = Path()
            val sin = kotlin.math.sin(angle).toFloat(); val cos = kotlin.math.cos(angle).toFloat()
            path.moveTo(x + sin * tip, y - cos * tip)
            path.lineTo(x + cos * side, y + sin * side)
            path.lineTo(x - cos * side, y - sin * side)
            path.close()
            canvas.drawPath(path, arrow)
        }
        canvas.drawCircle(x, y, 8f * density, dot)
        canvas.drawCircle(x, y, 8f * density, ring)
    }
}

/** Holds the MapView and its overlays across recompositions; applies state diffs. */
private class MapHolder(context: Context) {
    val density = context.resources.displayMetrics.density
    val map = MapView(context)
    private val itemsOverlay = ItemsOverlay(density)
    private val userOverlay = UserOverlay(density)
    private val routeLines = ArrayList<Polyline>()
    private var routeSignature = ""
    private var itemSignature = ""
    var onUserGesture: (() -> Unit)? = null
    var onSelectRoute: ((Int) -> Unit)? = null
    var onLongPress: ((GeoPoint) -> Unit)? = null
    var onTapItem: ((MapItem) -> Unit)? = null
    var onTapEmpty: (() -> Unit)? = null
    private var lastMode: CameraMode? = null
    private var lastFollowing = false
    private var fittedSignature = ""
    var wasActive = true
    private var initialCentered = false

    init {
        map.setTileSource(MapSetup.cartoDark(density >= 2f))
        map.isTilesScaledToDpi = density < 2f
        map.setMultiTouchControls(true)
        map.zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
        map.minZoomLevel = 3.0
        map.maxZoomLevel = 19.5
        map.isVerticalMapRepetitionEnabled = false
        map.setBackgroundColor(0xFF0E0E10.toInt())
        map.overlayManager.tilesOverlay.loadingBackgroundColor = 0xFF101216.toInt()
        map.overlayManager.tilesOverlay.loadingLineColor = 0xFF1A1D22.toInt()
        map.controller.setZoom(12.0)
        map.controller.setCenter(OGeoPoint(41.3111, 69.2797))   // Tashkent
        val events = MapEventsOverlay(object : MapEventsReceiver {
            override fun singleTapConfirmedHelper(p: OGeoPoint): Boolean { onTapEmpty?.invoke(); return false }
            override fun longPressHelper(p: OGeoPoint): Boolean {
                onLongPress?.invoke(GeoPoint(p.latitude, p.longitude)); return true
            }
        })
        map.overlays.add(events)
        map.overlays.add(itemsOverlay)
        map.overlays.add(userOverlay)
        itemsOverlay.onTap = { onTapItem?.invoke(it) }
        @SuppressLint("ClickableViewAccessibility")
        map.setOnTouchListener { _, ev ->
            if (ev.actionMasked == MotionEvent.ACTION_MOVE || ev.pointerCount > 1) onUserGesture?.invoke()
            false
        }
    }

    fun setRoutes(routes: List<MapRoute>, segments: List<SpeedLimitSegment>) {
        val signature = routes.joinToString("|") { "${it.id}:${it.selected}:${it.polyline.size}:${it.polyline.firstOrNull()}" } +
            "#" + segments.joinToString(",") { "${it.limitKmh}:${it.end.toInt()}" }
        if (signature == routeSignature) return
        routeSignature = signature
        map.overlays.removeAll(routeLines.toSet())
        routeLines.clear()
        val ordered = routes.sortedBy { it.selected }   // alternatives below, selected on top
        for (route in ordered) {
            val points = route.polyline.map { it.o() }
            if (points.size < 2) continue
            if (!route.selected) {
                routeLines += line(points, 0xFF5A6B85.toInt(), 7f, route.id)
                continue
            }
            routeLines += line(points, 0xFF06301F.toInt(), 11f, route.id)                  // casing
            if (segments.isEmpty()) {
                routeLines += line(points, 0xFF30EB9E.toInt(), 6.5f, route.id)
            } else {
                routeLines += line(points, NavStyle.speedLimitColor(null).toArgb(), 6.5f, route.id)
                val cumulative = Geo.cumulativeDistances(route.polyline)
                for (s in segments) {
                    if (s.limitKmh == null) continue
                    val part = slice(route.polyline, cumulative, s.start, s.end)
                    if (part.size >= 2) routeLines += line(part.map { it.o() }, NavStyle.speedLimitColor(s.limitKmh).toArgb(), 6.5f, route.id)
                }
            }
        }
        // Routes go right above the event receiver (index 0), below markers and the user dot.
        map.overlays.addAll(1, routeLines)
        map.invalidate()
    }

    private fun line(points: List<OGeoPoint>, color: Int, widthDp: Float, id: Int): Polyline = Polyline(map).apply {
        setPoints(points)
        outlinePaint.color = color
        outlinePaint.strokeWidth = widthDp * density
        outlinePaint.strokeCap = Paint.Cap.ROUND
        outlinePaint.strokeJoin = Paint.Join.ROUND
        infoWindow = null
        setOnClickListener { _, _, _ -> onSelectRoute?.invoke(id); true }
    }

    private fun slice(points: List<GeoPoint>, cumulative: List<Double>, start: Double, end: Double): List<GeoPoint> {
        val result = ArrayList<GeoPoint>()
        Geo.pointAtDistance(start, points, cumulative)?.let { result.add(it) }
        for (i in points.indices) if (cumulative[i] > start && cumulative[i] < end) result.add(points[i])
        Geo.pointAtDistance(end, points, cumulative)?.let { result.add(it) }
        return result
    }

    fun setItems(items: List<MapItem>) {
        val signature = items.joinToString("|") { it.key }
        if (signature == itemSignature) return
        itemSignature = signature
        itemsOverlay.items = items
        map.invalidate()
    }

    fun setUser(position: GeoPoint?, accuracy: Float, course: Double?) {
        userOverlay.position = position
        userOverlay.accuracy = accuracy
        userOverlay.course = course
        map.invalidate()
    }

    fun updateCamera(mode: CameraMode, following: Boolean, user: GeoPoint?, course: Double?, routes: List<MapRoute>) {
        val modeChanged = mode != lastMode
        val followingResumed = following && !lastFollowing
        lastMode = mode
        lastFollowing = following
        when (mode) {
            CameraMode.IDLE -> {
                if (map.mapOrientation != 0f) map.mapOrientation = 0f
                if (modeChanged) map.setMapCenterOffset(0, 0)
                if (following && user != null) {
                    if (!initialCentered || modeChanged || followingResumed) {
                        initialCentered = true
                        map.controller.animateTo(user.o(), max(map.zoomLevelDouble, 15.5), 600L)
                    } else {
                        map.controller.animateTo(user.o())
                    }
                }
                if (modeChanged) fittedSignature = ""
            }
            CameraMode.OVERVIEW -> {
                if (map.mapOrientation != 0f) map.mapOrientation = 0f
                val signature = routes.joinToString("|") { "${it.id}:${it.polyline.size}" }
                if ((signature != fittedSignature || followingResumed) && map.width > 0 && map.height > 0) {
                    val all = routes.flatMap { it.polyline }
                    val box = Geo.boundingBox(all, 0.0) ?: return
                    fittedSignature = signature
                    // The route options panel covers the lower half: stretch the box downwards so the routes
                    // end up in the visible upper part of the map.
                    val span = box.north - box.south
                    val bb = BoundingBox(box.north + span * 0.25, box.east, box.south - span * 1.1, box.west)
                    map.setMapCenterOffset(0, 0)
                    map.zoomToBoundingBox(bb.increaseByScale(1.1f), true, (map.width * 0.08).toInt())
                }
            }
            CameraMode.NAVIGATING -> {
                if (!following || user == null) return
                // Keep the car in the lower third so more of the road ahead is visible.
                if (modeChanged) map.setMapCenterOffset(0, (map.height * 0.18).toInt())
                val zoom = if (modeChanged || followingResumed) 17.0 else map.zoomLevelDouble
                course?.let { map.mapOrientation = (-it).toFloat() }
                map.controller.animateTo(user.o(), zoom, if (modeChanged || followingResumed) 600L else 900L)
            }
        }
    }

    /** After the navigator becomes visible again: jump instead of animating a long way. */
    fun snap(user: GeoPoint?) {
        if (user != null && lastFollowing && lastMode != CameraMode.OVERVIEW) map.controller.setCenter(user.o())
    }
}

/**
 * osmdroid map in Compose: CARTO Dark tiles, routes (selected one coloured by speed limit), markers, user position.
 * With [isActive] false the overlays still update, but the camera is not animated (the screen is hidden).
 */
@Composable
fun NavMap(
    modifier: Modifier,
    isActive: Boolean,
    mode: CameraMode,
    following: Boolean,
    routes: List<MapRoute>,
    segments: List<SpeedLimitSegment>,
    items: List<MapItem>,
    user: GeoPoint?,
    accuracy: Float,
    course: Double?,
    onUserGesture: () -> Unit,
    onSelectRoute: (Int) -> Unit,
    onLongPress: (GeoPoint) -> Unit,
    onTapItem: (MapItem) -> Unit,
    onTapEmpty: () -> Unit,
) {
    val context = LocalContext.current
    val holder = remember { MapSetup.configure(context); MapHolder(context) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> holder.map.onResume()
                Lifecycle.Event.ON_PAUSE -> holder.map.onPause()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); holder.map.onDetach() }
    }
    holder.onUserGesture = onUserGesture
    holder.onSelectRoute = onSelectRoute
    holder.onLongPress = onLongPress
    holder.onTapItem = onTapItem
    holder.onTapEmpty = onTapEmpty
    AndroidView(factory = { holder.map }, modifier = modifier, update = {
        holder.setRoutes(routes, segments)
        holder.setItems(items)
        holder.setUser(user, accuracy, if (mode == CameraMode.NAVIGATING || (course != null)) course else null)
        val becameActive = isActive && !holder.wasActive
        holder.wasActive = isActive
        if (isActive) {
            if (becameActive) holder.snap(user)
            holder.updateCamera(mode, following, user, course, routes)
        }
    })
}
