package uz.roadvis.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.tan

/** Pinhole-camera parameters needed for rough monocular distance estimation. */
data class CameraGeometry(
    /** Horizontal field of view of the sensor's long side, degrees. */
    val horizontalFOVDegrees: Double,
    /** Image width in the display orientation, pixels. */
    val imageWidth: Double,
    /** Image height in the display orientation, pixels. */
    val imageHeight: Double,
) {
    /** Focal length in pixels. The FOV refers to the long side of the sensor, whatever the orientation. */
    val focalLengthPixels: Double
        get() {
            val longSide = max(imageWidth, imageHeight)
            val half = horizontalFOVDegrees * PI / 360
            if (!(half > 0 && half < PI / 2)) return longSide
            return (longSide / 2) / tan(half)
        }

    companion object {
        /** Typical phone wide camera, portrait 1080×1920. */
        val defaultPortrait = CameraGeometry(65.0, 1080.0, 1920.0)
    }
}

object MonocularDistance {
    /**
     * Distance along the optical axis: Z = f_px · H_real / h_px.
     * Returns null for boxes that are too small (< 1.5 % of the frame) or too large (> 95 %).
     */
    fun distance(realHeight: Double, normalizedBoxHeight: Double, geometry: CameraGeometry): Double? {
        if (!(realHeight > 0 && normalizedBoxHeight >= 0.015 && normalizedBoxHeight <= 0.95 && geometry.imageHeight > 0)) return null
        val pixelHeight = normalizedBoxHeight * geometry.imageHeight
        val z = geometry.focalLengthPixels * realHeight / pixelHeight
        return if (z.isFinite()) z else null
    }
}

/**
 * Estimates distance and speed of tracked vehicles from the change of their apparent size.
 * Results are rough estimates (single camera, assumed vehicle height) and are shown with "≈".
 */
class MonocularSpeedEstimator(val windowSeconds: Double = 1.5, val maxDistance: Double = 120.0) {
    private data class Sample(val t: Double, val z: Double)

    private val history = HashMap<Int, MutableList<Sample>>()
    private val lastSeen = HashMap<Int, Double>()
    /** Smoothed ground speed per track (EMA), km/h. */
    private val smoothedSpeed = HashMap<Int, Double>()


    fun reset() {
        history.clear()
        lastSeen.clear()
        smoothedSpeed.clear()
    }

    fun update(tracks: List<TrackedObject>, ownSpeedKmh: Double?, geometry: CameraGeometry, timestamp: Double): List<TrackedObject> {
        val result = tracks.map { it.copy() }
        for (t in result) {
            if (t.missed > 0) {
                // Coasted track (predicted box, see `ObjectTracker.Config.coastFrames`): no new sample — a predicted
                // box height is not a measurement. The last measured distance stays on screen; speeds are withheld.
                val recent = (history[t.id] ?: emptyList<Sample>()).takeLast(3).map { it.z }.sorted()
                t.distanceMeters = if (recent.isEmpty()) null else recent[recent.size / 2]
                t.relativeSpeedKmh = null
                t.estimatedSpeedKmh = null
                t.isOncoming = false
                if (recent.isNotEmpty()) lastSeen[t.id] = timestamp
                continue
            }
            val realH = t.kind.typicalHeightMeters
            val z = if (realH != null && t.box.maxY < 0.985 && t.box.minY > 0.005)
                MonocularDistance.distance(realH, t.box.height, geometry) else null
            if (z == null || z > maxDistance) {
                t.distanceMeters = null
                t.relativeSpeedKmh = null
                t.estimatedSpeedKmh = null
                t.isOncoming = false
                continue
            }
            val samples = history.getOrPut(t.id) { mutableListOf() }
            samples.add(Sample(timestamp, z))
            samples.removeAll { timestamp - it.t > windowSeconds }
            lastSeen[t.id] = timestamp

            val recent = samples.takeLast(3).map { it.z }.sorted()
            t.distanceMeters = recent[recent.size / 2]

            t.relativeSpeedKmh = null
            t.estimatedSpeedKmh = null
            t.isOncoming = false
            val first = samples.firstOrNull()
            val slope = if (samples.size >= 4 && first != null && timestamp - first.t >= 0.5) slope(samples) else null
            if (slope != null) {
                val rel = slope * 3.6
                if (abs(rel) <= 150) {
                    t.relativeSpeedKmh = rel
                    val own = ownSpeedKmh
                    // Ground speed of every vehicle (same direction OR oncoming): v_other = |own + rel|, the sign
                    // tells the direction. Needs a longer window, a nearer object and per-track smoothing.
                    if (t.kind.isVehicle && own != null && own >= 0 && first != null &&
                        samples.size >= MIN_SPEED_SAMPLES && timestamp - first.t >= MIN_SPEED_WINDOW && z <= MAX_SPEED_DISTANCE) {
                        val signed = own + rel
                        var absolute = abs(signed)
                        if (absolute < STANDSTILL_KMH) absolute = 0.0
                        if (absolute <= 250) {
                            val previous = smoothedSpeed[t.id]
                            val value = if (previous != null) previous + SPEED_SMOOTHING * (absolute - previous) else absolute
                            smoothedSpeed[t.id] = value
                            t.estimatedSpeedKmh = value
                            t.isOncoming = signed < -STANDSTILL_KMH
                        }
                    }
                }
            }
        }
        val stale = lastSeen.filter { timestamp - it.value > 2 }.keys
        for (id in stale) {
            lastSeen.remove(id)
            history.remove(id)
            smoothedSpeed.remove(id)
        }
        return result
    }

    companion object {
        /** Ground speed needs more evidence than the distance: ≥ 5 samples over ≥ 0.8 s. */
        const val MIN_SPEED_SAMPLES = 5
        const val MIN_SPEED_WINDOW = 0.8
        /** Farther than this the height-based distance is too noisy for a speed. */
        const val MAX_SPEED_DISTANCE = 80.0
        /** Below this the vehicle is shown as standing (noise of the distance slope). */
        const val STANDSTILL_KMH = 4.0
        /** EMA factor of the displayed ground speed (≈ 0.5 s time constant at 15 fps). */
        const val SPEED_SMOOTHING = 0.3
        /** Least-squares slope dz/dt in m/s. */
        private fun slope(s: List<Sample>): Double? {
            val n = s.size.toDouble()
            val meanT = s.sumOf { it.t } / n
            val meanZ = s.sumOf { it.z } / n
            var num = 0.0; var den = 0.0
            for (p in s) {
                num += (p.t - meanT) * (p.z - meanZ)
                den += (p.t - meanT) * (p.t - meanT)
            }
            if (den <= 1e-9) return null
            return num / den
        }
    }
}
