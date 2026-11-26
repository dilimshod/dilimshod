package uz.roadvis.app.camera

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import uz.roadvis.app.app.AppState
import uz.roadvis.app.detection.ModelStatus
import uz.roadvis.app.detection.YoloDetector
import uz.roadvis.core.CameraEventInput
import uz.roadvis.core.CameraDrivingEventMonitor
import uz.roadvis.core.CameraGeometry
import uz.roadvis.core.CoachFrameInput
import uz.roadvis.core.EgoCorridor
import uz.roadvis.core.FollowingDistanceAssessment
import uz.roadvis.core.FollowingDistanceCalculator
import uz.roadvis.core.FollowingDistancePolicy
import uz.roadvis.core.LaneDepartureDetector
import uz.roadvis.core.LaneEstimate
import uz.roadvis.core.LaneSide
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.ObservedTrafficLight
import uz.roadvis.core.PedestrianHazard
import uz.roadvis.core.RoadStaffSighting
import uz.roadvis.core.RoadSurfaceCondition
import uz.roadvis.core.RoadwayZone
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.VehicleKind
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Camera + recognition as seen by the UI (port of iOS `RecognitionPipeline`). Only holds Compose state and the
 * main-thread logic; frames are processed by [RecognitionWorker] on its own thread (≤ 15 fps) and every processed
 * frame publishes one snapshot back to the main thread.
 *
 * Following distance: the worker picks the lead vehicle; here it becomes a [FollowingDistanceAssessment] (own GPS speed,
 * road surface from the manual setting — "auto" assumes dry because no weather feed reaches the camera feature) and
 * drives the haptic / tone warnings ([DistanceWarningController]) while the [DriverCoach] speaks. Camera driving events
 * go to `bus.emitEvent`; the lead distances to `bus.leadCameraDistanceMeters` / `bus.leadGapMeters` every frame.
 */
class RecognitionController(val app: AppState) {
    val assist = AssistSettings(app.context)
    val worker = RecognitionWorker(app.context)
    private val settings = app.settings
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // Published state
    var tracks by mutableStateOf<List<TrackedObject>>(emptyList()); private set
    var visibleCounts by mutableStateOf<Map<VehicleKind, Int>>(emptyMap()); private set
    var uniqueCounts by mutableStateOf<Map<VehicleKind, Int>>(emptyMap()); private set
    var fps by mutableStateOf(0.0); private set
    var inferenceMs by mutableStateOf(0.0); private set
    var detectorStatus by mutableStateOf<ModelStatus>(ModelStatus.Loading); private set
    var makeClassifierStatus by mutableStateOf<ModelStatus>(ModelStatus.Loading); private set
    var currentLightColor by mutableStateOf<TrafficLightColor?>(null); private set
    /** True while the camera is bound and delivering frames. */
    var isRunning by mutableStateOf(false)
    var cameraPermissionDenied by mutableStateOf(false)
    var cameraError by mutableStateOf<String?>(null)
    var frameWidth by mutableStateOf(720); private set
    var frameHeight by mutableStateOf(1280); private set
    var processedFrames by mutableStateOf(0); private set
    var horizontalFov by mutableStateOf(65.0)

    var leadVehicle by mutableStateOf<LeadVehicle?>(null); private set
    var followingAssessment by mutableStateOf<FollowingDistanceAssessment?>(null); private set
    var roadSurface by mutableStateOf(RoadSurfaceCondition.DRY); private set
    var roadSurfaceSource by mutableStateOf(RoadSurfaceSource.NO_WEATHER); private set
    var isForwardCollisionWarning by mutableStateOf(false); private set

    var laneEstimate by mutableStateOf<LaneEstimate?>(null); private set
    var laneDepartureSide by mutableStateOf<LaneSide?>(null); private set
    var pedestrianHazards by mutableStateOf<List<PedestrianHazard>>(emptyList()); private set
    var roadStaff by mutableStateOf<List<RoadStaffSighting>>(emptyList()); private set
    var roadwayZone by mutableStateOf<RoadwayZone?>(null); private set
    var corridorCenterX by mutableStateOf(0.5); private set

