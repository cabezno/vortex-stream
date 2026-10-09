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
class RotatingRelay(encoderSurface: Surface, val width: Int, val height: Int) {
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

    // Size the CAMERA writes into [inputSurface] (2026-10-09). It was the encoder's (3840x2160): a camera without that
    // size (the Redmi's front one) picks another — 1920x1440, 4:3 — which was then stretched to 16:9. The caller gives
    // the camera's own largest size with the encoder's aspect; the relay scales it, never distorts. Blocks until set.
    fun setInputSize(w: Int, h: Int) {
        val done = java.util.concurrent.CountDownLatch(1)
        handler.post { try { texture.setDefaultBufferSize(w, h) } finally { done.countDown() } }
        done.await(1, java.util.concurrent.TimeUnit.SECONDS)
        Log.i(TAG, "camera → relay ${w}x$h (encoder ${width}x$height)")
    }

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

    // The camera's SurfaceTexture transform is NOT used to draw (2026-10-09). It turns the picture by the sensor
    // orientation (a fixed quarter turn) and, for the FRONT camera, also mirrors it like a selfie preview: drawing it
    // squeezed a portrait picture into 16:9 (DT-139), and "cancelling" its quarter turn turned the front camera's mirror
    // into an upside-down flip. The relay draws the sensor's own frame — no turn, no mirror, only GL's v flip — and the
    // orientation goes as data (SROT / SBL header: Android's JPEG-orientation formula, sensor ∓ device turn).
    private val raw = floatArrayOf(1f, 0f, 0f, 0f,  0f, -1f, 0f, 0f,  0f, 0f, 1f, 0f,  0f, 1f, 0f, 1f)   // (u, 1 − v)
    // raw · quarter turn about the centre: what the back camera's own transform does for the phone held upright
    // (+90); −90 for the other way. Used to send the picture UPRIGHT when the receiver cannot be told (RTMP).
    private fun rawTurned(deg: Float, out: FloatArray): FloatArray {
        val q = FloatArray(16)
        android.opengl.Matrix.setIdentityM(q, 0)
        android.opengl.Matrix.translateM(q, 0, 0.5f, 0.5f, 0f)
        android.opengl.Matrix.rotateM(q, 0, deg, 0f, 0f, 1f)
        android.opengl.Matrix.translateM(q, 0, -0.5f, -0.5f, 0f)
        android.opengl.Matrix.multiplyMM(out, 0, raw, 0, q, 0)
        return out
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
            texture.getTransformMatrix(matrix)                 // only logged (see `raw`)
            if (matrix[0] != lastM0 || matrix[1] != lastM1) {
                lastM0 = matrix[0]; lastM1 = matrix[1]
                Log.i(TAG, "camera transform [${matrix[0]},${matrix[1]},${matrix[4]},${matrix[5]}] (not used: raw frame)")
            }
            // Receivers that cannot be told the orientation (RTMP: YouTube, Twitch, any server) get the picture
            // UPRIGHT with black bars when the phone is held upright, drawn into a centred portrait-shaped viewport.
            val turn = if (pillarbox) uprightTurn else 0
            if (turn == 90 || turn == 270) {
                val m = rawTurned(if (turn == 90) 90f else -90f, turned)
                val vw = (height.toLong() * height / width).toInt()
                GLES20.glViewport(0, 0, width, height)
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                drawer.drawOes(oesTex, m, width, height, (width - vw) / 2, 0, vw, height)
                egl.swapBuffers(texture.timestamp)
                return
            }
            val m = if (rotation == 180) turned.also { android.opengl.Matrix.multiplyMM(it, 0, raw, 0, half, 0) }
                    else raw
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
