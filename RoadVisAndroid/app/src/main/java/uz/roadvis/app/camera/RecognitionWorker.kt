package uz.roadvis.app.camera

import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import uz.roadvis.app.detection.MakeClassifier
import uz.roadvis.app.detection.ModelStatus
import uz.roadvis.app.detection.YoloDetector
import uz.roadvis.app.learning.LearningCollector
import uz.roadvis.app.learning.LearningFeature
import uz.roadvis.core.CameraGeometry
import uz.roadvis.core.Detection
import uz.roadvis.core.DetectionThresholds
import uz.roadvis.core.DetectorQualityGovernor
import uz.roadvis.core.EgoCorridor
import uz.roadvis.core.LaneDetector
import uz.roadvis.core.LaneEstimate
import uz.roadvis.core.LaneHorizonEstimator
import uz.roadvis.core.LaneImage
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.LeadVehicleTracker
import uz.roadvis.core.MonocularSpeedEstimator
import uz.roadvis.core.ObjectTracker
import uz.roadvis.core.ObservedTrafficLight
import uz.roadvis.core.PedestrianHazard
import uz.roadvis.core.PedestrianHazardDetector
import uz.roadvis.core.PersonRoleClassifier
import uz.roadvis.core.PersonSceneResult
import uz.roadvis.core.RoadStaffSighting
import uz.roadvis.core.RoadwayZone
import uz.roadvis.core.RoadwayZoneEstimator
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.TrafficLightColor
import uz.roadvis.core.TrafficLightColorClassifier
import uz.roadvis.core.TrafficLightSelection
import uz.roadvis.core.VehicleKind
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Frame-processing engine (port of iOS `RecognitionWorker`): ONNX inference, tracking, distance / speed estimation,
 * lane detection, lead-vehicle selection, pedestrians vs roadway, traffic-light colour and person-role sampling.
 *
 * Threading: everything heavy runs on the single [executor] thread, which is also the CameraX analyzer executor —
 * so the detector, tracker and estimators are confined to it. Frames come in through [analyze] (CameraX calls it on
 * [executor] with KEEP_ONLY_LATEST, so a frame is processed only after the previous one is closed); frames arriving
 * faster than [MAX_FPS] or while inactive are closed at once. Inputs from the main thread ([inputs], [active],
 * [fovDegrees]) are volatile snapshots. Results go to [outputHandler] (on [executor]; the controller posts to main).
 */
class RecognitionWorker(context: Context) : ImageAnalysis.Analyzer {
    /** Values pushed from the main thread before / while processing. */
    data class Inputs(
        val ownSpeedKmh: Double? = null,
        val detection: YoloDetector.Options = YoloDetector.Options(),
        val makeRecognitionEnabled: Boolean = true,
        val followingDistanceEnabled: Boolean = true,
        val corridorHorizon: Double = EgoCorridor.default.horizonY,
        /**
         * Measure the horizon from the lane vanishing point ([LaneHorizonEstimator]); [corridorHorizon] is then only
         * the start value (`settings.autoHorizonEnabled`).
         */
        val autoHorizonEnabled: Boolean = true,
        /** Last measured horizons of earlier sessions (null = none), used until this session has its own estimate. */
        val storedHorizonPortrait: Double? = null,
        val storedHorizonLandscape: Double? = null,
        val cameraToBumperMeters: Double = 2.2,
        val laneDetectionEnabled: Boolean = true,
        val pedestrianWarningsEnabled: Boolean = true,
        /**
         * Continuous-learning collection (`docs/TRAINING_API.md`); null = off. The controller leaves it null while
         * pedestrians are not detected, because the head blurring needs the person boxes.
         */
        val learning: LearningCollector.Options? = null,
    )

