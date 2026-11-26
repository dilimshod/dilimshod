package uz.roadvis.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.tan

// Classical (non-ML) lane-marking detection for the beginner-driver coach.
//
// HONEST SCOPE: a heuristic. It works on clearly painted white / yellow markings in daylight on a reasonably
// straight road. Worn markings, night, rain, glare, tight curves, shadows, zebra crossings and cars covering
// the markings reduce the confidence (the detector then reports low confidence instead of guessing).
//
// Pipeline (all on a small downsampled single-channel image, ≤ 200 px wide):
//  1. `LaneImage.fromBGRA` builds a "marking brightness" channel: luma, with yellow pixels lifted to white level.
//  2. ROI = rows between `EgoCorridor.horizonY` (+ margin) and `roiBottom`.
//  3. Per row: bright-ridge test ("dark–light–dark") + local-contrast test + minimum brightness.
//  4. Hough voting separately for the left and the right half with slope constraints, then least-squares refit.
//     The three thresholds adapt per frame to the measured pixel noise and road brightness (`adaptiveThresholds`),
//     and the marking image is the pixel-wise maximum of the last `accumulateFrames` lane frames (dashed lines).
//  5. Temporal smoothing (EMA of the line end points, outlier rejection, confidence decay when missed).
//  6. The intersection of the two raw fits (vanishing point) is published per frame for `LaneHorizonEstimator`.
// Mirror of the Swift core; the evidence quoted there is synthetic images only (nothing verified on real video).

/** Single-channel 8-bit image (row-major, top-left origin). [pixels] holds unsigned bytes (read with `and 0xFF`). */
class LaneImage(val width: Int, val height: Int, val pixels: ByteArray) {
    init {
        require(pixels.size == width * height) { "pixel count must be width × height" }
    }

    constructor(width: Int, height: Int, fill: Int = 0) :
        this(width, height, ByteArray(max(0, width * height)) { fill.toByte() })

    /** Pixel value 0…255. */
    operator fun get(x: Int, y: Int): Int = pixels[y * width + x].toInt() and 0xFF
    operator fun set(x: Int, y: Int, value: Int) { pixels[y * width + x] = value.coerceIn(0, 255).toByte() }

    companion object {
        /** "Marking brightness" of one pixel: luma, but saturated yellow (road-marking yellow) counts as bright. */
        fun markingValue(r: Int, g: Int, b: Int): Int {
            val luma = (77 * r + 150 * g + 29 * b) shr 8
            val rg = (r + g) / 2
            var value = luma
            if (r > 110 && g > 85 && rg - b > 45) {
                value = max(value, min(255, rg + (rg - b) / 2))
            }
            return value.coerceIn(0, 255)
        }

        /**
         * Downsamples a 4-byte-per-pixel buffer (BGRA by default; RGBA with [bgra] = false) to [targetWidth]
         * (aspect kept) and converts it to marking brightness. Rows above [roiTop] (fraction) are left black.
         * Each output pixel max-pools 2×2-averaged samples taken every 2 source pixels across its cell.
         */
        fun fromBGRA(
            base: ByteArray, width: Int, height: Int, bytesPerRow: Int,
            targetWidth: Int = 160, roiTop: Double = 0.0, bgra: Boolean = true,
        ): LaneImage {
            if (!(width > 1 && height > 1 && targetWidth > 1)) return LaneImage(0, 0)
            val outW = min(targetWidth, width)
            val scale = width.toDouble() / outW
            val outH = max(1, (height / scale).toInt())
            val image = LaneImage(outW, outH)
            val firstRow = max(0, min(outH, (outH * max(0.0, min(1.0, roiTop))).toInt()))
            val rOff = if (bgra) 2 else 0
            val bOff = if (bgra) 0 else 2
            fun u(i: Int) = base[i].toInt() and 0xFF
            for (oy in firstRow until outH) {
                val sy = min(height - 2, ((oy + 0.5) * scale).toInt())
                val row0 = sy * bytesPerRow
                val row1 = row0 + bytesPerRow
                for (ox in 0 until outW) {
                    val x0 = min(width - 2, (ox * scale).toInt())
                    val x1 = max(x0 + 1, min(width - 1, ((ox + 1) * scale).toInt()))
                    var best = 0
                    var sx = x0
                    while (sx < x1) {
                        val p = min(sx, width - 2) * 4
                        val b = (u(row0 + p + bOff) + u(row0 + p + 4 + bOff) + u(row1 + p + bOff) + u(row1 + p + 4 + bOff)) shr 2
                        val g = (u(row0 + p + 1) + u(row0 + p + 5) + u(row1 + p + 1) + u(row1 + p + 5)) shr 2
                        val r = (u(row0 + p + rOff) + u(row0 + p + 4 + rOff) + u(row1 + p + rOff) + u(row1 + p + 4 + rOff)) shr 2
                        best = max(best, markingValue(r, g, b))
                        sx += 2
                    }
                    image.pixels[oy * outW + ox] = best.toByte()
                }
            }
            return image
        }
    }
}

