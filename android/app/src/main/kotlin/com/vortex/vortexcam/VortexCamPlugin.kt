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
import android.os.PowerManager
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
import com.vortex.vortexcam.studio.rtmp.RtmpStreamer
import io.github.thibaultbee.srtdroid.core.Srt
import io.github.thibaultbee.srtdroid.core.enums.SockOpt
import io.github.thibaultbee.srtdroid.core.enums.SockStatus
import io.github.thibaultbee.srtdroid.core.enums.Transtype
import io.github.thibaultbee.srtdroid.core.models.SrtSocket as LibSrtSocket

private const val TAG     = "VortexCam"
private const val CHANNEL = "com.vortex.vortexcam/native"

/** SRT payload: 7 MPEG-TS packets of 188 bytes, the size every SRT receiver expects. */
private const val SRT_PAYLOAD = 1316

/** libsrt (srtdroid), started once. Not ready (library missing on this ABI, startup failed) = TCP only. */
private object SrtLib {
    val ready: Boolean by lazy {
        try { Srt.startUp(); true } catch (t: Throwable) { Log.w("VortexCam", "libsrt unavailable, TCP only: $t"); false }
    }
}

class VortexCamPlugin(
    private val context:         Context,
    private val textureRegistry: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    // For NFC pairing (reader mode needs the activity) and native → Dart callbacks.
    private var activity: java.lang.ref.WeakReference<FlutterActivity>? = null
    private var channel: MethodChannel? = null

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
    // RTMP / RTMPS transport — the same publisher as the Switcher mode (audio, TLS, server handshake, reconnects).
    private var rtmpClient: RtmpStreamer? = null
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
    @Volatile private var sblFrameCvo = 0   // orientation the frame being sent was shot with (cvoForFrame)

    // ====================================================================
    // Registration
    // ====================================================================
    companion object {
        fun registerWith(activity: FlutterActivity, flutterEngine: FlutterEngine) {
            val plugin = VortexCamPlugin(
                activity.applicationContext,
                flutterEngine.renderer,
            )
            plugin.activity = java.lang.ref.WeakReference(activity)
            plugin.channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .also { it.setMethodCallHandler(plugin) }
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
                val dispDeg = displayDegrees()
                val rot = uprightDegrees()
                result.success(mapOf("rotation" to rot, "sensor" to sensor, "display" to dispDeg,
                    "front" to (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT)))
            }
            "stopCamera"   -> { stopCamera(); result.success(null) }
            "flipCamera"   -> { flipCamera(result) }
            "setTorch"     -> { setTorch(call.argument<Boolean>("on") ?: false); result.success(null) }

            // Wi-Fi band the phone is on (MHz; 0 = not on Wi-Fi). 2.4 GHz is crowded and slow: with several phones or
            // 4K the app recommends 5 GHz or above (2026-10-05, after the three-phone tests).
            "wifiBand" -> {
                val mhz = try {
                    @Suppress("DEPRECATION")
                    (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager)
                        .connectionInfo?.frequency ?: 0
                } catch (_: Exception) { 0 }
                result.success(mhz)
            }
            // Changes when Android or the app is updated → the capability probe must run again.
            "capsStamp" -> result.success(DeviceCaps.stamp(context))
            // The phone's own name, the app's default camera name (SAMBA names the source after it): the name the user
            // sees in Android's «About phone» («Redmi Note 14 Pro+ 5G»), else Build.MODEL («SM-A105M»).
            "deviceName" -> {
                val n = try {
                    android.provider.Settings.Global.getString(context.contentResolver, android.provider.Settings.Global.DEVICE_NAME)
                } catch (_: Exception) { null }
                result.success(n?.trim()?.takeIf { it.isNotEmpty() } ?: Build.MODEL)
            }
            // What this phone can do (encoders, cameras, OMT speed) — the app offers only what works.
            "listCameras" -> result.success(DeviceCaps.listCameras(context))
            // Android 9 and older cannot join a Wi-Fi from an app: open the system's Wi-Fi list for the user.
            "openWifiSettings" -> {
                try {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_WIFI_SETTINGS)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (e: Exception) { result.success(false) }
            }
            "sdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
            // «Sonido» of the camera → SAMBA (DT-315): «voz» / «auto» only when the phone has a noise suppressor.
            "audioCaps" -> result.success(mapOf(
                "noiseSuppressor" to MicProcessing.available(),
                "echoCanceler" to (try { android.media.audiofx.AcousticEchoCanceler.isAvailable() } catch (_: Exception) { false })))
            "setMicMode" -> { micProc.setMode(call.argument<String>("mode") ?: "natural"); result.success(null) }
            // NFC pairing (NfcPairing.kt): the switcher advertises its QR JSON as a card, a camera reads it.
            "nfcInfo" -> {
                val a = activity?.get()
                result.success(mapOf("available" to (a != null && NfcPairing.available(a)),
                                     "enabled" to (a != null && NfcPairing.enabled(a))))
            }
            "nfcSetPayload" -> {
                NfcPairing.payload = call.argument<String>("json")?.toByteArray(Charsets.UTF_8)
                result.success(true)
            }
            "nfcStartReader" -> {
                val a = activity?.get()
                if (a == null) { result.success(false); return }
                NfcPairing.startReader(a) { json ->
                    android.os.Handler(android.os.Looper.getMainLooper()).post { channel?.invokeMethod("nfcPayload", json) }
                }
                result.success(true)
            }
            "nfcStopReader" -> { activity?.get()?.let { NfcPairing.stopReader(it) }; result.success(true) }
            "openNfcSettings" -> {
                try {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_NFC_SETTINGS)
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (e: Exception) { result.success(false) }
            }
            "probeCapabilities" -> thread(name = "DeviceCaps") {
                val caps = try { DeviceCaps.probe(context) } catch (e: Exception) { mapOf("error" to (e.message ?: "")) }
                android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(caps) }
            }
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
                                  "linkUp" to (srtSocket?.linkUp ?: (rtmpClient?.isConnected ?: true)),
                                  "reconnects" to ((srtSocket?.reconnects ?: 0) + (rtmpClient?.reconnects ?: 0)),
                                  "transport" to (srtSocket?.mode ?: ""),
                                  "targetMbps" to ((abr?.currentBps ?: encBitrate) / 1e6)))

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
            // SAMBA's tally for this phone (SBL, and SRT once SAMBA sends it back): known = heard in the last 6 s.
            "getTally" -> {
                val fresh = tallyAtMs > 0 && System.currentTimeMillis() - tallyAtMs < 6000
                result.success(mapOf("known" to fresh, "pgm" to (fresh && tallyPgm), "prv" to (fresh && tallyPrv)))
            }

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

        // Connecting again after «Detener» calls startCamera with the previous camera still open (Detener stops the
        // stream, not the preview). Opening it twice made Android evict the old device, and its late onDisconnected
        // cleared cameraDevice AFTER the new one had opened: the new capture session saw a «closed» camera and shut
        // itself, the encoder got no frames and SAMBA no picture (Redmi, 2026-10-21). Close the old one first.
        releaseCamera()

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
            // Only forget the camera if it is still THIS one: a callback of an older device must not clear a newer one.
            override fun onDisconnected(camera: CameraDevice) {
                camera.close(); if (cameraDevice === camera) cameraDevice = null
            }
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close(); if (cameraDevice === camera) cameraDevice = null
                result.error("CAMERA_ERROR", "Camera error: $error", null)   // no-op if already answered
                Thread { sendLogBytes("[cámara] error $error (servicio de cámara caído o cámara ocupada)\n", "camera_error") }.start()
            }
        }, cameraHandler)
    }

    // The camera's largest output size with the encoder's aspect (±1 %), at most the encoder's size; null = none.
    private fun cameraSizeForEncoder(cameraId: String, encW: Int, encH: Int): android.util.Size? = try {
        val map = cameraManager?.getCameraCharacteristics(cameraId)
            ?.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val target = encW.toDouble() / encH
        map?.getOutputSizes(android.graphics.SurfaceTexture::class.java)
            ?.filter { Math.abs(it.width.toDouble() / it.height - target) / target < 0.01 &&
                       it.width <= encW && it.height <= encH }
            ?.maxByOrNull { it.width.toLong() * it.height }
    } catch (e: Exception) { null }

    private fun startPreviewSession() {
        val dev = cameraDevice ?: return
        val surfaces = mutableListOf(previewSurface ?: return)
        relay?.let { r ->
            val sz = cameraSizeForEncoder(dev.id, r.width, r.height)
            if (sz != null) r.setInputSize(sz.width, sz.height)
            else Log.w(TAG, "camera ${dev.id}: no ${r.width}x${r.height}-shaped size — the relay keeps the encoder size")
        }
        (relay?.inputSurface ?: encoderSurface)?.let { surfaces.add(it) }
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
        releaseCamera()
        Log.i(TAG, "Camera stopped")
    }

    /** Camera, preview texture and camera thread (not the stream). Safe to call with nothing open. */
    private fun releaseCamera() {
        try { captureSession?.stopRepeating() } catch (_: Exception) {}
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        val dev = cameraDevice
        cameraDevice = null
        try { dev?.close() } catch (_: Exception) {}
        previewSurface?.release(); previewSurface = null
        flutterTexture?.release(); flutterTexture = null
        cameraThread?.quitSafely()
        cameraThread = null; cameraHandler = null
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
                updateRelayRotation()   // front and back cameras turn opposite ways
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
    private fun displayDegrees(): Int = try {
        ((context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager)
            .getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation ?: 0) * 90
    } catch (e: Exception) { 0 }

    /** Clockwise degrees that turn the camera's raw frame upright (front cameras turn the other way). */
    private fun uprightDegrees(): Int {
        val sensor = cachedSensorOrientation; val d = displayDegrees()
        return if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) (sensor + d) % 360 else (sensor - d + 360) % 360
    }

    // Pixel rotation for the stream (RotatingRelay): the phone held in either landscape gives 0 or 180.
    private var relay: RotatingRelay? = null
    private var displayListener: android.hardware.display.DisplayManager.DisplayListener? = null
    // Orientation of what is STREAMED, from the accelerometer (2026-10-09). The display rotation (what the preview
    // follows) only changes after Android's auto-rotate settles — ~1 s plus the animation — and SAMBA turned the picture
    // that much later. The camera frame no longer depends on the display (the relay always sends the sensor's frame),
    // so the stream can follow the phone itself. It switches 15° past the 45° edge: no flapping there, and a phone
    // held a little tilted still turns (the first version waited until it was within 15° of upright: felt slow).
    @Volatile private var deviceDisplayDeg = -1          // the display rotation the phone's pose means; -1 = unknown
    private var orientListener: android.view.OrientationEventListener? = null
    private fun startOrientationListener() {
        if (orientListener != null) return
        orientListener = object : android.view.OrientationEventListener(context, android.hardware.SensorManager.SENSOR_DELAY_UI) {
            override fun onOrientationChanged(o: Int) {
                if (o == ORIENTATION_UNKNOWN) return
                val q    = ((o + 45) / 90 % 4) * 90                     // device turned q° clockwise from natural
                val cand = (360 - q) % 360                              // → the display rotation that pose gives
                val cur  = deviceDisplayDeg
                if (cand == cur) return
                if (cur >= 0) {
                    var d = Math.abs(o - q); if (d > 180) d = 360 - d
                    if (d > 30) return                                  // not yet 15° past the 45° edge
                }
                deviceDisplayDeg = cand
                updateRelayRotation()
            }
        }.also {
            if (it.canDetectOrientation()) { it.enable(); Log.i(TAG, "orientation from the accelerometer (stream)") }
            else { orientListener = null; Log.i(TAG, "no accelerometer orientation — stream follows the display") }
        }
    }
    private fun stopOrientationListener() {
        orientListener?.disable(); orientListener = null; deviceDisplayDeg = -1
    }
    /** [uprightDegrees] for the STREAM: the phone's pose when known, else the display. */
    private fun streamUprightDegrees(): Int {
        val d = deviceDisplayDeg.takeIf { it >= 0 } ?: displayDegrees()
        val sensor = cachedSensorOrientation
        return if (cameraFacing == CameraCharacteristics.LENS_FACING_FRONT) (sensor + d) % 360 else (sensor - d + 360) % 360
    }

    // RTMP has no way to carry the orientation: the relay turns the picture upright itself (black bars when held
    // upright). SRT / SBL send the sensor frame + the orientation (SROT / frame header) and SAMBA turns it.
    @Volatile private var pillarboxPixels = false
    private var lastRelayTurn = -1
    private fun updateRelayRotation() {
        val r = streamUprightDegrees()
        val turn = if (r == 180) 180 else 0
        // Landscape upside down is turned HERE, in pixels: SRT's SROT / SBL's header stay at 0, so without this line
        // nothing showed that the phone had turned (DT-061, 2026-10-26).
        if (relay != null && turn != lastRelayTurn) {
            val msg = "[orientación] giro en píxeles ${turn}° (el celular ${if (turn == 180) "en horizontal invertido" else "derecho"})\n"
            if (lastRelayTurn >= 0) { Log.i(TAG, msg.trim()); Thread { sendLogBytes(msg, "orientation") }.start() }
            lastRelayTurn = turn
        }
        relay?.rotation = turn
        relay?.pillarbox = pillarboxPixels
        relay?.uprightTurn = (r - (relay?.rotation ?: 0) + 360) % 360
    }
    private fun releaseRelay() {
        displayListener?.let {
            try { (context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager)
                .unregisterDisplayListener(it) } catch (_: Exception) {}
        }
        displayListener = null
        stopOrientationListener()
        relay?.release(); relay = null
        lastRelayTurn = -1
    }
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
    // Same for the bitrate: the ladder lowers it with the size. SBL paces at 1.5× this; pacing for the requested 4K
    // (30 Mbps → 45 Mbps bursts) while encoding 1080p @16 Mbps lost the big IDR fragments on the A10's Wi-Fi →
    // no complete keyframe ever → grey picture in SAMBA (2026-10-03).
    @Volatile private var encBitrate = 0
    // SBL / SRT bitrate that follows the network (AdaptiveBitrate.kt). null when not streaming one of them.
    @Volatile private var abr: AdaptiveBitrate? = null
    private var abrLabel = ""

    // Heat (DT-145, HeatGuard.kt). The encode threads hold [encLock] for each output buffer, so the encoder can be
    // swapped for a 1080p one while streaming without a thread using the old one's buffer indices.
    private val encLock = java.util.concurrent.locks.ReentrantLock()
    private var encCodec = "h264"
    private var encKeyframeMs = 2000
    private var heat: HeatGuard? = null
    @Volatile private var heatDownshifted = false
    @Volatile private var thermalStatus = 0

    private fun startAbr(label: String) {
        abrLabel = label
        abr = AdaptiveBitrate(encBitrate, label) { bps ->
            encoder?.setParameters(android.os.Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bps) })
            sblPaceBps = bps.toLong()            // SBL paces at 1.5x the bitrate: follow it down and up
            Thread { sendLogBytes("[abr] $label ${bps / 1000} kbps\n", "abr") }.start()
        }
    }

    private fun setupEncoder(
        codec: String, width: Int, height: Int,
        bitrateBps: Int, keyframeMs: Int,
        operatingRate: Int = 120,   // 0 = let the codec pick (hot phone: no clocks at the maximum)
    ): Boolean {
        encCodec = codec; encKeyframeMs = keyframeMs
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
                if (tryConfigureEncoder(codec, a.first, a.second, a.third, keyframeMs, tuned, operatingRate)) {
                    encWidth = a.first; encHeight = a.second; encBitrate = a.third
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
        bitrateBps: Int, keyframeMs: Int, tuned: Boolean, operatingRate: Int,
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
                    if (operatingRate > 0) setInteger(MediaFormat.KEY_OPERATING_RATE, operatingRate)
                    if (android.os.Build.VERSION.SDK_INT >= 30)
                        setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                // Portrait (90/270) keeps the old metadata hint; landscape either way is turned in PIXELS by the relay.
                if (rotation == 90 || rotation == 270)
                    setInteger(MediaFormat.KEY_ROTATION, rotation)
            }
            encoder = MediaCodec.createEncoderByType(mime)
            encoder!!.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = encoder!!.createInputSurface()
            encoder!!.start()
            // Camera → relay → encoder, so a phone in reverse landscape is not upside down in SAMBA (SRT/SBL/RTMP).
            releaseRelay()
            relay = try { RotatingRelay(encoderSurface!!, encW, encH) }
                    catch (e: Exception) { Log.w(TAG, "RotatingRelay unavailable (${e.message}): direct to the encoder"); null }
            if (relay != null) {
                updateRelayRotation()
                val dm = context.getSystemService(Context.DISPLAY_SERVICE) as android.hardware.display.DisplayManager
                displayListener = object : android.hardware.display.DisplayManager.DisplayListener {
                    override fun onDisplayAdded(id: Int) {}
                    override fun onDisplayRemoved(id: Int) {}
                    override fun onDisplayChanged(id: Int) { updateRelayRotation() }
                }.also { dm.registerDisplayListener(it, android.os.Handler(android.os.Looper.getMainLooper())) }
                android.os.Handler(android.os.Looper.getMainLooper()).post { startOrientationListener() }
                Log.i(TAG, "Stream turned in pixels: ${relay?.rotation}°")
            }

            // Restart camera session with encoder surface
            captureSession?.close()
            startPreviewSession()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Encoder setup failed at ${width}x${height}: $e", e)
            lastEncoderError = "${width}x${height}: $e" + (e.cause?.let { " ← $it" } ?: "")
            try { encoder?.release() } catch (_: Exception) {}
            encoder = null
            releaseRelay()
            encoderSurface = null
            false
        }
    }

    // ====================================================================
    // Heat (DT-145)
    // ====================================================================
    private fun startHeatGuard() {
        heatDownshifted = false
        heat?.stop()
        heat = HeatGuard(context,
            onStatus = { s -> onThermalStatus(s) },
            onSlowEncoder = { fps -> heatDownshift("codificador a ${"%.1f".format(fps)} fps (sin dato térmico o antes de él)") },
        ).also { it.start() }
    }

    // Android thermal status: from MODERATE the bitrate gets a ceiling (less work for the encoder and the radio);
    // from SEVERE the picture goes down to 1080p. Back to normal only lifts the ceiling: the size stays at 1080p
    // until the next stream, so a phone at the edge does not bounce between 4K and 1080p.
    private fun onThermalStatus(s: Int) {
        thermalStatus = s
        val msg = "[calor] estado térmico ${HeatGuard.name(s)} · ${encWidth}x${encHeight}\n"
        Log.i(TAG, msg.trim())
        Thread { sendLogBytes(msg, "heat") }.start()
        when {
            s >= PowerManager.THERMAL_STATUS_SEVERE -> {
                abr?.setHeatCeiling(0.6, "estado ${HeatGuard.name(s)}")
                heatDownshift("estado térmico ${HeatGuard.name(s)}")
            }
            s >= PowerManager.THERMAL_STATUS_MODERATE -> abr?.setHeatCeiling(0.6, "estado ${HeatGuard.name(s)}")
            else -> abr?.setHeatCeiling(1.0, "estado ${HeatGuard.name(s)}")
        }
    }

    // Swap the encoder for a 1080p one without stopping the stream (once per stream). The encode thread holds
    // encLock per buffer, so it never touches the old encoder after it is released. Each transport picks up the new
    // parameter sets from INFO_OUTPUT_FORMAT_CHANGED (SRT: TS muxer, SBL: frame header + SPS/PPS, RTMP: new AVC
    // sequence header); the new encoder starts with an IDR.
    private fun heatDownshift(why: String) {
        if (heatDownshifted || !streaming.get() || encWidth <= 1920) return
        heatDownshifted = true
        thread(name = "HeatDownshift") {
            val from = "${encWidth}x${encHeight}"
            var ok = false
            encLock.lock()
            try {
                if (!streaming.get()) return@thread
                releaseRelay()
                try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
                encoder = null
                encoderSurface?.release(); encoderSurface = null
                sblSps = null; sblPps = null
                ok = setupEncoder(encCodec, 1920, 1080, 16_000_000, encKeyframeMs, operatingRate = 0)
            } finally { encLock.unlock() }
            val msg = if (ok) {
                if (abrLabel.isNotEmpty() && abr != null) {
                    startAbr(abrLabel)                                   // max = the new encoder's bitrate
                    if (thermalStatus >= PowerManager.THERMAL_STATUS_MODERATE)
                        abr?.setHeatCeiling(0.6, "estado ${HeatGuard.name(thermalStatus)}")
                }
                sblPaceBps = encBitrate.toLong()
                "[calor] $why → baja de $from a ${encWidth}x${encHeight} @${encBitrate / 1000} kbps sin cortar\n"
            } else "[calor] $why → no pudo rearmar el codificador ($lastEncoderError)\n"
            if (ok) Log.w(TAG, msg.trim()) else Log.e(TAG, msg.trim())
            Thread { sendLogBytes(msg, "heat") }.start()
        }
    }

    private fun requestIdr() {
        try {
            encoder?.setParameters(android.os.Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: Exception) { Log.w(TAG, "IDR request failed: $e") }
    }

    private fun stopStream() {
        if (!streaming.getAndSet(false)) return
        heat?.stop(); heat = null
        tallyAtMs = 0L; tallyPgm = false; tallyPrv = false
        retLogAtMs = 0L
        encodeThread?.join(2000); encodeThread = null
        audioInThread?.join(1000);  audioInThread  = null
        audioOutThread?.join(1000); audioOutThread = null
        sblMicThread?.join(1000)
        stopSblMicUplink()
        sblSps = null; sblPps = null   // re-captured on the next stream
        micProc.release()
        try { audioRecord?.stop(); audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { audioEncoder?.stop(); audioEncoder?.release() } catch (_: Exception) {}
        audioEncoder = null
        try { encoder?.signalEndOfInputStream() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        encoder = null
        releaseRelay()
        encoderSurface?.release(); encoderSurface = null
        srtSocket?.close(); srtSocket = null
        srtMuxer = null
        rtmpClient?.disconnect(); rtmpClient = null
        abr = null
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
            micProc.attach(audioRecord!!.audioSessionId, audioSampleRate)
            Log.i(TAG, "Audio: ${audioSampleRate}Hz mono 128kbps AAC · sonido ${micProc.label()}")
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
                noteMicPcm(pcm, n)
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
                micPkts.incrementAndGet()
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
        val sourceName  = call.argument<String>("sourceName") ?: ""

        thread(name = "SrtStart") {
            try {
                pillarboxPixels = false          // SRT: SAMBA turns it from SROT
                if (!setupEncoder(codec, width, height, bitrate, keyframeMs)) {
                    result.error("ENC", "Encoder setup failed — $lastEncoderError", null); return@thread
                }
                setupAudio()

                srtSocket = SrtSocket(ip, port, latencyMs, srtStreamId(sourceName)).also { sk ->
                    sk.onReconnected = { downMs ->
                        requestIdr()   // the receiver must not wait for the next GOP
                        Thread { sendLogBytes("[srt] reconectado a $ip:$port por ${sk.mode} tras ${downMs} ms\n", "reconnect") }.start()
                    }
                }
                if (!srtSocket!!.connect()) throw Exception("SRT connect to $ip:$port failed")
                startAbr("SRT")

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
                startHeatGuard()

                result.success(null)
                val how = srtSocket?.mode ?: "?"
                Log.i(TAG, "SRT streaming → $ip:$port ${width}x$height @${bitrate/1000}kbps $codec por $how")
                Thread { sendLogBytes("[srt] transporte: $how → $ip:$port (latencia $latencyMs ms)\n", "transport") }.start()
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
            // Built AND sent under the send lock: [pace], [retorno], [abr], [tally]... each go out on their own thread,
            // and muxing two at once (or one with the orientation packet, same PID) broke the 0x1FF0 continuity counter.
            val bytes = text.toByteArray(Charsets.UTF_8)
            synchronized(sendLock) { for (p in mux.muxLog(bytes, reason)) sock.send(p) }
            true
        } catch (e: Exception) { Log.w(TAG, "sendLog: $e"); false }
    }

    // What SAMBA still has to turn the SRT picture (CVO 0..3): the camera's upright turn minus what the relay
    // already turned in pixels (landscape upside down). Portrait used to rely on KEY_ROTATION, which MPEG-TS
    // never carries → the phone held upright arrived sideways in SAMBA (2026-10-08).
    /**
     * SRT stream id, SRT Access Control style: «#!::r=<camera name>,u=<phone id>». SAMBA shows r= and tells phones
     * apart by u=: two phones with the same name (same model → same default name) keep their own source and suffix
     * whatever order they connect in (2026-10-21). u = 8 hex of SHA-256(ANDROID_ID): fixed per phone (and app
     * signing key), survives reinstalls and reconnections, and does not expose the raw id. ',' would split the
     * fields, so it becomes a space in the name.
     */
    private fun srtStreamId(name: String): String {
        val raw = try {
            android.provider.Settings.Secure.getString(context.contentResolver, android.provider.Settings.Secure.ANDROID_ID)
        } catch (_: Exception) { null } ?: (Build.MANUFACTURER + Build.MODEL + Build.FINGERPRINT)
        val id = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray())
            .take(4).joinToString("") { "%02x".format(it) }
        val r = name.replace(',', ' ').trim().take(400)   // SRTO_STREAMID holds 512 bytes
        return if (r.isEmpty()) "#!::u=$id" else "#!::r=$r,u=$id"
    }

    private fun srtCvo(): Int = ((streamUprightDegrees() - (relay?.rotation ?: 0) + 360) % 360) / 90

    // Orientation tied to the FRAMES, not to the moment of the turn (2026-10-09). The video reaches SAMBA a few hundred
    // ms after it is shot (encoder + network + receive buffer) but the orientation went out at once, so SAMBA turned
    // frames shot BEFORE the turn — wrong for the whole delay. Now a change is armed (the relay marks the first camera
    // frame drawn after it) and takes effect from the first ENCODED frame with that timestamp: SRT sends SROT right
    // before that frame, SBL stamps every frame with the orientation it was shot with.
    @Volatile private var frameCvo = 0
    private var pendingCvo = -1
    private val cvoLock = Any()
    private fun armCvoChange() = synchronized(cvoLock) {
        val t = srtCvo()
        if (t == frameCvo) { pendingCvo = -1; return@synchronized }        // no change, or turned back in time
        if (t == pendingCvo) return@synchronized
        pendingCvo = t
        val r = relay
        if (r == null) { frameCvo = t; pendingCvo = -1 } else r.requestMark()
    }
    private fun cvoForFrame(ptsUs: Long): Int = synchronized(cvoLock) {
        if (pendingCvo >= 0) {
            val r = relay
            val mark = r?.markTsNs ?: Long.MIN_VALUE
            if (r == null || (mark != Long.MIN_VALUE && ptsUs * 1000 >= mark)) { frameCvo = pendingCvo; pendingCvo = -1 }
        }
        frameCvo
    }
    private fun resetCvo() = synchronized(cvoLock) { frameCvo = srtCvo(); pendingCvo = -1 }

    private fun drainToSrt(muxer: TsMuxer) {
        val info = MediaCodec.BufferInfo()
        var lastCvo = -1
        var lastCvoSentMs = 0L
        var lastCvoCheckMs = 0L
        // Pacing, every 5 s (DT-293): to tell «the phone/encoder is late» from «the phone sends evenly and the network
        // bunches it». Wall clock (nanoTime), video frames only; SAMBA measures the same on arrival.
        var paceStartNs = System.nanoTime()
        var lastOutNs = 0L; var lastSendNs = 0L; var lastPtsUs = -1L
        var maxOutGapNs = 0L; var maxSendGapNs = 0L; var maxSendNs = 0L; var maxPtsGapUs = 0L; var paceFrames = 0
        resetCvo()
        while (streaming.get()) {
            // Orientation: a change is ARMED when the phone turns (checked every 250 ms) and sent with the first frame
            // shot after it (below); the current one is repeated every ~1 s (survives a reconnect).
            val nowMs = System.currentTimeMillis()
            if (nowMs - lastCvoCheckMs >= 250) {
                lastCvoCheckMs = nowMs
                armCvoChange()
                if (lastCvo >= 0 && nowMs - lastCvoSentMs >= 1000) {
                    synchronized(sendLock) { for (p in muxer.muxRotation(lastCvo)) srtSocket?.send(p) }
                    lastCvoSentMs = nowMs
                }
            }
            encLock.lock()
            try {
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
            val isFrame = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
            if (isFrame) {
                heat?.noteFrame(info.presentationTimeUs)
                val tOut = System.nanoTime()
                if (lastOutNs != 0L) maxOutGapNs = maxOf(maxOutGapNs, tOut - lastOutNs)
                lastOutNs = tOut
                if (lastPtsUs >= 0) maxPtsGapUs = maxOf(maxPtsGapUs, info.presentationTimeUs - lastPtsUs)
                lastPtsUs = info.presentationTimeUs
            }
            if (isFrame) {
                val cvo = cvoForFrame(info.presentationTimeUs)
                if (cvo != lastCvo) {                    // right before the first frame shot with it
                    synchronized(sendLock) { for (p in muxer.muxRotation(cvo)) srtSocket?.send(p) }
                    val msg = "[orientación] SRT → rotación $cvo (${cvo * 90}°)\n"
                    Log.i(TAG, msg.trim())
                    Thread { sendLogBytes(msg, "orientation") }.start()
                    lastCvo = cvo; lastCvoSentMs = System.currentTimeMillis()
                }
            }
            // ONE write per frame (2026-10-09). Writing each 188-byte TS packet on its own (tcpNoDelay) meant ~20 000
            // writes and TCP segments a second at 4K / 30 Mbps: this thread pegged a CPU core and the Wi-Fi radio
            // sent tiny segments — the phone overheated and its encoder throttled to ~3 fps (jerky picture in SAMBA).
            val pkts = muxer.mux(buf, info)
            if (pkts.isNotEmpty()) {
                val joined = ByteArray(pkts.size * 188)
                for ((i, pkt) in pkts.withIndex()) pkt.copyInto(joined, i * 188)
                val t0 = System.nanoTime()
                synchronized(sendLock) { srtSocket?.send(joined) }
                if (isFrame) {
                    val t1 = System.nanoTime()
                    if (lastSendNs != 0L) maxSendGapNs = maxOf(maxSendGapNs, t0 - lastSendNs)
                    lastSendNs = t0
                    maxSendNs = maxOf(maxSendNs, t1 - t0)
                    paceFrames++
                }
                bytesSent.addAndGet(joined.size.toLong())
            }
            val nowNs = System.nanoTime()
            if (nowNs - paceStartNs >= 5_000_000_000L) {
                val sock = srtSocket
                val msg = "[pace] ${sock?.mode ?: "-"} · $paceFrames cuadros en 5 s · codificador: mayor salto " +
                    "${maxOutGapNs / 1_000_000} ms (PTS ${maxPtsGapUs / 1000} ms) · envío: mayor salto " +
                    "${maxSendGapNs / 1_000_000} ms, más largo ${maxSendNs / 1_000_000} ms" +
                    (sock?.takePaceStats()?.let { " · $it" } ?: "") + "\n"
                Log.i(TAG, msg.trim())
                Thread { sendLogBytes(msg, "pace") }.start()
                maybeLogReturn(force = true)   // same 5 s window as [pace]
                paceStartNs = nowNs
                maxOutGapNs = 0L; maxSendGapNs = 0L; maxSendNs = 0L; maxPtsGapUs = 0L; paceFrames = 0
            }
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            } finally { encLock.unlock() }
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
                pillarboxPixels = true           // RTMP: upright in the pixels (no orientation on the wire)
                if (!setupEncoder("h264", width, height, bitrate, keyframeMs)) {
                    result.error("ENC", "Encoder setup failed — $lastEncoderError", null); return@thread
                }
                setupAudio()                     // the mic → AAC, as SRT does (RTMP used to go out without audio)
                streamClock = StreamClock()
                val st = RtmpStreamer()
                st.onNeedKeyframe = { requestIdr() }
                val hasAudio = audioEncoder != null
                st.setMetadata(width, height, 30, bitrate / 1000, if (hasAudio) 128 else 0,
                               if (hasAudio) audioSampleRate else 0, audioChannels)
                st.connect(url, "")              // rtmp(s)://host[:port]/app/KEY — the key is the URL's last segment
                rtmpClient = st

                streaming.set(true)
                startAudioInputThread()
                startRtmpAudioOutputThread(st)
                encodeThread = thread(name = "RtmpEncode") { drainToRtmp(st) }
                startHeatGuard()

                result.success(null)
                Log.i(TAG, "RTMP streaming → $url ${width}x$height @${bitrate/1000}kbps H.264, audio=$hasAudio")
            } catch (e: Exception) {
                Log.e(TAG, "startRtmp failed: $e")
                stopStream()
                result.error("RTMP_ERR", e.message, null)
            }
        }
    }

    // The publisher reconnects by itself; this loop only keeps feeding it (frames are skipped while the link is down).
    private fun drainToRtmp(st: RtmpStreamer) {
        val info = MediaCodec.BufferInfo()
        val out = MediaCodec.BufferInfo()
        var spsData: ByteArray? = null
        var ppsData: ByteArray? = null
        var headerSet = false

        while (streaming.get()) {
            encLock.lock()
            try {
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    headerSet = false            // a new encoder (heat → 1080p): new AVC sequence header
                    val fmt = encoder!!.outputFormat
                    spsData = fmt.getByteBuffer("csd-0")?.let { ByteArray(it.remaining()).also { a -> it.duplicate().get(a) } }
                    ppsData = fmt.getByteBuffer("csd-1")?.let { ByteArray(it.remaining()).also { a -> it.duplicate().get(a) } }
                    continue
                }
                idx < 0 -> continue
            }
            val buf = encoder!!.getOutputBuffer(idx) ?: run {
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                // Some encoders deliver SPS+PPS as a buffer instead of (or as well as) csd-0/csd-1.
                if (spsData == null) spsData = ByteArray(info.size).also { buf.duplicate().apply { position(info.offset) }.get(it) }
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            // csd-0 may hold SPS and PPS together (csd-1 absent): the header builder finds each by NAL type.
            if (!headerSet && spsData != null) {
                val all = spsData!! + (ppsData ?: ByteArray(0))
                st.setSpsPps(all, all); headerSet = true
            }
            val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
            heat?.noteFrame(info.presentationTimeUs)
            out.set(info.offset, info.size, streamClock.video.sessionUs(info.presentationTimeUs), info.flags)
            st.sendVideoData(buf, out, isKey)
            bytesSent.addAndGet(info.size.toLong())
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            } finally { encLock.unlock() }
        }
    }

    private fun startRtmpAudioOutputThread(st: RtmpStreamer) {
        val enc = audioEncoder ?: return
        audioOutThread = thread(name = "RtmpAudioOut") {
            val info = MediaCodec.BufferInfo()
            val out = MediaCodec.BufferInfo()
            while (streaming.get()) {
                val idx = enc.dequeueOutputBuffer(info, 10_000)
                when {
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        enc.outputFormat.getByteBuffer("csd-0")?.let { b ->
                            st.setAudioConfig(ByteArray(b.remaining()).also { b.duplicate().get(it) })
                        }
                        continue
                    }
                    idx < 0 -> continue
                }
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) { enc.releaseOutputBuffer(idx, false); continue }
                val buf = enc.getOutputBuffer(idx) ?: run { enc.releaseOutputBuffer(idx, false); continue }
                out.set(info.offset, info.size, streamClock.audio.sessionUs(info.presentationTimeUs), info.flags)
                st.sendAudioData(buf, out)
                enc.releaseOutputBuffer(idx, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
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

        thread(name = "SblStart") {
            try {
                pillarboxPixels = false          // SBL: orientation in the frame header
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
                // The size and bitrate the encoder accepted, not the ones requested (see encWidth / encBitrate).
                val w = encWidth; val h = encHeight
                sblPaceBps = encBitrate.toLong()
                startAbr("SBL")
                encodeThread = thread(name = "SblEncode") { drainToSbl() }
                startHeatGuard()
                result.success(null)
                Log.i(TAG, "SBL streaming → $host:$port ${w}x${h} @${encBitrate/1000}kbps (pedido ${width}x${height} @${bitrate/1000}kbps)")
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
            // MIC, as SRT. VOICE_COMMUNICATION (the phone's call processing: echo cancelling, noise suppression) reached
            // SAMBA as digital silence (−108 dB with a tone playing in the room, the return on the loudspeaker), while
            // the same phone by SRT gave −30/−40 (DT-315, 2026-10-26).
            sblMicRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC, SBL_AUDIO_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minBuf * 4)
            sblMicRecord!!.startRecording()
            micProc.attach(sblMicRecord!!.audioSessionId, SBL_AUDIO_RATE)

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
                noteMicPcm(pcm, n)
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
                        micPkts.incrementAndGet()
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

    private fun drainToSbl() {
        val info = MediaCodec.BufferInfo()
        var keepaliveNs = System.nanoTime()
        var cvoCheckNs = 0L
        resetCvo()
        while (streaming.get()) {
            // Keepalive every 1s
            val now = System.nanoTime()
            if (now - cvoCheckNs > 250_000_000L) { cvoCheckNs = now; armCvoChange() }   // orientation → frame header
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
            encLock.lock()
            try {
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

            sblFrameCvo = cvoForFrame(info.presentationTimeUs)
            heat?.noteFrame(info.presentationTimeUs)
            // encWidth/encHeight, not the size at start: heat can swap the encoder for a 1080p one (DT-145).
            sendSblVideoFrame(nalData, isKey, streamClock.video.sessionUs(info.presentationTimeUs), encWidth, encHeight)
            bytesSent.addAndGet(nalData.size.toLong())
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            maybeLogReturn()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            } finally { encLock.unlock() }
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
                // reserved → orientation (2026-10-09, DT-139): 0x80 | CVO 0..3, the same value SRT sends as SROT.
                // SAMBA turns the picture from it; 0 (older apps) = no orientation, as before.
                pkt.putInt(0x80 or sblFrameCvo)
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
    // SrtSocket — MPEG-TS to SAMBA over real SRT (libsrt through srtdroid: UDP, live mode), TCP as the fallback.
    // ====================================================================
    // Until 2026-10-20 this was plain TCP («SRT» in name only). On a lossy Wi-Fi TCP stalls every later byte until a
    // lost one is resent (head-of-line): a Galaxy A10 on 2.4 GHz sending 15 Mbps averaged 30 fps in SAMBA but paused
    // 260-390 ms every few seconds. SRT resends only what was lost, inside a fixed latency window, and drops what is
    // too late instead of stalling the stream.
    //   - SRT caller, live mode, latency = srtLatencyMs, 1316-byte messages (7 TS packets), 25 % overhead for resends.
    //   - When the SRT handshake does not complete (~2 s: an older SAMBA, a busy listener) it falls back to TCP on the
    //     same port, as before. The mode in use is in [mode] («SRT» / «SRT (TCP)»), on screen and in the logs.
    // It HEALS ITSELF (2026-10-03): a failed write or one blocked > 3 s marks the link DOWN at once; while down,
    // packets are dropped (camera and encoder keep running) and a watchdog reconnects every second, trying the mode
    // that last worked first; on success onReconnected asks the encoder for an IDR.
    private inner class SrtSocket(val ip: String, val port: Int, val latencyMs: Int, val streamId: String) {
        @Volatile private var srt: LibSrtSocket? = null
        @Volatile private var tcpSocket: Socket? = null
        @Volatile private var out: OutputStream? = null
        @Volatile var linkUp = false; private set
        @Volatile var reconnects = 0; private set
        /** «SRT» (UDP) or «SRT (TCP)» (fallback); empty before the first connection. */
        @Volatile var mode = ""; private set
        @Volatile private var rttMs = 0
        @Volatile private var writeStartMs = 0L        // > 0 while a write is in progress
        @Volatile private var maxWriteMs = 0L          // longest write since the last bitrate sample
        @Volatile private var closed = false
        @Volatile private var downSinceMs = 0L
        private var watchdog: Thread? = null
        var onReconnected: ((downMs: Long) -> Unit)? = null

        private fun openSrt(): Boolean {
            val s = connectSrt() ?: return false
            adoptSrt(s)
            return true
        }

        /** The latency SRT agreed with SAMBA (the larger of both sides'): what the send queue is measured against. */
        @Volatile private var effLatencyMs = latencyMs

        private fun adoptSrt(s: LibSrtSocket) {
            effLatencyMs = try { (s.getSockFlag(SockOpt.PEERLATENCY) as Number).toInt() } catch (_: Exception) { latencyMs }
                .coerceAtLeast(latencyMs)
            srt = s; mode = "SRT"; linkUp = true
            srtUpAtMs = System.currentTimeMillis(); severeStreak = 0
            Log.i(TAG, "SRT (UDP, libsrt) connected → $ip:$port, latency $latencyMs ms (acordada $effLatencyMs ms)")
            startReceive(s)
        }

        /** A connected SRT socket, or null. */
        private fun connectSrt(): LibSrtSocket? {
            if (!SrtLib.ready) return null
            val s = try { LibSrtSocket() } catch (t: Throwable) { Log.w(TAG, "SRT socket: $t"); return null }
            fun opt(o: SockOpt, v: Any) = try { s.setSockFlag(o, v) } catch (e: Exception) { Log.w(TAG, "SRT $o=$v: $e") }
            return try {
                s.setSockFlag(SockOpt.TRANSTYPE, Transtype.LIVE)
                s.setSockFlag(SockOpt.LATENCY, latencyMs)
                opt(SockOpt.PAYLOADSIZE, SRT_PAYLOAD)
                // Fixed ceiling (bytes/s), 1.5x the configured video rate + 1 Mbps (DT-314). It used to be 0 = the input
                // rate measured by libsrt + 25 %. The 4K start-up burst (22 Mbps for ~5 s on the Mi A3's 2.4 GHz)
                // left seconds of video queued. Then the ABR cut the input to ~1 Mbps, and that cut the drain rate
                // with it (input + 25 %): the queue grew to 19 s with the encoder at 1 Mbps, and SAMBA got video 19 s
                // late (2026-10-26). With a ceiling tied to the configured rate, a backlog drains as fast as the link
                // allows, whatever the ABR is doing.
                opt(SockOpt.MAXBW, (encBitrate.toLong() * 3 / 2 + 1_000_000L) / 8)
                opt(SockOpt.CONNTIMEO, 2000)
                opt(SockOpt.PEERIDLETIMEO, 3000)       // SAMBA silent 3 s = link down (the default is 5 s)
                if (streamId.isNotEmpty()) opt(SockOpt.STREAMID, streamId)
                s.connect(ip, port)
                s
            } catch (e: Exception) {
                Log.w(TAG, "SRT connect to $ip:$port failed: $e")
                try { s.close() } catch (_: Exception) {}
                null
            }
        }

        /**
         * Back from the TCP fallback to real SRT. A reconnect while SAMBA was restarting found SRT not answering yet
         * and TCP answering, and the camera stayed on TCP for good (2026-10-21). Every 10 s on TCP: connect SRT on the
         * side and, if it answers, swap under the send lock (no frame goes half on each) and drop TCP.
         */
        private var lastUpgradeTryMs = 0L
        private fun tryUpgradeToSrt(now: Long) {
            if (now - lastUpgradeTryMs < 10_000) return
            lastUpgradeTryMs = now
            val s = connectSrt() ?: return
            synchronized(sendLock) {
                if (closed || !linkUp || srt != null) { try { s.close() } catch (_: Exception) {}; return }
                try { tcpSocket?.close() } catch (_: Exception) {}
                tcpSocket = null; out = null
                adoptSrt(s)
            }
            reconnects++
            Log.i(TAG, "SRT: vuelve de TCP a SRT real")
            onReconnected?.invoke(0)
        }

        /** What SAMBA sends back on this SRT connection (tally, return audio): see [processSrtReturn]. */
        private fun startReceive(s: LibSrtSocket) {
            thread(name = "SrtReceive", isDaemon = true) {
                val buf = ByteArray(1500)
                while (!closed && srt === s) {
                    try {
                        val n = s.recv(buf, 0, buf.size)
                        if (n > 0) processSrtReturn(buf, n)
                    } catch (e: Exception) {
                        if (closed || srt !== s) break
                        try { Thread.sleep(50) } catch (_: InterruptedException) { break }
                    }
                }
            }
        }

        private fun openTcp(): Boolean = try {
            val sk = Socket()
            sk.tcpNoDelay = true; sk.keepAlive = true; sk.soTimeout = 0
            sk.connect(java.net.InetSocketAddress(ip, port), 2000)
            tcpSocket = sk; out = sk.getOutputStream(); mode = "SRT (TCP)"; linkUp = true
            Log.i(TAG, "SRT/TCP (fallback) connected → $ip:$port")
            true
        } catch (e: Exception) {
            Log.w(TAG, "SRT/TCP connect to $ip:$port failed: $e")
            false
        }

        /** The mode that worked last goes first; SRT first on the first connection. */
        private fun open(): Boolean =
            if (mode == "SRT (TCP)") openTcp() || openSrt() else openSrt() || openTcp()

        fun connect(): Boolean {
            val ok = open()
            if (ok) startWatchdog()
            return ok
        }

        /** [data] is whole 188-byte TS packets. SRT carries them as messages of up to 7 (1316 bytes). */
        fun send(data: ByteArray) {
            if (!linkUp) return
            val t0 = System.currentTimeMillis()
            writeStartMs = t0
            try {
                val s = srt
                if (s != null) {
                    var off = 0
                    while (off < data.size) {
                        val n = minOf(SRT_PAYLOAD, data.size - off)
                        // inOrder: SAMBA reads with TSBPD off (each message as soon as it is complete); a resent
                        // message must not be handed over after the ones that followed it, or the TS comes out of
                        // order and the video continuity counter «jumps» at every RTT spike (2026-10-21).
                        s.send(data, off, n, -1, true)
                        off += n
                    }
                } else {
                    (out ?: return).write(data)
                }
            } catch (e: Exception) { markDown("write failed: $e") }
            finally {
                writeStartMs = 0L
                val dt = System.currentTimeMillis() - t0
                if (dt > maxWriteMs) maxWriteMs = dt
            }
        }

        private fun markDown(why: String) {
            if (!linkUp || closed) return
            linkUp = false
            downSinceMs = System.currentTimeMillis()
            Log.w(TAG, "$mode link DOWN ($why) — reconnecting every 1 s")
            dropTransport()   // unblocks a writer stuck in a write
        }

        private fun dropTransport() {
            try { srt?.close() } catch (_: Exception) {}
            try { tcpSocket?.close() } catch (_: Exception) {}
            srt = null; tcpSocket = null; out = null
        }

        private var lastStatsMs = 0L
        @Volatile private var srtUpAtMs = 0L     // when this SRT connection came up
        private var severeStreak = 0             // consecutive 1 s samples with a queue over 2x the latency
        // Summed / maxed over the [pace] window (DT-293): what libsrt itself queued, resent and dropped.
        private val paceLock = Any()
        private var paceSndBufMaxMs = 0
        private var paceRetrans = 0L
        private var paceLost = 0L
        private var paceDropped = 0L
        private var paceRttMaxMs = 0

        /** libsrt's side of the [pace] line since the last call (empty on the TCP fallback), then reset. */
        fun takePaceStats(): String? = synchronized(paceLock) {
            if (srt == null) return@synchronized null
            val r = "SRT: colchón de envío máx $paceSndBufMaxMs ms, reenviados $paceRetrans, perdidos $paceLost, " +
                "descartados $paceDropped, RTT máx $paceRttMaxMs ms"
            paceSndBufMaxMs = 0; paceRetrans = 0; paceLost = 0; paceDropped = 0; paceRttMaxMs = 0
            r
        }

        private fun srtSample(s: LibSrtSocket, now: Long) {
            if (now - lastStatsMs < 1000) return
            lastStatsMs = now
            val st = try { s.bstats(true) } catch (e: Exception) { return }
            rttMs = st.msRTT.toInt()
            synchronized(paceLock) {
                paceSndBufMaxMs = maxOf(paceSndBufMaxMs, st.msSndBuf)
                paceRetrans += st.pktRetrans.toLong()
                paceLost += st.pktSndLoss.toLong()
                paceDropped += st.pktSndDrop.toLong()
                paceRttMaxMs = maxOf(paceRttMaxMs, st.msRTT.toInt())
            }
            val sent = st.pktSent
            val lossPct = if (sent > 0) st.pktSndLoss * 100.0 / sent else 0.0
            // Lost and resent packets are SRT's normal work. The send queue (msSndBuf, time span of unacknowledged data)
            // is the signal, measured against latency + RTT - the data in flight on a slow link (DT-302/304, 2026-10-21):
            //  - packets dropped (they waited past the latency), or a queue over 2x latency + RTT for 2 s in a row = the
            //    Wi-Fi is far from carrying this rate: cut hard, toward what libsrt measured it delivered. A 4K start at
            //    30 Mbps on a 2.4 GHz Wi-Fi used to take ~10 s of 1 s queues and ~1500 drops per 2 s to come down;
            //  - queue over latency + RTT, or loss > 5 % = a bit too much: the usual -30 %;
            //  - else clean (rises after 8 s). A clean 5 GHz link sits at a 25-60 ms queue: a «hold» tier at RTT + 20 ms
            //    kept the Redmi stuck at 5 Mbps for minutes.
            // The first 3 s of a connection only count drops: the encoder starts with a stall and a burst (and a 4K
            // IDR), a 340 ms queue that is not congestion - it cut the Redmi 21 -> 10.5 -> 5 Mbps on a clean Wi-Fi.
            val q = st.msSndBuf
            val rtt = st.msRTT.toInt()
            val detail = "SRT pérdida ${"%.1f".format(lossPct)} %, descartados ${st.pktSndDrop}, " +
                "buffer $q ms, RTT $rtt ms"
            val warmingUp = now - srtUpAtMs < 3000
            val lat = effLatencyMs
            severeStreak = if (q > 2 * lat + rtt) severeStreak + 1 else 0
            val a = abr
            when {
                st.pktSndDrop > 0 || (!warmingUp && severeStreak >= 2) -> a?.reportSevere(st.mbpsSendRate, detail)
                warmingUp -> {}
                lossPct > 5.0 || q > lat + rtt -> a?.report(true, detail)
                else -> a?.report(false, detail)
            }
            val lossy = st.pktSndDrop > 0 || lossPct > 5.0 || q > lat + rtt
            if (lossy) Log.i(TAG, "SRT stats: sent $sent, lost ${st.pktSndLoss}, retrans ${st.pktRetrans}, " +
                "dropped ${st.pktSndDrop}, sndBuf ${st.msSndBuf} ms, RTT ${st.msRTT} ms, bw ${"%.1f".format(st.mbpsBandwidth)} Mbps")
        }

        private fun startWatchdog() {
            watchdog = thread(name = "SrtWatchdog", isDaemon = true) {
                var lastTry = 0L
                while (!closed) {
                    try { Thread.sleep(500) } catch (_: InterruptedException) { break }
                    val now = System.currentTimeMillis()
                    if (linkUp) {
                        val ws = writeStartMs
                        if (ws > 0 && now - ws > 3000) { markDown("write blocked ${now - ws} ms"); continue }
                        val s = srt
                        if (s != null) {
                            val st = try { s.sockState } catch (_: Exception) { null }
                            if (st == SockStatus.BROKEN || st == SockStatus.CLOSED || st == SockStatus.NONEXIST) {
                                markDown("SRT $st"); continue
                            }
                            srtSample(s, now)
                        } else {
                            // A write that waits > 150 ms = the TCP send buffer is full: the Wi-Fi does not carry this rate.
                            val mw = maxOf(maxWriteMs, if (ws > 0) now - ws else 0L)
                            maxWriteMs = 0L
                            abr?.report(mw > 150, "escritura TCP trabada $mw ms")
                            tryUpgradeToSrt(now)
                        }
                    } else if (!closed && now - lastTry >= 1000) {
                        lastTry = now
                        if (open()) {
                            reconnects++
                            val down = now - downSinceMs
                            Log.i(TAG, "$mode reconnected after $down ms (#$reconnects)")
                            onReconnected?.invoke(down)
                        }
                    }
                }
            }
        }

        fun getRttMs(): Int = rttMs  // SRT measures it; TCP does not (0)

        fun close() {
            closed = true
            dropTransport(); linkUp = false
            watchdog?.interrupt(); watchdog = null
        }
    }

    // =========================================================================
    // SBL AudioReturn — receive Opus packets from engine, decode, play
    // =========================================================================

    /**
     * The Opus decoder's format, built fresh for every decoder (configure reads the CSD buffers).
     * csd-1 was an EMPTY buffer: Codec2's C2SoftOpusDec (Mi A3, Galaxy A10) takes csd-1 as the codec delay, an 8-byte
     * time in ns, and rejects anything shorter ("Input sample size is too small") - the decoder died at once, was
     * recreated every second and the return audio never played there (DT-301, 2026-10-21). The Redmi's decoder
     * tolerated it. Pre-skip 312 samples = libopus' lookahead at 48 kHz (was 3840 = 80 ms of audio thrown away).
     */
    private fun opusReturnFormat(): android.media.MediaFormat {
        val preSkip = 312
        val opusHead = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
        opusHead.put("OpusHead".toByteArray(Charsets.US_ASCII))  // magic (8)
        opusHead.put(1.toByte())        // version
        opusHead.put(1.toByte())        // channels = 1 (mono)
        opusHead.putShort(preSkip.toShort())
        opusHead.putInt(48000)          // input sample rate
        opusHead.putShort(0)            // output gain
        opusHead.put(0.toByte())        // channel mapping family
        opusHead.flip()
        fun ns(v: Long) = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).also { it.flip() }
        val fmt = android.media.MediaFormat.createAudioFormat("audio/opus", 48000, 1)
        fmt.setByteBuffer("csd-0", opusHead)
        fmt.setByteBuffer("csd-1", ns(preSkip * 1_000_000_000L / 48000))   // codec delay, ns
        fmt.setByteBuffer("csd-2", ns(80_000_000L))                        // seek pre-roll 80 ms, ns
        return fmt
    }

    private fun initReturnAudio() {
        try {
            returnConfigured = true
            returnDecoder = newReturnDecoder()

            val minBuf = AudioTrack.getMinBufferSize(
                48000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            returnTrack = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    // MEDIA, not VOICE_COMMUNICATION: that one plays through the call earpiece, audible only with the
                    // phone against the ear (measured 2026-10-21). MEDIA goes to the loudspeaker, or to headphones /
                    // Bluetooth when connected. The «Retorno» button mutes it.
                    .setUsage(AudioAttributes.USAGE_MEDIA)
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
            Log.i(TAG, "AudioReturn: Opus decoder + AudioTrack ready")
        } catch (e: Exception) {
            Log.w(TAG, "SBL AudioReturn init failed: $e")
            returnDecoder?.release(); returnDecoder = null
            returnTrack?.release();   returnTrack   = null
        }
    }

    private fun stopReturnAudio() {
        srtReturnInit = false
        returnRunning.set(false)
        returnThread?.join(1000); returnThread = null
        synchronized(returnLock) {
            returnConfigured = false
            try { returnDecoder?.stop() } catch (_: Exception) {}
            returnDecoder?.release(); returnDecoder = null
            returnTrack?.stop();   returnTrack?.release();   returnTrack   = null
        }
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
        // Feedback (packet type 6, every 0.5 s): SAMBA's measured loss rate (SblFeedbackPayload.lossRatePct, a
        // big-endian float right after the bandwidth estimate). Ignored until 2026-10-04; now drives the bitrate.
        if ((buf[4].toInt() and 0xFF) == 6 && len >= 32 + 8) {
            val loss = java.nio.ByteBuffer.wrap(buf, 32 + 4, 4).order(java.nio.ByteOrder.BIG_ENDIAN).float
            if (!loss.isNaN()) abr?.report(loss > 1.5f, "pérdida %.1f %%".format(loss))
            return
        }
        if ((buf[4].toInt() and 0xFF) == 7) {
            abr?.report(true, "SAMBA pidió un cuadro completo (perdió fragmentos)")
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
        if ((buf[4].toInt() and 0xFF) == 0 && streamId == 4) { handleTallyFrame(buf, len); return }
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

    // ---- Tally from SAMBA (2026-10-20) --------------------------------------------------------------------------
    // SblSource::setTally sends it every 2 s and on every change: a Metadata FRAME (packetType 0 Data, streamID 4),
    // one fragment; payload = SblFrameHeader (32 B, codec 0xFF Raw) + MessagePack {"tally":{"pgm":bool,"prv":bool}}.
    // pgm = this camera is in the scene on air; prv = in the studio-mode preview. It used to be dropped here (only
    // streamID 3 went through), so the phone never showed it was on air.
    @Volatile private var tallyPgm = false
    @Volatile private var tallyPrv = false
    @Volatile private var tallyAtMs = 0L

    private fun handleTallyFrame(buf: ByteArray, len: Int) {
        val payloadLen = ((buf[24].toInt() and 0xFF) shl 8) or (buf[25].toInt() and 0xFF)
        val end = 32 + payloadLen
        if (payloadLen <= 32 || end > len) return
        val pgm = msgpackBool(buf, 64, end, "pgm") ?: return
        val prv = msgpackBool(buf, 64, end, "prv") ?: false
        if (tallyAtMs == 0L || pgm != tallyPgm || prv != tallyPrv) {
            val msg = "[tally] SAMBA: ${if (pgm) "AL AIRE" else if (prv) "en vista previa" else "fuera del aire"}\n"
            Log.i(TAG, msg.trim())
            Thread { sendLogBytes(msg, "tally") }.start()
        }
        tallyPgm = pgm; tallyPrv = prv; tallyAtMs = System.currentTimeMillis()
    }

    /** The bool after the MessagePack key [key] (a fixstr) in buf[from, to), or null if it is not there. */
    private fun msgpackBool(buf: ByteArray, from: Int, to: Int, key: String): Boolean? {
        val k = key.toByteArray(Charsets.US_ASCII)
        var i = from
        while (i + 1 + k.size < to) {
            if ((buf[i].toInt() and 0xFF) == 0xA0 + k.size &&
                (k.indices).all { buf[i + 1 + it] == k[it] }) {
                return when (buf[i + 1 + k.size].toInt() and 0xFF) { 0xC3 -> true; 0xC2 -> false; else -> null }
            }
            i++
        }
        return null
    }

    // ---- SAMBA → phone over the SRT connection -------------------------------------------------------------------
    // SRT is two-way: SAMBA sends back, on the connection it accepted, the SAME SBL v3 packets it sends an SBL phone
    // over UDP, one per SRT message - the tally (above) and the return audio (streamID 3, Opus), and maybe a keyframe
    // request. Agreed with SAMBA 2026-10-20 (it lands there after several SRT callers per port); until then nothing
    // arrives and nothing changes.
    private var srtReturnInit = false
    private fun processSrtReturn(buf: ByteArray, len: Int) {
        if (len < 32) return
        if (buf[0] != 0x53.toByte() || buf[1] != 0x42.toByte() || buf[2] != 0x4C.toByte()) return
        val type = buf[4].toInt() and 0xFF
        val streamId = buf[5].toInt() and 0xFF
        when {
            type == 0 && streamId == 4 -> handleTallyFrame(buf, len)
            type == 7 -> {
                val now = System.currentTimeMillis()
                if (now - lastForcedIdrMs >= 1000) { lastForcedIdrMs = now; requestIdr() }
            }
            streamId == 3 -> {
                val payloadLen = ((buf[24].toInt() and 0xFF) shl 8) or (buf[25].toInt() and 0xFF)
                if (payloadLen <= 0 || 32 + payloadLen > len) return
                if (!srtReturnInit) { srtReturnInit = true; initReturnAudio() }
                decodeAndPlay(buf, 32, payloadLen)
            }
        }
    }

    private var returnConfigured = false
    // The SRT receive thread decodes while stopStream releases the decoder ("releaseOutputBuffer() is valid only at
    // Executing states; currently during stop()", Redmi 2026-10-21): both go through this lock.
    private val returnLock = Any()
    private var returnPtsUs = 0L
    private var returnLastResetMs = 0L
    private var returnResets = 0

    private fun newReturnDecoder(): MediaCodec =
        MediaCodec.createDecoderByType("audio/opus").also { it.configure(opusReturnFormat(), null, null, 0); it.start() }

    // ---- Return audio, measured (2026-10-21): one «[retorno]» line every 5 s, so whether it arrives and where it
    // sounds does not depend on someone's ear. Counted on the receive thread, logged from the encode loop.
    private val retPkts = java.util.concurrent.atomic.AtomicLong()
    private val retBytes = java.util.concurrent.atomic.AtomicLong()
    private val retFrames = java.util.concurrent.atomic.AtomicLong()
    private val retSumSq = java.util.concurrent.atomic.AtomicLong()   // ≤ 2^30 per sample: no overflow in 5 s
    private val retSamples = java.util.concurrent.atomic.AtomicLong()
    private val retDroppedSamples = java.util.concurrent.atomic.AtomicLong()   // left out to keep the delay short
    private var retLogAtMs = 0L

    // ---- Microphone, measured (DT-315, 2026-10-26): by SBL and WHIP the mic reached SAMBA silent and nothing on the
    // phone said so. One «[mic]» line with the [retorno] one: what was captured (level and peak) and the audio packets
    // sent. Captured on the mic thread, logged from the encode loop.
    private val micSumSq = java.util.concurrent.atomic.AtomicLong()
    private val micSamples = java.util.concurrent.atomic.AtomicLong()
    private val micPeak = java.util.concurrent.atomic.AtomicInteger()
    private val micPkts = java.util.concurrent.atomic.AtomicLong()
    // Natural / voice / auto (MicProcessing.kt): the phone's noise suppressor on the mic's own session.
    private val micProc = MicProcessing { msg -> Log.i(TAG, msg.trim()); Thread { sendLogBytes(msg, "mic_mode") }.start() }

    private fun noteMicPcm(pcm: ByteArray, n: Int) {
        var sq = 0L; var peak = 0
        var i = 0
        while (i + 1 < n) {
            val v = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)).toShort().toInt()
            sq += v.toLong() * v; val a = if (v < 0) -v else v; if (a > peak) peak = a
            i += 2
        }
        micSumSq.addAndGet(sq); micSamples.addAndGet((n / 2).toLong())
        micProc.note(sq, n / 2)
        micPeak.accumulateAndGet(peak) { x, y -> maxOf(x, y) }
    }

    private fun micLine(via: String, secs: Double): String {
        val sq = micSumSq.getAndSet(0).toDouble(); val n = micSamples.getAndSet(0)
        val peak = micPeak.getAndSet(0); val pk = micPkts.getAndSet(0)
        val level = if (n > 0 && sq > 0) "%.0f dBFS (pico %.0f)".format(
                        10 * Math.log10(sq / n / (32768.0 * 32768.0)), 20 * Math.log10(maxOf(peak, 1) / 32768.0))
                    else if (n > 0) "silencio digital" else "nada capturado"
        return "[mic] $via · ${"%.0f".format(pk / secs)} paq/s enviados · $level · sonido ${micProc.label()}\n"
    }

    private fun routeName(t: Int): String = when (t) {
        android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "auricular de llamada"
        android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "parlante"
        android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET, android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "auriculares con cable"
        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth (llamada)"
        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth (música)"
        android.media.AudioDeviceInfo.TYPE_USB_HEADSET, android.media.AudioDeviceInfo.TYPE_USB_DEVICE -> "USB"
        26 /* TYPE_BLE_HEADSET */ -> "Bluetooth LE"
        else -> "tipo $t"
    }

    /** Called from the encode loops; writes the line every 5 s while streaming ([force]: now, with the [pace] line). */
    private fun maybeLogReturn(force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (retLogAtMs == 0L) { retLogAtMs = now; return }
        val dt = now - retLogAtMs
        if (dt < (if (force) 1000 else 5000)) return
        retLogAtMs = now
        val pk = retPkts.getAndSet(0); val by = retBytes.getAndSet(0); val fr = retFrames.getAndSet(0)
        val sq = retSumSq.getAndSet(0).toDouble(); val n = retSamples.getAndSet(0)
        val droppedMs = retDroppedSamples.getAndSet(0) * 1000 / 48000
        val secs = dt / 1000.0
        val level = if (n > 0 && sq > 0) "%.0f dBFS".format(10 * Math.log10(sq / n / (32768.0 * 32768.0)))
                    else if (n > 0) "silencio" else "nada escrito"
        val route = try {
            val d = returnTrack?.routedDevice
            if (d == null) (if (returnTrack == null) "sin reproductor" else "sin ruta") else "${routeName(d.type)} (tipo ${d.type})"
        } catch (e: Exception) { "?" }
        val via = if (srtSocket != null) "SRT" else "SBL"
        val msg = "[retorno] $via · ${"%.0f".format(pk / secs)} paq/s · ${"%.1f".format(by / secs / 1000)} kB/s · " +
            "$fr cuadros · $level · descartado ${droppedMs} ms · sale por: $route · botón: ${if (talkbackMuted.get()) "silenciado" else "activo"}\n"
        Log.i(TAG, msg.trim())
        Thread { sendLogBytes(msg, "return_stats") }.start()
        val mic = micLine(via, secs)
        Log.i(TAG, mic.trim())
        Thread { sendLogBytes(mic, "mic_stats") }.start()
    }

    private fun decodeAndPlay(buf: ByteArray, offset: Int, length: Int) = synchronized(returnLock) {
        retPkts.incrementAndGet(); retBytes.addAndGet(length.toLong())
        if (!returnConfigured) return@synchronized
        try { decodeAndPlayOnce(buf, offset, length) } catch (e: Exception) {
            // Recreate the decoder (at most once a second) instead of leaving it dead.
            try { returnDecoder?.release() } catch (_: Exception) {}
            returnDecoder = null
            val now = System.currentTimeMillis()
            if (now - returnLastResetMs >= 1000) {
                returnLastResetMs = now
                returnDecoder = try { newReturnDecoder() } catch (e2: Exception) { null }
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
            if (info.size > 0) retFrames.incrementAndGet()
            if (outBuf != null && info.size > 0 && !talkbackMuted.get()) {
                val pcm = ShortArray(info.size / 2)
                outBuf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(pcm)
                // NON-BLOCKING: the return arrives in bursts on a bad Wi-Fi (the A10: 19-51 packets/s) and the track
                // plays at real time, so a blocking write kept every stall as delay for good - the A10 heard the
                // program ~20 s late (2026-10-21). What does not fit in the track's buffer now is dropped: the delay
                // stays at that buffer (~0.2-0.3 s) and a burst costs a few skipped ms instead.
                val w = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
                if (w in 0 until pcm.size) retDroppedSamples.addAndGet((pcm.size - w).toLong())
                var sq = 0L
                for (v in pcm) sq += v.toLong() * v
                retSumSq.addAndGet(sq); retSamples.addAndGet(pcm.size.toLong())
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

    // Phone orientation (MPEG-TS has no CVO like WHIP): "SROT" | u8 rotation, same PID as the log, one packet.
    // Values as CVO: 0 = 0°, 1 = 90° clockwise, 2 = 180°, 3 = 90° counter-clockwise — what the receiver turns the
    // picture to see it upright. A SAMBA that does not know it only accepts "SLOG" and ignores it.
    @Synchronized fun muxRotation(cvo: Int): List<ByteArray> {
        val out = mutableListOf<ByteArray>()
        logCc = packetize(logPid, "SROT".toByteArray(Charsets.US_ASCII) + byteArrayOf((cvo and 0x03).toByte()), logCc, out)
        return out
    }

    // Diagnostic log inside the stream. Message: "SLOG" | u32 BE textLen | u8 reasonLen | reason | text.
    @Synchronized fun muxLog(text: ByteArray, reason: String): List<ByteArray> {
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
