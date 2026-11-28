package uz.roadvis.app.trips

import androidx.compose.ui.graphics.Color
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.app.ui.RV
import uz.roadvis.core.DrivingEvent
import uz.roadvis.core.DrivingEventKind
import uz.roadvis.core.DrivingEventSeverity
import uz.roadvis.core.GeoPoint
import uz.roadvis.core.RVFormat
import uz.roadvis.core.RVLang
import uz.roadvis.core.Trip
import uz.roadvis.core.TripSpeedBand
import uz.roadvis.core.decimal
import uz.roadvis.core.distance
import uz.roadvis.core.duration
import uz.roadvis.core.unitKmh
import uz.roadvis.core.unitMeters
import uz.roadvis.core.unitSeconds
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Core formatting in the current app language (port of iOS `RVFormat.app…`). */
object AppFormat {
    val lang: RVLang get() = RVLang.fromRaw(LocalizationManager.language.raw) ?: RVLang.UZ
    fun distance(meters: Double): String = RVFormat.distance(meters, lang)
    fun duration(seconds: Double): String = RVFormat.duration(seconds, lang)
    fun decimal(value: Double, digits: Int): String = RVFormat.decimal(value, digits, lang)
    fun speed(kmh: Double): String = RVFormat.speed(kmh)
    val kmh: String get() = RVFormat.unitKmh(lang)
    val meters: String get() = RVFormat.unitMeters(lang)
    val seconds: String get() = RVFormat.unitSeconds(lang)
    fun percent(share: Double): String = "${Math.round(share * 100)}%"
}

/** Localized `tripReportTitle`. */
val DrivingEventKind.localizedTitle: String get() = L("event.$raw")

/** "0–5 km/soat" … */
val TripSpeedBand.localizedTitle: String
    get() {
        val unit = AppFormat.kmh
        return when (this) {
            TripSpeedBand.STANDING -> "0–5 $unit"
            TripSpeedBand.SLOW -> "5–30 $unit"
            TripSpeedBand.URBAN -> "30–60 $unit"
            TripSpeedBand.FAST -> "60–90 $unit"
            TripSpeedBand.HIGHWAY -> "90+ $unit"
        }
    }

/** Colours and texts of the trip report (shared by the live report, the PDF and the history). Port of iOS `TripStyle`. */
object TripStyle {
    val purple = Color(0xFFBF5AF2)
    val teal = Color(0xFF40C8E0)
    val orange = Color(0xFFFF9F0A)
    val mint = Color(0xFF66D4CF)
    val route = Color(0xB38E8E93)

    fun color(kind: DrivingEventKind): Color = when (kind) {
        DrivingEventKind.SPEEDING -> Color(1.0f, 0.27f, 0.27f)
        DrivingEventKind.TAILGATING -> Color(1.0f, 0.62f, 0.1f)
        DrivingEventKind.COLLISION_RISK -> Color(0.93f, 0.1f, 0.45f)
        DrivingEventKind.LANE_DEPARTURE -> Color(0.98f, 0.85f, 0.2f)
        DrivingEventKind.RED_LIGHT_RUNNING -> Color(0.8f, 0.05f, 0.1f)
        DrivingEventKind.STOP_SIGN_IGNORED -> Color(0.75f, 0.35f, 1.0f)
        DrivingEventKind.PEDESTRIAN_NOT_YIELDED -> Color(1.0f, 0.1f, 0.1f)
        DrivingEventKind.HARSH_BRAKING -> Color(0.2f, 0.6f, 1.0f)
        DrivingEventKind.HARSH_ACCELERATION -> Color(0.2f, 0.85f, 0.85f)
        DrivingEventKind.TRAFFIC_OFFICER_SEEN -> RV.trafficOfficer
        DrivingEventKind.ROAD_WORKERS_SEEN -> RV.roadWorker
    }

    /** Ring colour of event markers on the map: info white, warning amber, violation red. */
    fun severityColor(severity: DrivingEventSeverity): Color = when (severity) {
        DrivingEventSeverity.INFO -> Color.White
        DrivingEventSeverity.WARNING -> RV.caution
        DrivingEventSeverity.VIOLATION -> RV.danger
    }

    fun scoreColor(score: Int): Color = when {
        score >= 90 -> RV.safe
        score >= 75 -> Color(0.55f, 0.85f, 0.3f)
        score >= 55 -> RV.caution
        else -> RV.danger
    }

