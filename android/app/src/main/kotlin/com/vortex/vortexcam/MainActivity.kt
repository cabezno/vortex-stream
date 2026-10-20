package com.vortex.vortexcam

import android.content.Intent
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.vortex.vortexcam.studio.StudioSwitcherPlugin

class MainActivity : FlutterActivity() {
    companion object { private const val PICK_VIDEO = 7301 }
    private var studioSwitcher: StudioSwitcherPlugin? = null
    private var pickResult: MethodChannel.Result? = null
    private var pickDir: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register native streaming plugins
        VortexCamPlugin.registerWith(this, flutterEngine)
        OmtStreamPlugin.registerWith(this, flutterEngine)
        // Switcher mode (ex SAMBA Móvil Studio): program compositor + encoder + RTMP
        studioSwitcher = StudioSwitcherPlugin.registerWith(flutterEngine, applicationContext)

        // Switcher intro video: the system picker, then a copy into the app (the gallery's file may move or go).
        // {dir} → {path, name}, or null when cancelled.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.vortex.vortexcam/pick")
            .setMethodCallHandler { call, result ->
                if (call.method != "pickVideo") { result.notImplemented(); return@setMethodCallHandler }
                pickResult?.success(null)
                pickResult = result
                pickDir = call.argument<String>("dir")
                try {
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "video/*"
                    }, PICK_VIDEO)
                } catch (e: Exception) {
                    pickResult = null
                    result.error("PICK", e.message, null)
                }
            }

        // Keep-alive while live (any transport, WHIP included): foreground service + Wi-Fi/CPU locks
        // (StreamKeepAliveService) and the screen kept on while the app is in front.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.vortex.vortexcam/keepalive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        StreamKeepAliveService.start(applicationContext, call.argument<String>("text") ?: "Transmitiendo")
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(true)
                    }
                    "stop" -> {
                        StreamKeepAliveService.stop(applicationContext)
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(true)
                    }
                    "running" -> result.success(StreamKeepAliveService.running)
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_VIDEO) return
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        val dir = pickDir
        if (resultCode != RESULT_OK || uri == null || dir == null) { result.success(null); return }
        val main = android.os.Handler(mainLooper)
        Thread({
            try {
                var name = "video.mp4"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0)?.let { n -> name = n }
                }
                val d = java.io.File(dir)
                d.deleteRecursively(); d.mkdirs()
                val ext = name.substringAfterLast('.', "mp4").take(5)
                val out = java.io.File(d, "intro.$ext")
                contentResolver.openInputStream(uri)!!.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 16) } }
                main.post { result.success(mapOf("path" to out.absolutePath, "name" to name)) }
            } catch (e: Exception) {
                main.post { result.error("PICK", e.message ?: e.toString(), null) }
            }
        }, "PickVideoCopy").start()
    }

    override fun onDestroy() {
        studioSwitcher?.dispose()
        studioSwitcher = null
        super.onDestroy()
    }
}
