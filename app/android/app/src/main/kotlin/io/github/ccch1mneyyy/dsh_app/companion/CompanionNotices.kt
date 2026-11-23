package io.github.ccch1mneyyy.dsh_app.companion

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.util.Base64

/** Main process, main thread. Nothing here starts an engine or owns a service lease. */
internal class CompanionNotices private constructor(private val app: Context) {
    private val component = ComponentName(app, NoticeListener::class.java)
    private val levels = app.getSharedPreferences("companion_notice_levels", Context.MODE_PRIVATE)
    private val statistics = NoticeStatistics(app)
    private val ids by lazy {
        val prefs = app.getSharedPreferences("companion_notice_ids", Context.MODE_PRIVATE)
        val encoded = prefs.getString("secret", null)
        val key = if (encoded != null) Base64.getDecoder().decode(encoded) else {
            ByteArray(32).also {
                SecureRandom().nextBytes(it)
                prefs.edit().putString("secret", Base64.getEncoder().encodeToString(it)).apply()
            }
        }
        NoticeIds(key)
    }
    private val inbox = NoticeInbox()
    private val posts = NoticePosts()
    private var listener: NoticeListener? = null
    private var retiring: NoticeListener? = null
    private var watching = false
    private var previous: NoticeAccess? = null
    private var epoch = System.currentTimeMillis()
    // Deferred summaries may cross a lock/unlock, but never a consent change or a cold process.
    private var consentEpoch = epoch
    var signal: ((Long) -> Unit)? = null

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = refreshBinding()
    }
    private val grants = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = refreshBinding()
    }

    private fun watch(enabled: Boolean) {
        if (watching == enabled) return
        if (enabled) {
            app.registerReceiver(screen, IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(Intent.ACTION_SCREEN_ON)
            })
            app.contentResolver.registerContentObserver(Settings.Secure.getUriFor(LISTENERS), false, grants)
        } else {
            app.unregisterReceiver(screen)
            app.contentResolver.unregisterContentObserver(grants)
        }
        watching = enabled
    }

    fun access(): NoticeAccess {
        val enabled = app.packageManager.getComponentEnabledSetting(component) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED // manifest default is disabled
        val granted = if (Build.VERSION.SDK_INT >= 27) {
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .isNotificationListenerAccessGranted(component)
        } else {
            Settings.Secure.getString(app.contentResolver, LISTENERS).orEmpty().split(':')
                .any { ComponentName.unflattenFromString(it) == component }
        }
        val keyguard = app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val state = NoticeAccess(enabled, granted, power.isInteractive && !keyguard.isKeyguardLocked && !keyguard.isDeviceLocked)
        val old = previous
        previous = state
        if (old != state) {
            watch(enabled)
            if (!enabled || !granted) {
                inbox.clear()
                posts.clear()
                statistics.clearRecent()
            } else if (!state.unlocked) {
                // Only records that are still on the shade may return. Already consumed versions stay consumed.
                posts.forgetPending(inbox.keys())
                inbox.clear()
            }
            invalidate(consentChanged = old == null || old.enabled != enabled || old.granted != granted)
        }
        return state
    }

    private fun invalidate(consentChanged: Boolean) {
        if (consentChanged) consentEpoch++
        epoch++
        signal?.invoke(epoch)
    }

    fun refreshBinding() {
        val state = access()
        when (noticeBinding(state, listener != null)) {
            NoticeBinding.UNBIND -> {
                val old = listener
                listener = null
                retiring = old
                if (state.granted && state.enabled) old?.requestUnbind()
            }
            NoticeBinding.REBIND -> NotificationListenerService.requestRebind(component)
            NoticeBinding.KEEP -> Unit
        }
    }

    fun connected(service: NoticeListener) {
        listener = service
        retiring = null
        refreshBinding()
        if (listener === service) service.recoverActive()
    }

    fun disconnected(service: NoticeListener) {
        if (listener !== service && retiring !== service) return
        if (listener === service) listener = null
        if (retiring === service) retiring = null
        // An unlock can race the acknowledgement of requestUnbind. Retry at that boundary.
        refreshBinding()
    }

    fun canObserve(service: NoticeListener, pkg: String, key: String, postedMs: Long, replay: Boolean): Boolean {
        if (listener !== service) return false
        val state = access()
        if (!state.open) {
            refreshBinding()
            return false
        }
        val id = ids.digest("key", key)
        val fresh = posts.observe(id, postedMs)
        if (fresh) statistics.observed(pkg, postedMs, replay)
        return state.reads(level(pkg)) && (!replay || !posts.captured(id))
    }

    fun accept(service: NoticeListener, pkg: String, key: String, postedMs: Long, text: String, title: String?) {
        if (listener !== service || !access().reads(level(pkg))) return
        val personId = title?.trim()?.takeIf { it.isNotEmpty() && it != appName(pkg) }
            ?.let { ids.digest("conversation:$pkg", it) }
        val id = ids.digest("key", key)
        val count = posts.markCaptured(id)
        if (inbox.add(pkg, id, System.currentTimeMillis(), postedMs, text, personId)) {
            if (count) statistics.record(received = 1)
            signal?.invoke(epoch)
        }
    }

    private fun level(pkg: String) = levels.getString(pkg, "off")!!

    fun setEnabled(enabled: Boolean) {
        app.packageManager.setComponentEnabledSetting(component, if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        refreshBinding()
        if (enabled && !access().granted) {
            app.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    fun setLevel(pkg: String, level: String) {
        require(pkg.matches(Regex("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*")) && pkg != app.packageName)
        require(level in setOf("off", "glance", "remember"))
        if (this.level(pkg) == level) return
        val edit = levels.edit()
        if (level == "off") edit.remove(pkg) else edit.putString(pkg, level)
        edit.apply()
        inbox.clear(pkg)
        invalidate(consentChanged = true)
    }

    fun status(): Map<String, Any> {
        val state = access()
        return mapOf("enabled" to state.enabled, "granted" to state.granted, "unlocked" to state.unlocked,
            "levels" to levels.all, "epoch" to epoch, "consentEpoch" to consentEpoch) + statistics.status()
    }

    fun pending() = if (access().open) inbox.pending() else emptyList()

    fun take(pkg: String, keys: List<String>, expected: Long): Map<String, Any>? {
        val level = level(pkg)
        if (!access().reads(level) || epoch != expected) return null
        val items = inbox.take(pkg, keys).map {
            mapOf("key" to it.key, "atMs" to it.segments.last().atMs, "segments" to it.segments.map { segment ->
                mapOf("text" to segment.text, "atMs" to segment.atMs, "personId" to segment.personId)
            })
        }
        if (items.isEmpty()) return null
        return mapOf("epoch" to epoch, "consentEpoch" to consentEpoch, "pkg" to pkg, "appName" to appName(pkg), "level" to level, "items" to items)
    }

    fun allows(expected: Long): Boolean = access().open && epoch == expected

    fun record(expected: Long, judged: Int, said: Int): Boolean {
        require(judged in 0..8 && said in 0..1)
        if (!allows(expected)) return false
        statistics.record(judged = judged, said = said)
        return true
    }

    private fun appName(pkg: String): String = try {
        app.packageManager.getApplicationInfo(pkg, 0).loadLabel(app.packageManager).toString()
    } catch (_: PackageManager.NameNotFoundException) {
        pkg // An app can be uninstalled before the retained observation expires.
    }

    private fun icon(pkg: String): ByteArray? = try {
        val drawable = app.packageManager.getApplicationIcon(pkg)
        val bitmap = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, 48, 48)
        drawable.draw(Canvas(bitmap))
        ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    fun recentApps(): List<Map<String, Any?>> {
        if (!access().open) return emptyList()
        return statistics.recent().entries.sortedByDescending { it.value }.map { (pkg, count) ->
            mapOf("pkg" to pkg, "name" to appName(pkg), "count" to count, "icon" to icon(pkg))
        }
    }

    companion object {
        private const val LISTENERS = "enabled_notification_listeners"
        private var instance: CompanionNotices? = null
        fun get(context: Context): CompanionNotices =
            instance ?: CompanionNotices(context.applicationContext).also { instance = it }
    }
}
