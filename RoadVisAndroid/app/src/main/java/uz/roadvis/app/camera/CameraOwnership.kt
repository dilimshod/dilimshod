package uz.roadvis.app.camera

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Who owns the back camera. The recognition camera ([CameraBinding], bound by `CameraScreen` and kept bound even while
 * the navigator is shown) and the QR scanner of the driver cabinet (`cabinet/QrScannerScreen`) use the same camera with
 * a preview + analysis pair each, which CameraX cannot run side by side. While [scannerOpen] is true the camera screen
 * unbinds its use cases (and pauses inference); the scanner binds only once [recognitionBound] is false, and clears
 * [scannerOpen] after it has unbound, so the camera screen rebinds. Main-thread Compose state.
 */
object CameraOwnership {
    /** Set before the scanner is shown, cleared after the scanner has released the camera. */
    var scannerOpen by mutableStateOf(false)

    /** True while the recognition camera has its use cases bound (set by the camera screen). */
    var recognitionBound by mutableStateOf(false)
}
