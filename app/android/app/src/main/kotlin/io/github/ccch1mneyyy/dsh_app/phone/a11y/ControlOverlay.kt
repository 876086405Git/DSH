// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: a status control at the top in three forms (ball, capsule, card) on one
// morphing surface, or the phone's own island instead; a beam round the screen's edge while it
// shows; separate confirm and handoff cards; buttons that refuse injected or obscured touches;
// pass-through and hide hooks for the Actuator and screenshots; blocking UserGate calls.

package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.phone.background.BackgroundPreview
import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.content.res.Resources
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.util.DisplayMetrics
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.github.ccch1mneyyy.dsh_app.phone.ConfirmRequest
import io.github.ccch1mneyyy.dsh_app.phone.Decision
import io.github.ccch1mneyyy.dsh_app.links.LinkTrampolineActivity
import io.github.ccch1mneyyy.dsh_app.phone.HandoffCause
import io.github.ccch1mneyyy.dsh_app.phone.HandoffResult
import io.github.ccch1mneyyy.dsh_app.notify.LiveActivity
import io.github.ccch1mneyyy.dsh_app.phone.PhoneControl
import io.github.ccch1mneyyy.dsh_app.phone.PhoneRegistry
import io.github.ccch1mneyyy.dsh_app.phone.PhoneThoughts
import io.github.ccch1mneyyy.dsh_app.phone.PhoneUnlocks
import io.github.ccch1mneyyy.dsh_app.phone.UserGate
import io.github.ccch1mneyyy.dsh_app.phone.PhonePromptPresenter
import io.github.ccch1mneyyy.dsh_app.phone.PhonePromptUi
import io.github.ccch1mneyyy.dsh_app.phone.PromptPresentation
import io.github.ccch1mneyyy.dsh_app.phone.MainThreadCall
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import io.github.ccch1mneyyy.dsh_app.pet.WindowPos
import kotlin.math.roundToInt
import io.github.ccch1mneyyy.dsh_app.theme.ThemeAccent
import android.animation.ValueAnimator
import android.graphics.Rect
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The main-screen [UserGate]: TYPE_ACCESSIBILITY_OVERLAY windows owned by the service
 * (no SYSTEM_ALERT_WINDOW). Blocking calls come from the bridge worker; all views live on
 * the main thread.
 *
 * While a task runs the person sees one control, in three forms (docs/design/phone-overlay.md):
 * the capsule with the line, 暂停 and 回到 DSH Go ([OverlayCapsule]), an island at the top centre
 * until the person drags it elsewhere, the card it grows into (what DSH thinks and its steps), and
 * the ball it folds into ([OverlayBall]), with a band of light round the screen's edge
 * ([EdgeBeam]). Where the phone has its own island and shows the task there ([LiveActivity]), that
 * island takes the capsule's and the ball's place. [FoldClock] decides the form; this class plays
 * the morphs between them, keeps the control where the person put it and clear of the keyboard and
 * the confirm card, and keeps 停止 one step away in every form.
 */
internal class ControlOverlay(private val service: AccessibilityService) : UserGate, PhonePromptPresenter {
    private val main = Handler(Looper.getMainLooper())
    private val wm = service.getSystemService(WindowManager::class.java)

    /** Keeps the screen on while the phone's own island shows instead of the capsule ([syncAwake]). */
    private var awake: View? = null
    private val a11y = service.getSystemService(AccessibilityManager::class.java)
    private val ime = service.getSystemService(InputMethodManager::class.java)

    /** 暂停 is on: the driver refuses actions until 继续. */
    @Volatile var paused = false
        private set

    /** The person is typing into 插话: actions wait so the keyboard isn't fought over. */
    @Volatile var editing = false
        private set

    /** Debug probe only: draw in the dark (true) or light (false) palette whatever the system says. */
    @Volatile var debugDark: Boolean? = null

    /** Debug probe only: show these lifted limits instead of the person's. */
    @Volatile var debugUnlocks: PhoneUnlocks? = null

    /** Debug probe only: the task's app, as the core would have set it. */
    @Volatile var debugApp: String? = null

    /** Debug probe only: no timer changes the form (screenshots of the card). */
    @Volatile var debugFreeze = false

    /** Debug probe only: let an injected tap reach a guarded button to observe the other checks. */
    @Volatile var debugIgnoreInjectGuard = false

    /** Last guarded-button verdict, for the debug probe. */
    @Volatile var lastGuardVerdict: String? = null
        private set

    // ---- main-thread state ----
    private var statusText: String? = null
    private val statusOwnership = StatusOwnership()
    private var line: StatusLine? = null
    private val steps = StepHistory()
    private var stoppedNote = false

    /** 「已发给 DSH：…」 for a moment after 插话, in the line's place. */
    private var steerNote: String? = null
    private var pill: OverlayCapsule? = null

    /** The background screen, shown in the capsule's place (§13); null when not showing. */
    private var screen: OverlayScreen? = null

    /** The task the time on the island counts from, and when it started (uptime ms). */
    private var timedTask: Long? = null
    private var taskStartedAt: Long? = null

    /** App icons by label, as the island shows them (null: none found for that label). */
    private val icons = HashMap<String, android.graphics.drawable.Drawable?>()
    private val previewOwner = Any()
    private var previewTaskId: Long? = null
    private var previewPill: OverlayCapsule? = null
    @Volatile private var destroying = false
    private val previewDecoder = OverlayPreviewDecoder { bitmap ->
        val w = screen?.takeIf { previewToScreen && !destroying }
        if (w == null) bitmap?.recycle()
        else w.showFrame(bitmap, if (bitmap == null) s(R.string.overlay_preview_unavailable) else null)
    }
    private var confirmCard: Card? = null
    private var handoffCard: Card? = null
    private var pendingConfirm: Pending<Decision>? = null
    private var pendingHandoff: Pending<HandoffResult>? = null
    @Volatile private var sharedPrompt: PromptPresentation? = null
    private var passThrough = false
    private val captureVisibility = CaptureVisibility()
    private val captureHidden: Boolean get() = captureVisibility.hidden
    private var darkBuilt: Boolean? = null

    // The form: FoldClock decides, the morphs follow.
    private val fold = FoldClock()
    private var ball: OverlayBall? = null

    /** The beam round the screen's edge, on exactly while the control shows for a live task (§12). */
    private val beam = EdgeBeam(service, wm)

    /** The top of a keyboard on screen (any app's, or 插话's), from the service's windows; null when none shows. */
    private var imeTop: Int? = null
    private val imeRect = Rect()

    /** The capsule gliding to where it rests now: over (or back from) the keyboard or the confirm card, down for the card's room, to an anchor after a drag. */
    private var lift: ValueAnimator? = null

    /** Where the person put the capsule: its anchor across and its height (kept across tasks, [OverlayPrefs]). */
    private var spot: CapsuleSpot

    /** While the capsule is dragged: its steady left and centre y on screen when the drag started, and now. */
    private var dragFrom: WindowPos? = null
    private var dragAt: WindowPos? = null

