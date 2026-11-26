package uz.roadvis.app.trips

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapLibreMapOptions
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.LineLayer
import org.maplibre.android.style.layers.Property
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.layers.SymbolLayer
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.LineString
import org.maplibre.geojson.Point
import uz.roadvis.app.navigation.MapSetup
import uz.roadvis.app.navigation.MapStyleLoader
import uz.roadvis.app.navigation.MapViewLifecycle
import uz.roadvis.app.navigation.cssColor
import uz.roadvis.app.ui.RV
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.GeoBounds
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.Trip
import java.util.UUID
import kotlin.math.cos
import kotlin.math.max

/** Coordinates and bounds of a trip for the map and the PDF drawing (port of iOS `TripMapView.mapRect`). */
object TripMapGeometry {
    /** All coordinates of the trip (track, route, A, B, events). */
    fun allCoordinates(trip: Trip): List<GeoPoint> {
        val all = trip.points.map { it.coordinate } + trip.routePolyline +
            listOfNotNull(trip.origin.coordinate, trip.destination?.coordinate) + trip.events.mapNotNull { it.coordinate }
        return all.filter { it.isValid }
    }

    /** Bounds around the whole trip with a 15 % margin each side (≥ ≈ 600 m); Tashkent when empty. */
    fun paddedBounds(trip: Trip): GeoBounds {
        val all = allCoordinates(trip)
        if (all.isEmpty()) return GeoBounds(41.22, 69.17, 41.40, 69.39)
        val south = all.minOf { it.latitude }; val north = all.maxOf { it.latitude }
        val west = all.minOf { it.longitude }; val east = all.maxOf { it.longitude }
        val midLat = (south + north) / 2; val midLon = (west + east) / 2
        val minLat = 600.0 / 111_320
        val minLon = 600.0 / (111_320 * max(0.2, cos(Math.toRadians(midLat))))
        val halfLat = max(north - south, minLat) * 0.65
        val halfLon = max(east - west, minLon) * 0.65
        return GeoBounds(midLat - halfLat, midLon - halfLon, midLat + halfLat, midLon + halfLon)
    }
}

/**
 * A→B map of a trip (MapLibre, OpenFreeMap dark vector tiles with the CARTO raster fallback): planned route (grey
 * dashed), driven track (blue), A and B pins and event markers filled with the kind colour and ringed by severity.
 * [highlightedEventId] is drawn larger and centred.
 */
@Composable
fun TripMap(trip: Trip, highlightedEventId: UUID?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val holder = remember(trip.id) { TripMapHolder(context, trip) }
    MapViewLifecycle(holder.view)
    Box(modifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { holder.view },
            update = { holder.setHighlight(highlightedEventId) },
        )
        Text(
            holder.attribution, color = Color(0xCCFFFFFF), fontSize = 9.sp, maxLines = 1,
            modifier = Modifier.align(Alignment.BottomStart).padding(4.dp)
                .background(Color(0x66000000), RoundedCornerShape(4.dp)).padding(horizontal = 4.dp, vertical = 1.dp),
        )
    }
}

private class TripMapHolder(context: Context, private val trip: Trip) {
    private val density = context.resources.displayMetrics.density
    val view: MapView
    var attribution by mutableStateOf(MapSetup.ATTRIBUTION_OPENFREEMAP)
        private set
    private var map: MapLibreMap? = null
    private var loader: MapStyleLoader? = null
    private var highlighted: UUID? = null
    private var centeredOn: UUID? = null
    private var fitted = false

    init {
        MapSetup.configure(context)
        val options = MapLibreMapOptions.createFromAttributes(context)
            .textureMode(true)   // inside a scrolling, clipped report: a TextureView clips and scrolls with it
            .foregroundLoadColor(0xFF1C1F24.toInt())
            .minZoomPreference(2.0)
            .maxZoomPreference(19.0)
            .attributionEnabled(false)
            .logoEnabled(false)
            .compassEnabled(false)
            .rotateGesturesEnabled(false)
            .tiltGesturesEnabled(false)
        view = MapView(context, options)
        view.setBackgroundColor(0xFF1C1F24.toInt())
        view.onCreate(null)
        // Pan / zoom the map without scrolling the report.
        @SuppressLint("ClickableViewAccessibility")
        view.setOnTouchListener { v, _ -> v.parent?.requestDisallowInterceptTouchEvent(true); false }
        view.getMapAsync { m ->
            map = m
            loader = MapStyleLoader(view, m, { attribution = it }) { style -> install(style) }
                .also { it.load(MapSetup.DARK_STYLE) }
            if (view.width > 0 && view.height > 0) fit(m)
            else view.addOnLayoutChangeListener(object : View.OnLayoutChangeListener {
                override fun onLayoutChange(v: View, l: Int, t: Int, r: Int, b: Int, ol: Int, ot: Int, or: Int, ob: Int) {
                    if (v.width > 0 && v.height > 0) { v.removeOnLayoutChangeListener(this); fit(m) }
                }
            })
        }
    }

    private fun fit(m: MapLibreMap) {
        if (fitted) return
        fitted = true
        val b = TripMapGeometry.paddedBounds(trip)
        m.moveCamera(CameraUpdateFactory.newLatLngBounds(LatLngBounds.from(b.north, b.east, b.south, b.west), 0))
        centerOnHighlight()
    }

