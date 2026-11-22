package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.text.InputFilter
import android.text.InputType
import android.text.StaticLayout
import android.text.TextUtils
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.Interpolator
import android.view.animation.LinearInterpolator
import android.view.animation.OvershootInterpolator
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.pet.Side
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin

/** What the capsule and its card show; ControlOverlay builds it from the task and the line. */
internal data class CapsuleState(
    /** The header's line: what DSH does now, or 已暂停 / 等你确认 / 已停止. */
    val line: String,
    val look: MarkLook,
    val paused: Boolean,
    val stopped: Boolean,
    /** The line opens the card (not while a confirm waits, nor once stopped): it shows its chevron. */
    val expandable: Boolean,
    /** Any limit lifted: a lock before the line, a row in the card. */
    val unlocked: Boolean,
    /** The card's 已解除限制 row (which limits). */
    val unlockedLine: CharSequence?,
    /** The card's first line under the header: 「免确认」 while approvals are off; null: none. */
    val meta: String?,
    /** The steps before this one, newest first. */
    val steps: List<String>,
    /** The second line under it: 「微信 · 第 6 步」 (the time is added and kept ticking here). Null: one line. */
    val sub: String? = null,
    /** When the task started (uptime ms), for the time on the second line; null: no time. */
    val startedAt: Long? = null,
    /** The app DSH works in, in the mark's place; null: the mark. */
    val icon: android.graphics.drawable.Drawable? = null,
    /** What DSH thinks now: its latest words in the chat (the card shows the tail); null: nothing yet. */
    val thought: String? = null,
)

/**
 * The control's open window (TYPE_ACCESSIBILITY_OVERLAY): one dark island surface that is a capsule
 * — the default: the app DSH works in, what it does now over 「微信 · 第 6 步 · 0:42」, 暂停 (held a
 * second: 停止) and 回到 DSH Go — or the card that grows out of it, and shrinks to a circle when it
 * folds into the ball. While DSH works a beam runs round its edge. The card is for watching DSH
 * work: what it thinks (its own words from the chat) and the steps it took, on a timeline that
 * runs out from the app's icon, each new step sliding in with its node popping; then 插话 and
 * 收成小球 / 停止. The surface is one view drawing one rounded rect that the morphs animate
 * ([OverlaySurface]); the rows inside never re-flow during a fold, they are cut by the outline and
 * fade. The header row is the same in both forms, so its keys never move. The card opens away from
 * the nearer end of the screen ([down]: under an island at the top, it hangs down). The capsule
 * sits on its [anchor]'s side of the card and grows from it. The header can be dragged (anywhere
 * but 暂停 / 回到 DSH Go, which stay taps and holds); the owner moves the window.
 *
 * Main thread only. The owner ([ControlOverlay]) adds and removes the window, decides the form and
 * runs the ball; this class draws, lays out and morphs.
 */
