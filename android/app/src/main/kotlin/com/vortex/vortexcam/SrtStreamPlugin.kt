package com.vortex.vortexcam

// =============================================================================
// SrtStreamPlugin — Android native SRT streaming with H.265 HW encode
//
// Pipeline:
//   Camera2 → Surface → MediaCodec (HEVC HW, low-latency) → ByteBuffer
//   → MPEG-TS muxer → SRT socket (libsrt via JNI or net.srt:srt-android)
//
// Integrated as a Flutter MethodChannel plugin.
// =============================================================================

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

private const val TAG = "VortexSRT"

class SrtStreamPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    // ---- State ----
    private var encoder:     MediaCodec?  = null
    private var muxer:       TsMuxer?     = null
    private var srtSocket:   SrtSocket?   = null
    private var encodeThread: Thread?     = null
    private var isStreaming:  Boolean     = false

    // ---- Stats ----
    private val bytesSent = AtomicLong(0L)
    private var lastStatNs = 0L
    private var bitrateMbps = 0.0
    private var rttMs = 0

    // ---- MethodChannel handler ----
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startSrt"    -> startSrt(call, result)
            "stopSrt"     -> { stopSrt(); result.success(null) }
            "getSrtStats" -> result.success(mapOf("bitrateMbps" to bitrateMbps, "rttMs" to rttMs))
            "discoverSrt" -> discoverSrt(call, result)
            else          -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Start SRT streaming
    // -------------------------------------------------------------------------
    private fun startSrt(call: MethodCall, result: MethodChannel.Result) {
        val engineIp     = call.argument<String>("engineIp")     ?: return result.error("BAD_ARG", "engineIp required", null)
        val enginePort   = call.argument<Int>("enginePort")      ?: 9000
        val width        = call.argument<Int>("width")           ?: 1280
        val height       = call.argument<Int>("height")          ?: 720
        val bitrateBps   = call.argument<Int>("bitrateBps")      ?: 6_000_000
        val keyframeMs   = call.argument<Int>("keyframeMs")      ?: 2000
        val srtLatencyMs = call.argument<Int>("srtLatencyMs")    ?: 80
        val codec        = call.argument<String>("codec")        ?: "hevc"
        val lowLatency   = call.argument<Boolean>("lowLatency")  ?: true
        val operatingRate= call.argument<Int>("operatingRate")   ?: 120

        try {
            // 1. Create MediaCodec H.265 encoder
            val mimeType = if (codec == "hevc") MediaFormat.MIMETYPE_VIDEO_HEVC
                           else MediaFormat.MIMETYPE_VIDEO_AVC
            val fmt = MediaFormat.createVideoFormat(mimeType, width, height).apply {
                setInteger(MediaFormat.KEY_BIT_RATE,            bitrateBps)
                setInteger(MediaFormat.KEY_FRAME_RATE,          30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL,    keyframeMs / 1000)
                setInteger(MediaFormat.KEY_COLOR_FORMAT,        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BITRATE_MODE,        MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                setInteger(MediaFormat.KEY_PRIORITY,            0)   // realtime
                setInteger(MediaFormat.KEY_OPERATING_RATE,      operatingRate)
                if (lowLatency) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }

            encoder = MediaCodec.createEncoderByType(mimeType)
            encoder!!.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            // NOTE: caller (camera_service) must call encoder.createInputSurface()
            //       and attach it to the Camera2 preview surface.

            // 2. Create MPEG-TS muxer
            muxer = TsMuxer(mimeType)

            // 3. Connect SRT (caller mode — engine is listener)
            srtSocket = SrtSocket(engineIp, enginePort, srtLatencyMs)
            if (!srtSocket!!.connect()) {
                throw Exception("SRT connect to $engineIp:$enginePort failed")
            }

            // 4. Start encode → mux → send loop
            isStreaming = true
            encoder!!.start()
            encodeThread = thread(name = "SrtEncodeThread", isDaemon = true) {
                drainEncoder()
            }

            Log.i(TAG, "Streaming started → $engineIp:$enginePort ${width}x$height @${bitrateBps/1000}kbps H.265")
            result.success(null)

        } catch (e: Exception) {
            Log.e(TAG, "startSrt failed: $e")
            stopSrt()
            result.error("SRT_ERROR", e.message, null)
        }
    }

    // -------------------------------------------------------------------------
    // Drain MediaCodec output → MPEG-TS → SRT
    // -------------------------------------------------------------------------
    private fun drainEncoder() {
        val info = MediaCodec.BufferInfo()
        while (isStreaming) {
            val idx = encoder?.dequeueOutputBuffer(info, 10_000) ?: break
            if (idx == MediaCodec.INFO_TRY_AGAIN_LATER) continue
            if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                muxer?.setFormat(encoder!!.outputFormat)
                continue
            }
            if (idx < 0) continue
            val buf = encoder!!.getOutputBuffer(idx) ?: continue

            val tsPackets = muxer!!.mux(buf, info)
            for (pkt in tsPackets) {
                srtSocket?.send(pkt)
                bytesSent.addAndGet(pkt.size.toLong())
            }

            encoder!!.releaseOutputBuffer(idx, false)
            updateStats()
        }
    }

    private fun updateStats() {
        val now = System.nanoTime()
        val elapsed = now - lastStatNs
        if (elapsed > 2_000_000_000L) {
            bitrateMbps = bytesSent.getAndSet(0L) * 8.0 / elapsed * 1000.0
            rttMs = srtSocket?.getRttMs() ?: 0
            lastStatNs = now
        }
    }

    // -------------------------------------------------------------------------
    // Stop
    // -------------------------------------------------------------------------
    fun stopSrt() {
        isStreaming = false
        encodeThread?.join(2000)
        encodeThread = null
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        encoder = null
        srtSocket?.close()
        srtSocket = null
        muxer = null
        Log.i(TAG, "Streaming stopped")
    }

    // -------------------------------------------------------------------------
    // mDNS discovery via NsdManager
    // -------------------------------------------------------------------------
    private fun discoverSrt(call: MethodCall, result: MethodChannel.Result) {
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
        val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        var resolved: Map<String, Any>? = null
        var listener: NsdManager.DiscoveryListener? = null

        listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                result.success(null)
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "mDNS discovery started for $serviceType")
            }
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(svc: NsdServiceInfo, error: Int) {}
                    override fun onServiceResolved(svc: NsdServiceInfo) {
                        Log.i(TAG, "Discovered SRT engine: ${svc.host}:${svc.port}")
                        resolved = mapOf("ip" to svc.host.hostAddress, "port" to svc.port)
                        nsdManager.stopServiceDiscovery(listener!!)
                    }
                })
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
        }

        nsdManager.discoverServices("_srt._udp", NsdManager.PROTOCOL_DNS_SD, listener!!)

        // Return after timeout
        thread(isDaemon = true) {
            Thread.sleep(timeoutMs.toLong())
            try { nsdManager.stopServiceDiscovery(listener) } catch (_: Exception) {}
            if (resolved != null) result.success(resolved)
            else result.success(null)
        }
    }

    // =========================================================================
    // Minimal SRT socket wrapper (calls native libsrt via System.loadLibrary)
    // To build: include libsrt.so in android/app/src/main/jniLibs/arm64-v8a/
    // Pre-built: https://github.com/Haivision/srt/releases (Android AAR)
    // =========================================================================
    private inner class SrtSocket(val ip: String, val port: Int, val latencyMs: Int) {
        private var socket: Long = 0L  // native handle

        external fun nativeCreate(latencyMs: Int): Long
        external fun nativeConnect(handle: Long, ip: String, port: Int): Boolean
        external fun nativeSend(handle: Long, data: ByteArray): Int
        external fun nativeGetRtt(handle: Long): Int
        external fun nativeClose(handle: Long)

        fun connect(): Boolean {
            return try {
                System.loadLibrary("srt")
                socket = nativeCreate(latencyMs)
                nativeConnect(socket, ip, port)
            } catch (e: UnsatisfiedLinkError) {
                // Fallback: plain TCP socket (no ARQ, but works for testing)
                Log.w(TAG, "libsrt not found — falling back to TCP socket")
                connectTcp()
            }
        }

        private var tcpSocket: Socket? = null

        private fun connectTcp(): Boolean {
            return try {
                tcpSocket = Socket(ip, port)
                tcpSocket!!.tcpNoDelay = true
                true
            } catch (e: Exception) {
                Log.e(TAG, "TCP fallback connect failed: $e"); false
            }
        }

        fun send(data: ByteArray) {
            if (socket != 0L) nativeSend(socket, data)
            else tcpSocket?.outputStream?.write(data)
        }

        fun getRttMs(): Int = if (socket != 0L) nativeGetRtt(socket) else 0

        fun close() {
            if (socket != 0L) { nativeClose(socket); socket = 0L }
            tcpSocket?.close(); tcpSocket = null
        }
    }
}

