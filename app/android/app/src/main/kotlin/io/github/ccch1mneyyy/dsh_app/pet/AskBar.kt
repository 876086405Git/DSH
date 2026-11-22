package io.github.ccch1mneyyy.dsh_app.pet

import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Where 问一句 sends, as Dart answers `askTarget` (docs/design/pets.md §2.7): the conversation the
 * pet stands for when it has one and it is idle ([current]), else a new chat on the host in use
 * ([fresh]); [problem] when nothing can be sent there (the engine is off, no host); whether the
 * offline voice model can take a recording ([voice]); for the resident companion, the light
 * session's last few messages, oldest first ([recent]).
 */
data class AskTarget(
    val current: AskChat?,
    val fresh: AskChat?,
    val problem: String?,
    val voice: String,
    val offer: Long? = null,
    val recent: List<AskLine> = emptyList(),
) {
    /** One conversation (null [sessionId]: a new one) and its one line, 「修复登录 · 本机」. */
    data class AskChat(val sessionId: String?, val host: String?, val line: String)

    /** One message shown above the input: the person's ([user]) or hers. */
    data class AskLine(val user: Boolean, val text: String)

    /** Where a send goes: [fresh] when asked for (「新对话」) or when there is no [current]. */
    fun chat(wantFresh: Boolean): AskChat? = if (wantFresh || current == null) fresh else current

    /** The 「新对话」 switch shows: there is a conversation to switch away from. */
    val canSwitch: Boolean get() = current != null && fresh != null

    companion object {
        const val VOICE_READY = "ready"
        const val VOICE_MISSING = "missing"
        const val VOICE_OFF = "off"
        private const val MAX_LINE = 40
        private const val MAX_RECENT = 3
        private const val MAX_RECENT_TEXT = 300

        fun fromMap(raw: Any?): AskTarget? {
            val m = raw as? Map<*, *> ?: return null
            fun chat(c: Any?): AskChat? {
                val map = c as? Map<*, *> ?: return null
                return AskChat(
                    PetPush.clean(map["sessionId"] as? String, 300),
                    (map["host"] as? String)?.takeIf { it.length <= 2_000 },
                    PetPush.clean(map["line"] as? String, MAX_LINE) ?: return null,
                )
            }
            return AskTarget(
                offer = (m["offer"] as? Number)?.toLong(),
                current = chat(m["current"])?.takeIf { it.sessionId != null },
                fresh = chat(m["fresh"])?.copy(sessionId = null),
                problem = PetPush.clean(m["problem"] as? String, MAX_LINE),
                voice = (m["voice"] as? String)?.takeIf { it == VOICE_READY || it == VOICE_MISSING } ?: VOICE_OFF,
                recent = (m["recent"] as? List<*>).orEmpty().mapNotNull { r ->
                    val row = r as? Map<*, *> ?: return@mapNotNull null
                    val role = row["role"] as? String
                    if (role != "user" && role != "assistant") return@mapNotNull null
                    AskLine(role == "user", PetPush.clean(row["text"] as? String, MAX_RECENT_TEXT) ?: return@mapNotNull null)
                }.takeLast(MAX_RECENT),
            )
        }
    }
}

/** Where the bar goes: beside the docked pet, towards the middle, at its height; above the keyboard. */
object AskPlace {
    /** What is left beside the pet's picture [pet] on [side], within [min]…[max] and the screen. */
    fun width(pet: ScreenRect, side: Side, area: SafeArea, gap: Int, margin: Int, min: Int, max: Int): Int {
        val room = if (side == Side.RIGHT) pet.left - gap - (area.left + margin) else area.screenW - area.right - margin - (pet.right + gap)
        val full = area.screenW - area.left - area.right - 2 * margin
        return room.coerceIn(min, max).coerceAtMost(full)
    }

    fun beside(pet: ScreenRect, side: Side, w: Int, h: Int, area: SafeArea, gap: Int, margin: Int): WindowPos {
        val x = if (side == Side.RIGHT) pet.left - gap - w else pet.right + gap
        return WindowPos(
            x.coerceIn(EdgeSnap.minX(area, margin), EdgeSnap.maxX(area, w, margin)),
            (pet.centerY - h / 2).coerceIn(EdgeSnap.minY(area, margin), EdgeSnap.maxY(area, h, margin)),
        )
    }

    /** IME insets describe overlap with this small window, not the keyboard's full screen height. */
    fun lift(y: Int, screenY: Int, overlap: Int, gap: Int, area: SafeArea, margin: Int): Int =
        if (overlap <= 0) screenY else minOf(y, screenY - overlap - gap).coerceAtLeast(EdgeSnap.minY(area, margin))

}

