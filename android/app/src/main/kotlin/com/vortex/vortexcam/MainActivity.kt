package com.vortex.vortexcam

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.vortex.vortexcam.studio.StudioSwitcherPlugin

class MainActivity : FlutterActivity() {
    private var studioSwitcher: StudioSwitcherPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register native streaming plugins
        VortexCamPlugin.registerWith(this, flutterEngine)
        OmtStreamPlugin.registerWith(this, flutterEngine)
        // Switcher mode (ex SAMBA Móvil Studio): program compositor + encoder + RTMP
        studioSwitcher = StudioSwitcherPlugin.registerWith(flutterEngine)

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

    override fun onDestroy() {
        studioSwitcher?.dispose()
        studioSwitcher = null
        super.onDestroy()
    }
}
