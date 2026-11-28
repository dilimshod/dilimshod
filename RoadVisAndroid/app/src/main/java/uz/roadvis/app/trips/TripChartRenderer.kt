package uz.roadvis.app.trips

import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.Trip
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min

/** Colours and scale of the chart renderer: dark for the screen (px per dp), light for the PDF (1 = 1 pt). */
class ChartPalette(
    val density: Float,
    val text: Int,
    val secondary: Int,
    val grid: Int,
    val mapBackground: Int,
) {
    companion object {
        fun dark(density: Float) = ChartPalette(density, 0xFFFFFFFF.toInt(), 0xFF9A9AA0.toInt(), 0x33FFFFFF, 0xFF1C1F24.toInt())
        val light = ChartPalette(1f, 0xFF111111.toInt(), 0xFF6B6B70.toInt(), 0x22000000, 0xFFEDEFF2.toInt())
    }
}

/**
 * Draws the trip charts on an `android.graphics.Canvas`, so the same code renders the Compose screen
 * (`drawIntoCanvas`) and the PDF pages (port of iOS `TripCharts` / Swift Charts).
 */
object TripChartRenderer {
    private val accent = RV.accent.toArgb()
    private val danger = RV.danger.toArgb()
    private val caution = RV.caution.toArgb()
    private val safe = RV.safe.toArgb()

    private fun Color.withAlpha(a: Float): Int = copy(alpha = a).toArgb()

