package com.vortex.vortexcam

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.util.Log

/**
 * Heat while streaming (DT-145). 2026-10-09 the Redmi at 4K / 30 Mbps reached «Thermal Level Warming(4)» and its
 * encoder fell to ~3 fps: jerky picture in SAMBA for minutes. Two signals, because not every phone has the first:
 *
 * - Android's thermal status (API 29+). The Mi A3 and the Galaxy A10 report «HAL Ready: false» and stay at 0 forever,
 *   so on them this signal never fires.
 * - The encoder itself slowing down: fewer than [SLOW_FPS] frames per second of CAMERA time (PTS), two 5 s windows in
 *   a row. Counted on PTS, not on the wall clock, so a drain loop held up by the network does not look like heat.
 *   The first 10 s do not count (encoder start-up, first IDR).
 *
 * The plugin decides what to do: [onStatus] for every status change, [onSlowEncoder] once per slow streak.
 */
class HeatGuard(
    private val context: Context,
    private val onStatus: (status: Int) -> Unit,
    private val onSlowEncoder: (fps: Double) -> Unit,
) {
    private var listener: PowerManager.OnThermalStatusChangedListener? = null
    private var firstPtsUs = -1L
    private var winStartPtsUs = -1L
    private var winFrames = 0
    private var slowWindows = 0

    fun start() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val l = PowerManager.OnThermalStatusChangedListener { s -> onStatus(s) }
        try {
            pm.addThermalStatusListener(context.mainExecutor, l)   // called back at once with the current status
            listener = l
            Log.i(TAG, "estado térmico al empezar: ${name(pm.currentThermalStatus)}")
        } catch (e: Exception) { Log.w(TAG, "thermal listener unavailable: $e") }
    }

    fun stop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val l = listener ?: return
        listener = null
        try { (context.getSystemService(Context.POWER_SERVICE) as PowerManager).removeThermalStatusListener(l) }
        catch (_: Exception) {}
    }

    /** One encoded video frame (encode thread). */
    fun noteFrame(ptsUs: Long) {
        if (firstPtsUs < 0) { firstPtsUs = ptsUs; winStartPtsUs = ptsUs; winFrames = 0; return }
        if (ptsUs - firstPtsUs < WARMUP_US) { winStartPtsUs = ptsUs; winFrames = 0; return }
        winFrames++
        val span = ptsUs - winStartPtsUs
        if (span < WINDOW_US) return
        val fps = winFrames * 1e6 / span
        slowWindows = if (fps < SLOW_FPS) slowWindows + 1 else 0
        winStartPtsUs = ptsUs; winFrames = 0
        if (slowWindows >= 2) { slowWindows = 0; onSlowEncoder(fps) }
    }

    companion object {
        private const val TAG = "HeatGuard"
        private const val SLOW_FPS = 20.0
        private const val WINDOW_US = 5_000_000L
        private const val WARMUP_US = 10_000_000L

        fun name(s: Int): String = when (s) {
            0 -> "0 (normal)"; 1 -> "1 (leve)"; 2 -> "2 (moderado)"; 3 -> "3 (severo)"
            4 -> "4 (crítico)"; 5 -> "5 (emergencia)"; 6 -> "6 (apagado)"; else -> s.toString()
        }
    }
}
