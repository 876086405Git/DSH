package io.github.ccch1mneyyy.dsh_app.runtime

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl

/** Foreground service that keeps the local DSH process alive in the background. */
class DshService : Service() {

    private val protection by lazy { AndroidBackgroundProtection.get(this) }
    private var locationForeground = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var networkWatch: NetworkAccess.Watch? = null
    private var installSink: RuntimeController.EventSink? = null
    private var installPercent = -1
    private var installUpgrade = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = RuntimeController.get(this)
        when (intent?.action) {
            ACTION_INSTALL -> {
                protection.detach(this)
                controller.clearServiceRecovery()
                // First unpack or an upgrade: keep the process (and the CPU) up until it is done.
                ensureChannel(this)
                installUpgrade = intent.getBooleanExtra("upgrade", false)
                installPercent = -1
                // The last unpack's "ready" / "stopped" is old news now.
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(INSTALL_ALERT_ID)
                foreground(buildInstallNotification(this, installUpgrade, installPercent))
                acquireWakeLock()
                if (installSink == null) {
                    val sink = RuntimeController.EventSink { event ->
                        if (event["type"] == "progress") {
                            val done = (event["done"] as? Number)?.toLong() ?: 0L
                            val total = (event["total"] as? Number)?.toLong() ?: 0L
                            val percent = if (total > 0) (done * 100 / total).toInt().coerceIn(0, 100) else -1
                            if (percent != installPercent) {
                                installPercent = percent
                                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                                nm.notify(NOTIFICATION_ID, buildInstallNotification(this, installUpgrade, percent))
                            }
                        }
                    }
                    installSink = sink
                    controller.addSink(sink)
                }
            }
            ACTION_INSTALL_DONE -> {
                installSink?.let { controller.removeSink(it) }
                installSink = null
                if (controller.phase != RuntimeController.Phase.STARTING && controller.phase != RuntimeController.Phase.RUNNING) {
                    running = false
                    stopForegroundCompat()
                }
                postInstallAlert(this, intent.getBooleanExtra(EXTRA_INSTALL_OK, true))
            }
            ACTION_PHONE_STOP -> {
                // 「停止操作」 on the notification: stop the task it was shown for, keep the engine.
                val taskId = intent.data?.takeIf { it.scheme == PHONE_TASK_SCHEME }?.schemeSpecificPart?.toLongOrNull()
                // l10n:keep agent stop reason
                if (taskId != null) PhoneControl.get(this).stopShownTask("用户在通知里停止", taskId)
            }
            ACTION_STOP -> {
                if (controller.phase != RuntimeController.Phase.INSTALLING) {
                    val expected = if (intent.hasExtra(EXTRA_STOP_GENERATION))
                        intent.getIntExtra(EXTRA_STOP_GENERATION, -1) else null
                    if (controller.stopProcess(expected, intent.getStringExtra(EXTRA_STOP_OWNER))) {
                        protection.detach(this)
                        running = false
                        stopForegroundCompat()
                    }
                }
            }
            ACTION_START, null -> if (controller.prepareServiceStart(recreated = intent == null)) {
                ensureChannel(this)
                val notification = buildNotification(this, controller)
                foreground(notification)
                running = true
                protection.attach(this)
                acquireWakeLock()
                registerNetworkCallback(controller)
                logBackgroundPolicy(controller)
                controller.startProcess()
            }
        }
        // A newer accepted command may still be waiting for onStartCommand, including a no-op stop.
        if (!running && installSink == null) stopSelf(startId)
        return if (running && installSink == null && controller.canRecreateService()) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        protection.detach(this)
        running = false
        installSink?.let { RuntimeController.get(this).removeSink(it) }
        installSink = null
        networkWatch?.let { RuntimeController.get(this).onNetworkWatchStopped(it) }
        networkWatch = null
        networkCallback?.let { callback ->
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            runCatching { cm.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun foreground(notification: Notification, location: Boolean = locationForeground) {
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

    internal fun setLocationForeground(enabled: Boolean): Boolean = runCatching {
        foreground(buildNotification(this, RuntimeController.get(this)), location = enabled)
        locationForeground = enabled
    }.isSuccess

    private fun registerNetworkCallback(controller: RuntimeController) {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val watch = controller.onNetworkWatchStarted()
        networkWatch = watch
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                controller.refreshDns(watch, properties)
            }

            // API 29+: the system cut (or restored) this uid's network, e.g. a vendor background policy.
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
                controller.onNetworkBlocked(watch, blocked, MainActivity.inForeground)
            }
        }
        if (runCatching { cm.registerDefaultNetworkCallback(callback) }.isSuccess) {
            networkCallback = callback
        } else {
            controller.onNetworkWatchStopped(watch)
            networkWatch = null
        }
    }

