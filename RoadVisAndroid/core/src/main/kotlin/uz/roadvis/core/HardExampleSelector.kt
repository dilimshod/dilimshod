package uz.roadvis.core

/** Reasons a frame is kept for training (string raw values of the upload metadata, `docs/TRAINING_API.md` §1). */
object HardExampleReason {
    const val MISSED_DETECTION = "missedDetection"
    const val SHORT_LIVED = "shortLived"
    const val LOW_CONFIDENCE = "lowConfidence"
    const val CLASS_FLIP = "classFlip"
    const val RANDOM = "random"

    /** All reasons in the order they are reported. */
    val all: List<String> = listOf(MISSED_DETECTION, SHORT_LIVED, LOW_CONFIDENCE, CLASS_FLIP, RANDOM)
}

/** Outcome for one frame: keep it or not, and why it was a candidate. */
data class HardExampleDecision(val keep: Boolean, val reasons: List<String>)

/**
 * Decides which processed frames are "hard examples" worth sending to the RoadVis Trainer
 * (`docs/TRAINING_API.md` §1; mirror of `HardExampleSelector` in the Swift `RoadVisCore`).
 *
 * The selector keeps a one-frame memory: [push] takes frame N and evaluates frame N − 1, the frame before it. That
 * is what makes `shortLived` reportable on the frame where the dying track was last detected — only frame N shows
 * that the track is gone. The caller therefore keeps the pixels of the previous frame (the Android worker double
 * buffers them at no extra cost).
 *
 * Two phases keep it cheap: [push] returns a [Candidate] only when a reason fired AND the cheap gates pass (interval,
 * per-trip cap, speed); only then does the caller compute [FrameQuality] on the candidate's pixels and call [decide],
 * which applies the quality gates and the near-duplicate check and records a kept frame.
 *
 * Not thread-safe (use it on the processing thread).
 */
class HardExampleSelector(val config: Config = Config()) {
    data class Config(
        val minIntervalSeconds: Double = 2.0,
        val maxPerTrip: Int = 300,
        /** Frames are kept only at this own speed or more, or while the speed is unknown, km/h. */
        val minSpeedKmh: Double = 5.0,
        val minSharpness: Double = 60.0,
        val minBrightness: Double = 35.0,
        val maxBrightness: Double = 225.0,
        val maxDuplicateHamming: Int = 6,
        /** `lowConfidence`: detections from this score up to (excluding) the class threshold. */
        val lowConfidenceFloor: Double = 0.25,
        /** `missedDetection`: minimum height of the coasting track's predicted box (normalized). */
        val missedMinBoxHeight: Double = 0.04,
        /** `shortLived`: a track that disappears unconfirmed with at most this many hits. */
        val shortLivedMaxHits: Int = 2,
        /** `random`: deterministic 1 % sample, `frameIndex % randomModulus == randomRemainder`. */
        val randomModulus: Long = 100,
        val randomRemainder: Long = 37,
        /** The next frame tells whether a track died only when it follows within this time, seconds. */
        val maxLookaheadGapSeconds: Double = 1.0,
    )

    /** Track as the selector needs it (snapshot; the tracker's [TrackedObject] is mutable). */
    data class Track(
        val id: Int,
        val kind: VehicleKind,
        val confidence: Double,
        val hits: Int,
        val missed: Int,
        val isConfirmed: Boolean,
        /** Box on this frame (predicted while the track is coasting), normalized, top-left origin. */
        val box: BBox,
        /** Class vote changed on this frame; null = unknown, the selector compares with the previous frame. */
        val classFlip: Boolean? = null,
    ) {
        companion object {
            fun from(t: TrackedObject): Track =
                Track(t.id, t.kind, t.confidence, t.hits, t.missed, t.isConfirmed, t.box)
        }
    }

    /** Everything the selector looks at for one processed frame. */
    data class Frame(
        /** Running index of processed frames (drives the `random` sample). */
        val frameIndex: Long,
        /** Seconds, any monotonic clock. */
        val timestamp: Double,
        /** Own speed, km/h; null = unknown. */
        val speedKmh: Double?,
        val tracks: List<Track>,
        /** Raw detections of the frame (before tracking). */
        val detections: List<Detection>,
        /** Per-class detection thresholds in use (classes missing here use [DetectionThresholds.threshold]). */
        val classThresholds: Map<VehicleKind, Double> = DetectionThresholds.perClass(),
    )

    /** A frame that has reasons and passed the cheap gates; [decide] needs its quality metrics. */
    data class Candidate(val frame: Frame, val reasons: List<String>)

    /** Frames kept since the last [resetTrip]. */
    var keptThisTrip: Int = 0
        private set
    /** Candidates rejected by sharpness / brightness / near-duplicate since creation (statistics). */
    var qualityRejections: Int = 0
        private set

    private var lastKeptTimestamp: Double? = null
    private var lastKeptHash: Long? = null
    private var pending: Frame? = null
    private var pendingFlips: Set<Int> = emptySet()

