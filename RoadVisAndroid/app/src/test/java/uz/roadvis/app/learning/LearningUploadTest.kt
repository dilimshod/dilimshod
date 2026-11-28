package uz.roadvis.app.learning

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LearningUploadTest {
    @Test fun multipartHasImageAndMetaParts() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x00, 0xFF.toByte(), 0xD9.toByte())
        val meta = "{\"id\":\"abc\"}".toByteArray()
        val body = LearningUploader.multipart("B0", "abc", jpeg, meta)
        val text = String(body, Charsets.ISO_8859_1)
        assertTrue(text.startsWith("--B0\r\nContent-Disposition: form-data; name=\"image\"; filename=\"abc.jpg\"\r\n" +
            "Content-Type: image/jpeg\r\n\r\n"))
        assertTrue(text.contains("\r\n--B0\r\nContent-Disposition: form-data; name=\"meta\"\r\n" +
            "Content-Type: application/json\r\n\r\n{\"id\":\"abc\"}\r\n--B0--\r\n"))
        // The JPEG bytes are copied unchanged.
        val start = text.indexOf("\r\n\r\n") + 4
        assertEquals(String(jpeg, Charsets.ISO_8859_1), text.substring(start, start + jpeg.size))
        assertTrue(text.endsWith("--B0--\r\n"))
    }
}
