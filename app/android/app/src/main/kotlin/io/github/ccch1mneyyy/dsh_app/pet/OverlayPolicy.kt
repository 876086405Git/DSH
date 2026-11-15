package io.github.ccch1mneyyy.dsh_app.pet

import kotlin.math.hypot

/** A short line over the pet; tapping it opens [sessionId] on [host]. */
data class PetBubble(
    val id: String,
    val kind: String,
    /** The whole line as Dart wrote it: 「做完了」「标题 · 等你确认」「3 个对话做完了」. */
    val text: String,
    /** The conversation's title (masked), for the open-notice fallback only. */
    val title: String?,
    val sessionId: String?,
    val host: String?,
    /** Device clock; the bubble goes at this time without waiting for another push. */
    val untilMs: Long,
    /** The reply's first lines, under the line: only for 问一句's own answer. */
    val detail: String? = null,
    /** A request answered on the bubble itself. */
    val ask: PetAsk? = null,
) {
    /** What the bubble shows: Dart composes the line, the overlay only draws it. */
    val line: String get() = text
}

/**
 * What a bubble asks the person (docs/design/pets.md §2.7): the whole action or question, as Dart
 * masked it, and how it may be answered right there.
 */
data class PetAsk(
    val eventId: String,
    val token: Long? = null,
    /** approval / question. */
    val kind: String,
    /** Shown in full before any button: an approval's exact action, a question's text. */
    val text: String,
    /** An approval whose exact call Dart could show: 拒绝 / 允许 may go on the bubble. */
    val approvable: Boolean,
    /** A question's 1–3 choices, each answered with one tap; empty: 去回答. */
    val choices: List<String>,
) {
    companion object {
        const val APPROVAL = "approval"
        const val QUESTION = "question"
        const val MAX_TEXT = 300
        const val MAX_CHOICE = 24
        const val MAX_CHOICES = 3

        fun fromMap(m: Map<*, *>?): PetAsk? {
            m ?: return null
            val kind = (m["kind"] as? String)?.takeIf { it == APPROVAL || it == QUESTION } ?: return null
            val raw = (m["choices"] as? List<*>).orEmpty()
            // The label goes back as the answer, so it is shown as it is or not at all: all or none.
            val choices = raw.filterIsInstance<String>().filter {
                it.isNotBlank() && it == it.trim() && '\n' !in it && it.codePointCount(0, it.length) <= MAX_CHOICE
            }
            val said = m["text"] as? String
            val text = PetPush.clean(said, MAX_TEXT) ?: return null
            return PetAsk(
                token = (m["token"] as? Number)?.toLong(),
                eventId = (m["eventId"] as? String)?.takeIf { it.isNotEmpty() && it.length <= 300 } ?: return null,
                kind = kind,
                text = text,
                // Cut here, it is no longer the whole action.
                approvable = kind == APPROVAL && m["approvable"] == true && text == said,
                choices = if (kind == QUESTION && text == said && choices.size == raw.size && raw.size <= MAX_CHOICES) choices else emptyList(),
            )
        }
    }
}

/** One button on a bubble. */
data class BubbleAction(val kind: Kind, val choice: String? = null) {
    enum class Kind { REJECT, ALLOW, CHOOSE, OPEN }

    companion object {
        /**
         * The buttons for [ask]. Nothing is answered that the person can't read whole: an ask whose
         * text is cut ([shownWhole] false) only opens the chat, as one Dart marked unanswerable does.
         */
        fun of(ask: PetAsk?, shownWhole: Boolean): List<BubbleAction> = when {
            ask == null -> emptyList()
            !shownWhole || ask.token == null -> listOf(BubbleAction(Kind.OPEN))
            ask.kind == PetAsk.APPROVAL && ask.approvable -> listOf(BubbleAction(Kind.REJECT), BubbleAction(Kind.ALLOW))
            ask.kind == PetAsk.QUESTION && ask.choices.isNotEmpty() -> ask.choices.map { BubbleAction(Kind.CHOOSE, it) }
            else -> listOf(BubbleAction(Kind.OPEN))
        }
    }
}

/** A host 切换主机 offers: its encoded ref, its label, whether it is the one in use. */
data class PetHost(val ref: String, val label: String, val current: Boolean)

/** The long-press menu's rows (docs/design/pets.md §2.7): shortcuts only where they apply. */
enum class PetMenuItem {
    ASK, NEW_CHAT, SCREENSHOT, STOP, SWITCH_HOST, SNOOZE, SETTINGS;

