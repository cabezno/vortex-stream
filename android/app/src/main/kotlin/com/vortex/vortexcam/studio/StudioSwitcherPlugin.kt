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
class StudioSwitcherPlugin private constructor(private val engine: FlutterEngine, private val appContext: android.content.Context) {
    companion object {
        private const val TAG = "StudioSwitcher"
        @JvmStatic fun registerWith(engine: FlutterEngine, appContext: android.content.Context): StudioSwitcherPlugin =
            StudioSwitcherPlugin(engine, appContext).also { it.register() }
        private const val CHANNEL = "com.samba.studio/program_encoder"
    }

    private var programEncoder: HardwareProgramEncoder? = null
    // The switcher's own Wi-Fi network for its cameras (LocalHotspot.kt).
    private val hotspot by lazy { LocalHotspot(appContext) }
    private var rtmpStreamer: RtmpStreamer? = null

    // One delayed sink per camera the program may need: on air, preview, second camera of a split (2026-10-06).
    // A cut from preview reuses that camera's sink, already filled → the aligned delay holds with no jump.
    private val sinks = HashMap<VideoTrack, WebRtcSourceSink>()
    private var primarySink: WebRtcSourceSink? = null
    private var secondarySink: WebRtcSourceSink? = null
    private var primaryTrack: VideoTrack? = null
    private var primaryAudioTrack: org.webrtc.AudioTrack? = null
    private var primaryAudioTrackId: String? = null
    private var primaryAudioDelayMs = 0
    private var micDelayMs = 0
    private var micTracks: List<Pair<org.webrtc.AudioTrack, Int>> = emptyList()
    private var secondaryTrack: VideoTrack? = null

    private fun register() {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startEncoder" -> {
                    val width = call.argument<Int>("width") ?: 1920
                    val height = call.argument<Int>("height") ?: 1080
                    val bitrate = call.argument<Int>("bitrate") ?: 4500000
                    val fps = call.argument<Int>("fps") ?: 30
                    val outputPath = call.argument<String>("outputPath")
                    // Program audio: the on-air camera's (audio follows video, default) and/or this phone's mic.
                    val audioCamera = call.argument<Boolean>("audioCamera") ?: true
                    val audioMic = call.argument<Boolean>("audioMic") ?: false

                    try {
                        stopHardwareEncoder()
                        val encoder = HardwareProgramEncoder(
                            requestedWidth = width,
                            requestedHeight = height,
                            bitrate = bitrate,
                            fps = fps,
                            outputPath = outputPath,
                            audioMic = audioMic,
                            audioCamera = audioCamera
                        )
                        encoder.setCameraAudioTrack(primaryAudioTrack, primaryAudioDelayMs)
                        encoder.setMicDelay(micDelayMs)
                        encoder.setMicTracks(micTracks)
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
                    val previewId = call.argument<Int>("previewTextureId")
                    // Alignment of sources: how much to hold each one in the PROGRAM (0 = live).
                    val pd = call.argument<Int>("primaryDelayMs") ?: 0
                    setCameraSources(primaryId, secondaryId, previewId, pd,
                        call.argument<Int>("secondaryDelayMs") ?: 0, call.argument<Int>("previewDelayMs") ?: 0)
                    micDelayMs = call.argument<Int>("micDelayMs") ?: 0
                    programEncoder?.setMicDelay(micDelayMs)
                    setPrimaryAudio(call.argument<String>("primaryAudioTrackId"), pd)
                    result.success(true)
                }
                // Beeps on the loudspeaker, heard back through every camera: each one's end-to-end latency (SyncProbe).
                "measureLatency" -> {
                    val ids = call.argument<Map<String, String>>("tracks") ?: emptyMap()
                    val tracks = ids.mapNotNull { (peer, id) -> audioTrackById(id)?.let { peer to it } }.toMap()
                    if (tracks.isEmpty()) { result.success(emptyMap<String, Int?>()); return@setMethodCallHandler }
                    SyncProbe { r -> result.success(r) }.run(tracks)
                }
                // «Solo micrófono» phones: {trackId: delayMs}, always mixed into the program.
                "setMicTracks" -> {
                    val m = call.argument<Map<String, Int>>("tracks") ?: emptyMap()
                    micTracks = m.mapNotNull { (id, d) -> audioTrackById(id)?.let { it to d } }
                    programEncoder?.setMicTracks(micTracks)
                    result.success(true)
                }
                "setAudioSources" -> {
                    programEncoder?.setAudioSources(call.argument<Boolean>("mic") ?: false,
                                                    call.argument<Boolean>("camera") ?: true)
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
                        "isEncoding" to (encoder != null),
                        // the size actually encoded (720p if this phone's encoder can't do 1080p)
                        "width" to (encoder?.programWidth ?: 0),
                        "height" to (encoder?.programHeight ?: 0)
                    )
                    result.success(stats)
                }
                "startRtmp" -> {
                    val url = call.argument<String>("url") ?: "rtmp://127.0.0.1/live"
                    val key = call.argument<String>("streamKey") ?: ""
                    // Network I/O off the main thread: connect() on it threw NetworkOnMainThreadException and the
                    // switcher never went live (2026-10-04). Reply back on the main thread (Flutter requires it).
                    val main = android.os.Handler(android.os.Looper.getMainLooper())
                    Thread({
                        try {
                            rtmpStreamer?.disconnect()
                            val streamer = RtmpStreamer()
                            programEncoder?.let { enc ->
                                streamer.setMetadata(enc.programWidth, enc.programHeight, enc.programFps, enc.programKbps,
                                                     enc.audioKbps, enc.audioSampleRate, enc.audioChannels)
                            }
                            streamer.connect(url, key)
                            main.post {
                                rtmpStreamer = streamer
                                programEncoder?.rtmpStreamer = streamer
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to start RTMP stream: ${e.message}", e)
                            main.post { result.error("RTMP_ERROR", e.message ?: e.toString(), null) }
                        }
                    }, "StudioRtmpConnect").start()
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
                        "isStreaming" to (streamer != null),
                        // false while the link is down and reconnecting by itself
                        "connected" to (streamer?.isConnected ?: false),
                        "reconnects" to (streamer?.reconnects ?: 0),
                        "lastError" to (streamer?.lastError ?: ""),
                        "hasAudio" to ((programEncoder?.audioSampleRate ?: 0) > 0),
                        "audioCamera" to (programEncoder?.audioCameraOn ?: false),
                        "audioMic" to (programEncoder?.audioMicOn ?: false),
                        "cameraAudioTrack" to (primaryAudioTrack != null)
                    )
                    result.success(stats)
                }
                // Own network: start returns {ok, ssid, password, band, ip} (or {ok:false, error}); info re-reads it.
                "startHotspot" -> hotspot.start { result.success(it) }
                "hotspotInfo" -> result.success(if (hotspot.isOn) hotspot.info() else mapOf("ok" to false))
                "stopHotspot" -> { hotspot.stop(); result.success(true) }
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

