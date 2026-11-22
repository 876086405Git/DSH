package io.github.ccch1mneyyy.dsh_app.companion

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.phone.SystemActions
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity

internal class CompanionReminderAndroid(private val context: Context) : CompanionReminderEffects {
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)

    override fun capabilities(): Map<String, Any> = CompanionReminderPlatform.capabilities(context)

    override fun register(key: ReminderKey, epochMs: Long) {
        alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, epochMs, alarmIntent(key))
    }

    override fun cancel(key: ReminderKey) {
        val pending = alarmIntent(key)
        alarms.cancel(pending)
        pending.cancel()
    }

    private fun alarmIntent(key: ReminderKey): PendingIntent = PendingIntent.getBroadcast(
        context, 0, Intent(context, CompanionReminderReceiver::class.java)
            .setAction(CompanionReminderReceiver.ACTION_ALARM).setData(key.uri("alarm")),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    override fun notify(reminder: StoredReminder) {
        val open = PendingIntent.getActivity(context, 0,
            Intent(context, EntryActivity::class.java).setAction(EntryActivity.ACTION_COMPANION_TASK)
                .setData(reminder.key.uri("open")),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, SystemActions.CHANNEL_NOTIFY)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(AppStrings.get(context, R.string.phone_reminder_channel))
            .setContentText(reminder.text)
            .setStyle(Notification.BigTextStyle().bigText(reminder.text))
            .setContentIntent(open)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .build()
        notifications.notify(reminder.key.notificationTag, 0, notification)
    }

    override fun isActive(key: ReminderKey): Boolean = notifications.activeNotifications.any {
        it.tag == key.notificationTag && it.id == 0
    }
}
