package com.vortex.vortexcam.studio.encoder

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * The switcher's own microphone → AAC-LC, for the program (RTMP + recording). Until 2026-10-04 the switcher's output
 * had no audio at all, so it could not go to a platform.
 *
 * Timestamps share the video's clock (`clockStartNano`, the same origin HardwareProgramEncoder gives the encoder
 * surface), counted from samples so they are continuous; if the mic clock drifts more than 80 ms from the system clock
 * the anchor is moved (no gap/overlap builds up over a long stream).
 */
class MicAacEncoder(
    private val clockStartNano: Long,
    private val listener: Listener,
    val sampleRate: Int = 48_000,
    val bitrate: Int = 128_000,
) {
    interface Listener {
        fun onAudioFormat(format: MediaFormat, asc: ByteArray)
        fun onAudioData(data: ByteBuffer, info: MediaCodec.BufferInfo)
    }

    companion object { private const val TAG = "MicAacEncoder" }

    var channels = 1
        private set
    private var record: AudioRecord? = null
    private var codec: MediaCodec? = null
    private val running = AtomicBoolean(false)
    private var thread: Thread? = null

    /** false = no mic (permission denied / busy): the program goes on without audio. */
    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        // CAMCORDER is the source tuned for video (stereo where the phone has two mics, light processing); MIC is the
        // universal fallback.
        for ((src, ch) in listOf(MediaRecorder.AudioSource.CAMCORDER to 2, MediaRecorder.AudioSource.MIC to 1)) {
            val mask = if (ch == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
            val min = AudioRecord.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val r = try { AudioRecord(src, sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT, maxOf(min * 4, 1024 * ch * 2 * 8)) }
                    catch (e: Exception) { Log.w(TAG, "AudioRecord src=$src ch=$ch: ${e.message}"); null }
            if (r != null && r.state == AudioRecord.STATE_INITIALIZED) { record = r; channels = ch; break }
            r?.release()
        }
        val rec = record ?: run { Log.w(TAG, "No microphone available — program without audio"); return false }

        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * channels * 2 * 4)
        }
        val c = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).also {
                it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE); it.start()
            }
        } catch (e: Exception) {
            Log.w(TAG, "AAC encoder failed: ${e.message}"); rec.release(); record = null; return false
        }
        codec = c
        try { rec.startRecording() } catch (e: Exception) {
            Log.w(TAG, "startRecording failed: ${e.message}"); stop(); return false
        }
        running.set(true)
        thread = Thread({ loop(rec, c) }, "MicAacEncoder").apply { start() }
        Log.i(TAG, "Mic → AAC-LC ${sampleRate} Hz ${if (channels == 2) "stereo" else "mono"} ${bitrate / 1000} kbps")
        return true
    }

    private fun loop(rec: AudioRecord, c: MediaCodec) {
        val frameBytes = 1024 * channels * 2
        val pcm = ByteArray(frameBytes)
        val info = MediaCodec.BufferInfo()
        var anchorUs = -1L
        var totalSamples = 0L
        while (running.get()) {
            val n = rec.read(pcm, 0, frameBytes)
            if (n <= 0) { if (n < 0) Log.w(TAG, "AudioRecord.read = $n"); continue }
            val samples = n / (2 * channels)
            val durUs = samples * 1_000_000L / sampleRate
            val expected = (System.nanoTime() - clockStartNano) / 1000 - durUs     // when the first sample was taken
            if (anchorUs < 0) { anchorUs = expected; totalSamples = 0 }
            var pts = anchorUs + totalSamples * 1_000_000L / sampleRate
            if (abs(pts - expected) > 80_000) { anchorUs = expected - totalSamples * 1_000_000L / sampleRate; pts = expected }
            totalSamples += samples
            try {
                val idx = c.dequeueInputBuffer(20_000)
                if (idx >= 0) {
                    val ib = c.getInputBuffer(idx)!!
                    ib.clear(); ib.put(pcm, 0, n)
                    c.queueInputBuffer(idx, 0, n, pts.coerceAtLeast(0), 0)
                }
                drain(c, info)
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "encode: ${e.message}")
            }
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
        try { record?.stop() } catch (_: Exception) {}
        try { thread?.join(500) } catch (_: InterruptedException) {}
        try { record?.release() } catch (_: Exception) {}
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        record = null; codec = null; thread = null
    }
}
