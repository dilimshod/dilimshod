package uz.roadvis.app.navigation

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import uz.roadvis.core.Geo
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.SpeedLimitSegment
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.pow

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

private fun GeoPoint.ll() = LatLng(latitude, longitude)
private fun GeoPoint.pt(): Point = Point.fromLngLat(longitude, latitude)

/** ARGB → CSS colour string for data-driven `to-color`. */
internal fun cssColor(argb: Int): String {
    val a = (argb ushr 24 and 0xFF) / 255.0
    return "rgba(${argb shr 16 and 0xFF},${argb shr 8 and 0xFF},${argb and 0xFF},${"%.3f".format(java.util.Locale.US, a)})"
}

/** Ids of the runtime sources / layers the navigator adds on top of the basemap. */
private object Ids {
    const val ROUTES = "rv-routes"
    const val ITEMS = "rv-items"
    const val USER = "rv-user"
    const val ROUTE_ALT = "rv-route-alt"
    const val ROUTE_CASING = "rv-route-casing"
    const val ROUTE_MAIN = "rv-route-main"
    const val ITEMS_SMALL = "rv-items-small"
    const val ITEMS_BADGE = "rv-items-badge"
    const val ITEMS_IMPORTANT = "rv-items-important"
    const val USER_HALO = "rv-user-halo"
    const val USER_ARROW = "rv-user-arrow"
    const val USER_DOT = "rv-user-dot"
    const val ARROW_ICON = "rv-arrow"
    val ROUTE_LAYERS = arrayOf(ROUTE_MAIN, ROUTE_CASING, ROUTE_ALT)
    val ITEM_LAYERS = arrayOf(ITEMS_IMPORTANT, ITEMS_BADGE, ITEMS_SMALL)
}

// MapLibre zoom levels use 512-px tiles: one level below the old 256-px raster map for the same scale.
private const val ZOOM_ALL_ITEMS = 13.5f
private const val ZOOM_BADGES = 11.5f
private const val ZOOM_FOLLOW_MIN = 14.5
private const val ZOOM_NAVIGATING = 16.0
private val TASHKENT = LatLng(41.3111, 69.2797)

/** Badge bitmaps for [MapItem]s (coloured circle, white ring, glyph), keyed by look. */
private class ItemIcons(private val density: Float) {
    private val cache = HashMap<String, Bitmap>()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = android.graphics.Color.WHITE; strokeWidth = 1.5f * density }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; textAlign = Paint.Align.CENTER; isFakeBoldText = true }

    fun name(item: MapItem): String =
        if (item.small) "rv-dot-${item.color.toArgb()}" else "rv-badge-${item.color.toArgb()}-${item.glyph}"

    fun bitmap(item: MapItem): Bitmap = cache.getOrPut(name(item)) {
        val r = (if (item.small) 5f else 12f) * density
        val half = r + stroke.strokeWidth
        val size = kotlin.math.ceil(half * 2).toInt()
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val cx = size / 2f
        fill.color = item.color.toArgb()
        c.drawCircle(cx, cx, r, fill)
        c.drawCircle(cx, cx, r, stroke)
        if (!item.small) {
            text.textSize = (if (item.glyph.length > 2) 9f else 12f) * density
            c.drawText(item.glyph, cx, cx - (text.descent() + text.ascent()) / 2, text)
        }
        bmp
    }

    /** Travel-direction arrow (points up; rotated by the course): tip 22 dp ahead of the dot centre. */
    fun arrow(): Bitmap {
        val tip = 22f * density; val side = 8f * density
        val size = kotlin.math.ceil(tip * 2).toInt()
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = size / 2f
        val path = Path().apply {
            moveTo(c, c - tip); lineTo(c + side, c); lineTo(c - side, c); close()
        }
        Canvas(bmp).drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF1A7AFF.toInt() })
        return bmp
    }
}

/** Holds the MapView, its runtime sources and the latest data across recompositions and style reloads. */
private class MapHolder(context: Context) {
    val density = context.resources.displayMetrics.density
    val view: MapView
    private var map: MapLibreMap? = null
    private var loader: MapStyleLoader? = null
    private val icons = ItemIcons(density)
    private val addedIcons = HashSet<String>()