/** A lane line in normalized image coordinates (top-left origin), from the bottom of the ROI up toward the horizon. */
data class LaneLine(val bottomX: Double, val bottomY: Double, val topX: Double, val topY: Double) {
    /** x of the (infinite) line at image row y. */
    fun x(atY: Double): Double {
        val dy = bottomY - topY
        if (abs(dy) <= 1e-9) return bottomX
        return bottomX + (topX - bottomX) * (bottomY - atY) / dy
    }
}

enum class LaneSide(val raw: String) {
    LEFT("left"), RIGHT("right");

    companion object {
        fun fromRaw(raw: String): LaneSide? = entries.firstOrNull { it.raw == raw }
    }
}

/** Result of the lane detector for one frame (smoothed). */
data class LaneEstimate(
    /** Left marking of the own lane (null when not found / confidence decayed). */
    val left: LaneLine?,
    /** Right marking of the own lane. */
    val right: LaneLine?,
    val leftConfidence: Double,
    val rightConfidence: Double,
    /** Lane centre at the reference row (bottom of the ROI), normalized x. */
    val laneCenterX: Double?,
    /** Ego position inside the lane: −1 = on the left line, 0 = centre, +1 = on the right line. */
    val egoOffset: Double?,
    /** Overall confidence 0…1 (heuristic, not a probability). */
    val confidence: Double,
    /** Row (normalized y) where `laneCenterX` / `egoOffset` are evaluated. */
    val referenceY: Double,
    val timestamp: Double,
) {
    fun line(side: LaneSide): LaneLine? = if (side == LaneSide.LEFT) left else right
    fun confidence(side: LaneSide): Double = if (side == LaneSide.LEFT) leftConfidence else rightConfidence

    companion object {
        fun empty(timestamp: Double = 0.0, referenceY: Double = 0.95): LaneEstimate =
            LaneEstimate(null, null, 0.0, 0.0, null, null, 0.0, referenceY, timestamp)
    }
}

/** Raw per-frame line fit (before smoothing), pixel coordinates of the analysed image. */
data class LaneLineFit(
    /** x at the bottom ROI row and at the horizon row, pixels. */
    val bottomX: Double,
    val horizonX: Double,
    /** Number of inlier pixels and distinct inlier rows. */
    val inliers: Int,
    val rows: Int,
    /** Raw confidence 0…1 (row coverage, residual). */
    val confidence: Double,
)

/** A marking candidate pixel. */
data class LanePoint(val x: Int, val y: Int)

