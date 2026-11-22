package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import io.github.ccch1mneyyy.dsh_app.pet.WindowPos
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The folded control: a 48 dp ball (its own TYPE_ACCESSIBILITY_OVERLAY window, 10 dp of room round
 * it for the shadow), the capsule's surface and mark as a circle. It shows the task's state only
 * and opens the capsule on a tap. Held still for a second it stops the task ([HoldToStop]: a ring
 * fills round it first, letting go cancels); screen readers get the same stop as an action. Under
 * an island at the top it first rests at the top centre, where the island was ([atTop]); else on
 * the right, level with the capsule. Dragged, it follows the finger and settles on the nearer side
 * — or back at the top centre, let go near it — where it stays (kept across tasks, like the pet's
 * dock: pet/EdgeSnap.kt). A confirm card lifts a ball resting on a side above it. Left alone it
 * fades, all of it alike, to the 闲置时不透明度, and one on a side slides half out of sight over it
 * ([tucked]); a touch brings it back. The whole window (the ball and the room round it) takes the
 * touch, so the half that shows is easy to hit, and it is kept out of the system's edge-back
 * gesture.
 *
 * The window is added once per control and shown or hidden (GONE windows take no touches); the
 * overlay folds and unfolds the capsule around it ([ControlOverlay]).
 */