    companion object {
        /** [screenshots]: whether this Android can take one (the accessibility screenshot, Android 11+). */
        fun of(push: PetPush?, screenshots: Boolean): List<PetMenuItem> = buildList {
            add(ASK)
            add(NEW_CHAT)
            if (screenshots) add(SCREENSHOT)
            if (push?.canStop == true) add(STOP)
            if ((push?.hosts?.size ?: 0) > 1) add(SWITCH_HOST)
            add(SNOOZE)
            add(SETTINGS)
        }
    }
}

/** Invalidating an action must not release the visibility gate before the actual capture ends. */
internal class PetCaptureState {
    class Request internal constructor() { internal var valid = true }
    private var pending: Request? = null
    val inFlight: Boolean get() = pending != null
    fun begin(): Request? {
        if (inFlight) return null
        return Request().also { pending = it }
    }
    fun invalidate() { pending?.valid = false }
    fun finish(request: Request): Boolean {
        if (pending !== request) return false
        pending = null
        return request.valid
    }
}

/**
 * What Dart pushes on `dsh/pet_overlay` `push`: the state PetMood reduced, the tier, the bubble, the most relevant conversation, whether anything
 * is going on, the pack and size. Nothing is reduced again here.
 */
data class PetPush(
    /** Pack id; null when the person picked 「不显示」 (`none`). */
    val packId: String?,
    val state: String,
    val tier: Int,
    val bubble: PetBubble?,
    /** The most relevant conversation: where a tap on the pet goes. */
    val sessionId: String?,
    val host: String?,
    /** A turn runs, something waits for the person, or a bubble is up. */
    val active: Boolean,
    /** small / medium / large. */
    val size: String,
    /** 安静模式 or pet alerts off: no bubbles, so results still need their notification to ring. */
    val quiet: Boolean = false,
    val reduceMotion: Boolean = false,
    /** The conversation the pet stands for runs on the host in use: 「停止当前任务」 applies. */
    val canStop: Boolean = false,
    /** The hosts 切换主机 offers; empty with only one. */
    val hosts: List<PetHost> = emptyList(),
) {
    /** Idle and asleep play a still frame with an occasional action; the rest plays at full speed. */
    val calm: Boolean get() = state == PetPack.IDLE || state == SLEEPING || state == ROAM

    /** A result or a request: worth lighting a dimmed pet up again for. */
    val calling: Boolean get() = state in CALLING

    companion object {
        const val SLEEPING = "sleeping"
        const val ROAM = "roam"
        val CALLING = setOf("attention", "error", "notification")
        private const val MAX_TEXT = 48
        private const val MAX_TITLE = 40
        private const val MAX_DETAIL = 120
        private const val MAX_HOSTS = 8
        private const val MAX_ID = 300
        private val ID = Regex("[a-z0-9][a-z0-9._-]*")

        /** From the channel's argument map; anything malformed falls back to safe values. */
        fun fromMap(m: Map<*, *>, now: Long): PetPush {
            val state = (m["state"] as? String)?.takeIf { it in PetPack.STATES } ?: PetPack.IDLE
            val bubble = (m["bubble"] as? Map<*, *>)?.let { raw ->
                val text = clean(raw["text"] as? String, MAX_TEXT) ?: return@let null
                val session = clean(raw["sessionId"] as? String, MAX_ID)
                PetBubble(
                    id = clean(raw["id"] as? String, MAX_ID) ?: "${raw["kind"]}|$session|$text",
                    kind = (raw["kind"] as? String) ?: "done",
                    text = text,
                    title = clean(raw["title"] as? String, MAX_TITLE),
                    sessionId = session,
                    host = (raw["host"] as? String)?.takeIf { it.length <= 2_000 },
                    untilMs = (raw["untilMs"] as? Number)?.toLong()?.coerceIn(now, now + MAX_BUBBLE_MS) ?: (now + DEFAULT_BUBBLE_MS),
                    detail = clean(raw["detail"] as? String, MAX_DETAIL),
                    ask = PetAsk.fromMap(raw["ask"] as? Map<*, *>),
                )
            }
            // The target conversation: `target {host, sessionId}` (pet_state.dart), or top-level fields.
            val target = m["target"] as? Map<*, *>
            val pack = (m["packId"] as? String)?.takeIf { it != "none" && it.length <= 64 && ID.matches(it) }
            val activeRaw = m["active"] as? Boolean
            return PetPush(
                packId = pack,
                state = state,
                tier = ((m["tier"] as? Number)?.toInt() ?: 0).coerceIn(0, 9),
                bubble = bubble,
                sessionId = clean((target?.get("sessionId") ?: m["sessionId"]) as? String, MAX_ID),
                host = ((target?.get("host") ?: m["host"]) as? String)?.takeIf { it.length <= 2_000 },
                // Older senders without `active`: busy states and a bubble count.
                active = activeRaw ?: (state in BUSY || bubble != null),
                size = when (val name = m["size"] as? String) {
                    "small", "medium", "large" -> name
                    // 自定义: its height rides along; the key changes with it, so the sprite reloads.
                    "custom" -> (m["bodyHeight"] as? Number)?.toFloat()?.takeIf { it.isFinite() }
                        ?.let { "custom:${Math.round(it.coerceIn(PetSize.CUSTOM_MIN, PetSize.CUSTOM_MAX) * 10) / 10f}" } ?: "medium"
                    else -> "medium"
                },
                quiet = m["quiet"] == true,
                reduceMotion = m["reduceMotion"] == true,
                canStop = m["canStop"] == true,
                hosts = (m["hosts"] as? List<*>).orEmpty().take(MAX_HOSTS).mapNotNull { raw ->
                    val h = raw as? Map<*, *> ?: return@mapNotNull null
                    val ref = (h["ref"] as? String)?.takeIf { it.length <= 2_000 } ?: return@mapNotNull null
                    PetHost(ref, clean(h["label"] as? String, MAX_TITLE) ?: return@mapNotNull null, h["current"] == true)
                },
            )
        }

        private val BUSY = setOf("thinking", "working", "juggling", "sweeping", "notification", "carrying")
        const val DEFAULT_BUBBLE_MS = 6_000L
        private const val MAX_BUBBLE_MS = 60_000L

        /** Trimmed, whitespace folded, cut to [max] code points with an ellipsis; blank → null. */
        fun clean(s: String?, max: Int): String? {
            val t = s?.trim()?.replace(Regex("\\s+"), " ")?.takeIf { it.isNotEmpty() } ?: return null
            if (t.codePointCount(0, t.length) <= max) return t
            return t.substring(0, t.offsetByCodePoints(0, max - 1)) + "…"
        }
    }
}

