package uz.roadvis.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Date
import java.util.GregorianCalendar
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min

// No public real-time signal timing (SPaT) feed exists for the supported region, so every waiting time
// produced here is an ESTIMATE: a fixed-time signal model, refined by the user's own observed stops.

/** Assumed fixed-time signal plan used when nothing has been learned yet. */
data class SignalTimingAssumptions(
    /** Full signal cycle, seconds. */
    val cycleSeconds: Double = 90.0,
    /** Share of the cycle that is green for our approach, 0…1. */
    val greenRatio: Double = 0.45,
) {
    /** Red (incl. amber) time per cycle, seconds: `C · (1 − g)` with sanitised inputs. */
    val redSeconds: Double
        get() {
            val c = if (cycleSeconds.isFinite()) max(1.0, cycleSeconds) else 90.0
            val g = if (greenRatio.isFinite()) min(1.0, max(0.0, greenRatio)) else 0.45
            return c * (1 - g)
        }

    /** Cycle length with sanitised input, seconds. */
    val sanitizedCycleSeconds: Double get() = if (cycleSeconds.isFinite()) max(1.0, cycleSeconds) else 90.0
}

/** One pass through a signalised intersection, recorded on the phone. */
data class SignalObservation(
    val signalID: String,
    /** Time the vehicle entered the signal area. */
    val date: Date,
    /** Whether the vehicle had to stop. */
    val stopped: Boolean,
    /** Time spent (almost) stationary in the signal area, seconds (0 when it did not stop). */
    val waitSeconds: Double,
) {
    /** iOS Codable layout; `date` is seconds since 2001-01-01. */
    fun toJSON(): JSONObject = JSONObject()
        .put("signalID", signalID)
        .put("date", Json.dateToJSON(date))
        .put("stopped", stopped)
        .put("waitSeconds", waitSeconds)

    companion object {
        fun fromJSON(o: JSONObject): SignalObservation = SignalObservation(
            o.getString("signalID"),
            Json.dateFromJSON(o.opt("date")) ?: throw IllegalArgumentException("date"),
            o.getBoolean("stopped"),
            Json.double(o.opt("waitSeconds")) ?: throw IllegalArgumentException("waitSeconds"),
        )
    }
}

/** Estimated waiting time at a signal. Always an estimate — show it with "≈" and "оценка". */
data class SignalWaitEstimate(
    /** Expected wait including the chance of not stopping at all, seconds. */
    val expectedWaitSeconds: Double,
    /** Probability of having to stop, 0…1. */
    val stopProbability: Double,
    /** Expected wait when the vehicle has to stop, seconds. */
    val meanWaitIfStopped: Double,
    /** Observations that contributed. */
    val observationCount: Int,
    val source: Source,
) {
    /** Where the numbers come from. */
    enum class Source(val raw: String) {
        /** Only the fixed-time model (no observations). */
        MODEL("model"),
        /** Enough own observations (≥ 5) — model no longer used. */
        LEARNED("learned"),
        /** Model blended with a few own observations. */
        BLENDED("blended"),
    }

    /** Russian label of the data source. */
    val sourceDescription: String
        get() = when (source) {
            Source.MODEL -> "оценка по типовому циклу светофора"
            Source.LEARNED -> "оценка по вашим поездкам ($observationCount набл.)"
            Source.BLENDED -> "оценка: типовой цикл + ваши поездки ($observationCount набл.)"
        }
}

/** Analytical waiting time at a fixed-time signal for a vehicle arriving at a random moment of the cycle. */
object SignalWaitModel {
    /** Random arrival, fixed-time signal: P(stop) = r/C, E[wait | stop] = r/2, E[wait] = r²/(2C), r = C·(1−g). */
    fun estimate(a: SignalTimingAssumptions): SignalWaitEstimate {
        val c = a.sanitizedCycleSeconds
        val r = a.redSeconds
        return SignalWaitEstimate(r * r / (2 * c), r / c, r / 2, 0, SignalWaitEstimate.Source.MODEL)
    }
}

/**
 * Per-signal history of the user's own stops, blended with the model. Persist it as JSON ([toJSON] / [fromJSON]).
 * Not thread-safe: use it from one thread.
 */
class SignalStatistics {
    private val bySignal = HashMap<String, MutableList<SignalObservation>>()

    /** Adds an observation (keeps the newest [maxObservationsPerSignal] per signal, ordered by date). */
    fun record(observation: SignalObservation) {
        if (!observation.waitSeconds.isFinite() || observation.waitSeconds < 0) return
        val list = bySignal[observation.signalID] ?: ArrayList()
        val last = list.lastOrNull()
        if (last != null && last.date.after(observation.date)) {
            val index = list.indexOfFirst { it.date.after(observation.date) }.let { if (it < 0) list.size else it }
            list.add(index, observation)
        } else {
            list.add(observation)
        }
        while (list.size > maxObservationsPerSignal) list.removeAt(0)
        bySignal[observation.signalID] = list
    }

