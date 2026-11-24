package io.github.ccch1mneyyy.dsh_app.companion

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneOffset
import java.util.UUID

/** The only replaceable boundary in native behavior tests is the system effect. */
internal interface CompanionReminderEffects {
    fun capabilities(): Map<String, Any>
    fun register(key: ReminderKey, epochMs: Long)
    fun cancel(key: ReminderKey)
    fun notify(reminder: StoredReminder)
    fun isActive(key: ReminderKey): Boolean
}

/** Called serially in :companion_reminder; SQLite is never held across an effect. */
internal class CompanionReminderRunner(
    private val ledger: CompanionReminderLedger,
    private val effects: CompanionReminderEffects,
    private val executorId: String,
    private val now: () -> Long = System::currentTimeMillis,
) {
    // false means a bounded cancellation batch has more work for the native Job.
    fun resume(taskId: String, maxEffects: Int = 2): Boolean {
        val initial = ledger.current(taskId) ?: return true
        if (initial.executorId != executorId) return true // Do not adopt a restored task.
        if (initial.operation == "cancel" && initial.state == "cancelled") return true
        if (initial.notificationClaim != null) {
            observeActive(initial.key)
            return true // An uncertain prior notification is never retried.
        }
        if (initial.state == "done" && initial.epochMs != null && initial.epochMs <= now()) {
            return true // A past registration success is not a new failed registration.
        }
        val key = initial.key
        if (!ledger.accepted(key, executorId, now())) return true
        val oldSchedules = ledger.oldSchedules(key, maxEffects + 1)
        for (old in oldSchedules.take(maxEffects)) {
            if (!call(key, "alarm.cancel:${old.revision}", old.uri("alarm").toString(), completedState = "running") {
                effects.cancel(old)
            }) return true
        }
        if (oldSchedules.size > maxEffects) return false
        val row = ledger.current(taskId) ?: return true
        if (row.key != key) return true
        if (row.operation == "cancel" || row.cancelRequested) {
            ledger.finishWithoutEffect(key, executorId, now(), "cancelled")
            return true
        }
        if (row.epochMs == null || row.offsetSeconds == null || row.localDate == null ||
            row.localTime == null || row.zoneId == null || row.text.isNullOrBlank()) {
            ledger.finishWithoutEffect(key, executorId, now(), "waiting", initial.waitReason ?: "invalid_time")
            return true
        }
        if (!validInstant(row)) {
            ledger.blocked(key, executorId, now(), "invalid_time")
            return true
        }
        if (row.epochMs <= now()) {
            ledger.blocked(key, executorId, now(), "time_passed")
            return true // Recovery does not replay a missed notification.
        }
        if (oldSchedules.size == maxEffects) return false
        // Notifications only matter when it rings, so it is set either way and
        // turning them on any time before then is enough. The reason stays on
        // the set reminder for her to mention until a later run sees them on.
        call(key, "alarm.register", key.uri("alarm").toString(), completedState = "done",
            completedReason = capabilityReason(effects.capabilities())) {
            effects.register(key, row.epochMs)
        }
        return true
    }

    private fun call(key: ReminderKey, step: String, effectId: String, completedState: String? = null,
                     completedReason: String? = null, effect: () -> Unit): Boolean {
        val attempt = UUID.randomUUID().toString()
        if (!ledger.claimEffect(key, step, attempt, effectId, executorId, now())) return false
        val row = ledger.revision(key)
        val stale = row == null || !row.current || row.executorId != executorId
        val epoch = row?.epochMs
        val expired = step == "alarm.register" && (epoch == null || epoch <= now())
        val cancelled = step == "alarm.register" && (row?.cancelRequested == true ||
            row?.operation == "cancel" || row?.notificationClaim != null)
        if (stale || expired || cancelled) {
            ledger.skippedEffect(key, step, attempt, effectId, executorId, now(),
                if (expired) "time_passed" else "revision_changed")
            return false
        }
        val error = try { effect(); null } catch (error: Exception) { error }
        // If this transaction fails after the API, the committed claim stays unknown.
        ledger.effectResult(key, step, attempt, effectId, executorId, now(), error, completedState, completedReason)
        return error == null
    }

    fun alarm(key: ReminderKey) {
        ledger.received(key, executorId, now())
        val row = ledger.revision(key) ?: return
        if (!row.current || row.executorId != executorId || row.cancelRequested || row.operation == "cancel") return
        if (row.notificationClaim != null) { observeActive(key); return }
        if (!validInstant(row) || row.epochMs!! > now() || row.text.isNullOrBlank()) return
        val reason = capabilityReason(effects.capabilities())
        if (reason != null) {
            ledger.notificationResult(key, UUID.randomUUID().toString(), executorId, now(),
                "blocked", "not_performed", reason)
            return
        }
        val claim = ledger.claimNotification(key, executorId, now()) ?: return
        val current = ledger.revision(key)
        if (current == null || !current.current || current.executorId != executorId ||
            current.cancelRequested || current.operation == "cancel") {
            ledger.notificationResult(key, claim, executorId, now(), "skipped", "not_performed", "revision_changed")
            return
        }
        val error = try { effects.notify(current); null } catch (error: Exception) { error }
        ledger.notificationResult(key, claim, executorId, now(),
            if (error == null) "returned" else "failed",
            if (error == null) "succeeded" else "unknown", error?.javaClass?.simpleName)
        if (error == null) observeActive(key)
    }

    private fun observeActive(key: ReminderKey) {
        // Absence or a failed query cannot establish that an old notification never appeared.
        val active = try { effects.isActive(key) } catch (_: Exception) { false }
        if (active) ledger.activeObserved(key, executorId, now())
    }

    companion object {
        internal fun validInstant(row: StoredReminder): Boolean = try {
            row.epochMs != null && row.offsetSeconds != null && row.zoneId != null &&
                LocalDate.parse(row.localDate).atTime(LocalTime.parse(row.localTime))
                    .toInstant(ZoneOffset.ofTotalSeconds(row.offsetSeconds)).toEpochMilli() == row.epochMs
        } catch (_: Exception) { false }

        private fun capabilityReason(values: Map<String, Any>): String? = when {
            values["appNotifications"] != true -> "notifications_disabled"
            values["channelNotifications"] != true -> "notification_channel_disabled"
            values["groupNotifications"] != true -> "notification_group_disabled"
            else -> null
        }
    }
}
