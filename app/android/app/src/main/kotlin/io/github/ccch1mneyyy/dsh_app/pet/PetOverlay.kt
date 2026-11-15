package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.Manifest
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Choreographer
import android.view.Display
import android.view.Gravity
import android.view.Surface
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.PathInterpolator
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.nativemedia.MicArbiter
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.a11y.PhoneA11yService
import io.github.ccch1mneyyy.dsh_app.runtime.DshService
import io.github.ccch1mneyyy.dsh_app.runtime.RuntimeController
import io.github.ccch1mneyyy.dsh_app.shortcuts.EntryActivity
import io.github.ccch1mneyyy.dsh_app.voice.WavRecorder
import java.util.Calendar
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.random.Random

/**
 * The out-of-app pet (docs/design/pets.md): a window the size of the pack's wide hit
 * box (grown around the lifted pose while held, and around an animation that reaches past it while
 * that shows, [PetFrames]), a separate bubble window (with a
 * request's answers on it), a long-press menu, 问一句's input bar, and a 「×」 target while
 * dragging. Dart pushes the reduced state ([push]) and does what the bar and the bubble ask
 * ([Listener.call]); when it shows is [OverlayMachine]'s call, the permission branches
 * [OverlayAccess]'s, the dock [EdgeSnap]'s, what plays [PetPlayer]'s.
 *
 * Window type: TYPE_ACCESSIBILITY_OVERLAY through the phone-control accessibility service when it
 * is on (no other permission), else TYPE_APPLICATION_OVERLAY with 「显示在其他应用上层」. Whether
 * that works is decided by adding the window, not by `canDrawOverlays` (vendor switches).
 *
 * Process-wide, main thread only. [init] comes from [PetOverlayPlugin] with the engine.
 */
internal object PetOverlay {
    interface Listener {
        fun onStatus(status: Map<String, Any?>)
        fun onOpenSettings()

        /** Asks Dart [method] (问一句, an answer, 停止, …); [reply] gets null when Dart can't answer. */
        fun call(method: String, args: Any?, reply: (Any?) -> Unit)
    }

    private const val TAG = "DshPet"
    private const val PREFS = "dsh_pet_overlay"
    private const val K_ENABLED = "enabled"
    private const val K_ALWAYS = "alwaysShow"
    private const val K_SNOOZE = "snoozedUntil"
    private const val K_TAP_HINTS = "tapHints"
    private const val TAP_HINTS = 3
    private const val K_SIDE = "dockSide"
    private const val K_Y = "dockY"
    private const val EDGE_DP = 8f
    private const val POLL_MS = 2_000L
    private const val OPEN_CHECK_MS = 1_500L
    private const val MENU_MS = 8_000L
    private const val TARGET_DP = 56f
    private const val TARGET_GAP_DP = 28f
    private const val CHANNEL_OPEN = "dsh-pet-open"
    private const val NOTICE_ID = 3091
    /** An answer key takes touches this long after its bubble shows (as phone control's prompt). */
    private const val ARM_MS = 600L
    /** 问一句's bar: as wide as there is room beside the pet, within these. */
    private const val ASK_MIN_DP = 240f
    private const val ASK_MAX_DP = 360f
    /** Less than this much recording is nothing heard (the composer's rule, 0.3 s at 16 kHz). */
    private const val MIN_WAV_BYTES = 44 + 9_600
    /** A recording held this long without the system silencing it is a real one. */
    private const val SILENCE_CHECK_MS = 400L

