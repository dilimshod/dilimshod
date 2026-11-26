package uz.roadvis.app.learning

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import uz.roadvis.core.BBox
import uz.roadvis.core.Detection
import uz.roadvis.core.FrameQuality
import uz.roadvis.core.HardExampleSelector
import uz.roadvis.core.LearningSampleMeta
import uz.roadvis.core.LearningStorePolicy
import uz.roadvis.core.TrackedObject
import uz.roadvis.core.VehicleKind
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Continuous-learning collector (`docs/TRAINING_API.md` §1–2), called by the recognition worker on its processing
 * thread for every frame the detector ran on.
 *
 * Cost per frame: one [HardExampleSelector.push] (a few list scans). Only when a reason fired and the cheap gates
 * (2 s interval, 300 per trip, speed) passed does it compute [FrameQuality] on a 160-px gray copy — at most every
 * [QUALITY_RETRY_SECONDS], so a dark or blurred stretch cannot make it run on every frame. A kept frame is copied
 * once and handed to a low-priority encoder thread, which builds the Bitmap, scales it to a 960-px long side, blurs
 * the head region of large persons, writes `<uuid>.jpg` (quality 80) + `<uuid>.json` and applies the retention rules.
 *
 * The selector decides about the PREVIOUS frame (see [HardExampleSelector]); the worker double-buffers the frame
 * bytes, so the pixels of the previous frame are still intact here. If the buffers ever coincide, nothing is saved.
 *
 * Face blurring: Android has no free on-device face detector without new dependencies, so instead of face boxes the
 * upper third of every person box at least [BLUR_MIN_PERSON_HEIGHT] of the frame tall is blurred (smaller persons are
 * too small for a recognizable face at 960 px).
 */
class LearningCollector(context: Context) {
    /** Per-frame options from the settings (pushed by the controller). */
    data class Options(
        val sendLocation: Boolean = false,
        val latitude: Double? = null,
        val longitude: Double? = null,
        val storageLimitMb: Int = LearningStorePolicy.DEFAULT_STORAGE_LIMIT_MB,
    )

    /** Name and version of the detector model that produced the detections (upload metadata `model`). */
    data class ModelTag(val name: String, val version: String)

    private class PixelRef(val bytes: ByteArray, val width: Int, val height: Int, val bytesPerRow: Int)
    private class FrameContext(val capturedAtMillis: Long, val model: ModelTag, val options: Options)

