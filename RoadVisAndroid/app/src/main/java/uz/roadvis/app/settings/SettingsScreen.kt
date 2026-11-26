package uz.roadvis.app.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AddRoad
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uz.roadvis.app.about.AppVersion
import uz.roadvis.app.app.AppState
import uz.roadvis.app.app.AppSettings
import uz.roadvis.app.app.SpeechPriority
import uz.roadvis.app.app.SpeechVoiceKind
import uz.roadvis.app.l10n.AppLanguage
import uz.roadvis.app.l10n.L
import uz.roadvis.app.l10n.LocalizationManager
import uz.roadvis.app.trips.AppFormat
import uz.roadvis.app.trips.TripSettingsSection
import uz.roadvis.app.ui.RV
import uz.roadvis.core.OSRM
import uz.roadvis.core.RVLang
import uz.roadvis.core.RoadSurfaceCondition
import uz.roadvis.core.SignalTimingAssumptions
import uz.roadvis.core.SignalWaitModel
import uz.roadvis.core.Valhalla
import uz.roadvis.core.VoiceClipCatalog
import uz.roadvis.core.VoicePhrase
import kotlin.math.roundToInt

/** All user settings grouped by topic, plus data sources and the safety notice (port of iOS `SettingsView`). */
@Composable
fun SettingsScreen(app: AppState, nav: SheetNav) {
    SheetScaffold(L("common.settings"), nav) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            LanguageSection(app)
            RecognitionSection(app)
            FollowingDistanceSection(app)
            DriverAssistSections(app)
            TripSettingsSection(app, nav)
            GeneralNavigationSection(app)
            NavigationSettingsSections(app)
            RoadDataSection(app)
            SignalSection(app)
            AboutSections(nav)
        }
    }
}

private fun percent(v: Double) = "${(v * 100).roundToInt()}%"

/** Trimmed http(s) URL with a host, else null (port of iOS `settingsValidatedURL`). */
internal fun validatedUrl(text: String): String? {
    val trimmed = text.trim()
    return try {
        val uri = java.net.URI(trimmed)
        val scheme = uri.scheme?.lowercase()
        if ((scheme == "https" || scheme == "http") && !uri.host.isNullOrEmpty()) trimmed else null
    } catch (_: Exception) {
        null
    }
}

// Language

@Composable
private fun LanguageSection(app: AppState) {
    val lang = LocalizationManager.language
    val kind = app.speech.voiceKind
    val footer = buildString {
        append(L("language.footer"))
        if (lang == AppLanguage.UZ && kind != SpeechVoiceKind.NATIVE) append("\n\n").append(TL("language.voice.uzNote"))
    }
    FormSection(header = "${L("language.title")} · Til · Язык · Language", footer = footer) {
        Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.Icon(Icons.Filled.Language, null, tint = RV.accent, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(8.dp))
            Text(L("language.picker"), color = SecondaryText, fontSize = 13.sp)
        }
        ChoiceRows(AppLanguage.entries.map { it.raw to it.displayName }, lang.raw, { LocalizationManager.select(AppLanguage.fromRaw(it)) })
        RowDivider()
        // Voice in use
        val approximate = kind == SpeechVoiceKind.APPROXIMATE_TURKISH || kind == SpeechVoiceKind.APPROXIMATE_RUSSIAN
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("language.voice.label"), color = androidx.compose.ui.graphics.Color.White, modifier = Modifier.weight(1f))
                if (approximate) {
                    Text(L("language.voice.approxBadge"), color = RV.caution, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.background(RV.caution.copy(alpha = 0.25f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
                }
            }
            val text = when (kind) {
                SpeechVoiceKind.NATIVE, SpeechVoiceKind.NATURAL_CLIPS -> L("language.voice.native", lang.voiceLanguageCode)
                SpeechVoiceKind.APPROXIMATE_TURKISH -> L("language.voice.approxTurkish", "tr-TR")
                SpeechVoiceKind.APPROXIMATE_RUSSIAN -> L("language.voice.approxRussian", "ru-RU")
                SpeechVoiceKind.SYSTEM_DEFAULT -> TL("language.voice.systemDefault")
            }
            Text(text, color = if (approximate) RV.caution else SecondaryText, fontSize = 13.sp)
        }
        RowDivider()
        // Natural voice clips
        val core = RVLang.fromRaw(lang.raw) ?: RVLang.UZ
        val installed = remember(lang) { app.speech.clips.installedCount("${lang.raw}_") }
        val total = remember(lang) { VoiceClipCatalog.clipIDs(core).size }
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(L("language.natural.title"), color = androidx.compose.ui.graphics.Color.White)
            if (installed > 0) {
                Text(L("language.natural.installed", installed, total), color = SecondaryText, fontSize = 13.sp)
                Text(L("language.natural.partial"), color = SecondaryText, fontSize = 13.sp)
            } else {
                Text(TL("language.natural.missing"), color = SecondaryText, fontSize = 13.sp)
            }
        }
        RowDivider()
        ButtonRow(L("language.voice.test"), Icons.AutoMirrored.Filled.VolumeUp, enabled = !app.speech.isMuted) {
            app.speech.speak(VoicePhrase.sample(L("language.voice.sample")), SpeechPriority.HIGH)
        }
    }
}

