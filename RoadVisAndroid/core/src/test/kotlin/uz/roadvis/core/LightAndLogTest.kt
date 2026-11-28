package uz.roadvis.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

class LightAndLogTest {
    @Test fun trafficLightColors() {
        val dark = List(80) { RGBPixel(20, 20, 20) }
        val red = List(20) { RGBPixel(250, 40, 30) }
        val green = List(20) { RGBPixel(40, 240, 160) }
        val yellow = List(20) { RGBPixel(250, 190, 30) }
        assertEquals(TrafficLightColor.RED, TrafficLightColorClassifier.classify(dark + red))
        assertEquals(TrafficLightColor.GREEN, TrafficLightColorClassifier.classify(dark + green))
        assertEquals(TrafficLightColor.YELLOW, TrafficLightColorClassifier.classify(dark + yellow))
        assertEquals(TrafficLightColor.UNKNOWN, TrafficLightColorClassifier.classify(dark))
    }

    @Test fun bgraSampling() {
        val w = 10; val h = 10
        val buf = ByteArray(w * h * 4)
        for (y in 0 until 3) for (x in 0 until w) {
            val i = (y * w + x) * 4
            buf[i] = 30; buf[i + 1] = 40; buf[i + 2] = 250.toByte(); buf[i + 3] = 255.toByte()
        }
        val color = TrafficLightColorClassifier.classifyBGRA(buf, w, h, w * 4, 0, 0, w, h, step = 1)
        assertEquals(TrafficLightColor.RED, color)
    }

    @Test fun experimentLogCSV() {
        val log = ExperimentLog("yolo11n", 0L)
        log.markFrame()
        log.append(ExperimentRecord(timestampMillis = 1000L, frameIndex = 1, trackID = 3, kind = VehicleKind.CAR,
            label = "car", confidence = 0.91, box = BBox(0.1, 0.2, 0.3, 0.2), make = "Chevrolet, Inc", makeConfidence = 0.5))
        log.append(ExperimentRecord(timestampMillis = 1000L, frameIndex = 1, kind = VehicleKind.BUS,
            label = "bus", confidence = 0.6, box = BBox(0.5, 0.2, 0.3, 0.4)))
        val csv = log.detectionsCSV()
        val lines = csv.split("\n").filter { it.isNotEmpty() }
        assertEquals(3, lines.size)
        assertTrue(lines[1].contains("\"Chevrolet, Inc\""))
        assertTrue(lines[1].startsWith("1970-01-01T00:00:01.000Z,1,3,car,car,0.910"))
        val summary = log.summaryCSV(mapOf(VehicleKind.CAR to 1, VehicleKind.BUS to 1), 60_000L)
        assertTrue(summary.contains("car,1,1,1,1,0.910"))
        assertTrue(summary.contains("vehicles_total,2,2,1,2,"))
        val dir = File(System.getProperty("java.io.tmpdir"), "rvtest-${UUID.randomUUID()}")
        val files = log.writeFiles(dir, mapOf(VehicleKind.CAR to 1), 60_000L)
        assertEquals(2, files.size)
        assertTrue(files[0].exists())
        dir.deleteRecursively()
    }
}
