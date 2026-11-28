package uz.roadvis.core

import org.json.JSONObject
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// Trip recording, statistics and scoring for the beginner-driver trip report. All camera-based values are estimates.
// Dates are epoch milliseconds (`...Millis`), durations Double seconds; JSON format described in TripJson.kt.

/** Start (A) or end (B) of a trip. */
data class TripEndpoint(
    /** Human-readable name (destination name, reverse-geocoded address); null while unknown. */
    var name: String? = null,
    var coordinate: GeoPoint? = null,
) {
    fun toJson(): JSONObject {
        val o = JSONObject()
        TripJson.putOpt(o, "name", name)
        coordinate?.let { o.put("coordinate", TripJson.geo(it)) }
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): TripEndpoint =
            TripEndpoint(TripJson.optString(o, "name"), TripJson.optObject(o, "coordinate")?.let { TripJson.geo(it) })
    }
}

/** One sample of the track (≈ 1 per second while recording). */
data class TripPoint(
    var dateMillis: Long,
    var coordinate: GeoPoint,
    /** Own GPS speed, km/h (null when the fix had no valid speed). */
    var speedKmh: Double? = null,
    /** Posted speed limit at that moment, km/h. */
    var speedLimitKmh: Int? = null,
    /** ≈ Distance to the lead vehicle (camera estimate), metres. */
    var leadDistanceMeters: Double? = null,
    /** Recommended following distance for the speed at that moment, metres. */
    var recommendedGapMeters: Double? = null,
    /** GPS horizontal accuracy, metres. */
    var horizontalAccuracy: Double? = null,
) {
    fun toJson(): JSONObject {
        val o = JSONObject().put("date", dateMillis).put("coordinate", TripJson.geo(coordinate))
        TripJson.putOpt(o, "speedKmh", speedKmh)
        TripJson.putOpt(o, "speedLimitKmh", speedLimitKmh)
        TripJson.putOpt(o, "leadDistanceMeters", leadDistanceMeters)
        TripJson.putOpt(o, "recommendedGapMeters", recommendedGapMeters)
        TripJson.putOpt(o, "horizontalAccuracy", horizontalAccuracy)
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): TripPoint = TripPoint(
            dateMillis = o.getLong("date"),
            coordinate = TripJson.geo(o.getJSONObject("coordinate")),
            speedKmh = TripJson.optDouble(o, "speedKmh"),
            speedLimitKmh = TripJson.optInt(o, "speedLimitKmh"),
            leadDistanceMeters = TripJson.optDouble(o, "leadDistanceMeters"),
            recommendedGapMeters = TripJson.optDouble(o, "recommendedGapMeters"),
            horizontalAccuracy = TripJson.optDouble(o, "horizontalAccuracy"),
        )
    }
}

/**
 * Thresholds in force while the trip was recorded (stored with the trip so its report stays reproducible).
 * The constructor normalizes values like the Swift init: tolerance ≥ 0, minimum speeding time ≥ 5 s,
 * braking threshold negative, acceleration threshold positive.
 */
