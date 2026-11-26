package uz.roadvis.core

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A detection followed over several frames. Times ([firstSeen], [lastSeen]) are seconds (any monotonic clock). */
data class TrackedObject(
    val id: Int,
    var kind: VehicleKind,
    var label: String,
    /** Smoothed latest box (normalized, top-left origin). */
    var box: BBox,
    /** Latest detector confidence (model score, not accuracy). */
    var confidence: Double,
    var hits: Int = 1,
    /** Consecutive frames without a matching detection. */
    var missed: Int = 0,
    var firstSeen: Double,
    var lastSeen: Double,
    /** True once the object was matched on at least `minHits` frames; only confirmed objects are counted. */
    var isConfirmed: Boolean = false,
    /** Majority vote of make classifications (null until the first observation). */
    var make: String? = null,
    /** Mean confidence of the winning make. */
    var makeConfidence: Double? = null,
    /**
     * Stable traffic-light colour: time-window vote over the recent observations ([TrafficLightColorVote]); null
     * while there are too few readable observations — a colour never outlives ≈ 0.8 s without a readable lamp.
     */
    var lightColor: TrafficLightColor? = null,
    /** Rough monocular distance estimate, metres (see MonocularSpeedEstimator). */
    var distanceMeters: Double? = null,
    /** Rate of change of the distance, km/h; positive = moving away from the camera. */
    var relativeSpeedKmh: Double? = null,
    /** Own speed + relative speed, km/h (only when plausible). */
    var estimatedSpeedKmh: Double? = null,
    /** Majority of recent person-role observations (≥ 5 needed; null before / for non-persons). Colour heuristic. */
    var personRole: PersonRole? = null,
    /**
     * Highest detector confidence the track has had so far. Gates that ask "is this a solid object?" use it instead of
     * the latest frame's score, which dips on single frames (and may sit below the class threshold while a confirmed
     * track is continued by a low-score detection).
     */
    var peakConfidence: Double = confidence,
)

/**
 * Greedy IoU tracker (SORT-like without a Kalman filter): matches detections to existing tracks by IoU,
 * keeps class votes, make votes and traffic-light colour votes per track, and counts unique confirmed objects.
 *
 * Counting rule: an object is counted once, at the moment its track becomes confirmed (`hits >= minHits`).
 * So [uniqueCounts] are tracked objects, while [frameDetectionCount] counts raw per-frame detections.
 */
class ObjectTracker(val config: Config = Config()) {
    data class Config(
        /** IoU above which a detection always matches a predicted track box. */
        val iouThreshold: Double = 0.3,
        /** Confirmed tracks survive this many frames without a detection (predicted meanwhile). */
        val maxMissed: Int = 8,
        /** Detections needed before a track is confirmed (and counted). */
        val minHits: Int = 3,
        /** Weight of the new box when smoothing (1 = no smoothing). */
        val boxSmoothing: Double = 0.6,
        /** Centre-distance gate for fast objects when IoU is low, in units of the box size. 0 disables it. */
        val centerGate: Double = 1.0,
        /** Maximum area ratio between a track box and a detection for a centre-distance match. */
        val maxAreaRatio: Double = 2.5,
        /** Unconfirmed (tentative) tracks are dropped after this many missed frames. */
        val maxMissedTentative: Int = 2,
        /**
         * Per-class minimum detector confidence needed to open a track (classes not listed: no filter). Initial value
         * of [ObjectTracker.minConfidence], which the owner may replace per frame (settings slider).
         */
        val minConfidence: Map<VehicleKind, Double> = defaultMinConfidence,
        /** Kinds counted only when the owner marks the confirmed track relevant ([markRelevant]). */
        val deferredCountKinds: Set<VehicleKind> = emptySet(),
        /**
         * A detection scoring below its class minimum but at least `minimum × continuationFactor` may still continue
         * an already confirmed track (it never opens a track). 1 = off.
         */
        val continuationFactor: Double = DetectionThresholds.CONTINUATION_FACTOR,
        /** Tracks not seen for longer than this are forgotten before matching, seconds (frames may just stop). */
        val maxIdleSeconds: Double = 3.0,
        /**
         * Confirmed tracks without a detection are still RETURNED by `update` for this many frames ("coasting"), with
         * `missed ≥ 1` and the box extrapolated by the constant-velocity model. 0 = only tracks seen on the frame.
         */
        val coastFrames: Int = defaultCoastFrames,
        /**
         * Minimum IoU (predicted track box vs detection) of the second association stage, in which low-score
         * detections continue confirmed tracks that no full-score detection matched.
         */
        val secondIoU: Double = defaultSecondIoU,
    ) {
        companion object {
            /**
             * Coasting length, 3 frames = 0.2 s at 15 fps. The value was measured on the Swift core by replaying a
             * real drive log (see `ObjectTracker.Config.defaultCoastFrames` in Tracking.swift); not re-measured here.
             */
            const val defaultCoastFrames: Int = 3
            /** Second-stage IoU (ByteTrack, arXiv 2110.06864); value from the same Swift-side replay. */
            const val defaultSecondIoU: Double = 0.3
            /** Thresholds at the default slider position, see [DetectionThresholds]. */
            val defaultMinConfidence: Map<VehicleKind, Double> = DetectionThresholds.perClass()
        }
    }

