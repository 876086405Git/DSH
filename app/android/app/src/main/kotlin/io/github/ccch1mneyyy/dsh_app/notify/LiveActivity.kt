package io.github.ccch1mneyyy.dsh_app.notify

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.Settings
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.pet.PetOverlay
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.a11y.IconPainter
import io.github.ccch1mneyyy.dsh_app.phone.a11y.StatusLines
import io.github.ccch1mneyyy.dsh_app.runtime.DshService
import io.github.ccch1mneyyy.dsh_app.runtime.VendorSettings
import io.github.ccch1mneyyy.dsh_app.theme.ThemeAccent

/**
 * The live activity: one ongoing notification (channel [CHANNEL], id [ID]) while DSH works, waits
 * on the person or drives the phone, asking Android 16 to promote it to a Live Update: the status
 * bar chip, the top of the shade, the lock screen. HyperOS 3.1+, ColorOS 16 and MagicOS 10 draw
 * promoted notifications in their islands; HyperOS's focus template rides along where SystemUI
 * takes it ([XiaomiFocus]). vivo's 原子岛 and Samsung's Now Bar take allowlisted apps only (on
 * OriginOS 6 the extras are stripped from anyone else's notification), so nothing here aims at them.
 *
 * Posted only where it is more than one more ongoing notification: promotion allowed for this app
 * (`canPostPromotedNotifications`, Android 16 QPR1+), or HyperOS taking the focus template.
 * Elsewhere — OriginOS 6's QPR0 framework compiles promotion out — nothing is posted.
 *
 * Promotion checks the notification and the `POST_PROMOTED_NOTIFICATIONS` permission, not the
 * target SDK, so targetSdk 28 is no obstacle; [EXTRA_REQUEST_PROMOTED_ONGOING] is spelled out
 * because it is public only from SDK 36.1. Updates run on one background thread, at most one post
 * per [MIN_GAP_MS] (NotificationManager drops bursts); the post is refreshed while it lasts and
 * times out otherwise, so a process that died doesn't leave 「工作中」 behind.
 *
 * Content: [LiveContent]. The agent's part comes from Dart ([update]); phone control's is read
 * here ([PhoneControl.liveTask]) whenever it changes ([refresh]): the app's icon, 「微信 · 点「发送」」,
 * 暂停 / 继续 and 停止, and a tap that goes back to the chat (pausing a task on the person's own
 * screen first, as the floating bar's 回到 DSH Go does).
 *
 * Where the phone's own island shows it ([islandShows]), the floating bar steps aside for it
 * (「用系统灵动岛显示」, ControlOverlay).
 */
object LiveActivity {
    const val CHANNEL = "dsh-live"
    const val ID = 3083

    /** `Notification.EXTRA_REQUEST_PROMOTED_ONGOING` (SDK 36.1). */
    const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"

    private const val PREFS = "dsh_live"
    private const val K_ENABLED = "enabled"
    private const val MIN_GAP_MS = 600L
    private const val REFRESH_MS = 4 * 60_000L
    private const val TIMEOUT_MS = 10 * 60_000L
    private const val ENDING_TIMEOUT_MS = 15_000L
    private const val PORTRAIT_DP = 64
    private const val ISLAND_TTL_MS = 60_000L

    /** Where SystemUI draws promoted notifications in an island: HyperOS 3.1+, ColorOS 16 (OPPO, OnePlus, realme), MagicOS 10. */
    private val ISLAND_VENDORS = setOf(VendorSettings.XIAOMI, VendorSettings.OPPO, VendorSettings.HONOR)

    private val handler: Handler by lazy { Handler(HandlerThread("dsh-live").apply { start() }.looper) }

    @Volatile private var app: Context? = null
    @Volatile private var agent: LiveContent? = null
    @Volatile private var packId: String? = null

    // Live thread only.
    private var shown: LiveContent? = null
    /** Unknown at start: a post of an earlier process may still be up. */
    private var posted = true
    private var postedAt = 0L
    private var phoneTask = 0L
    private var phoneSince = 0L
    private var portraitKey: String? = null
    private var portrait: Bitmap? = null