    private var routeData: FeatureCollection = FeatureCollection.fromFeatures(emptyList())
    private var itemData: FeatureCollection = FeatureCollection.fromFeatures(emptyList())
    private var userData: FeatureCollection = FeatureCollection.fromFeatures(emptyList())
    private var items: List<MapItem> = emptyList()
    private var itemsByKey: Map<String, MapItem> = emptyMap()
    private var userAccuracy = 0f
    private var userLat = 0.0
    private var routeSignature = ""
    private var itemSignature = ""
    private var userSignature = ""
    private var pendingStyleUrl: String? = null

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
    /** Camera work requested before the map was ready, replayed once it is. */
    private var pendingCamera: (() -> Unit)? = null

    init {
        MapSetup.configure(context)
        val options = MapLibreMapOptions.createFromAttributes(context)
            // TextureView: the navigator is faded with Compose alpha / z-order (RootScreen), a SurfaceView ignores both.
            .textureMode(true)
            .foregroundLoadColor(0xFF0E0E10.toInt())
            .camera(CameraPosition.Builder().target(TASHKENT).zoom(11.0).build())
            .minZoomPreference(2.0)
            .maxZoomPreference(19.0)
            .attributionEnabled(false)   // credits are shown by NavigatorScreen (MapSetup.ATTRIBUTION)
            .logoEnabled(false)
            .compassEnabled(false)
            .rotateGesturesEnabled(false)
            .tiltGesturesEnabled(false)
        view = MapView(context, options)
        view.setBackgroundColor(0xFF0E0E10.toInt())
        view.onCreate(null)
        view.getMapAsync { m ->
            map = m
            loader = MapStyleLoader(view, m, MapSetup::setNavigatorAttribution) { style -> installLayers(style) }
            m.addOnMapClickListener { ll -> handleTap(m, ll); true }
            m.addOnMapLongClickListener { ll -> onLongPress?.invoke(GeoPoint(ll.latitude, ll.longitude)); true }
            m.addOnCameraMoveStartedListener { reason ->
                if (reason == MapLibreMap.OnCameraMoveStartedListener.REASON_API_GESTURE) onUserGesture?.invoke()
            }
            pendingStyleUrl?.let { loader?.load(it) }
            pendingCamera?.invoke()
            pendingCamera = null
        }
    }

    fun setStyleUrl(url: String) {
        val l = loader
        if (l == null) pendingStyleUrl = url else l.load(url)
    }

    fun retryStyle() { loader?.retryIfFallback() }

    // ---- Style ----------------------------------------------------------------------------------------------------