    /**
     * Per-class confidence needed to open a track. Starts as [Config.minConfidence]; the app sets it from the settings
     * slider ([DetectionThresholds.perClass]) — the same table the detector floor is derived from.
     */
    var minConfidence: Map<VehicleKind, Double> = config.minConfidence

    private class MakeVote(var count: Int, var confidenceSum: Double)

    private class State(var obj: TrackedObject) {
        val kindVotes = LinkedHashMap<VehicleKind, Double>()
        val makeVotes = LinkedHashMap<String, MakeVote>()
        /** Every colour observation of a traffic-light track, INCLUDING unknown (those age the state out). */
        val colorHistory = mutableListOf<TrafficLightColorVote.Observation>()
        val roleHistory = mutableListOf<PersonRole>()
        var vdx = 0.0; var vdy = 0.0
        var dw = 0.0; var dh = 0.0
        var counted = false
    }

    private val states = mutableListOf<State>()
    private var nextID = 1
    private val _uniqueCounts = LinkedHashMap<VehicleKind, Int>()
    val uniqueCounts: Map<VehicleKind, Int> get() = _uniqueCounts
    var frameDetectionCount: Int = 0
        private set
    /** Number of second-stage (low-score) matches so far (diagnostics / tests). */
    var lowScoreMatches: Int = 0
        private set

    val totalUniqueVehicles: Int
        get() = _uniqueCounts.entries.sumOf { if (it.key.isVehicle) it.value else 0 }

    fun reset() {
        states.clear()
        _uniqueCounts.clear()
        frameDetectionCount = 0
        lowScoreMatches = 0
        nextID = 1
    }

    /**
     * Forgets the live tracks but keeps the unique counters and the ID sequence. Call it when frames stop for a while
     * (pause, background): otherwise the first frame after the gap would continue the old tracks — confirmed state,
     * hit count, make / colour / role votes — with whatever overlaps their last boxes.
     */
    fun dropTracks() {
        states.clear()
    }

