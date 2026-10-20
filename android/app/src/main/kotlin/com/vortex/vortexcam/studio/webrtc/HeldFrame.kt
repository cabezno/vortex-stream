package com.vortex.vortexcam.studio.webrtc

import android.opengl.GLES20
import org.webrtc.GlTextureFrameBuffer
import org.webrtc.VideoFrame
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/** A picture a [WebRtcSourceSink] keeps for the program: a CPU copy (I420) or a GPU copy. Ref-counted. */
sealed class HeldFrame {
    abstract fun retain()
    abstract fun release()

    class Cpu(val frame: VideoFrame) : HeldFrame() {
        override fun retain() = frame.retain()
        override fun release() = frame.release()
    }

    /**
     * An upright RGBA copy of a camera texture, made on the GPU (2026-10-19). The switcher's own camera used to be
     * read back to the CPU (toI420, ~14–31 ms a frame on a Mi A3) and uploaded again by the compositor; a GPU copy
     * costs a draw. The copy is finished (glFinish) before the frame is handed out, so the compositor's context (the
     * same share group) can sample it right away.
     */
    class Gpu(val fb: GlTextureFrameBuffer, private val pool: GpuFramePool) : HeldFrame() {
        val width get() = fb.width
        val height get() = fb.height
        internal val refs = AtomicInteger(1)
        override fun retain() { refs.incrementAndGet() }
        override fun release() { if (refs.decrementAndGet() == 0) pool.recycle(this) }
    }
}

/**
 * The GPU copies of one sink. Textures are created, resized and deleted only on a thread with a GL context of the
 * share group current (the camera's thread in onFrame, or the program's render thread via [drainOrphans]); released
 * frames come back here from any thread.
 */
class GpuFramePool {
    private val free = ConcurrentLinkedQueue<HeldFrame.Gpu>()
    @Volatile private var disposed = false

    /** A frame of exactly w×h, ref-count 1. Call with a GL context current. */
    fun obtain(w: Int, h: Int): HeldFrame.Gpu {
        drainOrphans()
        while (true) {
            val f = free.poll() ?: break
            if (f.width == w && f.height == h) { f.refs.set(1); return f }
            delete(f)                                           // a size from another layout
        }
        val fb = GlTextureFrameBuffer(GLES20.GL_RGBA)
        fb.setSize(w, h)
        return HeldFrame.Gpu(fb, this)
    }

    fun recycle(f: HeldFrame.Gpu) { if (disposed) orphans.add(f) else free.add(f) }

    /** The sink is gone (any thread): its textures are deleted by the next thread with a GL context. */
    fun dispose() {
        disposed = true
        while (true) orphans.add(free.poll() ?: break)
    }

    companion object {
        private val orphans = ConcurrentLinkedQueue<HeldFrame.Gpu>()

        /** Deletes the textures of disposed sinks. Call with a GL context of the share group current. */
        fun drainOrphans() { while (true) delete(orphans.poll() ?: break) }

        private fun delete(f: HeldFrame.Gpu) {
            try {
                f.fb.release()
            } catch (_: Exception) {}
        }
    }
}
