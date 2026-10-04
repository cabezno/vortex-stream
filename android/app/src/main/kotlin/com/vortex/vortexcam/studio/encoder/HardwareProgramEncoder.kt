package com.vortex.vortexcam.studio.encoder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
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
 * MediaCodec (H.264, CBR, 720p) -> createInputSurface() -> Shared WebRTC EglBase -> ProgramCompositor (VideoFrameDrawer) -> MediaMuxer (.mp4) & RtmpStreamer (FLV).
 * Renders real camera VideoFrames from WebRTC into a valid, playable MP4 and RTMP live stream.
 */
class HardwareProgramEncoder(
    private val width: Int = 1280,
    private val height: Int = 720,
    private var bitrate: Int = 3500000,
    private val fps: Int = 30,
    private val outputPath: String? = null
) {
    companion object {
        private const val TAG = "HardwareProgramEncoder"
        private const val MIME_TYPE = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val TIMEOUT_USEC = 10000L
    }

    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var mediaMuxer: MediaMuxer? = null
    private var videoTrackIndex = -1
    private var isMuxerStarted = false

    private var eglBase: EglBase? = null
    private var compositor: ProgramCompositor? = null

    var primarySink: WebRtcSourceSink? = null
    var secondarySink: WebRtcSourceSink? = null
    // SPS/PPS arrive ONCE (INFO_OUTPUT_FORMAT_CHANGED). An RTMP output attached later (the connect now runs on its own
    // thread, or "EMITIR" pressed while the encoder was already running) never got the AVC sequence header: the
    // receiver could not decode (ffmpeg: "No start code is found", 2026-10-04). Keep them and hand them, plus a
    // keyframe request, to every streamer attached afterwards.
    @Volatile private var lastSps: ByteArray? = null
    @Volatile private var lastPps: ByteArray? = null
    var rtmpStreamer: RtmpStreamer? = null
        set(value) {
            field = value
            val sps = lastSps; val pps = lastPps
            if (value != null && sps != null && pps != null) {
                value.setSpsPps(sps, pps)
                try {
                    mediaCodec?.setParameters(android.os.Bundle().apply {
                        putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                    })
                } catch (e: Exception) { Log.w(TAG, "IDR request failed: ${e.message}") }
            }
        }

    private val isRunning = AtomicBoolean(false)
    private var renderThread: Thread? = null
    private var drainThread: Thread? = null

    var currentLayoutMode: LayoutMode = LayoutMode.SINGLE
    var encodedFrames: Long = 0
        private set
    var totalBytesWritten: Long = 0
        private set

    fun start() {
        if (isRunning.get()) return

        Log.i(TAG, "Starting HardwareProgramEncoder: ${width}x${height} @ ${bitrate / 1000} kbps, out=$outputPath")

        // 1. Prepare MediaFormat for H.264
        val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1 second keyframe interval
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }

        // 2. Instantiate & Configure MediaCodec with Input Surface
        val codec = MediaCodec.createEncoderByType(MIME_TYPE)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()
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

        // 5. Start Render Loop Thread (~30fps presentation to encoder surface)
        renderThread = Thread({ runRenderLoop() }, "ProgramRenderThread").apply { start() }

        // 6. Start Drain Loop Thread (dequeueOutputBuffer -> MediaMuxer & RtmpStreamer)
        drainThread = Thread({ runDrainLoop() }, "ProgramDrainThread").apply { start() }

        Log.i(TAG, "Hardware encoder and draining pipeline successfully active with WebRTC EglBase sharing")
    }

    private fun runRenderLoop() {
        val frameIntervalMs = 1000L / fps
        val startNano = System.nanoTime()

        while (isRunning.get()) {
            val loopStart = System.currentTimeMillis()
            val nowNano = System.nanoTime() - startNano

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
                    if (isMuxerStarted) {
                        Log.w(TAG, "Format changed twice in muxer")
                    } else {
                        val newFormat = codec.outputFormat
                        Log.i(TAG, "Encoder output format changed: $newFormat")

                        // Extract SPS and PPS for RTMP FLV sequence header
                        try {
                            val csd0 = newFormat.getByteBuffer("csd-0")
                            val csd1 = newFormat.getByteBuffer("csd-1")
                            if (csd0 != null && csd1 != null) {
                                val spsBytes = ByteArray(csd0.remaining()).also { csd0.get(it); csd0.rewind() }
                                val ppsBytes = ByteArray(csd1.remaining()).also { csd1.get(it); csd1.rewind() }
                                lastSps = spsBytes; lastPps = ppsBytes
                                rtmpStreamer?.setSpsPps(spsBytes, ppsBytes)
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Could not extract SPS/PPS: ${e.message}")
                        }

                        mediaMuxer?.let { muxer ->
                            videoTrackIndex = muxer.addTrack(newFormat)
                            muxer.start()
                            isMuxerStarted = true
                            Log.i(TAG, "MediaMuxer started with video track index: $videoTrackIndex")
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

                            // 1. Send to RTMP Streamer (AVCC NALU packet)
                            rtmpStreamer?.sendVideoData(encodedData.duplicate(), bufferInfo, isKeyFrame)

                            // 2. Write to MediaMuxer (.mp4 file)
                            if (isMuxerStarted && mediaMuxer != null) {
                                encodedData.position(bufferInfo.offset)
                                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                                mediaMuxer?.writeSampleData(videoTrackIndex, encodedData, bufferInfo)
                                totalBytesWritten += bufferInfo.size
                                encodedFrames++
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

    private var isDraining = false

    fun updateBitrate(newBitrate: Int) {
        bitrate = newBitrate
        mediaCodec?.let { codec ->
            if (isRunning.get() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                val params = Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, newBitrate)
                }
                codec.setParameters(params)
                Log.d(TAG, "Updated dynamic bitrate to ${newBitrate / 1000} kbps")
            }
        }
    }

    fun stop() {
        if (!isRunning.getAndSet(false)) return

        Log.i(TAG, "Stopping HardwareProgramEncoder...")
        isDraining = true

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