    /**
     * Blends the model with learned observations (same peak/off-peak bucket preferred, else all).
     * n = observations used, w = min(1, n/5): expected = w·learned + (1−w)·model (likewise for the stop
     * probability and the wait if stopped). Source: MODEL for n = 0, LEARNED for n ≥ 5, else BLENDED.
     */
    fun estimate(signalID: String, at: Date, assumptions: SignalTimingAssumptions,
                 timeZone: TimeZone = TimeZone.getDefault()): SignalWaitEstimate {
        val model = SignalWaitModel.estimate(assumptions)
        val all = bySignal[signalID] ?: emptyList()
        if (all.isEmpty()) return model

        val peak = isPeak(at, timeZone)
        val sameBucket = all.filter { isPeak(it.date, timeZone) == peak }
        val used = if (sameBucket.isEmpty()) all else sameBucket
        val n = used.size

        val stops = used.filter { it.stopped }
        val learnedProbability = stops.size.toDouble() / n
        val learnedMeanIfStopped = if (stops.isEmpty()) model.meanWaitIfStopped
            else stops.sumOf { it.waitSeconds } / stops.size
        val learnedExpected = used.sumOf { if (it.stopped) it.waitSeconds else 0.0 } / n

        val w = min(1.0, n.toDouble() / fullConfidenceObservations)
        return SignalWaitEstimate(
            expectedWaitSeconds = w * learnedExpected + (1 - w) * model.expectedWaitSeconds,
            stopProbability = w * learnedProbability + (1 - w) * model.stopProbability,
            meanWaitIfStopped = w * learnedMeanIfStopped + (1 - w) * model.meanWaitIfStopped,
            observationCount = n,
            source = if (n >= fullConfidenceObservations) SignalWaitEstimate.Source.LEARNED else SignalWaitEstimate.Source.BLENDED,
        )
    }

    /** Observations of one signal, oldest first. */
    fun observations(signalID: String): List<SignalObservation> = bySignal[signalID]?.toList() ?: emptyList()

    /** Ids of all signals with observations. */
    val signalIDs: List<String> get() = bySignal.keys.sorted()

    val totalObservations: Int get() = bySignal.values.sumOf { it.size }

    fun removeAll() {
        bySignal.clear()
    }

    /** `{"version": 1, "observations": [...]}` (the iOS Codable layout). */
    fun toJSON(): String {
        val arr = JSONArray()
        for (key in bySignal.keys.sorted()) bySignal[key]?.forEach { arr.put(it.toJSON()) }
        return JSONObject().put("version", 1).put("observations", arr).toString()
    }

    companion object {
        /** Observations kept per signal (oldest are dropped). */
        const val maxObservationsPerSignal = 50
        /** Observations needed for a fully learned estimate. */
        const val fullConfidenceObservations = 5

        /** @throws org.json.JSONException / IllegalArgumentException for malformed data. */
        fun fromJSON(json: String): SignalStatistics {
            val obj = JSONObject(json)
            val stats = SignalStatistics()
            val arr = obj.optJSONArray("observations") ?: return stats
            val list = (0 until arr.length()).map { SignalObservation.fromJSON(arr.getJSONObject(it)) }
            for (o in list.sortedBy { it.date.time }) stats.record(o)
            return stats
        }

        /** Peak hours: Monday–Friday 07:00–10:00 and 17:00–20:00 local time (in [timeZone]). */
        fun isPeak(date: Date, timeZone: TimeZone): Boolean {
            val c = GregorianCalendar(timeZone)
            c.time = date
            val weekday = c.get(Calendar.DAY_OF_WEEK)   // 1 = Sunday, 7 = Saturday
            val hour = c.get(Calendar.HOUR_OF_DAY)
            val isWorkday = weekday in 2..6
            return isWorkday && (hour in 7 until 10 || hour in 17 until 20)
        }
    }
}

/**
 * Detects passes through signalised intersections from GPS fixes and measures how long the vehicle stood.
 *
 * A pass starts when the vehicle comes within `signalRadius` of a [SignalLocation] and ends when it is more
 * than `signalRadius + 15 m` away from it. Inside the area the vehicle is "halted" from the moment its speed
 * drops below `stopSpeedKmh` until it exceeds `resumeSpeedKmh` (so creeping forward in the queue still counts
 * as waiting); halted time is accumulated, and if it reaches `minStopSeconds` the pass counts as a stop with
 * that waiting time. Exactly one observation is emitted per pass. Passes are discarded when the GPS jumps more
 * than 200 m between fixes, when fixes are missing for over 5 minutes, or when the vehicle stood longer than
 * 5 minutes (parking, not a signal). After a pass ends, the same signal can only be entered again once the
 * vehicle has left its area, so a discarded pass is not restarted half-way.
 */
