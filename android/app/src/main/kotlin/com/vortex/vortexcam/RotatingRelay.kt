package com.vortex.vortexcam

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer

/**
 * Camera → GPU → encoder, turning the PIXELS (2026-10-06). The encoder's KEY_ROTATION is only metadata: encoders
 * ignore it and SRT / SBL / RTMP carry no rotation, so with the phone in reverse landscape (display 270°) SAMBA got
 * the picture upside down. The camera now draws into [inputSurface]; every frame is drawn into the encoder's surface
 * turned by [rotation] (0 or 180; follows the phone live). Costs one GPU copy per frame.
 */
class RotatingRelay(encoderSurface: Surface, private val width: Int, private val height: Int) {
    companion object { private const val TAG = "RotatingRelay" }

    @Volatile var rotation = 0

    private val thread = HandlerThread("RotatingRelay").apply { start() }
    private val handler = Handler(thread.looper)
    private lateinit var egl: EglBase
    private lateinit var drawer: GlRectDrawer
    private lateinit var texture: SurfaceTexture
    private var oesTex = 0
    private val matrix = FloatArray(16)
    private val turned = FloatArray(16)
    // 180°: sample (1 − u, 1 − v) — texture matrix × (translate(1,1) · scale(−1,−1)), column-major.
    private val half = floatArrayOf(-1f, 0f, 0f, 0f, 0f, -1f, 0f, 0f, 0f, 0f, 1f, 0f, 1f, 1f, 0f, 1f)
    lateinit var inputSurface: Surface
        private set

    init {
        val ready = java.util.concurrent.CountDownLatch(1)
        var error: Exception? = null
        handler.post {
            try {
                egl = EglBase.create(null, EglBase.CONFIG_RECORDABLE)
                egl.createSurface(encoderSurface)
                egl.makeCurrent()
                drawer = GlRectDrawer()
                val t = IntArray(1); GLES20.glGenTextures(1, t, 0); oesTex = t[0]
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                texture = SurfaceTexture(oesTex).apply {
                    setDefaultBufferSize(width, height)
                    setOnFrameAvailableListener({ draw() }, handler)
                }
                inputSurface = Surface(texture)
            } catch (e: Exception) { error = e }
            ready.countDown()
        }
        ready.await()
        error?.let { release(); throw it }
        Log.i(TAG, "relay ${width}x$height ready")
    }

    private fun draw() {
        try {
            texture.updateTexImage()
            texture.getTransformMatrix(matrix)
            val m = if (rotation == 180) turned.also { android.opengl.Matrix.multiplyMM(it, 0, matrix, 0, half, 0) }
                    else matrix
            GLES20.glViewport(0, 0, width, height)
            drawer.drawOes(oesTex, m, width, height, 0, 0, width, height)
            egl.swapBuffers(texture.timestamp)
        } catch (e: Exception) {
            Log.w(TAG, "draw: ${e.message}")
        }
    }

    fun release() {
        handler.post {
            try { if (::inputSurface.isInitialized) inputSurface.release() } catch (_: Exception) {}
            try { if (::texture.isInitialized) texture.release() } catch (_: Exception) {}
            try { if (::drawer.isInitialized) drawer.release() } catch (_: Exception) {}
            try { if (oesTex != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTex), 0) } catch (_: Exception) {}
            try { if (::egl.isInitialized) egl.release() } catch (_: Exception) {}
            thread.quitSafely()
        }
    }
}
