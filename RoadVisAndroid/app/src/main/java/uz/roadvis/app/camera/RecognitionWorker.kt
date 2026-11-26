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
import uz.roadvis.core.CameraGeometry
import uz.roadvis.core.Detection
import uz.roadvis.core.DetectionThresholds
import uz.roadvis.core.DetectorQualityGovernor
import uz.roadvis.core.EgoCorridor
import uz.roadvis.core.LaneDetector
import uz.roadvis.core.LaneEstimate
import uz.roadvis.core.LaneImage
import uz.roadvis.core.LeadVehicle
import uz.roadvis.core.LeadVehicleTracker
import uz.roadvis.core.MonocularSpeedEstimator
import uz.roadvis.core.ObjectTracker
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
        val cameraToBumperMeters: Double = 2.2,
        val laneDetectionEnabled: Boolean = true,
        val pedestrianWarningsEnabled: Boolean = true,
    )

    /** Snapshot published after every processed frame. */
    data class Output(
        val generation: Int,
        val tracks: List<TrackedObject>,
        val visibleCounts: Map<VehicleKind, Int>,
        val uniqueCounts: Map<VehicleKind, Int>,
        val fps: Double,
        val inferenceMs: Double,
        val lightColor: TrafficLightColor?,
        val frameWidth: Int,
        val frameHeight: Int,
        val processedFrames: Int,
        val leadVehicle: LeadVehicle?,
        val laneEstimate: LaneEstimate?,
        val pedestrianHazards: List<PedestrianHazard>,
        val roadStaff: List<RoadStaffSighting>,
        val roadwayZone: RoadwayZone?,
        val corridor: EgoCorridor,
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
    private var corridorCenterX = 0.5
    private var generation = 0
    private var lastFrameTimestamp: Double? = null
    private var fpsEstimate = 0.0
    private var inferenceEstimate = 0.0
    private var processedFrames = 0
    private var lastAcceptedUptime = 0.0
    private var frameBytes = ByteArray(0)

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
        executor.execute { detector.close() }
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
            if (frameBytes.size < needed) frameBytes = ByteArray(needed)
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
        // Lanes first: independent of the detector, and the lead corridor below follows the fresh lane estimate.
        updateLanes(rgba, width, height, bytesPerRow, inputs)

        val result = if (detectorReady) detector.detect(rgba, width, height, bytesPerRow, inputs.detection) else null
        // The session in use changes with the frame orientation and the quality level.
        val detectorStatus = detector.status
        if (detectorReady && detectorStatus != reportedDetectorStatus) {
            reportedDetectorStatus = detectorStatus
            statusHandler?.invoke(ModelStatuses(detectorStatus, makeClassifierStatus))
        }
        if (result == null) {
            // No detector: still publish the lane estimate so the lane overlay / departure warning work.
            if (inputs.laneDetectionEnabled && !detectorReady) {
                outputHandler?.invoke(Output(generation, emptyList(), emptyMap(), tracker.uniqueCounts.toMap(), fpsEstimate,
                    0.0, null, width, height, processedFrames, null, laneEstimate, emptyList(), emptyList(), null,
                    leadTracker.corridor))
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
        val geometry = CameraGeometry(fovDegrees, width.toDouble(), height.toDouble())
        tracks = estimator.update(tracks, inputs.ownSpeedKmh, geometry, timestamp)
        val leadVehicle = updateLeadVehicle(tracks, inputs, geometry, timestamp)
        // Roadway / sidewalk split: persons outside the roadway zone (not moving toward it) are dropped here.
        val scene = updatePedestrians(tracks, inputs, geometry, timestamp)
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
        var largestLight: TrackedObject? = null
        for (t in tracks) {
            if (!t.isConfirmed) continue
            visibleCounts[t.kind] = (visibleCounts[t.kind] ?: 0) + 1
            // Indicator only for a solid, currently visible light (no flicker from one-off false positives).
            if (t.kind == VehicleKind.TRAFFIC_LIGHT && t.missed == 0 && t.hits >= LIGHT_MIN_HITS &&
                t.peakConfidence >= LIGHT_MIN_CONFIDENCE && t.box.area > (largestLight?.box?.area ?: 0.0)
            ) largestLight = t
        }
        val lightColor = largestLight?.let { it.lightColor ?: TrafficLightColor.UNKNOWN }

        outputHandler?.invoke(Output(
            generation = generation, tracks = tracks, visibleCounts = visibleCounts,
            uniqueCounts = tracker.uniqueCounts.toMap(), fps = fpsEstimate, inferenceMs = inferenceEstimate,
            lightColor = lightColor, frameWidth = width, frameHeight = height, processedFrames = processedFrames,
            leadVehicle = leadVehicle, laneEstimate = laneEstimate, pedestrianHazards = hazards, roadStaff = staff,
            roadwayZone = if (inputs.detection.trackPedestrians) roadwayEstimator.zone else null,
            corridor = leadTracker.corridor,
        ))
    }

    /**
     * Picks the lead vehicle (strictly ahead in the own-lane corridor) and fuses its distance from the apparent box
     * width and height. The corridor centre follows the lane centre (smoothed, clamped 0.35–0.65) while the lane
     * estimate is confident, else returns to the frame centre. Resets the tracker while the feature is off.
     */
    private fun updateLeadVehicle(tracks: List<TrackedObject>, inputs: Inputs, geometry: CameraGeometry, timestamp: Double): LeadVehicle? {
        if (!inputs.followingDistanceEnabled) {
            leadTracker.reset()
            return null
        }
        val horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        corridorCenterX = EgoCorridor.smoothedCenterX(corridorCenterX, if (inputs.laneDetectionEnabled) laneEstimate else null)
        val centerX = (corridorCenterX * 1000).roundToLong() / 1000.0
        if (leadTracker.corridor.horizonY != horizon || leadTracker.corridor.centerX != centerX) {
            leadTracker.corridor = EgoCorridor(centerX = centerX, horizonY = horizon)
        }
        leadTracker.cameraToBumperMeters = inputs.cameraToBumperMeters
        return leadTracker.update(tracks, geometry, timestamp)
    }

    /** Persons vs the roadway zone: hazards, officers / road workers, and the sidewalk persons to drop. */
    private fun updatePedestrians(tracks: List<TrackedObject>, inputs: Inputs, geometry: CameraGeometry, timestamp: Double): PersonSceneResult {
        if (!inputs.detection.trackPedestrians) {
            pedestrianDetector.reset()
            roadwayEstimator.reset()
            return PersonSceneResult()
        }
        val horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        if (pedestrianDetector.corridor.horizonY != horizon) pedestrianDetector.corridor = EgoCorridor(horizonY = horizon)
        if (roadwayEstimator.config.roadWidthFactor != pedestrianDetector.roadWidthFactor) {
            roadwayEstimator.config = roadwayEstimator.config.copy(roadWidthFactor = pedestrianDetector.roadWidthFactor)
        }
        pedestrianDetector.roadway = roadwayEstimator.update(
            if (inputs.laneDetectionEnabled) laneEstimate else null, pedestrianDetector.corridor,
        )
        return pedestrianDetector.evaluate(tracks, inputs.ownSpeedKmh, geometry, timestamp)
    }

    /** Lane detector at ≈ 5 Hz on a ≤ 160 px wide marking-brightness copy (rows above the horizon skipped). */
    private fun updateLanes(rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, inputs: Inputs) {
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
        val horizon = min(0.8, max(0.1, inputs.corridorHorizon))
        if (laneDetector.config.horizonY != horizon) laneDetector.config = laneDetector.config.copy(horizonY = horizon)
        val image = LaneImage.fromBGRA(rgba, width, height, bytesPerRow, targetWidth = LANE_IMAGE_WIDTH,
            roiTop = max(0.0, horizon - 0.02), bgra = false)
        if (image.width <= 0) return
        laneEstimate = laneDetector.process(image, now)
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
            // About 24 samples along the short side keeps the cost constant for near and far lights.
            val step = max(1, min(rw, rh) / 24)
            d.copy(lightColor = TrafficLightColorClassifier.classifyBGRA(rgba, width, height, bytesPerRow, rx, ry, rw, rh,
                step = step, bgra = false))
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
         * A traffic light drives the colour indicator only with this many hits and once the track has reached this
         * detector confidence ([TrackedObject.peakConfidence]). Kept at 0.5 whatever the slider says: traffic-light
         * precision was only ≈ 50–58 % at 0.25 in the BDD100K measurement (see [DetectionThresholds]).
         */
        const val LIGHT_MIN_HITS = 5
        const val LIGHT_MIN_CONFIDENCE = 0.5
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
