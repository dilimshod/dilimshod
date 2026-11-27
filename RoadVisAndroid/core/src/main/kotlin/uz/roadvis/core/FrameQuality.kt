package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 8-bit grayscale image (row-major, values 0…255). */
class GrayImage(val width: Int, val height: Int, val pixels: IntArray) {
    init {
        require(width >= 0 && height >= 0 && pixels.size >= width * height) { "GrayImage: bad size" }
    }

    operator fun get(x: Int, y: Int): Int = pixels[y * width + x]

    companion object {
        fun filled(width: Int, height: Int, value: Int): GrayImage =
            GrayImage(width, height, IntArray(width * height) { value })
    }
}

/**
 * Frame-quality metrics of the continuous-learning collector (`docs/TRAINING_API.md` §1), computed on a
 * [WIDTH]-px-wide grayscale copy of the frame — identical to `FrameQuality` in the Swift `RoadVisCore` and to the
 * server-side re-check:
 *  - sharpness = variance of the 4-neighbour Laplacian (interior pixels);
 *  - brightness = mean gray value;
 *  - 64-bit dHash: 9×8 area resize, row-wise comparison left > right (bit 63 = row 0, column 0).
 */
object FrameQuality {
    /** Width of the grayscale copy the metrics are defined on, pixels. */
    const val WIDTH = 160

    data class Metrics(val sharpness: Double, val brightness: Double, val dhash: Long) {
        /** 16 lowercase hex digits (the `quality.dhash` value of the upload metadata). */
        val dhashHex: String get() = hex(dhash)
    }

    fun measure(gray: GrayImage): Metrics = Metrics(sharpness(gray), brightness(gray), dHash(gray))

    /** Variance of the 4-neighbour Laplacian over the interior pixels; 0 for images smaller than 3×3. */
    fun sharpness(gray: GrayImage): Double {
        val w = gray.width
        val h = gray.height
        if (w < 3 || h < 3) return 0.0
        val p = gray.pixels
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        for (y in 1 until h - 1) {
            val row = y * w
            for (x in 1 until w - 1) {
                val i = row + x
                val lap = (4 * p[i] - p[i - 1] - p[i + 1] - p[i - w] - p[i + w]).toDouble()
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        val mean = sum / n
        return max(0.0, sumSq / n - mean * mean)
    }

    /** Mean gray value 0…255 (0 for an empty image). */
    fun brightness(gray: GrayImage): Double {
        val count = gray.width * gray.height
        if (count == 0) return 0.0
        var sum = 0L
        for (i in 0 until count) sum += gray.pixels[i]
        return sum.toDouble() / count
    }

    /** 64-bit difference hash: area resize to 9×8, bit = (left > right), row by row, most significant bit first. */
    fun dHash(gray: GrayImage): Long {
        if (gray.width == 0 || gray.height == 0) return 0L
        val small = areaResize(gray, 9, 8)
        var hash = 0L
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                hash = hash shl 1
                if (small[y * 9 + x] > small[y * 9 + x + 1]) hash = hash or 1L
            }
        }
        return hash
    }

    fun hamming(a: Long, b: Long): Int = java.lang.Long.bitCount(a xor b)

    fun hex(hash: Long): String = java.lang.Long.toHexString(hash).padStart(16, '0')

    /** Mean of each output cell over the source pixels it covers (every cell covers at least one pixel). */
    internal fun areaResize(gray: GrayImage, outW: Int, outH: Int): DoubleArray {
        val out = DoubleArray(outW * outH)
        for (oy in 0 until outH) {
            val y0 = min(gray.height - 1, oy * gray.height / outH)
            val y1 = max(y0 + 1, min(gray.height, (oy + 1) * gray.height / outH))
            for (ox in 0 until outW) {
                val x0 = min(gray.width - 1, ox * gray.width / outW)
                val x1 = max(x0 + 1, min(gray.width, (ox + 1) * gray.width / outW))
                var sum = 0L
                for (y in y0 until y1) {
                    val row = y * gray.width
                    for (x in x0 until x1) sum += gray.pixels[row + x]
                }
                out[oy * outW + ox] = sum.toDouble() / ((y1 - y0) * (x1 - x0))
            }
        }
        return out
    }

    /**
     * Grayscale copy of an RGBA (or BGRA) frame scaled to [targetWidth] pixels wide (never upscaled), height in
     * proportion. Each output pixel is the mean BT.601 luma of the source block it covers.
     */
    fun grayFromRGBA(
        bytes: ByteArray, width: Int, height: Int, bytesPerRow: Int = width * 4,
        targetWidth: Int = WIDTH, bgra: Boolean = false,
    ): GrayImage {
        if (width <= 0 || height <= 0) return GrayImage(0, 0, IntArray(0))
        val outW = max(1, min(targetWidth, width))
        val outH = max(1, (height.toDouble() * outW / width).roundToInt())
        val rOff = if (bgra) 2 else 0
        val bOff = if (bgra) 0 else 2
        val pixels = IntArray(outW * outH)
        for (oy in 0 until outH) {
            val y0 = min(height - 1, oy * height / outH)
            val y1 = max(y0 + 1, min(height, (oy + 1) * height / outH))
            for (ox in 0 until outW) {
                val x0 = min(width - 1, ox * width / outW)
                val x1 = max(x0 + 1, min(width, (ox + 1) * width / outW))
                var sum = 0L
                for (y in y0 until y1) {
                    var i = y * bytesPerRow + x0 * 4
                    for (x in x0 until x1) {
                        if (i + 3 > bytes.size) break
                        val r = bytes[i + rOff].toInt() and 0xFF
                        val g = bytes[i + 1].toInt() and 0xFF
                        val b = bytes[i + bOff].toInt() and 0xFF
                        sum += (r * 77 + g * 150 + b * 29) shr 8
                        i += 4
                    }
                }
                pixels[oy * outW + ox] = (sum / ((y1 - y0) * (x1 - x0))).toInt()
            }
        }
        return GrayImage(outW, outH, pixels)
    }
}