internal class OverlayBall(
    private val context: Context,
    private val wm: WindowManager,
    private val area: () -> SafeArea,
    private val palette: OverlayPalette,
    private val onTap: () -> Unit,
    /** Held for a second, or the screen reader's stop action. */
    private val onStop: () -> Unit,
    /** A finger came down on the ball or left it (tap, hold or drag): it is not idle, and counts again from the release. */
    private val onTouched: () -> Unit = {},
    /** The capsule's centre y: where a ball the person never moved rests, level with it. */
    private val capsuleCentre: () -> Int,
    /** A confirm card's top while one shows: a resting ball stays above it. */
    private val bottomLimit: () -> Int?,
    /** The capsule is an island at the top (its card opens down): a ball never moved rests at the top centre. */
    private val islandAtTop: () -> Boolean = { false },
    /** The centre y of a ball at the top centre: where an island at the top has its centre. */
    private val topCentreY: () -> Int = capsuleCentre,
) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Dropped at the top centre last (kept across tasks). */
    private var savedTop = prefs.getString(K_SIDE, null) == TOP

    /** Where the person dropped the ball on a side last (kept across tasks); null until they do. */
    private var saved: Dock? = if (!savedTop && prefs.contains(K_Y)) Dock(
        if (prefs.getString(K_SIDE, null) == "left") Side.LEFT else Side.RIGHT,
        prefs.getFloat(K_Y, 0f),
    ) else null

    /** The ball rests at the top centre: dropped there, or never moved and under an island at the top. */
    val atTop: Boolean get() = savedTop || (saved == null && islandAtTop())

    /** Where the ball rests on a side: where it was dropped, else on the right, level with the capsule. */
    val dock: Dock get() = saved ?: BallGeometry.dockLevel(area(), size, margin, capsuleCentre())

    /** The end of the capsule a fold goes to and an unfold comes from: the ball's side, or its middle (null) at the top centre. */
    val foldSide: Side? get() = if (atTop) null else dock.side

    /** Idle: half of it slid out over its side ([dockPos] says so). The owner sets it and glides the ball there. */
    var tucked = false

    /** Room round the ball for its shadow, on every side (the window is square and centred on it). */
    val pad = context.dp(PAD_DP)
    val diameter = context.dp(BALL_DP)

    /** Window side. */
    val size = diameter + 2 * pad

    /** The ball's gap to the screen side, as a window margin: 12 dp, like the capsule. */
    private val margin = BallGeometry.margin(context.dp(EDGE_DP), pad)

    private val ball = BallView(context)
    val root: FrameLayout = FrameLayout(context).apply {
        setPadding(pad, pad, pad, pad)
        clipToPadding = false
        clipChildren = false
        addView(ball, FrameLayout.LayoutParams(diameter, diameter))
    }

    val params = WindowManager.LayoutParams(
        size,
        size,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            // Tucked, half the window is past the screen's side.
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    private var glide: ValueAnimator? = null
    private var markFade: ValueAnimator? = null
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false
    private var tracker: VelocityTracker? = null
    private val hold = HoldToStop()

    /** A finger is on the ball: the owner leaves its position alone (no tucking under a drag). */
    var touching = false
        private set

    init {
        ball.setOnClickListener { onTap() }
        ball.setOnTouchListener { _, e -> onTouch(e) }
        // The room round the ball takes touches anyway (it is the window's): it counts as the ball.
        root.setOnTouchListener { _, e -> onTouch(e) }
        if (Build.VERSION.SDK_INT >= 29) {
            // At the screen's side a drag inward would otherwise be the system's back gesture.
            root.addOnLayoutChangeListener { v, l, t, r, b, _, _, _, _ -> v.systemGestureExclusionRects = listOf(Rect(0, 0, r - l, b - t)) }
        }
    }

    val attached: Boolean get() = root.isAttachedToWindow

    /** Adds the window, hidden, at [at]; false when the system refused it. */
    fun attach(title: CharSequence, untouchable: Boolean, at: WindowPos): Boolean {
        if (attached) return true
        params.title = title
        params.flags = if (untouchable) params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        else params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        params.x = at.x
        params.y = at.y
        root.visibility = View.GONE
        return try {
            wm.addView(root, params)
            true
        } catch (e: Exception) {
            Log.w(TAG, "ball addView failed", e)
            false
        }
    }

    fun detach() {
        cancelGlide()
        markFade?.cancel()
        markFade = null
        endHold()
        endDrag()
        root.animate().cancel()
        try { wm.removeView(root) } catch (_: Exception) {}
    }

    /** What the mark says, the screen reader's line, and whether a lifted limit badges it. */
    fun setLook(look: MarkLook, description: CharSequence, badge: Boolean, stopLabel: CharSequence?, icon: android.graphics.drawable.Drawable? = null) {
        ball.icon = icon
        ball.look = look
        ball.badge = badge
        ball.contentDescription = description
        ball.stopLabel = stopLabel
    }

    /** The whole ball's opacity: the 闲置时不透明度 when idle, full otherwise. */
    fun setIdle(alpha: Float, animated: Boolean, durationMs: Long) = OverlayMotion.fadeIdle(root, alpha, animated, durationMs)

    /**
     * Where the ball rests now: at the top centre ([atTop]; never tucked), or [dock] on the current
     * screen, above a confirm card if one shows, half out of sight when [tucked].
     */
    fun dockPos(): WindowPos {
        val a = area()
        if (atTop) return BallGeometry.topCentre(a, size, topCentreY())
        val d = dock
        val pos = BallGeometry.above(EdgeSnap.position(d, size, size, a, margin), size, bottomLimit(), EdgeSnap.minY(a, margin))
        return if (tucked) BallGeometry.tucked(pos, d.side, a, pad, diameter) else pos
    }

    /** A capsule dragged off [side] folds into the ball there, level with it (centre [centreY]): that is its dock from now on. */
    fun dropAt(side: Side, centreY: Int) = keep(BallGeometry.dockLevel(area(), size, margin, centreY, side))

    val pos: WindowPos get() = WindowPos(params.x, params.y)

    fun move(to: WindowPos) {
        cancelGlide()
        params.x = to.x
        params.y = to.y
        update()
    }

    /** Slides the window to [to] (at once when [animated] is false), then runs [then]. */
    fun glideTo(to: WindowPos, animated: Boolean, durationMs: Long = GLIDE_MS, then: (() -> Unit)? = null) {
        cancelGlide()
        val fromX = params.x
        val fromY = params.y
        if (!animated || !OverlayMotion.on() || (fromX == to.x && fromY == to.y)) {
            move(to)
            then?.invoke()
            return
        }
        glide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = durationMs
            interpolator = OverlayMotion.glide
            addUpdateListener { a ->
                val f = a.animatedValue as Float
                params.x = (fromX + (to.x - fromX) * f).roundToInt()
                params.y = (fromY + (to.y - fromY) * f).roundToInt()
                update()
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (glide === animation) glide = null
                    if (!cancelled) then?.invoke()
                }
            })
            start()
        }
    }

    fun cancelGlide() {
        glide?.cancel()
        glide = null
    }

    /** Fades the mark inside the ball (the surface stays): out on the way back into the capsule, in after a fold. */
    fun fadeMark(to: Float, animated: Boolean, durationMs: Long = MARK_MS) {
        markFade?.cancel()
        markFade = null
        if (!animated || !OverlayMotion.on()) {
            ball.markAlpha = to
            return
        }
        markFade = ValueAnimator.ofFloat(ball.markAlpha, to).apply {
            duration = durationMs
            interpolator = OverlayMotion.glide
            addUpdateListener { ball.markAlpha = it.animatedValue as Float }
            start()
        }
    }

    private fun update() {
        try { if (root.isAttachedToWindow) wm.updateViewLayout(root, params) } catch (e: Exception) { Log.w(TAG, "ball update failed", e) }
    }

    // ---- touch ----------------------------------------------------------------------------------

    private fun onTouch(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                cancelGlide()
                // A tucked ball glides back out from here; a drag takes over from wherever it has got to.
                touching = true
                onTouched()
                downX = e.rawX
                downY = e.rawY
                startX = params.x
                startY = params.y
                dragging = false
                tracker?.recycle()
                tracker = VelocityTracker.obtain().also { track(it, e) }
                press(true)
                startHold()
            }
            MotionEvent.ACTION_MOVE -> {
                tracker?.let { track(it, e) }
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!dragging && hold.state != HoldToStop.State.FIRED && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    cancelGlide()
                    // The ball follows the finger from where it was touched. Only a ball that glided
                    // since then (untucking) is taken over where it has got to, so it doesn't jump back.
                    if (params.x != startX || params.y != startY) {
                        startX = params.x - dx.roundToInt()
                        startY = params.y - dy.roundToInt()
                    }
                    hold.moved()
                    endHold()
                    press(false)
                }
                if (dragging) {
                    val p = EdgeSnap.clampDrag(startX + dx.roundToInt(), startY + dy.roundToInt(), size, size, area())
                    params.x = p.x
                    params.y = p.y
                    update()
                }
            }
            MotionEvent.ACTION_UP -> {
                tracker?.let { track(it, e) }
                press(false)
                val release = hold.up(SystemClock.uptimeMillis())
                endHold()
                // The drop is kept before the owner hears the touch ended: it may untuck the ball
                // at once (no animations), and that must go to the new dock, not the old one.
                if (release == HoldToStop.Release.DRAG) settle(velocityX())
                touching = false
                onTouched()
                when (release) {
                    HoldToStop.Release.TAP -> ball.performClick()
                    HoldToStop.Release.STOP -> fire()
                    else -> Unit
                }
                endDrag()
            }
            MotionEvent.ACTION_CANCEL -> {
                press(false)
                hold.cancel()
                endHold()
                if (dragging) settle(0f)
                touching = false
                onTouched()
                endDrag()
            }
        }
        return true
    }

    /**
     * The ring round the ball while it is held; the stop when it closes. Frame callbacks on the
     * wall clock ([HoldToStop]), not an animator: with 移除动画 an animator would end at once and the
     * hold would never stop anything.
     */
    private val holdTick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            if (hold.tick(now)) {
                fire()
                return
            }
            ball.hold = hold.progress(now)
            if (hold.nextAt() != null) ball.postOnAnimation(this)
        }
    }

    private fun fire() {
        ball.hold = 1f
        ball.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        press(false)
        onStop()
    }

    private fun startHold() {
        endHold()
        hold.down(SystemClock.uptimeMillis())
        ball.postOnAnimation(holdTick)
    }

    private fun endHold() {
        ball.removeCallbacks(holdTick)
        if (hold.state != HoldToStop.State.FIRED) ball.hold = 0f
    }

    /** Raw coordinates: the window moves under the finger, so view coordinates stand still. */
    private fun track(t: VelocityTracker, e: MotionEvent) {
        val copy = MotionEvent.obtain(e)
        copy.setLocation(e.rawX, e.rawY)
        t.addMovement(copy)
        copy.recycle()
    }

    private fun velocityX(): Float {
        val t = tracker ?: return 0f
        t.computeCurrentVelocity(1000)
        return t.xVelocity
    }

    private fun endDrag() {
        dragging = false
        tracker?.recycle()
        tracker = null
    }

    private fun settle(velocityX: Float) {
        val a = area()
        if (BallGeometry.nearTopCentre(params.x + size / 2, params.y + size / 2, a, diameter)) keepTop()
        else keep(EdgeSnap.dockFor(params.x, params.y, size, size, a, margin, velocityX))
        glideTo(dockPos(), OverlayMotion.on())
    }

    private fun keep(d: Dock) {
        saved = d
        savedTop = false
        prefs.edit().putString(K_SIDE, if (d.side == Side.LEFT) "left" else "right").putFloat(K_Y, d.yFraction).apply()
    }

    private fun keepTop() {
        saved = null
        savedTop = true
        prefs.edit().putString(K_SIDE, TOP).remove(K_Y).apply()
    }

    private fun press(down: Boolean) {
        val scale = if (down) PRESS_SCALE else 1f
        if (!OverlayMotion.on()) {
            ball.scaleX = scale
            ball.scaleY = scale
            return
        }
        ball.animate().scaleX(scale).scaleY(scale).setDuration(if (down) 90 else 200).setInterpolator(OverlayMotion.glide).start()
    }

    /**
     * The ball itself: the capsule's surface as a circle and its mark ([MarkPainter]); a small
     * brick-rose dot on its shoulder while a limit is lifted; the hold-to-stop ring.
     */
    private inner class BallView(context: Context) : View(context) {
        private val painter = MarkPainter(context)
        private val surface = SurfacePainter(context)
        private val iconPainter = IconPainter()

        /** The app DSH works in, the state as a badge on it (the capsule's mark column, as a ball). */
        var icon: android.graphics.drawable.Drawable? = null
            set(value) { if (field !== value) { field = value; invalidate() } }
        private val circle = RectF()
        private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
        private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var breath: ValueAnimator? = null
        private var phase = 1f
        private var shown = false

        var look: MarkLook = MarkLook.RUNNING
            set(value) {
                if (field == value) return
                field = value
                syncBreath()
                invalidate()
            }

        var badge = false
            set(value) { if (field != value) { field = value; invalidate() } }

        /** 0–1: the hold-to-stop ring. */
        var hold = 0f
            set(value) { if (field != value) { field = value; invalidate() } }

        var stopLabel: CharSequence? = null

        /** The mark's opacity (0–1) on top of its own; the surface is not affected. */
        var markAlpha = 1f
            set(value) {
                val v = value.coerceIn(0f, 1f)
                if (field == v) return
                field = v
                invalidate()
            }

        init {
            isClickable = true
            isFocusable = true
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setOval(0, 0, view.width, view.height)
            }
            softShadow(palette, 5f)
        }

        override fun getAccessibilityClassName(): CharSequence = android.widget.Button::class.java.name

        override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(info)
            stopLabel?.let { info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.overlay_action_stop, it)) }
        }

        override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
            if (action == R.id.overlay_action_stop && stopLabel != null) {
                onStop()
                return true
            }
            return super.performAccessibilityAction(action, arguments)
        }

        override fun onVisibilityAggregated(isVisible: Boolean) {
            super.onVisibilityAggregated(isVisible)
            shown = isVisible
            syncBreath()
        }

        override fun onDetachedFromWindow() {
            shown = false
            syncBreath()
            super.onDetachedFromWindow()
        }

        private fun syncBreath() {
            val want = shown && look == MarkLook.RUNNING && OverlayMotion.on()
            if (want && breath == null) {
                breath = breathing { phase = it; invalidate() }
            } else if (!want && breath != null) {
                breath?.cancel()
                breath = null
                phase = 1f
                invalidate()
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            circle.set(0f, 0f, width.toFloat(), height.toFloat())
            surface.draw(canvas, circle, width / 2f, palette)
            val cx = width / 2f
            val cy = height / 2f
            val app = icon
            if (app != null) {
                val s = context.dpf(MarkView.ICON_DP)
                iconPainter.draw(canvas, app, cx, cy, s, markAlpha)
                painter.drawBadge(canvas, cx + s / 2 - context.dpf(2f), cy + s / 2 - context.dpf(2f), look, palette, phase, markAlpha)
                if (look == MarkLook.RUNNING && markAlpha > 0f) {
                    // A thin breathing ring round the icon: still at work.
                    ringPaint.color = palette.accent
                    ringPaint.alpha = (255 * markAlpha * (0.25f + 0.5f * phase)).roundToInt()
                    ringPaint.strokeWidth = context.dpf(1.5f)
                    val rr = width / 2f - context.dpf(3f)
                    canvas.drawCircle(cx, cy, rr, ringPaint)
                }
            } else painter.draw(canvas, cx, cy, look, palette, phase, markAlpha)
            if (hold > 0f) {
                // Over the mark's ring, from twelve o'clock, in the stop colour.
                ringPaint.color = palette.danger
                ringPaint.alpha = 255
                ringPaint.strokeWidth = context.dpf(2.5f)
                val r = if (icon != null) width / 2f - context.dpf(3f) else context.dpf(10f)
                canvas.drawArc(cx - r, cy - r, cx + r, cy + r, -90f, 360f * hold, false, ringPaint)
            }
            if (badge && markAlpha > 0f) {
                // On the ball's shoulder (45°), ringed in the surface so it reads as on top of it.
                val off = width / 2f * 0.7071f
                val bx = cx + off
                val by = cy - off
                dotPaint.color = palette.surfaceTop
                dotPaint.alpha = (255 * markAlpha).roundToInt()
                canvas.drawCircle(bx, by, context.dpf(5.5f), dotPaint)
                dotPaint.color = palette.danger
                dotPaint.alpha = (255 * markAlpha).roundToInt()
                canvas.drawCircle(bx, by, context.dpf(4f), dotPaint)
            }
        }
    }

    companion object {
        private const val TAG = "DshA11y"
        private const val PREFS = OverlayPrefs.FILE
        private const val K_SIDE = "ballSide"
        private const val K_Y = "ballY"
        private const val TOP = "top"

        const val BALL_DP = CapsuleMetrics.HEIGHT_DP
        const val PAD_DP = 10
        const val EDGE_DP = CapsuleMetrics.EDGE_DP
        const val GLIDE_MS = 260L
        const val MARK_MS = 200L
        const val PRESS_SCALE = 0.94f
    }
}
