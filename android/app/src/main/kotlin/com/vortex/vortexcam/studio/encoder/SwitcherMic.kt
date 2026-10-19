package com.vortex.vortexcam.studio.encoder

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The switcher phone's microphone, shared: the program audio (ProgramAudioEncoder, while encoding) and the level meter
 * of the switcher's own camera (while that camera is on, encoding or not). One AudioRecord for both — two at once
 * leave one of them silent on most phones (Android gives the mic to the newest capture).
 *
 * 2026-10-15: the switcher's camera card had no level (it has no WebRTC audio track, so nothing reported one), and
 * the mic only existed inside the encoder.
 */
object SwitcherMic {
    private const val TAG = "SwitcherMic"
    private const val SAMPLE_RATE = ProgramAudioEncoder.SAMPLE_RATE

    private val users = HashSet<Any>()
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val running = AtomicBoolean(false)

    /** Receives every frame (left, right) while set: the program's mic ring. */
    @Volatile var sink: ((Float, Float) -> Unit)? = null

    /** Sees every block read (pcm, samples, channels, nanoTime it ended): the sync clapperboard's beep reference. */
    @Volatile var tap: ((ShortArray, Int, Int, Long) -> Unit)? = null

    /** Level of the last ~100 ms in dBFS (-100 while the mic is off). */
    @Volatile var levelDbfs = -100f
        private set

    val isRunning: Boolean get() = running.get()

    /** [owner] wants the mic; it opens with the first one. False = no mic (permission denied / busy). */
    @Synchronized fun acquire(owner: Any): Boolean {
        users.add(owner)
        if (!running.get()) open()
        return running.get()
    }

    @Synchronized fun release(owner: Any) {
        users.remove(owner)
        if (users.isEmpty() && running.get()) close()
    }

    @SuppressLint("MissingPermission")
    private fun open() {
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
        running.set(true)
        val ch = chans
        thread = Thread({
            val pcm = ShortArray(480 * ch)
            var sum = 0.0; var count = 0
            while (running.get()) {
                val n = rec.read(pcm, 0, pcm.size)
                if (n <= 0) continue
                tap?.invoke(pcm, n, ch, System.nanoTime())
                val out = sink
                var i = 0
                while (i + ch <= n) {
                    val l = pcm[i] / 32768f
                    val r = if (ch > 1) pcm[i + 1] / 32768f else l
                    out?.invoke(l, r)
                    sum += (l * l + r * r) / 2.0; count++
                    i += ch
                }
                if (count >= SAMPLE_RATE / 10) {
                    levelDbfs = (10.0 * kotlin.math.log10(sum / count + 1e-10)).toFloat().coerceAtLeast(-100f)
                    sum = 0.0; count = 0
                }
            }
        }, "SwitcherMic").apply { start() }
        Log.i(TAG, "Mic on (${if (ch == 2) "stereo" else "mono"})")
    }

    private fun close() {
        running.set(false)
        try { record?.stop() } catch (_: Exception) {}
        try { thread?.join(300) } catch (_: InterruptedException) {}
        try { record?.release() } catch (_: Exception) {}
        record = null; thread = null
        levelDbfs = -100f
        Log.i(TAG, "Mic off")
    }
}