class TripThresholds(
    speedToleranceKmh: Double = 5.0,
    speedingMinSeconds: Double = 5.0,
    harshBrakingMps2: Double = -3.5,
    harshAccelerationMps2: Double = 3.0,
) {
    /** km/h above the limit that still counts as "within the limit". */
    val speedToleranceKmh: Double = max(0.0, speedToleranceKmh)
    /** Minimum time above limit + tolerance before a speeding event is recorded, seconds (≥ 5). */
    val speedingMinSeconds: Double = max(5.0, speedingMinSeconds)
    /** Deceleration that counts as harsh braking, m/s² (negative). */
    val harshBrakingMps2: Double = -abs(harshBrakingMps2)
    /** Acceleration that counts as harsh acceleration, m/s² (positive). */
    val harshAccelerationMps2: Double = abs(harshAccelerationMps2)

    fun copy(
        speedToleranceKmh: Double = this.speedToleranceKmh,
        speedingMinSeconds: Double = this.speedingMinSeconds,
        harshBrakingMps2: Double = this.harshBrakingMps2,
        harshAccelerationMps2: Double = this.harshAccelerationMps2,
    ) = TripThresholds(speedToleranceKmh, speedingMinSeconds, harshBrakingMps2, harshAccelerationMps2)

    override fun equals(other: Any?): Boolean = other is TripThresholds &&
        speedToleranceKmh == other.speedToleranceKmh && speedingMinSeconds == other.speedingMinSeconds &&
        harshBrakingMps2 == other.harshBrakingMps2 && harshAccelerationMps2 == other.harshAccelerationMps2

    override fun hashCode(): Int =
        listOf(speedToleranceKmh, speedingMinSeconds, harshBrakingMps2, harshAccelerationMps2).hashCode()

    override fun toString(): String =
        "TripThresholds(speedToleranceKmh=$speedToleranceKmh, speedingMinSeconds=$speedingMinSeconds, " +
            "harshBrakingMps2=$harshBrakingMps2, harshAccelerationMps2=$harshAccelerationMps2)"

    fun toJson(): JSONObject = JSONObject()
        .put("speedToleranceKmh", speedToleranceKmh)
        .put("speedingMinSeconds", speedingMinSeconds)
        .put("harshBrakingMps2", harshBrakingMps2)
        .put("harshAccelerationMps2", harshAccelerationMps2)

    companion object {
        val default = TripThresholds()

        fun fromJson(o: JSONObject): TripThresholds = TripThresholds(
            TripJson.optDouble(o, "speedToleranceKmh") ?: 5.0,
            TripJson.optDouble(o, "speedingMinSeconds") ?: 5.0,
            TripJson.optDouble(o, "harshBrakingMps2") ?: -3.5,
            TripJson.optDouble(o, "harshAccelerationMps2") ?: 3.0,
        )
    }
}

/** A recorded trip: track, A and B, the planned route and all driving events. */
data class Trip(
    var id: UUID = UUID.randomUUID(),
    var startedAtMillis: Long,
    /** null while recording (or when the app was killed during recording). */
    var endedAtMillis: Long? = null,
    var origin: TripEndpoint = TripEndpoint(),
    var destination: TripEndpoint? = null,
    /** Planned route polyline (simplified), empty for trips without navigation. */
    var routePolyline: List<GeoPoint> = emptyList(),
    /** Routing engine badge of the route ("Valhalla", …). */
    var routeSource: String? = null,
    var points: List<TripPoint> = emptyList(),
    var events: List<DrivingEvent> = emptyList(),
    var thresholds: TripThresholds = TripThresholds.default,
    /** True when navigation reported arrival at B. */
    var arrived: Boolean = false,
    /** True when started automatically with «Поехали». */
    var startedWithNavigation: Boolean = false,
    /** File names of the camera research CSV recorded during the trip. */
    var cameraCSVFiles: List<String> = emptyList(),
    var formatVersion: Int = currentFormatVersion,
) {
    /** End of the trip: `endedAt`, else the last point, else the start (epoch ms). */
    val effectiveEndMillis: Long get() = endedAtMillis ?: points.lastOrNull()?.dateMillis ?: startedAtMillis
    /** Seconds. */
    val duration: Double get() = max(0.0, (effectiveEndMillis - startedAtMillis) / 1000.0)
    /** Events sorted by time. */
    val sortedEvents: List<DrivingEvent> get() = events.sortedBy { it.dateMillis }

    fun toJson(): JSONObject {
        val o = JSONObject()
            .put("id", id.toString())
            .put("formatVersion", formatVersion)
            .put("startedAt", startedAtMillis)
            .put("origin", origin.toJson())
            .put("routePolyline", TripJson.array(routePolyline) { TripJson.geo(it) })
            .put("points", TripJson.array(points) { it.toJson() })
            .put("events", TripJson.array(events) { it.toJson() })
            .put("thresholds", thresholds.toJson())
            .put("arrived", arrived)
            .put("startedWithNavigation", startedWithNavigation)
            .put("cameraCSVFiles", TripJson.array(cameraCSVFiles) { it })
        TripJson.putOpt(o, "endedAt", endedAtMillis)
        destination?.let { o.put("destination", it.toJson()) }
        TripJson.putOpt(o, "routeSource", routeSource)
        return o
    }

    companion object {
        const val currentFormatVersion = 1

        fun fromJson(o: JSONObject): Trip {
            val files = if (o.has("cameraCSVFiles")) o.getJSONArray("cameraCSVFiles") else null
            return Trip(
                id = UUID.fromString(o.getString("id")),
                startedAtMillis = o.getLong("startedAt"),
                endedAtMillis = TripJson.optLong(o, "endedAt"),
                origin = TripJson.optObject(o, "origin")?.let { TripEndpoint.fromJson(it) } ?: TripEndpoint(),
                destination = TripJson.optObject(o, "destination")?.let { TripEndpoint.fromJson(it) },
                routePolyline = TripJson.list(o, "routePolyline") { TripJson.geo(it) },
                routeSource = TripJson.optString(o, "routeSource"),
                points = TripJson.list(o, "points") { TripPoint.fromJson(it) },
                events = TripJson.list(o, "events") { DrivingEvent.fromJson(it) },
                thresholds = TripJson.optObject(o, "thresholds")?.let { TripThresholds.fromJson(it) } ?: TripThresholds.default,
                arrived = o.optBoolean("arrived", false),
                startedWithNavigation = o.optBoolean("startedWithNavigation", false),
                cameraCSVFiles = if (files == null) emptyList() else (0 until files.length()).map { files.getString(it) },
                formatVersion = o.optInt("formatVersion", currentFormatVersion),
            )
        }
    }
}

