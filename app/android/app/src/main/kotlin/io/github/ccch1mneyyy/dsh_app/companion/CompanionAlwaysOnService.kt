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
        // startForegroundService obliges a startForeground call within seconds on
        // every path, including the ones that stop at once; skipping it, or a
        // notification the system rejects, kills the whole app, and the app asks
        // for this service again on every launch. So: satisfy the contract first,
        // and if even that fails, switch the feature off instead of looping.
        if (!startForegroundSafely()) {
            CompanionAlwaysOnState.set(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        // This feature needs a visible conversation notification. Android itself
        // can run an FGS without POST_NOTIFICATIONS; do not mistake that for
        // permission to show a reply surface, or request permission on restore.
        if (!CompanionAlwaysOnState.read(this).enabled || !CompanionConversationNotification.available(this)) {
            // onDestroy's clear keeps a task reminder that shares this display.
            stopSelf()
            return START_NOT_STICKY
        }
        try {
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

    /** The conversation notification, or a plain one when it can't be built. */
    private fun startForegroundSafely(): Boolean {
        return try {
            val notification = try {
                CompanionConversationNotification.build(this)
            } catch (error: Throwable) {
                CompanionAlwaysOnPlugin.failure = error.javaClass.simpleName
                CompanionConversationNotification.fallback(this)
            }
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(CompanionConversationNotification.ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(CompanionConversationNotification.ID, notification)
            }
            true
        } catch (error: Throwable) {
            CompanionAlwaysOnPlugin.failure = error.javaClass.simpleName
            false
        }
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
