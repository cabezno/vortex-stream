package com.vortex.vortexcam.studio

import android.os.Build
import android.util.Log
import android.util.LongSparseArray
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.vortex.vortexcam.studio.encoder.HardwareProgramEncoder
import com.vortex.vortexcam.studio.gl.LayoutMode
import com.vortex.vortexcam.studio.rtmp.RtmpStreamer
import com.vortex.vortexcam.studio.webrtc.WebRtcSourceSink
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.VideoTrack

// Native side of the Switcher mode (ex SAMBA Móvil Studio MainActivity): program compositor + hardware encoder +
// RTMP out, fed by the WebRTC tracks the switcher receives. Registered by Samba Air's MainActivity; the screen is kept
// on by the Studio mode itself (keepalive channel) instead of a global FLAG_KEEP_SCREEN_ON.
class StudioSwitcherPlugin private constructor(private val engine: FlutterEngine) {
    companion object {
        private const val TAG = "StudioSwitcher"
        @JvmStatic fun registerWith(engine: FlutterEngine): StudioSwitcherPlugin =
            StudioSwitcherPlugin(engine).also { it.register() }
        private const val CHANNEL = "com.samba.studio/program_encoder"
    }

    private var programEncoder: HardwareProgramEncoder? = null
    private var rtmpStreamer: RtmpStreamer? = null

    private var primarySink: WebRtcSourceSink? = null
    private var secondarySink: WebRtcSourceSink? = null
    private var primaryTrack: VideoTrack? = null
    private var secondaryTrack: VideoTrack? = null

