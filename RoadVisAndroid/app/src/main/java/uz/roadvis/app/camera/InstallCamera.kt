package uz.roadvis.app.camera

import uz.roadvis.app.app.AppState

/** Holder of the camera feature's long-lived controller (one per process, survives activity recreation). */
object CameraFeature {
    private var controller: RecognitionController? = null

    /** The recognition controller, created on first use (main thread). */
    fun controller(app: AppState): RecognitionController =
        controller ?: RecognitionController(app).also { controller = it }
}

/**
 * Called once from [AppState.start]: creates the recognition controller (loads the ONNX model in the background,
 * registers the location listener, the coach and the drive-start hook). The camera itself is bound by [CameraScreen].
 */
fun installCamera(app: AppState) {
    CameraFeature.controller(app)
}
