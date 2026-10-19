package com.vortex.vortexcam.studio.webrtc

import android.opengl.EGL14
import android.opengl.GLES20
import android.util.Log
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer
import org.webrtc.VideoSink

/**
 * Thread-safe VideoSink feeding the program compositor from a WebRTC VideoTrack, optionally DELAYED.
 * VideoFrame instances in WebRTC are ref-counted (retain/release).
 *
 * Delay (2026-10-06, alignment of sources): cameras reach the switcher with different latencies (the switcher's own
 * camera ~0, Wi-Fi cameras 100–300 ms). The program aligns them to the slowest by holding the faster ones: this sink
 * keeps the last frames with their arrival time and hands out the one from [delayMs] ago. Only the program is
 * delayed; the switcher's own monitors stay live.
 */
class WebRtcSourceSink : VideoSink {
    private val lock = Object()
    private val frames = ArrayDeque<Pair<Long, HeldFrame>>()   // (play time, frame), oldest first

    /** Hold the program picture of this source by this much (0 = live). */
    @Volatile var delayMs: Int = 0

    // Keep a COPY, never the decoder's own frame. A decoded WebRTC frame is usually a texture of the decoder's
    // SurfaceTextureHelper, which has only ONE frame in flight: holding it until the next onFrame() starves the
    // decoder — it froze after ~1 frame (framesReceived kept growing, framesDecoded stuck; diagnosed 2026-09-29 and
    // again 2026-10-04 on a Galaxy A10). toI420() copies it (GPU readback, on the decoder thread where its EGL
    // context is current) and the original is released by the caller right after onFrame returns.
    override fun onFrame(frame: VideoFrame) {
        val copy: HeldFrame = gpuCopy(frame) ?: try {
            val cropped = coverBox?.let { cropFor(frame.buffer, frame.rotation, it) }
            val i420 = try { (cropped ?: frame.buffer).toI420() } finally { cropped?.release() }
            HeldFrame.Cpu(VideoFrame(i420 ?: return, frame.rotation, frame.timestampNs))
        } catch (e: Exception) {
            return
        }
        val now = System.nanoTime()
        // Pace by the frame's own timestamp, not by its arrival: over Wi-Fi frames arrive in bursts (several at once,
        // then a gap), and choosing by arrival time skipped a burst in one go and then held a frame — the program
        // "sped up and slowed down" (split screen, 2026-10-15). playAt = timestamp + the smallest transit seen, so the
        // spacing between frames is the camera's; JITTER_MS of extra hold absorbs the bursts.
        val transit = now - frame.timestampNs
        minTransitNs = if (minTransitNs == Long.MIN_VALUE || transit < minTransitNs) transit
                       else minTransitNs + (transit - minTransitNs) / 500   // follow clock drift slowly
        // A jump (camera restarted, clocks reset) makes the timestamp useless: fall back to arrival until it settles.
        val playAt = if (transit - minTransitNs > RESYNC_NS) { minTransitNs = transit; now }
                     else frame.timestampNs + minTransitNs + JITTER_MS * 1_000_000L
        // Memory cap: a 1080p I420 is ~3 MB, a 4K one ~12 MB → at most MAX_BYTES per source (at 4K that limits the
        // usable delay to ~5 frames). A GPU copy is RGBA (~8 MB at 1080p) in its own, larger budget.
        val (bytes, budget) = when (copy) {
            is HeldFrame.Cpu -> copy.frame.buffer.width.toLong() * copy.frame.buffer.height * 3 / 2 to MAX_BYTES
            is HeldFrame.Gpu -> copy.width.toLong() * copy.height * 4 to MAX_GPU_BYTES
        }
        val maxFrames = (budget / bytes.coerceAtLeast(1)).toInt().coerceIn(2, MAX_FRAMES)
        synchronized(lock) {
            frames.addLast(playAt to copy)
            // Keep what the delay needs (+ the jitter hold + 100 ms).
            val keepNs = (delayMs + JITTER_MS + 100) * 1_000_000L
            while (frames.size > 1 && (frames.size > maxFrames || now - frames.first().first > keepNs)) {
                frames.removeFirst().second.release()
            }
        }
    }

    /**
     * The box this source fills in the program by cropping (split halves, PiP inset), or null (shown whole).
     * Split screen stuttered on a Mi A3 (2026-10-19): the switcher's own camera took ~31 ms per frame to read back from
     * the GPU and the compositor uploaded two full 1080p pictures per frame, though each half shows less than half of
     * one. Cropping here — and, for a camera texture, scaling down to the box, free in the readback — copies and
     * uploads only what is shown.
     */
    @Volatile var coverBox: android.util.Size? = null

