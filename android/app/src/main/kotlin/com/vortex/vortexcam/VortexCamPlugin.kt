package com.vortex.vortexcam

// =============================================================================
// VortexCamPlugin — unified native plugin for SRT + RTMP + SBL streaming
//
// Pipeline (SRT, RTMP, SBL):
//   Camera2 → Surface → MediaCodec (HEVC or AVC) → MPEG-TS muxer → SRT/RTMP
//   Camera2 → Surface → MediaCodec (AVC)          → SBL datagrams → UDP
//
// Preview:
//   Camera2 → SurfaceTexture (Flutter Texture) — live preview via Texture widget
//
// Registered as MethodChannel "com.vortex.vortexcam/native"
// =============================================================================

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import android.view.WindowManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private const val TAG     = "VortexCam"
private const val CHANNEL = "com.vortex.vortexcam/native"

class VortexCamPlugin(
    private val context:         Context,
    private val textureRegistry: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    // ---- Camera ----
    private var cameraManager:   CameraManager?            = null
    private var cameraDevice:    CameraDevice?             = null
    private var captureSession:  CameraCaptureSession?     = null
    private var cameraThread:    HandlerThread?            = null
    private var cameraHandler:   Handler?                  = null
    private var cameraFacing     = CameraCharacteristics.LENS_FACING_BACK

    // ---- Preview texture ----
    private var flutterTexture:  TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface:  Surface?                  = null

    // ---- Encoder ----
    private var encoder:         MediaCodec?               = null
    private var encoderSurface:  Surface?                  = null
    private var encodeThread:    Thread?                   = null
    private val streaming        = AtomicBoolean(false)

    // ---- Stats ----
    private val bytesSent        = AtomicLong(0L)
    private var lastStatNs       = 0L
    private var bitrateMbps      = 0.0
    private var rttMs            = 0

    // ---- Transport sockets ----
    private var srtSocket:  SrtSocket? = null   // SRT transport
    private var srtMuxer:   TsMuxer?   = null   // kept to carry the app log in the same stream
    // Last encoder failure, returned to Dart (→ log shipped to SAMBA) instead of a bare "failed".
    @Volatile private var lastEncoderError = ""
    // Camera sensor orientation, read once when the camera opens (getCameraCharacteristics is NOT cheap and
    // previewRotation runs on the main thread).
    @Volatile private var cachedSensorOrientation = 90
    // AE fps range the OPEN camera supports (asking for 30-60 on a 30 fps-only camera made the Galaxy A10's camera
    // service abort on the next reconfigure). Read once per camera open.
    @Volatile private var cachedFpsRange = android.util.Range(30, 30)
    private var rtmpClient: RtmpClient? = null  // RTMP transport
    @Volatile private var rtmpUrl = ""
    @Volatile private var rtmpDown = false
    @Volatile private var rtmpReconnects = 0
    // Session clock shared by video and audio of whichever transport is up (new one per stream start).
    @Volatile private var streamClock = StreamClock()

    // ---- SBL UDP transport ----
    private var sblSocket:     java.net.DatagramSocket?    = null
    private var sblRemoteAddr: java.net.InetSocketAddress? = null
    private val sblPktSeq     = java.util.concurrent.atomic.AtomicInteger(0)   // video + mic + control threads

    // ---- Mic audio for SRT (mic → AAC encoder → MPEG-TS) ----
    private var audioEncoder:    MediaCodec?  = null
    private var audioRecord:     AudioRecord? = null
    private var audioInThread:   Thread?      = null
    private var audioOutThread:  Thread?      = null
    private val audioSampleRate  = 44100
    private val audioChannels    = 1
    private val sendLock         = Any()   // serializes SRT socket writes from video + audio threads

    // ---- SBL AudioReturn receiver (engine → phone talkback) ----
    private var returnDecoder:    MediaCodec?         = null
    private var returnTrack:      AudioTrack?         = null
    private val returnRunning    = AtomicBoolean(false)
    private var returnThread:     Thread?             = null
    // ONE frame counter for video AND audio. SAMBA's PacketReassembler keys frames by frameSeqNum alone (one reassembler
    // per source, not per stream): separate counters made audio frame N collide with video frame N, and the gap
    // between the two counters read as "Sender restarted its stream" ~25 times a second -> half-built 4K frames
    // thrown away, blocky picture, a keyframe request every second (2026-10-02).
    private val sblFrameSeq   = java.util.concurrent.atomic.AtomicInteger(0)
    // Video datagrams are PACED at 1.5x the bitrate: a 4K keyframe (~400 KB = ~340 datagrams) sent back-to-back
    // overflowed the Wi-Fi uplink and lost fragments; every lost fragment cost the whole frame and a new keyframe
    // request -> a loss / keyframe storm with a blocky picture (Xiaomi 4K30 SBL, 2026-10-02).
    @Volatile private var sblPaceBps = 8_000_000L
    // Video frames and audio frames never interleave on the wire. SAMBA's reassembler treats every frameSeqNum at
    // or below the highest COMPLETED one as finished: a one-packet audio frame N+1 sent while video frame N was
    // still going out completed first, and the rest of frame N was then discarded as stale -> lost frames and the
    // smeared "ghost" picture. Each frame takes its sequence number and goes out whole, under this lock.
    private val sblSendLock = Any()
    private var sblPaceNextNs = 0L
    // Forced IDRs at most once a second: SAMBA asked ~3/s while frames were being lost, and each 4K keyframe is
    // itself the biggest burst of all.
    @Volatile private var lastForcedIdrMs = 0L
    // SBL is UDP: a write never fails. Liveness = traffic FROM SAMBA (feedback every 0.5 s, keyframe requests,
    // talkback audio). Nothing for 3 s → link down → re-send Hello every second (SAMBA re-handshakes on a Hello
    // after it dropped the peer); the first packet back → link up again + IDR.
    @Volatile private var sblLastRxMs = 0L
    @Volatile private var sblLinkUp = true
    @Volatile private var sblReconnects = 0
    @Volatile private var sblSourceName = "SambaAir"

    // H.264 parameter sets, republished with every keyframe so a receiver can
    // join the stream at any IDR rather than only at the very first frame.
    private var sblSps: ByteArray? = null
    private var sblPps: ByteArray? = null

    // Toggled from Dart via "setTalkbackMuted" — checked in decodeAndPlay() before
    // writing to the AudioTrack, so muting doesn't tear down/reopen the decoder.
    private val talkbackMuted    = AtomicBoolean(false)

    // ---- SBL protocol constants ----
    private val SBL_MAGIC           = byteArrayOf(0x53, 0x42, 0x4C) // "SBL"
    private val SBL_VERSION: Byte   = 3
    private val SBL_MAX_PAYLOAD     = 1200
    private val SBL_HEADER_SIZE     = 32
    private val SBL_FRAME_HEADER_SIZE = 32

    // ====================================================================
    // Registration
    // ====================================================================
    companion object {
        fun registerWith(activity: FlutterActivity, flutterEngine: FlutterEngine) {
            val plugin = VortexCamPlugin(
                activity.applicationContext,
                flutterEngine.renderer,
            )
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(plugin)
        }
    }

    // ====================================================================
    // MethodChannel dispatch
    // ====================================================================
    // A Flutter reply may be sent ONCE. Camera callbacks can fire again after the call was answered (onError after
    // onOpened when the camera service dies — Galaxy A10, 2026-10-02) and a second reply throws
    // "Reply already submitted" on the camera thread, which killed the whole app.
    private class OnceResult(private val r: MethodChannel.Result) : MethodChannel.Result {
        private val done = AtomicBoolean(false)
        override fun success(v: Any?) { if (done.compareAndSet(false, true)) r.success(v) }
        override fun error(code: String, msg: String?, details: Any?) {
            if (done.compareAndSet(false, true)) r.error(code, msg, details) else Log.w(TAG, "late error ignored: $code $msg")
        }
        override fun notImplemented() { if (done.compareAndSet(false, true)) r.notImplemented() }
    }

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = OnceResult(rawResult)
        when (call.method) {
            "startCamera"  -> startCamera(call, result)
            // Preview only (what goes to SAMBA is untouched): clockwise degrees to show the camera upright.
            "previewRotation" -> {
                val sensor = cachedSensorOrientation
                val disp = try {
                    (context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager)
                        .getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation ?: 0
                } catch (e: Exception) { 0 }
                val dispDeg = disp * 90
                val rot = if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) (sensor + dispDeg) % 360
                          else (sensor - dispDeg + 360) % 360
                result.success(mapOf("rotation" to rot, "sensor" to sensor, "display" to dispDeg,
                    "front" to (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT)))
            }
            "stopCamera"   -> { stopCamera(); result.success(null) }
            "flipCamera"   -> { flipCamera(result) }
            "setTorch"     -> { setTorch(call.argument<Boolean>("on") ?: false); result.success(null) }

            "startSrt"     -> startSrt(call, result)
            "sendLog"      -> {
                // Network is not allowed on the main thread (NetworkOnMainThreadException): write from a worker.
                val text = call.argument<String>("text") ?: ""
                val reason = call.argument<String>("reason") ?: "manual"
                Thread {
                    val ok = sendLogBytes(text, reason)
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) }
                }.start()
            }
            "stopSrt"      -> { stopStream(); result.success(null) }

            "startRtmp"    -> startRtmp(call, result)
            "stopRtmp"     -> { stopStream(); result.success(null) }

            "getStats"     -> result.success(mapOf("bitrateMbps" to bitrateMbps, "rttMs" to rttMs,
                                  // false while SRT/RTMP is reconnecting by itself (the UI can say so)
                                  "linkUp" to (srtSocket?.linkUp ?: !rtmpDown),
                                  "reconnects" to ((srtSocket?.reconnects ?: 0) + rtmpReconnects)))

            "startSbl"         -> startSbl(call, result)
            "startSblStream"   -> startSbl(call, result)          // alias
            "stopSbl"          -> { stopStream(); result.success(null) }
            "getSblStats"      -> result.success(mapOf("bitrateMbps" to bitrateMbps, "linkUp" to sblLinkUp,
                                                     "reconnects" to sblReconnects))
            "startSrtCamera"   -> startCamera(call, result)       // alias
            "configureSrt"     -> result.success(null)            // no-op; config comes in startSbl

            "discoverSrt"  -> discoverSrt(call, result)
            "connectWifi"  -> connectWifi(call, result)

            // Mute/unmute the SBL AudioReturn (talkback) playback without tearing down
            // the MediaCodec/AudioTrack — reopening those on every toggle would add an
            // audible gap and risks fighting the Camera2 session (see the freeze-fix
            // comment on encoder surface dimensions elsewhere in this file).
            "setTalkbackMuted" -> {
                talkbackMuted.set(call.argument<Boolean>("muted") ?: false)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ====================================================================
    // Camera
    // ====================================================================
    @SuppressLint("MissingPermission")
    private fun startCamera(call: MethodCall, result: MethodChannel.Result) {
        val facingArg = call.argument<String>("facing") ?: "back"
        cameraFacing  = if (facingArg == "front") CameraCharacteristics.LENS_FACING_FRONT
                        else CameraCharacteristics.LENS_FACING_BACK

        cameraThread = HandlerThread("CameraThread").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)
        cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        // Create Flutter preview texture
        flutterTexture = textureRegistry.createSurfaceTexture()
        val surfTex = flutterTexture!!.surfaceTexture()
        surfTex.setDefaultBufferSize(1920, 1080)
        previewSurface = Surface(surfTex)

        val cameraId = getCameraId(cameraFacing)
        if (cameraId == null) {
            result.error("NO_CAMERA", "No camera found for facing=$facingArg", null)
            return
        }

        cameraManager!!.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                cachedFpsRange = pickFpsRange(cameraId)
                Log.i(TAG, "Camera opened: $cameraId (AE $cachedFpsRange fps)")
                cachedSensorOrientation = try {
                    cameraManager?.getCameraCharacteristics(cameraId)?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
                } catch (e: Exception) { 90 }
                // Start preview-only session (no encoder surface yet)
                startPreviewSession()
                result.success(mapOf("textureId" to flutterTexture!!.id()))
            }
            override fun onDisconnected(camera: CameraDevice) {
                camera.close(); cameraDevice = null
            }
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close(); cameraDevice = null
                result.error("CAMERA_ERROR", "Camera error: $error", null)   // no-op if already answered
                Thread { sendLogBytes("[cámara] error $error (servicio de cámara caído o cámara ocupada)\n", "camera_error") }.start()
            }
        }, cameraHandler)
    }

    private fun startPreviewSession() {
        val dev = cameraDevice ?: return
        val surfaces = mutableListOf(previewSurface ?: return)
        if (encoderSurface != null) surfaces.add(encoderSurface!!)
        try { dev.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                // The camera may have been closed (flip, stop, camera service death) while this session was being
                // configured: cameraDevice!! used to throw NPE here, on the camera thread, and kill the app.
                if (cameraDevice !== dev) { try { session.close() } catch (_: Exception) {}; return }
                captureSession = session
                try {
                    val req = dev.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        surfaces.forEach { addTarget(it) }
                        set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, cachedFpsRange)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    }
                    session.setRepeatingRequest(req.build(), null, cameraHandler)
                    Log.i(TAG, "Capture session started (${surfaces.size} surfaces)")
                } catch (e: Exception) { Log.w(TAG, "Capture session lost while starting: $e") }
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
                Log.e(TAG, "Capture session configure failed")
            }
        }, cameraHandler) } catch (e: Exception) { Log.w(TAG, "createCaptureSession failed: $e") }
    }

    private fun stopCamera() {
        stopStream()
        captureSession?.stopRepeating()
        captureSession?.close(); captureSession = null
        cameraDevice?.close();   cameraDevice  = null
        previewSurface?.release(); previewSurface = null
        flutterTexture?.release(); flutterTexture = null
        cameraThread?.quitSafely()
        cameraThread = null; cameraHandler = null
        Log.i(TAG, "Camera stopped")
    }

    private fun flipCamera(result: MethodChannel.Result) {
        // Swap ONLY the camera. The encoder input surface and the SRT/SBL/RTMP connection stay alive, so the stream
        // to SAMBA continues with the other camera. It used to call stopStream() — closing the encoder and the
        // socket — and never resumed: flipping while live disconnected SAMBA (2026-10-01).
        cameraFacing = if (cameraFacing == CameraCharacteristics.LENS_FACING_BACK)
            CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        captureSession?.close(); captureSession = null
        cameraDevice?.close();   cameraDevice  = null

        val cameraId = getCameraId(cameraFacing)
        if (cameraId == null) { result.error("NO_CAMERA", "No camera for facing", null); return }

        @SuppressLint("MissingPermission")
        cameraManager?.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                cameraDevice = cam
                cachedFpsRange = pickFpsRange(cameraId)
                cachedSensorOrientation = try {
                    cameraManager?.getCameraCharacteristics(cameraId)?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
                } catch (e: Exception) { 90 }
                startPreviewSession()   // preview + (if streaming) the same encoder surface
                val facing = if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) "frontal" else "trasera"
                val msg = "[flip] cámara $facing (id $cameraId, sensor $cachedSensorOrientation°), transmisión ${if (streaming.get()) "sigue" else "no activa"}\n"
                Thread { sendLogBytes(msg, "flip") }.start()
                result.success(null)
            }
            override fun onDisconnected(cam: CameraDevice) { cam.close() }
            override fun onError(cam: CameraDevice, error: Int) {
                cam.close()
                val msg = "[flip] error al abrir la cámara $cameraId: $error\n"
                Thread { sendLogBytes(msg, "flip_error") }.start()
                result.error("ERR", "error $error", null)
            }
        }, cameraHandler)
    }

    private fun setTorch(on: Boolean) {
        try {
            val id = getCameraId(cameraFacing) ?: return
            cameraManager?.setTorchMode(id, on)
        } catch (e: Exception) { Log.w(TAG, "Torch: $e") }
    }

    // Highest-ceiling AE range the camera lists, preferring a floor of at least 30 (no dark-scene drop to 15 fps).
    private fun pickFpsRange(cameraId: String): android.util.Range<Int> = try {
        val ranges = cameraManager?.getCameraCharacteristics(cameraId)
            ?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.toList().orEmpty()
        ranges.filter { it.upper <= 60 }.maxWithOrNull(
            compareBy<android.util.Range<Int>>({ it.upper }, { if (it.lower >= 30) 1 else 0 }, { -it.lower }))   // [30,60] over [60,60]: keeps exposure in low light
            ?: android.util.Range(30, 30)
    } catch (e: Exception) { android.util.Range(30, 30) }

    private fun getCameraId(facing: Int): String? {
        val mgr = cameraManager ?: return null
        return mgr.cameraIdList.firstOrNull { id ->
            mgr.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == facing
        }
    }

    // ====================================================================
    // Shared encode setup
    // ====================================================================
    // Returns the rotation angle (0/90/180/270) to apply to the encoder so that
    // VortexEngine receives upright video regardless of how the phone is held.
    private fun encoderRotationDegrees(): Int {
        // `context` is the Application context (non-visual — see registerWith, which
        // passes activity.applicationContext). On Android 11+ (API 30) both
        // Context.getDisplay() and WindowManager.defaultDisplay throw
        // UnsupportedOperationException ("Tried to obtain display from a Context not
        // associated with one") when called on a non-visual context. That exception
        // was aborting tryConfigureEncoder() at EVERY resolution, so SRT/SBL/RTMP
        // failed to start at all (black screen) on Android 11+ — only WHIP, which
        // uses WebRTC's own encoder, kept working.
        //
        // DisplayManager.getDisplay(DEFAULT_DISPLAY) works from ANY context, so it
        // gives the real rotation without the visual-context restriction. The
        // try/catch is a final safety net so the encoder can never be blocked by a
        // rotation query again.
        val rotation = try {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE)
                    as android.hardware.display.DisplayManager
            dm.getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation ?: Surface.ROTATION_0
        } catch (e: Exception) {
            Log.w(TAG, "encoderRotationDegrees: display unavailable (${e.message}) — using ROTATION_0")
            Surface.ROTATION_0
        }
        val sensorOrientation = cameraManager
            ?.getCameraCharacteristics(getCameraId(cameraFacing) ?: "0")
            ?.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        // Compensate for sensor orientation + display rotation so output is always upright.
        val displayDegrees = when (rotation) {
            Surface.ROTATION_90  -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else                 -> 0
        }
        return (sensorOrientation - displayDegrees + 360) % 360
    }

    // Public entry: try the requested resolution, then fall back DOWN a quality
    // ladder until the device's encoder accepts one. Phones that can't configure
    // 4K silently settle at the best they support — "max quality with graceful
    // fallback". Bitrate scales with the resolution that actually starts.
    // What the encoder ACTUALLY runs at after the ladder below (the request may have been refused). SBL announces this
    // in every frame header and SAMBA builds its decoder from it: announcing the request (4K) while an A10 encoded
    // 1080p gave SAMBA a 4K decoder fed 1080p → grey/green picture (2026-10-03).
    @Volatile private var encWidth = 0
    @Volatile private var encHeight = 0

    private fun setupEncoder(
        codec: String, width: Int, height: Int,
        bitrateBps: Int, keyframeMs: Int,
    ): Boolean {
        val ladder = listOf(
            Triple(3840, 2160, 30_000_000),
            Triple(1920, 1080, 16_000_000),
            Triple(1280,  720,  8_000_000),
            Triple( 960,  540,  4_000_000),
        )
        val attempts = ArrayList<Triple<Int, Int, Int>>()
        attempts.add(Triple(width, height, bitrateBps))            // requested first
        for (t in ladder) if (t.first < width) attempts.add(t)     // then strictly smaller tiers
        for (a in attempts) {
            // First with the latency tuning, then plain: some encoders (Exynos on the Galaxy A10, 2026-10-02) reject
            // KEY_LOW_LATENCY with -22 at EVERY resolution, so nothing could stream on SRT/RTMP/SBL at all.
            for (tuned in listOf(true, false)) {
                if (tryConfigureEncoder(codec, a.first, a.second, a.third, keyframeMs, tuned)) {
                    encWidth = a.first; encHeight = a.second
                    Log.i(TAG, "encoder @ ${a.first}x${a.second} @${a.third / 1000}kbps${if (tuned) "" else " (sin ajustes de latencia)"}")
                    return true
                }
            }
            Log.w(TAG, "encoder ${a.first}x${a.second} rejected — falling back")
        }
        return false
    }

    private fun tryConfigureEncoder(
        codec: String, width: Int, height: Int,
        bitrateBps: Int, keyframeMs: Int, tuned: Boolean,
    ): Boolean {
        return try {
            val mime = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC
                       else MediaFormat.MIMETYPE_VIDEO_AVC
            val rotation = encoderRotationDegrees()
            // Camera2 always outputs frames in the sensor's native landscape orientation.
            // The encoder surface must match those dimensions exactly; swapping width/height
            // would produce a portrait surface that Camera2 can't stream to simultaneously
            // with the landscape preview surface → endConfigure fails.
            // KEY_ROTATION embeds the display orientation in the bitstream as metadata.
            val encW = width
            val encH = height
            val fmt = MediaFormat.createVideoFormat(mime, encW, encH).apply {
                setInteger(MediaFormat.KEY_BIT_RATE,         bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE,       30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeMs / 1000)
                setInteger(MediaFormat.KEY_COLOR_FORMAT,     MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BITRATE_MODE,     MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                if (tuned) {
                    setInteger(MediaFormat.KEY_PRIORITY,         0)
                    setInteger(MediaFormat.KEY_OPERATING_RATE,   120)
                    if (android.os.Build.VERSION.SDK_INT >= 30)
                        setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                if (rotation != 0)
                    setInteger(MediaFormat.KEY_ROTATION, rotation)
            }
            encoder = MediaCodec.createEncoderByType(mime)
            encoder!!.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = encoder!!.createInputSurface()
            encoder!!.start()

            // Restart camera session with encoder surface
            captureSession?.close()
            startPreviewSession()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Encoder setup failed at ${width}x${height}: $e", e)
            lastEncoderError = "${width}x${height}: $e" + (e.cause?.let { " ← $it" } ?: "")
            try { encoder?.release() } catch (_: Exception) {}
            encoder = null
            encoderSurface = null
            false
        }
    }

    private fun requestIdr() {
        try {
            encoder?.setParameters(android.os.Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: Exception) { Log.w(TAG, "IDR request failed: $e") }
    }

    private fun stopStream() {
        if (!streaming.getAndSet(false)) return
        encodeThread?.join(2000); encodeThread = null
        audioInThread?.join(1000);  audioInThread  = null
        audioOutThread?.join(1000); audioOutThread = null
        sblMicThread?.join(1000)
        stopSblMicUplink()
        sblSps = null; sblPps = null   // re-captured on the next stream
        try { audioRecord?.stop(); audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { audioEncoder?.stop(); audioEncoder?.release() } catch (_: Exception) {}
        audioEncoder = null
        try { encoder?.signalEndOfInputStream() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        encoder = null
        encoderSurface?.release(); encoderSurface = null
        srtSocket?.close(); srtSocket = null
        srtMuxer = null
        rtmpClient?.close(); rtmpClient = null
        stopReturnAudio()
        sblSocket?.close(); sblSocket = null
        bytesSent.set(0L); bitrateMbps = 0.0; rttMs = 0
        // Restart preview-only session
        captureSession?.close()
        startPreviewSession()
        Log.i(TAG, "Stream stopped")
    }

    // ====================================================================
    // Mic audio — AAC encoder + AudioRecord for SRT transport
    // ====================================================================
    @SuppressLint("MissingPermission")
    private fun setupAudio() {
        try {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, audioSampleRate, audioChannels)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096)
            fmt.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            audioEncoder!!.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            audioEncoder!!.start()

            val minBuf = AudioRecord.getMinBufferSize(
                audioSampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC, audioSampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minBuf * 4)
            audioRecord!!.startRecording()
            Log.i(TAG, "Audio: ${audioSampleRate}Hz mono 128kbps AAC")
        } catch (e: Exception) {
            Log.e(TAG, "Audio setup failed (stream continues without audio): $e")
            try { audioRecord?.release() } catch (_: Exception) {}
            try { audioEncoder?.release() } catch (_: Exception) {}
            audioRecord = null; audioEncoder = null
        }
    }

    private fun startAudioInputThread() {
        val rec = audioRecord ?: return
        val enc = audioEncoder ?: return
        audioInThread = thread(name = "SrtAudioIn") {
            val pcm = ByteArray(1024 * 2)   // 1024 PCM-16 samples = one AAC frame
            while (streaming.get()) {
                val n = rec.read(pcm, 0, pcm.size)
                if (n <= 0) continue
                val inIdx = enc.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val inBuf = enc.getInputBuffer(inIdx) ?: continue
                    inBuf.clear(); inBuf.put(pcm, 0, n)
                    enc.queueInputBuffer(inIdx, 0, n, System.nanoTime() / 1000, 0)
                }
            }
            val inIdx = enc.dequeueInputBuffer(10_000)
            if (inIdx >= 0)
                enc.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        }
    }

    private fun startAudioOutputThread(muxer: TsMuxer, socket: SrtSocket) {
        val enc = audioEncoder ?: return
        audioOutThread = thread(name = "SrtAudioOut") {
            val info = MediaCodec.BufferInfo()
            while (streaming.get()) {
                val idx = enc.dequeueOutputBuffer(info, 10_000)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER      -> continue
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                    idx < 0                                       -> continue
                }
                // Skip codec-config frames (CSD-0) — no ADTS needed for those
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    enc.releaseOutputBuffer(idx, false); continue
                }
                val buf = enc.getOutputBuffer(idx)
                    ?: run { enc.releaseOutputBuffer(idx, false); continue }
                val pkts = muxer.muxAudio(buf, info, audioSampleRate, audioChannels)
                for (pkt in pkts) synchronized(sendLock) { socket.send(pkt) }
                enc.releaseOutputBuffer(idx, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        }
    }

    // ====================================================================
    // SRT
    // ====================================================================
    private fun startSrt(call: MethodCall, result: MethodChannel.Result) {
        val ip          = call.argument<String>("engineIp")   ?: return result.error("BAD", "engineIp missing", null)
        val port        = call.argument<Int>("enginePort")    ?: 9000
        val width       = call.argument<Int>("width")         ?: 1280
        val height      = call.argument<Int>("height")        ?: 720
        val bitrate     = call.argument<Int>("bitrateBps")    ?: 6_000_000
        val keyframeMs  = call.argument<Int>("keyframeMs")    ?: 2000
        val latencyMs   = call.argument<Int>("srtLatencyMs")  ?: 80
        val codec       = call.argument<String>("codec")      ?: "h264"

        thread(name = "SrtStart") {
            try {
                if (!setupEncoder(codec, width, height, bitrate, keyframeMs)) {
                    result.error("ENC", "Encoder setup failed — $lastEncoderError", null); return@thread
                }
                setupAudio()

                srtSocket = SrtSocket(ip, port, latencyMs).also { sk ->
                    sk.onReconnected = { downMs ->
                        requestIdr()   // the receiver must not wait for the next GOP
                        Thread { sendLogBytes("[srt] reconectado a $ip:$port tras ${downMs} ms\n", "reconnect") }.start()
                    }
                }
                if (!srtSocket!!.connect()) throw Exception("SRT connect to $ip:$port failed")

                val mime = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC
                           else MediaFormat.MIMETYPE_VIDEO_AVC
                streamClock = StreamClock()
                val muxer = TsMuxer(mime, streamClock)
                srtMuxer = muxer
                streaming.set(true)

                startAudioInputThread()
                startAudioOutputThread(muxer, srtSocket!!)
                encodeThread = thread(name = "SrtEncode") {
                    drainToSrt(muxer)
                }

                result.success(null)
                Log.i(TAG, "SRT streaming → $ip:$port ${width}x$height @${bitrate/1000}kbps $codec")
            } catch (e: Exception) {
                Log.e(TAG, "startSrt failed: $e")
                stopStream()
                result.error("SRT_ERR", e.message, null)
            }
        }
    }

    // Send the app log through the SAME connection the video uses (private TS PID → SAMBA phone_logs).
    // Returns false when no SRT stream is up (the caller then falls back to HTTP).
    private fun sendLogBytes(text: String, reason: String): Boolean {
        val sock = srtSocket ?: return false
        val mux  = srtMuxer  ?: return false
        if (!streaming.get()) return false
        return try {
            val pkts = mux.muxLog(text.toByteArray(Charsets.UTF_8), reason)
            synchronized(sendLock) { for (p in pkts) sock.send(p) }
            true
        } catch (e: Exception) { Log.w(TAG, "sendLog: $e"); false }
    }

    private fun drainToSrt(muxer: TsMuxer) {
        val info = MediaCodec.BufferInfo()
        while (streaming.get()) {
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    muxer.setFormat(encoder!!.outputFormat); continue
                }
                idx < 0 -> continue
            }
            val buf = encoder!!.getOutputBuffer(idx) ?: run {
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            val pkts = muxer.mux(buf, info)
            for (pkt in pkts) {
                synchronized(sendLock) { srtSocket?.send(pkt) }
                bytesSent.addAndGet(pkt.size.toLong())
            }
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }
    }

    // ====================================================================
    // RTMP
    // ====================================================================
    private fun startRtmp(call: MethodCall, result: MethodChannel.Result) {
        val url        = call.argument<String>("rtmpUrl")    ?: return result.error("BAD", "rtmpUrl missing", null)
        val width      = call.argument<Int>("width")         ?: 1280
        val height     = call.argument<Int>("height")        ?: 720
        val bitrate    = call.argument<Int>("bitrateBps")    ?: 4_000_000
        val keyframeMs = call.argument<Int>("keyframeMs")    ?: 2000

        thread(name = "RtmpStart") {
            try {
                if (!setupEncoder("h264", width, height, bitrate, keyframeMs)) {
                    result.error("ENC", "Encoder setup failed — $lastEncoderError", null); return@thread
                }
                streamClock = StreamClock()
                rtmpUrl = url; rtmpDown = false; rtmpReconnects = 0
                rtmpClient = RtmpClient(url)
                rtmpClient!!.connect()

                streaming.set(true)
                encodeThread = thread(name = "RtmpEncode") {
                    drainToRtmp()
                }

                result.success(null)
                Log.i(TAG, "RTMP streaming → $url ${width}x$height @${bitrate/1000}kbps H.264")
            } catch (e: Exception) {
                Log.e(TAG, "startRtmp failed: $e")
                stopStream()
                result.error("RTMP_ERR", e.message, null)
            }
        }
    }

    private fun drainToRtmp() {
        val info = MediaCodec.BufferInfo()
        var spsData: ByteArray? = null
        var ppsData: ByteArray? = null
        var seqHeaderSent = false
        var rtmpLastTry = 0L
        var rtmpDownSince = 0L

        while (streaming.get()) {
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // Extract SPS/PPS from format for sequence header
                    val fmt = encoder!!.outputFormat
                    spsData = fmt.getByteBuffer("csd-0")?.let { ByteArray(it.remaining()).also { a -> it.get(a) } }
                    ppsData = fmt.getByteBuffer("csd-1")?.let { ByteArray(it.remaining()).also { a -> it.get(a) } }
                    continue
                }
                idx < 0 -> continue
            }
            val buf = encoder!!.getOutputBuffer(idx) ?: run {
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            val data = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
            val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                // Some encoders deliver SPS+PPS as a buffer instead of (or as well as) csd-0/csd-1: keep them as
                // the sequence header, never send them as a frame.
                if (spsData == null) spsData = data
                encoder!!.releaseOutputBuffer(idx, false); continue
            }

            // Link down: keep draining the encoder (camera + encoder stay alive), reconnect once a second.
            if (rtmpDown) {
                val now = System.currentTimeMillis()
                if (now - rtmpLastTry >= 1000) {
                    rtmpLastTry = now
                    try {
                        val c = RtmpClient(rtmpUrl); c.connect()
                        rtmpClient = c; rtmpDown = false; rtmpReconnects++; seqHeaderSent = false
                        requestIdr()
                        Log.i(TAG, "RTMP reconnected after ${now - rtmpDownSince} ms (#$rtmpReconnects)")
                    } catch (e: Exception) { Log.w(TAG, "RTMP reconnect failed: $e") }
                }
                if (rtmpDown) { encoder!!.releaseOutputBuffer(idx, false); continue }
            }

            // csd-0 may hold SPS and PPS together (csd-1 absent) — the header builder splits them.
            if (!seqHeaderSent && spsData != null) {
                seqHeaderSent = rtmpClient?.sendVideoSequenceHeader(spsData, ppsData ?: ByteArray(0)) == true
            }
            if (seqHeaderSent) {
                try {
                    rtmpClient?.sendVideoData(data, streamClock.video.sessionUs(info.presentationTimeUs) / 1000, isKey)
                    bytesSent.addAndGet(data.size.toLong())
                } catch (e: java.io.IOException) {
                    // The receiver went away (Broken pipe / reset). This used to escape the encode thread and kill
                    // the whole app; now the link goes DOWN and the loop above reconnects every second.
                    Log.w(TAG, "RTMP link DOWN: $e — reconnecting every 1 s")
                    try { rtmpClient?.close() } catch (_: Exception) {}
                    rtmpDown = true; rtmpDownSince = System.currentTimeMillis(); rtmpLastTry = rtmpDownSince
                }
            }

            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }
    }

    // ====================================================================
    // Stats
    // ====================================================================
    private fun updateStats() {
        val now = System.nanoTime()
        val elapsed = now - lastStatNs
        if (elapsed > 2_000_000_000L) {
            bitrateMbps = bytesSent.getAndSet(0L) * 8.0 / elapsed * 1000.0
            rttMs       = srtSocket?.getRttMs() ?: 0
            lastStatNs  = now
        }
    }

    // ====================================================================
    // SBL — Samba Binary Link (UDP, H.264 raw NAL datagrams)
    // ====================================================================
    private fun startSbl(call: MethodCall, result: MethodChannel.Result) {
        val host       = call.argument<String>("host")       ?: return result.error("BAD", "host missing", null)
        val port       = call.argument<Int>("port")          ?: 8890
        val sourceName = call.argument<String>("sourceName") ?: "SambaAir"
        val width      = call.argument<Int>("width")         ?: 1280
        val height     = call.argument<Int>("height")        ?: 720
        val bitrate    = call.argument<Int>("bitrateBps")    ?: 8_000_000
        sblPaceBps = bitrate.toLong()

        thread(name = "SblStart") {
            try {
                if (!setupEncoder("h264", width, height, bitrate, 1000)) {
                    result.error("ENC", "Encoder setup failed — $lastEncoderError", null); return@thread
                }
                sblSocket = java.net.DatagramSocket()
                sblSocket!!.setSoTimeout(0)
                sblRemoteAddr = java.net.InetSocketAddress(host, port)
                sblPktSeq.set(0)
                sblFrameSeq.set(0)
                streamClock = StreamClock()
                sblSourceName = sourceName; sblLastRxMs = 0L; sblLinkUp = true; sblReconnects = 0
                // Send Hello
                sendSblHello(sourceName)
                // Small wait for HelloAck (optional, non-blocking approach)
                Thread.sleep(200)
                streaming.set(true)
                // Start receive loop for incoming packets (AudioReturn from engine)
                returnRunning.set(true)
                returnThread = thread(name = "SblReceive") { receiveLoop() }
                startSblMicUplink()
                // The size the encoder accepted, not the one requested (see encWidth).
                val w = encWidth; val h = encHeight
                encodeThread = thread(name = "SblEncode") { drainToSbl(w, h) }
                result.success(null)
                Log.i(TAG, "SBL streaming → $host:$port ${w}x${h} @${bitrate/1000}kbps (pedido ${width}x${height})")
            } catch (e: Exception) {
                Log.e(TAG, "startSbl failed: $e")
                stopStream()
                result.error("SBL_ERR", e.message, null)
            }
        }
    }

    // ====================================================================
    // SBL microphone uplink (phone → engine)
    //
    // SBL audio was only ever half-built: the engine has had an Opus decoder on
    // the Audio stream and an Opus encoder for talkback (AudioReturn) for a
    // while, and this app decodes and plays that return. Nothing ever sent the
    // microphone the other way — the AAC path above belongs to SRT — so the
    // engine sat with a decoder waiting for a stream that never arrived.
    //
    // Opus at 48 kHz mono, which is what SblAudioDecoder is configured for and
    // Opus's native rate. Deliberately separate from the SRT AAC pipeline so the
    // two transports cannot disturb each other.
    // ====================================================================
    private var sblMicRecord:  AudioRecord? = null
    private var sblOpusEncoder: MediaCodec? = null
    private var sblMicThread:  Thread? = null

    private val SBL_AUDIO_RATE     = 48_000   // Opus native; matches SblAudioConfig
    private val SBL_AUDIO_CHANNELS = 1
    private val SBL_AUDIO_BITRATE  = 48_000

    @SuppressLint("MissingPermission")
    private fun startSblMicUplink() {
        try {
            val fmt = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_OPUS, SBL_AUDIO_RATE, SBL_AUDIO_CHANNELS)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, SBL_AUDIO_BITRATE)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)

            sblOpusEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            sblOpusEncoder!!.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            sblOpusEncoder!!.start()

            val minBuf = AudioRecord.getMinBufferSize(
                SBL_AUDIO_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            sblMicRecord = AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION, SBL_AUDIO_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minBuf * 4)
            sblMicRecord!!.startRecording()

            sblMicThread = thread(name = "SblMicUplink") { sblMicLoop() }
            Log.i(TAG, "SBL mic uplink: ${SBL_AUDIO_RATE}Hz mono Opus ${SBL_AUDIO_BITRATE/1000}kbps")
        } catch (e: Exception) {
            // Video must not depend on the microphone: a device without an Opus
            // encoder, or a denied permission, keeps streaming picture.
            Log.e(TAG, "SBL mic uplink unavailable (video continues): $e")
            stopSblMicUplink()
        }
    }

    private fun stopSblMicUplink() {
        try { sblMicRecord?.stop() }    catch (_: Exception) {}
        try { sblMicRecord?.release() } catch (_: Exception) {}
        try { sblOpusEncoder?.stop() }  catch (_: Exception) {}
        try { sblOpusEncoder?.release() } catch (_: Exception) {}
        sblMicRecord = null
        sblOpusEncoder = null
        sblMicThread = null
    }

    private fun sblMicLoop() {
        val rec = sblMicRecord ?: return
        val enc = sblOpusEncoder ?: return
        // 20 ms at 48 kHz mono = 960 samples = 1920 bytes, one Opus frame.
        val pcm = ByteArray(960 * 2)
        val info = MediaCodec.BufferInfo()

        while (streaming.get()) {
            val n = rec.read(pcm, 0, pcm.size)
            if (n > 0) {
                val inIdx = enc.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    enc.getInputBuffer(inIdx)?.let { b ->
                        b.clear(); b.put(pcm, 0, n)
                        enc.queueInputBuffer(inIdx, 0, n, System.nanoTime() / 1000, 0)
                    }
                }
            }
            var outIdx = enc.dequeueOutputBuffer(info, 0)
            while (outIdx >= 0) {
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && info.size > 0) {
                    val out = enc.getOutputBuffer(outIdx)
                    if (out != null) {
                        val frame = ByteArray(info.size)
                        out.position(info.offset); out.get(frame)
                        sendSblAudioFrame(frame, streamClock.audio.sessionUs(info.presentationTimeUs))
                    }
                }
                enc.releaseOutputBuffer(outIdx, false)
                outIdx = enc.dequeueOutputBuffer(info, 0)
            }
        }
    }

    // One Opus frame on the Audio stream (streamID 1). Small enough to always
    // fit a single datagram, so no fragmentation loop is needed.
    private fun sendSblAudioFrame(opus: ByteArray, ptsUs: Long) = synchronized(sblSendLock) {
        sendSblAudioFrameLocked(opus, ptsUs)
    }

    private fun sendSblAudioFrameLocked(opus: ByteArray, ptsUs: Long) {
        val payloadLen = SBL_FRAME_HEADER_SIZE + opus.size
        if (SBL_HEADER_SIZE + payloadLen > 1400) return   // guard; Opus frames are ~120B

        val pkt = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE + payloadLen)
        pkt.put(SBL_MAGIC); pkt.put(SBL_VERSION)
        pkt.put(0)                              // packetType = Data
        pkt.put(1)                              // streamID   = Audio
        pkt.putShort(sblPktSeq.getAndIncrement().toShort())
        pkt.putInt(sblFrameSeq.getAndIncrement())   // shared with video (see sblFrameSeq)
        pkt.putShort(0)                         // fragmentIdx
        pkt.putShort(1)                         // fragmentTotal
        pkt.putLong(ptsUs)
        pkt.putShort(payloadLen.toShort())
        pkt.putShort(0)                         // flags
        pkt.putInt(0)                           // authTagPartial — filled by sealSblPacket

        // Frame header: declare Opus so the engine routes it to the right decoder.
        pkt.put(0x10)                           // SblCodec::Opus
        pkt.put(SBL_AUDIO_CHANNELS.toByte())
        pkt.putShort(0); pkt.putShort(0)        // width / height (audio = 0)
        pkt.putShort(0); pkt.putShort(0)        // fpsNum / fpsDen
        pkt.putInt(0)                           // flags
        pkt.putInt(opus.size)                   // totalFrameSize
        pkt.putShort(0); pkt.putShort(0); pkt.putShort(0)  // colour metadata
        pkt.putInt(SBL_AUDIO_RATE)              // sampleRate
        pkt.putInt(0)                           // reserved

        pkt.put(opus)
        sendSblDatagram(pkt.array())
    }

    private fun sendSblHello(sourceName: String) {
        // Packet header (32) + Hello payload (105)
        // No .order() call: SBL v3 is big-endian on the wire and that is
        // ByteBuffer's default.  See sealSblPacket() for why this used to be
        // LITTLE_ENDIAN and must not go back.
        val buf = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE + 105)
        // Header
        buf.put(SBL_MAGIC)           // [0..2] magic
        buf.put(SBL_VERSION)         // [3]
        buf.put(2)                   // [4] packetType = Hello
        buf.put(0)                   // [5] streamID = VideoColor
        buf.putShort(sblPktSeq.getAndIncrement().toShort()) // [6..7]
        buf.putInt(0)                // [8..11] frameSeq
        buf.putShort(0)              // [12..13] fragmentIdx
        buf.putShort(1)              // [14..15] fragmentTotal
        buf.putLong(System.currentTimeMillis() * 1000) // [16..23] timestamp us
        buf.putShort(105)            // [24..25] payloadLen
        buf.putShort(0)              // [26..27] flags
        buf.putInt(0)                // [28..31] authTagPartial
        // Hello payload
        buf.put(3)                   // version
        val nameBytes  = sourceName.toByteArray(Charsets.UTF_8)
        val namePadded = ByteArray(64)
        nameBytes.copyInto(namePadded, 0, 0, minOf(63, nameBytes.size))
        buf.put(namePadded)          // sourceName[64]
        buf.put(0x01)                // codecCapabilities: H264
        buf.put(0x02)                // flags: hasAudio
        buf.put(0)                   // wantEncryption
        buf.put(0)                   // reserved
        buf.putInt(50)               // maxBandwidthMbps
        buf.put(ByteArray(32))       // ecdhPublicKey = zeros
        sendSblDatagram(buf.array())
    }

    private fun sendSblKeepalive() {
        val buf = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE)   // big-endian default
        buf.put(SBL_MAGIC); buf.put(SBL_VERSION)
        buf.put(4)  // Keepalive
        buf.put(0)  // streamID
        buf.putShort(sblPktSeq.getAndIncrement().toShort())
        buf.putInt(0); buf.putShort(0); buf.putShort(1)
        buf.putLong(System.currentTimeMillis() * 1000)
        buf.putShort(0); buf.putShort(0); buf.putInt(0)
        sendSblDatagram(buf.array())
    }

    // ------------------------------------------------------------------
    // SBL v3 wire format
    //
    // Byte order: every multi-byte field is big-endian (network byte order),
    // which is ByteBuffer's default. These builders used to force
    // LITTLE_ENDIAN to match an engine-side receiver that parsed its header
    // with a raw struct memcpy on x86. That receiver has been fixed to match
    // the spec, the Go relay and this app; do not add .order() calls back.
    //
    // Integrity: an unencrypted packet carries a CRC32 of the whole packet in
    // authTagPartial [28..31], computed with those four bytes zeroed. The
    // engine's PacketReassembler::validatePacket() drops anything whose CRC
    // does not match, and this app always wrote zero there — so every packet
    // it ever sent was discarded, silently, before it reached reassembly.
    //
    // The engine uses the standard reflected polynomial 0xEDB88320
    // (sbl_transport.hpp), so java.util.zip.CRC32 is bit-compatible with its
    // sblCRC32() and there is nothing to hand-roll.
    //
    // Verified against TESTS/sbl_golden_vectors.txt by SblWireFormatTest.
    // ------------------------------------------------------------------
    private fun sealSblPacket(pkt: ByteArray): ByteArray {
        if (pkt.size < SBL_HEADER_SIZE) return pkt
        pkt[28] = 0; pkt[29] = 0; pkt[30] = 0; pkt[31] = 0
        val crc = java.util.zip.CRC32().apply { update(pkt) }.value
        pkt[28] = (crc ushr 24).toByte()
        pkt[29] = (crc ushr 16).toByte()
        pkt[30] = (crc ushr  8).toByte()
        pkt[31] = (crc        ).toByte()
        return pkt
    }

    // Token-bucket pacing for the video stream (see sblPaceBps). Small idle gaps are not saved up beyond 20 ms, so a
    // pause cannot turn into a later burst.
    private fun paceSbl(bytes: Int) {
        val rate = (sblPaceBps * 3 / 2).coerceAtLeast(2_000_000L)          // bits/s
        val now = System.nanoTime()
        if (sblPaceNextNs < now - 20_000_000L) sblPaceNextNs = now - 20_000_000L
        val wait = sblPaceNextNs - now
        if (wait > 200_000L) java.util.concurrent.locks.LockSupport.parkNanos(wait)
        sblPaceNextNs += bytes * 8L * 1_000_000_000L / rate
    }

    private fun sendSblDatagram(data: ByteArray) {
        try {
            // Sealed here rather than at each call site so a new packet type
            // cannot forget the CRC and get silently dropped by the engine.
            val sealed = sealSblPacket(data)
            val pkt = java.net.DatagramPacket(sealed, sealed.size, sblRemoteAddr)
            sblSocket?.send(pkt)
        } catch (e: Exception) {
            Log.w(TAG, "SBL send error: $e")
        }
    }

    private fun drainToSbl(width: Int, height: Int) {
        val info = MediaCodec.BufferInfo()
        var keepaliveNs = System.nanoTime()
        while (streaming.get()) {
            // Keepalive every 1s
            val now = System.nanoTime()
            if (now - keepaliveNs > 1_000_000_000L) {
                sendSblKeepalive()
                keepaliveNs = now
                val rx = sblLastRxMs
                val ms = System.currentTimeMillis()
                if (sblLinkUp && rx > 0 && ms - rx > 3000) {
                    sblLinkUp = false
                    Log.w(TAG, "SBL link DOWN (nothing from SAMBA for ${ms - rx} ms) — re-sending Hello every 1 s")
                }
                if (!sblLinkUp) sendSblHello(sblSourceName)
            }
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // H.264 parameter sets live here, and MediaCodec reports them
                    // exactly once. This used to `continue`, throwing them away,
                    // so a receiver that joined after the stream started never
                    // got an SPS/PPS and could not decode a single frame
                    // ("No SPS/PPS yet - dropping slice" on the engine side).
                    // Keep them and republish with every keyframe below.
                    captureSblParameterSets()
                    continue
                }
                idx < 0 -> continue
            }
            val buf = encoder!!.getOutputBuffer(idx) ?: run {
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            val nalData = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
            val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
            val isKey    = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

            if (isConfig) {
                // Some devices deliver the parameter sets as a normal output
                // buffer instead of (or as well as) the format change. Keep them
                // and do not send as a frame; they ride along with each keyframe.
                if (sblSps == null) sblSps = nalData
                encoder!!.releaseOutputBuffer(idx, false)
                continue
            }

            sendSblVideoFrame(nalData, isKey, streamClock.video.sessionUs(info.presentationTimeUs), width, height)
            bytesSent.addAndGet(nalData.size.toLong())
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }
    }

    // Pull csd-0 / csd-1 out of the encoder's output format. For AVC csd-0 is
    // the SPS and csd-1 the PPS, both already in Annex-B form; some encoders put
    // both into csd-0.
    private fun captureSblParameterSets() {
        try {
            val fmt = encoder?.outputFormat ?: return
            fmt.getByteBuffer("csd-0")?.let { b ->
                sblSps = ByteArray(b.remaining()).also { b.duplicate().get(it) }
            }
            fmt.getByteBuffer("csd-1")?.let { b ->
                sblPps = ByteArray(b.remaining()).also { b.duplicate().get(it) }
            }
            Log.i(TAG, "SBL parameter sets captured: sps=${sblSps?.size ?: 0}B pps=${sblPps?.size ?: 0}B")
        } catch (e: Exception) {
            Log.w(TAG, "SBL: could not read csd from output format: $e")
        }
    }

    private fun sendSblVideoFrame(
        rawNal: ByteArray, isKeyframe: Boolean,
        ptsUs: Long, width: Int, height: Int,
    ) = synchronized(sblSendLock) { sendSblVideoFrameLocked(rawNal, isKeyframe, ptsUs, width, height) }

    private fun sendSblVideoFrameLocked(
        rawNal: ByteArray, isKeyframe: Boolean,
        ptsUs: Long, width: Int, height: Int,
    ) {
        // Prepend SPS/PPS to every keyframe. MediaCodec emits them once at
        // stream start; without repeating them, any receiver that connects later
        // sits on "Waiting for IDR" forever because it has no parameter sets to
        // decode against.
        val nalData: ByteArray =
            if (isKeyframe && (sblSps != null || sblPps != null)) {
                val sps = sblSps ?: ByteArray(0)
                val pps = sblPps ?: ByteArray(0)
                ByteArray(sps.size + pps.size + rawNal.size).also { out ->
                    var o = 0
                    sps.copyInto(out, o); o += sps.size
                    pps.copyInto(out, o); o += pps.size
                    rawNal.copyInto(out, o)
                }
            } else rawNal

        val frameSeq   = sblFrameSeq.getAndIncrement()
        val frameFlags: Short = if (isKeyframe) 0x0001 else 0x0000
        // Fragment into MAX_PAYLOAD chunks; fragment 0 gets extra SblFrameHeader
        val dataPerFrag0 = SBL_MAX_PAYLOAD - SBL_FRAME_HEADER_SIZE
        val chunks = mutableListOf<ByteArray>()
        var offset = 0; var first = true
        while (offset < nalData.size) {
            val avail = if (first) dataPerFrag0 else SBL_MAX_PAYLOAD
            val len   = minOf(avail, nalData.size - offset)
            chunks.add(nalData.copyOfRange(offset, offset + len))
            offset += len; first = false
        }
        if (chunks.isEmpty()) return
        val total = chunks.size

        for ((i, chunk) in chunks.withIndex()) {
            val isFirst    = i == 0
            val payloadLen = (if (isFirst) SBL_FRAME_HEADER_SIZE else 0) + chunk.size
            val pkt = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE + payloadLen)
            // big-endian default; see sealSblPacket()
            // Packet header
            pkt.put(SBL_MAGIC); pkt.put(SBL_VERSION)
            pkt.put(0)  // Data
            pkt.put(0)  // VideoColor
            pkt.putShort(sblPktSeq.getAndIncrement().toShort())
            pkt.putInt(frameSeq)
            pkt.putShort(i.toShort())
            pkt.putShort(total.toShort())
            pkt.putLong(ptsUs)
            pkt.putShort(payloadLen.toShort())
            pkt.putShort(frameFlags)
            pkt.putInt(0)  // authTagPartial
            // Frame header (only in fragment 0)
            if (isFirst) {
                pkt.put(0x03)  // H264 codec
                pkt.put(0)     // channels (video=0)
                pkt.putShort(width.toShort())
                pkt.putShort(height.toShort())
                pkt.putShort(30)  // fpsNum
                pkt.putShort(1)   // fpsDen
                pkt.putInt(frameFlags.toInt())
                pkt.putInt(nalData.size)
                pkt.putShort(1)  // BT.709 colorPrimaries
                pkt.putShort(1)  // transferFunc
                pkt.putShort(1)  // matrixCoeff
                pkt.putInt(0)    // sampleRate (video=0)
                pkt.putInt(0)    // reserved
            }
            pkt.put(chunk)
            val dg = pkt.array().copyOf(SBL_HEADER_SIZE + payloadLen)
            paceSbl(dg.size)
            sendSblDatagram(dg)
        }
    }

    // ====================================================================
    // WiFi connect (Android 10+ WifiNetworkSpecifier; graceful on older)
    // ====================================================================
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null

    private fun connectWifi(call: MethodCall, result: MethodChannel.Result) {
        val ssid     = call.argument<String>("ssid")     ?: return result.success(false)
        val password = call.argument<String>("password") ?: return result.success(false)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Android 9 and below: no programmatic WPA2 connect without deprecated API.
            result.success(false)
            return
        }

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        // Release previous request if any.
        wifiCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .setNetworkSpecifier(specifier)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            private var responded = false
            override fun onAvailable(network: Network) {
                if (responded) return; responded = true
                cm.bindProcessToNetwork(network)
                wifiCallback = null
                result.success(true)
            }
            override fun onUnavailable() {
                if (responded) return; responded = true
                wifiCallback = null
                result.success(false)
            }
        }
        wifiCallback = cb

        try {
            cm.requestNetwork(request, cb, 10_000 /* 10s timeout */)
        } catch (e: Exception) {
            Log.e(TAG, "connectWifi: $e")
            result.success(false)
        }
    }

    // ====================================================================
    // mDNS discovery
    // ====================================================================
    private fun discoverSrt(call: MethodCall, result: MethodChannel.Result) {
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
        val nsdMgr = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        var resolved: Map<String, Any>? = null
        var listener: NsdManager.DiscoveryListener? = null
        listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(t: String, e: Int) { result.success(null) }
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                nsdMgr.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(s: NsdServiceInfo, e: Int) {}
                    override fun onServiceResolved(s: NsdServiceInfo) {
                        resolved = mapOf("ip" to (s.host?.hostAddress ?: ""), "port" to s.port)
                        try { nsdMgr.stopServiceDiscovery(listener) } catch (_: Exception) {}
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {}
        }
        nsdMgr.discoverServices("_srt._udp", NsdManager.PROTOCOL_DNS_SD, listener!!)
        thread(isDaemon = true) {
            Thread.sleep(timeoutMs.toLong())
            try { nsdMgr.stopServiceDiscovery(listener) } catch (_: Exception) {}
            result.success(resolved)
        }
    }

    // ====================================================================
    // SrtSocket — plain TCP MPEG-TS transport.
    // VortexEngine listens on TCP + UDP (SRT) on the same port.
    // When libsrt.so is available it will be preferred (true SRT with FEC/CC).
    // Until then, TCP delivers reliable MPEG-TS on LAN with ~1ms extra latency.
    // ====================================================================
    // SRT over TCP that HEALS ITSELF. A dead link used to go unnoticed: send() swallowed every error and a write
    // into a dead Wi-Fi could block for a minute (SAMBA cut the phone after 5 s; the phone noticed > 60 s later,
    // 2026-10-03). Now:
    //   - a failed write (receiver closed / reset) or a write blocked > 3 s marks the link DOWN at once;
    //   - while down, packets are dropped (the camera and the encoder keep running) and a watchdog reconnects
    //     every second; on success onReconnected asks the encoder for an IDR (PAT/PMT ride along with it).
    private inner class SrtSocket(val ip: String, val port: Int, val latencyMs: Int) {
        @Volatile private var tcpSocket: Socket? = null
        @Volatile private var out: OutputStream? = null
        @Volatile var linkUp = false; private set
        @Volatile var reconnects = 0; private set
        @Volatile private var writeStartMs = 0L        // > 0 while a write is in progress
        @Volatile private var closed = false
        @Volatile private var downSinceMs = 0L
        private var watchdog: Thread? = null
        var onReconnected: ((downMs: Long) -> Unit)? = null

        private fun open(): Boolean = try {
            val sk = Socket()
            sk.tcpNoDelay = true; sk.keepAlive = true; sk.soTimeout = 0
            sk.connect(java.net.InetSocketAddress(ip, port), 2000)
            tcpSocket = sk; out = sk.getOutputStream(); linkUp = true
            Log.i(TAG, "SRT/TCP connected → $ip:$port")
            true
        } catch (e: Exception) {
            Log.w(TAG, "SRT/TCP connect to $ip:$port failed: $e")
            false
        }

        fun connect(): Boolean {
            val ok = open()
            if (ok) startWatchdog()
            return ok
        }

        fun send(data: ByteArray) {
            val o = out ?: return
            if (!linkUp) return
            writeStartMs = System.currentTimeMillis()
            try { o.write(data) } catch (e: Exception) { markDown("write failed: $e") }
            finally { writeStartMs = 0L }
        }

        private fun markDown(why: String) {
            if (!linkUp || closed) return
            linkUp = false
            downSinceMs = System.currentTimeMillis()
            Log.w(TAG, "SRT/TCP link DOWN ($why) — reconnecting every 1 s")
            try { tcpSocket?.close() } catch (_: Exception) {}   // unblocks a writer stuck in write()
            tcpSocket = null; out = null
        }

        private fun startWatchdog() {
            watchdog = thread(name = "SrtWatchdog", isDaemon = true) {
                var lastTry = 0L
                while (!closed) {
                    try { Thread.sleep(500) } catch (_: InterruptedException) { break }
                    val now = System.currentTimeMillis()
                    if (linkUp) {
                        val ws = writeStartMs
                        if (ws > 0 && now - ws > 3000) markDown("write blocked ${now - ws} ms")
                    } else if (!closed && now - lastTry >= 1000) {
                        lastTry = now
                        if (open()) {
                            reconnects++
                            val down = now - downSinceMs
                            Log.i(TAG, "SRT/TCP reconnected after $down ms (#$reconnects)")
                            onReconnected?.invoke(down)
                        }
                    }
                }
            }
        }

        fun getRttMs(): Int = 0  // TCP doesn't expose RTT; use 0

        fun close() {
            closed = true
            try { tcpSocket?.close() } catch (_: Exception) {}
            tcpSocket = null; out = null; linkUp = false
            watchdog?.interrupt(); watchdog = null
        }
    }

    // =========================================================================
    // SBL AudioReturn — receive Opus packets from engine, decode, play
    // =========================================================================

    private fun initReturnAudio() {
        try {
            // OpusHead CSD-0 (19 bytes, little-endian fields)
            val opusHead = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            opusHead.put("OpusHead".toByteArray(Charsets.US_ASCII))  // magic (8)
            opusHead.put(1.toByte())        // version
            opusHead.put(1.toByte())        // channels = 1 (mono)
            opusHead.putShort(3840)         // pre-skip (little-endian)
            opusHead.putInt(48000)          // input sample rate
            opusHead.putShort(0)            // output gain
            opusHead.put(0.toByte())        // channel mapping family
            opusHead.flip()

            // CSD-2: 80ms seek pre-roll in nanoseconds (little-endian int64)
            val csd2 = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            csd2.putLong(80_000_000L)
            csd2.flip()

            val fmt = android.media.MediaFormat.createAudioFormat("audio/opus", 48000, 1)
            fmt.setByteBuffer("csd-0", opusHead)
            fmt.setByteBuffer("csd-1", ByteBuffer.allocate(0))
            fmt.setByteBuffer("csd-2", csd2)

            returnFormat = fmt
            returnDecoder = newReturnDecoder(fmt)

            val minBuf = AudioTrack.getMinBufferSize(
                48000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            returnTrack = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(48000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build())
                .setBufferSizeInBytes(minBuf * 4)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            returnTrack!!.play()
            Log.i(TAG, "SBL AudioReturn: Opus decoder + AudioTrack ready")
        } catch (e: Exception) {
            Log.w(TAG, "SBL AudioReturn init failed: $e")
            returnDecoder?.release(); returnDecoder = null
            returnTrack?.release();   returnTrack   = null
        }
    }

    private fun stopReturnAudio() {
        returnRunning.set(false)
        returnThread?.join(1000); returnThread = null
        returnDecoder?.stop(); returnDecoder?.release(); returnDecoder = null
        returnTrack?.stop();   returnTrack?.release();   returnTrack   = null
    }

    private fun receiveLoop() {
        val socket = sblSocket ?: return
        initReturnAudio()
        socket.soTimeout = 5          // 5ms — allows checking returnRunning
        val buf = ByteArray(2048)
        val pkt = java.net.DatagramPacket(buf, buf.size)
        while (returnRunning.get() && streaming.get()) {
            try {
                socket.receive(pkt)
                processIncoming(buf, pkt.length)
            } catch (_: java.net.SocketTimeoutException) {
                // normal — loop continues
            } catch (e: Exception) {
                if (returnRunning.get()) Log.w(TAG, "SBL recv: $e")
            }
        }
    }

    private fun processIncoming(buf: ByteArray, len: Int) {
        if (len < 32) return
        // SBL magic check: buf[0..2] == "SBL"
        if (buf[0] != 0x53.toByte() || buf[1] != 0x42.toByte() || buf[2] != 0x4C.toByte()) return
        sblLastRxMs = System.currentTimeMillis()
        if (!sblLinkUp) {
            sblLinkUp = true; sblReconnects++
            Log.i(TAG, "SBL link UP again (#$sblReconnects) — forcing IDR")
            requestIdr()
            Thread { sendLogBytes("[sbl] reconectado (#$sblReconnects)\n", "reconnect") }.start()
        }
        // KeyframeRequest (packet type 7) — the engine asks for an IDR when it
        // joins the stream or loses sync. It arrives on the Control stream, so
        // it must be handled before the AudioReturn filter below. Without this
        // the engine asked once per second and nothing ever answered.
        if ((buf[4].toInt() and 0xFF) == 7) {
            val now = System.currentTimeMillis()
            if (now - lastForcedIdrMs < 1000) return          // at most one forced IDR per second
            lastForcedIdrMs = now
            try {
                encoder?.setParameters(android.os.Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
                Log.i(TAG, "SBL: keyframe requested by engine — forcing IDR")
            } catch (e: Exception) {
                Log.w(TAG, "SBL: could not force IDR: $e")
            }
            return
        }

        val streamId = buf[5].toInt() and 0xFF
        if (streamId != 3) return   // only AudioReturn (streamID=3)
        // SblPacketHeaderV3 is big-endian on the wire, like the rest of SBL v3.
        //
        // This was little-endian, and the comment that used to sit here explained
        // why: the engine's receiver parsed its header with a raw struct memcpy,
        // so on x86 it behaved as little-endian, and this app was changed to
        // match it. That made talkback work against a broken engine. The engine
        // has since been fixed to the actual spec — which is also what the Go
        // relay parses and what ByteBuffer defaults to — so this has to read
        // big-endian again or payloadLen comes back as garbage (0x0050 read the
        // wrong way is 0x5000 = 20480) and every AudioReturn packet fails the
        // size check below and disappears without a trace.
        val payloadLen = ((buf[24].toInt() and 0xFF) shl 8) or (buf[25].toInt() and 0xFF)
        if (payloadLen <= 0 || 32 + payloadLen > len) return
        decodeAndPlay(buf, 32, payloadLen)
    }

    private var returnFormat: android.media.MediaFormat? = null
    private var returnPtsUs = 0L
    private var returnLastResetMs = 0L
    private var returnResets = 0

    private fun newReturnDecoder(fmt: android.media.MediaFormat): MediaCodec =
        MediaCodec.createDecoderByType("audio/opus").also { it.configure(fmt, null, null, 0); it.start() }

    private fun decodeAndPlay(buf: ByteArray, offset: Int, length: Int) {
        try { decodeAndPlayOnce(buf, offset, length) } catch (e: Exception) {
            // Recreate the decoder (at most once a second) instead of leaving it dead.
            try { returnDecoder?.release() } catch (_: Exception) {}
            returnDecoder = null
            val now = System.currentTimeMillis()
            if (now - returnLastResetMs >= 1000) {
                returnLastResetMs = now
                returnDecoder = try { returnFormat?.let { newReturnDecoder(it) } } catch (e2: Exception) { null }
                if (returnResets++ < 5) {
                    val msg = "[retorno] decodificador Opus reiniciado (${e.javaClass.simpleName}: ${e.message})\n"
                    Log.w(TAG, msg.trim())
                    Thread { sendLogBytes(msg, "talkback_reset") }.start()
                }
            }
        }
    }

    private fun decodeAndPlayOnce(buf: ByteArray, offset: Int, length: Int) {
        val dec   = returnDecoder ?: run {
            // Dead decoder and no reset yet this second: try again on a later packet.
            if (System.currentTimeMillis() - returnLastResetMs >= 1000) throw IllegalStateException("no decoder")
            return
        }
        val track = returnTrack   ?: return
        val inputIdx = dec.dequeueInputBuffer(5_000)
        if (inputIdx >= 0) {
            val inBuf = dec.getInputBuffer(inputIdx) ?: return
            inBuf.clear()
            inBuf.put(buf, offset, length)
            dec.queueInputBuffer(inputIdx, 0, length, returnPtsUs, 0)
            returnPtsUs += 20_000   // one 20 ms Opus frame per packet (was 0 for every packet)
        }
        val info = MediaCodec.BufferInfo()
        var outIdx = dec.dequeueOutputBuffer(info, 5_000)
        while (outIdx >= 0) {
            val outBuf = dec.getOutputBuffer(outIdx)
            // Keep draining the decoder even while muted — skipping dequeueOutputBuffer
            // would back up MediaCodec's internal buffers and eventually stall input.
            // Just don't write the decoded PCM to the AudioTrack.
            if (outBuf != null && info.size > 0 && !talkbackMuted.get()) {
                val pcm = ShortArray(info.size / 2)
                outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(pcm)
                track.write(pcm, 0, pcm.size)
            }
            dec.releaseOutputBuffer(outIdx, false)
            outIdx = dec.dequeueOutputBuffer(info, 0)
        }
    }
}

// =============================================================================
// MPEG-TS muxer (H.264 / H.265)
// =============================================================================
// MPEG-TS for SRT. Every PES ends on the declared byte: the last TS packet is padded with ADAPTATION-FIELD
// stuffing, never with 0xFF inside the payload (Media Foundation tolerated that garbage after the last NAL,
// VideoToolbox rejects the whole frame — the phone camera froze on SAMBA Mac, 2026-10-01). PAT/PMT carry a
// real CRC and their own continuity counters, the video PID carries the PCR, and PTS come from the shared
// StreamClock (real capture spacing — the camera runs at 30-60 fps, not a fixed 30).
class TsMuxer(private val mimeType: String, private val clock: StreamClock) {
    private val videoPid = 0x100
    private val audioPid = 0x101
    private val pmtPid   = 0x1000
    private val logPid   = 0x1FF0   // private, not in the PMT → other receivers ignore it

    // Continuity counters, one per PID (each is touched by a single thread: video / audio / log).
    private var videoCc = 0
    private var audioCc = 0
    private var patCc   = 0
    private var pmtCc   = 0
    private var logCc   = 0

    private var lastPsiUs = Long.MIN_VALUE
    private var paramSets: ByteArray? = null   // SPS/PPS (VPS too for HEVC), Annex-B, from the codec-config buffer

    fun setFormat(fmt: MediaFormat) { /* SPS/PPS travel in-band with every keyframe */ }

    // Diagnostic log inside the stream. Message: "SLOG" | u32 BE textLen | u8 reasonLen | reason | text.
    fun muxLog(text: ByteArray, reason: String): List<ByteArray> {
        val r = reason.toByteArray(Charsets.UTF_8).let { if (it.size > 255) it.copyOf(255) else it }
        val hdr = java.nio.ByteBuffer.allocate(9 + r.size)
            .put("SLOG".toByteArray(Charsets.US_ASCII)).putInt(text.size).put(r.size.toByte()).put(r).array()
        val out = mutableListOf<ByteArray>()
        logCc = packetize(logPid, hdr + text, logCc, out)
        return out
    }

    // One AAC frame: ADTS header + audio PES.
    fun muxAudio(buf: ByteBuffer, info: MediaCodec.BufferInfo, sampleRate: Int, channels: Int): List<ByteArray> {
        val rawAac = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
        val adts   = buildAdtsHeader(rawAac.size, sampleRate, channels) + rawAac
        val pts90  = (clock.audio.sessionUs(info.presentationTimeUs) + PTS_DELAY_US) * 9 / 100
        val out = mutableListOf<ByteArray>()
        audioCc = packetize(audioPid, buildPES(0xC0, adts, pts90, bounded = true), audioCc, out)
        return out
    }

    fun mux(buf: ByteBuffer, info: MediaCodec.BufferInfo): List<ByteArray> {
        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
        val raw   = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
        // The codec-config buffer is not a picture: it used to go out as its own PES with the same PTS as the first
        // frame. Keep it and put it in front of EVERY keyframe, so a receiver can also join at any keyframe.
        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) { paramSets = raw; return emptyList() }
        val data  = paramSets?.takeIf { isKey }?.let { it + raw } ?: raw
        val us    = clock.video.sessionUs(info.presentationTimeUs)
        val out   = mutableListOf<ByteArray>()
        // PAT/PMT before every keyframe and at least every 100 ms, so a receiver can join at any time.
        if (isKey || lastPsiUs == Long.MIN_VALUE || us - lastPsiUs >= 100_000) {
            out.add(buildPAT()); out.add(buildPMT()); lastPsiUs = us
        }
        // PCR = capture time; PTS = capture time + PTS_DELAY_US (decoder buffer headroom, PTS never behind PCR).
        val pes = buildPES(0xE0, data, (us + PTS_DELAY_US) * 9 / 100, bounded = false)
        videoCc = packetize(videoPid, pes, videoCc, out, pcr27 = us * 27, randomAccess = isKey)
        return out
    }

    // Splits one PES (or log message) into 188-byte packets. The first packet may carry PCR / random-access in
    // its adaptation field; the last one is filled with adaptation-field stuffing. Returns the next CC.
    private fun packetize(pid: Int, payload: ByteArray, ccIn: Int, out: MutableList<ByteArray>,
                          pcr27: Long = -1, randomAccess: Boolean = false): Int {
        var cc = ccIn
        var off = 0
        var first = true
        while (off < payload.size) {
            val pkt = ByteArray(188)
            pkt[0] = 0x47
            pkt[1] = ((if (first) 0x40 else 0x00) or ((pid shr 8) and 0x1F)).toByte()
            pkt[2] = (pid and 0xFF).toByte()

            val withPcr = first && pcr27 >= 0
            var afFlags = 0
            if (first && randomAccess) afFlags = afFlags or 0x40
            if (withPcr)               afFlags = afFlags or 0x10
            // Adaptation field size (length byte excluded) before stuffing: flags byte + 6 PCR bytes.
            var afLen = if (afFlags != 0) 1 + (if (withPcr) 6 else 0) else -1   // -1 = no adaptation field
            val remaining = payload.size - off
            val room = 184 - (if (afLen >= 0) 1 + afLen else 0)
            if (remaining < room) afLen = 184 - remaining - 1                     // grow it to stuff the gap
            val len = minOf(remaining, 184 - (if (afLen >= 0) 1 + afLen else 0))

            pkt[3] = ((if (afLen >= 0) 0x30 else 0x10) or (cc and 0x0F)).toByte()
            cc = (cc + 1) and 0x0F
            var p = 4
            if (afLen >= 0) {
                pkt[p++] = afLen.toByte()
                if (afLen > 0) {
                    val afEnd = p + afLen
                    pkt[p++] = afFlags.toByte()
                    if (withPcr) {
                        val base = (pcr27 / 300) and 0x1FFFFFFFFL
                        val ext  = (pcr27 % 300).toInt()
                        pkt[p++] = (base shr 25).toByte()
                        pkt[p++] = (base shr 17).toByte()
                        pkt[p++] = (base shr 9).toByte()
                        pkt[p++] = (base shr 1).toByte()
                        pkt[p++] = (((base and 1L).toInt() shl 7) or 0x7E or (ext shr 8)).toByte()
                        pkt[p++] = ext.toByte()
                    }
                    while (p < afEnd) pkt[p++] = 0xFF.toByte()
                }
            }
            payload.copyInto(pkt, p, off, off + len)
            out.add(pkt)
            off += len
            first = false
        }
        return cc
    }

    // PES with PTS only (the encoder emits no B-frames). Video is unbounded (PES_packet_length = 0, allowed for
    // video; a keyframe easily exceeds 64 KB and used to be written modulo 65536). Audio declares its length.
    private fun buildPES(streamId: Int, data: ByteArray, pts90In: Long, bounded: Boolean): ByteArray {
        val pts = pts90In and 0x1FFFFFFFFL
        val hdr = ByteArray(14)
        hdr[0] = 0; hdr[1] = 0; hdr[2] = 1; hdr[3] = streamId.toByte()
        val pesLen = if (bounded && data.size + 8 <= 0xFFFF) data.size + 8 else 0
        hdr[4] = ((pesLen shr 8) and 0xFF).toByte()
        hdr[5] = (pesLen and 0xFF).toByte()
        hdr[6] = 0x80.toByte(); hdr[7] = 0x80.toByte(); hdr[8] = 5
        hdr[9]  = (0x21 or ((pts shr 29) and 0x0E).toInt()).toByte()
        hdr[10] = ((pts shr 22) and 0xFF).toByte()
        hdr[11] = (0x01 or ((pts shr 14) and 0xFE).toInt()).toByte()
        hdr[12] = ((pts shr 7) and 0xFF).toByte()
        hdr[13] = (0x01 or ((pts and 0x7F).toInt() shl 1)).toByte()
        return hdr + data
    }

    private fun buildAdtsHeader(dataLen: Int, sampleRate: Int, channels: Int): ByteArray {
        val freqIdx = when (sampleRate) {
            96000 -> 0; 88200 -> 1; 64000 -> 2; 48000 -> 3
            44100 -> 4; 32000 -> 5; 24000 -> 6; 22050 -> 7
            16000 -> 8; 12000 -> 9; 11025 -> 10; else -> 4
        }
        val frameLen = 7 + dataLen
        return byteArrayOf(
            0xFF.toByte(),
            0xF1.toByte(),   // MPEG-4, no CRC
            ((1 shl 6) or (freqIdx shl 2) or (channels shr 2)).toByte(),
            (((channels and 3) shl 6) or ((frameLen shr 11) and 0x03)).toByte(),
            ((frameLen shr 3) and 0xFF).toByte(),
            (((frameLen and 7) shl 5) or 0x1F).toByte(),
            0xFC.toByte()    // buffer_fullness=0x7FF (VBR), num_raw_blocks=0
        )
    }

    // PSI packet: pointer_field + section + CRC32/MPEG-2; 0xFF after a section is the standard PSI stuffing.
    private fun psiPacket(pid: Int, cc: Int, section: ByteArray): ByteArray {
        val p = ByteArray(188).also { it.fill(0xFF.toByte()) }
        p[0] = 0x47
        p[1] = (0x40 or ((pid shr 8) and 0x1F)).toByte()
        p[2] = (pid and 0xFF).toByte()
        p[3] = (0x10 or (cc and 0x0F)).toByte()
        p[4] = 0   // pointer_field
        section.copyInto(p, 5)
        val crc = crc32Mpeg(section)
        p[5 + section.size]     = (crc ushr 24).toByte()
        p[5 + section.size + 1] = (crc ushr 16).toByte()
        p[5 + section.size + 2] = (crc ushr 8).toByte()
        p[5 + section.size + 3] = crc.toByte()
        return p
    }

    private fun buildPAT(): ByteArray {
        val s = byteArrayOf(
            0x00, 0xB0.toByte(), 0x0D,               // table_id PAT, section_length 13
            0x00, 0x01, 0xC1.toByte(), 0x00, 0x00,   // transport_stream_id 1, version 0, current, section 0/0
            0x00, 0x01,                              // program_number 1
            (0xE0 or ((pmtPid shr 8) and 0x1F)).toByte(), (pmtPid and 0xFF).toByte())
        return psiPacket(0x0000, patCc, s).also { patCc = (patCc + 1) and 0x0F }
    }

    private fun buildPMT(): ByteArray {
        val streamType = if (mimeType == MediaFormat.MIMETYPE_VIDEO_HEVC) 0x24 else 0x1B
        val s = byteArrayOf(
            0x02, 0xB0.toByte(), 0x17,               // table_id PMT, section_length 23
            0x00, 0x01, 0xC1.toByte(), 0x00, 0x00,   // program_number 1, version 0, current, section 0/0
            (0xE0 or (videoPid shr 8)).toByte(), (videoPid and 0xFF).toByte(),   // PCR_PID = video
            0xF0.toByte(), 0x00,                     // program_info_length 0
            streamType.toByte(), (0xE0 or (videoPid shr 8)).toByte(), (videoPid and 0xFF).toByte(), 0xF0.toByte(), 0x00,
            0x0F, (0xE0 or (audioPid shr 8)).toByte(), (audioPid and 0xFF).toByte(), 0xF0.toByte(), 0x00)  // AAC ADTS
        return psiPacket(pmtPid, pmtCc, s).also { pmtCc = (pmtCc + 1) and 0x0F }
    }

    companion object {
        private const val PTS_DELAY_US = 200_000L

        // CRC-32/MPEG-2: poly 0x04C11DB7, init 0xFFFFFFFF, not reflected, no final xor.
        fun crc32Mpeg(data: ByteArray): Int {
            var crc = -1
            for (b in data) {
                crc = crc xor ((b.toInt() and 0xFF) shl 24)
                repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
            }
            return crc
        }
    }
}

