package uz.roadvis.app.detection

import java.nio.FloatBuffer
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Letterbox geometry of a `srcW × srcH` frame scaled (aspect kept) into a square `size × size` model input, centred,
 * the same convention [uz.roadvis.core.YOLODecoder] undoes with `sourceWidth` / `sourceHeight`.
 */
data class Letterbox(val size: Int, val srcW: Int, val srcH: Int) {
    val gain: Double = if (srcW > 0 && srcH > 0) min(size.toDouble() / srcW, size.toDouble() / srcH) else 1.0
    val scaledW: Int = (srcW * gain).roundToInt().coerceIn(1, size)
    val scaledH: Int = (srcH * gain).roundToInt().coerceIn(1, size)
    val padX: Int = (size - scaledW) / 2
    val padY: Int = (size - scaledH) / 2

    /** Normalized source x of an input-pixel x (inverse mapping, for tests). */
    fun sourceX(inputX: Double): Double = (inputX - (size - srcW * gain) / 2) / gain / srcW
    fun sourceY(inputY: Double): Double = (inputY - (size - srcH * gain) / 2) / gain / srcH

    /**
     * Writes the letterboxed RGB planes (CHW, 0…1, Ultralytics grey padding 114) of an RGBA_8888 frame into [out]
     * (capacity ≥ 3·size²). Nearest-neighbour sampling with precomputed column offsets ([xTable] is reused).
     */
    fun fill(rgba: ByteArray, bytesPerRow: Int, out: FloatBuffer, xTable: IntArray) {
        val plane = size * size
        val pad = 114f / 255f
        out.clear()
        for (i in 0 until scaledW) {
            val sx = min(srcW - 1, ((i + 0.5) / gain).toInt())
            xTable[i] = sx * 4
        }
        val inv = 1f / 255f
        for (y in 0 until size) {
            val rowBase = y * size
            val sy = y - padY
            if (sy < 0 || sy >= scaledH) {
                for (x in 0 until size) {
                    out.put(rowBase + x, pad); out.put(plane + rowBase + x, pad); out.put(2 * plane + rowBase + x, pad)
                }
                continue
            }
            val srcRow = min(srcH - 1, ((sy + 0.5) / gain).toInt()) * bytesPerRow
            for (x in 0 until size) {
                val ix = x - padX
                if (ix < 0 || ix >= scaledW) {
                    out.put(rowBase + x, pad); out.put(plane + rowBase + x, pad); out.put(2 * plane + rowBase + x, pad)
                } else {
                    val p = srcRow + xTable[ix]
                    out.put(rowBase + x, (rgba[p].toInt() and 0xFF) * inv)
                    out.put(plane + rowBase + x, (rgba[p + 1].toInt() and 0xFF) * inv)
                    out.put(2 * plane + rowBase + x, (rgba[p + 2].toInt() and 0xFF) * inv)
                }
            }
        }
        out.position(0)
        out.limit(3 * plane)
    }
}