    /** Snapshot published after every processed frame. */
    data class Output(
        val generation: Int,
        val tracks: List<TrackedObject>,
        val visibleCounts: Map<VehicleKind, Int>,
        val uniqueCounts: Map<VehicleKind, Int>,
        val fps: Double,
        val inferenceMs: Double,
        /**
         * Stable colour of the traffic light that applies to the own lane ([TrafficLightSelection.ownLane]: confirmed,
         * ≥ 5 hits, known colour from the tracker's time-window vote, ahead of the corridor); null when none.
         */
        val lightColor: TrafficLightColor?,
        /** The light [lightColor] comes from (track ID, colour, box) — the one the coach looks at. */
        val observedLight: ObservedTrafficLight?,
        val frameWidth: Int,
        val frameHeight: Int,
        val processedFrames: Int,
        val leadVehicle: LeadVehicle?,
        val laneEstimate: LaneEstimate?,
        val pedestrianHazards: List<PedestrianHazard>,
        val roadStaff: List<RoadStaffSighting>,
        val roadwayZone: RoadwayZone?,
        val corridor: EgoCorridor,
        /** Horizon row in use on this frame (manual setting, or the measured one while auto horizon is on). */
        val horizonY: Double,
        /**
         * Horizon measured in this session from the lane vanishing point (null until the estimator converged or while
         * auto horizon is off), with the frame orientation it belongs to.
         */
        val measuredHorizon: Double?,
        val measuredHorizonIsLandscape: Boolean,
    )

    data class ModelStatuses(val detector: ModelStatus, val makeClassifier: ModelStatus)

