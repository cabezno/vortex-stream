package org.webrtc

import android.opengl.GLES20

/**
 * A GlRectDrawer that also corrects the colour (ColorMatch, 2026-10-19): per-channel gains (white balance and
 * exposure) and saturation, set with [set] before each draw. In package org.webrtc because GlGenericDrawer — the
 * class that adapts one shader to OES, RGB and YUV textures — is package-private.
 */
class GradeDrawer private constructor(private val cb: Callbacks) : GlGenericDrawer(FRAGMENT, cb) {
    constructor() : this(Callbacks())

    fun set(r: Float, g: Float, b: Float, sat: Float) { cb.r = r; cb.g = g; cb.b = b; cb.sat = sat }

    private class Callbacks : ShaderCallbacks {
        var r = 1f; var g = 1f; var b = 1f; var sat = 1f
        private var gainLoc = -1
        private var satLoc = -1
        override fun onNewShader(shader: GlShader) {
            gainLoc = shader.getUniformLocation("cg_gain")
            satLoc = shader.getUniformLocation("cg_sat")
        }
        override fun onPrepareShader(shader: GlShader, texMatrix: FloatArray, frameWidth: Int, frameHeight: Int,
                                     viewportWidth: Int, viewportHeight: Int) {
            GLES20.glUniform3f(gainLoc, r, g, b)
            GLES20.glUniform1f(satLoc, sat)
        }
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
    }
}