/** Detects the own-lane markings in [LaneImage]s and smooths them over time. Not thread-safe. */
class LaneDetector(var config: Config = Config()) {
    data class Config(
        /** Horizon row (fraction of the height); the ROI starts a little below it. */
        val horizonY: Double = EgoCorridor.default.horizonY,
        /** Extra margin below the horizon where the ROI starts (fraction of the height). */
        val roiTopMargin: Double = 0.04,
        /** Bottom of the ROI (excludes the bonnet / phone mount edge). */
        val roiBottom: Double = 0.96,
        /** Horizontal ego reference (camera centre), normalized x. */
        val egoX: Double = 0.5,
        /** Minimum brightness of a marking pixel (0…255). */
        val minBrightness: Int = 85,
        /** Required brightness above the ± d neighbours (ridge test). */
        val ridgeContrast: Int = 14,
        /** Required brightness above the local road brightness (box mean ±W/8). */
        val localContrast: Int = 18,
        /** Expected marking width at the bottom row, fraction of the image width. */
        val markingWidthAtBottom: Double = 0.035,
        /** Allowed line angle to the horizontal, degrees. */
        val minAngleDegrees: Double = 18.0,
        val maxAngleDegrees: Double = 86.0,
        /** Distinct inlier rows needed (fraction of ROI rows) for a line to count. */
        val minRowCoverage: Double = 0.12,
        /** Row coverage at which the raw confidence saturates at 1. */
        val fullRowCoverage: Double = 0.45,
        /** EMA weight of a new observation (1 = no smoothing). */
        val smoothing: Double = 0.4,
        /** Confidence multiplier per frame without a detection. */
        val missDecay: Double = 0.8,
        /**
         * Typical lane width at the reference row (normalized) used when only one line is visible. The value (and the
         * 0.25…2.2 plausibility limits of `process`) is for a 16:9 LANDSCAPE frame; for other frame shapes they are
         * multiplied by [LaneDetector.aspectScale] (≈ 3.16 for 9:16 portrait).
         */
        val defaultLaneWidth: Double = 0.9,
        /**
         * Derive `minBrightness` / `ridgeContrast` / `localContrast` per frame from the pixel noise and the road
         * brightness of the ROI ([LaneDetector.adaptiveThresholds]). The three configured values then act as the upper
         * bound of the brightness floor and as the fallback when the ROI is too small to sample.
         */
        val adaptiveThresholds: Boolean = true,
        /** The detector analyses the pixel-wise maximum of the last this-many lane frames (1 = single frame). */
        val accumulateFrames: Int = defaultAccumulateFrames,
    ) {
        companion object {
            /** Frames accumulated by default (value from the Swift core; measured there on synthetic images only). */
            const val defaultAccumulateFrames: Int = 3
        }
    }

    /** Per-frame candidate thresholds. */
    data class Thresholds(val minBrightness: Int, val ridgeContrast: Int, val localContrast: Int)

    private data class SideState(var bottomX: Double, var topX: Double, var confidence: Double, var outliers: Int = 0)

    private var left: SideState? = null
    private var right: SideState? = null
    private var laneWidth: Double = config.defaultLaneWidth
    /** Aspect factor of the frames seen so far (1 until the first frame); a change (rotation) restarts the state. */
    private var aspect: Double = 1.0
    /** Previous lane frames (newest last) for the pixel-wise maximum, with the horizon they were analysed with. */
    private val previousImages = ArrayList<Pair<LaneImage, Double>>()
    private var accumulationHorizon: Double = -1.0
    /** Vanishing point of the two RAW fits of the last processed frame (null unless both lines were fitted). */
    var lastVanishingPoint: LaneVanishingPoint? = null
        private set

    fun reset() {
        left = null
        right = null
        laneWidth = config.defaultLaneWidth * aspect
        previousImages.clear()
        lastVanishingPoint = null
    }

    /**
     * Changes the horizon row and keeps the smoothed lines where they are in the image (their stored top x is the x
     * AT the horizon row, so it is re-evaluated at the new row). Use this instead of replacing `config` while the
     * detector is running.
     */
    fun setHorizon(horizonY: Double) {
        val old = config.horizonY
        if (!(horizonY.isFinite() && abs(horizonY - old) > 1e-9)) return
        val span = config.roiBottom - old
        if (abs(span) > 1e-6) {
            val factor = (config.roiBottom - horizonY) / span
            left?.let { it.topX = it.bottomX + (it.topX - it.bottomX) * factor }
            right?.let { it.topX = it.bottomX + (it.topX - it.bottomX) * factor }
        }
        config = config.copy(horizonY = horizonY)
    }

