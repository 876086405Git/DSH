package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import io.github.ccch1mneyyy.dsh_app.phone.PhoneScreen
import io.github.ccch1mneyyy.dsh_app.phone.PhoneTasks
import io.github.ccch1mneyyy.dsh_app.phone.SafetyRules
import io.github.ccch1mneyyy.dsh_app.phone.TargetInfo

/** Bounded, process-local facts. No action arguments, screen text, images or Throwable are retained. */
class PhoneTaskTrace {
    data class OwnerKey(val taskId: Long, val lifecycle: Long)
    enum class Action { OPEN_APP, TAP, TAP_XY, LONG_TAP, TYPE, TYPE_SUBMIT, SCROLL_UP, SCROLL_DOWN, SCROLL_LEFT, SCROLL_RIGHT,
        KEY_BACK, KEY_HOME, KEY_RECENTS, KEY_NOTIFICATIONS }
    enum class Role { BUTTON, INPUT, TAB, LIST, SWITCH, UNKNOWN }
    enum class Anchor { SEARCH, NEXT, BACK, CANCEL, CONFIRM, SAVE, SEND, SUBMIT, DELETE }
    /** CALLED means crossing Core's driver/system boundary, not proof input reached the app. */
    enum class Receipt { CALLED, RETURNED_OK, RETURNED_ERROR, STALE_REJECTED, UNCERTAIN }
    enum class Gap { UNSUPPORTED_EFFECT, SECRET_TARGET, LIMIT, UNCERTAIN_RESULT }
    data class Step internal constructor(
        val action: Action, val screen: PhoneScreen, val role: Role, val anchor: Anchor?,
        val receipt: Receipt = Receipt.CALLED, val postObservationAvailable: Boolean = false,
        internal val navigation: PhoneSkillNavigationWitness? = null,
        val packageName: String? = null, val screenChanged: Boolean? = null,
    )
    data class Snapshot internal constructor(
        val owner: OwnerKey, val steps: List<Step>, val ended: Boolean, val eligible: Boolean, val gap: Gap?,
        val userIntervened: Boolean = false, val confirmationUnresolved: Boolean = false,
    ) {
        val canDraft: Boolean get() = ended && eligible && gap == null && steps.isNotEmpty() &&
            steps.all { it.receipt == Receipt.RETURNED_OK && it.action != Action.TAP_XY } && !userIntervened

        /** Three accepted driver calls. Business success is reported separately by run completion. */
        val canLearn: Boolean get() = ended && eligible && !userIntervened && !confirmationUnresolved && gap == null &&
            steps.count { it.receipt == Receipt.RETURNED_OK } >= 3
    }
    class Ticket internal constructor(internal val owner: OwnerKey, internal val serial: Long, internal val index: Int)
    private class Entry(val serial: Long) {
        val steps = ArrayList<Step>()
        var ended = false
        var eligible = false
        var gap: Gap? = null
        var userIntervened = false
        var confirmationUnresolved = false
    }
    private val entries = LinkedHashMap<OwnerKey, Entry>()
    private var serial = 0L

    /** Call only for a genuinely new task; evicted/discarded owners must not be recreated on each tool call. */
    @Synchronized fun start(owner: PhoneTasks.Owner) {
        if (!owner.active) return
        val key = key(owner)
        if (key in entries) return
        if (entries.size >= MAX_TASKS) {
            val old = entries.entries.firstOrNull { it.value.ended }?.key ?: return
            entries.remove(old)
        }
        if (reservedBytes() + TASK_BYTES > MAX_BYTES) return
        entries[key] = Entry(++serial)
    }