internal class OverlayCapsule(
    private val ctx: Context,
    private val c: OverlayPalette,
    private val strings: Strings,
    private val actions: Actions,
    /** Applies [params] to the window (after the surface changed size). */
    private val relayout: () -> Unit,
) {
    class Strings(
        val fold: String, val expand: String, val collapse: String,
        val pause: String, val resume: String, val stop: String, val back: String, val stopRow: String,
        val steerHint: String, val send: String,
        val unlocksDescription: String, val review: String,
        val foldRow: String, val holdHint: String, val separator: String,
        val moveLeft: String, val moveCentre: String, val moveRight: String,
        /** The screen reader's name for the thought row: 「DSH 的想法」. */
        val thought: String,
    )

    interface Actions {
        /** Any finger came down on the window. */
        fun touched()

        /** The header is being dragged (past the touch slop, not from 暂停 / 停止): it follows the finger by ([dx], [dy]) px. */
        fun dragStart()
        fun dragMove(dx: Float, dy: Float)

        /** Let go, at [velocityX] px/s across (0 when the gesture was taken away). */
        fun dragEnd(velocityX: Float)

        /** The screen reader's 移到左侧 / 居中 / 右侧. */
        fun place(anchor: CapsuleAnchor)
        fun mark()
        fun line()
        fun pause()

        /** 暂停 held a second, the card's 停止, or the screen reader's stop. */
        fun stop()

        /** 回到 DSH Go. */
        fun back()
        fun unlocks()
        fun steer()
        fun send()
        fun inputDone()
    }

    enum class Shape { CAPSULE, CARD }

    private val headerH = ctx.dp(CapsuleMetrics.HEIGHT_DP)
    private val ball = headerH

    /** Room round the surface for its shadow (transparent, inside the window). */
    val padX = ctx.dp(PAD_X_DP)
    val padTop = ctx.dp(PAD_TOP_DP)
    val padBottom = ctx.dp(PAD_BOTTOM_DP)

    // ---- header -----------------------------------------------------------------------------------

    val mark = MarkView(ctx, c).apply {
        contentDescription = strings.fold
        foreground = RippleDrawable(ColorStateList.valueOf(c.ripple), null,
            InsetDrawable(GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }, ctx.dp(4)))
        setOnClickListener { actions.mark() }
    }

    private val lock = GlyphView(ctx, Glyph.LOCK, CapsuleMetrics.LOCK_DP.toFloat()).apply {
        color = c.danger
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        visibility = View.GONE
    }

    val text = TextView(ctx).apply {
        textSize = 14.5f
        setTextColor(c.ink)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** 「微信 · 第 6 步 · 0:42」 under the line; the time ticks every second while it shows. */
    private val sub = TextView(ctx).apply {
        textSize = 11.5f
        setTextColor(c.faint)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        fontFeatureSettings = "tnum"
        visibility = View.GONE
        setPadding(0, ctx.dp(3), 0, 0)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The line over its second line. */
    private val lines = LinearLayout(ctx).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_VERTICAL
        addView(text, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(sub, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    private val chevron = GlyphView(ctx, Glyph.CHEVRON, CapsuleMetrics.CHEVRON_DP.toFloat()).apply {
        color = c.faint
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The line with its lock and chevron: one key that opens and closes the card. */
    private val lineKey = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        isClickable = true
        isFocusable = true
        setPadding(0, 0, ctx.dp(CapsuleMetrics.LINE_END_DP), 0)
        foreground = RippleDrawable(ColorStateList.valueOf(c.ripple), null,
            InsetDrawable(GradientDrawable().apply { cornerRadius = ctx.dpf(18f); setColor(Color.WHITE) }, 0, ctx.dp(6), 0, ctx.dp(6)))
        addView(lock, LinearLayout.LayoutParams(ctx.dp(CapsuleMetrics.LOCK_DP), ctx.dp(CapsuleMetrics.LOCK_DP)).apply { marginEnd = ctx.dp(CapsuleMetrics.LOCK_GAP_DP) })
        addView(lines, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(chevron, LinearLayout.LayoutParams(ctx.dp(CapsuleMetrics.CHEVRON_DP), ctx.dp(CapsuleMetrics.CHEVRON_DP)).apply { marginStart = ctx.dp(CapsuleMetrics.CHEVRON_GAP_DP) })
        setOnClickListener { actions.line() }
        // A screen reader can't drag: the line moves the capsule to an anchor or folds it, as actions.
        accessibilityDelegate = object : View.AccessibilityDelegate() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = android.widget.Button::class.java.name
                info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK,
                    if (shape == Shape.CARD) strings.collapse else strings.expand))
                for ((a, id, label) in placeActions) if (a != anchor) info.addAction(AccessibilityNodeInfo.AccessibilityAction(id, label))
                if (mark.isClickable) info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.overlay_action_fold, strings.fold))
            }

            override fun performAccessibilityAction(host: View, action: Int, args: android.os.Bundle?): Boolean {
                placeActions.firstOrNull { it.second == action }?.let { actions.place(it.first); return true }
                if (action == R.id.overlay_action_fold && mark.isClickable) { actions.mark(); return true }
                return super.performAccessibilityAction(host, action, args)
            }
        }
    }

    private val placeActions = listOf(
        Triple(CapsuleAnchor.LEFT, R.id.overlay_action_left, strings.moveLeft),
        Triple(CapsuleAnchor.CENTRE, R.id.overlay_action_centre, strings.moveCentre),
        Triple(CapsuleAnchor.RIGHT, R.id.overlay_action_right, strings.moveRight),
    )

    /** 暂停 / 继续; held a second it stops the task (a ring fills round it first). */
    val pause = RoundKey(ctx, CapsuleMetrics.DISC_DP, 18).apply {
        disc = c.tonal
        ink = c.ink
        holdColor = c.danger
        setRipple(c.ripple)
        contentDescription = strings.pause
        setOnClickListener { actions.pause() }
        holdToStop({ if (state?.stopped == true) null else strings.stop }) { actions.stop() }
    }

    /** 回到 DSH Go: the chat this task belongs to. */
    val back = RoundKey(ctx, CapsuleMetrics.DISC_DP, 18).apply {
        disc = c.tonal
        ink = c.ink
        setGlyph(Glyph.BACK, animated = false)
        setRipple(c.ripple)
        contentDescription = strings.back
        setOnClickListener { actions.back() }
    }

    private val keyGap = View(ctx)

    private val header = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        val key = ctx.dp(CapsuleMetrics.KEY_DP)
        addView(mark, LinearLayout.LayoutParams(key, key))
        addView(lineKey, LinearLayout.LayoutParams(0, key, 1f))
        addView(pause, LinearLayout.LayoutParams(key, key))
        addView(keyGap, LinearLayout.LayoutParams(ctx.dp(CapsuleMetrics.KEY_GAP_DP), 1))
        addView(back, LinearLayout.LayoutParams(key, key))
    }

    // ---- card body ----------------------------------------------------------------------------------

    /** Where the card's text starts: level with the line, the mark's column as a gutter. */
    private val column = ctx.dp(CapsuleMetrics.KEY_DP + 4)
    private val gutter = ctx.dpf(CapsuleMetrics.KEY_DP / 2f)

    private val meta = TextView(ctx).apply {
        textSize = 12f
        setTextColor(c.faint)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /**
     * What DSH thinks now — its own words in the chat, the tail that fits [THOUGHT_LINES] lines —
     * next to the line, a sparkle for its node on the timeline.
     */
    private val thought = TextView(ctx).apply {
        textSize = 13f
        setTextColor(c.ink)
        maxLines = THOUGHT_LINES
        setLineSpacing(0f, THOUGHT_SPACING)
        includeFontPadding = false
        setPadding(column, ctx.dp(6), ctx.dp(16), ctx.dp(8))
        visibility = View.GONE
    }

    /** The steps before the line's, newest nearest the header. */
    private val stepRows = List(StepHistory.CAPACITY) { StepRow() }

    private val unlockText = TextView(ctx).apply {
        textSize = 13f
        setTextColor(c.onDangerSoft)
        maxLines = 3
        ellipsize = TextUtils.TruncateAt.END
        setLineSpacing(0f, 1.15f)
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private val unlocks = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = ctx.dp(48)
        isClickable = true
        isFocusable = true
        contentDescription = strings.unlocksDescription
        val r = ctx.dpf(INNER_RADIUS_DP)
        background = GradientDrawable().apply { cornerRadius = r; setColor(c.dangerSoft) }
        foreground = RippleDrawable(ColorStateList.valueOf(c.ripple), null, GradientDrawable().apply { cornerRadius = r; setColor(Color.WHITE) })
        setPadding(0, ctx.dp(8), ctx.dp(12), ctx.dp(8))
        // The lock in the mark's column (the row sits 12 dp in, its text level with the card's).
        val inset = ctx.dp(BODY_INSET_DP)
        addView(GlyphView(ctx, Glyph.LOCK, 16f).apply { color = c.danger },
            LinearLayout.LayoutParams(ctx.dp(CapsuleMetrics.KEY_DP) - 2 * inset, ctx.dp(16)).apply { marginEnd = column - (ctx.dp(CapsuleMetrics.KEY_DP) - inset) })
        addView(unlockText, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(TextView(ctx).apply {
            text = strings.review
            textSize = 13f
            setTextColor(c.danger)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setPadding(ctx.dp(12), 0, 0, 0)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        })
        addView(GlyphView(ctx, Glyph.CHEVRON, 12f).apply { color = c.danger; turn = -90f },
            LinearLayout.LayoutParams(ctx.dp(12), ctx.dp(12)).apply { marginStart = ctx.dp(2) })
        setOnClickListener { actions.unlocks() }
    }

    /** 插话: a field that only takes the keyboard once tapped (the window is not focusable till then). */
    val input: EditText = object : EditText(ctx) {
        override fun onKeyPreIme(keyCode: Int, event: KeyEvent?): Boolean {
            if (keyCode == KeyEvent.KEYCODE_BACK && event?.action == KeyEvent.ACTION_UP) { actions.inputDone(); return true }
            return super.onKeyPreIme(keyCode, event)
        }
    }.apply {
        textSize = 14f
        setTextColor(c.ink)
        setHintTextColor(c.faint)
        hint = strings.steerHint
        background = null
        setPadding(ctx.dp(16), ctx.dp(11), ctx.dp(8), ctx.dp(11))
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = 3
        filters = arrayOf(InputFilter.LengthFilter(2000))
        setOnEditorActionListener { _, action, _ -> if (action == EditorInfo.IME_ACTION_SEND) { actions.send(); true } else false }
        addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) { syncSend() }
        })
    }

    private val send = RoundKey(ctx, 32, 16).apply {
        setGlyph(Glyph.SEND, animated = false)
        setRipple(c.ripple)
        contentDescription = strings.send
        setOnClickListener { actions.send() }
    }

    /** Taps on the field before typing starts go to [Actions.steer], not the text. */
    var editing = false
        private set

    private val steer = object : LinearLayout(ctx) {
        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = !editing
        override fun onTouchEvent(ev: MotionEvent): Boolean {
            if (!editing && ev.actionMasked == MotionEvent.ACTION_UP) actions.steer()
            return !editing || super.onTouchEvent(ev)
        }
    }.apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = ctx.dp(44)
        background = GradientDrawable().apply { cornerRadius = ctx.dpf(22f); setColor(c.field) }
        setPadding(0, 0, ctx.dp(6), 0)
        addView(input, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(send, LinearLayout.LayoutParams(ctx.dp(40), ctx.dp(40)))
    }

    /** The card's 停止: a plain tap here (the card is a deliberate place), a hold on 暂停 elsewhere. */
    private val stopRow = TextView(ctx).apply {
        text = strings.stopRow
        textSize = 13f
        setTextColor(c.danger)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        setPadding(ctx.dp(14), 0, ctx.dp(14), 0)
        isClickable = true
        isFocusable = true
        background = GradientDrawable().apply { cornerRadius = ctx.dpf(18f); setColor(c.dangerSoft) }
        foreground = RippleDrawable(ColorStateList.valueOf(c.ripple), null, GradientDrawable().apply { cornerRadius = ctx.dpf(18f); setColor(Color.WHITE) })
        contentDescription = strings.stop
        setOnClickListener { actions.stop() }
    }

    private val footer = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = ctx.dp(48)
        isClickable = true
        isFocusable = true
        foreground = RippleDrawable(ColorStateList.valueOf(c.ripple), null,
            InsetDrawable(GradientDrawable().apply { cornerRadius = ctx.dpf(INNER_RADIUS_DP); setColor(Color.WHITE) }, ctx.dp(BODY_INSET_DP), 0, ctx.dp(BODY_INSET_DP), 0))
        contentDescription = "${strings.foldRow}. ${strings.holdHint}"
        addView(GlyphView(ctx, Glyph.BALL, 14f).apply { color = c.faint },
            LinearLayout.LayoutParams(ctx.dp(CapsuleMetrics.KEY_DP), ctx.dp(14)).apply { marginEnd = column - ctx.dp(CapsuleMetrics.KEY_DP) })
        addView(LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(ctx).apply { text = strings.foldRow; textSize = 13f; setTextColor(c.muted) })
            addView(TextView(ctx).apply { text = strings.holdHint; textSize = 11f; setTextColor(c.faint); setPadding(0, ctx.dp(1), 0, 0) })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = ctx.dp(8) })
        addView(stopRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, ctx.dp(36)).apply { marginEnd = ctx.dp(BODY_INSET_DP) })
        setOnClickListener { actions.mark() }
    }

    /**
     * The card's second layer, on the header's far side ([arrange]): out from the line, 免确认,
     * what DSH thinks, its steps (newest first), the lifted limits, 插话 and 收成小球 / 停止 — in
     * that order down from an island at the top, mirrored up from a capsule lower down, so what
     * belongs to the line stays next to it. Under the rows, the timeline ([drawTimeline]).
     */
    private val body = object : LinearLayout(ctx) {
        override fun dispatchDraw(canvas: Canvas) {
            drawTimeline(canvas, this)
            super.dispatchDraw(canvas)
        }

        override fun onVisibilityAggregated(isVisible: Boolean) {
            super.onVisibilityAggregated(isVisible)
            post { syncFlow() }
        }
    }.apply {
        orientation = LinearLayout.VERTICAL
        setWillNotDraw(false)
    }

    /** One past step, level with the line; its node on the timeline is the body's to draw. */
    private inner class StepRow : TextView(ctx) {
        init {
            textSize = 13f
            setTextColor(c.muted)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_VERTICAL
            minHeight = ctx.dp(STEP_ROW_DP)
            setPadding(column, 0, ctx.dp(16), 0)
            visibility = View.GONE
        }
    }

    /** The body's rows in order for the way the card opens ([down]): from the header outward, or mirrored. */
    private fun arrange() {
        body.removeAllViews()
        val m = ctx.dp(BODY_INSET_DP)
        fun row() = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        // [near]: the margin on the header's side, [far]: on the other.
        fun spaced(near: Int, far: Int, inset: Int = 0) = row().apply {
            if (down) { topMargin = near; bottomMargin = far } else { bottomMargin = near; topMargin = far }
            leftMargin = inset
            rightMargin = inset
        }
        meta.setPadding(column, if (down) ctx.dp(2) else ctx.dp(4), ctx.dp(16), if (down) ctx.dp(4) else 0)
        val outward = listOf<Pair<View, LinearLayout.LayoutParams>>(meta to row(), thought to row()) +
            stepRows.map { it to row() } +
            listOf(
                unlocks to spaced(ctx.dp(8), 0, m),
                steer to spaced(ctx.dp(10), 0, m),
                footer to spaced(ctx.dp(4), 0),
            )
        for ((v, lp) in if (down) outward else outward.asReversed()) body.addView(v, lp)
        body.setPadding(0, if (down) ctx.dp(4) else ctx.dp(8), 0, if (down) ctx.dp(8) else 0)
    }

    // ---- the timeline ---------------------------------------------------------------------------------

    private val rule = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeWidth = ctx.dpf(1f) }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = ctx.dpf(1.25f) }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    private val spark = Paint(Paint.ANTI_ALIAS_FLAG)
    private val overshoot = OvershootInterpolator(2.2f)

    /** 0–1 while the newest step's node pops in; 1 at rest. */
    private var pop = 1f
    private var popAnim: ValueAnimator? = null

    /** 0–1 along [FLOW_MS]: the light running back along the timeline to the line; NaN when it doesn't run. */
    private var flow = Float.NaN
    private var flowAnim: ValueAnimator? = null

    // The nodes this frame, out from the header: y, kind, opacity.
    private val nodeY = FloatArray(StepHistory.CAPACITY + 1)
    private val nodeKind = IntArray(StepHistory.CAPACITY + 1)
    private val nodeAlpha = FloatArray(StepHistory.CAPACITY + 1)

    /**
     * The timeline in the mark's column, out from under the app's icon: the thought's sparkle, then
     * a dot per step — the newest in the accent, popping in when it arrives, the rest faint — joined
     * by a hairline broken round each node. While DSH works, a small light runs now and then from
     * the oldest step back to the line: the work flows toward now.
     */
    private fun drawTimeline(canvas: Canvas, v: View) {
        val out = if (down) 1f else -1f
        val start = if (down) ctx.dpf(1f) else v.height - ctx.dpf(1f)
        var n = 0
        if (thought.visibility == View.VISIBLE && thought.parent === v) {
            nodeY[n] = thought.top + thought.translationY + thought.paddingTop + thought.lineHeight / 2f
            nodeKind[n] = NODE_THOUGHT
            nodeAlpha[n] = thought.alpha
            n++
        }
        stepRows.forEachIndexed { i, row ->
            if (row.visibility != View.VISIBLE || row.parent !== v) return@forEachIndexed
            nodeY[n] = row.top + row.translationY + row.height / 2f
            nodeKind[n] = if (i == 0) NODE_NEWEST else NODE_STEP
            nodeAlpha[n] = row.alpha
            n++
        }
        if (n == 0) return
        rule.color = c.faint
        rule.alpha = 0x40
        // The hairline, in pieces between the nodes (they come in order out from the header).
        var from = start
        var far = start
        for (i in 0 until n) {
            val gap = nodeRadius(nodeKind[i]) + ctx.dpf(3f)
            val to = nodeY[i] - out * gap
            if ((to - from) * out > 0f) canvas.drawLine(gutter, from, gutter, to, rule)
            from = nodeY[i] + out * gap
            if ((nodeY[i] - far) * out > 0f) far = nodeY[i]
        }
        // The light, under the nodes: from the far end back to the line, a short trail behind it.
        val f = flow
        if (!f.isNaN() && f < FLOW_RUN && (far - start) * out > ctx.dpf(24f)) {
            val t = f / FLOW_RUN
            val y = far + (start - far) * OverlayMotion.glide.getInterpolation(t)
            val fade = sin(PI * t).toFloat()
            dot.color = c.accent
            for (k in 0 until FLOW_TRAIL) {
                dot.alpha = (255 * 0.75f * fade * (1f - k.toFloat() / FLOW_TRAIL)).roundToInt()
                canvas.drawCircle(gutter, y + out * k * ctx.dpf(2.5f), ctx.dpf(1.4f), dot)
            }
        }
        for (i in 0 until n) {
            val y = nodeY[i]
            val a = nodeAlpha[i].coerceIn(0f, 1f)
            when (nodeKind[i]) {
                NODE_THOUGHT -> {
                    spark.color = c.accent
                    spark.alpha = (255 * a).roundToInt()
                    Glyph.draw(canvas, Glyph.SPARK, gutter, y, ctx.dpf(SPARK_DP), spark)
                }
                NODE_NEWEST -> {
                    val r = ctx.dpf(NEWEST_DOT_DP)
                    val p = pop
                    if (p < 1f) {
                        // A ring going out once as the node lands.
                        ring.color = c.accent
                        ring.alpha = (255 * 0.5f * (1f - p) * a).roundToInt()
                        canvas.drawCircle(gutter, y, r * (1f + 1.8f * p), ring)
                    }
                    dot.color = c.accent
                    dot.alpha = (255 * a).roundToInt()
                    canvas.drawCircle(gutter, y, r * (0.35f + 0.65f * overshoot.getInterpolation(p)), dot)
                }
                else -> {
                    dot.color = c.faint
                    dot.alpha = (255 * 0.85f * a).roundToInt()
                    canvas.drawCircle(gutter, y, ctx.dpf(DOT_DP), dot)
                }
            }
        }
    }

    private fun nodeRadius(kind: Int): Float = ctx.dpf(
        when (kind) {
            NODE_THOUGHT -> SPARK_DP / 2f
            NODE_NEWEST -> NEWEST_DOT_DP
            else -> DOT_DP
        },
    )

    /** The light runs while DSH works and the card shows (never with 移除动画). */
    private fun syncFlow() {
        val want = state?.look == MarkLook.RUNNING && layer.visibility == View.VISIBLE && body.isShown &&
            body.isAttachedToWindow && OverlayMotion.on()
        if (want && flowAnim == null) {
            flowAnim = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = FLOW_MS
                repeatCount = ValueAnimator.INFINITE
                interpolator = LinearInterpolator()
                addUpdateListener { flow = it.animatedValue as Float; body.invalidate() }
                start()
            }
        } else if (!want && flowAnim != null) {
            flowAnim?.cancel()
            flowAnim = null
            flow = Float.NaN
            body.invalidate()
        }
    }

    /**
     * A step arrived on an open card: the steps already there move one place out from the header
     * (each row takes over the text of the one nearer the header, and starts where that one was),
     * the new one fades in at the head and its node pops.
     */
    private fun slideSteps() {
        val toward = if (down) -1f else 1f
        val fallback = ctx.dp(STEP_ROW_DP).toFloat()
        stepRows.forEachIndexed { i, row ->
            if (row.visibility != View.VISIBLE) return@forEachIndexed
            row.animate().cancel()
            val h = row.height.takeIf { it > 0 }?.toFloat() ?: fallback
            if (i == 0) {
                row.alpha = 0f
                row.translationY = toward * h * 0.6f
            } else {
                row.alpha = 1f
                row.translationY = toward * h
            }
            row.animate().alpha(1f).translationY(0f).setDuration(STEP_SLIDE_MS).setInterpolator(OverlayMotion.glide)
                .setUpdateListener { body.invalidate() }.start()
        }
        popAnim?.cancel()
        pop = 0f
        popAnim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = POP_MS
            startDelay = STEP_SLIDE_MS / 3
            interpolator = LinearInterpolator()
            addUpdateListener { pop = it.animatedValue as Float; body.invalidate() }
            start()
        }
    }

    /** Every step row where it belongs, the newest node at rest (no slide under way). */
    private fun settleSteps() {
        popAnim?.cancel()
        popAnim = null
        pop = 1f
        for (row in stepRows) {
            row.animate().cancel()
            row.alpha = 1f
            row.translationY = 0f
        }
    }

    /** The steps on show now (what the next ones are compared with, for [slideSteps]). */
    private var shownSteps: List<String> = emptyList()

    /**
     * What DSH thinks: a longer version of the same words (they stream in) changes in place; other
     * words cross-fade. Only the tail that fits shows, after an ellipsis: the newest words matter.
     */
    private fun setThought(raw: String?, animated: Boolean) {
        val words = raw?.trim()?.takeIf { it.isNotEmpty() }
        thought.animate().cancel()
        if (words == null) {
            thought.alpha = 1f
            thought.text = ""
            thought.visibility = View.GONE
            return
        }
        val fitted = fitTail(words, cardW - column - ctx.dp(16))
        thought.contentDescription = strings.thought + strings.separator + words
        val old = thought.text?.toString().orEmpty()
        if (fitted == old && thought.visibility == View.VISIBLE) {
            thought.alpha = 1f
            return
        }
        if (!animated || thought.visibility != View.VISIBLE || old.isEmpty() || sameWords(old, fitted)) {
            thought.alpha = 1f
            thought.text = fitted
            thought.visibility = View.VISIBLE
            return
        }
        thought.animate().alpha(0f).setDuration(90).setInterpolator(OverlayMotion.emphasized).setUpdateListener { body.invalidate() }.withEndAction {
            thought.text = fitted
            thought.animate().alpha(1f).setDuration(200).setInterpolator(OverlayMotion.glide).setUpdateListener { body.invalidate() }.start()
        }.start()
    }

    /** Two cuts of the same streaming words: one begins as the other does, or both are tails of something long. */
    private fun sameWords(a: String, b: String): Boolean {
        if (a.startsWith(ELLIPSIS) && b.startsWith(ELLIPSIS)) return true
        val k = minOf(a.length, b.length, 12)
        return k > 0 && a.take(k) == b.take(k)
    }

    /** [text] if it fits [THOUGHT_LINES] lines [width] px wide, else 「…」 and as much of its end as fits. */
    private fun fitTail(text: String, width: Int): String {
        if (width <= 0) return text
        fun lines(t: CharSequence) = StaticLayout.Builder.obtain(t, 0, t.length, thought.paint, width)
            .setLineSpacing(0f, THOUGHT_SPACING).setIncludePad(false).build().lineCount
        if (lines(text) <= THOUGHT_LINES) return text
        var lo = 0
        var hi = text.length
        while (lo < hi) {
            val mid = (lo + hi) / 2
            if (lines(ELLIPSIS + text.substring(mid)) <= THOUGHT_LINES) hi = mid else lo = mid + 1
        }
        if (lo < text.length && Character.isLowSurrogate(text[lo])) lo++
        return ELLIPSIS + text.substring(lo).trimStart()
    }

    /**
     * The second layer as the surface holds it: the body, scrolling when the room above the header
     * ([maxCardHeight]) is less than it needs — a short screen with the keyboard up — so 插话 stays
     * reachable and the header stays put. A focused field scrolls itself into view.
     */
    private val layer = ScrollView(ctx).apply {
        isVerticalScrollBarEnabled = false
        overScrollMode = View.OVER_SCROLL_NEVER
        visibility = View.GONE
        addView(body)
    }

    init {
        arrange()
    }

    // ---- window ---------------------------------------------------------------------------------------

    val surface = OverlaySurface(ctx, c, header, layer)

    /** The tallest the card may be (header included): from the header's far edge to under the status bar, or (down) to over the keyboard or the navigation bar. */
    var maxCardHeight: Int = Int.MAX_VALUE
        set(value) {
            if (field == value) return
            field = value
            surface.maxCardH = value
            if (shape == Shape.CARD && morph == null) refitCard(OverlayMotion.on())
        }

    /**
     * The whole capsule's opacity: the 闲置时不透明度 when idle, full otherwise. On [surface], so the
     * window's own alpha stays free for the unfold's swap.
     */
    fun setIdle(alpha: Float, animated: Boolean, durationMs: Long) = OverlayMotion.fadeIdle(surface, alpha, animated, durationMs)

    val root: FrameLayout = object : FrameLayout(ctx) {
        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) actions.touched()
            return super.dispatchTouchEvent(ev)
        }

        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean = watchDrag(ev)

        override fun onTouchEvent(ev: MotionEvent): Boolean {
            if (ev.actionMasked == MotionEvent.ACTION_OUTSIDE) {
                if (editing) actions.inputDone()
                return false
            }
            watchDrag(ev)
            return dragging || (ev.actionMasked == MotionEvent.ACTION_DOWN && dragFrom)
        }
    }.apply {
        setPadding(padX, padTop, padX, padBottom)
        clipToPadding = false
        clipChildren = false
        addView(surface, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
    }

    // ---- dragging ---------------------------------------------------------------------------------

    private val slop = ViewConfiguration.get(ctx).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f

    /** The finger came down on the header, not on 暂停 / 回到 DSH Go (always taps or holds), and nobody is typing. */
    private var dragFrom = false
    private var tracker: VelocityTracker? = null

    /** Past the touch slop: the header follows the finger, and the keys under it got a cancel, never a click. */
    var dragging = false
        private set

    /** Watches every event on the window; true once it is a drag (the root takes the gesture over). */
    private fun watchDrag(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                dragging = false
                dragFrom = !editing && on(header, e) && !on(pause, e) && !on(back, e)
                tracker?.recycle()
                tracker = if (dragFrom) VelocityTracker.obtain().also { track(it, e) } else null
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragFrom) return false
                tracker?.let { track(it, e) }
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!dragging && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    actions.dragStart()
                }
                if (dragging) actions.dragMove(dx, dy)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging) {
                    val t = tracker
                    var vx = 0f
                    if (t != null && e.actionMasked == MotionEvent.ACTION_UP) {
                        track(t, e)
                        t.computeCurrentVelocity(1000)
                        vx = t.xVelocity
                    }
                    dragging = false
                    actions.dragEnd(vx)
                }
                dragFrom = false
                tracker?.recycle()
                tracker = null
            }
        }
        return dragging
    }

    private fun on(v: View, e: MotionEvent): Boolean {
        if (!v.isShown) return false
        val at = IntArray(2)
        v.getLocationOnScreen(at)
        return e.rawX >= at[0] && e.rawX < at[0] + v.width && e.rawY >= at[1] && e.rawY < at[1] + v.height
    }

    /** Raw coordinates: the window moves under the finger, so view coordinates stand still. */
    private fun track(t: VelocityTracker, e: MotionEvent) {
        val copy = MotionEvent.obtain(e)
        copy.setLocation(e.rawX, e.rawY)
        t.addMovement(copy)
        copy.recycle()
    }

    lateinit var params: android.view.WindowManager.LayoutParams

    // ---- state ------------------------------------------------------------------------------------------

    var shape = Shape.CAPSULE
        private set

    private var morph: ValueAnimator? = null
    private var state: CapsuleState? = null
    private var screenW = 0
    private var screenHdp = 800f
    private val width = CapsuleWidth(slack = ctx.dp(24))

    /** The card's width (and the capsule's widest). */
    private var cardW = 0

    val morphing: Boolean get() = morph != null

    /** The side the capsule rests against: it sits on that side of the card and grows from it. */
    var anchor = CapsuleAnchor.CENTRE
        set(value) {
            if (field == value) return
            field = value
            if (morph == null && extentSet) settle(shape)
        }

    private val extentSet: Boolean get() = surface.extentW > 0

    /** The steady capsule's width now (the card's until a line has been measured). */
    val capsuleWidth: Int get() = width.width.takeIf { it > 0 } ?: cardW

    /** The steady capsule's left in the surface as it is now (the card's, or a resize's room): where the owner lines the window up. */
    fun steadyLeft(): Int = CapsulePlacement.leftIn(anchor, surface.extentW, capsuleWidth)

    /** The open card's height with nothing capping it, header included: what it needs above the header's bottom. */
    fun naturalCardHeight(): Int = surface.naturalCardHeight()

    /** A new screen size (first placement, rotation): widths again, at once. */
    /** [screenW] is the width there is room for ([CapsulePlacement.roomW]), not the whole display's. */
    fun place(screenW: Int, screenH: Int) {
        this.screenW = screenW
        screenHdp = screenH / ctx.resources.displayMetrics.density
        cardW = CapsuleMetrics.maxPx(screenW, ctx.resources.displayMetrics.density)
        surface.cardW = cardW
        cancelMorph()
        width.reset()
        state?.let { width.force(wantedWidth(it)) }
        settle(shape)
    }

    /** Shows [s]; [animated] cross-fades the line and lets the capsule follow its width. */
    fun render(s: CapsuleState, animated: Boolean, now: Long) {
        val old = state
        state = s
        val anim = animated && OverlayMotion.on()
        setLine(s.line, anim && old != null)
        subBase = s.sub
        startedAt = s.startedAt
        sub.visibility = if (s.sub == null) View.GONE else View.VISIBLE
        tickSub()
        lineKey.contentDescription = listOfNotNull(s.line, s.sub).joinToString(". ")
        mark.icon = s.icon
        mark.setLook(s.look, anim)
        surface.beam.running = s.look == MarkLook.RUNNING
        lock.visibility = if (s.unlocked && !s.stopped) View.VISIBLE else View.GONE
        // The open card keeps its chevron (it closes it); a capsule that can't open hides it.
        chevron.visibility = if (s.expandable || shape == Shape.CARD) View.VISIBLE else View.GONE
        lineKey.isClickable = s.expandable || shape == Shape.CARD
        val keys = if (s.stopped) View.GONE else View.VISIBLE
        pause.visibility = keys
        keyGap.visibility = keys
        back.visibility = keys
        pause.setGlyph(if (s.paused) Glyph.PLAY else Glyph.PAUSE, anim)
        pause.disc = if (s.paused) c.accentSoft else c.tonal
        pause.ink = if (s.paused) c.accent else c.ink
        pause.contentDescription = if (s.paused) strings.resume else strings.pause
        mark.contentDescription = strings.fold
        mark.isClickable = !s.stopped
        bindBody(s, anim)
        syncFlow()
        // The width: a state change (stopped) at once; a new line grows now, shrinks later.
        val wanted = wantedWidth(s)
        val changed = if (old == null || old.stopped != s.stopped || old.unlocked != s.unlocked || old.expandable != s.expandable ||
            (old.sub == null) != (s.sub == null)) width.force(wanted)
        else width.offer(wanted, now)
        if (shape == Shape.CAPSULE && changed && morph == null) resize(anim)
        if (shape == Shape.CARD && morph == null) refitCard(anim)
    }

    /** When a narrower line may shrink the capsule (the owner re-renders then); null if nothing waits. */
    val shrinkAt: Long? get() = width.shrinkAt

    private fun wantedWidth(s: CapsuleState): Int {
        val density = ctx.resources.displayMetrics.density
        // The wider of the line and its second line, measured with the widest time it will show for a while.
        val subPx = s.sub?.let { sub.paint.measureText(subText(it, Elapsed.WIDEST)) } ?: 0f
        val textPx = maxOf(text.paint.measureText(s.line), subPx)
        val content = CapsuleMetrics.contentDp(textPx / density, s.unlocked && !s.stopped, s.stopped, s.expandable || shape == Shape.CARD) * density
        return CapsuleMetrics.widthPx(content, screenW, density)
    }

    /**
     * A new line rolls in: the old one slides up and fades (70 ms), the new one comes up from below
     * into its place (220 ms, glide) — the island's text change.
     */
    private fun setLine(line: String, animated: Boolean) {
        if (text.text?.toString() == line) return
        text.animate().cancel()
        if (!animated) {
            text.text = line
            text.alpha = 1f
            text.translationY = 0f
            return
        }
        val rise = ctx.dpf(6f)
        text.animate().alpha(0f).translationY(-rise).setDuration(70).setInterpolator(OverlayMotion.emphasized).withEndAction {
            text.text = line
            text.translationY = rise
            text.animate().alpha(1f).translationY(0f).setDuration(220).setInterpolator(OverlayMotion.glide).start()
        }.start()
    }

    private var subBase: String? = null
    private var startedAt: Long? = null

    private fun subText(base: String, time: String?): String =
        if (time == null) base else base + strings.separator + time

    /** The second line now; while it shows with a time, again in a second. */
    private val subTick = Runnable { tickSub() }

    private fun tickSub() {
        sub.removeCallbacks(subTick)
        val base = subBase ?: return
        val from = startedAt
        val now = android.os.SystemClock.uptimeMillis()
        sub.text = subText(base, from?.let { Elapsed.format(now - it) })
        if (from != null && sub.isAttachedToWindow) sub.postDelayed(subTick, 1_000 - (now - from) % 1_000)
    }

    init {
        sub.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = tickSub()
            override fun onViewDetachedFromWindow(v: View) { sub.removeCallbacks(subTick) }
        })
    }

    private fun bindBody(s: CapsuleState, animated: Boolean) {
        meta.text = s.meta.orEmpty()
        meta.visibility = if (s.meta.isNullOrBlank()) View.GONE else View.VISIBLE
        val next = s.steps.take(CapsuleMetrics.steps(screenHdp))
        // One new step at the head of the ones on show: it slides in, on a card that is open.
        val arrived = animated && shape == Shape.CARD && morph == null && body.isShown && next.isNotEmpty() &&
            next != shownSteps && next.drop(1) == shownSteps.take(next.size - 1)
        stepRows.forEachIndexed { i, row ->
            val step = next.getOrNull(i)
            row.visibility = if (step == null) View.GONE else View.VISIBLE
            row.text = step.orEmpty()
        }
        shownSteps = next
        if (arrived) slideSteps() else if (next.isEmpty() || !animated) settleSteps()
        setThought(s.thought, animated && shape == Shape.CARD && body.isShown)
        unlocks.visibility = if (s.unlocked && s.unlockedLine != null) View.VISIBLE else View.GONE
        unlockText.text = s.unlockedLine
        body.invalidate()
    }

    private fun syncSend() {
        val has = !input.text.isNullOrBlank()
        send.disc = if (has) c.accent else Color.TRANSPARENT
        send.ink = if (has) c.onAccent else c.faint
        send.isEnabled = has
    }

    init {
        syncSend()
        // The field grows a line while typing, the thought a line as it streams: the card follows.
        body.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (shape == Shape.CARD && morph == null && bottom - top != oldBottom - oldTop) {
                root.post { if (shape == Shape.CARD && morph == null) refitCard(OverlayMotion.on() && root.isShown) }
            }
        }
        root.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = syncFlow()
            override fun onViewDetachedFromWindow(v: View) {
                flowAnim?.cancel()
                flowAnim = null
                flow = Float.NaN
                settleSteps()
            }
        })
    }

    // ---- typing ---------------------------------------------------------------------------------------

    fun startEditing() {
        editing = true
        input.isFocusableInTouchMode = true
        input.requestFocus()
    }

    fun stopEditing() {
        editing = false
        input.clearFocus()
    }

    // ---- which way the card opens -----------------------------------------------------------------------

    /**
     * The card opens downward: the capsule is an island in the upper half of the screen. The owner
     * hangs the window from the top then (from the bottom otherwise), so the header stays put.
     */
    var down = false
        private set

    /** Which way the card opens; the owner changes it only on a capsule at rest (no card, no morph). */
    fun setDown(value: Boolean) {
        if (down == value) return
        down = value
        surface.down = value
        arrange()
        if (extentSet) settle(shape)
    }

    /** The chevron's turn on the capsule and on the card: it points the way the card opens, then back. */
    private val capsuleTurn: Float get() = if (down) CAPSULE_TURN_DOWN else CAPSULE_TURN
    private val cardTurn: Float get() = if (down) CARD_TURN_DOWN else CARD_TURN

    // ---- morphs ---------------------------------------------------------------------------------------

    /** The steady layout of [to]: extent, rect, what shows, the window's size. */
    fun settle(to: Shape) {
        morph = null
        surface.pin(null)
        header.alpha = 1f
        shape = to
        val capW = width.width.takeIf { it > 0 } ?: cardW
        when (to) {
            Shape.CAPSULE -> {
                layer.visibility = View.GONE
                layer.alpha = 0f
                layer.translationY = 0f
                chevron.turn = capsuleTurn
                surface.setExtent(capW, headerH)
                surface.setRect(0f, 0f, capW.toFloat(), headerH.toFloat())
            }
            Shape.CARD -> {
                layer.visibility = View.VISIBLE
                layer.alpha = 1f
                layer.translationY = 0f
                chevron.turn = cardTurn
                val h = surface.cardHeight()
                surface.setExtent(cardW, h)
                surface.setRect(0f, 0f, cardW.toFloat(), h.toFloat())
            }
        }
        fitWindow()
        syncFlow()
    }

    /** Ends a morph where it stands and lays out the form it was in. */
    fun cancelMorph() {
        val m = morph
        morph = null
        m?.cancel()
        settle(shape)
    }

    /**
     * The capsule grows into the card: out away from the header — down from an island at the top,
     * up from a capsule lower down — the header's edge staying put, the body fading in behind and
     * coming 6 dp out from the header.
     */
    fun expand(animated: Boolean, then: () -> Unit = {}) {
        morph?.let { it.cancel(); morph = null }
        // From a collapse cut short, carry on from where the body and the chevron are.
        val wasOpen = layer.visibility == View.VISIBLE
        val startAlpha = if (wasOpen) layer.alpha else 0f
        val startTurn = if (wasOpen) chevron.turn else capsuleTurn
        val carryOn = wasOpen && surface.extentW == cardW
        shape = Shape.CARD
        layer.alpha = startAlpha
        layer.visibility = View.VISIBLE
        val h = surface.cardHeight()
        // The extent keeps the rect's bottom where it is when it grows (OverlaySurface.setExtent).
        surface.setExtent(cardW, h)
        surface.setRect(if (carryOn) RectF(surface.rect) else steadyRectInCard())
        fitWindow()
        val shift = ctx.dpf(6f) * if (down) -1f else 1f
        animate(RectF(0f, 0f, cardW.toFloat(), h.toFloat()), OverlayMotion.MORPH_MS, OverlayMotion.emphasized, animated, frame = { t ->
            val k = ((t - 0.3f) / 0.7f).coerceIn(0f, 1f)
            layer.alpha = startAlpha + (1f - startAlpha) * k
            layer.translationY = shift * (1f - k) * (1f - startAlpha)
            chevron.turn = startTurn + (cardTurn - startTurn) * t
        }) { settle(Shape.CARD); then() }
    }

    /** The card shrinks back into the capsule, toward the header, the body fading first. */
    fun collapse(animated: Boolean, then: () -> Unit = {}) {
        if (shape != Shape.CARD) { then(); return }
        morph?.let { it.cancel(); morph = null }
        val capW = capsuleWidth
        val left = steadyLeft().toFloat()
        val top = if (down) 0f else surface.extentH.toFloat() - headerH
        val startAlpha = layer.alpha
        val startTurn = chevron.turn
        animate(RectF(left, top, left + capW, top + headerH), OverlayMotion.MORPH_MS, OverlayMotion.emphasized, animated, frame = { t ->
            layer.alpha = startAlpha * (1f - t / 0.4f).coerceIn(0f, 1f)
            chevron.turn = startTurn + (capsuleTurn - startTurn) * t
        }) { settle(Shape.CAPSULE); then() }
    }

    /** The capsule follows a new width, growing from its anchor's side, its keys travelling with its end. */
    private fun resize(animated: Boolean) {
        val to = width.width
        val from = surface.rect.width().roundToInt()
        if (to == from || to <= 0) return
        val extent = maxOf(to, from)
        val start = CapsulePlacement.leftIn(anchor, extent, from).toFloat()
        surface.setExtent(extent, headerH)
        surface.setRect(start, 0f, start + from, headerH.toFloat())
        fitWindow()
        val left = CapsulePlacement.leftIn(anchor, extent, to).toFloat()
        animate(RectF(left, 0f, left + to, headerH.toFloat()), OverlayMotion.RESIZE_MS, OverlayMotion.glide, animated) { settle(Shape.CAPSULE) }
    }

    /** The open card's height follows its content (a step more, a lifted limit, a second line typed or thought). */
    private fun refitCard(animated: Boolean) {
        val h = surface.cardHeight()
        if (h == surface.rect.height().roundToInt() && surface.extentW == cardW) return
        // Room for the old height and the new while it eases; the header's edge stays put.
        surface.setExtent(cardW, maxOf(h, surface.rect.height().roundToInt()))
        fitWindow()
        val top = if (down) 0f else surface.extentH.toFloat() - h
        animate(RectF(0f, top, cardW.toFloat(), top + h), OverlayMotion.RESIZE_MS, OverlayMotion.glide, animated) { settle(Shape.CARD) }
    }

    /** The header's circle at its end on [side] (null: its middle) of the surface now, in the surface's own coordinates (left, top). */
    fun endCircle(side: Side?): Pair<Int, Int> {
        val r = surface.rect
        val top = if (down) r.top.roundToInt() else r.bottom.roundToInt() - headerH
        return BallGeometry.circleLeft(r.left.roundToInt(), r.right.roundToInt(), ball, side) to top
    }

    /** The circle a steady capsule would have at its end on [side] (null: its middle) (left, top in the surface). */
    fun capsuleEndCircle(side: Side?): Pair<Int, Int> {
        val capW = capsuleWidth
        val left = steadyLeft()
        return BallGeometry.circleLeft(left, left + capW, ball, side) to (if (down) 0 else surface.extentH - headerH)
    }

    /**
     * Folding: the surface narrows (and, from the card, shortens to the header) to the circle at
     * the header's end on [side] — or, for a ball at the top centre (null), in its middle — the rows
     * pinned where they were, fading in the first 40 %. [then] when it is the ball's size and place.
     */
    fun foldTo(side: Side?, animated: Boolean, then: () -> Unit) {
        morph?.let { it.cancel(); morph = null }
        val r = RectF(surface.rect)
        val top = if (down) r.top else r.bottom - headerH
        surface.pin(RectF(r.left, top, r.right, top + headerH))
        val left = BallGeometry.circleLeft(r.left.roundToInt(), r.right.roundToInt(), ball, side).toFloat()
        val bodyAlpha = layer.alpha
        animate(RectF(left, top, left + ball, top + headerH), OverlayMotion.MORPH_MS, OverlayMotion.emphasized, animated, frame = { t ->
            header.alpha = (1f - t / 0.4f).coerceIn(0f, 1f)
            layer.alpha = bodyAlpha * (1f - t / 0.3f).coerceIn(0f, 1f)
        }) { then() }
    }

    /**
     * The capsule as the circle on [side] (null: its middle), its row hidden: what [unfoldFrom]
     * starts from. The owner shows the window like this (transparent) while the ball is still on
     * its way, so the window has drawn before the swap and the morph starts on its first frame.
     */
    fun prepareUnfold(side: Side?) {
        morph?.let { it.cancel(); morph = null }
        settle(Shape.CAPSULE)
        val full = RectF(surface.rect)
        surface.pin(RectF(full))
        val left = BallGeometry.circleLeft(full.left.roundToInt(), full.right.roundToInt(), ball, side).toFloat()
        surface.setRect(left, 0f, left + ball, headerH.toFloat())
        header.alpha = 0f
    }

    /** Unfolding: from the circle on [side] ([prepareUnfold]) the capsule grows out, its row fading in over the last half. */
    fun unfoldFrom(side: Side?, animated: Boolean, then: () -> Unit) {
        if (morph != null || shape != Shape.CAPSULE || surface.rect.width().roundToInt() != ball) prepareUnfold(side)
        val capW = width.width.takeIf { it > 0 } ?: cardW
        val full = RectF(0f, 0f, capW.toFloat(), headerH.toFloat())
        animate(full, OverlayMotion.MORPH_MS, OverlayMotion.emphasized, animated, frame = { t ->
            header.alpha = ((t - 0.5f) / 0.5f).coerceIn(0f, 1f)
        }) { settle(Shape.CAPSULE); then() }
    }

    /** The steady capsule at the header's edge of the card's extent, on its anchor's side. */
    private fun steadyRectInCard(): RectF {
        val capW = capsuleWidth
        val left = CapsulePlacement.leftIn(anchor, cardW, capW).toFloat()
        val top = if (down) 0f else surface.extentH.toFloat() - headerH
        return RectF(left, top, left + capW, top + headerH)
    }

    private fun animate(to: RectF, ms: Long, curve: Interpolator, animated: Boolean, frame: ((Float) -> Unit)? = null, then: () -> Unit) {
        val from = RectF(surface.rect)
        if (!animated || !OverlayMotion.on()) {
            surface.setRect(to)
            frame?.invoke(1f)
            then()
            return
        }
        val now = RectF()
        morph = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = ms
            interpolator = curve
            addUpdateListener { a ->
                val t = a.animatedValue as Float
                now.set(from.left + (to.left - from.left) * t, from.top + (to.top - from.top) * t,
                    from.right + (to.right - from.right) * t, from.bottom + (to.bottom - from.bottom) * t)
                surface.setRect(now)
                frame?.invoke(t)
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled) return
                    if (morph === animation) morph = null
                    then()
                }
            })
            start()
        }
    }

    private fun fitWindow() {
        if (!::params.isInitialized) return
        val w = surface.extentW + 2 * padX
        val h = surface.extentH + padTop + padBottom
        if (params.width == w && params.height == h) return
        params.width = w
        params.height = h
        relayout()
    }

    companion object {
        /** The window's room round the surface for its shadow. */
        const val PAD_X_DP = 12
        const val PAD_TOP_DP = 4
        const val PAD_BOTTOM_DP = 16

        /** Rows inside the card sit this far in; their corners are the card's less that (24 − 12). */
        const val BODY_INSET_DP = 12
        const val INNER_RADIUS_DP = 12f

        /** The line's chevron: ⌃ on the capsule (the card opens upward), ⌄ on the card (it closes down). */
        const val CAPSULE_TURN = 180f
        const val CARD_TURN = 360f

        /** The chevron under an island at the top: ⌄ on the capsule (the card opens down), ⌃ on the card. */
        const val CAPSULE_TURN_DOWN = 0f
        const val CARD_TURN_DOWN = 180f

        /** A step's row; the thought's lines and their spacing. */
        const val STEP_ROW_DP = 26
        const val THOUGHT_LINES = 3
        const val THOUGHT_SPACING = 1.15f
        const val ELLIPSIS = "…"

        /** The timeline's nodes: a step's dot, the newest step's (accent), the thought's sparkle. */
        const val DOT_DP = 2.5f
        const val NEWEST_DOT_DP = 3.5f
        const val SPARK_DP = 13f
        const val NODE_THOUGHT = 0
        const val NODE_NEWEST = 1
        const val NODE_STEP = 2

        /** A new step: the rows slide one place, then its node pops (with a ring going out). */
        const val STEP_SLIDE_MS = 260L
        const val POP_MS = 420L

        /** The light on the timeline: one run back to the line in the first [FLOW_RUN] of [FLOW_MS], then rest. */
        const val FLOW_MS = 2_800L
        const val FLOW_RUN = 0.5f
        const val FLOW_TRAIL = 5
    }
}

