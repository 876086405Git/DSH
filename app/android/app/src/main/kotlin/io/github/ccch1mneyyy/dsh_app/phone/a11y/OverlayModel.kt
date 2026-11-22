package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.pet.Dock
import io.github.ccch1mneyyy.dsh_app.pet.EdgeSnap
import io.github.ccch1mneyyy.dsh_app.pet.SafeArea
import io.github.ccch1mneyyy.dsh_app.pet.Side
import io.github.ccch1mneyyy.dsh_app.pet.WindowPos
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt

// The control's pure half (measured in OverlayModelTest): what the line says, the steps behind it,
// the header's keys, the capsule's width, the ball's hold-to-stop, where the capsule rests and
// where a drag leaves it, and where the ball meets the capsule and tucks away. ControlOverlay,
// OverlayCapsule and OverlayBall draw what these decide.

/**
 * A status line as the capsule shows it. The core says 「免确认 · DSH 正在操作 · 点「发送」」; the
 * capsule is DSH's own, so it shows 「点「发送」」 and keeps 免确认 for the card.
 */
internal data class StatusLine(
    /** What the capsule shows. */
    val text: String,
    /** The 免确认 prefix was there: nothing in this task asks. */
    val waived: Boolean,
    /** An action (tap, type, scroll, key) rather than reading the screen: it goes into the steps. */
    val acting: Boolean,
)

/**
 * Takes the prefixes off the core's lines. [waivedFormat] and [actingFormat] are the core's own
 * formats in the app language (`phone_waived_status`, `phone_acting`), so the prefixes match
 * whichever language the line came in.
 */
internal class StatusLines(waivedFormat: String, actingFormat: String) {
    private val waived = prefixOf(waivedFormat)
    private val acting = prefixOf(actingFormat)

    fun parse(raw: String): StatusLine {
        val whole = raw.trim()
        var t = whole
        var isWaived = false
        if (waived != null && t.startsWith(waived)) {
            isWaived = true
            t = t.substring(waived.length).trim()
        }
        var isActing = false
        if (acting != null && t.startsWith(acting)) {
            isActing = true
            t = t.substring(acting.length).trim()
        }
        return StatusLine(t.ifEmpty { whole }, isWaived, isActing)
    }

    companion object {
        /** What a one-argument format says before the argument (「免确认 · %1$s」 → 「免确认 · 」); null unless it ends in it. */
        fun prefixOf(format: String): String? {
            for (arg in ARGS) if (format.endsWith(arg)) return format.dropLast(arg.length).takeIf { it.isNotBlank() }
            return null
        }

        private val ARGS = listOf("%1\$s", "%s")
    }
}

/** The task's last actions, for the card: newest last, the same action twice in a row once. */
internal class StepHistory(private val capacity: Int = CAPACITY) {
    private val steps = ArrayDeque<String>()

    /** Every action so far this task (not only the ones kept): the island's 「第 N 步」. */
    var count = 0
        private set

    fun add(line: StatusLine) {
        if (!line.acting || steps.lastOrNull() == line.text) return
        count++
        steps.addLast(line.text)
        // One more than shown: the newest may be the line the header shows.
        while (steps.size > capacity + 1) steps.removeFirst()
    }

    /** Up to [limit] steps before [current] (the header's line), newest first. */
    fun before(current: StatusLine?, limit: Int): List<String> {
        val list = steps.toMutableList()
        if (current != null && current.acting && list.lastOrNull() == current.text) list.removeAt(list.lastIndex)
        return list.asReversed().take(limit.coerceAtLeast(0))
    }

    fun clear() {
        steps.clear()
        count = 0
    }

    companion object {
        const val CAPACITY = 3
    }
}

/**
 * The header's keys, left to right: the same in the capsule and the card. 暂停 (held a second:
 * 停止) and 回到 DSH Go at the right end.
 */
internal enum class Slot { MARK, LINE, PAUSE, BACK }

/**
 * Sizes of the control, in dp. One radius for every form: the capsule's ends, the card's corners
 * and the ball are the same 24 dp curve, so a morph never re-bends a corner.
 */
