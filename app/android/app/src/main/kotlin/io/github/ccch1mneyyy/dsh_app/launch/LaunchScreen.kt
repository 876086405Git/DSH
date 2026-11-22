package io.github.ccch1mneyyy.dsh_app.launch

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.animation.LinearInterpolator
import android.window.SplashScreenView
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIconPlugin
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons
import io.github.ccch1mneyyy.dsh_app.runtime.LaunchStart
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimeController
import java.lang.ref.WeakReference
import java.nio.ByteBuffer
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * 启动画面: the system's launch window hands over to the app's own launch screen
 * (app/lib/launch/launch_state.dart) with nothing to see in between. MethodChannel `dsh/launch`:
 *
 * - `begin` → what the launch window shows, for Dart's first frame: `{active, sdk, systemSplash,
 *   iconPx, icon (RGBA, premultiplied, iconPx × iconPx), background, backgroundBottom, dark,
 *   coldEngine, systemIcon}`. `coldEngine` ([LaunchEngine.cold]): the engine didn't run when this
 *   process's first activity was created, and LaunchStart is starting it now. `systemIcon`: the
 *   system's launch window shows the chosen icon (Android 13+ with its own splash theme in place,
 *   [LaunchThemes]); otherwise it shows the page colour alone and the app brings the icon in.
 *   `icon` is always the chosen 桌面图标's.
 * - native → Dart `systemSplash {icon: [left, top, width, height] | null, removed}` (logical
 *   pixels, from the Flutter view's corner): Android 12+'s splash, now lying over Dart's first
 *   frame, measured. `removed`: its icon was exactly where the first frame drew it, so it is
 *   already gone (no round trip). Otherwise Dart draws its frame to match, then calls
 * - `reveal`: the splash fades out ([FADE_MS]) over that identical frame and is removed; the
 *   answer comes when it is gone.
 * - `mark {name}`: `firstFrame`, `ready`. The launch line goes to the log (logcat and the runtime
 *   log, like the engine's own startup line) once the launch screen is gone ([done]).
 * - `done`: the launch screen is gone; a splash still waiting is removed.
 * - `snapshot` → `begin`'s answer for now, for a preview of the launch screen in settings.
 *
 * Only the first activity of a process that also starts Dart (no cached engine yet) takes part:
 * Dart's first frame is then the launch screen. Later activities keep the system's own exit.
 */
object LaunchScreen {
    private const val TAG = "DshLaunch"

    /** The splash dissolves into the app's frame: unseen when the two match, soft where a vendor's differs. */
    private const val FADE_MS = 160L

    /** Dart never followed up (a crash, a stall): the splash goes anyway. */
    private const val REVEAL_TIMEOUT_MS = 900L

    /** How long `begin` waits for the icon before answering without it. */
    private const val ICON_WAIT_MS = 600L

    /** How long `begin` waits for LaunchStart to decide whether it starts the engine. */
    private const val START_WAIT_MS = 400L

    /** The engine already ran when this process's first activity was created. */
    @Volatile private var engineRunningAtLaunch = false

    /** This launch's splash shows the chosen icon (Android 13+, its own splash theme in place). */
    @Volatile private var systemIcon = false

    private val main = Handler(Looper.getMainLooper())
    private var seen = false
    private var active = false
    private var activity: WeakReference<FlutterActivity>? = null
    private var info: Map<String, Any?> = emptyMap()
    private var icon: FutureTask<ByteArray?>? = null
    private var splash: View? = null
    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private val marks = LinkedHashMap<String, Long>()
    private val processStart: Long? = runCatching { Process.getStartElapsedRealtime() }.getOrNull()

    private val revealTimeout = Runnable {
        splash?.let { view ->
            Log.i(TAG, "splash: no answer from the launch screen, dissolving it")
            splash = null
            fadeOut(view) {}
        }
    }

    /**
     * MainActivity.onCreate, before Flutter's own: [coldDart] when no engine is cached, so this
     * activity starts Dart. Picks up what the launch window shows and starts drawing its icon.
     */
    fun onActivityCreate(activity: FlutterActivity, coldDart: Boolean) {
        if (seen) return
        seen = true
        if (!coldDart) return
        active = true
        this.activity = WeakReference(activity)
        // Before LaunchStart's own start (posted after its device probe): what the app found.
        engineRunningAtLaunch = runCatching {
            RuntimeController.get(activity).phase == RuntimeController.Phase.RUNNING
        }.getOrDefault(false)
        val sdk = Build.VERSION.SDK_INT
        val metrics = activity.resources.displayMetrics
        val iconPx = LaunchGeometry.iconPx(metrics.density)
        // The icon the person chose, whichever way the app was opened (an entry, a shortcut).
        val variant = runCatching { LauncherIconPlugin.current(activity) }.getOrDefault(LauncherIcons.MIST)
        // What this launch's own splash was drawn from (set by an earlier launch, Android 13+).
        val applied = LaunchThemeSync.applied(activity)
        val dark = LaunchThemeSync.dark(activity)
        systemIcon = LaunchThemes.showsIcon(applied, variant)
        val dpi = LaunchGeometry.iconDpi(sdk, metrics.densityDpi)
        val app = activity.applicationContext
        val iconRes = mipmapOf(variant)
        icon = FutureTask { render(app, iconRes, dpi, iconPx) }.also { thread(name = "dsh-launch-icon", isDaemon = true) { it.run() } }
        val splashExit = sdk >= LaunchGeometry.SPLASH_SDK && listenForSplash(activity)
        info = mapOf(
            "active" to true,
            "sdk" to sdk,
            "systemSplash" to splashExit,
            "systemIcon" to systemIcon,
            "iconPx" to iconPx,
            "background" to backgroundOf(activity, applied, dark, top = true),
            "backgroundBottom" to backgroundOf(activity, applied, dark, top = false),
            "dark" to dark,
        )
    }

    /** The launcher icon's own resource for a 桌面图标 [variant] (LauncherIcons.mipmapOf). */
    private fun mipmapOf(variant: String): Int = when (LauncherIcons.mipmapOf(variant)) {
        "ic_launcher_night" -> R.mipmap.ic_launcher_night
        "ic_launcher_frost" -> R.mipmap.ic_launcher_frost
        "ic_launcher_ink" -> R.mipmap.ic_launcher_ink
        else -> R.mipmap.ic_launcher
    }

    /** The colour the launch window lays: a plain splash theme's, else the page's ([top] / bottom of 8–11's gradient). */
    private fun backgroundOf(context: Context, applied: String?, dark: Boolean, top: Boolean): Int = when (applied) {
        LaunchThemes.WHITE, LaunchThemes.BLACK -> LaunchThemes.background(applied, dark)
        else -> context.getColor(if (top) R.color.launch_background_top else R.color.launch_background_bottom)
    }

    /** [res] drawn at [px] square: RGBA, premultiplied (what Flutter's raw rgba8888 expects). */
    private fun render(context: Context, res: Int, dpi: Int, px: Int): ByteArray? = try {
        val drawable = context.resources.getDrawableForDensity(res, dpi, null)
        if (drawable == null || px <= 0) {
            null
        } else {
            val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
            drawable.setBounds(0, 0, px, px)
            drawable.draw(Canvas(bitmap))
            val buffer = ByteBuffer.allocate(bitmap.byteCount)
            bitmap.copyPixelsToBuffer(buffer)
            bitmap.recycle()
            buffer.array()
        }
    } catch (e: Exception) {
        Log.w(TAG, "icon: ${e.javaClass.simpleName}")
        null
    }

    private fun listenForSplash(activity: FlutterActivity): Boolean = try {
        if (Build.VERSION.SDK_INT >= LaunchGeometry.SPLASH_SDK) {
            activity.splashScreen.setOnExitAnimationListener { view -> onSplashExit(view) }
            true
        } else {
            false
        }
    } catch (_: Exception) {
        false
    }

    @RequiresApi(31)
    private fun onSplashExit(view: SplashScreenView) {
        val channel = channel
        if (!active || channel == null) {
            // The launch screen is already gone: the splash dissolves onto the app.
            Log.i(TAG, "splash: handed over after the launch screen, dissolving it")
            fadeOut(view) {}
            return
        }
        splash = view
        main.postDelayed(revealTimeout, REVEAL_TIMEOUT_MS)
        val send = Runnable {
            if (splash !== view) return@Runnable
            if (!systemIcon) {
                // An icon-less splash on the page colour: the first frame under it is the same page.
                Log.i(TAG, "splash: handed to the app, no icon")
                main.removeCallbacks(revealTimeout)
                splash = null
                removeNow(view)
                mark("handedOver")
                channel.invokeMethod("systemSplash", mapOf("icon" to null, "removed" to true))
                return@Runnable
            }
            val (rect, inPlace) = measure(view)
            if (inPlace) {
                // The first frame under it already shows this icon in this square: nothing to
                // redraw, nothing to wait for. Identical pixels, so taking it away can't be seen.
                Log.i(TAG, "splash: handed to the app, icon in place")
                main.removeCallbacks(revealTimeout)
                splash = null
                removeNow(view)
                mark("handedOver")
            } else {
                Log.i(TAG, "splash: handed to the app, icon elsewhere: $rect")
            }
            channel.invokeMethod("systemSplash", mapOf("icon" to rect, "removed" to inPlace))
        }
        if (view.isLaidOut) send.run() else view.post(send)
    }

    /**
     * The splash's icon square (logical, from the Flutter view's corner; null without an icon),
     * and whether it is exactly the square the app's first frame centred it in.
     */
    @RequiresApi(31)
    private fun measure(view: SplashScreenView): Pair<List<Double>?, Boolean> = try {
        val icon = view.iconView
        val host = activity?.get()?.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
            ?: activity?.get()?.findViewById(android.R.id.content)
        if (icon == null || host == null || icon.visibility != View.VISIBLE || icon.width <= 0 || icon.height <= 0) {
            null to false
        } else {
            val at = IntArray(2)
            val origin = IntArray(2)
            icon.getLocationInWindow(at)
            host.getLocationInWindow(origin)
            val rect = LaunchGeometry.relative(
                at[0], at[1], icon.width, icon.height, origin[0], origin[1],
                view.resources.displayMetrics.density,
            )
            val inPlace = LaunchGeometry.inPlace(
                at[0] - origin[0], at[1] - origin[1], icon.width, icon.height,
                host.width, host.height, info["iconPx"] as? Int ?: 0,
            )
            rect to inPlace
        }
    } catch (_: Exception) {
        null to false
    }

    private fun fadeOut(view: View, then: () -> Unit) {
        // The icon may be a SurfaceView (13+), which a parent's alpha doesn't reach.
        val icon = if (Build.VERSION.SDK_INT >= LaunchGeometry.SPLASH_SDK) (view as? SplashScreenView)?.iconView else null
        icon?.animate()?.alpha(0f)?.setDuration(FADE_MS)?.setInterpolator(LinearInterpolator())?.start()
        view.animate()
            .alpha(0f)
            .setDuration(FADE_MS)
            .setInterpolator(LinearInterpolator())
            .withEndAction {
                removeNow(view)
                then()
            }
            .start()
    }

    private fun removeNow(view: View) {
        try {
            if (Build.VERSION.SDK_INT >= LaunchGeometry.SPLASH_SDK && view is SplashScreenView) view.remove()
        } catch (_: Exception) {
        }
        // Removing the splash puts back the bar colours from before Dart set its own.
        activity?.get()?.updateSystemUiOverlays()
    }

    // ── Channel ──

    internal fun attach(context: Context, methods: MethodChannel) {
        appContext = context
        channel = methods
    }

    internal fun detach(methods: MethodChannel) {
        if (channel === methods) channel = null
    }

    internal fun begin(result: MethodChannel.Result) {
        if (!active) {
            result.success(mapOf("active" to false))
            return
        }
        val task = icon
        val base = info
        val context = appContext
        thread(name = "dsh-launch-begin", isDaemon = true) {
            val pixels = try {
                task?.get(ICON_WAIT_MS, TimeUnit.MILLISECONDS)
            } catch (_: Exception) {
                null
            }
            val deadline = SystemClock.elapsedRealtime() + START_WAIT_MS
            while (LaunchStart.decided == null && SystemClock.elapsedRealtime() < deadline) Thread.sleep(10)
            val phaseNow = context?.let { c -> runCatching { RuntimeController.get(c).phase.wire }.getOrNull() }
            val cold = LaunchEngine.cold(engineRunningAtLaunch, LaunchStart.decided, phaseNow)
            main.post { result.success(base + mapOf("icon" to pixels, "coldEngine" to cold)) }
        }
    }

    /** What the launch window shows now (the current 桌面图标's icon, the system's mode): for a preview. */
    internal fun snapshot(context: Context, result: MethodChannel.Result) {
        thread(name = "dsh-launch-preview", isDaemon = true) {
            val map = try {
                val sdk = Build.VERSION.SDK_INT
                val metrics = context.resources.displayMetrics
                val px = LaunchGeometry.iconPx(metrics.density)
                val variant = runCatching { LauncherIconPlugin.current(context) }.getOrDefault(LauncherIcons.MIST)
                val dark = LaunchThemeSync.dark(context)
                val next = if (sdk >= 33) LaunchThemes.next(LaunchThemeSync.custom(context), dark) { variant } else null
                val res = mipmapOf(variant)
                mapOf(
                    "active" to true,
                    "sdk" to sdk,
                    "systemSplash" to false,
                    "systemIcon" to LaunchThemes.showsIcon(next, variant),
                    "iconPx" to px,
                    "icon" to render(context, res, LaunchGeometry.iconDpi(sdk, metrics.densityDpi), px),
                    "background" to backgroundOf(context, next, dark, top = true),
                    "backgroundBottom" to backgroundOf(context, next, dark, top = false),
                    "dark" to dark,
                )
            } catch (_: Exception) {
                null
            }
            main.post { result.success(map) }
        }
    }

    internal fun reveal(result: MethodChannel.Result) {
        main.removeCallbacks(revealTimeout)
        val view = splash
        if (view == null) {
            result.success(false)
            return
        }
        splash = null
        fadeOut(view) {
            mark("handedOver")
            result.success(true)
        }
    }

    internal fun mark(name: String) {
        val at = LaunchGeometry.sinceStart(processStart, SystemClock.elapsedRealtime()) ?: return
        if (marks.containsKey(name)) return
        marks[name] = at
    }

    /** The launch line, once the launch screen is gone (`ready` and a late `handed over` both in). */
    private fun writeLine() {
        val line = LaunchGeometry.line(marks) ?: return
        Log.i(TAG, line)
        appContext?.let { context -> runCatching { RuntimeController.get(context).note(line) } }
    }

    internal fun done() {
        if (active) mark("gone")
        active = false
        main.removeCallbacks(revealTimeout)
        // Still waiting (the app was ready first): it dissolves rather than cuts.
        splash?.let { view ->
            Log.i(TAG, "splash: still up when the launch screen left, dissolving it")
            fadeOut(view) {}
        }
        splash = null
        writeLine()
        icon = null
        activity = null
    }
}

/** `dsh/launch`, see [LaunchScreen]. */
class LaunchPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "dsh/launch").also { it.setMethodCallHandler(this) }
        LaunchScreen.attach(context, methods)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        LaunchScreen.detach(methods)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "begin" -> LaunchScreen.begin(result)
            "snapshot" -> LaunchScreen.snapshot(context, result)
            // The custom launch screen changed: the next launches' splash follows it (13+).
            "syncTheme" -> {
                MainActivity.current?.get()?.let { LaunchThemeSync.sync(it) }
                result.success(null)
            }
            "reveal" -> LaunchScreen.reveal(result)
            "mark" -> {
                call.argument<String>("name")?.let { LaunchScreen.mark(it) }
                result.success(null)
            }
            "done" -> {
                LaunchScreen.done()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
