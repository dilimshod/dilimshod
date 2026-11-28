package uz.roadvis.app.camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.camera.view.PreviewView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.delay
import uz.roadvis.app.app.AppState
import uz.roadvis.app.app.SpeechPriority
import uz.roadvis.core.AlertToneKind
import uz.roadvis.core.CoachMessage
import uz.roadvis.core.VoicePhrase
import kotlin.math.roundToInt

/**
 * Full-screen camera with live recognition (port of iOS `RecognitionView`). Minimal dashcam HUD, portrait and
 * landscape: top-left speedometer + road line, the navigation mini banner and the following-distance pill; top-right
 * settings, voice mute, status dot, traffic-light indicator and the counters button; pedestrian / officer / road-works
 * banner under the top row; map button bottom-right. No recording control (trip recording runs in the background).
 *
 * Stays mounted behind the navigator: while [isActive] is false the camera stays bound but inference is paused
 * (`setProcessing(false)`) and no per-frame layer or HUD is composed.
 */
@Composable
fun CameraScreen(app: AppState, isActive: Boolean) {
    val c = remember { CameraFeature.controller(app) }
    val context = LocalContext.current
    val view = LocalView.current
    @Suppress("DEPRECATION")
    val lifecycleOwner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    val configuration = LocalConfiguration.current
    val landscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

    var granted by remember { mutableStateOf(hasCameraPermission(context)) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) granted = hasCameraPermission(context)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(granted) { c.cameraPermissionDenied = !granted }
    // The cabinet's QR scanner borrows the back camera: no inference while it is open (the camera is unbound below).
    val scannerOpen = CameraOwnership.scannerOpen
    LaunchedEffect(isActive, granted, scannerOpen) { c.setProcessing(isActive && granted && !scannerOpen) }

    DisposableEffect(view) {
        c.haptic = { kind ->
            val constant = when (kind) {
                AssistHaptic.ERROR -> if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
                AssistHaptic.WARNING -> HapticFeedbackConstants.LONG_PRESS
                AssistHaptic.LIGHT -> HapticFeedbackConstants.KEYBOARD_TAP
                AssistHaptic.SOFT -> HapticFeedbackConstants.CONTEXT_CLICK
            }
            view.performHapticFeedback(constant)
        }
        onDispose { c.haptic = null }
    }

    var selectedTrackID by remember { mutableStateOf<Int?>(null) }
    var showStatus by rememberSaveable { mutableStateOf(false) }
    var showNorms by rememberSaveable { mutableStateOf(false) }
    var hideModelBanner by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(isActive) { if (!isActive) selectedTrackID = null }

    // Over-limit reminder (app language), at most once per 30 s, only while the camera screen is shown.
    LaunchedEffect(isActive) {
        if (!isActive) return@LaunchedEffect
        var last = Double.NEGATIVE_INFINITY
        snapshotFlow { app.location.speedKmh }.collect { speed ->
            val s = app.settings
            val limit = app.bus.speedLimitKmh ?: return@collect
            if (!s.speedWarningEnabled || !isOverLimit(speed, limit, s.speedWarningTolerance)) return@collect
            val now = RecognitionWorker.uptimeSeconds()
            if (now - last < 30) return@collect
            last = now
            val m = CoachMessage.OverSpeedLimit(limit)
            // In the "sounds only" mode the tone is the whole reminder (`playAlertTone` checks the mode).
            app.speech.playAlertTone(AlertToneKind.SPEEDING)
            app.speech.speak(VoicePhrase.coach(m, CoachPhrases.phrase(m)), SpeechPriority.LOW)
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (c.cameraPermissionDenied) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CameraPermissionCard {
                    try {
                        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (_: Exception) {}
                }
            }
        } else {
            CameraPreview(c, granted && !scannerOpen, app.settings.videoStabilization != "off")
            if (isActive) {
                val expanded = c.assist.distanceHUDExpanded
                val insets = if (landscape) LabelInsets(70f, if (expanded) 270f else 200f, 70f, 80f)
                else LabelInsets((if (expanded) 330f else 150f) + (if (c.assist.countersExpanded) 50f else 0f), 16f, 90f, 16f)
                LiveDetectionLayer(c, app.settings, selectedTrackID, { selectedTrackID = it }, insets)
            }
        }
        if (isActive) {
            CameraHud(app, c, landscape, hideModelBanner, { hideModelBanner = true }, { showStatus = true }, { showNorms = true })
            if (!c.cameraPermissionDenied) TrackDetailLayer(c, selectedTrackID) { selectedTrackID = it }
            CollisionWarningGlow(c.isForwardCollisionWarning && app.settings.distanceWarningsEnabled)
        }
    }
    if (showStatus) RecognitionStatusSheet(app, c) { showStatus = false }
    if (showNorms) DistanceNormsSheet(c) { showNorms = false }
}