internal object CapsuleMetrics {
    /** Capsule height, ball diameter, card header. */
    const val HEIGHT_DP = 48
    const val RADIUS_DP = 24

    /** Touch target of the mark, 暂停 and 停止 (≥ 48 dp). */
    const val KEY_DP = 48

    /** The visible disc of 暂停 / 停止: concentric with the capsule's round end (6 dp in all round). */
    const val DISC_DP = 36
    const val KEY_GAP_DP = 4

    /** 已解除限制's lock before the line, when any limit is lifted. */
    const val LOCK_DP = 14
    const val LOCK_GAP_DP = 6

    /** The line's chevron (opens the card) and the room after it. */
    const val CHEVRON_DP = 14
    const val CHEVRON_GAP_DP = 6
    const val LINE_END_DP = 6

    /** A stopped capsule (no keys) ends this far after its line. */
    const val STOPPED_END_DP = 20

    /** Width range; widths come in whole [STEP_DP] so a line a glyph longer doesn't nudge it. */
    const val MIN_DP = 120
    const val MAX_DP = 400
    const val STEP_DP = 8

    /** Gap to the screen sides, as the app's floating controls (page-design §7). */
    const val EDGE_DP = 12

    fun slots(stopped: Boolean): List<Slot> =
        if (stopped) listOf(Slot.MARK, Slot.LINE) else listOf(Slot.MARK, Slot.LINE, Slot.PAUSE, Slot.BACK)

    /** The capsule's content width in dp for a line [textDp] wide ([chevron]: the line can open the card). */
    fun contentDp(textDp: Float, lock: Boolean, stopped: Boolean, chevron: Boolean = !stopped): Float {
        var w = KEY_DP + textDp
        if (lock) w += LOCK_DP + LOCK_GAP_DP
        if (chevron) w += CHEVRON_GAP_DP + CHEVRON_DP
        w += if (stopped) STOPPED_END_DP.toFloat() else (LINE_END_DP + KEY_DP + KEY_GAP_DP + KEY_DP).toFloat()
        return w
    }

    /** The widest the capsule (and the card) gets on a screen [screenW] px wide. */
    fun maxPx(screenW: Int, density: Float): Int =
        minOf(screenW - (2 * EDGE_DP * density).roundToInt(), (MAX_DP * density).roundToInt()).coerceAtLeast((MIN_DP * density).roundToInt())

    /** The capsule's width in px for content [contentPx] wide: whole steps, within the range. */
    fun widthPx(contentPx: Float, screenW: Int, density: Float): Int {
        val step = STEP_DP * density
        val stepped = (ceil(contentPx / step) * step).roundToInt()
        return stepped.coerceIn((MIN_DP * density).roundToInt(), maxPx(screenW, density))
    }

    /** How many past steps the card lists: one on a short screen (landscape), else three. */
    fun steps(screenHeightDp: Float): Int = if (screenHeightDp < 560f) 1 else StepHistory.CAPACITY
}

/**
 * The capsule's width over time. It grows at once (a longer line is never cut while there is
 * room), but shrinks only after the lines have been narrower for [shrinkAfterMs], and only by
 * more than [slack] px: the agent alternates 「正在看屏幕」 and 「点「…」」 every second, and a
 * capsule pulsing with them would be restless.
 */
internal class CapsuleWidth(private val slack: Int, private val shrinkAfterMs: Long = SHRINK_AFTER_MS) {
    var width = 0
        private set

    /** The widest line since they got narrower, and since when. */
    private var narrower = 0
    private var since: Long? = null

    /** When [offer] may shrink it; null while nothing is pending. */
    val shrinkAt: Long? get() = since?.let { it + shrinkAfterMs }

    /** A line wanting [wanted] px at [now]; true when [width] changed. */
    fun offer(wanted: Int, now: Long): Boolean {
        if (width == 0 || wanted >= width) {
            since = null
            if (wanted == width) return false
            width = wanted
            return true
        }
        if (width - wanted <= slack) {
            // Nearly as wide: keep it, and forget an older, narrower wish.
            since = null
            return false
        }
        val start = since
        if (start == null) {
            since = now
            narrower = wanted
            return false
        }
        narrower = maxOf(narrower, wanted)
        if (now - start < shrinkAfterMs) return false
        since = null
        width = narrower
        return true
    }