/**
 * 问一句's input bar (docs/design/pets.md §2.7): the target in one line with a 「新对话」 switch, the
 * text, hold-to-talk and send, a status line for what can't be done. A window of its own that
 * takes focus while it is open, so the keyboard comes; a touch outside or back closes it.
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
internal class AskBarView(context: Context, private val listener: Listener) : LinearLayout(context) {
    interface Listener {
        fun onSend(text: String)
        fun onSwitch()

        /** Pressed ([down]) and let go, or slid off ([cancelled]). */
        fun onMic(down: Boolean, cancelled: Boolean)
        fun onDraft(text: String)
        fun onClose()

        /** The keyboard covers this much of the bar's bottom, px, and whether it is up at all. */
        fun onIme(overlap: Int, visible: Boolean)
    }

    private val palette = OverlayPalette.of(context)
    private val target = TextView(context).apply {
        textSize = 12f
        setTextColor(palette.muted)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    private val switch = TextView(context).apply {
        text = AppStrings.get(context, R.string.pet_new_chat)
        textSize = 12f
        gravity = Gravity.CENTER
        minHeight = context.dp(28f)
        setPadding(context.dp(10f), 0, context.dp(10f), 0)
        isClickable = true
        isFocusable = false
        visibility = GONE
        setOnClickListener { listener.onSwitch() }
    }
    val input: EditText = object : EditText(context) {
        // Back with the keyboard up closes the bar at once, as phone control's input does.
        override fun onKeyPreIme(keyCode: Int, event: KeyEvent?): Boolean {
            if (keyCode == KeyEvent.KEYCODE_BACK && event?.action == KeyEvent.ACTION_UP) {
                listener.onClose()
                return true
            }
            return super.onKeyPreIme(keyCode, event)
        }
    }.apply {
        textSize = 15f
        setTextColor(palette.ink)
        setHintTextColor(palette.muted)
        hint = AppStrings.get(context, R.string.pet_ask_hint)
        background = GradientDrawable().apply { cornerRadius = context.dp(14f).toFloat(); setColor(palette.pressed) }
        setPadding(context.dp(12f), context.dp(9f), context.dp(12f), context.dp(9f))
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_ACTION_SEND or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = 4
        filters = arrayOf(InputFilter.LengthFilter(MAX_TEXT))
        setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_SEND) {
                send()
                true
            } else {
                false
            }
        }
    }
    private val mic = key(R.drawable.ic_pet_mic, AppStrings.get(context, R.string.pet_ask_hold_to_talk))
    private val sendKey = key(R.drawable.ic_pet_send, AppStrings.get(context, R.string.pet_ask_send)).apply {
        setOnClickListener { send() }
    }
    private val status = TextView(context).apply {
        textSize = 12f
        setTextColor(palette.muted)
        visibility = GONE
    }

    /** The resident companion's last few messages, between her name and the input. */
    private val history = LinearLayout(context).apply {
        orientation = VERTICAL
        visibility = GONE
    }
    private var blocked = false
    private var busy = false
    private var listening = false

    init {
        orientation = VERTICAL
        val pad = context.dp(12f)
        setPadding(pad, context.dp(10f), pad, pad)
        background = GradientDrawable().apply {
            cornerRadius = context.dp(18f).toFloat()
            setColor(palette.fill)
            setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
        }
        val head = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        head.addView(target, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        head.addView(switch, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = context.dp(8f) })
        addView(head, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(28f)))
        addView(history, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(2f) })
        val row = LinearLayout(context).apply { orientation = HORIZONTAL; gravity = Gravity.BOTTOM }
        row.addView(input, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        val size = context.dp(40f)
        row.addView(mic, LayoutParams(size, size).apply { marginStart = context.dp(8f) })
        row.addView(sendKey, LayoutParams(size, size).apply { marginStart = context.dp(8f) })
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(6f) })
        addView(status, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(6f) })
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                refreshKeys()
                listener.onDraft(s?.toString().orEmpty())
            }
        })
        mic.setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    listener.onMic(down = true, cancelled = false)
                }
                MotionEvent.ACTION_UP -> {
                    v.isPressed = false
                    val inside = e.x >= 0 && e.y >= 0 && e.x <= v.width && e.y <= v.height
                    listener.onMic(down = false, cancelled = !inside)
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    listener.onMic(down = false, cancelled = true)
                }
            }
            true
        }
        if (Build.VERSION.SDK_INT >= 30) {
            setOnApplyWindowInsetsListener { _, insets ->
                listener.onIme(insets.getInsets(WindowInsets.Type.ime()).bottom, insets.isVisible(WindowInsets.Type.ime()))
                insets
            }
        }
        setSwitch(on = false, shown = false)
        refreshKeys()
    }

    private fun key(icon: Int, label: String) = ImageView(context).apply {
        setImageResource(icon)
        scaleType = ImageView.ScaleType.CENTER
        contentDescription = label
        isClickable = true
        isFocusable = true
    }

    /** The target's line, and the switch: [on] when 「新对话」 is chosen. */
    fun setTarget(line: String?, switchShown: Boolean, on: Boolean) {
        target.text = line ?: ""
        setSwitch(on, switchShown)
    }

    /**
     * [lines] above the input: hers at the start in ink, the person's at the end and muted, three
     * lines each at most. Empty hides the panel; [fade] brings it in briefly.
     */
    fun setRecent(lines: List<AskTarget.AskLine>, fade: Boolean) {
        history.removeAllViews()
        history.visibility = if (lines.isEmpty()) GONE else VISIBLE
        val indent = context.dp(28f)
        lines.forEachIndexed { i, line ->
            val row = TextView(context).apply {
                text = line.text
                textSize = 13f
                setTextColor(if (line.user) palette.muted else palette.ink)
                maxLines = 3
                ellipsize = TextUtils.TruncateAt.END
                gravity = if (line.user) Gravity.END else Gravity.START
                setPaddingRelative(if (line.user) indent else 0, 0, if (line.user) 0 else indent, 0)
            }
            history.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { if (i > 0) topMargin = context.dp(6f) })
        }
        if (fade && lines.isNotEmpty()) {
            history.alpha = 0f
            history.animate().alpha(1f).setDuration(150).start()
        }
    }

    private fun setSwitch(on: Boolean, shown: Boolean) {
        switch.visibility = if (shown) VISIBLE else GONE
        switch.isSelected = on
        switch.setTextColor(if (on) palette.onTonal else palette.ink)
        switch.background = GradientDrawable().apply {
            cornerRadius = context.dp(14f).toFloat()
            setColor(if (on) palette.tonal else palette.fill)
            if (!on) setStroke(context.dp(1f).coerceAtLeast(1), palette.stroke)
        }
    }

    /** One line under the input; [error] in the danger tone. Null hides it. */
    fun setStatus(text: String?, error: Boolean = false) {
        status.text = text
        status.setTextColor(if (error) palette.danger else palette.muted)
        status.visibility = if (text == null) GONE else VISIBLE
    }

    /** [problem]: nothing can be sent now; [sending]: a send is on its way. */
    fun setState(problem: Boolean = blocked, sending: Boolean = busy, listening: Boolean = this.listening) {
        blocked = problem
        busy = sending
        this.listening = listening
        input.isEnabled = !sending
        refreshKeys()
    }

    private fun refreshKeys() {
        val can = AskBarView.canSend(input.text?.toString(), blocked, busy, listening)
        sendKey.isEnabled = can
        sendKey.alpha = if (can) 1f else 0.4f
        sendKey.background = circle(if (can) palette.accent else palette.pressed)
        sendKey.imageTintList = ColorStateList.valueOf(if (can) palette.onAccent else palette.muted)
        mic.background = circle(if (listening) palette.accent else palette.pressed)
        mic.imageTintList = ColorStateList.valueOf(if (listening) palette.onAccent else palette.ink)
        mic.isEnabled = !busy
    }

    private fun circle(color: Int) = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }

    /** Puts [words] in at the cursor (a recording's text), with a space between Latin words. */
    fun insert(words: String) {
        if (words.isEmpty()) return
        val e = input.text ?: return
        val at = input.selectionEnd.coerceIn(0, e.length)
        val before = if (at > 0) e[at - 1] else ' '
        val lead = if (at > 0 && !before.isWhitespace() && before.code < 0x2E80 && words.first().code < 0x2E80) " " else ""
        e.insert(at, lead + words)
    }

    private fun send() {
        val text = input.text?.toString() ?: return
        if (canSend(text, blocked, busy, listening)) listener.onSend(text.trim())
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP) listener.onClose()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_OUTSIDE) {
            listener.onClose()
            return true
        }
        return super.dispatchTouchEvent(event)
    }

    fun measureFor(width: Int): Pair<Int, Int> {
        measure(
            MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        return measuredWidth to measuredHeight
    }

    companion object {
        const val MAX_TEXT = 4_000

        /** Something typed, nothing in the way, nothing on its way, not recording. */
        fun canSend(text: String?, problem: Boolean, sending: Boolean, listening: Boolean): Boolean =
            !text.isNullOrBlank() && !problem && !sending && !listening
    }
}
