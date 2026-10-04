package com.vortex.vortexcam.studio.webrtc

import org.webrtc.VideoFrame
import org.webrtc.VideoSink

/**
 * Thread-safe VideoSink that holds the latest VideoFrame from an active WebRTC VideoTrack.
 * VideoFrame instances in WebRTC are ref-counted (retain/release).
 */
class WebRtcSourceSink : VideoSink {
    private val lock = Object()
    private var latestFrame: VideoFrame? = null

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
        synchronized(lock) {
            latestFrame?.release()
            latestFrame = copy
        }
    }

    /**
     * Retrieves the latest frame with an incremented ref-count.
     * The caller MUST call frame.release() when done rendering.
     */
    fun getFrame(): VideoFrame? {
        synchronized(lock) {
            val f = latestFrame
            f?.retain()
            return f
        }
    }

    fun release() {
        synchronized(lock) {
            latestFrame?.release()
            latestFrame = null
        }
    }
}
