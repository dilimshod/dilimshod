package uz.roadvis.app.camera

import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.Lin
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.core.CoachMessage
import uz.roadvis.core.LaneSide
import uz.roadvis.core.RVFormat
import uz.roadvis.core.RouteFeatureKind

/**
 * Spoken phrases of the beginner-driver coach (`CoachMessage` → text) in the app language (port of iOS
 * `CoachPhrases.swift`; texts are the "coach.*" keys of the string tables). Numbers stay digits.
 */
object CoachPhrases {
    fun phrase(m: CoachMessage, language: AppLanguage = LocalizationManager.language): String {
        fun text(key: String) = Lin(key, language)
        fun format(key: String, vararg args: Any?) = LocalizationManager.format(key, language, *args)
        return when (m) {
            CoachMessage.CollisionRisk -> text("coach.collision")
            is CoachMessage.PedestrianDanger -> text("coach.pedestrian.danger")
            is CoachMessage.PedestrianCaution -> text("coach.pedestrian.caution")
            CoachMessage.RedLightAhead -> text("coach.redLight")
            is CoachMessage.LaneDeparture -> text(if (m.side == LaneSide.LEFT) "coach.lane.left" else "coach.lane.right")
            is CoachMessage.KeepDistance -> {
                val meters = m.recommendedMeters
                if (meters != null && meters > 0) format("coach.keepDistance.meters", meterQuantity(meters, language))
                else text("coach.keepDistance")
            }
            is CoachMessage.RoadSign -> format("coach.roadSign", meterQuantity(m.distanceMeters, language), name(m.kind, language))
            is CoachMessage.SpeedLimit -> format("coach.speedLimit", m.kmh)
            is CoachMessage.SpeedLimitAhead -> format("coach.speedLimitAhead", meterQuantity(m.distanceMeters, language), m.kmh)
            CoachMessage.StopSignAhead -> text("coach.stopSign")
            is CoachMessage.OverSpeedLimit -> format("coach.overLimit", m.limitKmh)
            CoachMessage.GreenLightGo -> text("coach.green")
            is CoachMessage.TrafficOfficerAhead -> text("coach.trafficOfficer")
            is CoachMessage.RoadWorkersAhead -> text("coach.roadWorkers")
        }
    }

    fun name(kind: RouteFeatureKind, language: AppLanguage): String = Lin("coach.sign.${kind.raw}", language)

    /** "300 metr" / "300 метров" / "300 metres". */
    fun meterQuantity(n: Int, language: AppLanguage): String {
        val one = Lin("unit.meter.one", language); val few = Lin("unit.meter.few", language)
        val many = Lin("unit.meter.many", language)
        if (language == AppLanguage.RU) return "$n " + RVFormat.plural(n, one, few, many)
        return "$n " + (if (n == 1) one else many)
    }
}
