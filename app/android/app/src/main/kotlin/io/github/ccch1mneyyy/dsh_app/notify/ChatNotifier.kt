package io.github.ccch1mneyyy.dsh_app.notify

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.theme.ThemeAccent
import java.security.SecureRandom

/**
 * Chat notifications: a turn ended, or the agent waits for an approval or an
 * answer. Flutter decides *whether* to notify (settings, foreground, which conversation is open);
 * this class owns the channels, per-conversation grouping, lock-screen redaction and the tap.
 *
 * Identity: one conversation is one group. Every notification of it carries the tag
 * `dsh-chat|<group>` (group = `<host>|<sessionId>`, built by Flutter) and an id derived from
 * its key (`turn`, or the approval / question event id), so a newer turn replaces the older one
 * and a redelivered request updates in place. With two or more in a group a silent summary
 * (id [SUMMARY_ID]) bundles them.
 *
 * Lock screen: every notification is VISIBILITY_PRIVATE with a public version ("DSH Go · 有一轮完成了"),
 * which Android shows when the person's lock-screen setting hides sensitive content. Posted while
 * the device is locked, the notification itself carries only that public text whatever the
 * setting, and gets its real title and text once the person unlocks (USER_PRESENT), silently.
 *
 * Kept apart from the engine (`dsh-runtime`) and phone-control (`dsh-phone-confirm`) channels.
 */
class ChatNotifier(private val app: Context) {

    /** One notification as Flutter describes it. */
    data class Post(
        val group: String,
        val key: String,
        /** Approval or question: the high-importance, heads-up channel. */
        val attention: Boolean,
        val title: String,
        val text: String,
        /** Lock-screen text ("有一轮完成了"): no session title, no content. */
        val publicText: String,
        val sessionId: String,
        /** `HostRef.encode()` of the host the conversation lives on. */
        val host: String,
        val kind: String,
        val eventId: String?,
        val canApprove: Boolean = false,
        val fullText: String? = null,
    )

    private val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val keyguard = app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    /** Whether notifications can show at all, per channel. Creates the channels first. */
    fun status(): Map<String, Any> {
        ensureChannels()
        val groupBlocked = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            nm.getNotificationChannelGroup(GROUP_ID)?.isBlocked == true
        fun open(id: String) = !groupBlocked &&
            (nm.getNotificationChannel(id)?.importance ?: NotificationManager.IMPORTANCE_DEFAULT) !=
            NotificationManager.IMPORTANCE_NONE
        return mapOf(
            "enabled" to nm.areNotificationsEnabled(),
            "done" to open(CHANNEL_DONE),
            "attention" to open(CHANNEL_ATTENTION),
        )
    }

    fun show(post: Post) = show(post, System.currentTimeMillis())