// Recognition

@Composable
private fun RecognitionSection(app: AppState) {
    val s = app.settings
    FormSection(header = L("recStatus.title"), footer = L("settings.rec.footer")) {
        SliderRow(L("settings.rec.threshold"), L("settings.rec.confidenceValue", percent(s.detectionConfidence)),
            s.detectionConfidence, 0.15..0.8, 0.05, { s.detectionConfidence = it })
        RowDivider()
        ToggleRow(L("settings.rec.makes"), s.makeRecognitionEnabled, { s.makeRecognitionEnabled = it })
        ToggleRow(L("settings.rec.distance"), s.showDistanceEstimates, { s.showDistanceEstimates = it })
        ToggleRow(L("settings.rec.speed"), s.showSpeedEstimates, { s.showSpeedEstimates = it })
        ToggleRow(L("settings.rec.pedestrians"), s.trackPedestrians, { s.trackPedestrians = it })
        ToggleRow(L("settings.rec.lights"), s.detectTrafficLights, { s.detectTrafficLights = it })
        ToggleRow(L("settings.rec.log"), s.recordExperimentLog, { s.recordExperimentLog = it })
    }
}

// Following distance

@Composable
private fun FollowingDistanceSection(app: AppState) {
    val s = app.settings
    val on = s.followingDistanceEnabled
    fun m(v: Double) = "${AppFormat.decimal(v, 1)} ${AppFormat.meters}"
    fun sec(v: Double) = "${AppFormat.decimal(v, 1)} ${AppFormat.seconds}"
    FormSection(header = L("settings.fd.title"), footer = L("settings.fd.footer")) {
        ToggleRow(L("settings.fd.enabled"), on, { s.followingDistanceEnabled = it })
        RowDivider()
        StepperRow(L("settings.fd.dryGap"), s.followingTimeGapDry, 1.0..4.0, 0.5, sec(s.followingTimeGapDry), { s.followingTimeGapDry = it }, on)
        StepperRow(L("settings.fd.hood"), s.hoodLengthMeters, 0.0..4.0, 0.1, m(s.hoodLengthMeters), { s.hoodLengthMeters = it }, on)
        HoodCalibrationRow(app, on)
        RowDivider()
        StepperRow(L("settings.fd.stoppedGap"), s.stoppedGapMeters, 1.0..10.0, 0.5, m(s.stoppedGapMeters), { s.stoppedGapMeters = it }, on)
        StepperRow(L("settings.fd.reaction"), s.reactionTimeSeconds, 0.5..2.5, 0.1, sec(s.reactionTimeSeconds), { s.reactionTimeSeconds = it }, on)
        RowDivider()
        TextRow(L("settings.fd.surface"), secondary = true)
        ChoiceRows(listOf("auto" to L("settings.fd.surfaceAuto")) + RoadSurfaceCondition.entries.map { it.raw to L("surface.${it.raw}") },
            s.roadSurfaceMode, { s.roadSurfaceMode = it }, enabled = on)
        RowDivider()
        ToggleRow(L("settings.fd.warnings"), s.distanceWarningsEnabled, { s.distanceWarningsEnabled = it }, enabled = on)
        ToggleRow(L("settings.fd.corridor"), s.showEgoCorridor, { s.showEgoCorridor = it }, enabled = on)
        SliderRow(L("settings.fd.horizon"), percent(s.corridorHorizon), s.corridorHorizon, 0.25..0.65, 0.01, { s.corridorHorizon = it }, on)
        ToggleRow(L("settings.fd.horizonAuto"), s.autoHorizonEnabled, { s.autoHorizonEnabled = it }, enabled = on)
        TextRow(L("settings.fd.horizonAuto.hint"), secondary = true)
    }
}

