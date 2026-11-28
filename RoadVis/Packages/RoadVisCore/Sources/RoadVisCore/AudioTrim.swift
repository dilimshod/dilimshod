import Foundation

/// Finds the audible part of a voice clip so clips can be joined without the leading / trailing silence that
/// text-to-speech files carry (edge-tts adds ≈ 100–700 ms at each end).
public enum AudioSilenceTrimmer {
    /// Linear amplitude of `decibels` dBFS (−40 dBFS → 0.01).
    public static func amplitude(decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }

    /// Range of sample frames to keep: from the first to the last sample whose magnitude exceeds `thresholdDB`
    /// (dBFS, full scale = 1.0), widened by `paddingSeconds` on both sides and clamped to the clip. A clip that never
    /// exceeds the threshold keeps a short piece (`paddingSeconds`) so callers never get an empty buffer.
    ///
    /// `samples` is one channel (or the per-frame maximum over channels) of float PCM.
    public static func audibleRange(samples: UnsafeBufferPointer<Float>, sampleRate: Double,
                                    thresholdDB: Double = -40, paddingSeconds: Double = 0.03) -> Range<Int> {
        let count = samples.count
        guard count > 0, sampleRate > 0 else { return 0..<count }
        let threshold = amplitude(decibels: thresholdDB)
        let padding = max(0, Int((paddingSeconds * sampleRate).rounded()))
        var first = -1
        for i in 0..<count where abs(samples[i]) > threshold {
            first = i
            break
        }
        guard first >= 0 else { return 0..<min(count, max(1, padding)) }
        var last = first
        var j = count - 1
        while j > first {
            if abs(samples[j]) > threshold {
                last = j
                break
            }
            j -= 1
        }
        let lower = max(0, first - padding)
        let upper = min(count, last + 1 + padding)
        return lower..<upper
    }

    /// Convenience for arrays (tests, offline tools).
    public static func audibleRange(_ samples: [Float], sampleRate: Double, thresholdDB: Double = -40,
                                    paddingSeconds: Double = 0.03) -> Range<Int> {
        samples.withUnsafeBufferPointer {
            audibleRange(samples: $0, sampleRate: sampleRate, thresholdDB: thresholdDB, paddingSeconds: paddingSeconds)
        }
    }

    /// Voice playback-rate factor clamped to the range offered in Settings (0.9…1.4); default 1.1.
    public static func clampedVoiceRate(_ rate: Double?) -> Double {
        guard let rate, rate.isFinite else { return 1.1 }
        return min(1.4, max(0.9, rate))
    }
}
