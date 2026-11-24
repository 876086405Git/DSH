package io.github.ccch1mneyyy.dsh_app.companion

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.net.Uri
import java.io.Closeable
import java.io.File
import java.util.UUID

internal data class ReminderKey(val taskId: String, val revision: Long) {
    fun uri(kind: String): Uri = Uri.Builder().scheme("dsh-reminder").authority(kind)
        .appendPath(taskId).appendPath(revision.toString()).build()

    val notificationTag: String get() = "dsh-reminder:$taskId:$revision"

    companion object {
        fun parse(uri: Uri?, kind: String): ReminderKey? {
            if (uri == null || uri.scheme != "dsh-reminder" || uri.authority != kind || uri.pathSegments.size != 2) return null
            val id = uri.pathSegments[0]
            val revision = uri.pathSegments[1].toLongOrNull() ?: return null
            return if (id.isNotEmpty() && revision > 0) ReminderKey(id, revision) else null
        }
    }
}

internal data class StoredReminder(
    val key: ReminderKey,
    val current: Boolean,
    val operation: String,
    val executorId: String,
    val text: String?,
    val localDate: String?,
    val localTime: String?,
    val zoneId: String?,
    val offsetSeconds: Int?,
    val epochMs: Long?,
    val state: String,
    val waitReason: String?,
    val cancelRequested: Boolean,
    val notificationClaim: String?,
)

/** 仅 :companion_reminder 进程使用平台 SQLite；没有 schema 或任务约定写入。 */
internal class CompanionReminderLedger(private val database: SQLiteDatabase) : Closeable {
    fun <T> transaction(block: () -> T): T {
        database.beginTransactionNonExclusive()
        try {
            val result = block()
            database.setTransactionSuccessful()
            return result
        } finally {
            database.endTransaction()
        }
    }

    fun current(taskId: String): StoredReminder? = database.rawQuery(
        "$SELECT WHERE t.task_id=? AND r.task_rev=t.current_rev AND t.kind='phone.reminder'", arrayOf(taskId),
    ).use { if (it.moveToFirst()) read(it) else null }

    fun revision(key: ReminderKey): StoredReminder? = database.rawQuery(
        "$SELECT WHERE r.task_id=? AND r.task_rev=? AND t.kind='phone.reminder'", args(key),
    ).use { if (it.moveToFirst()) read(it) else null }

