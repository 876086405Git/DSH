package io.github.ccch1mneyyy.dsh_app.pet

import java.net.URI
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/** The page is an app-owned, per-launch loopback capability, never a remote URL. */
internal class CompanionFloatEndpoint private constructor(val page: String, private val uri: URI) {
    private val root = uri.path.substringBefore("/app/") + "/"

    fun owns(raw: String): Boolean = try {
        val next = URI(raw)
        next.scheme == uri.scheme && next.rawAuthority == uri.rawAuthority &&
            next.normalize().path.startsWith(root) && next.rawUserInfo == null
    } catch (_: Exception) { false }

    companion object {
        fun parse(raw: String): CompanionFloatEndpoint? = try {
            val uri = URI(raw)
            if (raw.length > 2048 || uri.scheme != "http" || uri.host != "127.0.0.1" ||
                uri.port !in 1..65535 || uri.rawUserInfo != null || uri.fragment != null ||
                !Regex("/[A-Za-z0-9_-]{32}/app/index\\.html").matches(uri.path) ||
                uri.rawQuery?.split('&')?.count { it == "mode=float" } != 1
            ) null else CompanionFloatEndpoint(raw, uri)
        } catch (_: Exception) { null }
    }
}

/** The retry belongs to a selection, not a window or a screen-on cycle. */
internal class CompanionFloatRecovery {
    enum class Failure { RETRY, FALLBACK, IGNORE }
    private var selection: String? = null
    private var retried = false
    var fallback = false
        private set

    fun select(page: String?) {
        if (page == selection) return
        selection = page
        retried = false
        fallback = false
    }

    fun failed(): Failure = when {
        selection == null || fallback -> Failure.IGNORE
        !retried -> { retried = true; Failure.RETRY }
        else -> { fallback = true; Failure.FALLBACK }
    }
}

/** Dimming keeps the first real picture; framework-ready can still mean blank shaders. */
internal class CompanionFloatFreeze {
    private var ready = false
    private var pictured = false
    private var requested = false
    private var applied = false

    fun request(value: Boolean): String? { requested = value; return change() }
    fun onReady(): String? { ready = true; return change() }
    fun onPicture(): String? { pictured = true; return change() }

    private fun change(): String? {
        if (!ready || !pictured || applied == requested) return null
        applied = requested
        return if (applied) "freeze" else "thaw"
    }
}

/**
 * When her float in 「一直在」 sits half past the edge: idle long enough (no touch, no bubble), or put
 * away by hand (a fling, 「收到边上」). Put away by hand, the bubble up then goes with her and the
 * rest of that reply stays tucked; a new reply brings her out. Pure, for the JVM tests.
 */
internal class CompanionTuck(private val idleMs: Long) {
    /** Half past the edge now, or sliding there. */
    var tucked = false
    private var byHand = false
    private var heldAt = 0L
    private var putAwayBubble: String? = null

    /**
     * Whether she should be tucked at [now]. [bubble]: one is up; [held]: something keeps her out
     * (a bubble's time, the bar, an answer on its way); [blocked]: a drag, the bar or the menu;
     * [lastCallAt]: the last touch or call for attention.
     */
    fun wanted(resident: Boolean, bubble: Boolean, held: Boolean, blocked: Boolean, dimmed: Boolean, lastCallAt: Long, now: Long): Boolean {
        // Counted from her last bubble too, not just the last touch: a reply gets read before she goes.
        if (held || bubble) heldAt = now
        val idle = dimmed && now - maxOf(lastCallAt, heldAt) >= idleMs
        val want = resident && !bubble && !blocked && (byHand || idle)
        if (!want) byHand = false
        return want
    }

    /** Flung at the side or 「收到边上」: her bubble up now ([bubbleId]) goes with her. */
    fun putAway(bubbleId: String?) {
        byHand = true
        putAwayBubble = bubbleId
    }

    /** More of the reply she was put away during stays tucked with her. */
    fun keeps(bubbleId: String) = tucked && bubbleId == putAwayBubble

    /** A touch, a drag, the menu or the bar: putting her away by hand is over. */
    fun letGo() {
        byHand = false
    }

    fun reset() {
        tucked = false
        byHand = false
        heldAt = 0L
        putAwayBubble = null
    }
}

/** No GL survives a known hidden/capture/screen-off/power-save state. */
internal fun companionCanRender(
    selected: Boolean, fallback: Boolean, shown: Boolean, interactive: Boolean,
    systemShown: Boolean, capturing: Boolean, powerSave: Boolean,
): Boolean = selected && !fallback && shown && interactive && systemShown && !capturing && !powerSave

/** A fixed viewport, cropped by the actual alpha box. Buffer pixels are not Android view pixels. */
internal data class CompanionFloatGeometry(val width: Int, val height: Int) {
    fun fromBuffer(bufferW: Int, bufferH: Int, box: FramePx): FramePx? {
        if (bufferW !in 1..2048 || bufferH !in 1..2048 ||
            box.left !in 0 until bufferW || box.top !in 0 until bufferH ||
            box.right !in 1..bufferW || box.bottom !in 1..bufferH ||
            box.right <= box.left || box.bottom <= box.top
        ) return null
        return FramePx(
            floor(box.left.toDouble() * width / bufferW).toInt(),
            floor(box.top.toDouble() * height / bufferH).toInt(),
            ceil(box.right.toDouble() * width / bufferW).toInt(),
            ceil(box.bottom.toDouble() * height / bufferH).toInt(),
        )
    }

    val whole: FramePx get() = FramePx(0, 0, width, height)

    fun frames(box: FramePx) = PetFrames(
        PetBox(0f, 0f, box.width.toFloat(), box.height.toFloat()), 1f, null,
        fullReach = FramePx(-box.left, -box.top, width - box.left, height - box.top),
    )

    companion object {
        /** Reserve the same margins that EdgeSnap uses for the whole viewport. */
        fun fit(desiredHeight: Int, area: SafeArea, margin: Int): CompanionFloatGeometry? {
            val availableW = area.screenW - area.left - area.right - 2 * margin
            val availableH = area.screenH - area.top - area.bottom - 2 * margin
            if (availableW <= 0 || availableH <= 0) return null
            val height = minOf(desiredHeight, 640, availableH)
            val width = minOf((height * 0.75f).roundToInt(), availableW).coerceAtLeast(1)
            return CompanionFloatGeometry(width, height)
        }

        /** Keep the same viewport origin even when an action changes the opaque box. */
        fun move(window: WindowPos, before: FramePx, after: FramePx) =
            WindowPos(window.x + after.left - before.left, window.y + after.top - before.top)

    }
}
