package com.vortex.vortexcam.studio.webrtc

import org.webrtc.VideoFrame
import org.webrtc.VideoSink

/** Colour correction of one source in the program: per-channel gains and saturation (ColorMatch). */
data class ColorGrade(val r: Float, val g: Float, val b: Float, val sat: Float) {
    val isIdentity get() = r == 1f && g == 1f && b == 1f && sat == 1f
}

/**
 * The average colour of a camera, for matching the cameras to each other (ColorMatch, 2026-10-19): ~3 times a second
 * the picture is shrunk to 32×18 and its mean Y/U/V taken (chroma only from pixels that are neither black nor
 * clipped), smoothed over ~1 s. Runs on the camera's delivery thread; cheap (a 32×18 readback).
 */
class ColorMeter : VideoSink {
    @Volatile var y = -1f; private set
    @Volatile var u = 128f; private set
    @Volatile var v = 128f; private set
    private var last = 0L

    override fun onFrame(frame: VideoFrame) {
        val now = System.nanoTime()
        if (now - last < 300_000_000L) return
        last = now
        val b = frame.buffer
        val small = try { b.cropAndScale(0, 0, b.width, b.height, 32, 18) } catch (_: Exception) { return }
        val i420: VideoFrame.I420Buffer? = try { small.toI420() } catch (_: Exception) { null } finally { small.release() }
        if (i420 == null) return
        try {
            var sy = 0.0; var n = 0; var su = 0.0; var sv = 0.0; var nc = 0
            val py = i420.dataY; val pu = i420.dataU; val pv = i420.dataV
            for (row in 0 until 18) for (col in 0 until 32) {
                val yy = py.get(row * i420.strideY + col).toInt() and 0xFF
                sy += yy; n++
                if (yy in 24..235) {
                    su += (pu.get((row / 2) * i420.strideU + col / 2).toInt() and 0xFF)
                    sv += (pv.get((row / 2) * i420.strideV + col / 2).toInt() and 0xFF)
                    nc++
                }
            }
            val my = (sy / n).toFloat()
            val k = if (y < 0) 1f else 0.3f                      // ~1 s smoothing at ~3 samples/s
            y = if (y < 0) my else y + (my - y) * k
            if (nc > n / 8) {
                u += ((su / nc).toFloat() - u) * k
                v += ((sv / nc).toFloat() - v) * k
            }
        } finally { i420.release() }
    }
}
