package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The pet itself, in a window of one of [PetFrames]' frames (the wide hit box at rest, grown
 * around the lifted pose while held, around the current animation's cell when it reaches past
 * rest): one cell of the current animation placed at its box on the canvas, whole, a whole number
 * of physical pixels per art pixel and unfiltered for 1× pixel art, smoothly scaled for hi-res
 * packs. Software drawn (the window asks for no hardware acceleration): a small view redrawn only
 * when the frame changes.
 *
 * Touch, on the body ([PetFrames.hit]): drag moves the window, one tap plays with the pet, two in a
 * row open the conversation, a long press opens the menu. A touch that starts elsewhere in a grown
 * window does nothing.
 */
@SuppressLint("ViewConstructor")
internal class PetView(context: Context, private val listener: Listener) : FrameLayout(context) {

    init {
        setWillNotDraw(false)
        descendantFocusability = FOCUS_BLOCK_DESCENDANTS
    }

    interface Listener {
        fun onDragStart()
        fun onDrag(dx: Int, dy: Int)
        fun onDragEnd(velocityX: Float)
        fun onDragCancel()
        /** One tap: play. ([x], [y]) is where, in 0–1 of the companion's viewport when she is shown. */
        fun onPoke(leftHalf: Boolean, x: Float, y: Float)

        /** The second tap of a quick pair, or the accessibility click: open the conversation. */
        fun onTap(leftHalf: Boolean)
        fun onLongPress(rawX: Float?, rawY: Float?)
        fun onMenuMove(rawX: Float, rawY: Float)
        fun onMenuEnd(rawX: Float, rawY: Float, cancelled: Boolean)

        /** A visibility notification actually delivered by the window system; not an occlusion guarantee. */
        fun onShownChanged(shown: Boolean)
    }

    private val paint = Paint().apply { isFilterBitmap = false; isAntiAlias = false; isDither = false }
    private val src = Rect()
    private val dst = RectF()
    private var sprites: PetSprites.Loaded? = null
    private var anim: PetAnimation? = null
    private var cell = -1

    /** Whether an animation change may crossfade: the overlay's motion policy (reduce motion, paused). */
    var blends = true
        set(value) {
            field = value
            if (!value && fromAnim != null) {
                fromAnim = null
                invalidate()
            }
        }

