package com.vortex.vortexcam.studio.webrtc

import org.webrtc.VideoFrame
import org.webrtc.VideoSink

/**
 * Thread-safe VideoSink feeding the program compositor from a WebRTC VideoTrack, optionally DELAYED.
 * VideoFrame instances in WebRTC are ref-counted (retain/release).
 *
 * Delay (2026-10-06, alignment of sources): cameras reach the switcher with different latencies (the switcher's own
 * camera ~0, Wi-Fi cameras 100–300 ms). The program aligns them to the slowest by holding the faster ones: this sink
 * keeps the last frames with their arrival time and hands out the one from [delayMs] ago. Only the program is
 * delayed; the switcher's own monitors stay live.
 */
class WebRtcSourceSink : VideoSink {
    private val lock = Object()
    private val frames = ArrayDeque<Pair<Long, VideoFrame>>()   // (arrival nanoTime, frame), oldest first

    /** Hold the program picture of this source by this much (0 = live). */
    @Volatile var delayMs: Int = 0

    // Keep a COPY, never the decoder's own frame. A decoded WebRTC frame is usually a texture of the decoder's
    // SurfaceTextureHelper, which has only ONE frame in flight: holding it until the next onFrame() starves the
    // decoder — it froze after ~1 frame (framesReceived kept growing, framesDecoded stuck; diagnosed 2026-09-29 and
    // again 2026-10-04 on a Galaxy A10). toI420() copies it (GPU readback, on the decoder thread where its EGL
    // context is current) and the original is released by the caller right after onFrame returns.
    override fun onFrame(frame: VideoFrame) {
        val copy = try {
            val i420 = frame.buffer.toI420() ?: return
            VideoFrame(i420, frame.rotation, frame.timestampNs)
        } catch (e: Exception) {
            return
        }
        val now = System.nanoTime()
        // Memory cap: a 1080p I420 is ~3 MB, a 4K one ~12 MB → at most MAX_BYTES per source (at 4K that limits the
        // usable delay to ~5 frames).
        val bytes = copy.buffer.width.toLong() * copy.buffer.height * 3 / 2
        val maxFrames = (MAX_BYTES / bytes.coerceAtLeast(1)).toInt().coerceIn(2, MAX_FRAMES)
        synchronized(lock) {
            frames.addLast(now to copy)
            // Keep what the delay needs (+100 ms).
            val keepNs = (delayMs + 100) * 1_000_000L
            while (frames.size > 1 && (frames.size > maxFrames || now - frames.first().first > keepNs)) {
                frames.removeFirst().second.release()
            }
        }
    }

    /**
     * The frame to show now: the newest one that arrived at least [delayMs] ago (the oldest kept while the buffer is
     * still filling, e.g. right after a direct cut), with an incremented ref-count.
     * The caller MUST call frame.release() when done rendering.
     */
    fun getFrame(): VideoFrame? {
        synchronized(lock) {
            if (frames.isEmpty()) return null
            val due = System.nanoTime() - delayMs * 1_000_000L
            var pick = frames.first()
            for (f in frames) { if (f.first <= due) pick = f else break }
            pick.second.retain()
            return pick.second
        }
    }

    fun release() {
        synchronized(lock) {
            while (frames.isNotEmpty()) frames.removeFirst().second.release()
        }
    }

    companion object {
        /** ~0.6 s at 30 fps: the alignment is capped at 500 ms anyway. */
        const val MAX_FRAMES = 18
        const val MAX_BYTES = 64L * 1024 * 1024
    }
}
