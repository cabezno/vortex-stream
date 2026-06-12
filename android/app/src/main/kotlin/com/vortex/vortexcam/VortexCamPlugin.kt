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
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.OutputStream
import java.net.Socket
import java.nio.ByteBuffer
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
    private var rtmpClient: RtmpClient? = null  // RTMP transport

    // ---- SBL UDP transport ----
    private var sblSocket:     java.net.DatagramSocket?    = null
    private var sblRemoteAddr: java.net.InetSocketAddress? = null
    private var sblPktSeq      = 0
    private var sblFrameSeq    = 0

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
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startCamera"  -> startCamera(call, result)
            "stopCamera"   -> { stopCamera(); result.success(null) }
            "flipCamera"   -> { flipCamera(result) }
            "setTorch"     -> { setTorch(call.argument<Boolean>("on") ?: false); result.success(null) }

            "startSrt"     -> startSrt(call, result)
            "stopSrt"      -> { stopStream(); result.success(null) }

            "startRtmp"    -> startRtmp(call, result)
            "stopRtmp"     -> { stopStream(); result.success(null) }

            "getStats"     -> result.success(mapOf("bitrateMbps" to bitrateMbps, "rttMs" to rttMs))

            "startSbl"         -> startSbl(call, result)
            "startSblStream"   -> startSbl(call, result)          // alias
            "stopSbl"          -> { stopStream(); result.success(null) }
            "getSblStats"      -> result.success(mapOf("bitrateMbps" to bitrateMbps))
            "startSrtCamera"   -> startCamera(call, result)       // alias
            "configureSrt"     -> result.success(null)            // no-op; config comes in startSbl

            "discoverSrt"  -> discoverSrt(call, result)
            "connectWifi"  -> connectWifi(call, result)

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
                Log.i(TAG, "Camera opened: $cameraId")
                // Start preview-only session (no encoder surface yet)
                startPreviewSession()
                result.success(mapOf("textureId" to flutterTexture!!.id()))
            }
            override fun onDisconnected(camera: CameraDevice) {
                camera.close(); cameraDevice = null
            }
            override fun onError(camera: CameraDevice, error: Int) {
                camera.close(); cameraDevice = null
                result.error("CAMERA_ERROR", "Camera error: $error", null)
            }
        }, cameraHandler)
    }

    private fun startPreviewSession() {
        val surfaces = mutableListOf(previewSurface!!)
        if (encoderSurface != null) surfaces.add(encoderSurface!!)
        cameraDevice?.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                val req = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    surfaces.forEach { addTarget(it) }
                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(30, 60))
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                }
                session.setRepeatingRequest(req.build(), null, cameraHandler)
                Log.i(TAG, "Capture session started (${surfaces.size} surfaces)")
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
                Log.e(TAG, "Capture session configure failed")
            }
        }, cameraHandler)
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
        cameraFacing = if (cameraFacing == CameraCharacteristics.LENS_FACING_BACK)
            CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val wasStreaming = streaming.get()
        stopStream()
        captureSession?.close(); captureSession = null
        cameraDevice?.close();   cameraDevice  = null

        val cameraId = getCameraId(cameraFacing)
        if (cameraId == null) { result.error("NO_CAMERA", "No camera for facing", null); return }

        @SuppressLint("MissingPermission")
        cameraManager?.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                cameraDevice = cam
                startPreviewSession()
                result.success(null)
            }
            override fun onDisconnected(cam: CameraDevice) { cam.close() }
            override fun onError(cam: CameraDevice, error: Int) { cam.close(); result.error("ERR", "error $error", null) }
        }, cameraHandler)
    }

    private fun setTorch(on: Boolean) {
        try {
            val id = getCameraId(cameraFacing) ?: return
            cameraManager?.setTorchMode(id, on)
        } catch (e: Exception) { Log.w(TAG, "Torch: $e") }
    }

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
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val rotation = if (android.os.Build.VERSION.SDK_INT >= 30)
            context.display?.rotation ?: Surface.ROTATION_0
        else
            @Suppress("DEPRECATION") wm.defaultDisplay.rotation
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

    private fun setupEncoder(
        codec: String, width: Int, height: Int,
        bitrateBps: Int, keyframeMs: Int,
    ): Boolean {
        return try {
            val mime = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC
                       else MediaFormat.MIMETYPE_VIDEO_AVC
            val rotation = encoderRotationDegrees()
            // Swap width/height for portrait (90° or 270°) so the encoded
            // resolution matches the upright frame dimensions.
            val encW = if (rotation == 90 || rotation == 270) height else width
            val encH = if (rotation == 90 || rotation == 270) width  else height
            val fmt = MediaFormat.createVideoFormat(mime, encW, encH).apply {
                setInteger(MediaFormat.KEY_BIT_RATE,         bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE,       30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeMs / 1000)
                setInteger(MediaFormat.KEY_COLOR_FORMAT,     MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BITRATE_MODE,     MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                setInteger(MediaFormat.KEY_PRIORITY,         0)
                setInteger(MediaFormat.KEY_OPERATING_RATE,   120)
                if (android.os.Build.VERSION.SDK_INT >= 30)
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
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
            Log.e(TAG, "Encoder setup failed: $e")
            false
        }
    }

    private fun stopStream() {
        if (!streaming.getAndSet(false)) return
        encodeThread?.join(2000); encodeThread = null
        try { encoder?.signalEndOfInputStream() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        encoder = null
        encoderSurface?.release(); encoderSurface = null
        srtSocket?.close(); srtSocket = null
        rtmpClient?.close(); rtmpClient = null
        sblSocket?.close(); sblSocket = null
        bytesSent.set(0L); bitrateMbps = 0.0; rttMs = 0
        // Restart preview-only session
        captureSession?.close()
        startPreviewSession()
        Log.i(TAG, "Stream stopped")
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
        val codec       = call.argument<String>("codec")      ?: "hevc"

        thread(name = "SrtStart") {
            try {
                if (!setupEncoder(codec, width, height, bitrate, keyframeMs)) {
                    result.error("ENC", "Encoder setup failed", null); return@thread
                }
                srtSocket = SrtSocket(ip, port, latencyMs)
                if (!srtSocket!!.connect()) throw Exception("SRT connect to $ip:$port failed")

                val mime = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC
                           else MediaFormat.MIMETYPE_VIDEO_AVC
                val muxer = TsMuxer(mime)
                streaming.set(true)

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
                srtSocket?.send(pkt)
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
                    result.error("ENC", "Encoder setup failed", null); return@thread
                }
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

            if (!seqHeaderSent && spsData != null && ppsData != null) {
                rtmpClient?.sendVideoSequenceHeader(spsData, ppsData)
                seqHeaderSent = true
            }
            if (seqHeaderSent) {
                rtmpClient?.sendVideoData(data, info.presentationTimeUs / 1000, isKey)
                bytesSent.addAndGet(data.size.toLong())
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

        thread(name = "SblStart") {
            try {
                if (!setupEncoder("h264", width, height, bitrate, 1000)) {
                    result.error("ENC", "Encoder setup failed", null); return@thread
                }
                sblSocket = java.net.DatagramSocket()
                sblSocket!!.setSoTimeout(0)
                sblRemoteAddr = java.net.InetSocketAddress(host, port)
                sblPktSeq   = 0
                sblFrameSeq = 0
                // Send Hello
                sendSblHello(sourceName)
                // Small wait for HelloAck (optional, non-blocking approach)
                Thread.sleep(200)
                streaming.set(true)
                encodeThread = thread(name = "SblEncode") { drainToSbl(width, height) }
                result.success(null)
                Log.i(TAG, "SBL streaming → $host:$port ${width}x${height} @${bitrate/1000}kbps")
            } catch (e: Exception) {
                Log.e(TAG, "startSbl failed: $e")
                stopStream()
                result.error("SBL_ERR", e.message, null)
            }
        }
    }

    private fun sendSblHello(sourceName: String) {
        // Packet header (32) + Hello payload (105)
        val buf = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE + 105)
        buf.order(java.nio.ByteOrder.BIG_ENDIAN)
        // Header
        buf.put(SBL_MAGIC)           // [0..2] magic
        buf.put(SBL_VERSION)         // [3]
        buf.put(2)                   // [4] packetType = Hello
        buf.put(0)                   // [5] streamID = VideoColor
        buf.putShort(sblPktSeq++.toShort()) // [6..7]
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
        val buf = java.nio.ByteBuffer.allocate(SBL_HEADER_SIZE)
        buf.order(java.nio.ByteOrder.BIG_ENDIAN)
        buf.put(SBL_MAGIC); buf.put(SBL_VERSION)
        buf.put(4)  // Keepalive
        buf.put(0)  // streamID
        buf.putShort(sblPktSeq++.toShort())
        buf.putInt(0); buf.putShort(0); buf.putShort(1)
        buf.putLong(System.currentTimeMillis() * 1000)
        buf.putShort(0); buf.putShort(0); buf.putInt(0)
        sendSblDatagram(buf.array())
    }

    private fun sendSblDatagram(data: ByteArray) {
        try {
            val pkt = java.net.DatagramPacket(data, data.size, sblRemoteAddr)
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
            }
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER     -> continue
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                idx < 0 -> continue
            }
            val buf = encoder!!.getOutputBuffer(idx) ?: run {
                encoder!!.releaseOutputBuffer(idx, false); continue
            }
            val nalData = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
            val isKey   = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
            val ptsUs   = info.presentationTimeUs
            sendSblVideoFrame(nalData, isKey, ptsUs, width, height)
            bytesSent.addAndGet(nalData.size.toLong())
            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }
    }

    private fun sendSblVideoFrame(
        nalData: ByteArray, isKeyframe: Boolean,
        ptsUs: Long, width: Int, height: Int,
    ) {
        val frameSeq   = sblFrameSeq++
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
            pkt.order(java.nio.ByteOrder.BIG_ENDIAN)
            // Packet header
            pkt.put(SBL_MAGIC); pkt.put(SBL_VERSION)
            pkt.put(0)  // Data
            pkt.put(0)  // VideoColor
            pkt.putShort(sblPktSeq++.toShort())
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
            sendSblDatagram(pkt.array().copyOf(SBL_HEADER_SIZE + payloadLen))
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
    private inner class SrtSocket(val ip: String, val port: Int, val latencyMs: Int) {
        private var tcpSocket: Socket? = null

        fun connect(): Boolean {
            return try {
                tcpSocket = Socket(ip, port).also {
                    it.tcpNoDelay  = true
                    it.soTimeout   = 0       // no recv timeout — keep-alive handled by send
                    it.keepAlive   = true
                }
                Log.i(TAG, "SRT/TCP connected → $ip:$port")
                true
            } catch (e: Exception) {
                Log.e(TAG, "SRT/TCP connect to $ip:$port failed: $e")
                false
            }
        }

        fun send(data: ByteArray) {
            try { tcpSocket?.outputStream?.write(data) } catch (_: Exception) {}
        }

        fun getRttMs(): Int = 0  // TCP doesn't expose RTT; use 0

        fun close() {
            try { tcpSocket?.close() } catch (_: Exception) {}
            tcpSocket = null
        }
    }
}

// =============================================================================
// MPEG-TS muxer (H.264 / H.265)
// =============================================================================
class TsMuxer(private val mimeType: String) {
    private val videoPid = 0x100
    private val pmtPid   = 0x1000
    private var pktCount = 0
    private var dts      = 0L

    fun setFormat(fmt: MediaFormat) { /* SPS/PPS embedded in stream */ }

    fun mux(buf: ByteBuffer, info: MediaCodec.BufferInfo): List<ByteArray> {
        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
        val data  = ByteArray(info.size).also { buf.position(info.offset); buf.get(it) }
        val pkts  = mutableListOf<ByteArray>()
        if (pktCount % 15 == 0) { pkts.add(buildPAT()); pkts.add(buildPMT()) }
        val pes = buildPES(data, dts)
        var off = 0; var first = true
        while (off < pes.size) {
            val pkt = ByteArray(188)
            pkt[0] = 0x47
            val pusi = if (first) 0x40 else 0x00
            pkt[1] = (pusi or ((videoPid shr 8) and 0x1F)).toByte()
            pkt[2] = (videoPid and 0xFF).toByte()
            pkt[3] = (0x10 or (pktCount++ and 0x0F)).toByte()
            val len = minOf(184, pes.size - off)
            pes.copyInto(pkt, 4, off, off + len)
            if (len < 184) pkt.fill(0xFF.toByte(), 4 + len)
            pkts.add(pkt); off += len; first = false
        }
        dts += 3000  // 90kHz ticks @ 30fps
        return pkts
    }

    private fun buildPES(data: ByteArray, pts: Long): ByteArray {
        val hdr = ByteArray(14)
        hdr[0] = 0; hdr[1] = 0; hdr[2] = 1; hdr[3] = 0xE0.toByte()
        val pesLen = data.size + 8
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
    private fun buildPAT(): ByteArray {
        val p = ByteArray(188).also { it.fill(0xFF.toByte()) }
        p[0]=0x47; p[1]=0x40; p[2]=0; p[3]=0x10; p[4]=0
        p[5]=0; p[6]=0xB0.toByte(); p[7]=0x0D
        p[8]=0; p[9]=1; p[10]=0xC1.toByte(); p[11]=0; p[12]=0
        p[13]=0; p[14]=1
        p[15]=(0xE0 or ((pmtPid shr 8) and 0x1F)).toByte()
        p[16]=(pmtPid and 0xFF).toByte()
        return p
    }
    private fun buildPMT(): ByteArray {
        val p = ByteArray(188).also { it.fill(0xFF.toByte()) }
        p[0]=0x47; p[1]=(0x40 or ((pmtPid shr 8) and 0x1F)).toByte()
        p[2]=(pmtPid and 0xFF).toByte(); p[3]=0x10; p[4]=0
        p[5]=2; p[6]=0xB0.toByte(); p[7]=0x12
        p[8]=0; p[9]=1; p[10]=0xC1.toByte(); p[11]=0; p[12]=0
        p[13]=0xE1.toByte(); p[14]=0; p[15]=0xF0.toByte(); p[16]=0
        val streamType = if (mimeType == MediaFormat.MIMETYPE_VIDEO_HEVC) 0x24 else 0x1B
        p[17]=streamType.toByte(); p[18]=0xE1.toByte(); p[19]=0
        p[20]=0xF0.toByte(); p[21]=0
        return p
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

        socket = Socket(host, port).also { it.tcpNoDelay = true; it.setSoTimeout(5000) }
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

    fun sendVideoSequenceHeader(sps: ByteArray, pps: ByteArray) {
        // AVCDecoderConfigurationRecord
        val buf = mutableListOf<Byte>()
        buf.add(0x17.toByte())  // keyframe + AVC
        buf.add(0x00)           // AVC sequence header
        buf.add(0); buf.add(0); buf.add(0)  // composition time = 0
        // AVCDecoderConfigurationRecord
        buf.add(1)              // configurationVersion
        buf.add(sps[1]); buf.add(sps[2]); buf.add(sps[3])  // profile/compat/level
        buf.add(0xFF.toByte())  // lengthSizeMinusOne = 3
        buf.add(0xE1.toByte())  // numSequenceParameterSets = 1
        buf.add(((sps.size shr 8) and 0xFF).toByte())
        buf.add((sps.size and 0xFF).toByte())
        buf.addAll(sps.toList())
        buf.add(1)  // numPictureParameterSets = 1
        buf.add(((pps.size shr 8) and 0xFF).toByte())
        buf.add((pps.size and 0xFF).toByte())
        buf.addAll(pps.toList())
        sendRtmpVideo(buf.toByteArray(), 0, true)
    }

    fun sendVideoData(data: ByteArray, timestampMs: Long, isKeyframe: Boolean) {
        // RTMP video tag: frameType + codecId + avcPacketType + compositionTime + data
        val buf = ByteArray(5 + data.size)
        buf[0] = if (isKeyframe) 0x17 else 0x27  // keyframe/interframe + AVC
        buf[1] = 0x01  // AVC NALU
        buf[2] = 0; buf[3] = 0; buf[4] = 0  // composition time offset
        data.copyInto(buf, 5)
        sendRtmpVideo(buf, timestampMs.toInt(), isKeyframe)
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
        // Basic header (1 byte, fmt=0)
        val basicHdr = (chunkStreamId and 0x3F).toByte()
        // Message header type 0 (11 bytes)
        val hdr = ByteArray(12)
        hdr[0] = basicHdr
        // timestamp (3 bytes big-endian, clamped to 0xFFFFFF)
        val ts = minOf(timestamp, 0xFFFFFF)
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

        // Chunk payload (chunk size = 128 by default)
        val chunkSize = 4096
        out.write(hdr)
        var offset = 0
        var first  = true
        while (offset < data.size) {
            if (!first) {
                // Continuation chunk: fmt=3 basic header
                out.write(0xC0 or (chunkStreamId and 0x3F))
            }
            val len = minOf(chunkSize, data.size - offset)
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
}