    /** The app DSH works in and its icon as the island shows it (the floating bar found it; [setPhoneIcon]). */
    @Volatile private var phoneIcon: Pair<String, Bitmap>? = null

    /** Whether the phone's own island shows the live activity; null until checked ([islandShows]). */
    @Volatile private var island: Boolean? = null
    @Volatile private var islandAt = 0L
    @Volatile private var islandChecking = false

    /** Told (on the live thread) when [islandShows] changes. */
    @Volatile var islandListener: (() -> Unit)? = null

    private val applyNow = Runnable { apply() }
    private val repost = Runnable {
        shown = null
        apply()
    }

    /**
     * Dart's part: whether the live activity is on ([enabled], kept for phone control while no
     * engine runs), the pet pack the pictures come from, and what the agent is doing (null: nothing).
     */
    fun update(context: Context, enabled: Boolean, packId: String?, agent: LiveContent?) {
        val ctx = attach(context)
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(K_ENABLED, true) != enabled) prefs.edit().putBoolean(K_ENABLED, enabled).apply()
        this.packId = packId?.takeIf { it.isNotEmpty() && it != "none" }
        this.agent = agent
        refresh(ctx)
    }

    /**
     * A brought pet's files changed (imported again, removed): its cached portrait is stale though
     * its id isn't. Drawn again from the files, and a post showing it is redone. Any thread.
     */
    fun forgetPack(context: Context, pack: String) {
        val ctx = attach(context)
        handler.post {
            if (portraitKey?.startsWith("$pack/") != true) return@post
            portraitKey = null
            portrait = null
            // The post carries the old picture; the same content would not be posted again.
            shown = null
            refresh(ctx)
        }
    }

    /** Something it shows changed: post the latest within [MIN_GAP_MS] of the last post. Any thread. */
    fun refresh(context: Context) {
        attach(context)
        handler.removeCallbacks(applyNow)
        val wait = (postedAt + MIN_GAP_MS - SystemClock.elapsedRealtime()).coerceAtLeast(0)
        handler.postDelayed(applyNow, wait)
    }

    /**
     * What the person's phone offers: `supported` (promotion exists here, or HyperOS takes the
     * focus template), `allowed` (and it is on for this app), `settings` (the system page to turn
     * it on opens). A binder call into SystemUI on HyperOS: call off the main thread.
     */
    fun status(context: Context): Map<String, Any?> {
        val ctx = attach(context)
        val canPost = canPromote(ctx)
        val page = Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA &&
            settingsIntent(ctx).resolveActivity(ctx.packageManager) != null
        val xiaomi = XiaomiFocus.allowed(ctx)
        return mapOf(
            "supported" to (canPost || page || xiaomi),
            "allowed" to (canPost || xiaomi),
            "settings" to page,
            "xiaomiFocus" to xiaomi,
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    /**
     * The phone's own island shows the live activity now: it is on, and either HyperOS takes the
     * focus template, or the system promotes it on a phone whose SystemUI draws promoted
     * notifications in an island ([ISLAND_VENDORS]). Read from a cache any thread may use; checked
     * again on the live thread when stale, [islandListener] hearing a change.
     */
    fun islandShows(context: Context): Boolean {
        val ctx = attach(context)
        if ((island == null || SystemClock.elapsedRealtime() - islandAt > ISLAND_TTL_MS) && !islandChecking) {
            islandChecking = true
            handler.post { checkIsland(ctx) }
        }
        return island == true
    }

    /**
     * For the settings page: `vendor` (this phone has an island the live activity can use) and
     * `shows` (it does now). A binder call into SystemUI on HyperOS: call off the main thread.
     */
    fun islandSupport(context: Context): Map<String, Any?> {
        val ctx = attach(context)
        return mapOf("vendor" to (islandVendor() || XiaomiFocus.allowed(ctx)), "shows" to checkIsland(ctx))
    }

    private fun islandVendor(): Boolean = VendorSettings.vendorOf(Build.MANUFACTURER, Build.BRAND) in ISLAND_VENDORS

    private fun checkIsland(ctx: Context): Boolean {
        val shows = enabled(ctx) && posts(ctx) && (XiaomiFocus.allowed(ctx) || (islandVendor() && canPromote(ctx)))
        islandAt = SystemClock.elapsedRealtime()
        islandChecking = false
        if (island != shows) {
            island = shows
            islandListener?.invoke()
        }
        return shows
    }

    /**
     * The icon of the app DSH works in ([label]), as the floating bar draws it: a rounded square,
     * for the island. Any thread; drawn once per app.
     */
    fun setPhoneIcon(context: Context, label: String, icon: Drawable) {
        if (phoneIcon?.first == label) return
        val ctx = attach(context)
        val px = (PORTRAIT_DP * ctx.resources.displayMetrics.density).toInt().coerceIn(96, 256)
        val bitmap = runCatching {
            Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888).also { b ->
                IconPainter().draw(Canvas(b), icon.constantState?.newDrawable(ctx.resources)?.mutate() ?: icon, px / 2f, px / 2f, px.toFloat(), 1f)
            }
        }.getOrNull() ?: return
        phoneIcon = label to bitmap
        refresh(ctx)
    }

    /** The system page with this app's 「实时活动」 switch (Android 16 QPR1+); check it resolves. */
    @SuppressLint("InlinedApi")
    fun settingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)

    private fun attach(context: Context): Context = context.applicationContext.also { app = it }

    private fun enabled(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(K_ENABLED, true)

    private fun canPromote(ctx: Context): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA &&
        runCatching { nm(ctx).canPostPromotedNotifications() }.getOrDefault(false)

    private fun nm(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /** Notifications are allowed and the live channel is above 最低 (a minimum-importance channel is never promoted to the island). */
    private fun posts(ctx: Context): Boolean = runCatching {
        val nm = nm(ctx)
        nm.areNotificationsEnabled() &&
            (nm.getNotificationChannel(CHANNEL)?.importance ?: NotificationManager.IMPORTANCE_DEFAULT) > NotificationManager.IMPORTANCE_MIN
    }.getOrDefault(false)

    private fun apply() {
        val ctx = app ?: return
        checkIsland(ctx)
        val content = if (enabled(ctx) && (canPromote(ctx) || XiaomiFocus.allowed(ctx))) {
            LiveContent.pick(phoneContent(ctx), agent)
        } else {
            null
        }
        if (content == null) {
            handler.removeCallbacks(repost)
            if (posted) nm(ctx).cancel(ID)
            posted = false
            shown = null
            return
        }
        if (content == shown) return
        runCatching { post(ctx, content) }.onFailure { return }
        posted = true
        shown = content
        postedAt = SystemClock.elapsedRealtime()
        handler.removeCallbacks(repost)
        if (!content.ending) handler.postDelayed(repost, REFRESH_MS)
    }

    private fun phoneContent(ctx: Context): LiveContent? {
        val task = PhoneControl.peek()?.liveTask() ?: return null
        if (task.id != phoneTask) {
            phoneTask = task.id
            phoneSince = System.currentTimeMillis()
        }
        val title = AppStrings.get(ctx, R.string.phone_running)
        // 「微信 · 点「发送」」: the line without its 「DSH 正在操作 · 」, after the app.
        val line = task.line?.let {
            StatusLines(AppStrings.get(ctx, R.string.phone_waived_status), AppStrings.get(ctx, R.string.phone_acting)).parse(it).text
        }
        return LiveContent(
            kind = LiveContent.Kind.PHONE,
            title = title,
            text = listOfNotNull(task.app, line).joinToString(" · "),
            chip = AppStrings.get(ctx, if (task.paused) R.string.live_chip_paused else R.string.live_chip_phone),
            publicText = title,
            sinceMs = phoneSince,
            packId = packId,
            mood = "working",
            phoneTaskId = task.id,
            phonePaused = task.paused,
            iconApp = task.app?.takeIf { it == phoneIcon?.first },
        )
    }

    private fun post(ctx: Context, c: LiveContent) {
        val nm = nm(ctx)
        ensureChannel(ctx, nm)
        val color = ThemeAccent.notificationColor(ctx)
        // Phone control shows the app DSH works in; otherwise the pet doing what the activity says.
        val picture = c.iconApp?.let { app -> phoneIcon?.takeIf { it.first == app }?.second } ?: c.packId?.let { portraitOf(ctx, it, c.mood) }
        val builder = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(color)
            .setContentTitle(c.title)
            .setContentText(c.text.ifEmpty { null })
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(if (c.busy) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion(ctx, c, color))
            .setContentIntent(openIntent(ctx, c))
            .setTimeoutAfter(if (c.ending) ENDING_TIMEOUT_MS else TIMEOUT_MS)
            .addExtras(Bundle().apply { putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true) })
        val since = c.sinceMs
        if (since != null && !c.ending) builder.setWhen(since).setShowWhen(true).setUsesChronometer(true) else builder.setShowWhen(false)
        picture?.let(builder::setLargeIcon)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            builder.setStyle(
                if (c.busy) {
                    Notification.ProgressStyle()
                        .setProgressSegments(listOf(Notification.ProgressStyle.Segment(1).setColor(color)))
                        .setProgressIndeterminate(true)
                } else {
                    Notification.BigTextStyle().bigText(c.text)
                },
            )
            c.chipWords?.let(builder::setShortCriticalText)
        } else if (c.busy) {
            builder.setProgress(0, 0, true)
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(c.text))
        }
        if (c.kind == LiveContent.Kind.PHONE && c.phoneTaskId != null) {
            // 暂停 / 继续 first, as on the floating bar; 停止 after it.
            val pause = PendingIntent.getService(
                ctx, ID + 1, DshService.phonePauseIntent(ctx, c.phoneTaskId, !c.phonePaused),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val pauseLabel = AppStrings.get(ctx, if (c.phonePaused) R.string.live_phone_resume else R.string.live_phone_pause)
            builder.addAction(Notification.Action.Builder(null, pauseLabel, pause).build())
            val stop = PendingIntent.getService(
                ctx, ID, DshService.phoneStopIntent(ctx, c.phoneTaskId),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(Notification.Action.Builder(null, AppStrings.get(ctx, R.string.service_stop_phone), stop).build())
        }
        val icon = picture?.let(Icon::createWithBitmap) ?: Icon.createWithResource(ctx, R.mipmap.ic_launcher)
        XiaomiFocus.apply(ctx, builder, c, icon)
        nm.notify(ID, builder.build())
    }

    /** The lock screen's version when it hides sensitive content: no title, no line. */
    private fun publicVersion(ctx: Context, c: LiveContent, color: Int): Notification {
        val builder = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setColor(color)
            .setContentTitle(AppStrings.APP_NAME)
            .setContentText(c.publicText)
            .setOngoing(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) c.chipWords?.let(builder::setShortCriticalText)
        return builder.build()
    }

    private fun openIntent(ctx: Context, c: LiveContent): PendingIntent {
        // Phone control: 回到 DSH Go, pausing a task on the person's own screen first.
        if (c.kind == LiveContent.Kind.PHONE && c.phoneTaskId != null) {
            return PendingIntent.getService(ctx, ID + 2, DshService.phoneBackIntent(ctx, c.phoneTaskId), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val session = c.sessionId
        val host = c.host
        if (session != null && host != null) return ChatNotifier(ctx).sessionIntent(session, host, "live", c.eventId, ID)
        return PendingIntent.getActivity(
            ctx, ID, Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** The pet doing what the activity says, in the shade and in HyperOS's island. */
    private fun portraitOf(ctx: Context, pack: String, mood: String): Bitmap? {
        val key = "$pack/$mood"
        if (key == portraitKey) return portrait
        val px = (PORTRAIT_DP * ctx.resources.displayMetrics.density).toInt().coerceIn(96, 256)
        portrait = PetOverlay.portrait(pack, mood, px)
        portraitKey = key
        return portrait
    }

    private fun ensureChannel(ctx: Context, nm: NotificationManager) {
        if (nm.getNotificationChannel(CHANNEL) != null) return
        // Default importance keeps its status bar icon where nothing promotes it (HyperOS's focus
        // path); it never makes a sound: an update is not news.
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, AppStrings.get(ctx, R.string.live_channel), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = AppStrings.get(ctx, R.string.live_channel_description)
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }
}
