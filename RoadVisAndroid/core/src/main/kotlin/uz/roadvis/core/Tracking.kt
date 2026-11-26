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
    /** Majority of recent traffic-light colour observations. */
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
    ) {
        companion object {
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
        val colorHistory = mutableListOf<TrafficLightColor>()
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

    val totalUniqueVehicles: Int
        get() = _uniqueCounts.entries.sumOf { if (it.key.isVehicle) it.value else 0 }

    fun reset() {
        states.clear()
        _uniqueCounts.clear()
        frameDetectionCount = 0
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
                // Low-score detections only keep confirmed tracks alive.
                if (!canSpawn[di] && !st.obj.isConfirmed) continue
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
            if (d.lightColor != null && d.lightColor != TrafficLightColor.UNKNOWN) {
                st.colorHistory.clear(); st.colorHistory.add(d.lightColor)
                st.obj.lightColor = d.lightColor
            }
            if (d.personRole != null) {
                st.roleHistory.clear(); st.roleHistory.add(d.personRole)
                st.obj.personRole = PersonRoleClassifier.majority(st.roleHistory)
            }
            if (config.minHits <= 1) confirm(st)
            states.add(st)
        }

        return states.filter { it.obj.missed == 0 }.map { it.obj.copy() }
    }

    private fun apply(d: Detection, index: Int, timestamp: Double) {
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
        o.hits += 1
        o.missed = 0
        o.lastSeen = timestamp
        o.label = d.label

        st.kindVotes[d.kind] = (st.kindVotes[d.kind] ?: 0.0) + d.confidence
        st.kindVotes.entries.maxByOrNull { it.value }?.let { o.kind = it.key }
        if (d.make != null && d.makeConfidence != null) addMake(st, d.make, d.makeConfidence)
        if (d.lightColor != null && d.lightColor != TrafficLightColor.UNKNOWN) {
            st.colorHistory.add(d.lightColor)
            while (st.colorHistory.size > 7) st.colorHistory.removeAt(0)
            o.lightColor = majority(st.colorHistory)
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

        private fun majority(colors: List<TrafficLightColor>): TrafficLightColor? {
            val counts = LinkedHashMap<TrafficLightColor, Int>()
            for (c in colors) counts[c] = (counts[c] ?: 0) + 1
            // Prefer the most recent colour on ties.
            return counts.entries.maxWithOrNull { a, b ->
                if (a.value == b.value) colors.lastIndexOf(a.key).compareTo(colors.lastIndexOf(b.key))
                else a.value.compareTo(b.value)
            }?.key
        }
    }
}
