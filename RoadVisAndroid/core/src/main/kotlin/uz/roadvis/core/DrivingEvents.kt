package uz.roadvis.core

import org.json.JSONObject
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

// Dates are epoch milliseconds (`...Millis`), durations Double seconds — see TripJson.kt.

/** Kinds of driving events recorded for the trip report (driver-coaching for beginners). */
enum class DrivingEventKind(val raw: String) {
    /** Own GPS speed above the posted limit (+ tolerance). */
    SPEEDING("speeding"),
    /** Gap to the lead vehicle below the recommended following distance. */
    TAILGATING("tailgating"),
    /** Time to collision with the lead vehicle below the warning threshold. */
    COLLISION_RISK("collisionRisk"),
    /** Vehicle crossed a lane marking (camera, heuristic). */
    LANE_DEPARTURE("laneDeparture"),
    /** Moved through an intersection while the camera saw a red light (heuristic). */
    RED_LIGHT_RUNNING("redLightRunning"),
    /** Did not stop at a STOP sign (camera/OSM, heuristic). */
    STOP_SIGN_IGNORED("stopSignIgnored"),
    /** Kept driving (> 15 km/h) while a pedestrian was in the own lane close ahead (camera, heuristic). */
    PEDESTRIAN_NOT_YIELDED("pedestrianNotYielded"),
    /** Strong deceleration (GPS / motion sensors). */
    HARSH_BRAKING("harshBraking"),
    /** Strong acceleration (GPS / motion sensors). */
    HARSH_ACCELERATION("harshAcceleration"),
    /** A traffic police officer (YHXX) was seen on / at the roadway (info, not a violation). */
    TRAFFIC_OFFICER_SEEN("trafficOfficerSeen"),
    /** Road workers were seen on / near the roadway (info, not a violation). */
    ROAD_WORKERS_SEEN("roadWorkersSeen");

    /** Default severity used when an event is created without an explicit one. */
    val defaultSeverity: DrivingEventSeverity
        get() = when (this) {
            SPEEDING, TAILGATING, LANE_DEPARTURE, HARSH_BRAKING, HARSH_ACCELERATION -> DrivingEventSeverity.WARNING
            COLLISION_RISK, RED_LIGHT_RUNNING, STOP_SIGN_IGNORED, PEDESTRIAN_NOT_YIELDED -> DrivingEventSeverity.VIOLATION
            TRAFFIC_OFFICER_SEEN, ROAD_WORKERS_SEEN -> DrivingEventSeverity.INFO
        }

    /** SF Symbol name (iOS reference; Android maps kinds to its own icons). */
    val symbolName: String
        get() = when (this) {
            SPEEDING -> "gauge.with.dots.needle.67percent"
            TAILGATING -> "car.2.fill"
            COLLISION_RISK -> "exclamationmark.triangle.fill"
            LANE_DEPARTURE -> "road.lanes"
            RED_LIGHT_RUNNING -> "light.beacon.max.fill"
            STOP_SIGN_IGNORED -> "octagon.fill"
            PEDESTRIAN_NOT_YIELDED -> "figure.walk"
            HARSH_BRAKING -> "arrow.down.circle.fill"
            HARSH_ACCELERATION -> "arrow.up.circle.fill"
            TRAFFIC_OFFICER_SEEN -> "shield.fill"
            ROAD_WORKERS_SEEN -> "hammer.fill"
        }

    /** Russian name used in the trip report. */
    val tripReportTitle: String
        get() = when (this) {
            SPEEDING -> "Превышение скорости"
            TAILGATING -> "Малая дистанция"
            COLLISION_RISK -> "Риск столкновения"
            LANE_DEPARTURE -> "Выезд из полосы"
            RED_LIGHT_RUNNING -> "Проезд на красный"
            STOP_SIGN_IGNORED -> "Без остановки у STOP"
            PEDESTRIAN_NOT_YIELDED -> "Пешеход не пропущен"
            HARSH_BRAKING -> "Резкое торможение"
            HARSH_ACCELERATION -> "Резкий разгон"
            TRAFFIC_OFFICER_SEEN -> "Сотрудник ГАИ (YHXX)"
            ROAD_WORKERS_SEEN -> "Дорожные рабочие"
        }

    /** Whether the event comes from the camera (an estimate) rather than GPS / sensors. */
    val isCameraBased: Boolean
        get() = when (this) {
            TAILGATING, COLLISION_RISK, LANE_DEPARTURE, RED_LIGHT_RUNNING, STOP_SIGN_IGNORED, PEDESTRIAN_NOT_YIELDED,
            TRAFFIC_OFFICER_SEEN, ROAD_WORKERS_SEEN -> true
            SPEEDING, HARSH_BRAKING, HARSH_ACCELERATION -> false
        }

    /** Unit of [DrivingEvent.value] for this kind (Russian). */
    val tripValueUnit: String
        get() = when (this) {
            SPEEDING -> "км/ч сверх"
            TAILGATING, PEDESTRIAN_NOT_YIELDED, TRAFFIC_OFFICER_SEEN, ROAD_WORKERS_SEEN -> "м"
            COLLISION_RISK -> "с до столкн."
            LANE_DEPARTURE -> ""
            RED_LIGHT_RUNNING, STOP_SIGN_IGNORED -> "км/ч"
            HARSH_BRAKING, HARSH_ACCELERATION -> "м/с²"
        }

