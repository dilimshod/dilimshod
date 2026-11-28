package uz.roadvis.app.about

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Report
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.AddRoad
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.l10n.L
import uz.roadvis.app.settings.ButtonRow
import uz.roadvis.app.settings.FormSection
import uz.roadvis.app.settings.LinkRow
import uz.roadvis.app.settings.NavRow
import uz.roadvis.app.settings.RowDivider
import uz.roadvis.app.settings.SecondaryText
import uz.roadvis.app.settings.SheetNav
import uz.roadvis.app.settings.SheetRoute
import uz.roadvis.app.settings.SheetScaffold
import uz.roadvis.app.settings.SourceRow
import uz.roadvis.app.settings.TextRow
import uz.roadvis.app.settings.ValueRow
import uz.roadvis.app.ui.RV

/** "1.0 (1)" from the package. */
object AppVersion {
    fun text(context: Context): String = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        "${info.versionName ?: "—"} ($code)"
    } catch (_: Exception) {
        "—"
    }
}

/** A developer of RoadVis (names stay in Latin script in every language). */
data class Developer(val name: String, val roleKey: String, val telegramHandle: String, val initials: String) {
    val telegramUrl: String get() = "https://t.me/${telegramHandle.trimStart('@')}"

    companion object {
        val all = listOf(
            Developer("Dilshod Imamaliyev", "dev.dilshod.role", "@dilimshod", "DI"),
            Developer("Soataliyev Raximjon", "dev.raximjon.role", "@engineer_iroad", "SR"),
        )
    }
}

/** Opens a Telegram profile (Telegram app via its t.me app link, else the browser). */
fun openTelegram(context: Context, developer: Developer) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(developer.telegramUrl)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: Exception) {
    }
}

/** MapKit route-guidance disclaimer shown verbatim in English in every language (kept as on iOS). */
const val ROUTE_GUIDANCE_DISCLAIMER =
    "YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE."

@Composable
fun AboutAppBadge(size: Dp = 52.dp) {
    Box(
        Modifier.size(size).background(Brush.linearGradient(listOf(Color(0xFF0A84FF), Color(0xFF30B0C7))), RoundedCornerShape(size * 0.24f)),
        contentAlignment = Alignment.Center,
    ) { Icon(Icons.Filled.DirectionsCar, null, tint = Color.White, modifier = Modifier.size(size * 0.5f)) }
}

/** "About" hub: description, offer, developers, data sources, version (port of iOS `AboutHubView`). */
@Composable
fun AboutHubScreen(nav: SheetNav) {
    val context = LocalContext.current
    SheetScaffold(L("about.title"), nav) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            FormSection(header = L("about.section.app")) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    AboutAppBadge()
                    Spacer(Modifier.width(14.dp))
                    Column {
                        Text("RoadVis", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        Text(L("desc.tagline"), color = SecondaryText, fontSize = 14.sp)
                    }
                }
                RowDivider()
                NavRow(L("about.description"), Icons.Filled.Info) { nav.push(SheetRoute.AboutDescription) }
                RowDivider()
                NavRow(L("about.developers"), Icons.Filled.People) { nav.push(SheetRoute.Developers) }
            }
            FormSection(header = L("about.section.legal")) {
                NavRow(L("about.offer"), Icons.Filled.Description) { nav.push(SheetRoute.Offer) }
                RowDivider()
                NavRow(L("about.sources"), Icons.Filled.Map) { nav.push(SheetRoute.DataSources) }
            }
            FormSection(footer = L("about.footer")) {
                ValueRow(L("about.version"), AppVersion.text(context), Icons.Filled.Tag)
            }
        }
    }
}

/** What RoadVis is and does (port of iOS `AppDescriptionView`). */
@Composable
fun AppDescriptionScreen(nav: SheetNav) {
    val features: List<Pair<ImageVector, String>> = listOf(
        Icons.Filled.DirectionsCar to "desc.f.vehicles",
        Icons.Filled.SwapHoriz to "desc.f.distance",
        Icons.Filled.Traffic to "desc.f.lights",
        Icons.Filled.Warning to "desc.f.signs",
        Icons.Filled.AddRoad to "desc.f.lanes",
        Icons.AutoMirrored.Filled.VolumeUp to "desc.f.voice",
        Icons.Filled.Map to "desc.f.navigator",
        Icons.Filled.BarChart to "desc.f.reports",
    )
    SheetScaffold(L("about.description"), nav) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            FormSection {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AboutAppBadge(60.dp)
                        Spacer(Modifier.width(14.dp))
                        Column {
                            Text(L("desc.title"), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                            Text(L("desc.tagline"), color = SecondaryText, fontSize = 14.sp)
                        }
                    }
                    Text(L("desc.intro"), color = Color.White, fontSize = 15.sp)
                }
            }
            FormSection(header = L("desc.featuresHeader")) {
                features.forEachIndexed { i, (icon, key) ->
                    if (i > 0) RowDivider()
                    IconText(icon, L(key), RV.accent)
                }
            }
            FormSection {
                IconText(Icons.Filled.Security, L("desc.privacy"), RV.safe)
                RowDivider()
                IconText(Icons.Filled.Report, L("desc.safety"), Color(0xFFFF9F0A))
            }
        }
    }
}

