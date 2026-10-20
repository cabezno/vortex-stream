package com.vortex.vortexcam.studio.clip

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.vortex.vortexcam.studio.encoder.ProgramAudioEncoder
import com.vortex.vortexcam.studio.webrtc.WebRtcSourceSink
import io.flutter.view.TextureRegistry
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.GlRectDrawer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import java.nio.ByteOrder

/**
 * A video from the phone in the program — the intro clip (2026-10-20). While it is on, the program shows it instead of
 * the cameras and plays its sound instead of theirs; when it ends (or is skipped) it fades out in [FADE_MS] to the
 * cameras and their sound.
 *
 * Video: MediaPlayer (hardware decoder) into a SurfaceTexture of WebRTC's root EGL share group, so its frames are
 * ordinary texture VideoFrames: a [WebRtcSourceSink] keeps them for the compositor (GPU copy, as a camera), and an
 * EglRenderer draws them into a Flutter texture for the switcher's monitor.
 * Audio: decoded apart (MediaExtractor + MediaCodec) into a ring of the program audio, paced by the player's position
 * so it stays with the picture.
 *
 * [prepare] shows black and silence (the clip is "on" but has not started), [play] starts it — so the program can be
 * started in between and the recording/stream begins with the clip's first frame.
 */
class ClipPlayer(private val path: String, val fill: Boolean, private val textures: TextureRegistry,
                 private val onEnded: () -> Unit) {
    companion object {
        private const val TAG = "ClipPlayer"
        const val FADE_MS = 500L
        /** The clip in the program now (read by the compositor and the program audio); null = cameras. */
        @Volatile var current: ClipPlayer? = null
            private set
    }

    /** What the compositor draws. */
    val sink = WebRtcSourceSink()
    /** The clip's sound, mixed into the program by ProgramAudioEncoder. */
    val audio = ProgramAudioEncoder.Ring()

    var width = 0; private set
    var height = 0; private set
    var durationMs = 0L; private set
    var textureId = -1L; private set

    private val main = Handler(Looper.getMainLooper())
    private var helper: SurfaceTextureHelper? = null
    private var surface: Surface? = null
    private var player: MediaPlayer? = null
    private var monitor: EglRenderer? = null
    private var monitorEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var audioThread: Thread? = null
    @Volatile private var released = false
    @Volatile private var playing = false
    @Volatile private var fadeStartNs = 0L
    private var ended = false

    /** 1 = only the clip, 0 = only the cameras; in between during the final fade. */
    fun alpha(): Float {
        val f = fadeStartNs
        if (f == 0L) return 1f
        return (1f - (System.nanoTime() - f) / (FADE_MS * 1_000_000f)).coerceIn(0f, 1f)
    }

    /** Opens the clip and puts it (black, silent) in the program. Main thread. Throws when it cannot be played. */
    fun prepare() {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(path)
            val w = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rot = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            if (w <= 0 || h <= 0) throw IllegalArgumentException("el archivo no tiene video")
            // The SurfaceTexture's matrix already turns the picture upright: the frame has the upright size.
            if (rot % 180 != 0) { width = h; height = w } else { width = w; height = h }
            Log.i(TAG, "Clip ${w}x$h rot $rot → ${width}x$height, ${durationMs} ms: $path")
        } finally {
            try { mmr.release() } catch (_: Exception) {}
        }
        val root = com.cloudwebrtc.webrtc.utils.EglUtils.getRootEglBaseContext()
        val hp = SurfaceTextureHelper.create("ClipPlayer", root)
            ?: throw IllegalStateException("sin contexto de video")
        helper = hp
        hp.setTextureSize(width, height)
        // The switcher's monitor: a Flutter texture, at most ~960 px wide.
        try {
            val entry = textures.createSurfaceTexture()
            val scale = minOf(1f, 960f / maxOf(width, height))
            entry.surfaceTexture().setDefaultBufferSize((width * scale).toInt().coerceAtLeast(2), (height * scale).toInt().coerceAtLeast(2))
            val r = EglRenderer("ClipMonitor")
            r.init(root, EglBase.CONFIG_PLAIN, GlRectDrawer())
            r.createEglSurface(entry.surfaceTexture())
            monitorEntry = entry; monitor = r; textureId = entry.id()
        } catch (e: Exception) {
            Log.w(TAG, "No monitor texture: ${e.message}")
        }
        hp.startListening { frame -> onFrame(frame) }
        val s = Surface(hp.surfaceTexture)
        surface = s
        val mp = MediaPlayer()
        player = mp
        mp.setDataSource(path)
        mp.setSurface(s)
        mp.setVolume(0f, 0f)                                   // its sound goes to the program, not the speaker
        mp.setOnCompletionListener { end() }
        mp.setOnErrorListener { _, what, extra -> Log.w(TAG, "MediaPlayer error $what/$extra"); end(); true }
        mp.prepare()
        current = this
    }

    /** Starts the clip (the program shows it from its first frame). */
    fun play() {
        if (released || playing) return
        val mp = player ?: return
        playing = true
        try { mp.start() } catch (e: Exception) { Log.w(TAG, "start: ${e.message}"); end(); return }
        audioThread = Thread({ decodeAudio() }, "ClipAudio").apply { start() }
    }

    /** Ends the clip now (it finished, or «Saltar»): fade to the cameras, then free everything. */
    fun end() {
        main.post {
            if (ended || released) return@post
            ended = true
            fadeStartNs = System.nanoTime()
            try { player?.pause() } catch (_: Exception) {}
            onEnded()
            main.postDelayed({ release() }, FADE_MS + 100)
        }
    }

    /** Takes it out of the program at once and frees it (the program stopped). Main thread. */
    fun release() {
        if (released) return
        released = true
        if (current === this) current = null
        try { audioThread?.interrupt() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null
        val hp = helper
        helper = null
        try { hp?.stopListening() } catch (_: Exception) {}
        try { monitor?.release() } catch (_: Exception) {}
        monitor = null
        try { surface?.release() } catch (_: Exception) {}
        try { hp?.dispose() } catch (_: Exception) {}
        try { monitorEntry?.release() } catch (_: Exception) {}
        monitorEntry = null
        sink.release()
        if (!ended) { ended = true; onEnded() }
    }

    // Helper thread (its EGL context is current: the sink makes its GPU copy here).
    private fun onFrame(frame: VideoFrame) {
        if (released) return
        // Stamped on arrival: the player's own timestamps are not on the system clock the sink paces by.
        frame.buffer.retain()
        val f = VideoFrame(frame.buffer, 0, System.nanoTime())
        try {
            sink.onFrame(f)
            monitor?.onFrame(f)
        } finally {
            f.release()
        }
    }

    // ── Audio ────────────────────────────────────────────────────────────────────────────────────────────────────

    private fun decodeAudio() {
        val ex = MediaExtractor()
        var dec: MediaCodec? = null
        try {
            ex.setDataSource(path)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: run { Log.i(TAG, "Clip without sound"); return }
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val c = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            dec = c
            c.configure(fmt, null, null, 0)
            c.start()
            var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            val info = MediaCodec.BufferInfo()
            val res = Resampler()
            var inputDone = false
            while (!released && !Thread.currentThread().isInterrupted) {
                if (!inputDone) {
                    val i = c.dequeueInputBuffer(5_000)
                    if (i >= 0) {
                        val n = ex.readSampleData(c.getInputBuffer(i)!!, 0)
                        if (n < 0) { c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { c.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = c.dequeueOutputBuffer(info, 5_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = c.outputFormat
                    rate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    ch = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    isFloat = of.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (o >= 0) {
                    // Paced by the picture: no further ahead than the player's position + a little.
                    val ptsMs = info.presentationTimeUs / 1000
                    while (!released && playing && ptsMs > position() + 30) Thread.sleep(5)
                    val buf = c.getOutputBuffer(o)
                    if (buf != null && info.size > 0 && !released && fadeStartNs == 0L) {
                        buf.position(info.offset); buf.limit(info.offset + info.size)
                        val b = buf.slice().order(ByteOrder.nativeOrder())
                        if (isFloat) {
                            val fb = b.asFloatBuffer()
                            res.push(fb.remaining() / ch, ch, rate) { i, c2 -> fb.get(i * ch + c2) }
                        } else {
                            val sb = b.asShortBuffer()
                            res.push(sb.remaining() / ch, ch, rate) { i, c2 -> sb.get(i * ch + c2) / 32768f }
                        }
                    }
                    c.releaseOutputBuffer(o, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
                }
            }
        } catch (_: InterruptedException) {
        } catch (e: Exception) {
            Log.w(TAG, "Clip audio: ${e.message}")
        } finally {
            try { dec?.stop() } catch (_: Exception) {}
            try { dec?.release() } catch (_: Exception) {}
            try { ex.release() } catch (_: Exception) {}
        }
    }

    private fun position(): Long = try { player?.currentPosition?.toLong() ?: Long.MAX_VALUE } catch (_: Exception) { Long.MAX_VALUE }

    /** Linear resampling to the program's 48 kHz stereo, into [audio]. */
    private inner class Resampler {
        private var pos = 0.0
        private var lastL = 0f; private var lastR = 0f
        fun push(frames: Int, ch: Int, rate: Int, sample: (Int, Int) -> Float) {
            if (frames <= 0 || ch < 1 || rate <= 0) return
            fun l(i: Int) = sample(i, 0)
            fun r(i: Int) = if (ch > 1) sample(i, 1) else sample(i, 0)
            if (rate == ProgramAudioEncoder.SAMPLE_RATE) {
                for (i in 0 until frames) audio.write(l(i), r(i))
            } else {
                val step = rate.toDouble() / ProgramAudioEncoder.SAMPLE_RATE
                var p = pos
                while (p < frames) {
                    val i = p.toInt(); val f = (p - i).toFloat()
                    val l0 = if (i == 0) lastL else l(i - 1); val r0 = if (i == 0) lastR else r(i - 1)
                    audio.write(l0 + (l(i) - l0) * f, r0 + (r(i) - r0) * f)
                    p += step
                }
                pos = p - frames
            }
            lastL = l(frames - 1); lastR = r(frames - 1)
        }
    }
}
