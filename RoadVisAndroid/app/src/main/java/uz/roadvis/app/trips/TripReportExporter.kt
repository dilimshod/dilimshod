package uz.roadvis.app.trips

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.pdf.PdfDocument
import androidx.compose.ui.graphics.toArgb
import androidx.core.content.FileProvider
import uz.roadvis.app.l10n.L
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.Trip
import uz.roadvis.core.TripExport
import uz.roadvis.core.TripScoring
import uz.roadvis.core.TripStats
import java.io.File
import kotlin.math.max

/**
 * Builds the shareable files of a trip report (port of iOS `TripReportExporter`): a multi-page A4 PDF (track drawing
 * with A/B and events, score, numbers, charts, the table of events) and two CSV files (events, track points), in
 * `cacheDir/trip_export/<id>/`, shared through the FileProvider.
 */
object TripReportExporter {
    data class Files(val pdf: File, val eventsCSV: File, val pointsCSV: File) {
        val all: List<File> get() = listOf(pdf, eventsCSV, pointsCSV)
    }

    private const val PAGE_W = 595
    private const val PAGE_H = 842
    private const val MARGIN = 25f
    private val BOM = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

    /** Writes the three files. Blocking — call off the main thread. */
    fun export(context: Context, trip: Trip): Files {
        val dir = File(context.cacheDir, "trip_export/${trip.id}")
        dir.mkdirs()
        val base = TripExport.baseFileName(trip)
        val events = File(dir, "${base}_events.csv")
        val points = File(dir, "${base}_track.csv")
        // UTF-8 BOM so spreadsheet apps detect the Cyrillic text.
        events.writeBytes(BOM + TripExport.eventsCSV(trip) { it.localizedTitle }.toByteArray(Charsets.UTF_8))
        points.writeBytes(BOM + TripExport.pointsCSV(trip).toByteArray(Charsets.UTF_8))
        val pdf = File(dir, "${base}_report.pdf")
        renderPDF(trip, pdf)
        return Files(pdf, events, points)
    }

    /** Opens the system share sheet for the files. */
    fun share(context: Context, files: List<File>) {
        val authority = "${context.packageName}.fileprovider"
        val uris = files.map { FileProvider.getUriForFile(context, authority, it) }
        if (uris.isEmpty()) return
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = if (files[0].extension == "pdf") "application/pdf" else "text/csv"
                putExtra(Intent.EXTRA_STREAM, uris[0])
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "*/*"
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
        }
        intent.putExtra(Intent.EXTRA_SUBJECT, L("report.pdfTitle"))
        val clip = ClipData.newRawUri(files[0].name, uris[0])
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
        intent.clipData = clip
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val chooser = Intent.createChooser(intent, L("report.share")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
    }

    // PDF

    private val p = ChartPalette.light
    private fun text(size: Float, bold: Boolean = false, color: Int = p.text) = TripChartRenderer.textPaint(color, size, bold)

    private class Row(val event: DrivingEvent, val index: Int, val height: Float)

    private val columns = floatArrayOf(22f, 52f, 128f, 180f) // №, time, event, value; place takes the rest

    private fun cellTexts(e: DrivingEvent, index: Int): List<String> = listOf(
        "${index + 1}",
        TripStyle.timeText(e.dateMillis),
        e.kind.localizedTitle,
        TripStyle.valueText(e),
        e.note?.takeUnless { it == "GPS" || it.startsWith("GPS +") } ?: TripStyle.coordinateText(e.coordinate),
    )

    private fun columnWidths(): FloatArray {
        val content = PAGE_W - 2 * MARGIN
        val rest = content - columns.sum() - 4 * 8f
        return columns + floatArrayOf(rest)
    }

