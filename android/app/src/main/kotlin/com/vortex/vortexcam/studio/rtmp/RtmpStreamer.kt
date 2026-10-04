package com.vortex.vortexcam.studio.rtmp

import android.media.MediaCodec
import android.util.Log
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.util.Random
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native RTMP Live Streamer (H.264 video + AAC audio FLV tag streaming)
 * Connects directly to YouTube, Twitch, Facebook, or custom RTMP/OBS servers on port 1935.
 */
class RtmpStreamer {
    companion object {
        private const val TAG = "RtmpStreamer"
        private const val DEFAULT_PORT = 1935
        private const val CHUNK_SIZE = 4096
    }

    private var socket: Socket? = null
    private var inStream: DataInputStream? = null
    private var outStream: BufferedOutputStream? = null

    private val isConnected = AtomicBoolean(false)
    private val sendQueue = LinkedBlockingQueue<ByteArray>(60)
    private var senderThread: Thread? = null

    var bytesSent: Long = 0
        private set
    var droppedPackets: Int = 0
        private set

    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var streamId = 1

    fun connect(rtmpUrl: String, streamKey: String) {
        if (isConnected.get()) disconnect()

        Log.i(TAG, "Connecting to RTMP: $rtmpUrl (key length: ${streamKey.length})")

        val uri = try {
            URI(rtmpUrl)
        } catch (e: Exception) {
            throw IllegalArgumentException("Invalid RTMP URL: $rtmpUrl")
        }

        val host = uri.host ?: "127.0.0.1"
        val port = if (uri.port > 0) uri.port else DEFAULT_PORT
        val app = uri.path?.trim('/') ?: "live"

        val s = Socket()
        s.tcpNoDelay = true
        s.connect(InetSocketAddress(host, port), 8000)

        socket = s
        inStream = DataInputStream(s.getInputStream())
        outStream = BufferedOutputStream(s.getOutputStream(), 16384)

        bytesSent = 0
        droppedPackets = 0

        // 1. RTMP Handshake
        performHandshake()

        // 2. Connect command
        sendConnectCommand(app, rtmpUrl)

        // 3. CreateStream command
        sendCreateStreamCommand()

        // 4. Publish command
        sendPublishCommand(streamKey)

        isConnected.set(true)

        // 5. Start async sender thread
        senderThread = Thread({ runSenderLoop() }, "RtmpSenderThread").apply { start() }

        Log.i(TAG, "RTMP connection established and publishing live stream")
    }

    private fun performHandshake() {
        val out = outStream ?: return
        val inS = inStream ?: return

        // Send C0 (0x03) + C1 (1536 random bytes)
        out.write(0x03)
        val c1 = ByteArray(1536)
        Random().nextBytes(c1)
        // Time = 0
        c1[0] = 0; c1[1] = 0; c1[2] = 0; c1[3] = 0
        // Zero = 0
        c1[4] = 0; c1[5] = 0; c1[6] = 0; c1[7] = 0
        out.write(c1)
        out.flush()

        // Read S0 (1 byte) + S1 (1536 bytes)
        val s0 = inS.readByte()
        if (s0.toInt() != 0x03) {
            throw RuntimeException("Unsupported RTMP version: $s0")
        }
        val s1 = ByteArray(1536)
        inS.readFully(s1)

        // Send C2 (mirroring S1)
        out.write(s1)
        out.flush()

        // Read S2 (1536 bytes)
        val s2 = ByteArray(1536)
        inS.readFully(s2)
    }

    private fun sendConnectCommand(app: String, tcUrl: String) {
        val baos = ByteArrayOutputStream()
        writeAmfString(baos, "connect")
        writeAmfNumber(baos, 1.0) // transaction ID

        // Command object
        baos.write(0x03) // Object start
        writeAmfProperty(baos, "app", app)
        writeAmfProperty(baos, "flashVer", "FMLE/3.0")
        writeAmfProperty(baos, "tcUrl", tcUrl)
        writeAmfProperty(baos, "fpad", false)
        writeAmfProperty(baos, "capabilities", 15.0)
        writeAmfProperty(baos, "audioCodecs", 3191.0)
        writeAmfProperty(baos, "videoCodecs", 252.0)
        writeAmfProperty(baos, "videoFunction", 1.0)
        baos.write(byteArrayOf(0x00, 0x00, 0x09)) // Object end

        sendRtmpPacket(csid = 3, messageType = 0x14, streamId = 0, payload = baos.toByteArray())
    }

    private fun sendCreateStreamCommand() {
        val baos = ByteArrayOutputStream()
        writeAmfString(baos, "createStream")
        writeAmfNumber(baos, 2.0)
        baos.write(0x05) // Null object

        sendRtmpPacket(csid = 3, messageType = 0x14, streamId = 0, payload = baos.toByteArray())
    }