class StopDetector(
    val stopSpeedKmh: Double = 3.0,
    resumeSpeedKmh: Double = 10.0,
    minStopSeconds: Double = 2.0,
    signalRadius: Double = 45.0,
) {
    val resumeSpeedKmh: Double = max(stopSpeedKmh, resumeSpeedKmh)
    val minStopSeconds: Double = max(0.0, minStopSeconds)
    val signalRadius: Double = max(5.0, signalRadius)

    companion object {
        /** Hysteresis added to `signalRadius` before a pass ends, metres. */
        const val exitMargin: Double = 15.0
        /** A jump between consecutive fixes larger than this invalidates the current pass, metres. */
        const val maxJumpMeters: Double = 200.0
        /** Longest plausible stand at a signal / longest gap between fixes, seconds. */
        const val maxWaitSeconds: Double = 300.0
    }

    private data class Pass(
        val signal: SignalLocation,
        val enteredAt: Date,
        var lowSpeedSeconds: Double,
        /** Halted at the previous fix (below `stopSpeedKmh` and not yet above `resumeSpeedKmh`). */
        var halted: Boolean,
        var valid: Boolean,
    )

    private data class Fix(val position: GeoPoint, val timestamp: Date)

    private var pass: Pass? = null
    private var lastFix: Fix? = null
    /** Signal of the last ended pass; not re-entered until the vehicle is outside its area. */
    private var suppressed: SignalLocation? = null

    /** Id of the signal area the vehicle is currently in, if any. */
    val currentSignalID: String? get() = pass?.signal?.id

    /** Low-speed time accumulated in the current signal area, seconds. */
    val currentWaitSeconds: Double get() = pass?.lowSpeedSeconds ?: 0.0

    /**
     * Feed every GPS fix. Returns an observation once the vehicle leaves a signal area
     * (stopped = true with the stop duration, or stopped = false when it passed without stopping).
     * A negative / non-finite [speedKmh] (invalid location speed) is replaced by the speed derived
     * from the previous fix when possible.
     */
    fun update(position: GeoPoint, speedKmh: Double, timestamp: Date, nearbySignals: List<SignalLocation>): SignalObservation? {
        if (!position.isValid) return null
        var emitted: SignalObservation? = null

        // Speed sanity: derive from displacement when the reported speed is invalid.
        var speed: Double? = if (speedKmh.isFinite() && speedKmh >= 0) speedKmh else null
        var jumped = false
        var gapTooLong = false
        var dt = 0.0
        val last = lastFix
        if (last != null) {
            dt = (timestamp.time - last.timestamp.time) / 1000.0
            val moved = Geo.distance(last.position, position)
            jumped = moved > maxJumpMeters
            gapTooLong = dt > maxWaitSeconds
            if (speed == null && dt > 0) speed = (moved / dt).kmh
        }

        val blocked = suppressed
        if (blocked != null && Geo.distance(position, blocked.coordinate) > signalRadius + exitMargin) {
            suppressed = null
        }

        val current = pass?.copy()
        if (current != null) {
            if (jumped || gapTooLong) {
                current.valid = false
            } else if (dt > 0 && current.halted) {
                // The interval since the previous fix counts as waiting when the vehicle was halted at that fix
                // (also covers location updates paused while stationary).
                current.lowSpeedSeconds += dt
            }
            if (current.lowSpeedSeconds > maxWaitSeconds) current.valid = false
            current.halted = nextHalted(current.halted, speed)

            val distance = Geo.distance(position, current.signal.coordinate)
            if (distance > signalRadius + exitMargin || !current.valid) {
                if (current.valid) {
                    val stopped = current.lowSpeedSeconds >= minStopSeconds
                    emitted = SignalObservation(current.signal.id, current.enteredAt, stopped,
                        if (stopped) current.lowSpeedSeconds else 0.0)
                }
                suppressed = current.signal
                pass = null
            } else {
                pass = current
            }
        }

        // Enter a (new) signal area. After an invalidated pass, wait for a clean fix first.
        if (pass == null && !jumped && !gapTooLong) {
            val blockedID = suppressed?.id
            var nearest: SignalLocation? = null
            var nearestDistance = signalRadius
            for (signal in nearbySignals) {
                if (signal.id == blockedID || !signal.coordinate.isValid) continue
                val d = Geo.distance(position, signal.coordinate)
                if (d <= nearestDistance) {
                    nearestDistance = d
                    nearest = signal
                }
            }
            if (nearest != null) {
                pass = Pass(nearest, timestamp, 0.0, nextHalted(false, speed), true)
            }
        }

        lastFix = Fix(position, timestamp)
        return emitted
    }

    /**
     * Halted-state hysteresis: halt below `stopSpeedKmh`, resume above `resumeSpeedKmh`, otherwise keep.
     * Unknown speed keeps the previous state.
     */
    private fun nextHalted(halted: Boolean, speed: Double?): Boolean {
        if (speed == null) return halted
        if (speed < stopSpeedKmh) return true
        if (speed > resumeSpeedKmh) return false
        return halted
    }

    /** Forgets the current pass, the last fix and the re-entry suppression. */
    fun reset() {
        pass = null
        lastFix = null
        suppressed = null
    }
}
