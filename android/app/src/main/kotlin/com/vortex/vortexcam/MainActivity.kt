package com.vortex.vortexcam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val registry = flutterEngine.plugins

        // Register native streaming plugins
        VortexCamPlugin.registerWith(this, flutterEngine)
        OmtStreamPlugin.registerWith(this, flutterEngine)
    }
}
