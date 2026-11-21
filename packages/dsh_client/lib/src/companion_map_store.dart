part of 'companion_memory_store.dart';

/// One fixed geo handoff. The native adapter rechecks the selected PM identity;
/// these fields are never interpreted as an arbitrary Intent or navigation URI.
class CompanionMapSpec {
  const CompanionMapSpec({
    required this.address,
    this.placeName,
    this.targetKind = 'choice',
    this.packageName,
    this.componentName,
    this.packageUid,
    this.targetLabel,
  });

  final String address, targetKind;
  final String? placeName, packageName, componentName, targetLabel;
  final int? packageUid;

  factory CompanionMapSpec._fromRow(MemoryRow row) => CompanionMapSpec(
    address: row['address']! as String,
    placeName: row['place_name'] as String?,
    targetKind: row['target_kind']! as String,
    packageName: row['package_name'] as String?,
    componentName: row['component_name'] as String?,
    packageUid: row['package_uid'] as int?,
    targetLabel: row['target_label'] as String?,
  );

  List<Object?> get _values => [address, placeName, targetKind, packageName, componentName, packageUid, targetLabel];

  void _validate() {
    _messageText(address);
    if (placeName != null) {
      _messageText(placeName!);
    }
    if (targetKind == 'choice') {
      if (packageName != null || componentName != null || packageUid != null || targetLabel != null) {
        throw _mapInvalid;
      }
    } else {
      if (!const ['selected', 'default'].contains(targetKind) ||
          packageUid == null ||
          packageUid! < 0 ||
          [packageName, componentName].any((value) => value == null || value.isEmpty || value.trim() != value)) {
        throw _mapInvalid;
      }
      if (targetLabel != null) {
        _messageText(targetLabel!);
      }
    }
  }
}

const _mapInvalid = DshRemoteException('companion/task-invalid-request', 'Invalid map handoff agreement', {
  'status': 400,
});

/// The owning isolate writes agreements only. Native owns every map.handoff
/// claim and result in the same SQLite database; MethodChannel ACKs are not receipts.
extension CompanionMapStore on CompanionMemoryStore {
  /// Close the native-created scope before queueing a platform close message.
  /// This same-database write serializes with native's final handoff transaction;
  /// it grants nothing and does not create a task revision or execution receipt.
  void closeMapHandoffScope({required String scopeId, required String sourceSessionId}) {
    _transaction(() {
      _db.execute('UPDATE companion_map_scopes SET closed=1 WHERE scope_id=? AND source_session_id=?', [
        scopeId,
        sourceSessionId,
      ]);
    });
  }

  MemoryRow createMapOpenFromMessage({
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    String? hostKey,
    String? hostSessionId,
    required String executorId,
    required CompanionMapSpec map,
  }) {
    if (itemNo < 0 ||
        expectedSourceRev < 1 ||
        executorId.trim().isEmpty ||
        !const ['light', 'full'].contains(roomMode) ||
        (roomMode == 'light' && (hostKey != null || hostSessionId != null)) ||
        (roomMode == 'full' && (hostKey == null || hostKey.trim().isEmpty)) ||
        (hostSessionId != null && hostSessionId.trim().isEmpty)) {
      throw _mapInvalid;
    }
    map._validate();
    final fingerprint = _taskFingerprint([
      'map.create',
      messageId,
      expectedSourceRev,
      itemNo,
      roomMode,
      hostKey,
      hostSessionId,
      executorId,
      ...map._values,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return mapTask(repeated['task_id']! as String)!;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      _mapWordsInSource(map, source);
      return _createMap(source, itemNo, fingerprint, roomMode, hostKey, hostSessionId, executorId, map);
    });
  }

