package uz.roadvis.app.camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.util.Size
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlin.math.atan
import kotlin.math.max

/**
 * CameraX setup of the camera screen: a 16:9 [Preview] into a [PreviewView] (FILL_CENTER, i.e. aspect-fill — the
 * geometry [AspectFillMapping] reproduces) and a 16:9 RGBA_8888 [ImageAnalysis] (KEEP_ONLY_LATEST, ≈ 1280 × 720,
 * rotated upright by CameraX) feeding [RecognitionWorker]. Both use cases share the aspect ratio, so the normalized
 * boxes of the analysed frame line up with the picture. Main thread only.
 */
class CameraBinding(
    private val context: Context,
    private val controller: RecognitionController,
    /**
     * Electronic stabilization (CameraX preview stabilization = Camera2 PREVIEW_STABILIZATION). Per the Camera2
     * contract it stabilizes the preview AND all other non-RAW streams with the same quality, so the analysed frames
     * stay aligned with the picture under the boxes. Used only where the device reports support; lens OIS is left to
     * the device default. It crops the frame slightly.
     */
    private val stabilization: Boolean = true,
) {
    private val selector16x9 = ResolutionSelector.Builder()
        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
        .build()

    private var preview: Preview? = null
    private var pendingRotation: Int = Surface.ROTATION_0

    /** True when preview stabilization is active on the bound camera. */
    var stabilizationActive: Boolean = false
        private set

    private fun buildPreview(p: ProcessCameraProvider): Preview {
        preview?.let { return it }
        val supported = stabilization && try {
            Preview.getPreviewCapabilities(p.getCameraInfo(CameraSelector.DEFAULT_BACK_CAMERA)).isStabilizationSupported
        } catch (_: Throwable) { false }
        stabilizationActive = supported
        val builder = Preview.Builder().setResolutionSelector(selector16x9).setTargetRotation(pendingRotation)
        if (supported) builder.setPreviewStabilizationEnabled(true)
        return builder.build().also { preview = it }
    }

    val analysis: ImageAnalysis = ImageAnalysis.Builder()
        .setResolutionSelector(
            ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build(),
        )
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
        .setOutputImageRotationEnabled(true)
        .build()
        .also { it.setAnalyzer(controller.worker.executor, controller.worker) }

    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var boundOwner: LifecycleOwner? = null
    /** Incremented by every [bind] / [unbind]: a provider callback of an older request does nothing. */
    private var requestGeneration = 0

    /** Binds preview + analysis to [owner] (idempotent for the same owner). */
    fun bind(owner: LifecycleOwner, previewView: PreviewView, rotation: Int) {
        setRotation(rotation)
        preview?.setSurfaceProvider(previewView.surfaceProvider)
        if (boundOwner === owner && camera != null) return
        val generation = ++requestGeneration
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            // Unbound (e.g. the QR scanner took the camera) before the provider was ready: stay unbound.
            if (generation != requestGeneration) return@addListener
            val p = try { future.get() } catch (t: Throwable) {
                controller.cameraError = t.message ?: t.javaClass.simpleName
                return@addListener
            }
            provider = p
            try {
                preview?.let { p.unbind(it) }
                p.unbind(analysis)
                val pv = try {
                    buildPreview(p)
                } catch (t: Throwable) {
                    // Never lose the camera over stabilization: fall back to a plain preview.
                    stabilizationActive = false
                    Preview.Builder().setResolutionSelector(selector16x9).build().also { preview = it }
                }
                pv.setSurfaceProvider(previewView.surfaceProvider)
                val cam = try {
                    p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, pv, analysis)
                } catch (t: Throwable) {
                    if (!stabilizationActive) throw t
                    // Some devices report support but refuse the combination: retry without stabilization.
                    p.unbind(pv)
                    stabilizationActive = false
                    val plain = Preview.Builder().setResolutionSelector(selector16x9).setTargetRotation(pendingRotation).build()
                    preview = plain
                    plain.setSurfaceProvider(previewView.surfaceProvider)
                    p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, plain, analysis)
                }
                camera = cam
                boundOwner = owner
                controller.cameraError = null
                controller.horizontalFov = horizontalFov(cam)
                controller.worker.fovDegrees = controller.horizontalFov
                cam.cameraInfo.cameraState.observe(owner) { state ->
                    when (state.type) {
                        CameraState.Type.OPEN -> controller.isRunning = true
                        CameraState.Type.CLOSED, CameraState.Type.CLOSING, CameraState.Type.PENDING_OPEN ->
                            if (controller.isRunning) controller.cameraStopped()
                        else -> {}
                    }
                    val error = state.error
                    controller.cameraError = if (error != null && error.type == CameraState.ErrorType.CRITICAL) {
                        "Camera error ${error.code}"
                    } else null
                }
            } catch (t: Throwable) {
                controller.cameraError = t.message ?: t.javaClass.simpleName
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun unbind() {
        requestGeneration++
        provider?.let { p -> preview?.let { p.unbind(it) }; p.unbind(analysis) }
        camera?.cameraInfo?.cameraState?.let { state -> boundOwner?.let { state.removeObservers(it) } }
        camera = null
        boundOwner = null
        controller.cameraStopped()
    }

    /** Follows the display rotation so analysis frames stay upright and the preview stays aligned. */
    fun setRotation(rotation: Int) {
        val r = when (rotation) { Surface.ROTATION_90, Surface.ROTATION_180, Surface.ROTATION_270 -> rotation; else -> Surface.ROTATION_0 }
        pendingRotation = r
        preview?.let { if (it.targetRotation != r) it.targetRotation = r }
        if (analysis.targetRotation != r) analysis.targetRotation = r
    }

    /** Horizontal field of view along the sensor's long side, degrees (65° when the camera does not report it). */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun horizontalFov(cam: Camera): Double = try {
        val info = Camera2CameraInfo.from(cam.cameraInfo)
        val sensor = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val focal = info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull()
        if (sensor != null && focal != null && focal > 0) {
            val longSide = max(sensor.width, sensor.height).toDouble()
            Math.toDegrees(2 * atan(longSide / (2 * focal))).takeIf { it in 30.0..120.0 } ?: 65.0
        } else 65.0
    } catch (_: Throwable) {
        65.0
    }
}