/** Speed bands used for the "share of time per speed band" chart. */
enum class TripSpeedBand(val raw: String) {
    STANDING("standing"), SLOW("slow"), URBAN("urban"), FAST("fast"), HIGHWAY("highway");

    /** Lower bound, km/h (inclusive). */
    val lowerBoundKmh: Double
        get() = when (this) {
            STANDING -> 0.0
            SLOW -> 5.0
            URBAN -> 30.0
            FAST -> 60.0
            HIGHWAY -> 90.0
        }

    /** "0–5 км/ч", "90+ км/ч". */
    val title: String
        get() = when (this) {
            STANDING -> "0–5 км/ч"
            SLOW -> "5–30 км/ч"
            URBAN -> "30–60 км/ч"
            FAST -> "60–90 км/ч"
            HIGHWAY -> "90+ км/ч"
        }

    companion object {
        fun fromRaw(raw: String): TripSpeedBand? = entries.firstOrNull { it.raw == raw }

        fun band(kmh: Double): TripSpeedBand {
            var result = STANDING
            for (b in entries) if (kmh >= b.lowerBoundKmh) result = b
            return result
        }
    }
}

/** Aggregated numbers of a trip. */
data class TripStats(
    /** Track length (sum of distances between accepted points), metres. */
    val distanceMeters: Double,
    /** Seconds. */
    val duration: Double,
    /** Time with speed ≥ 5 km/h, seconds. */
    val movingDuration: Double,
    /** distance / duration, km/h. */
    val averageSpeedKmh: Double,
    /** distance / moving time, km/h. */
    val averageMovingSpeedKmh: Double,
    val maxSpeedKmh: Double,
    /** Time above limit + tolerance, seconds. */
    val timeOverLimit: Double,
    /** Share (0…1) of the time with a known speed limit. */
    val speedLimitCoverage: Double,
    val eventCounts: Map<DrivingEventKind, Int>,
    val totalEvents: Int,
    /** Events per 100 km (distance floored at 1 km). */
    val eventsPer100km: Double,
    /** Seconds spent in each speed band. */
    val timeBySpeedBand: Map<TripSpeedBand, Double>,
    /** ≈ Mean camera gap to the lead vehicle while one was measured, metres. */
    val averageLeadDistanceMeters: Double?,
    /** Share (0…1) of the time with a measured lead gap below the recommended gap. */
    val shareBelowRecommendedGap: Double?,
) {
    companion object {
        /** Gaps between consecutive points longer than this are not integrated (GPS loss, app suspended), seconds. */
        const val maxSampleGap: Double = 10.0
        /** Fixes worse than this are ignored for distance. */
        const val maxAccuracyForDistance: Double = 50.0
        /** Below this speed the car counts as standing. */
        const val movingSpeedKmh: Double = 5.0

        fun compute(trip: Trip): TripStats {
            val points = trip.points.sortedBy { it.dateMillis }
            val tolerance = trip.thresholds.speedToleranceKmh
            var distance = 0.0
            var moving = 0.0
            var overLimit = 0.0
            var withLimit = 0.0
            var integrated = 0.0
            var maxSpeed = 0.0
            val bands = LinkedHashMap<TripSpeedBand, Double>()
            var leadSum = 0.0
            var leadTime = 0.0
            var belowGapTime = 0.0
            var lastAccepted: TripPoint? = null

            for (point in points) {
                val s = point.speedKmh
                if (s != null && s.isFinite()) maxSpeed = max(maxSpeed, s)
                if ((point.horizontalAccuracy ?: 0.0) <= maxAccuracyForDistance) {
                    val previous = lastAccepted
                    if (previous != null) {
                        val dt = (point.dateMillis - previous.dateMillis) / 1000.0
                        val step = Geo.distance(previous.coordinate, point.coordinate)
                        if (dt > 0 && step / dt < 70) distance += step
                    }
                    lastAccepted = point
                }
            }
            for (i in 1 until points.size) {
                val a = points[i - 1]
                val b = points[i]
                val dt = (b.dateMillis - a.dateMillis) / 1000.0
                if (!(dt > 0 && dt <= maxSampleGap)) continue
                integrated += dt
                val speed = a.speedKmh ?: 0.0
                if (speed >= movingSpeedKmh) moving += dt
                val band = TripSpeedBand.band(speed)
                bands[band] = (bands[band] ?: 0.0) + dt
                val limit = a.speedLimitKmh
                if (limit != null) {
                    withLimit += dt
                    if (speed > limit + tolerance) overLimit += dt
                }
                val lead = a.leadDistanceMeters
                if (lead != null) {
                    leadSum += lead * dt
                    leadTime += dt
                    val recommended = a.recommendedGapMeters
                    if (recommended != null && lead < recommended) belowGapTime += dt
                }
            }
            val duration = trip.duration
            val counts = LinkedHashMap<DrivingEventKind, Int>()
            for (event in trip.events) counts[event.kind] = (counts[event.kind] ?: 0) + 1
            val km = distance / 1000
            return TripStats(
                distanceMeters = distance,
                duration = duration,
                movingDuration = moving,
                averageSpeedKmh = if (duration > 0) distance / duration * 3.6 else 0.0,
                averageMovingSpeedKmh = if (moving > 0) distance / moving * 3.6 else 0.0,
                maxSpeedKmh = maxSpeed,
                timeOverLimit = overLimit,
                speedLimitCoverage = if (integrated > 0) withLimit / integrated else 0.0,
                eventCounts = counts,
                totalEvents = trip.events.size,
                eventsPer100km = trip.events.size.toDouble() / max(km, 1.0) * 100,
                timeBySpeedBand = bands,
                averageLeadDistanceMeters = if (leadTime > 0) leadSum / leadTime else null,
                shareBelowRecommendedGap = if (leadTime > 0) belowGapTime / leadTime else null,
            )
        }
    }
}