    private fun show(post: Post, postedAt: Long) {
        ensureChannels()
        val tag = tagOf(post.group)
        val id = idOf(post.key)
        // Redelivery keeps the first decision and the owner of its timeout.
        val processing = post.canApprove && actions[tag to id]?.let {
            it.post.key == post.key && it.decision != null
        } == true
        val channel = if (post.attention) CHANNEL_ATTENTION else CHANNEL_DONE
        val locked = keyguard.isKeyguardLocked
        val public = Notification.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(ThemeAccent.notificationColor(app))
            .setContentTitle(AppStrings.APP_NAME)
            .setContentText(post.publicText)
            .build()
        val (title, text) = when {
            locked -> AppStrings.APP_NAME to post.publicText
            processing -> post.title to AppStrings.get(app, R.string.notify_action_processing)
            else -> post.title to post.text
        }
        val builder = Notification.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(ThemeAccent.notificationColor(app))
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(if (locked || processing) text else post.fullText ?: text))
            .setWhen(postedAt)
            .setShowWhen(true)
            .setAutoCancel(true)
            // Updates (a redelivered request, the unlock reveal) don't buzz again.
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setGroup(tag)
            .setContentIntent(openIntent(post, tag, id))
        if (post.attention) builder.setCategory(Notification.CATEGORY_REMINDER)
        // The floating pet is out and its bubble says 做完了 / 出错了: posted, but no banner, no sound.
        io.github.ccch1mneyyy.dsh_app.pet.ResultSilence.apply(builder, tag, post.attention)
        // Approval buttons, in the approval card's order; not on the lock screen.
        if (!processing) {
            if (post.canApprove) actions[tag to id] = ActionEntry(post, postedAt) else actions.remove(tag to id)
        }
        if (post.canApprove && !locked && !processing) {
            for ((label, decision) in listOf(AppStrings.get(app, R.string.notify_decline) to "rejected", AppStrings.get(app, R.string.notify_allow_once) to "allowed-once")) {
                val action = Notification.Action.Builder(null, label, actionIntent(post, decision))
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) action.setAuthenticationRequired(true)
                builder.addAction(action.build())
            }
        }
        nm.notify(tag, id, builder.build())
        synchronized(deferred) {
            if (locked) deferred[tag to id] = post to postedAt else deferred.remove(tag to id)
        }
        if (locked) watchUnlock()
        summaries[tag] = (if (locked) AppStrings.APP_NAME else post.title) to channel
        // The new child may not be listed yet: count it explicitly.
        updateSummary(tag, children(tag, exclude = id) + 1)
    }

    fun cancel(group: String, key: String) {
        val tag = tagOf(group)
        val id = idOf(key)
        // Answered from its own buttons: the result replaces it (finishAction).
        if (actions[tag to id]?.decision != null) return
        actions.remove(tag to id)
        nm.cancel(tag, id)
        synchronized(deferred) { deferred.remove(tag to id) }
        updateSummary(tag, children(tag, exclude = id))
    }

    fun cancelGroup(group: String) {
        val tag = tagOf(group)
        for (n in nm.activeNotifications) if (n.tag == tag) nm.cancel(tag, n.id)
        actions.keys.removeAll { it.first == tag }
        nm.cancel(tag, SUMMARY_ID)
        summaries.remove(tag)
        synchronized(deferred) { deferred.keys.removeAll { it.first == tag } }
    }

    /** Unlocked: give the notifications posted while locked their real content (no sound). */
    private fun reveal() {
        val pending = synchronized(deferred) { deferred.values.toList().also { deferred.clear() } }
        if (pending.isEmpty()) return
        val active = nm.activeNotifications.map { it.tag to it.id }.toSet()
        for ((post, postedAt) in pending) {
            if ((tagOf(post.group) to idOf(post.key)) in active) show(post, postedAt)
        }
    }

    private fun watchUnlock() {
        if (unlockReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = ChatNotifier(context.applicationContext).reveal()
        }
        unlockReceiver = receiver
        val filter = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= 33) {
            // SystemUI may use its own UID. USER_PRESENT is protected: only the
            // system can send it, so exporting this single-action receiver is safe.
            app.applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            app.applicationContext.registerReceiver(receiver, filter)
        }
    }

    fun cancelAll() {
        for (n in nm.activeNotifications) if (n.tag?.startsWith(TAG_PREFIX) == true) nm.cancel(n.tag, n.id)
        summaries.clear()
        actions.clear()
        synchronized(deferred) { deferred.clear() }
    }

    /** The system page where the person turns DSH's notifications (or one channel) back on. */
    fun settingsIntent(channel: String?): Intent {
        val id = when (channel) {
            "done" -> CHANNEL_DONE
            "attention" -> CHANNEL_ATTENTION
            else -> null
        }
        val intent = if (id != null && nm.areNotificationsEnabled()) {
            ensureChannels()
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_CHANNEL_ID, id)
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
        }
        return intent.putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
    }

    /** Fallback when a ROM has no notification settings page: the app's info page. */
    fun detailsIntent(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))

    /**
     * The tap payload if [intent] came from one of our notifications, else null. Clears it from
     * the intent, so re-attaching the activity (rotation) doesn't route twice.
     */
    fun takeTap(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != ACTION_OPEN) return null
        val ok = intent.getStringExtra(EXTRA_TOKEN) == token()
        val tap = mapOf(
            "sessionId" to intent.getStringExtra(EXTRA_SESSION),
            "host" to intent.getStringExtra(EXTRA_HOST),
            "kind" to intent.getStringExtra(EXTRA_KIND),
            "eventId" to intent.getStringExtra(EXTRA_EVENT),
        )
        intent.action = null
        intent.replaceExtras(Bundle())
        // MainActivity is exported: only intents carrying our secret are taps of ours.
        return if (ok && !(tap["sessionId"] as String?).isNullOrEmpty()) tap else null
    }

    fun ensureChannels() {
        // Refresh localized labels; Android preserves user-controlled channel behavior.
        // An app can't raise a channel's importance once created: the old IMPORTANCE_DEFAULT
        // "一轮结束" channel goes, and the heads-up one lives under a new id.
        nm.deleteNotificationChannel(LEGACY_CHANNEL_DONE)
        nm.createNotificationChannelGroup(NotificationChannelGroup(GROUP_ID, AppStrings.get(app, R.string.notify_group_chats)))
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, AppStrings.get(app, R.string.notify_channel_done), NotificationManager.IMPORTANCE_HIGH).apply {
                description = AppStrings.get(app, R.string.notify_channel_done_description)
                group = GROUP_ID
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ATTENTION, AppStrings.get(app, R.string.notify_channel_attention), NotificationManager.IMPORTANCE_HIGH).apply {
                description = AppStrings.get(app, R.string.notify_channel_attention_description)
                group = GROUP_ID
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    private fun children(tag: String, exclude: Int): Int =
        nm.activeNotifications.count { it.tag == tag && it.id != SUMMARY_ID && it.id != exclude }

    /** Posts, refreshes or removes the group's summary for [count] children. */
    private fun updateSummary(tag: String, count: Int) {
        val (title, channel) = summaries[tag] ?: (null to CHANNEL_DONE)
        if (count < 2 || title == null) {
            nm.cancel(tag, SUMMARY_ID)
            if (count == 0) summaries.remove(tag)
            return
        }
        val public = Notification.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(ThemeAccent.notificationColor(app))
            .setContentTitle(AppStrings.APP_NAME)
            .setContentText(AppStrings.plural(app, R.plurals.notify_reminders, count, count))
            .build()
        val summary = Notification.Builder(app, channel)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(ThemeAccent.notificationColor(app))
            .setContentTitle(if (keyguard.isKeyguardLocked) AppStrings.APP_NAME else title)
            .setContentText(AppStrings.plural(app, R.plurals.notify_reminder_count, count, count))
            .setGroup(tag)
            .setGroupSummary(true)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .build()
        nm.notify(tag, SUMMARY_ID, summary)
    }

    private fun openIntent(post: Post, tag: String, id: Int): PendingIntent =
        sessionIntent(post.sessionId, post.host, post.kind, post.eventId, 31 * tag.hashCode() + id)

    /**
     * A tap that opens [sessionId] on [host], the way a chat notification's does (it carries the
     * secret [takeTap] checks). Full route data distinguishes PendingIntents even when their
     * [requestCode] hashes collide; extras alone do not participate in identity.
     */
    fun sessionIntent(sessionId: String, host: String, kind: String, eventId: String?, requestCode: Int): PendingIntent {
        val intent = Intent(app, MainActivity::class.java)
            .setAction(ACTION_OPEN)
            .setData(Uri.Builder().scheme("dsh-notify").authority("open")
                .appendQueryParameter("host", host)
                .appendQueryParameter("session", sessionId)
                .appendQueryParameter("kind", kind)
                .apply { if (eventId != null) appendQueryParameter("event", eventId) }
                .build())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_TOKEN, token())
            .putExtra(EXTRA_SESSION, sessionId)
            .putExtra(EXTRA_HOST, host)
            .putExtra(EXTRA_KIND, kind)
            .putExtra(EXTRA_EVENT, eventId)
        return PendingIntent.getActivity(app, requestCode, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun actionIntent(post: Post, decision: String): PendingIntent {
        val intent = Intent(app, NotifyActionReceiver::class.java)
            // Unique per button, so no two notifications' buttons share a PendingIntent.
            .setData(Uri.Builder().scheme("dsh-notify").authority("action").appendPath(post.group).appendPath(post.key).appendPath(decision).build())
            .putExtra("group", post.group)
            .putExtra("key", post.key)
            .putExtra("decision", decision)
        return PendingIntent.getBroadcast(app, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /**
     * An approval button was tapped: hand the decision to Flutter, which answers the Host and
     * reports back through [finishAction]. Buttons of a notification posted by an earlier process
     * find no entry and do nothing.
     */
    fun receiveAction(intent: Intent) {
        val group = intent.getStringExtra("group") ?: return
        val key = intent.getStringExtra("key") ?: return
        val decision = intent.getStringExtra("decision") ?: return
        val identity = tagOf(group) to idOf(key)
        val entry = actions[identity] ?: return actionStatus(identity, null, AppStrings.get(app, R.string.notify_action_failed))
        if (entry.decision != null) return
        if (keyguard.isKeyguardLocked) {
            // Before Android 12 a button can't ask for the unlock: post it again without buttons until then.
            show(entry.post, entry.postedAt)
            return
        }
        entry.decision = decision
        actionStatus(identity, entry.post, AppStrings.get(app, R.string.notify_action_processing))
        val sent = NotifyPlugin.dispatchAction(
            mapOf("host" to entry.post.host, "group" to group, "key" to key, "eventId" to entry.post.eventId, "decision" to decision),
        )
        if (!sent) return finishAction(group, key, "failed")
        Handler(Looper.getMainLooper()).postDelayed({ if (actions[identity] === entry) finishAction(group, key, "failed") }, 20_000)
    }

    /** Flutter's answer for a tapped button: `handled`, `gone` (no longer pending) or `failed`. */
    fun finishAction(group: String, key: String, result: String) {
        val identity = tagOf(group) to idOf(key)
        val entry = actions[identity]?.takeIf { it.decision != null } ?: return
        actions.remove(identity)
        val text = when (result) {
            "handled" -> if (entry.decision == "allowed-once") AppStrings.get(app, R.string.notify_action_allowed) else AppStrings.get(app, R.string.notify_action_declined)
            "gone" -> AppStrings.get(app, R.string.notify_action_expired)
            else -> AppStrings.get(app, R.string.notify_action_failed)
        }
        actionStatus(identity, entry.post, text, expire = result == "handled")
    }

    /** Replaces an approval notification with a short, silent status; tapping it opens the conversation. */
    private fun actionStatus(identity: Pair<String, Int>, post: Post?, text: String, expire: Boolean = false) {
        ensureChannels()
        val builder = Notification.Builder(app, CHANNEL_ATTENTION)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(ThemeAccent.notificationColor(app))
            .setContentTitle(if (keyguard.isKeyguardLocked) AppStrings.APP_NAME else post?.title ?: AppStrings.APP_NAME)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup(identity.first)
        // A cold action has no Post; retain the existing notification's route.
        val tap = post?.let { openIntent(it, identity.first, identity.second) }
            ?: nm.activeNotifications.firstOrNull { it.tag == identity.first && it.id == identity.second }
                ?.notification?.contentIntent
        if (tap != null) builder.setContentIntent(tap)
        if (expire) builder.setTimeoutAfter(1_000)
        nm.notify(identity.first, identity.second, builder.build())
    }

    /** Per-install secret proving a launch intent came from our own PendingIntent. */
    private fun token(): String = synchronized(tokenLock) {
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(PREF_TOKEN, null)?.let { return@synchronized it }
        val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
        val fresh = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString(PREF_TOKEN, fresh).apply()
        fresh
    }

    companion object {
        const val CHANNEL_DONE = "dsh-chat-done-2"
        private const val LEGACY_CHANNEL_DONE = "dsh-chat-done"
        const val CHANNEL_ATTENTION = "dsh-chat-attention"
        private const val GROUP_ID = "dsh-chat"
        private const val TAG_PREFIX = "dsh-chat|"
        private const val SUMMARY_ID = 0

        /** An approval notification with buttons; [decision] is set once one was tapped. */
        private class ActionEntry(val post: Post, val postedAt: Long) {
            var decision: String? = null
        }

        /** Approval notifications of this process, by (tag, id). Main thread only. */
        private val actions = HashMap<Pair<String, Int>, ActionEntry>()

        const val ACTION_OPEN = "io.github.ccch1mneyyy.dsh_app.OPEN_SESSION"
        private const val EXTRA_TOKEN = "dsh.notify.token"
        private const val EXTRA_SESSION = "dsh.notify.session"
        private const val EXTRA_HOST = "dsh.notify.host"
        private const val EXTRA_KIND = "dsh.notify.kind"
        private const val EXTRA_EVENT = "dsh.notify.event"
        private const val PREFS = "dsh_notify"
        private const val PREF_TOKEN = "tap_token"
        // The UI notifier and dsh-live worker create different ChatNotifier instances.
        private val tokenLock = Any()

        /**
         * Per group: the conversation title and channel its summary uses (latest child wins).
         * Process-wide, so a new Flutter engine still updates the summaries of the old one.
         */
        private val summaries = HashMap<String, Pair<String, String>>()

        /** Posted while locked, shown redacted: (tag, id) → the post and its time. */
        private val deferred = HashMap<Pair<String, Int>, Pair<Post, Long>>()

        /** Process-wide USER_PRESENT receiver, registered on the first locked post. */
        @Volatile private var unlockReceiver: BroadcastReceiver? = null

        fun tagOf(group: String) = TAG_PREFIX + group

        fun idOf(key: String): Int {
            val h = key.hashCode()
            return if (h == SUMMARY_ID) 1 else h
        }
    }
}
