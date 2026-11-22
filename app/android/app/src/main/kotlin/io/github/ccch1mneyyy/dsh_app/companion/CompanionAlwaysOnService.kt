package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.app.RemoteInput
import io.github.ccch1mneyyy.dsh_app.DshFlutterEngine
import java.util.UUID

/** A lease on dsh-main, independent of whether the selected Host runs on this phone. */
class CompanionAlwaysOnService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // This feature needs a visible conversation notification. Android itself
        // can run an FGS without POST_NOTIFICATIONS; do not mistake that for
        // permission to show a reply surface, or request permission on restore.
        if (!CompanionAlwaysOnState.read(this).enabled || !CompanionConversationNotification.available(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = CompanionConversationNotification.build(this)
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(CompanionConversationNotification.ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(CompanionConversationNotification.ID, notification)
            }
            running = true
            if (wakeLock == null) {
                wakeLock = getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:companion").also {
                        it.setReferenceCounted(false)
                        it.acquire()
                    }
            }
            // A real RemoteInput is never reconstructed from notification text.
            if (intent?.action == ACTION_REPLY) {
                val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(INPUT)?.toString()
                if (!reply.isNullOrBlank()) {
                    CompanionAlwaysOnPlugin.acceptReply(this, UUID.randomUUID().toString(), reply)
                }
            }
            DshFlutterEngine.getOrCreate(this)
            CompanionAlwaysOnPlugin.statusChanged()
        } catch (error: Throwable) {
            running = false
            CompanionAlwaysOnPlugin.failure = error.javaClass.simpleName
            stopSelf()
        }
        // No input Intent is redelivered. A killed/unknown turn is never auto-submitted again.
        return if (running) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        try {
            CompanionConversationNotification.clear(this) { keepReminder ->
                stopForeground(if (keepReminder) STOP_FOREGROUND_DETACH else STOP_FOREGROUND_REMOVE)
            }
        } catch (_: Exception) {
            // An unreadable display cannot prove there is no task reminder.
            stopForeground(STOP_FOREGROUND_DETACH)
        } finally {
            CompanionAlwaysOnPlugin.statusChanged()
            super.onDestroy()
        }
    }

    companion object {
        const val ACTION_REPLY = "io.github.ccch1mneyyy.dsh_app.COMPANION_REPLY"
        const val INPUT = "companion_reply"
        @Volatile var running = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, CompanionAlwaysOnService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }
    }
}