    fun recoveryBatch(executorId: String, now: Long, afterTaskId: String, limit: Int): List<String> =
        database.rawQuery("""
            SELECT t.task_id FROM companion_tasks t JOIN companion_task_revisions r
              ON r.task_id=t.task_id AND r.task_rev=t.current_rev
            WHERE t.kind='phone.reminder' AND r.executor_id=? AND t.task_id>?
              AND ((r.operation='cancel' AND r.state!='cancelled') OR
                   (r.operation='amend' AND r.epoch_ms IS NULL AND EXISTS(
                     SELECT 1 FROM companion_task_receipts old WHERE old.task_id=t.task_id
                       AND old.task_rev<r.task_rev AND old.step_key='alarm.register' AND old.event_kind='claimed')) OR
                   (r.operation!='cancel' AND r.epoch_ms>? AND r.cancel_requested=0
                    AND r.notification_claim_id IS NULL AND r.state!='failed'))
            ORDER BY t.task_id LIMIT ?
        """.trimIndent(), arrayOf(executorId, afterTaskId, now.toString(), limit.toString())).use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
        }

    fun oldSchedules(key: ReminderKey, limit: Int): List<ReminderKey> = database.rawQuery("""
        SELECT DISTINCT old.task_rev FROM companion_task_receipts old
        WHERE old.task_id=? AND old.task_rev<? AND old.step_key='alarm.register' AND old.event_kind='claimed'
          AND NOT EXISTS(SELECT 1 FROM companion_task_receipts stopped
            WHERE stopped.task_id=old.task_id AND stopped.task_rev>old.task_rev
              AND stopped.step_key='alarm.cancel:'||old.task_rev
              AND stopped.event_kind='returned' AND stopped.outcome='succeeded')
        ORDER BY old.task_rev LIMIT ?
    """.trimIndent(), arrayOf(key.taskId, key.revision.toString(), limit.toString())).use { cursor ->
        buildList { while (cursor.moveToNext()) add(ReminderKey(key.taskId, cursor.getLong(0))) }
    }

    fun hasRegistrationClaim(key: ReminderKey): Boolean = database.rawQuery("""
        SELECT 1 FROM companion_task_receipts
        WHERE task_id=? AND task_rev=? AND step_key='alarm.register' AND event_kind='claimed' LIMIT 1
    """.trimIndent(), args(key)).use { it.moveToFirst() }

    fun isCurrent(key: ReminderKey, executorId: String): Boolean = revision(key)?.let {
        it.current && it.executorId == executorId
    } == true

    fun accepted(key: ReminderKey, executorId: String, now: Long): Boolean = transaction {
        val row = revision(key) ?: return@transaction false
        if (!row.current || row.executorId != executorId) return@transaction false
        receipt(key, "executor", UUID.randomUUID().toString(), "accepted", executorId, now)
        if (row.state == "queued" || row.state == "waiting") state(key, "running", null, now)
        true
    }

    /** The committed claim, not a RAM flag, is the possible-effect boundary. */
    fun claimEffect(key: ReminderKey, step: String, attempt: String, effectId: String,
                    executorId: String, now: Long): Boolean = transaction {
        val row = revision(key) ?: return@transaction false
        if (!row.current || row.executorId != executorId) return@transaction false
        if (step == "alarm.register" && (row.cancelRequested || row.operation == "cancel" ||
                row.notificationClaim != null || row.epochMs == null || row.epochMs <= now)) return@transaction false
        receipt(key, step, attempt, "claimed", executorId, now, effectId = effectId)
        state(key, "unknown", null, now)
        true
    }

    fun effectResult(key: ReminderKey, step: String, attempt: String, effectId: String,
                     executorId: String, now: Long, error: Exception? = null,
                     completedState: String? = null, completedReason: String? = null) = transaction {
        receipt(key, step, attempt, if (error == null) "returned" else "failed", executorId, now,
            effectId, if (error == null) "succeeded" else "unknown",
            error?.let { org.json.JSONObject().put("errorClass", it.javaClass.simpleName).toString() })
        if (error != null) state(key, "unknown", "system_call_failed", now)
        else if (completedState != null) state(key, completedState, completedReason, now)
    }

    fun skippedEffect(key: ReminderKey, step: String, attempt: String, effectId: String,
                      executorId: String, now: Long, reason: String) = transaction {
        receipt(key, step, attempt, "skipped", executorId, now, effectId, "not_performed",
            org.json.JSONObject().put("reason", reason).toString())
    }

    fun blocked(key: ReminderKey, executorId: String, now: Long, reason: String) = transaction {
        val row = revision(key) ?: return@transaction
        if (!row.current || row.executorId != executorId) return@transaction
        receipt(key, "executor", UUID.randomUUID().toString(), "blocked", executorId, now,
            outcome = "not_performed", detail = org.json.JSONObject().put("reason", reason).toString())
        state(key, if (row.state == "unknown") "unknown" else "failed", reason, now)
    }

    fun finishWithoutEffect(key: ReminderKey, executorId: String, now: Long, result: String,
                            reason: String? = null) = transaction {
        if (isCurrent(key, executorId)) state(key, result, reason, now)
    }

    fun received(key: ReminderKey, executorId: String, now: Long) = transaction {
        val row = revision(key) ?: return@transaction
        if (row.executorId != executorId) return@transaction
        receipt(key, "notification", UUID.randomUUID().toString(), "received", executorId, now,
            effectId = key.notificationTag)
    }

    fun claimNotification(key: ReminderKey, executorId: String, now: Long): String? = transaction {
        val row = revision(key) ?: return@transaction null
        if (!row.current || row.executorId != executorId || row.cancelRequested || row.operation == "cancel" ||
            row.epochMs == null || row.epochMs > now || row.notificationClaim != null || !hasRegistrationClaim(key)) return@transaction null
        val claim = UUID.randomUUID().toString()
        val values = ContentValues().apply {
            put("notification_claim_id", claim)
            put("notification_claimed_at_ms", now)
            put("updated_at_ms", now)
        }
        check(database.update("companion_task_revisions", values,
            "task_id=? AND task_rev=? AND notification_claim_id IS NULL", args(key)) == 1)
        receipt(key, "notification", claim, "claimed", executorId, now, effectId = key.notificationTag)
        // Delivery progress does not change the separate registration result.
        claim
    }

    fun notificationResult(key: ReminderKey, claim: String, executorId: String, now: Long,
                           event: String, outcome: String?, reason: String? = null) = transaction {
        receipt(key, "notification", claim, event, executorId, now, key.notificationTag, outcome,
            reason?.let { org.json.JSONObject().put("reason", it).toString() })
        // It rang, so a set reminder's "notifications are off" no longer holds.
        if (outcome == "succeeded") {
            database.update("companion_task_revisions", ContentValues().apply {
                putNull("wait_reason")
                put("updated_at_ms", now)
            }, "task_id=? AND task_rev=? AND state='done'", args(key))
        }
    }

    fun activeObserved(key: ReminderKey, executorId: String, now: Long) = transaction {
        val row = revision(key) ?: return@transaction
        if (row.executorId != executorId || row.notificationClaim == null) return@transaction
        receipt(key, "notification", UUID.randomUUID().toString(), "active_observed", executorId, now,
            effectId = key.notificationTag)
    }

    fun opened(key: ReminderKey, executorId: String, now: Long) = transaction {
        val row = revision(key) ?: return@transaction
        val claim = row.notificationClaim ?: return@transaction
        if (row.executorId != executorId) return@transaction
        val already = database.rawQuery("""
            SELECT 1 FROM companion_task_receipts WHERE task_id=? AND task_rev=?
              AND step_key='notification' AND attempt_id=? AND event_kind='opened'
        """.trimIndent(), arrayOf(key.taskId, key.revision.toString(), claim)).use { it.moveToFirst() }
        if (!already) receipt(key, "notification", claim, "opened", executorId, now, effectId = key.notificationTag)
    }

    private fun state(key: ReminderKey, state: String, reason: String?, now: Long) {
        val values = ContentValues().apply {
            put("state", state)
            put("wait_reason", reason)
            put("updated_at_ms", now)
        }
        database.update("companion_task_revisions", values, "task_id=? AND task_rev=?", args(key))
    }

    private fun receipt(key: ReminderKey, step: String, attempt: String, event: String,
                        executorId: String, now: Long, effectId: String? = null,
                        outcome: String? = null, detail: String? = null) {
        val values = ContentValues().apply {
            put("task_id", key.taskId)
            put("task_rev", key.revision)
            put("step_key", step)
            put("attempt_id", attempt)
            put("event_kind", event)
            put("executor_id", executorId)
            put("occurred_at_ms", now)
            put("effect_id", effectId)
            put("outcome", outcome)
            put("detail_json", detail)
        }
        database.insertOrThrow("companion_task_receipts", null, values)
    }

    override fun close() = database.close()

    companion object {
        private const val SELECT = "SELECT r.*,t.current_rev FROM companion_task_revisions r JOIN companion_tasks t ON t.task_id=r.task_id"
        private fun args(key: ReminderKey): Array<String> = arrayOf(key.taskId, key.revision.toString())
        private fun read(cursor: Cursor): StoredReminder {
            fun string(name: String): String? = cursor.getColumnIndexOrThrow(name).let { if (cursor.isNull(it)) null else cursor.getString(it) }
            fun number(name: String): Long? = cursor.getColumnIndexOrThrow(name).let { if (cursor.isNull(it)) null else cursor.getLong(it) }
            val revision = number("task_rev")!!
            return StoredReminder(ReminderKey(string("task_id")!!, revision), revision == number("current_rev"),
                string("operation")!!, string("executor_id")!!, string("reminder_text"), string("local_date"),
                string("local_time"), string("zone_id"), number("offset_seconds")?.toInt(), number("epoch_ms"),
                string("state")!!, string("wait_reason"), number("cancel_requested") == 1L, string("notification_claim_id"))
        }

        fun open(context: Context): CompanionReminderLedger {
            val path = File(context.filesDir, "companion/memory.sqlite")
            val database = SQLiteDatabase.openDatabase(path.path, null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                DatabaseErrorHandler { throw SQLiteDatabaseCorruptException("Existing companion database is corrupt") })
            try {
                check(database.version in 11..17) { "Reminder schema is not ready" }
                database.setForeignKeyConstraintsEnabled(true)
                val ledger = CompanionReminderLedger(database)
                // Configure the primary writer connection; the first Android open/lock
                // still uses the platform's own timeout and may fail without a claim.
                ledger.transaction {
                    database.rawQuery("PRAGMA busy_timeout=1000", null).use { check(it.moveToFirst()) }
                    database.rawQuery("PRAGMA foreign_keys", null).use { check(it.moveToFirst() && it.getInt(0) == 1) }
                }
                return ledger
            } catch (error: Exception) {
                database.close()
                throw error
            }
        }
    }
}
