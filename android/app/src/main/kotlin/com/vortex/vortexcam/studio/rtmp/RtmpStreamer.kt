package com.vortex.vortexcam.studio.rtmp

import android.media.MediaCodec
import android.util.Log
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.util.Random
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * RTMP / RTMPS publisher for the switcher's program: H.264 video + AAC audio as FLV tags.
 *
 * Rewritten 2026-10-04. The Studio original was enough for SAMBA's ingest but not for platforms: no audio, no RTMPS
 * (Facebook only takes rtmps://…:443), it never read the server (stream id assumed 1, a rejected key looked like a
 * live stream, Window-Ack / ping never answered), 128-byte chunks and timestamps clamped at 4.6 h. Now:
 *  - rtmp:// and rtmps:// (TLS with SNI + hostname check);
 *  - real command exchange: connect → releaseStream/FCPublish/createStream (stream id from _result) → publish, and
 *    waits for NetStream.Publish.Start (a refused key is an error with the server's own words);
 *  - @setDataFrame onMetaData, AVC + AAC sequence headers, re-sent after every reconnection;
 *  - a reader thread answers Window Acknowledgement, ping and Set Chunk Size;
 *  - congestion: never drops audio or headers; drops video until the next keyframe and asks the encoder for one;
 *  - the link drops → reconnects by itself (every 2 s) until disconnect().
 */
class RtmpStreamer {
    companion object {
        private const val TAG = "RtmpStreamer"
        private const val OUT_CHUNK = 4096
        private const val CSID_CONTROL = 2
        private const val CSID_COMMAND = 3
        private const val CSID_AUDIO = 4
        private const val CSID_DATA = 5
        private const val CSID_VIDEO = 6
        private const val MAX_QUEUE_BYTES = 3L * 1024 * 1024     // ≈5 s at 4.5 Mbps: beyond this the link can't keep up
        private const val SETUP_TIMEOUT_MS = 10_000
    }

    private class Msg(val csid: Int, val type: Int, val ts: Int, val sid: Int, val payload: ByteArray)

    @Volatile private var socket: Socket? = null
    @Volatile private var input: DataInputStream? = null
    @Volatile private var output: BufferedOutputStream? = null
    private val writeLock = Any()

    private val wanted = AtomicBoolean(false)     // between connect() and disconnect()
    private val linkUp = AtomicBoolean(false)     // published and sending
    private val queue = LinkedBlockingDeque<Msg>()
    private val queuedBytes = AtomicLong(0)
    private var senderThread: Thread? = null
    private var readerThread: Thread? = null
    private var reconnectThread: Thread? = null

    private var url = ""
    private var key = ""
    private var streamId = 1
    private var txn = 0

    // Server → client state (reader thread)
    private var inChunkSize = 128
    private var windowAck = 2_500_000L
    private var bytesIn = 0L
    private var lastAckSent = 0L
    private val pendingResponses = LinkedBlockingDeque<List<Any?>>()

    // What a (re)connection must send before any media
    @Volatile private var metadata: ByteArray? = null
    @Volatile private var videoHeader: ByteArray? = null
    @Volatile private var audioHeader: ByteArray? = null
    @Volatile private var videoHeaderSent = false
    @Volatile private var audioHeaderSent = false
    @Volatile private var waitKeyframe = true
    private var tsBaseUs = -1L

    /** Asked when video was dropped / after a reconnection: the receiver needs a keyframe to restart decoding. */
    var onNeedKeyframe: (() -> Unit)? = null

    var bytesSent: Long = 0
        private set
    var droppedPackets: Int = 0
        private set
    var reconnects: Int = 0
        private set
    @Volatile var lastError: String? = null
        private set
    val isConnected: Boolean get() = linkUp.get()

    // ── Public API ───────────────────────────────────────────────────────────────────────────────────────────────

    /** Blocking (call it off the main thread). Throws with the server's reason if the publish is refused. */
    fun connect(rtmpUrl: String, streamKey: String) {
        disconnect()
        url = rtmpUrl.trim().trimEnd('/')
        key = streamKey.trim()
        if (key.isEmpty()) {                        // key pasted at the end of the URL: rtmp://host/app/KEY
            val segs = (URI(url).path ?: "").trim('/').split('/').filter { it.isNotEmpty() }
            if (segs.size >= 2) { key = segs.last(); url = url.substring(0, url.length - key.length - 1) }
        }
        wanted.set(true)
        try {
            openAndPublish()
        } catch (e: Exception) {
            wanted.set(false)
            closeSocket()
            lastError = e.message ?: e.toString()
            throw e
        }
    }

    fun disconnect() {
        if (!wanted.getAndSet(false) && socket == null) return
        linkUp.set(false)
        reconnectThread?.interrupt()
        // Polite end: FCUnpublish + deleteStream (best effort, the socket closes right after)
        try {
            synchronized(writeLock) {
                writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("FCUnpublish", (++txn).toDouble(), null, key)))
                writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("deleteStream", (++txn).toDouble(), null, streamId.toDouble())))
                output?.flush()
            }
        } catch (_: Exception) {}
        closeSocket()
        queue.clear(); queuedBytes.set(0)
        Log.i(TAG, "RTMP disconnected: $bytesSent bytes sent, $droppedPackets dropped, $reconnects reconnections")
    }

    /** FLV onMetaData; call before connect() (it is re-sent on every reconnection). sampleRate 0 = no audio. */
    fun setMetadata(width: Int, height: Int, fps: Int, videoKbps: Int, audioKbps: Int, sampleRate: Int, channels: Int) {
        val b = ByteArrayOutputStream()
        amfWriteString(b, "@setDataFrame"); amfWriteString(b, "onMetaData")
        val props = linkedMapOf<String, Any>(
            "duration" to 0.0, "width" to width.toDouble(), "height" to height.toDouble(),
            "videodatarate" to videoKbps.toDouble(), "framerate" to fps.toDouble(), "videocodecid" to 7.0,
            "encoder" to "Samba Air")
        if (sampleRate > 0) {
            props["audiodatarate"] = audioKbps.toDouble(); props["audiosamplerate"] = sampleRate.toDouble()
            props["audiosamplesize"] = 16.0; props["stereo"] = channels > 1; props["audiocodecid"] = 10.0
        }
        b.write(0x08)                                                    // ECMA array
        b.write(int32(props.size))
        for ((k, v) in props) amfWriteProperty(b, k, v)
        b.write(byteArrayOf(0, 0, 0x09))
        val md = b.toByteArray()
        metadata = md
        if (linkUp.get()) enqueue(Msg(CSID_DATA, 0x12, 0, streamId, md), control = true)
    }

    /** AVC sequence header from MediaCodec's csd-0 / csd-1 (Annex-B or raw). */
    fun setSpsPps(spsBytes: ByteArray, ppsBytes: ByteArray) {
        val sps = splitAnnexB(spsBytes).firstOrNull { (it[0].toInt() and 0x1F) == 7 } ?: stripStartCode(spsBytes)
        val pps = splitAnnexB(ppsBytes).firstOrNull { (it[0].toInt() and 0x1F) == 8 } ?: stripStartCode(ppsBytes)
        if (sps.size < 4 || pps.isEmpty()) return
        val b = ByteArrayOutputStream()
        b.write(0x17); b.write(0x00); b.write(byteArrayOf(0, 0, 0))   // keyframe+AVC, sequence header, cts 0
        b.write(1); b.write(sps[1].toInt()); b.write(sps[2].toInt()); b.write(sps[3].toInt())
        b.write(0xFF); b.write(0xE1)
        b.write((sps.size shr 8) and 0xFF); b.write(sps.size and 0xFF); b.write(sps)
        b.write(1); b.write((pps.size shr 8) and 0xFF); b.write(pps.size and 0xFF); b.write(pps)
        val hdr = b.toByteArray()
        videoHeader = hdr
        if (linkUp.get()) { enqueue(Msg(CSID_VIDEO, 0x09, 0, streamId, hdr), control = true); videoHeaderSent = true }
    }

    /** AAC sequence header: the AudioSpecificConfig (csd-0 of the AAC encoder). */
    fun setAudioConfig(asc: ByteArray) {
        val hdr = byteArrayOf(0xAF.toByte(), 0x00) + asc
        audioHeader = hdr
        if (linkUp.get()) { enqueue(Msg(CSID_AUDIO, 0x08, 0, streamId, hdr), control = true); audioHeaderSent = true }
    }

    fun sendVideoData(data: ByteBuffer, bufferInfo: MediaCodec.BufferInfo, isKeyFrame: Boolean) {
        if (!linkUp.get() || !videoHeaderSent || bufferInfo.size <= 0) return
        if (waitKeyframe && !isKeyFrame) return
        if (queuedBytes.get() > MAX_QUEUE_BYTES && !isKeyFrame) {         // link can't keep up: skip to next keyframe
            if (!waitKeyframe) { waitKeyframe = true; onNeedKeyframe?.invoke() }
            droppedPackets++; return
        }
        waitKeyframe = false
        val raw = ByteArray(bufferInfo.size)
        val dup = data.duplicate(); dup.position(bufferInfo.offset); dup.get(raw)
        val b = ByteArrayOutputStream(raw.size + 16)
        b.write(if (isKeyFrame) 0x17 else 0x27); b.write(0x01); b.write(byteArrayOf(0, 0, 0))
        for (nal in splitAnnexB(raw)) {
            val t = nal[0].toInt() and 0x1F
            if (t == 9 || t == 7 || t == 8) continue        // AUD, and in-band SPS/PPS (already in the header)
            b.write(int32(nal.size)); b.write(nal)
        }
        enqueue(Msg(CSID_VIDEO, 0x09, mediaTs(bufferInfo.presentationTimeUs), streamId, b.toByteArray()), control = false)
    }

    fun sendAudioData(data: ByteBuffer, bufferInfo: MediaCodec.BufferInfo) {
        if (!linkUp.get() || !audioHeaderSent || bufferInfo.size <= 0) return
        if (queuedBytes.get() > MAX_QUEUE_BYTES * 2) { droppedPackets++; return }   // hopeless link: drop everything
        val out = ByteArray(2 + bufferInfo.size)
        out[0] = 0xAF.toByte(); out[1] = 0x01
        val dup = data.duplicate(); dup.position(bufferInfo.offset); dup.get(out, 2, bufferInfo.size)
        enqueue(Msg(CSID_AUDIO, 0x08, mediaTs(bufferInfo.presentationTimeUs), streamId, out), control = false)
    }

    // ── Connection ───────────────────────────────────────────────────────────────────────────────────────────────

    private fun openAndPublish() {
        val u = URI(url)
        val scheme = u.scheme ?: ""
        val secure = scheme.equals("rtmps", ignoreCase = true)
        if (!secure && !scheme.equals("rtmp", ignoreCase = true)) throw IllegalArgumentException("La URL no es rtmp:// ni rtmps://: $url")
        val host = u.host ?: throw IllegalArgumentException("URL sin servidor: $url")
        val port = if (u.port > 0) u.port else if (secure) 443 else 1935
        val app = (u.path ?: "").trim('/')
        Log.i(TAG, "Connecting ${if (secure) "RTMPS" else "RTMP"} $host:$port app='$app' (key ${key.length} chars)")

        val plain = Socket().apply { tcpNoDelay = true; soTimeout = SETUP_TIMEOUT_MS }
        plain.connect(InetSocketAddress(host, port), 8000)
        val s: Socket = if (secure) {
            val ssl = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(plain, host, port, true) as SSLSocket
            ssl.startHandshake()
            if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, ssl.session)) {
                ssl.close(); throw IOException("El certificado TLS no corresponde a $host")
            }
            ssl
        } else plain
        socket = s
        input = DataInputStream(s.getInputStream())
        output = BufferedOutputStream(s.getOutputStream(), 64 * 1024)
        inChunkSize = 128; windowAck = 2_500_000L; bytesIn = 0; lastAckSent = 0
        pendingResponses.clear(); queue.clear(); queuedBytes.set(0)

        handshake()
        synchronized(writeLock) {
            writeMessage(Msg(CSID_CONTROL, 0x01, 0, 0, int32(OUT_CHUNK)))   // our chunk size, announced before use
            val connectObj = linkedMapOf<String, Any>(
                "app" to app, "type" to "nonprivate", "flashVer" to "FMLE/3.0 (compatible; SambaAir)",
                "tcUrl" to url, "fpad" to false, "capabilities" to 15.0, "audioCodecs" to 3191.0,
                "videoCodecs" to 252.0, "videoFunction" to 1.0)
            writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("connect", 1.0, connectObj)))
            output!!.flush()
        }
        txn = 1
        readerThread = Thread({ readerLoop() }, "RtmpReader").apply { isDaemon = true; start() }
        awaitResult(1.0, "connect")

        synchronized(writeLock) {
            writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("releaseStream", 2.0, null, key)))
            writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("FCPublish", 3.0, null, key)))
            writeMessage(Msg(CSID_COMMAND, 0x14, 0, 0, amfCommand("createStream", 4.0, null)))
            output!!.flush()
        }
        txn = 4
        val cs = awaitResult(4.0, "createStream")
        streamId = (cs.getOrNull(3) as? Double)?.toInt() ?: 1

        synchronized(writeLock) {
            writeMessage(Msg(CSID_COMMAND, 0x14, 0, streamId, amfCommand("publish", 5.0, null, key, "live")))
            output!!.flush()
        }
        txn = 5
        awaitPublishStart()
        s.soTimeout = 0

        // Media may flow now: metadata + sequence headers first, then wait for a keyframe.
        videoHeaderSent = false; audioHeaderSent = false; waitKeyframe = true
        synchronized(this) { tsBaseUs = -1 }
        linkUp.set(true)
        metadata?.let { queue.offerLast(Msg(CSID_DATA, 0x12, 0, streamId, it)) }
        videoHeader?.let { queue.offerLast(Msg(CSID_VIDEO, 0x09, 0, streamId, it)); videoHeaderSent = true }
        audioHeader?.let { queue.offerLast(Msg(CSID_AUDIO, 0x08, 0, streamId, it)); audioHeaderSent = true }
        senderThread = Thread({ senderLoop() }, "RtmpSender").apply { start() }
        lastError = null
        onNeedKeyframe?.invoke()
        Log.i(TAG, "Publishing on $host:$port/$app (stream id $streamId)")
    }

    private fun handshake() {
        val out = output!!; val inp = input!!
        val c1 = ByteArray(1536); Random().nextBytes(c1)
        for (i in 0 until 8) c1[i] = 0
        out.write(0x03); out.write(c1); out.flush()
        val s0 = inp.readUnsignedByte()
        if (s0 != 0x03) throw IOException("Versión RTMP no soportada: $s0")
        val s1 = ByteArray(1536); inp.readFully(s1)
        out.write(s1); out.flush()                     // C2 = echo of S1
        val s2 = ByteArray(1536); inp.readFully(s2)
        bytesIn += 1 + 1536 * 2
    }

    private fun awaitResult(id: Double, what: String): List<Any?> {
        val deadline = System.currentTimeMillis() + SETUP_TIMEOUT_MS
        while (true) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) throw IOException("El servidor no respondió a '$what'")
            val r = pendingResponses.poll(left, TimeUnit.MILLISECONDS) ?: continue
            val name = r.getOrNull(0) as? String
            val t = r.getOrNull(1) as? Double
            if (name == "_error" && (t == id || t == -1.0)) throw IOException("El servidor rechazó '$what': ${describe(r)}")
            if (name == "_result" && t == id) return r
            // anything else (onBWDone, onFCPublish…) is informational
        }
    }

    private fun awaitPublishStart() {
        val deadline = System.currentTimeMillis() + SETUP_TIMEOUT_MS
        while (true) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) throw IOException("El servidor no confirmó la publicación (¿clave correcta?)")
            val r = pendingResponses.poll(left, TimeUnit.MILLISECONDS) ?: continue
            val name = r.getOrNull(0) as? String
            val t = r.getOrNull(1) as? Double
            // YouTube / Facebook / Twitch don't answer a wrong key: they just close the connection at publish.
            if (name == "_error" && t == -1.0)
                throw IOException("La plataforma cortó al publicar: revisá la clave de transmisión (o que el evento esté creado)")
            if (name == "_error" && t == 5.0) throw IOException("Publicación rechazada: ${describe(r)}")
            if (name != "onStatus") continue
            val info = r.getOrNull(3) as? Map<*, *> ?: continue
            val code = info["code"] as? String ?: ""
            if (code == "NetStream.Publish.Start") return
            if ((info["level"] as? String) == "error" || code.contains("BadName") || code.contains("Failed") ||
                code.contains("Rejected") || code.contains("Denied"))
                throw IOException("Publicación rechazada: $code ${info["description"] ?: ""}".trim())
        }
    }

    private fun describe(r: List<Any?>): String {
        val info = r.drop(2).firstOrNull { it is Map<*, *> } as? Map<*, *>
        return listOfNotNull(info?.get("code"), info?.get("description")).joinToString(" ").ifEmpty { r.toString() }
    }

    private fun linkLost(reason: String) {
        if (!linkUp.getAndSet(false) || !wanted.get()) return
        lastError = reason
        Log.w(TAG, "RTMP link lost: $reason — reconnecting")
        closeSocket()
        reconnectThread = Thread({
            while (wanted.get() && !linkUp.get()) {
                try { Thread.sleep(2000) } catch (_: InterruptedException) { return@Thread }
                if (!wanted.get()) return@Thread
                try {
                    openAndPublish(); reconnects++
                    Log.i(TAG, "RTMP reconnected (#$reconnects)")
                } catch (e: Exception) {
                    lastError = e.message ?: e.toString()
                    Log.w(TAG, "RTMP reconnect failed: $lastError"); closeSocket()
                }
            }
        }, "RtmpReconnect").apply { isDaemon = true; start() }
    }

    private fun closeSocket() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null; input = null; output = null
        val me = Thread.currentThread()
        readerThread?.let { if (it !== me) it.interrupt() }; readerThread = null
        senderThread?.let { if (it !== me) it.interrupt() }; senderThread = null
    }

    // ── Sending ──────────────────────────────────────────────────────────────────────────────────────────────────

    @Synchronized private fun mediaTs(ptsUs: Long): Int {
        if (tsBaseUs < 0) tsBaseUs = ptsUs
        return ((ptsUs - tsBaseUs) / 1000).coerceAtLeast(0).toInt()
    }

    private fun enqueue(m: Msg, control: Boolean) {
        queuedBytes.addAndGet(m.payload.size.toLong())
        if (control) queue.offerFirst(m) else queue.offerLast(m)
    }

    private fun senderLoop() {
        while (linkUp.get()) {
            val m = (try { queue.poll(200, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { null }) ?: continue
            queuedBytes.addAndGet(-m.payload.size.toLong())
            try {
                synchronized(writeLock) {
                    writeMessage(m)
                    if (queue.isEmpty()) output?.flush()
                }
            } catch (e: Exception) {
                linkLost("envío: ${e.message}"); break
            }
        }
    }

    /** One message as fmt-0 chunks of OUT_CHUNK bytes (extended timestamp from 0xFFFFFF on). Caller holds writeLock. */
    private fun writeMessage(m: Msg) {
        val out = output ?: throw IOException("socket cerrado")
        val ext = m.ts >= 0xFFFFFF
        val ts = if (ext) 0xFFFFFF else m.ts
        val h = ByteArray(12)
        h[0] = (m.csid and 0x3F).toByte()
        h[1] = (ts shr 16).toByte(); h[2] = (ts shr 8).toByte(); h[3] = ts.toByte()
        h[4] = (m.payload.size shr 16).toByte(); h[5] = (m.payload.size shr 8).toByte(); h[6] = m.payload.size.toByte()
        h[7] = m.type.toByte()
        h[8] = m.sid.toByte(); h[9] = (m.sid shr 8).toByte(); h[10] = (m.sid shr 16).toByte(); h[11] = (m.sid shr 24).toByte()
        out.write(h)
        val extBytes = int32(m.ts)
        if (ext) out.write(extBytes)
        var off = 0
        while (off < m.payload.size) {
            if (off > 0) { out.write(0xC0 or (m.csid and 0x3F)); if (ext) out.write(extBytes) }
            val n = minOf(OUT_CHUNK, m.payload.size - off)
            out.write(m.payload, off, n); off += n
        }
        bytesSent += 12 + m.payload.size + (m.payload.size / OUT_CHUNK)
    }

    // ── Reading (server messages) ────────────────────────────────────────────────────────────────────────────────

    private class InState { var len = 0; var type = 0; var buf: ByteArrayOutputStream? = null; var ext = false }

    private fun readerLoop() {
        val states = HashMap<Int, InState>()
        val inp = input ?: return
        try {
            while (wanted.get()) {
                // A quiet server is not a dead link: most servers (ffmpeg, SAMBA) send nothing after publish. The
                // setup timeout (10 s) stays on a read that was already blocked when it is lifted, so a silent server
                // looked like "Read timed out" after 10 s and the stream reconnected (found 2026-10-04, Mi A3).
                val b0 = try { inp.readUnsignedByte() } catch (_: java.net.SocketTimeoutException) {
                    if (linkUp.get()) continue else throw IOException("el servidor no respondió")
                }
                count(1)
                val fmt = b0 ushr 6
                var csid = b0 and 0x3F
                if (csid == 0) { csid = 64 + inp.readUnsignedByte(); count(1) }
                else if (csid == 1) { csid = 64 + inp.readUnsignedByte() + inp.readUnsignedByte() * 256; count(2) }
                val st = states.getOrPut(csid) { InState() }
                if (fmt <= 2) {
                    val ts = read24(inp)
                    if (fmt <= 1) { st.len = read24(inp); st.type = inp.readUnsignedByte(); count(1) }
                    if (fmt == 0) { inp.readInt(); count(4) }                           // message stream id
                    st.ext = ts == 0xFFFFFF
                    if (st.ext) { inp.readInt(); count(4) }
                } else if (st.ext) { inp.readInt(); count(4) }
                val buf = st.buf ?: ByteArrayOutputStream(st.len).also { st.buf = it }
                val n = minOf(inChunkSize, st.len - buf.size())
                if (n > 0) { val tmp = ByteArray(n); inp.readFully(tmp); count(n); buf.write(tmp) }
                if (buf.size() >= st.len) { st.buf = null; onServerMessage(st.type, buf.toByteArray()) }
            }
        } catch (e: Exception) {
            if (wanted.get()) {
                if (linkUp.get()) linkLost("lectura: ${e.message}")
                else pendingResponses.offer(listOf("_error", -1.0, null,
                    mapOf("code" to "conexión cerrada por el servidor", "description" to (e.message ?: ""))))
            }
        }
    }

    private fun read24(inp: DataInputStream): Int {
        val v = (inp.readUnsignedByte() shl 16) or (inp.readUnsignedByte() shl 8) or inp.readUnsignedByte()
        count(3); return v
    }

    private fun count(n: Int) {
        bytesIn += n
        if (bytesIn - lastAckSent >= windowAck) {
            lastAckSent = bytesIn
            try { synchronized(writeLock) { writeMessage(Msg(CSID_CONTROL, 0x03, 0, 0, int32(bytesIn.toInt()))); output?.flush() } }
            catch (_: Exception) {}
        }
    }

    private fun onServerMessage(type: Int, p: ByteArray) {
        when (type) {
            0x01 -> if (p.size >= 4) inChunkSize = (readInt(p, 0) and 0x7FFFFFFF).coerceAtLeast(1)
            0x05 -> if (p.size >= 4) windowAck = (readInt(p, 0).toLong() and 0xFFFFFFFFL).coerceAtLeast(1)
            0x04 -> if (p.size >= 6 && (((p[0].toInt() and 0xFF) shl 8) or (p[1].toInt() and 0xFF)) == 6) {   // ping
                val resp = byteArrayOf(0, 7) + p.copyOfRange(2, 6)
                try { synchronized(writeLock) { writeMessage(Msg(CSID_CONTROL, 0x04, 0, 0, resp)); output?.flush() } } catch (_: Exception) {}
            }
            0x14 -> {
                val vals = try { Amf0Reader(p).readAll() } catch (_: Exception) { return }
                val name = vals.getOrNull(0) as? String
                if (name == "onStatus" && linkUp.get()) {
                    val code = (vals.getOrNull(3) as? Map<*, *>)?.get("code") as? String ?: ""
                    Log.i(TAG, "onStatus $code")
                    if (code.contains("Unpublish") || code.contains("Failed") || code.contains("BadName"))
                        linkLost("el servidor cortó: $code")
                } else pendingResponses.offer(vals)
            }
        }
    }

    // ── AMF0 ─────────────────────────────────────────────────────────────────────────────────────────────────────

    private fun amfCommand(name: String, txnId: Double, obj: Map<String, Any>?, vararg args: Any): ByteArray {
        val b = ByteArrayOutputStream()
        amfWriteString(b, name); amfWriteNumber(b, txnId)
        if (obj == null) b.write(0x05) else { b.write(0x03); for ((k, v) in obj) amfWriteProperty(b, k, v); b.write(byteArrayOf(0, 0, 9)) }
        for (a in args) amfWriteValue(b, a)
        return b.toByteArray()
    }

    private fun amfWriteValue(b: ByteArrayOutputStream, v: Any) {
        when (v) {
            is String -> amfWriteString(b, v)
            is Double -> amfWriteNumber(b, v)
            is Int -> amfWriteNumber(b, v.toDouble())
            is Boolean -> { b.write(0x01); b.write(if (v) 1 else 0) }
        }
    }

    private fun amfWriteString(b: ByteArrayOutputStream, s: String) {
        val bytes = s.toByteArray(Charsets.UTF_8)
        b.write(0x02); b.write((bytes.size shr 8) and 0xFF); b.write(bytes.size and 0xFF); b.write(bytes)
    }

    private fun amfWriteNumber(b: ByteArrayOutputStream, n: Double) {
        b.write(0x00)
        val bits = java.lang.Double.doubleToRawLongBits(n)
        for (i in 7 downTo 0) b.write(((bits shr (i * 8)) and 0xFF).toInt())
    }

    private fun amfWriteProperty(b: ByteArrayOutputStream, k: String, v: Any) {
        val kb = k.toByteArray(Charsets.UTF_8)
        b.write((kb.size shr 8) and 0xFF); b.write(kb.size and 0xFF); b.write(kb)
        amfWriteValue(b, v)
    }

    private class Amf0Reader(private val p: ByteArray) {
        private var i = 0
        fun readAll(): List<Any?> { val l = ArrayList<Any?>(); while (i < p.size) l.add(value()); return l }
        private fun u16(): Int { val v = ((p[i].toInt() and 0xFF) shl 8) or (p[i + 1].toInt() and 0xFF); i += 2; return v }
        private fun str(n: Int): String { val s = String(p, i, n, Charsets.UTF_8); i += n; return s }
        private fun props(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            while (i + 2 < p.size) {
                val n = u16()
                if (n == 0 && (p[i].toInt() and 0xFF) == 0x09) { i++; break }
                val k = str(n); m[k] = value()
            }
            return m
        }
        fun value(): Any? = when (val t = p[i++].toInt() and 0xFF) {
            0x00 -> { val v = ByteBuffer.wrap(p, i, 8).double; i += 8; v }
            0x01 -> (p[i++].toInt() != 0)
            0x02 -> str(u16())
            0x03 -> props()
            0x05, 0x06 -> null
            0x08 -> { i += 4; props() }
            0x0A -> { val n = ByteBuffer.wrap(p, i, 4).int; i += 4; List(n) { value() } }
            0x0C -> { val n = ByteBuffer.wrap(p, i, 4).int; i += 4; str(n) }
            else -> throw IllegalStateException("AMF0 type $t")
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────────────────────────────

    private fun int32(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
    private fun readInt(p: ByteArray, o: Int) =
        ((p[o].toInt() and 0xFF) shl 24) or ((p[o + 1].toInt() and 0xFF) shl 16) or ((p[o + 2].toInt() and 0xFF) shl 8) or (p[o + 3].toInt() and 0xFF)

    private fun stripStartCode(n: ByteArray): ByteArray = when {
        n.size >= 4 && n[0].toInt() == 0 && n[1].toInt() == 0 && n[2].toInt() == 0 && n[3].toInt() == 1 -> n.copyOfRange(4, n.size)
        n.size >= 3 && n[0].toInt() == 0 && n[1].toInt() == 0 && n[2].toInt() == 1 -> n.copyOfRange(3, n.size)
        else -> n
    }

    /** NAL units of an Annex-B buffer without start codes; no start code at all → the whole buffer is one NAL. */
    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 2 < data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) { starts.add(i + 3); i += 3 } else i++
        }
        if (starts.isEmpty()) return if (data.isEmpty()) emptyList() else listOf(data)
        val nals = ArrayList<ByteArray>(starts.size)
        for ((k, st) in starts.withIndex()) {
            var end = if (k + 1 < starts.size) starts[k + 1] - 3 else data.size
            while (end > st && data[end - 1].toInt() == 0) end--
            if (end > st) nals.add(data.copyOfRange(st, end))
        }
        return nals
    }
}