    val topPedestrianHazard: PedestrianHazard? get() = pedestrianHazards.firstOrNull()
    val topRoadStaff: RoadStaffSighting? get() = roadStaff.firstOrNull()
    val egoCorridor: EgoCorridor get() = EgoCorridor(centerX = corridorCenterX, horizonY = min(0.8, max(0.1, settings.corridorHorizon)))
    val totalUniqueVehicles: Int get() = uniqueCounts.entries.sumOf { if (it.key.isVehicle) it.value else 0 }
    val totalVisibleVehicles: Int get() = visibleCounts.entries.sumOf { if (it.key.isVehicle) it.value else 0 }

    /** The following-distance policy currently in effect (from the settings). */
    val followingDistancePolicy: FollowingDistancePolicy
        get() = FollowingDistancePolicy(
            timeGapDry = settings.followingTimeGapDry,
            timeGapWet = settings.followingTimeGapDry * 2,
            timeGapSnow = settings.followingTimeGapDry * 3,
            timeGapIce = settings.followingTimeGapDry * 5,
            stoppedGapMeters = settings.stoppedGapMeters,
            reactionTimeSeconds = settings.reactionTimeSeconds,
        )

    // Main-thread logic
    private val warnings = DistanceWarningController()
    val coach = DriverCoach(app, assist)
    private val laneDeparture = LaneDepartureDetector()
    private val eventMonitor = CameraDrivingEventMonitor()
    private var wantsProcessing = false
    private var generation = 0
    private var lastLaneTimestamp: Double? = null
    private var lastLaneDepartureUptime = Double.NEGATIVE_INFINITY
    private var lastFrameRefreshUptime = Double.NEGATIVE_INFINITY
    private val recentTracks = HashMap<Int, Pair<TrackedObject, Double>>()
    private var lastLeadUptime = Double.NEGATIVE_INFINITY
    private var lastPedestrianUptime = Double.NEGATIVE_INFINITY
    private var lastRoadStaffUptime = Double.NEGATIVE_INFINITY

    /** Haptic output (set by the camera view, which owns a View to perform it on). */
    var haptic: ((AssistHaptic) -> Unit)? = null
        set(value) {
            field = value
            warnings.haptic = value
            coach.haptic = value
        }

    init {
        // The coach speaks the distance warnings (no duplicate speech); the controller gives haptics and the tone.
        warnings.speech = null
        warnings.tones = { kind -> app.speech.playAlertTone(kind) }
        worker.outputHandler = { output -> main.post { apply(output) } }
        worker.statusHandler = { statuses -> main.post { applyModelStatuses(statuses) } }
        pushSettings()
        pushLocation()
        app.location.addListener {
            pushLocation()
            // Keeps the recommended gap current without camera frames.
            if (RecognitionWorker.uptimeSeconds() - lastFrameRefreshUptime > 0.5) refreshFollowingDistance(fromFrame = false)
        }
        scope.launch {
            snapshotFlow {
                listOf(settings.detectionConfidence, settings.nmsIoUThreshold, settings.trackPedestrians,
                    settings.detectTrafficLights, settings.makeRecognitionEnabled, settings.followingDistanceEnabled,
                    settings.corridorHorizon, settings.hoodLengthMeters, settings.followingTimeGapDry,
                    settings.stoppedGapMeters, settings.reactionTimeSeconds, settings.roadSurfaceMode,
                    assist.laneDepartureEnabled, assist.showLaneOverlay, assist.pedestrianWarningsEnabled)
            }.drop(1).collect {
                pushSettings()
                refreshFollowingDistance(fromFrame = false)
            }
        }
        app.bus.onDriveStarted += { coach.resetAnnouncements() }
        refreshFollowingDistance(fromFrame = false)
        worker.loadModels()
    }