/**
 * The bubble Dart says is up, minus the ones already dealt with: tapped away here, or pushed
 * while the app was on screen (the chat page's pet said it there).
 */
class BubbleSlot {
    private val done = object : LinkedHashMap<String, Unit>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>?) = size > 64
    }
    private var current: PetBubble? = null

    /** The bubble of the latest push; [inApp] marks it said already. Returns true for a new bubble. */
    fun set(b: PetBubble?, inApp: Boolean): Boolean {
        if (b == null || done.containsKey(b.id)) {
            current = null
            return false
        }
        if (inApp) {
            done[b.id] = Unit
            current = null
            return false
        }
        val fresh = current?.id != b.id
        current = b
        return fresh
    }

    fun current(now: Long): PetBubble? {
        if (current != null && now >= current!!.untilMs) current = null
        return current
    }

    /** Tapped: gone for good, even if Dart pushes it again. */
    fun dismiss() {
        current?.let { done[it.id] = Unit }
        current = null
    }
}

enum class Visibility { HIDDEN, SHOWN, PAUSED }

/**
 * One evaluation: whether the window shows, whether it is dimmed where it docks, whether the
 * overlay needs its own foreground service, the bubble, and when to evaluate again without any
 * event ([wakeAt]).
 */
data class Decision(
    val visibility: Visibility,
    val dimmed: Boolean,
    val ownService: Boolean,
    val bubble: PetBubble?,
    val wakeAt: Long?,
    val why: String,
)

/** A tap plays with the pet; a second one soon after, close by, opens the conversation instead. */
internal class PetTaps(private val timeoutMs: Long, private val slop: Float) {
    private var waiting = false
    private var at = 0L
    private var x = 0f
    private var y = 0f

    /**
     * Whether the tap pressed at [downMs] and released at [upMs] on ([tapX], [tapY]) is the second
     * of a pair. As the platform's double tap: the wait runs from one release to the next press.
     */
    fun second(downMs: Long, upMs: Long, tapX: Float, tapY: Float): Boolean {
        val paired = waiting && downMs - at in 0..timeoutMs && hypot(tapX - x, tapY - y) <= slop
        waiting = !paired
        at = upMs; x = tapX; y = tapY
        return paired
    }

    /** A drag, a long press or a cancelled touch came in between: the next tap starts over. */
    fun clear() { waiting = false }
}

/**
 * The out-of-app pet's visibility and power rules:
 *
 * - shows only while the app is in the background and something is going on ([PetPush.active]),
 *   or always with 「一直显示」;
 * - hides while the app is on screen, during a phone-control task (its own status pill is up),
 *   and for the rest of the day after 「今天不再显示」;
 * - pauses with the screen off or locked;
 * - collapses [IDLE_COLLAPSE_MS] after the last thing going on (not with 「一直显示」);
 * - stays lit while active; after activity ends, dims after [DIM_AFTER_MS] idle unless a touch
 *   or a new call for attention restarts the wait: whole where it docks, at [DIM_ALPHA], animation paused;
 * - neither collapses nor dims while 问一句 is open ([holding]);
 * - keeps the process up with its own foreground service only when it is out and DshService is
 *   not running (remote hosts only).
 */
