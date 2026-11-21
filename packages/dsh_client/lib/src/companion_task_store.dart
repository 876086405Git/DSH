part of 'companion_memory_store.dart';

/// A concrete reminder or the specific missing fields awaiting a new command.
/// Regional time rules are resolved by the native platform before persistence.
class CompanionReminderSpec {
  const CompanionReminderSpec({
    this.text,
    this.localDate,
    this.localTime,
    this.zoneId,
    this.offsetSeconds,
    this.epochMs,
    this.waitReason,
  });

  final String? text, localDate, localTime, zoneId, waitReason;
  final int? offsetSeconds, epochMs;

  List<Object?> get _values => [text, localDate, localTime, zoneId, offsetSeconds, epochMs, waitReason];

  void _validate() {
    if (text != null) {
      _messageText(text!);
    }
    if (zoneId != null && (zoneId!.isEmpty || zoneId!.trim() != zoneId)) {
      throw _taskInvalid;
    }
    final date = localDate;
    final time = localTime;
    DateTime? local;
    if (date != null) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        throw _taskInvalid;
      }
      final day = DateTime.tryParse('${date}T00:00:00Z');
      if (day == null || day.toIso8601String().substring(0, 10) != date) {
        throw _taskInvalid;
      }
    }
    if (time != null) {
      if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$').hasMatch(time)) {
        throw _taskInvalid;
      }
      if (date != null) {
        local = DateTime.parse('${date}T${time}Z');
      }
    }
    final epoch = epochMs;
    final offset = offsetSeconds;
    if (epoch != null || offset != null) {
      if (epoch == null ||
          offset == null ||
          text == null ||
          local == null ||
          zoneId == null ||
          waitReason != null ||
          epoch < 0 ||
          epoch > 8640000000000000 ||
          offset < -64800 ||
          offset > 64800 ||
          local.millisecondsSinceEpoch - offset * 1000 != epoch) {
        throw _taskInvalid;
      }
      return;
    }
    final missing = switch (waitReason) {
      'text_missing' => text == null,
      'date_missing' => date == null,
      'time_missing' => time == null,
      'zone_missing' => zoneId == null,
      'time_gap' || 'time_overlap' => date != null && time != null && zoneId != null,
      _ => false,
    };
    if (!missing) {
      throw _taskInvalid;
    }
  }
}

const _taskInvalid = DshRemoteException('companion/task-invalid-request', 'Invalid reminder agreement', {
  'status': 400,
});

