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
    // Ceiling below maxBps while the phone is hot (DT-145): the network may carry more, the phone should not make it.
    private var ceilingBps = maxBps
    private var lastChangeMs = 0L
    private var cleanSinceMs = System.currentTimeMillis()

    /** One sample from the transport: [lossy] = the network is not carrying this rate. [detail] goes to the log. */
    @Synchronized fun report(lossy: Boolean, detail: String = "") {
        val now = System.currentTimeMillis()
        if (lossy) {
            cleanSinceMs = now
            if (now - lastChangeMs < 1500 || currentBps <= floorBps) return
            set(maxOf(floorBps, (currentBps * 0.7).toInt()), now, "baja — $detail")
        } else if (currentBps < ceilingBps && now - cleanSinceMs >= 8000 && now - lastChangeMs >= 4000) {
            set(minOf(ceilingBps, (currentBps * 1.15).toInt()), now, "sube — red limpia")
        }
    }

    /** Heat ceiling as a fraction of the configured rate (1.0 = none). Lowers at once; raising is left to [report]. */
    @Synchronized fun setHeatCeiling(fraction: Double, detail: String) {
        ceilingBps = maxOf(floorBps, (maxBps * fraction).toInt())
        if (currentBps > ceilingBps) set(ceilingBps, System.currentTimeMillis(), "calor — $detail")
        else Log.i("AdaptiveBitrate", "$label: techo ${ceilingBps / 1000} kbps ($detail)")
    }

    /**
     * The network is far from carrying this rate (SRT: packets dropped, or a send queue over twice the latency).
     * Cut at once to 70 % of what actually got through ([sentMbps], libsrt's measured send rate), at least halving,
     * at most every second - not -30 % every 1.5 s from a rate it never carried.
     */
    @Synchronized fun reportSevere(sentMbps: Double, detail: String = "") {
        val now = System.currentTimeMillis()
        cleanSinceMs = now
        if (now - lastChangeMs < 1000 || currentBps <= floorBps) return
        val measured = if (sentMbps > 0) (sentMbps * 1e6 * 0.7).toInt() else Int.MAX_VALUE
        set(maxOf(floorBps, minOf(currentBps / 2, measured)), now, "baja fuerte — $detail")
    }

    private fun set(bps: Int, now: Long, why: String) {
        if (bps == currentBps) return
        currentBps = bps; lastChangeMs = now
        Log.i("AdaptiveBitrate", "$label: ${bps / 1000} kbps ($why)")
        try { apply(bps) } catch (e: Exception) { Log.w("AdaptiveBitrate", "apply: $e") }
    }
}
