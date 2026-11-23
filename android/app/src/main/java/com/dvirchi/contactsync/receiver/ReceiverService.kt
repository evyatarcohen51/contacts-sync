package com.dvirchi.contactsync.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Always-on foreground service: listens for the iPhone on port 8765
 * (reachable over Tailscale and the local Wi-Fi) and advertises itself
 * on the LAN via Bonjour/NSD for first-time pairing.
 */
class ReceiverService : Service() {

    companion object {
        private const val TAG = "ReceiverService"
        private const val CHANNEL = "receiver"
        private const val NOTIF_ID = 1

        fun start(ctx: Context) {
            ContextCompat.startForegroundService(ctx, Intent(ctx, ReceiverService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var server: MiniHttpServer
    private var wakeLock: PowerManager.WakeLock? = null
    private var nsdListener: NsdManager.RegistrationListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ReceiverApi.init(this)
        createChannel()
        goForeground(notificationText(AppState.status.value))

        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ContactSync:request")
            .apply { setReferenceCounted(true) }

        server = MiniHttpServer(
            Protocol.PORT,
            preflight = ReceiverApi::preflight,
            // Keep the CPU awake from the moment the iPhone connects until it has its answer.
            around = { serve ->
                runCatching { wakeLock?.acquire(10 * 60_000L) }
                try {
                    serve()
                } finally {
                    runCatching { wakeLock?.release() }
                }
            },
            onInterrupted = ReceiverApi::uploadInterrupted,
            handler = ReceiverApi::handle,
        )
        try {
            server.start()
            AppState.update { it.copy(running = true) }
        } catch (e: Exception) {
            Log.e(TAG, "could not start server", e)
            AppState.update { it.copy(running = false, message = "Could not open port ${Protocol.PORT}: ${e.message}") }
        }
        registerNsd()

        scope.launch {
            AppState.status.map { notificationText(it) }.distinctUntilChanged().collect { text ->
                getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every startForegroundService() call must be answered with startForeground().
        goForeground(notificationText(AppState.status.value))
        return START_STICKY
    }

    private fun notificationText(s: Status) =
        if (s.contactCount > 0) "${s.message} · ${s.contactCount} contacts" else s.message

    override fun onDestroy() {
        scope.cancel()
        server.stop()
        nsdListener?.let { runCatching { (getSystemService(NSD_SERVICE) as NsdManager).unregisterService(it) } }
        AppState.update { it.copy(running = false) }
        super.onDestroy()
    }

    private fun registerNsd() {
        val nsd = getSystemService(NSD_SERVICE) as NsdManager
        val info = NsdServiceInfo().apply {
            serviceName = "ContactSync ${Build.MODEL}"
            serviceType = Protocol.NSD_TYPE
            port = Protocol.PORT
            setAttribute("v", "1")
            Net.addresses().tailscale?.let { setAttribute("ts", it) }
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "NSD registered ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "NSD failed $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l) }
            .onSuccess { nsdListener = l }
            .onFailure { Log.w(TAG, "NSD register threw", it) }
    }

    private fun createChannel() {
        val ch = NotificationChannel(CHANNEL, "Contact sync", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Shows that the Samsung is ready to receive contacts from the iPhone"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_sync)
            .setContentTitle("iPhone contact sync")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    private fun goForeground(text: String) {
        val n = buildNotification(text)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            // Android 12+ can refuse this when it restarts the service by itself in the
            // background. Keep listening anyway; opening the app puts it back in the foreground.
            Log.w(TAG, "could not enter the foreground", e)
        }
    }
}
