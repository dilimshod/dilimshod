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
class CameraBinding(private val context: Context, private val controller: RecognitionController) {
    private val selector16x9 = ResolutionSelector.Builder()
        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
        .build()

    val preview: Preview = Preview.Builder().setResolutionSelector(selector16x9).build()

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

    /** Binds preview + analysis to [owner] (idempotent for the same owner). */
    fun bind(owner: LifecycleOwner, previewView: PreviewView, rotation: Int) {
        setRotation(rotation)
        preview.setSurfaceProvider(previewView.surfaceProvider)
        if (boundOwner === owner && camera != null) return
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val p = try { future.get() } catch (t: Throwable) {
                controller.cameraError = t.message ?: t.javaClass.simpleName
                return@addListener
            }
            provider = p
            try {
                p.unbind(preview, analysis)
                val cam = p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
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
        provider?.unbind(preview, analysis)
        camera?.cameraInfo?.cameraState?.let { state -> boundOwner?.let { state.removeObservers(it) } }
        camera = null
        boundOwner = null
        controller.cameraStopped()
    }

    /** Follows the display rotation so analysis frames stay upright and the preview stays aligned. */
    fun setRotation(rotation: Int) {
        val r = when (rotation) { Surface.ROTATION_90, Surface.ROTATION_180, Surface.ROTATION_270 -> rotation; else -> Surface.ROTATION_0 }
        if (preview.targetRotation != r) preview.targetRotation = r
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