    private lateinit var app: Context
    private lateinit var prefs: SharedPreferences
    private lateinit var sprites: PetSprites
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "dsh-pet").apply { isDaemon = true } }
    private var initialized = false

    val machine = OverlayMachine()
    private var listener: Listener? = null
    private val producer = OverlayProducerOwner()

    /**
     * The pet is on screen, lit, not hidden by the system, with bubbles on: 「做完了」「出错了」
     * notifications go silent meanwhile (notify/ChatNotifier.kt), the bubble says it.
     */
    @Volatile var speaksForResults = false
        private set

    // ---- permission bookkeeping ----
    private var lastAdd: AddResult? = null
    private var failedAt = 0L
    private var lastCanDraw: Boolean? = null
    private val accessibilityRetry = AccessibilityOverlayRetry()

    // ---- pack ----
    private var loaded: PetSprites.Loaded? = null
    private var loadedKey: String? = null
    private var loadingKey: String? = null
    private var loadRequest = 0L
    private val failedIds = HashSet<String>()

    // ---- windows ----
    private val windows = OverlayWindowOwner()
    private val windowTickets = IdentityHashMap<View, OverlayWindowOwner.Ticket>()
    private var petTicket: OverlayWindowOwner.Ticket? = null
    private var host = OverlayHost.NONE
    private var hostContext: Context? = null
    private var appWindowContext: Context? = null
    private var wm: WindowManager? = null
    private var petView: PetView? = null
    private var petParams: WindowManager.LayoutParams? = null
    private var systemShown = true
    private var companionEndpoint: CompanionFloatEndpoint? = null
    private var companionView: CompanionFloatView? = null
    private var companionEpoch = 0L
    private val companionRecovery = CompanionFloatRecovery()
    private var companionProblem: String? = null
    private var companionNotice: String? = null
    private var bubbleView: BubbleView? = null
    private var bubbleId: String? = null
    private var menuView: PetMenuView? = null
    private var closingMenu: PetMenuView? = null
    private val capture = PetCaptureState()
    private var target: DismissTargetView? = null
    private var targetCenter: WindowPos? = null
    private var dock = Dock.DEFAULT
    private var dimmed = false
    private var dragStart: WindowPos? = null
    /** Where the finger puts the rest frame, kept on screen as before the window grew: release and 「×」 read it. */
    private var dropAt: WindowPos? = null
    private var dragging = false
    private var slideAnim: ValueAnimator? = null
    private var lastVisibility = Visibility.HIDDEN
    private var lastWhy = ""

    // ---- animation ----
    private val player = PetPlayer()
    private var stateKey: String? = null
    private var looping = false

    // ---- app state ----
    private var started = 0
    private var pendingSettings = false
    private var lastStatus: Map<String, Any?>? = null
    private var lastConfig: Configuration? = null
    private var openPendingIntent: PendingIntent? = null

    fun init(context: Context, assetPath: (String) -> String) {
        if (initialized) return
        initialized = true
        app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        askDraft = prefs.getString("ask_draft", "").orEmpty()
        sprites = PetSprites(app, assetPath)
        machine.enabled = prefs.getBoolean(K_ENABLED, false)
        machine.alwaysShow = prefs.getBoolean(K_ALWAYS, false)
        machine.snoozedUntil = prefs.getLong(K_SNOOZE, 0L)
        dock = Dock(
            if (prefs.getString(K_SIDE, null) == "left") Side.LEFT else Side.RIGHT,
            prefs.getFloat(K_Y, Dock.DEFAULT.yFraction),
        )
        if (MainActivity.inForeground) started = 1
        (app as? Application)?.registerActivityLifecycleCallbacks(lifecycle)
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED) else app.registerReceiver(screen, filter)
        lastConfig = Configuration(app.resources.configuration)
        app.registerComponentCallbacks(config)
        RuntimeController.get(app).addSink { event -> if (event["type"] == "status") main.postDelayed(evaluateRunnable, 300) }
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) PetOverlayProbe.register(app)
        machine.onForeground(started > 0, now())
    }

    // ---- from Dart ------------------------------------------------------------------------------

    fun attachProducer(nextListener: Listener): Long {
        val token = producer.attach()
        resetProducer()
        listener = nextListener
        lastStatus = null
        return token
    }

    fun ownsProducer(token: Long) = producer.owns(token)

    fun detachProducer(token: Long) {
        if (!producer.detach(token)) return
        listener = null
        resetProducer()
    }

    private fun resetProducer() {
        capture.invalidate()
        loadRequest++
        loadingKey = null
        pendingSettings = false
        pendingVoice = false
        returnAsk = false
        voiceHandoff++
        answerState.reset()
        askDraftState.resetProducer()
        machine.resetProducer()
        companionEndpoint = null
        companionRecovery.select(null)
        companionProblem = null
        companionNotice = null
        removeWindows()
        evaluate()
    }

    /** [PetSprites.portrait] of the pack [id]; null before [init] or when it has none. Any thread. */
    fun portrait(id: String, state: String, px: Int): Bitmap? = if (initialized) sprites.portrait(id, state, px) else null

    fun push(args: Map<*, *>) {
        if (!initialized) return
        val p = PetPush.fromMap(args, now())
        machine.onPush(p, now())
        p.packId?.let { ensurePack(it, p.size) }
        retarget()
        evaluate()
    }

    /**
     * A brought pet's files changed (imported again, removed): what was read of [id] is stale even
     * though its id and size are not. Read it again if it is the one out. If it isn't (不显示,
     * another pet), what is kept or still loading of it goes, so choosing it again reads it fresh.
     */
    fun reloadPack(id: String) {
        if (!initialized) return
        failedIds -= id
        val out = machine.last?.takeIf { it.packId == id }
        if (out != null) return ensurePack(id, out.size, reload = true)
        if (loadingKey?.startsWith("$id@") == true) {
            loadRequest++
            loadingKey = null
        }
        if (loadedKey?.startsWith("$id@") != true) return
        loaded?.release()
        loaded = null
        loadedKey = null
        stateKey = null
        if (petView != null) removeWindows()
        evaluate()
    }

    /** The Dart server has already checked the local pack. Null returns to the original renderer. */
    fun configureCompanion(url: String?, notice: String?): Boolean {
        val endpoint = if (url == null) null else CompanionFloatEndpoint.parse(url) ?: return false
        val message = PetPush.clean(notice, 200)
        if (endpoint != null && message == null) return false
        companionNotice = message
        if (endpoint?.page == companionEndpoint?.page) return true
        companionEndpoint = endpoint
        companionRecovery.select(endpoint?.page)
        companionProblem = null
        removeWindows()
        evaluate()
        return true
    }

    fun setEnabled(on: Boolean): Map<String, Any?> {
        if (!on) capture.invalidate()
        machine.enabled = on
        prefs.edit().putBoolean(K_ENABLED, on).apply()
        if (on) {
            failedIds.clear()
            machine.last?.let { p -> p.packId?.let { ensurePack(it, p.size) } }
        }
        evaluate()
        return status()
    }

    fun setAlwaysShow(on: Boolean): Map<String, Any?> {
        machine.alwaysShow = on
        prefs.edit().putBoolean(K_ALWAYS, on).apply()
        evaluate()
        return status()
    }

    fun unsnooze(): Map<String, Any?> {
        machine.snoozedUntil = 0L
        prefs.edit().putLong(K_SNOOZE, 0L).apply()
        evaluate()
        return status()
    }

    /** Status after a real check: adds (and removes) an invisible window unless the pet's own proves it. */
    fun permissionStatus(): Map<String, Any?> {
        refreshCanDraw()
        if (!a11yConnected() && !(host == OverlayHost.APPLICATION && petView?.isAttachedToWindow == true)) probe()
        evaluate()
        return status()
    }

    fun status(): Map<String, Any?> {
        val canDraw = canDraw()
        val a11y = a11yConnected()
        return mapOf(
            "enabled" to machine.enabled,
            "alwaysShow" to machine.alwaysShow,
            "permission" to OverlayAccess.permission(a11y, canDraw, lastAdd).wire,
            "canDraw" to canDraw,
            "accessibility" to a11y,
            "snoozed" to machine.snoozed(now()),
            "showing" to (petView?.isAttachedToWindow == true && !capture.inFlight),
            "sdk" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
        ) + if (companionEndpoint == null) emptyMap() else mapOf(
            "companionRendering" to (companionView != null),
            "companionFallback" to companionRecovery.fallback,
            "companionProblem" to companionProblem,
        )
    }

    /** 「今天不再显示」: hidden until local midnight. */
    fun snoozeToday() {
        capture.invalidate()
        val c = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        machine.snoozedUntil = c.timeInMillis
        prefs.edit().putLong(K_SNOOZE, c.timeInMillis).apply()
        evaluate()
    }

    // ---- the rules, applied ---------------------------------------------------------------------

    private fun now() = System.currentTimeMillis()

    private val evaluateRunnable = Runnable { evaluate() }

    fun evaluate() {
        if (!initialized) return
        main.removeCallbacks(evaluateRunnable)
        if (capture.inFlight) {
            // Keep the invisible PET ticket for openIntent's authenticated generation, but never
            // let polling, an incoming Dart push or window-cleanup callbacks re-show captured UI.
            stopLoop()
            stopCompanion()
            petView?.visibility = View.INVISIBLE
            speaksForResults = false
            publishStatus()
            return
        }
        refreshCanDraw()
        machine.canHost = overlayHost() != OverlayHost.NONE
        machine.hasPet = loaded != null && loadedKey == packKey(machine.last)
        machine.phoneTask = PhoneControl.peek()?.foregroundLine() != null
        machine.dshService = DshService.isRunning
        machine.interactive = interactive()
        machine.holding = askView != null || menuView != null || answerState.bubbleId != null || returnAsk
        val t = now()
        val d = machine.decide(t)
        if (d.visibility != lastVisibility || d.why != lastWhy) {
            Log.i(TAG, "overlay ${d.visibility.name.lowercase()}: ${d.why}")
            lastVisibility = d.visibility
            lastWhy = d.why
        }
        when (d.visibility) {
            Visibility.HIDDEN -> {
                stopLoop()
                removeWindows()
            }
            Visibility.PAUSED -> {
                petView?.cancelInteraction()
                stopLoop()
                stopCompanion()
                dismissMenu()
                removeAsk()
            }
            Visibility.SHOWN -> {
                val before = lastAdd
                if (!attachPet()) {
                    // With the permission now known not to work, decide again; else retry at the next poll.
                    if (lastAdd != before) main.post(evaluateRunnable)
                } else {
                    petView?.visibility = View.VISIBLE
                    if (!dragging) setDimmed(d.dimmed)
                    if (companionAllowed()) startCompanion() else stopCompanion()
                    retarget()
                    companionView?.freeze(dimmed)
                    if (dimmed || !systemShown || companionView != null) stopLoop() else startLoop()
                    showBubble(d.bubble)
                    if (returnAsk) {
                        returnAsk = false
                        main.post { if (!machine.appForeground && alive(petTicket)) showAsk(askFresh) }
                    }
                }
            }
        }
        speaksForResults = ResultSilence.petSpeaks(d.visibility, petView?.isAttachedToWindow == true, systemShown, machine.last?.quiet == true)
        PetOverlayService.ensure(app, d.ownService)
        // Polled only while out (or held back by a phone task): the accessibility service, a phone
        // task and DshService change without telling us.
        val poll = d.visibility == Visibility.SHOWN || (machine.phoneTask && machine.enabled && !machine.appForeground)
        val wake = listOfNotNull(
            d.wakeAt?.let { it - t }, if (poll) POLL_MS else null,
            accessibilityRetry.remaining(PhoneA11yService.instance, t),
        ).minOrNull()
        if (wake != null) main.postDelayed(evaluateRunnable, wake.coerceAtLeast(50))
        publishStatus()
    }

    private fun publishStatus() {
        val s = status()
        if (s != lastStatus) {
            lastStatus = s
            listener?.onStatus(s)
        }
    }

    // ---- companion renderer ---------------------------------------------------------------------

    private fun companionAllowed() = companionCanRender(
        selected = companionEndpoint != null, fallback = companionRecovery.fallback,
        shown = lastVisibility == Visibility.SHOWN, interactive = machine.interactive,
        systemShown = systemShown, capturing = capture.inFlight,
        powerSave = companionEndpoint != null && app.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true,
    )

    private fun startCompanion() {
        if (companionView != null) return
        val endpoint = companionEndpoint ?: return
        val v = petView ?: return
        val p = petParams ?: return
        val ticket = petTicket
        if (!alive(ticket)) return
        stopLoop()
        slideAnim?.cancel()
        val area = safeArea()
        // Full-body default, within both the readback cap and the existing dock margins.
        val geometry = CompanionFloatGeometry.fit(
            v.context.dp(PetSize.dpOf(machine.last?.size) * 4),
            area, edge(v.context),
        ) ?: return
        val epoch = ++companionEpoch
        fun current() = epoch == companionEpoch && petView === v && alive(ticket)
        try {
            val renderer = CompanionFloatView(app, endpoint, geometry, object : CompanionFloatView.Listener {
                override fun bounds(box: FramePx?) {
                    if (!current()) return
                    val before = v.companionBounds
                    val next = box ?: FramePx(geometry.width / 2, geometry.height / 2,
                        geometry.width / 2 + 1, geometry.height / 2 + 1)
                    val previous = WindowPos(p.x, p.y)
                    val wanted = CompanionFloatGeometry.move(previous, before, next)
                    val pos = if (dragging) EdgeSnap.clampDrag(wanted.x, wanted.y, next.width, next.height, safeArea()) else wanted
                    val dx = pos.x - previous.x
                    val dy = pos.y - previous.y
                    dragStart = dragStart?.let { WindowPos(it.x + dx, it.y + dy) }
                    dropAt = dropAt?.let { WindowPos(it.x + dx, it.y + dy) }
                    v.setCompanionBounds(next)
                    p.x = pos.x; p.y = pos.y
                    p.width = next.width; p.height = next.height
                    p.alpha = if (box == null) 0f else 1f
                    p.flags = if (box == null) p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        else p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                    update(v, p)
                    if (dragging) updateTargetArmed(v)
                    followBubble(force = true)
                    menuView?.let { menu -> menuParams?.let { params ->
                        if (placeMenu(menu, params)) update(menu, params) else dismissMenu()
                    } }
                }
                override fun failed(code: String) { if (current()) companionFailed(code) }
                override fun resumeNeeded() {
                    if (!current()) return
                    stopCompanion()
                    if (companionAllowed()) startCompanion()
                }
            })
            companionView = renderer
            v.setCompanion(renderer.view, geometry)
            p.width = geometry.width; p.height = geometry.height
            // The page must render at a stable viewport size, but has no touch
            // surface until actual alpha arrives. Alpha=0 also avoids Android
            // 12+ treating this invisible application overlay as an occluder.
            p.alpha = 0f
            p.flags = p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            placeRest(v, p, EdgeSnap.position(dock, v.reach, area, edge(v.context)))
            update(v, p)
            renderer.state(machine.last?.state ?: PetPack.IDLE, machine.last?.reduceMotion == true)
            renderer.freeze(dimmed)
            renderer.start()
        } catch (_: RuntimeException) {
            if (current()) companionFailed("companion_hardware_unavailable")
        }
    }

    private fun stopCompanion(restorePixels: Boolean = true) {
        val renderer = companionView ?: return
        companionView = null
        companionEpoch++ // Fence queued JS, page and renderer callbacks before destroy.
        val v = petView
        try { renderer.close() } finally {
            v?.clearCompanion()
            stateKey = null
        }
        if (!restorePixels || v == null || !alive(petTicket)) return
        v.cancelInteraction()
        slideAnim?.cancel()
        val p = petParams ?: return
        p.alpha = 1f
        p.flags = p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        p.width = v.frame.width; p.height = v.frame.height
        placeRest(v, p, EdgeSnap.position(dock, v.reach, safeArea(), edge(v.context)))
        update(v, p)
        retarget()
        drawStill()
        followBubble(force = true)
    }

    private fun companionFailed(code: String) {
        val failure = companionRecovery.failed()
        if (failure == CompanionFloatRecovery.Failure.IGNORE) return
        companionProblem = code
        stopCompanion()
        if (failure == CompanionFloatRecovery.Failure.FALLBACK) {
            removeWindows() // Pixel fallback uses the original window flags again.
            companionNotice?.let { Toast.makeText(app, it, Toast.LENGTH_LONG).show() }
        }
        main.post(evaluateRunnable)
    }

    // ---- permission -----------------------------------------------------------------------------

    private fun a11yConnected() = PhoneA11yService.instance != null

    private fun overlayHost(): OverlayHost = OverlayAccess.host(
        a11yConnected(), lastAdd,
        a11yFailed = accessibilityRetry.remaining(PhoneA11yService.instance, now()) != null,
        canDraw = canDraw(),
    )

    private fun canDraw(): Boolean = try { Settings.canDrawOverlays(app) } catch (_: Exception) { false }

    private fun refreshCanDraw() {
        val cd = canDraw()
        val changed = lastCanDraw != null && lastCanDraw != cd
        lastCanDraw = cd
        if (lastAdd == AddResult.FAILED && OverlayAccess.retry(lastAdd, failedAt, now(), cd, changed)) lastAdd = null
    }

    /** Adds a 1×1 invisible application overlay and removes it again; the result is the permission. */
    private fun probe() {
        val ctx = appWindowContext()
        val w = ctx.getSystemService(WindowManager::class.java) ?: return
        val v = View(ctx)
        val p = WindowManager.LayoutParams(
            1, 1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { alpha = 0f; gravity = Gravity.TOP or Gravity.START; title = AppStrings.get(app, R.string.pet_window_title) }
        lastAdd = try {
            w.addView(v, p)
            try { w.removeViewImmediate(v) } catch (_: Exception) {}
            AddResult.OK
        } catch (e: Exception) {
            Log.i(TAG, "overlay permission probe failed: ${e.javaClass.simpleName}")
            failedAt = now()
            AddResult.FAILED
        }
    }

    // ---- pack -----------------------------------------------------------------------------------

    private fun packKey(p: PetPush?): String? = p?.packId?.let { "$it@${p.size}" }

    /** Loads [id] at [size] unless it is loaded, loading or broken; [reload]: from disk again regardless. */
    private fun ensurePack(id: String, size: String, reload: Boolean = false) {
        val key = "$id@$size"
        if (!reload && (key == loadedKey || key == loadingKey || id in failedIds)) return
        loadingKey = key
        val request = ++loadRequest
        val density = app.resources.displayMetrics.density
        worker.execute {
            val l = sprites.load(id, worker) { pack -> pack.screenScale(size, density) }
            l?.warmResident()
            main.post {
                if (request != loadRequest || loadingKey != key || packKey(machine.last) != key) {
                    if (request == loadRequest) loadingKey = null
                    l?.release()
                    return@post
                }
                loadingKey = null
                if (l == null) {
                    Log.w(TAG, "pet pack $id not found")
                    failedIds += id
                    // Read again (reloadPack) and gone or broken now: the old picture doesn't stay.
                    if (loadedKey == key) {
                        loaded?.release()
                        loaded = null
                        loadedKey = null
                        stateKey = null
                        if (petView != null) removeWindows()
                    }
                } else {
                    loaded?.release()
                    loaded = l
                    loadedKey = key
                    stateKey = null
                    if (petView != null) removeWindows()
                }
                evaluate()
            }
        }
    }

    // ---- animation ------------------------------------------------------------------------------

    /** Starts the pushed state's animation; restarts only when the state, tier or pack changes. */
    private fun retarget() {
        val l = loaded ?: return
        val p = machine.last ?: return
        companionView?.let { it.state(p.state, p.reduceMotion); return }
        // The floating pet doesn't roam: roam plays as idle.
        val state = if (p.state == PetPush.ROAM) PetPack.IDLE else p.state
        val key = "${l.pack.id}|$state|${p.tier}|${p.reduceMotion}"
        if (key == stateKey) return
        stateKey = key
        val pack = l.pack
        // Calm states hold a still frame and play one action every 8–15 s: for idle,
        // a cycle of the plain idle (blink, breath) or now and then one from the pack's idle pool.
        val calmPool = when (state) {
            PetPack.IDLE -> pack.primary(state, 0).let { base -> listOf(PetIdleItem(base, base.totalMs, 3)) } + pack.idlePool
            PetPush.SLEEPING -> pack.primary(state, 0).let { listOf(PetIdleItem(it, it.totalMs, 1)) }
            else -> null
        }
        player.setState(pack.primary(state, p.tier), calmPool, pack.bonusOf(state, p.tier), SystemClock.uptimeMillis())
        if (looping) restartLoop() else petView?.let { drawStill() }
    }

    /**
     * Plays [kind]'s reaction. A tap picks one at random among the pack's alternatives; the drag
     * pose stays the one first named (the window is rebuilt around it, so it must not change).
     */
    private fun react(kind: String, loop: Boolean, random: Boolean = true) {
        if (petView?.companionGeometry != null) return
        val pack = loaded?.pack ?: return
        val a = (if (random) pack.reaction(kind, Random.Default) else pack.reaction(kind)) ?: return
        player.react(a, loop, SystemClock.uptimeMillis())
        restartLoop()
    }

    private var frame: Choreographer.FrameCallback? = null

    private fun startLoop() {
        if (petView?.companionGeometry != null) return
        if (looping) {
            // System animations may have been re-enabled while no frame was scheduled.
            if (player.still && animationsOn()) restartLoop()
            return
        }
        if (!alive(petTicket)) return
        looping = true
        tick()
    }

    private fun restartLoop() {
        if (!looping) return
        frame?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frame = null
        tick()
    }

    private fun stopLoop() {
        looping = false
        frame?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frame = null
    }

    /** One frame, then sleep until the picture next changes (the still idle frame waits seconds). */
    private fun tick() {
        if (!looping) return
        val ticket = petTicket
        if (!alive(ticket)) return
        val view = petView ?: return
        val l = loaded ?: return
        player.still = !animationsOn()
        val f = player.frame(SystemClock.uptimeMillis()) ?: return
        if (!view.show(f.anim, f.index)) {
            l.request(f.anim) { if (alive(ticket) && loaded === l) redraw() }
            return
        }
        onShown()
        f.nextInMs?.let { delay ->
            lateinit var callback: Choreographer.FrameCallback
            callback = Choreographer.FrameCallback {
                if (frame === callback) {
                    frame = null
                    if (alive(ticket)) tick()
                }
            }
            frame = callback
            Choreographer.getInstance().postFrameCallbackDelayed(callback, delay.coerceAtLeast(8))
        }
    }

    /** Paused or dimmed: still draw the current picture once (sheet permitting). */
    private fun drawStill() {
        if (petView?.companionGeometry != null) return
        val ticket = petTicket
        if (!alive(ticket)) return
        val view = petView ?: return
        val l = loaded ?: return
        val f = player.frame(SystemClock.uptimeMillis()) ?: return
        if (view.show(f.anim, f.index)) onShown() else l.request(f.anim) { if (alive(ticket) && loaded === l) redraw() }
    }

    /** A picture is on screen: the window fits it, a bubble moves over it. */
    private fun onShown() {
        fitFrame()
        followBubble()
    }

    /** A sheet arrived: carry on playing, or show its still picture. */
    private fun redraw() {
        if (looping) restartLoop() else drawStill()
    }

    // ---- the window's frame ---------------------------------------------------------------------

    /** Where the rest frame sits now: the window, less how far its frame reaches past rest. */
    private fun restPos(v: PetView, p: WindowManager.LayoutParams) = PetFrames.restOf(WindowPos(p.x, p.y), v.frame)

    private fun placeRest(v: PetView, p: WindowManager.LayoutParams, rest: WindowPos) {
        val at = PetFrames.windowAt(rest, v.frame)
        p.x = at.x
        p.y = at.y
    }

    /**
     * Sizes the pet window to what it shows (docs/design/pets.md §6.1): grown around the lifted pose
     * while held and until that picture is gone, around the shown animation's whole cell when it
     * reaches past rest (a jump, typing's laptop, a thought cloud, Zzz), the rest frame otherwise,
     * so every frame is drawn whole. The rest frame keeps its place, so the pet doesn't move on
     * screen: held, the grown window is kept whole on screen; docked, the dock already left room for
     * every frame ([PetFrames.reach]). One window update when the frame changes, none while it stays.
     */
    private fun fitFrame() {
        val v = petView ?: return
        if (v.companionGeometry != null) return
        val p = petParams ?: return
        val l = loaded ?: return
        if (!alive(petTicket)) return
        val next = l.frames.frameFor(v.shown, dragging)
        if (next == v.frame) return
        val rest = restPos(v, p)
        v.setFrame(next)
        p.width = next.width
        p.height = next.height
        placeRest(v, p, rest)
        if (dragging) EdgeSnap.clampDrag(p.x, p.y, p.width, p.height, safeArea()).let { p.x = it.x; p.y = it.y }
        update(v, p)
    }

    // ---- windows --------------------------------------------------------------------------------

    private fun appWindowContext(): Context {
        appWindowContext?.let { return it }
        val ctx = if (Build.VERSION.SDK_INT >= 30) {
            val display = app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
            app.createDisplayContext(display).createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
        } else {
            app
        }
        appWindowContext = ctx
        return ctx
    }

    private fun windowType(h: OverlayHost) =
        if (h == OverlayHost.ACCESSIBILITY) WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY else WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY

    private fun baseParams(w: Int, h: Int, flags: Int) = WindowManager.LayoutParams(
        w, h, windowType(host),
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or flags,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        title = AppStrings.get(app, R.string.pet_window_title)
        if (Build.VERSION.SDK_INT >= 28) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
        // A window whose size and place change in one layout gets the system's ~0.4 s move
        // animation, and every move meanwhile is ignored: picked up, the pet grows around the
        // lifted pose and then lagged the finger until it ended. Our windows move themselves.
        if (Build.VERSION.SDK_INT >= 34) {
            setCanPlayMoveAnimation(false)
        } else {
            // PRIVATE_FLAG_NO_MOVE_ANIMATION, what setCanPlayMoveAnimation sets.
            runCatching { javaClass.getField("privateFlags").run { setInt(this@apply, getInt(this@apply) or 0x40) } }
        }
    }

    private fun edge(ctx: Context) = ctx.dp(EDGE_DP)

    /** The pet window, on the right host; false when it couldn't be added. */
    private fun attachPet(): Boolean {
        val want = overlayHost()
        if (want == OverlayHost.NONE) return false
        val service = PhoneA11yService.instance
        return try {
            val ctx = if (want == OverlayHost.ACCESSIBILITY) service?.overlayWindowContext() ?: return false else appWindowContext()
            val current = petView
            if (current != null && host == want && windows.isHost(ctx) && alive(petTicket)) return true
            removeWindows()
            if (!windows.begin(ctx)) return false
            val w = ctx.getSystemService(WindowManager::class.java) ?: return false
            host = want
            hostContext = ctx
            wm = w
            val ticket = windows.claim(OverlayWindowOwner.Role.PET) ?: return false
            petTicket = ticket
            val view = PetView(ctx, petListener(ticket)).apply { setSprites(loaded) }
            if (view.pixelWidth <= 0) {
                removeWindows()
                return false
            }
            view.contentDescription = loaded?.pack?.name ?: AppStrings.get(app, R.string.pet_label)
            dimmed = false
            systemShown = true
            val pos = EdgeSnap.position(dock, view.reach, safeArea(), edge(ctx))
            val hardware = if (companionEndpoint != null && !companionRecovery.fallback)
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED else 0
            val params = baseParams(view.pixelWidth, view.pixelHeight, hardware).apply { x = pos.x; y = pos.y }
            petView = view
            petParams = params
            // The 「×」 goes in first, hidden, so the dragged pet stays above it.
            addTarget(ctx, w)
            if (!installWindow(ticket, view, w, params)) {
                removeWindows()
                return false
            }
            if (want == OverlayHost.APPLICATION) lastAdd = AddResult.OK
            if (companionEndpoint == null || companionRecovery.fallback) enter(view)
            drawStill()
            true
        } catch (e: Exception) {
            Log.i(TAG, "overlay add failed (${want.name.lowercase()}): ${e.javaClass.simpleName}")
            removeWindows()
            if (want == OverlayHost.APPLICATION) {
                lastAdd = AddResult.FAILED
                failedAt = now()
            } else if (service != null) {
                accessibilityRetry.failed(service, now())
                service.invalidateOverlayWindowContext()
            }
            host = OverlayHost.NONE
            false
        }
    }

    private fun removeWindows() {
        // Invalidate input/async callbacks before cancel() or platform removal can call us back.
        windows.retire()
        stopCompanion(restorePixels = false)
        stopLoop()
        openPendingIntent?.cancel()
        openPendingIntent = null
        if (initialized) app.getSystemService(NotificationManager::class.java)?.cancel(NOTICE_ID)
        slideAnim?.cancel()
        slideAnim = null
        dismissMenu()
        removeAsk()
        removeBubble()
        removeTarget()
        petView?.let { remove(it) }
        petView = null
        petTicket = null
        petParams = null
        dragging = false
        dimmed = false
        player.endReaction()
        speaksForResults = false
        host = OverlayHost.NONE
        hostContext = null
        wm = null
        scheduleCleanup()
    }

    private fun update(v: View, p: WindowManager.LayoutParams) {
        if (!alive(windowTickets[v])) return
        try { wm?.updateViewLayout(v, p) } catch (e: Exception) { Log.w(TAG, "overlay update failed", e) }
    }

    private fun remove(v: View) {
        val ticket = windowTickets.remove(v)
        v.visibility = View.GONE // A deferred or failed platform removal must not leak UI into a screenshot.
        windows.remove(ticket)
        v.animate().cancel()
        scheduleCleanup()
    }

    private fun alive(ticket: OverlayWindowOwner.Ticket?) = windows.owns(petTicket) && windows.owns(ticket)

    private val cleanupRunnable = Runnable {
        windows.retryRemovals()
        scheduleCleanup()
        evaluate()
    }

    private fun scheduleCleanup() {
        main.removeCallbacks(cleanupRunnable)
        if (windows.pendingRemovals > 0) main.postDelayed(cleanupRunnable, POLL_MS)
    }

    private fun installWindow(ticket: OverlayWindowOwner.Ticket, v: View, manager: WindowManager, p: WindowManager.LayoutParams): Boolean {
        val attached = object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) {
                if (!windows.owns(ticket)) return
                windows.revoke(ticket)
                main.post {
                    if (petTicket == ticket) removeWindows() else if (windowTickets[v] == ticket) remove(v)
                    evaluate()
                }
            }
        }
        v.addOnAttachStateChangeListener(attached)
        windowTickets[v] = ticket
        val removal = OverlayRemoval(
            request = {
                // The exact manager which accepted add; pending attachment is still owned.
                try {
                    manager.removeViewImmediate(v)
                } catch (e: IllegalArgumentException) {
                    // WindowManager reports an unregistered view, including failed add.
                    // Do not infer this from attachment state without actually trying remove.
                    if (v.isAttachedToWindow || v.parent != null) throw e
                }
            },
            detached = { !v.isAttachedToWindow && v.parent == null },
            nextTurn = { confirm ->
                main.post {
                    confirm()
                    // A deferred removal still attached after this turn must wait for the poll;
                    // retrying it here can post another confirmation forever on the main thread.
                    if (!v.isAttachedToWindow && v.parent == null) {
                        windows.retryRemovals()
                        evaluate()
                    }
                    scheduleCleanup()
                }
            },
        )
        return try {
            windows.install(ticket, remove = {
                if (removal.attempt()) {
                    v.removeOnAttachStateChangeListener(attached)
                    if (windowTickets[v] == ticket) windowTickets.remove(v)
                    true
                } else {
                    false
                }
            }, add = { manager.addView(v, p) })
        } finally {
            scheduleCleanup()
        }
    }

    private val easing = PathInterpolator(0.2f, 0f, 0f, 1f)

    private fun animationsOn() = machine.last?.reduceMotion != true && ValueAnimator.areAnimatorsEnabled()

    private fun enter(v: PetView) {
        if (!animationsOn()) return
        v.alpha = 0f
        v.scaleX = 0.9f
        v.scaleY = 0.9f
        v.pivotX = v.pixelWidth / 2f
        v.pivotY = v.pixelHeight.toFloat()
        v.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(easing).start()
    }

    /** Fades to [OverlayMachine.DIM_ALPHA] and back where it docks; the whole pet stays on screen. */
    private fun setDimmed(on: Boolean) {
        if (on == dimmed) return
        val v = petView ?: return
        dimmed = on
        companionView?.freeze(on)
        if (on) {
            dismissMenu()
            removeBubble()
        }
        val alpha = if (on) OverlayMachine.DIM_ALPHA else 1f
        if (animationsOn()) v.animate().alpha(alpha).setDuration(if (on) 400 else 150).setInterpolator(easing).start() else v.alpha = alpha
    }

    /** The screen minus status / navigation bars and the cutout. */
    private fun safeArea(): SafeArea {
        val w = wm ?: appWindowContext().getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) {
            val m = w.currentWindowMetrics
            val i = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return SafeArea(m.bounds.width(), m.bounds.height(), i.left, i.top, i.right, i.bottom)
        }
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        val display = w.defaultDisplay
        @Suppress("DEPRECATION")
        display.getRealMetrics(dm)
        val res = Resources.getSystem()
        fun dimen(name: String) = res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize) ?: 0
        val status = dimen("status_bar_height")
        val nav = dimen("navigation_bar_height")
        return when (display.rotation) {
            Surface.ROTATION_90 -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, nav, 0)
            Surface.ROTATION_270 -> SafeArea(dm.widthPixels, dm.heightPixels, nav, status, 0, 0)
            else -> SafeArea(dm.widthPixels, dm.heightPixels, 0, status, 0, nav)
        }
    }

    // ---- touch ----------------------------------------------------------------------------------

    private fun petListener(ticket: OverlayWindowOwner.Ticket) = object : PetView.Listener {
        override fun onDragStart() {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            slideAnim?.cancel()
            // Kept as the rest frame's place: the window grows around the lifted pose (fitFrame).
            dragStart = restPos(v, p)
            dropAt = dragStart
            dragging = true
            setDimmed(false)
            machine.onTouch(now())
            dismissMenu()
            removeBubble()
            showTarget()
            react("drag", loop = true, random = false)
            startLoop()
        }

        override fun onDrag(dx: Int, dy: Int) {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            val s = dragStart ?: return
            val area = safeArea()
            // The window, lifted pose and all, stays whole on screen.
            val pos = EdgeSnap.carry(s, dx, dy, v.frame, area)
            p.x = pos.x
            p.y = pos.y
            update(v, p)
            // Release and 「×」 read the rest frame where the finger puts it, kept on screen as it
            // always was: docking doesn't change, though at the top the held window stops earlier.
            val drop = EdgeSnap.clampDrag(s.x + dx, s.y + dy, v.pixelWidth, v.pixelHeight, area)
            dropAt = drop
            updateTargetArmed(v)
        }

        override fun onDragEnd(velocityX: Float) {
            if (!alive(ticket)) return
            val v = petView ?: return
            val p = petParams ?: return
            dragging = false
            player.endReaction()
            val dismiss = target?.armed == true
            hideTarget()
            machine.onTouch(now())
            if (dismiss) {
                // Dropped on 「×」: today it stays away.
                snoozeToday()
                return
            }
            // Put down: the state's picture now, and the window back to rest around the same
            // origin (later, if that picture's sheet has to be decoded again first).
            redraw()
            fitFrame()
            val area = safeArea()
            val drop = dropAt ?: restPos(v, p)
            dock = EdgeSnap.dockFor(drop, v.pixelWidth, v.reach, area, edge(v.context), velocityX)
            prefs.edit().putString(K_SIDE, if (dock.side == Side.LEFT) "left" else "right").putFloat(K_Y, dock.yFraction).apply()
            slide(v, p, EdgeSnap.position(dock, v.reach, area, edge(v.context))) { evaluate() }
        }

        override fun onDragCancel() {
            if (!alive(ticket)) return
            dragging = false
            player.endReaction()
            hideTarget()
            redraw()
            val v = petView ?: return
            val p = petParams ?: return
            slide(v, p, EdgeSnap.position(dock, v.reach, safeArea(), edge(v.context))) { evaluate() }
        }

        override fun onPoke(leftHalf: Boolean, x: Float, y: Float) {
            if (!alive(ticket)) return
            machine.onTouch(now())
            if (dimmed) evaluate()
            dismissMenu()
            companionView?.tap(x, y) ?: react(if (leftHalf) "tapLeft" else "tapRight", loop = false)
            // One tap used to open the conversation: say where that went, a few times.
            val told = prefs.getInt(K_TAP_HINTS, 0)
            if (told < TAP_HINTS) {
                prefs.edit().putInt(K_TAP_HINTS, told + 1).apply()
                Toast.makeText(app, AppStrings.get(app, R.string.pet_tap_hint), Toast.LENGTH_SHORT).show()
            }
        }

        override fun onTap(leftHalf: Boolean) {
            if (!alive(ticket)) return
            machine.onTouch(now())
            if (dimmed) evaluate()
            dismissMenu()
            prefs.edit().putInt(K_TAP_HINTS, TAP_HINTS).apply()
            val push = machine.last
            open(push?.sessionId, push?.host, null)
        }

        override fun onLongPress(rawX: Float?, rawY: Float?) {
            if (!alive(ticket)) return
            machine.onTouch(now())
            if (dimmed) evaluate()
            showMenu(rawX, rawY)
        }

        override fun onMenuMove(rawX: Float, rawY: Float) {
            if (alive(ticket)) menuView?.movePointer(rawX, rawY)
        }

        override fun onMenuEnd(rawX: Float, rawY: Float, cancelled: Boolean) {
            if (!alive(ticket)) return
            menuView?.endPointer(rawX, rawY, cancelled)
            menuView?.let { windowTickets[it] }?.takeIf(::alive)?.let(::scheduleMenuTimeout)
        }

        override fun onShownChanged(shown: Boolean) {
            if (!alive(ticket)) return
            if (shown == systemShown) return
            systemShown = shown
            if (!shown) {
                stopCompanion()
                dismissMenu()
            }
            // Hidden by the system (another app's setHideOverlayWindows): wait, don't re-add.
            main.post(evaluateRunnable)
        }
    }

    /** Slides the rest frame to [to]; the window follows with whatever frame it has at each step. */
    private fun slide(v: PetView, p: WindowManager.LayoutParams, to: WindowPos, then: (() -> Unit)?) {
        val ticket = windowTickets[v]
        if (!alive(ticket)) return
        slideAnim?.cancel()
        if (!animationsOn()) {
            placeRest(v, p, to)
            update(v, p)
            then?.invoke()
            return
        }
        val from = restPos(v, p)
        val initialBounds = v.companionBounds
        slideAnim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 260
            interpolator = easing
            addUpdateListener { a ->
                if (!alive(ticket)) return@addUpdateListener
                val f = a.animatedValue as Float
                val at = WindowPos((from.x + (to.x - from.x) * f).roundToInt(), (from.y + (to.y - from.y) * f).roundToInt())
                placeRest(v, p, if (v.companionGeometry == null) at else
                    CompanionFloatGeometry.move(at, initialBounds, v.companionBounds))
                update(v, p)
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (slideAnim === animation) slideAnim = null
                    if (!cancelled && alive(ticket)) then?.invoke()
                }
            })
            start()
        }
    }

    // ---- 「×」 target ----------------------------------------------------------------------------

    private fun addTarget(ctx: Context, w: WindowManager) {
        removeTarget()
        val ticket = windows.claim(OverlayWindowOwner.Role.TARGET) ?: return
        val size = (ctx.dp(TARGET_DP) * 1.2f).roundToInt()
        val c = EdgeSnap.dismissCenter(safeArea(), size, ctx.dp(TARGET_GAP_DP))
        val view = DismissTargetView(ctx).apply { visibility = View.GONE }
        val params = baseParams(size, size, WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE).apply {
            x = c.x - size / 2
            y = c.y - size / 2
        }
        target = view
        targetCenter = c
        installWindow(ticket, view, w, params)
    }

    private fun updateTargetArmed(v: PetView) {
        val drop = dropAt
        val center = targetCenter
        target?.setArmed(drop != null && center != null &&
            EdgeSnap.overDismiss(drop, v.pixelWidth, v.pixelHeight, center, v.context.dp(TARGET_DP)))
    }

    private fun showTarget() {
        val view = target ?: return
        view.setArmed(false)
        view.visibility = View.VISIBLE
        if (animationsOn()) {
            view.alpha = 0f
            view.animate().alpha(1f).setDuration(150).start()
        }
    }

    private fun hideTarget() {
        target?.let {
            it.animate().cancel()
            it.visibility = View.GONE
        }
    }

    private fun removeTarget() {
        target?.let { remove(it) }
        target = null
        targetCenter = null
    }

    // ---- bubble ---------------------------------------------------------------------------------

    private fun showBubble(b: PetBubble?) {
        if (b == null || dragging || dimmed || slideAnim != null || menuView != null || closingMenu != null || capture.inFlight) {
            removeBubble()
            return
        }
        val ctx = hostContext ?: return
        if (bubbleId == b.id && alive(bubbleView?.let { windowTickets[it] })) return
        removeBubble()
        val ticket = windows.claim(OverlayWindowOwner.Role.BUBBLE) ?: return
        val view = BubbleView(ctx) { if (alive(ticket)) onBubbleTap(b) }
        view.bind(b)
        b.ask?.let { ask ->
            // Laid out once first: the buttons depend on whether the request's text shows whole.
            view.measureCard()
            view.setActions(BubbleAction.of(ask, view.detailWhole()), ask.kind, SystemClock.uptimeMillis() + ARM_MS) { a ->
                if (alive(ticket)) onBubbleAction(b, a)
            }
        }
        val card = view.measureCard()
        val shown = petView?.shown?.name
        val place = bubblePlace(card, view.tailPx) ?: return
        view.setTail(place.tailAt, place.tail)
        val params = baseParams(place.w, place.h, 0).apply { x = place.pos.x; y = place.pos.y }
        try {
            val manager = wm ?: return
            if (!installWindow(ticket, view, manager, params)) return
        } catch (e: Exception) {
            Log.w(TAG, "bubble add failed", e)
            return
        }
        bubbleView = view
        bubbleId = b.id
        bubbleParams = params
        bubbleCard = card
        bubbleFor = shown
        if (animationsOn()) {
            // Comes out of the tail's side, towards where it rests.
            val d = ctx.dp(4f).toFloat()
            view.alpha = 0f
            when (place.tail) {
                Tail.DOWN -> view.translationY = d
                Tail.UP -> view.translationY = -d
                Tail.RIGHT -> view.translationX = d
                Tail.LEFT -> view.translationX = -d
            }
            view.animate().alpha(1f).translationX(0f).translationY(0f).setDuration(200).setInterpolator(easing).start()
        }
    }

    /**
     * Where the bubble goes for the picture on screen now (docs/design/pets.md §2.7): over the
     * body and the current animation's cell, so a jump or a thought cloud stays in front of it.
     */
    private fun bubblePlace(card: Pair<Int, Int>, tailPx: Int): BubblePlacement? {
        val ctx = hostContext ?: return null
        val pv = petView ?: return null
        val pp = petParams ?: return null
        val f = loaded?.frames ?: return null
        val rest = restPos(pv, pp)
        return EdgeSnap.bubble(
            f.body.at(rest), f.art(pv.shown).at(rest), dock.side, card.first, card.second, tailPx, safeArea(),
            gap = ctx.dp(4f), margin = edge(ctx), tailInset = ctx.dp(20f),
        )
    }

    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleCard: Pair<Int, Int>? = null
    /** The animation the bubble was placed over. */
    private var bubbleFor: String? = null
    private var bubbleMove: ValueAnimator? = null

    /**
     * The picture under a bubble changed (idle to a jump, say): the bubble glides to its place over
     * the new one, the way the chat page's bubble follows the head. Nothing to do while it stays.
     */
    private fun followBubble(force: Boolean = false) {
        val view = bubbleView ?: return
        val p = bubbleParams ?: return
        val card = bubbleCard ?: return
        val ticket = windowTickets[view]
        if (!alive(ticket)) return
        val shown = petView?.shown?.name
        if (!force && shown == bubbleFor) return
        bubbleFor = shown
        val place = bubblePlace(card, view.tailPx) ?: return
        bubbleMove?.cancel()
        view.setTail(place.tailAt, place.tail)
        p.width = place.w
        p.height = place.h
        val from = WindowPos(p.x, p.y)
        if (force || !animationsOn() || from == place.pos) {
            p.x = place.pos.x
            p.y = place.pos.y
            update(view, p)
            return
        }
        bubbleMove = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 200
            interpolator = easing
            addUpdateListener { a ->
                if (!alive(ticket) || bubbleParams !== p) return@addUpdateListener
                val t = a.animatedValue as Float
                p.x = (from.x + (place.pos.x - from.x) * t).roundToInt()
                p.y = (from.y + (place.pos.y - from.y) * t).roundToInt()
                update(view, p)
            }
            start()
        }
    }

    private fun removeBubble() {
        bubbleMove?.cancel()
        bubbleMove = null
        bubbleView?.let { remove(it) }
        bubbleView = null
        bubbleId = null
        bubbleParams = null
        bubbleCard = null
        bubbleFor = null
    }

    private fun onBubbleTap(b: PetBubble) {
        machine.onTouch(now())
        machine.bubbles.dismiss()
        removeBubble()
        val push = machine.last
        if (b.sessionId != null) open(b.sessionId, b.host, b.title) else open(push?.sessionId, push?.host, b.title)
    }

    /** The bubble whose answer is on its way to Dart. */
    private val answerState = PetAnswerState()

    /**
     * An answer from the bubble, through Dart's own path (the one the notification's buttons
     * take). Answered or settled elsewhere, the bubble goes; refused, it says so and leads to the chat.
     */
    private fun onBubbleAction(b: PetBubble, a: BubbleAction) {
        machine.onTouch(now())
        val ask = b.ask ?: return
        if (a.kind == BubbleAction.Kind.OPEN) return onBubbleTap(b)
        val view = bubbleView ?: return
        val answer = answerState.begin(b.id) ?: return
        view.setBusy(a)
        val args = mapOf(
            "host" to b.host, "sessionId" to b.sessionId, "eventId" to ask.eventId, "token" to ask.token, "kind" to ask.kind,
            "decision" to when (a.kind) {
                BubbleAction.Kind.ALLOW -> "allow"
                BubbleAction.Kind.REJECT -> "reject"
                else -> null
            },
            "choice" to a.choice,
        )
        callDart("answer", args) { raw ->
            if (!answerState.finish(answer)) return@callDart
            val result = (raw as? Map<*, *>)?.get("result")
            Log.i(TAG, "bubble answer ${a.kind.name.lowercase()}: $result")
            if (bubbleId == b.id) {
                if (result == "handled" || result == "gone") {
                    machine.bubbles.dismiss()
                    removeBubble()
                } else {
                    bubbleView?.let { v ->
                        v.showFailed(AppStrings.get(app, R.string.pet_answer_failed), ask.kind) { onBubbleTap(b) }
                        refitBubble(v)
                    }
                }
            }
            evaluate()
        }
    }

    /** The bubble's content changed size: measured and placed again where it is. */
    private fun refitBubble(view: BubbleView) {
        val p = bubbleParams ?: return
        val card = view.measureCard()
        bubbleCard = card
        val place = bubblePlace(card, view.tailPx) ?: return
        view.setTail(place.tailAt, place.tail)
        p.width = place.w
        p.height = place.h
        p.x = place.pos.x
        p.y = place.pos.y
        update(view, p)
    }

    // ---- menu -----------------------------------------------------------------------------------

    private var menuTimeout: Runnable? = null
    private var menuParams: WindowManager.LayoutParams? = null

    private fun showMenu(rawX: Float? = null, rawY: Float? = null) {
        if (capture.inFlight || !interactive()) return
        val currentTicket = menuView?.let { windowTickets[it] }
        if (currentTicket != null && alive(currentTicket)) {
            // Reuse the live menu: removing it would reserve MENU until the
            // next-loop confirmation, so an immediate replacement cannot add.
            if (rawX != null && rawY != null) menuView?.beginPointer(rawX, rawY)
            scheduleMenuTimeout(currentTicket)
            return
        }
        dismissMenu()
        val ctx = hostContext ?: return
        val ticket = windows.claim(OverlayWindowOwner.Role.MENU) ?: return
        slideAnim?.cancel()
        removeBubble()
        val menuTarget = machine.last
        val rows = menuItems(menuTarget).map { item ->
            PetMenuView.Row(menuLabel(item), item = item, shortLabel = wheelLabel(item)) { if (alive(ticket)) onMenu(item, ticket, menuTarget) }
        }
        val view = PetMenuView(ctx, rows, onOutside = { if (alive(ticket)) dismissMenu(animated = true) }, motion = ::animationsOn)
        val params = baseParams(0, 0, WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH)
        if (!placeMenu(view, params)) return
        try {
            val manager = wm ?: return
            if (!installWindow(ticket, view, manager, params)) return
        } catch (e: Exception) {
            Log.w(TAG, "menu add failed", e)
            return
        }
        menuView = view
        menuParams = params
        if (rawX != null && rawY != null) view.beginPointer(rawX, rawY)
        scheduleMenuTimeout(ticket)
    }

    private fun placeMenu(view: PetMenuView, params: WindowManager.LayoutParams): Boolean {
        val ctx = hostContext ?: return false
        val pv = petView ?: return false
        val pp = petParams ?: return false
        val rest = restPos(pv, pp)
        val body = loaded?.frames?.body?.at(rest) ?: return false
        val g = PetWheelGeometry.fit(
            if (view.hosts) machine.last?.hosts?.size?.coerceAtLeast(1) ?: 1 else menuItems(machine.last).size,
            dock.side, body.centerX.toFloat(), body.centerY.toFloat(), safeArea(), ctx.resources.displayMetrics.density,
            if (view.hosts) 2f else ctx.resources.configuration.fontScale,
            view.labelWidth(),
        )
        view.place(g)
        params.width = g.bounds.width
        params.height = g.bounds.height
        params.x = g.bounds.left
        params.y = g.bounds.top
        return true
    }

    private fun menuLabel(item: PetMenuItem): String = AppStrings.get(app, when (item) {
        PetMenuItem.ASK -> R.string.pet_ask
        PetMenuItem.NEW_CHAT -> R.string.pet_new_chat
        PetMenuItem.SCREENSHOT -> R.string.pet_screenshot
        PetMenuItem.STOP -> R.string.pet_stop
        PetMenuItem.SWITCH_HOST -> R.string.pet_switch_host
        PetMenuItem.SNOOZE -> R.string.pet_snooze
        PetMenuItem.SETTINGS -> R.string.pet_settings
    })

    private fun wheelLabel(item: PetMenuItem): String = AppStrings.get(app, when (item) {
        PetMenuItem.ASK -> R.string.pet_ask
        PetMenuItem.NEW_CHAT -> R.string.pet_new_chat
        PetMenuItem.SCREENSHOT -> R.string.pet_wheel_screenshot
        PetMenuItem.STOP -> R.string.pet_wheel_stop
        PetMenuItem.SWITCH_HOST -> R.string.pet_wheel_hosts
        PetMenuItem.SNOOZE -> R.string.pet_wheel_snooze
        PetMenuItem.SETTINGS -> R.string.pet_wheel_settings
    })

    private fun onMenu(item: PetMenuItem, ticket: OverlayWindowOwner.Ticket, target: PetPush?) {
        machine.onTouch(now())
        when (item) {
            PetMenuItem.ASK, PetMenuItem.NEW_CHAT -> {
                dismissMenu(animated = true)
                showAsk(fresh = item == PetMenuItem.NEW_CHAT)
            }
            PetMenuItem.SCREENSHOT -> captureScreenshot()
            PetMenuItem.STOP -> {
                dismissMenu(animated = true)
                callDart("stop", mapOf("host" to target?.host, "sessionId" to target?.sessionId)) { evaluate() }
            }
            PetMenuItem.SWITCH_HOST -> showHosts(ticket)
            PetMenuItem.SNOOZE -> {
                dismissMenu()
                snoozeToday()
            }
            PetMenuItem.SETTINGS -> {
                dismissMenu()
                pendingSettings = true
                open(null, null, null)
                if (started > 0) deliverSettings()
            }
        }
    }

    /** 切换主机: the menu's rows become the hosts, the one in use muted. */
    /** The rows this phone can offer: the accessibility screenshot exists from Android 11. */
    private fun menuItems(push: PetPush?) = PetMenuItem.of(push, screenshots = Build.VERSION.SDK_INT >= 30)

    private fun showHosts(ticket: OverlayWindowOwner.Ticket) {
        val view = menuView ?: return
        val params = menuParams ?: return
        view.setRows(machine.last?.hosts.orEmpty().map { h ->
            PetMenuView.Row(h.label, muted = h.current) {
                if (alive(ticket)) {
                    dismissMenu()
                    if (!h.current) callDart("switchHost", mapOf("host" to h.ref)) { evaluate() }
                }
            }
        })
        // Rows and buttons only match again once placed; a list that can't be shown goes.
        if (!placeMenu(view, params)) { dismissMenu(); return }
        update(view, params)
        scheduleMenuTimeout(ticket)
    }

    private fun scheduleMenuTimeout(ticket: OverlayWindowOwner.Ticket) {
        menuTimeout?.let(main::removeCallbacks)
        Runnable { if (alive(ticket)) dismissMenu() }.also {
            menuTimeout = it
            main.postDelayed(it, MENU_MS)
        }
    }

    private fun dismissMenu(animated: Boolean = false) {
        menuTimeout?.let(main::removeCallbacks)
        menuTimeout = null
        closingMenu?.let { remove(it) }
        closingMenu = null
        val view = menuView
        menuView = null
        menuParams = null
        if (view != null) {
            if (animated && animationsOn() && alive(windowTickets[view])) {
                closingMenu = view
                view.close {
                    remove(view)
                    if (closingMenu === view) closingMenu = null
                }
            } else remove(view)
        }
    }

    private fun captureScreenshot() {
        val ticket = petTicket
        if (!alive(ticket)) return
        val request = capture.begin() ?: return
        // No exit animation may remain in the image. INVISIBLE keeps the PET generation alive
        // for EntryActivity's authenticated openIntent without drawing or intercepting touches.
        dismissMenu()
        removeBubble()
        removeAsk()
        hideTarget()
        stopLoop()
        stopCompanion()
        petView?.animate()?.cancel()
        petView?.visibility = View.INVISIBLE
        speaksForResults = false
        publishStatus()
        PetScreenshot.capture(app) { result ->
            val accepted = capture.finish(request) && alive(ticket) && interactive() && machine.enabled &&
                started == 0 && !machine.appForeground && !machine.snoozed(now()) &&
                // A phone task that began meanwhile keeps the screen; DSH Go doesn't jump in front of it.
                PhoneControl.peek()?.foregroundLine() == null
            val path = result.path
            if (accepted && path != null) {
                openIntent(EntryActivity.screenshot(app, path), null)
            } else {
                if (path != null) PetScreenshot.discard(app, path)
                if (accepted) Toast.makeText(app, AppStrings.get(app, when (result.error) {
                    PetScreenshot.Error.UNSUPPORTED -> R.string.pet_screenshot_unsupported
                    PetScreenshot.Error.ACCESSIBILITY_REQUIRED -> R.string.pet_screenshot_accessibility
                    PetScreenshot.Error.SECURE -> R.string.pet_screenshot_secure
                    PetScreenshot.Error.BUSY -> R.string.pet_screenshot_busy
                    PetScreenshot.Error.TIMEOUT -> R.string.pet_screenshot_timeout
                    else -> R.string.pet_screenshot_failed
                }), Toast.LENGTH_LONG).show()
            }
            evaluate()
        }
    }

    private fun deliverSettings() {
        if (!pendingSettings) return
        pendingSettings = false
        listener?.onOpenSettings()
    }

    private fun callDart(method: String, args: Any?, reply: (Any?) -> Unit) {
        val l = listener ?: return reply(null)
        l.call(method, args, reply)
    }

    // ---- 问一句 ---------------------------------------------------------------------------------

    private var askView: AskBarView? = null
    private var askParams: WindowManager.LayoutParams? = null

    /** Where the bar sits with the keyboard down. */
    private var askY = 0
    private var askFresh = false

    /** Dart's answer to `askTarget`; null until it comes. */
    private var askTarget: AskTarget? = null

    /** What was typed: kept when the bar closes, until it is sent. */
    private val askDraftState = PetAskDraft()
    private var askDraft: String
        get() = askDraftState.text
        set(value) { askDraftState.edit(value) }
    private var voiceHandoff = 0L
    private var pendingVoice = false
    private var returnAsk = false
    private var askRequest = 0L

    /**
     * Opens the bar beside the docked pet ([fresh]: on 「新对话」), focused, the keyboard up; asks
     * Dart where a send would go meanwhile.
     */
    private fun showAsk(fresh: Boolean) {
        if (capture.inFlight || !interactive()) return
        removeAsk()
        val ctx = hostContext ?: return
        val pv = petView ?: return
        val f = loaded?.frames ?: return
        val ticket = windows.claim(OverlayWindowOwner.Role.ASK) ?: return
        askFresh = fresh
        askTarget = null
        val view = AskBarView(ctx, askListener(ticket))
        view.input.setText(askDraft)
        view.setState(problem = true, sending = askDraftState.sending)
        view.input.setSelection(view.input.length())
        view.setTarget(null, switchShown = false, on = fresh)
        val area = safeArea()
        val gap = ctx.dp(8f)
        val margin = edge(ctx)
        val at = if (pv.companionGeometry != null) petParams?.let { restPos(pv, it) } ?: return
            else EdgeSnap.position(dock, pv.reach, area, margin)
        val body = f.body.at(at)
        val pet = ScreenRect(at.x + pv.reach.left, body.top, at.x + pv.reach.right, body.bottom)
        val w = AskPlace.width(pet, dock.side, area, gap, margin, ctx.dp(ASK_MIN_DP), ctx.dp(ASK_MAX_DP))
        val (_, h) = view.measureFor(w)
        val pos = AskPlace.beside(pet, dock.side, w, h, area, gap, margin)
        // The one window that takes focus, and only while it is open: the keyboard needs it.
        val params = baseParams(w, WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH).apply {
            flags = flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
            x = pos.x
            y = pos.y
        }
        try {
            val manager = wm ?: return
            if (!installWindow(ticket, view, manager, params)) return
        } catch (e: Exception) {
            Log.w(TAG, "ask bar add failed", e)
            return
        }
        askView = view
        askParams = params
        askY = pos.y
        dismissMenu()
        removeBubble()
        if (animationsOn()) {
            view.alpha = 0f
            view.animate().alpha(1f).setDuration(150).setInterpolator(easing).start()
        }
        view.input.requestFocus()
        view.post { if (askView === view) view.context.getSystemService(InputMethodManager::class.java)?.showSoftInput(view.input, 0) }
        evaluate()
        val request = ++askRequest
        callDart("askTarget", mapOf("fresh" to fresh)) { raw ->
            if (request != askRequest || askView !== view) return@callDart
            // No answer: nothing known to stand in the way; a send hands the text to the app.
            askTarget = AskTarget.fromMap(raw) ?: AskTarget(null, null, null, AskTarget.VOICE_OFF)
            showTarget(view)
        }
    }

    private fun showTarget(view: AskBarView) {
        val t = askTarget ?: return
        val fresh = askFresh || t.current == null
        view.setTarget(t.chat(fresh)?.line ?: AppStrings.get(app, R.string.pet_new_chat), t.canSwitch, fresh)
        view.setStatus(t.problem, error = t.problem != null)
        view.setState(problem = t.problem != null)
    }

    private fun askListener(ticket: OverlayWindowOwner.Ticket) = object : AskBarView.Listener {
        override fun onSend(text: String) {
            if (alive(ticket)) sendAsk(text)
        }

        override fun onSwitch() {
            if (!alive(ticket)) return
            askFresh = !askFresh
            askView?.let(::showTarget)
        }

        override fun onMic(down: Boolean, cancelled: Boolean) {
            if (!alive(ticket)) return
            if (down) micDown() else micUp(cancelled)
        }

        override fun onDraft(text: String) {
            if (alive(ticket)) {
                askDraft = text
                prefs.edit().putString("ask_draft", text).apply()
            }
        }

        override fun onClose() {
            if (!alive(ticket)) return
            removeAsk()
            evaluate()
        }

        override fun onIme(overlap: Int, visible: Boolean) {
            if (alive(ticket)) liftAsk(overlap, visible)
        }
    }

    /** Above the keyboard while it covers the bar, back in place once it goes. */
    private fun liftAsk(overlap: Int, visible: Boolean) {
        val v = askView ?: return
        val p = askParams ?: return
        val ctx = hostContext ?: return
        // Use the laid-out position, not params.y (which may already contain a pending move).
        val location = IntArray(2).also(v::getLocationOnScreen)
        val y = when {
            overlap > 0 -> AskPlace.lift(askY, location[1], overlap, ctx.dp(8f), safeArea(), edge(ctx))
            visible -> p.y
            else -> askY
        }
        if (y == p.y) return
        p.y = y
        update(v, p)
    }

    /**
     * Sends through Dart's own send path. Sent: the bar goes and the pet thinks. Refused (the
     * engine is off, no host, the send failed): the bar says why and keeps the text. No Dart to
     * answer: the app comes up with the text in a new chat's composer, unsent.
     */
    private fun sendAsk(text: String) {
        val view = askView ?: return
        val send = askDraftState.beginSend(text) ?: return
        machine.onTouch(now())
        val fresh = askFresh || askTarget?.current == null
        val chat = askTarget?.chat(fresh)
        view.setState(sending = true)
        view.setStatus(AppStrings.get(app, R.string.pet_ask_sending))
        val request = askRequest
        val args = mapOf("offer" to askTarget?.offer, "text" to text, "fresh" to (chat?.sessionId == null), "sessionId" to chat?.sessionId, "host" to chat?.host)
        callDart("ask", args) { raw ->
            val r = raw as? Map<*, *>
            val completion = askDraftState.finish(send, accepted = r?.get("sent") == true) ?: return@callDart
            val current = request == askRequest && askView === view
            askView?.setState(sending = false)
            when {
                r?.get("sent") == true -> {
                    Log.i(TAG, "ask sent (${if (chat?.sessionId == null) "new chat" else "same chat"})")
                    if (completion.cleared) {
                        // A reopened bar shares this draft. Clear its copy too so closing it
                        // cannot resurrect text the host already accepted.
                        askView?.input?.setText("")
                        prefs.edit().remove("ask_draft").apply()
                        if (current) removeAsk()
                    }
                }
                r != null -> if (current) {
                    view.setState(sending = false)
                    view.setStatus((r["problem"] as? String) ?: AppStrings.get(app, R.string.pet_ask_failed), error = true)
                }
                // Closed meanwhile, the text stays the bar's draft (removeAsk kept it).
                current -> {
                    removeAsk()
                    openIntent(EntryActivity.newChat(app).putExtra(EntryActivity.EXTRA_TEXT, text), null)
                }
            }
            evaluate()
        }
    }

    private fun removeAsk() {
        askRequest++
        stopRecording()
        askView?.let { v ->
            askDraft = v.input.text?.toString() ?: askDraft
            remove(v)
        }
        askView = null
        askParams = null
        askTarget = null
    }

    // ---- 语音问 ---------------------------------------------------------------------------------

    private var recorder: WavRecorder? = null
    private var recorderMic = 0
    private var recording = 0L

    /** Hold to talk: the offline voice model's recorder, as the chat's dictation records for it. */
    private fun micDown() {
        val view = askView ?: return
        machine.onTouch(now())
        val voice = askTarget?.voice
        when {
            voice == AskTarget.VOICE_MISSING -> view.setStatus(AppStrings.get(app, R.string.pet_ask_voice_missing))
            voice != AskTarget.VOICE_READY -> view.setStatus(AppStrings.get(app, R.string.pet_ask_voice_off))
            app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> foregroundVoice(view)
            else -> startRecording(view)
        }
    }

    private fun startRecording(view: AskBarView) {
        stopRecording()
        val gen = ++recording
        lateinit var r: WavRecorder
        r = WavRecorder(
            maxSeconds = 60,
            onLevel = {},
            onLimit = { main.post { if (gen == recording) micUp(cancelled = false) } },
            onError = { main.post {
                if (gen == recording && recorder === r) {
                    stopRecording()
                    if (askView === view) view.setStatus(AppStrings.get(app, R.string.pet_ask_not_heard), error = true)
                }
            } },
        )
        val mic = MicArbiter.beginDictation()
        if (!runCatching { r.start() }.getOrDefault(false)) {
            MicArbiter.endDictation(mic)
            foregroundVoice(view)
            return
        }
        recorder = r
        recorderMic = mic
        view.setState(listening = true)
        view.setStatus(AppStrings.get(app, R.string.pet_ask_listening))
        main.postDelayed({ if (gen == recording && recorder === r) checkSilenced(r, view) }, SILENCE_CHECK_MS)
    }

    /**
     * Android hands a background app silence instead of the microphone (while-in-use, docs/design/
     * pets.md §6.3): the recording then goes to the app, brought to the front with the text so far.
     */
    private fun checkSilenced(r: WavRecorder, view: AskBarView) {
        if (Build.VERSION.SDK_INT < 29) return
        val am = app.getSystemService(AudioManager::class.java) ?: return
        val mine = am.activeRecordingConfigurations.filter { it.clientAudioSessionId == r.sessionId }
        val silenced = mine.any { it.isClientSilenced }
        Log.i(TAG, "pet mic: configs=${mine.size} silenced=$silenced dshService=${DshService.isRunning} petService=${PetOverlayService.running}")
        if (!silenced) return
        foregroundVoice(view)
    }

    private fun foregroundVoice(view: AskBarView) {
        if (askView !== view) return
        stopRecording()
        // Keep the overlay draft until the app accepts the handoff. A vendor
        // may block Activity launch and notifications at the same time.
        removeAsk()
        evaluate()
        pendingVoice = true
        openIntent(EntryActivity.openApp(app), null)
    }

    /** Let go: the recording goes to the voice model, its words into the box. Slid off: dropped. */
    private fun micUp(cancelled: Boolean) {
        val r = recorder ?: return
        val view = askView
        val mic = recorderMic
        recorder = null
        val gen = ++recording
        view?.setState(listening = false)
        if (cancelled) {
            worker.execute {
                runCatching { r.discard() }
                main.post { MicArbiter.endDictation(mic) }
            }
            view?.setStatus(null)
            return
        }
        view?.setStatus(AppStrings.get(app, R.string.pet_ask_transcribing))
        worker.execute {
            val wav = runCatching { r.finish() }.getOrNull()
            main.post {
                MicArbiter.endDictation(mic)
                if (gen != recording || view == null || askView !== view) return@post
                if (wav == null || wav.size < MIN_WAV_BYTES) {
                    view.setStatus(AppStrings.get(app, R.string.pet_ask_not_heard))
                    return@post
                }
                callDart("transcribe", mapOf("wav" to wav)) { raw ->
                    if (gen != recording || askView !== view) return@callDart
                    val r2 = raw as? Map<*, *>
                    val words = (r2?.get("text") as? String)?.trim()
                    if (words.isNullOrEmpty()) {
                        view.setStatus((r2?.get("problem") as? String) ?: AppStrings.get(app, R.string.pet_ask_not_heard), error = r2?.get("problem") != null)
                    } else {
                        view.setStatus(null)
                        view.insert(words)
                    }
                }
            }
        }
    }

    private fun stopRecording() {
        recording++
        val r = recorder ?: return
        val mic = recorderMic
        recorder = null
        askView?.setState(listening = false)
        worker.execute {
            runCatching { r.discard() }
            main.post { MicArbiter.endDictation(mic) }
        }
    }

    // ---- opening the app ------------------------------------------------------------------------

    /**
     * Opens [sessionId] (or just the app) through EntryActivity. A tap on an overlay may start an
     * activity on stock Android, but some vendors block 「后台弹出界面」 on their own: when the app
     * isn't up shortly after, a notification takes the tap instead (as SystemActions.kt does).
     */
    private fun open(sessionId: String?, host: String?, title: String?) = openIntent(
        if (sessionId != null) EntryActivity.openChat(app, sessionId, host) else EntryActivity.openApp(app),
        title,
    )

    private fun openIntent(entry: Intent, title: String?) {
        val token = windows.openToken() ?: return
        val intent = entry.putExtra(EntryActivity.EXTRA_PET_GENERATION, token).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            app.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "open failed", e)
            if (windows.acceptsOpen(token)) postOpenNotice(intent, title)
            return
        }
        main.postDelayed({ if (started == 0 && windows.acceptsOpen(token)) postOpenNotice(intent, title) }, OPEN_CHECK_MS)
    }

    fun acceptsOpen(token: String?) = windows.acceptsOpen(token)

    private fun postOpenNotice(intent: Intent, title: String?) {
        val nm = app.getSystemService(NotificationManager::class.java) ?: return
        if (!nm.areNotificationsEnabled()) return
        nm.createNotificationChannel(NotificationChannel(CHANNEL_OPEN, AppStrings.get(app, R.string.pet_open_channel), NotificationManager.IMPORTANCE_HIGH))
        val pi = PendingIntent.getActivity(app, NOTICE_ID, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        openPendingIntent = pi
        val n = Notification.Builder(app, CHANNEL_OPEN)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(title ?: AppStrings.APP_NAME)
            .setContentText(AppStrings.get(app, R.string.pet_tap_open))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .build()
        nm.notify(NOTICE_ID, n)
    }

    // ---- system signals -------------------------------------------------------------------------

    private fun interactive(): Boolean {
        val pm = app.getSystemService(PowerManager::class.java)
        val km = app.getSystemService(KeyguardManager::class.java)
        return (pm?.isInteractive != false) && (km?.isKeyguardLocked != true)
    }

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == PowerManager.ACTION_POWER_SAVE_MODE_CHANGED && companionEndpoint == null) return
            if (intent.action == Intent.ACTION_SCREEN_OFF || !interactive()) capture.invalidate()
            evaluate()
        }
    }

    private val config = object : ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: Configuration) {
            val diff = lastConfig?.diff(newConfig) ?: 0
            lastConfig = Configuration(newConfig)
            val relevant = ActivityInfo.CONFIG_ORIENTATION or ActivityInfo.CONFIG_SCREEN_SIZE or ActivityInfo.CONFIG_UI_MODE or ActivityInfo.CONFIG_DENSITY or ActivityInfo.CONFIG_FONT_SCALE
            if (diff and relevant == 0) return
            capture.invalidate()
            removeWindows()
            if (diff and ActivityInfo.CONFIG_DENSITY != 0) {
                loadRequest++
                loadingKey = null
                loaded?.release()
                loaded = null
                loadedKey = null
                machine.last?.let { p -> p.packId?.let { ensurePack(it, p.size) } }
            }
            evaluate()
        }

        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = Unit

        override fun onTrimMemory(level: Int) {
            if (petView == null) loaded?.release()
        }
    }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            if (activity !is MainActivity) return
            started++
            capture.invalidate()
            machine.onForeground(true, now())
            app.getSystemService(NotificationManager::class.java)?.cancel(NOTICE_ID)
            evaluate()
            deliverSettings()
        }

        override fun onActivityStopped(activity: Activity) {
            if (activity !is MainActivity) return
            started = (started - 1).coerceAtLeast(0)
            if (started == 0) {
                machine.onForeground(false, now())
                if (returnAsk) machine.onTouch(now())
                evaluate()
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) {
            if (activity !is MainActivity || !pendingVoice) return
            pendingVoice = false
            val owner = listener
            val generation = ++voiceHandoff
            callDart("voiceFallback", mapOf("text" to askDraft)) { raw ->
                if (listener !== owner || generation != voiceHandoff) return@callDart
                val text = (raw as? Map<*, *>)?.get("text") as? String ?: return@callDart
                val limit = AskBarView.MAX_TEXT
                val cut = if (text.length > limit && text[limit - 1].isHighSurrogate() && text[limit].isLowSurrogate()) limit - 1 else limit
                askDraft = text.take(cut)
                prefs.edit().putString("ask_draft", askDraft).apply()
                returnAsk = true
                activity.moveTaskToBack(true)
            }
        }
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    /** For the debug probe: 问一句's bar, as the menu opens it. */
    fun probeAsk(fresh: Boolean) {
        if (alive(petTicket)) showAsk(fresh)
    }

    /** For the debug probe: what the window is doing now. */
    fun debugState(): Map<String, Any?> = mapOf(
        "visibility" to lastVisibility.name.lowercase(),
        "why" to lastWhy,
        "host" to host.name.lowercase(),
        "x" to petParams?.x, "y" to petParams?.y, "w" to petParams?.width, "h" to petParams?.height,
        "frame" to petView?.frame?.let { "${it.left},${it.top} ${it.width}x${it.height}" },
        "hit" to loaded?.frames?.hit(petView?.shown)?.let { "${it.left},${it.top} ${it.width}x${it.height}" },
        "shown" to petView?.shown?.name,
        "dragging" to dragging,
        "dock" to "${dock.side.name.lowercase()}@${"%.2f".format(dock.yFraction)}",
        "dimmed" to dimmed,
        "alpha" to petView?.alpha,
        "looping" to looping,
        "bubble" to bubbleId,
        "bubbleAsk" to machine.bubbles.current(now())?.ask?.let { "${it.kind}:${it.approvable}:${it.choices.size}" },
        "menu" to (menuView != null),
        "ask" to askView?.let { askParams?.let { p -> "${p.x},${p.y} ${p.width}w" } ?: "open" },
        "askTarget" to askTarget?.let { it.chat(askFresh || it.current == null)?.line },
        "answering" to answerState.bubbleId,
        "service" to PetOverlayService.running,
        "scale" to loaded?.screenScale,
        "pack" to loadedKey,
        "speaksForResults" to speaksForResults,
        "windowGeneration" to windows.generation,
        "registeredWindows" to windows.registeredWindows,
        "pendingRemovals" to windows.pendingRemovals,
        "lastRemovalFailure" to windows.lastRemovalFailure,
    )
}