// =============================================================================
// RtmpClient — pure Kotlin RTMP publisher
// Implements: handshake → connect → createStream → publish → video data
// =============================================================================
class RtmpClient(private val rtmpUrl: String) {
    private var socket: Socket? = null
    private var output: OutputStream? = null
    private var streamId = 1
    private var timestamp = 0

    fun connect() {
        // Parse rtmp://host:port/app/streamkey
        val noScheme = rtmpUrl.removePrefix("rtmp://")
        val slashIdx = noScheme.indexOf('/')
        val hostPort = if (slashIdx >= 0) noScheme.substring(0, slashIdx) else noScheme
        val pathPart = if (slashIdx >= 0) noScheme.substring(slashIdx + 1) else ""
        val colonIdx = hostPort.lastIndexOf(':')
        val host = if (colonIdx >= 0) hostPort.substring(0, colonIdx) else hostPort
        val port = if (colonIdx >= 0) hostPort.substring(colonIdx + 1).toIntOrNull() ?: 1935 else 1935
        val lastSlash = pathPart.lastIndexOf('/')
        val app       = if (lastSlash >= 0) pathPart.substring(0, lastSlash) else pathPart
        val streamKey = if (lastSlash >= 0) pathPart.substring(lastSlash + 1) else "live"

        socket = Socket().also {
            it.tcpNoDelay = true; it.setSoTimeout(5000)
            it.connect(java.net.InetSocketAddress(host, port), 3000)
        }
        output = socket!!.getOutputStream()
        val input = socket!!.getInputStream()

        // C0+C1 handshake
        val c0c1 = ByteArray(1537)
        c0c1[0] = 0x03
        System.currentTimeMillis().let {
            c0c1[1] = ((it shr 24) and 0xFF).toByte()
            c0c1[2] = ((it shr 16) and 0xFF).toByte()
            c0c1[3] = ((it shr  8) and 0xFF).toByte()
            c0c1[4] = (it and 0xFF).toByte()
        }
        // bytes 5-8 = zeros, rest = random
        for (i in 9 until 1537) c0c1[i] = (i and 0xFF).toByte()
        output!!.write(c0c1)

        // S0+S1+S2
        val s0s1s2 = ByteArray(3073)
        var totalRead = 0
        while (totalRead < s0s1s2.size) {
            val n = input.read(s0s1s2, totalRead, s0s1s2.size - totalRead)
            if (n < 0) throw Exception("RTMP handshake EOF")
            totalRead += n
        }
        // C2 = echo of S1
        val c2 = s0s1s2.copyOfRange(1, 1537)
        output!!.write(c2)
        socket!!.setSoTimeout(0)

        // Announce our chunk size BEFORE using it. sendRtmpChunk() always cut at 4096 but never said so, and every
        // receiver (SAMBA's ingest included) reads chunks at the default 128 bytes → the stream was garbage.
        sendRtmpChunk(chunkStreamId = 2, msgTypeId = 1, msgStreamId = 0, timestamp = 0,
                      data = byteArrayOf(0, 0, (CHUNK_SIZE shr 8).toByte(), CHUNK_SIZE.toByte()))

        // connect command
        sendRtmpConnect(app)
        readAck()
        // createStream
        sendCreateStream()
        readAck()
        // publish
        sendPublish(streamKey)
        readAck()

        Log.i("RtmpClient", "Connected to $rtmpUrl (app=$app stream=$streamKey)")
    }