    /**
     * Pixel-wise maximum of [image] and the recent frames (same size, same horizon, close in time). Dashed lines show
     * only part of their strokes on one frame; the car's forward motion moves them along the same image line.
     */
    private fun accumulated(image: LaneImage, timestamp: Double): LaneImage {
        val frames = max(1, config.accumulateFrames)
        if (abs(accumulationHorizon - config.horizonY) > 1e-9) {
            // Rows above the horizon are blanked by the caller; frames made for another horizon do not mix.
            previousImages.clear()
            accumulationHorizon = config.horizonY
        }
        previousImages.removeAll {
            it.first.width != image.width || it.first.height != image.height ||
                timestamp - it.second > accumulateMaxGap * (frames - 1).toDouble() || timestamp < it.second
        }
        val newest = previousImages.lastOrNull()
        if (newest != null && timestamp - newest.second > accumulateMaxGap) previousImages.clear()
        var result = image
        if (frames > 1 && previousImages.isNotEmpty()) {
            val out = image.pixels.copyOf()
            for (entry in previousImages) {
                val other = entry.first.pixels
                val n = min(out.size, other.size)
                for (i in 0 until n) {
                    if ((other[i].toInt() and 0xFF) > (out[i].toInt() and 0xFF)) out[i] = other[i]
                }
            }
            result = LaneImage(image.width, image.height, out)
        }
        if (frames > 1) {
            previousImages.add(image to timestamp)
            while (previousImages.size > frames - 1) previousImages.removeAt(0)
        } else {
            previousImages.clear()
        }
        return result
    }

    /** Analyses one frame and returns the smoothed estimate. */
    fun process(image: LaneImage, timestamp: Double): LaneEstimate {
        val k = aspectScale(image.width, image.height)
        if (abs(k - aspect) > 0.01) {
            // Frame shape changed (rotation, first frame): normalized x of the old state means something else.
            aspect = k
            left = null
            right = null
            laneWidth = config.defaultLaneWidth * k
        }
        val analysed = accumulated(image, timestamp)
        val fits = detectLines(analysed, config)
        val w = max(1, image.width).toDouble()
        lastVanishingPoint = vanishingPoint(fits.first, fits.second, w, max(1, image.height).toDouble(), config)
        left = smooth(left, fits.first, w, k, config)
        right = smooth(right, fits.second, w, k, config)
        val l = left; val r = right
        if (l != null && r != null) {
            val width = r.bottomX - l.bottomX
            // Crossing check at the MIDDLE row of the ROI, not at the configured horizon: two correct lines meet at
            // the REAL horizon and are crossed above it, so with a configured horizon above the real one the old
            // check halved the weaker side on every frame.
            val span = config.roiBottom - config.horizonY
            val roiTop = config.horizonY + config.roiTopMargin
            val middle = (roiTop + config.roiBottom) / 2
            val f = if (abs(span) > 1e-6) (config.roiBottom - middle) / span else 1.0
            val leftTop = l.bottomX + (l.topX - l.bottomX) * f
            val rightTop = r.bottomX + (r.topX - r.bottomX) * f
            // Only the upper limit scales with the aspect (the lower one is a sanity bound for any frame shape).
            if (width < minLaneWidth || width > maxLaneWidthLandscape * k || rightTop < leftTop - crossingTolerance) {
                if (l.confidence < r.confidence) l.confidence *= 0.5 else r.confidence *= 0.5
            } else if (l.confidence >= 0.5 && r.confidence >= 0.5) {
                laneWidth += 0.1 * (width - laneWidth)
            }
        }
        if ((left?.confidence ?: 0.0) < 0.08) left = null
        if ((right?.confidence ?: 0.0) < 0.08) right = null
        return makeEstimate(timestamp)
    }

    private fun makeEstimate(timestamp: Double): LaneEstimate {
        val topY = min(config.roiBottom - 0.05, config.horizonY + 0.02)
        val refY = config.roiBottom
        fun line(s: SideState?): LaneLine? {
            if (s == null) return null
            val full = LaneLine(s.bottomX, refY, s.topX, config.horizonY)
            return LaneLine(s.bottomX, refY, full.x(topY), topY)
        }
        val l = left; val r = right
        val lc = l?.confidence ?: 0.0; val rc = r?.confidence ?: 0.0
        var center: Double? = null
        var half: Double? = null
        if (l != null && r != null && r.bottomX > l.bottomX) {
            center = (l.bottomX + r.bottomX) / 2
            half = (r.bottomX - l.bottomX) / 2
        } else if (l != null) {
            center = l.bottomX + laneWidth / 2
            half = laneWidth / 2
        } else if (r != null) {
            center = r.bottomX - laneWidth / 2
            half = laneWidth / 2
        }
        var offset: Double? = null
        if (center != null && half != null && half > 0.01) {
            offset = max(-3.0, min(3.0, (config.egoX - center) / half))
        }
        val overall = if (l != null && r != null) (lc + rc) / 2 else max(lc, rc) * 0.6
        return LaneEstimate(line(l), line(r), lc, rc, center, offset, overall, refY, timestamp)
    }

