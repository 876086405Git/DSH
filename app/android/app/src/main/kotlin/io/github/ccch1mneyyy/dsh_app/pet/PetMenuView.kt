package io.github.ccch1mneyyy.dsh_app.pet

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.PI

/**
 * The long-press menu: a fan of round buttons that blooms out of the pet, each label on its outer
 * side where the finger doesn't cover it. The pet forwards its still-owned pointer stream, so one
 * press-slide-release picks an action; a press let go in place leaves the fan open for a tap.
 *
 * Everything is drawn here over a soft mist in the theme's surface colour, which keeps the labels
 * readable on whatever app is underneath. The buttons swell with the finger's angle and nudge
 * their neighbours aside continuously instead of jumping from one to the next. The child views
 * are invisible: they carry the names and clicks for accessibility services.
 */
@SuppressLint("ViewConstructor")
internal class PetMenuView(
    context: Context,
    rows: List<Row>,
    private val onOutside: () -> Unit,
    private val motion: () -> Boolean,
) : FrameLayout(context) {
    class Row(val label: String, val muted: Boolean = false, val item: PetMenuItem? = null, val shortLabel: String = label, val action: () -> Unit)

    private val palette = OverlayPalette.of(context)
    private val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val mistColor = if (night) 0x12151B else 0xEDF1FA
    private val shadowColor = if (night) 0x000000 else 0x283A6E
    private val shadowAlpha = if (night) 0.5f else 0.22f

    private var rows = rows
    val rowCount: Int get() = rows.size
    private var geometry: PetWheelGeometry? = null
    private var gesture: PetWheelGesture? = null
    /** The gesture began on this window (a tap on the open fan), not on the pet. */
    private var ownStream = false
    private var selection: Int? = null
    private var pointing = false
    private var pointerX = 0f
    private var pointerY = 0f
    private var lastFrame = 0L
    private var ticking = false
    private var closing = false
    private var closed: (() -> Unit)? = null
    var hosts = false
        private set

    // ---- the fan's motion ------------------------------------------------------------------
    private var enter = emptyArray<PetSpring>()
    private var weight = emptyArray<PetSpring>()
    private var nudge = emptyArray<PetSpring>()
    private var pick = emptyArray<PetSpring>()
    private var delay = FloatArray(0)
    private var labelW = FloatArray(0)
    private var order = IntArray(0)
    private val presence = PetSpring(0f, 420f, 36f)
    private var mist = 0f
    private var elapsed = 0f
    /** The action being run: its button stays, swells and fades while the others fold away. */
    private var chosen: Int? = null
    private var committed: Int? = null
    private var commit = 0f

    // ---- the list fallback -----------------------------------------------------------------
    private val buttons = ArrayList<TextView>()
    private val fills = ArrayList<GradientDrawable>()
    private var amounts = FloatArray(rows.size)
    private var reveal = 0f
    private val visibleRect = Rect()

    private val hairline = context.dp(1f).coerceAtLeast(1).toFloat()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = hairline }
    private val mistPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        shader = RadialGradient(
            0f, 0f, 1f,
            intArrayOf(withAlpha(shadowColor, shadowAlpha), withAlpha(shadowColor, shadowAlpha), withAlpha(shadowColor, 0f)),
            floatArrayOf(0f, 0.41f, 1f), Shader.TileMode.CLAMP,
        )
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 12.5f, context.resources.displayMetrics)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        textAlign = Paint.Align.LEFT
    }
    private val icons = PetWheelIcons()
    private val box = RectF()

    init {
        clipChildren = false
        clipToPadding = false
        isClickable = true
        setWillNotDraw(false)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The widest short label as drawn: [PetWheelGeometry.fit] keeps that much room past the buttons. */
    fun labelWidth(): Float = rows.maxOfOrNull { labelPaint.measureText(it.shortLabel) } ?: 0f

    fun setRows(next: List<Row>) {
        gesture = null
        selection = null
        chosen = null
        pointing = false
        hosts = true
        rows = next
        amounts = FloatArray(next.size)
        geometry = null
    }

    fun place(g: PetWheelGeometry) {
        geometry = g
        removeAllViews()
        buttons.clear()
        fills.clear()
        if (g.list) placeList(g) else placeFan(g)
        wake()
    }

    private fun placeFan(g: PetWheelGeometry) {
        alpha = 1f
        background = null
        val n = rows.size
        if (enter.size != n) {
            val middle = (n - 1) / 2f
            enter = Array(n) { PetSpring(0f, 420f, 30f) }
            weight = Array(n) { PetSpring(0f, 520f, 38f) }
            nudge = Array(n) { PetSpring(0f, 520f, 38f) }
            pick = Array(n) { PetSpring(0f, 600f, 44f) }
            delay = FloatArray(n) { abs(it - middle) * 0.022f } // blooms from the middle outward
            order = IntArray(n) { it }
            elapsed = 0f
        }
        labelW = FloatArray(n) { labelPaint.measureText(rows[it].shortLabel) }
        val cx = g.centerX - g.bounds.left
        val cy = g.centerY - g.bounds.top
        val outer = g.mist
        val full = withAlpha(mistColor, 0.9f)
        mistPaint.shader = RadialGradient(
            cx, cy, outer,
            // Clear over the pet itself, full behind the buttons and their labels, then gone.
            intArrayOf(withAlpha(mistColor, 0f), withAlpha(mistColor, 0f), full, full, withAlpha(mistColor, 0.4f), withAlpha(mistColor, 0f)),
            floatArrayOf(0f, 30f * g.density / outer, 72f * g.density / outer, 1f - 66f * g.density / outer, 1f - 32f * g.density / outer, 1f),
            Shader.TileMode.CLAMP,
        )
        for ((i, row) in rows.withIndex()) {
            addView(View(context).apply {
                contentDescription = row.label
                isClickable = true
                isFocusable = true
                setOnClickListener { if (!closing) perform(i) }
            }, LayoutParams(g.buttonWidth, g.buttonHeight).apply {
                leftMargin = (g.centers[i].first - g.bounds.left - g.buttonWidth / 2f).roundToInt()
                topMargin = (g.centers[i].second - g.bounds.top - g.buttonHeight / 2f).roundToInt()
            })
        }
    }

    private fun placeList(g: PetWheelGeometry) {
        alpha = reveal
        background = GradientDrawable().apply {
            cornerRadius = context.dp(20f).toFloat()
            setColor(palette.fill)
            setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
        }
        val list = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(context.dp(6f), context.dp(6f), context.dp(6f), context.dp(6f))
        }
        addView(ScrollView(context).apply {
            isFillViewport = false
            addView(list)
        }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        for ((i, row) in rows.withIndex()) {
            val face = GradientDrawable().apply {
                cornerRadius = context.dp(14f).toFloat()
                setColor(palette.fill)
                setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
            }
            val button = TextView(context).apply {
                text = row.label
                contentDescription = row.label
                textSize = 15f
                gravity = Gravity.CENTER_VERTICAL
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                setTextColor(if (row.muted) palette.muted else palette.ink)
                setPadding(context.dp(14f), context.dp(4f), context.dp(14f), context.dp(4f))
                minHeight = context.dp(52f)
                background = face
                isClickable = true
                isFocusable = true
                setOnClickListener { if (!closing) perform(i) }
            }
            buttons += button
            fills += face
            list.addView(button, LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
    }

    // ---- the pointer ----------------------------------------------------------------------------

    fun beginPointer(x: Float, y: Float) {
        selection = null
        ownStream = false
        gesture = PetWheelGesture(x, y, context.dp(10f).toFloat())
        pointing = true
        pointerX = x
        pointerY = y
        wake()
    }

    fun movePointer(x: Float, y: Float) {
        if (closing) return
        val g = geometry ?: return
        pointerX = x
        pointerY = y
        val selected = gesture?.move(x, y) {
            if (!g.list) g.hit(x, y, selection) else buttons.indexOfFirst {
                it.getGlobalVisibleRect(visibleRect) && g.hitsVisibleRow(x, y, visibleRect.left, visibleRect.top, visibleRect.right, visibleRect.bottom)
            }.takeIf { it >= 0 }
        }
        if (selection != selected) {
            selection = selected
            if (selected != null) performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        }
        wake()
    }

    fun endPointer(x: Float, y: Float, cancelled: Boolean) {
        val active = gesture ?: return
        movePointer(x, y)
        gesture = null
        pointing = false
        // Let go where the long press began: the menu waits for a tap (and, as a list, hands
        // native scrolling a new touch stream). Coming back after a drag still cancels.
        val stays = !ownStream && active.staysOpen(cancelled)
        val index = active.finish(cancelled)
        ownStream = false
        if (stays && !closing) {
            selection = null
            wake()
            return
        }
        if (!closing && index != null) perform(index) else onOutside()
    }

    private fun perform(index: Int) {
        val row = rows.getOrNull(index) ?: return onOutside()
        chosen = index
        performHapticFeedback(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY)
        row.action()
    }

    fun close(then: () -> Unit) {
        if (closing) return
        closing = true
        gesture = null
        pointing = false
        committed = chosen
        commit = 0f
        elapsed = 0f
        closed = then
        wake()
    }

    // The open fan takes its own touches whole: a press on a button or its label picks it and
    // may still slide to another; a press anywhere else, or a second finger, closes without
    // running anything. The list keeps native clicks and scrolling.
    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = geometry?.list == false

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        val g = geometry ?: return false
        if (g.list) return super.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                selection = null
                val pressed = g.tap(event.rawX, event.rawY, labelPaint.textSize * 0.88f) { labelW[it] }
                if (pressed == null) {
                    onOutside()
                    return true
                }
                ownStream = true
                gesture = PetWheelGesture(g.centerX, g.centerY, context.dp(10f).toFloat()).also { it.pin(pressed, event.rawX, event.rawY) }
                pointing = true
                movePointer(event.rawX, event.rawY)
            }
            MotionEvent.ACTION_MOVE -> movePointer(event.rawX, event.rawY)
            MotionEvent.ACTION_UP -> endPointer(event.rawX, event.rawY, false)
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_DOWN -> endPointer(event.rawX, event.rawY, true)
        }
        return true
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
            onOutside()
            return true
        }
        return if (closing) true else super.dispatchTouchEvent(event)
    }

    // ---- frames ---------------------------------------------------------------------------------

    private fun wake() {
        if (!ticking) {
            ticking = true
            lastFrame = SystemClock.uptimeMillis()
            postOnAnimation(tick)
        }
    }

    // One frame loop owns enter, swell and return. Pointer moves only change targets: no layout,
    // Animator allocation or repeated animator cancellation at touch-sampling frequency.
    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val dt = (now - lastFrame).coerceIn(1, 40)
            lastFrame = now
            val g = geometry
            val moving = if (g == null || g.list) stepList(dt) else stepFan(g, dt / 1000f)
            invalidate()
            if (closing && !moving) {
                ticking = false
                val done = closed
                closed = null
                done?.invoke()
            } else if (moving) postOnAnimation(this) else ticking = false
        }
    }

    private fun stepFan(g: PetWheelGeometry, dt: Float): Boolean {
        val animated = motion()
        elapsed += dt
        val goal = if (closing) 0f else 1f
        mist += (goal - mist) * (if (animated) 1f - exp(-dt / (if (closing) 0.05f else 0.07f)) else 1f)
        if (abs(goal - mist) < 0.01f) mist = goal
        var moving = mist != goal

        // Where the finger points, in the fan's own frame, and how far it has left the pet.
        var aim = Double.NaN
        var reach = 0f
        if (pointing && !closing) {
            val dx = (pointerX - g.centerX) * g.direction
            val dy = pointerY - g.centerY
            val distance = hypot(dx, dy)
            if (dx > 0 && distance <= g.limit) {
                aim = atan2(dy, dx).toDouble().coerceIn(-PI / 2, PI / 2)
                val u = ((distance - g.dead * 0.6f) / (g.dead * 0.5f)).coerceIn(0f, 1f)
                reach = u * u * (3 - 2 * u)
            }
        }
        presence.target = if (selection != null && !closing) 1f else 0f
        moving = advance(presence, dt, animated) || moving

        val last = delay.maxOrNull() ?: 0f
        for (i in enter.indices) {
            val stays = closing && committed == i
            val e = enter[i]
            if (!closing) {
                if (elapsed >= delay[i]) e.target = 1f else moving = true
            } else if (!stays) {
                e.stiffness = 760f
                e.damping = 55f
                // The outer buttons fold first, the reverse of the bloom.
                if (elapsed >= (last - delay[i]) * 0.5f) e.target = 0f else moving = true
            }
            val d = if (aim.isNaN()) 9f else ((g.angle(i) - aim) / g.step).toFloat()
            if (!stays) {
                weight[i].target = if (closing) 0f else reach * exp(-d * d / 0.5f)
                pick[i].target = if (!closing && selection == i) 1f else 0f
            }
            nudge[i].target = if (closing) 0f else (reach * 0.33f * g.step * d * exp(-d * d / 2f)).toFloat()
            moving = advance(e, dt, animated) || moving
            moving = advance(weight[i], dt, animated) || moving
            moving = advance(nudge[i], dt, animated) || moving
            moving = advance(pick[i], dt, animated) || moving
        }
        if (closing && committed != null) {
            commit = min(1f, commit + dt / (if (animated) 0.22f else 0.001f))
            if (commit < 1f) moving = true
        }
        return moving
    }

    private fun advance(spring: PetSpring, dt: Float, animated: Boolean): Boolean =
        if (animated) spring.step(dt) else spring.snap()

    private fun stepList(dt: Long): Boolean {
        val fraction = if (motion()) 1f - exp(-dt / (if (closing) 28f else 42f)) else 1f
        val goal = if (closing) 0f else 1f
        reveal += (goal - reveal) * fraction
        if (abs(goal - reveal) < 0.01f) reveal = goal
        var settling = reveal != goal
        alpha = reveal
        for ((i, b) in buttons.withIndex()) {
            val target = if (selection == i && !closing) 1f else 0f
            amounts[i] += (target - amounts[i]) * fraction
            if (abs(target - amounts[i]) < 0.005f) amounts[i] = target
            settling = settling || amounts[i] != target
            val amount = amounts[i]
            b.scaleX = 1f + 0.04f * amount
            b.scaleY = b.scaleX
            fills[i].setColor(blend(palette.fill, palette.tonal, amount))
            fills[i].setStroke(context.dp(1f).coerceAtLeast(1), blend(palette.stroke, palette.accent, amount))
            b.isSelected = selection == i
        }
        return settling
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val g = geometry ?: return
        if (g.list || enter.size != rows.size) return
        mistPaint.alpha = (255 * mist).roundToInt()
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), mistPaint)
        // The button under the finger is drawn last, over its neighbours.
        for (i in 1 until order.size) {
            val v = order[i]
            var j = i - 1
            while (j >= 0 && weight[order[j]].x > weight[v].x) {
                order[j + 1] = order[j]
                j--
            }
            order[j + 1] = v
        }
        for (i in order) drawButton(canvas, g, i)
    }

    private fun drawButton(canvas: Canvas, g: PetWheelGeometry, i: Int) {
        val e = enter[i].x
        if (e <= 0.01f) return
        val d = g.density
        val w = weight[i].x.coerceIn(0f, 1.2f)
        val isCommitted = committed == i
        val ct = if (isCommitted) commit else 0f
        val picked = if (isCommitted) 1f else pick[i].x.coerceIn(0f, 1f)
        val angle = g.angle(i) + nudge[i].x
        val ux = g.direction * cos(angle).toFloat()
        val uy = sin(angle).toFloat()
        val reach = g.radius * e + 9f * d * w
        val x = g.centerX - g.bounds.left + reach * ux
        val y = g.centerY - g.bounds.top + reach * uy
        val scale = (0.45f + 0.55f * e.coerceIn(0f, 1.15f)) * (1f + 0.24f * w) * (1f + 0.3f * ct)
        val alpha = (e * 1.8f).coerceIn(0f, 1f) * (1f - ct)
        val r = g.orb * scale
        val a = (255 * alpha).roundToInt()

        val spread = r + 12f * d
        val save = canvas.save()
        canvas.translate(x, y + 4f * d)
        canvas.scale(spread, spread)
        shadow.alpha = a
        canvas.drawCircle(0f, 0f, 1f, shadow)
        canvas.restoreToCount(save)

        fill.color = blend(palette.fill, palette.accent, picked)
        fill.alpha = a
        canvas.drawCircle(x, y, r, fill)
        ring.strokeWidth = hairline
        ring.color = blend(palette.stroke, palette.accent, picked)
        ring.alpha = a
        canvas.drawCircle(x, y, r - hairline / 2, ring)
        rows[i].item?.let {
            icons.draw(canvas, it, x, y, 23f * d * scale, blend(palette.accent, palette.onAccent, picked), a,
                mirror = it == PetMenuItem.TUCK && g.direction > 0)
        }
        if (isCommitted && ct > 0f) {
            // Running it: one ring rolls outward as the button lets go.
            ring.strokeWidth = 2f * d
            ring.color = palette.accent
            ring.alpha = (255 * (1f - ct) * 0.6f).roundToInt()
            canvas.drawCircle(x, y, g.orb * (1.3f + 0.7f * ct), ring)
        }

        // The label, clear of the button along the same ray: the gap plus the label's own half
        // extent in that direction, so it never sits on the circle at any angle.
        val la = ((e - 0.55f) / 0.4f).coerceIn(0f, 1f) * (1f - ct) * (1f - 0.5f * presence.x.coerceIn(0f, 1f) * (1f - picked)) * (mist * 1.4f).coerceIn(0f, 1f)
        if (la <= 0.01f) return
        val label = rows[i].shortLabel
        val tw = labelW[i]
        val half = labelPaint.textSize * 0.88f
        val lr = reach + r + (9f + 7f * picked) * d + abs(ux) * tw / 2 + abs(uy) * half * 0.75f
        val ly = g.centerY - g.bounds.top + lr * uy
        val left = g.centerX - g.bounds.left + lr * ux - tw / 2
        if (picked > 0.01f) {
            fill.color = palette.tonal
            fill.alpha = (255 * la * picked).roundToInt()
            box.set(left - 8f * d, ly - half, left + tw + 8f * d, ly + half)
            canvas.drawRoundRect(box, half, half, fill)
        }
        labelPaint.color = blend(if (rows[i].muted) palette.muted else palette.ink, palette.onTonal, picked)
        labelPaint.alpha = (255 * la).roundToInt()
        canvas.drawText(label, left, ly - (labelPaint.ascent() + labelPaint.descent()) / 2, labelPaint)
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(tick)
        ticking = false
        closed = null
        gesture = null
        super.onDetachedFromWindow()
    }

    private fun withAlpha(rgb: Int, alpha: Float): Int = (rgb and 0xFFFFFF) or ((255 * alpha).roundToInt() shl 24)

    private fun blend(a: Int, b: Int, t: Float): Int = Color.rgb(
        (Color.red(a) + (Color.red(b) - Color.red(a)) * t).roundToInt(),
        (Color.green(a) + (Color.green(b) - Color.green(a)) * t).roundToInt(),
        (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * t).roundToInt(),
    )
}

