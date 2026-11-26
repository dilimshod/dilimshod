package uz.roadvis.app.camera

import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.core.DistanceStatus
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.FollowingDistanceNorms
import uz.roadvis.core.FollowingDistancePolicy
import uz.roadvis.core.PersonRole
import uz.roadvis.core.RVFormat
import uz.roadvis.core.RVLang
import uz.roadvis.core.RoadSegmentInfo
import uz.roadvis.core.RoadSurfaceCondition
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind
import uz.roadvis.core.decimal
import uz.roadvis.core.distance
import uz.roadvis.core.duration
import uz.roadvis.core.unitKmh
import uz.roadvis.core.unitMeters
import uz.roadvis.core.unitSeconds
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

// Text helpers of the camera screen in the app language (port of iOS `RVFormat.app…`, `DistanceFormatting.swift`
// and `CoreNames+L10n.swift`). Decimals use a comma in uz / ru and a point in English; estimates carry "≈".

/** Current app language as the core language. */
val appLang: RVLang get() = RVLang.fromRaw(LocalizationManager.language.raw) ?: RVLang.UZ

object CamFmt {
    val meters: String get() = RVFormat.unitMeters(appLang)
    val seconds: String get() = RVFormat.unitSeconds(appLang)
    val kmh: String get() = RVFormat.unitKmh(appLang)

    fun decimal(value: Double, digits: Int): String = RVFormat.decimal(value, digits, appLang)
    fun distance(meters: Double): String = RVFormat.distance(meters, appLang)
    fun duration(seconds: Double): String = RVFormat.duration(seconds, appLang)

    /** Rounded integer as text (Swift `Int(x.rounded())`). */
    private fun r(v: Double): Int = v.roundToInt()

    /** "1,6 m", "18 m", "125 m"; "—" when unknown. */
    fun gapMeters(meters: Double?): String {
        if (meters == null || !meters.isFinite()) return "—"
        val m = max(0.0, meters)
        if (m < 10) return decimal(m, 1) + " " + this.meters
        if (m < 100) return "${r(m)} " + this.meters
        return "${r(m / 5) * 5} " + this.meters
    }

    /** "1,4 s", "12 s"; "—" when unknown. */
    fun gapSeconds(seconds: Double?): String {
        if (seconds == null || !seconds.isFinite()) return "—"
        val s = max(0.0, seconds)
        return if (s < 10) decimal(s, 1) + " " + this.seconds else "${r(s)} " + this.seconds
    }

    /** Like [gapMeters] without a trailing ",0" below 10 m. */
    fun normMeters(meters: Double): String {
        if (!meters.isFinite()) return "—"
        return if (meters < 10) compactNumber(max(0.0, meters)) + " " + this.meters else gapMeters(meters)
    }

    /** 2 → "2", 1.5 → "1,5". */
    fun compactNumber(value: Double): String {
        if (!value.isFinite()) return "—"
        val rounded = (value * 10).roundToInt() / 10.0
        if (rounded == Math.rint(rounded)) return "${rounded.toInt()}"
        return decimal(rounded, 1)
    }

    /** GPS speed "54"; below 1 km/h "0". */
    fun speed(kmh: Double?): String {
        if (kmh == null || !kmh.isFinite()) return "—"
        return if (kmh < 1) "0" else RVFormat.speed(kmh)
    }

    fun spokenMeters(value: Double): String = spokenQuantity(value, "meter")
    fun spokenSeconds(value: Double): String = spokenQuantity(value, "second")

    private fun spokenQuantity(value: Double, unit: String): String {
        if (!value.isFinite()) return "—"
        val digits = if (value < 10) 1 else 0
        val one = L("unit.$unit.one"); val few = L("unit.$unit.few"); val many = L("unit.$unit.many")
        val factor = 10.0.pow(digits)
        val rounded = (max(0.0, value) * factor).roundToInt() / factor
        val isInt = rounded == Math.rint(rounded)
        val number = if (isInt) "${rounded.toInt()}" else decimal(rounded, digits)
        if (appLang == RVLang.RU) {
            return if (isInt) number + " " + RVFormat.plural(rounded.toInt(), one, few, many) else "$number $few"
        }
        return number + " " + (if (number == "1") one else many)
    }
}

// Localized names of core enums

val VehicleKind.localizedName: String get() = L("vehicle.$raw")
val TrafficLightColor.localizedName: String get() = L("light.$raw")
val RoadSurfaceCondition.localizedName: String get() = L("surface.$raw")
val DistanceStatus.localizedName: String get() = L("distanceStatus.$raw")
val PersonRole.localizedName: String get() = L("role.$raw")
/** "≈ YHXX xodimi" — the label of a box (marked as an estimate). */
val PersonRole.approximateName: String get() = "≈ $localizedName"

/** Officer / road worker role of a person track (null for pedestrians and other classes). */
val TrackedObject.roadStaffRole: PersonRole?
    get() {
        if (kind != VehicleKind.PERSON) return null
        val role = personRole ?: return null
        return if (role.isRoadStaff) role else null
    }

val FollowingDistanceNorms.Status.localizedName: String
    get() = when (this) {
        FollowingDistanceNorms.Status.NORM -> L("norms.status.norm")
        FollowingDistanceNorms.Status.RECOMMENDATION -> L("norms.status.recommendation")
        FollowingDistanceNorms.Status.APP_SETTING -> L("norms.status.appSetting")
    }