    // Start / pause

    /** Processing on (camera screen visible) or paused (navigator shown: the camera stays bound, no inference). */
    fun setProcessing(processing: Boolean) {
        if (processing == wantsProcessing) return
        wantsProcessing = processing
        pushSettings()
        pushLocation()
        worker.setActive(processing)
        if (!processing) {
            generation += 1
            worker.setGeneration(generation)
            clearVisibleState()
        }
    }

    /** The camera stopped (lifecycle, unbind, error): clears the visible objects. */
    fun cameraStopped() {
        isRunning = false
        generation += 1
        worker.setGeneration(generation)
        clearVisibleState()
    }

    /** Resets the unique counters, the tracks and the estimator history. */
    fun resetCounters() {
        generation += 1
        worker.reset(generation)
        uniqueCounts = emptyMap()
        clearVisibleState()
    }

    // Updates from the worker (main thread)

    private fun apply(output: RecognitionWorker.Output) {
        if (output.generation != generation || !wantsProcessing) return
        val now = RecognitionWorker.uptimeSeconds()
        val displayed = displayTracks(output.tracks, now)
        if (tracks != displayed) tracks = displayed
        if (visibleCounts != output.visibleCounts) visibleCounts = output.visibleCounts
        if (uniqueCounts != output.uniqueCounts) uniqueCounts = output.uniqueCounts
        if (abs(fps - output.fps) >= 0.5) fps = output.fps
        if (abs(inferenceMs - output.inferenceMs) >= 1) inferenceMs = output.inferenceMs
        if (frameWidth != output.frameWidth) frameWidth = output.frameWidth
        if (frameHeight != output.frameHeight) frameHeight = output.frameHeight
        if (abs(corridorCenterX - output.corridor.centerX) >= 0.003) corridorCenterX = output.corridor.centerX
        if (currentLightColor != output.lightColor) currentLightColor = output.lightColor
        processedFrames = output.processedFrames
        isRunning = true

        var lead = if (settings.followingDistanceEnabled) output.leadVehicle else null
        if (lead != null) {
            lastLeadUptime = now
        } else if (settings.followingDistanceEnabled && leadVehicle != null && now - lastLeadUptime < LEAD_HOLD) {
            lead = leadVehicle   // bridge a few frames without the lead instead of blinking the line / HUD
        }
        if (leadVehicle != lead) leadVehicle = lead
        // Raw camera distance (bonnet calibration) and bumper gap, every frame (null without a lead).
        app.bus.leadCameraDistanceMeters = lead?.cameraDistanceMeters
        app.bus.leadGapMeters = lead?.distanceMeters

        val pedOn = assist.pedestrianWarningsEnabled
        var hazards = if (pedOn) output.pedestrianHazards else emptyList()
        if (hazards.isNotEmpty()) lastPedestrianUptime = now
        else if (pedOn && now - lastPedestrianUptime < PEDESTRIAN_HOLD) hazards = pedestrianHazards
        if (pedestrianHazards != hazards) pedestrianHazards = hazards
        var staff = if (pedOn) output.roadStaff else emptyList()
        if (staff.isNotEmpty()) lastRoadStaffUptime = now
        else if (pedOn && now - lastRoadStaffUptime < PEDESTRIAN_HOLD) staff = roadStaff
        if (roadStaff != staff) roadStaff = staff
        if (roadwayZone != output.roadwayZone) roadwayZone = output.roadwayZone
        refreshFollowingDistance(fromFrame = true)
        updateDriverAssist(output, now)
    }

