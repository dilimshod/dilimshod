package uz.roadvis.core

/** Age after which an empty placeholder cannot belong to a recording that has just started in this launch, ms. */
const val STALE_PLACEHOLDER_AGE_MS = 300_000L

/**
 * Unfinished trip without a usable track: the placeholder written when a recording starts and never replaced by an
 * autosave or a finished trip (the app was killed early). Such a trip is not shown in the history.
 */
val Trip.isEmptyPlaceholder: Boolean get() = endedAtMillis == null && points.size < 2

/** True when the file of this empty placeholder may be deleted. */
fun Trip.isStalePlaceholder(nowMillis: Long): Boolean =
    isEmptyPlaceholder && nowMillis - startedAtMillis > STALE_PLACEHOLDER_AGE_MS

/**
 * Decides when an automatically recorded trip ends because the car stands still (port of iOS `TripStandstillTimer`).
 *
 * Standing time is counted only from a valid GPS speed. A GPS outage (tunnel, underground road: no fresh fix or a fix
 * without speed, `speedKmh == null`) is not "standing"; the trip then ends only after the much longer [noSpeedMs]
 * without any valid speed (car left in an underground garage with the app open).
 */
class TripStandstillTimer(
    val stationarySpeedKmh: Double = 3.0,
    val stopMs: Long = 180_000L,
    val noSpeedMs: Long = 900_000L,
) {
    var stationarySince: Long? = null
        private set
    var noSpeedSince: Long? = null
        private set

    fun reset() {
        stationarySince = null
        noSpeedSince = null
    }

    /** Feeds the current speed (null = no usable GPS speed). Returns true when the trip should be stopped. */
    fun update(nowMillis: Long, speedKmh: Double?): Boolean {
        if (speedKmh == null || !speedKmh.isFinite() || speedKmh < 0) {
            stationarySince = null
            val since = noSpeedSince ?: nowMillis
            noSpeedSince = since
            return nowMillis - since >= noSpeedMs
        }
        noSpeedSince = null
        if (speedKmh > stationarySpeedKmh) {
            stationarySince = null
            return false
        }
        val since = stationarySince ?: nowMillis
        stationarySince = since
        return nowMillis - since >= stopMs
    }
}
