package uz.roadvis.app.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uz.roadvis.app.app.NavBanner
import uz.roadvis.app.detection.Letterbox
import uz.roadvis.core.BBox
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
        val lb = Letterbox(640, 720, 1280)
        assertEquals(0.5, lb.gain, 1e-9)
        assertEquals(360, lb.scaledW); assertEquals(640, lb.scaledH)
        assertEquals(140, lb.padX); assertEquals(0, lb.padY)
        // A box in input pixels maps back through the core decoder to the same source region.
        val n = 100
        val v = FloatArray(84 * n)   // channel-major [1, 84, N]; only anchor 0 is scored
        v[0 * n] = 320f; v[1 * n] = 320f; v[2 * n] = 180f; v[3 * n] = 320f; v[(4 + 2) * n] = 0.9f
        val d = YOLODecoder.decode(v, listOf(1, 84, n), 640.0, 640.0, 0.5, 0.45, sourceWidth = 720.0, sourceHeight = 1280.0).single()
        assertEquals(0.25, d.box.x, 1e-6); assertEquals(0.25, d.box.y, 1e-6)
        assertEquals(0.5, d.box.width, 1e-6); assertEquals(0.5, d.box.height, 1e-6)
        assertEquals(0.25, lb.sourceX(230.0), 1e-6)
    }

    @Test fun letterboxFillPadsAndCopies() {
        val w = 4; val h = 8
        val rgba = ByteArray(w * h * 4) { i -> if (i % 4 == 0) 255.toByte() else 0 }
        val buf = ByteBuffer.allocateDirect(3 * 16 * 16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        Letterbox(16, w, h).fill(rgba, w * 4, buf, IntArray(16))
        assertEquals(114f / 255f, buf.get(0), 1e-6f)          // left padding
        assertEquals(1f, buf.get(8 * 16 + 8), 1e-6f)           // red plane inside
        assertEquals(0f, buf.get(256 + 8 * 16 + 8), 1e-6f)     // green plane inside
    }

    @Test fun countdownFraction() {
        fun b(d: Double, step: Double?) = NavBanner(ManeuverType.RIGHT, d, "", null, step)
        assertNull(countdownFraction(b(500.0, 1000.0)))
        assertEquals(0.5f, countdownFraction(b(150.0, 1000.0))!!, 1e-6f)
        assertEquals(0.5f, countdownFraction(b(50.0, 100.0))!!, 1e-6f)
    }
}