    /** Lane departure, coaching cues and camera-based driving events for one processed frame. */
    private fun updateDriverAssist(output: RecognitionWorker.Output, now: Double) {
        val speed = app.location.speedKmh
        val estimate = if (assist.laneDetectionNeeded) output.laneEstimate else null
        if (laneEstimate != estimate) laneEstimate = estimate

        var departure: LaneSide? = null
        if (assist.laneDepartureEnabled && estimate != null) {
            if (estimate.timestamp != lastLaneTimestamp) {
                lastLaneTimestamp = estimate.timestamp
                if (laneDeparture.config.minSpeedKmh != assist.laneWarningMinSpeedKmh) {
                    laneDeparture.config = laneDeparture.config.copy(minSpeedKmh = assist.laneWarningMinSpeedKmh)
                }
                departure = laneDeparture.update(estimate, speed, now)
                if (departure != null) lastLaneDepartureUptime = now
            }
        } else {
            laneDeparture.reset()
            lastLaneTimestamp = null
        }
        // Keep the red line visible a moment after the warning even if the estimate jitters back.
        val side = laneDeparture.activeSide ?: (if (now - lastLaneDepartureUptime < 1.5) laneDepartureSide else null)
        if (laneDepartureSide != side) laneDepartureSide = side

        val assessment = if (settings.followingDistanceEnabled) followingAssessment else null
        val fresh = output.tracks.filter { it.missed == 0 }

        val coachInput = CoachFrameInput(timestamp = now, speedKmh = speed, assessment = assessment,
            hasLead = leadVehicle != null, collisionWarning = isForwardCollisionWarning, laneDeparture = departure,
            light = ObservedTrafficLight.largest(fresh))
        val stopIDs = fresh.filter { it.kind == VehicleKind.STOP_SIGN && it.isConfirmed }.map { it.id }
        coach.handle(DriverAssistFrame(coachInput, stopIDs, pedestrianHazards, roadStaff))

        val geometry = CameraGeometry(horizontalFov, frameWidth.toDouble(), frameHeight.toDouble())
        val input = CameraEventInput(
            timestamp = now, dateMillis = System.currentTimeMillis(), speedKmh = speed,
            coordinate = app.location.coordinate, assessment = assessment, hasLead = leadVehicle != null,
            collisionWarning = isForwardCollisionWarning,
            collisionThresholdSeconds = followingDistancePolicy.collisionWarningSeconds,
            laneDeparture = departure, laneOffset = estimate?.egoOffset, tracks = fresh, geometry = geometry,
            pedestrianHazards = if (assist.pedestrianWarningsEnabled) output.pedestrianHazards else emptyList(),
            roadStaff = if (assist.pedestrianWarningsEnabled) output.roadStaff else emptyList(),
        )
        for (event in eventMonitor.update(input)) app.bus.emitEvent(event)
    }

    /** Current tracks plus confirmed tracks missed for at most [TRACK_HOLD] seconds (marked `missed ≥ 1`). */
    private fun displayTracks(fresh: List<TrackedObject>, now: Double): List<TrackedObject> {
        val result = fresh.toMutableList()
        val freshIDs = HashSet<Int>()
        for (t in fresh) {
            freshIDs.add(t.id)
            recentTracks[t.id] = t to now
        }
        val it = recentTracks.entries.iterator()
        while (it.hasNext()) {
            val (id, entry) = it.next()
            if (id in freshIDs) continue
            if (entry.first.isConfirmed && now - entry.second <= TRACK_HOLD) {
                result.add(entry.first.copy(missed = max(1, entry.first.missed)))
            } else {
                it.remove()
            }
        }
        return result
    }

    private fun applyModelStatuses(s: RecognitionWorker.ModelStatuses) {
        if (detectorStatus != s.detector) detectorStatus = s.detector
        if (makeClassifierStatus != s.makeClassifier) makeClassifierStatus = s.makeClassifier
    }