    /**
     * Feeds the detections of one frame.
     *
     * Returns the tracks matched on this frame (`missed == 0`) plus, for at most [Config.coastFrames] frames, the
     * CONFIRMED tracks that were not matched: those carry `missed ≥ 1` and a box predicted by the constant-velocity
     * model. Consumers that must not act on a predicted box (pedestrian warnings, traffic-light logic, distance
     * samples, the research log) filter on `missed == 0`.
     */
    fun update(detections: List<Detection>, timestamp: Double): List<TrackedObject> {
        frameDetectionCount += detections.size

        // Tracks whose last observation is too old (frames stopped without dropTracks()) are not continued.
        if (config.maxIdleSeconds > 0) states.removeAll { timestamp - it.obj.lastSeen > config.maxIdleSeconds }

        // Per-class confidence filter with hysteresis: at or above the class minimum a detection may open a track;
        // between `minimum × continuationFactor` and the minimum it may only continue a confirmed track.
        val factor = min(1.0, max(0.0, config.continuationFactor))
        val dets = ArrayList<Detection>(detections.size)
        val canSpawn = ArrayList<Boolean>(detections.size)
        for (d in detections) {
            val minimum = minConfidence[d.kind] ?: 0.0
            if (d.confidence >= minimum) {
                dets.add(d); canSpawn.add(true)
            } else if (d.confidence >= minimum * factor) {
                dets.add(d); canSpawn.add(false)
            }
        }

        val predicted: List<BBox> = states.map { st ->
            val dt = max(0.0, timestamp - st.obj.lastSeen)
            val b = st.obj.box
            if (!(dt > 0 && dt < 1.0)) return@map b
            val w = max(0.002, b.width + st.dw * dt)
            val h = max(0.002, b.height + st.dh * dt)
            val cx = b.midX + st.vdx * dt
            val cy = b.midY + st.vdy * dt
            BBox(cx - w / 2, cy - h / 2, w, h)
        }

        data class Pair3(val track: Int, val det: Int, val score: Double)
        val pairs = mutableListOf<Pair3>()
        for ((ti, st) in states.withIndex()) {
            val p = predicted[ti]
            for ((di, d) in dets.withIndex()) {
                if (!compatible(st.obj.kind, d.kind)) continue
                // Low-score detections take part only in the second stage below (ByteTrack order: a full-score
                // detection is never left without its track because a low-score box overlapped it better).
                if (!canSpawn[di]) continue
                val iou = p.iou(d.box)
                val penalty = if (st.obj.kind == d.kind) 0.0 else 0.05
                var score = -1.0
                if (iou - penalty >= config.iouThreshold) {
                    score = 1 + iou - penalty
                } else if (config.centerGate > 0) {
                    val scale = sqrt(max(p.area, d.box.area))
                    val dx = p.midX - d.box.midX; val dy = p.midY - d.box.midY
                    val dist = if (scale > 0) sqrt(dx * dx + dy * dy) / scale else Double.POSITIVE_INFINITY
                    val ratio = max(p.area, d.box.area) / max(1e-9, min(p.area, d.box.area))
                    val gate = config.centerGate * (if (st.obj.hits < 2) 1.6 else 1.0)
                    if (dist <= gate && ratio <= config.maxAreaRatio) {
                        score = (1 - dist / gate) * 0.9 + iou - penalty
                    }
                }
                if (score > 0) pairs.add(Pair3(ti, di, score))
            }
        }
        pairs.sortByDescending { it.score }

        val trackMatched = BooleanArray(states.size)
        val detMatched = BooleanArray(dets.size)
        for (p in pairs) {
            if (trackMatched[p.track] || detMatched[p.det]) continue
            trackMatched[p.track] = true
            detMatched[p.det] = true
            apply(dets[p.det], p.track, timestamp)
        }

        // Second association (ByteTrack "BYTE" step): confirmed tracks that no full-score detection matched may be
        // continued by a low-score detection of a compatible class, by IoU on the predicted box only (no centre
        // gate). Such a match refreshes box, velocity and `lastSeen`, but adds no hit and no class vote, and it
        // never opens or confirms a track.
        val lowPairs = mutableListOf<Pair3>()
        for ((di, d) in dets.withIndex()) {
            if (canSpawn[di]) continue
            for ((ti, st) in states.withIndex()) {
                if (trackMatched[ti] || !st.obj.isConfirmed || !compatible(st.obj.kind, d.kind)) continue
                val iou = predicted[ti].iou(d.box)
                if (iou >= config.secondIoU) lowPairs.add(Pair3(ti, di, iou))
            }
        }
        lowPairs.sortByDescending { it.score }
        for (p in lowPairs) {
            if (trackMatched[p.track] || detMatched[p.det]) continue
            trackMatched[p.track] = true
            detMatched[p.det] = true
            lowScoreMatches += 1
            apply(dets[p.det], p.track, timestamp, lowScore = true)
        }

        for (i in states.indices) if (!trackMatched[i]) states[i].obj.missed += 1
        states.removeAll { st -> st.obj.missed > (if (st.obj.isConfirmed) config.maxMissed else config.maxMissedTentative) }

        for ((di, d) in dets.withIndex()) {
            if (detMatched[di] || !canSpawn[di]) continue
            val st = State(TrackedObject(id = nextID, kind = d.kind, label = d.label, box = d.box,
                confidence = d.confidence, firstSeen = timestamp, lastSeen = timestamp))
            nextID += 1
            st.kindVotes[d.kind] = (st.kindVotes[d.kind] ?: 0.0) + d.confidence
            if (d.make != null && d.makeConfidence != null) {
                st.makeVotes[d.make] = MakeVote(1, d.makeConfidence)
                st.obj.make = d.make
                st.obj.makeConfidence = d.makeConfidence
            }
            if (d.kind == VehicleKind.TRAFFIC_LIGHT) {
                st.colorHistory.clear()
                st.colorHistory.add(TrafficLightColorVote.Observation(timestamp, d.lightColor ?: TrafficLightColor.UNKNOWN))
                st.obj.lightColor = TrafficLightColorVote.decide(st.colorHistory, timestamp, null)
            }
            if (d.personRole != null) {
                st.roleHistory.clear(); st.roleHistory.add(d.personRole)
                st.obj.personRole = PersonRoleClassifier.majority(st.roleHistory)
            }
            if (config.minHits <= 1) confirm(st)
            states.add(st)
        }

        val coast = max(0, config.coastFrames)
        return states.mapNotNull { st ->
            if (st.obj.missed == 0) return@mapNotNull st.obj.copy()
            if (!(st.obj.isConfirmed && st.obj.missed <= coast)) return@mapNotNull null
            // Coasted: the stored box stays at the last observation (re-acquisition predicts from it); only the
            // returned copy is extrapolated. `dt` is clamped like the matching prediction above.
            val o = st.obj.copy()
            val dt = max(0.0, min(1.0, timestamp - o.lastSeen))
            val w = max(0.002, o.box.width + st.dw * dt)
            val h = max(0.002, o.box.height + st.dh * dt)
            o.box = BBox(o.box.midX + st.vdx * dt - w / 2, o.box.midY + st.vdy * dt - h / 2, w, h)
            o
        }
    }