    /** At once, whatever it was (a state change, such as 已停止, rather than a new line). */
    fun force(wanted: Int): Boolean {
        since = null
        if (width == wanted) return false
        width = wanted
        return true
    }

    fun reset() {
        width = 0
        since = null
    }

    companion object {
        const val SHRINK_AFTER_MS = 1_200L
    }
}

/**
 * The ball's press-and-hold stop: a tap opens the capsule; holding still for [armMs] starts a ring
 * filling round the ball, and at [armMs] + [fillMs] the task stops. Letting go while it fills
 * cancels (it is neither a tap nor a stop); moving past the touch slop is a drag, never a stop.
 */
internal class HoldToStop(val armMs: Long = ARM_MS, val fillMs: Long = FILL_MS) {
    enum class State { IDLE, PRESSED, FILLING, FIRED, DRAGGING }

    /** [STOP]: stop now (the hold closed on this release); [STOPPED]: it already stopped while held. */
    enum class Release { TAP, CANCELLED, DRAG, STOP, STOPPED, NONE }

    var state = State.IDLE
        private set

    private var downAt = 0L

    fun down(now: Long) {
        state = State.PRESSED
        downAt = now
    }

    /** The finger moved past the slop: a drag from here on. */
    fun moved() {
        if (state == State.PRESSED || state == State.FILLING) state = State.DRAGGING
    }

    /** True exactly once: when the hold has lasted long enough to stop. */
    fun tick(now: Long): Boolean {
        if (state != State.PRESSED && state != State.FILLING) return false
        val held = now - downAt
        if (held >= armMs + fillMs) {
            state = State.FIRED
            return true
        }
        if (held >= armMs) state = State.FILLING
        return false
    }

    /** The ring, 0–1 (0 until [armMs]). */
    fun progress(now: Long): Float = when (state) {
        State.PRESSED, State.FILLING -> ((now - downAt - armMs).toFloat() / fillMs).coerceIn(0f, 1f)
        State.FIRED -> 1f
        else -> 0f
    }

    /** When [tick] next has something to do; null when nothing is pressed. */
    fun nextAt(): Long? = when (state) {
        State.PRESSED -> downAt + armMs
        State.FILLING -> downAt + armMs + fillMs
        else -> null
    }

    fun up(now: Long): Release {
        // A frame that would have closed the ring may never have come (a busy main thread).
        val closedNow = tick(now)
        val r = when (state) {
            State.PRESSED -> Release.TAP
            State.FILLING -> Release.CANCELLED
            State.DRAGGING -> Release.DRAG
            State.FIRED -> if (closedNow) Release.STOP else Release.STOPPED
            State.IDLE -> Release.NONE
        }
        state = State.IDLE
        return r
    }

    fun cancel() {
        state = State.IDLE
    }

    companion object {
        /** Under the system's long-press timeout (400 ms): a held finger shows the ring promptly. */
        const val ARM_MS = 300L

        /** The ring's fill: a full second from touch to stop, long enough not to happen by accident. */
        const val FILL_MS = 700L
    }
}

/** Where the capsule rests across the screen; it grows from this side when its line gets longer. */
internal enum class CapsuleAnchor { LEFT, CENTRE, RIGHT }

/** Where the person left the capsule: across, and its centre's height as a share of the safe height. Kept across tasks. */
internal data class CapsuleSpot(val anchor: CapsuleAnchor = CapsuleAnchor.CENTRE, val fraction: Float = CapsulePlacement.CENTRE)

/**
 * Where the capsule sits, in px. By default centred in the lower middle of the screen (its centre
 * at [CENTRE] of the safe height, in the thumb's reach and off the app's own header); dragged, at
 * the height it was let go and against the nearest of three anchors ([CapsuleAnchor], [EDGE_DP]
 * from the side). Always [GAP_DP] clear of the bars and of whatever takes the bottom — the
 * keyboard, the confirm card — by moving up over it, and moved down while the card is open if the
 * card would not fit above it. The card grows upward from it, so the header (and 停止) stays where
 * the capsule was. Its window hangs from the bottom (Gravity.BOTTOM): a taller window grows up, the
 * bottom edge never moves.
 */