// =============================================================================
// Minimal MPEG-TS muxer for H.264/H.265 video (no audio)
// Produces 188-byte TS packets from MediaCodec output buffers.
// =============================================================================
class TsMuxer(private val mimeType: String) {
    private var videoPid = 0x100
    private var pmtPid   = 0x1000
    private var pktCount = 0
    private var format: MediaFormat? = null
    private var dts = 0L   // 90kHz clock

    fun setFormat(fmt: MediaFormat) { format = fmt }

    fun mux(buf: java.nio.ByteBuffer, info: MediaCodec.BufferInfo): List<ByteArray> {
        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
        val data = ByteArray(info.size)
        buf.position(info.offset); buf.get(data)

        val packets = mutableListOf<ByteArray>()
        if (pktCount % 10 == 0) {
            packets.add(buildPAT())
            packets.add(buildPMT())
        }
        // PES header + NAL data in TS packets
        val pes = buildPES(data, isKey, dts)
        var offset = 0
        var firstPkt = true
        while (offset < pes.size) {
            val pkt = ByteArray(188)
            pkt[0] = 0x47
            val pusi = if (firstPkt) 0x40 else 0x00
            pkt[1] = ((pusi or ((videoPid shr 8) and 0x1F))).toByte()
            pkt[2] = (videoPid and 0xFF).toByte()
            val cc = (pktCount++ and 0x0F)
            pkt[3] = (0x10 or cc).toByte()  // payload only, continuity counter
            val payloadLen = minOf(184, pes.size - offset)
            pes.copyInto(pkt, 4, offset, offset + payloadLen)
            if (payloadLen < 184) pkt.fill(0xFF.toByte(), 4 + payloadLen, 188)
            packets.add(pkt)
            offset += payloadLen
            firstPkt = false
        }
        dts += (90000 / 30)  // advance 1/30s in 90kHz units
        return packets
    }