    companion object {
        /** Lane frames further apart than this are not accumulated, seconds (the lane detector runs at ≈ 5 Hz). */
        internal const val accumulateMaxGap: Double = 0.5
        /** The two lines may cross by this much at the middle row of the ROI before the weaker side is distrusted. */
        internal const val crossingTolerance: Double = 0.05
        /** Plausible lane width at the ROI bottom for a 16:9 landscape frame, fractions of the image width. */
        internal const val minLaneWidth: Double = 0.25
        internal const val maxLaneWidthLandscape: Double = 2.2
        /** Bottom-x jump (fraction of the width, landscape) above which a new fit is treated as a stray line. */
        internal const val bottomJumpLandscape: Double = 0.15

        /**
         * Lane-width factor of a frame relative to 16:9 landscape: (H / W) ÷ (9 / 16). 1 for 16:9 landscape, ≈ 3.16
         * for 9:16 portrait, 1.33 for 4:3 landscape. Clamped to 0.75…4.
         */
        fun aspectScale(width: Int, height: Int): Double {
            if (!(width > 0 && height > 0)) return 1.0
            return min(4.0, max(0.75, (height.toDouble() / width.toDouble()) / (9.0 / 16.0)))
        }

        // Adaptive candidate thresholds (factors from the Swift core, measured there on SYNTHETIC images only).
        /** Ridge contrast = this × noise (median |p[x] − p[x+2]| of the ROI)… */
        internal const val adaptiveRidgeFactor: Double = 3.0
        /** …clamped to this range. */
        internal const val adaptiveRidgeMin: Int = 8
        internal const val adaptiveRidgeMax: Int = 40
        /** Local contrast = this × noise… */
        internal const val adaptiveLocalFactor: Double = 3.5
        internal const val adaptiveLocalMin: Int = 10
        internal const val adaptiveLocalMax: Int = 45
        /** Lowest brightness floor (the floor is road median + local contrast, at most `Config.minBrightness`). */
        internal const val adaptiveMinBrightnessFloor: Int = 30
        /** Sampling of the ROI for the noise estimate: every 4th row, every 3rd pixel. */
        internal const val adaptiveRowStep: Int = 4
        internal const val adaptivePixelStep: Int = 3

        /**
         * Per-frame candidate thresholds from the ROI's pixel noise and median brightness; [config]'s own values when
         * `config.adaptiveThresholds` is off or the ROI is too small.
         */
        fun adaptiveThresholds(image: LaneImage, config: Config): Thresholds {
            val fixed = Thresholds(config.minBrightness, config.ridgeContrast, config.localContrast)
            if (!config.adaptiveThresholds) return fixed
            val w = image.width; val h = image.height
            if (w < 16 || h < 16) return fixed
            val yTop = max(1, (h * min(0.95, config.horizonY + config.roiTopMargin)).toInt())
            val yBottom = min(h - 1, (h * config.roiBottom).toInt())
            if (yBottom - yTop < 6) return fixed
            // Histograms instead of sorting (values are 0…255).
            val diffHistogram = IntArray(256)
            val valueHistogram = IntArray(256)
            var count = 0
            val px = image.pixels
            var y = yTop
            while (y <= yBottom) {
                val row = y * w
                var x = 0
                while (x + 2 < w) {
                    val a = px[row + x].toInt() and 0xFF
                    val b = px[row + x + 2].toInt() and 0xFF
                    diffHistogram[abs(a - b)] += 1
                    valueHistogram[a] += 1
                    count += 1
                    x += adaptivePixelStep
                }
                y += adaptiveRowStep
            }
            if (count < 32) return fixed
            fun median(histogram: IntArray): Int {
                // Element at index count / 2 of the sorted samples.
                var seen = 0
                for (value in histogram.indices) {
                    seen += histogram[value]
                    if (seen > count / 2) return value
                }
                return 255
            }
            val noise = median(diffHistogram).toDouble()
            val road = median(valueHistogram)
            // Math.round on non-negative values = Swift `.rounded()` (half away from zero).
            val ridge = min(adaptiveRidgeMax, max(adaptiveRidgeMin, Math.round(adaptiveRidgeFactor * noise).toInt()))
            val local = min(adaptiveLocalMax, max(adaptiveLocalMin, Math.round(adaptiveLocalFactor * noise).toInt()))
            val brightness = min(config.minBrightness, max(adaptiveMinBrightnessFloor, road + local))
            return Thresholds(brightness, ridge, local)
        }

        /** Intersection of the two raw fits of one frame (null unless both exist and are not parallel). */
        fun vanishingPoint(left: LaneLineFit?, right: LaneLineFit?, width: Double, height: Double, config: Config): LaneVanishingPoint? {
            if (left == null || right == null || !(width > 0 && height > 0)) return null
            // Same rows as `detectLines`: the fits give x at the ROI bottom row and at the configured horizon row.
            val yb = min(height.toInt() - 1, (height * config.roiBottom).toInt()).toDouble()
            val yh = height * config.horizonY
            val dl = left.horizonX - left.bottomX; val dr = right.horizonX - right.bottomX
            val denominator = dl - dr
            if (abs(denominator) <= 1e-6) return null
            val u = (right.bottomX - left.bottomX) / denominator // fraction of (yb − yh) above the bottom row
            val x = left.bottomX + dl * u
            val y = yb - u * (yb - yh)
            if (!(x.isFinite() && y.isFinite())) return null
            return LaneVanishingPoint(x / width, y / height, min(left.confidence, right.confidence))
        }

        private fun smooth(state: SideState?, fit: LaneLineFit?, width: Double, aspect: Double, config: Config): SideState? {
            if (fit == null) {
                val s = state?.copy() ?: return null
                s.confidence *= config.missDecay
                return s
            }
            val bx = fit.bottomX / width; val tx = fit.horizonX / width
            val s = state?.copy() ?: return SideState(bx, tx, fit.confidence * 0.6)
            // The bottom x is extrapolated far outside a portrait frame, so only its threshold scales with the aspect.
            val jump = abs(bx - s.bottomX) > bottomJumpLandscape * aspect || abs(tx - s.topX) > 0.1
            if (jump && s.confidence >= 0.3 && s.outliers < 2) {
                s.outliers += 1
                s.confidence *= config.missDecay
                return s
            }
            val a = if (jump) 0.8 else min(1.0, max(0.05, config.smoothing))
            s.bottomX += a * (bx - s.bottomX)
            s.topX += a * (tx - s.topX)
            s.confidence += 0.4 * (fit.confidence - s.confidence)
            s.outliers = 0
            return s
        }

        /** Marking candidate pixels of the ROI (pixel coordinates). */
        fun candidatePoints(image: LaneImage, config: Config): List<LanePoint> {
            val w = image.width; val h = image.height
            if (w < 16 || h < 16) return emptyList()
            val yTop = max(1, (h * min(0.95, config.horizonY + config.roiTopMargin)).toInt())
            val yBottom = min(h - 1, (h * config.roiBottom).toInt())
            if (yBottom - yTop < 6) return emptyList()
            val thresholds = adaptiveThresholds(image, config)
            val minBrightness = thresholds.minBrightness
            val ridgeContrast = thresholds.ridgeContrast
            val localContrast = thresholds.localContrast
            val window = max(4, w / 8)
            val points = ArrayList<LanePoint>(1024)
            val prefix = IntArray(w + 1)
            val px = image.pixels
            for (y in yTop..yBottom) {
                val row = y * w
                for (x in 0 until w) prefix[x + 1] = prefix[x] + (px[row + x].toInt() and 0xFF)
                val t = (y - yTop).toDouble() / max(1, yBottom - yTop)
                val d = max(2, ((0.25 + 0.75 * t) * config.markingWidthAtBottom * w + 1).toInt())
                if (w <= 2 * d + 2) continue
                for (x in d until (w - d)) {
                    val v = px[row + x].toInt() and 0xFF
                    if (v < minBrightness) continue
                    val l = px[row + x - d].toInt() and 0xFF
                    val r = px[row + x + d].toInt() and 0xFF
                    if (v - max(l, r) < ridgeContrast) continue
                    val a = max(0, x - window); val b = min(w, x + window + 1)
                    val mean = (prefix[b] - prefix[a]) / max(1, b - a)
                    if (v - mean < localContrast) continue
                    points.add(LanePoint(x, y))
                }
            }
            return points
        }

        /** Hough + least-squares line fits for the left (first) and the right (second) half. */
        fun detectLines(image: LaneImage, config: Config): Pair<LaneLineFit?, LaneLineFit?> {
            val points = candidatePoints(image, config)
            if (points.size < 6) return Pair(null, null)
            val w = image.width.toDouble(); val h = image.height.toDouble()
            val yb = min(image.height - 1, (h * config.roiBottom).toInt()).toDouble()
            val yh = h * config.horizonY
            val yTop = max(1, (h * min(0.95, config.horizonY + config.roiTopMargin)).toInt()).toDouble()
            val roiRows = max(1, (yb - yTop).toInt() + 1)
            val egoPx = config.egoX * w
            val leftPts = ArrayList<DoubleArray>()
            val rightPts = ArrayList<DoubleArray>()
            for (p in points) {
                val pt = doubleArrayOf(p.x.toDouble(), p.y.toDouble())
                if (pt[0] < egoPx) leftPts.add(pt) else rightPts.add(pt)
            }
            val k = aspectScale(image.width, image.height)
            val leftFit = fitSide(leftPts, LaneSide.LEFT, w, yb, yh, roiRows, k, config)
            val rightFit = fitSide(rightPts, LaneSide.RIGHT, w, yb, yh, roiRows, k, config)
            return Pair(leftFit, rightFit)
        }

        private fun fitSide(
            pts: List<DoubleArray>, side: LaneSide, w: Double, yb: Double, yh: Double,
            roiRows: Int, aspect: Double, config: Config,
        ): LaneLineFit? {
            if (pts.size < 6) return null
            val sMin = 1 / tan(config.maxAngleDegrees * PI / 180)
            val sMax = 1 / tan(config.minAngleDegrees * PI / 180)
            val slopeBins = 48
            // Bottom-intercept range: one image width beyond the frame in 16:9 landscape, `aspect` widths for taller
            // frames (in portrait the own-lane lines reach the ROI bottom ≈ 0.9 widths outside the frame).
            val binWidth = max(1.0, w / 80 * max(1.0, aspect / 2))
            val xbMin = if (side == LaneSide.LEFT) -w * aspect else 0.35 * w
            val xbMax = if (side == LaneSide.LEFT) 0.65 * w else (1 + aspect) * w
            val xbBins = max(1, ((xbMax - xbMin) / binWidth).toInt() + 1)
            val horizonMin = 0.12 * w; val horizonMax = 0.88 * w
            val acc = IntArray(slopeBins * xbBins)
            val slopes = DoubleArray(slopeBins)
            for (k in 0 until slopeBins) {
                val mag = sMin + (sMax - sMin) * k.toDouble() / (slopeBins - 1).toDouble()
                slopes[k] = if (side == LaneSide.LEFT) mag else -mag
            }
            val dyh = yb - yh
            for (p in pts) {
                val up = yb - p[1]
                for (k in 0 until slopeBins) {
                    val s = slopes[k]
                    val xb = p[0] - s * up
                    if (!(xb >= xbMin && xb < xbMax)) continue
                    val xh = xb + s * dyh
                    if (!(xh >= horizonMin && xh <= horizonMax)) continue
                    acc[k * xbBins + ((xb - xbMin) / binWidth).toInt()] += 1
                }
            }
            var best = -1
            for (i in acc.indices) if (best < 0 || acc[i] > acc[best]) best = i
            if (best < 0 || acc[best] < 6) return null
            var s = slopes[best / xbBins]
            var xb = xbMin + ((best % xbBins).toDouble() + 0.5) * binWidth

            var inliers: List<DoubleArray> = emptyList()
            for (tolerance in doubleArrayOf(max(2.0, w / 60), max(1.5, w / 100))) {
                val s0 = s; val xb0 = xb
                inliers = pts.filter { abs(it[0] - (xb0 + s0 * (yb - it[1]))) <= tolerance }
                if (inliers.size < 6) return null
                val n = inliers.size.toDouble()
                val mu = inliers.sumOf { yb - it[1] } / n
                val mx = inliers.sumOf { it[0] } / n
                var num = 0.0; var den = 0.0
                for (q in inliers) {
                    val u = yb - q[1] - mu
                    num += u * (q[0] - mx)
                    den += u * u
                }
                if (den <= 1e-6) return null
                val fitted = num / den
                if (!((if (side == LaneSide.LEFT) fitted else -fitted) >= sMin * 0.8 && abs(fitted) <= sMax * 1.2)) return null
                s = fitted
                xb = mx - s * mu
            }
            val rows = inliers.map { it[1].toInt() }.toSet().size
            val coverage = rows.toDouble() / roiRows
            if (coverage < config.minRowCoverage) return null
            val residual = inliers.sumOf { abs(it[0] - (xb + s * (yb - it[1]))) } / inliers.size
            val residualFactor = max(0.3, 1 - residual / max(2.0, w / 40))
            val confidence = min(1.0, coverage / config.fullRowCoverage) * residualFactor
            return LaneLineFit(xb, xb + s * (yb - yh), inliers.size, rows, confidence)
        }
    }
}