/**
 * Driving score 0…100.
 *   penalty(event) = weight(kind) × severityFactor × durationFactor
 *     severityFactor: info 0.5, warning 1.0, violation 1.5
 *     durationFactor: 1 + min(duration / 30 s, 2)
 *   penaltyPerKm = Σ penalty / max(distance km, 1)
 *   score = clamp(100 − 10 × penaltyPerKm, 0, 100), rounded
 */
object TripScoring {
    const val scale: Double = 10.0
    const val minimumDistanceKm: Double = 1.0

    fun weight(kind: DrivingEventKind): Double = when (kind) {
        DrivingEventKind.RED_LIGHT_RUNNING -> 8.0
        DrivingEventKind.PEDESTRIAN_NOT_YIELDED -> 8.0
        DrivingEventKind.STOP_SIGN_IGNORED -> 5.0
        DrivingEventKind.COLLISION_RISK -> 5.0
        DrivingEventKind.SPEEDING -> 3.0
        DrivingEventKind.TAILGATING -> 2.0
        DrivingEventKind.HARSH_BRAKING -> 2.0
        DrivingEventKind.HARSH_ACCELERATION -> 1.5
        DrivingEventKind.LANE_DEPARTURE -> 1.5
        DrivingEventKind.TRAFFIC_OFFICER_SEEN, DrivingEventKind.ROAD_WORKERS_SEEN -> 0.0
    }

    fun severityFactor(severity: DrivingEventSeverity): Double = when (severity) {
        DrivingEventSeverity.INFO -> 0.5
        DrivingEventSeverity.WARNING -> 1.0
        DrivingEventSeverity.VIOLATION -> 1.5
    }

    fun penalty(event: DrivingEvent): Double {
        val durationFactor = 1 + min(max(0.0, event.duration) / 30, 2.0)
        return weight(event.kind) * severityFactor(event.severity) * durationFactor
    }

