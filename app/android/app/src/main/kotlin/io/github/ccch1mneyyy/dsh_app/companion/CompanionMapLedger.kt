package io.github.ccch1mneyyy.dsh_app.companion

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.UUID

internal data class CompanionMapKey(val taskId: String, val revision: Long)
internal data class CompanionMapClaim(val key: CompanionMapKey, val attemptId: String, val executorId: String)
internal data class StoredCompanionMap(
    val key: CompanionMapKey, val current: Boolean, val sourceSessionId: String,
    val operation: String, val executorId: String, val state: String, val waitReason: String?,
    val cancelRequested: Boolean, val argument: CompanionMapArgument,
)

/** Opens the owning store's existing v14 database. No schema or user agreement writes. */
internal class CompanionMapLedger(private val database: SQLiteDatabase) : Closeable {
    private fun <T> transaction(block: () -> T): T {
        database.beginTransactionNonExclusive()
        try {
            val result = block()
            database.setTransactionSuccessful()
            return result
        } finally { database.endTransaction() }
    }

    fun revision(key: CompanionMapKey): StoredCompanionMap? = database.rawQuery(
        "$SELECT WHERE t.kind='phone.map_open' AND r.task_id=? AND r.task_rev=?", args(key),
    ).use { if (it.moveToFirst()) read(it) else null }

    /** Native alone grants a short scope. Old rows are not execution history. */
    fun openScope(scopeId: String, sourceSessionId: String) = transaction {
        database.delete("companion_map_scopes", null, null)
        database.insertOrThrow("companion_map_scopes", null, ContentValues().apply {
            put("scope_id", scopeId); put("source_session_id", sourceSessionId); put("closed", 0)
        })
        Unit
    }

    fun scopeOpen(scopeId: String, sourceSessionId: String): Boolean = database.rawQuery("""
        SELECT 1 FROM companion_map_scopes WHERE scope_id=? AND source_session_id=? AND closed=0
    """.trimIndent(), arrayOf(scopeId, sourceSessionId)).use { it.moveToFirst() }

    private fun possibleEffect(taskId: String): Boolean = database.rawQuery("""
        SELECT 1 FROM companion_task_receipts c
        WHERE c.task_id=? AND c.step_key='map.handoff' AND c.event_kind='claimed'
          AND NOT EXISTS(SELECT 1 FROM companion_task_receipts done
            WHERE done.task_id=c.task_id AND done.task_rev=c.task_rev
              AND done.step_key=c.step_key AND done.attempt_id=c.attempt_id
              AND done.event_kind IN ('returned','failed','blocked','skipped')
              AND done.outcome='not_performed') LIMIT 1
    """.trimIndent(), arrayOf(taskId)).use { it.moveToFirst() }

    private fun pending(claim: CompanionMapClaim): Boolean = database.rawQuery("""
        SELECT 1 FROM companion_task_receipts c
        WHERE c.task_id=? AND c.task_rev=? AND c.step_key='map.handoff'
          AND c.attempt_id=? AND c.executor_id=? AND c.event_kind='claimed'
          AND NOT EXISTS(SELECT 1 FROM companion_task_receipts done
            WHERE done.task_id=c.task_id AND done.task_rev=c.task_rev
              AND done.step_key=c.step_key AND done.attempt_id=c.attempt_id
              AND done.event_kind IN ('returned','failed','blocked','skipped')) LIMIT 1
    """.trimIndent(), arrayOf(claim.key.taskId, claim.key.revision.toString(),
        claim.attemptId, claim.executorId)).use { it.moveToFirst() }

    /** This transaction must commit before any physical handoff may begin. */
    fun claim(key: CompanionMapKey, executorId: String, now: Long,
              guard: (StoredCompanionMap) -> String?): CompanionMapClaim? = transaction {
        val row = revision(key) ?: return@transaction null
        if (!row.current || row.executorId != executorId || row.cancelRequested || row.operation == "cancel" ||
            row.state !in setOf("queued", "waiting") || possibleEffect(key.taskId)) return@transaction null
        val claim = CompanionMapClaim(key, UUID.randomUUID().toString(), executorId)
        val reason = guard(row)
        if (reason != null) {
            receipt(claim, now, row.argument, CompanionMapPlatform.blocked(reason))
            state(key, "waiting", reason, now)
            return@transaction null
        }
        receipt(claim, now, row.argument, null)
        state(key, "unknown", "map_handoff_pending", now)
        claim
    }

