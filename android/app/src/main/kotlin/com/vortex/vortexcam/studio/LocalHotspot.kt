package com.vortex.vortexcam.studio

import android.content.Context
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The switcher's OWN Wi-Fi network for its cameras (plan PLAN-CONEXION-SWITCHER.md §1, 2026-10-05).
 * A local-only hotspot (Android 8+): an internal network, no internet sharing — the switcher's SIM stays free for the
 * outgoing RTMP. Each camera packet crosses the air once (camera → switcher) instead of twice through a router, and
 * no foreign traffic shares the channel. The SSID / password / band are chosen by the system; they travel in the
 * pairing QR so a camera joins by itself.
 */
class LocalHotspot(private val ctx: Context) {
    companion object { private const val TAG = "LocalHotspot" }

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private val main = Handler(Looper.getMainLooper())

    val isOn: Boolean get() = reservation != null

    fun start(onResult: (Map<String, Any?>) -> Unit) {
        if (reservation != null) { onResult(info()); return }
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wm.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = r
                    WebRtcOwnNetwork.enable(ctx)
                    // The access-point interface gets its address a moment after the network starts.
                    main.postDelayed({ onResult(info()) }, 800)
                }
                override fun onStopped() {
                    reservation = null; WebRtcOwnNetwork.disable(ctx); Log.i(TAG, "hotspot stopped by the system")
                }
                override fun onFailed(reason: Int) {
                    val why = when (reason) {
                        ERROR_NO_CHANNEL -> "no hay canal Wi-Fi libre"
                        ERROR_TETHERING_DISALLOWED -> "este celular no permite crear redes (política del fabricante u operador)"
                        ERROR_INCOMPATIBLE_MODE -> "el Wi-Fi está en un modo incompatible (¿hay otro hotspot activo?)"
                        else -> "error $reason"
                    }
                    onResult(mapOf("ok" to false, "error" to why))
                }
            }, main)
        } catch (e: SecurityException) {
            onResult(mapOf("ok" to false, "error" to "falta el permiso de ubicación / dispositivos cercanos (y la ubicación encendida)"))
        } catch (e: Exception) {
            onResult(mapOf("ok" to false, "error" to (e.message ?: e.toString())))
        }
    }

    fun stop() {
        val was = reservation != null
        try { reservation?.close() } catch (_: Exception) {}
        reservation = null
        if (was) WebRtcOwnNetwork.disable(ctx)
    }

    @Suppress("DEPRECATION")
    fun info(): Map<String, Any?> {
        val r = reservation ?: return mapOf("ok" to false, "error" to "apagado")
        var ssid: String? = null; var pass: String? = null; val band = ""
        if (Build.VERSION.SDK_INT >= 30) {
            val c: SoftApConfiguration = r.softApConfiguration
            ssid = c.ssid; pass = c.passphrase
            // The band is not readable by apps (SoftApConfiguration.getBand is a system API): the cameras measure it
            // once joined (their Wi-Fi frequency).
        } else {
            val c = r.wifiConfiguration
            ssid = c?.SSID?.trim('"'); pass = c?.preSharedKey?.trim('"')
        }
        return mapOf("ok" to true, "ssid" to ssid, "password" to pass, "band" to band, "ip" to apAddress())
    }

    /** The switcher's address on its own network (the access-point interface: swlan0 / ap0 / wlan1 / softap0…). */
    private fun apAddress(): String? {
        val cands = mutableListOf<Pair<String, String>>()
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                if (!ni.isUp || ni.isLoopback) continue
                for (a in ni.inetAddresses) if (a is Inet4Address && a.isSiteLocalAddress) cands.add(ni.name to a.hostAddress!!)
            }
        } catch (_: Exception) {}
        val ap = cands.firstOrNull { (n, _) -> n.startsWith("swlan") || n.startsWith("ap") || n.startsWith("softap") }
            ?: cands.firstOrNull { (n, _) -> n.startsWith("wlan") && n != "wlan0" }
        Log.i(TAG, "interfaces: $cands → ${ap?.second}")
        return ap?.second
    }
}