    private fun installLayers(style: Style) {
        addedIcons.clear()
        style.addImage(Ids.ARROW_ICON, icons.arrow())
        style.addSource(GeoJsonSource(Ids.ROUTES, routeData))
        style.addSource(GeoJsonSource(Ids.ITEMS, itemData))
        style.addSource(GeoJsonSource(Ids.USER, userData))
        val round = arrayOf(
            PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
            PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
        )
        // Alternatives below, the selected route (dark casing + speed-limit coloured line) on top.
        style.addLayer(LineLayer(Ids.ROUTE_ALT, Ids.ROUTES)
            .withFilter(Expression.eq(Expression.get("kind"), "alt"))
            .withProperties(*round, PropertyFactory.lineColor(cssColor(0xFF5A6B85.toInt())), PropertyFactory.lineWidth(7f)))
        style.addLayer(LineLayer(Ids.ROUTE_CASING, Ids.ROUTES)
            .withFilter(Expression.eq(Expression.get("kind"), "casing"))
            .withProperties(*round, PropertyFactory.lineColor(cssColor(0xFF06301F.toInt())), PropertyFactory.lineWidth(11f)))
        style.addLayer(LineLayer(Ids.ROUTE_MAIN, Ids.ROUTES)
            .withFilter(Expression.eq(Expression.get("kind"), "main"))
            .withProperties(*round,
                PropertyFactory.lineColor(Expression.toColor(Expression.get("color"))),
                PropertyFactory.lineWidth(6.5f),
                PropertyFactory.lineSortKey(Expression.get("z"))))
        // Markers: small dots only close up, badges from mid zoom, important ones always.
        fun itemLayer(id: String, tier: Int, minZoom: Float?) = SymbolLayer(id, Ids.ITEMS)
            .withFilter(Expression.eq(Expression.get("tier"), tier))
            .withProperties(
                PropertyFactory.iconImage(Expression.get("icon")),
                PropertyFactory.iconAllowOverlap(true),
                PropertyFactory.iconIgnorePlacement(true),
                PropertyFactory.symbolZOrder(Property.SYMBOL_Z_ORDER_SOURCE),
                PropertyFactory.symbolSortKey(Expression.get("z")),
            ).also { layer -> minZoom?.let { layer.setMinZoom(it) } }
        style.addLayer(itemLayer(Ids.ITEMS_SMALL, 2, ZOOM_ALL_ITEMS))
        style.addLayer(itemLayer(Ids.ITEMS_BADGE, 1, ZOOM_BADGES))
        style.addLayer(itemLayer(Ids.ITEMS_IMPORTANT, 0, null))
        // User: accuracy halo, direction arrow, blue dot with white ring.
        style.addLayer(CircleLayer(Ids.USER_HALO, Ids.USER).withProperties(
            PropertyFactory.circleColor(cssColor(0x331A7AFF)),
            PropertyFactory.circleRadius(haloRadius()),
            PropertyFactory.circlePitchAlignment(Property.CIRCLE_PITCH_ALIGNMENT_MAP),
        ))
        style.addLayer(SymbolLayer(Ids.USER_ARROW, Ids.USER)
            .withFilter(Expression.has("course"))
            .withProperties(
                PropertyFactory.iconImage(Ids.ARROW_ICON),
                PropertyFactory.iconRotate(Expression.get("course")),
                PropertyFactory.iconRotationAlignment(Property.ICON_ROTATION_ALIGNMENT_MAP),
                PropertyFactory.iconAllowOverlap(true),
                PropertyFactory.iconIgnorePlacement(true),
            ))
        style.addLayer(CircleLayer(Ids.USER_DOT, Ids.USER).withProperties(
            PropertyFactory.circleColor(cssColor(0xFF1A7AFF.toInt())),
            PropertyFactory.circleRadius(8f),
            PropertyFactory.circleStrokeColor(cssColor(android.graphics.Color.WHITE)),
            PropertyFactory.circleStrokeWidth(3f),
        ))
        addItemIcons(style)
    }

    private fun source(id: String): GeoJsonSource? = loader?.style?.getSourceAs(id)

    private fun addItemIcons(style: Style) {
        for (item in items) {
            val name = icons.name(item)
            if (addedIcons.add(name)) style.addImage(name, icons.bitmap(item))
        }
    }

    /** Halo radius in dp as a zoom expression: [userAccuracy] metres at the user's latitude (512-px world). */
    private fun haloRadius(): Expression {
        val acc = if (userAccuracy > 15) userAccuracy.toDouble() else 0.0
        val metersPerDpZ0 = 40_075_016.686 * cos(Math.toRadians(userLat)) / 512.0
        val r0 = if (metersPerDpZ0 > 0) acc / metersPerDpZ0 else 0.0
        return Expression.interpolate(Expression.exponential(2), Expression.zoom(),
            Expression.stop(0, r0), Expression.stop(22, r0 * 2.0.pow(22)))
    }

    // ---- Data -----------------------------------------------------------------------------------------------------

    fun setRoutes(routes: List<MapRoute>, segments: List<SpeedLimitSegment>) {
        val signature = routes.joinToString("|") { "${it.id}:${it.selected}:${it.polyline.size}:${it.polyline.firstOrNull()}" } +
            "#" + segments.joinToString(",") { "${it.limitKmh}:${it.end.toInt()}" }
        if (signature == routeSignature) return
        routeSignature = signature
        val features = ArrayList<Feature>()
        for (route in routes) {
            if (route.polyline.size < 2) continue
            val line = LineString.fromLngLats(route.polyline.map { it.pt() })
            if (!route.selected) {
                features += feature(line, route.id, "alt", null, 0)
                continue
            }
            features += feature(line, route.id, "casing", null, 0)
            if (segments.isEmpty()) {
                features += feature(line, route.id, "main", 0xFF30EB9E.toInt(), 0)
            } else {
                features += feature(line, route.id, "main", NavStyle.speedLimitColor(null).toArgb(), 0)
                val cumulative = Geo.cumulativeDistances(route.polyline)
                for (s in segments) {
                    if (s.limitKmh == null) continue
                    val part = slice(route.polyline, cumulative, s.start, s.end)
                    if (part.size >= 2) {
                        features += feature(LineString.fromLngLats(part.map { it.pt() }), route.id, "main",
                            NavStyle.speedLimitColor(s.limitKmh).toArgb(), 1)
                    }
                }
            }
        }
        routeData = FeatureCollection.fromFeatures(features)
        source(Ids.ROUTES)?.setGeoJson(routeData)
    }

