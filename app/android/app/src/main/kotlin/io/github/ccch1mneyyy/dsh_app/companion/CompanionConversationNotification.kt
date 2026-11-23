package io.github.ccch1mneyyy.dsh_app.companion

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity
import io.github.ccch1mneyyy.dsh_app.phone.CompanionScreenBridge
import io.github.ccch1mneyyy.dsh_app.phone.CompanionScreenPauseReceiver
import io.github.ccch1mneyyy.dsh_app.phone.SystemActions
import java.io.File
import java.io.RandomAccessFile

/** Reads the current system notification across the reminder/main processes.
 * Its bounded display metadata is not a second conversation or delivery ledger. */
internal object CompanionConversationNotification {
    const val ID = 0x434f4d50
    const val CHANNEL = "dsh-companion-conversation"
    private data class Line(val id: String, val text: String, val user: Boolean, val at: Long, val taskUri: String? = null)
    private val lines = mutableListOf<Line>()
    private var name = "Companion"

    fun available(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    @Synchronized
    private fun <T> locked(context: Context, body: () -> T): T {
        val directory = File(context.noBackupFilesDir, "companion-resident").apply { mkdirs() }
        return RandomAccessFile(File(directory, "display.lock"), "rw").use { file ->
            file.channel.lock().use { body() }
        }
    }

    @Suppress("DEPRECATION")
    private fun readDisplay(context: Context, epoch: Long) {
        lines.clear()
        val active = context.getSystemService(NotificationManager::class.java).activeNotifications
            .firstOrNull { it.id == ID && it.tag == null }?.notification ?: return
        val extras = active.extras
        val sameConversation = extras.getLong("companionEpoch", -1) == epoch
        name = extras.getString("companionName") ?: name
        for (row in extras.getParcelableArrayList<Bundle>("companionLines").orEmpty()) {
            val id = row.getString("id") ?: continue
            val text = row.getString("text") ?: continue
            val taskUri = row.getString("taskUri")
            if (!sameConversation && taskUri == null) continue
            lines.add(Line(id, text, row.getBoolean("user"), row.getLong("at"), taskUri))
        }
    }

    fun clear(context: Context, stopService: ((keepReminder: Boolean) -> Unit)? = null) = locked(context) {
        CompanionAlwaysOnState.withValue(context) { state ->
            readDisplay(context, state.epoch)
            lines.removeAll { it.taskUri == null }
            // Service shutdown must not subsequently remove the same ID's
            // task reminders. Keep this decision under the shared display lock.
            val keepReminder = lines.isNotEmpty()
            stopService?.invoke(keepReminder)
            val manager = context.getSystemService(NotificationManager::class.java)
            val resident = state.enabled && CompanionAlwaysOnService.running && stopService == null
            if (resident || keepReminder) {
                manager.notify(ID, render(context, epoch = state.epoch, resident = resident))
            } else manager.cancel(ID)
        }
    }

    fun update(context: Context, epoch: Long, id: String, text: String, speaker: String, user: Boolean,
               quiet: Boolean, taskUri: String? = null): Boolean = locked(context) {
        CompanionAlwaysOnState.withValue(context) { state ->
            if (!state.enabled || state.epoch != epoch || !available(context) || text.isBlank()) return@withValue false
            readDisplay(context, epoch)
            if (speaker.isNotBlank()) name = speaker
            val previous = lines.indexOfFirst { it.id == id }
            val line = Line(id, text, user, if (previous < 0) System.currentTimeMillis() else lines[previous].at, taskUri)
            if (previous < 0) lines.add(line) else lines[previous] = line
            while (lines.size > 8) lines.removeAt(0)
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(ID, render(context, quiet, state.epoch))
            // ReminderRunner records the returned system call and observes
            // activity separately. A stale snapshot must not rewrite that
            // returned call as unknown. Ordinary followups still require shown.
            if (taskUri == null && manager.activeNotifications.none { it.id == ID && it.tag == null &&
                    it.notification.extras.getString("companionMessageId") == id }) {
                throw IllegalStateException("companion_delivery_unknown")
            }
            true
        }
    }

    fun contains(context: Context, id: String): Boolean = locked(context) {
        readDisplay(context, CompanionAlwaysOnState.read(context).epoch)
        lines.any { it.id == id }
    }

    /** A plain resident notification for when the conversation one can't be built. */
    fun fallback(context: Context): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(CHANNEL, "Companion", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(context, CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        return builder.setSmallIcon(R.drawable.ic_stat_dsh).setContentTitle(name).setContentText("Companion is here")
            .setOngoing(true).build()
    }

    fun build(context: Context): Notification = locked(context) {
        val epoch = CompanionAlwaysOnState.read(context).epoch
        readDisplay(context, epoch)
        render(context, epoch = epoch)
    }

    @Suppress("DEPRECATION")
    private fun render(context: Context, quiet: Boolean = true, epoch: Long, resident: Boolean = true): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        // The due reminder retains its existing user-controlled sound/vibration
        // channel even while it shares the resident conversation's display ID.
        val reminder = lines.lastOrNull()?.taskUri != null
        val channel = if (reminder) SystemActions.CHANNEL_NOTIFY else CHANNEL
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channel,
                if (reminder) AppStrings.get(context, R.string.phone_reminder_channel) else "Companion",
                if (reminder) NotificationManager.IMPORTANCE_DEFAULT else NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(context, ID,
            Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("dshgo://open/companion"))
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val reply = PendingIntent.getService(context, ID,
            Intent(context, CompanionAlwaysOnService::class.java)
                .setAction(CompanionAlwaysOnService.ACTION_REPLY),
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0))
        val action = Notification.Action.Builder(android.R.drawable.ic_menu_send, "Reply", reply)
            .addRemoteInput(RemoteInput.Builder(CompanionAlwaysOnService.INPUT).setLabel("Reply").build()).build()
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context)
        builder.setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(name).setContentText(lines.lastOrNull()?.text ?: "Always here")
            .setContentIntent(open).setOngoing(resident).setAutoCancel(!resident).setOnlyAlertOnce(quiet)
            .setCategory(if (reminder) Notification.CATEGORY_REMINDER else Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPriority(if (reminder) Notification.PRIORITY_DEFAULT else Notification.PRIORITY_LOW)
        if (resident) builder.addAction(action)
        if (resident && CompanionScreenBridge.isEnabled(context)) {
            val pause = PendingIntent.getBroadcast(context, ID,
                Intent(context, CompanionScreenPauseReceiver::class.java).setAction(CompanionScreenPauseReceiver.ACTION_PAUSE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Pause screen watching", pause).build())
        }
        lines.lastOrNull { it.taskUri != null }?.taskUri?.let { uri ->
            val task = PendingIntent.getActivity(context, ID,
                Intent(context, EntryActivity::class.java).setAction(EntryActivity.ACTION_COMPANION_TASK)
                    .setData(Uri.parse(uri)), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(android.R.drawable.ic_menu_view, "Open task", task).build())
            if (!resident) builder.setContentIntent(task)
        }
        val locked = context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true
        if (Build.VERSION.SDK_INT >= 24 && !locked) {
            val style = Notification.MessagingStyle("You").setConversationTitle(name)
            for (line in lines) style.addMessage(line.text, line.at, if (line.user) null else name)
            builder.setStyle(style)
        } else if (locked) {
            builder.setContentText("Companion is here")
        }
        val neutral = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context))
            .setSmallIcon(R.drawable.ic_stat_dsh).setContentTitle(name).setContentText("Companion is here").build()
        builder.setPublicVersion(neutral)
        builder.setExtras(Bundle().apply {
            putString("companionMessageId", lines.lastOrNull()?.id)
            putString("companionName", name)
            putLong("companionEpoch", epoch)
            putParcelableArrayList("companionLines", ArrayList(lines.map { line -> Bundle().apply {
                putString("id", line.id); putString("text", line.text); putBoolean("user", line.user)
                putLong("at", line.at); putString("taskUri", line.taskUri)
            }}))
        })
        return builder.build()
    }
}