/**
 * Lane-departure warning logic: a departure is reported when the ego reference point comes within the margin of a
 * confident lane line (|egoOffset| ≥ `triggerOffset`) for at least `minDuration` seconds while driving at least
 * `minSpeedKmh`, at most once per `cooldown` and re-armed only after returning toward the lane centre.
 */
class LaneDepartureDetector(var config: Config = Config()) {
    data class Config(
        val minSpeedKmh: Double = 40.0,
        val minDuration: Double = 0.4,
        /** |egoOffset| at which the car is considered to touch the marking. */
        val triggerOffset: Double = 0.6,
        /** Back below this |offset| re-arms the warning. */
        val rearmOffset: Double = 0.4,
        /** Minimum confidence of the line on the departure side. */
        val minLineConfidence: Double = 0.45,
        val cooldown: Double = 5.0,
        /** Estimates older than this are ignored. */
        val maxAge: Double = 0.6,
    )

    private var candidateSide: LaneSide? = null
    private var candidateSince: Double? = null
    private var armed = true
    private var lastWarning = Double.NEGATIVE_INFINITY
    /** Side the car is currently drifting over (for the overlay), null when inside the lane. */
    var activeSide: LaneSide? = null
        private set

    fun reset() {
        candidateSide = null
        candidateSince = null
        armed = true
        activeSide = null
    }

    /** Feeds one estimate; returns the side when a NEW departure warning should be given. */
    fun update(estimate: LaneEstimate?, speedKmh: Double?, timestamp: Double): LaneSide? {
        val offset = estimate?.egoOffset
        if (estimate == null || timestamp - estimate.timestamp > config.maxAge || offset == null ||
            (speedKmh ?: 0.0) < config.minSpeedKmh
        ) {
            candidateSide = null; candidateSince = null; activeSide = null
            return null
        }
        val side = if (offset < 0) LaneSide.LEFT else LaneSide.RIGHT
        val confident = estimate.line(side) != null && estimate.confidence(side) >= config.minLineConfidence
        if (abs(offset) < config.rearmOffset) armed = true
        if (!(confident && abs(offset) >= config.triggerOffset)) {
            candidateSide = null; candidateSince = null; activeSide = null
            return null
        }
        if (candidateSide != side) {
            candidateSide = side
            candidateSince = timestamp
        }
        val since = candidateSince
        if (since == null || timestamp - since < config.minDuration) return null
        activeSide = side
        if (!(armed && timestamp - lastWarning >= config.cooldown)) return null
        armed = false
        lastWarning = timestamp
        return side
    }
}