/**
 * Calibrates the bonnet offset while standing behind another car: the user enters the real bumper-to-bumper gap,
 * the app sets `hoodLengthMeters = camera distance − real gap` (port of iOS `HoodCalibrationRow`).
 */
@Composable
private fun HoodCalibrationRow(app: AppState, enabled: Boolean) {
    var realGap by remember { mutableDoubleStateOf(1.5) }
    var resultText by remember { mutableStateOf<String?>(null) }
    val cameraDistance = app.bus.leadCameraDistanceMeters
    StepperRow(L("settings.fd.calib.real"), realGap, 0.5..6.0, 0.1, "${AppFormat.decimal(realGap, 1)} ${AppFormat.meters}", { realGap = it }, enabled)
    ButtonRow(L("settings.fd.calib.button"), Icons.Filled.Straighten, enabled = enabled && cameraDistance != null) {
        val d = cameraDistance ?: return@ButtonRow
        val hood = (d - realGap).coerceIn(0.0, 4.0)
        app.settings.hoodLengthMeters = (hood * 10).roundToInt() / 10.0
        resultText = L("settings.fd.calib.done", AppFormat.decimal(app.settings.hoodLengthMeters, 1))
    }
    TextRow(resultText ?: if (cameraDistance == null) L("settings.fd.calib.noLead") else L("settings.fd.calib.hint"), secondary = true)
}

// Driver assistant

@Composable
private fun DriverAssistSections(app: AppState) {
    val x = ExtraSettings.get(app.context)
    FormSection(header = L("assist.title"), footer = L("assist.footer")) {
        // Master switch for all spoken prompts (same state as the speaker button on the camera screen).
        ToggleRow(L("assist.voicePrompts"), !app.speech.isMuted, { app.speech.isMuted = !it }, icon = Icons.AutoMirrored.Filled.VolumeUp)
        ToggleRow(L("assist.alertSounds"), app.settings.alertSoundsEnabled, { app.settings.alertSoundsEnabled = it }, icon = Icons.Filled.Notifications)
        ToggleRow(L("assist.voice"), x.voiceCoachingEnabled, { x.voiceCoachingEnabled = it }, icon = Icons.Filled.RecordVoiceOver)
        ToggleRow(L("assist.pedestrians"), x.pedestrianWarningsEnabled, { x.pedestrianWarningsEnabled = it }, icon = Icons.AutoMirrored.Filled.DirectionsWalk)
        ToggleRow(L("assist.lights"), x.trafficLightHintsEnabled, { x.trafficLightHintsEnabled = it }, icon = Icons.Filled.Traffic, enabled = x.voiceCoachingEnabled)
        ToggleRow(L("assist.signs"), x.signAnnouncementsEnabled, { x.signAnnouncementsEnabled = it }, icon = Icons.Filled.Warning, enabled = x.voiceCoachingEnabled)
    }
    FormSection(header = L("assist.lanes.title"), footer = L("assist.lanes.footer")) {
        ToggleRow(L("assist.laneWarnings"), x.laneDepartureEnabled, { x.laneDepartureEnabled = it }, icon = Icons.Filled.AddRoad)
        ToggleRow(L("assist.showLanes"), x.showLaneOverlay, { x.showLaneOverlay = it }, icon = Icons.Filled.Timeline)
        ToggleRow(L("assist.showRoadway"), x.showRoadwayBoundary, { x.showRoadwayBoundary = it }, icon = Icons.Filled.AddRoad)
        SliderRow(L("assist.minSpeed"), "${x.laneWarningMinSpeedKmh.toInt()} ${AppFormat.kmh}", x.laneWarningMinSpeedKmh.coerceIn(20.0, 90.0),
            20.0..90.0, 5.0, { x.laneWarningMinSpeedKmh = it }, x.laneDepartureEnabled)
    }
}