private fun hasCameraPermission(context: android.content.Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

/**
 * The CameraX preview (TextureView, so the root crossfade alpha applies) bound while [granted] (camera permission and
 * no QR scanner open, see [CameraOwnership]).
 */
@Composable
private fun CameraPreview(c: RecognitionController, granted: Boolean, stabilization: Boolean) {
    val context = LocalContext.current
    @Suppress("DEPRECATION")
    val owner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    val configuration = LocalConfiguration.current
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    // A new binding (and a re-bind) when the stabilization setting changes: CameraX fixes it when the Preview is built.
    val binding = remember(stabilization) { CameraBinding(context.applicationContext, c, stabilization) }
    AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
    DisposableEffect(owner, granted, binding) {
        if (granted) {
            binding.bind(owner, previewView, previewView.display?.rotation ?: 0)
            CameraOwnership.recognitionBound = true
        }
        onDispose {
            if (granted) {
                binding.unbind()
                CameraOwnership.recognitionBound = false
            }
        }
    }
    LaunchedEffect(configuration.orientation, configuration.screenWidthDp) {
        // The activity handles rotation itself: follow the display rotation once the view has been laid out.
        delay(50)
        binding.setRotation(previewView.display?.rotation ?: 0)
    }
}

@Composable
private fun CameraHud(
    app: AppState, c: RecognitionController, landscape: Boolean, hideModelBanner: Boolean, onHideModelBanner: () -> Unit,
    onShowStatus: () -> Unit, onShowNorms: () -> Unit,
) {
    val settings = app.settings
    Column(
        Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(start = CamTheme.gutter, end = CamTheme.gutter, top = 4.dp, bottom = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SpeedometerView(app.location.speedKmh, app.bus.speedLimitKmh, settings.speedWarningTolerance, settings.speedWarningEnabled)
                    RoadLine(app.bus.currentRoad)
                }
                NavigationMiniBanner(app)
                val assessment = c.followingAssessment
                if (settings.followingDistanceEnabled && !c.cameraPermissionDenied && assessment != null) {
                    FollowingDistanceHud(
                        assessment, c.leadVehicle, c.followingDistancePolicy, c.roadSurfaceSource,
                        c.isForwardCollisionWarning && settings.distanceWarningsEnabled, mini = landscape,
                        expanded = c.assist.distanceHUDExpanded,
                        onToggle = { c.assist.distanceHUDExpanded = !c.assist.distanceHUDExpanded },
                        onShowNorms = onShowNorms,
                    )
                }
            }
            Spacer(Modifier.size(8.dp))
            Column(horizontalAlignment = Alignment.End) {
                SettingsButton(app)
                VoiceMuteButton(app)
                StatusDotButton(c, onShowStatus)
                PopVisibility(c.currentLightColor != null, 0.8f) {
                    Box(Modifier.size(width = CamTheme.hit, height = 88.dp).padding(vertical = 2.dp), contentAlignment = Alignment.Center) {
                        c.currentLightColor?.let { TrafficLightIndicator(it, 18.dp, 0.45f) }
                    }
                }
                CountersButton(c.totalUniqueVehicles, c.assist.countersExpanded) { c.assist.countersExpanded = !c.assist.countersExpanded }
            }
        }
        // Pedestrian hazard, else officer / road workers.
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Box(Modifier.widthIn(max = 360.dp)) {
                val hazard = c.topPedestrianHazard
                val staff = if (hazard == null) c.topRoadStaff else null
                PopVisibility(hazard != null, 0.85f) { (hazard ?: c.topPedestrianHazard)?.let { PedestrianHazardBanner(it) } }
                PopVisibility(staff != null, 0.85f) { staff?.let { RoadStaffBanner(it) } }
            }
        }
        if (c.assist.countersExpanded) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { CountersPanel(c, settings.trackPedestrians) }
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { BannerStack(c, hideModelBanner, onHideModelBanner) }
        Spacer(Modifier.weight(1f))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            NavigatorCornerButton { app.toggleMode() }
        }
    }
}