    private fun stroke(color: Int, width: Float, dash: FloatArray? = null) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        this.color = color
        strokeWidth = width
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        if (dash != null) pathEffect = DashPathEffect(dash, 0f)
    }

    private fun fill(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; this.color = color }

    fun textPaint(color: Int, size: Float, bold: Boolean = false) = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        textSize = size
        typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
    }

    /** Draws wrapped text at (x, y top); returns its height. */
    fun drawWrapped(c: Canvas, text: String, x: Float, y: Float, width: Float, paint: TextPaint, maxLines: Int = Int.MAX_VALUE): Float {
        val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, width.toInt()))
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setMaxLines(maxLines)
            .setEllipsize(if (maxLines == Int.MAX_VALUE) null else TextUtils.TruncateAt.END)
            .build()
        c.save()
        c.translate(x, y)
        layout.draw(c)
        c.restore()
        return layout.height.toFloat()
    }

    fun measureWrapped(text: String, width: Float, paint: TextPaint): Float =
        StaticLayout.Builder.obtain(text, 0, text.length, paint, max(1, width.toInt())).build().height.toFloat()

    private fun niceStep(maxValue: Double): Double {
        val steps = doubleArrayOf(1.0, 2.0, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 500.0)
        return steps.firstOrNull { maxValue / it <= 5 } ?: 1000.0
    }

    private class Frame(val left: Float, val top: Float, val right: Float, val bottom: Float, val t0: Long, val t1: Long, val yMax: Double) {
        fun x(t: Long) = (left + (t - t0).toFloat() / max(1L, t1 - t0).toFloat() * (right - left)).coerceIn(left, right)
        fun y(v: Double) = bottom - (v / yMax).toFloat().coerceIn(0f, 1f) * (bottom - top)
    }

    private fun axes(c: Canvas, f: Frame, unit: String, p: ChartPalette) {
        val s = p.density
        val grid = stroke(p.grid, 1f * s)
        val label = textPaint(p.secondary, 9 * s).apply { textAlign = Paint.Align.RIGHT }
        val step = niceStep(f.yMax)
        var v = 0.0
        while (v <= f.yMax + 1e-9) {
            val y = f.y(v)
            c.drawLine(f.left, y, f.right, y, grid)
            c.drawText(AppFormat.decimal(v, 0), f.left - 4 * s, y + 3 * s, label)
            v += step
        }
        val xLabel = textPaint(p.secondary, 9 * s).apply { textAlign = Paint.Align.CENTER }
        val ticks = 4
        for (i in 0..ticks) {
            val t = f.t0 + (f.t1 - f.t0) * i / ticks
            val x = f.x(t)
            c.drawLine(x, f.top, x, f.bottom, grid)
            val text = TripStyle.clockText(t)
            val half = xLabel.measureText(text) / 2
            c.drawText(text, x.coerceIn(f.left + half, f.right - half), f.bottom + 12 * s, xLabel)
        }
        c.drawText(unit, f.left - 4 * s, f.top - 4 * s, textPaint(p.secondary, 9 * s).apply { textAlign = Paint.Align.LEFT })
    }

    /** Own GPS speed (blue area + line) vs the posted limit (red dashed steps) with event markers. */
    fun drawSpeedChart(c: Canvas, w: Float, h: Float, d: TripChartData, p: ChartPalette) {
        val s = p.density
        val f = Frame(34 * s, 14 * s, w - 8 * s, h - 18 * s, d.startMillis, d.endMillis, d.maxSpeed * 1.1)
        axes(c, f, AppFormat.kmh, p)
        if (d.speed.size >= 2) {
            val line = Path()
            d.speed.forEachIndexed { i, sample ->
                val x = f.x(sample.dateMillis); val y = f.y(sample.speedKmh)
                if (i == 0) line.moveTo(x, y) else line.lineTo(x, y)
            }
            val area = Path(line)
            area.lineTo(f.x(d.speed.last().dateMillis), f.bottom)
            area.lineTo(f.x(d.speed.first().dateMillis), f.bottom)
            area.close()
            val gradient = fill(0).apply {
                shader = LinearGradient(0f, f.top, 0f, f.bottom, RV.accent.withAlpha(0.35f), RV.accent.withAlpha(0.02f), Shader.TileMode.CLAMP)
            }
            c.drawPath(area, gradient)
            c.drawPath(line, stroke(accent, 2 * s))
        }
        // Limit: step lines per contiguous segment.
        val limitPaint = stroke(danger, 2 * s, floatArrayOf(5 * s, 3 * s))
        d.limits.groupBy { it.segment }.values.forEach { seg ->
            val path = Path()
            seg.forEachIndexed { i, sample ->
                val x = f.x(sample.dateMillis); val y = f.y(sample.value)
                if (i == 0) path.moveTo(x, y) else {
                    path.lineTo(x, f.y(seg[i - 1].value))
                    path.lineTo(x, y)
                }
            }
            if (seg.size == 1) path.lineTo(f.x(seg[0].dateMillis) + 3 * s, f.y(seg[0].value))
            c.drawPath(path, limitPaint)
        }
        val ring = stroke(0xFFFFFFFF.toInt(), 1.2f * s)
        d.markers.forEach { m ->
            val x = f.x(m.dateMillis); val y = f.y(m.speedKmh)
            c.drawCircle(x, y, 4.5f * s, fill(TripStyle.color(m.kind).toArgb()))
            c.drawCircle(x, y, 4.5f * s, ring)
        }
    }

    /** ≈ Camera gap to the lead vehicle (green) vs the recommended gap (amber dashed). */
    fun drawLeadChart(c: Canvas, w: Float, h: Float, d: TripChartData, p: ChartPalette) {
        val s = p.density
        val maxValue = max(d.leads.maxOfOrNull { it.value } ?: 0.0, d.recommended.maxOfOrNull { it.value } ?: 0.0)
        val f = Frame(34 * s, 14 * s, w - 8 * s, h - 18 * s, d.startMillis, d.endMillis, max(10.0, maxValue * 1.1))
        axes(c, f, AppFormat.meters + " (≈)", p)
        fun drawSegments(samples: List<TripChartData.SegmentSample>, paint: Paint) {
            samples.groupBy { it.segment }.values.forEach { seg ->
                val path = Path()
                seg.forEachIndexed { i, sample ->
                    val x = f.x(sample.dateMillis); val y = f.y(sample.value)
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                if (seg.size == 1) {
                    c.drawCircle(f.x(seg[0].dateMillis), f.y(seg[0].value), 1.5f * s, fill(paint.color))
                } else c.drawPath(path, paint)
            }
        }
        drawSegments(d.recommended, stroke(caution, 1.5f * s, floatArrayOf(4 * s, 3 * s)))
        drawSegments(d.leads, stroke(safe, 2 * s))
    }

    /** Height of [drawKindBars] for the data. */
    fun kindBarsHeight(d: TripChartData, p: ChartPalette): Float = max(1, d.kindCounts.size) * 26 * p.density

    /** Number of events per kind: horizontal bars in the kind colours with the count. */
    fun drawKindBars(c: Canvas, w: Float, d: TripChartData, p: ChartPalette) {
        val s = p.density
        val rowH = 26 * s
        val labelW = min(w * 0.45f, 150 * s)
        val countW = 26 * s
        val label = textPaint(p.text, 10 * s)
        val count = textPaint(p.secondary, 10 * s, bold = true)
        val maxCount = d.kindCounts.maxOfOrNull { it.count } ?: 1
        d.kindCounts.forEachIndexed { i, item ->
            val top = i * rowH
            val text = TextUtils.ellipsize(item.kind.localizedTitle, label, labelW - 6 * s, TextUtils.TruncateAt.END).toString()
            c.drawText(text, 0f, top + rowH / 2 + 3.5f * s, label)
            val barMax = w - labelW - countW
            val barW = max(4 * s, barMax * item.count / maxCount)
            val rect = RectF(labelW, top + 5 * s, labelW + barW, top + rowH - 5 * s)
            val color = TripStyle.color(item.kind)
            val paint = fill(0).apply {
                shader = LinearGradient(rect.left, 0f, rect.right, 0f, color.withAlpha(0.65f), color.toArgb(), Shader.TileMode.CLAMP)
            }
            c.drawRoundRect(rect, 5 * s, 5 * s, paint)
            c.drawText("${item.count}", rect.right + 5 * s, top + rowH / 2 + 3.5f * s, count)
        }
    }

    /** Share of driving time per speed band (donut). */
    fun drawDonut(c: Canvas, cx: Float, cy: Float, radius: Float, d: TripChartData, p: ChartPalette) {
        val width = radius * 0.42f
        val r = radius - width / 2
        val oval = RectF(cx - r, cy - r, cx + r, cy + r)
        var start = -90f
        val inset = if (d.bands.size > 1) 1.5f else 0f
        d.bands.forEach { b ->
            val sweep = (b.share * 360).toFloat()
            val paint = stroke(TripStyle.bandColor(b.band).toArgb(), width).apply { strokeCap = Paint.Cap.BUTT }
            c.drawArc(oval, start + inset / 2, max(0.5f, sweep - inset), false, paint)
            start += sweep
        }
    }

    /** Circular score gauge 0…100 in the score colour, with "of 100". */
    fun drawScoreRing(c: Canvas, cx: Float, cy: Float, size: Float, score: Int, p: ChartPalette) {
        val color = TripStyle.scoreColor(score)
        val lw = size * 0.1f
        val r = size / 2 - lw / 2
        val oval = RectF(cx - r, cy - r, cx + r, cy + r)
        c.drawCircle(cx, cy, r, stroke(color.withAlpha(0.18f), lw))
        val sweep = 360f * score.coerceIn(0, 100) / 100f
        if (sweep > 0) {
            val paint = stroke(color.toArgb(), lw).apply {
                shader = SweepGradient(cx, cy, intArrayOf(color.withAlpha(0.6f), color.toArgb(), color.toArgb()), floatArrayOf(0f, max(0.01f, sweep / 360f), 1f))
            }
            c.save()
            c.rotate(-90f, cx, cy)
            c.drawArc(oval, 0f, sweep, false, paint)
            c.restore()
        }
        val big = textPaint(p.text, size * 0.34f, bold = true).apply { textAlign = Paint.Align.CENTER }
        val small = textPaint(p.secondary, size * 0.11f, bold = true).apply { textAlign = Paint.Align.CENTER }
        c.drawText("$score", cx, cy + size * 0.08f, big)
        c.drawText(L("report.of100"), cx, cy + size * 0.24f, small)
    }

    /** Simple drawing of the trip on a plain background (PDF): planned route, track, events, A and B. */
    fun drawTrack(c: Canvas, w: Float, h: Float, trip: Trip, p: ChartPalette) {
        val s = p.density
        c.drawRoundRect(RectF(0f, 0f, w, h), 8 * s, 8 * s, fill(p.mapBackground))
        val all = TripMapGeometry.allCoordinates(trip)
        if (all.isEmpty()) {
            val t = textPaint(p.secondary, 10 * s).apply { textAlign = Paint.Align.CENTER }
            c.drawText(L("report.noMap"), w / 2, h / 2, t)
            return
        }
        val box = TripMapGeometry.paddedBounds(trip)
        val k = cos(Math.toRadians((box.north + box.south) / 2))
        val spanX = (box.east - box.west) * k
        val spanY = box.north - box.south
        val pad = 14 * s
        val scale = min((w - 2 * pad) / spanX, (h - 2 * pad) / spanY)
        val offX = (w - spanX * scale) / 2
        val offY = (h - spanY * scale) / 2
        fun pt(g: GeoPoint): Pair<Float, Float> =
            (offX + (g.longitude - box.west) * k * scale).toFloat() to (offY + (box.north - g.latitude) * scale).toFloat()
        fun path(points: List<GeoPoint>): Path? {
            if (points.size < 2) return null
            val path = Path()
            points.forEachIndexed { i, g -> val (x, y) = pt(g); if (i == 0) path.moveTo(x, y) else path.lineTo(x, y) }
            return path
        }
        // Light grid for orientation.
        val grid = stroke(p.grid, 0.6f * s)
        for (i in 1..5) { val x = w * i / 6; c.drawLine(x, 0f, x, h, grid) }
        for (i in 1..3) { val y = h * i / 4; c.drawLine(0f, y, w, y, grid) }
        path(trip.routePolyline)?.let { c.drawPath(it, stroke(TripStyle.route.toArgb(), 5 * s, floatArrayOf(6 * s, 6 * s))) }
        path(trip.points.map { it.coordinate })?.let { c.drawPath(it, stroke(accent, 3.5f * s)) }
        trip.events.forEach { e ->
            val g = e.coordinate ?: return@forEach
            val (x, y) = pt(g)
            c.drawCircle(x, y, 5 * s, fill(TripStyle.color(e.kind).toArgb()))
            c.drawCircle(x, y, 5 * s, stroke(0xFFFFFFFF.toInt(), 1.5f * s))
        }
        fun pin(g: GeoPoint?, letter: String, color: Int) {
            g ?: return
            val (x, y) = pt(g)
            c.drawCircle(x, y, 10 * s, fill(color))
            c.drawCircle(x, y, 10 * s, stroke(0xFFFFFFFF.toInt(), 2 * s))
            val t = textPaint(0xFFFFFFFF.toInt(), 11 * s, bold = true).apply { textAlign = Paint.Align.CENTER }
            c.drawText(letter, x, y + 4 * s, t)
        }
        pin(trip.origin.coordinate ?: trip.points.firstOrNull()?.coordinate, "A", safe)
        pin(trip.destination?.coordinate ?: trip.points.lastOrNull()?.coordinate, "B", danger)
    }
}
