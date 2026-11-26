package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Finds the audible part of a voice clip so clips can be joined without the leading / trailing silence that
 * text-to-speech files carry (edge-tts adds ≈ 100–700 ms at each end).
 */
object AudioSilenceTrimmer {
    /** Linear amplitude of [decibels] dBFS (−40 dBFS → 0.01). */
    fun amplitude(decibels: Double): Float = 10.0.pow(decibels / 20).toFloat()

    /**
     * Range of sample frames to keep (half-open in Swift; here an [IntRange] `lower until upper`): from the first to
     * the last sample whose magnitude exceeds [thresholdDB] (dBFS, full scale = 1.0), widened by [paddingSeconds] on
     * both sides and clamped to the clip. A clip that never exceeds the threshold keeps a short piece.
     * [samples] is one channel (or the per-frame maximum over channels) of float PCM.
     */
    fun audibleRange(samples: FloatArray, sampleRate: Double, thresholdDB: Double = -40.0, paddingSeconds: Double = 0.03): IntRange {
        val count = samples.size
        if (!(count > 0 && sampleRate > 0)) return 0 until count
        val threshold = amplitude(thresholdDB)
        val padding = max(0, (paddingSeconds * sampleRate).rounded().toInt())
        var first = -1
        for (i in 0 until count) {
            if (abs(samples[i]) > threshold) { first = i; break }
        }
        if (first < 0) return 0 until min(count, max(1, padding))
        var last = first
        var j = count - 1
        while (j > first) {
            if (abs(samples[j]) > threshold) { last = j; break }
            j -= 1
        }
        val lower = max(0, first - padding)
        val upper = min(count, last + 1 + padding)
        return lower until upper
    }

    /** Voice playback-rate factor clamped to the range offered in Settings (0.9…1.4); default 1.1. */
    fun clampedVoiceRate(rate: Double?): Double {
        if (rate == null || !rate.isFinite()) return 1.1
        return min(1.4, max(0.9, rate))
    }
}
