package com.vortex.vortexcam

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.nio.ByteBuffer

/**
 * What THIS phone can do, measured on the phone (2026-10-04) so the app only offers what works — no surprises.
 * Hardware video encoders (H.264 / H.265 / AV1) with the largest 16:9 size at 30 and 60 fps, the cameras' largest
 * 16:9 capture, and OMT's CPU encoder speed (timed on a 1080p frame). The WebRTC H.264 check (WHIP) is done on the
 * Dart side with a short loopback session. Never a list of phone models.
 */
object DeviceCaps {
    private const val TAG = "DeviceCaps"
    private val SIZES = listOf(3840 to 2160, 2560 to 1440, 1920 to 1080, 1280 to 720, 960 to 540)

    /** Android build + when this APK was installed/updated: a different stamp means "probe again". */
    fun stamp(ctx: Context): String {
        val upd = try { ctx.packageManager.getPackageInfo(ctx.packageName, 0).lastUpdateTime } catch (_: Exception) { 0L }
        return "${Build.FINGERPRINT}|$upd"
    }

    fun probe(ctx: Context): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        out["fingerprint"] = Build.FINGERPRINT
        out["model"] = "${Build.MANUFACTURER} ${Build.MODEL}"
        out["sdk"] = Build.VERSION.SDK_INT
        out["avc"] = encoderCaps(MediaFormat.MIMETYPE_VIDEO_AVC)
        out["hevc"] = encoderCaps(MediaFormat.MIMETYPE_VIDEO_HEVC)
        out["av1"] = if (Build.VERSION.SDK_INT >= 29) encoderCaps(MediaFormat.MIMETYPE_VIDEO_AV1) else null
        out["cameraBack"] = cameraCaps(ctx, CameraCharacteristics.LENS_FACING_BACK)
        out["cameraFront"] = cameraCaps(ctx, CameraCharacteristics.LENS_FACING_FRONT)
        out["omt"] = omtCaps()
        Log.i(TAG, "probe: $out")
        return out
    }

    private fun isHw(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated
        else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")

    /** Best HARDWARE encoder of [mime]: its name and largest 16:9 size at 30 / 60 fps; null = no hardware encoder. */
    private fun encoderCaps(mime: String): Map<String, Any?>? {
        val infos = try { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos } catch (e: Exception) { return null }
        var best: Map<String, Any?>? = null
        var bestPixels = 0
        for (info in infos) {
            if (!info.isEncoder || !isHw(info) || info.supportedTypes.none { it.equals(mime, true) }) continue
            val vc = try { info.getCapabilitiesForType(mime).videoCapabilities } catch (_: Exception) { null } ?: continue
            fun maxAt(fps: Double) = SIZES.firstOrNull { (w, h) ->
                try { vc.areSizeAndRateSupported(w, h, fps) } catch (_: Exception) { false } }
            val m30 = maxAt(30.0) ?: continue
            val m60 = maxAt(60.0)
            val px = m30.first * m30.second
            if (px > bestPixels) {
                bestPixels = px
                best = mapOf("name" to info.name, "max30" to "${m30.first}x${m30.second}",
                             "max60" to m60?.let { "${it.first}x${it.second}" },
                             "maxBitrate" to vc.bitrateRange.upper)
            }
        }
        return best
    }

    /** Largest 16:9 capture of the first camera facing [facing], and its highest frame rate. */
    private fun cameraCaps(ctx: Context, facing: Int): Map<String, Any?>? {
        return try {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            for (id in cm.cameraIdList) {
                val ch = cm.getCameraCharacteristics(id)
                if (ch.get(CameraCharacteristics.LENS_FACING) != facing) continue
                val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: continue
                val sizes = map.getOutputSizes(SurfaceTexture::class.java) ?: continue
                val wide = sizes.filter { kotlin.math.abs(it.width * 9 - it.height * 16) <= it.height / 10 }
                    .maxByOrNull { it.width * it.height } ?: continue
                val fps = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.maxOfOrNull { it.upper } ?: 30
                return mapOf("max" to "${wide.width}x${wide.height}", "maxFps" to fps)
            }
            null
        } catch (e: Exception) { Log.w(TAG, "camera caps: ${e.message}"); null }
    }

    /**
     * Every camera Android exposes NOW, with its id (what getUserMedia's deviceId takes), facing — back / front /
     * external (a USB camera or HDMI capture dongle, UVC) — and largest 16:9 size; plus whether this phone supports
     * external cameras at all (FEATURE_CAMERA_EXTERNAL — many makers leave it out, then a USB camera never appears).
     */
    fun listCameras(ctx: Context): Map<String, Any?> {
        val cams = ArrayList<Map<String, Any?>>()
        try {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            for (id in cm.cameraIdList) {
                val ch = cm.getCameraCharacteristics(id)
                val facing = when (ch.get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_BACK -> "back"
                    CameraCharacteristics.LENS_FACING_FRONT -> "front"
                    else -> "external"
                }
                val sizes = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    ?.getOutputSizes(SurfaceTexture::class.java) ?: emptyArray()
                val best = sizes.filter { kotlin.math.abs(it.width * 9 - it.height * 16) <= it.height / 10 }
                    .maxByOrNull { it.width * it.height } ?: sizes.maxByOrNull { it.width * it.height }
                cams.add(mapOf("id" to id, "facing" to facing, "max" to best?.let { "${it.width}x${it.height}" }))
            }
        } catch (e: Exception) { Log.w(TAG, "listCameras: ${e.message}") }
        val ext = ctx.packageManager.hasSystemFeature("android.hardware.camera.external")
        return mapOf("cameras" to cams, "externalSupported" to ext)
    }

    /** OMT encodes on the CPU (VMX): time a 1080p frame to know what this CPU sustains. */
    private fun omtCaps(): Map<String, Any?> {
        if (!OmtStreamPlugin.nativeAvailable) return mapOf("available" to false, "reason" to "falta la librería VMX")
        return try {
            val w = 1920; val h = 1080
            val y = ByteBuffer.allocateDirect(w * h); val uv = ByteBuffer.allocateDirect(w * h / 2)
            for (i in 0 until w * h step 7) y.put(i, (i and 0xFF).toByte())        // not a flat frame
            val enc = OmtStreamPlugin.nativeCreateEncoder(w, h, 166, 709)
            if (enc == 0L) return mapOf("available" to false, "reason" to "el encoder VMX no se pudo crear")
            OmtStreamPlugin.nativeEncodeNV12(enc, y, w, uv, w)                     // warm-up
            val t0 = System.nanoTime()
            repeat(5) { OmtStreamPlugin.nativeEncodeNV12(enc, y, w, uv, w) }
            val msPerFrame = (System.nanoTime() - t0) / 5e6
            OmtStreamPlugin.nativeDestroyEncoder(enc)
            mapOf("available" to true, "fps1080" to (1000.0 / msPerFrame).toInt())
        } catch (t: Throwable) {
            mapOf("available" to false, "reason" to "falló la prueba del encoder: ${t.message}")
        }
    }
}
