package com.vortex.vortexcam.studio.gl

import android.opengl.GLES20
import android.util.Log
import com.vortex.vortexcam.studio.webrtc.WebRtcSourceSink
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer

enum class LayoutMode {
    SINGLE,
    SPLIT_SCREEN,
    PIP
}

/**
 * GPU Compositor for Program output using libwebrtc's VideoFrameDrawer and GlRectDrawer.
 * Renders real camera VideoFrames (supporting OES, RGB, and I420 with correct rotation matrices)
 * directly into the encoder Surface.
 */
class ProgramCompositor(private val width: Int, private val height: Int) {
    companion object {
        private const val TAG = "ProgramCompositor"
    }

    private val frameDrawer = VideoFrameDrawer()
    private val rectDrawer = GlRectDrawer()

    /**
     * Draws the composed layout using the latest VideoFrames from active sinks.
     */
    fun drawFrame(
        layoutMode: LayoutMode,
        primarySink: WebRtcSourceSink?,
        secondarySink: WebRtcSourceSink?
    ) {
        // Clear background to studio dark grey
        GLES20.glClearColor(0.05f, 0.05f, 0.07f, 1.0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        val primaryFrame = primarySink?.getFrame()
        val secondaryFrame = secondarySink?.getFrame()

        try {
            when (layoutMode) {
                LayoutMode.SINGLE -> {
                    if (primaryFrame != null) {
                        frameDrawer.drawFrame(primaryFrame, rectDrawer, null, 0, 0, width, height)
                    }
                }
                LayoutMode.SPLIT_SCREEN -> {
                    val halfW = width / 2
                    if (primaryFrame != null) {
                        frameDrawer.drawFrame(primaryFrame, rectDrawer, null, 0, 0, halfW - 2, height)
                    }
                    if (secondaryFrame != null) {
                        frameDrawer.drawFrame(secondaryFrame, rectDrawer, null, halfW + 2, 0, halfW - 2, height)
                    }
                }
                LayoutMode.PIP -> {
                    // 1. Fullscreen main camera
                    if (primaryFrame != null) {
                        frameDrawer.drawFrame(primaryFrame, rectDrawer, null, 0, 0, width, height)
                    }

                    // 2. Inset secondary camera (bottom-right 32% size)
                    if (secondaryFrame != null) {
                        val pipW = (width * 0.32).toInt()
                        val pipH = (height * 0.32).toInt()
                        val pipX = width - pipW - 24
                        val pipY = 24
                        frameDrawer.drawFrame(secondaryFrame, rectDrawer, null, pipX, pipY, pipW, pipH)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error drawing VideoFrame in compositor: ${e.message}")
        } finally {
            primaryFrame?.release()
            secondaryFrame?.release()
        }
    }

    fun release() {
        try {
            frameDrawer.release()
            rectDrawer.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing drawers: ${e.message}")
        }
    }
}
