package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.content.ContextWrapper
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.test.AndroidTestCase
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Real Android SQLite and production ledger; only the physical launch callback is controlled. */
@Suppress("DEPRECATION")
class CompanionMapLedgerTest : AndroidTestCase() {
    private lateinit var f: Fixture

    override fun setUp() { super.setUp(); f = Fixture(context) }
    override fun tearDown() { try { f.close() } finally { super.tearDown() } }

    fun testClaimCommitsUnknownBeforeLaunchAndReturnedReceiptOnlyMeansHandoff() {
        f.revision(1)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        assertEquals("unknown", f.ledger.revision(KEY)!!.state)
        var launches = 0
        f.ledger.dispatch(claim, { NOW + 1 }, { null }) { argument ->
            // f.sql is a separate platform connection: the first transaction
            // must already have committed before this callback is entered.
            assertEquals(1L, f.count("event_kind='claimed'"))
            assertEquals(ADDRESS, argument.address)
            assertEquals("selected", argument.targetKind)
            val target = checkNotNull(argument.target)
            assertEquals("example.maps", target.packageName)
            assertEquals(10234, target.uid)
            launches++
            DISPATCHED
        }
        assertEquals(1, launches)
        assertEquals("done", f.ledger.revision(KEY)!!.state)
        assertEquals(1L, f.count("event_kind='returned' AND outcome='succeeded'"))
        val detail = f.lastDetail()
        assertEquals("handoff_dispatched", detail.getString("result"))
        assertEquals(CompanionMapAddress.uri(ADDRESS), detail.getString("uri"))
        assertFalse(detail.has("displayed"))
        assertNull(f.ledger.claim(KEY, EXECUTOR, NOW + 2) { null })
        f.ledger.dispatch(claim, { NOW + 3 }, { null }) { launches++; DISPATCHED }
        assertEquals(1, launches)
    }

    fun testCancellationCommittedAfterClaimPreventsTheOldStart() {
        f.revision(1)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        f.revision(2, cancelled = true)
        var launches = 0
        f.ledger.dispatch(claim, { NOW + 1 }, { null }) { launches++; DISPATCHED }
        assertEquals(0, launches)
        assertEquals("cancelled", f.ledger.revision(CompanionMapKey("t", 2))!!.state)
        assertEquals(2L, f.currentRevision())
        assertEquals(1L, f.count("task_rev=1 AND event_kind='blocked' AND outcome='not_performed'"))
        assertEquals("map_agreement_changed", f.lastDetail().getString("reason"))
        assertNull(f.ledger.claim(CompanionMapKey("t", 2), EXECUTOR, NOW + 2) { null })
    }

    fun testDispatchWriteTransactionOrdersAConcurrentCancellationAfterItsOldEffect() {
        f.revision(1)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        val inLaunch = CountDownLatch(1)
        val returnLaunch = CountDownLatch(1)
        val cancelEntered = CountDownLatch(1)
        val cancelCommitted = CountDownLatch(1)
        val failures = AtomicReference<Throwable?>()
        val launches = AtomicInteger()
        val dispatcher = thread(name = "map-dispatch-test", isDaemon = true) {
            try {
                f.ledger.dispatch(claim, { NOW + 1 }, { null }) {
                    launches.incrementAndGet()
                    inLaunch.countDown()
                    check(returnLaunch.await(5, TimeUnit.SECONDS)) { "Test did not release launch" }
                    DISPATCHED
                }
            } catch (error: Throwable) { failures.compareAndSet(null, error) }
        }
        var canceller: Thread? = null
        try {
            assertTrue("Dispatch did not enter its final write transaction", inLaunch.await(5, TimeUnit.SECONDS))
            canceller = thread(name = "map-cancel-test", isDaemon = true) {
                try {
                    cancelEntered.countDown()
                    // This is the second real SQLite connection, using the
                    // SDK's BEGIN IMMEDIATE-equivalent write transaction.
                    f.revision(2, cancelled = true)
                    cancelCommitted.countDown()
                } catch (error: Throwable) { failures.compareAndSet(null, error) }
            }
            assertTrue(cancelEntered.await(5, TimeUnit.SECONDS))
            assertFalse("Cancel committed through an active dispatch write lock",
                cancelCommitted.await(150, TimeUnit.MILLISECONDS))
        } finally {
            // Never wait for the cancelling writer while still holding the
            // launch barrier. Both joins are bounded, including failed asserts.
            returnLaunch.countDown()
            dispatcher.join(5_000)
            canceller?.join(5_000)
        }
        assertFalse("Dispatch thread did not drain", dispatcher.isAlive)
        assertFalse("Cancel thread did not drain", canceller?.isAlive == true)
        failures.get()?.let { throw it }
        assertEquals(0L, cancelCommitted.count)
        assertEquals(1, launches.get())
        assertEquals("done", f.ledger.revision(KEY)!!.state)
        assertEquals("cancelled", f.ledger.revision(CompanionMapKey("t", 2))!!.state)
        assertEquals(2L, f.currentRevision())
        assertEquals(1L, f.count("task_rev=1 AND event_kind='returned' AND outcome='succeeded'"))
    }