    fun bandColor(band: TripSpeedBand): Color = when (band) {
        TripSpeedBand.STANDING -> Color(0.6f, 0.6f, 0.6f)
        TripSpeedBand.SLOW -> Color(0.35f, 0.75f, 1.0f)
        TripSpeedBand.URBAN -> RV.safe
        TripSpeedBand.FAST -> RV.caution
        TripSpeedBand.HIGHWAY -> Color(1.0f, 0.45f, 0.3f)
    }

    /** Localized `TripScoring.grade`. */
    fun grade(score: Int): String = when {
        score >= 90 -> L("score.grade.excellent")
        score >= 75 -> L("score.grade.good")
        score >= 55 -> L("score.grade.work")
        else -> L("score.grade.dangerous")
    }

    val formula: String get() = L("score.formula")

    /** "Дом → Работа". */
    fun title(trip: Trip): String {
        val a = trip.origin.name ?: L("trip.start")
        val b = trip.destination?.name ?: L("trip.finish")
        return "$a → $b"
    }

    private val locale: Locale get() = LocalizationManager.language.locale

    /** "25 нояб. 2026 г., 14:35". */
    fun dateText(trip: Trip): String = dateText(trip.startedAtMillis)

    fun dateText(millis: Long): String =
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale)
            .format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))

    fun timeText(millis: Long): String =
        DateTimeFormatter.ofPattern("HH:mm:ss", locale).format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))

    fun clockText(millis: Long): String =
        DateTimeFormatter.ofPattern("HH:mm", locale).format(Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()))

    /** Measured value of an event in words, estimates marked with ≈. */
    fun valueText(event: DrivingEvent): String {
        fun n(v: Double, digits: Int = 0) = AppFormat.decimal(v, digits)
        val estimate = " (" + L("common.estimate") + ")"
        return when (event.kind) {
            DrivingEventKind.SPEEDING -> {
                var text = event.value?.let { "+${n(it)} ${AppFormat.kmh}" } ?: L("tripval.speeding")
                event.limit?.let { text += " " + L("tripval.atLimit", n(it)) }
                if (event.duration > 0) text += " · ${AppFormat.duration(event.duration)}"
                text
            }
            DrivingEventKind.TAILGATING -> {
                var text = event.value?.let { "≈ ${n(it)} ${AppFormat.meters}" } ?: L("tripval.tooClose")
                event.limit?.let { text += " " + L("tripval.atNorm", n(it)) }
                text + estimate
            }
            DrivingEventKind.COLLISION_RISK ->
                (event.value?.let { L("tripval.ttc", n(it, 1)) } ?: L("tripval.closing")) + estimate
            DrivingEventKind.HARSH_BRAKING, DrivingEventKind.HARSH_ACCELERATION -> {
                var text = event.value?.let { "${n(it, 1)} ${L("event.unit.harshBraking")}" } ?: "—"
                event.limit?.let { text += " (" + L("tripval.threshold", n(it, 1)) + ")" }
                text
            }
            DrivingEventKind.PEDESTRIAN_NOT_YIELDED -> {
                var text = event.value?.let { "≈ ${n(it)} ${AppFormat.meters}" } ?: ("≈ " + L("fd.cameraEstimate"))
                event.speedKmh?.let { text += " " + L("tripval.atSpeed", n(it)) }
                text + estimate
            }
            DrivingEventKind.TRAFFIC_OFFICER_SEEN, DrivingEventKind.ROAD_WORKERS_SEEN -> {
                val text = event.value?.let { "≈ ${n(it)} ${AppFormat.meters}" } ?: ("≈ " + L("fd.cameraEstimate"))
                text + " (" + L("role.heuristic") + ")"
            }
            DrivingEventKind.LANE_DEPARTURE, DrivingEventKind.RED_LIGHT_RUNNING, DrivingEventKind.STOP_SIGN_IGNORED -> {
                val speed = event.speedKmh?.let { " " + L("tripval.atSpeed", n(it)) } ?: ""
                "≈ " + L("fd.cameraEstimate") + speed
            }
        }
    }

    /** "41.31110, 69.27970". */
    fun coordinateText(point: GeoPoint?): String =
        point?.let { String.format(Locale.US, "%.5f, %.5f", it.latitude, it.longitude) } ?: "—"

    /** Note + coordinate line of an event (GPS / motion-sensor notes localized). */
    fun placeText(event: DrivingEvent): String {
        val parts = mutableListOf<String>()
        val note = event.note
        if (!note.isNullOrEmpty()) parts += if (note.startsWith("GPS +")) L("trip.note.gpsSensors") else note
        parts += coordinateText(event.coordinate)
        return parts.joinToString(" · ")
    }
}
