package com.vortex.vortexcam.studio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.webrtc.AudioTrackSink
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Measures how late each camera reaches the switcher, end to end (plan §5b, 2026-10-06 — the user's "pip" idea):
 * the switcher plays BEEPS on its loudspeaker; every camera's microphone hears them and sends them back in its audio;
 * here each camera's received audio is watched (AudioTrackSink, delivered at playout time, i.e. after the jitter
 * buffer and lip-sync) and the delay between playing a beep and hearing it is that camera's full latency: capture,
 * Bluetooth headset, encoding, Wi-Fi and buffer. The picture of a camera is lip-synced to its audio, so the same
 * number aligns its video.
 *
 * 3 beeps 600 ms apart (one may be missed or masked by a voice): per camera the median of the beeps heard.
 * A beep = 120 ms of 2 kHz + 3 kHz (cuts through noise suppression better than a pure tone).
 */
class SyncProbe(private val onDone: (Map<String, Int?>) -> Unit) {
    companion object {
        private const val TAG = "SyncProbe"
        private const val RATE = 48_000
        private const val BEEPS = 3
        private const val GAP_MS = 600L
        private const val BEEP_MS = 120
        private const val LISTEN_MS = 1200L     // after the last beep (a camera up to ~1 s late is still measured)
    }

    private inner class Detector(val peer: String) : AudioTrackSink {
        @Volatile var floor = 1e-4               // running noise floor (RMS)
        val onsets = mutableListOf<Long>()       // nanoTime of each detected onset
        @Volatile var armedAt = 0L               // ignore onsets before this (refractory after one)
        override fun onData(data: java.nio.ByteBuffer, bits: Int, rate: Int, ch: Int, frames: Int, absTimeMs: Long) {
            if (bits != 16 || ch < 1 || frames <= 0) return
            val now = System.nanoTime()
            val s = data.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
            var sum = 0.0
            for (i in 0 until frames) { val v = s.get(i * ch) / 32768.0; sum += v * v }
            val rms = sqrt(sum / frames)
            // Onset: well above this camera's own floor and loud enough in absolute terms.
            if (rms > floor * 6 && rms > 0.01 && now >= armedAt) {
                // The chunk ends at "now": its start is frames/rate earlier.
                synchronized(onsets) { onsets.add(now - frames * 1_000_000_000L / rate.coerceAtLeast(1)) }
                armedAt = now + 300_000_000L
            } else if (rms < floor * 3) {
                floor = floor * 0.95 + rms * 0.05
            }
        }
    }

    private val detectors = mutableListOf<Pair<org.webrtc.AudioTrack, Detector>>()
    private val main = Handler(Looper.getMainLooper())

    /** [tracks]: peerId → that camera's received audio track. */
    fun run(tracks: Map<String, org.webrtc.AudioTrack>) {
        for ((peer, t) in tracks) {
            val d = Detector(peer)
            try { t.addSink(d); detectors.add(t to d) } catch (e: Exception) { Log.w(TAG, "addSink $peer: ${e.message}") }
        }
        Thread({
            Thread.sleep(700)                                     // learn each camera's noise floor first
            val emitted = mutableListOf<Long>()
            val player = beepPlayer()
            try {
                for (k in 0 until BEEPS) {
                    val t0 = System.nanoTime()
                    player.write(beep, 0, beep.size)              // MODE_STREAM: returns once queued
                    emitted.add(t0 + outputLatencyNs(player))
                    Thread.sleep(GAP_MS)
                }
            } catch (e: Exception) { Log.w(TAG, "beep: ${e.message}") }
            Thread.sleep(LISTEN_MS)
            try { player.stop(); player.release() } catch (_: Exception) {}
            val result = HashMap<String, Int?>()
            for ((t, d) in detectors) {
                try { t.removeSink(d) } catch (_: Exception) {}
                val lat = synchronized(d.onsets) {
                    emitted.mapNotNull { e -> d.onsets.firstOrNull { it > e && it - e < 1_500_000_000L }?.let { (it - e) / 1_000_000 } }
                }.sorted()
                result[d.peer] = if (lat.isEmpty()) null else lat[lat.size / 2].toInt()
                Log.i(TAG, "${d.peer}: beeps heard ${lat.size}/$BEEPS → ${result[d.peer]} ms ($lat)")
            }
            main.post { onDone(result) }
        }, "SyncProbe").start()
    }

    private val beep: ShortArray by lazy {
        val n = RATE * BEEP_MS / 1000
        ShortArray(n) { i ->
            val env = minOf(1.0, i / 240.0, (n - i) / 240.0)     // 5 ms ramps: no click
            val v = 0.5 * sin(2 * PI * 2000 * i / RATE) + 0.4 * sin(2 * PI * 3000 * i / RATE)
            (v * env * 0.9 * 32767).toInt().toShort()
        }
    }

    private fun beepPlayer(): AudioTrack {
        val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
        val fmt = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
        val min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack(attrs, fmt, maxOf(min, beep.size * 2), AudioTrack.MODE_STREAM, 0).also { it.play() }
    }

    /** How long a sample written now takes to leave the loudspeaker (measured by the platform when available). */
    private fun outputLatencyNs(t: AudioTrack): Long = try {
        val m = AudioTrack::class.java.getMethod("getLatency")      // hidden API, ms; present on most phones
        (m.invoke(t) as Int).toLong() * 1_000_000L
    } catch (_: Exception) { 0L }
}
