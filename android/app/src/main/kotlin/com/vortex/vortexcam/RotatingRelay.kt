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
    // Quarter turn still missing after [rotation] (0, 90 or 270 — the phone held upright). Only used when [pillarbox]:
    // SRT / SBL send the sensor frame plus the orientation and SAMBA turns it; RTMP carries no orientation.
    @Volatile var uprightTurn = 0
    @Volatile var pillarbox = false

    // Timestamp (same clock as the encoder's presentation time) of the first camera frame drawn after [requestMark]:
    // lets the sender tie an orientation change to the frames shot AFTER the turn (2026-10-09).
    @Volatile var markTsNs = Long.MIN_VALUE
        private set
    @Volatile private var markRequested = false
    fun requestMark() { markTsNs = Long.MIN_VALUE; markRequested = true }

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

    // The SurfaceTexture transform of a camera already turns the picture upright for the CURRENT display rotation:
    // with the phone held upright that is a 90° turn, and drawing it into the landscape encoder surface squeezed a
    // portrait picture into 16:9 — SAMBA got it stretched, and then turned it again by the SROT it was sent
    // (2026-10-08, DT-139). Cancel any quarter turn of that matrix (keep its crop / mirror) so the encoder always
    // gets the sensor's own landscape frame; SAMBA turns it upright from SROT (srtCvo).
    private val unturned = FloatArray(16)
    private val quarter = FloatArray(16)
    private fun withoutQuarterTurn(m: FloatArray): FloatArray {
        // Column 0 = where u goes. Upright (or mirrored / 180°) keeps it on the u axis; a quarter turn moves it to v.
        if (Math.abs(m[1]) <= Math.abs(m[0])) return m
        for (deg in floatArrayOf(90f, -90f)) {
            android.opengl.Matrix.setIdentityM(quarter, 0)
            android.opengl.Matrix.translateM(quarter, 0, 0.5f, 0.5f, 0f)
            android.opengl.Matrix.rotateM(quarter, 0, deg, 0f, 0f, 1f)
            android.opengl.Matrix.translateM(quarter, 0, -0.5f, -0.5f, 0f)
            android.opengl.Matrix.multiplyMM(unturned, 0, m, 0, quarter, 0)
            if (unturned[0] > 0f) return unturned            // same handedness as the landscape case (u → +u)
        }
        return unturned
    }

    // At most [maxFps] frames into the encoder (2026-10-09). The camera may run up to 60 fps (its AE range keeps
    // exposure in low light) and an input-surface encoder encodes EVERY frame it gets, whatever KEY_FRAME_RATE says:
    // since the relay (2026-10-06) the phone encoded 4K at ~60 fps — it overheated after a long session and its
    // encoder throttled to ~3 fps. A frame arriving too early is consumed and not drawn.
    @Volatile var maxFps = 30
    private var lastDrawnTs = Long.MIN_VALUE
    private var lastM0 = Float.NaN; private var lastM1 = Float.NaN

    private fun draw() {
        try {
            texture.updateTexImage()
            val ts = texture.timestamp
            val minGapNs = 1_000_000_000L / maxOf(1, maxFps) - 4_000_000L      // 4 ms slack for camera jitter
            if (lastDrawnTs != Long.MIN_VALUE && ts - lastDrawnTs in 0 until minGapNs) return
            lastDrawnTs = ts
            if (markRequested) { markTsNs = ts; markRequested = false }
            texture.getTransformMatrix(matrix)
            val base = withoutQuarterTurn(matrix)
            if (matrix[0] != lastM0 || matrix[1] != lastM1) {
                lastM0 = matrix[0]; lastM1 = matrix[1]
                Log.i(TAG, "camera transform [${matrix[0]},${matrix[1]},${matrix[4]},${matrix[5]}] → " +
                           if (base === matrix) "as is" else "quarter turn cancelled")
            }
            // Receivers that cannot be told the orientation (RTMP: YouTube, Twitch, any server) get the picture
            // UPRIGHT with black bars when the phone is held upright: the camera's own transform (`matrix`) is exactly
            // that turn (back camera), drawn into a centred portrait-shaped viewport instead of stretched to 16:9.
            val turn = if (pillarbox) uprightTurn else 0
            if (turn == 90 || turn == 270) {
                val m = if (turn == 90) matrix else turned.also { android.opengl.Matrix.multiplyMM(it, 0, matrix, 0, half, 0) }
                val vw = (height.toLong() * height / width).toInt()
                GLES20.glViewport(0, 0, width, height)
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                drawer.drawOes(oesTex, m, width, height, (width - vw) / 2, 0, vw, height)
                egl.swapBuffers(texture.timestamp)
                return
            }
            val m = if (rotation == 180) turned.also { android.opengl.Matrix.multiplyMM(it, 0, base, 0, half, 0) }
                    else base
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