    fun renderPDF(trip: Trip, file: File) {
        val stats = TripStats.compute(trip)
        val score = TripScoring.score(trip.events, stats.distanceMeters)
        val data = TripChartData(trip, stats)
        val events = trip.sortedEvents

        // Paginate the event table by measured row heights.
        val widths = columnWidths()
        val cell = text(9f)
        val rows = events.mapIndexed { i, e ->
            val h = cellTexts(e, i).mapIndexed { c, t -> TripChartRenderer.measureWrapped(t, widths[c] - if (c == 2) 11f else 0f, cell) }.max()
            Row(e, i, h + 5f)
        }
        val tableTop = MARGIN + 20f + 22f + 18f
        val tableBottom = PAGE_H - MARGIN - 40f
        val pages = mutableListOf<List<Row>>()
        var current = mutableListOf<Row>()
        var y = tableTop
        for (r in rows) {
            if (y + r.height > tableBottom && current.isNotEmpty()) {
                pages += current; current = mutableListOf(); y = tableTop
            }
            current += r; y += r.height
        }
        pages += current
        val pageCount = 2 + pages.size

        val doc = PdfDocument()
        try {
            var number = 1
            fun page(draw: (Canvas) -> Unit) {
                val pg = doc.startPage(PdfDocument.PageInfo.Builder(PAGE_W, PAGE_H, number).create())
                val c = pg.canvas
                c.drawColor(0xFFFFFFFF.toInt())
                frame(c, trip, number, pageCount)
                draw(c)
                doc.finishPage(pg)
                number++
            }
            page { summaryPage(it, trip, stats, score) }
            page { chartsPage(it, data) }
            pages.forEach { rowsOfPage -> page { eventsPage(it, trip, rowsOfPage, widths) } }
            file.outputStream().use { doc.writeTo(it) }
        } finally {
            doc.close()
        }
    }

    private fun frame(c: Canvas, trip: Trip, page: Int, pageCount: Int) {
        val content = PAGE_W - 2 * MARGIN
        c.drawText(L("report.pageHeader"), MARGIN, MARGIN + 10f, text(10f, true, p.secondary))
        val date = TripStyle.dateText(trip)
        val datePaint = text(10f, color = p.secondary).apply { textAlign = Paint.Align.RIGHT }
        c.drawText(date, PAGE_W - MARGIN, MARGIN + 10f, datePaint)
        val footerTop = PAGE_H - MARGIN - 28f
        TripChartRenderer.drawWrapped(c, L("report.pdfFooter"), MARGIN, footerTop, content - 80f, text(7f, color = p.secondary))
        val pageText = text(8f, color = p.secondary).apply { textAlign = Paint.Align.RIGHT }
        c.drawText(L("report.page", page, pageCount), PAGE_W - MARGIN, PAGE_H - MARGIN, pageText)
    }