    private fun clearVisibleState() {
        recentTracks.clear()
        lastLeadUptime = Double.NEGATIVE_INFINITY
        lastPedestrianUptime = Double.NEGATIVE_INFINITY
        lastRoadStaffUptime = Double.NEGATIVE_INFINITY
        if (tracks.isNotEmpty()) tracks = emptyList()
        if (visibleCounts.isNotEmpty()) visibleCounts = emptyMap()
        if (fps != 0.0) fps = 0.0
        currentLightColor = null
        leadVehicle = null
        app.bus.leadCameraDistanceMeters = null
        app.bus.leadGapMeters = null
        corridorCenterX = 0.5
        laneEstimate = null
        laneDepartureSide = null
        if (pedestrianHazards.isNotEmpty()) pedestrianHazards = emptyList()
        if (roadStaff.isNotEmpty()) roadStaff = emptyList()
        roadwayZone = null
        laneDeparture.reset()
        lastLaneTimestamp = null
        eventMonitor.reset()
        warnings.reset()
        refreshFollowingDistance(fromFrame = false)
    }

    // Following distance

    /** Recomputes the assessment (and, for camera frames, feeds the warning controller). */
    private fun refreshFollowingDistance(fromFrame: Boolean) {
        if (!settings.followingDistanceEnabled) {
            leadVehicle = null
            followingAssessment = null
            isForwardCollisionWarning = false
            warnings.reset()
            return
        }
        val (condition, source) = resolveRoadSurface()
        if (roadSurface != condition) roadSurface = condition
        if (roadSurfaceSource != source) roadSurfaceSource = source

        val policy = followingDistancePolicy
        val lead = leadVehicle
        val assessment = FollowingDistanceCalculator.assess(lead?.distanceMeters, app.location.speedKmh,
            lead?.relativeSpeedKmh, policy, condition)
        if (followingAssessment != assessment) followingAssessment = assessment
        val collision = lead != null && DistanceWarningController.isForwardCollision(assessment, policy)
        if (isForwardCollisionWarning != collision) isForwardCollisionWarning = collision
        if (fromFrame) {
            lastFrameRefreshUptime = RecognitionWorker.uptimeSeconds()
            warnings.evaluate(assessment, lead?.trackID, policy, settings.distanceWarningsEnabled)
        }
    }

    /** Manual surface from the settings; "auto" → dry (no weather reaches the camera feature on Android yet). */
    private fun resolveRoadSurface(): Pair<RoadSurfaceCondition, RoadSurfaceSource> {
        val mode = settings.roadSurfaceMode
        if (mode != "auto") RoadSurfaceCondition.fromRaw(mode)?.let { return it to RoadSurfaceSource.MANUAL }
        return RoadSurfaceCondition.DRY to RoadSurfaceSource.NO_WEATHER
    }

    // Inputs to the worker

    private fun pushLocation() {
        worker.inputs = worker.inputs.copy(ownSpeedKmh = app.location.speedKmh)
    }

    private fun pushSettings() {
        val options = YoloDetector.Options(
            confidenceThreshold = settings.detectionConfidence,
            iouThreshold = settings.nmsIoUThreshold,
            trackPedestrians = settings.trackPedestrians,
            detectTrafficLights = settings.detectTrafficLights,
        )
        worker.inputs = worker.inputs.copy(
            laneDetectionEnabled = assist.laneDetectionNeeded,
            pedestrianWarningsEnabled = assist.pedestrianWarningsEnabled,
            detection = options,
            makeRecognitionEnabled = settings.makeRecognitionEnabled,
            followingDistanceEnabled = settings.followingDistanceEnabled,
            corridorHorizon = settings.corridorHorizon,
            cameraToBumperMeters = settings.hoodLengthMeters,
        )
    }

    companion object {
        /** How long a confirmed track missed by the detector stays on screen, seconds. */
        const val TRACK_HOLD = 0.3
        /** How long the lead vehicle survives frames without it, seconds. */
        const val LEAD_HOLD = 0.5
        /** Pedestrian hazards are kept this long after they vanish from a frame. */
        const val PEDESTRIAN_HOLD = 0.6
    }
}