/**
 * One rounded rect of solid surface ([rect], radius 24 dp) that the morphs animate, with the
 * header and the card body inside, cut to its outline. The view itself is [extentW] × [extentH]
 * (the window's content, hanging from the window's bottom — or its top, [down]); the rect moves
 * inside it. The header sits on the rect's bottom edge (top edge, [down]) and follows its width,
 * or stays where [pin] put it while a fold cuts it; the body is laid out once at the card's width,
 * on the header's far side.
 */
internal class OverlaySurface(context: Context, private val c: OverlayPalette, private val header: View, private val body: View) : ViewGroup(context) {
    private val painter = SurfacePainter(context)
    private val radius = context.dpf(CapsuleMetrics.RADIUS_DP.toFloat())

    /** The beam round the edge while DSH works. */
    val beam = IslandBeam(this)
    private val headerH = context.dp(CapsuleMetrics.HEIGHT_DP)

    /** The body ends this far into the header's margin: its nearest line reads as the line's own. */
    private val overlap = context.dp(6)

    /**
     * The card opens downward: the header on the rect's top edge, the body under it. The window
     * hangs from its top then, so a taller extent leaves everything where it is.
     */
    var down = false
        set(value) {
            if (field == value) return
            field = value
            layoutHeader()
            requestLayout()
            invalidateOutline()
        }