    /** The confirm card's height settled or changed: the capsule and a resting ball keep clear of it. */
    private val obstacleWatch = View.OnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
        if (bottom - top != oldBottom - oldTop) main.post { avoidObstacles() }
    }

    /** What is on screen: the capsule (or card), or the ball (lags [fold] while a fold or unfold plays). */
    private var ballShown = false

    /** The ball is gliding back to the capsule's end; its glide's end swaps the windows. A finger stops it. */
    private var unfolding = false
    private val foldTick = Runnable { onFoldTick() }

    /** A narrower line may shrink the capsule now. */
    private val shrinkTick = Runnable { renderPill() }

    // 闲置时不透明度 (the ball's), 「闲置时自动收起」, 「屏幕边缘光效」 and 「用系统灵动岛显示」
    // (设置 → 手机操控 → 悬浮条), live while showing.
    private val overlayPrefs = OverlayPrefs.prefs(service)
    private var idleOpacity = OverlayPrefs.from(overlayPrefs).idleOpacity
    private var edgeGlow = OverlayPrefs.from(overlayPrefs).edgeGlow
    private var systemIsland = OverlayPrefs.from(overlayPrefs).systemIsland
    private val prefsListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == OverlayPrefs.K_OPACITY || key == OverlayPrefs.K_AUTO_FOLD || key == OverlayPrefs.K_EDGE_GLOW ||
            key == OverlayPrefs.K_SYSTEM_ISLAND) {
            main.post { onPrefsChanged() }
        }
    }

    /** The phone's own island came or went (LiveActivity found out on its thread), or DSH said something new. */
    private val islandListener: () -> Unit = { main.post { if (pill != null) syncWindows() } }
    private val thoughtListener: () -> Unit = { main.post { if (pill != null && !fold.folded) renderPill() } }

    init {
        spot = OverlayPrefs.spot(overlayPrefs)
        fold.setAutoFold(OverlayPrefs.from(overlayPrefs).autoFold, SystemClock.uptimeMillis())
        overlayPrefs.registerOnSharedPreferenceChangeListener(prefsListener)
        LiveActivity.islandListener = islandListener
        PhoneThoughts.listener = thoughtListener
        // Ask now, so the first task already knows whether the phone's own island takes it.
        LiveActivity.islandShows(service)
    }

    private class Pending<T : Any> {
        private val latch = CountDownLatch(1)
        @Volatile var value: T? = null
            private set

        fun resolve(v: T): Boolean {
            synchronized(this) { if (value != null) return false; value = v }
            latch.countDown()
            return true
        }

        fun await(ms: Long): T? { latch.await(ms, TimeUnit.MILLISECONDS); return value }
    }

    private class Card(val root: FrameLayout, val params: WindowManager.LayoutParams, val tick: Runnable?)

    // ---- UserGate --------------------------------------------------------------------------------

    override fun status(text: String?) = status(text) { update -> update(); true }

    override fun status(text: String?, ifCurrent: (() -> Unit) -> Boolean) {
        main.post {
            // This runnable and close apply on the same queue. Never hold the task lock
            // over WindowManager work or enqueue a second, unguarded status runnable.
            // The pill's 暂停 / 停止 / 插话 are bound to this status's own task, captured inside its guard.
            if (!statusOwnership.publish(ifCurrent) { PhoneRegistry.controlListener?.shownControls() }) return@post
            if (editing && statusOwnership.editingControls == null) endEditing()
            statusText = text
            paused = statusOwnership.controls?.isPaused() == true
            setStopped(false)
            if (text == null) {
                statusOwnership.clear()
                paused = false
                line = null
                steps.clear()
                removePill(animated = true, preservePrompts = true)
            } else {
                val l = StatusLines(AppStrings.get(service, R.string.phone_waived_status), AppStrings.get(service, R.string.phone_acting)).parse(text)
                line = l
                steps.add(l)
                showPill()
            }
        }
    }

    override fun clearStatus(ifCurrent: (() -> Unit) -> Unit) {
        main.post {
            // The displayed status can be stale even if this cleanup request lost selection.
            // Prompt cards and their CONFIRM/HANDOFF holds belong to separate tickets.
            val stale = statusOwnership.takeStale()
            var accepted = false
            ifCurrent { accepted = true }
            if (stale || accepted) {
                statusOwnership.clear()
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                paused = false
                removePill(animated = true, preservePrompts = true)
            }
        }
    }

    /** The turn that drove the phone is over: every window goes, pending questions answer STOP. */
    override fun close(ifCurrent: (() -> Unit) -> Unit) {
        val shared = sharedPrompt
        val confirm = pendingConfirm
        val handoff = pendingHandoff
        main.post {
            // A -> stop -> B can invalidate A's cleanup ticket while A's status is
            // still displayed. Retire that status by its own owner, without touching B's cards.
            if (statusOwnership.takeStale()) {
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                removePill(animated = false, preservePrompts = true)
            }
            var cleanupCurrent = false
            ifCurrent { cleanupCurrent = true }
            if (cleanupCurrent) {
                // A new pre-tool engine prompt can share an inactive task id. Remove only the
                // questions captured by this cleanup, even when the task itself has not started.
                if (sharedPrompt === shared) {
                    shared?.ticket?.stop()
                    if (shared != null) { sharedPrompt = null; dismissConfirm() }
                }
                if (sharedPrompt == null && pendingConfirm === confirm) {
                    confirm?.resolve(Decision.STOP)
                    dismissConfirm()
                }
                if (pendingHandoff === handoff) {
                    handoff?.resolve(HandoffResult.STOP)
                    dismissHandoff()
                }
                statusOwnership.clear()
                statusText = null
                line = null
                steps.clear()
                setStopped(false)
                paused = false
                removePill(animated = true)
            }
        }
    }

    override fun confirm(request: ConfirmRequest): Decision {
        PhoneRegistry.promptGate?.let { return it.confirm(request) }
        if (Looper.myLooper() == Looper.getMainLooper()) { Log.w(TAG, "confirm() on the main thread: denied"); return Decision.DENY }
        val pending = Pending<Decision>()
        val shown = onMain(1_500) { showConfirm(request, pending) } == true
        if (!shown) {
            pending.resolve(Decision.UNAVAILABLE)
            main.post { if (pendingConfirm === pending) dismissConfirm() }
            Log.w(TAG, "confirm overlay could not be shown; falling back to the notification gate")
            return PhoneRegistry.notificationGate?.confirm(request) ?: Decision.DENY
        }
        val decision = try {
            pending.await(request.timeoutMs + 1_500) ?: run { pending.resolve(Decision.DENY); pending.value!! }
        } catch (_: InterruptedException) {
            // The core's stop interrupts the worker: answer STOP and keep the flag for the caller.
            pending.resolve(Decision.STOP)
            Thread.currentThread().interrupt()
            pending.value!!
        }
        main.post { if (pendingConfirm === pending) dismissConfirm() }
        return decision
    }

    override fun handoff(reason: String, timeoutMs: Long): HandoffResult = handoff(reason, timeoutMs, null)

    override fun handoff(reason: String, timeoutMs: Long, cause: HandoffCause?): HandoffResult {
        PhoneRegistry.promptGate?.let { return it.handoff(reason, timeoutMs, cause) }
        if (Looper.myLooper() == Looper.getMainLooper()) return HandoffResult.STOP
        val limit = timeoutMs.coerceIn(5_000, 10 * 60_000)
        val pending = Pending<HandoffResult>()
        val shown = onMain(1_500) { showHandoff(reason, limit, pending, cause) } == true
        if (!shown) {
            pending.resolve(HandoffResult.STOP)
            main.post { if (pendingHandoff === pending) dismissHandoff() }
            return PhoneRegistry.notificationGate?.handoff(reason, limit, cause) ?: HandoffResult.STOP
        }
        val result = try {
            pending.await(limit + 1_500) ?: run { pending.resolve(HandoffResult.TIMEOUT); pending.value!! }
        } catch (_: InterruptedException) {
            pending.resolve(HandoffResult.STOP)
            Thread.currentThread().interrupt()
            pending.value!!
        }
        main.post { if (pendingHandoff === pending) dismissHandoff() }
        return result
    }

    // ---- hooks for the driver ---------------------------------------------------------------------

    /** Makes every overlay window untouchable (true) so an injected stroke reaches the app below. */
    fun setPassThrough(on: Boolean) {
        // Cleanup must survive a busy main thread or an interrupted gesture worker.
        // Gesture calls are serialized; this stays ahead of the next queued enable.
        if (!on) { main.post { applyPassThrough(false) }; return }
        if (Looper.myLooper() == Looper.getMainLooper()) { applyPassThrough(on); return }
        val changed = onMain(500) { applyPassThrough(on) } == true
        if (changed) SystemClock.sleep(80) // input windows update a frame after the layout
    }

    /** Paired hides for full-display screenshots; captures may overlap. */
    fun hideForCapture(hide: Boolean) { captureHiddenResult(hide, false) }

    /** Null means the UI hide did not finish normally. An empty set is a normal result.
     * The IDs describe only this operation's invisible attached controls, not compositor pixels.
     * The caller must still pair this with hideForCapture(false), including on interruption. */
    internal fun hideForCaptureWithReceipt(): Set<Int>? = captureHiddenResult(true, true)

    private fun captureHiddenResult(hide: Boolean, includeWindowIds: Boolean): Set<Int>? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            // The main-thread pet caller schedules its own delay before it shoots.
            applyCaptureHidden(hide)
            return if (includeWindowIds) hiddenWindowIds() else null
        }
        // Both halves run on the main queue in the order they were asked for and are never
        // cancelled: a release can't overtake its own hide, and recovery still runs if the
        // screenshot worker times out or is interrupted.
        val applied = CountDownLatch(1)
        var settle = false
        var windowIds: Set<Int>? = null
        main.post {
            try {
                settle = applyCaptureHidden(hide)
                if (includeWindowIds) windowIds = hiddenWindowIds()
            } catch (e: Exception) { Log.w(TAG, "overlay main-thread call failed", e) }
            finally { applied.countDown() }
        }
        if (!hide || !applied.await(500, TimeUnit.MILLISECONDS)) return null
        if (settle) SystemClock.sleep(120)
        return windowIds
    }

    @Suppress("DEPRECATION")
    private fun hiddenWindowIds(): Set<Int> = buildSet {
        for (root in ownRoots()) {
            val id = runCatching {
                if (!root.isAttachedToWindow || root.visibility == View.VISIBLE) null
                else {
                    val node = root.createAccessibilityNodeInfo()
                    if (node == null) null
                    else try { node.windowId.takeIf { it >= 0 } } finally { node.recycle() }
                }
            }.getOrNull()
            if (id != null) add(id)
        }
    }

    private fun applyCaptureHidden(hide: Boolean): Boolean {
        if (captureVisibility.update(hide)) {
            val v = if (captureHidden) View.INVISIBLE else View.VISIBLE
            syncWindows()
            confirmCard?.root?.visibility = v
            handoffCard?.root?.visibility = v
            screen?.setHidden(captureHidden)
            beam.setHidden(captureHidden || passThrough)
        }
        return hide && (pill != null || confirmCard != null || handoffCard != null || screen != null || beam.attached)
    }

    /** Screen off, lock, 停止 elsewhere, service going away: answer everything pending with STOP. */
    fun stopAll() {
        val shared = sharedPrompt
        val confirm = pendingConfirm
        val handoff = pendingHandoff
        shared?.ticket?.stop()
        main.post {
            if (sharedPrompt === shared) {
                if (shared != null) { sharedPrompt = null; dismissConfirm() }
            }
            if (sharedPrompt == null && pendingConfirm === confirm) { confirm?.resolve(Decision.STOP); dismissConfirm() }
            if (pendingHandoff === handoff) { handoff?.resolve(HandoffResult.STOP); dismissHandoff() }
            paused = false
            clearPreview()
            endEditing()
            if (statusText != null) { setStopped(true); renderPill(); clearStoppedLater() }
        }
    }

    /** "已停止" stays briefly; if the core doesn't clear or replace the status, the control (and its KEEP_SCREEN_ON) goes. */
    private fun clearStoppedLater() {
        main.postDelayed({ if (stoppedNote) { statusText = null; line = null; steps.clear(); setStopped(false); paused = false; removePill(animated = true) } }, 4_000)
    }

    /** The 已停止 note: holds the capsule (or the ball) as it is, the card folding back first. */
    private fun setStopped(on: Boolean) {
        stoppedNote = on
        if (on) holdFold(FoldClock.Hold.STOPPED) else releaseFold(FoldClock.Hold.STOPPED)
    }

    /** Debug probe: screen centre of the visible button labelled [label], if any. */
    fun debugButtonCenter(label: String): Pair<Int, Int>? = onMain(1_000) {
        fun find(v: View): View? {
            if ((v is TextView && v.text?.toString() == label) || v.contentDescription?.toString() == label) return v
            if (v is android.view.ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
            return null
        }
        val roots = listOfNotNull(confirmCard?.root, handoffCard?.root, pill?.root?.takeIf { it.isShown }, ball?.root?.takeIf { it.isShown },
            screen?.root?.takeIf { it.isShown })
        roots.firstNotNullOfOrNull { find(it) }?.let { v ->
            val loc = IntArray(2)
            v.getLocationOnScreen(loc)
            (loc[0] + v.width / 2) to (loc[1] + v.height / 2)
        }
    }

    /** Debug probe: puts the control in [form] (ball, capsule, card) as the person's taps would. */
    fun debugForm(form: String) {
        main.post {
            when (form) {
                "ball" -> if (!fold.folded) collapseByHand()
                "capsule" -> if (fold.folded) onBallTapped() else if (fold.expanded) onLineTapped()
                "card" -> if (fold.folded) { onBallTapped(); main.postDelayed({ onLineTapped() }, 700) } else if (!fold.expanded) onLineTapped()
            }
        }
    }

    /** Debug probe: 暂停 / 继续 / 停止 / the steer field, as the keys do. */
    fun debugKey(key: String) {
        main.post {
            when (key) {
                "pause" -> togglePause()
                "stop" -> stopFromPill()
                "steer" -> startSteer()
                "done" -> endEditing()
            }
        }
    }

    /** Debug probe: what the control is showing. */
    fun debugState(): String = onMain(1_000) {
        "form=${fold.form} ballShown=$ballShown shape=${pill?.shape} paused=$paused stopped=$stoppedNote line=${line?.text} " +
            "window=${pill?.params?.let { "${it.width}x${it.height}@${it.x},${it.y}" }} spot=$spot ball=${ball?.let { "${it.pos}" }} steps=${steps.before(line, 3)}"
    } ?: "timeout"

    fun onConfigurationChanged() {
        main.post {
            val dark = isDark()
            if (darkBuilt != null && darkBuilt != dark) {
                // Rebuild in the new palette; pending questions keep their latches.
                pill?.let { removePill(animated = false); if (statusText != null) showPill() }
            } else {
                pill?.let { p ->
                    imeTop = imeWindowTop()
                    placeCapsule(p)
                    ball?.let { b -> if (ballResting()) b.move(b.dockPos()) }
                }
                beam.relayout()
                screen?.relayout()
                confirmCard?.let { place(it.root, it.params, top = false) }
                handoffCard?.let { place(it.root, it.params, top = true) }
            }
        }
    }

    fun destroy() {
        destroying = true
        sharedPrompt?.ticket?.stop()
        pendingConfirm?.resolve(Decision.STOP)
        pendingHandoff?.resolve(HandoffResult.STOP)
        overlayPrefs.unregisterOnSharedPreferenceChangeListener(prefsListener)
        if (LiveActivity.islandListener === islandListener) LiveActivity.islandListener = null
        if (PhoneThoughts.listener === thoughtListener) PhoneThoughts.listener = null
        main.post {
            clearPreview()
            dismissConfirm()
            dismissHandoff()
            removePill(animated = false)
            syncAwake()
        }
    }

    /**
     * Subscription follows what shows: the background-screen window, never the mere existence of a
     * View. (The card has no picture of the background screen: it shows what DSH thinks and does.)
     */
    private fun syncPreview() {
        val p = pill
        val control = PhoneControl.peek()
        // A minimised window shows no picture: no frames are taken for it.
        val toScreen = screen?.let { it.attached && !it.isMinimized } == true && !captureHidden
        val taskId = if (!destroying && p != null && toScreen) control?.liveTask()?.id else null
        if (taskId == previewTaskId && toScreen == previewToScreen && (taskId == null || previewPill === p)) return
        clearPreview()
        if (taskId == null || p == null || control == null) return
        previewTaskId = taskId
        previewPill = p
        previewToScreen = toScreen
        control.preview.addConsumer(previewOwner, taskId, BackgroundPreview.ConsumerKind.OVERLAY) { frame ->
            if (destroying || previewTaskId != taskId || previewPill !== p) return@addConsumer
            when (frame["state"]) {
                "frame" -> (frame["imageBytes"] as? ByteArray)?.let(previewDecoder::offer)
                else -> {
                    previewDecoder.clear()
                    val label = when (frame["state"]) {
                        "off" -> null
                        "inUse" -> s(R.string.overlay_preview_in_use)
                        "protected" -> s(R.string.overlay_preview_protected)
                        "waiting" -> s(R.string.overlay_preview_waiting)
                        else -> s(R.string.overlay_preview_unavailable)
                    }
                    if (previewToScreen) screen?.showFrame(null, label ?: s(R.string.overlay_preview_waiting))
                }
            }
        }
    }

    private fun clearPreview() {
        PhoneControl.peek()?.preview?.removeConsumer(previewOwner)
        previewDecoder.clear()
        previewPill = null
        previewTaskId = null
        previewToScreen = false
    }

    private var previewToScreen = false

    /**
     * The live task runs on the background screen: the person's own screen isn't being operated
     * (no edge glow), and with 实时查看后台屏 on its picture shows in the capsule's place.
     */
    private fun onBackground(): Boolean {
        val control = PhoneControl.peek() ?: return false
        val id = control.liveTask()?.id ?: return false
        return control.background.previewTarget(id) != null
    }

    /**
     * The phone's own island shows the task (HyperOS 超级岛, ColorOS 流体云, MagicOS; [LiveActivity])
     * and 「用系统灵动岛显示」 is on: the capsule and the ball stay away (§14). The edge glow, the
     * confirm card and the handoff card are still this overlay's.
     */
    private fun islandMode(): Boolean = systemIsland && LiveActivity.islandShows(service)

    /** The background-screen window instead of the capsule and the ball (§13). Kept through 已停止 once shown. */
    private fun screenMode(): Boolean {
        if (destroying || pill == null || handoffCard != null) return false
        if (stoppedNote) return screen != null
        return onBackground() && PhoneControl.peek()?.preview?.enabled == true
    }

    /** Shows or takes away the background-screen window as [screenMode] says; true when it came or went. */
    private fun syncScreen(): Boolean {
        val want = screenMode()
        val w = screen
        if (want && w == null) {
            val made = buildScreen()
            if (made.show(s(R.string.overlay_window_title), captureHidden)) {
                screen = made
                if (passThrough) applyTouchable(made.root, made.params, false)
                return true
            }
        } else if (!want && w != null) {
            screen = null
            w.remove(animated = animationsOn())
            return true
        }
        return false
    }

    private fun buildScreen(): OverlayScreen {
        val strings = OverlayScreen.Strings(
            pause = s(R.string.overlay_pause_description), resume = s(R.string.overlay_resume_description),
            stop = s(R.string.overlay_stop_description), back = s(R.string.overlay_back_description),
            view = s(R.string.overlay_screen_view), separator = s(R.string.overlay_meta_separator),
            minimize = s(R.string.overlay_screen_minimize), restore = s(R.string.overlay_screen_restore),
        )
        return OverlayScreen(service, wm, islandColors(), strings, ::safeArea, object : OverlayScreen.Actions {
            override fun touched() = onPillTouched()
            override fun pause() = togglePause()
            override fun stop() = stopFromPill()
            override fun back() = backToApp()
            override fun minimized(min: Boolean) = syncPreview()
        })
    }

    private fun applyTouchable(root: View, params: WindowManager.LayoutParams, touchable: Boolean) {
        params.flags = if (!touchable) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        update(root, params)
    }

    // ---- capsule ----------------------------------------------------------------------------------

    private fun s(id: Int, vararg args: Any): String = AppStrings.get(service, id, *args)

    private fun unlocks(): PhoneUnlocks = debugUnlocks ?: PhoneRegistry.unlocks()

    /** A confirm (or a shared prompt) is up: the line points at it. */
    private fun waiting() = pendingConfirm != null || sharedPrompt != null

    private fun showPill() {
        if (pill == null) {
            darkBuilt = isDark()
            imeTop = imeWindowTop()
            val p = buildPill()
            // The beam's window first, so the control's windows come over it.
            beam.attach(s(R.string.overlay_window_title), isDark(), ThemeAccent.notificationColor(service), captureHidden || passThrough)
            if (!add(p.root, p.params)) { beam.detach(animated = false); return }
            pill = p
            ballShown = false
            fold.start(now())
            syncWindows()
            renderPill(animated = false)
            enter(p.root)
            scheduleFold()
            return
        }
        renderPill()
    }

    /** What the capsule, the card and the ball say now; [animated] cross-fades what changed. */
    private fun renderPill(animated: Boolean = true) {
        val p = pill ?: return
        val base = line ?: return
        val u = unlocks()
        val look = when {
            stoppedNote -> MarkLook.STOPPED
            waiting() -> MarkLook.WAITING
            paused -> MarkLook.PAUSED
            else -> MarkLook.RUNNING
        }
        val text = when {
            stoppedNote -> s(R.string.overlay_stopped)
            waiting() -> s(R.string.overlay_waiting)
            paused -> s(R.string.overlay_paused_short)
            else -> steerNote ?: base.text
        }
        val sep = s(R.string.overlay_meta_separator)
        val control = PhoneControl.peek()
        val live = control?.liveTask()
        val app = debugApp ?: live?.app
        // The app is on the second line already: the card's meta only says approvals are off.
        val meta = if (base.waived) s(R.string.overlay_waived) else null
        val thought = if (stoppedNote) null else PhoneThoughts.get(live?.id?.let { control.taskSession(it) })
        // The island's second line: 「微信 · 第 6 步」 and the time since the task started.
        if (live != null && live.id != timedTask) { timedTask = live.id; taskStartedAt = now() }
        val stepsDone = steps.count
        val sub = listOfNotNull(app, if (stepsDone > 0) s(R.string.overlay_step, stepsDone) else null).joinToString(sep)
            .ifEmpty { s(R.string.overlay_dsh_working) }
        val icon = app?.let(::iconFor)
        val state = CapsuleState(
            line = text,
            look = look,
            paused = paused,
            stopped = stoppedNote,
            expandable = !stoppedNote && !waiting(),
            unlocked = u.any,
            unlockedLine = if (u.any) unlockedLine(u) else null,
            meta = meta,
            steps = steps.before(base, StepHistory.CAPACITY),
            sub = sub,
            startedAt = if (stoppedNote) null else taskStartedAt,
            icon = icon,
            thought = thought,
        )
        p.render(state, animated && p.root.isShown && !ballShown, now())
        val switched = syncScreen()
        screen?.render(state)
        main.removeCallbacks(shrinkTick)
        p.shrinkAt?.let { main.postAtTime(shrinkTick, it + 1) }
        ball?.setLook(
            look,
            s(
                when (look) {
                    MarkLook.STOPPED -> R.string.overlay_ball_stopped
                    MarkLook.WAITING -> R.string.overlay_ball_waiting
                    MarkLook.PAUSED -> R.string.overlay_ball_paused
                    MarkLook.RUNNING -> R.string.overlay_ball_running
                },
            ),
            badge = u.any && !stoppedNote,
            stopLabel = if (stoppedNote) null else s(R.string.overlay_stop_description),
            icon = icon,
        )
        // Window visibility is only re-laid when the screen window came or went: mid-morph the
        // capsule may be up, transparent, while the ball still shows.
        if (switched) syncWindows() else { syncPreview(); syncBeam() }
    }

    /**
     * The icon of the app labelled [label]: the app DSH is in now, read off the active window
     * (so no package list is needed), kept by label. Null when the label isn't the active app's.
     */
    private fun iconFor(label: String): android.graphics.drawable.Drawable? {
        if (icons.containsKey(label)) return icons[label]
        // Not found a moment ago (another app was still in front): ask the window again in a while, not on every line.
        iconMiss[label]?.let { if (now() - it < ICON_RETRY_MS) return null }
        iconMiss[label] = now()
        val pm = service.packageManager
        val pkg = runCatching {
            @Suppress("DEPRECATION")
            service.rootInActiveWindow?.let { node -> try { node.packageName?.toString() } finally { node.recycle() } }
        }.getOrNull()?.takeIf { it != service.packageName } ?: return null
        val info = runCatching { pm.getApplicationInfo(pkg, 0) }.getOrNull() ?: return null
        if (pm.getApplicationLabel(info).toString() != label) return null
        val icon = runCatching { pm.getApplicationIcon(info).mutate() }.getOrNull()
        icons[label] = icon
        iconMiss.remove(label)
        // The phone's own island shows the same icon.
        icon?.let { LiveActivity.setPhoneIcon(service, label, it) }
        return icon
    }

    private val iconMiss = HashMap<String, Long>()

    /**
     * The edge beam: on while the control shows for a live task on the person's own screen (not on
     * the background screen, not once 已停止, not while the handoff card has the screen, never with
     * 屏幕边缘光效 off), still and faint while paused, not drawn during a screenshot or an injected
     * stroke.
     */
    private fun syncBeam() {
        beam.set(on = edgeGlow && pill != null && !stoppedNote && handoffCard == null && !onBackground(), paused = paused)
        beam.setHidden(captureHidden || passThrough)
    }

    /** 「已解除限制」 in bold over what is lifted (「系统设置、密码和验证码」), a size smaller. */
    private fun unlockedLine(u: PhoneUnlocks): CharSequence {
        val names = listOfNotNull(
            if (u.systemPages) s(R.string.overlay_unlock_system) else null,
            if (u.secretFields) s(R.string.overlay_unlock_secrets) else null,
            if (u.ownApp) s(R.string.overlay_unlock_own_app) else null,
        ).joinToString(s(R.string.overlay_list_separator))
        val title = s(R.string.overlay_unlocked)
        return SpannableStringBuilder(title).apply {
            setSpan(StyleSpan(Typeface.BOLD), 0, title.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            append('\n')
            val at = length
            append(names)
            setSpan(RelativeSizeSpan(12f / 13f), at, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    /** Takes the control away; [animated]: it fades first (a task that ended, not a rebuild). */
    private fun removePill(animated: Boolean, preservePrompts: Boolean = false) {
        clearPreview()
        screen?.let { screen = null; it.remove(animated && animationsOn()) }
        timedTask = null
        taskStartedAt = null
        val p = pill ?: return
        endEditing()
        main.removeCallbacks(foldTick)
        main.removeCallbacks(shrinkTick)
        lift?.cancel()
        lift = null
        beam.detach(animated && animationsOn())
        fold.reset()
        if (preservePrompts) {
            if (waiting()) fold.hold(FoldClock.Hold.CONFIRM, now())
            if (handoffCard != null) fold.hold(FoldClock.Hold.HANDOFF, now())
        }
        val b = ball
        pill = null
        syncAwake()
        // A capsule taken away under the finger: endDrag finds no capsule, so the drag ends here.
        dragFrom = null
        dragAt = null
        ball = null
        ballShown = false
        unfolding = false
        steerNote = null
        p.cancelMorph()
        val roots = listOfNotNull(p.root.takeIf { it.isShown }, b?.root?.takeIf { it.isShown })
        if (!animated || !animationsOn() || roots.isEmpty()) {
            remove(p.root)
            b?.detach()
            return
        }
        b?.cancelGlide()
        var left = roots.size
        for (r in roots) {
            r.animate().alpha(0f).scaleX(0.96f).scaleY(0.96f).setDuration(180).setInterpolator(OverlayMotion.emphasized).withEndAction {
                if (--left == 0) { remove(p.root); b?.detach() }
            }.start()
        }
    }

    private fun buildPill(): OverlayCapsule {
        val c = islandColors()
        val strings = OverlayCapsule.Strings(
            fold = s(R.string.overlay_fold), expand = s(R.string.overlay_expand), collapse = s(R.string.overlay_collapse),
            pause = s(R.string.overlay_pause_description), resume = s(R.string.overlay_resume_description),
            stop = s(R.string.overlay_stop_description), back = s(R.string.overlay_back_description), stopRow = s(R.string.overlay_stop_row),
            steerHint = s(R.string.overlay_steer_hint), send = s(R.string.overlay_send),
            unlocksDescription = s(R.string.overlay_unlocked_description), review = s(R.string.overlay_unlocks_review),
            foldRow = s(R.string.overlay_fold_row), holdHint = s(R.string.overlay_hold_hint), separator = s(R.string.overlay_meta_separator),
            moveLeft = s(R.string.overlay_move_left), moveCentre = s(R.string.overlay_move_centre), moveRight = s(R.string.overlay_move_right),
            thought = s(R.string.overlay_thought),
        )
        lateinit var capsule: OverlayCapsule
        val actions = object : OverlayCapsule.Actions {
            override fun touched() = onPillTouched()
            override fun dragStart() = startDrag()
            override fun dragMove(dx: Float, dy: Float) = dragTo(dx, dy)
            override fun dragEnd(velocityX: Float) = endDrag(velocityX)
            override fun place(anchor: CapsuleAnchor) = moveTo(anchor)
            override fun mark() = collapseByHand()
            override fun line() = onLineTapped()
            override fun pause() = togglePause()
            override fun stop() = stopFromPill()
            override fun back() = backToApp()
            override fun unlocks() = openUnlocks()
            override fun steer() = startSteer()
            override fun send() = sendInterjection()
            override fun inputDone() = endEditing()
        }
        // A new size (a longer line, the card) keeps the capsule on its anchor, or under the finger.
        capsule = OverlayCapsule(service, c, strings, actions) { capsule.params.x = capsuleX(capsule); update(capsule.root, capsule.params) }
        capsule.root.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = Unit
            override fun onViewDetachedFromWindow(view: View) {
                if (previewPill === capsule) clearPreview()
            }
        })
        // Hung from the top under an island at the top (the card grows down out of it), from the
        // bottom lower down (it grows up); either way the header stays put ([syncDirection]).
        // Placed from the left (capsuleX), and free to go past a side while it is dragged there.
        capsule.params = params(top = false, keepScreenOn = true).apply {
            gravity = Gravity.BOTTOM or Gravity.LEFT
            flags = flags or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        }
        capsule.anchor = spot.anchor
        placeCapsule(capsule)
        return capsule
    }

    /** Where the person put it (by default an island at the top centre), clear of the bars, a keyboard and the confirm card ([CapsulePlacement]); sizes for this screen. */
    private fun placeCapsule(p: OverlayCapsule) {
        val a = safeArea()
        lift?.cancel()
        lift = null
        syncDirection(p, a)
        p.params.y = capsuleY(p, a)
        p.place(CapsulePlacement.roomW(a), a.screenH)
        p.params.x = capsuleX(p)
        update(p.root, p.params)
    }

    /** The capsule's centre y with nothing in the way: where a ball the person never moved rests too. */
    private fun capsuleCentre(a: SafeArea = safeArea(), obstacle: Int? = null, cardH: Int = 0) =
        CapsulePlacement.centreY(a, dp(CapsuleMetrics.HEIGHT_DP), dp(CapsulePlacement.GAP_DP), obstacle, spot.fraction, cardH)

    /**
     * The capsule's window offset clear of what is in the way. Opening down, it stays put and the
     * card gets the room below it (over the keyboard while 插话 is typed); opening up, it goes low
     * enough for the open card, which gets the room above it.
     */
    private fun capsuleY(p: OverlayCapsule, a: SafeArea): Int {
        val headerH = dp(CapsuleMetrics.HEIGHT_DP)
        if (p.down) {
            val obstacle = obstacleTop()
            val cardH = if (fold.expanded) p.naturalCardHeight() else 0
            val centre = CapsulePlacement.liftForCard(a, capsuleCentre(a, obstacle), headerH, dp(CapsulePlacement.GAP_DP), obstacle, cardH)
            p.maxCardHeight = CapsulePlacement.cardRoomBelow(a, centre, headerH, dp(CapsulePlacement.GAP_DP), obstacleTop())
            return CapsulePlacement.windowTopY(centre, headerH, p.padTop)
        }
        val centre = capsuleCentre(a, obstacleTop(), if (fold.expanded) p.naturalCardHeight() else 0)
        p.maxCardHeight = CapsulePlacement.cardRoom(a, centre, headerH, dp(CapsulePlacement.GAP_DP))
        return CapsulePlacement.windowY(a.screenH, centre, headerH, p.padBottom)
    }

    /**
     * Which way the card opens: down from an island in the upper half, up from a capsule lower
     * down, the window hanging from that end so the header stays put as it grows. Changed only on a
     * capsule at rest, keeping its place on screen; the caller moves it on from there.
     */
    private fun syncDirection(p: OverlayCapsule, a: SafeArea = safeArea()) {
        if (p.morphing || p.shape != OverlayCapsule.Shape.CAPSULE) return
        val down = CapsulePlacement.opensDown(a, capsuleCentre(a))
        val vertical = if (down) Gravity.TOP else Gravity.BOTTOM
        val now = p.params.gravity and Gravity.VERTICAL_GRAVITY_MASK
        if (p.down == down && now == vertical) return
        val h = p.params.height.coerceAtLeast(0)
        val top = if (now == Gravity.TOP) p.params.y else a.screenH - p.params.y - h
        p.setDown(down)
        p.params.gravity = vertical or Gravity.LEFT
        p.params.y = if (down) top else a.screenH - top - h
        update(p.root, p.params)
    }

    /** The capsule window's x: its steady capsule on the anchor, or where the finger has it. */
    private fun capsuleX(p: OverlayCapsule): Int {
        val left = dragAt?.x ?: CapsulePlacement.capsuleLeft(p.anchor, safeArea(), p.capsuleWidth, dp(CapsulePlacement.EDGE_DP))
        return CapsulePlacement.windowX(left, p.padX, p.steadyLeft())
    }

    // ---- dragging the capsule -------------------------------------------------------------------

    /** The header is being dragged: the card goes back to the capsule first, nothing folds meanwhile. */
    private fun startDrag() {
        val p = pill ?: return
        lift?.cancel()
        lift = null
        main.removeCallbacks(foldTick)
        if (fold.expanded) {
            endEditing()
            // Let go before the card is back in: the way it opens is settled once it is.
            if (fold.collapse(now())) p.collapse(animationsOn()) { if (dragAt == null && pill === p) { syncDirection(p); avoidObstacles() } }
        }
        val a = safeArea()
        val headerH = dp(CapsuleMetrics.HEIGHT_DP)
        val centreY = if (p.down) p.params.y + p.padTop + headerH / 2 else a.screenH - p.params.y - p.padBottom - headerH / 2
        val from = WindowPos(p.params.x + p.padX + p.steadyLeft(), centreY)
        dragFrom = from
        dragAt = from
    }

    /** Follows the finger: anywhere across (past a side too), up and down within the bars. */
    private fun dragTo(dx: Float, dy: Float) {
        val p = pill ?: return
        val from = dragFrom ?: return
        val a = safeArea()
        val headerH = dp(CapsuleMetrics.HEIGHT_DP)
        val at = WindowPos(from.x + dx.roundToInt(), CapsulePlacement.clampCentre(a, from.y + dy.roundToInt(), headerH, dp(CapsulePlacement.GAP_DP)))
        dragAt = at
        p.params.x = capsuleX(p)
        p.params.y = if (p.down) CapsulePlacement.windowTopY(at.y, headerH, p.padTop) else CapsulePlacement.windowY(a.screenH, at.y, headerH, p.padBottom)
        update(p.root, p.params)
    }

    /**
     * Let go: past a side (or thrown out of it) the capsule folds into the ball there, at that
     * height; otherwise it keeps the height and glides to the nearest anchor. Either is kept.
     */
    private fun endDrag(velocityX: Float) {
        val p = pill ?: return
        val at = dragAt ?: return
        dragAt = null
        dragFrom = null
        val a = safeArea()
        val headerH = dp(CapsuleMetrics.HEIGHT_DP)
        val side = CapsulePlacement.foldSide(at.x, p.capsuleWidth, a.screenW, dp(CapsulePlacement.FOLD_OUT_DP), velocityX)
        val anchor = when (side) {
            Side.LEFT -> CapsuleAnchor.LEFT
            Side.RIGHT -> CapsuleAnchor.RIGHT
            null -> CapsulePlacement.anchorFor(at.x, p.capsuleWidth, a, dp(CapsulePlacement.EDGE_DP), velocityX)
        }
        spot = CapsuleSpot(anchor, CapsulePlacement.fractionFor(a, at.y, headerH, dp(CapsulePlacement.GAP_DP)))
        OverlayPrefs.saveSpot(overlayPrefs, spot)
        fold.touch(now())
        if (side != null && !stoppedNote) {
            val b = ensureBall()
            if (b != null && fold.foldByHand(now())) {
                // The capsule folds where it was let go and moves to its new anchor once it is hidden.
                b.dropAt(side, at.y)
                foldPill(animationsOn())
                scheduleFold()
                return
            }
        }
        p.anchor = anchor
        // Let go in the other half: the card opens the other way from now on.
        syncDirection(p, a)
        avoidObstacles()
        scheduleFold()
    }

    /** The screen reader's 移到左侧 / 中间 / 右侧: the same anchors, at the same height. */
    private fun moveTo(anchor: CapsuleAnchor) {
        val p = pill ?: return
        spot = spot.copy(anchor = anchor)
        OverlayPrefs.saveSpot(overlayPrefs, spot)
        p.anchor = anchor
        avoidObstacles()
    }

    /** The higher of a keyboard's top and the confirm card's, on screen; null when neither shows. */
    private fun obstacleTop(): Int? = listOfNotNull(imeTop, confirmTop()).minOrNull()

    private fun confirmTop(): Int? {
        val card = confirmCard ?: return null
        val h = card.root.height.takeIf { it > 0 } ?: return null
        return CapsulePlacement.windowTop(safeArea().screenH, card.params.y, h)
    }

    /** The top of the keyboard window on screen, if one shows. */
    private fun imeWindowTop(): Int? = runCatching {
        service.windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }?.let { w ->
            w.getBoundsInScreen(imeRect)
            imeRect.top.takeIf { !imeRect.isEmpty }
        }
    }.getOrNull()

    /** The service's windows changed: a keyboard may have come or gone. */
    fun onWindowsChanged() {
        if (pill == null) return
        val top = imeWindowTop()
        if (top == imeTop) return
        imeTop = top
        avoidObstacles()
    }

    /**
     * The capsule glides to where it rests now: over a keyboard or the confirm card or back, down
     * for the open card's room or back up, to its anchor after a drag; a resting ball keeps clear
     * of the confirm card too. Not while the finger has the capsule.
     */
    private fun avoidObstacles() {
        val p = pill ?: return
        if (dragAt != null) return
        val toY = capsuleY(p, safeArea())
        val toX = capsuleX(p)
        lift?.cancel()
        lift = null
        if (toX != p.params.x || toY != p.params.y) {
            if (!animationsOn() || !p.root.isShown) {
                p.params.x = toX
                p.params.y = toY
                update(p.root, p.params)
            } else {
                val fromX = p.params.x
                val fromY = p.params.y
                lift = ValueAnimator.ofFloat(0f, 1f).apply {
                    duration = OverlayMotion.RESIZE_MS
                    interpolator = OverlayMotion.glide
                    addUpdateListener { a ->
                        val f = a.animatedValue as Float
                        p.params.x = (fromX + (toX - fromX) * f).roundToInt()
                        p.params.y = (fromY + (toY - fromY) * f).roundToInt()
                        update(p.root, p.params)
                    }
                    start()
                }
            }
        }
        ball?.let { b -> if (ballResting() && !b.touching) b.glideTo(b.dockPos(), animationsOn()) }
    }

    /**
     * The ball is the form on screen and not on its way back into the capsule: an unfold's glide
     * ends in the window swap, so nothing may move it (moving cancels the glide, and the swap with it).
     */
    private fun ballResting() = ballShown && !unfolding

    /** The 「已解除限制」 row: 设置 › 手机操控 › 解除限制, through the app's own page link. */
    private fun openUnlocks() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(UNLOCKS_LINK))
            .setClass(service, LinkTrampolineActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { service.startActivity(intent) } catch (e: Exception) { Log.w(TAG, "unlocks page: ${e.javaClass.simpleName}") }
    }

    /**
     * 回到 DSH Go: the chat this task belongs to. A task on the person's own screen is paused first —
     * DSH would otherwise go on tapping in whatever app is in front, now DSH Go itself; one on the
     * background screen goes on.
     */
    private fun backToApp() {
        if (!stoppedNote && !paused && !onBackground()) togglePause()
        endEditing()
        val control = PhoneControl.peek()
        val session = control?.liveTask()?.id?.let { control.taskSession(it) }
        if (control == null || !control.reopen(session, null)) {
            val intent = service.packageManager.getLaunchIntentForPackage(service.packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try { if (intent != null) service.startActivity(intent) } catch (e: Exception) { Log.w(TAG, "back to app: ${e.javaClass.simpleName}") }
        }
    }

    private fun togglePause() {
        if (stoppedNote) return
        val controls = statusOwnership.controls ?: return
        val next = !controls.isPaused()
        if (!controls.setPaused(next)) {
            announce(s(R.string.overlay_control_rejected))
            return
        }
        paused = next
        renderPill()
        announce(s(if (paused) R.string.overlay_paused_short else R.string.overlay_resume_description))
    }

    /** Stop only the displayed task; its native owner chain cancels its own prompt tickets. */
    private fun stopFromPill() {
        if (stoppedNote) return
        val controls = statusOwnership.controls ?: return
        // l10n:keep agent stop reason
        if (!controls.stop("你在悬浮条上点了停止")) {
            announce(s(R.string.overlay_control_rejected))
            return
        }
        paused = false
        endEditing()
        setStopped(true)
        renderPill()
        clearStoppedLater()
        announce(s(R.string.overlay_stopped))
    }

    private fun announce(text: String) {
        val v = screen?.root ?: if (ballShown) ball?.root else pill?.root
        if (a11y.isEnabled) v?.announceForAccessibility(text)
    }

    /** The line: the capsule opens into the card, the card closes. */
    private fun onLineTapped() {
        val p = pill ?: return
        if (stoppedNote || ballShown) return
        if (fold.expanded) {
            endEditing()
            if (fold.collapse(now())) p.collapse(animationsOn()) { avoidObstacles() }
        } else if (fold.expand(now())) {
            applyIdle(animated = true)
            renderPill(animated = false)
            // A capsule dragged up high moves down while the card is open, so the card fits above it.
            avoidObstacles()
            p.expand(animationsOn())
        }
        scheduleFold()
    }

    /** The steer field in the card: the window takes the keyboard until the text goes or is sent. */
    private fun startSteer() {
        val p = pill ?: return
        if (stoppedNote || !fold.expanded || editing || !statusOwnership.beginEditing()) return
        editing = true
        holdFold(FoldClock.Hold.EDITING)
        p.params.flags = p.params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv()
        update(p.root, p.params)
        p.startEditing()
        p.input.post { if (editing) ime.showSoftInput(p.input, InputMethodManager.SHOW_IMPLICIT) }
    }

    private fun endEditing() {
        statusOwnership.endEditing()
        val p = pill
        p?.input?.setText("")
        p?.input?.error = null
        if (p != null && (editing || p.editing)) {
            ime.hideSoftInputFromWindow(p.input.windowToken, 0)
            p.stopEditing()
            if (p.params.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE == 0) {
                p.params.flags = p.params.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                update(p.root, p.params)
            }
        }
        editing = false
        releaseFold(FoldClock.Hold.EDITING)
    }

    private fun sendInterjection() {
        val p = pill ?: return
        val text = p.input.text?.toString()?.trim().orEmpty()
        if (text.isEmpty()) return
        val controls = statusOwnership.editingControls
        if (controls == null || !controls.interject(text)) {
            val failure = s(R.string.overlay_steer_rejected)
            p.input.error = failure
            announce(failure)
            return
        }
        p.input.error = null
        endEditing()
        val note = s(R.string.overlay_steer_sent, text)
        steerNote = note
        // Back to the capsule: the note shows where the line is.
        if (fold.collapse(now())) p.collapse(animationsOn()) { avoidObstacles() }
        renderPill()
        scheduleFold()
        main.postDelayed({ if (pill === p && steerNote == note) { steerNote = null; renderPill() } }, 2_500)
    }

    // ---- confirm --------------------------------------------------------------------------------

    /** Called only by the shared main-thread coordinator; no blocking or implicit fallback. */
    override fun showPrompt(presentation: PromptPresentation): (() -> Unit)? {
        val p = presentation
        if (Looper.myLooper() != Looper.getMainLooper() || !p.live || confirmCard != null || handoffCard != null) return null
        val root = FrameLayout(service).apply {
            setPadding(dp(6), dp(6), dp(6), dp(6))
            addView(PhonePromptUi.card(service, p), FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        }
        showWindow(root)
        val layout = params(top = false, keepScreenOn = true)
        place(root, layout, top = false)
        if (!p.live || !add(root, layout)) return null
        if (!p.markShown()) { remove(root); return null }
        sharedPrompt = p
        confirmCard = Card(root, layout, null)
        root.addOnLayoutChangeListener(obstacleWatch)
        holdFold(FoldClock.Hold.CONFIRM)
        renderPill()
        return {
            if (sharedPrompt === p) {
                sharedPrompt = null
                dismissConfirm()
            }
            p.retire()
        }
    }

    private fun showConfirm(request: ConfirmRequest, pending: Pending<Decision>): Boolean {
        if (sharedPrompt != null || pending.value != null) return false
        pendingConfirm?.resolve(Decision.DENY)
        dismissConfirm()
        val c = colors()
        darkBuilt = isDark()
        val deadline = SystemClock.uptimeMillis() + request.timeoutMs
        val root = FrameLayout(service).apply { setPadding(dp(6), dp(8), dp(6), dp(6)); clipToPadding = false }
        val card = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            background = surface(c, dp(24).toFloat())
            elevation = dp(8).toFloat()
            setPadding(dp(18), dp(16), dp(18), dp(14))
        }
        val head = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        val app = request.appLabel?.takeIf { it.isNotBlank() }
        head.addView(TextView(service).apply {
            text = if (request.firstInApp && app != null) AppStrings.get(service, R.string.overlay_first_app, app) else AppStrings.get(service, R.string.overlay_action_title)
            textSize = 12f; setTextColor(c.accent); typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val countdown = TextView(service).apply { textSize = 12f; setTextColor(c.muted) }
        head.addView(countdown)
        card.addView(head)
        val body = TextView(service).apply {
            text = request.sentence
            textSize = 16f; setTextColor(c.ink); setLineSpacing(0f, 1.3f)
            setPadding(0, dp(8), 0, dp(4))
        }
        card.addView(ScrollView(service).apply { addView(body); isVerticalScrollBarEnabled = false },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        card.addView(TextView(service).apply {
            text = AppStrings.get(service, R.string.overlay_timeout_hint)
            textSize = 12f; setTextColor(c.faint); setLineSpacing(0f, 1.2f); setPadding(0, 0, 0, dp(10))
        })

        val armedAt = SystemClock.uptimeMillis() + ARM_MS
        val guarded = mutableListOf<GuardedButton>()
        fun decide(d: Decision) { if (pending.resolve(d)) main.post { if (pendingConfirm === pending) dismissConfirm() } }
        // 允许一次 is the main answer; 本轮允许 (same app and kind, this turn only) stays beside 取消.
        // A visual scope is its own grant: allow visual taps for this task, or only this one step.
        val visual = request.visualScope != null
        val round = !visual && request.allowRound
        val primary = GuardedButton(service, armedAt).apply {
            text = AppStrings.get(service, if (visual) R.string.phone_prompt_allow_visual else R.string.overlay_allow_once)
            style(this, c.accent, c.onAccent, c)
            setOnClickListener { decide(if (visual) Decision.ALLOW_VISUAL_FOR_TASK else Decision.ALLOW_ONCE) }
        }
        guarded += primary
        card.addView(primary, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)).apply { bottomMargin = dp(8) })
        val decline = textButton(AppStrings.get(service, R.string.overlay_decline), c.ink, c) { decide(Decision.DENY) }
        decline.background = outlined(c)
        if (round || visual) {
            val second = GuardedButton(service, armedAt).apply {
                text = AppStrings.get(service, if (round) R.string.overlay_allow_round else R.string.overlay_allow_once)
                style(this, c.accentSoft, c.onAccentSoft, c)
                setOnClickListener { decide(if (round) Decision.ALLOW_APP_FOR_TASK else Decision.ALLOW_ONCE) }
            }
            guarded += second
            val row = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
            row.addView(second, LinearLayout.LayoutParams(0, dp(46), 1f))
            row.addView(decline, LinearLayout.LayoutParams(0, dp(46), 1f).apply { marginStart = dp(8) })
            card.addView(row)
        } else {
            card.addView(decline, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(46)))
        }
        root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        guarded.forEach { it.alpha = 0.5f }
        main.postDelayed({ guarded.forEach { it.animate().alpha(1f).setDuration(120).start() } }, ARM_MS)

        val tick = object : Runnable {
            override fun run() {
                val left = deadline - SystemClock.uptimeMillis()
                if (left <= 0) { decide(Decision.DENY); return }
                countdown.text = AppStrings.plural(service, R.plurals.overlay_seconds, ((left + 999) / 1000).toInt(), (left + 999) / 1000)
                main.postDelayed(this, 1_000)
            }
        }
        showWindow(root)
        val params = params(top = false, keepScreenOn = true)
        place(root, params, top = false)
        if (!add(root, params)) return false
        if (pending.value != null) { remove(root); return false }
        confirmCard = Card(root, params, tick)
        root.addOnLayoutChangeListener(obstacleWatch)
        pendingConfirm = pending
        tick.run()
        enter(root)
        holdFold(FoldClock.Hold.CONFIRM)
        renderPill()
        return true
    }

    private fun dismissConfirm() {
        val card = confirmCard ?: return
        card.tick?.let(main::removeCallbacks)
        card.root.removeOnLayoutChangeListener(obstacleWatch)
        remove(card.root)
        confirmCard = null
        pendingConfirm = null
        releaseFold(FoldClock.Hold.CONFIRM)
        renderPill()
        avoidObstacles()
    }

    // ---- handoff --------------------------------------------------------------------------------

    private fun showHandoff(reason: String, timeoutMs: Long, pending: Pending<HandoffResult>, cause: HandoffCause?): Boolean {
        if (sharedPrompt != null || pending.value != null) return false
        pendingHandoff?.resolve(HandoffResult.STOP)
        dismissHandoff()
        val c = colors()
        darkBuilt = isDark()
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        val root = FrameLayout(service).apply { setPadding(dp(6), dp(4), dp(6), dp(8)); clipToPadding = false }
        val card = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            background = surface(c, dp(22).toFloat())
            elevation = dp(8).toFloat()
            setPadding(dp(18), dp(14), dp(14), dp(10))
        }
        val head = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        head.addView(TextView(service).apply {
            text = cause?.let { PhonePromptUi.handoffCause(service, it) } ?: AppStrings.get(service, R.string.overlay_handoff_title)
            textSize = 12f; setTextColor(c.accent); typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        val countdown = TextView(service).apply { textSize = 12f; setTextColor(c.muted) }
        head.addView(countdown)
        card.addView(head)
        card.addView(TextView(service).apply {
            text = reason; textSize = 15f; setTextColor(c.ink); maxLines = 4; ellipsize = TextUtils.TruncateAt.END
            setLineSpacing(0f, 1.25f); setPadding(0, dp(6), 0, dp(2))
        })
        card.addView(TextView(service).apply {
            text = AppStrings.get(service, R.string.overlay_handoff_hint); textSize = 12f; setTextColor(c.faint); setPadding(0, 0, 0, dp(6))
        })
        fun finish(r: HandoffResult) { if (pending.resolve(r)) main.post { if (pendingHandoff === pending) dismissHandoff() } }
        val row = LinearLayout(service).apply { gravity = Gravity.CENTER_VERTICAL }
        row.addView(textButton(AppStrings.get(service, R.string.overlay_stop), c.danger, c) { finish(HandoffResult.STOP) })
        row.addView(View(service), LinearLayout.LayoutParams(0, 1, 1f))
        val armedAt = SystemClock.uptimeMillis() + ARM_MS
        val go = GuardedButton(service, armedAt).apply {
            text = AppStrings.get(service, R.string.overlay_continue)
            style(this, c.accent, c.onAccent, c)
            setOnClickListener { finish(HandoffResult.CONTINUE) }
        }
        row.addView(go, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(44)))
        card.addView(row)
        root.addView(card, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))

        val tick = object : Runnable {
            override fun run() {
                val left = deadline - SystemClock.uptimeMillis()
                if (left <= 0) { finish(HandoffResult.TIMEOUT); return }
                val s = (left + 999) / 1000
                countdown.text = if (s >= 60) AppStrings.get(service, R.string.overlay_time_remaining, "${s / 60}:${"%02d".format(s % 60)}") else AppStrings.plural(service, R.plurals.overlay_seconds_remaining, s.toInt(), s)
                main.postDelayed(this, 1_000)
            }
        }
        showWindow(root)
        val params = params(top = true, keepScreenOn = true)
        place(root, params, top = true)
        if (!add(root, params)) return false
        if (pending.value != null) { remove(root); return false }
        handoffCard = Card(root, params, tick)
        pendingHandoff = pending
        // The card says it all: capsule and ball step aside, and the capsule comes back after.
        holdFold(FoldClock.Hold.HANDOFF)
        syncWindows()
        tick.run()
        enter(root)
        return true
    }

    private fun dismissHandoff() {
        val card = handoffCard ?: return
        card.tick?.let(main::removeCallbacks)
        remove(card.root)
        handoffCard = null
        pendingHandoff = null
        syncWindows()
        releaseFold(FoldClock.Hold.HANDOFF)
    }

    // ---- guarded buttons ------------------------------------------------------------------------

    /**
     * A confirm button that only real fingers can press:
     *  - not in its first [ARM_MS] (a tap already in flight when the card appeared);
     *  - not while this service is injecting a gesture (InjectGuard);
     *  - not when the touch came through another window on top (tapjacking, FLAG_WINDOW_IS_OBSCURED);
     *  - ACTION_CLICK from an accessibility service only while touch exploration (TalkBack) is on,
     *    and never while this service is acting itself.
     * And the Actuator makes the overlay untouchable for every stroke it injects.
     * Event fields don't decide: on OPPO / realme a real finger arrives with device -1 and flags
     * 0x800, like our own dispatchGesture tap (#608, #296), so guessing from them locked real users
     * out. What the card guards against is the assistant, and every input it sends is ours and marked
     * (PromptInputPolicy has the full rule).
     */
    private inner class GuardedButton(context: Context, private val armedAt: Long) : TextView(context) {
        private var rejected = false

        init { filterTouchesWhenObscured = true; isClickable = true; isFocusable = true; gravity = Gravity.CENTER }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                val why = rejectReason(event)
                rejected = why != null
                lastGuardVerdict = "${why ?: "accepted"} flags=0x${Integer.toHexString(event.flags)} device=${event.deviceId} source=0x${Integer.toHexString(event.source)} tool=${event.getToolType(0)}"
                Log.i(TAG, "guarded '$text': $lastGuardVerdict")
            }
            if (rejected) {
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) isPressed = false
                return true
            }
            return super.dispatchTouchEvent(event)
        }

        override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
            if ((action == AccessibilityNodeInfo.ACTION_CLICK || action == AccessibilityNodeInfo.ACTION_LONG_CLICK) &&
                (!a11y.isTouchExplorationEnabled || InjectGuard.active() || SystemClock.uptimeMillis() < armedAt)) {
                lastGuardVerdict = "accessibility-action"
                Log.i(TAG, "guarded '$text': refused accessibility click")
                return false
            }
            return super.performAccessibilityAction(action, arguments)
        }

        private fun rejectReason(event: MotionEvent): String? = when {
            SystemClock.uptimeMillis() < armedAt -> "too-early"
            InjectGuard.active() && !debugIgnoreInjectGuard -> "injecting"
            event.flags and MotionEvent.FLAG_WINDOW_IS_OBSCURED != 0 -> "obscured"
            else -> null
        }
    }

    // ---- forms -----------------------------------------------------------------------------------
    //
    // Folding: the surface narrows to the circle at its end on the ball's side, the row fading
    // first; the ball takes its place and glides to its dock. Unfolding: the ball glides back to
    // that end and the capsule grows out of it. Capsule ↔ card: the same surface grows up and
    // out from the header, the body fading in behind (OverlayCapsule). One window shows at a time, except a few
    // frames of overlap at the swap (both are the same circle there), so neither ever blinks.

    private fun now() = SystemClock.uptimeMillis()

    private fun scheduleFold() {
        syncPreview()
        main.removeCallbacks(foldTick)
        // Nothing folds or fades under a dragging finger; the drag's end counts again.
        if (debugFreeze || dragAt != null) return
        val at = fold.nextAt ?: return
        main.postAtTime(foldTick, at)
    }

    private fun onFoldTick() {
        if (debugFreeze || dragAt != null) return
        when (fold.tick(now())) {
            FoldClock.Tick.FOLD -> foldPill(animationsOn())
            FoldClock.Tick.COLLAPSE -> pill?.collapse(animationsOn()) { avoidObstacles() }
            FoldClock.Tick.DIM -> applyIdle(animated = true)
            FoldClock.Tick.NONE -> Unit
        }
        scheduleFold()
    }

    private fun onPillTouched() {
        // A touch on a capsule that is still shrinking into the ball opens it again.
        if (fold.folded && !ballShown) {
            fold.unfold(now())
            pill?.cancelMorph()
        } else if (fold.touch(now())) applyIdle(animated = true)
        scheduleFold()
    }

    private fun onBallTouched() {
        // A finger stops an unfold's glide: the capsule it had brought up (transparent) goes again.
        unfolding = false
        syncWindows()
        fold.touch(now())
        applyIdle(animated = true)
        scheduleFold()
    }

    private fun onBallTapped() {
        if (fold.unfold(now())) unfoldPill(animationsOn())
        applyIdle(animated = true)
        scheduleFold()
    }

    /** The mark (or the card's 收成小球): folded until the ball is tapped, for the rest of this task. */
    private fun collapseByHand() {
        endEditing()
        if (fold.foldByHand(now())) foldPill(animationsOn())
        scheduleFold()
    }

    private fun holdFold(hold: FoldClock.Hold) {
        // A handoff hides both anyway: change form without a show.
        if (fold.hold(hold, now())) syncForm(animationsOn() && hold != FoldClock.Hold.HANDOFF)
        applyIdle(animated = true)
        scheduleFold()
    }

    private fun releaseFold(hold: FoldClock.Hold) {
        fold.release(hold, now())
        scheduleFold()
    }

    /** Brings what is on screen to the form [fold] says. */
    private fun syncForm(animated: Boolean) {
        val p = pill ?: return
        when (fold.form) {
            FoldClock.Form.BALL -> if (!ballShown) foldPill(animated)
            FoldClock.Form.CAPSULE -> when {
                ballShown -> unfoldPill(animated)
                p.shape == OverlayCapsule.Shape.CARD -> { endEditing(); p.collapse(animated) { avoidObstacles() } }
            }
            FoldClock.Form.CARD -> if (!ballShown && p.shape != OverlayCapsule.Shape.CARD) { avoidObstacles(); p.expand(animated) }
        }
    }

    private fun onPrefsChanged() {
        val p = OverlayPrefs.from(overlayPrefs)
        idleOpacity = p.idleOpacity
        if (p.systemIsland != systemIsland) {
            systemIsland = p.systemIsland
            if (pill != null) syncWindows()
        }
        fold.setAutoFold(p.autoFold, now())
        // 屏幕边缘光效 turned off fades the glow out at once; turned on, it fades in for a live task.
        if (p.edgeGlow != edgeGlow) {
            edgeGlow = p.edgeGlow
            syncBeam()
        }
        // A new 不透明度 shows at once on a faded ball or capsule.
        applyIdle(animated = false)
        scheduleFold()
    }

    /**
     * The ball or the capsule fades, all of it alike, to the idle opacity, or comes back to full:
     * slowly going idle, quickly on a touch. The card never fades. The form not on screen is kept
     * at full, ready for the next fold or unfold.
     */
    private fun applyIdle(animated: Boolean) {
        val target = if (fold.dimmed) idleOpacity else 1f
        val durationMs = if (target < 1f) DIM_FADE_MS else UNDIM_FADE_MS
        ball?.setIdle(if (fold.folded) target else 1f, animated, durationMs)
        pill?.setIdle(if (fold.folded) 1f else target, animated, durationMs)
        // An idle ball also slides half out over its side; a touch, a confirm or a handoff brings it back whole.
        ball?.let { b ->
            val tuck = fold.folded && fold.dimmed
            if (b.tucked == tuck) return@let
            b.tucked = tuck
            // Never tucked away from under a finger; brought back out the moment one lands.
            if (ballResting() && !(tuck && b.touching)) b.glideTo(b.dockPos(), animated, if (tuck) DIM_FADE_MS else UNTUCK_MS)
        }
    }

    /** The ball's window for this control, added (hidden) on first use; null when the system refused it. */
    private fun ensureBall(): OverlayBall? {
        ball?.let { return it }
        val b = OverlayBall(
            service, wm, ::safeArea, islandColors(), ::onBallTapped, ::stopFromPill, ::onBallTouched,
            capsuleCentre = { capsuleCentre() },
            bottomLimit = { obstacleTop()?.minus(dp(CapsulePlacement.GAP_DP)) },
            islandAtTop = { pill?.down == true },
            topCentreY = {
                if (pill?.down == true) capsuleCentre()
                else CapsulePlacement.centreY(safeArea(), dp(CapsuleMetrics.HEIGHT_DP), dp(CapsulePlacement.GAP_DP), fraction = CapsulePlacement.TOP)
            },
        )
        if (!b.attach(s(R.string.overlay_window_title), passThrough, b.dockPos())) return null
        ball = b
        renderPill(animated = false)
        return b
    }

    /** The ball window over the surface's circle at ([circle]) in the capsule window. */
    private fun ballOver(p: OverlayCapsule, b: OverlayBall, circle: Pair<Int, Int>): WindowPos {
        val a = safeArea()
        return BallGeometry.ballOver(
            windowX = p.params.x,
            windowY = if (p.down) p.params.y else CapsulePlacement.windowTop(a.screenH, p.params.y, p.params.height),
            padX = p.padX, padTop = p.padTop, circleLeft = circle.first, circleTop = circle.second, pad = b.pad,
        )
    }

    private fun foldPill(animated: Boolean) {
        val p = pill ?: return
        if (ballShown) return
        endEditing()
        val b = ensureBall()
        if (b == null) {
            // No second window: the capsule stays as it was.
            fold.unfold(now())
            scheduleFold()
            return
        }
        // Folding is a change worth seeing: at full from here, fading again later.
        applyIdle(animated = false)
        val shown = animated && p.root.isShown && p.surface.width > 0
        if (!shown) {
            p.cancelMorph()
            p.settle(OverlayCapsule.Shape.CAPSULE)
            b.move(b.dockPos())
            b.fadeMark(1f, animated = false)
            ballShown = true
            syncWindows()
            parkCapsule(p)
            renderPill(animated = false)
            return
        }
        val side = b.foldSide
        b.move(ballOver(p, b, p.endCircle(side)))
        p.foldTo(side, animated = true) {
            ballShown = true
            b.fadeMark(0f, animated = false)
            showWindow(b.root)
            b.fadeMark(1f, animated = true)
            // The capsule goes (and gets its plain layout back) once the ball is surely drawn over it.
            b.root.postDelayed({ if (pill === p && ballShown) { syncWindows(); p.settle(OverlayCapsule.Shape.CAPSULE); parkCapsule(p) } }, SWAP_MS)
            renderPill(animated = false)
            b.glideTo(b.dockPos(), animated = true)
        }
    }

    /** The hidden capsule goes to where it rests (its anchor may have changed with a drag off a side), for the next unfold. */
    private fun parkCapsule(p: OverlayCapsule) {
        lift?.cancel()
        lift = null
        p.anchor = spot.anchor
        syncDirection(p)
        p.params.x = capsuleX(p)
        p.params.y = capsuleY(p, safeArea())
        update(p.root, p.params)
    }

    private fun unfoldPill(animated: Boolean) {
        val p = pill ?: return
        val b = ball
        if (b == null || !ballShown) {
            ballShown = false
            syncWindows()
            renderPill()
            return
        }
        if (!animated || captureHidden || !b.root.isShown) {
            p.settle(OverlayCapsule.Shape.CAPSULE)
            b.move(b.dockPos())
            ballShown = false
            syncWindows()
            renderPill(animated = false)
            return
        }
        // Only the ball shows from here (a fold may have just ended with both up).
        syncWindows()
        val side = b.foldSide
        // The capsule window comes up now, transparent, as the circle the ball is heading for:
        // drawn before the swap, so the morph starts on its first frame instead of popping in late.
        renderPill(animated = false)
        p.prepareUnfold(side)
        p.root.alpha = 0f
        p.root.visibility = if (screen != null) View.GONE else if (captureHidden) View.INVISIBLE else View.VISIBLE
        // The ball goes back to the capsule's end first, its mark fading.
        b.fadeMark(0f, animated = true, durationMs = UNFOLD_GLIDE_MS)
        unfolding = true
        b.glideTo(ballOver(p, b, p.capsuleEndCircle(side)), animated = true, durationMs = UNFOLD_GLIDE_MS) {
            unfolding = false
            if (pill !== p || !ballShown) return@glideTo
            ballShown = false
            showWindow(p.root)
            p.unfoldFrom(side, animated = true) {}
            // The ball goes once the capsule is surely drawn over it, back to its dock for next time.
            b.root.postDelayed({
                if (pill === p && !ballShown) { syncWindows(); b.move(b.dockPos()); b.fadeMark(1f, animated = false) }
            }, SWAP_MS)
        }
    }

    /**
     * Capsule and ball visibility from the state: the handoff card, the background-screen window
     * and the phone's own island hide both, a screenshot makes them invisible for its moment,
     * otherwise the one [ballShown] says. GONE windows take no touches, so the hidden one is never
     * in the way.
     */
    private fun syncWindows() {
        syncScreen()
        syncPreview()
        syncBeam()
        val p = pill ?: return
        val away = handoffCard != null || screen != null || islandMode()
        val shown = if (captureHidden) View.INVISIBLE else View.VISIBLE
        p.root.visibility = if (away || ballShown) View.GONE else shown
        ball?.root?.visibility = if (away || !ballShown) View.GONE else shown
        syncAwake()
    }

    /**
     * While the phone's own island stands in for the capsule and the ball (GONE windows keep
     * nothing awake), a 1 px window that takes no touches keeps the screen on: the screen going
     * off stops the task (PhoneA11yService).
     */
    private fun syncAwake() {
        val want = !destroying && pill != null && islandMode()
        if (want == (awake != null)) return
        if (!want) {
            awake?.let { remove(it) }
            awake = null
            return
        }
        val v = View(service)
        val lp = WindowManager.LayoutParams(
            1,
            1,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            title = s(R.string.overlay_window_title)
        }
        if (add(v, lp)) awake = v
    }

    private fun showWindow(root: View) {
        root.alpha = 1f
        // While the background screen or the phone's own island shows, the capsule and the ball stay away.
        val away = (screen != null || islandMode()) && (root === pill?.root || root === ball?.root)
        root.visibility = if (away) View.GONE else if (captureHidden) View.INVISIBLE else View.VISIBLE
    }

    /** The screen and its bars and cutout, in px (the ball's dock is kept clear of them). */
    private fun safeArea(): SafeArea {
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.currentWindowMetrics
            val i = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return SafeArea(m.bounds.width(), m.bounds.height(), i.left, i.top, i.right, i.bottom)
        }
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        val display = wm.defaultDisplay
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

    // ---- window plumbing ------------------------------------------------------------------------

    private fun params(top: Boolean, keepScreenOn: Boolean) = WindowManager.LayoutParams(
        WindowManager.LayoutParams.MATCH_PARENT,
        WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            (if (keepScreenOn) WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON else 0) or
            (if (passThrough) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0),
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = (if (top) Gravity.TOP else Gravity.BOTTOM) or Gravity.CENTER_HORIZONTAL
        softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING
        title = s(R.string.overlay_window_title)
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    /** The confirm and handoff cards: nearly the screen's width, at the top or the bottom. */
    private fun place(root: View, params: WindowManager.LayoutParams, top: Boolean) {
        // Let the window manager lay the window out at the display's real width, then fix the card's
        // own width from what it got. Sizing it from metrics() (WindowManager.getCurrentWindowMetrics)
        // is what made this card 1192 px wide on a 1080 px screen: right after a cold start the
        // service can still hold a configuration from before the display rotated (it reported
        // 2207 × 1080 there), and the window manager's own layout cannot be that stale snapshot.
        params.width = WindowManager.LayoutParams.MATCH_PARENT
        fitCardWidth(root, params, if (top) CardMetrics.HANDOFF_DP else CardMetrics.CONFIRM_DP)
        val (_, insetTop, insetBottom) = metrics()
        params.y = if (top) insetTop + dp(2) else insetBottom + dp(6)
        if (root.isAttachedToWindow) update(root, params)
    }

    /**
     * Shrinks the card window from the display's width to [CardMetrics.windowWidthPx] once the
     * layout knows how wide the display really is, before that frame is drawn. A second
     * configuration change may already have fixed it; then this leaves the width alone.
     */
    private fun fitCardWidth(root: View, params: WindowManager.LayoutParams, capDp: Int) {
        root.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (params.width != WindowManager.LayoutParams.MATCH_PARENT) {
                    root.viewTreeObserver.removeOnPreDrawListener(this)
                    return true
                }
                val displayW = root.width
                if (displayW <= 0) return true
                root.viewTreeObserver.removeOnPreDrawListener(this)
                params.width = CardMetrics.windowWidthPx(displayW, service.resources.displayMetrics.density, capDp)
                // This update also schedules the next traversal: the false below cancels the draw,
                // and without a fresh pass a hidden (screenshot) window would stay unsized.
                update(root, params)
                return false // nothing to see at the display's width: draw once it is the card's
            }
        })
    }

    private fun applyPassThrough(on: Boolean): Boolean {
        if (passThrough == on) return false
        passThrough = on
        var any = false
        for ((root, params) in windows()) {
            params.flags = if (on) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            update(root, params)
            any = true
        }
        // The beam never takes a touch; while a stroke is injected it is not drawn at all.
        if (beam.attached) {
            beam.setHidden(captureHidden || on)
            any = true
        }
        return any
    }

    /** The windows whose touchability follows pass-through (the beam is never touchable). */
    private fun windows(): List<Pair<View, WindowManager.LayoutParams>> = listOfNotNull(
        pill?.let { it.root to it.params }, ball?.let { it.root to it.params },
        confirmCard?.let { it.root to it.params }, handoffCard?.let { it.root to it.params },
        screen?.let { it.root to it.params },
    )

    /** Every window of this control, the beam's included. */
    private fun ownRoots(): List<View> = windows().map { it.first } + listOfNotNull(beam.root.takeIf { beam.attached })

    /** Main-thread identity check, including invisible roots during a display capture. */
    internal fun ownsWindow(windowId: Int): Boolean = windowId >= 0 && ownRoots().any { root ->
        if (!root.isAttachedToWindow) return@any false
        val node = root.createAccessibilityNodeInfo() ?: return@any false
        try { node.windowId == windowId } finally { node.recycle() }
    }

    private fun add(view: View, params: WindowManager.LayoutParams): Boolean = try {
        wm.addView(view, params); true
    } catch (e: Exception) { Log.w(TAG, "overlay addView failed", e); false }

    private fun update(view: View, params: WindowManager.LayoutParams) {
        try { if (view.isAttachedToWindow) wm.updateViewLayout(view, params) } catch (e: Exception) { Log.w(TAG, "overlay update failed", e) }
    }

    private fun remove(view: View) {
        try { wm.removeView(view) } catch (_: Exception) {}
    }

    private fun enter(view: View) {
        if (!animationsOn()) return
        view.alpha = 0f
        view.translationY = -dp(6).toFloat()
        view.scaleX = 0.96f
        view.scaleY = 0.96f
        view.animate().alpha(1f).translationY(0f).scaleX(1f).scaleY(1f).setDuration(220).setInterpolator(OverlayMotion.emphasized).start()
    }

    /** Runs [block] on the main thread and waits for it; null on timeout. */
    private fun <T> onMain(timeoutMs: Long, block: () -> T): T? {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val call = MainThreadCall { try { block() } catch (e: Exception) { Log.w(TAG, "overlay main-thread call failed", e); null } }
        main.post { call.run() }
        return call.await(timeoutMs)
    }

    private fun metrics(): Triple<Int, Int, Int> {
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.currentWindowMetrics
            val insets = m.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            return Triple(m.bounds.width(), insets.top, insets.bottom)
        }
        val res = Resources.getSystem()
        fun dimen(name: String) = res.getIdentifier(name, "dimen", "android").takeIf { it != 0 }?.let(res::getDimensionPixelSize) ?: 0
        @Suppress("DEPRECATION")
        val width = wm.defaultDisplay.width
        return Triple(width, dimen("status_bar_height"), dimen("navigation_bar_height"))
    }

    // ---- look -----------------------------------------------------------------------------------

    private fun isDark() = debugDark
        ?: (service.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
    private fun colors() = if (isDark()) OverlayPalette.DARK else OverlayPalette.LIGHT

    /** The capsule, the card, the ball and the background-screen window: one dark island in either theme. */
    private fun islandColors() = OverlayPalette.island(ThemeAccent.notificationColor(service))

    /** The confirm and handoff cards' surface: the control's, as a drawable. */
    private fun surface(c: OverlayPalette, radius: Float) = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(c.surfaceTop, c.surfaceBottom)).apply {
        cornerRadius = radius
        setStroke(1, c.hairline)
    }

    private fun outlined(c: OverlayPalette) = RippleDrawable(ColorStateList.valueOf(c.ripple), GradientDrawable().apply {
        cornerRadius = dp(14).toFloat(); setStroke(dp(1), c.outline); setColor(Color.TRANSPARENT)
    }, null)

    private fun style(button: TextView, fill: Int, ink: Int, c: OverlayPalette) {
        button.textSize = 15f
        button.setTextColor(ink)
        button.typeface = Typeface.DEFAULT_BOLD
        button.setPadding(dp(18), 0, dp(18), 0)
        button.background = RippleDrawable(ColorStateList.valueOf(c.ripple), GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(fill) }, null)
    }

    private fun textButton(label: String, ink: Int, c: OverlayPalette, action: () -> Unit) = TextView(service).apply {
        text = label
        textSize = 14f
        setTextColor(ink)
        gravity = Gravity.CENTER
        minimumHeight = dp(48)
        minimumWidth = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        background = RippleDrawable(ColorStateList.valueOf(c.ripple), null, GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(Color.WHITE) })
        isClickable = true
        isFocusable = true
        setOnClickListener { action() }
    }

    private fun animationsOn() = OverlayMotion.on()

    private fun dp(v: Int) = service.dp(v)

    companion object {
        private const val TAG = "DshA11y"
        private const val ARM_MS = 600L

        /** The app's page link for 解除限制 (lib/ui/settings/index/spots.dart). */
        private const val UNLOCKS_LINK = "dshgo://open/phone-unlocks"

        /** An app icon not found in the active window is looked for again after this long. */
        private const val ICON_RETRY_MS = 3_000L

        /** The ball's way back to the capsule on a tap: quicker than the way out. */
        private const val UNFOLD_GLIDE_MS = 220L

        /** Frames both windows show at a swap, so the one going is surely covered (≈ 3 frames). */
        private const val SWAP_MS = 48L

        /** Going idle is slow and quiet; a touch brings it back at once. */
        private const val DIM_FADE_MS = 400L
        private const val UNDIM_FADE_MS = 120L

        /** A touched half-hidden ball slides back out under the finger: quick, so a tap lands on it whole. */
        private const val UNTUCK_MS = 200L
    }
}