class OverlayMachine {
    var enabled = false
    var alwaysShow = false
    var snoozedUntil = 0L

    /** A window type is usable (accessibility overlay, or the overlay permission works). */
    var canHost = false

    /** The pack for the pushed id is loaded. */
    var hasPet = false
    var interactive = true
    var phoneTask = false
    var dshService = false

    /** 问一句 is open, or an answer from a bubble is on its way: the pet stays out and lit. */
    var holding = false

    var appForeground = true
        private set
    var last: PetPush? = null
        private set

    /** Last time something was going on while the app was in the background; 0 = none since it left. */
    var lastActiveAt = 0L
        private set

    /** Idle starts when activity ends; touches and calls for attention restart the dim wait. */
    var lastCallAt = 0L
        private set

    val bubbles = BubbleSlot()
    private var wasShown = false

    fun onPush(p: PetPush, now: Long) {
        val prev = last
        last = p
        if (prev?.active == true && !p.active) lastCallAt = now
        if (bubbles.set(p.bubble, inApp = appForeground)) {
            lastCallAt = now
            lastActiveAt = now
        }
        if (p.calling && prev?.state != p.state) lastCallAt = now
        if (!appForeground && p.active) lastActiveAt = now
    }

    /** A replacement Flutter engine must provide its own current host/session and activity. */
    fun resetProducer() {
        last = null
        lastActiveAt = 0L
        lastCallAt = 0L
        wasShown = false
        bubbles.dismiss()
    }

    fun onForeground(foreground: Boolean, now: Long) {
        if (foreground == appForeground) return
        appForeground = foreground
        if (foreground) {
            // Back in the app: what happened out there has been seen; leaving again starts clean.
            lastActiveAt = 0L
            bubbles.dismiss()
        } else if (last?.active == true) {
            lastActiveAt = now
        }
    }

    /** The person touched the pet or its bubble. */
    fun onTouch(now: Long) {
        lastCallAt = now
        if (!appForeground) lastActiveAt = now
    }

    fun snoozed(now: Long) = now < snoozedUntil

    fun decide(now: Long): Decision {
        val d = rule(now)
        val shown = d.visibility != Visibility.HIDDEN
        if (shown && !wasShown) lastCallAt = now
        wasShown = shown
        return if (shown && d.visibility == Visibility.SHOWN) withDim(d, now) else d
    }

    private fun withDim(d: Decision, now: Long): Decision {
        if (last?.active == true || d.bubble != null || holding) return d
        val dimAt = lastCallAt + DIM_AFTER_MS
        if (now >= dimAt) return d.copy(dimmed = true)
        return d.copy(wakeAt = listOfNotNull(d.wakeAt, dimAt).minOrNull())
    }

    private fun rule(now: Long): Decision {
        val push = last
        fun hidden(why: String, keepAlive: Boolean = false, wakeAt: Long? = null) =
            Decision(Visibility.HIDDEN, false, keepAlive && !dshService, null, wakeAt, why)

        if (!enabled) return hidden("off")
        if (push == null || push.packId == null) return hidden("no pet")
        if (!hasPet) return hidden("pack not loaded")
        if (!canHost) return hidden("no window permission")
        if (appForeground) return hidden("app on screen")
        if (snoozed(now)) return hidden("snoozed", wakeAt = snoozedUntil)

        val bubble = bubbles.current(now)
        val recent = lastActiveAt > 0 && now - lastActiveAt < IDLE_COLLAPSE_MS
        if (!(alwaysShow || push.active || bubble != null || recent || holding)) return hidden("nothing going on")

        val wakeAt = listOfNotNull(
            bubble?.untilMs,
            if (!alwaysShow && !push.active && lastActiveAt > 0) lastActiveAt + IDLE_COLLAPSE_MS else null,
        ).minOrNull()
        if (phoneTask) return hidden("phone task", keepAlive = true, wakeAt = wakeAt)
        if (!interactive) return Decision(Visibility.PAUSED, false, !dshService, bubble, wakeAt, "screen off")
        return Decision(Visibility.SHOWN, false, !dshService, bubble, wakeAt, if (push.active) "active" else "recent")
    }

    companion object {
        const val IDLE_COLLAPSE_MS = 5 * 60_000L
        const val DIM_AFTER_MS = 10_000L

        /** The pet's opacity while dimmed. */
        const val DIM_ALPHA = 0.6f
    }
}