    /** The picture fading out after an animation change (smooth art only), and since when. */
    private var fromAnim: PetAnimation? = null
    private var fromCell = -1
    private var fadeStart = 0L
    private val fadeOut = Paint()
    private val fadeIn = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD) }
    var companionGeometry: CompanionFloatGeometry? = null
        private set
    var companionBounds = FramePx(0, 0, 0, 0)
        private set

    fun setCompanion(view: View, geometry: CompanionFloatGeometry) {
        companionGeometry = geometry
        companionBounds = geometry.whole
        sprites?.overlayFrames = geometry.frames(companionBounds)
        anim = null
        cell = -1
        frame = sprites?.frames?.rest ?: geometry.whole
        addView(view, LayoutParams(geometry.width, geometry.height))
        requestLayout()
        invalidate()
    }

    fun setCompanionBounds(box: FramePx) {
        companionBounds = box
        sprites?.overlayFrames = companionGeometry?.frames(box)
        setFrame(FramePx(0, 0, box.width, box.height))
        // Equal-sized boxes can still move within the fixed viewport.
        requestLayout()
    }

    fun clearCompanion() {
        if (companionGeometry == null) return
        removeAllViews()
        companionGeometry = null
        sprites?.overlayFrames = null
        setSprites(sprites)
    }

    /** The window's frame now, around the rest frame's origin (see [PetFrames]). */
    var frame = FramePx(0, 0, 0, 0)
        private set

    /** The animation on screen (null before the first sheet arrives). */
    val shown: PetAnimation? get() = if (companionGeometry == null) anim else null

    fun setSprites(loaded: PetSprites.Loaded?) {
        sprites = loaded
        paint.isFilterBitmap = loaded?.pack?.crisp == false
        anim = null
        cell = -1
        fromAnim = null
        frame = loaded?.frames?.rest ?: FramePx(0, 0, 0, 0)
        requestLayout()
        invalidate()
    }

    /**
     * Draws into [next] from now on (the window is resized to it in the same main-thread turn, so
     * the pet stays put on screen). False when it already was.
     */
    fun setFrame(next: FramePx): Boolean {
        if (next == frame) return false
        frame = next
        requestLayout()
        invalidate()
        return true
    }

    /**
     * Shows [frameIndex] of [animation] if its sheet is decoded (else keeps the last picture and
     * returns false). Redraws only when the cell actually changes.
     */
    fun show(animation: PetAnimation, frameIndex: Int): Boolean {
        if (companionGeometry != null) return false
        val s = sprites ?: return false
        if (s.sheet(animation) == null) return false
        val c = animation.frames.getOrNull(frameIndex)?.cell ?: return false
        if (animation === anim && c == cell) return true
        val previous = anim
        if (blends && previous != null && previous !== animation && cell >= 0 && !s.pack.pixelArt) {
            fromAnim = previous
            fromCell = cell
            fadeStart = SystemClock.uptimeMillis()
        }
        anim = animation
        cell = c
        invalidate()
        return true
    }

    /** The window's size at rest. */
    val pixelWidth: Int get() = sprites?.frames?.rest?.width ?: 0
    val pixelHeight: Int get() = sprites?.frames?.rest?.height ?: 0

    /** Every frame the window may take while docked ([PetFrames.reach]). */
    val reach: FramePx get() = sprites?.frames?.reach ?: frame

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(frame.width, frame.height)
        companionGeometry?.let { size ->
            getChildAt(0)?.measure(
                MeasureSpec.makeMeasureSpec(size.width, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(size.height, MeasureSpec.EXACTLY),
            )
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val size = companionGeometry ?: return
        val box = companionBounds
        getChildAt(0)?.layout(-box.left, -box.top, size.width - box.left, size.height - box.top)
    }

    // Every gesture, including the initial DOWN, belongs to the existing native listener.
    override fun onInterceptTouchEvent(event: MotionEvent) = true

    override fun onDraw(canvas: Canvas) {
        if (companionGeometry != null) return
        val s = sprites ?: return
        val a = anim ?: return
        if (cell < 0) return
        val from = fromAnim
        val t = (SystemClock.uptimeMillis() - fadeStart).toFloat() / BLEND_MS
        if (from != null && t < 1f && s.sheet(from) != null) {
            // Old × (1 − t) plus new × t in one layer: a true crossfade, the body never goes see-through.
            val layer = canvas.saveLayer(null, null)
            fadeOut.set(paint)
            fadeOut.alpha = ((1f - t) * 255).roundToInt()
            drawCell(canvas, s, from, fromCell, fadeOut)
            fadeIn.isFilterBitmap = paint.isFilterBitmap
            fadeIn.alpha = (t * 255).roundToInt()
            drawCell(canvas, s, a, cell, fadeIn)
            canvas.restoreToCount(layer)
            postInvalidateOnAnimation()
        } else {
            fromAnim = null
            drawCell(canvas, s, a, cell, paint)
        }
    }

    private fun drawCell(canvas: Canvas, s: PetSprites.Loaded, a: PetAnimation, cell: Int, paint: Paint) {
        val sheet = s.sheet(a) ?: return
        val r = sheet.perLogical
        val cw = (a.box.w * r).toInt()
        val ch = (a.box.h * r).toInt()
        val col = cell % a.cols
        val row = cell / a.cols
        src.set(col * cw, row * ch, (col + 1) * cw, (row + 1) * ch)
        if (src.right > sheet.bitmap.width || src.bottom > sheet.bitmap.height) return
        // Placed on whole physical pixels, from the rest origin whatever the frame (the pet doesn't
        // move when the window grows); the size is whole too for 1× pixel art (k is an integer).
        val at = s.frames.cell(a)
        dst.set(
            (at.left - frame.left).toFloat(), (at.top - frame.top).toFloat(),
            (at.right - frame.left).toFloat(), (at.bottom - frame.top).toFloat(),
        )
        canvas.drawBitmap(sheet.bitmap, src, dst, paint)
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        listener.onShownChanged(visibility == VISIBLE)
    }

    // ---- touch ---------------------------------------------------------------------------------

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
    private var downX = 0f
    private var downY = 0f
    private var dragging = false
    private var longPressed = false
    private var touching = false
    private var lastX = 0f
    private var lastY = 0f
    private var tracker: VelocityTracker? = null
    private val taps = PetTaps(
        ViewConfiguration.getDoubleTapTimeout().toLong(),
        ViewConfiguration.get(context).scaledDoubleTapSlop.toFloat(),
    )
    private val longPress = Runnable {
        if (touching && !dragging) {
            longPressed = true
            taps.clear()
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            listener.onLongPress(lastX, lastY)
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Off the body (a thought cloud, the air over a jump): not the pet's, and the rest
                // of the gesture isn't either.
                if (!onBody(event.x, event.y)) return false
                downX = event.rawX
                downY = event.rawY
                lastX = downX
                lastY = downY
                touching = true
                dragging = false
                longPressed = false
                tracker?.recycle()
                tracker = VelocityTracker.obtain().also { it.addMovement(event) }
                postDelayed(longPress, longPressMs)
            }
            MotionEvent.ACTION_MOVE -> {
                if (!touching) return true
                lastX = event.rawX
                lastY = event.rawY
                tracker?.addMovement(event)
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                if (!dragging && !longPressed && (abs(dx) > slop || abs(dy) > slop)) {
                    dragging = true
                    taps.clear()
                    removeCallbacks(longPress)
                    listener.onDragStart()
                }
                if (longPressed) listener.onMenuMove(event.rawX, event.rawY)
                else if (dragging) listener.onDrag(dx.roundToInt(), dy.roundToInt())
            }
            MotionEvent.ACTION_UP -> {
                if (!touching) return true
                removeCallbacks(longPress)
                tracker?.addMovement(event)
                when {
                    longPressed -> listener.onMenuEnd(event.rawX, event.rawY, false)
                    dragging -> listener.onDragEnd(velocity())
                    else -> {
                        val size = companionGeometry
                        // Left and right halves split at the body's centre line (anchor.x), not the window's.
                        val left = event.x + frame.left < if (size != null) width / 2f else
                            (sprites?.let { (it.pack.anchorX - it.window.x) * it.screenScale } ?: (width / 2f))
                        if (taps.second(event.downTime, event.eventTime, event.rawX, event.rawY)) listener.onTap(left)
                        else if (size == null) listener.onPoke(left, 0.5f, 0.5f)
                        else listener.onPoke(
                            left,
                            (event.x + companionBounds.left) / size.width,
                            (event.y + companionBounds.top) / size.height,
                        )
                    }
                }
                reset()
            }
            MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_POINTER_DOWN -> cancelGesture()
        }
        return true
    }

    /** Whether ([x], [y]) in the view is on the shown animation's body, or anywhere before any is shown. */
    private fun onBody(x: Float, y: Float): Boolean {
        val f = sprites?.frames ?: return true
        return f.hit(anim).contains(x + frame.left, y + frame.top)
    }

    private fun velocity(): Float {
        val t = tracker ?: return 0f
        t.computeCurrentVelocity(1000)
        return t.xVelocity
    }

    fun cancelInteraction() = cancelGesture()

    private fun cancelGesture() {
        taps.clear()
        val held = touching && longPressed
        val dragged = touching && dragging
        reset()
        if (held) listener.onMenuEnd(lastX, lastY, true)
        else if (dragged) listener.onDragCancel()
    }

    private fun reset() {
        removeCallbacks(longPress)
        touching = false
        longPressed = false
        dragging = false
        tracker?.recycle()
        tracker = null
    }

    override fun onDetachedFromWindow() {
        if (companionGeometry != null) listener.onShownChanged(false)
        cancelGesture()
        super.onDetachedFromWindow()
    }

    // ---- accessibility: a button that opens the conversation, long-press for the menu ----------

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = "android.widget.Button"
        info.isClickable = true
        info.isLongClickable = true
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_CLICK, AppStrings.get(context, R.string.pet_open_chat)))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(AccessibilityNodeInfo.ACTION_LONG_CLICK, AppStrings.get(context, R.string.pet_more)))
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean = when (action) {
        AccessibilityNodeInfo.ACTION_CLICK -> { listener.onTap(false); true }
        AccessibilityNodeInfo.ACTION_LONG_CLICK -> { listener.onLongPress(null, null); true }
        else -> super.performAccessibilityAction(action, arguments)
    }

    private companion object {
        /** Crossfade between two animations of a smooth (non-pixel) pack; matches Dart's petBlend. */
        const val BLEND_MS = 180f
    }
}