    private fun summaryPage(c: Canvas, trip: Trip, stats: TripStats, score: TripScoring.Result) {
        val content = PAGE_W - 2 * MARGIN
        var y = MARGIN + 22f
        y += TripChartRenderer.drawWrapped(c, TripStyle.title(trip), MARGIN, y, content, text(20f, true), maxLines = 2) + 10f
        c.save(); c.translate(MARGIN, y)
        TripChartRenderer.drawTrack(c, content, 300f, trip, p)
        c.restore()
        y += 310f
        TripChartRenderer.drawScoreRing(c, MARGIN + 48f, y + 48f, 96f, score.score, p)
        val tx = MARGIN + 114f
        val tw = content - 114f
        var ty = y + 4f
        ty += TripChartRenderer.drawWrapped(c, TripStyle.grade(score.score), tx, ty, tw, text(16f, true, TripStyle.scoreColor(score.score).toArgb())) + 4f
        ty += TripChartRenderer.drawWrapped(c, L("report.penaltyPdf", AppFormat.decimal(score.totalPenalty, 1), AppFormat.decimal(score.penaltyPerKm, 2)), tx, ty, tw, text(10f)) + 4f
        ty += TripChartRenderer.drawWrapped(c, TripStyle.formula, tx, ty, tw, text(8f, color = p.secondary))
        y = max(y + 106f, ty + 10f)
        // Stats tiles, 3 columns.
        val tiles = TripStatsTiles.tiles(stats)
        val gap = 8f
        val tileW = (content - 2 * gap) / 3
        val tileH = 38f
        tiles.forEachIndexed { i, tile ->
            val col = i % 3; val row = i / 3
            val left = MARGIN + col * (tileW + gap)
            val top = y + row * (tileH + gap)
            val rect = RectF(left, top, left + tileW, top + tileH)
            c.drawRoundRect(rect, 8f, 8f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = tile.color.copy(alpha = 0.10f).toArgb() })
            c.drawText(tile.title, left + 7f, top + 13f, text(8f, true, tile.color.toArgb()))
            c.drawText(tile.value, left + 7f, top + 30f, text(13f, true))
        }
    }

    private fun chartsPage(c: Canvas, data: TripChartData) {
        val content = PAGE_W - 2 * MARGIN
        var y = MARGIN + 22f
        c.drawText(L("report.speedAndLimit"), MARGIN, y + 12f, text(13f, true)); y += 20f
        c.save(); c.translate(MARGIN, y); TripChartRenderer.drawSpeedChart(c, content, 190f, data, p); c.restore()
        y += 196f
        // Legend.
        var lx = MARGIN
        fun legend(color: Int, label: String, dot: Boolean = false, dashed: Boolean = false) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; strokeWidth = 2f }
            if (dot) c.drawCircle(lx + 4f, y + 4f, 4f, paint) else {
                if (dashed) paint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(3f, 2f), 0f)
                c.drawLine(lx, y + 4f, lx + 14f, y + 4f, paint)
            }
            val t = text(8f)
            c.drawText(label, lx + 18f, y + 7f, t)
            lx += 18f + t.measureText(label) + 14f
        }
        legend(uz.roadvis.app.ui.RV.accent.toArgb(), L("chart.legend.speed"))
        legend(uz.roadvis.app.ui.RV.danger.toArgb(), L("chart.limit"), dashed = true)
        legend(TripStyle.color(uz.roadvis.core.DrivingEventKind.SPEEDING).toArgb(), L("chart.events"), dot = true)
        y += 22f
        // Events by kind | time by speed.
        val colW = (content - 20f) / 2
        c.drawText(L("report.eventsByKind"), MARGIN, y + 12f, text(13f, true))
        c.drawText(L("report.timeBySpeed"), MARGIN + colW + 20f, y + 12f, text(13f, true))
        y += 20f
        var leftH = 14f
        if (data.kindCounts.isEmpty()) {
            c.drawText(L("report.noEvents"), MARGIN, y + 10f, text(9f, color = p.secondary))
        } else {
            c.save(); c.translate(MARGIN, y); TripChartRenderer.drawKindBars(c, colW, data, p); c.restore()
            leftH = TripChartRenderer.kindBarsHeight(data, p)
        }
        var rightH = 14f
        val rx = MARGIN + colW + 20f
        if (data.bands.isEmpty()) {
            c.drawText(L("report.noSpeedData"), rx, y + 10f, text(9f, color = p.secondary))
        } else {
            TripChartRenderer.drawDonut(c, rx + 45f, y + 45f, 45f, data, p)
            var ly = y + 4f
            data.bands.forEach { b ->
                c.drawCircle(rx + 100f, ly + 4f, 4f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TripStyle.bandColor(b.band).toArgb() })
                c.drawText(b.band.localizedTitle, rx + 108f, ly + 7f, text(8f))
                val v = "${Math.round(b.share * 100)}% · ${AppFormat.duration(b.seconds)}"
                c.drawText(v, rx + colW, ly + 7f, text(8f, true).apply { textAlign = Paint.Align.RIGHT })
                ly += 15f
            }
            rightH = max(90f, ly - y)
        }
        y += max(leftH, rightH) + 16f
        c.drawText(L("report.leadDistanceCamera"), MARGIN, y + 12f, text(13f, true)); y += 20f
        if (data.hasLeadData) {
            c.save(); c.translate(MARGIN, y); TripChartRenderer.drawLeadChart(c, content, 150f, data, p); c.restore()
        } else {
            c.drawText(L("report.noLeadData"), MARGIN, y + 10f, text(9f, color = p.secondary))
        }
    }

    private fun eventsPage(c: Canvas, trip: Trip, rows: List<Row>, widths: FloatArray) {
        var y = MARGIN + 22f
        c.drawText(L("report.violations", trip.events.count()), MARGIN, y + 12f, text(13f, true))
        y += 22f
        if (rows.isEmpty()) {
            c.drawText(L("report.noEventsTrip"), MARGIN, y + 10f, text(11f))
            return
        }
        val headers = listOf(L("report.col.number"), L("report.col.time"), L("report.col.event"), L("report.col.value"), L("report.col.place"))
        var x = MARGIN
        headers.forEachIndexed { i, h -> c.drawText(h, x, y + 9f, text(9f, true)); x += widths[i] + 8f }
        y += 13f
        c.drawLine(MARGIN, y, PAGE_W - MARGIN, y, Paint().apply { color = p.grid; strokeWidth = 0.8f })
        y += 5f
        val cell = text(9f)
        rows.forEach { r ->
            val texts = cellTexts(r.event, r.index)
            x = MARGIN
            texts.forEachIndexed { i, t ->
                if (i == 2) {
                    c.drawCircle(x + 3.5f, y + 6f, 3.5f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = TripStyle.color(r.event.kind).toArgb() })
                    TripChartRenderer.drawWrapped(c, t, x + 11f, y, widths[i] - 11f, cell)
                } else {
                    TripChartRenderer.drawWrapped(c, t, x, y, widths[i], cell)
                }
                x += widths[i] + 8f
            }
            y += r.height
        }
    }
}
