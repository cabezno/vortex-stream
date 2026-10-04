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

    override fun onFrame(frame: VideoFrame) {
        frame.retain()
        synchronized(lock) {
            latestFrame?.release()
            latestFrame = frame
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