internal object CapsulePlacement {
    const val CENTRE = 0.72f
    const val GAP_DP = 12
    const val EDGE_DP = CapsuleMetrics.EDGE_DP

    /** Let go this far past the screen's side (or thrown out past it), the capsule folds into the ball there. */
    const val FOLD_OUT_DP = 32

    /**
     * The capsule's centre y on [area], at [fraction] of the safe height; [obstacleTop]: the top of a
     * keyboard or confirm card, if one shows; [cardH]: the open card's height (header included),
     * which must fit under the status bar above the header.
     */
    fun centreY(area: SafeArea, headerH: Int, gap: Int, obstacleTop: Int? = null, fraction: Float = CENTRE, cardH: Int = 0): Int {
        val top = area.top
        val bottom = area.screenH - area.bottom
        var base = top + ((bottom - top) * fraction).roundToInt()
        if (cardH > 0) base = maxOf(base, top + gap + cardH - headerH / 2)
        val limit = minOf(bottom, obstacleTop ?: bottom) - gap - headerH / 2
        val floor = top + gap + headerH / 2
        return maxOf(floor, minOf(base, limit))
    }

    /** A dragged capsule's centre, kept [gap] clear of the bars. */
    fun clampCentre(area: SafeArea, centreY: Int, headerH: Int, gap: Int): Int =
        centreY.coerceIn(area.top + gap + headerH / 2, maxOf(area.top + gap + headerH / 2, area.screenH - area.bottom - gap - headerH / 2))

    /** The share of the safe height a capsule let go at [centreY] keeps (what [centreY] takes back). */
    fun fractionFor(area: SafeArea, centreY: Int, headerH: Int, gap: Int): Float {
        val h = area.screenH - area.bottom - area.top
        if (h <= 0) return CENTRE
        return (clampCentre(area, centreY, headerH, gap) - area.top).toFloat() / h
    }

    /**
     * The width the capsule and the card are sized for: the screen less a cutout or bar on either
     * side. A left or right anchor starts inside that inset, so the widest card still ends on screen.
     */
    fun roomW(area: SafeArea): Int = area.screenW - area.left - area.right

    /** The capsule's left on screen at [anchor], [capW] wide, [edge] from the side. Centred means on the whole screen. */
    fun capsuleLeft(anchor: CapsuleAnchor, area: SafeArea, capW: Int, edge: Int): Int = when (anchor) {
        CapsuleAnchor.LEFT -> area.left + edge
        CapsuleAnchor.CENTRE -> (area.screenW - capW) / 2
        CapsuleAnchor.RIGHT -> area.screenW - area.right - edge - capW
    }

    /** Where a steady capsule [capW] wide sits in a surface [extentW] wide: on its anchor's side, so it grows from there. */
    fun leftIn(anchor: CapsuleAnchor, extentW: Int, capW: Int): Int = when (anchor) {
        CapsuleAnchor.LEFT -> 0
        CapsuleAnchor.CENTRE -> (extentW - capW) / 2
        CapsuleAnchor.RIGHT -> extentW - capW
    }

    /** The window's x (Gravity.LEFT) that puts the steady capsule's left at [capLeft]; [leftInSurface] is [leftIn]. */
    fun windowX(capLeft: Int, padX: Int, leftInSurface: Int) = capLeft - padX - leftInSurface

    /** The anchor a capsule let go at [capLeft] settles on: thrown, the side it was thrown to; else the nearest. */
    fun anchorFor(capLeft: Int, capW: Int, area: SafeArea, edge: Int, velocityX: Float): CapsuleAnchor {
        if (abs(velocityX) >= EdgeSnap.FLING_PX_PER_S) return if (velocityX < 0) CapsuleAnchor.LEFT else CapsuleAnchor.RIGHT
        return CapsuleAnchor.entries.minBy { abs(capsuleLeft(it, area, capW, edge) - capLeft) }
    }

