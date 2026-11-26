package uz.roadvis.core

import kotlin.math.floor
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
 * Heuristic colour classification of a traffic-light crop ("v2": relative brightness + red halo + position prior).
 * Line-by-line mirror of the Swift `TrafficLightColorClassifier`, itself a port of the evaluated Python prototype; the
 * measurements are documented there (LISA sample, optimistic to an unknown degree, nothing measured on Uzbek roads or
 * on a phone). The Kotlin port is checked against the same 292-crop parity fixture as the Swift one.
 *
 * Algorithm, on a grid of ≈ 24 samples along the short side of the box:
 *  1. candidate pixel = hue red / orange / yellow (330…360, 0…70) or green (90…200), S ≥ 0.40, V ≥ 0.30;
 *  2. `vref` = 90th percentile of V over the candidates; lit = candidate with V ≥ max(0.30, 0.5 · vref);
 *  3. every lit pixel weighs S·V; masses R (hue < 10 or ≥ 330), A (10…40), Y (40…70), G (90…200);
 *  4. warm = R + A + Y: if R ≥ 0.3 · (A + Y) all warm mass is RED (red halo); else if the box is vertical
 *     (h ≥ 1.6 w), the weighted centroid of the warm pixels is in the top 42 % and R + A ≥ 0.3 · warm → RED; else A
 *     joins YELLOW;
 *  5. the winner needs ≥ 60 % of the mass, ≥ 3 lit pixels and a lit share ≥ 0.4 %;
 *  6. guards: for GREEN only, > 60 % of its mass in the outer 15 % border ring (grid ≥ 8 × 6) → unknown; for any
 *     colour the weighted mean V of the winning pixels must exceed the 25th percentile of V in the crop by ≥ 0.10.
 */
object TrafficLightColorClassifier {
    /** Candidate pixel: minimum saturation / value. */
    internal const val minSaturation = 0.40
    internal const val minValue = 0.30
    /** Lit = candidate at least this share of the 90th-percentile candidate brightness. */
    internal const val relativeValue = 0.5
    internal const val referencePercentile = 0.90
    /** Hue bounds, degrees. */
    internal const val amberLow = 10.0
    internal const val amberHigh = 40.0
    internal const val warmHigh = 70.0
    internal const val redWrap = 330.0
    internal const val greenLow = 90.0
    internal const val greenHigh = 200.0
    /** Red halo: red mass ≥ this × (amber + yellow mass) → the whole warm mass is red. */
    internal const val haloRatio = 0.3
    /** Position prior for vertical housings: warm centroid above this share of the box height → red. */
    internal const val topSectionY = 0.42
    /** The box counts as a vertical housing when height ≥ this × width. */
    internal const val verticalAspect = 1.6
    /** Winner share of the total colour mass. */
    internal const val minWinnerShare = 0.6
    /** Minimum lit pixels and lit share of the sampled pixels. */
    internal const val minLitPixels = 3
    internal const val minLitShare = 0.004
    /** Green border-ring guard. */
    internal const val ringWidth = 0.15
    internal const val maxRingShare = 0.6
    internal const val ringMinRows = 8
    internal const val ringMinColumns = 6
    /** Lamp-vs-housing contrast: weighted mean V of the winner minus the 25th percentile of V. */
    internal const val minContrast = 0.10
    internal const val housingPercentile = 0.25
    /** Samples along the short side of the box. */
    const val samplesAlongShortSide = 24

    /** Sampling step used for a box of the given pixel size (≈ 24 samples along the short side). */
    fun samplingStep(rectWidth: Int, rectHeight: Int): Int = max(1, min(rectWidth, rectHeight) / samplesAlongShortSide)

    /** Classifies a flat list of pixels (no geometry: no position prior and no border-ring guard). */
    fun classify(pixels: List<RGBPixel>): TrafficLightColor =
        classify(pixels, pixels.size, if (pixels.isEmpty()) 0 else 1, vertical = false)

    /**
     * Classifies a row-major grid of `width × height` sampled pixels of a traffic-light box.
     * [vertical]: whether the BOX (in image pixels) is a vertical housing; null → from the grid shape.
     */
    fun classify(pixels: List<RGBPixel>, width: Int, height: Int, vertical: Boolean? = null): TrafficLightColor {
        if (!(width > 0 && height > 0 && pixels.size >= width * height)) return TrafficLightColor.UNKNOWN
        val grid = Grid(width, height)
        for (k in 0 until width * height) {
            val p = pixels[k]
            grid.append(p.r, p.g, p.b)
        }
        return decide(grid, vertical ?: (height.toDouble() >= verticalAspect * width.toDouble()))
    }

