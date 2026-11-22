package io.github.ccch1mneyyy.dsh_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import io.github.ccch1mneyyy.dsh_app.launch.LaunchScreen
import io.github.ccch1mneyyy.dsh_app.launch.LaunchThemeSync
import io.github.ccch1mneyyy.dsh_app.runtime.AndroidBackgroundProtection
import io.github.ccch1mneyyy.dsh_app.runtime.LaunchStart
import io.github.ccch1mneyyy.dsh_app.text.CachedTextActions
import java.lang.ref.WeakReference
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private var appChannel: MethodChannel? = null

    /** The selection toolbar's text actions, asked of the engine once (see [CachedTextActions]). */
    private var textActions: CachedTextActions? = null

    /**
     * One engine per process, outliving this activity: swiping the app away from recents keeps
     * Dart running, and with it the event subscriptions behind turn-finished / needs-you
     * notifications. Plugins are registered once, with the engine.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine = DshFlutterEngine.getOrCreate(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    /**
     * This activity's own <meta-data> (normal theme, Flutter deep linking off), whichever launcher
     * alias opened it: Flutter reads it for getComponentName(), which is the alias — that has
     * none of it, and is disabled once the user picks another 桌面图标 (icons/).
     */
    override fun getMetaData(): Bundle? =
        packageManager.getActivityInfo(ComponentName(this, MainActivity::class.java), PackageManager.GET_META_DATA).metaData

    override fun onCreate(savedInstanceState: Bundle?) {
        // 「打开 App 时自动启动」: DSH boots while Flutter starts, not after its first frame.
        LaunchStart.onActivityCreate(this)
        // 启动画面: the first activity of a cold start hands the system's launch window to Dart's.
        LaunchScreen.onActivityCreate(this, coldDart = FlutterEngineCache.getInstance().get(ENGINE_ID) == null)
        // Recreated, or reopened from recents: the launch intent is an old notification tap or
        // link that was handled back then. Don't let the plugins route it again.
        if (savedInstanceState != null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) {
            intent.action = Intent.ACTION_MAIN
            intent.replaceExtras(Bundle())
        }
        super.onCreate(savedInstanceState)
        // Fully transparent system bars, no OEM scrim behind the gesture handle.
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.setDecorFitsSystemWindows(false)
        current = WeakReference(this)
        // After LaunchScreen read what this launch's splash showed: the next ones show the icon
        // (and launch screen) chosen now (Android 13+).
        LaunchThemeSync.sync(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // Light / dark: a custom launch screen's plain splash colour (the page's) may change with it.
        LaunchThemeSync.sync(this)
        // The language: other apps' text actions are named in it.
        textActions?.forget()
    }

    override fun onStart() {
        super.onStart()
        AndroidBackgroundProtection.get(this).setAppVisible(true)
    }

    override fun onStop() {
        AndroidBackgroundProtection.get(this).setAppVisible(false)
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundControl.get(applicationContext).restoreKeptChannel()
        inForeground = true
        // Another app may have been changed meanwhile.
        textActions?.forget()
        // Coming back counts as activity: the first frames may not be scheduled yet.
        framesActive = true
        applyRefreshRate()
    }

    /**
     * The window's preferred display mode, from the in-app refresh-rate setting.
     *
     * `preferredDisplayModeId = 0` means "no preference": the system picks, and its own
     * refresh-rate setting and power saving still decide. Apps that never ask stay at 60 or
     * 90 Hz on some 120 Hz phones (OriginOS, HyperOS, ColorOS); once an app does ask, those
     * systems show their per-app switch as an in-app setting – hence the setting in 设置 › 性能.
     *
     * auto: fastest mode while Flutter is producing frames, released after the last one.
     * max: pinned. system: never declared.
     */
    private fun applyRefreshRate() {
        val want = if (refreshMode == "max" || (refreshMode != "system" && framesActive)) {
            @Suppress("DEPRECATION")
            val display = windowManager.defaultDisplay
            val now = display.mode
            display.supportedModes
                .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
                .maxByOrNull { it.refreshRate }
        } else null
        val target = want?.modeId ?: 0
        if (window.attributes.preferredDisplayModeId != target) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = target }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val view = flutterSurfaceView(findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)) ?: return
        if (view !== votedView) {
            votedView = view
            // Coming back from the background, onResume runs before the surface is made again.
            view.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = applyRefreshRate()
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            })
        }
        val surface = view.holder.surface
        if (surface.isValid) surface.setFrameRate(want?.refreshRate ?: 0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
    }

    /** Flutter's SurfaceView, which [applyRefreshRate] also votes on. */
    private var votedView: SurfaceView? = null

    private fun flutterSurfaceView(view: View?): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                flutterSurfaceView(view.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    override fun onPause() {
        inForeground = false
        framesActive = false
        applyRefreshRate()
        super.onPause()
    }

    /** Per activity: the handler acts on this activity, so it goes with it (see [cleanUpFlutterEngine]). */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textActions = CachedTextActions.install(flutterEngine)
        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/app")
        appChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getTimeZoneId" -> result.success(TimeZone.getDefault().id)
                "initializePairingScanner" -> {
                    try {
                        io.github.ccch1mneyyy.dsh_app.mlkit.MlKitRuntime.initialize(applicationContext)
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("scanner_initialization_failed", "The barcode scanner could not be initialized", null)
                    }
                }
                // A browser sign-in finished (a Custom Tab on top of this task): clearing down
                // to this activity closes the tab and shows the app again.
                // 设置 → 性能 → 刷新率: auto | max | system, and whether Flutter is drawing.
                "setRefreshRateMode" -> {
                    when (call.argument<String>("mode")) {
                        "auto", "max", "system" -> refreshMode = call.argument<String>("mode")!!
                    }
                    applyRefreshRate()
                    result.success(null)
                }
                "setFrameActive" -> {
                    framesActive = call.argument<Boolean>("active") ?: framesActive
                    applyRefreshRate()
                    result.success(null)
                }
                "bringToFront" -> {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        appChannel?.setMethodCallHandler(null)
        appChannel = null
        textActions = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Back on the home screen sends the app to the background instead of finishing the activity
    // (Android 12's default for launcher roots): coming back finds it as it was.
    override fun popSystemNavigator(): Boolean = moveTaskToBack(true)

    /** Flutter produced a frame recently (see RefreshRateService): auto mode follows it. */
    private var framesActive = true

    companion object {
        private const val ENGINE_ID = "dsh-main"

        /** 设置 › 性能 › 刷新率; the Flutter side owns the stored choice. */
        private var refreshMode = "auto"

        /** The app is on screen (resumed). */
        @Volatile var inForeground = false
            private set

        /** The activity now, for what needs one later (the splash theme of the next launches). */
        @Volatile var current: WeakReference<MainActivity>? = null
            private set
    }
}
