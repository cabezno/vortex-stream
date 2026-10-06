package com.vortex.vortexcam.studio.encoder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Bundle
import android.util.Log
import android.view.Surface
import com.vortex.vortexcam.studio.gl.LayoutMode
import com.vortex.vortexcam.studio.gl.ProgramCompositor
import com.vortex.vortexcam.studio.rtmp.RtmpStreamer
import com.vortex.vortexcam.studio.webrtc.WebRtcSourceSink
import org.webrtc.EglBase
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Concrete hardware pipeline:
 * MediaCodec (H.264, CBR) -> createInputSurface() -> Shared WebRTC EglBase -> ProgramCompositor (VideoFrameDrawer)
 * -> MediaMuxer (.mp4) & RtmpStreamer (FLV), plus the program audio as AAC (ProgramAudioEncoder: the on-air camera's
 * audio and/or the switcher's mic) on the same clock.
 */
class HardwareProgramEncoder(
    requestedWidth: Int = 1920,
    requestedHeight: Int = 1080,
    private var bitrate: Int = 4500000,
    private val fps: Int = 30,
    private val outputPath: String? = null,
    private val audioMic: Boolean = false,
    private val audioCamera: Boolean = true,
) {
    companion object {
        private const val TAG = "HardwareProgramEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val TIMEOUT_USEC = 10000L

        /** The requested size if this phone's H.264 encoder can do it at `fps`, else the largest 16:9 step it can. */
        fun supportedSize(w: Int, h: Int, fps: Int): Pair<Int, Int> {
            val caps = try {
                android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos
                    .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MIME_TYPE, true) } }
                    .mapNotNull { try { it.getCapabilitiesForType(MIME_TYPE).videoCapabilities } catch (_: Exception) { null } }
            } catch (_: Exception) { emptyList() }
            if (caps.isEmpty()) return w to h
            for ((cw, ch) in listOf(w to h, 1920 to 1080, 1280 to 720, 960 to 540)) {
                if (cw > w) continue
                if (caps.any { c -> try { c.areSizeAndRateSupported(cw, ch, fps.toDouble()) } catch (_: Exception) { false } })
                    return cw to ch
            }
            return 1280 to 720
        }
    }

    private var width: Int
    private var height: Int
    init {
        val (w, h) = supportedSize(requestedWidth, requestedHeight, fps)
        width = w; height = h
        if (w != requestedWidth) Log.i(TAG, "Encoder can't do ${requestedWidth}x$requestedHeight@$fps → ${w}x$h")
    }

    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null

    // Recording: the muxer starts once every track it will carry is known (video, and audio if the mic works).
    private val muxLock = Any()
    private var mediaMuxer: MediaMuxer? = null
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1
    private var isMuxerStarted = false

    private var eglBase: EglBase? = null
    private var compositor: ProgramCompositor? = null
    private var clockStartNano = 0L

    private var audio: ProgramAudioEncoder? = null
    @Volatile private var cameraAudioTrack: org.webrtc.AudioTrack? = null
    @Volatile private var audioReady = false          // the AAC format is known (or there is no audio)
    @Volatile private var lastAsc: ByteArray? = null
    val audioSampleRate: Int get() = if (audio != null) ProgramAudioEncoder.SAMPLE_RATE else 0
    val audioChannels: Int get() = if (audio != null) ProgramAudioEncoder.CHANNELS else 0
    val audioKbps: Int get() = if (audio != null) ProgramAudioEncoder.BITRATE / 1000 else 0
    /** What the program's audio carries right now (for the UI). */
    val audioCameraOn: Boolean get() = audio?.useCamera == true
    val audioMicOn: Boolean get() = audio?.micActive == true

    /** The on-air camera's WebRTC audio track (audio follows video), held [delayMs] like its picture. */
    fun setCameraAudioTrack(track: org.webrtc.AudioTrack?, delayMs: Int = cameraAudioDelayMs) {
        cameraAudioTrack = track
        cameraAudioDelayMs = delayMs
        audio?.setCameraTrack(track, delayMs)
    }
    private var cameraAudioDelayMs = 0
    private var micDelayMs = 0
    fun setCameraAudioDelay(ms: Int) { cameraAudioDelayMs = ms; audio?.setCameraDelay(ms) }
    /** «Solo micrófono» phones, always in the program mix, each with its alignment delay. */
    private var micTracks: List<Pair<org.webrtc.AudioTrack, Int>> = emptyList()
    fun setMicTracks(tracks: List<Pair<org.webrtc.AudioTrack, Int>>) { micTracks = tracks; audio?.setMicTracks(tracks) }

    /** The switcher's own microphone, held to line up with the cameras (they arrive later than it). */
    fun setMicDelay(ms: Int) { micDelayMs = ms; audio?.setMicDelay(ms) }

    fun setAudioSources(mic: Boolean, camera: Boolean) { audio?.setSources(mic, camera) }
    val programWidth get() = width
    val programHeight get() = height
    val programFps get() = fps
    val programKbps get() = bitrate / 1000

    var primarySink: WebRtcSourceSink? = null
    var secondarySink: WebRtcSourceSink? = null
    // SPS/PPS arrive ONCE (INFO_OUTPUT_FORMAT_CHANGED). An RTMP output attached later (the connect runs on its own
    // thread, or "EMITIR" pressed while the encoder was already running) never got the AVC sequence header: the
    // receiver could not decode (ffmpeg: "No start code is found", 2026-10-04). Keep them — and the AAC config — and
    // hand them, plus a keyframe request, to every streamer attached afterwards.
    @Volatile private var lastSps: ByteArray? = null
    @Volatile private var lastPps: ByteArray? = null
    var rtmpStreamer: RtmpStreamer? = null
        set(value) {
            field = value
            if (value == null) return
            value.onNeedKeyframe = { requestKeyframe() }
            val sps = lastSps; val pps = lastPps
            if (sps != null && pps != null) value.setSpsPps(sps, pps)
            lastAsc?.let { if (it.isNotEmpty()) value.setAudioConfig(it) }
            requestKeyframe()
        }

    private val isRunning = AtomicBoolean(false)
    private var renderThread: Thread? = null
    private var drainThread: Thread? = null

    var currentLayoutMode: LayoutMode = LayoutMode.SINGLE
    var encodedFrames: Long = 0
        private set
    var totalBytesWritten: Long = 0
        private set

    fun requestKeyframe() {
        try {
            mediaCodec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: Exception) { Log.w(TAG, "IDR request failed: ${e.message}") }
    }

    fun start() {
        if (isRunning.get()) return

        Log.i(TAG, "Starting HardwareProgramEncoder: ${width}x${height} @ ${bitrate / 1000} kbps, audio camera=$audioCamera mic=$audioMic, out=$outputPath")

        // 1–2. H.264 encoder on an input surface. The phone's video hardware is SHARED with the decoders of the cameras
        // the switcher receives: a Galaxy A10 decoding two 1080p cameras refused a 1080p encoder ("codec capacity",
        // 0xffffec77) and nothing went out (2026-10-04). Detected here, live: step down until the encoder accepts.
        var codec: MediaCodec? = null
        var surface: Surface? = null
        val ladder = listOf(width to height, 2560 to 1440, 1920 to 1080, 1280 to 720, 960 to 540, 640 to 360)
            .filter { it.first <= width }.distinct()
        for ((w, h) in ladder) {
            val format = MediaFormat.createVideoFormat(MIME_TYPE, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, if (w == width) bitrate else minOf(bitrate, w * h * 3))
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2) // platforms ask for a keyframe every 2 s
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            }
            val c = MediaCodec.createEncoderByType(MIME_TYPE)
            try {
                c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                surface = c.createInputSurface()
                c.start()
                codec = c
                if (w != width) {
                    Log.w(TAG, "Encoder refused ${width}x$height (video hardware busy decoding the cameras) → ${w}x$h")
                    width = w; height = h; bitrate = minOf(bitrate, w * h * 3)
                }
                break
            } catch (e: Exception) {
                Log.w(TAG, "H.264 encoder ${w}x$h refused: ${e.message}")
                try { c.release() } catch (_: Exception) {}
            }
        }
        if (codec == null || surface == null) throw IllegalStateException("el encoder de video de este celular no tiene capacidad libre (está decodificando las cámaras)")
        mediaCodec = codec
        inputSurface = surface

        // 3. Initialize EglBase shared with libwebrtc's root EGL context
        val rootContext = try {
            com.cloudwebrtc.webrtc.utils.EglUtils.getRootEglBaseContext()
        } catch (e: Exception) {
            Log.w(TAG, "EglUtils.getRootEglBaseContext() unavailable, using standalone context: ${e.message}")
            null
        }

        val egl = try {
            if (rootContext != null) {
                EglBase.create(rootContext, EglBase.CONFIG_RECORDABLE)
            } else {
                EglBase.create(null, EglBase.CONFIG_RECORDABLE)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to create EglBase with CONFIG_RECORDABLE, falling back to CONFIG_PLAIN: ${e.message}")
            EglBase.create(rootContext, EglBase.CONFIG_PLAIN)
        }

        egl.createSurface(surface)
        egl.makeCurrent()
        val comp = ProgramCompositor(width, height)
        // Release the context from THIS (main) thread: an EGL context can be current on one thread only, so the
        // render thread's makeCurrent() failed on every frame ("eglMakeCurrent failed: 0x3000") and nothing was
        // encoded — no recording, no RTMP (found 2026-10-04 testing the Switcher mode on a Galaxy A10).
        egl.detachCurrent()

        eglBase = egl
        compositor = comp

        // 4. Initialize MediaMuxer if output file path is specified
        if (!outputPath.isNullOrBlank()) {
            val file = File(outputPath)
            file.parentFile?.mkdirs()
            mediaMuxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }

        isRunning.set(true)
        encodedFrames = 0
        totalBytesWritten = 0
        isMuxerStarted = false
        videoTrackIndex = -1; audioTrackIndex = -1
        clockStartNano = System.nanoTime()

        // 5. Program audio (same clock as the video): the on-air camera and/or this phone's mic.
        audioReady = true
        if (audioMic || audioCamera) {
            val pa = ProgramAudioEncoder(clockStartNano, object : ProgramAudioEncoder.Listener {
                override fun onAudioFormat(format: MediaFormat, asc: ByteArray) {
                    lastAsc = asc
                    if (asc.isNotEmpty()) rtmpStreamer?.setAudioConfig(asc)
                    synchronized(muxLock) {
                        mediaMuxer?.let { if (!isMuxerStarted && audioTrackIndex < 0) audioTrackIndex = it.addTrack(format) }
                        audioReady = true
                        maybeStartMuxer()
                    }
                }
                override fun onAudioData(data: ByteBuffer, info: MediaCodec.BufferInfo) {
                    rtmpStreamer?.sendAudioData(data, info)
                    synchronized(muxLock) {
                        if (isMuxerStarted && audioTrackIndex >= 0) {
                            mediaMuxer?.writeSampleData(audioTrackIndex, data.duplicate().apply {
                                position(info.offset); limit(info.offset + info.size) }, info)
                        }
                    }
                }
            }, audioMic, audioCamera)
            audioReady = false
            if (pa.start()) {
                audio = pa; pa.setCameraTrack(cameraAudioTrack, cameraAudioDelayMs); pa.setMicDelay(micDelayMs)
                pa.setMicTracks(micTracks)
            } else audioReady = true
        }

        // 6. Start Render Loop Thread (~30fps presentation to encoder surface)
        renderThread = Thread({ runRenderLoop() }, "ProgramRenderThread").apply { start() }

        // 7. Start Drain Loop Thread (dequeueOutputBuffer -> MediaMuxer & RtmpStreamer)
        drainThread = Thread({ runDrainLoop() }, "ProgramDrainThread").apply { start() }

        Log.i(TAG, "Hardware encoder and draining pipeline successfully active with WebRTC EglBase sharing")
    }

    /** Caller holds muxLock. */
    private fun maybeStartMuxer() {
        val muxer = mediaMuxer ?: return
        if (isMuxerStarted || videoTrackIndex < 0 || !audioReady) return
        muxer.start()
        isMuxerStarted = true
        Log.i(TAG, "MediaMuxer started: video track $videoTrackIndex, audio track $audioTrackIndex")
    }

    private fun runRenderLoop() {
        val frameIntervalMs = 1000L / fps

        while (isRunning.get()) {
            val loopStart = System.currentTimeMillis()
            val nowNano = System.nanoTime() - clockStartNano

            try {
                val egl = eglBase
                val comp = compositor

                if (egl != null && comp != null) {
                    egl.makeCurrent()
                    comp.drawFrame(currentLayoutMode, primarySink, secondarySink)
                    egl.swapBuffers(nowNano)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in render loop: ${e.message}")
            }

            val elapsed = System.currentTimeMillis() - loopStart
            val sleepTime = frameIntervalMs - elapsed
            if (sleepTime > 0) {
                try {
                    Thread.sleep(sleepTime)
                } catch (ignored: InterruptedException) {
                    break
                }
            }
        }
    }

    private fun runDrainLoop() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()

        while (isRunning.get() || isDraining) {
            val outputBufferIndex = try {
                codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_USEC)
            } catch (e: Exception) {
                Log.w(TAG, "dequeueOutputBuffer exception: ${e.message}")
                break
            }

            when {
                outputBufferIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (isDraining) break
                }
                outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFormat = codec.outputFormat
                    Log.i(TAG, "Encoder output format changed: $newFormat")

                    // Extract SPS and PPS for RTMP FLV sequence header
                    try {
                        val csd0 = newFormat.getByteBuffer("csd-0")
                        val csd1 = newFormat.getByteBuffer("csd-1")
                        if (csd0 != null && csd1 != null) {
                            val spsBytes = ByteArray(csd0.remaining()).also { csd0.duplicate().get(it) }
                            val ppsBytes = ByteArray(csd1.remaining()).also { csd1.duplicate().get(it) }
                            lastSps = spsBytes; lastPps = ppsBytes
                            rtmpStreamer?.setSpsPps(spsBytes, ppsBytes)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Could not extract SPS/PPS: ${e.message}")
                    }

                    synchronized(muxLock) {
                        val muxer = mediaMuxer
                        if (muxer != null && !isMuxerStarted && videoTrackIndex < 0) {
                            videoTrackIndex = muxer.addTrack(newFormat)
                            maybeStartMuxer()
                        }
                    }
                }
                outputBufferIndex >= 0 -> {
                    val encodedData = codec.getOutputBuffer(outputBufferIndex)
                    if (encodedData != null) {
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                            // Codec config data (SPS/PPS), handled by format change
                            bufferInfo.size = 0
                        }

                        if (bufferInfo.size != 0) {
                            val isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                            encodedFrames++

                            // 1. Send to RTMP Streamer (AVCC NALU packet)
                            rtmpStreamer?.sendVideoData(encodedData, bufferInfo, isKeyFrame)

                            // 2. Write to MediaMuxer (.mp4 file)
                            synchronized(muxLock) {
                                if (isMuxerStarted) {
                                    encodedData.position(bufferInfo.offset)
                                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                    mediaMuxer?.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                    totalBytesWritten += bufferInfo.size
                                }
                            }
                        }

                        codec.releaseOutputBuffer(outputBufferIndex, false)

                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            Log.i(TAG, "End of stream reached in encoder")
                            break
                        }
                    }
                }
            }
        }
    }

    @Volatile private var isDraining = false

    fun updateBitrate(newBitrate: Int) {
        bitrate = newBitrate
        mediaCodec?.let { codec ->
            if (isRunning.get()) {
                codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate) })
                Log.d(TAG, "Updated dynamic bitrate to ${newBitrate / 1000} kbps")
            }
        }
    }

    fun stop() {
        if (!isRunning.getAndSet(false)) return

        Log.i(TAG, "Stopping HardwareProgramEncoder...")
        isDraining = true

        // 0. Audio first (its callbacks write into the muxer)
        audio?.stop(); audio = null

        // 1. Signal end of input stream on surface
        try {
            mediaCodec?.signalEndOfInputStream()
        } catch (e: Exception) {
            Log.w(TAG, "signalEndOfInputStream: ${e.message}")
        }

        // 2. Wait for threads to complete
        try {
            renderThread?.join(500)
            drainThread?.join(1000)
        } catch (ignored: InterruptedException) {}

        // 3. Stop & release MediaCodec
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping mediaCodec: ${e.message}")
        } finally {
            mediaCodec = null
            inputSurface = null
        }

        // 4. Stop & release MediaMuxer
        synchronized(muxLock) {
            try {
                if (isMuxerStarted) {
                    mediaMuxer?.stop()
                }
                mediaMuxer?.release()
                Log.i(TAG, "MediaMuxer closed: $encodedFrames frames, $totalBytesWritten bytes written to $outputPath")
            } catch (e: Exception) {
                Log.w(TAG, "Error releasing MediaMuxer: ${e.message}")
            } finally {
                mediaMuxer = null
                isMuxerStarted = false
            }
        }

        // 5. Release Compositor and EglBase
        compositor?.release()
        compositor = null

        try {
            eglBase?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing EglBase: ${e.message}")
        }
        eglBase = null

        isDraining = false
        Log.i(TAG, "HardwareProgramEncoder completely stopped and resources freed")
    }
}