    val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "recognition.processing").apply { priority = Thread.NORM_PRIORITY + 1 }
    }

    // Thread-safe inputs (written on main, read on the executor)
    @Volatile var inputs = Inputs()
    @Volatile var fovDegrees: Double = 65.0
    @Volatile var outputHandler: ((Output) -> Unit)? = null
    @Volatile var statusHandler: ((ModelStatuses) -> Unit)? = null
    @Volatile private var active = false
    @Volatile private var detectorReady = false

    private val appContext: Context = context.applicationContext

    // Executor-confined
    private val detector = YoloDetector(context.applicationContext)
    private val makeClassifier = MakeClassifier(context.applicationContext)
    /**
     * Persons are counted only once they are on / at the roadway (`PersonSceneResult.relevantIDs`). The per-class
     * confidence table ([ObjectTracker.minConfidence]) follows the settings slider.
     */
    private val tracker = ObjectTracker(ObjectTracker.Config(deferredCountKinds = setOf(VehicleKind.PERSON)))
    /** 384×640 vs 544×960 detector input, decided from the measured inference time and the thermal status. */
    private val qualityGovernor = DetectorQualityGovernor(DetectorQualityGovernor.Config.android)
    private var appliedConfidence = Double.NaN
    private var reportedDetectorStatus: ModelStatus = ModelStatus.Loading
    private var makeClassifierStatus: ModelStatus = ModelStatus.Loading
    private var thermalConstrained = false
    private var lastThermalCheck = Double.NEGATIVE_INFINITY
    private val estimator = MonocularSpeedEstimator()
    private val leadTracker = LeadVehicleTracker()
    private val laneDetector = LaneDetector()
    private val pedestrianDetector = PedestrianHazardDetector().apply { minConfidence = PEDESTRIAN_MIN_CONFIDENCE }
    private val roadwayEstimator = RoadwayZoneEstimator()
    private var lastLaneUptime = Double.NEGATIVE_INFINITY
    private var laneEstimate: LaneEstimate? = null
    /**
     * Horizon from the lane vanishing point (`settings.autoHorizonEnabled`). [measuredHorizon] is the value in use; it
     * changes only when the estimator moves by more than [LaneHorizonEstimator.applyDelta].
     */
    private val horizonEstimator = LaneHorizonEstimator()
    private var measuredHorizon: Double? = null
    /** Orientation the estimator's samples belong to (null before the first frame). */
    private var horizonIsLandscape: Boolean? = null
    private var corridorCenterX = 0.5
    private var generation = 0
    private var lastFrameTimestamp: Double? = null
    private var fpsEstimate = 0.0
    private var inferenceEstimate = 0.0
    private var processedFrames = 0
    private var lastAcceptedUptime = 0.0
    /**
     * Frame buffers. While learning collection is on they alternate, so the pixels of the previous frame stay intact
     * for one more frame (the hard-example selector decides about the previous frame); otherwise only [0] is used.
     */
    private val frameBuffers = arrayOf(ByteArray(0), ByteArray(0))
    private var bufferIndex = 0
    /** Continuous-learning collector, created when collection is first switched on. */
    private var collector: LearningCollector? = null

    /** Loads the detector and the make classifier on the processing thread and reports their status. */
    fun loadModels() {
        executor.execute {
            // Orientation hint for the first session; the one for the real frame shape is created with the first frame.
            val landscape = appContext.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            val detectorStatus = detector.load(landscape)
            reportedDetectorStatus = detectorStatus
            detectorReady = detectorStatus.isReady
            statusHandler?.invoke(ModelStatuses(detectorStatus, ModelStatus.Loading))
            val makeStatus = makeClassifier.load()
            makeClassifierStatus = makeStatus
            statusHandler?.invoke(ModelStatuses(reportedDetectorStatus, makeStatus))
        }
    }

    /** Starts or stops accepting camera frames. Stopping drops frames immediately and resets the per-drive state. */
    fun setActive(isActive: Boolean) {
        active = isActive
        executor.execute {
            collector?.skipFrame()
            if (isActive) {
                lastAcceptedUptime = 0.0
            } else {
                lastFrameTimestamp = null
                fpsEstimate = 0.0
                // Live tracks must not survive the gap (they would be continued by whatever overlaps their old
                // boxes when frames come back). Unique counters and track IDs are kept.
                tracker.dropTracks()
                estimator.reset()
                leadTracker.reset()
                laneDetector.reset()
                pedestrianDetector.reset()
                roadwayEstimator.reset()
                laneEstimate = null
                corridorCenterX = 0.5
            }
        }
    }

    /** Marks subsequent outputs with [newGeneration] (the controller drops outputs of older generations). */
    fun setGeneration(newGeneration: Int) {
        executor.execute { generation = newGeneration }
    }

    /** Clears tracks, unique counts and estimator history. */
    fun reset(newGeneration: Int) {
        executor.execute {
            collector?.skipFrame()
            tracker.reset()
            estimator.reset()
            leadTracker.reset()
            laneDetector.reset()
            pedestrianDetector.reset()
            roadwayEstimator.reset()
            laneEstimate = null
            corridorCenterX = 0.5
            makeClassifier.reset()
            generation = newGeneration
            lastFrameTimestamp = null
        }
    }

    fun shutdown() {
        executor.execute {
            detector.close()
            collector?.shutdown()
        }
        executor.shutdown()
    }

    // Frames (executor thread)

    override fun analyze(image: ImageProxy) {
        try {
            val now = uptimeSeconds()
            val frameInputs = inputs
            if (!active || !(detectorReady || frameInputs.laneDetectionEnabled)) return
            if (now - lastAcceptedUptime < (1.0 / MAX_FPS) * 0.9) return
            lastAcceptedUptime = now
            val plane = image.planes.firstOrNull() ?: return
            val width = image.width
            val height = image.height
            if (width <= 1 || height <= 1 || plane.pixelStride != 4) return
            val bytesPerRow = plane.rowStride
            val buffer = plane.buffer
            buffer.rewind()
            val needed = bytesPerRow * height
            bufferIndex = if (frameInputs.learning != null) bufferIndex xor 1 else 0
            var frameBytes = frameBuffers[bufferIndex]
            if (frameBytes.size < needed) {
                frameBytes = ByteArray(needed)
                frameBuffers[bufferIndex] = frameBytes
            }
            if (frameInputs.learning == null && frameBuffers[1].isNotEmpty()) frameBuffers[1] = ByteArray(0)
            val count = min(buffer.remaining(), needed)
            buffer.get(frameBytes, 0, count)
            // Sensor timestamp (ns, monotonic); falls back to the uptime when missing.
            val ts = image.imageInfo.timestamp
            val timestamp = if (ts > 0) ts / 1_000_000_000.0 else now
            process(frameBytes, width, height, bytesPerRow, timestamp, frameInputs)
        } catch (_: Throwable) {
            // A bad frame must never kill the analyzer.
        } finally {
            image.close()
        }
    }

    private fun process(rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, timestamp: Double, inputs: Inputs) {
        // One horizon for the lane ROI, the lead corridor, the roadway zone and the light selection of this frame.
        val horizon = horizonInUse(inputs, width, height)
        // Lanes first: independent of the detector, and the lead corridor below follows the fresh lane estimate.
        updateLanes(rgba, width, height, bytesPerRow, inputs, horizon)

        val result = if (detectorReady) detector.detect(rgba, width, height, bytesPerRow, inputs.detection) else null
        // The session in use changes with the frame orientation and the quality level.
        val detectorStatus = detector.status
        if (detectorReady && detectorStatus != reportedDetectorStatus) {
            reportedDetectorStatus = detectorStatus
            statusHandler?.invoke(ModelStatuses(detectorStatus, makeClassifierStatus))
        }
        if (detectorReady) detector.noteFrame(timestamp, inputs.ownSpeedKmh, (result?.rawCount ?: 0) > 0)
        LearningFeature.lastFrameElapsedMs = SystemClock.elapsedRealtime()
        if (result == null) {
            collector?.skipFrame()
            // No detector: still publish the lane estimate so the lane overlay / departure warning work.
            if (inputs.laneDetectionEnabled && !detectorReady) {
                outputHandler?.invoke(Output(generation, emptyList(), emptyMap(), tracker.uniqueCounts.toMap(), fpsEstimate,
                    0.0, null, null, width, height, processedFrames, null, laneEstimate, emptyList(), emptyList(), null,
                    leadTracker.corridor, horizon, measuredHorizon, width >= height))
            }
            return
        }
        // Input size for the next frames, from this frame's inference time and the thermal status.
        detector.preferredLevel = qualityGovernor.record(result.inferenceMs, isThermalConstrained(), uptimeSeconds())
        // One threshold table for the decoder floor and the tracker (no second hidden per-class filter).
        val confidence = inputs.detection.confidenceThreshold
        if (appliedConfidence != confidence) {
            tracker.minConfidence = DetectionThresholds.perClass(confidence)
            appliedConfidence = confidence
        }

        var detections = result.detections
        detections = classifyTrafficLights(detections, rgba, width, height, bytesPerRow)
        detections = classifyPersonRoles(detections, rgba, width, height, bytesPerRow)

        var tracks = tracker.update(detections, timestamp)
        collectLearningSample(rgba, width, height, bytesPerRow, timestamp, inputs, tracks, detections, result)
        val geometry = CameraGeometry(fovDegrees, width.toDouble(), height.toDouble())
        tracks = estimator.update(tracks, inputs.ownSpeedKmh, geometry, timestamp)
        val leadVehicle = updateLeadVehicle(tracks, inputs, geometry, timestamp, horizon)
        // Roadway / sidewalk split: persons outside the roadway zone (not moving toward it) are dropped here.
        val scene = updatePedestrians(tracks, inputs, geometry, timestamp, horizon)
        if (scene.filteredIDs.isNotEmpty()) tracks = tracks.filter { it.id !in scene.filteredIDs }
        tracker.markRelevant(scene.relevantIDs.toList())
        val warningsOn = inputs.pedestrianWarningsEnabled
        val hazards = if (warningsOn) scene.hazards else emptyList()
        val staff = if (warningsOn) scene.staff else emptyList()

        if (inputs.makeRecognitionEnabled && makeClassifier.status.isReady) {
            // Votes become visible in the tracks of the next frame.
            for (o in makeClassifier.classify(tracks, rgba, width, height, bytesPerRow, timestamp)) {
                tracker.addMakeObservation(o.trackID, o.make, o.confidence)
            }
        }

        updateStatistics(timestamp, result.inferenceMs)
        val visibleCounts = HashMap<VehicleKind, Int>()
        val lightThreshold = DetectionThresholds.threshold(VehicleKind.TRAFFIC_LIGHT, confidence)
        for (t in tracks) {
            if (!t.isConfirmed) continue
            // Low-score lights without a readable colour are neither drawn (controller) nor counted as visible.
            if (!TrafficLightSelection.isDisplayable(t, lightThreshold)) continue
            visibleCounts[t.kind] = (visibleCounts[t.kind] ?: 0) + 1
        }
        // Indicator / coach: the light that applies to the own lane (stable known colour, ≥ 5 hits), not simply the
        // largest box.
        val observedLight = TrafficLightSelection.ownLane(tracks, corridorCenterX = corridorCenterX, horizonY = horizon,
            minHits = LIGHT_MIN_HITS)
        val lightColor = observedLight?.color

        outputHandler?.invoke(Output(
            generation = generation, tracks = tracks, visibleCounts = visibleCounts,
            uniqueCounts = tracker.uniqueCounts.toMap(), fps = fpsEstimate, inferenceMs = inferenceEstimate,
            lightColor = lightColor, observedLight = observedLight, frameWidth = width, frameHeight = height, processedFrames = processedFrames,
            leadVehicle = leadVehicle, laneEstimate = laneEstimate, pedestrianHazards = hazards, roadStaff = staff,
            roadwayZone = if (inputs.detection.trackPedestrians) roadwayEstimator.zone else null,
            corridor = leadTracker.corridor, horizonY = horizon, measuredHorizon = measuredHorizon,
            measuredHorizonIsLandscape = width >= height,
        ))
    }

    /**
     * Hands the frame to the continuous-learning collector (cheap unless the frame becomes a sample; see
     * [LearningCollector]). Uses the tracker output before the sidewalk filter, so a dropped person is not mistaken for
     * a track that died.
     */
    private fun collectLearningSample(
        rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, timestamp: Double, inputs: Inputs,
        tracks: List<TrackedObject>, detections: List<Detection>, result: YoloDetector.Output,
    ) {
        val options = inputs.learning
        if (options == null) {
            collector?.skipFrame()
            return
        }
        val c = collector ?: LearningCollector(appContext).also { collector = it }
        try {
            c.onFrame(rgba, width, height, bytesPerRow, timestamp, inputs.ownSpeedKmh, tracks, detections,
                tracker.minConfidence, detector.modelTag(result.inputWidth, result.inputHeight), options)
        } catch (_: Throwable) {
            c.skipFrame()
        }
    }

    /**
     * Picks the lead vehicle (strictly ahead in the own-lane corridor) and fuses its distance from the apparent box
     * width and height. The corridor centre follows the lane centre (smoothed, clamped 0.35–0.65) while the lane
     * estimate is confident, else returns to the frame centre. Resets the tracker while the feature is off.
     */
    private fun updateLeadVehicle(
        tracks: List<TrackedObject>, inputs: Inputs, geometry: CameraGeometry, timestamp: Double, horizon: Double,
    ): LeadVehicle? {
        if (!inputs.followingDistanceEnabled) {
            leadTracker.reset()
            return null
        }
        corridorCenterX = EgoCorridor.smoothedCenterX(corridorCenterX, if (inputs.laneDetectionEnabled) laneEstimate else null)
        val centerX = (corridorCenterX * 1000).roundToLong() / 1000.0
        // Aspect-aware corridor (portrait frames need a wider one); the whole value is compared so a rotation
        // updates it too.
        val corridor = EgoCorridor.forFrame(centerX = centerX, horizonY = horizon, imageWidth = geometry.imageWidth,
            imageHeight = geometry.imageHeight)
        if (leadTracker.corridor != corridor) leadTracker.corridor = corridor
        leadTracker.cameraToBumperMeters = inputs.cameraToBumperMeters
        return leadTracker.update(tracks, geometry, timestamp)
    }

    /** Persons vs the roadway zone: hazards, officers / road workers, and the sidewalk persons to drop. */
    private fun updatePedestrians(
        tracks: List<TrackedObject>, inputs: Inputs, geometry: CameraGeometry, timestamp: Double, horizon: Double,
    ): PersonSceneResult {
        if (!inputs.detection.trackPedestrians) {
            pedestrianDetector.reset()
            roadwayEstimator.reset()
            return PersonSceneResult()
        }
        val corridor = EgoCorridor.forFrame(horizonY = horizon, imageWidth = geometry.imageWidth,
            imageHeight = geometry.imageHeight)
        if (pedestrianDetector.corridor != corridor) pedestrianDetector.corridor = corridor
        val aspectScale = LaneDetector.aspectScale(geometry.imageWidth.toInt(), geometry.imageHeight.toInt())
        if (roadwayEstimator.config.roadWidthFactor != pedestrianDetector.roadWidthFactor ||
            roadwayEstimator.config.aspectScale != aspectScale
        ) {
            roadwayEstimator.config = roadwayEstimator.config.copy(
                roadWidthFactor = pedestrianDetector.roadWidthFactor, aspectScale = aspectScale)
        }
        pedestrianDetector.roadway = roadwayEstimator.update(
            if (inputs.laneDetectionEnabled) laneEstimate else null, pedestrianDetector.corridor,
        )
        return pedestrianDetector.evaluate(tracks, inputs.ownSpeedKmh, geometry, timestamp)
    }

    /**
     * Lane detector at ≈ 5 Hz on a ≤ 160 px wide marking-brightness copy (rows above the horizon skipped).
     *
     * Each lane frame also yields the vanishing point of the two raw line fits; while auto horizon is on and the car
     * drives at least [LaneHorizonEstimator.minSpeedKmh], it is fed to [horizonEstimator]. A converged estimate that
     * differs from the horizon in use by more than [LaneHorizonEstimator.applyDelta] becomes [measuredHorizon] (used
     * from the next frame on by everything that shares the horizon).
     */
    private fun updateLanes(rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, inputs: Inputs, horizon: Double) {
        if (!inputs.laneDetectionEnabled) {
            if (laneEstimate != null) {
                laneDetector.reset()
                laneEstimate = null
            }
            return
        }
        val now = uptimeSeconds()
        if (now - lastLaneUptime < LANE_INTERVAL * 0.9) return
        lastLaneUptime = now
        // Keeps the smoothed lines where they are in the picture (their stored top x is tied to the horizon row).
        if (laneDetector.config.horizonY != horizon) laneDetector.setHorizon(horizon)
        val image = LaneImage.fromBGRA(rgba, width, height, bytesPerRow, targetWidth = LANE_IMAGE_WIDTH,
            roiTop = max(0.0, horizon - 0.02), bgra = false)
        if (image.width <= 0) return
        laneEstimate = laneDetector.process(image, now)

        val speed = inputs.ownSpeedKmh
        if (!inputs.autoHorizonEnabled || speed == null || !speed.isFinite() || speed < LaneHorizonEstimator.minSpeedKmh) return
        val estimate = horizonEstimator.add(laneDetector.lastVanishingPoint)
        if (estimate != null && LaneHorizonEstimator.shouldApply(estimate, horizon)) measuredHorizon = estimate
    }

    /**
     * Horizon row for this frame, clamped to 0.1…0.8: the manual setting, or — while auto horizon is on — the horizon
     * measured in this session, else the one stored from an earlier session for this frame orientation, else the
     * manual setting. A change of the frame orientation (or switching auto off) discards the estimate: the horizon
     * row of a portrait frame says nothing about a landscape one.
     */
    private fun horizonInUse(inputs: Inputs, width: Int, height: Int): Double {
        val landscape = width >= height
        if (horizonIsLandscape != landscape || !inputs.autoHorizonEnabled) {
            if (horizonIsLandscape != null || measuredHorizon != null) {
                horizonEstimator.reset()
                measuredHorizon = null
            }
            horizonIsLandscape = landscape
        }
        var value = inputs.corridorHorizon
        if (inputs.autoHorizonEnabled) {
            val stored = if (landscape) inputs.storedHorizonLandscape else inputs.storedHorizonPortrait
            val measured = measuredHorizon
            if (measured != null) {
                value = measured
            } else if (stored != null && stored.isFinite() && stored >= LaneHorizonEstimator.rowMin &&
                stored <= LaneHorizonEstimator.rowMax
            ) {
                value = stored
            }
        }
        return min(0.8, max(0.1, value))
    }

    /** Estimates the colour of every traffic light from the RGBA pixels inside its box. */
    private fun classifyTrafficLights(detections: List<Detection>, rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int): List<Detection> {
        if (detections.none { it.kind == VehicleKind.TRAFFIC_LIGHT }) return detections
        return detections.map { d ->
            if (d.kind != VehicleKind.TRAFFIC_LIGHT) return@map d
            val box = d.box.clamped
            val rx = floor(box.x * width).toInt(); val ry = floor(box.y * height).toInt()
            val rw = ceil(box.width * width).toInt(); val rh = ceil(box.height * height).toInt()
            if (rw < 3 || rh < 6) return@map d
            // The classifier samples about 24 points along the short side (constant cost for near and far lights).
            d.copy(lightColor = TrafficLightColorClassifier.classifyBGRA(rgba, width, height, bytesPerRow, rx, ry, rw, rh,
                bgra = false))
        }
    }

    /** Guesses the role of every person (officer / road worker / pedestrian) from the hi-vis vest colour. */
    private fun classifyPersonRoles(detections: List<Detection>, rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int): List<Detection> {
        if (detections.none { it.kind == VehicleKind.PERSON }) return detections
        return detections.map { d ->
            if (d.kind != VehicleKind.PERSON) return@map d
            val box = d.box.clamped
            val rw = ceil(box.width * width).toInt(); val rh = ceil(box.height * height).toInt()
            if (rw < 8 || rh < PersonRoleClassifier.minBoxHeightPixels) return@map d
            // About 20 samples across the box width keeps the cost constant for near and far persons.
            val step = max(1, rw / 20)
            d.copy(personRole = PersonRoleClassifier.classifyBGRA(rgba, width, height, bytesPerRow,
                floor(box.x * width).toInt(), floor(box.y * height).toInt(), rw, rh, step = step, bgra = false))
        }
    }

    /** True while the system reports thermal status "severe" or worse (API 29+; polled every few seconds). */
    private fun isThermalConstrained(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val now = uptimeSeconds()
        if (now - lastThermalCheck >= THERMAL_CHECK_INTERVAL) {
            lastThermalCheck = now
            thermalConstrained = try {
                val power = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                (power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE) >= PowerManager.THERMAL_STATUS_SEVERE
            } catch (_: Throwable) {
                false
            }
        }
        return thermalConstrained
    }

    /** Exponential moving averages of the processing rate and the inference time. */
    private fun updateStatistics(timestamp: Double, inferenceMs: Double) {
        lastFrameTimestamp?.let { last ->
            val dt = timestamp - last
            if (dt > 0.001 && dt < 2) {
                val instant = 1 / dt
                fpsEstimate = if (fpsEstimate == 0.0) instant else fpsEstimate * 0.85 + instant * 0.15
            }
        }
        lastFrameTimestamp = timestamp
        inferenceEstimate = if (inferenceEstimate == 0.0) inferenceMs else inferenceEstimate * 0.85 + inferenceMs * 0.15
        processedFrames += 1
    }

    companion object {
        /** Upper bound of the processing rate (the camera delivers 30 fps). */
        const val MAX_FPS = 15.0
        /**
         * A traffic light drives the colour indicator / coach only with this many hits AND a stable known colour
         * ([TrafficLightSelection.ownLane]). The former extra 0.5 confidence floor is gone: the class threshold is
         * 0.30 for recall (see [DetectionThresholds.classBase]), and the colour requirement filters false boxes.
         */
        const val LIGHT_MIN_HITS = TrafficLightSelection.minHits
        /** A pedestrian can raise a warning once its track has reached the person threshold of the default slider. */
        val PEDESTRIAN_MIN_CONFIDENCE = DetectionThresholds.threshold(VehicleKind.PERSON, DetectionThresholds.DEFAULT_GLOBAL_NANO)
        /** Seconds between thermal status polls. */
        const val THERMAL_CHECK_INTERVAL = 5.0
        /** Lane detection interval, seconds (≈ 5 Hz). */
        const val LANE_INTERVAL = 0.2
        /** Width of the downsampled image analysed by the lane detector, pixels. */
        const val LANE_IMAGE_WIDTH = 160

        /** Monotonic clock shared by the worker and the controller, seconds. */
        fun uptimeSeconds(): Double = SystemClock.elapsedRealtimeNanos() / 1_000_000_000.0
    }
}
