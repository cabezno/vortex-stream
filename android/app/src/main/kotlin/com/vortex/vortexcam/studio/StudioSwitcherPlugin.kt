package com.vortex.vortexcam.studio

import android.os.Build
import android.util.Log
import android.util.LongSparseArray
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.vortex.vortexcam.studio.encoder.HardwareProgramEncoder
import com.vortex.vortexcam.studio.encoder.SwitcherMic
import com.vortex.vortexcam.studio.gl.LayoutMode
import com.vortex.vortexcam.studio.rtmp.RtmpStreamer
import com.vortex.vortexcam.studio.webrtc.ColorGrade
import com.vortex.vortexcam.studio.webrtc.ColorMeter
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
    private val micMeterOwner = Any()
    private var syncProbe: SyncProbe? = null
    private var channel: MethodChannel? = null
    // Intro video (ClipPlayer, 2026-10-20).
    private var clip: com.vortex.vortexcam.studio.clip.ClipPlayer? = null
    // Colour matching (ColorMatch, 2026-10-19): a meter on every camera, a grade per camera applied to its sink.
    private val colorMeters = HashMap<String, Pair<VideoTrack, ColorMeter>>()   // peerId → (track, meter)
    private val gradeByTrack = HashMap<String, ColorGrade>()                     // track id → grade

    // -- Switcher speaker ------------------------------------------------------------------------------------------
    private fun setSpeakerMute(mute: Boolean): Boolean = try {
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
        val hf = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler").apply { isAccessible = true }
        val handler = plugin?.let { hf.get(it) }
        val af = handler?.javaClass?.getDeclaredField("audioDeviceModule")?.apply { isAccessible = true }
        val adm = af?.get(handler) as? org.webrtc.audio.JavaAudioDeviceModule
        adm?.setSpeakerMute(mute)
        Log.i(TAG, "Switcher speaker ${if (mute) "muted" else "on"} (adm=${adm != null})")
        adm != null
    } catch (e: Exception) { Log.w(TAG, "speaker mute: ${e.message}"); false }

    // -- The switcher's own camera follows the phone's physical orientation --------------------------------------
    // WebRTC rotates a camera frame by the SCREEN's orientation: a switcher held upright to use it, with the phone's
    // camera lying sideways on a stand, put that camera in the program upright (a vertical strip with bars,
    // 2026-10-20). The accelerometer says how the phone is held; the difference is added to the frame's rotation.
    private var localTextureId: Int? = null
    private var localFront = false
    @Volatile private var physicalRotation = -1                          // 0/90/180/270 like Display.getRotation, -1 unknown
    private val orientation = object : android.view.OrientationEventListener(appContext) {
        override fun onOrientationChanged(o: Int) {
            if (o == ORIENTATION_UNKNOWN) return
            val q = ((o + 45) / 90 % 4) * 90
            val p = (360 - q) % 360
            if (p != physicalRotation) {
                physicalRotation = p
                android.os.Handler(android.os.Looper.getMainLooper()).post { updateLocalOrientation() }
            }
        }
    }

    private var lastOrientationLog = ""

    private fun displayRotation(): Int = try {
        @Suppress("DEPRECATION")
        val d = (appContext.getSystemService(android.content.Context.WINDOW_SERVICE) as android.view.WindowManager).defaultDisplay
        d.rotation * 90
    } catch (_: Exception) { 0 }

    private fun updateLocalOrientation() {
        val tex = localTextureId
        if (tex == null || tex < 0) { for (sk in sinks.values) sk.extraRotation = 0; orientation.disable(); return }
        if (orientation.canDetectOrientation()) orientation.enable()
        val p = physicalRotation
        val d = displayRotation()
        // Camera2Session: frame rotation = sensor + (front ? d : 360 - d). We want it with p instead of d.
        val corr = if (p < 0) 0 else ((if (localFront) p - d else d - p) % 360 + 360) % 360
        val track = getVideoTrackForTextureId(tex)
        for ((t, sk) in sinks) sk.extraRotation = if (t == track) corr else 0
        val state = "physical $p, screen $d, front $localFront -> +$corr"
        if (state != lastOrientationLog) { lastOrientationLog = state; Log.i(TAG, "Local camera orientation: $state") }
    }

    private fun applyGrades() {
        for ((t, sk) in sinks) sk.grade = try { gradeByTrack[t.id()] } catch (_: Exception) { null }   // a disposed track throws
    }

    private fun register() {
        RecordingsStore.registerWith(engine, appContext)   // its own channel: recordings in the gallery
        CaptureTuner.registerWith(engine)                  // its own channel: best image processing of the cameras
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // Intro video: prepare (black + silence in the program) → play → it ends or is skipped (fade to the
                // cameras); «clipEnded» goes back to Dart when the fade starts.
                "clipPrepare" -> {
                    clip?.release(); clip = null
                    val path = call.argument<String>("path")
                    if (path == null) { result.error("CLIP", "sin archivo", null); return@setMethodCallHandler }
                    try {
                        lateinit var c: com.vortex.vortexcam.studio.clip.ClipPlayer
                        c = com.vortex.vortexcam.studio.clip.ClipPlayer(path, call.argument<Boolean>("fill") ?: false,
                            engine.renderer) {
                            if (clip === c) clip = null
                            channel?.invokeMethod("clipEnded", null)
                        }
                        clip = c
                        c.prepare()
                        result.success(mapOf("textureId" to c.textureId, "width" to c.width, "height" to c.height,
                            "durationMs" to c.durationMs))
                    } catch (e: Exception) {
                        Log.w(TAG, "Clip: ${e.message}", e)
                        clip?.release(); clip = null
                        result.error("CLIP", e.message ?: e.toString(), null)
                    }
                }
                // The switcher's speaker: off by default. It played the on-air camera, and every camera's microphone
                // picked it up again - an echo loop between the phones (2026-10-20). Muting the playout (not the
                // tracks) keeps the program audio: its sinks are fed when WebRTC pulls the audio either way.
                "setMonitorAudio" -> { result.success(setSpeakerMute(!(call.argument<Boolean>("on") ?: false))) }
                // The switcher's own camera (its renderer) and which way it faces: its picture in the program follows
                // how the phone is physically held, not the screen's orientation.
                "setLocalCamera" -> {
                    localTextureId = call.argument<Int>("textureId")
                    localFront = call.argument<Boolean>("front") ?: false
                    updateLocalOrientation()
                    result.success(true)
                }
                "clipPlay" -> { clip?.play(); result.success(clip != null) }
                "clipSkip" -> { clip?.end(); result.success(true) }
                "clipStop" -> { clip?.release(); clip = null; result.success(true) }
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
                // Sync clapperboard (SyncProbe): this screen flashes and beeps, every camera is timed. Dart drives it:
                // start → one mark per flash → finish (the results).
                "syncProbeStart" -> {
                    syncProbe?.finish()
                    val a = (call.argument<Map<String, String>>("audio") ?: emptyMap())
                        .mapNotNull { (peer, id) -> audioTrackById(id)?.let { peer to it } }.toMap()
                    val v = (call.argument<Map<String, Int>>("video") ?: emptyMap())
                        .mapNotNull { (peer, tex) -> getVideoTrackForTextureId(tex)?.let { peer to it } }.toMap()
                    syncProbe = SyncProbe().also { it.start(a, v, call.argument<String>("localPeer")) }
                    result.success(a.size + v.size)
                }
                // {cams: {peerId: textureId}}: the cameras whose colour is measured (meters on the others removed).
                "setColorMeters" -> {
                    val cams = call.argument<Map<String, Int>>("cams") ?: emptyMap()
                    for (peer in colorMeters.keys.toList()) {
                        val tex = cams[peer]
                        val track = tex?.let { getVideoTrackForTextureId(it) }
                        val same = try { track != null && track.id() == colorMeters[peer]!!.first.id() } catch (_: Exception) { false }
                        if (!same) {
                            val (t, m) = colorMeters.remove(peer)!!
                            try { t.removeSink(m) } catch (_: Exception) {}
                        }
                    }
                    for ((peer, tex) in cams) if (peer !in colorMeters) {
                        val t = getVideoTrackForTextureId(tex) ?: continue
                        val m = ColorMeter()
                        try { t.addSink(m); colorMeters[peer] = t to m } catch (e: Exception) { Log.w(TAG, "meter: ${e.message}") }
                    }
                    result.success(colorMeters.size)
                }
                // peerId → [Y, U, V] mean (0–255) of the cameras measured so far.
                "getColorStats" -> result.success(colorMeters.mapNotNull { (peer, tm) ->
                    val m = tm.second
                    if (m.y < 0) null else peer to listOf(m.y.toDouble(), m.u.toDouble(), m.v.toDouble())
                }.toMap())
                // {grades: {peerId: [r, g, b, sat]}}: colour correction of each camera in the program.
                "setColorGrades" -> {
                    val g = call.argument<Map<String, List<Double>>>("grades") ?: emptyMap()
                    gradeByTrack.clear()
                    for ((peer, v) in g) {
                        val t = colorMeters[peer]?.first ?: continue
                        if (v.size >= 4) gradeByTrack[try { t.id() } catch (_: Exception) { continue }] = ColorGrade(v[0].toFloat(), v[1].toFloat(), v[2].toFloat(), v[3].toFloat())
                    }
                    applyGrades()
                    result.success(true)
                }
                "syncProbeMark" -> { syncProbe?.mark(); result.success(true) }
                "syncProbeFinish" -> {
                    val r = syncProbe?.finish() ?: emptyMap()
                    syncProbe = null
                    result.success(r)
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
                // Level meter of the switcher's own camera: keeps the mic open while that camera is on.
                "setMicMeter" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    result.success(if (on) SwitcherMic.acquire(micMeterOwner) else { SwitcherMic.release(micMeterOwner); false })
                }
                "getMicLevel" -> result.success(SwitcherMic.levelDbfs.toDouble())
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

    /**
     * A remote audio track by its flutter_webrtc id, read ONLY from each connection's registry of remote tracks
     * (PeerConnectionObserver.getRemoteTrack, a map). Not getTrackForId: when the id is not in a connection's map it
     * walks that connection's transceivers (PeerConnection.getTransceivers), which disposes the list handed out before.
     * A camera joining runs the same call on the signaling thread (onAddTrack) while this ran on the main thread —
     * the camera's switch of sources fires right then — and one disposed what the other was disposing:
     * «RtpTransceiver has been disposed» inside a JNI callback → SIGABRT (jvm.cc:81) of the whole switcher
     * (2026-10-20, Mi A3 and Redmi Note 14 Pro as switchers, when the second camera joined).
     */
    private fun audioTrackById(id: String): org.webrtc.AudioTrack? = try {
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin
        val hf = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler").apply { isAccessible = true }
        val handler = plugin?.let { hf.get(it) }
        val of = handler?.javaClass?.getDeclaredField("mPeerConnectionObservers")?.apply { isAccessible = true }
        val observers = (of?.get(handler) as? Map<*, *>)?.values?.toList() ?: emptyList()
        var found: org.webrtc.AudioTrack? = null
        for (pco in observers) {
            if (pco == null) continue
            val m = pco.javaClass.getDeclaredMethod("getRemoteTrack", String::class.java).apply { isAccessible = true }
            found = m.invoke(pco, id) as? org.webrtc.AudioTrack
            if (found != null) break
        }
        if (found == null) Log.w(TAG, "Audio track $id not (yet) registered")
        found
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
        updateLocalOrientation()
        p?.let { sinks[it]?.delayMs = primaryDelayMs }
        sec?.let { sinks[it]?.delayMs = secondaryDelayMs }
        pvw?.let { if (it != p && it != sec) sinks[it]?.delayMs = previewDelayMs }
        if (p != primaryTrack) Log.i(TAG, "Program primary: ${p?.id()} (delay $primaryDelayMs ms)")
        primaryTrack = p; secondaryTrack = sec
        primarySink = p?.let { sinks[it] }
        secondarySink = sec?.let { sinks[it] }
        programEncoder?.primarySink = primarySink
        programEncoder?.secondarySink = secondarySink
        applyGrades()
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
        orientation.disable()
        setSpeakerMute(false)
        clip?.release(); clip = null
        syncProbe?.finish(); syncProbe = null
        for ((_, tm) in colorMeters) { try { tm.first.removeSink(tm.second) } catch (_: Exception) {} }
        colorMeters.clear(); gradeByTrack.clear()
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
