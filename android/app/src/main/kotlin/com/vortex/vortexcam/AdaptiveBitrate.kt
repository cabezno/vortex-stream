package com.vortex.vortexcam

import android.util.Log

/**
 * Bitrate that follows the network, for SBL and SRT (2026-10-04). They used to send a fixed rate (4K = 30 Mbps): on a
 * phone with a lossy Wi-Fi (Mi A3, 6–15 % ping loss) or with two 4K phones on one Wi-Fi, SAMBA got an incomplete frame
 * every second and pauses up to 0.4 s, while WHIP — which adapts — stayed clean on the same phone.
 *
 * Down fast (−30 % per bad sample, at most every 1.5 s), up slowly (+15 % after 8 s with no loss, at most every 4 s),
 * never above what was configured nor below [floorBps]. The signal comes from each transport, measured live: SAMBA's
 * own loss report and keyframe requests (SBL), writes blocked on a full TCP buffer (SRT/TCP). Never fixed thresholds
 * per phone.
 */
class AdaptiveBitrate(
    private val maxBps: Int,
    private val label: String,
    private val apply: (bps: Int) -> Unit,
) {
    private val floorBps = maxOf(1_500_000, maxBps / 8)
    @Volatile var currentBps = maxBps
        private set
    private var lastChangeMs = 0L
    private var cleanSinceMs = System.currentTimeMillis()

    /** One sample from the transport: [lossy] = the network is not carrying this rate. [detail] goes to the log. */
    @Synchronized fun report(lossy: Boolean, detail: String = "") {
        val now = System.currentTimeMillis()
        if (lossy) {
            cleanSinceMs = now
            if (now - lastChangeMs < 1500 || currentBps <= floorBps) return
            set(maxOf(floorBps, (currentBps * 0.7).toInt()), now, "baja — $detail")
        } else if (currentBps < maxBps && now - cleanSinceMs >= 8000 && now - lastChangeMs >= 4000) {
            set(minOf(maxBps, (currentBps * 1.15).toInt()), now, "sube — red limpia")
        }
    }

    private fun set(bps: Int, now: Long, why: String) {
        if (bps == currentBps) return
        currentBps = bps; lastChangeMs = now
        Log.i("AdaptiveBitrate", "$label: ${bps / 1000} kbps ($why)")
        try { apply(bps) } catch (e: Exception) { Log.w("AdaptiveBitrate", "apply: $e") }
    }
}
