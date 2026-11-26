package uz.roadvis.app.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallMerge
import androidx.compose.material.icons.automirrored.filled.TrendingFlat
import androidx.compose.material.icons.filled.TurnLeft
import androidx.compose.material.icons.filled.TurnRight
import androidx.compose.material.icons.filled.TurnSlightLeft
import androidx.compose.material.icons.filled.TurnSlightRight
import androidx.compose.material.icons.filled.AltRoute
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.FamilyRestroom
import androidx.compose.material.icons.filled.Help
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.LocalParking
import androidx.compose.material.icons.filled.LocalPolice
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.RoundaboutRight
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.UTurnLeft
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WbCloudy
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.Water
import androidx.compose.material.icons.filled.ChangeHistory
import androidx.compose.material.icons.filled.Remove
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import uz.roadvis.app.ui.RV
import uz.roadvis.core.CongestionLevel
import uz.roadvis.core.LaneTurn
import uz.roadvis.core.ManeuverType
import uz.roadvis.core.RoadIncidentKind
import uz.roadvis.core.RouteFeatureKind
import uz.roadvis.core.RouteSource
import uz.roadvis.core.RouteTimelineKind

/** Colours and icons of the navigator (port of iOS `NavigatorStyle`; SF Symbols mapped to Material icons). */
object NavStyle {
    val maneuverGreen = Color(0xFF0A5C3D)
    val rerouteOrange = Color(0xFF9E5405)
    val orange = Color(0xFFFF9500)
    val purple = Color(0xFFAF52DE)
    val yellow = Color(0xFFFFCC00)
    val blue = Color(0xFF0A84FF)
    val gray = Color(0xFF8E8E93)
    val brown = Color(0xFFA2845E)
    val red = Color(0xFFFF3B30)
    val pink = Color(0xFFFF2D55)
    val teal = Color(0xFF30B0C7)
    val indigo = Color(0xFF5856D6)
    val cyan = Color(0xFF32ADE6)

    fun speedLimitColor(kmh: Int?): Color = when {
        kmh == null -> Color(0xFF8C99B3)
        kmh <= 30 -> Color(0xFFED424D)
        kmh <= 50 -> Color(0xFFFF9429)
        kmh <= 70 -> Color(0xFF1A7AFF)
        kmh <= 90 -> Color(0xFF1FB8D1)
        else -> Color(0xFF33C773)
    }

    val speedLimitLegend: List<Pair<String, Int?>>
        get() = listOf("≤30" to 30, "40–50" to 50, "60–70" to 70, "80–90" to 90, "≥100" to 100,
            uz.roadvis.app.l10n.L("common.noData") to null)

    fun featureColor(kind: RouteFeatureKind): Color = when (kind) {
        RouteFeatureKind.TRAFFIC_SIGNALS -> orange
        RouteFeatureKind.SPEED_CAMERA -> purple
        RouteFeatureKind.SCHOOL, RouteFeatureKind.KINDERGARTEN -> yellow
        RouteFeatureKind.PEDESTRIAN_CROSSING -> blue
        RouteFeatureKind.RAILWAY_CROSSING -> gray
        RouteFeatureKind.CONSTRUCTION -> orange
        RouteFeatureKind.TRAFFIC_CALMING -> brown
        RouteFeatureKind.STOP_SIGN -> red
        RouteFeatureKind.GIVE_WAY -> pink
        RouteFeatureKind.FUEL -> teal
        RouteFeatureKind.PARKING -> indigo
    }

    fun incidentColor(kind: RoadIncidentKind): Color = if (kind == RoadIncidentKind.SPEED_CAMERA) purple else red

    fun incidentTint(kind: RoadIncidentKind): Color = when (kind) {
        RoadIncidentKind.ACCIDENT, RoadIncidentKind.CLOSURE -> red
        RoadIncidentKind.ROAD_WORK, RoadIncidentKind.HAZARD -> orange
        RoadIncidentKind.JAM -> yellow
        RoadIncidentKind.POLICE -> blue
        RoadIncidentKind.POTHOLE -> brown
        RoadIncidentKind.SPEED_CAMERA -> purple
    }

    fun eventColor(kind: RouteTimelineKind): Color = when (kind) {
        is RouteTimelineKind.Maneuver -> Color(0xFF0A8054)
        is RouteTimelineKind.SpeedLimit -> speedLimitColor(kind.kmh)
        is RouteTimelineKind.Lanes -> gray
        RouteTimelineKind.TrafficSignal -> orange
        is RouteTimelineKind.Feature -> featureColor(kind.kind)
        is RouteTimelineKind.Incident -> incidentColor(kind.kind)
        RouteTimelineKind.Destination -> red
    }

    fun congestionColor(level: CongestionLevel): Color = when (level) {
        CongestionLevel.FREE -> RV.safe
        CongestionLevel.LIGHT -> yellow
        CongestionLevel.MODERATE -> RV.caution
        CongestionLevel.HEAVY -> RV.danger
        CongestionLevel.SEVERE -> Color(0xFF990000)
    }

    fun sourceColor(source: RouteSource): Color = when (source) {
        RouteSource.APPLE -> RV.accent
        RouteSource.VALHALLA -> RV.safe
        RouteSource.OSRM -> Color(0xFFB39EFF)
    }