    /**
     * Samples a 4-byte-per-pixel buffer (row stride [bytesPerRow]) inside the given pixel rectangle.
     * Default layout is BGRA (as on iOS); pass [bgra] = false for an RGBA buffer (e.g. Android RGBA_8888).
     * [step]: sampling step in pixels; null → [samplingStep].
     */
    fun classifyBGRA(
        base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
        rectX: Int, rectY: Int, rectWidth: Int, rectHeight: Int,
        step: Int? = null, bgra: Boolean = true,
    ): TrafficLightColor {
        val x0 = max(0, min(width - 1, rectX))
        val y0 = max(0, min(height - 1, rectY))
        val x1 = max(x0, min(width, rectX + rectWidth))
        val y1 = max(y0, min(height, rectY + rectHeight))
        if (!(x1 > x0 && y1 > y0 && bytesPerRow >= width * 4)) return TrafficLightColor.UNKNOWN
        val s = max(1, step ?: samplingStep(x1 - x0, y1 - y0))
        val columns = (x1 - x0 + s - 1) / s
        val rows = (y1 - y0 + s - 1) / s
        val grid = Grid(columns, rows)
        var y = y0
        while (y < y1) {
            val row = y * bytesPerRow
            var x = x0
            while (x < x1) {
                val i = row + x * 4
                val c0 = base[i].toInt() and 0xFF
                val c1 = base[i + 1].toInt() and 0xFF
                val c2 = base[i + 2].toInt() and 0xFF
                if (bgra) grid.append(c2, c1, c0) else grid.append(c0, c1, c2)
                x += s
            }
            y += s
        }
        return decide(grid, (y1 - y0).toDouble() >= verticalAspect * (x1 - x0).toDouble())
    }

    // Implementation

    /** Hue (degrees 0..<360), saturation and value of the sampled pixels, row-major. */
    internal class Grid(val width: Int, val height: Int) {
        private val capacity = max(0, width * height)
        val hue = DoubleArray(capacity)
        val saturation = DoubleArray(capacity)
        val value = DoubleArray(capacity)
        /** 8-bit value channel (V = max(r, g, b) / 255 takes 256 levels → exact percentiles). */
        val valueLevels = IntArray(capacity)
        var count = 0
            private set

        fun append(r: Int, g: Int, b: Int) {
            if (count >= capacity) return
            val rd = r / 255.0; val gd = g / 255.0; val bd = b / 255.0
            val maxC = maxOf(rd, gd, bd); val minC = minOf(rd, gd, bd)
            val delta = maxC - minC
            hue[count] = if (delta > 0) hsvHue(rd, gd, bd, maxC, delta) else 0.0
            saturation[count] = if (maxC > 0) delta / maxC else 0.0
            value[count] = maxC
            valueLevels[count] = maxOf(r, g, b)
            count++
        }
    }

    /** Linear-interpolated percentile (same definition as `numpy.percentile`) from a 256-level histogram. */
    internal fun percentile(histogram: IntArray, count: Int, fraction: Double): Double {
        if (count <= 0) return 0.0
        val position = (count - 1).toDouble() * fraction
        val lowIndex = floor(position).toInt()
        val highIndex = min(count - 1, lowIndex + 1)
        val weight = position - lowIndex.toDouble()
        var low = 0.0; var high = 0.0
        var seen = 0
        var haveLow = false
        for (level in 0 until 256) {
            val c = histogram[level]
            if (c <= 0) continue
            seen += c
            if (!haveLow && seen > lowIndex) {
                low = level / 255.0
                haveLow = true
            }
            if (seen > highIndex) {
                high = level / 255.0
                break
            }
        }
        return low + (high - low) * weight
    }

    private enum class Band { RED, AMBER, YELLOW, GREEN, NONE }

    private fun band(hue: Double): Band = when {
        hue < amberLow || hue >= redWrap -> Band.RED
        hue < amberHigh -> Band.AMBER
        hue < warmHigh -> Band.YELLOW
        hue >= greenLow && hue < greenHigh -> Band.GREEN
        else -> Band.NONE
    }

