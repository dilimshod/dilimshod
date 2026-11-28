package uz.roadvis.app.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uz.roadvis.app.app.NavBanner
import uz.roadvis.app.detection.Letterbox
import uz.roadvis.app.detection.YoloDetector
import uz.roadvis.core.BBox
import uz.roadvis.core.DetectorQualityGovernor
import uz.roadvis.core.ManeuverType
import uz.roadvis.core.YOLODecoder
import java.nio.ByteBuffer
import java.nio.ByteOrder

class GeometryTest {
    @Test fun aspectFillPortraitFrameOnTallerView() {
        // 720×1280 frame on a 1080×2400 view: height-limited, sides cropped.
        val m = AspectFillMapping.of(720f, 1280f, 1080f, 2400f)
        assertEquals(2400f, m.displayedHeight, 0.01f)
        assertEquals(1350f, m.displayedWidth, 0.01f)
        assertEquals(-135f, m.offsetX, 0.01f)
        assertEquals(0f, m.offsetY, 0.01f)
        val r = m.rect(BBox(0.5, 0.5, 0.1, 0.1))
        assertEquals(540f, r.left, 0.01f)
        assertEquals(1200f, r.top, 0.01f)
        val (nx, ny) = m.normalized(540f, 1200f)
        assertEquals(0.5, nx, 1e-6); assertEquals(0.5, ny, 1e-6)
    }

    @Test fun aspectFillLandscapeWiderView() {
        val m = AspectFillMapping.of(1280f, 720f, 2400f, 1080f)
        assertEquals(2400f, m.displayedWidth, 0.01f)
        assertEquals(1350f, m.displayedHeight, 0.01f)
        assertEquals(-135f, m.offsetY, 0.01f)
    }

    @Test fun letterboxMatchesDecoderMapping() {
        // Portrait 720×1280 frame in the LITE portrait input 384×640: gain 0.5, 12-pixel bars left and right.
        val lb = Letterbox(384, 640, 720, 1280)
        assertEquals(0.5, lb.gain, 1e-9)
        assertEquals(360, lb.scaledW); assertEquals(640, lb.scaledH)
        assertEquals(12, lb.padX); assertEquals(0, lb.padY)
        // A box in input pixels maps back through the core decoder to the same source region.
        val n = 100
        val v = FloatArray(84 * n)   // channel-major [1, 84, N]; only anchor 0 is scored
        v[0 * n] = 192f; v[1 * n] = 320f; v[2 * n] = 180f; v[3 * n] = 320f; v[(4 + 2) * n] = 0.9f
        val d = YOLODecoder.decode(v, listOf(1, 84, n), 384.0, 640.0, 0.5, 0.45, sourceWidth = 720.0, sourceHeight = 1280.0).single()
        assertEquals(0.25, d.box.x, 1e-6); assertEquals(0.25, d.box.y, 1e-6)
        assertEquals(0.5, d.box.width, 1e-6); assertEquals(0.5, d.box.height, 1e-6)
        assertEquals(0.25, lb.sourceX(102.0), 1e-6)
        assertEquals(0.25, lb.sourceY(160.0), 1e-6)
    }

    @Test fun letterboxRectangularInputs() {
        // Landscape 1280×720 frame: LITE 640×384 → gain 0.5, 12-pixel bars top and bottom.
        val lite = Letterbox(640, 384, 1280, 720)
        assertEquals(0.5, lite.gain, 1e-9)
        assertEquals(640, lite.scaledW); assertEquals(360, lite.scaledH)
        assertEquals(0, lite.padX); assertEquals(12, lite.padY)
        assertEquals(0.0, lite.sourceY(12.0), 1e-9); assertEquals(1.0, lite.sourceY(372.0), 1e-9)
        // FULL 960×544 → gain 0.75, 2-pixel bars.
        val full = Letterbox(960, 544, 1280, 720)
        assertEquals(0.75, full.gain, 1e-9)
        assertEquals(960, full.scaledW); assertEquals(540, full.scaledH)
        assertEquals(0, full.padX); assertEquals(2, full.padY)
        // Input sizes per orientation / level, and the decoder un-letterboxing a FULL landscape box.
        assertEquals(960 to 544, YoloDetector.inputSize(true, DetectorQualityGovernor.Level.FULL))
        assertEquals(640 to 384, YoloDetector.inputSize(true, DetectorQualityGovernor.Level.LITE))
        assertEquals(544 to 960, YoloDetector.inputSize(false, DetectorQualityGovernor.Level.FULL))
        assertEquals(384 to 640, YoloDetector.inputSize(false, DetectorQualityGovernor.Level.LITE))
        val n = 100
        val v = FloatArray(84 * n)
        v[0 * n] = 480f; v[1 * n] = 272f; v[2 * n] = 96f; v[3 * n] = 54f; v[(4 + 2) * n] = 0.9f
        val d = YOLODecoder.decode(v, listOf(1, 84, n), 960.0, 544.0, 0.5, 0.45, sourceWidth = 1280.0, sourceHeight = 720.0).single()
        assertEquals(0.5, d.box.midX, 1e-6); assertEquals(0.5, d.box.midY, 1e-6)
        assertEquals(0.1, d.box.width, 1e-6); assertEquals(0.1, d.box.height, 1e-6)
        // The old square input for comparison: 44 % of it was padding.
        val square = Letterbox(640, 640, 1280, 720)
        assertEquals(140, square.padY)
    }

    @Test fun letterboxFillPadsAndCopies() {
        val w = 4; val h = 8
        val rgba = ByteArray(w * h * 4) { i -> if (i % 4 == 0) 255.toByte() else 0 }
        val buf = ByteBuffer.allocateDirect(3 * 16 * 16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        Letterbox(16, 16, w, h).fill(rgba, w * 4, buf, IntArray(16))
        assertEquals(114f / 255f, buf.get(0), 1e-6f)          // left padding
        assertEquals(1f, buf.get(8 * 16 + 8), 1e-6f)           // red plane inside
        assertEquals(0f, buf.get(256 + 8 * 16 + 8), 1e-6f)     // green plane inside
        // Rectangular input 16 wide × 8 high for an 8×4 frame: no padding at all, every pixel is copied.
        val wide = ByteArray(8 * 4 * 4) { i -> if (i % 4 == 1) 255.toByte() else 0 }
        val rect = ByteBuffer.allocateDirect(3 * 16 * 8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        Letterbox(16, 8, 8, 4).fill(wide, 8 * 4, rect, IntArray(16))
        assertEquals(3 * 16 * 8, rect.limit())
        assertEquals(0f, rect.get(0), 1e-6f)                   // red plane
        assertEquals(1f, rect.get(16 * 8), 1e-6f)              // green plane, first pixel
        assertEquals(1f, rect.get(2 * 16 * 8 - 1), 1e-6f)      // green plane, last pixel
    }

    @Test fun countdownFraction() {
        fun b(d: Double, step: Double?) = NavBanner(ManeuverType.RIGHT, d, "", null, step)
        assertNull(countdownFraction(b(500.0, 1000.0)))
        assertEquals(0.5f, countdownFraction(b(150.0, 1000.0))!!, 1e-6f)
        assertEquals(0.5f, countdownFraction(b(50.0, 100.0))!!, 1e-6f)
    }
}