    private fun logBackgroundPolicy(controller: RuntimeController) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val line = runCatching {
            NetworkAccess.policyLine(
                batteryExempt = pm.isIgnoringBatteryOptimizations(packageName),
                dataSaverStatus = cm.restrictBackgroundStatus,
                notifications = nm.areNotificationsEnabled(),
            )
        }.getOrNull() ?: return
        controller.note(line)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dsh-app:runtime").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }

    companion object {
        const val ACTION_INSTALL = "io.github.ccch1mneyyy.dsh_app.INSTALL"
        const val ACTION_INSTALL_DONE = "io.github.ccch1mneyyy.dsh_app.INSTALL_DONE"
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.STOP"
        const val ACTION_PHONE_STOP = "io.github.ccch1mneyyy.dsh_app.PHONE_STOP"
        private const val PHONE_TASK_SCHEME = "dsh-phone-task"
        private const val EXTRA_STOP_GENERATION = "stopGeneration"
        private const val EXTRA_STOP_OWNER = "stopOwner"

        /** 停止操作 for exactly [taskId]. The id is the intent's data, so every task gets its own
         * PendingIntent: a newer task's button never rewrites the one still on screen. */
        fun phoneStopIntent(context: Context, taskId: Long): Intent = Intent(context, DshService::class.java)
            .setAction(ACTION_PHONE_STOP).setData(Uri.fromParts(PHONE_TASK_SCHEME, taskId.toString(), null))

        /** With [ACTION_INSTALL_DONE]: the unpack finished (true) or stopped. */
        const val EXTRA_INSTALL_OK = "ok"
        private const val CHANNEL_ID = "dsh-runtime"
        private const val NOTIFICATION_ID = 3080
        private const val ALERT_ID = 3081
        private const val ALERT_CHANNEL = "dsh-runtime-alert"
        private const val INSTALL_ALERT_ID = 3082
        private const val INSTALL_CHANNEL = "dsh-runtime-ready"

        private fun openApp(context: Context, id: Int): PendingIntent = PendingIntent.getActivity(
            context, id, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        /** The unpack ended while the app was away: ready, or stopped (see [InstallAlert]). */
        private fun postInstallAlert(context: Context, ok: Boolean) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val alert = InstallAlert.choose(ok, MainActivity.inForeground, nm.areNotificationsEnabled()) ?: return
            nm.createNotificationChannel(
                NotificationChannel(INSTALL_CHANNEL, AppStrings.get(context, R.string.install_alert_channel), NotificationManager.IMPORTANCE_DEFAULT),
            )
            val (title, text) = when (alert) {
                InstallAlert.READY -> R.string.install_ready_title to R.string.install_ready_text
                InstallAlert.FAILED -> R.string.install_failed_title to R.string.install_failed_text
            }
            val notification = Notification.Builder(context, INSTALL_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.get(context, title))
                .setContentText(AppStrings.get(context, text))
                .setContentIntent(openApp(context, INSTALL_ALERT_ID))
                .setAutoCancel(true)
                .build()
            nm.notify(INSTALL_ALERT_ID, notification)
        }

        fun cancelStoppedAlert(context: Context) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(ALERT_ID)
        }