    fun testChooserReturnRemainsWaitingAndCannotBeReopenedByTheSameTask() {
        f.revision(1, choice = true)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        var launches = 0
        f.ledger.dispatch(claim, { NOW + 1 }, { null }) { argument ->
            assertEquals("choice", argument.targetKind)
            assertNull(argument.target)
            launches++
            CompanionMapObservation("chooser_shown", "waiting", "returned", "unknown", "map_target_choice")
        }
        f.reopen()
        assertEquals("waiting", f.ledger.revision(KEY)!!.state)
        assertEquals("map_target_choice", f.ledger.revision(KEY)!!.waitReason)
        assertNull(f.ledger.claim(KEY, EXECUTOR, NOW + 2) { null })
        f.ledger.dispatch(claim, { NOW + 3 }, { null }) { launches++; DISPATCHED }
        assertEquals(1, launches)
        assertEquals(1L, f.count("event_kind='claimed'"))
        assertEquals(1L, f.count("event_kind='returned' AND outcome='unknown'"))
        assertEquals("chooser_shown", f.lastDetail().getString("result"))
    }

    fun testLaunchThenFailedReceiptLeavesUnknownAndFreshEntryCannotClaimAgain() {
        f.revision(1)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        f.sql.execSQL("""CREATE TRIGGER reject_map_return BEFORE INSERT ON companion_task_receipts
            WHEN NEW.step_key='map.handoff' AND NEW.event_kind='returned'
            BEGIN SELECT RAISE(ABORT,'return receipt failed'); END""")
        var launches = 0
        expectSqlFailure {
            f.ledger.dispatch(claim, { NOW + 1 }, { null }) { launches++; DISPATCHED }
        }
        assertEquals(1, launches)
        assertEquals(1L, f.count("event_kind='claimed'"))
        assertEquals(0L, f.count("event_kind='returned'"))
        f.sql.execSQL("DROP TRIGGER reject_map_return")
        f.reopen() // Real persisted recovery, not an Android process-kill test.
        assertEquals("unknown", f.ledger.revision(KEY)!!.state)
        val fresh = f.ledger.claim(KEY, EXECUTOR, NOW + 2) { null }
        if (fresh != null) f.ledger.dispatch(fresh, { NOW + 3 }, { null }) { launches++; DISPATCHED }
        assertNull(fresh)
        assertEquals(1, launches)
        assertEquals(1L, f.count("event_kind='claimed'"))
        assertEquals(0L, f.count("event_kind='returned'"))
    }