    @Synchronized fun beginAction(owner: PhoneTasks.Owner, action: PhoneAction, target: TargetInfo?,
                                  packageName: String? = target?.packageName): Ticket? {
        if (target != null && (target.label.length > 256 || target.role.length > 256 || (target.viewId?.length ?: 0) > 256)) {
            markIncomplete(owner, Gap.LIMIT)
            return null
        }
        if (SafetyRules.isSecretTarget(target)) {
            markIncomplete(owner, Gap.SECRET_TARGET)
            return null
        }
        val kind = when (action) {
            is PhoneAction.Tap -> if (action.long) Action.LONG_TAP else Action.TAP
            is PhoneAction.Type -> if (action.submit) Action.TYPE_SUBMIT else Action.TYPE // Never read action.text.
            is PhoneAction.Scroll -> when (action.direction) {
                PhoneAction.Direction.UP -> Action.SCROLL_UP
                PhoneAction.Direction.DOWN -> Action.SCROLL_DOWN
                PhoneAction.Direction.LEFT -> Action.SCROLL_LEFT
                PhoneAction.Direction.RIGHT -> Action.SCROLL_RIGHT
            }
            is PhoneAction.Key -> when (action.key) {
                PhoneAction.GlobalKey.BACK -> Action.KEY_BACK
                PhoneAction.GlobalKey.HOME -> Action.KEY_HOME
                PhoneAction.GlobalKey.RECENTS -> Action.KEY_RECENTS
                PhoneAction.GlobalKey.NOTIFICATIONS -> Action.KEY_NOTIFICATIONS
            }
            is PhoneAction.TapXY -> Action.TAP_XY
        }
        val screen = PhoneScreen.ofScreenId(action.screenId) ?: run {
            markIncomplete(owner, Gap.UNSUPPORTED_EFFECT); return null
        }
        val pkg = safePackage(packageName)
        if (kind == Action.TAP_XY) return append(owner, Step(kind, screen, Role.UNKNOWN, null, packageName = pkg))
        val role = when (target?.role) {
            "按钮" -> Role.BUTTON
            "输入框" -> Role.INPUT
            "标签" -> Role.TAB
            "列表" -> Role.LIST
            "开关" -> Role.SWITCH
            else -> Role.UNKNOWN
        }
        // Even a short contact name is private. Only exact public action words on structural controls qualify.
        val anchor = if ((role == Role.BUTTON || role == Role.TAB) && target != null) {
            when (target.label) {
                "搜索", "Search" -> Anchor.SEARCH
                "下一步", "Next" -> Anchor.NEXT
                "返回", "Back" -> Anchor.BACK
                "取消", "Cancel" -> Anchor.CANCEL
                "确认", "Confirm" -> Anchor.CONFIRM
                "保存", "Save" -> Anchor.SAVE
                "发送", "Send" -> Anchor.SEND
                "提交", "Submit" -> Anchor.SUBMIT
                "删除", "Delete" -> Anchor.DELETE
                else -> null
            }
        } else null
        return append(owner, Step(kind, screen, role, anchor, packageName = pkg))
    }

    @Synchronized fun beginOpen(owner: PhoneTasks.Owner, screen: PhoneScreen, packageName: String? = null): Ticket? =
        append(owner, Step(Action.OPEN_APP, screen, Role.UNKNOWN, null, packageName = safePackage(packageName)))

    private fun append(owner: PhoneTasks.Owner, step: Step): Ticket? {
        val key = key(owner)
        val entry = entries[key] ?: return null
        if (entry.ended || entry.gap != null) return null
        if (entry.steps.size >= MAX_STEPS || reservedBytes() + STEP_BYTES + (step.packageName?.length ?: 0) > MAX_BYTES) {
            entry.gap = Gap.LIMIT
            return null
        }
        entry.steps += step
        return Ticket(key, entry.serial, entry.steps.lastIndex)
    }

