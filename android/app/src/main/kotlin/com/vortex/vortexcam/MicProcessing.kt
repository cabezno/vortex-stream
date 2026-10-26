package com.vortex.vortexcam

import android.media.audiofx.NoiseSuppressor
import android.util.Log

/**
 * «Sonido» of the camera → SAMBA mic (SRT, SBL, RTMP), DT-315 (2026-10-26). The mic is always opened as MIC (the place
 * as it sounds); «voz» adds the phone's own noise suppressor on the same AudioRecord session, so switching never
 * re-opens the mic. Offered only when the phone has one ([available]).
 *
 * «auto» switches by itself: voice after [ENTER_MS] of steady background noise (the quietest 0.5 s block of the window
 * above [ENTER_DB] — speech has pauses, a fan or traffic does not), natural again after [EXIT_MS] with the quietest
 * block under [EXIT_DB]. The exit threshold is lower than the entry one because what is measured comes AFTER the
 * suppressor while it is on: it takes off part of the noise, and without the gap the mode would bounce.
 */
class MicProcessing(private val log: (String) -> Unit) {
    @Volatile var mode = "natural"          // natural | voice | auto
        private set
    @Volatile var voiceOn = false           // the suppressor is working right now
        private set
    @Volatile private var autoVoice = false
    private var ns: NoiseSuppressor? = null

    // 0.5 s blocks, newest last; enough for the longer of the two windows.
    private val blocks = ArrayDeque<Double>()
    private var blockSq = 0.0
    private var blockN = 0
    private var blockSize = 24_000         // samples in 0.5 s; set from the sample rate in attach()
    @Volatile var lastFloorDb = Double.NaN // quietest block of the last ENTER_MS, for the [mic] line
        private set

    @Synchronized fun attach(sessionId: Int, sampleRate: Int) {
        release()
        blockSize = sampleRate / 2
        if (available()) ns = try { NoiseSuppressor.create(sessionId) } catch (e: Exception) { Log.w(TAG, "NoiseSuppressor: $e"); null }
        apply()
    }

    @Synchronized fun release() {
        try { ns?.release() } catch (_: Exception) {}
        ns = null; voiceOn = false; autoVoice = false
        blocks.clear(); blockSq = 0.0; blockN = 0; lastFloorDb = Double.NaN
    }

    @Synchronized fun setMode(m: String) {
        mode = if (m == "voice" || m == "auto") m else "natural"
        if (mode != "auto") autoVoice = false
        apply()
    }

    private fun apply() {
        val on = ns != null && (mode == "voice" || (mode == "auto" && autoVoice))
        try { ns?.enabled = on } catch (e: Exception) { Log.w(TAG, "NoiseSuppressor.enabled: $e") }
        voiceOn = on
    }

    /** Sum of squares and sample count of one read from the mic (mic thread). */
    @Synchronized fun note(sumSq: Long, samples: Int) {
        blockSq += sumSq.toDouble(); blockN += samples
        if (blockN < blockSize) return
        val db = if (blockSq > 0) 10 * Math.log10(blockSq / blockN / (32768.0 * 32768.0)) else -120.0
        blockSq = 0.0; blockN = 0
        blocks.addLast(db)
        while (blocks.size > EXIT_MS / 500) blocks.removeFirst()
        val enterN = (ENTER_MS / 500).toInt()
        if (blocks.size >= enterN) lastFloorDb = blocks.takeLast(enterN).minOrNull() ?: Double.NaN
        if (mode != "auto" || ns == null) return
        if (!autoVoice && blocks.size >= enterN && lastFloorDb > ENTER_DB) {
            autoVoice = true; apply()
            log("[mic] modo → voz por ruido de fondo (piso %.0f dBFS durante %d s)\n".format(lastFloorDb, ENTER_MS / 1000))
        } else if (autoVoice && blocks.size >= EXIT_MS / 500) {
            // Calm = BOTH halves of the window have a quiet block: one quiet moment in 20 s is not enough.
            val half = blocks.size / 2
            val floor = maxOf(blocks.take(half).minOrNull() ?: 0.0, blocks.drop(half).minOrNull() ?: 0.0)
            if (floor < EXIT_DB) {
                autoVoice = false; apply()
                log("[mic] modo → natural, se calmó (piso %.0f dBFS durante %d s)\n".format(floor, EXIT_MS / 1000))
            }
        }
    }

    /** For the [mic] line. */
    fun label(): String = when (mode) {
        "auto" -> if (voiceOn) "auto: voz" else "auto: natural"
        else -> mode
    } + (if (lastFloorDb.isNaN()) "" else " · piso %.0f".format(lastFloorDb))

    companion object {
        private const val TAG = "MicProcessing"
        // 2026-10-26, Mi A3 in a room with PC fans: steady floor −45/−48, which −50 already took for «noise» (always
        // voice) and the suppressor barely moved. Voice is for noise that really bothers: −40 in, −52 out.
        const val ENTER_DB = -40.0
        const val EXIT_DB = -52.0
        const val ENTER_MS = 10_000L
        const val EXIT_MS = 20_000L
        fun available(): Boolean = try { NoiseSuppressor.isAvailable() } catch (_: Exception) { false }
    }
}
