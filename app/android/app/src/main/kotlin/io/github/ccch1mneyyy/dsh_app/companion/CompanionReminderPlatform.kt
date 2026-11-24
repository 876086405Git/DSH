package io.github.ccch1mneyyy.dsh_app.companion

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.AtomicFile
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.phone.SystemActions
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.util.UUID

/** 主进程只读平台能力；同一安装的任务库由独立原生进程访问。 */
internal object CompanionReminderPlatform {
    @Synchronized
    fun executorId(context: Context): String {
        val directory = context.noBackupFilesDir
        val identity = AtomicFile(File(directory, "companion-reminder-id"))
        // AtomicFile handles a torn write; the separate lock coordinates its two processes.
        RandomAccessFile(File(directory, "companion-reminder-id.lock"), "rw").channel.use { channel ->
            channel.lock().use {
                try {
                    val value = identity.openRead().bufferedReader(Charsets.UTF_8).use { it.readText() }
                    require(UUID.fromString(value).toString() == value) { "Invalid reminder installation identity" }
                    return value
                } catch (_: FileNotFoundException) {
                    val value = UUID.randomUUID().toString()
                    val output = identity.startWrite()
                    try {
                        output.write(value.toByteArray(Charsets.UTF_8))
                        output.fd.sync()
                        identity.finishWrite(output)
                    } catch (error: Exception) {
                        identity.failWrite(output)
                        throw error
                    }
                    // AtomicFile logs some commit failures instead of throwing.
                    check(identity.openRead().bufferedReader(Charsets.UTF_8).use { it.readText() } == value) {
                        "Reminder installation identity was not committed"
                    }
                    return value
                }
            }
        }
    }

    fun capabilities(context: Context): Map<String, Any> {
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(
            SystemActions.CHANNEL_NOTIFY,
            AppStrings.get(context, R.string.phone_reminder_channel),
            NotificationManager.IMPORTANCE_DEFAULT,
        ))
        val channel = notifications.getNotificationChannel(SystemActions.CHANNEL_NOTIFY)
        val appEnabled = notifications.areNotificationsEnabled()
        val channelEnabled = channel != null && channel.importance != NotificationManager.IMPORTANCE_NONE
        val group = channel?.group
        val groupEnabled = Build.VERSION.SDK_INT < 28 || group == null ||
            notifications.getNotificationChannelGroup(group)?.isBlocked != true
        return mapOf(
            "executorId" to executorId(context),
            "notifications" to (appEnabled && channelEnabled && groupEnabled),
            "appNotifications" to appEnabled,
            "channelNotifications" to channelEnabled,
            "groupNotifications" to groupEnabled,
        )
    }
}