    private val appContext = context.applicationContext
    private val store = LearningStore(appContext)
    private val selector = HardExampleSelector()
    private val encoder: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "learning.encoder").apply { priority = Thread.MIN_PRIORITY }
    }
    private val encoding = AtomicBoolean(false)
    private val appVersion: String = try {
        appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName ?: "1.0"
    } catch (_: Exception) {
        "1.0"
    }

    // Processing-thread state
    private var frameIndex = 0L
    private var pendingPixels: PixelRef? = null
    private var pendingContext: FrameContext? = null
    private var lastQualityCheck = Double.NEGATIVE_INFINITY
    private var seenTripGeneration = LearningFeature.tripGeneration
    private var unreportedQualityRejections = 0
    private var lastRejectionFlush = Double.NEGATIVE_INFINITY

    /**
     * One processed frame: [rgba] is the upright RGBA_8888 frame (must stay intact until the next call), [tracks] the
     * tracker output of this frame, [detections] the raw detections, [classThresholds] the per-class thresholds in use.
     */
    fun onFrame(
        rgba: ByteArray, width: Int, height: Int, bytesPerRow: Int, timestamp: Double, speedKmh: Double?,
        tracks: List<TrackedObject>, detections: List<Detection>, classThresholds: Map<VehicleKind, Double>,
        model: ModelTag, options: Options,
    ) {
        val trip = LearningFeature.tripGeneration
        if (trip != seenTripGeneration) {
            seenTripGeneration = trip
            selector.resetTrip()
        }
        frameIndex += 1
        val frame = HardExampleSelector.Frame(frameIndex, timestamp, speedKmh, tracks.map { HardExampleSelector.Track.from(it) },
            detections, classThresholds)
        val previousPixels = pendingPixels
        val previousContext = pendingContext
        pendingPixels = PixelRef(rgba, width, height, bytesPerRow)
        pendingContext = FrameContext(System.currentTimeMillis(), model, options)

        flushRejections(timestamp)
        val candidate = selector.push(frame) ?: return
        if (previousPixels == null || previousContext == null || previousPixels.bytes === rgba) return
        if (encoding.get()) return
        if (timestamp - lastQualityCheck < QUALITY_RETRY_SECONDS && timestamp >= lastQualityCheck) return
        lastQualityCheck = timestamp

        val gray = FrameQuality.grayFromRGBA(previousPixels.bytes, previousPixels.width, previousPixels.height,
            previousPixels.bytesPerRow)
        val quality = FrameQuality.measure(gray)
        val decision = selector.decide(candidate, quality)
        if (!decision.keep) {
            unreportedQualityRejections += 1
            return
        }
        val p = previousPixels
        val needed = min(p.bytes.size, p.bytesPerRow * p.height)
        val copy = p.bytes.copyOf(needed)
        encoding.set(true)
        try {
            encoder.execute {
                try {
                    save(copy, p.width, p.height, p.bytesPerRow, candidate.frame, decision.reasons, quality, previousContext)
                } catch (_: Throwable) {
                    // A failed sample is simply not saved.
                } finally {
                    encoding.set(false)
                }
            }
        } catch (_: Throwable) {
            encoding.set(false)
        }
    }

    /** The detector produced nothing for this frame, or frames stopped: the one-frame memory is no longer valid. */
    fun skipFrame() {
        selector.reset()
        pendingPixels = null
        pendingContext = null
    }

    fun shutdown() {
        encoder.shutdown()
    }

    private fun flushRejections(timestamp: Double) {
        if (unreportedQualityRejections == 0) return
        if (timestamp - lastRejectionFlush < 10.0 && timestamp >= lastRejectionFlush) return
        lastRejectionFlush = timestamp
        val n = unreportedQualityRejections
        unreportedQualityRejections = 0
        encoder.execute { LearningStatus.addDeletedByQuality(appContext, n) }
    }

    // Encoder thread

    private fun save(
        bytes: ByteArray, width: Int, height: Int, bytesPerRow: Int, frame: HardExampleSelector.Frame,
        reasons: List<String>, quality: FrameQuality.Metrics, context: FrameContext,
    ) {
        val full = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val tight = width * 4
        if (bytesPerRow == tight) {
            full.copyPixelsFromBuffer(ByteBuffer.wrap(bytes, 0, tight * height))
        } else {
            val packed = ByteArray(tight * height)
            for (y in 0 until height) System.arraycopy(bytes, y * bytesPerRow, packed, y * tight, tight)
            full.copyPixelsFromBuffer(ByteBuffer.wrap(packed))
        }
        val scale = min(1.0, LearningStorePolicy.JPEG_LONG_SIDE.toDouble() / max(width, height))
        val tw = max(1, (width * scale).roundToInt())
        val th = max(1, (height * scale).roundToInt())
        var image = if (tw == width && th == height) full else Bitmap.createScaledBitmap(full, tw, th, true)
        if (!image.isMutable) image = image.copy(Bitmap.Config.ARGB_8888, true)
        if (image !== full) full.recycle()

        blurPersonHeads(image, frame)

        val out = ByteArrayOutputStream(256 * 1024)
        image.compress(Bitmap.CompressFormat.JPEG, LearningStorePolicy.JPEG_QUALITY, out)
        image.recycle()
        val jpeg = out.toByteArray()
        if (jpeg.size > LearningStorePolicy.MAX_UPLOAD_BYTES) return

        val o = context.options
        val id = UUID.randomUUID().toString()
        val meta = LearningSampleMeta(
            id = id, capturedAtMillis = context.capturedAtMillis, appVersion = appVersion,
            modelName = context.model.name, modelVersion = context.model.version,
            imageWidth = tw, imageHeight = th, reasons = reasons, speedKmh = frame.speedKmh,
            lat = if (o.sendLocation) o.latitude else null, lon = if (o.sendLocation) o.longitude else null,
            detections = frame.detections, tracks = frame.tracks, quality = quality,
        )
        if (store.write(id, jpeg, meta.toJson().toString())) {
            store.applyRetention(o.storageLimitMb)
            LearningStatus.refresh(appContext)
        }
    }

    /** Blurs the upper third of every person box (detections and live tracks) at least 12 % of the frame tall. */
    private fun blurPersonHeads(image: Bitmap, frame: HardExampleSelector.Frame) {
        val boxes = ArrayList<BBox>()
        for (d in frame.detections) if (d.kind == VehicleKind.PERSON) boxes.add(d.box)
        for (t in frame.tracks) if (t.kind == VehicleKind.PERSON && t.missed == 0) boxes.add(t.box)
        if (boxes.isEmpty()) return
        val canvas = Canvas(image)
        for (box in boxes) {
            val b = box.clamped
            if (b.height < BLUR_MIN_PERSON_HEIGHT) continue
            val left = floor(b.x * image.width).toInt().coerceIn(0, image.width - 1)
            val top = floor(b.y * image.height).toInt().coerceIn(0, image.height - 1)
            val right = ceil((b.x + b.width) * image.width).toInt().coerceIn(left + 1, image.width)
            val bottom = ceil((b.y + b.height / 3) * image.height).toInt().coerceIn(top + 1, image.height)
            val rw = right - left
            val rh = bottom - top
            if (rw < 2 || rh < 2) continue
            val region = Bitmap.createBitmap(image, left, top, rw, rh)
            // Down to ≈ 6 cells across, then back up with bilinear filtering: a strong blur without dependencies.
            val sw = max(1, min(rw, BLUR_CELLS))
            val sh = max(1, (rh.toDouble() * sw / rw).roundToInt())
            val small = Bitmap.createScaledBitmap(region, sw, sh, true)
            val blurred = Bitmap.createScaledBitmap(small, rw, rh, true)
            canvas.drawBitmap(blurred, null, Rect(left, top, right, bottom), null)
            if (region !== image) region.recycle()
            if (small !== region) small.recycle()
            if (blurred !== small) blurred.recycle()
        }
    }

    companion object {
        /** After a quality check, the next one waits at least this long, seconds. */
        const val QUALITY_RETRY_SECONDS = 0.5
        /** Person boxes from this height (fraction of the frame) get their upper third blurred. */
        const val BLUR_MIN_PERSON_HEIGHT = 0.12
        private const val BLUR_CELLS = 6
    }
}
