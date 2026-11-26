package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Test

class YOLODecoderTest {
    @Test fun channelsFirstWithNMS() {
        val n = 10; val c = 7
        val v = FloatArray(c * n)
        fun set(ch: Int, i: Int, x: Float) { v[ch * n + i] = x }
        set(0, 0, 320f); set(1, 0, 320f); set(2, 0, 100f); set(3, 0, 50f); set(6, 0, 0.9f)
        set(0, 1, 322f); set(1, 1, 321f); set(2, 1, 100f); set(3, 1, 50f); set(6, 1, 0.8f)
        set(0, 2, 100f); set(1, 2, 100f); set(2, 2, 40f); set(3, 2, 80f); set(4, 2, 0.5f)
        set(0, 3, 500f); set(1, 3, 500f); set(2, 3, 10f); set(3, 3, 10f); set(5, 3, 0.1f)
        val d = YOLODecoder.decode(v, listOf(1, c, n), 640.0, 640.0, confidenceThreshold = 0.25, iouThreshold = 0.45)
        assertEquals(2, d.size)
        assertEquals(2, d[0].classIndex)
        assertEquals((320 - 50) / 640.0, d[0].box.x, 1e-6)
        assertEquals(100 / 640.0, d[0].box.width, 1e-6)
        assertEquals(0, d[1].classIndex)
    }

    @Test fun endToEndLayout() {
        val v = FloatArray(300 * 6)
        v[0] = 64f; v[1] = 64f; v[2] = 192f; v[3] = 128f; v[4] = 0.8f; v[5] = 7f
        v[6] = 0f; v[7] = 0f; v[8] = 10f; v[9] = 10f; v[10] = 0.1f; v[11] = 2f
        val d = YOLODecoder.decode(v, listOf(1, 300, 6), 640.0, 640.0, confidenceThreshold = 0.25, iouThreshold = 0.45)
        assertEquals(1, d.size)
        assertEquals(7, d[0].classIndex)
        assertEquals(VehicleKind.TRUCK, VehicleKind.fromCocoIndex(d[0].classIndex))
        assertEquals(64 / 640.0, d[0].box.height, 1e-6)
    }

    @Test fun letterboxUndo() {
        val v = FloatArray(300 * 6)
        v[0] = 0f; v[1] = 140f; v[2] = 640f; v[3] = 500f; v[4] = 0.9f; v[5] = 2f
        val d = YOLODecoder.decode(v, listOf(1, 300, 6), 640.0, 640.0, confidenceThreshold = 0.25, iouThreshold = 0.45,
            sourceWidth = 1920.0, sourceHeight = 1080.0)
        assertEquals(1, d.size)
        assertEquals(0.0, d[0].box.x, 1e-6)
        assertEquals(0.0, d[0].box.y, 1e-6)
        assertEquals(1.0, d[0].box.width, 1e-6)
        assertEquals(1.0, d[0].box.height, 1e-6)
    }

    @Test fun coco() {
        assertEquals(80, COCOLabels.names.size)
        assertEquals("traffic light", COCOLabels.names[9])
        assertEquals(VehicleKind.BUS, VehicleKind.fromLabel(COCOLabels.name(5)))
    }
}