// Navigation

@Composable
private fun GeneralNavigationSection(app: AppState) {
    val s = app.settings
    FormSection(header = L("settings.nav.title"), footer = L("settings.nav.footer")) {
        ToggleRow(L("settings.nav.voice"), s.voiceGuidanceEnabled, { s.voiceGuidanceEnabled = it })
        ToggleRow(L("settings.nav.avoidTolls"), s.avoidTolls, { s.avoidTolls = it })
        ToggleRow(L("settings.nav.avoidHighways"), s.avoidHighways, { s.avoidHighways = it })
        ToggleRow(L("settings.nav.pip"), s.showCameraPiP, { s.showCameraPiP = it })
        ToggleRow(L("settings.nav.speedWarning"), s.speedWarningEnabled, { s.speedWarningEnabled = it })
        StepperRow(L("settings.nav.tolerance"), s.speedWarningTolerance, 0.0..30.0, 1.0,
            "+${s.speedWarningTolerance.toInt()} ${AppFormat.kmh}", { s.speedWarningTolerance = it }, s.speedWarningEnabled)
        StepperRow(L("settings.nav.incidentLifetime"), s.incidentLifetimeMinutes, 15.0..720.0, 15.0,
            AppFormat.duration(s.incidentLifetimeMinutes * 60), { s.incidentLifetimeMinutes = it })
    }
}

/** Map layer, routing engine and servers, camera / event sources (port of iOS `NavigationSettingsSection`). */
@Composable
private fun NavigationSettingsSections(app: AppState) {
    val s = app.settings
    val x = ExtraSettings.get(app.context)
    FormSection(header = L("navset.map"), footer = L("navset.map.footer")) {
        TextRow(L("nav.mapLayer"), secondary = true)
        ChoiceRows(listOf("cartoDark" to TL("android.mapStyle.dark"), "osmStandard" to TL("android.mapStyle.osmStandard")),
            if (s.mapStyle == "osmStandard") "osmStandard" else "cartoDark", { s.mapStyle = it })
    }
    FormSection(header = L("navset.routing"), footer = L("navset.routing.footer")) {
        TextRow(L("navset.engine"), secondary = true)
        ChoiceRows(listOf("auto", "valhalla", "osrm").map { it to L("engine.option.$it") }, s.routingEngine, { s.routingEngine = it })
        RowDivider()
        UrlFieldRow(L("navset.valhallaServer"), s.valhallaEndpoint, Valhalla.defaultEndpoint, { s.valhallaEndpoint = it },
            error = if (validatedUrl(s.valhallaEndpoint) == null) L("navset.badURL") else null)
        if (s.valhallaEndpoint != Valhalla.defaultEndpoint) {
            ButtonRow(L("navset.resetValhalla")) { s.valhallaEndpoint = Valhalla.defaultEndpoint }
        }
        RowDivider()
        UrlFieldRow(L("navset.osrmServer"), x.osrmEndpoint, OSRM.defaultEndpoint, { x.osrmEndpoint = it },
            error = if (validatedUrl(x.osrmEndpoint) == null) L("navset.badOSRMURL") else null)
        if (x.osrmEndpoint != OSRM.defaultEndpoint) {
            ButtonRow(L("navset.resetOSRM")) { x.osrmEndpoint = OSRM.defaultEndpoint }
        }
        RowDivider()
        ToggleRow(L("navset.routeAttributes"), s.routeAttributesEnabled, { s.routeAttributesEnabled = it })
    }
    FormSection(header = L("navset.sources"), footer = L("navset.sources.footer")) {
        ToggleRow(L("navset.sources.waze"), s.showWazeButton, { s.showWazeButton = it })
        ToggleRow(L("navset.sources.osmCameras"), s.osmCamerasEnabled, { s.osmCamerasEnabled = it })
        ToggleRow(L("navset.sources.ownMarks"), s.ownMarksEnabled, { s.ownMarksEnabled = it })
    }
}