    private fun sendPublishCommand(streamKey: String) {
        val baos = ByteArrayOutputStream()
        writeAmfString(baos, "publish")
        writeAmfNumber(baos, 0.0)
        baos.write(0x05) // Null object
        writeAmfString(baos, streamKey)
        writeAmfString(baos, "live")

        sendRtmpPacket(csid = 4, messageType = 0x14, streamId = streamId, payload = baos.toByteArray())
    }

    private fun stripStartCode(nalu: ByteArray): ByteArray {
        var offset = 0
        if (nalu.size >= 4 && nalu[0] == 0.toByte() && nalu[1] == 0.toByte() && nalu[2] == 0.toByte() && nalu[3] == 1.toByte()) {
            offset = 4
        } else if (nalu.size >= 3 && nalu[0] == 0.toByte() && nalu[1] == 0.toByte() && nalu[2] == 1.toByte()) {
            offset = 3
        }
        if (offset == 0) return nalu
        return nalu.copyOfRange(offset, nalu.size)
    }

    private fun annexBtoAvcc(buffer: ByteBuffer, bufferInfo: MediaCodec.BufferInfo): ByteArray {
        val raw = ByteArray(bufferInfo.size)
        val origPos = buffer.position()
        buffer.position(bufferInfo.offset)
        buffer.get(raw)
        buffer.position(origPos)

        val out = ByteArrayOutputStream()
        var i = 0
        while (i < raw.size) {
            val startCodeLen = if (i + 4 <= raw.size && raw[i] == 0.toByte() && raw[i+1] == 0.toByte() && raw[i+2] == 0.toByte() && raw[i+3] == 1.toByte()) {
                4
            } else if (i + 3 <= raw.size && raw[i] == 0.toByte() && raw[i+1] == 0.toByte() && raw[i+2] == 1.toByte()) {
                3
            } else {
                0
            }

            if (startCodeLen > 0) {
                val naluStart = i + startCodeLen
                var nextStart = raw.size
                var j = naluStart
                while (j < raw.size - 2) {
                    if (raw[j] == 0.toByte() && raw[j+1] == 0.toByte() && (raw[j+2] == 1.toByte() || (j+3 < raw.size && raw[j+2] == 0.toByte() && raw[j+3] == 1.toByte()))) {
                        nextStart = j
                        break
                    }
                    j++
                }

                val naluLen = nextStart - naluStart
                if (naluLen > 0) {
                    out.write((naluLen shr 24) and 0xFF)
                    out.write((naluLen shr 16) and 0xFF)
                    out.write((naluLen shr 8) and 0xFF)
                    out.write(naluLen and 0xFF)
                    out.write(raw, naluStart, naluLen)
                }
                i = nextStart
            } else {
                i++
            }
        }
        return out.toByteArray()
    }

    /**
     * Send video slice or sequence header (SPS/PPS) to RTMP server in AVCC format
     */
    fun sendVideoData(data: ByteBuffer, bufferInfo: MediaCodec.BufferInfo, isKeyFrame: Boolean) {
        if (!isConnected.get()) return

        val pts = (bufferInfo.presentationTimeUs / 1000).toInt()
        val avccData = annexBtoAvcc(data, bufferInfo)
        if (avccData.isEmpty()) return

        val payload = ByteArray(5 + avccData.size)
        // FrameType & CodecID: 0x17 = Keyframe + AVC, 0x27 = Interframe + AVC
        payload[0] = if (isKeyFrame) 0x17.toByte() else 0x27.toByte()
        payload[1] = 0x01 // AVC NALU
        payload[2] = 0x00 // Composition time (3 bytes)
        payload[3] = 0x00
        payload[4] = 0x00
        System.arraycopy(avccData, 0, payload, 5, avccData.size)

        val packet = buildRtmpPacket(csid = 6, messageType = 0x09, timestamp = pts, streamId = streamId, payload = payload)
        if (!sendQueue.offer(packet)) {
            droppedPackets++
        }
    }