  MemoryRow amendMapOpen({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required CompanionMapSpec map,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1) {
      throw _mapInvalid;
    }
    map._validate();
    final fingerprint = _taskFingerprint([
      'map.amend',
      taskId,
      expectedTaskRev,
      messageId,
      expectedSourceRev,
      itemNo,
      ...map._values,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return mapTask(repeated['task_id']! as String)!;
      }
      final previous = _currentMap(taskId, expectedTaskRev);
      if (previous['cancel_requested'] == 1 ||
          const ['unknown', 'done', 'cancelled'].contains(previous['state']) ||
          _mapMayHaveHandedOff(taskId)) {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id']) {
        throw _conflict;
      }
      _mapWordsInSource(map, source, previous: previous);
      final at = _checkedNow();
      _insertMapRevision(
        taskId,
        expectedTaskRev + 1,
        'amend',
        source,
        itemNo,
        fingerprint,
        previous['executor_id']! as String,
        map,
        at,
        reopensTaskId: previous['reopens_task_id'] as String?,
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [
        expectedTaskRev + 1,
        at,
        taskId,
      ]);
      return mapTask(taskId)!;
    });
  }

  MemoryRow cancelMapOpen({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1) {
      throw _mapInvalid;
    }
    final fingerprint = _taskFingerprint(['map.cancel', taskId, expectedTaskRev, messageId, expectedSourceRev, itemNo]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return mapTask(repeated['task_id']! as String)!;
      }
      final previous = _currentMap(taskId, expectedTaskRev);
      if (previous['cancel_requested'] == 1) {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id']) {
        throw _conflict;
      }
      final at = _checkedNow();
      // Native's final current-revision check and synchronous start are in one
      // short write transaction. This commit fences every later old-rev start.
      // Any earlier, possibly performed handoff remains in its original receipt.
      _insertMapRevision(
        taskId,
        expectedTaskRev + 1,
        'cancel',
        source,
        itemNo,
        fingerprint,
        previous['executor_id']! as String,
        CompanionMapSpec._fromRow(previous),
        at,
        cancel: true,
        reopensTaskId: previous['reopens_task_id'] as String?,
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [
        expectedTaskRev + 1,
        at,
        taskId,
      ]);
      return mapTask(taskId)!;
    });
  }

  /// A new explicit user action; this never retries or rewrites the old attempt.
  MemoryRow reopenMapOpenFromMessage({
    required String oldTaskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String executorId,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1 || executorId.trim().isEmpty) {
      throw _mapInvalid;
    }
    return _transaction(() {
      // A retry reads the accepted command's immutable map, even if the old
      // task was subsequently amended or deleted. It does not re-resolve a target.
      final accepted = _db.select(
        '''
        SELECT m.* FROM companion_task_revisions r JOIN companion_map_revisions m
          ON m.task_id=r.task_id AND m.task_rev=r.task_rev
        WHERE r.command_message_id=? AND r.command_item_no=?
      ''',
        [messageId, itemNo],
      );
      final previous = accepted.isEmpty
          ? _currentMap(oldTaskId, expectedTaskRev)
          : Map<String, Object?>.from(accepted.single);
      final map = CompanionMapSpec._fromRow(previous);
      final fingerprint = _taskFingerprint([
        'map.reopen',
        oldTaskId,
        expectedTaskRev,
        messageId,
        expectedSourceRev,
        itemNo,
        executorId,
        ...map._values,
      ]);
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return mapTask(repeated['task_id']! as String)!;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id'] ||
          (messageId == previous['source_message_id'] && itemNo == previous['item_no'])) {
        throw _conflict;
      }
      return _createMap(
        source,
        itemNo,
        fingerprint,
        previous['room_mode']! as String,
        previous['host_key'] as String?,
        previous['host_session_id'] as String?,
        executorId,
        map,
        reopensTaskId: oldTaskId,
      );
    });
  }

  MemoryRow? mapTask(String taskId) {
    final current = task(taskId);
    if (current == null || current['kind'] != 'phone.map_open') {
      return null;
    }
    final map = _db.select('SELECT * FROM companion_map_revisions WHERE task_id=? AND task_rev=?', [
      taskId,
      current['task_rev'],
    ]).single;
    return {...current, ...Map<String, Object?>.from(map)};
  }

  MemoryRow _currentMap(String taskId, int revision) {
    final current = mapTask(taskId);
    if (current == null || current['task_rev'] != revision) {
      throw _conflict;
    }
    return current;
  }

  bool _mapMayHaveHandedOff(String taskId) => _db
      .select(
        '''
    SELECT 1 FROM companion_task_receipts c
    WHERE c.task_id=? AND c.step_key='map.handoff' AND c.event_kind='claimed'
      AND NOT EXISTS(SELECT 1 FROM companion_task_receipts r
        WHERE r.task_id=c.task_id AND r.task_rev=c.task_rev AND r.step_key=c.step_key
          AND r.attempt_id=c.attempt_id AND r.event_kind IN ('returned','failed','blocked','skipped')
          AND r.outcome='not_performed') LIMIT 1
  ''',
        [taskId],
      )
      .isNotEmpty;

  MemoryRow _createMap(
    Row source,
    int itemNo,
    String fingerprint,
    String roomMode,
    String? hostKey,
    String? hostSessionId,
    String executorId,
    CompanionMapSpec map, {
    String? reopensTaskId,
  }) {
    final id = _createId();
    final at = _checkedNow();
    _db.execute(
      '''
      INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,item_no,kind,
        room_mode,host_key,host_session_id,current_rev,created_at_ms,updated_at_ms)
      VALUES(?,?,?,?,?,'phone.map_open',?,?,?,1,?,?)
    ''',
      [id, archive['id'], source['id'], source['session_id'], itemNo, roomMode, hostKey, hostSessionId, at, at],
    );
    _insertMapRevision(id, 1, 'create', source, itemNo, fingerprint, executorId, map, at, reopensTaskId: reopensTaskId);
    return mapTask(id)!;
  }

  void _insertMapRevision(
    String id,
    int revision,
    String operation,
    Row source,
    int itemNo,
    String fingerprint,
    String executorId,
    CompanionMapSpec map,
    int at, {
    bool cancel = false,
    String? reopensTaskId,
  }) {
    _db.execute(
      '''
      INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,command_source_rev,
        command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,source_offset_minutes,source_offset_seconds,
        executor_id,state,wait_reason,cancel_requested,created_at_ms,updated_at_ms)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        cancel
            ? 'cancelled'
            : map.targetKind == 'choice'
            ? 'waiting'
            : 'queued',
        !cancel && map.targetKind == 'choice' ? 'map_target_choice' : null,
        cancel ? 1 : 0,
        at,
        at,
      ],
    );
    _db.execute(
      '''
      INSERT INTO companion_map_revisions(task_id,task_rev,address,place_name,target_kind,
        package_name,component_name,package_uid,target_label,reopens_task_id)
      VALUES(?,?,?,?,?,?,?,?,?,?)
    ''',
      [id, revision, ...map._values, reopensTaskId],
    );
  }
}

void _mapWordsInSource(CompanionMapSpec map, Row source, {MemoryRow? previous}) {
  final text = source['text']! as String;
  if (map.address != previous?['address'] && !text.contains(map.address) ||
      map.placeName != null && map.placeName != previous?['place_name'] && !text.contains(map.placeName!)) {
    throw _mapInvalid;
  }
}

const _mapSchema = '''
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
''';