    private fun apply(d: Detection, index: Int, timestamp: Double, lowScore: Boolean = false) {
        val st = states[index]
        val old = st.obj.box
        val dt = timestamp - st.obj.lastSeen
        val w = min(1.0, max(0.0, config.boxSmoothing))
        val newBox = old.lerp(d.box, w)
        if (dt > 0 && dt < 1.5) {
            val vx = (d.box.midX - old.midX) / dt
            val vy = (d.box.midY - old.midY) / dt
            val vw = (d.box.width - old.width) / dt
            val vh = (d.box.height - old.height) / dt
            val beta = if (st.obj.hits < 2) 1.0 else 0.4
            st.vdx += beta * (vx - st.vdx); st.vdy += beta * (vy - st.vdy)
            st.dw += beta * (vw - st.dw); st.dh += beta * (vh - st.dh)
        }
        val o = st.obj
        o.box = newBox
        o.confidence = d.confidence
        o.peakConfidence = max(o.peakConfidence, d.confidence)
        if (!lowScore) o.hits += 1
        o.missed = 0
        o.lastSeen = timestamp
        if (!lowScore) {
            o.label = d.label
            st.kindVotes[d.kind] = (st.kindVotes[d.kind] ?: 0.0) + d.confidence
        }
        st.kindVotes.entries.maxByOrNull { it.value }?.let { o.kind = it.key }
        if (d.make != null && d.makeConfidence != null) addMake(st, d.make, d.makeConfidence)
        if (d.kind == VehicleKind.TRAFFIC_LIGHT || st.colorHistory.isNotEmpty() || o.lightColor != null) {
            // Runs on every matched frame, also when the lamp was unreadable: unknown observations are recorded so
            // an old colour cannot survive (it used to stay red for the life of the track).
            st.colorHistory.add(TrafficLightColorVote.Observation(timestamp, d.lightColor ?: TrafficLightColor.UNKNOWN))
            TrafficLightColorVote.prune(st.colorHistory, timestamp)
            o.lightColor = TrafficLightColorVote.decide(st.colorHistory, timestamp, o.lightColor)
        }
        if (d.personRole != null) {
            st.roleHistory.add(d.personRole)
            val window = PersonRoleClassifier.voteWindow
            while (st.roleHistory.size > window) st.roleHistory.removeAt(0)
            o.personRole = PersonRoleClassifier.majority(st.roleHistory, previous = o.personRole)
        }
        if (!st.counted && o.hits >= config.minHits) confirm(st)
    }

    private fun confirm(st: State) {
        st.obj.isConfirmed = true
        if (!st.counted && st.obj.kind !in config.deferredCountKinds) {
            st.counted = true
            _uniqueCounts[st.obj.kind] = (_uniqueCounts[st.obj.kind] ?: 0) + 1
        }
    }