    // MediaCodec hands out Annex-B (start codes, csd-0/csd-1 included); FLV wants raw parameter sets in the
    // AVCDecoderConfigurationRecord and 4-byte length-prefixed NALs. Sending Annex-B made the profile bytes read
    // as 00 00 01 and every frame undecodable.
    fun sendVideoSequenceHeader(csd0: ByteArray, csd1: ByteArray): Boolean {
        val nals = splitAnnexB(csd0) + splitAnnexB(csd1)
        val sps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 7 } ?: return false
        val pps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1F) == 8 } ?: return false
        if (sps.size < 4) return false
        val buf = java.io.ByteArrayOutputStream()
        buf.write(0x17)                 // keyframe + AVC
        buf.write(0x00)                 // AVC sequence header
        buf.write(0); buf.write(0); buf.write(0)   // composition time = 0
        buf.write(1)                    // configurationVersion
        buf.write(sps[1].toInt()); buf.write(sps[2].toInt()); buf.write(sps[3].toInt())  // profile/compat/level
        buf.write(0xFF)                 // lengthSizeMinusOne = 3
        buf.write(0xE1)                 // numSequenceParameterSets = 1
        buf.write(sps.size shr 8); buf.write(sps.size and 0xFF); buf.write(sps)
        buf.write(1)                    // numPictureParameterSets = 1
        buf.write(pps.size shr 8); buf.write(pps.size and 0xFF); buf.write(pps)
        sendRtmpVideo(buf.toByteArray(), 0, true)
        return true
    }

    fun sendVideoData(data: ByteArray, timestampMs: Long, isKeyframe: Boolean) {
        // RTMP video tag: frameType + codecId + avcPacketType + compositionTime + AVCC NALs
        val buf = java.io.ByteArrayOutputStream(data.size + 32)
        buf.write(if (isKeyframe) 0x17 else 0x27)  // keyframe/interframe + AVC
        buf.write(0x01)                            // AVC NALU
        buf.write(0); buf.write(0); buf.write(0)   // composition time offset (no B-frames)
        for (nal in splitAnnexB(data)) {
            if (nal.isEmpty() || (nal[0].toInt() and 0x1F) == 9) continue   // drop access-unit delimiters
            buf.write(nal.size ushr 24); buf.write(nal.size ushr 16); buf.write(nal.size ushr 8); buf.write(nal.size)
            buf.write(nal)
        }
        sendRtmpVideo(buf.toByteArray(), timestampMs.toInt(), isKeyframe)
    }

    private fun sendRtmpConnect(app: String) {
        val amf = encodeAmfConnect(app)
        sendRtmpChunk(chunkStreamId = 3, msgTypeId = 20, msgStreamId = 0,
                      timestamp = 0, data = amf)
    }

    private fun sendCreateStream() {
        val amf = buildAmfCmd("createStream", 2.0)
        sendRtmpChunk(3, 20, 0, 0, amf)
    }

    private fun sendPublish(streamKey: String) {
        val amf = buildAmfPublish(streamKey)
        sendRtmpChunk(3, 20, streamId, 0, amf)
    }

    private fun sendRtmpVideo(data: ByteArray, ts: Int, isKey: Boolean) {
        sendRtmpChunk(chunkStreamId = 4, msgTypeId = 9, msgStreamId = streamId,
                      timestamp = ts, data = data)
    }

    private fun sendRtmpChunk(
        chunkStreamId: Int, msgTypeId: Int, msgStreamId: Int,
        timestamp: Int, data: ByteArray,
    ) {
        val out = output ?: return
        // Timestamps at or above 0xFFFFFF (4.6 h) go in the 4-byte extended field, which is then repeated after
        // every continuation header. They used to be clamped, freezing every later frame on the same timestamp.
        val extended = timestamp >= 0xFFFFFF
        val ts = if (extended) 0xFFFFFF else timestamp
        val ext = byteArrayOf((timestamp ushr 24).toByte(), (timestamp ushr 16).toByte(),
                              (timestamp ushr 8).toByte(), timestamp.toByte())
        // Basic header (fmt=0) + message header type 0 (11 bytes)
        val hdr = ByteArray(12)
        hdr[0] = (chunkStreamId and 0x3F).toByte()
        hdr[1] = ((ts shr 16) and 0xFF).toByte()
        hdr[2] = ((ts shr  8) and 0xFF).toByte()
        hdr[3] = (ts and 0xFF).toByte()
        // message length (3 bytes)
        hdr[4] = ((data.size shr 16) and 0xFF).toByte()
        hdr[5] = ((data.size shr  8) and 0xFF).toByte()
        hdr[6] = (data.size and 0xFF).toByte()
        // message type id (1 byte)
        hdr[7] = msgTypeId.toByte()
        // message stream id (4 bytes little-endian)
        hdr[8] = (msgStreamId and 0xFF).toByte()
        hdr[9] = ((msgStreamId shr 8) and 0xFF).toByte()
        hdr[10]= ((msgStreamId shr 16) and 0xFF).toByte()
        hdr[11]= ((msgStreamId shr 24) and 0xFF).toByte()

        out.write(hdr)
        if (extended) out.write(ext)
        var offset = 0
        var first  = true
        while (offset < data.size) {
            if (!first) {
                // Continuation chunk: fmt=3 basic header
                out.write(0xC0 or (chunkStreamId and 0x3F))
                if (extended) out.write(ext)
            }
            val len = minOf(CHUNK_SIZE, data.size - offset)
            out.write(data, offset, len)
            offset += len; first = false
        }
        out.flush()
    }

    private fun readAck() {
        // Minimal read to drain server responses
        val input = socket?.getInputStream() ?: return
        Thread.sleep(50)
        val available = input.available()
        if (available > 0) {
            val buf = ByteArray(available)
            input.read(buf)
        }
    }

    // AMF0 encoding helpers
    private fun encodeAmfConnect(app: String): ByteArray {
        val buf = mutableListOf<Byte>()
        amfString(buf, "connect")
        amfNumber(buf, 1.0)
        amfObjectStart(buf)
        amfKvString(buf, "app", app)
        amfKvString(buf, "type", "nonprivate")
        amfKvString(buf, "flashVer", "FMLE/3.0")
        amfKvString(buf, "tcUrl", rtmpUrl.substringBeforeLast('/'))
        amfObjectEnd(buf)
        return buf.toByteArray()
    }

    private fun buildAmfCmd(name: String, txId: Double): ByteArray {
        val buf = mutableListOf<Byte>()
        amfString(buf, name); amfNumber(buf, txId); buf.add(5)  // AMF0 null
        return buf.toByteArray()
    }

    private fun buildAmfPublish(streamKey: String): ByteArray {
        val buf = mutableListOf<Byte>()
        amfString(buf, "publish"); amfNumber(buf, 4.0); buf.add(5)
        amfString(buf, streamKey); amfString(buf, "live")
        return buf.toByteArray()
    }

    private fun amfString(buf: MutableList<Byte>, s: String) {
        buf.add(2)  // AMF0 string type
        val bytes = s.toByteArray(Charsets.UTF_8)
        buf.add(((bytes.size shr 8) and 0xFF).toByte())
        buf.add((bytes.size and 0xFF).toByte())
        buf.addAll(bytes.toList())
    }
    private fun amfNumber(buf: MutableList<Byte>, n: Double) {
        buf.add(0)  // AMF0 number type
        val bits = java.lang.Double.doubleToRawLongBits(n)
        for (i in 7 downTo 0) buf.add(((bits shr (i * 8)) and 0xFF).toByte())
    }
    private fun amfObjectStart(buf: MutableList<Byte>) { buf.add(3) }
    private fun amfObjectEnd(buf: MutableList<Byte>)   { buf.add(0); buf.add(0); buf.add(9) }
    private fun amfKvString(buf: MutableList<Byte>, k: String, v: String) {
        val kb = k.toByteArray(Charsets.UTF_8)
        buf.add(((kb.size shr 8) and 0xFF).toByte())
        buf.add((kb.size and 0xFF).toByte())
        buf.addAll(kb.toList())
        amfString(buf, v)
    }

    fun close() { try { socket?.close() } catch (_: Exception) {}; socket = null; output = null }

    companion object {
        private const val CHUNK_SIZE = 4096

        // NAL units of an Annex-B buffer, start codes removed. No start code at all → the whole buffer is one NAL.
        fun splitAnnexB(data: ByteArray): List<ByteArray> {
            val starts = ArrayList<Int>()   // index of the first NAL byte after each start code
            var i = 0
            while (i + 2 < data.size) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                    starts.add(i + 3); i += 3
                } else i++
            }
            if (starts.isEmpty()) return if (data.isEmpty()) emptyList() else listOf(data)
            val nals = ArrayList<ByteArray>(starts.size)
            for ((k, st) in starts.withIndex()) {
                var end = if (k + 1 < starts.size) starts[k + 1] - 3 else data.size
                while (end > st && data[end - 1].toInt() == 0) end--   // trailing zero of a 4-byte start code
                if (end > st) nals.add(data.copyOfRange(st, end))
            }
            return nals
        }
    }
}