    /** The on-air camera's remote audio track, looked up by id in flutter_webrtc (MethodCallHandlerImpl.getTrackForId). */
    private fun setPrimaryAudio(trackId: String?, delayMs: Int = 0) {
        if (delayMs != primaryAudioDelayMs) {
            primaryAudioDelayMs = delayMs
            programEncoder?.setCameraAudioDelay(delayMs)
        }
        if (trackId == primaryAudioTrackId && (trackId == null || primaryAudioTrack != null)) return
        primaryAudioTrackId = trackId
        primaryAudioTrack = trackId?.let { audioTrackById(it) }
        Log.i(TAG, "On-air audio track: ${primaryAudioTrack?.id() ?: "none"} (asked $trackId)")
        programEncoder?.setCameraAudioTrack(primaryAudioTrack, primaryAudioDelayMs)
    }

    /** A remote audio track by its flutter_webrtc id (MethodCallHandlerImpl.getTrackForId). */
    private fun audioTrackById(id: String): org.webrtc.AudioTrack? = try {
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
        val hf = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler").apply { isAccessible = true }
        val handler = plugin?.let { hf.get(it) }
        handler?.javaClass?.getMethod("getTrackForId", String::class.java, String::class.java)
            ?.invoke(handler, id, null) as? org.webrtc.AudioTrack
    } catch (e: Exception) { Log.w(TAG, "Audio track $id not found: ${e.message}"); null }

    private fun setCameraSources(primaryTextureId: Int?, secondaryTextureId: Int?, previewTextureId: Int?,
                                 primaryDelayMs: Int, secondaryDelayMs: Int, previewDelayMs: Int) {
        fun track(id: Int?) = if (id != null && id >= 0) getVideoTrackForTextureId(id) else null
        val p = track(primaryTextureId); val sec = track(secondaryTextureId); val pvw = track(previewTextureId)
        val wanted = listOfNotNull(p, sec, pvw).toSet()
        // Sinks of cameras no longer needed: detach and free their frames.
        for (t in sinks.keys.toList()) if (t !in wanted) {
            val old = sinks.remove(t)
            try { t.removeSink(old) } catch (_: Exception) {}
            old?.release()
        }
        for (t in wanted) if (t !in sinks) {
            val sk = WebRtcSourceSink()
            try { t.addSink(sk); sinks[t] = sk } catch (e: Exception) { Log.w(TAG, "addSink: ${e.message}") }
        }
        p?.let { sinks[it]?.delayMs = primaryDelayMs }
        sec?.let { sinks[it]?.delayMs = secondaryDelayMs }
        pvw?.let { if (it != p && it != sec) sinks[it]?.delayMs = previewDelayMs }
        if (p != primaryTrack) Log.i(TAG, "Program primary: ${p?.id()} (delay $primaryDelayMs ms)")
        primaryTrack = p; secondaryTrack = sec
        primarySink = p?.let { sinks[it] }
        secondarySink = sec?.let { sinks[it] }
        programEncoder?.primarySink = primarySink
        programEncoder?.secondarySink = secondarySink
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
        for ((t, sk) in sinks) { try { t.removeSink(sk) } catch (_: Exception) {}; sk.release() }
        sinks.clear()
        primarySink = null
        secondarySink = null
        stopHardwareEncoder()
        rtmpStreamer?.disconnect()
        rtmpStreamer = null
        hotspot.stop()
    }
}
