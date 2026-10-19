package com.vortex.vortexcam.studio.gl

import android.opengl.GLES20
import org.webrtc.GlShader
import org.webrtc.RendererCommon
import java.lang.reflect.Proxy

/**
 * A GlRectDrawer that also corrects the colour (ColorMatch, 2026-10-19): per-channel gains (white balance and
 * exposure) and saturation, set with [set] before each draw. Built on WebRTC's GlGenericDrawer — the class that adapts
 * one fragment shader to OES, RGB and YUV textures — which is package-private, so it is created by reflection (the
 * CI keeps only this app's own Kotlin package, so the class cannot live in org.webrtc). Null when that fails: the
 * compositor then draws without correction.
 */
class GradeDrawer private constructor(private val inner: RendererCommon.GlDrawer, private val u: Uniforms)
    : RendererCommon.GlDrawer by inner {

    fun set(r: Float, g: Float, b: Float, sat: Float) { u.r = r; u.g = g; u.b = b; u.sat = sat }

    private class Uniforms {
        @Volatile var r = 1f; @Volatile var g = 1f; @Volatile var b = 1f; @Volatile var sat = 1f
        var gainLoc = -1; var satLoc = -1
    }

    companion object {
        private const val FRAGMENT = """uniform vec3 cg_gain;
uniform float cg_sat;
void main() {
  vec4 c = sample(tc);
  vec3 rgb = c.rgb * cg_gain;
  float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
  gl_FragColor = vec4(clamp(mix(vec3(l), rgb, cg_sat), 0.0, 1.0), c.a);
}
"""

        fun create(): GradeDrawer? = try {
            val generic = Class.forName("org.webrtc.GlGenericDrawer")
            val callbacks = Class.forName("org.webrtc.GlGenericDrawer\$ShaderCallbacks")
            val u = Uniforms()
            val proxy = Proxy.newProxyInstance(callbacks.classLoader, arrayOf(callbacks)) { _, m, args ->
                when (m.name) {
                    "onNewShader" -> {
                        val sh = args[0] as GlShader
                        u.gainLoc = sh.getUniformLocation("cg_gain")
                        u.satLoc = sh.getUniformLocation("cg_sat")
                    }
                    "onPrepareShader" -> {
                        GLES20.glUniform3f(u.gainLoc, u.r, u.g, u.b)
                        GLES20.glUniform1f(u.satLoc, u.sat)
                    }
                }
                null
            }
            val ctor = generic.getDeclaredConstructor(String::class.java, callbacks).apply { isAccessible = true }
            GradeDrawer(ctor.newInstance(FRAGMENT, proxy) as RendererCommon.GlDrawer, u)
        } catch (e: Throwable) {
            android.util.Log.w("GradeDrawer", "No colour correction: ${e.message}")
            null
        }
    }
}