/** Small, consistent stroke icons on a 24-unit grid; no font glyphs or third-party UI dependency. */
private class PetWheelIcons {
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 1.7f; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND
    }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val paths = HashMap<PetMenuItem, Path>()

    /** [mirror]: drawn the other way round (tuck points at the side she docks on). */
    fun draw(canvas: Canvas, item: PetMenuItem, x: Float, y: Float, size: Float, color: Int, alpha: Int, mirror: Boolean = false) {
        stroke.color = color
        stroke.alpha = alpha
        dot.color = color
        dot.alpha = alpha
        val save = canvas.save()
        canvas.translate(x - size / 2, y - size / 2)
        canvas.scale(size / 24f, size / 24f)
        if (mirror) canvas.scale(-1f, 1f, 12f, 12f)
        canvas.drawPath(paths.getOrPut(item) { outline(item) }, stroke)
        when (item) {
            PetMenuItem.ASK -> for (dx in floatArrayOf(8.6f, 12f, 15.4f)) canvas.drawCircle(dx, 10.5f, 1.05f, dot)
            PetMenuItem.SWITCH_HOST -> {
                canvas.drawCircle(7.6f, 7.5f, 1.05f, dot)
                canvas.drawCircle(7.6f, 16.5f, 1.05f, dot)
            }
            else -> Unit
        }
        canvas.restoreToCount(save)
    }

    private fun outline(item: PetMenuItem) = Path().apply {
        when (item) {
            PetMenuItem.ASK -> bubble()
            PetMenuItem.NEW_CHAT -> {
                bubble()
                moveTo(12f, 7.6f); lineTo(12f, 13.4f)
                moveTo(9.1f, 10.5f); lineTo(14.9f, 10.5f)
            }
            PetMenuItem.SCREENSHOT -> {
                // Four viewfinder corners around a lens.
                moveTo(4f, 9f); lineTo(4f, 7f); arcTo(RectF(4f, 4f, 10f, 10f), 180f, 90f); lineTo(9f, 4f)
                moveTo(15f, 4f); lineTo(17f, 4f); arcTo(RectF(14f, 4f, 20f, 10f), 270f, 90f); lineTo(20f, 9f)
                moveTo(20f, 15f); lineTo(20f, 17f); arcTo(RectF(14f, 14f, 20f, 20f), 0f, 90f); lineTo(15f, 20f)
                moveTo(9f, 20f); lineTo(7f, 20f); arcTo(RectF(4f, 14f, 10f, 20f), 90f, 90f); lineTo(4f, 15f)
                addCircle(12f, 12f, 2.8f, Path.Direction.CW)
            }
            PetMenuItem.STOP -> addRoundRect(RectF(6.5f, 6.5f, 17.5f, 17.5f), 3f, 3f, Path.Direction.CW)
            PetMenuItem.SWITCH_HOST -> {
                addRoundRect(RectF(4f, 4.5f, 20f, 10.5f), 2f, 2f, Path.Direction.CW)
                addRoundRect(RectF(4f, 13.5f, 20f, 19.5f), 2f, 2f, Path.Direction.CW)
            }
            PetMenuItem.SNOOZE -> {
                // A crescent: most of a circle, closed by the half circle that bites into it.
                arcTo(RectF(3.74f, 4.26f, 19.74f, 20.26f), 14f, 242f, true)
                arcTo(RectF(7.79f, 2.49f, 21.51f, 16.21f), 225f, -180f)
                close()
            }
            PetMenuItem.SETTINGS -> {
                // Two sliders.
                moveTo(4f, 8f); lineTo(11.4f, 8f); moveTo(16.6f, 8f); lineTo(20f, 8f)
                moveTo(4f, 16f); lineTo(5.4f, 16f); moveTo(10.6f, 16f); lineTo(20f, 16f)
                addCircle(14f, 8f, 2.6f, Path.Direction.CW)
                addCircle(8f, 16f, 2.6f, Path.Direction.CW)
            }
            PetMenuItem.ROOM -> {
                // A small house: roof, walls, a door.
                moveTo(4f, 11f); lineTo(12f, 4.5f); lineTo(20f, 11f)
                moveTo(6.5f, 9.2f); lineTo(6.5f, 19.5f); lineTo(17.5f, 19.5f); lineTo(17.5f, 9.2f)
                moveTo(10.2f, 19.5f); lineTo(10.2f, 15f); lineTo(13.8f, 15f); lineTo(13.8f, 19.5f)
            }
            PetMenuItem.UNWATCH -> {
                // An eye, struck through.
                moveTo(3f, 12f); quadTo(12f, 3.5f, 21f, 12f); quadTo(12f, 20.5f, 3f, 12f)
                addCircle(12f, 12f, 2.6f, Path.Direction.CW)
                moveTo(5f, 19f); lineTo(19f, 5f)
            }
            PetMenuItem.TUCK -> {
                // Towards the edge: an arrow up to a line.
                moveTo(19.5f, 5f); lineTo(19.5f, 19f)
                moveTo(4.5f, 12f); lineTo(15f, 12f)
                moveTo(11f, 8f); lineTo(15f, 12f); lineTo(11f, 16f)
            }
            PetMenuItem.HIDE_HOUR -> {
                // A clock face.
                addCircle(12f, 12f, 8f, Path.Direction.CW)
                moveTo(12f, 7.5f); lineTo(12f, 12f); lineTo(15.2f, 14f)
            }
        }
    }

    private fun Path.bubble() {
        moveTo(7.5f, 4.5f)
        lineTo(16.5f, 4.5f)
        arcTo(RectF(12.5f, 4.5f, 20.5f, 12.5f), 270f, 90f)
        lineTo(20.5f, 12.5f)
        arcTo(RectF(12.5f, 8.5f, 20.5f, 16.5f), 0f, 90f)
        lineTo(11f, 16.5f)
        lineTo(6.5f, 20f)
        lineTo(6.5f, 16.37f)
        arcTo(RectF(3.5f, 8.5f, 11.5f, 16.5f), 104.5f, 75.5f)
        lineTo(3.5f, 8.5f)
        arcTo(RectF(3.5f, 4.5f, 11.5f, 12.5f), 180f, 90f)
        close()
    }
}