// Road data

@Composable
private fun RoadDataSection(app: AppState) {
    val s = app.settings
    val custom = "custom"
    var choice by remember { mutableStateOf(if (s.overpassEndpoint in AppSettings.OVERPASS_ENDPOINTS) s.overpassEndpoint else custom) }
    var customText by remember { mutableStateOf(if (choice == custom) s.overpassEndpoint else "") }
    var customError by remember { mutableStateOf<String?>(null) }
    FormSection(header = L("settings.road.title"), footer = L("settings.road.footer")) {
        ToggleRow(L("settings.road.osm"), s.roadDataEnabled, { s.roadDataEnabled = it })
        RowDivider()
        TextRow(L("settings.road.server"), secondary = true)
        val options = AppSettings.OVERPASS_ENDPOINTS.map { it to (Uri.parse(it).host ?: it) } + (custom to L("settings.customServer"))
        ChoiceRows(options, choice, { v ->
            choice = v
            if (v != custom) { s.overpassEndpoint = v; customError = null }
        }, enabled = s.roadDataEnabled)
        if (choice == custom) {
            UrlFieldRow(L("settings.customServer"), customText, "https://example.org/api/interpreter", { text ->
                customText = text
                val trimmed = text.trim()
                if (trimmed.isEmpty()) { customError = null; return@UrlFieldRow }
                val valid = validatedUrl(trimmed)
                if (valid == null) customError = L("settings.road.invalidURL") else { s.overpassEndpoint = valid; customError = null }
            }, error = customError)
        }
    }
}

// Traffic signals

@Composable
private fun SignalSection(app: AppState) {
    val s = app.settings
    val estimate = SignalWaitModel.estimate(SignalTimingAssumptions(s.signalCycleSeconds, s.signalGreenRatio))
    FormSection(header = L("settings.signal.title"), footer = L("settings.signal.footer")) {
        StepperRow(L("settings.signal.cycle"), s.signalCycleSeconds, 40.0..180.0, 5.0,
            "${s.signalCycleSeconds.toInt()} ${AppFormat.seconds}", { s.signalCycleSeconds = it })
        SliderRow(L("settings.signal.green"), percent(s.signalGreenRatio), s.signalGreenRatio, 0.2..0.8, 0.05, { s.signalGreenRatio = it })
        RowDivider()
        ValueRow(L("settings.signal.modelWait"), "")
        TextRow(L("settings.signal.modelWaitValue", AppFormat.duration(estimate.expectedWaitSeconds), percent(estimate.stopProbability)), secondary = true)
        RowDivider()
        ToggleRow(L("settings.signal.learn"), s.learnSignalTimings, { s.learnSignalTimings = it })
    }
}

// About

@Composable
private fun AboutSections(nav: SheetNav) {
    val context = LocalContext.current
    FormSection(header = L("about.title")) {
        NavRow(L("settings.about.link"), Icons.Filled.Info) { nav.push(SheetRoute.AboutHub) }
        RowDivider()
        ValueRow(L("common.version"), AppVersion.text(context))
    }
    FormSection(header = L("about.sources")) {
        SourceRow(L("sources.osm.title"), L("sources.osm.detail"))
        LinkRow("openstreetmap.org/copyright", "https://www.openstreetmap.org/copyright")
        LinkRow(L("sources.osm.fix"), "https://www.openstreetmap.org/fixthemap")
        RowDivider()
        SourceRow(L("sources.weather.title"), L("sources.weather.detail"))
        LinkRow("open-meteo.com", "https://open-meteo.com/")
        RowDivider()
        SourceRow(L("sources.yolo.title"), L("sources.yolo.detail") + " " + L("settings.sources.makeLicense"))
    }
    FormSection(header = L("sources.safety.header")) {
        TextRow(L("sources.safety.body"))
    }
}

@Composable
fun SourceRow(title: String, detail: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, color = androidx.compose.ui.graphics.Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(detail, color = SecondaryText, fontSize = 13.sp)
    }
}

@Composable
fun LinkRow(title: String, url: String) {
    val context = LocalContext.current
    ButtonRow(title) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
        }
    }
}