    companion object {
        fun fromRaw(raw: String): DrivingEventKind? = entries.firstOrNull { it.raw == raw }
    }
}

/** Ordered INFO < WARNING < VIOLATION. */
enum class DrivingEventSeverity(val rawValue: Int) {
    INFO(0), WARNING(1), VIOLATION(2);

    companion object {
        fun fromRaw(raw: Int): DrivingEventSeverity? = entries.firstOrNull { it.rawValue == raw }
    }
}

/** One event of a trip. All camera-based values are estimates. */
data class DrivingEvent(
    var id: UUID = UUID.randomUUID(),
    var kind: DrivingEventKind,
    var severity: DrivingEventSeverity = kind.defaultSeverity,
    /** Event time, epoch milliseconds. */
    var dateMillis: Long = System.currentTimeMillis(),
    var coordinate: GeoPoint? = null,
    /** Own speed at the event, km/h. */
    var speedKmh: Double? = null,
    /** Measured value: km/h over the limit, gap in metres, time to collision in s, deceleration in m/s², offset… */
    var value: Double? = null,
    /** Reference value: speed limit km/h, recommended gap m, threshold… */
    var limit: Double? = null,
    /** How long the condition lasted, seconds (0 for instantaneous events). */
    var duration: Double = 0.0,
    /** Free text (e.g. road name), not localized. */
    var note: String? = null,
) {
    fun toJson(): JSONObject {
        val o = JSONObject()
            .put("id", id.toString())
            .put("kind", kind.raw)
            .put("severity", severity.rawValue)
            .put("date", dateMillis)
            .put("duration", duration)
        coordinate?.let { o.put("coordinate", TripJson.geo(it)) }
        TripJson.putOpt(o, "speedKmh", speedKmh)
        TripJson.putOpt(o, "value", value)
        TripJson.putOpt(o, "limit", limit)
        TripJson.putOpt(o, "note", note)
        return o
    }

    companion object {
        fun fromJson(o: JSONObject): DrivingEvent {
            val kind = DrivingEventKind.fromRaw(o.getString("kind"))
                ?: throw IllegalArgumentException("unknown event kind ${o.getString("kind")}")
            return DrivingEvent(
                id = UUID.fromString(o.getString("id")),
                kind = kind,
                severity = TripJson.optInt(o, "severity")?.let { DrivingEventSeverity.fromRaw(it) } ?: kind.defaultSeverity,
                dateMillis = o.getLong("date"),
                coordinate = TripJson.optObject(o, "coordinate")?.let { TripJson.geo(it) },
                speedKmh = TripJson.optDouble(o, "speedKmh"),
                value = TripJson.optDouble(o, "value"),
                limit = TripJson.optDouble(o, "limit"),
                duration = TripJson.optDouble(o, "duration") ?: 0.0,
                note = TripJson.optString(o, "note"),
            )
        }
    }
}

/**
 * Collapses repeated events: a new event of the same kind within [cooldown] seconds extends the previous one
 * (duration, worst value) instead of creating a duplicate. Used by both the camera and the trip recorder.
 */
class DrivingEventDebouncer(var cooldown: Double = 8.0) {
    private val lastIndexByKind = HashMap<DrivingEventKind, Int>()
    private val _events = mutableListOf<DrivingEvent>()
    val events: List<DrivingEvent> get() = _events

    /** Adds or merges the event. Returns true when a NEW event was created (callers announce only new ones). */
    fun add(event: DrivingEvent): Boolean {
        val i = lastIndexByKind[event.kind]
        if (i != null) {
            val previous = _events[i]
            if ((event.dateMillis - previous.dateMillis) / 1000.0 - previous.duration <= cooldown) {
                val merged = previous.copy()
                merged.duration = max(previous.duration, (event.dateMillis - previous.dateMillis) / 1000.0 + event.duration)
                merged.severity = maxOf(previous.severity, event.severity)
                val v = event.value
                if (v != null) {
                    val old = merged.value
                    merged.value = if (old != null) (if (event.kind in smallerIsWorse) min(old, v) else max(old, v)) else v
                }
                _events[i] = merged
                return false
            }
        }
        _events.add(event)
        lastIndexByKind[event.kind] = _events.size - 1
        return true
    }

    fun reset() {
        _events.clear()
        lastIndexByKind.clear()
    }

    private companion object {
        /** Keep the worst value: larger for "over" quantities, smaller for gaps / TTC. */
        val smallerIsWorse = setOf(
            DrivingEventKind.TAILGATING, DrivingEventKind.COLLISION_RISK, DrivingEventKind.PEDESTRIAN_NOT_YIELDED,
            DrivingEventKind.TRAFFIC_OFFICER_SEEN, DrivingEventKind.ROAD_WORKERS_SEEN,
        )
    }
}