    private fun register() {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startEncoder" -> {
                    val width = call.argument<Int>("width") ?: 1280
                    val height = call.argument<Int>("height") ?: 720
                    val bitrate = call.argument<Int>("bitrate") ?: 3500000
                    val fps = call.argument<Int>("fps") ?: 30
                    val outputPath = call.argument<String>("outputPath")

                    try {
                        stopHardwareEncoder()
                        val encoder = HardwareProgramEncoder(
                            width = width,
                            height = height,
                            bitrate = bitrate,
                            fps = fps,
                            outputPath = outputPath
                        )
                        encoder.primarySink = primarySink
                        encoder.secondarySink = secondarySink
                        encoder.rtmpStreamer = rtmpStreamer
                        encoder.start()
                        programEncoder = encoder
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start HardwareProgramEncoder: ${e.message}", e)
                        result.error("ENCODER_ERROR", e.message, null)
                    }
                }
                "setCameraSources" -> {
                    val primaryId = call.argument<Int>("primaryTextureId")
                    val secondaryId = call.argument<Int>("secondaryTextureId")
                    setCameraSources(primaryId, secondaryId)
                    result.success(true)
                }
                "setLayoutMode" -> {
                    val modeStr = call.argument<String>("mode") ?: "single"
                    val layoutMode = when (modeStr.lowercase()) {
                        "splitscreen", "split_screen" -> LayoutMode.SPLIT_SCREEN
                        "pip" -> LayoutMode.PIP
                        else -> LayoutMode.SINGLE
                    }
                    programEncoder?.currentLayoutMode = layoutMode
                    result.success(true)
                }
                "setBitrate" -> {
                    val bitrate = call.argument<Int>("bitrate") ?: 3500000
                    try {
                        programEncoder?.updateBitrate(bitrate)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BITRATE_ERROR", e.message, null)
                    }
                }
                "getStats" -> {
                    val encoder = programEncoder
                    val stats = mapOf(
                        "encodedFrames" to (encoder?.encodedFrames ?: 0L),
                        "totalBytesWritten" to (encoder?.totalBytesWritten ?: 0L),
                        "isEncoding" to (encoder != null)
                    )
                    result.success(stats)
                }
                "startRtmp" -> {
                    val url = call.argument<String>("url") ?: "rtmp://127.0.0.1/live"
                    val key = call.argument<String>("streamKey") ?: ""
                    try {
                        rtmpStreamer?.disconnect()
                        val streamer = RtmpStreamer()
                        streamer.connect(url, key)
                        rtmpStreamer = streamer
                        programEncoder?.rtmpStreamer = streamer
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start RTMP stream: ${e.message}", e)
                        result.error("RTMP_ERROR", e.message, null)
                    }
                }
                "stopRtmp" -> {
                    try {
                        rtmpStreamer?.disconnect()
                        programEncoder?.rtmpStreamer = null
                        rtmpStreamer = null
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("RTMP_STOP_ERROR", e.message, null)
                    }
                }
                "getRtmpStats" -> {
                    val streamer = rtmpStreamer
                    val stats = mapOf(
                        "bytesSent" to (streamer?.bytesSent ?: 0L),
                        "droppedPackets" to (streamer?.droppedPackets ?: 0),
                        "isStreaming" to (streamer != null)
                    )
                    result.success(stats)
                }
                "stopEncoder" -> {
                    try {
                        stopHardwareEncoder()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getVideoTrackForTextureId(textureId: Int): VideoTrack? {
        try {
            val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin ?: return null
            val handlerField = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler").apply { isAccessible = true }
            val handler = handlerField.get(plugin) ?: return null
            val rendersField = handler.javaClass.getDeclaredField("renders").apply { isAccessible = true }
            val renders = rendersField.get(handler) as? LongSparseArray<*> ?: return null
            val renderer = renders.get(textureId.toLong()) ?: return null
            val trackField = renderer.javaClass.getDeclaredField("videoTrack").apply { isAccessible = true }
            return trackField.get(renderer) as? VideoTrack
        } catch (e: Exception) {
            Log.w(TAG, "Could not extract VideoTrack for textureId $textureId: ${e.message}")
            return null
        }
    }

    private fun setCameraSources(primaryTextureId: Int?, secondaryTextureId: Int?) {
        // 1. Primary Source
        if (primaryTextureId != null && primaryTextureId >= 0) {
            val newTrack = getVideoTrackForTextureId(primaryTextureId)
            if (newTrack != primaryTrack) {
                primaryTrack?.removeSink(primarySink)
                primaryTrack = newTrack
                if (primarySink == null) {
                    primarySink = WebRtcSourceSink()
                }
                primaryTrack?.addSink(primarySink)
                programEncoder?.primarySink = primarySink
                Log.i(TAG, "Attached primary VideoSink to VideoTrack: ${newTrack?.id()}")
            }
        } else {
            primaryTrack?.removeSink(primarySink)
            primaryTrack = null
            programEncoder?.primarySink = null
        }

        // 2. Secondary Source (for Split-Screen / PiP)
        if (secondaryTextureId != null && secondaryTextureId >= 0) {
            val newTrack = getVideoTrackForTextureId(secondaryTextureId)
            if (newTrack != secondaryTrack) {
                secondaryTrack?.removeSink(secondarySink)
                secondaryTrack = newTrack
                if (secondarySink == null) {
                    secondarySink = WebRtcSourceSink()
                }
                secondaryTrack?.addSink(secondarySink)
                programEncoder?.secondarySink = secondarySink
                Log.i(TAG, "Attached secondary VideoSink to VideoTrack: ${newTrack?.id()}")
            }
        } else {
            secondaryTrack?.removeSink(secondarySink)
            secondaryTrack = null
            programEncoder?.secondarySink = null
        }
    }

    private fun stopHardwareEncoder() {
        try {
            programEncoder?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping program encoder: ${e.message}")
        } finally {
            programEncoder = null
        }
    }

    fun dispose() {
        primaryTrack?.removeSink(primarySink)
        secondaryTrack?.removeSink(secondarySink)
        primarySink?.release()
        secondarySink?.release()
        primarySink = null
        secondarySink = null
        stopHardwareEncoder()
        rtmpStreamer?.disconnect()
        rtmpStreamer = null
    }
}