    private fun addMake(st: State, make: String, confidence: Double) {
        val entry = st.makeVotes.getOrPut(make) { MakeVote(0, 0.0) }
        entry.count += 1
        entry.confidenceSum += confidence
        // Winner: highest summed confidence (ties → more votes).
        var best: Map.Entry<String, MakeVote>? = null
        for (e in st.makeVotes.entries) {
            val b = best
            if (b == null) { best = e; continue }
            val less = if (b.value.confidenceSum == e.value.confidenceSum) b.value.count < e.value.count
            else b.value.confidenceSum < e.value.confidenceSum
            if (less) best = e
        }
        best?.let {
            st.obj.make = it.key
            st.obj.makeConfidence = it.value.confidenceSum / max(1, it.value.count).toDouble()
        }
    }

    /** Counts the given confirmed tracks of a deferred kind ([Config.deferredCountKinds]) once. */
    fun markRelevant(trackIDs: List<Int>) {
        if (trackIDs.isEmpty()) return
        val ids = trackIDs.toSet()
        for (st in states) {
            if (st.obj.id !in ids) continue
            if (!st.obj.isConfirmed || st.counted) continue
            st.counted = true
            _uniqueCounts[st.obj.kind] = (_uniqueCounts[st.obj.kind] ?: 0) + 1
        }
    }

    fun addMakeObservation(trackID: Int, make: String, confidence: Double) {
        val st = states.firstOrNull { it.obj.id == trackID } ?: return
        addMake(st, make, confidence)
    }

    companion object {
        /** Classes the detector may confuse (car ↔ truck ↔ bus, motorcycle ↔ bicycle) can still match. */
        private fun compatible(a: VehicleKind, b: VehicleKind): Boolean {
            if (a == b) return true
            val motor = setOf(VehicleKind.CAR, VehicleKind.TRUCK, VehicleKind.BUS)
            val twoWheel = setOf(VehicleKind.MOTORCYCLE, VehicleKind.BICYCLE)
            return (a in motor && b in motor) || (a in twoWheel && b in twoWheel)
        }
    }
}

/**
 * Time-window vote that turns per-frame traffic-light colour observations into a stable colour.
 *
 * Why time based: the old vote kept the last 7 KNOWN colours for the life of the track and ignored unknown frames, so
 * a light that was red and then became unreadable stayed "red" indefinitely. The vote constants are reasoning — no
 * video sequences were evaluated.
 */
object TrafficLightColorVote {
    data class Observation(val time: Double, val color: TrafficLightColor)

    /** Observations older than this are forgotten, seconds (≈ 12 frames at 15 fps). */
    const val window: Double = 0.8
    /** Known-colour votes the winner needs inside the window… */
    const val minVotes: Int = 3
    /** …and its share of the known votes. */
    const val minShare: Double = 0.6
    /** Switching to a different colour additionally needs the newest this-many known observations to agree. */
    const val switchAgreement: Int = 2
    /** Hard cap of stored observations (frames arrive at ≤ 30 fps). */
    internal const val maxObservations: Int = 48

    /** Drops observations outside the window. */
    fun prune(history: MutableList<Observation>, now: Double) {
        history.removeAll { now - it.time > window || it.time > now + 1e-6 }
        while (history.size > maxObservations) history.removeAt(0)
    }

    /**
     * Stable colour for the observations inside the window, or null (not enough readable evidence).
     * [previous] is the colour reported so far (hysteresis).
     */
    fun decide(history: List<Observation>, now: Double, previous: TrafficLightColor?): TrafficLightColor? {
        val known = ArrayList<TrafficLightColor>()
        for (o in history) if (now - o.time <= window && o.color != TrafficLightColor.UNKNOWN) known.add(o.color)
        if (known.size < minVotes) return null
        val counts = HashMap<TrafficLightColor, Int>()
        for (c in known) counts[c] = (counts[c] ?: 0) + 1
        // Most votes; ties → the colour seen most recently.
        var winner = known[known.size - 1]
        var winnerCount = counts[winner] ?: 0
        for (color in listOf(TrafficLightColor.RED, TrafficLightColor.YELLOW, TrafficLightColor.GREEN)) {
            val count = counts[color] ?: 0
            if (count > winnerCount) {
                winner = color
                winnerCount = count
            }
        }
        if (!(winnerCount >= minVotes && winnerCount.toDouble() / known.size.toDouble() >= minShare)) return null
        if (previous != null && previous != TrafficLightColor.UNKNOWN && winner != previous) {
            // Hysteresis: the newest known observations must already show the new colour.
            val newest = known.takeLast(switchAgreement)
            if (newest.size < switchAgreement || newest.any { it != winner }) {
                return if ((counts[previous] ?: 0) > 0) previous else null
            }
        }
        return winner
    }
}
