package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.TextUtils
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
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The background screen, shown (docs/design/phone-overlay.md §13): while a task runs on the
 * background screen and 实时查看后台屏 is on, this small window takes the capsule's place — a live,
 * view-only picture of the background screen in the island's dark frame, what DSH does under it,
 * 暂停 (held a second: 停止) and 回到 DSH Go. A beam runs round it while DSH works.
 *
 * It rests against the left or right side at a height the person chose (kept across tasks), in
 * one of two sizes: a tap on the picture switches them. The key in the picture's corner minimises
 * it to a ball at the same side and height (the app's icon, the beam round it while DSH works); a
 * tap on the ball brings the window back. Only the person minimises it, never a timer, and each task
 * starts with the picture. While minimised no frames are taken.
 * Dragged, either form follows the finger and settles on the nearer side (or the side it was flung to). Its own TYPE_ACCESSIBILITY_OVERLAY window,
 * never focusable; it keeps the screen on like the capsule (the task stops if the screen goes off).
 *
 * Main thread only. [ControlOverlay] decides when it shows and feeds it frames and the line.
 */
internal class OverlayScreen(
    private val ctx: Context,
    private val wm: WindowManager,
    private val c: OverlayPalette,
    private val strings: Strings,
    private val area: () -> SafeArea,
    private val actions: Actions,
) {
    class Strings(
        val pause: String, val resume: String, val stop: String, val back: String,
        val view: String, val separator: String,
        val minimize: String, val restore: String,
    )

    interface Actions {
        /** Any finger came down on the window. */
        fun touched()
        fun pause()
        fun stop()
        fun back()

        /** Minimised or brought back: frames are taken only while the picture shows. */
        fun minimized(min: Boolean)
    }

    private val prefs = OverlayPrefs.prefs(ctx)
    private var side = if (prefs.getString(K_SIDE, null) == "left") Side.LEFT else Side.RIGHT
    private var fraction = prefs.getFloat(K_Y, ScreenWindow.CENTRE)
    private var large = prefs.getBoolean(K_LARGE, false)
    /** Only the person minimises it (最小化), never a timer; each task starts with the picture. */
    private var minimized = false

    /** Shown as the ball: the picture is away and takes no frames. */
    val isMinimized: Boolean get() = minimized

    /** Height ÷ width of the background screen, from its frames. */
    private var aspect = ScreenWindow.DEFAULT_ASPECT

    /** The picture's width now (animates between the two sizes). */
    private var viewW = ctx.dp(if (large) ScreenWindow.LARGE_DP else ScreenWindow.SMALL_DP)

    private val pad = ctx.dp(PAD_DP)
    private val frame = ctx.dp(ScreenWindow.FRAME_DP)
    private val footerH = ctx.dp(ScreenWindow.FOOTER_DP)
    private val edge = ctx.dp(CapsuleMetrics.EDGE_DP)
    private val ballPx = ctx.dp(OverlayBall.BALL_DP)

    // ---- views -----------------------------------------------------------------------------------

    private val image = ImageView(ctx).apply {
        scaleType = ImageView.ScaleType.FIT_XY
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private val label = TextView(ctx).apply {
        gravity = Gravity.CENTER
        textSize = 11.5f
        setTextColor(c.muted)
        setPadding(ctx.dp(10), ctx.dp(8), ctx.dp(10), ctx.dp(8))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The picture: rounded, view only; a tap switches the size. */
    private val viewport = FrameLayout(ctx).apply {
        setBackgroundColor(c.field)
        clipToOutline = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) =
                outline.setRoundRect(0, 0, view.width, view.height, ctx.dpf(ScreenWindow.VIEW_RADIUS_DP.toFloat()))
        }
        isClickable = true
        isFocusable = true
        contentDescription = strings.view
        addView(image, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        addView(label, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        setOnClickListener { toggleSize() }
    }

    /** 最小化, in the picture's top corner away from the screen's edge: a dark disc over the picture. */
    private val minKey = RoundKey(ctx, MIN_DISC_DP, 13).apply {
        disc = MIN_DISC
        ink = c.ink
        setGlyph(Glyph.MINIMIZE, animated = false)
        contentDescription = strings.minimize
        setOnClickListener { setMinimized(true) }
    }.also {
        viewport.addView(it, FrameLayout.LayoutParams(ctx.dp(MIN_KEY_DP), ctx.dp(MIN_KEY_DP), Gravity.TOP or Gravity.END))
    }

    /** The window minimised: a ball with the app's icon, the beam round it while DSH works. */
    private val mini = object : View(ctx) {
        private val painter = SurfacePainter(ctx)
        private val mark = MarkPainter(ctx)
        private val iconPainter = IconPainter()
        private val rect = RectF()
        val beam = IslandBeam(this)
        var icon: android.graphics.drawable.Drawable? = null
            set(v) { if (field !== v) { field = v; invalidate() } }
        var look = MarkLook.RUNNING
            set(v) { if (field != v) { field = v; invalidate() } }

        /** 0–1: the hold-to-stop ring. */
        var hold = 0f
            set(v) { if (field != v) { field = v; invalidate() } }
        private val ringPaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            style = android.graphics.Paint.Style.STROKE
            strokeCap = android.graphics.Paint.Cap.ROUND
            strokeWidth = ctx.dpf(2.5f)
            color = c.danger
        }

        init {
            isClickable = true
            isFocusable = true
            contentDescription = strings.restore
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setOval(0, 0, view.width, view.height)
            }
            softShadow(c, 5f)
            setOnClickListener { setMinimized(false) }
        }

        override fun getAccessibilityClassName(): CharSequence = android.widget.Button::class.java.name

        override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(info)
            if (state?.stopped != true) info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.overlay_action_stop, strings.stop))
        }

        override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
            if (action == R.id.overlay_action_stop && state?.stopped != true) {
                actions.stop()
                return true
            }
            return super.performAccessibilityAction(action, arguments)
        }

        /** Touches are the window's ([watchDrag]): a tap expands, a hold stops, a drag moves. */
        @android.annotation.SuppressLint("ClickableViewAccessibility")
        override fun onTouchEvent(event: MotionEvent): Boolean = true

        override fun onVisibilityAggregated(isVisible: Boolean) {
            super.onVisibilityAggregated(isVisible)
            beam.visible(isVisible && isAttachedToWindow)
        }

        override fun onDetachedFromWindow() {
            beam.visible(false)
            super.onDetachedFromWindow()
        }

        override fun onDraw(canvas: Canvas) {
            rect.set(0f, 0f, width.toFloat(), height.toFloat())
            val r = width / 2f
            painter.draw(canvas, rect, r, c)
            val app = icon
            if (app != null) {
                val s = ctx.dpf(MarkView.ICON_DP)
                iconPainter.draw(canvas, app, r, r, s, 1f)
                mark.drawBadge(canvas, r + s / 2 - ctx.dpf(2f), r + s / 2 - ctx.dpf(2f), look, c, 1f, 1f)
            } else {
                mark.draw(canvas, r, r, look, c, 1f, 1f)
            }
            painter.drawBeam(canvas, rect, r, c, beam.turn, beam.alpha)
            if (hold > 0f) {
                val rr = r - ctx.dpf(3f)
                canvas.drawArc(r - rr, r - rr, r + rr, r + rr, -90f, 360f * hold, false, ringPaint)
            }
        }
    }

    private val line = TextView(ctx).apply {
        textSize = 13f
        setTextColor(c.ink)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
    }

    private val sub = TextView(ctx).apply {
        textSize = 10.5f
        setTextColor(c.faint)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        fontFeatureSettings = "tnum"
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private var state: CapsuleState? = null

    val pause = RoundKey(ctx, KEY_DISC_DP, 15).apply {
        disc = c.tonal
        ink = c.ink
        holdColor = c.danger
        contentDescription = strings.pause
        setOnClickListener { actions.pause() }
        holdToStop({ if (state?.stopped == true) null else strings.stop }) { actions.stop() }
    }

    private val back = RoundKey(ctx, KEY_DISC_DP, 15).apply {
        disc = c.tonal
        ink = c.ink
        setGlyph(Glyph.BACK, animated = false)
        contentDescription = strings.back
        setOnClickListener { actions.back() }
    }

    private val footer = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(ctx.dp(7), ctx.dp(8), 0, 0)
        addView(line, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = ctx.dp(6) })
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(sub, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            val k = ctx.dp(KEY_DP)
            addView(pause, LinearLayout.LayoutParams(k, k))
            addView(back, LinearLayout.LayoutParams(k, k))
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    /** The island: the frame, its picture and footer, the beam on top. */
    private val surface = object : LinearLayout(ctx) {
        private val painter = SurfacePainter(ctx)
        private val rect = RectF()
        private val radius = ctx.dpf(ScreenWindow.RADIUS_DP.toFloat())
        val beam = IslandBeam(this)

        init {
            orientation = VERTICAL
            setWillNotDraw(false)
            setPadding(frame, frame, frame, 0)
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) = outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
            softShadow(c, 8f)
        }

        override fun onVisibilityAggregated(isVisible: Boolean) {
            super.onVisibilityAggregated(isVisible)
            beam.visible(isVisible && isAttachedToWindow)
        }

        override fun onDetachedFromWindow() {
            beam.visible(false)
            super.onDetachedFromWindow()
        }

        override fun onDraw(canvas: Canvas) {
            rect.set(0f, 0f, width.toFloat(), height.toFloat())
            painter.draw(canvas, rect, radius, c)
        }

        override fun dispatchDraw(canvas: Canvas) {
            super.dispatchDraw(canvas)
            painter.drawBeam(canvas, rect, radius, c, beam.turn, beam.alpha)
        }
    }.also {
        it.addView(viewport, LinearLayout.LayoutParams(viewW, ScreenWindow.viewHeight(viewW, aspect, Int.MAX_VALUE)))
        it.addView(footer, LinearLayout.LayoutParams(viewW, footerH))
    }

    private val beam get() = surface.beam

    val root: FrameLayout = object : FrameLayout(ctx) {
        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) actions.touched()
            return super.dispatchTouchEvent(ev)
        }

        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = watchDrag(ev)

        override fun onTouchEvent(ev: MotionEvent): Boolean {
            watchDrag(ev)
            return true
        }
    }.apply {
        setPadding(pad, pad, pad, pad)
        clipToPadding = false
        clipChildren = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(surface, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT))
        addView(mini, FrameLayout.LayoutParams(ballPx, ballPx))
    }

    val params = WindowManager.LayoutParams(
        0, 0,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    val attached: Boolean get() = root.isAttachedToWindow

    // ---- showing ----------------------------------------------------------------------------------

    /** Adds the window at its place, coming in (fade, 0.92 → 1); false when refused. */
    fun show(title: CharSequence, hidden: Boolean): Boolean {
        if (attached) return true
        params.title = title
        removing = false
        syncForm()
        fit()
        root.visibility = if (hidden) View.INVISIBLE else View.VISIBLE
        return try {
            wm.addView(root, params)
            if (OverlayMotion.on()) {
                val f = face()
                f.alpha = 0f
                f.scaleX = 0.92f
                f.scaleY = 0.92f
                f.pivotX = if (minimized) ballPx / 2f else if (side == Side.RIGHT) surfaceW().toFloat() else 0f
                f.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(260).setInterpolator(OverlayMotion.glide).start()
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "screen window addView failed", e)
            false
        }
    }

    /** Goes; [animated]: it fades out first. */
    fun remove(animated: Boolean) {
        if (!attached) return
        removing = true
        glide?.cancel()
        sizeAnim?.cancel()
        endHold()
        sub.removeCallbacks(subTick)
        // A minimise or restore under way must not take the fade over (its end action would never
        // run and the window would stay): both forms stop, the one showing fades.
        surface.animate().cancel()
        mini.animate().cancel()
        if (!animated || !OverlayMotion.on()) { removeNow(); return }
        val f = if (mini.visibility == View.VISIBLE) mini else surface
        f.animate().alpha(0f).scaleX(0.94f).scaleY(0.94f).setDuration(180).setInterpolator(OverlayMotion.emphasized)
            .withEndAction { removeNow() }.start()
    }

    private fun removeNow() {
        try { wm.removeView(root) } catch (_: Exception) {}
        for (f in listOf(surface, mini)) {
            f.animate().cancel()
            f.alpha = 1f
            f.scaleX = 1f
            f.scaleY = 1f
        }
    }

    /** Going away: no minimise or restore starts. */
    private var removing = false

    /** What is on screen: the island with its picture, or the ball. */
    private fun face(): View = if (minimized) mini else surface

    private fun syncForm() {
        surface.visibility = if (minimized) View.GONE else View.VISIBLE
        mini.visibility = if (minimized) View.VISIBLE else View.GONE
    }

    /**
     * 最小化 / back: the island shrinks toward its side and the ball grows in at the same side and
     * height (or the other way), the window resized between the two. Only for this task.
     */
    private fun setMinimized(min: Boolean) {
        if (min == minimized || removing) return
        endHold()
        minimized = min
        actions.minimized(min)
        val from = if (min) surface else mini
        val to = if (min) mini else surface
        from.animate().cancel()
        to.animate().cancel()
        fun swap() {
            from.alpha = 1f
            from.scaleX = 1f
            from.scaleY = 1f
            syncForm()
            fit()
            update()
        }
        if (!attached || !OverlayMotion.on()) { swap(); return }
        from.pivotX = if (from === mini) ballPx / 2f else if (side == Side.RIGHT) surfaceW().toFloat() else 0f
        from.pivotY = from.height / 2f
        from.animate().alpha(0f).scaleX(0.6f).scaleY(0.6f).setDuration(150).setInterpolator(OverlayMotion.emphasized).withEndAction {
            if (removing) return@withEndAction
            swap()
            to.alpha = 0f
            to.scaleX = 0.7f
            to.scaleY = 0.7f
            to.pivotX = if (to === mini) ballPx / 2f else if (side == Side.RIGHT) surfaceW().toFloat() else 0f
            to.pivotY = if (to === mini) ballPx / 2f else (viewH() + frame + footerH) / 2f
            to.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(240).setInterpolator(OverlayMotion.glide).start()
        }.start()
    }

    /** Not drawn (a screenshot of the main screen, an injected stroke). */
    fun setHidden(hidden: Boolean) {
        root.visibility = if (hidden) View.INVISIBLE else View.VISIBLE
    }

    /** A rotation or a new display size. */
    fun relayout() {
        if (!attached) return
        fit()
        update()
    }

    // ---- content ----------------------------------------------------------------------------------

    /** The line under the picture, its second line and the keys, as the capsule shows them. */
    fun render(s: CapsuleState) {
        val old = state
        state = s
        if (line.text?.toString() != s.line) {
            line.animate().cancel()
            if (old == null || !OverlayMotion.on()) line.text = s.line
            else {
                val rise = ctx.dpf(5f)
                line.animate().alpha(0f).translationY(-rise).setDuration(70).withEndAction {
                    line.text = s.line
                    line.translationY = rise
                    line.animate().alpha(1f).translationY(0f).setDuration(220).setInterpolator(OverlayMotion.glide).start()
                }.start()
            }
        }
        line.contentDescription = listOfNotNull(s.line, s.sub).joinToString(". ")
        subBase = s.sub
        startedAt = s.startedAt
        tickSub()
        val keys = if (s.stopped) View.GONE else View.VISIBLE
        pause.visibility = keys
        back.visibility = keys
        pause.setGlyph(if (s.paused) Glyph.PLAY else Glyph.PAUSE, old != null)
        pause.disc = if (s.paused) c.accentSoft else c.tonal
        pause.ink = if (s.paused) c.accent else c.ink
        pause.contentDescription = if (s.paused) strings.resume else strings.pause
        beam.running = s.look == MarkLook.RUNNING
        mini.beam.running = s.look == MarkLook.RUNNING
        mini.look = s.look
        mini.icon = s.icon
        minKey.visibility = if (s.stopped) View.GONE else View.VISIBLE
    }

    /** A frame of the background screen, or what to say in its place (waiting, protected…). */
    fun showFrame(bitmap: Bitmap?, text: String?) {
        image.setImageBitmap(bitmap)
        image.visibility = if (bitmap == null) View.GONE else View.VISIBLE
        label.text = text.orEmpty()
        label.visibility = if (bitmap == null) View.VISIBLE else View.GONE
        viewport.contentDescription = if (bitmap == null && text != null) text else strings.view
        if (bitmap != null && bitmap.width > 0) {
            val a = bitmap.height.toFloat() / bitmap.width
            if (abs(a - aspect) > 0.01f) {
                aspect = a
                resizeViewport()
                if (attached) { fit(); update() }
            }
        }
    }

    private var subBase: String? = null
    private var startedAt: Long? = null
    private val subTick = Runnable { tickSub() }

    private fun tickSub() {
        sub.removeCallbacks(subTick)
        val base = subBase
        val from = startedAt
        val now = SystemClock.uptimeMillis()
        sub.text = when {
            base == null -> ""
            from == null -> base
            else -> base + strings.separator + Elapsed.format(now - from)
        }
        if (base != null && from != null && attached) sub.postDelayed(subTick, 1_000 - (now - from) % 1_000)
    }

    init {
        sub.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = tickSub()
            override fun onViewDetachedFromWindow(v: View) { sub.removeCallbacks(subTick) }
        })
    }

    // ---- size and place ---------------------------------------------------------------------------

    private fun viewH(): Int {
        val a = area()
        // Never taller than the safe area leaves room for (the footer and a gap each side).
        val max = a.screenH - a.top - a.bottom - footerH - 2 * frame - 2 * pad - 2 * edge
        return ScreenWindow.viewHeight(viewW, aspect, max.coerceAtLeast(ctx.dp(80)))
    }

    private fun surfaceW() = viewW + 2 * frame

    private fun resizeViewport() {
        (viewport.layoutParams as LinearLayout.LayoutParams).apply { width = viewW; height = viewH() }
        (footer.layoutParams as LinearLayout.LayoutParams).width = viewW
        viewport.requestLayout()
        footer.requestLayout()
    }

    /** 最小化 in the picture's top corner toward the screen's middle (away from the edge it rests on). */
    private fun placeMinKey() {
        val lp = minKey.layoutParams as FrameLayout.LayoutParams
        val g = Gravity.TOP or (if (side == Side.RIGHT) Gravity.START else Gravity.END)
        if (lp.gravity != g) { lp.gravity = g; minKey.layoutParams = lp }
    }

    /** Size and place from [side], [fraction] and the picture's size (or the ball's, minimised). */
    private fun fit() {
        resizeViewport()
        val w = if (minimized) ballPx + 2 * pad else surfaceW() + 2 * pad
        val h = if (minimized) ballPx + 2 * pad else viewH() + frame + footerH + 2 * pad
        val a = area()
        params.width = w
        params.height = h
        params.x = ScreenWindow.left(side, a, w, edge - pad)
        params.y = ScreenWindow.top(fraction, a, h, edge - pad)
        placeMinKey()
    }

    private var sizeAnim: ValueAnimator? = null

    /** 大 ↔ 小, from the side it rests on, its centre height kept. */
    private fun toggleSize() {
        large = !large
        prefs.edit().putBoolean(K_LARGE, large).apply()
        viewport.contentDescription = strings.view
        val to = ctx.dp(if (large) ScreenWindow.LARGE_DP else ScreenWindow.SMALL_DP)
        sizeAnim?.cancel()
        if (!OverlayMotion.on()) {
            viewW = to
            fit(); update()
            return
        }
        sizeAnim = ValueAnimator.ofInt(viewW, to).apply {
            duration = 300
            interpolator = OverlayMotion.glide
            addUpdateListener { viewW = it.animatedValue as Int; fit(); update() }
            start()
        }
    }

    private fun update() {
        try { if (attached) wm.updateViewLayout(root, params) } catch (e: Exception) { Log.w(TAG, "screen window update failed", e) }
    }

    // ---- dragging -----------------------------------------------------------------------------------

    private val slop = ViewConfiguration.get(ctx).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dragFrom = false
    private var dragging = false
    private var tracker: VelocityTracker? = null
    private var glide: ValueAnimator? = null

    /** The ball held: the ring fills and the task stops, as on the capsule's ball. */
    private val hold = HoldToStop()
    private var onBall = false

    private val holdTick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            if (hold.tick(now)) {
                mini.hold = 1f
                mini.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                actions.stop()
                return
            }
            mini.hold = hold.progress(now)
            if (hold.nextAt() != null) mini.postOnAnimation(this)
        }
    }

    private fun endHold() {
        mini.removeCallbacks(holdTick)
        if (hold.state != HoldToStop.State.FIRED) mini.hold = 0f
    }

    /** Watches every event; true once it is a drag (the root takes the gesture over from the keys and the picture). */
    private fun watchDrag(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                startX = params.x
                startY = params.y
                dragging = false
                // 暂停 is a hold too: a finger on it never drags.
                dragFrom = !on(pause, e) && !on(back, e) && !on(minKey, e)
                onBall = minimized && on(mini, e)
                if (onBall) {
                    endHold()
                    if (state?.stopped != true) {
                        hold.down(SystemClock.uptimeMillis())
                        mini.postOnAnimation(holdTick)
                    }
                }
                glide?.cancel()
                tracker?.recycle()
                tracker = VelocityTracker.obtain().also { track(it, e) }
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragFrom) return false
                tracker?.let { track(it, e) }
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!dragging && !(onBall && hold.state == HoldToStop.State.FIRED) && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    if (onBall) { hold.moved(); endHold() }
                }
                if (dragging) {
                    val a = area()
                    params.x = (startX + dx.roundToInt()).coerceIn(-params.width / 2, a.screenW - params.width / 2)
                    params.y = (startY + dy.roundToInt()).coerceIn(a.top - pad, a.screenH - a.bottom - params.height + pad)
                    update()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging) {
                    var vx = 0f
                    val t = tracker
                    if (t != null && e.actionMasked == MotionEvent.ACTION_UP) {
                        track(t, e)
                        t.computeCurrentVelocity(1000)
                        vx = t.xVelocity
                    }
                    settle(vx)
                }
                if (onBall) {
                    if (e.actionMasked == MotionEvent.ACTION_UP) {
                        val release = if (state?.stopped == true) HoldToStop.Release.TAP else hold.up(SystemClock.uptimeMillis())
                        endHold()
                        when (release) {
                            HoldToStop.Release.TAP -> if (!dragging) mini.performClick()
                            // Let go just as the second closed, before the ring's last frame.
                            HoldToStop.Release.STOP -> {
                                mini.hold = 1f
                                mini.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                                actions.stop()
                            }
                            else -> Unit
                        }
                    } else {
                        hold.cancel()
                        endHold()
                    }
                    onBall = false
                }
                dragging = false
                dragFrom = false
                tracker?.recycle()
                tracker = null
            }
        }
        return dragging
    }

    /** Let go: to the nearer side (or the flung one), at the height it was dropped, both kept. */
    private fun settle(velocityX: Float) {
        val a = area()
        side = ScreenWindow.sideFor(params.x, params.width, a.screenW, velocityX)
        fraction = ScreenWindow.fractionFor(params.y + pad, a, params.height - 2 * pad)
        prefs.edit().putString(K_SIDE, if (side == Side.LEFT) "left" else "right").putFloat(K_Y, fraction).apply()
        val fromX = params.x
        val fromY = params.y
        fit()
        val toX = params.x
        val toY = params.y
        if (!OverlayMotion.on()) { update(); return }
        params.x = fromX
        params.y = fromY
        glide = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 260
            interpolator = OverlayMotion.glide
            addUpdateListener {
                val f = it.animatedValue as Float
                params.x = (fromX + (toX - fromX) * f).roundToInt()
                params.y = (fromY + (toY - fromY) * f).roundToInt()
                update()
            }
            start()
        }
    }

    private fun on(v: View, e: MotionEvent): Boolean {
        if (!v.isShown) return false
        val at = IntArray(2)
        v.getLocationOnScreen(at)
        return e.rawX >= at[0] && e.rawX < at[0] + v.width && e.rawY >= at[1] && e.rawY < at[1] + v.height
    }

    private fun track(t: VelocityTracker, e: MotionEvent) {
        val copy = MotionEvent.obtain(e)
        copy.setLocation(e.rawX, e.rawY)
        t.addMovement(copy)
        copy.recycle()
    }

    companion object {
        private const val TAG = "DshA11y"
        private const val K_SIDE = "screenSide"
        private const val K_Y = "screenY"
        private const val K_LARGE = "screenLarge"

        /** Room round the island for its shadow, inside the window. */
        const val PAD_DP = 12

        /** 暂停 and 回到 DSH Go under the picture: 40 dp to touch, a 30 dp disc. */
        const val KEY_DP = 40
        const val KEY_DISC_DP = 30

        /** 最小化 on the picture: 32 dp to touch, a 24 dp disc dark enough to read over any picture. */
        const val MIN_KEY_DP = 32
        const val MIN_DISC_DP = 24
        const val MIN_DISC = 0x8C000000.toInt()
    }
}
