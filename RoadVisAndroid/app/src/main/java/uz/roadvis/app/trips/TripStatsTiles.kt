package uz.roadvis.app.trips

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Route
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.SocialDistance
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import uz.roadvis.core.TripStats

/** Number tiles of a trip (port of iOS `TripStatsGrid.tiles`), shared by the report screen and the PDF. */
object TripStatsTiles {
    data class Tile(val title: String, val value: String, val icon: ImageVector, val color: Color)

    @Suppress("DEPRECATION")
    fun tiles(stats: TripStats): List<Tile> {
        val result = mutableListOf(
            Tile(L("routes.row.distance"), AppFormat.distance(stats.distanceMeters), Icons.Filled.Route, RV.accent),
            Tile(L("report.tile.duration"), AppFormat.duration(stats.duration), Icons.Filled.Schedule, TripStyle.purple),
            Tile(L("routes.row.avgSpeed"), "${AppFormat.speed(stats.averageSpeedKmh)} ${AppFormat.kmh}", Icons.Filled.Speed, TripStyle.teal),
            Tile(L("report.tile.maxSpeed"), "${AppFormat.speed(stats.maxSpeedKmh)} ${AppFormat.kmh}", Icons.Filled.TrendingUp, TripStyle.orange),
            Tile(L("report.tile.overLimit"), AppFormat.duration(stats.timeOverLimit), Icons.Filled.Warning, RV.danger),
            Tile(L("report.tile.eventsPer100"), AppFormat.decimal(stats.eventsPer100km, 1), Icons.Filled.BarChart, RV.caution),
        )
        stats.averageLeadDistanceMeters?.let { lead ->
            result += Tile(L("report.tile.avgLead"), "≈ ${AppFormat.decimal(lead, 0)} ${AppFormat.meters}", Icons.Filled.SocialDistance, RV.safe)
        }
        result += Tile(L("norms.moving"), AppFormat.duration(stats.movingDuration), Icons.Filled.DirectionsCar, TripStyle.mint)
        return result
    }
}
