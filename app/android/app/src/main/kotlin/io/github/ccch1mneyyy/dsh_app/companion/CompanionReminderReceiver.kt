package io.github.ccch1mneyyy.dsh_app.companion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Explicit app-only receiver; opened records come only through the private EntryActivity. */
class CompanionReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action !in setOf(ACTION_WAKE, ACTION_ALARM, ACTION_OPENED)) return
        val ordered = isOrderedBroadcast
        val pending = goAsync()
        CompanionReminderWork.executor.execute {
            var processed = false
            try {
                val executorId = CompanionReminderPlatform.executorId(context)
                CompanionReminderLedger.open(context).use { ledger ->
                    val runner = CompanionReminderRunner(ledger, CompanionReminderAndroid(context), executorId)
                    when (action) {
                        ACTION_WAKE -> intent.getStringExtra(EXTRA_TASK)?.let { runner.resume(it); processed = true }
                        ACTION_ALARM -> ReminderKey.parse(intent.data, "alarm")?.let { runner.alarm(it); processed = true }
                        ACTION_OPENED -> ReminderKey.parse(intent.data, "open")?.let {
                            ledger.opened(it, executorId, System.currentTimeMillis()); processed = true
                        }
                    }
                }
            } catch (_: Exception) {
                // Failure to persist a claim never licenses an effect. No missed-alarm replay.
            } finally {
                if (ordered) pending.setResultCode(if (processed) Activity.RESULT_OK else Activity.RESULT_CANCELED)
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION_WAKE = "io.github.ccch1mneyyy.dsh_app.companion.REMINDER_WAKE"
        const val ACTION_ALARM = "io.github.ccch1mneyyy.dsh_app.companion.REMINDER_ALARM"
        const val ACTION_OPENED = "io.github.ccch1mneyyy.dsh_app.companion.REMINDER_OPENED"
        const val EXTRA_TASK = "taskId"
    }
}
