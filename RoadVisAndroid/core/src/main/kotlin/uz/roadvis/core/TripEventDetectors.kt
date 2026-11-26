package uz.roadvis.core

import kotlin.math.abs
import kotlin.math.max

// Dates are epoch milliseconds, durations Double seconds — see TripJson.kt.

private fun secondsBetween(laterMillis: Long, earlierMillis: Long): Double = (laterMillis - earlierMillis) / 1000.0

/**
 * Speeding episodes: own GPS speed above limit + tolerance for at least `speedingMinSeconds` (≥ 5 s).
 * While the episode lasts, every update returns an event that starts at the beginning of the episode with the
 * duration so far and the worst excess. Feed the events into [DrivingEventDebouncer]: they merge into one per episode.
 */
class SpeedingDetector(var thresholds: TripThresholds = TripThresholds.default) {
    private var overSince: Long? = null
    private var startCoordinate: GeoPoint? = null
    private var startSpeed: Double? = null
    private var maxExcess = 0.0
    private var limitAtStart: Int? = null

    fun update(dateMillis: Long, speedKmh: Double?, limitKmh: Int?, coordinate: GeoPoint?): DrivingEvent? {
        if (speedKmh == null || !speedKmh.isFinite() || limitKmh == null || limitKmh <= 0 ||
            speedKmh <= limitKmh + thresholds.speedToleranceKmh
        ) {
            reset()
            return null
        }
        val speed = speedKmh; val limit = limitKmh
        if (overSince == null || limitAtStart != limit) {
            overSince = dateMillis
            startCoordinate = coordinate
            startSpeed = speed
            maxExcess = 0.0
            limitAtStart = limit
        }
        maxExcess = max(maxExcess, speed - limit)
        val since = overSince ?: return null
        val held = secondsBetween(dateMillis, since)
        if (held < thresholds.speedingMinSeconds) return null
        return DrivingEvent(kind = DrivingEventKind.SPEEDING, dateMillis = since, coordinate = startCoordinate ?: coordinate,
            speedKmh = max(startSpeed ?: speed, speed), value = maxExcess, limit = limit.toDouble(), duration = held)
    }

    fun reset() {
        overSince = null
        startCoordinate = null
        startSpeed = null
        maxExcess = 0.0
        limitAtStart = null
    }
}

/**
 * Harsh braking / acceleration from the GPS speed derivative, optionally confirmed by the motion sensors
 * (user-acceleration magnitude, gravity removed, m/s²). See the Swift original for the exact rules.
 */
class HarshMotionDetector(var thresholds: TripThresholds = TripThresholds.default) {
    var derivativeSpan: Double = 2.0
    var minimumSpan: Double = 0.9
    var minimumSpeedKmh: Double = 10.0
    var cooldown: Double = 4.0
    var motionConfirmationFactor: Double = 0.75

    private data class SpeedSample(val dateMillis: Long, val mps: Double)
    private data class MotionSample(val dateMillis: Long, val magnitude: Double)

    private val samples = mutableListOf<SpeedSample>()
    private val motion = mutableListOf<MotionSample>()
    private val lastEventDate = HashMap<DrivingEventKind, Long>()
    /** Latest GPS derivative, m/s² (for diagnostics / UI). */
    var lastAcceleration: Double? = null
        private set

    /** User acceleration magnitude in m/s² (gravity removed). */
    fun addMotion(dateMillis: Long, magnitude: Double) {
        if (!magnitude.isFinite()) return
        motion.add(MotionSample(dateMillis, magnitude))
        val cutoffSeconds = max(derivativeSpan, 1.0) + 0.5
        val first = motion.firstOrNull()
        if (first != null && secondsBetween(dateMillis, first.dateMillis) > cutoffSeconds) {
            motion.removeAll { secondsBetween(dateMillis, it.dateMillis) > cutoffSeconds }
        }
    }

    fun addSpeed(dateMillis: Long, speedKmh: Double, coordinate: GeoPoint?): DrivingEvent? {
        if (!(speedKmh.isFinite() && speedKmh >= 0)) return null
        val mps = speedKmh / 3.6
        samples.add(SpeedSample(dateMillis, mps))
        samples.removeAll { secondsBetween(dateMillis, it.dateMillis) > derivativeSpan + 0.05 }
        val reference = samples.firstOrNull { secondsBetween(dateMillis, it.dateMillis) >= minimumSpan }
        if (reference == null) {
            lastAcceleration = null
            return null
        }
        val dt = secondsBetween(dateMillis, reference.dateMillis)
        if (dt <= 0) return null
        val a = (mps - reference.mps) / dt
        lastAcceleration = a

        val peak = motion.filter { secondsBetween(dateMillis, it.dateMillis) <= derivativeSpan }.maxOfOrNull { it.magnitude }
        val kind: DrivingEventKind
        val threshold: Double
        if (a < 0) {
            if (reference.mps * 3.6 < minimumSpeedKmh) return null
            kind = DrivingEventKind.HARSH_BRAKING
            threshold = abs(thresholds.harshBrakingMps2)
        } else {
            if (speedKmh < minimumSpeedKmh) return null
            kind = DrivingEventKind.HARSH_ACCELERATION
            threshold = thresholds.harshAccelerationMps2
        }
        val magnitude = abs(a)
        val byGPS = magnitude >= threshold
        val byMotion = magnitude >= threshold * motionConfirmationFactor && (peak ?: 0.0) >= threshold
        if (!(byGPS || byMotion)) return null
        val last = lastEventDate[kind]
        if (last != null && secondsBetween(dateMillis, last) < cooldown) return null
        lastEventDate[kind] = dateMillis
        val value = if (byGPS) magnitude else max(magnitude, peak ?: magnitude)
        return DrivingEvent(kind = kind, dateMillis = dateMillis, coordinate = coordinate, speedKmh = reference.mps * 3.6,
            value = (value * 100).rounded() / 100, limit = threshold, duration = 0.0,
            note = if (byGPS) "GPS" else "GPS + датчики движения")
    }

    fun reset() {
        samples.clear()
        motion.clear()
        lastEventDate.clear()
        lastAcceleration = null
    }
}
