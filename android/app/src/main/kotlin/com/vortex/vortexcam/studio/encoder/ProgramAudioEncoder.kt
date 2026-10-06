package com.vortex.vortexcam.studio.encoder

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Log
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The program's audio → AAC-LC 48 kHz stereo, for RTMP and the recording.
 *
 * Sources, mixed:
 *  - the ON-AIR CAMERA's audio (WebRTC remote track, read with AudioTrackSink) — "audio follows video", the default:
 *    the sound of whoever is on screen. On a cut the new camera fades in (20 ms) so there is no click;
 *  - the switcher's own microphone (optional, for a presenter next to the switcher).
 * Every source lands in its own ring buffer; a clock thread takes 1024 frames every 21.3 ms of SYSTEM time, so the
 * timestamps follow the same clock as the video (`clockStartNano`) and never drift, whatever each source's own clock
 * does (rings that fill up are trimmed, empty ones give silence).
 *
 * 2026-10-04. Before, the switcher's output had no audio at all; the first version (MicAacEncoder) only had the mic.
 */
class ProgramAudioEncoder(
    private val clockStartNano: Long,
    private val listener: Listener,
    useMic: Boolean,
    useCamera: Boolean,
) {
    interface Listener {
        fun onAudioFormat(format: MediaFormat, asc: ByteArray)
        fun onAudioData(data: ByteBuffer, info: MediaCodec.BufferInfo)
    }

    companion object {
        private const val TAG = "ProgramAudio"
        const val SAMPLE_RATE = 48_000
        const val CHANNELS = 2
        const val BITRATE = 160_000
        private const val FRAME = 1024                                    // AAC frame
        private const val PREBUFFER = SAMPLE_RATE * 40 / 1000             // start reading a ring at 40 ms
        private const val MAX_LEVEL = SAMPLE_RATE * 250 / 1000            // > 250 ms queued → trim to PREBUFFER
    }

    /**
     * Stereo float ring, written by one source thread and read by the clock thread. [delayFrames] holds the source
     * back (alignment with slower cameras, 2026-10-06): reading starts once that much more is queued, and the trim
     * keeps it — the level settles around PREBUFFER + delay.
     */
    private class Ring {
        private val buf = FloatArray(SAMPLE_RATE * CHANNELS)              // 1 s
        private var w = 0; private var r = 0; private var level = 0       // level in frames
        private var primed = false
        var fadeIn = 0                                                   // frames of fade-in left (after a cut)
        @Volatile var delayFrames = 0
        @Synchronized fun write(l: Float, rr: Float) {
            if (level >= buf.size / CHANNELS) { r = (r + CHANNELS) % buf.size; level-- }
            buf[w] = l; buf[w + 1] = rr; w = (w + CHANNELS) % buf.size; level++
        }
        /** Adds `frames` frames × gain into out (stereo interleaved); silence while not primed / empty. */
        @Synchronized fun mixInto(out: FloatArray, frames: Int, gain: Float) {
            val base = PREBUFFER + delayFrames
            if (!primed) { if (level >= base) primed = true else return }
            if (level > MAX_LEVEL + delayFrames) { val drop = level - base; r = (r + drop * CHANNELS) % buf.size; level -= drop }
            val n = minOf(frames, level)
            for (i in 0 until n) {
                var g = gain
                if (fadeIn > 0) { g *= 1f - fadeIn / 960f; fadeIn-- }
                out[i * 2] += buf[r] * g; out[i * 2 + 1] += buf[r + 1] * g
                r = (r + CHANNELS) % buf.size
            }
            level -= n
            if (level == 0) primed = false                                // underrun: rebuild the cushion
        }
    }

    /**
     * A «Solo micrófono» phone (a presenter's dedicated microphone, 2026-10-06): ALWAYS in the mix, whatever camera
     * is on air — its own ring, resampler and alignment delay.
     */
    private inner class TrackInput(val track: AudioTrack) : AudioTrackSink {
        val ring = Ring()
        private var pos = 0.0; private var lastL = 0f; private var lastR = 0f
        override fun onData(data: ByteBuffer, bits: Int, rate: Int, ch: Int, frames: Int, absTimeMs: Long) {
            if (bits != 16 || ch < 1 || rate <= 0) return
            val s = data.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
            if (rate == SAMPLE_RATE) {
                for (i in 0 until frames) {
                    val l = s.get(i * ch) / 32768f
                    ring.write(l, if (ch > 1) s.get(i * ch + 1) / 32768f else l)
                }
                return
            }
            val step = rate.toDouble() / SAMPLE_RATE
            var p = pos
            while (p < frames) {
                val i = p.toInt(); val f = (p - i).toFloat()
                val l1 = s.get(i * ch) / 32768f; val r1 = if (ch > 1) s.get(i * ch + 1) / 32768f else l1
                val l0 = if (i == 0) lastL else s.get((i - 1) * ch) / 32768f
                val r0 = if (i == 0) lastR else (if (ch > 1) s.get((i - 1) * ch + 1) / 32768f else l0)
                ring.write(l0 + (l1 - l0) * f, r0 + (r1 - r0) * f)
                p += step
            }
            pos = p - frames
            lastL = s.get((frames - 1) * ch) / 32768f
            lastR = if (ch > 1) s.get((frames - 1) * ch + 1) / 32768f else lastL
        }
    }
    private val micTracks = java.util.concurrent.CopyOnWriteArrayList<TrackInput>()

    /** The «Solo micrófono» phones' tracks with their alignment delays; others are dropped. */
    fun setMicTracks(tracks: List<Pair<AudioTrack, Int>>) {
        for (m in micTracks) if (tracks.none { it.first === m.track }) {
            try { m.track.removeSink(m) } catch (_: Exception) {}
            micTracks.remove(m)
        }
        for ((t, d) in tracks) {
            val m = micTracks.firstOrNull { it.track === t } ?: TrackInput(t).also {
                try { t.addSink(it); micTracks.add(it) } catch (e: Exception) { Log.w(TAG, "mic track addSink: ${e.message}") }
            }
            m.ring.delayFrames = framesOf(d)
        }
        Log.i(TAG, "Mic-only phones in the mix: ${micTracks.size}")
    }

    @Volatile var useMic = useMic
        private set
    @Volatile var useCamera = useCamera
        private set
    private val micRing = Ring()
    @Volatile private var camRing = Ring()
    private var camTrack: AudioTrack? = null
    private val camSink = AudioTrackSink { data, bits, rate, ch, frames, _ -> onCameraAudio(data, bits, rate, ch, frames) }

    private var record: AudioRecord? = null
    private var micThread: Thread? = null
    private var codec: MediaCodec? = null
    private var clockThread: Thread? = null
    private val running = AtomicBoolean(false)
    private val micRunning = AtomicBoolean(false)

    // Resampling state for a camera that is not at 48 kHz (Opus decodes at 48 kHz, so normally a straight copy).
    private var resPos = 0.0
    private var lastL = 0f; private var lastR = 0f

    fun start(): Boolean {
        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, CHANNELS).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, FRAME * CHANNELS * 2 * 4)
        }
        codec = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).also {
                it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); it.start()
            }
        } catch (e: Exception) { Log.w(TAG, "AAC encoder failed: ${e.message}"); return false }
        running.set(true)
        if (useMic) startMic()
        clockThread = Thread({ clockLoop(codec!!) }, "ProgramAudioClock").apply { priority = Thread.MAX_PRIORITY; start() }
        Log.i(TAG, "Program audio: AAC-LC ${SAMPLE_RATE} Hz stereo ${BITRATE / 1000} kbps — on-air camera=$useCamera, mic=${micRunning.get()}")
        return true
    }

    fun setSources(mic: Boolean, camera: Boolean) {
        useCamera = camera
        if (mic && !micRunning.get() && running.get()) startMic()
        if (!mic && micRunning.get()) stopMic()
        useMic = mic
        Log.i(TAG, "Sources: on-air camera=$camera, mic=$mic")
    }

    val micActive: Boolean get() = micRunning.get()

    private fun framesOf(ms: Int) = (ms.coerceIn(0, 500) * SAMPLE_RATE / 1000)
    fun setCameraDelay(ms: Int) { camRing.delayFrames = framesOf(ms) }
    fun setMicDelay(ms: Int) { micRing.delayFrames = framesOf(ms) }

    /** The on-air camera's audio track (null = none). A new track starts with a fresh ring and a 20 ms fade-in. */
    @Synchronized fun setCameraTrack(track: AudioTrack?, delayMs: Int = 0) {
        if (track === camTrack) { setCameraDelay(delayMs); return }
        try { camTrack?.removeSink(camSink) } catch (_: Exception) {}
        camRing = Ring().also { it.fadeIn = 960; it.delayFrames = framesOf(delayMs) }
        resPos = 0.0
        camTrack = track
        try { track?.addSink(camSink) } catch (e: Exception) { Log.w(TAG, "addSink: ${e.message}") }
        Log.i(TAG, "On-air camera audio: ${track?.id() ?: "none"}")
    }

    private fun onCameraAudio(data: ByteBuffer, bits: Int, rate: Int, ch: Int, frames: Int) {
        if (!useCamera || bits != 16 || ch < 1 || rate <= 0) return
        val s = data.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
        val ring = camRing
        val step = rate.toDouble() / SAMPLE_RATE
        if (rate == SAMPLE_RATE) {
            for (i in 0 until frames) {
                val l = s.get(i * ch) / 32768f
                val r = if (ch > 1) s.get(i * ch + 1) / 32768f else l
                ring.write(l, r)
            }
        } else {                                                          // linear resampling to 48 kHz
            var pos = resPos
            while (pos < frames) {
                val i = pos.toInt(); val f = (pos - i).toFloat()
                val l1 = s.get(i * ch) / 32768f; val r1 = if (ch > 1) s.get(i * ch + 1) / 32768f else l1
                val l0 = if (i == 0) lastL else s.get((i - 1) * ch) / 32768f
                val r0 = if (i == 0) lastR else (if (ch > 1) s.get((i - 1) * ch + 1) / 32768f else l0)
                ring.write(l0 + (l1 - l0) * f, r0 + (r1 - r0) * f)
                pos += step
            }
            resPos = pos - frames
            lastL = s.get((frames - 1) * ch) / 32768f
            lastR = if (ch > 1) s.get((frames - 1) * ch + 1) / 32768f else lastL
        }
    }

    // ── Microphone ───────────────────────────────────────────────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun startMic() {
        // CAMCORDER = the source tuned for video (stereo where the phone has two mics); MIC = universal fallback.
        var rec: AudioRecord? = null; var chans = 1
        for ((src, ch) in listOf(MediaRecorder.AudioSource.CAMCORDER to 2, MediaRecorder.AudioSource.MIC to 1)) {
            val mask = if (ch == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
            val min = AudioRecord.getMinBufferSize(SAMPLE_RATE, mask, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val r = try { AudioRecord(src, SAMPLE_RATE, mask, AudioFormat.ENCODING_PCM_16BIT, maxOf(min * 4, 48_000)) }
                    catch (e: Exception) { Log.w(TAG, "AudioRecord src=$src: ${e.message}"); null }
            if (r != null && r.state == AudioRecord.STATE_INITIALIZED) { rec = r; chans = ch; break }
            r?.release()
        }
        if (rec == null) { Log.w(TAG, "No microphone (permission denied / busy)"); return }
        try { rec.startRecording() } catch (e: Exception) { Log.w(TAG, "startRecording: ${e.message}"); rec.release(); return }
        record = rec
        micRunning.set(true)
        val ch = chans
        micThread = Thread({
            val pcm = ShortArray(480 * ch)
            while (micRunning.get()) {
                val n = rec.read(pcm, 0, pcm.size)
                if (n <= 0) continue
                var i = 0
                while (i + ch <= n) {
                    val l = pcm[i] / 32768f
                    micRing.write(l, if (ch > 1) pcm[i + 1] / 32768f else l)
                    i += ch
                }
            }
        }, "ProgramAudioMic").apply { start() }
        Log.i(TAG, "Mic on (${if (ch == 2) "stereo" else "mono"})")
    }

    private fun stopMic() {
        micRunning.set(false)
        try { record?.stop() } catch (_: Exception) {}
        try { micThread?.join(300) } catch (_: InterruptedException) {}
        try { record?.release() } catch (_: Exception) {}
        record = null; micThread = null
    }

    // ── Clock + encoder ──────────────────────────────────────────────────────────────────────────────────────────

    private fun clockLoop(c: MediaCodec) {
        val mix = FloatArray(FRAME * CHANNELS)
        val pcm = ByteArray(FRAME * CHANNELS * 2)
        val info = MediaCodec.BufferInfo()
        val t0 = System.nanoTime()
        val firstPtsUs = (t0 - clockStartNano) / 1000
        var n = 0L
        while (running.get()) {
            val due = t0 + n * FRAME * 1_000_000_000L / SAMPLE_RATE
            val wait = due - System.nanoTime()
            if (wait > 0) try { Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt()) } catch (_: InterruptedException) { break }
            java.util.Arrays.fill(mix, 0f)
            if (useCamera) camRing.mixInto(mix, FRAME, 1f)
            if (useMic && micRunning.get()) micRing.mixInto(mix, FRAME, 1f)
            for (m in micTracks) m.ring.mixInto(mix, FRAME, 1f)
            for (i in mix.indices) {
                val v = (mix[i].coerceIn(-1f, 1f) * 32767f).toInt()
                pcm[i * 2] = v.toByte(); pcm[i * 2 + 1] = (v shr 8).toByte()
            }
            val pts = firstPtsUs + n * FRAME * 1_000_000L / SAMPLE_RATE
            n++
            try {
                val idx = c.dequeueInputBuffer(10_000)
                if (idx >= 0) {
                    val ib = c.getInputBuffer(idx)!!
                    ib.clear(); ib.put(pcm)
                    c.queueInputBuffer(idx, 0, pcm.size, pts, 0)
                }
                drain(c, info)
            } catch (e: Exception) { if (running.get()) Log.w(TAG, "encode: ${e.message}") }
        }
    }

    private fun drain(c: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val idx = c.dequeueOutputBuffer(info, 0)
            when {
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    val csd = f.getByteBuffer("csd-0")
                    val asc = if (csd != null) ByteArray(csd.remaining()).also { csd.duplicate().get(it) } else ByteArray(0)
                    listener.onAudioFormat(f, asc)
                }
                idx >= 0 -> {
                    val buf = c.getOutputBuffer(idx)
                    if (buf != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0)
                        listener.onAudioData(buf, info)
                    c.releaseOutputBuffer(idx, false)
                }
                else -> return
            }
        }
    }

    fun stop() {
        running.set(false)
        setCameraTrack(null)
        setMicTracks(emptyList())
        stopMic()
        try { clockThread?.join(500) } catch (_: InterruptedException) {}
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null; clockThread = null
    }
}
