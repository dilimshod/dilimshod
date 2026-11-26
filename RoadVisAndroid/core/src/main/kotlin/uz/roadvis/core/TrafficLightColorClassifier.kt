package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min

/** An 8-bit RGB pixel; components are 0...255. */
data class RGBPixel(val r: Int, val g: Int, val b: Int)

/** HSV hue in degrees [0, 360) as computed by the Swift classifiers (Swift `truncatingRemainder` semantics). */
internal fun hsvHue(r: Double, g: Double, b: Double, maxC: Double, delta: Double): Double {
    var hue = when (maxC) {
        r -> 60 * (((g - b) / delta) % 6)
        g -> 60 * ((b - r) / delta + 2)
        else -> 60 * ((r - g) / delta + 4)
    }
    if (hue < 0) hue += 360
    return hue
}

/** Reads one pixel of a 4-byte-per-pixel buffer at byte offset [i] (BGRA when [bgra], else RGBA). */
internal fun pixelAt(base: ByteArray, i: Int, bgra: Boolean): RGBPixel {
    val c0 = base[i].toInt() and 0xFF
    val c1 = base[i + 1].toInt() and 0xFF
    val c2 = base[i + 2].toInt() and 0xFF
    return if (bgra) RGBPixel(c2, c1, c0) else RGBPixel(c0, c1, c2)
}

/**
 * Heuristic colour classification of a traffic-light crop: votes over bright, saturated pixels by hue.
 * Works for standard round red/yellow/green signals; arrows, LED matrices and back-lit glare can fool it,
 * so the result is shown as an estimate and smoothed over several frames by the tracker.
 */
object TrafficLightColorClassifier {
    /** Minimum share of "lit" pixels (of all sampled pixels) needed for a decision. */
    internal const val minLitShare = 0.015
    /** The winning colour must have at least this share of the lit pixels. */
    internal const val minWinnerShare = 0.5

    fun classify(pixels: List<RGBPixel>): TrafficLightColor {
        if (pixels.isEmpty()) return TrafficLightColor.UNKNOWN
        var red = 0; var yellow = 0; var green = 0
        for (p in pixels) {
            when (hueClass(p)) {
                TrafficLightColor.RED -> red++
                TrafficLightColor.YELLOW -> yellow++
                TrafficLightColor.GREEN -> green++
                TrafficLightColor.UNKNOWN -> {}
            }
        }
        return decide(red, yellow, green, pixels.size)
    }

    /**
     * Samples a 4-byte-per-pixel buffer (row stride [bytesPerRow]) inside the given pixel rectangle.
     * Default layout is BGRA (as on iOS); pass [bgra] = false for an RGBA buffer (e.g. Android RGBA_8888).
     */
    fun classifyBGRA(
        base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
        step: Int = 2, bgra: Boolean = true,
    ): TrafficLightColor {
        val x0 = max(0, min(width - 1, rectX))
        val y0 = max(0, min(height - 1, rectY))
        val x1 = max(x0, min(width, rectX + rectWidth))
        val y1 = max(y0, min(height, rectY + rectHeight))
        if (!(x1 > x0 && y1 > y0 && bytesPerRow >= width * 4)) return TrafficLightColor.UNKNOWN
        val s = max(1, step)
        var red = 0; var yellow = 0; var green = 0; var total = 0
        var y = y0
        while (y < y1) {
            val row = y * bytesPerRow
            var x = x0
            while (x < x1) {
                when (hueClass(pixelAt(base, row + x * 4, bgra))) {
                    TrafficLightColor.RED -> red++
                    TrafficLightColor.YELLOW -> yellow++
                    TrafficLightColor.GREEN -> green++
                    TrafficLightColor.UNKNOWN -> {}
                }
                total++
                x += s
            }
            y += s
        }
        return decide(red, yellow, green, total)
    }

    internal fun decide(red: Int, yellow: Int, green: Int, total: Int): TrafficLightColor {
        val lit = red + yellow + green
        if (!(total > 0 && lit.toDouble() / total >= minLitShare && lit >= 3)) return TrafficLightColor.UNKNOWN
        val best = maxOf(red, yellow, green)
        if (best.toDouble() / lit < minWinnerShare) return TrafficLightColor.UNKNOWN
        if (best == red) return TrafficLightColor.RED
        if (best == green) return TrafficLightColor.GREEN
        return TrafficLightColor.YELLOW
    }

    /** Hue class of a single pixel; only bright and saturated pixels count as "lit". */
    internal fun hueClass(p: RGBPixel): TrafficLightColor {
        val r = p.r / 255.0; val g = p.g / 255.0; val b = p.b / 255.0
        val maxC = maxOf(r, g, b); val minC = minOf(r, g, b)
        val delta = maxC - minC
        val value = maxC
        val saturation = if (maxC > 0) delta / maxC else 0.0
        if (!(value >= 0.55 && saturation >= 0.35 && delta > 0)) return TrafficLightColor.UNKNOWN
        val hue = hsvHue(r, g, b, maxC, delta)
        return when {
            (hue >= 0 && hue < 20) || (hue >= 330 && hue <= 360) -> TrafficLightColor.RED
            hue >= 20 && hue < 70 -> TrafficLightColor.YELLOW
            hue >= 90 && hue < 200 -> TrafficLightColor.GREEN // signal greens are often cyan-ish
            else -> TrafficLightColor.UNKNOWN
        }
    }
}
