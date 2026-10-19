package com.vortex.vortexcam.studio

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.Camera2Capturer
import org.webrtc.CameraEnumerationAndroid

/**
 * Asks the camera's own image processor (ISP) for its best processing on a WebRTC camera (2026-10-19, the user's
 * "usar los algoritmos de mejora de imagen"). WebRTC opens the camera with the RECORD template and only sets frame
 * rate, exposure, focus and stabilization: noise reduction, sharpening, tone mapping and lens shading are left at the
 * template's default, usually FAST (the cheap variant). This rebuilds the repeating request of the running camera
 * session with the HIGH_QUALITY variants the camera lists — the same reflection flutter_webrtc uses for zoom/torch.
 *
 * HIGH_QUALITY "may slow the capture rate" (Camera2 docs): the rate is measured with FAST first (3 s), then with
 * HIGH_QUALITY (6 s); if it fell more than 10 %, the request goes back to FAST. (Measured against FAST, not against
 * the nominal 30 fps: in a dim room the camera lowers the rate on its own either way.) A camera that cannot be reached this way (Camera1, a
 * changed WebRTC) is left as it is.
 */
class CaptureTuner(private val engine: FlutterEngine) {
    companion object {
        private const val TAG = "CaptureTuner"
        private const val CHANNEL = "com.samba.studio/capture"
        private const val WINDOW_MS = 3000L

        fun registerWith(engine: FlutterEngine) {
            val t = CaptureTuner(engine)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    // {trackId, high}: tune the camera behind this local video track.
                    "tune" -> {
                        val id = call.argument<String>("trackId")
                        if (id == null) { result.success(false); return@setMethodCallHandler }
                        t.tune(id, call.argument<Boolean>("high") ?: true, attempt = 0)
                        result.success(true)
                    }
                    // What the camera ended up with: "high", "fast" (went back), "default" (not reachable) or "".
                    "status" -> result.success(t.status[call.argument<String>("trackId")] ?: "")
                    else -> result.notImplemented()
                }
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    val status = java.util.concurrent.ConcurrentHashMap<String, String>()

    private class Session(
        val capture: CameraCaptureSession, val device: CameraDevice, val format: CameraEnumerationAndroid.CaptureFormat,
        val fpsUnit: Int, val surface: Surface, val handler: Handler, val chars: CameraCharacteristics,
    )

    /** The camera session behind [trackId], or null while it is still opening / not a Camera2 capturer. */
    private fun session(trackId: String): Session? {
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin ?: return null
        val handler = field(plugin, "methodCallHandler") ?: return null
        val gum = field(handler, "getUserMediaImpl") ?: return null
        val info = gum.javaClass.getMethod("getCapturerInfo", String::class.java).invoke(gum, trackId) ?: return null
        val capturer = info.javaClass.getField("capturer").get(info) as? Camera2Capturer ?: return null
        val s = field(capturer, "currentSession") ?: return null
        val manager = field(capturer, "cameraManager") as? CameraManager ?: return null
        val device = field(s, "cameraDevice") as? CameraDevice ?: return null
        return Session(
            field(s, "captureSession") as? CameraCaptureSession ?: return null,
            device,
            field(s, "captureFormat") as? CameraEnumerationAndroid.CaptureFormat ?: return null,
            field(s, "fpsUnitFactor") as? Int ?: return null,
            field(s, "surface") as? Surface ?: return null,
            field(s, "cameraThreadHandler") as? Handler ?: return null,
            manager.getCameraCharacteristics(device.id),
        )
    }

    /** A private field by name, looked up through the superclasses. */
    private fun field(o: Any, name: String): Any? {
        var c: Class<*>? = o.javaClass
        while (c != null) {
            try { return c.getDeclaredField(name).apply { isAccessible = true }.get(o) } catch (_: NoSuchFieldException) {}
            c = c.superclass
        }
        return null
    }

    fun tune(trackId: String, high: Boolean, attempt: Int) {
        val s = try { session(trackId) } catch (e: Exception) { Log.w(TAG, "session: ${e.message}"); null }
        if (s == null) {
            // getUserMedia returns before the camera session is configured: try again for a few seconds.
            if (attempt < 15) main.postDelayed({ tune(trackId, high, attempt + 1) }, 300)
            else { status[trackId] = "default"; Log.i(TAG, "$trackId: no Camera2 session to tune") }
            return
        }
        if (!high) { s.handler.post { apply(trackId, s, false, onRate = null) }; return }
        // FAST for a window (the baseline), then HIGH_QUALITY for two; keep it only if it holds the rate.
        s.handler.post {
            apply(trackId, s, false) { base ->
                apply(trackId, s, true, windows = 2) { hq ->
                    if (hq < base * 0.9) {
                        Log.w(TAG, "$trackId: ${"%.1f".format(hq)} fps with HIGH_QUALITY vs ${"%.1f".format(base)} → FAST")
                        status[trackId] = "fast"
                        apply(trackId, s, false, onRate = null)
                    } else {
                        Log.i(TAG, "$trackId: HIGH_QUALITY holds ${"%.1f".format(hq)} fps (FAST ${"%.1f".format(base)})")
                    }
                }
            }
        }
    }

    /**
     * Runs on the camera thread. [onRate], when given: called once (camera thread) with the average capture rate over
     * [windows] windows of [WINDOW_MS], after a first second of settling.
     */
    private fun apply(trackId: String, s: Session, high: Boolean, windows: Int = 1, onRate: ((Double) -> Unit)?) {
        val minFps = s.format.framerate.min / s.fpsUnit
        val maxFps = s.format.framerate.max / s.fpsUnit
        val b = try { s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD) } catch (e: Exception) {
            Log.w(TAG, "createCaptureRequest: ${e.message}"); return
        }
        // What WebRTC's Camera2Session sets (it is rebuilt from scratch).
        b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(minFps, maxFps))
        b.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        b.set(CaptureRequest.CONTROL_AE_LOCK, false)
        val ch = s.chars
        fun has(key: CameraCharacteristics.Key<IntArray>, v: Int) = ch.get(key)?.contains(v) == true
        if (has(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
            b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)
            b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
        } else if (has(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
            b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
        }
        if (has(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO))
            b.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        // Flicker of mains-powered lights (50 Hz here): let the camera pick.
        if (has(CameraCharacteristics.CONTROL_AE_AVAILABLE_ANTIBANDING_MODES, CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO))
            b.set(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO)
        // The processing: HIGH_QUALITY where listed, else FAST.
        val applied = mutableListOf<String>()
        fun quality(name: String, avail: CameraCharacteristics.Key<IntArray>, key: CaptureRequest.Key<Int>, hq: Int, fast: Int) {
            val want = if (high && has(avail, hq)) hq else if (has(avail, fast)) fast else return
            b.set(key, want); if (want == hq) applied.add(name)
        }
        quality("ruido", CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES,
            CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY, CaptureRequest.NOISE_REDUCTION_MODE_FAST)
        quality("nitidez", CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES,
            CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_HIGH_QUALITY, CaptureRequest.EDGE_MODE_FAST)
        quality("tonos", CameraCharacteristics.TONEMAP_AVAILABLE_TONE_MAP_MODES,
            CaptureRequest.TONEMAP_MODE, CaptureRequest.TONEMAP_MODE_HIGH_QUALITY, CaptureRequest.TONEMAP_MODE_FAST)
        quality("aberración", CameraCharacteristics.COLOR_CORRECTION_AVAILABLE_ABERRATION_MODES,
            CaptureRequest.COLOR_CORRECTION_ABERRATION_MODE, CaptureRequest.COLOR_CORRECTION_ABERRATION_MODE_HIGH_QUALITY,
            CaptureRequest.COLOR_CORRECTION_ABERRATION_MODE_FAST)
        quality("sombreado", CameraCharacteristics.SHADING_AVAILABLE_MODES,
            CaptureRequest.SHADING_MODE, CaptureRequest.SHADING_MODE_HIGH_QUALITY, CaptureRequest.SHADING_MODE_FAST)
        quality("píxeles", CameraCharacteristics.HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES,
            CaptureRequest.HOT_PIXEL_MODE, CaptureRequest.HOT_PIXEL_MODE_HIGH_QUALITY, CaptureRequest.HOT_PIXEL_MODE_FAST)
        b.addTarget(s.surface)

        val callback = if (onRate == null) null else object : CameraCaptureSession.CaptureCallback() {
            val settleUntil = android.os.SystemClock.elapsedRealtime() + 1000
            var start = 0L; var count = 0; var fired = false
            override fun onCaptureCompleted(session: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
                if (fired) return
                val now = android.os.SystemClock.elapsedRealtime()
                if (now < settleUntil) return
                if (start == 0L) { start = now; return }
                count++
                if (now - start < WINDOW_MS * windows) return
                fired = true
                onRate?.invoke(count * 1000.0 / (now - start))
            }
        }
        try {
            s.capture.setRepeatingRequest(b.build(), callback, s.handler)
            if (high) status[trackId] = if (applied.isEmpty()) "default" else "high"
            Log.i(TAG, "$trackId: ${if (high) "HIGH_QUALITY ${applied.joinToString()}" else "FAST"} " +
                "(${s.format.width}x${s.format.height} @ $minFps-$maxFps)")
        } catch (e: Exception) {
            Log.w(TAG, "setRepeatingRequest: ${e.message}")
        }
    }
}