private fun lookup(key: String): String? = L(key).takeIf { it != key }
val FollowingDistanceNorms.Item.localizedTitle: String get() = lookup("norms.item.$id.title") ?: title
val FollowingDistanceNorms.Item.localizedText: String get() = lookup("norms.item.$id.text") ?: text
val FollowingDistanceNorms.Item.localizedSource: String get() = lookup("norms.item.$id.source") ?: source

/** Localized `displayName`: name ?: ref ?: localized road class. */
val RoadSegmentInfo.localizedDisplayName: String
    get() {
        if (!name.isNullOrEmpty()) return name!!
        if (!ref.isNullOrEmpty()) return ref!!
        return lookup("highway.$highway") ?: roadClassName
    }

/** Origin of the road surface used for the recommendation (port of iOS `RoadSurfaceSource`). */
enum class RoadSurfaceSource(val raw: String) {
    WEATHER("weather"), NO_WEATHER("noWeather"), MANUAL("manual");

    val localizedName: String
        get() = when (this) {
            WEATHER -> L("surfaceSource.auto")
            NO_WEATHER -> L("surfaceSource.noWeather")
            MANUAL -> L("surfaceSource.manual")
        }
}

/** Localized strings built from a [FollowingDistanceAssessment] and the active [FollowingDistancePolicy]. */
object FollowingDistanceText {
    fun gap(meters: Double?): String {
        if (meters == null || !meters.isFinite() || meters <= 0) return "—"
        return "≈ " + CamFmt.gapMeters(meters)
    }

    fun recommended(a: FollowingDistanceAssessment): String = "≥ " + CamFmt.normMeters(a.recommendedDistanceMeters)

    fun movingNorm(a: FollowingDistanceAssessment, policy: FollowingDistancePolicy): String {
        val gap = policy.timeGap(a.condition)
        val surface = a.condition.localizedName.lowercase()
        return if (!a.isStopped) {
            "≥ ${CamFmt.compactNumber(gap)} ${CamFmt.seconds} ≈ ${CamFmt.normMeters(a.recommendedDistanceMeters)} ($surface)"
        } else {
            "≥ ${CamFmt.compactNumber(gap)} ${CamFmt.seconds} ($surface)"
        }
    }

    fun stoppedNorm(policy: FollowingDistancePolicy): String = "≥ " + CamFmt.normMeters(policy.stoppedGapMeters)

    fun stoppingDistance(a: FollowingDistanceAssessment): String? {
        val d = a.stoppingDistanceMeters ?: return null
        if (!d.isFinite()) return null
        return "≈ " + CamFmt.gapMeters(d)
    }

    fun timeToCollision(a: FollowingDistanceAssessment): String? {
        val t = a.timeToCollisionSeconds ?: return null
        if (!t.isFinite()) return null
        return "≈ " + CamFmt.gapSeconds(t)
    }

    /** "closing 12 km/h" / "pulling away 5 km/h"; null below 2 km/h. */
    fun relativeMotion(relativeSpeedKmh: Double?): String? {
        val rel = relativeSpeedKmh ?: return null
        if (!rel.isFinite() || abs(rel) < 2) return null
        val value = abs(rel).roundToInt()
        return if (rel < 0) L("fd.closing", value) else L("fd.opening", value)
    }

    fun accessibilitySummary(a: FollowingDistanceAssessment, policy: FollowingDistancePolicy, hasLead: Boolean): String {
        val parts = mutableListOf<String>()
        val d = a.distanceMeters
        if (hasLead && d != null) {
            parts.add(L("fd.a11y.lead", CamFmt.spokenMeters(d)))
            parts.add(a.status.localizedName)
        } else {
            parts.add(L("fd.a11y.noLead"))
        }
        if (a.isStopped) parts.add(L("fd.a11y.stopped", CamFmt.spokenMeters(policy.stoppedGapMeters)))
        else parts.add(L("fd.a11y.moving", CamFmt.spokenMeters(a.recommendedDistanceMeters)))
        a.timeToCollisionSeconds?.let { parts.add(L("fd.a11y.ttc", CamFmt.spokenSeconds(it))) }
        return parts.joinToString(". ")
    }
}

/** Box label texts (port of the static helpers of iOS `DetectionOverlayView`). */
object TrackText {
    fun confidentMake(t: TrackedObject): String? {
        val make = t.make ?: return null
        val c = t.makeConfidence ?: return null
        return if (c >= 0.6) make else null
    }

    fun makeText(t: TrackedObject): String? {
        val make = t.make ?: return null
        val c = t.makeConfidence ?: return null
        if (c < 0.4) return null
        return if (c < 0.6) "$make?" else make
    }

    fun confidencePercent(t: TrackedObject): Int = (t.confidence.coerceIn(0.0, 1.0) * 100).roundToInt()

    fun title(t: TrackedObject): String {
        t.roadStaffRole?.let { return it.approximateName + " (" + L("role.heuristic") + ")" }
        if (t.kind == VehicleKind.TRAFFIC_LIGHT) {
            val c = t.lightColor
            return if (c != null && c != TrafficLightColor.UNKNOWN) "${t.kind.localizedName} · ${c.localizedName}" else t.kind.localizedName
        }
        makeText(t)?.let { return t.kind.localizedName + " · " + it }
        return t.kind.localizedName
    }

    fun compactTitle(t: TrackedObject): String {
        if (t.kind == VehicleKind.TRAFFIC_LIGHT) return title(t)
        t.roadStaffRole?.let { return it.approximateName }
        confidentMake(t)?.let { return t.kind.localizedName + " · " + it }
        return t.kind.localizedName
    }
}