    /**
     * The side a capsule let go at [capLeft] folds into the ball on: past the screen's side by [out]
     * px, or past it at all and thrown that way; null when it stays a capsule.
     */
    fun foldSide(capLeft: Int, capW: Int, screenW: Int, out: Int, velocityX: Float): Side? {
        val pastLeft = -capLeft
        val pastRight = capLeft + capW - screenW
        return when {
            pastLeft >= out || (pastLeft > 0 && velocityX <= -EdgeSnap.FLING_PX_PER_S) -> Side.LEFT
            pastRight >= out || (pastRight > 0 && velocityX >= EdgeSnap.FLING_PX_PER_S) -> Side.RIGHT
            else -> null
        }
    }

    /**
     * The card's room, header included, above a capsule centred at [centreY]: up to [gap] under
     * the status bar. A short screen with the keyboard up has little; the card's body scrolls in it.
     */
    fun cardRoom(area: SafeArea, centreY: Int, headerH: Int, gap: Int): Int = centreY + headerH / 2 - (area.top + gap)

    /** The body's height in a card at most [maxCard] tall, of which the header takes [headerPart]. */
    fun bodyHeight(natural: Int, maxCard: Int, headerPart: Int): Int = minOf(natural, (maxCard - headerPart).coerceAtLeast(0))

    /** The window's Gravity.BOTTOM offset for a capsule centred at [centreY], its root padding the surface by [padBottom] below. */
    fun windowY(screenH: Int, centreY: Int, headerH: Int, padBottom: Int) = screenH - (centreY + headerH / 2) - padBottom

    /** A Gravity.BOTTOM window's top on screen, from its offset [y] and its height. */
    fun windowTop(screenH: Int, y: Int, windowH: Int) = screenH - y - windowH
}

/**
 * Where the ball's window goes, in px. The ball sits [edge] from the screen side like the app's
 * floating controls; folding starts on the capsule's end circle.
 */
internal object BallGeometry {
    /** The window margin EdgeSnap keeps from the safe area so the ball itself is [edge] in. */
    fun margin(edge: Int, pad: Int) = edge - pad

    /** A ball on [side], level with a capsule centred at [centreY]: where one never moved rests (on the right), and where a capsule dragged off a side folds. */
    fun dockLevel(area: SafeArea, size: Int, margin: Int, centreY: Int, side: Side = Side.RIGHT): Dock {
        val lo = EdgeSnap.minY(area, margin)
        val hi = EdgeSnap.maxY(area, size, margin)
        val f = if (hi <= lo) 0f else ((centreY - size / 2 - lo).toFloat() / (hi - lo)).coerceIn(0f, 1f)
        return Dock(side, f)
    }

    /**
     * An idle ball half out of sight: slid out on its [side] until its centre is on the safe area's
     * edge, half of it showing. [pos] is its docked window ([pad] round a [ball] across).
     */
    fun tucked(pos: WindowPos, side: Side, area: SafeArea, pad: Int, ball: Int): WindowPos =
        WindowPos(if (side == Side.LEFT) area.left - ball / 2 - pad else area.screenW - area.right - ball / 2 - pad, pos.y)

    /** A resting ball window ([size] square) at [pos] lifted, if it would reach below [limit] (a confirm card's top), but not above [minY]. */
    fun above(pos: WindowPos, size: Int, limit: Int?, minY: Int): WindowPos =
        if (limit == null || pos.y + size <= limit) pos else WindowPos(pos.x, maxOf(minY, limit - size))

    /** The left edge of the circle at the end on [side] of a rect [left]..[right] ([ball] across). */
    fun circleLeft(left: Int, right: Int, ball: Int, side: Side) = if (side == Side.RIGHT) right - ball else left

    /**
     * The ball window over a circle at ([circleLeft], [circleTop]) in the surface of a capsule
     * window at ([windowX], [windowY]) whose root pads the surface by [padX], [padTop]; [pad] is
     * the ball window's own room round the ball.
     */
    fun ballOver(windowX: Int, windowY: Int, padX: Int, padTop: Int, circleLeft: Int, circleTop: Int, pad: Int) =
        WindowPos(windowX + padX + circleLeft - pad, windowY + padTop + circleTop - pad)
}

