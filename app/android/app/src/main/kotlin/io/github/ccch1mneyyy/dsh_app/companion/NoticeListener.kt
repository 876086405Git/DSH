package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Notification
import android.os.Process
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/** Android binds this component independently of the cached Flutter engine and the residency switch. */
class NoticeListener : NotificationListenerService() {
    private val notices get() = CompanionNotices.get(this)

    override fun onListenerConnected() {
        super.onListenerConnected()
        notices.connected(this)
    }

    internal fun recoverActive() {
        // activeNotifications is only valid after onListenerConnected. Both the snapshot and each
        // individual record are gated because permission/keyguard can change between them.
        if (!notices.access().open) return
        try {
            activeNotifications?.sortedBy { it.postTime }?.forEach { read(it, replay = true) }
        } catch (_: SecurityException) {
            notices.refreshBinding()
            Log.w("CompanionNotices", "Notification access changed during reconnect")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) = read(sbn, replay = false)

    private fun read(sbn: StatusBarNotification, replay: Boolean) {
        if (sbn.user != Process.myUserHandle() || sbn.packageName == packageName) return
        val pkg = sbn.packageName
        if (!notices.canObserve(this, pkg, sbn.key, sbn.postTime, replay)) return
        val notification = sbn.notification
        if (!NoticeFilter.acceptsCategory(notification.category, sbn.isOngoing,
                notification.flags and Notification.FLAG_FOREGROUND_SERVICE != 0)) return
        try {
            val extras = notification.extras ?: return
            if (extras.getInt(Notification.EXTRA_PROGRESS_MAX) > 0 ||
                extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE) ||
                extras.containsKey(Notification.EXTRA_MEDIA_SESSION) ||
                extras.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN) ||
                notification.category == null && extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)) return
            val fields = mutableListOf<CharSequence>()
            for (field in listOf(Notification.EXTRA_TITLE, Notification.EXTRA_TITLE_BIG, Notification.EXTRA_TEXT,
                    Notification.EXTRA_BIG_TEXT, Notification.EXTRA_SUB_TEXT, Notification.EXTRA_SUMMARY_TEXT,
                    Notification.EXTRA_INFO_TEXT)) {
                extras.getCharSequence(field)?.let(fields::add)
            }
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.let { fields.addAll(it) }
            val segment = NoticeFilter.segment(fields) ?: return
            notices.accept(this, pkg, sbn.key, sbn.postTime, segment, extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
        } catch (e: RuntimeException) {
            // Bundle data comes from another package. Never expose a malformed value in diagnostic logs.
            Log.w("CompanionNotices", "Skipped malformed notification: " + e.javaClass.simpleName)
        }
    }

    override fun onListenerDisconnected() {
        notices.disconnected(this)
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        notices.disconnected(this)
        super.onDestroy()
    }
}