    /** Material icon for an SF Symbol name used by the core. */
    fun icon(symbol: String): ImageVector = when (symbol) {
        "location.north.line.fill" -> Icons.Filled.Navigation
        "arrow.up" -> Icons.Filled.ArrowUpward
        "arrow.up.left" -> Icons.Filled.TurnSlightLeft
        "arrow.up.right" -> Icons.Filled.TurnSlightRight
        "arrow.turn.up.left" -> Icons.Filled.TurnLeft
        "arrow.turn.up.right" -> Icons.Filled.TurnRight
        "arrow.uturn.down" -> Icons.Filled.UTurnLeft
        "arrow.triangle.turn.up.right.circle" -> Icons.Filled.RoundaboutRight
        "arrow.merge" -> Icons.AutoMirrored.Filled.CallMerge
        "flag.checkered" -> Icons.Filled.Flag
        "arrow.triangle.branch" -> Icons.Filled.AltRoute
        "light.beacon.max" -> Icons.Filled.Traffic
        "figure.walk" -> Icons.Filled.DirectionsWalk
        "camera.fill" -> Icons.Filled.CameraAlt
        "exclamationmark.triangle", "exclamationmark.triangle.fill" -> Icons.Filled.WarningAmber
        "tram.fill" -> Icons.Filled.Train
        "graduationcap.fill" -> Icons.Filled.School
        "figure.and.child.holdinghands" -> Icons.Filled.FamilyRestroom
        "cone.fill" -> Icons.Filled.Construction
        "octagon.fill" -> Icons.Filled.Report
        "arrowtriangle.down" -> Icons.Filled.ChangeHistory
        "fuelpump.fill" -> Icons.Filled.LocalGasStation
        "parkingsign" -> Icons.Filled.LocalParking
        "speedometer" -> Icons.Filled.Speed
        "road.lanes" -> Icons.AutoMirrored.Filled.TrendingFlat
        "exclamationmark.octagon.fill" -> Icons.Filled.Report
        "car.2.fill" -> Icons.Filled.DirectionsCar
        "shield.fill" -> Icons.Filled.LocalPolice
        "exclamationmark.circle.fill" -> Icons.Filled.ErrorOutline
        "nosign" -> Icons.Filled.Block
        "sun.max.fill" -> Icons.Filled.WbSunny
        "moon.stars.fill", "cloud.moon.fill" -> Icons.Filled.NightsStay
        "cloud.sun.fill" -> Icons.Filled.WbCloudy
        "cloud.fill" -> Icons.Filled.Cloud
        "cloud.fog.fill" -> Icons.Filled.Cloud
        "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill", "cloud.sleet.fill" -> Icons.Filled.Water
        "cloud.snow.fill", "cloud.hail.fill" -> Icons.Filled.AcUnit
        "cloud.bolt.rain.fill" -> Icons.Filled.Thunderstorm
        "thermometer" -> Icons.Filled.Thermostat
        else -> Icons.Filled.Help
    }

    fun maneuverIcon(type: ManeuverType): ImageVector = icon(type.symbolName)

    fun laneIcon(turn: LaneTurn): ImageVector = when (turn) {
        LaneTurn.NONE -> Icons.Filled.Remove
        else -> icon(turn.symbolName)
    }

    /** Glyph drawn inside map markers (osmdroid canvas; emoji render with the system font). */
    fun glyph(kind: RouteTimelineKind): String = when (kind) {
        is RouteTimelineKind.Maneuver -> when {
            kind.type.isLeftward -> "↰"
            kind.type.isRightward -> "↱"
            kind.type == ManeuverType.ROUNDABOUT -> "⟳"
            else -> "↑"
        }
        is RouteTimelineKind.SpeedLimit -> kind.kmh?.toString() ?: "?"
        is RouteTimelineKind.Lanes -> "${kind.to}"
        RouteTimelineKind.TrafficSignal -> "🚦"
        is RouteTimelineKind.Feature -> featureGlyph(kind.kind)
        is RouteTimelineKind.Incident -> incidentGlyph(kind.kind)
        RouteTimelineKind.Destination -> "🏁"
    }

    fun featureGlyph(kind: RouteFeatureKind): String = when (kind) {
        RouteFeatureKind.TRAFFIC_SIGNALS -> "🚦"
        RouteFeatureKind.PEDESTRIAN_CROSSING -> "🚶"
        RouteFeatureKind.SPEED_CAMERA -> "📷"
        RouteFeatureKind.TRAFFIC_CALMING -> "⚠"
        RouteFeatureKind.RAILWAY_CROSSING -> "🚆"
        RouteFeatureKind.SCHOOL -> "🏫"
        RouteFeatureKind.KINDERGARTEN -> "🧒"
        RouteFeatureKind.CONSTRUCTION -> "🚧"
        RouteFeatureKind.STOP_SIGN -> "🛑"
        RouteFeatureKind.GIVE_WAY -> "▽"
        RouteFeatureKind.FUEL -> "⛽"
        RouteFeatureKind.PARKING -> "P"
    }

    fun incidentGlyph(kind: RoadIncidentKind): String = when (kind) {
        RoadIncidentKind.ACCIDENT -> "💥"
        RoadIncidentKind.ROAD_WORK -> "🚧"
        RoadIncidentKind.JAM -> "🚗"
        RoadIncidentKind.POLICE -> "👮"
        RoadIncidentKind.POTHOLE -> "🕳"
        RoadIncidentKind.HAZARD -> "⚠"
        RoadIncidentKind.CLOSURE -> "⛔"
        RoadIncidentKind.SPEED_CAMERA -> "📷"
    }
}