/// User agreements use the existing phone database and owning isolate.
/// Native execution in its separate process writes receipts, never these heads.
extension CompanionTaskStore on CompanionMemoryStore {
  MemoryRow createReminderFromMessage({
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    String? hostKey,
    String? hostSessionId,
    required String executorId,
    required CompanionReminderSpec reminder,
  }) {
    if (itemNo < 0 ||
        expectedSourceRev < 1 ||
        executorId.trim().isEmpty ||
        !const ['light', 'full'].contains(roomMode) ||
        (roomMode == 'light' && (hostKey != null || hostSessionId != null)) ||
        (roomMode == 'full' && (hostKey == null || hostKey.trim().isEmpty)) ||
        (hostSessionId != null && hostSessionId.trim().isEmpty)) {
      throw _taskInvalid;
    }
    final fingerprint = _taskFingerprint([
      'create',
      messageId,
      expectedSourceRev,
      itemNo,
      roomMode,
      hostKey,
      hostSessionId,
      executorId,
      ...reminder._values,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return repeated;
      }
      reminder._validate();
      final source = _taskSource(messageId, expectedSourceRev);
      if (reminder.text != null && !(source['text'] as String).contains(reminder.text!)) {
        throw _taskInvalid;
      }
      final at = _checkedNow();
      final id = _createId();
      _db.execute(
        '''
        INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,item_no,kind,
          room_mode,host_key,host_session_id,current_rev,created_at_ms,updated_at_ms)
        VALUES(?,?,?,?,?,'phone.reminder',?,?,?,1,?,?)
      ''',
        [id, archive['id'], messageId, source['session_id'], itemNo, roomMode, hostKey, hostSessionId, at, at],
      );
      _insertReminderRevision(id, 1, 'create', source, itemNo, fingerprint, executorId, reminder, at: at);
      return task(id)!;
    });
  }

  MemoryRow amendReminder({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required CompanionReminderSpec reminder,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1) {
      throw _taskInvalid;
    }
    final fingerprint = _taskFingerprint([
      'amend',
      taskId,
      expectedTaskRev,
      messageId,
      expectedSourceRev,
      itemNo,
      ...reminder._values,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return repeated;
      }
      reminder._validate();
      final previous = task(taskId);
      if (previous == null || previous['task_rev'] != expectedTaskRev || previous['kind'] != 'phone.reminder') {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id']) {
        throw _conflict;
      }
      if (reminder.text != null &&
          reminder.text != previous['reminder_text'] &&
          !(source['text'] as String).contains(reminder.text!)) {
        throw _taskInvalid;
      }
      final at = _checkedNow();
      _insertReminderRevision(
        taskId,
        expectedTaskRev + 1,
        'amend',
        source,
        itemNo,
        fingerprint,
        previous['executor_id'] as String,
        reminder,
        at: at,
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [
        expectedTaskRev + 1,
        at,
        taskId,
      ]);
      return task(taskId)!;
    });
  }

  MemoryRow cancelReminder({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1) {
      throw _taskInvalid;
    }
    final fingerprint = _taskFingerprint(['cancel', taskId, expectedTaskRev, messageId, expectedSourceRev, itemNo]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return repeated;
      }
      final previous = task(taskId);
      if (previous == null || previous['task_rev'] != expectedTaskRev || previous['kind'] != 'phone.reminder') {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id']) {
        throw _conflict;
      }
      final at = _checkedNow();
      final mayHaveRegistered = _db
          .select(
            '''
        SELECT 1 FROM companion_task_receipts
        WHERE task_id=? AND step_key='alarm.register' AND event_kind='claimed' LIMIT 1
      ''',
            [taskId],
          )
          .isNotEmpty;
      final reminder = CompanionReminderSpec(
        text: previous['reminder_text'] as String?,
        localDate: previous['local_date'] as String?,
        localTime: previous['local_time'] as String?,
        zoneId: previous['zone_id'] as String?,
        offsetSeconds: previous['offset_seconds'] as int?,
        epochMs: previous['epoch_ms'] as int?,
      );
      _insertReminderRevision(
        taskId,
        expectedTaskRev + 1,
        'cancel',
        source,
        itemNo,
        fingerprint,
        previous['executor_id'] as String,
        reminder,
        at: at,
        cancelRequested: true,
        state: mayHaveRegistered ? 'queued' : 'cancelled',
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [
        expectedTaskRev + 1,
        at,
        taskId,
      ]);
      return task(taskId)!;
    });
  }

  MemoryRow? task(String taskId) {
    final rows = _db.select('$_taskRead WHERE t.task_id=?', [taskId]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  MemoryRow? taskForCommand(String messageId, int itemNo) {
    final rows = _db.select(
      '''
      SELECT task_id FROM companion_task_revisions WHERE command_message_id=? AND command_item_no=?
    ''',
      [messageId, itemNo],
    );
    return rows.isEmpty ? null : task(rows.single['task_id'] as String);
  }

  List<MemoryRow> tasks({String? sourceSessionId, int limit = 100}) {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit');
    }
    final rows = _db.select(
      '''
      $_taskRead ${sourceSessionId == null ? '' : 'WHERE t.source_session_id=?'}
      ORDER BY t.created_at_ms DESC,t.task_id LIMIT ?
    ''',
      [?sourceSessionId, limit],
    );
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  List<MemoryRow> taskReceipts(String taskId, {int afterSeq = 0}) {
    if (afterSeq < 0) {
      throw ArgumentError.value(afterSeq, 'afterSeq');
    }
    return [
      for (final row in _db.select(
        '''
        SELECT * FROM companion_task_receipts WHERE task_id=? AND runner_receipt_seq>? ORDER BY runner_receipt_seq
      ''',
        [taskId, afterSeq],
      ))
        {
          for (final key in row.keys)
            if (key != 'detail_json') key: row[key],
          'detail': row['detail_json'] == null ? null : jsonDecode(row['detail_json'] as String),
        },
    ];
  }

  Row _taskSource(String id, int revision) {
    final rows = _db.select('SELECT * FROM memory_messages WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['source_rev'] != revision) {
      throw _conflict;
    }
    if (rows.single['role'] != 'user' || rows.single['scope'] != 'real') {
      throw const DshRemoteException('companion/task-source-invalid', 'A current real user source is required', {
        'status': 400,
      });
    }
    return rows.single;
  }

  MemoryRow? _repeatTaskCommand(String messageId, int itemNo, String fingerprint) {
    final rows = _db.select(
      '''
      SELECT task_id,request_fingerprint FROM companion_task_revisions
      WHERE command_message_id=? AND command_item_no=?
    ''',
      [messageId, itemNo],
    );
    if (rows.isEmpty) {
      return null;
    }
    if (rows.single['request_fingerprint'] != fingerprint) {
      throw _conflict;
    }
    return task(rows.single['task_id'] as String)!;
  }

  void _insertReminderRevision(
    String id,
    int revision,
    String operation,
    Row source,
    int itemNo,
    String fingerprint,
    String executorId,
    CompanionReminderSpec reminder, {
    required int at,
    bool cancelRequested = false,
    String? state,
  }) {
    _db.execute(
      '''
      INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,command_source_rev,
        command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,source_offset_minutes,source_offset_seconds,
        executor_id,reminder_text,local_date,local_time,zone_id,offset_seconds,epoch_ms,state,wait_reason,
        cancel_requested,created_at_ms,updated_at_ms)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ''',
      [
        id,
        revision,
        operation,
        source['id'],
        source['source_rev'],
        itemNo,
        fingerprint,
        source['said_at_utc'],
        source['zone_id'],
        source['offset_minutes'],
        source['offset_seconds'],
        executorId,
        reminder.text,
        reminder.localDate,
        reminder.localTime,
        reminder.zoneId,
        reminder.offsetSeconds,
        reminder.epochMs,
        state ?? (reminder.waitReason == null ? 'queued' : 'waiting'),
        cancelRequested ? null : reminder.waitReason,
        cancelRequested ? 1 : 0,
        at,
        at,
      ],
    );
  }
}

String _taskFingerprint(List<Object?> fields) => sha256.convert(utf8.encode(jsonEncode(fields))).toString();

const _taskRead = '''
  SELECT t.archive_id,t.source_message_id,t.source_session_id,t.item_no,t.kind,t.room_mode,t.host_key,t.host_session_id,
    r.*,(SELECT COALESCE(MAX(q.runner_receipt_seq),0) FROM companion_task_receipts q WHERE q.task_id=t.task_id)
      AS runner_receipt_seq
  FROM companion_tasks t JOIN companion_task_revisions r ON r.task_id=t.task_id AND r.task_rev=t.current_rev
''';

const _taskSchema = '''
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
''';