    data class Result(
        /** 0…100. */
        val score: Int,
        val totalPenalty: Double,
        val penaltyPerKm: Double,
        /** Penalty points per event kind. */
        val penaltyByKind: Map<DrivingEventKind, Double>,
    )

    fun score(events: List<DrivingEvent>, distanceMeters: Double): Result {
        val byKind = LinkedHashMap<DrivingEventKind, Double>()
        var total = 0.0
        for (event in events) {
            val p = penalty(event)
            byKind[event.kind] = (byKind[event.kind] ?: 0.0) + p
            total += p
        }
        val perKm = total / max(distanceMeters / 1000, minimumDistanceKm)
        val raw = 100 - scale * perKm
        val score = min(100.0, max(0.0, raw)).rounded().toInt()
        return Result(score, total, perKm, byKind)
    }

    fun score(trip: Trip): Result = score(trip.events, TripStats.compute(trip).distanceMeters)

    /** Russian grade for the score. */
    fun grade(score: Int): String = when {
        score >= 90 -> "Отлично"
        score >= 75 -> "Хорошо"
        score >= 55 -> "Есть над чем поработать"
        else -> "Опасный стиль"
    }

    /** One-line description of the formula (Russian, for the report). */
    const val formulaDescription: String =
        "Балл = 100 − 10 × (штрафные очки на 1 км, не меньше 1 км). Очки события = вес вида × тяжесть (0,5 / 1 / 1,5) × (1 + длительность/30 с, макс. 3). Веса: красный свет 8, пешеход не пропущен 8, STOP 5, риск столкновения 5, превышение 3, дистанция 2, резкое торможение 2, резкий разгон 1,5, выезд из полосы 1,5."
}

/** CSV export of a trip (UTF-8, ',' separator, '.' decimals, ISO-8601 UTC timestamps). */
object TripExport {
    /** [title] names an event kind in the CSV "title" column (default: the Russian `tripReportTitle`). */
    fun eventsCSV(trip: Trip, title: (DrivingEventKind) -> String = { it.tripReportTitle }): String {
        val lines = mutableListOf("timestamp,kind,title,severity,latitude,longitude,speed_kmh,value,limit,duration_s,camera_estimate,note")
        for (event in trip.sortedEvents) {
            val fields = listOf(
                TripJson.iso(event.dateMillis),
                event.kind.raw,
                TripJson.escape(title(event.kind)),
                event.severity.rawValue.toString(),
                TripJson.number(event.coordinate?.latitude, 6),
                TripJson.number(event.coordinate?.longitude, 6),
                TripJson.number(event.speedKmh, 1),
                TripJson.number(event.value, 2),
                TripJson.number(event.limit, 2),
                TripJson.number(event.duration, 1),
                if (event.kind.isCameraBased) "1" else "0",
                TripJson.escape(event.note ?: ""),
            )
            lines.add(fields.joinToString(","))
        }
        return lines.joinToString("\n") + "\n"
    }

    fun pointsCSV(trip: Trip): String {
        val lines = mutableListOf("timestamp,latitude,longitude,speed_kmh,speed_limit_kmh,lead_distance_m_estimate,recommended_gap_m,accuracy_m")
        for (p in trip.points) {
            val fields = listOf(
                TripJson.iso(p.dateMillis),
                TripJson.number(p.coordinate.latitude, 6),
                TripJson.number(p.coordinate.longitude, 6),
                TripJson.number(p.speedKmh, 1),
                p.speedLimitKmh?.toString() ?: "",
                TripJson.number(p.leadDistanceMeters, 1),
                TripJson.number(p.recommendedGapMeters, 1),
                TripJson.number(p.horizontalAccuracy, 1),
            )
            lines.add(fields.joinToString(","))
        }
        return lines.joinToString("\n") + "\n"
    }

    /** "trip_2026-11-25_14-35" (local time of [timeZone]). */
    fun baseFileName(trip: Trip, timeZone: TimeZone = TimeZone.getDefault()): String {
        val t = Instant.ofEpochMilli(trip.startedAtMillis).atZone(timeZone.toZoneId())
        fun two(v: Int) = String.format(Locale.US, "%02d", v)
        return "trip_${t.year}-${two(t.monthValue)}-${two(t.dayOfMonth)}_${two(t.hour)}-${two(t.minute)}"
    }
}