    @Synchronized fun finish(ticket: Ticket?, ok: Boolean, staleRejected: Boolean, postObservationAvailable: Boolean,
                             navigation: PhoneSkillNavigationWitness? = null, screenChanged: Boolean? = null) {
        val entry = pending(ticket) ?: return
        val t = ticket!!
        val receipt = when { !ok && staleRejected -> Receipt.STALE_REJECTED; ok -> Receipt.RETURNED_OK; else -> Receipt.RETURNED_ERROR }
        val step = entry.steps[t.index]
        val qualified = navigation?.takeIf { ok && !staleRejected && postObservationAvailable &&
            step.action == Action.TAP && step.screen == PhoneScreen.MAIN }
        val retained = if (qualified != null && reservedBytes() + NAVIGATION_BYTES > MAX_BYTES) {
            entry.gap = entry.gap ?: Gap.LIMIT
            null
        } else qualified
        entry.steps[t.index] = step.copy(receipt = receipt, postObservationAvailable = postObservationAvailable,
            navigation = retained, screenChanged = screenChanged.takeIf { postObservationAvailable })
    }

    @Synchronized fun fail(ticket: Ticket?) {
        val entry = pending(ticket) ?: return
        entry.steps[ticket!!.index] = entry.steps[ticket.index].copy(receipt = Receipt.UNCERTAIN)
        entry.gap = entry.gap ?: Gap.UNCERTAIN_RESULT
    }

    private fun pending(ticket: Ticket?): Entry? {
        if (ticket == null) return null
        val entry = entries[ticket.owner] ?: return null
        return entry.takeIf { !it.ended && it.serial == ticket.serial && it.steps.getOrNull(ticket.index)?.receipt == Receipt.CALLED }
    }

    @Synchronized fun markIncomplete(owner: PhoneTasks.Owner, gap: Gap = Gap.UNSUPPORTED_EFFECT) {
        entries[key(owner)]?.takeIf { !it.ended }?.let { it.gap = it.gap ?: gap }
    }

    @Synchronized fun userIntervened(owner: PhoneTasks.Owner) {
        entries[key(owner)]?.takeUnless { it.ended }?.userIntervened = true
    }

    @Synchronized fun confirmationUnresolved(owner: PhoneTasks.Owner) {
        entries[key(owner)]?.takeUnless { it.ended }?.confirmationUnresolved = true
    }

    /** Pass the ORIGINAL active owner captured before finishScope increments lifecycle, never its inactive return value. */
    @Synchronized fun complete(owner: PhoneTasks.Owner, eligible: Boolean) {
        val entry = entries[key(owner)] ?: return
        if (entry.ended) return
        entry.ended = true
        entry.eligible = eligible
        if (entry.steps.any { it.receipt == Receipt.CALLED }) entry.gap = entry.gap ?: Gap.UNCERTAIN_RESULT
    }

    @Synchronized fun snapshot(owner: PhoneTasks.Owner): Snapshot? = snapshot(key(owner))
    @Synchronized fun snapshot(owner: OwnerKey): Snapshot? = entries[owner]?.let {
        Snapshot(owner, it.steps.toList(), it.ended, it.eligible, it.gap, it.userIntervened, it.confirmationUnresolved)
    }
    @Synchronized fun discard(owner: OwnerKey) { entries.remove(owner) }
    @Synchronized fun clear() { entries.clear() }
    @Synchronized fun reservedBytes(): Int = entries.values.sumOf { entry ->
        TASK_BYTES + entry.steps.sumOf { step ->
            STEP_BYTES + (step.packageName?.length ?: 0) + (if (step.navigation != null) NAVIGATION_BYTES else 0)
        }
    }

    companion object {
        internal fun safePackage(value: String?): String? = value?.takeIf { it.length <= 255 && PACKAGE.matches(it) }
        private val PACKAGE = Regex("[A-Za-z][A-Za-z0-9_]*(?:[.][A-Za-z][A-Za-z0-9_]*)+|android")
        const val MAX_TASKS = 8
        const val MAX_STEPS = 60
        const val MAX_BYTES = 32 * 1024
        // Conservative UTF-8 summary reservation, not a JVM heap measurement. Fixed enums/bools plus separately reserved bounded native navigation identity.
        private const val TASK_BYTES = 256
        private const val STEP_BYTES = 256
        private const val NAVIGATION_BYTES = 512
        fun key(owner: PhoneTasks.Owner) = OwnerKey(owner.taskId, owner.lifecycle)
    }
}
