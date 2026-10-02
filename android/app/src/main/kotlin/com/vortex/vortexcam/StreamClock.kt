package com.vortex.vortexcam

// =============================================================================
// StreamClock — one session clock for every transport (SRT, RTMP, SBL, OMT).
//
// The phone's raw timestamps do not share a time base: video from Camera2 →
// MediaCodec carries the SENSOR timestamp (elapsedRealtime on some devices,
// CLOCK_MONOTONIC on others — they drift apart by every minute the phone
// slept), audio was stamped with System.nanoTime(), and the TS muxer ignored
// both and counted video at a fixed 30 fps while the camera runs at 30-60 fps.
//
// Each track keeps its OWN source deltas (exact frame spacing) and is anchored
// once to the session clock at the moment its first sample arrives, so video
// and audio land on the same base whatever clock the device uses. All values
// start near 0 and only grow: transports convert to their own unit (90 kHz TS,
// ms RTMP, µs SBL, 100 ns OMT) with no wrap or base assumptions.
// =============================================================================
class StreamClock {
    private val t0Ns = System.nanoTime()

    /** Microseconds since the session started. */
    fun nowUs(): Long = (System.nanoTime() - t0Ns) / 1000

    inner class Track {
        private var firstSrcUs = Long.MIN_VALUE
        private var anchorUs   = 0L
        private var lastUs     = -1L

        /** Maps a source timestamp (µs, any base) to session µs: monotonic, real spacing. */
        @Synchronized fun sessionUs(srcUs: Long): Long {
            val now = nowUs()
            if (firstSrcUs == Long.MIN_VALUE) { firstSrcUs = srcUs; anchorUs = now }
            var us = srcUs - firstSrcUs + anchorUs
            // The source jumped (encoder restarted, camera reopened on another time base): re-anchor to arrival.
            if (kotlin.math.abs(us - now) > REANCHOR_US) { firstSrcUs = srcUs; anchorUs = now; us = now }
            if (us <= lastUs) us = lastUs + 1
            lastUs = us
            return us
        }
    }

    val video = Track()
    val audio = Track()

    companion object {
        private const val REANCHOR_US = 5_000_000L
    }
}
