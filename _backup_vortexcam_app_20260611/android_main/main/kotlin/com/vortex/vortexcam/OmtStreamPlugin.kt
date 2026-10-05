package com.vortex.vortexcam

// =============================================================================
// OmtStreamPlugin — OMT (Open Media Transport) sender for VortexEngine
//
// Architecture:
//   Camera2 ImageReader (NV12/YUV_420_888) → JNI VMX encode → OMT TCP frames
//   TCP server: phone listens, VortexEngine connects
//   mDNS: phone announces _omt._tcp.local so VortexEngine discovers it
//
// Protocol:
//   OMT wire format: 16-byte header + 32-byte video extended header + VMX data
//   Quality: Low=133 / Medium=166 / High=199 (OMT_LQ/SQ/HQ profiles in libvmx)
//   Bitrate: ~43 Mbps (Low) / ~100 Mbps (Med) / ~130 Mbps (High) at 1080p30
// =============================================================================

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private const val TAG     = "VortexOMT"
private const val CHANNEL = "com.vortex.vortexcam/omt"

// OMT FourCC for VMX: "VMX " = 0x20584D56
private const val FOURCC_VMX = 0x20584D56

class OmtStreamPlugin(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        // Whether the native VMX bridge loaded successfully. If false, OMT is
        // unavailable but the app still runs (WHIP/SRT/RTMP keep working).
        @JvmStatic var nativeAvailable = false
            private set

        init {
            // MUST NOT throw from a static initializer: an exception here makes
            // the whole class fail to load, and since MainActivity.onCreate
            // touches OmtStreamPlugin, that crashes the entire app at launch.
            // Load defensively; if libvmx/vmxjni is missing just disable OMT.
            try {
                // Load libvmx first so vmxjni's dlopen finds it already mapped.
                try { System.loadLibrary("vmx") } catch (_: Throwable) {}
                System.loadLibrary("vmxjni")
                nativeAvailable = true
                Log.i(TAG, "vmxjni loaded — OMT available")
            } catch (t: Throwable) {
                nativeAvailable = false
                Log.e(TAG, "vmxjni load failed — OMT disabled: $t")
            }
        }

        @JvmStatic external fun nativeCreateEncoder(w: Int, h: Int, quality: Int, colorSpace: Int): Long
        @JvmStatic external fun nativeDestroyEncoder(handle: Long)
        @JvmStatic external fun nativeEncodeNV12(handle: Long,
            yBuf: ByteBuffer, yStride: Int,
            uvBuf: ByteBuffer, uvStride: Int): ByteArray?

        fun registerWith(activity: FlutterActivity, engine: FlutterEngine) {
            val plugin = OmtStreamPlugin(activity.applicationContext)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(plugin)
        }
    }

    // ── State ────────────────────────────────────────────────────────────────
    private var encoderHandle  = 0L
    private var serverSocket   : ServerSocket? = null
    private var clientSocket   : Socket? = null
    private var clientOutput   : OutputStream? = null
    private val streaming      = AtomicBoolean(false)
    private val clientConnected = AtomicBoolean(false)

    private var imageReader    : ImageReader? = null
    private var captureSession : CameraCaptureSession? = null
    private var cameraDevice   : CameraDevice? = null
    private var cameraThread   : HandlerThread? = null
    private var cameraHandler  : Handler? = null

    private val bytesSent      = AtomicLong(0L)
    private val framesSent     = AtomicLong(0L)
    private var nsdManager     : NsdManager? = null
    private var nsdRegistered  = false

    private var width    = 1920
    private var height   = 1080
    private var fpsN     = 30
    private var quality  = 2    // 0=Low 1=Med 2=High
    private var hostName = "Android"

    // ── MethodChannel dispatch ───────────────────────────────────────────────
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startOmt"   -> startOmt(call, result)
            "stopOmt"    -> { stopOmt(); result.success(null) }
            "getStats"   -> result.success(mapOf(
                "bytesSent"  to bytesSent.get(),
                "framesSent" to framesSent.get(),
                "connected"  to clientConnected.get()
            ))
            else -> result.notImplemented()
        }
    }

    // ── Start ────────────────────────────────────────────────────────────────
    private fun startOmt(call: MethodCall, result: MethodChannel.Result) {
        if (!nativeAvailable) {
            result.error("OMT_UNAVAILABLE",
                "El códec VMX nativo no está disponible en este dispositivo. Usá WHIP o SRT.", null)
            return
        }
        width    = call.argument<Int>("width")    ?: 1920
        height   = call.argument<Int>("height")   ?: 1080
        fpsN     = call.argument<Int>("fps")      ?: 30
        quality  = call.argument<Int>("quality")  ?: 2
        hostName = call.argument<String>("name")  ?: "VortexCam"
        val port = call.argument<Int>("port")     ?: 5960

        thread(name = "OmtStart") {
            try {
                // Create VMX encoder
                encoderHandle = nativeCreateEncoder(width, height, quality, 709)
                if (encoderHandle == 0L) throw Exception("VMX encoder init failed")

                // Start TCP server (phone listens, VortexEngine connects)
                serverSocket = ServerSocket(port)
                streaming.set(true)

                // Announce via mDNS
                announceMdns(hostName, port)

                // Start camera
                startCamera()

                // Accept connections in background
                thread(name = "OmtAccept", isDaemon = true) { acceptLoop() }

                result.success(mapOf("port" to serverSocket!!.localPort))
                Log.i(TAG, "OMT sender started on :$port ${width}x${height}@${fpsN}fps q=$quality")
            } catch (e: Exception) {
                Log.e(TAG, "startOmt failed: $e")
                stopOmt()
                result.error("OMT_ERR", e.message, null)
            }
        }
    }

    private fun stopOmt() {
        streaming.set(false)
        unregisterMdns()
        stopCamera()
        clientSocket?.close(); clientSocket = null
        serverSocket?.close(); serverSocket = null
        clientConnected.set(false)
        if (encoderHandle != 0L) { nativeDestroyEncoder(encoderHandle); encoderHandle = 0L }
        Log.i(TAG, "OMT sender stopped")
    }

    // ── TCP accept loop ──────────────────────────────────────────────────────
    private fun acceptLoop() {
        while (streaming.get()) {
            try {
                val client = serverSocket?.accept() ?: break
                Log.i(TAG, "OMT receiver connected: ${client.inetAddress}")
                clientSocket?.close()
                clientSocket  = client
                clientOutput  = client.outputStream
                clientConnected.set(true)

                // Read subscribe commands (fire and forget — we stream regardless)
                thread(isDaemon = true) {
                    try {
                        val buf = ByteArray(4096)
                        while (streaming.get() && client.isConnected) {
                            val n = client.inputStream.read(buf)
                            if (n <= 0) break
                            // Parse OMT commands (Subscribe, Tally, Quality)
                            handleReceivedCommand(buf, n)
                        }
                    } catch (_: Exception) {}
                    clientConnected.set(false)
                    Log.i(TAG, "OMT receiver disconnected")
                }
            } catch (_: Exception) { break }
        }
    }

    private fun handleReceivedCommand(data: ByteArray, len: Int) {
        if (len < 16) return
        val frameType = data[1].toInt() and 0xFF
        if (frameType == 1) {  // Metadata
            val dataLen = ByteBuffer.wrap(data, 12, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (dataLen > 0 && len >= 16 + dataLen) {
                val xml = String(data, 16, dataLen - 1)  // strip null terminator
                Log.d(TAG, "OMT command: $xml")
                if (xml.contains("Quality=\"Low\""))    quality = 0
                if (xml.contains("Quality=\"Medium\"")) quality = 1
                if (xml.contains("Quality=\"High\""))   quality = 2
            }
        }
    }

    // ── Camera2 capture ──────────────────────────────────────────────────────
    @Suppress("MissingPermission")
    private fun startCamera() {
        cameraThread = HandlerThread("OmtCameraThread").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)
        val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        // YUV_420_888 → NV12 for VMX
        imageReader = ImageReader.newInstance(width, height, ImageFormat.YUV_420_888, 3)
        imageReader!!.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                if (!streaming.get() || !clientConnected.get()) return@setOnImageAvailableListener
                val yPlane  = image.planes[0]
                val uvPlane = image.planes[1]  // NV12: interleaved UV
                val encoded = nativeEncodeNV12(
                    encoderHandle,
                    yPlane.buffer,  yPlane.rowStride,
                    uvPlane.buffer, uvPlane.rowStride
                ) ?: return@setOnImageAvailableListener
                sendVideoFrame(encoded)
            } finally {
                image.close()
            }
        }, cameraHandler)

        val cameraId = mgr.cameraIdList.firstOrNull { id ->
            mgr.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: throw Exception("No back camera")

        mgr.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                cameraDevice = cam
                cam.createCaptureSession(
                    listOf(imageReader!!.surface),
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                addTarget(imageReader!!.surface)
                                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                                    android.util.Range(fpsN, fpsN))
                            }
                            session.setRepeatingRequest(req.build(), null, cameraHandler)
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            Log.e(TAG, "Camera session configure failed")
                        }
                    }, cameraHandler)
            }
            override fun onDisconnected(cam: CameraDevice) { cam.close() }
            override fun onError(cam: CameraDevice, error: Int) { cam.close() }
        }, cameraHandler)
    }

    private fun stopCamera() {
        captureSession?.stopRepeating(); captureSession?.close(); captureSession = null
        cameraDevice?.close(); cameraDevice = null
        imageReader?.close(); imageReader = null
        cameraThread?.quitSafely(); cameraThread = null; cameraHandler = null
    }

    // ── OMT frame encoding ───────────────────────────────────────────────────
    private fun sendVideoFrame(vmxData: ByteArray) {
        val out = clientOutput ?: return
        val ts  = System.nanoTime() / 100L  // 100-nanosecond units (OMT protocol)

        // Video extended header (32 bytes)
        val xhdr = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(FOURCC_VMX)  // Codec FourCC
            putInt(width)
            putInt(height)
            putInt(fpsN)        // FrameRateN
            putInt(1)           // FrameRateD
            putFloat(width.toFloat() / height)  // AspectRatio
            putInt(0)           // Flags
            putInt(709)         // ColorSpace BT.709
        }.array()

        val dataLen = xhdr.size + vmxData.size  // DataLength = extHdr + data

        // OMT header (16 bytes): Version(1)+FrameType(1)+Timestamp(8)+Rsvd(2)+DataLen(4)
        val hdr = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(1)    // Version
            put(2)    // FrameType: Video
            putLong(ts)
            put(0)    // Reserved
            put(0)    // Reserved
            putInt(dataLen)
        }.array()

        try {
            out.write(hdr)
            out.write(xhdr)
            out.write(vmxData)
            out.flush()
            bytesSent.addAndGet((hdr.size + xhdr.size + vmxData.size).toLong())
            framesSent.incrementAndGet()
        } catch (_: Exception) {
            clientConnected.set(false)
        }
    }

    // ── mDNS announcement ─────────────────────────────────────────────────────
    private fun announceMdns(name: String, port: Int) {
        nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val svcInfo = NsdServiceInfo().apply {
            // OMT format: "HOSTNAME (Source Name)"
            serviceName = "${getHostName()} ($name)"
            serviceType = "_omt._tcp."
            this.port   = port
        }
        nsdManager?.registerService(svcInfo, NsdManager.PROTOCOL_DNS_SD,
            object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {
                    nsdRegistered = true
                    Log.i(TAG, "mDNS registered: ${info.serviceName}")
                }
                override fun onRegistrationFailed(info: NsdServiceInfo, err: Int) {
                    Log.w(TAG, "mDNS registration failed: $err")
                }
                override fun onServiceUnregistered(info: NsdServiceInfo) { nsdRegistered = false }
                override fun onUnregistrationFailed(info: NsdServiceInfo, err: Int) {}
            })
    }

    private fun unregisterMdns() {
        if (nsdRegistered) {
            try { nsdManager?.unregisterService(object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(i: NsdServiceInfo) {}
                override fun onRegistrationFailed(i: NsdServiceInfo, e: Int) {}
                override fun onServiceUnregistered(i: NsdServiceInfo) {}
                override fun onUnregistrationFailed(i: NsdServiceInfo, e: Int) {}
            }) } catch (_: Exception) {}
            nsdRegistered = false
        }
    }

    private fun getHostName(): String = try {
        NetworkInterface.getNetworkInterfaces()
            .asSequence()
            .flatMap { it.inetAddresses.asSequence() }
            .firstOrNull { !it.isLoopbackAddress && it is java.net.Inet4Address }
            ?.hostName ?: "Android"
    } catch (_: Exception) { "Android" }
}