    /**
     * [buf] cropped (centre) to the box's aspect, and scaled down to it if it is a texture; null = use it as is.
     * Widths are multiples of 8: the chroma planes are half as wide and GL uploads rows 4-byte aligned — a 958-wide
     * crop (479 chroma) came out sheared diagonally.
     */
    private fun cropFor(buf: VideoFrame.Buffer, rotation: Int, box: android.util.Size): VideoFrame.Buffer? {
        val bw = buf.width; val bh = buf.height
        // The box is in screen orientation; the buffer is not rotated yet.
        val tw = if (rotation % 180 != 0) box.height else box.width
        val th = if (rotation % 180 != 0) box.width else box.height
        if (bw <= 0 || bh <= 0 || tw <= 0 || th <= 0) return null
        val target = tw.toFloat() / th; val aspect = bw.toFloat() / bh
        var cw = bw; var ch = bh
        if (kotlin.math.abs(aspect - target) / target > 0.02f) {
            if (aspect > target) cw = ((bh * target).toInt() and 7.inv()).coerceIn(8, bw)
            else ch = ((bw / target).toInt() and 1.inv()).coerceIn(2, bh)
        }
        var sw = cw; var sh = ch
        // An I420 buffer cropped without scaling is a view (no copy); scaling it would be a CPU resize, so only
        // textures (read back by the GPU at whatever size) are scaled.
        if (buf is VideoFrame.TextureBuffer && tw < cw) {
            sw = (tw and 7.inv()).coerceAtLeast(8); sh = ((ch.toLong() * sw / cw).toInt() and 1.inv()).coerceAtLeast(2)
        }
        if (cw == bw && ch == bh && sw == bw && sh == bh) return null
        return buf.cropAndScale(((bw - cw) / 2) and 1.inv(), ((bh - ch) / 2) and 1.inv(), cw, ch, sw, sh)
    }

    // ── GPU copy (2026-10-19) ─────────────────────────────────────────────────────────────────────────────────
    // A camera texture is drawn — cropped to [coverBox], scaled down to it and rotated upright — into a texture of
    // our own, on the thread that delivers it (its EGL context, shared with the program's, is current there).
    // Anything else (I420 from a software decoder, no context) takes the CPU path.
    private val gpuPool = GpuFramePool()
    private var gpuDrawer: VideoFrameDrawer? = null
    private var gpuRect: GlRectDrawer? = null
    @Volatile private var gpuBroken = false
    private val gpuCrop = android.graphics.Matrix()

    private fun gpuCopy(frame: VideoFrame): HeldFrame? {
        if (gpuBroken || frame.buffer !is VideoFrame.TextureBuffer) return null
        if (EGL14.eglGetCurrentContext() == EGL14.EGL_NO_CONTEXT) return null
        val rw = frame.rotatedWidth; val rh = frame.rotatedHeight
        if (rw <= 0 || rh <= 0) return null
        // Output: the box's aspect (cropped from the centre) and at most its size; the whole picture without a box.
        val box = coverBox
        var cw = rw.toFloat(); var ch = rh.toFloat(); var ow = rw; var oh = rh
        if (box != null && box.width > 0 && box.height > 0) {
            val boxAspect = box.width.toFloat() / box.height
            if (rw.toFloat() / rh > boxAspect) cw = rh * boxAspect else ch = rw / boxAspect
            ow = minOf(cw.toInt(), box.width); oh = (ow / boxAspect).toInt()
        }
        ow = ow.coerceAtLeast(2); oh = oh.coerceAtLeast(2)
        return try {
            val out = gpuPool.obtain(ow, oh)
            val drawer = gpuDrawer ?: VideoFrameDrawer().also { gpuDrawer = it }
            val rect = gpuRect ?: GlRectDrawer().also { gpuRect = it }
            // Crop in the output (rotated) space: VideoFrameDrawer applies this before rotating the texture.
            gpuCrop.reset()
            gpuCrop.preTranslate(0.5f, 0.5f)
            gpuCrop.preScale(cw / rw, ch / rh)
            gpuCrop.preTranslate(-0.5f, -0.5f)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, out.fb.frameBufferId)
            drawer.drawFrame(frame, rect, gpuCrop, 0, 0, ow, oh)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            // Done before it is handed out: another context samples it. (A fence would let the GPU overlap more,
            // but WebRTC's contexts are GLES 2, where fences are not guaranteed.) It waits only for this small draw.
            GLES20.glFinish()
            val err = GLES20.glGetError()
            if (err != GLES20.GL_NO_ERROR) {
                out.release()
                throw IllegalStateException("GL error 0x${Integer.toHexString(err)}")
            }
            out
        } catch (e: Throwable) {
            // Never again for this sink: the CPU path works everywhere.
            gpuBroken = true
            Log.w("WebRtcSourceSink", "GPU copy off, CPU copy from now on: ${e.message}")
            null
        }
    }

    // Smallest (arrival − timestamp) seen: the transit of an on-time frame. Written on the decoder thread only.
    private var minTransitNs = Long.MIN_VALUE

    /**
     * The frame to show now: the newest one that arrived at least [delayMs] ago (the oldest kept while the buffer is
     * still filling, e.g. right after a direct cut), with an incremented ref-count.
     * The caller MUST call frame.release() when done rendering.
     */
    fun getFrame(): HeldFrame? {
        synchronized(lock) {
            if (frames.isEmpty()) return null
            val due = System.nanoTime() - delayMs * 1_000_000L
            var pick = frames.first()
            for (f in frames) { if (f.first <= due) pick = f else break }
            pick.second.retain()
            return pick.second
        }
    }

    fun release() {
        gpuPool.dispose()                                      // before the frames come back to it
        synchronized(lock) {
            while (frames.isNotEmpty()) frames.removeFirst().second.release()
        }
    }

    companion object {
        /** ~0.6 s at 30 fps: the alignment is capped at 500 ms anyway. */
        const val MAX_FRAMES = 18
        const val MAX_BYTES = 64L * 1024 * 1024
        const val MAX_GPU_BYTES = 128L * 1024 * 1024
        /** Hold that absorbs Wi-Fi bursts (on top of the alignment delay). */
        const val JITTER_MS = 60
        /** A frame this much later than the on-time transit = the stream restarted, not jitter. */
        const val RESYNC_NS = 1_000_000_000L
    }
}
