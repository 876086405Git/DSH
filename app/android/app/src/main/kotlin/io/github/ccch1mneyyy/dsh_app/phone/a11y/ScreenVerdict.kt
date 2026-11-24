package io.github.ccch1mneyyy.dsh_app.phone.a11y

/**
 * What an action may honestly say about the screen after it.
 *
 * The one rule: **缺少观测依据不等于界面没变**。Empty fingerprints on both sides, or a screen
 * whose content is filtered (see [TreeCapture] `unreadableWindowTitle`), mean "cannot verify" —
 * saying 「没有明显变化」 there makes the model retry an action that already worked, and saying
 * 「可能已经到头了」 after a scroll makes it give up on a list it never reached the end of.
 */
internal object ScreenVerdict {
    const val UNCHANGED = "界面没有明显变化。"
    const val SCROLL_END = "内容没有变化，可能已经到头了。"
    // l10n:keep agent screen result
    const val UNVERIFIABLE = "（动作已提交，但无法验证结果：缺少足够的可读内容，可能受敏感视图策略限制。）"
    // vivo's calculator: its display EditText always reads "" while the digits change on screen.
    // l10n:keep agent screen result
    const val UNSEEN_CHANGE = "（读到的文字没变，但这个应用刚报告了界面更新：有些显示（比如计算器的数字屏）读屏读不到，" +
        "不能据此认为没生效。能截图就截图核对；不能就按计划继续，最后请用户核对。不要直接重复这一步。）"
    const val KEYBOARD_HIDDEN = "键盘已收起。"
    const val KEYBOARD_SHOWN = "键盘已弹出。"

    /**
     * The sentence to append after 「已点击…」/「已返回…」. Empty when the tree changed (or the
     * window insets did) and both screens are readable: the new screen speaks for itself.
     *
     * @param comparable both before and after had readable elements to compare
     * @param changed observed content, app/window identity, bounds or keyboard state differ
     * @param keyboard what happened to the IME, when that is what changed
     * @param scrolled the action was a scroll, so "unchanged" would read as "end of list"
     * @param appReported the front app sent content/text-change events after the action
     */
    fun note(comparable: Boolean, changed: Boolean, keyboard: String?, scrolled: Boolean, appReported: Boolean = false): String = when {
        !comparable -> listOfNotNull(keyboard, UNVERIFIABLE).joinToString("")
        keyboard != null -> keyboard
        changed -> ""
        // A list's rows are in the tree, so a scroll with the same tree did not move it, whatever
        // else (a playing video, a clock) the app redrew meanwhile.
        scrolled -> SCROLL_END
        appReported -> UNSEEN_CHANGE
        else -> UNCHANGED
    }

    /** What the step trace may record: an unseen change is neither "changed" nor "unchanged". */
    fun screenChanged(comparable: Boolean, changed: Boolean, appReported: Boolean): Boolean? = when {
        !comparable -> null
        changed -> true
        appReported -> null
        else -> false
    }
}
