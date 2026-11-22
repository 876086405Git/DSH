package io.github.ccch1mneyyy.dsh_app.shortcuts

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Launcher shortcuts and the Quick Settings tile: MethodChannel `dsh/shortcuts`.
 *
 * Entries ([EntryActivity] → MainActivity as [ACTION_ENTRY]) are pushed to Dart as `entry`
 * calls, `{kind: new | voice | chat | screenshot | companion_task, sessionId?, host?, text?, path?, taskId?, taskRev?}`, after
 * Dart's `ready` (held until then, like links/LinksPlugin). An entry without this process's
 * [token] is ignored. `text` is
 * 问一句's text the floating pet couldn't send itself (pet/PetOverlay.kt): it waits in the composer.
 *
 * - `setRecent {items: [{id, title, host}]}`: the recent conversations as dynamic shortcuts
 *   (newest first, at most [MAX_RECENT]; an empty list clears them). Pinned copies of a
 *   conversation that is still recent are retitled with it.
 *
 * The two static shortcuts (新对话, 语音输入) are res/xml/shortcuts.xml, on every launcher alias.
 * The recent ones belong to the alias that is the launcher entry now ([LauncherIconPlugin.entry]);
 * a new 桌面图标 moves them over ([rebind]) — the system drops shortcuts of a disabled entry.
 */
class ShortcutsPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private var activity: ActivityPluginBinding? = null
    private var ready = false
    private val pending = ArrayList<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        ready = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                ready = true
                val held = ArrayList(pending)
                pending.clear()
                result.success(true)
                for (event in held) methods.invokeMethod("entry", event)
            }
            "setRecent" -> {
                val items = (call.argument<List<*>>("items") ?: emptyList<Any>()).mapNotNull { raw ->
                    val map = raw as? Map<*, *> ?: return@mapNotNull null
                    val id = map["id"] as? String ?: return@mapNotNull null
                    val title = (map["title"] as? String)?.trim().orEmpty()
                    if (id.isEmpty() || title.isEmpty()) return@mapNotNull null
                    Recent(id, title, map["host"] as? String)
                }
                worker.execute {
                    val ok = publish(items)
                    main.post { result.success(ok) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private class Recent(val sessionId: String, val title: String, val host: String?)

    private fun publish(recents: List<Recent>): Boolean {
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return false
        return try {
            val room = (manager.maxShortcutCountPerActivity - STATIC_SHORTCUTS).coerceIn(0, MAX_RECENT)
            val entry = LauncherIconPlugin.entry(context)
            val shortcuts = recents.take(room).mapIndexed { rank, recent ->
                chat(
                    context,
                    RECENT_PREFIX + recent.sessionId,
                    ShortcutLabels.short(recent.title),
                    ShortcutLabels.long(recent.title),
                    EntryActivity.openChat(context, recent.sessionId, recent.host),
                    rank,
                    entry,
                )
            }
            if (shortcuts.isEmpty()) {
                manager.removeAllDynamicShortcuts()
                true
            } else {
                // Rate-limited while the app is in the background: false, and the next change
                // made in the foreground catches up.
                manager.setDynamicShortcuts(shortcuts)
            }
        } catch (_: Exception) {
            false
        }
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        val launch = binding.activity.intent ?: return
        if (launch.getBooleanExtra(EXTRA_TAKEN, false)) return
        if ((launch.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        if (take(launch)) launch.putExtra(EXTRA_TAKEN, true)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this)
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean = take(intent)

    /** Delivers an entry; false when [intent] isn't one of ours. */
    private fun take(intent: Intent): Boolean {
        if (intent.action != ACTION_ENTRY) return false
        val kind = intent.getStringExtra(EXTRA_KIND) ?: return true
        if (kind == KIND_SCREENSHOT) {
            val event = ScreenshotEntry.event(context.cacheDir, token,
                intent.getStringExtra(EXTRA_TOKEN), intent.getStringExtra(EXTRA_PATH)) ?: return true
            if (ready) methods.invokeMethod("entry", event) else pending += event
            return true
        }
        // Consumed either way: an entry without our token goes nowhere.
        if (intent.getStringExtra(EXTRA_TOKEN) != token) return true
        if (kind == KIND_COMPANION_TASK) {
            val taskId = intent.getStringExtra(EXTRA_TASK)
            val revision = intent.getLongExtra(EXTRA_TASK_REV, 0)
            if (taskId.isNullOrEmpty() || revision < 1) return true
            val event = mapOf("kind" to kind, "taskId" to taskId, "taskRev" to revision)
            if (ready) methods.invokeMethod("entry", event) else pending += event
            return true
        }
        if (kind != KIND_NEW && kind != KIND_VOICE && kind != KIND_CHAT) return true
        val sessionId = intent.getStringExtra(EXTRA_SESSION)
        if (kind == KIND_CHAT && sessionId.isNullOrEmpty()) return true
        val event = mapOf(
            "kind" to kind, "sessionId" to sessionId, "host" to intent.getStringExtra(EXTRA_HOST),
            "text" to intent.getStringExtra(EXTRA_TEXT),
        )
        if (ready) methods.invokeMethod("entry", event) else pending += event
        return true
    }

    companion object {
        const val CHANNEL = "dsh/shortcuts"
        const val ACTION_ENTRY = "io.github.ccch1mneyyy.dsh_app.action.ENTRY"
        const val EXTRA_KIND = "io.github.ccch1mneyyy.dsh_app.entry.KIND"
        const val EXTRA_SESSION = "io.github.ccch1mneyyy.dsh_app.entry.SESSION"
        const val EXTRA_HOST = "io.github.ccch1mneyyy.dsh_app.entry.HOST"
        const val EXTRA_TEXT = "io.github.ccch1mneyyy.dsh_app.entry.TEXT"
        const val EXTRA_PATH = "io.github.ccch1mneyyy.dsh_app.entry.PATH"
        const val EXTRA_TOKEN = "io.github.ccch1mneyyy.dsh_app.entry.TOKEN"
        const val EXTRA_TASK = "io.github.ccch1mneyyy.dsh_app.entry.TASK"
        const val EXTRA_TASK_REV = "io.github.ccch1mneyyy.dsh_app.entry.TASK_REV"
        private const val EXTRA_TAKEN = "io.github.ccch1mneyyy.dsh_app.entry.TAKEN"

        const val KIND_NEW = "new"
        const val KIND_VOICE = "voice"
        const val KIND_CHAT = "chat"
        const val KIND_SCREENSHOT = "screenshot"
        const val KIND_COMPANION_TASK = "companion_task"

        const val MAX_RECENT = 3
        const val RECENT_PREFIX = "chat:"

        /** 新对话 and 语音输入 in res/xml/shortcuts.xml. */
        private const val STATIC_SHORTCUTS = 2

        /** Per process, never leaves it: proves an entry came through [EntryActivity]. */
        val token: String by lazy { UUID.randomUUID().toString() }

        /**
         * ShortcutManager and launcher-entry changes are binder calls: off the main thread, and
         * one at a time (a new 桌面图标 and a new recents list must not interleave).
         */
        internal val worker: ExecutorService =
            Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-shortcuts").apply { isDaemon = true } }

        private fun chat(
            context: Context,
            id: String,
            short: CharSequence,
            long: CharSequence?,
            intent: Intent,
            rank: Int,
            entry: ComponentName?,
        ): ShortcutInfo = ShortcutInfo.Builder(context, id)
            .setShortLabel(short)
            .apply { if (!long.isNullOrEmpty()) setLongLabel(long) }
            .setIcon(Icon.createWithResource(context, R.drawable.ic_shortcut_chat))
            .setIntent(intent)
            .setRank(rank)
            .apply { if (entry != null) setActivity(entry) }
            .build()

        /**
         * Re-publishes the recent conversations under [entry], the launcher alias just switched
         * on (before the old one goes off: the system deletes dynamic shortcuts whose activity is
         * no longer a launcher entry). Pinned copies stay pinned. On [worker].
         */
        fun rebind(context: Context, entry: ComponentName): Boolean {
            val manager = context.getSystemService(ShortcutManager::class.java) ?: return false
            return try {
                val current = manager.dynamicShortcuts
                if (current.isEmpty()) return true
                val moved = current.sortedBy { it.rank }.mapNotNull { old ->
                    val intent = old.intent ?: return@mapNotNull null
                    val short = old.shortLabel ?: return@mapNotNull null
                    chat(context, old.id, short, old.longLabel, intent, old.rank, entry)
                }
                manager.setDynamicShortcuts(moved)
            } catch (_: Exception) {
                false
            }
        }
    }
}