@Composable
private fun IconText(icon: ImageVector, text: String, tint: Color) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text(text, color = Color.White, fontSize = 15.sp)
    }
}

/** Public offer / terms of use (port of iOS `OfferView`). */
@Composable
fun OfferScreen(nav: SheetNav) {
    val context = LocalContext.current
    SheetScaffold(L("about.offer"), nav) {
        SelectionContainer {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(L("offer.title"), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Text(L("offer.subtitle"), color = SecondaryText, fontSize = 14.sp)
                }
                Row(
                    Modifier.fillMaxWidth().background(Color(0x26FF9F0A), RoundedCornerShape(12.dp)).padding(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(Icons.Filled.Info, null, tint = Color(0xFFFF9F0A))
                    Spacer(Modifier.width(8.dp))
                    Text(L("offer.templateNote"), color = Color(0xFFFF9F0A), fontSize = 13.sp)
                }
                for (n in 1..9) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(L("offer.s$n.title"), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                        Text(L("offer.s$n.body"), color = Color.White, fontSize = 15.sp)
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(L("offer.mapkitHeader"), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    Text(ROUTE_GUIDANCE_DISCLAIMER, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Developer.all.forEach { d ->
                        Row(Modifier.clickable { openTelegram(context, d) }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.AutoMirrored.Filled.Send, null, tint = RV.accent, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("${d.name} — ${d.telegramHandle}", color = RV.accent, fontSize = 15.sp)
                        }
                    }
                }
            }
        }
    }
}

/** Names, roles and Telegram links of the developers (port of iOS `DevelopersView`). */
@Composable
fun DevelopersScreen(nav: SheetNav) {
    val context = LocalContext.current
    SheetScaffold(L("dev.title"), nav) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            FormSection { TextRow(L("dev.intro")) }
            Developer.all.forEach { d ->
                FormSection {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
                        Box(Modifier.size(48.dp).background(RV.accent.copy(alpha = 0.25f), CircleShape), contentAlignment = Alignment.Center) {
                            Text(d.initials, color = RV.accent, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                        }
                        Spacer(Modifier.width(14.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(d.name, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Text(L(d.roleKey), color = SecondaryText, fontSize = 14.sp)
                        }
                    }
                    RowDivider()
                    ButtonRow("${L("dev.telegram")}: ${d.telegramHandle}", Icons.AutoMirrored.Filled.Send) { openTelegram(context, d) }
                }
            }
            FormSection { TextRow(L("dev.contactNote"), secondary = true) }
        }
    }
}

/** Data sources, licences and the safety notice (port of iOS `DataSourcesView`; Apple-only sources omitted). */
@Composable
fun DataSourcesScreen(nav: SheetNav) {
    SheetScaffold(L("about.sources"), nav) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            FormSection(header = L("sources.title")) {
                SourceRow(L("sources.osm.title"), L("sources.osm.detail"))
                LinkRow(L("sources.osm.copyright"), "https://www.openstreetmap.org/copyright")
                LinkRow(L("sources.osm.fix"), "https://www.openstreetmap.org/fixthemap")
                RowDivider()
                SourceRow("OpenFreeMap", "© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors")
                RowDivider()
                SourceRow("CARTO", "© OpenStreetMap contributors © CARTO")
                RowDivider()
                SourceRow(L("sources.weather.title"), L("sources.weather.detail"))
                LinkRow("open-meteo.com", "https://open-meteo.com/")
                RowDivider()
                SourceRow(L("sources.yolo.title"), L("sources.yolo.detail"))
            }
            FormSection(header = L("sources.safety.header")) {
                TextRow(L("sources.safety.body"))
                TextRow(ROUTE_GUIDANCE_DISCLAIMER, bold = true)
            }
        }
    }
}
