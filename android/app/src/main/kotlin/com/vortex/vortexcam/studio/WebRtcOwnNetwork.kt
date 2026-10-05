package com.vortex.vortexcam.studio

import android.content.Context
import android.util.Log
import org.webrtc.Logging
import org.webrtc.NetworkChangeDetector
import org.webrtc.NetworkMonitor
import org.webrtc.NetworkMonitorAutoDetect
import org.webrtc.PeerConnectionFactory

/**
 * WebRTC over the switcher's OWN hotspot (2026-10-05). libwebrtc on Android only uses interfaces that Android reports
 * as a Network and binds every socket to one: the local-only hotspot interface (wlan2 / swlan0 / ap0) is not a Network,
 * so the switcher offered candidates only on the home Wi-Fi / SIM, the camera's checks arrived (weak host) but every
 * reply left through wlan0 and ICE failed. While the own network is on:
 *  - field trial `WebRTC-AndroidNetworkMonitor-IsAdapterAvailable/Disabled/`: interfaces without a network handle count;
 *  - a network detector without network callbacks: libwebrtc does not bind sockets to a Network (binding "not
 *    supported"), the kernel routes them — the local_network table already holds the hotspot subnet.
 * Both are read when a peer connection builds its transports / starts network monitoring, so this runs when the
 * hotspot starts (before the cameras join) and is undone when it stops: the other modes keep the stock behaviour.
 */
object WebRtcOwnNetwork {
    private const val TAG = "WebRtcOwnNetwork"
    private const val TRIALS = "WebRTC-AndroidNetworkMonitor-IsAdapterAvailable/Disabled/"

    fun enable(ctx: Context) {
        try {
            reinit(ctx, TRIALS)
            NetworkMonitor.getInstance().setNetworkChangeDetectorFactory { _, _ -> Unbound }
            Log.i(TAG, "on: every interface, sockets not bound to a Network")
        } catch (e: Throwable) { Log.e(TAG, "enable: $e") }
    }

    fun disable(ctx: Context) {
        try {
            reinit(ctx, "")
            NetworkMonitor.getInstance().setNetworkChangeDetectorFactory { o, c -> NetworkMonitorAutoDetect(o, c) }
            Log.i(TAG, "off: stock network monitor")
        } catch (e: Throwable) { Log.e(TAG, "disable: $e") }
    }

    private fun reinit(ctx: Context, trials: String) =
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(ctx.applicationContext)
                .setFieldTrials(trials)
                // Keep libwebrtc's log in logcat (re-initializing without a logger deletes flutter_webrtc's).
                .setInjectableLogger({ msg, _, tag -> Log.i(tag, msg) }, Logging.Severity.LS_INFO)
                .createInitializationOptions())

    private object Unbound : NetworkChangeDetector {
        override fun getCurrentConnectionType() = NetworkChangeDetector.ConnectionType.CONNECTION_WIFI
        override fun supportNetworkCallback() = false
        override fun getActiveNetworkList(): List<NetworkChangeDetector.NetworkInformation> = emptyList()
        override fun destroy() {}
    }
}