    fun testOldRevisionIsBlockedWithoutChangingTheNewAgreementOrItsResult() {
        f.revision(1)
        val old = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW) { null })
        var launches = 0
        // G01 forbids amend while an old claim is uncertain. First obtain the
        // real not_performed result that makes the later amendment reachable.
        f.ledger.dispatch(old, { NOW + 1 }, { "map_scope_closed" }) { launches++; DISPATCHED }
        assertEquals(0, launches)
        assertEquals(1L, f.count("task_rev=1 AND event_kind='blocked' AND outcome='not_performed'"))
        f.revision(2)
        f.ledger.dispatch(old, { NOW + 1 }, { null }) { launches++; DISPATCHED }
        val newer = CompanionMapKey("t", 2)
        assertEquals(0, launches)
        assertEquals("queued", f.ledger.revision(newer)!!.state)
        assertEquals(2L, f.currentRevision())
        assertEquals(1L, f.count("task_rev=1 AND event_kind='blocked' AND outcome='not_performed'"))
        val current = checkNotNull(f.ledger.claim(newer, EXECUTOR, NOW + 2) { null })
        f.ledger.dispatch(current, { NOW + 3 }, { null }) { launches++; DISPATCHED }
        f.ledger.dispatch(old, { NOW + 4 }, { null }) { launches++; DISPATCHED }
        assertEquals(1, launches)
        assertEquals("done", f.ledger.revision(newer)!!.state)
        assertEquals(2L, f.currentRevision())
    }

    fun testCommittedPageCloseBlocksAnAlreadyQueuedHandoffBeforeAndAfterClaim() {
        f.revision(1)
        var launches = 0
        for (closeBeforeClaim in listOf(true, false)) {
            val scopes = CompanionMapScopes()
            val owner = scopes.open(ROOM)
            f.ledger.openScope(owner.id, owner.sourceSessionId)
            fun guard(row: StoredCompanionMap): String? =
                if (scopes.current(owner.id)?.sourceSessionId == row.sourceSessionId &&
                    f.ledger.scopeOpen(owner.id, row.sourceSessionId)) null else "map_scope_closed"
            // The native RAM token deliberately remains live: closeScope's
            // platform message is still queued behind handoff in this scenario.
            if (closeBeforeClaim) f.closeScope(owner.id, ROOM)
            val claim = f.ledger.claim(KEY, EXECUTOR, NOW, ::guard)
            if (closeBeforeClaim) assertNull(claim) else {
                assertNotNull(claim)
                f.closeScope(owner.id, ROOM)
                f.ledger.dispatch(claim!!, { NOW + 1 }, ::guard) { launches++; DISPATCHED }
            }
            assertNotNull(scopes.current(owner.id))
            assertFalse(f.ledger.scopeOpen(owner.id, ROOM))
            assertEquals(0, launches)
            assertEquals("waiting", f.ledger.revision(KEY)!!.state)
            assertEquals("map_scope_closed", f.ledger.revision(KEY)!!.waitReason)
        }
        assertEquals(1L, f.count("event_kind='claimed'"))
        assertEquals(2L, f.count("event_kind='blocked' AND outcome='not_performed'"))
    }

    fun testNativeScopeReplacementCannotBeRevokedByAnOldPageClose() {
        val scopes = CompanionMapScopes()
        val old = scopes.open(ROOM)
        f.ledger.openScope(old.id, old.sourceSessionId)
        val fresh = scopes.open(ROOM)
        f.ledger.openScope(fresh.id, fresh.sourceSessionId)
        f.closeScope(old.id, ROOM)
        assertFalse(f.ledger.scopeOpen(old.id, ROOM))
        assertTrue(f.ledger.scopeOpen(fresh.id, ROOM))
        f.closeScope(fresh.id, "another-room")
        assertTrue(f.ledger.scopeOpen(fresh.id, ROOM))
    }

    fun testScopeFailureAtPreflightAndAfterClaimNeverCallsLaunch() {
        f.revision(1)
        val scopes = CompanionMapScopes()
        fun guard(owner: CompanionMapScopes.Owner): (StoredCompanionMap) -> String? = { row ->
            if (scopes.current(owner.id)?.sourceSessionId == row.sourceSessionId) null else "map_scope_changed"
        }
        val goneBeforeClaim = scopes.open(ROOM)
        scopes.close(goneBeforeClaim.id)
        assertNull(f.ledger.claim(KEY, EXECUTOR, NOW, guard(goneBeforeClaim)))
        assertEquals(0L, f.count("event_kind='claimed'"))
        assertEquals(1L, f.count("event_kind='blocked' AND outcome='not_performed'"))
        val live = scopes.open(ROOM)
        val claim = checkNotNull(f.ledger.claim(KEY, EXECUTOR, NOW + 1, guard(live)))
        scopes.close(live.id)
        var launches = 0
        f.ledger.dispatch(claim, { NOW + 2 }, guard(live)) { launches++; DISPATCHED }
        assertEquals(0, launches)
        assertEquals("waiting", f.ledger.revision(KEY)!!.state)
        assertEquals("map_scope_changed", f.ledger.revision(KEY)!!.waitReason)
        assertEquals(2L, f.count("event_kind='blocked' AND outcome='not_performed'"))
    }

    fun testDifferentInstallationCannotAdoptTheOriginalTask() {
        f.revision(1)
        assertNull(f.ledger.claim(KEY, "other-installation", NOW) { null })
        assertEquals("queued", f.ledger.revision(KEY)!!.state)
        assertEquals(0L, f.count("1=1"))
    }

    fun testFailedClaimCommitCannotReachTheLaunchCallback() {
        f.revision(1)
        f.sql.execSQL("""CREATE TRIGGER reject_map_claim BEFORE INSERT ON companion_task_receipts
            WHEN NEW.step_key='map.handoff' AND NEW.event_kind='claimed'
            BEGIN SELECT RAISE(ABORT,'claim failed'); END""")
        var launches = 0
        expectSqlFailure {
            val claim = f.ledger.claim(KEY, EXECUTOR, NOW) { null }
            if (claim != null) f.ledger.dispatch(claim, { NOW + 1 }, { null }) { launches++; DISPATCHED }
        }
        assertEquals(0, launches)
        assertEquals("queued", f.ledger.revision(KEY)!!.state)
        assertEquals(0L, f.count("1=1"))
    }

    private fun expectSqlFailure(block: () -> Unit) {
        try { block(); fail("Expected an actual SQLite transaction failure") }
        catch (_: SQLiteException) { }
    }

    private class Fixture(context: Context) : Closeable {
        val directory = File(context.cacheDir, "companion-map-ledger-${UUID.randomUUID()}").apply { check(mkdirs()) }
        private val isolated = object : ContextWrapper(context) { override fun getFilesDir() = directory }
        val sql: SQLiteDatabase
        var ledger: CompanionMapLedger
        fun closeScope(scopeId: String, sourceSessionId: String) {
            sql.beginTransactionNonExclusive()
            try {
                // Exact SDK close-only command, exercised on its own connection.
                sql.execSQL("UPDATE companion_map_scopes SET closed=1 WHERE scope_id=? AND source_session_id=?",
                    arrayOf(scopeId, sourceSessionId))
                sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
        }
        init {
            val path = File(directory, "companion/memory.sqlite")
            check(path.parentFile!!.mkdirs())
            sql = SQLiteDatabase.openOrCreateDatabase(path, null)
            sql.setForeignKeyConstraintsEnabled(true)
            SCHEMA.split(';').filter { it.isNotBlank() }.forEach { sql.execSQL(it) }
            sql.version = 14
            sql.rawQuery("PRAGMA busy_timeout=5000", null).use { check(it.moveToFirst()) }
            sql.execSQL("""INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,
                item_no,kind,room_mode,current_rev,created_at_ms,updated_at_ms)
                VALUES('t','archive','original',?,0,'phone.map_open','light',1,?,?)""", arrayOf<Any?>(ROOM, NOW, NOW))
            ledger = CompanionMapLedger.open(isolated)
        }

        fun revision(revision: Long, cancelled: Boolean = false, choice: Boolean = false) {
            sql.beginTransactionNonExclusive()
            try {
                sql.execSQL("""INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,
                    command_source_rev,command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,
                    source_offset_minutes,source_offset_seconds,executor_id,state,wait_reason,cancel_requested,
                    created_at_ms,updated_at_ms)
                    VALUES('t',?,?,?,1,0,?,?,'Asia/Shanghai',480,28800,?,?,?,?,?,?)""", arrayOf<Any?>(revision,
                    if (cancelled) "cancel" else if (revision == 1L) "create" else "amend",
                    "command-$revision", "fingerprint-$revision", NOW, EXECUTOR,
                    if (cancelled) "cancelled" else if (choice) "waiting" else "queued",
                    if (choice && !cancelled) "map_target_choice" else null, if (cancelled) 1 else 0, NOW, NOW))
                sql.execSQL("""INSERT INTO companion_map_revisions(task_id,task_rev,address,place_name,target_kind,
                    package_name,component_name,package_uid,target_label,reopens_task_id)
                    VALUES('t',?,?,?, ?,?,?,?, ?,NULL)""", arrayOf<Any?>(revision, ADDRESS, "东门",
                    if (choice) "choice" else "selected", if (choice) null else "example.maps",
                    if (choice) null else "example.maps.GeoActivity", if (choice) null else 10234,
                    if (choice) null else "测试地图"))
                sql.execSQL("UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id='t'",
                    arrayOf(revision, NOW))
                sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
        }

        fun count(where: String): Long = sql.rawQuery("SELECT COUNT(*) FROM companion_task_receipts WHERE $where", null)
            .use { check(it.moveToFirst()); it.getLong(0) }
        fun currentRevision(): Long = sql.rawQuery("SELECT current_rev FROM companion_tasks WHERE task_id='t'", null)
            .use { check(it.moveToFirst()); it.getLong(0) }
        fun lastDetail(): JSONObject = sql.rawQuery("SELECT detail_json FROM companion_task_receipts " +
            "WHERE task_id='t' ORDER BY runner_receipt_seq DESC LIMIT 1", null)
            .use { check(it.moveToFirst()); JSONObject(it.getString(0)) }
        fun reopen() { ledger.close(); ledger = CompanionMapLedger.open(isolated) }
        override fun close() { ledger.close(); sql.close(); check(directory.deleteRecursively()) }
    }

    companion object {
        private const val EXECUTOR = "map-test-installation"
        private const val ROOM = "light:map-room"
        private const val NOW = 1795219200000L
        private const val ADDRESS = "上海市 科创路 18 号 & 展厅（东门）"
        private val KEY = CompanionMapKey("t", 1)
        private val DISPATCHED = CompanionMapObservation("handoff_dispatched", "done", "returned", "succeeded")
        // Literal D/E/F/G task DDL from the exact G01 SDK. No copied user data,
        // fake database, Android map app, model, permission grant, or dependency install.
        private val SCHEMA = """
CREATE TABLE companion_tasks (
  task_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  source_message_id TEXT NOT NULL,
  source_session_id TEXT NOT NULL,
  item_no INTEGER NOT NULL CHECK(item_no>=0),
  kind TEXT NOT NULL,
  room_mode TEXT NOT NULL CHECK(room_mode IN ('light','full')),
  host_key TEXT,
  host_session_id TEXT,
  current_rev INTEGER NOT NULL CHECK(current_rev>=1),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  UNIQUE(source_message_id,item_no)
);
CREATE INDEX companion_tasks_room ON companion_tasks(source_session_id,created_at_ms,task_id);

CREATE TABLE companion_task_revisions (
  task_id TEXT NOT NULL REFERENCES companion_tasks(task_id) ON DELETE CASCADE,
  task_rev INTEGER NOT NULL CHECK(task_rev>=1),
  operation TEXT NOT NULL CHECK(operation IN ('create','amend','cancel')),
  command_message_id TEXT NOT NULL,
  command_source_rev INTEGER NOT NULL,
  command_item_no INTEGER NOT NULL CHECK(command_item_no>=0),
  request_fingerprint TEXT NOT NULL,
  source_said_at_utc INTEGER NOT NULL,
  source_zone_id TEXT,
  source_offset_minutes INTEGER NOT NULL,
  source_offset_seconds INTEGER,
  executor_id TEXT NOT NULL,
  reminder_text TEXT,
  local_date TEXT,
  local_time TEXT,
  zone_id TEXT,
  offset_seconds INTEGER,
  epoch_ms INTEGER,
  state TEXT NOT NULL CHECK(state IN ('queued','waiting','running','unknown','done','partial','failed','cancelled')),
  wait_reason TEXT,
  cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK(cancel_requested IN (0,1)),
  notification_claim_id TEXT,
  notification_claimed_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY(task_id,task_rev),
  UNIQUE(command_message_id,command_item_no),
  CHECK((epoch_ms IS NULL)=(offset_seconds IS NULL)),
  CHECK((notification_claim_id IS NULL)=(notification_claimed_at_ms IS NULL))
);
CREATE INDEX companion_task_executor ON companion_task_revisions(executor_id,state,epoch_ms);

CREATE TABLE companion_task_receipts (
  runner_receipt_seq INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  task_rev INTEGER NOT NULL,
  step_key TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  event_kind TEXT NOT NULL CHECK(event_kind IN
    ('accepted','claimed','returned','failed','blocked','received','active_observed','opened','skipped')),
  executor_id TEXT NOT NULL,
  occurred_at_ms INTEGER NOT NULL,
  effect_id TEXT,
  outcome TEXT CHECK(outcome IN ('succeeded','not_performed','unknown')),
  detail_json TEXT,
  FOREIGN KEY(task_id,task_rev) REFERENCES companion_task_revisions(task_id,task_rev) ON DELETE CASCADE,
  UNIQUE(task_id,task_rev,step_key,attempt_id,event_kind)
);
CREATE INDEX companion_task_receipts_task ON companion_task_receipts(task_id,runner_receipt_seq);

ALTER TABLE companion_task_revisions ADD COLUMN lookup_place_name TEXT;
ALTER TABLE companion_task_revisions ADD COLUMN lookup_city TEXT;
ALTER TABLE companion_task_revisions ADD COLUMN lookup_question TEXT;
ALTER TABLE companion_task_revisions ADD COLUMN lookup_deadline_ms INTEGER;
ALTER TABLE companion_task_revisions ADD COLUMN lookup_result_json TEXT;
ALTER TABLE companion_task_revisions ADD COLUMN lookup_result_fingerprint TEXT;
CREATE TABLE companion_lookup_attempts (
  request_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  task_rev INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('search','fetch','answer')),
  attempt_no INTEGER NOT NULL CHECK(attempt_no>=1),
  input_json TEXT NOT NULL,
  request_fingerprint TEXT NOT NULL,
  execution_mode TEXT NOT NULL CHECK(execution_mode IN ('phone','host')),
  instance_id TEXT,
  provider TEXT,
  model TEXT,
  unit_price_micro_cny INTEGER CHECK(unit_price_micro_cny>=0),
  price_as_of TEXT,
  dispatched INTEGER CHECK(dispatched IN (0,1)),
  http_status INTEGER CHECK(http_status BETWEEN 100 AND 599),
  terminal TEXT,
  complete INTEGER NOT NULL DEFAULT 0 CHECK(complete IN (0,1)),
  valid_result INTEGER NOT NULL DEFAULT 0 CHECK(valid_result IN (0,1)),
  tool_response_json TEXT,
  tool_response_fingerprint TEXT,
  source_metadata_json TEXT,
  answer_text TEXT,
  raw_usage_json TEXT,
  normalized_usage_json TEXT,
  tool_success_units INTEGER CHECK(tool_success_units IN (0,1)),
  estimated_tool_micro_cny INTEGER CHECK(estimated_tool_micro_cny>=0),
  finish_fingerprint TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  finished_at_ms INTEGER,
  FOREIGN KEY(task_id,task_rev) REFERENCES companion_task_revisions(task_id,task_rev) ON DELETE CASCADE,
  UNIQUE(task_id,kind,attempt_no),
  CHECK((execution_mode='host')=(instance_id IS NOT NULL))
);
CREATE INDEX companion_lookup_task ON companion_lookup_attempts(task_id,task_rev,created_at_ms,request_id);

CREATE TABLE companion_host_tasks (
  task_id TEXT PRIMARY KEY REFERENCES companion_tasks(task_id) ON DELETE CASCADE,
  host_store_id TEXT,
  host_execution_id TEXT,
  applied_host_receipt_seq INTEGER NOT NULL DEFAULT 0 CHECK(applied_host_receipt_seq>=0),
  snapshot_json TEXT
);
CREATE TABLE companion_host_commands (
  task_id TEXT NOT NULL,
  task_rev INTEGER NOT NULL,
  operation_id TEXT UNIQUE,
  request_json TEXT NOT NULL,
  display_json TEXT NOT NULL DEFAULT '{}',
  possible_sent_at_ms INTEGER,
  PRIMARY KEY(task_id,task_rev),
  FOREIGN KEY(task_id,task_rev) REFERENCES companion_task_revisions(task_id,task_rev) ON DELETE CASCADE
);

CREATE TABLE companion_map_revisions (
  task_id TEXT NOT NULL,
  task_rev INTEGER NOT NULL,
  address TEXT NOT NULL CHECK(length(address)>0),
  place_name TEXT,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('selected','default','choice')),
  package_name TEXT,
  component_name TEXT,
  package_uid INTEGER,
  target_label TEXT,
  reopens_task_id TEXT,
  PRIMARY KEY(task_id,task_rev),
  FOREIGN KEY(task_id,task_rev)
    REFERENCES companion_task_revisions(task_id,task_rev) ON DELETE CASCADE,
  CHECK(
    (target_kind='choice' AND package_name IS NULL AND component_name IS NULL
      AND package_uid IS NULL AND target_label IS NULL)
    OR
    (target_kind IN ('selected','default') AND package_name IS NOT NULL
      AND component_name IS NOT NULL AND package_uid IS NOT NULL AND package_uid>=0)
  )
);
CREATE TABLE companion_map_scopes (
  scope_id TEXT PRIMARY KEY,
  source_session_id TEXT NOT NULL,
  closed INTEGER NOT NULL CHECK(closed IN(0,1))
);
        """
    }
}
