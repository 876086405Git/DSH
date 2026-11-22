package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.github.ccch1mneyyy.dsh_app.performance.DevicePerformance
import io.github.ccch1mneyyy.dsh_app.performance.DeviceProfile
import io.github.ccch1mneyyy.dsh_app.performance.PerformancePolicy
import kotlin.concurrent.thread

/**
 * 「打开 App 时自动启动」 as soon as the activity is created. The app root (RootGate,
 * app/lib/ui/shell/root_gate.dart) asks for the same start once Flutter is up, settings and the
 * runtime status have loaded and the first frame is out: about half a second later on an
 * emulator, more on a phone. Starting here boots DSH alongside Flutter; RootGate's own start()
 * then finds the engine starting and changes nothing.
 */
object LaunchStart {
    /** Flutter's shared_preferences store and its keys (app/lib/state/settings_state.dart). */
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val K_PHONE_STORAGE = "flutter.phone_storage"
    private const val K_VISUAL_REPLIES = "flutter.visual_replies"

    @Volatile private var tried = false

    /**
     * This process's own start of the engine: true once it asked for one, false when the rule said
     * no (or it failed); null before it has decided. The launch screen reads it
     * (launch/LaunchScreen.kt): a start under way is a cold start, worth covering.
     */
    @Volatile var decided: Boolean? = null
        private set

    /**
     * RootGate's rule: the setting is on, the runtime is installed and idle, and the failure card
     * is not waiting for the user (EngineControl.shouldAutoStart: two failures in a row with
     * automatic safe mode off).
     */
    fun shouldStart(autoStart: Boolean, phase: String?, safeState: String?, autoSafe: Boolean, strikes: Int): Boolean =
        autoStart && phase == RuntimeController.Phase.INSTALLED.wire &&
            !(safeState == SafeState.OFF.wire && !autoSafe && strikes >= 2)

    /** Once per process: a recreated activity, or one reopened later, leaves the engine to the user. */
    fun onActivityCreate(context: Context) {
        if (tried) return
        tried = true
        val app = context.applicationContext
        // The first device probe includes sysfs. Start it beside Flutter, never on the UI thread.
        thread(name = "dsh-launch-policy", isDaemon = true) {
            val profile = runCatching { DevicePerformance.read(app) }.getOrDefault(DeviceProfile())
            Handler(Looper.getMainLooper()).post { startIfAllowed(app, profile) }
        }
    }

    private fun startIfAllowed(context: Context, profile: DeviceProfile) {
        try {
            val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            val controller = RuntimeController.get(context)
            if (!controller.shouldAutoStart(PerformancePolicy.autoStart(context, profile))) {
                decided = false
                return
            }
            // The same call RootGate makes (runtime_state.dart start()): no env, the current mode.
            controller.start(
                emptyMap(),
                phoneStorage = prefs.getBoolean(K_PHONE_STORAGE, false),
                mode = null,
                visualReplies = prefs.getBoolean(K_VISUAL_REPLIES, true),
            )
            decided = true
        } catch (_: Exception) {
            // RootGate starts it a moment later.
            decided = false
        }
    }
}
