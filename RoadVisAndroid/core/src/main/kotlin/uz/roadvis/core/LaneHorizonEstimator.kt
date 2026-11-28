package uz.roadvis.core

import kotlin.math.abs

/** Vanishing point of the two raw lane-line fits of one frame, normalized image coordinates (top-left origin). */
data class LaneVanishingPoint(
    val x: Double,
    val y: Double,
    /** The lower of the two raw fit confidences. */
    val confidence: Double,
)

/**
 * Estimates the horizon row from the vanishing point of the own-lane markings.
 *
 * The horizon (`EgoCorridor.horizonY`) is shared by the lane detector, the lead-vehicle corridor, the pedestrian
 * roadway zone and the traffic-light selection. On a straight flat road the two lane lines meet on the horizon, so the
 * median of their intersections is the horizon of the phone as it is mounted.
 *
 * EVIDENCE: synthetic images only, on the Swift core (see LaneHorizonEstimator.swift) — no real video. Hills, curves
 * and roads with one visible line give no or biased samples; the caller's speed gate, the spread gate and the range
 * limit are the mitigations. All gate values are reasoning unless stated otherwise.
 */
class LaneHorizonEstimator(initial: Double? = null) {
    private val samples = ArrayList<Double>()

    /** Latest estimate (null until enough consistent samples). */
    var horizonY: Double? = if (initial != null && initial.isFinite() && initial in rowMin..rowMax) initial else null
        private set

    val sampleCount: Int get() = samples.size

    /** Forgets the samples and the estimate (frame shape changed: the horizon row is a different one). */
    fun reset() {
        samples.clear()
        horizonY = null
    }

    /**
     * Feeds the vanishing point of one lane frame ([LaneDetector.lastVanishingPoint]; null = no usable pair of lines).
     * Returns the current estimate.
     */
    fun add(point: LaneVanishingPoint?): Double? {
        if (point == null || !(point.confidence >= minFitConfidence) || !point.x.isFinite() || !point.y.isFinite() ||
            point.y !in rowMin..rowMax || point.x !in columnMin..columnMax
        ) return horizonY
        samples.add(point.y)
        while (samples.size > window) samples.removeAt(0)
        if (samples.size < minSamples) return horizonY
        val sorted = samples.sorted()
        if (sorted[sorted.size * 3 / 4] - sorted[sorted.size / 4] > maxSpread) return horizonY
        horizonY = sorted[sorted.size / 2]
        return horizonY
    }

    companion object {
        /** Both raw fits need at least this confidence for a sample. */
        const val minFitConfidence: Double = 0.5
        /** Samples kept (25 lane frames ≈ 5 s at 5 Hz). */
        const val window: Int = 25
        /** Samples needed before an estimate is given (12 ≈ 2.4 s of good frames). */
        const val minSamples: Int = 12
        /** Accepted vanishing-point rows / columns (fractions of the frame). */
        const val rowMin: Double = 0.20
        const val rowMax: Double = 0.70
        const val columnMin: Double = 0.25
        const val columnMax: Double = 0.75
        /** The interquartile range (p75 − p25) of the window must be at most this for an estimate. */
        const val maxSpread: Double = 0.04
        /** Samples should be fed only at or above this own speed, km/h. */
        const val minSpeedKmh: Double = 30.0
        /** A new estimate replaces the horizon in use only when it differs by more than this. */
        const val applyDelta: Double = 0.015

        /** True when [estimate] should replace the horizon currently in use. */
        fun shouldApply(estimate: Double, current: Double): Boolean = abs(estimate - current) > applyDelta
    }
}