    internal fun decide(grid: Grid, vertical: Boolean): TrafficLightColor {
        val n = grid.count
        if (!(n > 0 && grid.width > 0 && grid.height > 0 && n == grid.width * grid.height)) return TrafficLightColor.UNKNOWN

        // 1. Candidates and their brightness histogram.
        val candidate = BooleanArray(n)
        val candidateHistogram = IntArray(256)
        val allHistogram = IntArray(256)
        var candidateCount = 0
        for (i in 0 until n) {
            allHistogram[grid.valueLevels[i]] += 1
            if (!(band(grid.hue[i]) != Band.NONE && grid.saturation[i] >= minSaturation && grid.value[i] >= minValue)) continue
            candidate[i] = true
            candidateCount += 1
            candidateHistogram[grid.valueLevels[i]] += 1
        }
        if (candidateCount < minLitPixels) return TrafficLightColor.UNKNOWN

        // 2. Lit pixels relative to the brightest candidates.
        val reference = percentile(candidateHistogram, candidateCount, referencePercentile)
        val litThreshold = max(minValue, relativeValue * reference)

        // 3. Colour masses (weight S·V) and the warm centroid.
        val weight = DoubleArray(n)
        var red = 0.0; var amber = 0.0; var yellow = 0.0; var green = 0.0
        var warmY = 0.0
        var litCount = 0
        for (row in 0 until grid.height) {
            val rowCentre = (row.toDouble() + 0.5) / grid.height.toDouble()
            for (column in 0 until grid.width) {
                val i = row * grid.width + column
                if (!(candidate[i] && grid.value[i] >= litThreshold)) continue
                val w = grid.saturation[i] * grid.value[i]
                weight[i] = w
                litCount += 1
                when (band(grid.hue[i])) {
                    Band.RED -> { red += w; warmY += w * rowCentre }
                    Band.AMBER -> { amber += w; warmY += w * rowCentre }
                    Band.YELLOW -> { yellow += w; warmY += w * rowCentre }
                    Band.GREEN -> green += w
                    Band.NONE -> {}
                }
            }
        }

        // 4. Red halo / position prior.
        val warm = red + amber + yellow
        var redScore = red; var yellowScore = yellow
        if (warm > 0) {
            val centroid = warmY / warm
            if (red >= haloRatio * (amber + yellow)) {
                redScore = warm
                yellowScore = 0.0
            } else if (vertical && centroid < topSectionY && red + amber >= 0.3 * warm) {
                redScore = warm
                yellowScore = 0.0
            } else {
                yellowScore = yellow + amber
            }
        }
        val total = redScore + yellowScore + green
        // Ties resolve red → yellow → green, as in the prototype.
        var best = TrafficLightColor.RED
        var bestScore = redScore
        if (yellowScore > bestScore) {
            best = TrafficLightColor.YELLOW
            bestScore = yellowScore
        }
        if (green > bestScore) {
            best = TrafficLightColor.GREEN
            bestScore = green
        }

        // 6. Guards on the winning colour's pixels.
        if (total > 0) {
            val rows = grid.height; val columns = grid.width
            // Math.rint = round half to even, like Swift `.rounded(.toNearestOrEven)` / Python `round`.
            val ringRows = max(1, Math.rint(rows.toDouble() * ringWidth).toInt())
            val ringColumns = max(1, Math.rint(columns.toDouble() * ringWidth).toInt())
            var winnerMass = 0.0; var innerMass = 0.0; var winnerValue = 0.0
            for (row in 0 until rows) {
                for (column in 0 until columns) {
                    val i = row * columns + column
                    val w = weight[i]
                    if (w <= 0) continue
                    val b = band(grid.hue[i])
                    val counts = when (best) {
                        TrafficLightColor.RED -> b == Band.RED || b == Band.AMBER || b == Band.YELLOW
                        TrafficLightColor.YELLOW -> b == Band.AMBER || b == Band.YELLOW
                        else -> b == Band.GREEN
                    }
                    if (!counts) continue
                    winnerMass += w
                    winnerValue += w * grid.value[i]
                    if (row >= ringRows && row < rows - ringRows && column >= ringColumns && column < columns - ringColumns) {
                        innerMass += w
                    }
                }
            }
            val mass = max(winnerMass, 1e-9)
            if (best == TrafficLightColor.GREEN && rows >= ringMinRows && columns >= ringMinColumns &&
                1 - innerMass / mass > maxRingShare
            ) {
                return TrafficLightColor.UNKNOWN // the colour sits on the box border: sky / foliage, not the lamp
            }
            val housing = percentile(allHistogram, n, housingPercentile)
            if (winnerValue / mass - housing < minContrast) {
                return TrafficLightColor.UNKNOWN // the lamp must be clearly brighter than the (dark) housing
            }
        }

        // 5. Enough lit pixels and a clear winner.
        if (!(litCount >= minLitPixels && litCount.toDouble() / n.toDouble() >= minLitShare && total > 0 &&
                bestScore / total >= minWinnerShare)
        ) return TrafficLightColor.UNKNOWN
        return best
    }
}