    private fun install(style: Style) {
        style.addImage("trip-a", pinBitmap("A", RV.safe.toArgb(), density))
        style.addImage("trip-b", pinBitmap("B", RV.danger.toArgb(), density))
        if (trip.routePolyline.size >= 2) {
            style.addSource(GeoJsonSource("trip-route", LineString.fromLngLats(trip.routePolyline.map(::pt))))
            style.addLayer(LineLayer("trip-route", "trip-route").withProperties(
                PropertyFactory.lineColor(cssColor(TripStyle.route.toArgb())),
                PropertyFactory.lineWidth(5f),
                PropertyFactory.lineCap(Property.LINE_CAP_BUTT),
                // Dash and gap of 6 dp, in line widths.
                PropertyFactory.lineDasharray(arrayOf(1.2f, 1.2f)),
            ))
        }
        if (trip.points.size >= 2) {
            style.addSource(GeoJsonSource("trip-track", LineString.fromLngLats(trip.points.map { pt(it.coordinate) })))
            style.addLayer(LineLayer("trip-track", "trip-track").withProperties(
                PropertyFactory.lineColor(cssColor(RV.accent.toArgb())),
                PropertyFactory.lineWidth(4f),
                PropertyFactory.lineCap(Property.LINE_CAP_ROUND),
                PropertyFactory.lineJoin(Property.LINE_JOIN_ROUND),
            ))
        }
        val pins = listOfNotNull(
            (trip.origin.coordinate ?: trip.points.firstOrNull()?.coordinate)?.let { pinFeature(it, "trip-a") },
            (trip.destination?.coordinate ?: trip.points.lastOrNull()?.coordinate)?.let { pinFeature(it, "trip-b") },
        )
        style.addSource(GeoJsonSource("trip-events", eventFeatures(style)))
        style.addLayer(symbolLayer("trip-events", "trip-events"))
        style.addSource(GeoJsonSource("trip-pins", FeatureCollection.fromFeatures(pins)))
        style.addLayer(symbolLayer("trip-pins", "trip-pins"))
    }

    private fun symbolLayer(id: String, source: String) = SymbolLayer(id, source).withProperties(
        PropertyFactory.iconImage(Expression.get("icon")),
        PropertyFactory.iconAllowOverlap(true),
        PropertyFactory.iconIgnorePlacement(true),
        PropertyFactory.symbolZOrder(Property.SYMBOL_Z_ORDER_SOURCE),
    )

    private fun pinFeature(p: GeoPoint, icon: String) =
        Feature.fromGeometry(pt(p)).apply { addStringProperty("icon", icon) }

    /** Event features (highlighted one last, so on top); adds the marker bitmaps they use to [style]. */
    private fun eventFeatures(style: Style): FeatureCollection {
        val events = trip.events.filter { it.coordinate != null }.sortedBy { it.id == highlighted }
        return FeatureCollection.fromFeatures(events.map { e ->
            val big = e.id == highlighted
            val icon = "trip-ev-${TripStyle.color(e.kind).toArgb()}-${TripStyle.severityColor(e.severity).toArgb()}-$big"
            if (style.getImage(icon) == null) style.addImage(icon, eventBitmap(e, big, density))
            Feature.fromGeometry(pt(e.coordinate!!)).apply { addStringProperty("icon", icon) }
        })
    }

    fun setHighlight(id: UUID?) {
        if (id == highlighted && centeredOn == id) return
        highlighted = id
        loader?.style?.let { style -> style.getSourceAs<GeoJsonSource>("trip-events")?.setGeoJson(eventFeatures(style)) }
        if (fitted) centerOnHighlight()
    }

    private fun centerOnHighlight() {
        val m = map ?: return
        if (centeredOn == highlighted) return
        centeredOn = highlighted
        val target = trip.events.firstOrNull { it.id == highlighted }?.coordinate ?: return
        m.animateCamera(CameraUpdateFactory.newLatLng(LatLng(target.latitude, target.longitude)))
    }
}

private fun pt(g: GeoPoint): Point = Point.fromLngLat(g.longitude, g.latitude)

private fun pinBitmap(letter: String, color: Int, density: Float): Bitmap {
    val size = (26 * density).toInt()
    val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val r = size / 2f
    c.drawCircle(r, r, r - density, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
    c.drawCircle(r, r, r - density, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; this.color = 0xFFFFFFFF.toInt(); strokeWidth = 2 * density
    })
    val t = TripChartRenderer.textPaint(0xFFFFFFFF.toInt(), 13 * density, bold = true).apply { textAlign = Paint.Align.CENTER }
    c.drawText(letter, r, r + 4.5f * density, t)
    return bmp
}

private fun eventBitmap(event: DrivingEvent, big: Boolean, density: Float): Bitmap {
    val size = ((if (big) 30 else 20) * density).toInt()
    val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val r = size / 2f
    val ring = (if (big) 3f else 2f) * density
    c.drawCircle(r, r, r - ring / 2, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TripStyle.color(event.kind).toArgb() })
    c.drawCircle(r, r, r - ring / 2, Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = TripStyle.severityColor(event.severity).toArgb(); strokeWidth = ring
    })
    return bmp
}