    private fun buildPES(data: ByteArray, isKey: Boolean, pts: Long): ByteArray {
        // PES header: start code + stream_id + flags + PTS
        val hdr = ByteArray(14)
        hdr[0] = 0x00; hdr[1] = 0x00; hdr[2] = 0x01
        hdr[3] = 0xE0.toByte()  // stream_id = video
        val pesLen = data.size + 8  // PES optional header (8 bytes)
        hdr[4] = ((pesLen shr 8) and 0xFF).toByte()
        hdr[5] = (pesLen and 0xFF).toByte()
        hdr[6] = 0x80.toByte()  // marker bits
        hdr[7] = 0x80.toByte()  // PTS_DTS_flags = PTS only
        hdr[8] = 0x05           // PES header data length
        // PTS (33 bits in 5 bytes)
        hdr[9]  = (0x21 or ((pts shr 29) and 0x0E).toInt()).toByte()
        hdr[10] = ((pts shr 22) and 0xFF).toByte()
        hdr[11] = (0x01 or ((pts shr 14) and 0xFE).toInt()).toByte()
        hdr[12] = ((pts shr 7) and 0xFF).toByte()
        hdr[13] = (0x01 or ((pts and 0x7F).toInt() shl 1)).toByte()
        return hdr + data
    }

    private fun buildPAT(): ByteArray {
        val pkt = ByteArray(188); pkt.fill(0xFF.toByte())
        pkt[0] = 0x47; pkt[1] = 0x40; pkt[2] = 0x00; pkt[3] = 0x10
        pkt[4] = 0x00  // pointer field
        pkt[5] = 0x00  // table_id = 0x00 (PAT)
        pkt[6] = 0xB0.toByte(); pkt[7] = 0x0D  // section_length = 13
        pkt[8] = 0x00; pkt[9] = 0x01           // transport_stream_id = 1
        pkt[10] = 0xC1.toByte()                 // version=0, current=1
        pkt[11] = 0x00; pkt[12] = 0x00          // section 0 of 0
        pkt[13] = 0x00; pkt[14] = 0x01          // program_number = 1
        pkt[15] = (0xE0 or ((pmtPid shr 8) and 0x1F)).toByte()
        pkt[16] = (pmtPid and 0xFF).toByte()
        return pkt
    }

    private fun buildPMT(): ByteArray {
        val pkt = ByteArray(188); pkt.fill(0xFF.toByte())
        pkt[0] = 0x47
        pkt[1] = (0x40 or ((pmtPid shr 8) and 0x1F)).toByte()
        pkt[2] = (pmtPid and 0xFF).toByte()
        pkt[3] = 0x10
        pkt[4] = 0x00  // pointer
        pkt[5] = 0x02  // table_id = PMT
        pkt[6] = 0xB0.toByte(); pkt[7] = 0x12  // section_length = 18
        pkt[8] = 0x00; pkt[9] = 0x01            // program_number = 1
        pkt[10] = 0xC1.toByte()
        pkt[11] = 0x00; pkt[12] = 0x00
        pkt[13] = 0xE1.toByte(); pkt[14] = 0x00 // PCR PID = 0x100
        pkt[15] = 0xF0.toByte(); pkt[16] = 0x00 // no program info
        // Stream descriptor: H.265=0x24, H.264=0x1B
        val streamType = if (mimeType == MediaFormat.MIMETYPE_VIDEO_HEVC) 0x24 else 0x1B
        pkt[17] = streamType.toByte()
        pkt[18] = 0xE1.toByte(); pkt[19] = 0x00 // elementary PID = 0x100
        pkt[20] = 0xF0.toByte(); pkt[21] = 0x00 // no ES info
        return pkt
    }
}