/**
 * Detail card of the tapped box, next to it. It stays while the track flickers, closes 1.5 s after the object left
 * the frame, or after 12 s.
 */
@Composable
private fun TrackDetailLayer(c: RecognitionController, selectedTrackID: Int?, onSelect: (Int?) -> Unit) {
    val current = selectedTrackID?.let { id -> c.tracks.firstOrNull { it.id == id } }
    var cached by remember { mutableStateOf<uz.roadvis.core.TrackedObject?>(null) }
    if (current != null) cached = current
    val shown = current ?: cached?.takeIf { it.id == selectedTrackID }
    LaunchedEffect(selectedTrackID) {
        val id = selectedTrackID ?: return@LaunchedEffect
        delay(12_000)
        if (selectedTrackID == id) onSelect(null)
    }
    LaunchedEffect(current == null && selectedTrackID != null) {
        val id = selectedTrackID ?: return@LaunchedEffect
        if (current != null) return@LaunchedEffect
        delay(1500)
        if (c.tracks.none { it.id == id }) onSelect(null)
    }
    shown ?: return
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val w = constraints.maxWidth.toFloat(); val h = constraints.maxHeight.toFloat()
        val mapping = AspectFillMapping.of(c.frameWidth.toFloat(), c.frameHeight.toFloat(), w, h)
        val rect = mapping.rect(shown.box)
        val lead = c.leadVehicle?.takeIf { it.trackID == shown.id }
        val d = density.density
        val cw = TRACK_CARD_WIDTH * d; val ch = TRACK_CARD_HEIGHT * d; val gutter = 16 * d
        val minX = gutter + cw / 2; val maxX = w - gutter - cw / 2
        val x = if (minX <= maxX) rect.centerX.coerceIn(minX, maxX) else w / 2
        val below = rect.centerY < h * 0.5f
        val preferredY = if (below) rect.bottom + 14 * d + ch / 2 else rect.top - 14 * d - ch / 2
        val minY = 56 * d + ch / 2; val maxY = h - 72 * d - ch / 2
        val y = if (minY <= maxY) preferredY.coerceIn(minY, maxY) else h / 2
        TrackDetailCard(shown, lead, if (lead == null) null else c.followingAssessment, { onSelect(null) },
            Modifier.layout { m, cons ->
                val p = m.measure(cons.copy(minWidth = 0, minHeight = 0))
                layout(p.width, p.height) { p.place((x - p.width / 2).roundToInt(), (y - p.height / 2).roundToInt()) }
            })
    }
}

/** Fade + scale in / out (scope-free, usable inside Column / Row content). */
@Composable
private fun PopVisibility(visible: Boolean, scale: Float, content: @Composable () -> Unit) {
    AnimatedVisibility(visible, enter = fadeIn() + scaleIn(initialScale = scale), exit = fadeOut() + scaleOut(targetScale = scale)) { content() }
}
