package com.vortex.vortexcam.studio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.vortex.vortexcam.studio.encoder.SwitcherMic
import org.webrtc.AudioTrackSink
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Measures how late each camera reaches the switcher (plan §5b, 2026-10-06 — the user's "pip" idea), now as a
 * CLAPPERBOARD (2026-10-19, the user's "algo que el programa reconozca"): the switcher's screen FLASHES white and its
 * loudspeaker BEEPS, several times. Per camera:
 *  - video: the flash seen in its picture (a sudden brightening of part of the frame) — the cameras must see this
 *    screen. Measured on the video itself, so it no longer assumes the picture is lip-synced to the audio, and works
 *    for cameras that send no audio;
 *  - audio: the beep heard in its received audio (AudioTrackSink, delivered at playout);
 *  - the switcher's own camera: it cannot see its own screen; its picture carries the capture time, so its latency is
 *    arrival − capture.
 * References: the beep as heard by the switcher's own microphone (the exact moment it came out; before, the time it
 * was queued plus the platform's guess of the output latency, off by tens of ms on some phones), and the flash as
 * drawn by Flutter plus [FLASH_DISPLAY_MS] to reach the panel.
 *
 * Driven from Dart: [start] (attaches the detectors), one [mark] per flash (Dart calls it once the white frame is
 * built; it beeps), [finish] (results, detaches). Per camera the median of the flashes/beeps detected.
 */
class SyncProbe {
    companion object {
        private const val TAG = "SyncProbe"
        private const val RATE = 48_000
        private const val BEEP_MS = 120
        /** From the end of Flutter's frame to light on the panel: raster + compositor + scan-out (~2 vsyncs). */
        private const val FLASH_DISPLAY_MS = 35L
        /** A camera later than this after a flash/beep is not matched to it (the marks come ~1 s apart). */
        private const val WINDOW_NS = 900_000_000L
        private const val GRID_W = 64
        private const val GRID_H = 36
    }

    /** Onsets of a loud sound in a stream of chunks (a camera's audio, the switcher's mic). */
    private class Onsets {
        @Volatile private var floor = 1e-4               // running noise floor (RMS)
        private var armedAt = 0L                         // refractory after an onset
        val times = mutableListOf<Long>()                // nanoTime of each onset

        /** A chunk of [rms] that ended at [endNs] and lasted [durNs]. */
        fun feed(rms: Double, endNs: Long, durNs: Long) {
            if (rms > floor * 6 && rms > 0.01 && endNs >= armedAt) {
                synchronized(times) { times.add(endNs - durNs) }
                armedAt = endNs + 300_000_000L
            } else if (rms < floor * 3) {
                floor = floor * 0.95 + rms * 0.05
            }
        }

        fun firstIn(from: Long): Long? = synchronized(times) { times.firstOrNull { it >= from && it - from < WINDOW_NS } }
    }

    private class AudioDetector(val onsets: Onsets = Onsets()) : AudioTrackSink {
        override fun onData(data: java.nio.ByteBuffer, bits: Int, rate: Int, ch: Int, frames: Int, absTimeMs: Long) {
            if (bits != 16 || ch < 1 || frames <= 0) return
            val now = System.nanoTime()
            val s = data.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
            var sum = 0.0
            for (i in 0 until frames) { val v = s.get(i * ch) / 32768.0; sum += v * v }
            onsets.feed(sqrt(sum / frames), now, frames * 1_000_000_000L / rate.coerceAtLeast(1))
        }
    }

    /**
     * The flash in a camera's picture: each frame shrunk to a 64×36 luma grid; an onset is a frame where several cells
     * jump well above what they were in the last frames (the switcher's screen going black → white). A camera moving
     * can fake one: the median over the flashes and the window after each flash keep that out.
     */
    private class VideoDetector(val local: Boolean) : VideoSink {
        val onsets = Onsets()
        private val history = ArrayDeque<ByteArray>()
        private var armedAt = 0L
        val transits = mutableListOf<Long>()             // local camera: arrival − capture

        override fun onFrame(frame: VideoFrame) {
            val now = System.nanoTime()
            if (local) {
                val t = now - frame.timestampNs
                if (t in 0..1_000_000_000L) synchronized(transits) { if (transits.size < 600) transits.add(t) }
                return
            }
            val y = try {
                val b = frame.buffer
                val small = b.cropAndScale(0, 0, b.width, b.height, GRID_W, GRID_H)
                val converted: VideoFrame.I420Buffer? = try { small.toI420() } finally { small.release() }
                val i420 = converted ?: return
                try {
                    val p = i420.dataY; val stride = i420.strideY
                    ByteArray(GRID_W * GRID_H) { k -> p.get((k / GRID_W) * stride + k % GRID_W) }
                } finally { i420.release() }
            } catch (e: Exception) { return }
            if (history.size >= 3) {
                var jumped = 0
                for (k in y.indices) {
                    val v = y[k].toInt() and 0xFF
                    var before = 0
                    for (h in history) before = maxOf(before, h[k].toInt() and 0xFF)
                    if (v - before > 45) jumped++
                }
                if (jumped >= 4 && now >= armedAt) {
                    synchronized(onsets.times) { onsets.times.add(now) }
                    armedAt = now + 400_000_000L
                }
                history.removeFirst()
            }
            history.addLast(y)
        }
    }

    private val audio = mutableListOf<Triple<String, org.webrtc.AudioTrack, AudioDetector>>()
    private val video = mutableListOf<Triple<String, org.webrtc.VideoTrack, VideoDetector>>()
    private val micOwner = Any()
    private val mic = Onsets()
    private var micOn = false
    private val flashes = mutableListOf<Long>()          // when each flash reached the panel
    private val beepsQueued = mutableListOf<Long>()      // fallback reference: queued + output latency
    private var player: AudioTrack? = null

    /** [audioTracks]/[videoTracks]: peerId → that camera's received track. [localPeer]: the switcher's own camera. */
    fun start(audioTracks: Map<String, org.webrtc.AudioTrack>, videoTracks: Map<String, org.webrtc.VideoTrack>,
              localPeer: String?) {
        for ((peer, t) in audioTracks) {
            val d = AudioDetector()
            try { t.addSink(d); audio.add(Triple(peer, t, d)) } catch (e: Exception) { Log.w(TAG, "audio $peer: ${e.message}") }
        }
        for ((peer, t) in videoTracks) {
            val d = VideoDetector(local = peer == localPeer)
            try { t.addSink(d); video.add(Triple(peer, t, d)) } catch (e: Exception) { Log.w(TAG, "video $peer: ${e.message}") }
        }
        micOn = SwitcherMic.acquire(micOwner)
        if (micOn) SwitcherMic.tap = { pcm, n, ch, endNs ->
            var sum = 0.0; var frames = 0; var i = 0
            while (i < n) { val v = pcm[i] / 32768.0; sum += v * v; frames++; i += ch }
            if (frames > 0) mic.feed(sqrt(sum / frames), endNs, frames * 1_000_000_000L / RATE)
        }
        player = try { beepPlayer() } catch (e: Exception) { Log.w(TAG, "player: ${e.message}"); null }
    }

    /** The white frame of flash [k] was just built: note when it lights up and beep. */
    fun mark() {
        val now = System.nanoTime()
        flashes.add(now + FLASH_DISPLAY_MS * 1_000_000L)
        val p = player ?: return
        try {
            p.write(beep, 0, beep.size)                  // MODE_STREAM, buffer ≥ the beep: returns once queued
            beepsQueued.add(now + outputLatencyNs(p))
        } catch (e: Exception) { Log.w(TAG, "beep: ${e.message}") }
    }

    /** peerId → {"video": ms?, "audio": ms?}; detaches everything. */
    fun finish(): Map<String, Map<String, Int?>> {
        if (micOn) { SwitcherMic.tap = null; SwitcherMic.release(micOwner) }
        try { player?.stop(); player?.release() } catch (_: Exception) {}
        player = null
        // The beeps as they came out: heard by this phone's mic when it could, else the queued guess.
        val beeps = beepsQueued.map { q -> mic.firstIn(q - 200_000_000L) ?: q }
        val heardByMic = beepsQueued.indices.count { mic.firstIn(beepsQueued[it] - 200_000_000L) != null }
        Log.i(TAG, "flashes ${flashes.size}, beeps ${beeps.size} (mic heard $heardByMic)")
        fun median(refs: List<Long>, o: Onsets, min: Int): Int? {
            val l = refs.mapNotNull { r -> o.firstIn(r)?.let { ((it - r) / 1_000_000).toInt() } }.sorted()
            return if (l.size < min) null else l[l.size / 2]
        }
        val out = HashMap<String, HashMap<String, Int?>>()
        for ((peer, t, d) in audio) {
            try { t.removeSink(d) } catch (_: Exception) {}
            out.getOrPut(peer) { HashMap() }["audio"] = median(beeps, d.onsets, 1)
        }
        for ((peer, t, d) in video) {
            try { t.removeSink(d) } catch (_: Exception) {}
            out.getOrPut(peer) { HashMap() }["video"] = if (d.local) synchronized(d.transits) {
                val l = d.transits.sorted()
                if (l.size < 10) null else (l[l.size / 2] / 1_000_000).toInt()
            } else median(flashes, d.onsets, 2)
        }
        audio.clear(); video.clear()
        Log.i(TAG, "result $out")
        return out
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