    /** Starts a new trip: the per-trip counter starts from zero (interval and duplicate memory stay). */
    fun resetTrip() {
        keptThisTrip = 0
    }

    /** Forgets the one-frame memory (call it when frames stop or the pixels of the previous frame are gone). */
    fun reset() {
        pending = null
        pendingFlips = emptySet()
    }

    /**
     * Feeds frame N and returns the candidate for frame N − 1 (null when it has no reason or fails a cheap gate).
     */
    fun push(frame: Frame): Candidate? {
        val previous = pending
        val previousFlips = pendingFlips
        pendingFlips = classFlips(frame, previous)
        pending = frame
        if (previous == null) return null
        val gap = frame.timestamp - previous.timestamp
        val next = if (gap > 0 && gap <= config.maxLookaheadGapSeconds) frame else null
        val reasons = reasons(previous, previousFlips, next)
        if (reasons.isEmpty() || !passesCheapGates(previous)) return null
        return Candidate(previous, reasons)
    }

    /** Applies the quality and near-duplicate gates to a candidate; a kept frame updates the interval / cap state. */
    fun decide(candidate: Candidate, quality: FrameQuality.Metrics): HardExampleDecision {
        val frame = candidate.frame
        if (!passesCheapGates(frame)) return HardExampleDecision(false, candidate.reasons)
        val qualityOk = quality.sharpness >= config.minSharpness &&
            quality.brightness >= config.minBrightness && quality.brightness <= config.maxBrightness
        val lastHash = lastKeptHash
        val duplicate = lastHash != null && FrameQuality.hamming(lastHash, quality.dhash) <= config.maxDuplicateHamming
        if (!qualityOk || duplicate) {
            qualityRejections += 1
            return HardExampleDecision(false, candidate.reasons)
        }
        lastKeptTimestamp = frame.timestamp
        lastKeptHash = quality.dhash
        keptThisTrip += 1
        return HardExampleDecision(true, candidate.reasons)
    }

    /** Interval since the last kept frame, per-trip cap, own speed. */
    fun passesCheapGates(frame: Frame): Boolean {
        if (keptThisTrip >= config.maxPerTrip) return false
        val speed = frame.speedKmh
        if (speed != null && speed.isFinite() && speed < config.minSpeedKmh) return false
        val last = lastKeptTimestamp
        // A clock that went backwards (new session) does not block collection.
        if (last != null && frame.timestamp >= last && frame.timestamp - last < config.minIntervalSeconds) return false
        return true
    }

    /**
     * Reasons of [frame], in [HardExampleReason.all] order. [flips] are the IDs of confirmed tracks whose class changed
     * on [frame]; [next] is the following frame (null when unknown or after a gap: no `shortLived`).
     */
    internal fun reasons(frame: Frame, flips: Set<Int>, next: Frame?): List<String> {
        val reasons = ArrayList<String>(2)
        if (frame.tracks.any { isMissedDetection(it) }) reasons.add(HardExampleReason.MISSED_DETECTION)
        if (next != null) {
            val alive = next.tracks.mapTo(HashSet()) { it.id }
            val died = frame.tracks.any {
                !it.isConfirmed && it.missed == 0 && it.hits <= config.shortLivedMaxHits && it.id !in alive
            }
            if (died) reasons.add(HardExampleReason.SHORT_LIVED)
        }
        val lowConfidence = frame.detections.any { d ->
            val threshold = frame.classThresholds[d.kind] ?: DetectionThresholds.threshold(d.kind)
            d.confidence >= config.lowConfidenceFloor && d.confidence < threshold
        }
        if (lowConfidence) reasons.add(HardExampleReason.LOW_CONFIDENCE)
        if (flips.isNotEmpty()) reasons.add(HardExampleReason.CLASS_FLIP)
        if (config.randomModulus > 0 && frame.frameIndex >= 0 &&
            frame.frameIndex % config.randomModulus == config.randomRemainder
        ) {
            reasons.add(HardExampleReason.RANDOM)
        }
        return reasons
    }

    /** A confirmed track coasting with its predicted box fully inside the frame and at least the minimum height. */
    private fun isMissedDetection(t: Track): Boolean {
        if (!t.isConfirmed || t.missed < 1) return false
        val b = t.box
        return b.x >= 0 && b.y >= 0 && b.maxX <= 1 && b.maxY <= 1 && b.height >= config.missedMinBoxHeight
    }

    /** Confirmed tracks of [frame] whose class changed: the explicit flag, else the kind differs from [previous]. */
    private fun classFlips(frame: Frame, previous: Frame?): Set<Int> {
        val previousKinds = previous?.tracks?.associate { it.id to it.kind } ?: emptyMap()
        val flips = HashSet<Int>()
        for (t in frame.tracks) {
            if (!t.isConfirmed) continue
            val flipped = t.classFlip ?: previousKinds[t.id]?.let { it != t.kind } ?: false
            if (flipped) flips.add(t.id)
        }
        return flips
    }
}
