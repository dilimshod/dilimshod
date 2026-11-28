package uz.roadvis.app.cabinet

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size as GeoSize
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import kotlinx.coroutines.flow.first
import uz.roadvis.app.camera.CameraOwnership
import uz.roadvis.app.l10n.L
import uz.roadvis.app.ui.RV
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

/**
 * Full-screen QR scanner of the website login (`CABINET_API.md` §4): its own CameraX preview + YUV ImageAnalysis with a
 * ZXing [QRCodeReader] on the luminance (Y) plane, a viewfinder overlay, a torch toggle and cancel. The recognition
 * camera of the camera screen uses the same back camera: the caller sets [CameraOwnership.scannerOpen] before showing
 * this dialog (the camera screen then unbinds), the scanner binds once the recognition camera is released, and clears
 * the flag after unbinding on close, so the camera screen rebinds. Asks for the camera permission when needed.
 *
 * [onResult] gets the raw text of the first QR code found (the dialog should be closed by the caller).
 */
@Composable
fun QrScannerScreen(onResult: (String) -> Unit, onCancel: () -> Unit) {
    Dialog(
        onDismissRequest = onCancel,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(Modifier.fillMaxSize().background(Color.Black)) { ScannerContent(onResult, onCancel) }
    }
}

@Composable
private fun ScannerContent(onResult: (String) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    @Suppress("DEPRECATION")
    val owner = androidx.compose.ui.platform.LocalLifecycleOwner.current
    var granted by remember { mutableStateOf(hasCameraPermission(context)) }
    var denied by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok
        denied = !ok
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }

    val scanner = remember { QrCameraController(context.applicationContext) { text -> onResult(text) } }
    val previewView = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }
    // One effect owns the hand-over: the flag stays set until the scanner has unbound.
    DisposableEffect(scanner) {
        CameraOwnership.scannerOpen = true
        onDispose {
            scanner.release()
            CameraOwnership.scannerOpen = false
        }
    }
    LaunchedEffect(granted) {
        if (!granted) return@LaunchedEffect
        // Wait until the camera screen has unbound the recognition camera (same back camera).
        snapshotFlow { CameraOwnership.recognitionBound }.first { !it }
        scanner.bind(owner, previewView)
    }

    if (granted) {
        AndroidView(factory = { previewView }, modifier = Modifier.fillMaxSize())
        Viewfinder(Modifier.fillMaxSize())
    }

    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onCancel) { Icon(Icons.Filled.Close, L("common.cancel"), tint = Color.White) }
            Text(L("cabinet.qr.title"), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
            Spacer(Modifier.size(48.dp))
        }
        Spacer(Modifier.weight(1f))
        when {
            denied || (!granted && !hasCameraPermission(context)) -> PermissionCard(denied, context, onCancel) {
                permission.launch(Manifest.permission.CAMERA)
            }
            scanner.error != null -> Text(L("cabinet.qr.error.camera", scanner.error ?: ""), color = RV.caution, fontSize = 14.sp,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(24.dp))
            else -> Text(L("cabinet.qr.hint"), color = Color.White, fontSize = 14.sp, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 12.dp))
        }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onCancel) { Text(L("common.cancel"), color = Color.White, fontSize = 16.sp) }
            if (granted && scanner.torchAvailable) {
                IconButton(
                    onClick = { scanner.setTorch(!scanner.torchOn) },
                    modifier = Modifier.size(56.dp).background(
                        if (scanner.torchOn) RV.accent.copy(alpha = 0.85f) else Color.White.copy(alpha = 0.18f), CircleShape),
                ) {
                    Icon(if (scanner.torchOn) Icons.Filled.FlashlightOn else Icons.Filled.FlashlightOff, L("cabinet.qr.torch"),
                        tint = Color.White)
                }
            }
        }
    }
}

@Composable
private fun PermissionCard(denied: Boolean, context: Context, onCancel: () -> Unit, request: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(24.dp).background(Color(0xFF1A1D22), androidx.compose.foundation.shape.RoundedCornerShape(RV.Radius.card)).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.QrCodeScanner, null, tint = RV.accent, modifier = Modifier.size(40.dp))
        Text(L("cabinet.qr.permission"), color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center)
        Button(
            onClick = {
                if (!denied) request() else try {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {}
            },
            colors = ButtonDefaults.buttonColors(containerColor = RV.accent),
        ) { Text(L("cabinet.qr.openSettings")) }
        TextButton(onClick = onCancel) { Text(L("common.cancel"), color = Color.White) }
    }
}

