package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.content.ContextWrapper
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.test.AndroidTestCase
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import java.time.Instant
import java.util.TimeZone
import java.util.UUID

/** Real platform SQLite and runner; only AlarmManager/NotificationManager effects are controlled. */
@Suppress("DEPRECATION")
class CompanionReminderLedgerTest : AndroidTestCase() {
    private lateinit var f: Fixture

    override fun setUp() { super.setUp(); f = Fixture(context) }
    override fun tearDown() { try { f.close() } finally { super.tearDown() } }

    fun testRegistrationClaimIsCommittedBeforeEffectAndReceiptIsNotDelivery() {
        f.revision(1)
        f.effects.beforeRegister = {
            // This connection is separate from the runner's writer connection.
            assertEquals(1L, f.count("step_key='alarm.register' AND event_kind='claimed'"))
            assertEquals("unknown", f.ledger.current("t")!!.state)
        }
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.registered)
        assertEquals("done", f.ledger.current("t")!!.state)
        assertEquals(1L, f.count("step_key='alarm.register' AND event_kind='returned'"))
        assertEquals(0L, f.count("step_key='notification'"))
        assertNull(f.ledger.current("t")!!.notificationClaim)
        // A returned notify and an actually observed notification are separate
        // receipts. A stale system snapshot is not a failed/unknown dispatch.
        f.now = DUE
        f.runner().alarm(ReminderKey("t", 1))
        val claim = f.ledger.current("t")!!.notificationClaim
        assertNotNull(claim)
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.notified)
        assertEquals(1L, f.count("step_key='notification' AND event_kind='returned' AND outcome='succeeded'"))
        assertEquals(0L, f.count("step_key='notification' AND event_kind='failed'"))
        assertEquals(0L, f.count("event_kind='active_observed'"))
        f.reopen()
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.notified)
        f.effects.active = true
        f.runner().alarm(ReminderKey("t", 1))
        assertEquals(claim, f.ledger.current("t")!!.notificationClaim)
        assertEquals(1L, f.count("event_kind='active_observed'"))
        assertEquals(1L, f.count("step_key='notification' AND event_kind='returned'"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.notified)

        // The real display read/render and its final platform-call boundary
        // share one lock. This callback observes that boundary; it does not
        // post a notification or simulate a second Android process.
        val displayLock = File(f.isolated.noBackupFilesDir, "companion-resident/display.lock")
        check(displayLock.parentFile!!.mkdirs() || displayLock.parentFile!!.isDirectory)
        RandomAccessFile(displayLock, "rw").use { probe ->
            var submitted = 0
            CompanionConversationNotification.startForeground(f.isolated) {
                submitted++
                var held = false
                val unexpected = try {
                    probe.channel.tryLock()
                } catch (_: OverlappingFileLockException) {
                    held = true
                    null
                }
                unexpected?.release()
                assertTrue("The display lock must remain held through the foreground submission", held)
            }
            assertEquals(1, submitted)
            val released = probe.channel.tryLock()
            assertNotNull("The display lock must be released after submission returns", released)
            released?.release()
            // Keep this probe open throughout the production lock: closing a
            // second channel early can release process locks on some systems.
        }
    }

    fun testFailedClaimTransactionsCannotCallRegisterOrNotify() {
        f.revision(1)
        f.sql.execSQL("""CREATE TRIGGER reject_register BEFORE INSERT ON companion_task_receipts
            WHEN NEW.step_key='alarm.register' AND NEW.event_kind='claimed'
            BEGIN SELECT RAISE(ABORT,'register claim failed'); END""")
        expectSqlFailure { f.runner().resume("t") }
        assertEquals(0, f.effects.registered.size)
        assertEquals(0L, f.count("event_kind='claimed'"))
        f.sql.execSQL("DROP TRIGGER reject_register")
        assertTrue(f.runner().resume("t"))
        f.now = DUE
        f.sql.execSQL("""CREATE TRIGGER reject_notification BEFORE INSERT ON companion_task_receipts
            WHEN NEW.step_key='notification' AND NEW.event_kind='claimed'
            BEGIN SELECT RAISE(ABORT,'notification claim failed'); END""")
        expectSqlFailure { f.runner().alarm(ReminderKey("t", 1)) }
        assertEquals(0, f.effects.notified.size)
        assertNull(f.ledger.current("t")!!.notificationClaim)
        assertEquals(0L, f.count("step_key='notification' AND event_kind='claimed'"))
    }

    fun testReturnedSystemCallWithFailedReceiptStaysUnknownAndReusesSameIdentity() {
        f.revision(1)
        f.sql.execSQL("""CREATE TRIGGER reject_return BEFORE INSERT ON companion_task_receipts
            WHEN NEW.step_key='alarm.register' AND NEW.event_kind='returned'
            BEGIN SELECT RAISE(ABORT,'return receipt failed'); END""")
        expectSqlFailure { f.runner().resume("t") }
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.registered)
        assertEquals("unknown", f.ledger.current("t")!!.state)
        assertEquals(0L, f.count("step_key='alarm.register' AND event_kind='returned'"))
        f.sql.execSQL("DROP TRIGGER reject_return")
        f.reopen()
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1), ReminderKey("t", 1)), f.effects.registered)
        assertEquals("done", f.ledger.current("t")!!.state)
        assertEquals(2L, f.count("step_key='alarm.register' AND event_kind='claimed'"))
        assertEquals(1L, f.count("step_key='alarm.register' AND event_kind='returned'"))
    }

    fun testLostNotificationReturnNeverCausesASecondNotifyAfterReopen() {
        f.revision(1)
        assertTrue(f.runner().resume("t"))
        f.now = DUE
        f.effects.afterNotify = { throw LostProcess() }
        try { f.runner().alarm(ReminderKey("t", 1)); fail("Expected the lost process boundary") }
        catch (_: LostProcess) { }
        val claim = f.ledger.current("t")!!.notificationClaim
        assertNotNull(claim)
        assertEquals(1, f.effects.notified.size)
        assertEquals(0L, f.count("step_key='notification' AND event_kind='returned'"))
        f.reopen() // Durable recovery only; this is not an Android process-kill test.
        f.effects.afterNotify = { }
        f.runner().alarm(ReminderKey("t", 1))
        f.runner().resume("t")
        assertEquals(1, f.effects.notified.size)
        assertEquals(claim, f.ledger.current("t")!!.notificationClaim)
        assertEquals(0L, f.count("event_kind='active_observed'"))
        assertEquals("done", f.ledger.current("t")!!.state) // Registration result stays separate.
        f.ledger.opened(ReminderKey("t", 1), EXECUTOR, f.now)
        f.ledger.opened(ReminderKey("t", 1), EXECUTOR, f.now + 1)
        assertEquals(1L, f.count("event_kind='opened'"))
    }

    fun testRevisionChangedAfterClaimCannotCallAnOldSystemEffect() {
        f.revision(1)
        f.revision(2, head = false)
        f.sql.execSQL("""CREATE TRIGGER move_head AFTER INSERT ON companion_task_receipts
            WHEN NEW.step_key='alarm.register' AND NEW.event_kind='claimed' AND NEW.task_rev=1
            BEGIN UPDATE companion_tasks SET current_rev=2 WHERE task_id='t'; END""")
        assertTrue(f.runner().resume("t"))
        assertEquals(0, f.effects.registered.size)
        assertEquals(1L, f.count("task_rev=1 AND event_kind='skipped' AND outcome='not_performed'"))
        assertEquals(2L, f.ledger.current("t")!!.key.revision)
        assertEquals("queued", f.ledger.current("t")!!.state)
        assertEquals("unknown", f.ledger.revision(ReminderKey("t", 1))!!.state)
    }

    fun testAnotherAmendmentKeepsPreviouslyProvedCancellationAfterReopen() {
        f.revision(1)
        assertTrue(f.runner().resume("t"))
        f.revision(2)
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.cancelled)
        f.reopen()
        f.revision(3)
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1), ReminderKey("t", 2)), f.effects.cancelled)
        assertEquals(listOf(ReminderKey("t", 1), ReminderKey("t", 2), ReminderKey("t", 3)), f.effects.registered)
        assertEquals(0L, f.count("task_rev=3 AND step_key='alarm.cancel:1'"))
        assertEquals("done", f.ledger.current("t")!!.state)
    }

    fun testMissingTimeKeepsItsQuestionAndRestoredExecutorDoesNotAdoptIt() {
        f.revision(1, resolved = false)
        assertTrue(f.runner().resume("t"))
        assertEquals("waiting", f.ledger.current("t")!!.state)
        assertEquals("time_missing", f.ledger.current("t")!!.waitReason)
        assertEquals(0, f.effects.registered.size)
        val before = f.count("1=1")
        CompanionReminderRunner(f.ledger, f.effects, "other-installation") { f.now }.resume("t")
        assertEquals(before, f.count("1=1"))
    }

    fun testSavedOffsetDeterminesRecoveryAndExpiredTaskIsNotCaughtUp() {
        f.revision(1)
        val originalZone = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"))
            assertTrue(f.runner().resume("t"))
        } finally { TimeZone.setDefault(originalZone) }
        assertEquals(listOf(DUE), f.effects.epochs)
        f.now = DUE + 1
        assertTrue(f.runner().resume("t"))
        assertEquals("done", f.ledger.current("t")!!.state)
        assertEquals(1, f.effects.registered.size)
        f.revision(2)
        assertTrue(f.runner().resume("t"))
        assertEquals(1, f.effects.registered.size)
        assertEquals(0, f.effects.notified.size)
        assertEquals("failed", f.ledger.current("t")!!.state)
        assertEquals("time_passed", f.ledger.current("t")!!.waitReason)

        f.now = DUE - 1
        f.revision(3)
        assertTrue(f.runner().resume("t"))
        val key = ReminderKey("t", 3)
        f.runner().alarm(key)
        assertNull(f.ledger.revision(key)!!.notificationClaim)
        assertEquals(0, f.effects.notified.size)

        // Move the injected wall clock back only after the real claim commits.
        // No call-count schedule or replacement ledger decides that boundary.
        val clock = {
            if (f.ledger.revision(key)!!.notificationClaim == null) DUE else DUE - 1
        }
        f.effects.afterNotify = { assertEquals(DUE - 1, clock()) }
        CompanionReminderRunner(f.ledger, f.effects, EXECUTOR, clock).alarm(key)
        assertEquals(listOf(key), f.effects.notified)
        assertEquals(1L, f.count("task_rev=3 AND step_key='notification' AND event_kind='returned' AND outcome='succeeded'"))
        assertEquals(0L, f.count("task_rev=3 AND step_key='notification' AND event_kind='skipped'"))

        f.reopen()
        f.now = DUE + 1
        assertTrue(f.runner().resume("t"))
        f.runner().alarm(key)
        assertEquals(listOf(key), f.effects.notified)
        assertEquals(1L, f.count("task_rev=3 AND step_key='notification' AND event_kind='claimed'"))
    }

    fun testReminderIsSetWhileNotificationsAreOffAndRingsOnceTheyAreOn() {
        f.revision(1)
        f.effects.notifications = false
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.registered)
        assertEquals("done", f.ledger.current("t")!!.state)
        assertEquals("notifications_disabled", f.ledger.current("t")!!.waitReason)

        // Turned on before it is due, with no run in between: it rings, and
        // the delivery itself drops the stale reason.
        f.effects.notifications = true
        f.now = DUE
        f.runner().alarm(ReminderKey("t", 1))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.notified)
        assertEquals("done", f.ledger.current("t")!!.state)
        assertNull(f.ledger.current("t")!!.waitReason)
    }

    fun testLookupUpgradeKeepsReminderRecoveryAndDoesNotExecuteTheLookupTask() {
        f.revision(1)
        f.installLookupSchema()
        f.sql.execSQL("""INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,
            item_no,kind,room_mode,current_rev,created_at_ms,updated_at_ms)
            VALUES('q','archive','lookup-source','light:s',1,'public.lookup','light',1,0,0)""")
        f.sql.execSQL("""INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,
            command_source_rev,command_item_no,request_fingerprint,source_said_at_utc,source_offset_minutes,
            executor_id,local_date,zone_id,state,created_at_ms,updated_at_ms,
            lookup_place_name,lookup_question,lookup_deadline_ms)
            VALUES('q',1,'create','lookup-source',1,1,'lookup-fingerprint',?,480,?,'2026-11-22',
            'Asia/Singapore','running',0,0,'青桥美术馆','今天开不开',?)""", arrayOf<Any?>(f.now, EXECUTOR, DUE))
        f.reopen()
        assertEquals(12, f.sql.version)
        assertEquals(listOf("t"), f.ledger.recoveryBatch(EXECUTOR, f.now, "", 50))
        assertNull(f.ledger.current("q"))
        assertNull(f.ledger.revision(ReminderKey("q", 1)))
        assertTrue(f.runner().resume("q"))
        assertEquals(0, f.effects.registered.size)
        assertTrue(f.runner().resume("t"))
        f.revision(2)
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.cancelled)
        assertEquals(listOf(ReminderKey("t", 1), ReminderKey("t", 2)), f.effects.registered)
        f.sql.rawQuery("SELECT state FROM companion_task_revisions WHERE task_id='q'", null).use {
            assertTrue(it.moveToFirst()); assertEquals("running", it.getString(0))
        }
        assertEquals(0L, f.count("task_id='q'"))
    }

    fun testHostUpgradeKeepsRemindersAndLeavesHostCommandsAndSnapshotsUntouched() {
        f.revision(1)
        f.installLookupSchema()
        f.installHostSchema()
        f.sql.execSQL("""INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,
            item_no,kind,room_mode,current_rev,created_at_ms,updated_at_ms)
            VALUES('h','archive','host-source','light:s',2,'host.notes_to_todo','light',1,0,0)""")
        f.sql.execSQL("""INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,
            command_source_rev,command_item_no,request_fingerprint,source_said_at_utc,source_offset_minutes,
            executor_id,state,created_at_ms,updated_at_ms)
            VALUES('h',1,'create','host-source',1,2,'host-fingerprint',?,480,'original-host-store',
            'running',0,0)""", arrayOf(f.now))
        val snapshot = """{"taskId":"h","state":"unknown","receiptSeq":7}"""
        val command = """{"taskId":"h","taskRev":1,"kind":"host.notes_to_todo"}"""
        f.sql.execSQL("""INSERT INTO companion_host_tasks(task_id,host_store_id,host_execution_id,
            applied_host_receipt_seq,snapshot_json) VALUES('h','original-host-store','original-execution',7,?)""",
            arrayOf(snapshot))
        f.sql.execSQL("""INSERT INTO companion_host_commands(task_id,task_rev,request_json,possible_sent_at_ms)
            VALUES('h',1,?,123)""", arrayOf(command))
        f.reopen()
        assertEquals(13, f.sql.version)
        assertEquals(listOf("t"), f.ledger.recoveryBatch(EXECUTOR, f.now, "", 50))
        assertNull(f.ledger.current("h"))
        assertNull(f.ledger.revision(ReminderKey("h", 1)))
        assertTrue(f.runner().resume("h"))
        assertEquals(0, f.effects.registered.size)
        assertTrue(f.runner().resume("t"))
        assertEquals(listOf(ReminderKey("t", 1)), f.effects.registered)
        assertEquals(0L, f.count("task_id='h'"))
        f.sql.rawQuery("SELECT applied_host_receipt_seq,snapshot_json FROM companion_host_tasks WHERE task_id='h'", null).use {
            assertTrue(it.moveToFirst()); assertEquals(7L, it.getLong(0)); assertEquals(snapshot, it.getString(1))
        }
        f.sql.rawQuery("SELECT request_json,possible_sent_at_ms,display_json FROM companion_host_commands WHERE task_id='h'", null).use {
            assertTrue(it.moveToFirst()); assertEquals(command, it.getString(0)); assertEquals(123L, it.getLong(1))
            assertEquals("{}", it.getString(2))
        }
    }

    fun testMapUpgradeKeepsReminderRecoveryAndNeverDispatchesThePendingMap() {
        f.revision(1)
        f.installLookupSchema(); f.installHostSchema(); f.installMapSchema()
        f.sql.execSQL("""INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,
            item_no,kind,room_mode,current_rev,created_at_ms,updated_at_ms)
            VALUES('m','archive','map-source','light:s',3,'phone.map_open','light',1,0,0)""")
        f.sql.execSQL("""INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,
            command_source_rev,command_item_no,request_fingerprint,source_said_at_utc,source_offset_minutes,
            executor_id,state,wait_reason,created_at_ms,updated_at_ms)
            VALUES('m',1,'create','map-source',1,3,'map-fingerprint',?,480,?,
            'unknown','map_handoff_pending',0,0)""", arrayOf<Any?>(f.now, EXECUTOR))
        f.sql.execSQL("""INSERT INTO companion_map_revisions(task_id,task_rev,address,target_kind)
            VALUES('m',1,'科创路 18 号 & 东门','choice')""")
        f.sql.execSQL("""INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,
            event_kind,executor_id,occurred_at_ms) VALUES('m',1,'map.handoff','original-map',
            'claimed',?,?)""", arrayOf<Any?>(EXECUTOR, f.now))
        f.reopen()
        assertEquals(14, f.sql.version)
        assertEquals(listOf("t"), f.ledger.recoveryBatch(EXECUTOR, f.now, "", 50))
        assertNull(f.ledger.current("m")); assertNull(f.ledger.revision(ReminderKey("m", 1)))
        assertTrue(f.runner().resume("m")); assertEquals(0, f.effects.registered.size)
        assertTrue(f.runner().resume("t")); assertEquals(listOf(ReminderKey("t", 1)), f.effects.registered)
        f.sql.rawQuery("SELECT state,wait_reason FROM companion_task_revisions WHERE task_id='m'", null).use {
            assertTrue(it.moveToFirst()); assertEquals("unknown", it.getString(0))
            assertEquals("map_handoff_pending", it.getString(1))
        }
        f.sql.rawQuery("SELECT address FROM companion_map_revisions WHERE task_id='m'", null).use {
            assertTrue(it.moveToFirst()); assertEquals("科创路 18 号 & 东门", it.getString(0))
        }
        assertEquals(1L, f.count("task_id='m'"))
    }

    fun testSchemaGateStillRejectsUnmigratedAndUnknownFutureStores() {
        f.revision(1)
        try {
            for (version in listOf(10, 18)) {
                f.sql.version = version
                try { f.probe(); fail("Unsupported version $version was opened") }
                catch (_: IllegalStateException) { }
            }
        } finally { f.sql.version = 11 }
        assertEquals(0L, f.count("1=1"))
        assertEquals(0, f.effects.registered.size)
        assertTrue(f.runner().resume("t"))
    }

    private fun expectSqlFailure(block: () -> Unit) {
        try { block(); fail("Expected an actual SQLite transaction failure") }
        catch (_: SQLiteException) { }
    }

    private class LostProcess : Error()

    private class Effects : CompanionReminderEffects {
        val registered = mutableListOf<ReminderKey>()
        val epochs = mutableListOf<Long>()
        val cancelled = mutableListOf<ReminderKey>()
        val notified = mutableListOf<ReminderKey>()
        var beforeRegister: () -> Unit = { }
        var afterNotify: () -> Unit = { }
        var notifications = true
        override fun capabilities() = mapOf<String, Any>("appNotifications" to notifications,
            "channelNotifications" to true, "groupNotifications" to true)
        override fun register(key: ReminderKey, epochMs: Long) {
            beforeRegister(); registered.add(key); epochs.add(epochMs)
        }
        override fun cancel(key: ReminderKey) { cancelled.add(key) }
        override fun notify(reminder: StoredReminder) { notified.add(reminder.key); afterNotify() }
        var active = false
        override fun isActive(key: ReminderKey) = active
    }

    private class Fixture(context: Context) : Closeable {
        val directory = File(context.cacheDir, "companion-ledger-test-${UUID.randomUUID()}").apply { check(mkdirs()) }
        val isolated = object : ContextWrapper(context) {
            override fun getFilesDir() = directory
            override fun getNoBackupFilesDir() = directory
        }
        val sql: SQLiteDatabase
        var ledger: CompanionReminderLedger
        val effects = Effects()
        var now = DUE - 60_000
        init {
            val path = File(directory, "companion/memory.sqlite")
            check(path.parentFile!!.mkdirs())
            sql = SQLiteDatabase.openOrCreateDatabase(path, null)
            sql.setForeignKeyConstraintsEnabled(true)
            SCHEMA.split(';').filter { it.isNotBlank() }.forEach { sql.execSQL(it) }
            sql.version = 11
            sql.execSQL("""INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,
                item_no,kind,room_mode,current_rev,created_at_ms,updated_at_ms)
                VALUES('t','archive','source','light:s',0,'phone.reminder','light',1,0,0)""")
            ledger = CompanionReminderLedger.open(isolated)
        }
        fun revision(revision: Long, operation: String = if (revision == 1L) "create" else "amend",
                     head: Boolean = true, resolved: Boolean = true) {
            sql.execSQL("""INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,
                command_source_rev,command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,
                source_offset_minutes,source_offset_seconds,executor_id,reminder_text,local_date,local_time,
                zone_id,offset_seconds,epoch_ms,state,wait_reason,created_at_ms,updated_at_ms)
                VALUES('t',?,?,?,1,0,?,?,'Asia/Singapore',480,28800,?,'带伞','2026-11-22',?,
                'Asia/Singapore',?,?,?,?,?,?)""", arrayOf<Any?>(revision, operation, "command-$revision",
                "fingerprint-$revision", now, EXECUTOR, if (resolved) "09:00" else null,
                if (resolved) 28800 else null, if (resolved) DUE else null,
                if (resolved) "queued" else "waiting", if (resolved) null else "time_missing", now, now))
            if (head) sql.execSQL("UPDATE companion_tasks SET current_rev=? WHERE task_id='t'", arrayOf(revision))
        }
        fun count(where: String): Long = sql.rawQuery("SELECT COUNT(*) FROM companion_task_receipts WHERE $where", null)
            .use { check(it.moveToFirst()); it.getLong(0) }
        fun runner() = CompanionReminderRunner(ledger, effects, EXECUTOR) { now }
        fun installLookupSchema() {
            sql.beginTransaction()
            try {
                LOOKUP_SCHEMA.split(';').filter { it.isNotBlank() }.forEach { sql.execSQL(it) }
                sql.version = 12
                sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
        }
        fun probe() { CompanionReminderLedger.open(isolated).use { } }
        fun installHostSchema() {
            sql.beginTransaction()
            try {
                HOST_SCHEMA.split(';').filter { it.isNotBlank() }.forEach { sql.execSQL(it) }
                sql.version = 13
                sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
        }
        fun reopen() { ledger.close(); ledger = CompanionReminderLedger.open(isolated) }
        fun installMapSchema() {
            sql.beginTransaction()
            try {
                MAP_SCHEMA.split(';').filter { it.isNotBlank() }.forEach { sql.execSQL(it) }
                sql.version = 14
                sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
        }
        override fun close() { ledger.close(); sql.close(); check(directory.deleteRecursively()) }
    }

    companion object {
        private const val EXECUTOR = "test-installation"
        private val DUE = Instant.parse("2026-11-22T01:00:00Z").toEpochMilli()
        // Literal three-table contract from companion_task_store.dart; no user database or asset.
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
        """.trimIndent()
        // Literal v14 extension from G SDK; native never migrates a database.
        private val MAP_SCHEMA = """
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
        """.trimIndent()
        // Literal v13 extension from the F SDK, not a native migrator.
        private val HOST_SCHEMA = """
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
        """.trimIndent()
        // Literal v12 extension from the frozen E SDK, not a native migrator.
        private val LOOKUP_SCHEMA = """
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
        """.trimIndent()
    }
}
