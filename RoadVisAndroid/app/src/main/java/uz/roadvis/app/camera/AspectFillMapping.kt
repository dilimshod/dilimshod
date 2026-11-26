package uz.roadvis.app.camera

import uz.roadvis.core.BBox
import kotlin.math.max

/** A rectangle in view pixels. */
data class ViewRect(val left: Float, val top: Float, val width: Float, val height: Float) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
    val centerX: Float get() = left + width / 2
    val centerY: Float get() = top + height / 2
    fun contains(x: Float, y: Float): Boolean = x in left..right && y in top..bottom
}

/**
 * Maps normalized image coordinates (top-left origin, 0…1, relative to the processed upright analysis frame) onto a
 * view that shows the camera picture with aspect-fill, centred — the geometry of `PreviewView.ScaleType.FILL_CENTER`
 * (port of iOS `AspectFillMapping`). `scale = max(viewW / imgW, viewH / imgH)`; the overflowing sides are cropped.
 */
data class AspectFillMapping(
    val displayedWidth: Float,
    val displayedHeight: Float,
    val offsetX: Float,
    val offsetY: Float,
) {
    fun rect(box: BBox): ViewRect = ViewRect(
        offsetX + box.x.toFloat() * displayedWidth,
        offsetY + box.y.toFloat() * displayedHeight,
        box.width.toFloat() * displayedWidth,
        box.height.toFloat() * displayedHeight,
    )

    fun x(nx: Double): Float = offsetX + nx.toFloat() * displayedWidth
    fun y(ny: Double): Float = offsetY + ny.toFloat() * displayedHeight

    /** Normalized image point of a view point (inverse of [x] / [y]). */
    fun normalized(px: Float, py: Float): Pair<Double, Double> {
        if (displayedWidth <= 0f || displayedHeight <= 0f) return 0.0 to 0.0
        return ((px - offsetX) / displayedWidth).toDouble() to ((py - offsetY) / displayedHeight).toDouble()
    }

    companion object {
        fun of(imageWidth: Float, imageHeight: Float, viewWidth: Float, viewHeight: Float): AspectFillMapping {
            if (!(imageWidth > 0 && imageHeight > 0 && viewWidth > 0 && viewHeight > 0)) {
                return AspectFillMapping(viewWidth, viewHeight, 0f, 0f)
            }
            val scale = max(viewWidth / imageWidth, viewHeight / imageHeight)
            val w = imageWidth * scale
            val h = imageHeight * scale
            return AspectFillMapping(w, h, (viewWidth - w) / 2, (viewHeight - h) / 2)
        }
    }
}