    private fun feature(line: LineString, id: Int, kind: String, color: Int?, z: Int): Feature =
        Feature.fromGeometry(line).apply {
            addNumberProperty("id", id)
            addStringProperty("kind", kind)
            if (color != null) addStringProperty("color", cssColor(color))
            addNumberProperty("z", z)
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
        this.items = items
        itemsByKey = items.associateBy { it.key }
        itemData = FeatureCollection.fromFeatures(items.mapIndexed { index, item ->
            Feature.fromGeometry(item.point.pt()).apply {
                addStringProperty("key", item.key)
                addStringProperty("icon", icons.name(item))
                addNumberProperty("tier", if (item.important) 0 else if (!item.small) 1 else 2)
                addNumberProperty("z", index)
            }
        })
        loader?.style?.let { addItemIcons(it) }
        source(Ids.ITEMS)?.setGeoJson(itemData)
    }

    fun setUser(position: GeoPoint?, accuracy: Float, course: Double?) {
        val signature = "$position|$accuracy|$course|${loader?.style != null}"
        if (signature == userSignature) return
        userSignature = signature
        val accuracyChanged = accuracy != userAccuracy || (position != null && kotlin.math.abs(position.latitude - userLat) > 0.05)
        userAccuracy = accuracy
        if (position != null) userLat = position.latitude
        userData = if (position == null) FeatureCollection.fromFeatures(emptyList()) else
            FeatureCollection.fromFeature(Feature.fromGeometry(position.pt()).apply {
                if (course != null) addNumberProperty("course", course)
            })
        val style = loader?.style ?: return
        style.getSourceAs<GeoJsonSource>(Ids.USER)?.setGeoJson(userData)
        if (accuracyChanged) style.getLayer(Ids.USER_HALO)?.setProperties(PropertyFactory.circleRadius(haloRadius()))
    }

    // ---- Interaction ----------------------------------------------------------------------------------------------

    /** Marker first (nearest within 18 dp), then a route line, else an empty-map tap. */
    private fun handleTap(m: MapLibreMap, ll: LatLng) {
        val p = m.projection.toScreenLocation(ll)
        val r = 18f * density
        val hits = m.queryRenderedFeatures(RectF(p.x - r, p.y - r, p.x + r, p.y + r), *Ids.ITEM_LAYERS)
        var best: MapItem? = null
        var bestD = Float.MAX_VALUE
        for (f in hits) {
            val item = f.getStringProperty("key")?.let { itemsByKey[it] } ?: continue
            val s = m.projection.toScreenLocation(item.point.ll())
            val d = (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y)
            if (d < bestD) { bestD = d; best = item }
        }
        best?.let { onTapItem?.invoke(it); return }
        val lr = 12f * density
        val lines = m.queryRenderedFeatures(RectF(p.x - lr, p.y - lr, p.x + lr, p.y + lr), *Ids.ROUTE_LAYERS)
        val routeId = lines.firstNotNullOfOrNull { f -> f.getNumberProperty("id")?.toInt() }
        if (routeId != null) { onSelectRoute?.invoke(routeId); return }
        onTapEmpty?.invoke()
    }

    // ---- Camera ---------------------------------------------------------------------------------------------------

    private fun position(target: LatLng, zoom: Double, bearing: Double, topPadding: Double) =
        CameraPosition.Builder().target(target).zoom(zoom).bearing(bearing).tilt(0.0)
            .padding(0.0, topPadding, 0.0, 0.0).build()

