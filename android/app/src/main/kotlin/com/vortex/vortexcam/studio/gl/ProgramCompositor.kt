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
                    if (primaryFrame != null) draw(primaryFrame, 0, 0, width, height, cover = false)
                }
                LayoutMode.SPLIT_SCREEN -> {
                    // Each half is ~8:9: a 16:9 camera is cropped to its centre (as a TV split does), not squeezed.
                    val halfW = width / 2
                    if (primaryFrame != null) draw(primaryFrame, 0, 0, halfW - 2, height, cover = true)
                    if (secondaryFrame != null) draw(secondaryFrame, halfW + 2, 0, halfW - 2, height, cover = true)
                }
                LayoutMode.PIP -> {
                    if (primaryFrame != null) draw(primaryFrame, 0, 0, width, height, cover = false)
                    // Inset secondary camera (bottom-right 32% size)
                    if (secondaryFrame != null) {
                        val pipW = (width * 0.32).toInt()
                        val pipH = (height * 0.32).toInt()
                        draw(secondaryFrame, width - pipW - 24, 24, pipW, pipH, cover = true)
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

    private val cropMatrix = android.graphics.Matrix()

    /**
     * Draws [frame] into the box keeping its proportions. Every frame used to be stretched to the box: a 16:9 camera
     * in a split half came out squeezed to half its width (2026-10-15).
     * cover = fill the box and crop the overflow from the centre (split halves, PiP inset);
     * otherwise fill it when the aspect is close (a 16:9 camera in a 16:9 program) and fit with bars when it is not
     * (a phone held upright: cropping a 9:16 picture to 16:9 would cut most of the person).
     */
    private fun draw(frame: VideoFrame, x: Int, y: Int, w: Int, h: Int, cover: Boolean) {
        val fw = frame.rotatedWidth.toFloat(); val fh = frame.rotatedHeight.toFloat()
        if (fw <= 0f || fh <= 0f || w <= 0 || h <= 0) return
        val frameAspect = fw / fh; val boxAspect = w.toFloat() / h
        val close = kotlin.math.abs(frameAspect - boxAspect) / boxAspect < 0.05f
        if (close) { frameDrawer.drawFrame(frame, rectDrawer, null, x, y, w, h); return }
        if (cover) {
            // Same crop EglRenderer uses: scale the texture coordinates about the centre.
            val sx = if (frameAspect > boxAspect) boxAspect / frameAspect else 1f
            val sy = if (frameAspect > boxAspect) 1f else frameAspect / boxAspect
            cropMatrix.reset()
            cropMatrix.preTranslate(0.5f, 0.5f)
            cropMatrix.preScale(sx, sy)
            cropMatrix.preTranslate(-0.5f, -0.5f)
            frameDrawer.drawFrame(frame, rectDrawer, cropMatrix, x, y, w, h)
        } else {
            val dw: Int; val dh: Int
            if (frameAspect > boxAspect) { dw = w; dh = (w / frameAspect).toInt() } else { dh = h; dw = (h * frameAspect).toInt() }
            frameDrawer.drawFrame(frame, rectDrawer, null, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh)
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