    fun setSpsPps(spsBytes: ByteArray, ppsBytes: ByteArray) {
        val cleanSps = stripStartCode(spsBytes)
        val cleanPps = stripStartCode(ppsBytes)
        if (cleanSps.size < 4 || cleanPps.isEmpty()) return

        this.sps = cleanSps
        this.pps = cleanPps

        // Build AVCDecoderConfigurationRecord (FLV sequence header)
        val baos = ByteArrayOutputStream()
        baos.write(0x17) // Keyframe + AVC
        baos.write(0x00) // AVC sequence header
        baos.write(byteArrayOf(0, 0, 0)) // Composition time

        // ConfigurationVersion = 1
        baos.write(1)
        baos.write(cleanSps[1].toInt()) // Profile (AVCProfileIndication)
        baos.write(cleanSps[2].toInt()) // Profile compatibility
        baos.write(cleanSps[3].toInt()) // Level (AVCLevelIndication)
        baos.write(0xFF) // 4 bytes NALU length size (lengthSizeMinusOne = 3)
        baos.write(0xE1) // 1 SPS
        baos.write((cleanSps.size shr 8) and 0xFF)
        baos.write(cleanSps.size and 0xFF)
        baos.write(cleanSps)

        baos.write(1) // 1 PPS
        baos.write((cleanPps.size shr 8) and 0xFF)
        baos.write(cleanPps.size and 0xFF)
        baos.write(cleanPps)

        val packet = buildRtmpPacket(csid = 6, messageType = 0x09, timestamp = 0, streamId = streamId, payload = baos.toByteArray())
        sendQueue.offer(packet)
    }

    private fun buildRtmpPacket(csid: Int, messageType: Int, timestamp: Int = 0, streamId: Int, payload: ByteArray): ByteArray {
        val baos = ByteArrayOutputStream()
        // Chunk Header: fmt = 0, csid
        baos.write((0 shl 6) or (csid and 0x3F))

        // Timestamp (3 bytes)
        val ts = if (timestamp > 0xFFFFFF) 0xFFFFFF else timestamp
        baos.write((ts shr 16) and 0xFF)
        baos.write((ts shr 8) and 0xFF)
        baos.write(ts and 0xFF)

        // Body Size (3 bytes)
        val len = payload.size
        baos.write((len shr 16) and 0xFF)
        baos.write((len shr 8) and 0xFF)
        baos.write(len and 0xFF)

        // Message Type ID (1 byte)
        baos.write(messageType and 0xFF)

        // Message Stream ID (4 bytes, little-endian)
        baos.write(streamId and 0xFF)
        baos.write((streamId shr 8) and 0xFF)
        baos.write((streamId shr 16) and 0xFF)
        baos.write((streamId shr 24) and 0xFF)

        // Payload in chunks of 128 bytes (default)
        var offset = 0
        val chunkSize = 128
        while (offset < payload.size) {
            val toWrite = Math.min(chunkSize, payload.size - offset)
            baos.write(payload, offset, toWrite)
            offset += toWrite
            if (offset < payload.size) {
                // Type 3 chunk header (fmt = 3, same csid)
                baos.write((3 shl 6) or (csid and 0x3F))
            }
        }

        return baos.toByteArray()
    }

    private fun sendRtmpPacket(csid: Int, messageType: Int, timestamp: Int = 0, streamId: Int, payload: ByteArray) {
        val packet = buildRtmpPacket(csid, messageType, timestamp, streamId, payload)
        sendQueue.offer(packet)
    }

    private fun runSenderLoop() {
        val out = outStream ?: return
        while (isConnected.get()) {
            val packet = try {
                sendQueue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                break
            }

            if (packet != null) {
                try {
                    out.write(packet)
                    out.flush()
                    bytesSent += packet.size
                } catch (e: Exception) {
                    Log.w(TAG, "Socket write error: ${e.message}")
                    disconnect()
                    break
                }
            }
        }
    }

    private fun writeAmfString(out: ByteArrayOutputStream, str: String) {
        out.write(0x02) // String marker
        val bytes = str.toByteArray(Charsets.UTF_8)
        out.write((bytes.size shr 8) and 0xFF)
        out.write(bytes.size and 0xFF)
        out.write(bytes)
    }

    private fun writeAmfNumber(out: ByteArrayOutputStream, num: Double) {
        out.write(0x00) // Number marker
        val bits = java.lang.Double.doubleToRawLongBits(num)
        for (i in 7 downTo 0) {
            out.write(((bits shr (i * 8)) and 0xFF).toInt())
        }
    }

    private fun writeAmfProperty(out: ByteArrayOutputStream, key: String, value: Any) {
        val keyBytes = key.toByteArray(Charsets.UTF_8)
        out.write((keyBytes.size shr 8) and 0xFF)
        out.write(keyBytes.size and 0xFF)
        out.write(keyBytes)

        when (value) {
            is String -> writeAmfString(out, value)
            is Double -> writeAmfNumber(out, value)
            is Boolean -> {
                out.write(0x01)
                out.write(if (value) 1 else 0)
            }
        }
    }

    fun disconnect() {
        isConnected.set(false)
        try {
            senderThread?.interrupt()
            socket?.close()
        } catch (ignored: Exception) {}
        socket = null
        inStream = null
        outStream = null
        sendQueue.clear()
        Log.i(TAG, "RTMP streamer disconnected: $bytesSent bytes sent, $droppedPackets dropped")
    }
}
