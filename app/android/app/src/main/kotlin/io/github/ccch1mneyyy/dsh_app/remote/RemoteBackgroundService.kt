package io.github.ccch1mneyyy.dsh_app.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.runtime.ApproximateBackgroundLocation
import io.github.ccch1mneyyy.dsh_app.runtime.SilentBackgroundAudio

/** Keeps the existing remote transport active in the background, independently of the local engine. */
internal class RemoteBackgroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private val audio = SilentBackgroundAudio()
    private val location = ApproximateBackgroundLocation(this, ::setLocationForeground, ::refreshLocation)

    private val backgroundActive get() = running === this && remoteActive && visibleHosts == 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requested = startPending
        startPending = false
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // Even if the caller disconnected while the start was pending, Android expects promotion.
        try {
            foreground(notification())
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not promote remote service to foreground", e)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        running = this
        if (!requested || !remoteActive) stop()
        else if (visibleHosts == 0) enterBackground()
        return START_NOT_STICKY
    }

    private fun foreground(notification: Notification, location: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
            return
        }
        val baseType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else ServiceInfo.FOREGROUND_SERVICE_TYPE_NONE
        val locationType = if (location) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        startForeground(NOTIFICATION_ID, notification, baseType or locationType)
    }

    private fun setLocationForeground(enabled: Boolean): Boolean = try {
        foreground(notification(), location = enabled)
        true
    } catch (e: RuntimeException) {
        Log.w(TAG, "Could not change remote location foreground type", e)
        false
    }

    private fun enterBackground() {
        acquireWakeLock()
        refreshAudio()
        refreshLocation()
    }

    private fun refreshAudio() {
        if (backgroundActive && audioEnabled) {
            if (!audio.start()) Log.w(TAG, "Remote background audio unavailable")
        } else audio.stop()
    }

    private fun refreshLocation() {
        try {
            if (backgroundActive && locationEnabled && location.hasBackgroundLocation() && location.enabledInSystem) {
                if (!location.start()) Log.w(TAG, "Remote background location unavailable")
            } else location.stop()
        } catch (e: RuntimeException) {
            location.stop()
            Log.w(TAG, "Could not refresh remote background location", e)
        }
    }

    private fun releaseResources(resetLocationType: Boolean) {
        releaseWakeLock()
        audio.stop()
        location.stop(resetForegroundType = resetLocationType)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:remote-background").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not acquire remote wake lock", e)
            stop()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun stop() {
        releaseResources(resetLocationType = false)
        if (running === this) running = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (running === this) stop()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseResources(resetLocationType = false)
        if (running === this) running = null
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, AppStrings.get(this, R.string.remote_background_channel), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) },
        )
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(AppStrings.get(this, R.string.remote_background_channel))
            .setContentText(AppStrings.get(this, R.string.remote_background_notification))
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "DshRemoteBackground"
        private const val CHANNEL_ID = "dsh-remote-background"
        private const val NOTIFICATION_ID = 3092

        // Activity, MethodChannel and Service callbacks all run on the main thread.
        private var remoteActive = false
        private var audioEnabled = false
        private var locationEnabled = false
        private var visibleHosts = 0
        private var startPending = false
        private var running: RemoteBackgroundService? = null

        fun setRemoteActive(context: Context, active: Boolean) {
            if (remoteActive == active) return
            remoteActive = active
            if (active) startIfVisible(context) else running?.stop()
        }

        fun setRemoteAudio(enabled: Boolean) {
            if (audioEnabled == enabled) return
            audioEnabled = enabled
            running?.refreshAudio()
        }

        fun setRemoteLocation(enabled: Boolean) {
            if (locationEnabled == enabled) return
            locationEnabled = enabled
            running?.refreshLocation()
        }

        fun onHostStarted(context: Context) {
            if (++visibleHosts != 1) return
            running?.releaseResources(resetLocationType = true)
            startIfVisible(context)
        }

        fun onHostStopped() {
            if (--visibleHosts != 0 || !remoteActive) return
            running?.enterBackground()
        }

        private fun startIfVisible(context: Context) {
            if (visibleHosts == 0 || !remoteActive || startPending || running != null) return
            try {
                startPending = context.startForegroundService(Intent(context, RemoteBackgroundService::class.java)) != null
            } catch (e: RuntimeException) {
                // A denied start is best-effort; don't try again from the background.
                Log.w(TAG, "Could not start remote foreground service", e)
            }
        }
    }
}