        /** DSH died and won't come back by itself; in the app the failure card says so instead. */
        fun postStoppedAlert(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (MainActivity.inForeground || !nm.areNotificationsEnabled()) return
            nm.createNotificationChannel(NotificationChannel(ALERT_CHANNEL, AppStrings.get(context, R.string.service_stopped_channel), NotificationManager.IMPORTANCE_DEFAULT))
            val open = PendingIntent.getActivity(
                context, ALERT_ID, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notification = Notification.Builder(context, ALERT_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.get(context, R.string.service_stopped_title))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            nm.notify(ALERT_ID, notification)
        }

        /** Unpacking the runtime: progress, no 停止 (an interrupted unpack only starts over). */
        private fun buildInstallNotification(context: Context, upgrade: Boolean, percent: Int): Notification =
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.APP_NAME)
                .setContentText(if (upgrade) AppStrings.get(context, R.string.service_updating) else AppStrings.get(context, R.string.service_preparing))
                .setProgress(100, percent.coerceAtLeast(0), percent < 0)
                .setContentIntent(openApp(context, NOTIFICATION_ID))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()

        private val notificationMain = Handler(Looper.getMainLooper())
        @Volatile private var running = false

        /**
         * A line about the voice model download (texts come from Dart, in the app's language): shown
         * instead of the engine line, with a bar when [voiceProgress] is 0..100 (-1: indeterminate).
         */
        @Volatile private var voiceLine: String? = null
        @Volatile private var voiceProgress: Int? = null

        /** Sets (or with null [text] clears) the voice model line and redraws the notification. */
        fun setVoiceLine(context: Context, text: String?, progress: Int?) {
            voiceLine = text?.take(120)
            voiceProgress = if (text == null) null else progress?.coerceIn(-1, 100)
            updateNotification(context)
        }

        /** The service is in the foreground (so the controller may start DSH directly). */
        val isRunning: Boolean get() = running

        fun updateNotification(context: Context) {
            if (!running) return
            // Build and publish with Service start/stop on the main looper, without an old snapshot.
            if (Looper.myLooper() != Looper.getMainLooper()) {
                val app = context.applicationContext
                notificationMain.post { updateNotification(app) }
                return
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(context, RuntimeController.get(context)))
        }

        fun stopSelfIfRunning(context: Context, generation: Int, owner: String) {
            if (running) context.startService(Intent(context, DshService::class.java).setAction(ACTION_STOP)
                .putExtra(EXTRA_STOP_GENERATION, generation)
                .putExtra(EXTRA_STOP_OWNER, owner))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, AppStrings.get(context, R.string.service_channel), NotificationManager.IMPORTANCE_LOW).apply {
                    description = AppStrings.get(context, R.string.service_channel_description)
                    setShowBadge(false)
                },
            )
        }

        private fun buildNotification(context: Context, controller: RuntimeController): Notification {
            val text = when (controller.phase) {
                RuntimeController.Phase.STARTING -> if (controller.safeRun) AppStrings.get(context, R.string.service_starting_safe) else AppStrings.get(context, R.string.service_starting)
                RuntimeController.Phase.RUNNING -> if (controller.safeRun) AppStrings.get(context, R.string.service_running_safe) else AppStrings.get(context, R.string.service_running)
                RuntimeController.Phase.STOPPING -> AppStrings.get(context, R.string.service_stopping)
                else -> AppStrings.get(context, R.string.service_title)
            }
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val stop = PendingIntent.getService(
                context, 1, Intent(context, DshService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(context)
            }
            // While DSH operates the phone: say what it does and offer 停止操作 for that task.
            val phone = PhoneControl.peek()
            val phoneTask = phone?.liveTask()
            val phoneLine = phoneTask?.let { phone?.foregroundLine(it) }
            if (phoneTask != null) {
                val stopPhone = PendingIntent.getService(
                    context, 2, phoneStopIntent(context, phoneTask.id),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                builder.addAction(Notification.Action.Builder(null, AppStrings.get(context, R.string.service_stop_phone), stopPhone).build())
            }
            // Phone control speaks first; then a voice model download (with its bar).
            val voice = if (phoneLine == null) voiceLine else null
            val progress = voiceProgress
            if (voice != null && progress != null) builder.setProgress(100, progress.coerceAtLeast(0), progress < 0)
            if (voice != null) builder.setOnlyAlertOnce(true)
            return builder
                .setSmallIcon(R.drawable.ic_stat_dsh)
                .setContentTitle(AppStrings.APP_NAME)
                .setContentText(phoneLine ?: voice ?: text)
                .setOngoing(true)
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null, AppStrings.get(context, R.string.service_stop), stop).build())
                .build()
        }
    }
}
