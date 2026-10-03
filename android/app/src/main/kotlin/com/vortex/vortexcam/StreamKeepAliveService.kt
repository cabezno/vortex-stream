package com.vortex.vortexcam

// =============================================================================
// StreamKeepAliveService — keeps a live transmission alive with the phone LOCKED or the app in the background.
//
// Without it Android takes the camera away and lets Wi-Fi sleep as soon as the screen locks: SAMBA saw the phone
// stop sending, cut it after 5 s, and the phone only noticed a minute later (Mac, 2 phones on SRT, 2026-10-03:
// «la app no resiste el bloqueo de android»).
//
// A foreground service of type camera|microphone (required on Android 14+, with FOREGROUND_SERVICE_CAMERA /
// FOREGROUND_SERVICE_MICROPHONE) lets the capture continue with the screen off; it shows a fixed notification
// while it runs. While running it also holds:
//   - a WifiLock (FULL_LOW_LATENCY on API 29+, FULL_HIGH_PERF before) — no Wi-Fi power save between packets;
//   - a PARTIAL_WAKE_LOCK — the CPU keeps encoding and sending with the screen off.
// Started by Dart when a transmission goes live (any transport), stopped on disconnect. Shared-core candidate
// (samba_core): the SAMBA Studio switcher needs exactly the same.
// =============================================================================

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

class StreamKeepAliveService : Service() {

    companion object {
        private const val TAG        = "VortexKeepAlive"
        private const val CHANNEL_ID = "samba_air_live"
        private const val NOTIF_ID   = 4711
        const val EXTRA_TEXT         = "text"

        @Volatile var running = false
            private set

        fun start(ctx: Context, text: String) {
            val i = Intent(ctx, StreamKeepAliveService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, StreamKeepAliveService::class.java)) }
    }

    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Transmitiendo"
        val notif = buildNotification(text)
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTIF_ID, notif,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (e: Exception) {
            // Android 14 refuses a camera FGS started from the background or without the runtime permission:
            // keep the app running instead of crashing; the locks below still help.
            Log.e(TAG, "startForeground failed: $e")
        }
        acquireLocks()
        running = true
        Log.i(TAG, "keep-alive ON ($text)")
        return START_NOT_STICKY   // never restart a transmission by itself after the process died
    }

    override fun onDestroy() {
        releaseLocks()
        running = false
        Log.i(TAG, "keep-alive OFF")
        super.onDestroy()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks() {
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                       else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "SambaAir:live").apply { setReferenceCounted(false); acquire() }
        }
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SambaAir:live").apply {
                setReferenceCounted(false); acquire()
            }
        }
    }

    private fun releaseLocks() {
        try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        wifiLock = null; wakeLock = null
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Transmisión en vivo",
                NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
                else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle("Samba Air — en vivo")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .apply { if (open != null) setContentIntent(open) }
            .build()
    }
}