/** Dimmed screen with a clear rounded square and accent corner brackets. */
@Composable
private fun Viewfinder(modifier: Modifier) {
    Canvas(modifier.graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)) {
        val side = min(size.width, size.height) * 0.68f
        val topLeft = Offset((size.width - side) / 2, (size.height - side) / 2)
        val radius = 24.dp.toPx()
        drawRect(Color.Black.copy(alpha = 0.55f))
        drawRoundRect(Color.Transparent, topLeft, GeoSize(side, side), CornerRadius(radius), blendMode = BlendMode.Clear)
        val stroke = 5.dp.toPx()
        val arm = side * 0.16f
        val l = topLeft.x
        val t = topLeft.y
        val r = topLeft.x + side
        val b = topLeft.y + side
        val c = RV.accent
        fun line(x1: Float, y1: Float, x2: Float, y2: Float) = drawLine(c, Offset(x1, y1), Offset(x2, y2), stroke, StrokeCap.Round)
        line(l, t + arm, l, t + radius / 2); line(l + radius / 2, t, l + arm, t)
        line(r - arm, t, r - radius / 2, t); line(r, t + radius / 2, r, t + arm)
        line(l, b - arm, l, b - radius / 2); line(l + radius / 2, b, l + arm, b)
        line(r - arm, b, r - radius / 2, b); line(r, b - radius / 2, r, b - arm)
    }
}

private fun hasCameraPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

/**
 * CameraX binding of the scanner: 16:9 preview + YUV_420_888 analysis (≈ 1280 × 720, KEEP_ONLY_LATEST). Each frame's
 * Y plane becomes a [PlanarYUVLuminanceSource] (row stride as data width) for [QRCodeReader]; QR detection does not
 * depend on the frame rotation. The first decoded text is delivered once on the main thread. Main thread only.
 */
private class QrCameraController(private val context: Context, private val onDecoded: (String) -> Unit) {
    var torchAvailable by mutableStateOf(false); private set
    var torchOn by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set

    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r -> Thread(r, "QrScanner").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private val delivered = AtomicBoolean(false)
    private var released = false
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null
    private var camera: Camera? = null

    private val reader = QRCodeReader()
    private val hints = mapOf(DecodeHintType.TRY_HARDER to true, DecodeHintType.CHARACTER_SET to "UTF-8")

    fun bind(owner: LifecycleOwner, previewView: PreviewView) {
        if (released || camera != null) return
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (released) return@addListener
            try {
                val p = future.get()
                provider = p
                val selector = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                    .build()
                val pv = Preview.Builder().setResolutionSelector(selector).build()
                pv.setSurfaceProvider(previewView.surfaceProvider)
                val an = ImageAnalysis.Builder()
                    .setResolutionSelector(selector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                    .build()
                an.setAnalyzer(executor) { image -> analyze(image) }
                preview = pv
                analysis = an
                val cam = p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, pv, an)
                camera = cam
                torchAvailable = cam.cameraInfo.hasFlashUnit()
                error = null
            } catch (t: Throwable) {
                error = t.message ?: t.javaClass.simpleName
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun setTorch(on: Boolean) {
        val cam = camera ?: return
        cam.cameraControl.enableTorch(on)
        torchOn = on
    }

    /** Unbinds synchronously (the camera screen may rebind right after). */
    fun release() {
        if (released) return
        released = true
        try {
            if (torchOn) camera?.cameraControl?.enableTorch(false)
        } catch (_: Throwable) {}
        analysis?.clearAnalyzer()
        val p = provider
        val use = listOfNotNull(preview, analysis)
        if (p != null && use.isNotEmpty()) {
            try { p.unbind(*use.toTypedArray()) } catch (_: Throwable) {}
        }
        camera = null
        executor.shutdown()
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (delivered.get()) return
            val plane = image.planes[0]
            val buffer = plane.buffer
            val data = ByteArray(buffer.remaining())
            buffer.get(data)
            val rowStride = plane.rowStride
            val width = image.width
            val height = image.height
            if (rowStride < width || data.size < (height - 1) * rowStride + width) return
            val source = PlanarYUVLuminanceSource(data, rowStride, height, 0, 0, width, height, false)
            val text = try {
                reader.decode(BinaryBitmap(HybridBinarizer(source)), hints).text
            } catch (_: ReaderException) {
                null
            } finally {
                reader.reset()
            }
            if (!text.isNullOrBlank() && delivered.compareAndSet(false, true)) {
                main.post { if (!released) onDecoded(text) }
            }
        } catch (_: Throwable) {
        } finally {
            image.close()
        }
    }
}
