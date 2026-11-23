package io.github.ccch1mneyyy.dsh_app.shortcuts

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.companion.CompanionAssistant
import io.github.ccch1mneyyy.dsh_app.companion.CompanionReminderReceiver
import io.github.ccch1mneyyy.dsh_app.companion.ReminderKey
import io.github.ccch1mneyyy.dsh_app.pet.PetOverlay
import io.github.ccch1mneyyy.dsh_app.pet.PetScreenshot

/**
 * Where the launcher shortcuts (res/xml/shortcuts.xml and the recent conversations) and the
 * Quick Settings tile point: hands the entry to the app's own task as
 * [ShortcutsPlugin.ACTION_ENTRY], stamped with [ShortcutsPlugin.token].
 *
 * Not exported. Launchers start shortcuts as the publishing app and the tile's PendingIntent is
 * ours, so only those reach it; MainActivity is exported (it is the launcher entry), so the
 * token is what tells the plugin an entry really came through here — another app can't open
 * the composer listening on the microphone.
 */
class EntryActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.hasExtra(EXTRA_PET_GENERATION) && !PetOverlay.acceptsOpen(intent.getStringExtra(EXTRA_PET_GENERATION))) {
            // A screenshot nobody will open doesn't wait in the cache for the next one.
            if (intent.action == ACTION_SCREENSHOT) intent.getStringExtra(EXTRA_PATH)?.let { PetScreenshot.discard(this, it) }
            finish()
            return
        }
        val kind = kindOf(intent.action)
        val reminder = if (kind == ShortcutsPlugin.KIND_COMPANION_TASK) {
            if (savedInstanceState != null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
                finish(); return
            }
            ReminderKey.parse(intent.data, "open") ?: run { finish(); return }
        } else null
        val screenshot = if (kind == ShortcutsPlugin.KIND_SCREENSHOT) {
            ScreenshotFiles.validate(cacheDir, intent.getStringExtra(EXTRA_PATH)) ?: run { finish(); return }
        } else null
        if (kind != null || intent.action == ACTION_OPEN_APP) {
            val forward = Intent(this, MainActivity::class.java).apply {
                if (kind != null) {
                    action = ShortcutsPlugin.ACTION_ENTRY
                    putExtra(ShortcutsPlugin.EXTRA_KIND, kind)
                    reminder?.let {
                        putExtra(ShortcutsPlugin.EXTRA_TASK, it.taskId)
                        putExtra(ShortcutsPlugin.EXTRA_TASK_REV, it.revision)
                    }
                    screenshot?.let { putExtra(ShortcutsPlugin.EXTRA_PATH, it.path) }
                    if (kind == ShortcutsPlugin.KIND_COMPANION_ASSISTANT) {
                        putExtra(ShortcutsPlugin.EXTRA_ASSIST_PAGE, intent.getStringExtra(ShortcutsPlugin.EXTRA_ASSIST_PAGE))
                        putExtra(ShortcutsPlugin.EXTRA_ASSIST_RETURN, intent.getBooleanExtra(ShortcutsPlugin.EXTRA_ASSIST_RETURN, false))
                    }
                    intent.getStringExtra(EXTRA_SESSION)?.let { putExtra(ShortcutsPlugin.EXTRA_SESSION, it) }
                    intent.getStringExtra(EXTRA_HOST)?.let { putExtra(ShortcutsPlugin.EXTRA_HOST, it) }
                    // 问一句's text the pet couldn't send: into the composer, unsent. Only from the pet.
                    if (intent.hasExtra(EXTRA_PET_GENERATION)) {
                        intent.getStringExtra(EXTRA_TEXT)?.take(MAX_TEXT)?.let { putExtra(ShortcutsPlugin.EXTRA_TEXT, it) }
                    }
                    putExtra(ShortcutsPlugin.EXTRA_TOKEN, ShortcutsPlugin.token)
                }
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            try {
                startActivity(forward)
                reminder?.let {
                    // This private Activity, reached by our immutable PendingIntent,
                    // records an open. Exported MainActivity extras are not evidence.
                    sendBroadcast(Intent(this, CompanionReminderReceiver::class.java)
                        .setAction(CompanionReminderReceiver.ACTION_OPENED).setData(it.uri("open")))
                }
            } catch (_: Exception) {
            }
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        const val ACTION_NEW_CHAT = "io.github.ccch1mneyyy.dsh_app.action.NEW_CHAT"
        const val ACTION_VOICE = "io.github.ccch1mneyyy.dsh_app.action.VOICE_INPUT"
        const val ACTION_OPEN_CHAT = "io.github.ccch1mneyyy.dsh_app.action.OPEN_CHAT"
        const val ACTION_SCREENSHOT = "io.github.ccch1mneyyy.dsh_app.action.SCREENSHOT"
        const val ACTION_COMPANION_TASK = "io.github.ccch1mneyyy.dsh_app.action.OPEN_COMPANION_TASK"
        private const val ACTION_COMPANION_ASSISTANT = "io.github.ccch1mneyyy.dsh_app.action.COMPANION_ASSISTANT"
        private const val ACTION_OPEN_APP = "io.github.ccch1mneyyy.dsh_app.action.OPEN_APP"
        const val EXTRA_PET_GENERATION = "pet_generation"
        const val EXTRA_SESSION = "session_id"
        const val EXTRA_HOST = "host"
        const val EXTRA_TEXT = "text"
        private const val EXTRA_PATH = "screenshot_path"
        private const val MAX_TEXT = 4_000

        fun kindOf(action: String?): String? = when (action) {
            ACTION_NEW_CHAT -> ShortcutsPlugin.KIND_NEW
            ACTION_VOICE -> ShortcutsPlugin.KIND_VOICE
            ACTION_OPEN_CHAT -> ShortcutsPlugin.KIND_CHAT
            ACTION_SCREENSHOT -> ShortcutsPlugin.KIND_SCREENSHOT
            ACTION_COMPANION_TASK -> ShortcutsPlugin.KIND_COMPANION_TASK
            ACTION_COMPANION_ASSISTANT -> ShortcutsPlugin.KIND_COMPANION_ASSISTANT
            else -> null
        }

        fun newChat(context: Context): Intent = Intent(context, EntryActivity::class.java).setAction(ACTION_NEW_CHAT)

        fun voice(context: Context): Intent = Intent(context, EntryActivity::class.java).setAction(ACTION_VOICE)
        fun companionAssistant(context: Context, page: String? = null, returnToApp: Boolean = false): Intent =
            Intent(context, EntryActivity::class.java).setAction(ACTION_COMPANION_ASSISTANT)
                .putExtra(ShortcutsPlugin.EXTRA_ASSIST_PAGE, CompanionAssistant.stagePage(page))
                .putExtra(ShortcutsPlugin.EXTRA_ASSIST_RETURN, returnToApp)

        fun openApp(context: Context): Intent = Intent(context, EntryActivity::class.java).setAction(ACTION_OPEN_APP)

        fun screenshot(context: Context, path: String): Intent =
            Intent(context, EntryActivity::class.java).setAction(ACTION_SCREENSHOT).putExtra(EXTRA_PATH, path)

        fun openChat(context: Context, sessionId: String, host: String?): Intent =
            Intent(context, EntryActivity::class.java).setAction(ACTION_OPEN_CHAT).apply {
                putExtra(EXTRA_SESSION, sessionId)
                if (host != null) putExtra(EXTRA_HOST, host)
            }
    }
}