/**
 * The confirm and handoff cards' windows: nearly the display's width, capped so a sentence keeps a
 * readable measure on a tablet. The width is measured from the window the manager laid out (see
 * ControlOverlay.fitCardWidth), never from the context's configuration, which can still describe
 * the previous rotation for a moment after a cold start.
 */
internal object CardMetrics {
    /** Window cap of the confirm card and of the handoff card, in dp. */
    const val CONFIRM_DP = 472
    const val HANDOFF_DP = 492

    /** The window width in px for a display [displayW] px wide ([density] as DisplayMetrics has it). */
    fun windowWidthPx(displayW: Int, density: Float, capDp: Int): Int =
        minOf(displayW - (CapsuleMetrics.EDGE_DP * density).roundToInt(), (capDp * density).roundToInt())
}

/** How long a task has run, as the island's second line shows it: 0:42, 12:05, 1:02:03. */
internal object Elapsed {
    fun format(ms: Long): String {
        val total = (ms.coerceAtLeast(0) / 1000)
        val h = total / 3600
        val m = total / 60 % 60
        val sec = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
    }

    /** The widest this can be for a while (the capsule's width is measured on it, not on every tick). */
    const val WIDEST = "00:00"
}

/**
 * The background-screen window (OverlayScreen): a small live view of the background screen in place
 * of the capsule, against the left or right side of the screen at a height the person chooses,
 * small or large. Sizes in dp.
 */
internal object ScreenWindow {
    /** The view's width in its two sizes; its height follows the background screen's shape. */
    const val SMALL_DP = 116
    const val LARGE_DP = 176

    /** Frame round the view, the footer's height and the surface's corner. */
    const val FRAME_DP = 5
    const val FOOTER_DP = 64
    const val RADIUS_DP = 22
    const val VIEW_RADIUS_DP = 17

    /** Default height (the window's centre) as a share of the safe area: upper half, clear of a confirm card. */
    const val CENTRE = 0.4f

    /** Height ÷ width of a background screen whose shape isn't known yet (a 9 : 20 phone). */
    const val DEFAULT_ASPECT = 20f / 9f

    /** The view's height for [widthPx] at the frame's [aspect] (height ÷ width), within [maxPx]. */
    fun viewHeight(widthPx: Int, aspect: Float, maxPx: Int): Int {
        val a = if (aspect.isFinite() && aspect > 0.5f && aspect < 4f) aspect else DEFAULT_ASPECT
        return (widthPx * a).roundToInt().coerceAtMost(maxPx).coerceAtLeast(widthPx / 2)
    }

    /** The window's left: against [side] of the safe area, [edge] px in. */
    fun left(side: Side, area: SafeArea, windowW: Int, edge: Int): Int =
        if (side == Side.LEFT) area.left + edge else area.screenW - area.right - edge - windowW

    /** The window's top for a centre at [fraction] of the safe area, kept inside it [gap] px from each bar. */
    fun top(fraction: Float, area: SafeArea, windowH: Int, gap: Int): Int {
        val lo = area.top + gap
        val hi = area.screenH - area.bottom - gap - windowH
        val centre = area.top + (area.screenH - area.top - area.bottom) * fraction
        return (centre - windowH / 2f).roundToInt().coerceIn(lo, maxOf(lo, hi))
    }

    /** The share of the safe area a window [windowH] tall at [top] has its centre at. */
    fun fractionFor(top: Int, area: SafeArea, windowH: Int): Float {
        val room = (area.screenH - area.top - area.bottom).coerceAtLeast(1)
        return ((top + windowH / 2f - area.top) / room).coerceIn(0f, 1f)
    }

    /** The side a window dropped with its left at [left] goes to: the nearer one, or the way it was flung. */
    fun sideFor(left: Int, windowW: Int, screenW: Int, velocityX: Float): Side = when {
        velocityX > FLING -> Side.RIGHT
        velocityX < -FLING -> Side.LEFT
        left + windowW / 2 < screenW / 2 -> Side.LEFT
        else -> Side.RIGHT
    }

    private const val FLING = 1200f
}
