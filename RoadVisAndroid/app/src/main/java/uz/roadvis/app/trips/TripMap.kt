package uz.roadvis.app.trips

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.XYTileSource
import org.osmdroid.util.BoundingBox
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.CopyrightOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
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

/** CARTO Dark Matter raster tiles (OpenStreetMap data). */
private val cartoDark = XYTileSource(
    "CartoDark", 0, 19, 256, ".png",
    arrayOf(
        "https://a.basemaps.cartocdn.com/dark_all/", "https://b.basemaps.cartocdn.com/dark_all/",
        "https://c.basemaps.cartocdn.com/dark_all/", "https://d.basemaps.cartocdn.com/dark_all/",
    ),
    "© OpenStreetMap contributors © CARTO",
)

private fun org(g: GeoPoint) = org.osmdroid.util.GeoPoint(g.latitude, g.longitude)

/**
 * A→B map of a trip (osmdroid, CARTO Dark): planned route (grey dashed), driven track (blue), A and B pins and event
 * markers filled with the kind colour and ringed by severity. [highlightedEventId] is drawn larger and centred.
 */
@Composable
fun TripMap(trip: Trip, highlightedEventId: UUID?, modifier: Modifier = Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { ctx -> createMap(ctx, trip) },
        update = { map -> updateEvents(map, trip, highlightedEventId) },
        onRelease = { it.onDetach() },
    )
}

@SuppressLint("ClickableViewAccessibility")
private fun createMap(ctx: Context, trip: Trip): MapView {
    Configuration.getInstance().apply {
        load(ctx, ctx.getSharedPreferences("osmdroid", Context.MODE_PRIVATE))
        userAgentValue = "RoadVis-Android/1.0"
    }
    val map = MapView(ctx)
    map.setTileSource(cartoDark)
    map.setTilesScaledToDpi(true)
    map.setMultiTouchControls(true)
    map.zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
    map.minZoomLevel = 3.0
    map.maxZoomLevel = 19.0
    map.setBackgroundColor(0xFF1C1F24.toInt())
    // Pan / zoom the map without scrolling the report.
    map.setOnTouchListener { v, _ -> v.parent?.requestDisallowInterceptTouchEvent(true); false }

    val density = ctx.resources.displayMetrics.density
    if (trip.routePolyline.size >= 2) {
        map.overlays += Polyline(map).apply {
            setPoints(trip.routePolyline.map(::org))
            outlinePaint.color = TripStyle.route.toArgb()
            outlinePaint.strokeWidth = 5 * density
            outlinePaint.strokeCap = Paint.Cap.ROUND
            outlinePaint.pathEffect = DashPathEffect(floatArrayOf(6 * density, 6 * density), 0f)
            infoWindow = null
        }
    }
    if (trip.points.size >= 2) {
        map.overlays += Polyline(map).apply {
            setPoints(trip.points.map { org(it.coordinate) })
            outlinePaint.color = RV.accent.toArgb()
            outlinePaint.strokeWidth = 4 * density
            outlinePaint.strokeCap = Paint.Cap.ROUND
            outlinePaint.strokeJoin = Paint.Join.ROUND
            infoWindow = null
        }
    }
    fun pin(point: GeoPoint?, letter: String, color: Int, title: String?) {
        point ?: return
        map.overlays += Marker(map).apply {
            position = org(point)
            icon = BitmapDrawable(ctx.resources, pinBitmap(letter, color, density))
            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
            this.title = title ?: letter
            infoWindow = null
            setOnMarkerClickListener { _, _ -> true }
        }
    }
    pin(trip.origin.coordinate ?: trip.points.firstOrNull()?.coordinate, "A", RV.safe.toArgb(), trip.origin.name)
    pin(trip.destination?.coordinate ?: trip.points.lastOrNull()?.coordinate, "B", RV.danger.toArgb(), trip.destination?.name)
    map.overlays += CopyrightOverlay(ctx).apply { setTextColor(0xCCFFFFFF.toInt()); setTextSize(9) }

    val b = TripMapGeometry.paddedBounds(trip)
    val box = BoundingBox(b.north, b.east, b.south, b.west)
    map.addOnFirstLayoutListener { _, _, _, _, _ -> map.zoomToBoundingBox(box, false) }
    map.onResume()
    return map
}

private class EventMarker(map: MapView, val event: DrivingEvent) : Marker(map)

private fun updateEvents(map: MapView, trip: Trip, highlighted: UUID?) {
    val ctx = map.context
    val density = ctx.resources.displayMetrics.density
    map.overlays.removeAll { it is EventMarker }
    var target: GeoPoint? = null
    // Insert below the copyright overlay (last) and above the track.
    val insertAt = max(0, map.overlays.size - 1)
    val markers = trip.events.filter { it.coordinate != null }.sortedBy { it.id == highlighted }.map { e ->
        val big = e.id == highlighted
        if (big) target = e.coordinate
        EventMarker(map, e).apply {
            position = org(e.coordinate!!)
            icon = BitmapDrawable(ctx.resources, eventBitmap(e, big, density))
            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
            title = e.kind.localizedTitle
            infoWindow = null
            setOnMarkerClickListener { _, _ -> true }
        }
    }
    map.overlays.addAll(insertAt, markers)
    if ((map.tag as? UUID) != highlighted) {
        map.tag = highlighted
        target?.let { map.controller.animateTo(org(it)) }
    }
    map.invalidate()
}

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
