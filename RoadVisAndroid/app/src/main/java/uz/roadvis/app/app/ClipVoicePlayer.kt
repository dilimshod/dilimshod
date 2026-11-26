package uz.roadvis.app.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.PlaybackParams
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * Plays pre-generated natural voice clips (assets/voice/<lang>_<id>.m4a|mp3, Microsoft Edge neural voices
 * generated on the developer's Mac with tools/generate_voice_clips.py) back to back without gaps:
 * every clip is decoded to 16-bit mono PCM, leading/trailing silence (< −40 dB) is trimmed, the clips are
 * concatenated and played with one AudioTrack at [rate] (1.1×). Port of iOS `ClipVoicePlayer`.
 */
class ClipVoicePlayer(private val context: Context) {
    private data class Pcm(val samples: ShortArray, val sampleRate: Int)

    private val executor = Executors.newSingleThreadExecutor()
    private val cache = HashMap<String, Pcm?>()
    private val available: Set<String> by lazy {
        (context.assets.list("voice") ?: emptyArray()).toSet()
    }
    @Volatile private var track: AudioTrack? = null
    @Volatile private var generation = 0
    @Volatile var isPlaying = false
        private set
    var rate: Float = 1.1f
    var onFinished: (() -> Unit)? = null

    /** Asset file name for a clip id, or null when not installed. */
    fun fileFor(name: String): String? = when {
        "$name.m4a" in available -> "$name.m4a"
        "$name.mp3" in available -> "$name.mp3"
        else -> null
    }

    fun hasAll(names: List<String>): Boolean = names.isNotEmpty() && names.all { fileFor(it) != null }

    fun installedCount(prefix: String): Int = available.count { it.startsWith(prefix) }

    /** Plays the named clips gaplessly. Returns false when any clip is missing (caller falls back to TTS). */
    fun play(names: List<String>, interrupt: Boolean = true): Boolean {
        if (!hasAll(names)) return false
        if (interrupt) stop()
        val gen = ++generation
        isPlaying = true
        executor.execute {
            val parts = names.mapNotNull { pcm(it) }
            if (gen != generation || parts.isEmpty()) { finish(gen); return@execute }
            val sr = parts.first().sampleRate
            val total = parts.sumOf { it.samples.size }
            val all = ShortArray(total)
            var off = 0
            for (p in parts) { System.arraycopy(p.samples, 0, all, off, p.samples.size); off += p.samples.size }
            // AudioTrack errors (e.g. an empty decode → zero buffer size) must not kill the process from this thread.
            try { playPcm(all, sr, gen) } catch (_: Exception) { track = null; finish(gen) }
        }
        return true
    }

    fun stop() {
        generation++
        track?.let { runCatching { it.pause(); it.flush(); it.release() } }
        track = null
        isPlaying = false
    }

    private fun finish(gen: Int) {
        if (gen != generation) return
        isPlaying = false
        onFinished?.invoke()
    }

    private fun playPcm(samples: ShortArray, sampleRate: Int, gen: Int) {
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        if (gen != generation) { t.release(); return }
        track = t
        t.write(samples, 0, samples.size)
        runCatching { t.playbackParams = PlaybackParams().setSpeed(rate).setPitch(1f) }
        t.notificationMarkerPosition = samples.size - 1
        t.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
            override fun onMarkerReached(track: AudioTrack?) {
                runCatching { track?.release() }
                if (this@ClipVoicePlayer.track === track) this@ClipVoicePlayer.track = null
                finish(gen)
            }
            override fun onPeriodicNotification(track: AudioTrack?) {}
        }, android.os.Handler(android.os.Looper.getMainLooper()))
        t.play()
    }

    private fun pcm(name: String): Pcm? = synchronized(cache) {
        cache.getOrPut(name) { fileFor(name)?.let { decode("voice/$it") }?.let { trim(it) } }
    }

    /** Removes leading / trailing audio below −40 dBFS, keeping 30 ms. */
    private fun trim(p: Pcm): Pcm {
        val threshold = (32767 * 0.01).toInt()
        val s = p.samples
        var a = 0; var b = s.size - 1
        while (a < s.size && abs(s[a].toInt()) < threshold) a++
        while (b > a && abs(s[b].toInt()) < threshold) b--
        if (a >= b) return p
        val keep = p.sampleRate * 30 / 1000
        a = maxOf(0, a - keep); b = minOf(s.size - 1, b + keep)
        return Pcm(s.copyOfRange(a, b + 1), p.sampleRate)
    }

    private fun decode(asset: String): Pcm? = runCatching {
        val afd = context.assets.openFd(asset)
        val ex = MediaExtractor()
        ex.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
        afd.close()
        val track = (0 until ex.trackCount).first {
            ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        }
        ex.selectTrack(track)
        val fmt = ex.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(fmt, null, null, 0)
        codec.start()
        var sampleRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val out = java.io.ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var inputDone = false; var outputDone = false
        while (!outputDone) {
            if (!inputDone) {
                val i = codec.dequeueInputBuffer(10_000)
                if (i >= 0) {
                    val buf = codec.getInputBuffer(i)!!
                    val n = ex.readSampleData(buf, 0)
                    if (n < 0) {
                        codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true
                    } else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                }
            }
            val o = codec.dequeueOutputBuffer(info, 10_000)
            if (o >= 0) {
                val buf = codec.getOutputBuffer(o)!!
                val bytes = ByteArray(info.size)
                buf.position(info.offset); buf.get(bytes)
                out.write(bytes)
                codec.releaseOutputBuffer(o, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
            } else if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            }
        }
        codec.stop(); codec.release(); ex.release()
        val bb = java.nio.ByteBuffer.wrap(out.toByteArray()).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val inter = ShortArray(bb.remaining()); bb.get(inter)
        val mono = if (channels <= 1) inter else ShortArray(inter.size / channels) { f ->
            var sum = 0
            for (c in 0 until channels) sum += inter[f * channels + c]
            (sum / channels).toShort()
        }
        Pcm(mono, sampleRate)
    }.getOrNull()
}