    val rect = RectF()
    private var pinned: RectF? = null

    var extentW = 0
        private set
    var extentH = 0
        private set

    /** The body's width: the card's. */
    var cardW = 0

    init {
        setWillNotDraw(false)
        clipChildren = true
        clipToOutline = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(rect.left.roundToInt(), rect.top.roundToInt(), rect.right.roundToInt(), rect.bottom.roundToInt(), radius)
            }
        }
        softShadow(c, 6f)
        addView(header)
        addView(body)
    }

    /**
     * The view's size. A window hanging from its bottom edge (not [down]) moves everything in it down
     * by as much as the extent grows: the rect (and a pinned header) keep their place on screen.
     */
    fun setExtent(w: Int, h: Int) {
        if (w == extentW && h == extentH) return
        val dy = (h - extentH).toFloat()
        if (!down && extentH != 0 && dy != 0f) {
            rect.offset(0f, dy)
            pinned?.offset(0f, dy)
            layoutHeader()
            invalidateOutline()
        }
        extentW = w
        extentH = h
        requestLayout()
    }

    fun setRect(r: RectF) = setRect(r.left, r.top, r.right, r.bottom)

    fun setRect(l: Float, t: Float, r: Float, b: Float) {
        val widthChanged = (r - l).roundToInt() != rect.width().roundToInt()
        rect.set(l, t, r, b)
        if (pinned == null) {
            // Laying the header out here, between traversals, clears its pending layout request:
            // measure it first if one is pending (a lock shown, a key hidden), or the next pass
            // would keep the stale measurement.
            if (widthChanged || header.isLayoutRequested) measureHeader()
            layoutHeader()
        }
        invalidateOutline()
        invalidate()
    }

    /** Holds the header at [at] (a fold cuts it there) or lets it follow the rect again (null). */
    fun pin(at: RectF?) {
        pinned = at
        measureHeader()
        layoutHeader()
    }

    /** The tallest the card may be (header included); the body scrolls in what is left. */
    var maxCardH = Int.MAX_VALUE

    /** The card's height for the body as it is now, within [maxCardH]. */
    fun cardHeight(): Int = headerH - overlap + bodyHeight()

    /** The card's height with the body at its natural height, whatever [maxCardH] says. */
    fun naturalCardHeight(): Int = headerH - overlap + naturalBody()

    /** The body's natural height, capped to the room [maxCardH] leaves above the header. */
    private fun bodyHeight(): Int = CapsulePlacement.bodyHeight(naturalBody(), maxCardH, headerH - overlap)

    private fun naturalBody(): Int {
        body.measure(MeasureSpec.makeMeasureSpec(cardW, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        return body.measuredHeight
    }

    private fun headerRect(): RectF = pinned ?: rect

    private fun measureHeader() {
        val w = headerRect().width().roundToInt().coerceAtLeast(0)
        header.measure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(headerH, MeasureSpec.EXACTLY))
    }

    private fun layoutHeader() {
        val r = headerRect()
        val l = r.left.roundToInt()
        val t = if (down) r.top.roundToInt() else r.bottom.roundToInt() - headerH
        header.layout(l, t, l + header.measuredWidth, t + headerH)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        measureHeader()
        if (body.visibility != View.GONE) {
            val h = bodyHeight()
            body.measure(MeasureSpec.makeMeasureSpec(cardW, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY))
        }
        setMeasuredDimension(extentW, extentH)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        layoutHeader()
        if (body.visibility != View.GONE) {
            val left = (extentW - cardW) / 2
            if (down) {
                val top = headerH - overlap
                body.layout(left, top, left + body.measuredWidth, top + body.measuredHeight)
            } else {
                val bottom = extentH - headerH + overlap
                body.layout(left, bottom - body.measuredHeight, left + body.measuredWidth, bottom)
            }
        }
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
        painter.draw(canvas, rect, radius, c)
    }

    /** Over the rows: the beam runs round the edge on top of everything inside. */
    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        painter.drawBeam(canvas, rect, radius, c, beam.turn, beam.alpha)
    }
}