    fun updateCamera(mode: CameraMode, following: Boolean, user: GeoPoint?, course: Double?, routes: List<MapRoute>) {
        val m = map
        if (m == null) {
            pendingCamera = { updateCamera(mode, following, user, course, routes) }
            return
        }
        val modeChanged = mode != lastMode
        val followingResumed = following && !lastFollowing
        lastMode = mode
        lastFollowing = following
        val current = m.cameraPosition
        when (mode) {
            CameraMode.IDLE -> {
                if (modeChanged) fittedSignature = ""
                if (following && user != null) {
                    if (!initialCentered || modeChanged || followingResumed) {
                        initialCentered = true
                        m.animateCamera(CameraUpdateFactory.newCameraPosition(
                            position(user.ll(), max(current.zoom, ZOOM_FOLLOW_MIN), 0.0, 0.0)), 600)
                    } else {
                        m.animateCamera(CameraUpdateFactory.newCameraPosition(position(user.ll(), current.zoom, 0.0, 0.0)), 800)
                    }
                } else if (modeChanged || current.bearing != 0.0) {
                    current.target?.let { m.moveCamera(CameraUpdateFactory.newCameraPosition(position(it, current.zoom, 0.0, 0.0))) }
                }
            }
            CameraMode.OVERVIEW -> {
                if (modeChanged) fittedSignature = ""
                val signature = routes.joinToString("|") { "${it.id}:${it.polyline.size}" }
                if ((signature != fittedSignature || followingResumed) && view.width > 0 && view.height > 0) {
                    val all = routes.flatMap { it.polyline }
                    val box = Geo.boundingBox(all, 0.0) ?: return
                    fittedSignature = signature
                    // The route options panel covers the lower half: stretch the box downwards so the routes
                    // end up in the visible upper part of the map.
                    val span = max(box.north - box.south, 0.002)
                    val north = (box.north + span * 0.25).coerceAtMost(85.0)
                    val south = (box.south - span * 1.1).coerceAtLeast(-85.0)
                    val east = max(box.east, box.west + 0.002)
                    val bounds = LatLngBounds.from(north, east, south, box.west)
                    val pad = (view.width * 0.08).toInt()
                    val fit = m.getCameraForLatLngBounds(bounds, intArrayOf(pad, pad, pad, pad), 0.0, 0.0) ?: return
                    val target = fit.target ?: return
                    m.animateCamera(CameraUpdateFactory.newCameraPosition(position(target, fit.zoom, 0.0, 0.0)), 800)
                }
            }
            CameraMode.NAVIGATING -> {
                if (!following || user == null) return
                // Keep the car in the lower third (top padding shifts the centre down) so more road ahead is visible.
                val top = view.height * 0.36
                val zoom = if (modeChanged || followingResumed) ZOOM_NAVIGATING else current.zoom
                val bearing = course ?: current.bearing
                m.animateCamera(CameraUpdateFactory.newCameraPosition(position(user.ll(), zoom, bearing, top)),
                    if (modeChanged || followingResumed) 600 else 900)
            }
        }
    }

    /** After the navigator becomes visible again: jump instead of animating a long way. */
    fun snap(user: GeoPoint?) {
        val m = map ?: return
        if (user == null || !lastFollowing || lastMode == CameraMode.OVERVIEW) return
        val c = m.cameraPosition
        m.moveCamera(CameraUpdateFactory.newCameraPosition(CameraPosition.Builder(c).target(user.ll()).build()))
    }
}

/**
 * MapLibre map in Compose: OpenFreeMap vector basemap (CARTO raster fallback), routes (selected one coloured by speed
 * limit), markers, user position. With [isActive] false the data still updates, but the camera is not animated (the
 * screen is hidden); the map itself is never re-created on a mode switch.
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
    mapStyle: String = "cartoDark",
) {
    val context = LocalContext.current
    val holder = remember { MapHolder(context) }
    MapViewLifecycle(holder.view)
    holder.onUserGesture = onUserGesture
    holder.onSelectRoute = onSelectRoute
    holder.onLongPress = onLongPress
    holder.onTapItem = onTapItem
    holder.onTapEmpty = onTapEmpty
    val styleUrl = MapSetup.styleUrl(mapStyle)
    AndroidView(factory = { holder.view }, modifier = modifier, update = {
        holder.setStyleUrl(styleUrl)
        holder.setRoutes(routes, segments)
        holder.setItems(items)
        holder.setUser(user, accuracy, course)
        val becameActive = isActive && !holder.wasActive
        holder.wasActive = isActive
        if (isActive) {
            if (becameActive) { holder.retryStyle(); holder.snap(user) }
            holder.updateCamera(mode, following, user, course, routes)
        }
    })
}