    /**
     * A second, short WRITE transaction serializes cancellation with the synchronous system call.
     * There is no suspension, callback, or retry between the final revision gate and launch.
     * If launch happened but this transaction cannot commit, the first claim stays unknown.
     */
    fun dispatch(claim: CompanionMapClaim, now: () -> Long,
                 guard: (StoredCompanionMap) -> String?,
                 launch: (CompanionMapArgument) -> CompanionMapObservation) = transaction {
        val row = revision(claim.key) ?: return@transaction
        if (row.executorId != claim.executorId || !pending(claim)) return@transaction
        val reason = if (!row.current || row.cancelRequested || row.operation == "cancel")
            "map_agreement_changed" else guard(row)
        val observation = if (reason != null) CompanionMapPlatform.blocked(reason)
            else launch(row.argument)
        val atMs = now()
        receipt(claim, atMs, row.argument, observation)
        // An old revision's result never changes current_rev or the new cancellation head.
        state(claim.key, observation.state, observation.reason, atMs)
    }

    private fun state(key: CompanionMapKey, value: String, reason: String?, now: Long) {
        val values = ContentValues().apply {
            put("state", value); put("wait_reason", reason); put("updated_at_ms", now)
        }
        check(database.update("companion_task_revisions", values, "task_id=? AND task_rev=?", args(key)) == 1)
    }

    private fun receipt(claim: CompanionMapClaim, now: Long, argument: CompanionMapArgument,
                        observation: CompanionMapObservation?) {
        val detail = JSONObject().put("uri", CompanionMapAddress.uri(argument.address))
            .put("targetKind", argument.targetKind)
        argument.target?.let { detail.put("target", JSONObject(it.value())) }
        if (observation != null) {
            detail.put("result", observation.result)
            observation.reason?.let { detail.put("reason", it) }
        }
        val values = ContentValues().apply {
            put("task_id", claim.key.taskId); put("task_rev", claim.key.revision)
            put("step_key", "map.handoff"); put("attempt_id", claim.attemptId)
            put("event_kind", observation?.event ?: "claimed"); put("executor_id", claim.executorId)
            put("occurred_at_ms", now); put("effect_id", "map:${claim.key.taskId}:${claim.key.revision}:${claim.attemptId}")
            put("outcome", observation?.outcome); put("detail_json", detail.toString())
        }
        database.insertOrThrow("companion_task_receipts", null, values)
    }

    override fun close() = database.close()

    companion object {
        private const val SELECT = "SELECT r.*,t.current_rev,t.source_session_id,m.address,m.place_name," +
            "m.target_kind,m.package_name,m.component_name,m.package_uid,m.target_label " +
            "FROM companion_tasks t JOIN companion_task_revisions r ON r.task_id=t.task_id " +
            "JOIN companion_map_revisions m ON m.task_id=r.task_id AND m.task_rev=r.task_rev"
        private fun args(key: CompanionMapKey) = arrayOf(key.taskId, key.revision.toString())
        private fun read(cursor: Cursor): StoredCompanionMap {
            fun string(name: String): String? = cursor.getColumnIndexOrThrow(name).let {
                if (cursor.isNull(it)) null else cursor.getString(it)
            }
            fun number(name: String): Long? = cursor.getColumnIndexOrThrow(name).let {
                if (cursor.isNull(it)) null else cursor.getLong(it)
            }
            val revision = number("task_rev")!!
            val kind = string("target_kind")!!
            val target = if (kind == "choice") null else {
                val uid = number("package_uid")!!
                require(uid in 0L..Int.MAX_VALUE.toLong())
                CompanionMapTarget(string("package_name")!!, string("component_name")!!,
                    uid.toInt(), string("target_label"))
            }
            return StoredCompanionMap(CompanionMapKey(string("task_id")!!, revision),
                revision == number("current_rev"), string("source_session_id")!!,
                string("operation")!!, string("executor_id")!!, string("state")!!, string("wait_reason"),
                number("cancel_requested") == 1L, CompanionMapArgument(string("address")!!, kind, target))
        }

        fun open(context: Context): CompanionMapLedger {
            val path = File(context.filesDir, "companion/memory.sqlite")
            val database = SQLiteDatabase.openDatabase(path.path, null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                DatabaseErrorHandler { throw SQLiteDatabaseCorruptException("Existing companion database is corrupt") })
            try {
                check(database.version in 14..16) { "Map schema is not ready" }
                database.setForeignKeyConstraintsEnabled(true)
                val ledger = CompanionMapLedger(database)
                ledger.transaction {
                    database.rawQuery("PRAGMA busy_timeout=1000", null).use { check(it.moveToFirst()) }
                    database.rawQuery("PRAGMA foreign_keys", null).use { check(it.moveToFirst() && it.getInt(0) == 1) }
                }
                return ledger
            } catch (error: Exception) { database.close(); throw error }
        }
    }
}
