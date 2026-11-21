part of 'companion_memory_store.dart';

const _hostTaskInvalid = DshRemoteException('companion/task-invalid-request', 'Invalid Host task agreement', {
  'status': 400,
});

/// Explicit notes and draft-finding tasks. Remote effects remain in the original Host's
/// complete snapshot; these commands never run a generic tool or chat loop.
extension CompanionHostTaskStore on CompanionMemoryStore {
  MemoryRow createNotesTaskFromMessage({
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    required String hostKey,
    String? hostSessionId,
    required MemoryRow agreement,
    MemoryRow directoryLabels = const {},
  }) => _createHostTaskFromMessage(kind: 'host.notes_to_todo',
    messageId: messageId, expectedSourceRev: expectedSourceRev, itemNo: itemNo,
    roomMode: roomMode, hostKey: hostKey, hostSessionId: hostSessionId,
    agreement: agreement, directoryLabels: directoryLabels,
  );

  MemoryRow createFindDraftTaskFromMessage({
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    required String hostKey,
    required String directoryHostStoreId,
    String? hostSessionId,
    required MemoryRow agreement,
    MemoryRow directoryLabels = const {},
  }) => _createHostTaskFromMessage(kind: 'host.find_draft',
    messageId: messageId, expectedSourceRev: expectedSourceRev, itemNo: itemNo,
    roomMode: roomMode, hostKey: hostKey, hostSessionId: hostSessionId,
    agreement: agreement, directoryLabels: directoryLabels,
    directoryHostStoreId: directoryHostStoreId,
  );

  MemoryRow _createHostTaskFromMessage({
    required String kind,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    required String hostKey,
    String? hostSessionId,
    required MemoryRow agreement,
    MemoryRow directoryLabels = const {},
    String? directoryHostStoreId,
  }) {
    if (itemNo < 0 ||
        expectedSourceRev < 1 ||
        hostKey.trim().isEmpty ||
        !const ['light', 'full'].contains(roomMode) ||
        (hostSessionId != null && hostSessionId.trim().isEmpty) ||
        (kind == 'host.find_draft' && !_hostId(directoryHostStoreId))) {
      throw _hostTaskInvalid;
    }
    final normalized = _hostAgreement(agreement, kind);
    final fingerprint = _taskFingerprint([
      kind == 'host.notes_to_todo' ? 'notes.create' : 'find.create',
      messageId,
      expectedSourceRev,
      itemNo,
      roomMode,
      hostKey,
      hostSessionId,
      _canonicalJson(normalized),
      if (kind == 'host.find_draft') directoryHostStoreId,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return hostTask(repeated['task_id']! as String)!;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (kind == 'host.find_draft' &&
          (source['zone_id'] != (normalized['args']! as MemoryRow)['timeZone'] || source['offset_seconds'] is! int)) {
        throw _hostTaskInvalid;
      }
      final id = _createId();
      final at = _checkedNow();
      _db.execute(
        '''
        INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,item_no,
          kind,room_mode,host_key,host_session_id,current_rev,created_at_ms,updated_at_ms)
        VALUES(?,?,?,?,?,?,?,?,?,1,?,?)
      ''',
        [id, archive['id'], messageId, source['session_id'], itemNo, kind, roomMode, hostKey, hostSessionId, at, at],
      );
      _insertHostRevision(id, 1, 'create', source, itemNo, fingerprint, hostKey, normalized, at: at);
      _db.execute('INSERT INTO companion_host_tasks(task_id,host_store_id) VALUES(?,?)', [id, directoryHostStoreId]);
      final request = <String, Object?>{
        'v': 1,
        'taskId': id,
        'taskRev': 1,
        'kind': kind,
        'origin': {'sourceSessionId': source['session_id'], 'messageId': messageId, 'itemNo': itemNo},
        'hostSessionId': hostSessionId,
        ...normalized,
      };
      _db.execute(
        '''
        INSERT INTO companion_host_commands(task_id,task_rev,request_json,display_json) VALUES(?,1,?,?)
      ''',
        [id, _canonicalJson(request), jsonEncode(directoryLabels)],
      );
      return hostTask(id)!;
    });
  }

  MemoryRow amendNotesTask({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required MemoryRow agreement,
    MemoryRow? directoryLabels,
  }) => _amendHostTask(kind: 'host.notes_to_todo',
    taskId: taskId, expectedTaskRev: expectedTaskRev, messageId: messageId,
    expectedSourceRev: expectedSourceRev, itemNo: itemNo,
    agreement: agreement, directoryLabels: directoryLabels,
  );

  MemoryRow amendFindDraftTask({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required MemoryRow agreement,
    MemoryRow? directoryLabels,
  }) => _amendHostTask(kind: 'host.find_draft',
    taskId: taskId, expectedTaskRev: expectedTaskRev, messageId: messageId,
    expectedSourceRev: expectedSourceRev, itemNo: itemNo,
    agreement: agreement, directoryLabels: directoryLabels,
  );

  MemoryRow _amendHostTask({
    required String kind,
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required MemoryRow agreement,
    MemoryRow? directoryLabels,
  }) {
    final normalized = _hostAgreement(agreement, kind);
    final fingerprint = _taskFingerprint([
      kind == 'host.notes_to_todo' ? 'notes.amend' : 'find.amend',
      taskId,
      expectedTaskRev,
      messageId,
      expectedSourceRev,
      itemNo,
      _canonicalJson(normalized),
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return hostTask(repeated['task_id']! as String)!;
      }
      final current = _hostCurrent(taskId, expectedTaskRev, kind);
      if (current['cancel_requested'] == 1 || current['state'] == 'cancelled' ||
          (kind == 'host.notes_to_todo' && const ['done', 'partial'].contains(current['state']))) {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != current['source_session_id'] || itemNo < 0) {
        throw _hostTaskInvalid;
      }
      if (kind == 'host.find_draft') {
        final originalArgs = (current['agreement']! as MemoryRow)['args']! as MemoryRow;
        if ((normalized['args']! as MemoryRow)['timeZone'] != originalArgs['timeZone']) {
          throw _hostTaskInvalid;
        }
      }
      final revision = expectedTaskRev + 1;
      final operation = _createId();
      final at = _checkedNow();
      _insertHostRevision(
        taskId,
        revision,
        'amend',
        source,
        itemNo,
        fingerprint,
        current['host_key']! as String,
        normalized,
        at: at,
      );
      _db.execute(
        '''
        INSERT INTO companion_host_commands(task_id,task_rev,operation_id,request_json,display_json) VALUES(?,?,?,?,?)
      ''',
        [
          taskId,
          revision,
          operation,
          _canonicalJson({
            'v': 1,
            'operationId': operation,
            if (kind == 'host.find_draft') 'kind': kind,
            'expectedTaskRev': expectedTaskRev,
            'taskRev': revision,
            'changes': normalized,
          }),
          jsonEncode(directoryLabels ?? current['directory_labels']),
        ],
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [revision, at, taskId]);
      return hostTask(taskId)!;
    });
  }

  MemoryRow cancelNotesTask({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) => _cancelHostTask(kind: 'host.notes_to_todo',
    taskId: taskId, expectedTaskRev: expectedTaskRev, messageId: messageId,
    expectedSourceRev: expectedSourceRev, itemNo: itemNo,
  );

  MemoryRow cancelFindDraftTask({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) => _cancelHostTask(kind: 'host.find_draft',
    taskId: taskId, expectedTaskRev: expectedTaskRev, messageId: messageId,
    expectedSourceRev: expectedSourceRev, itemNo: itemNo,
  );

  MemoryRow _cancelHostTask({
    required String kind,
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) {
    final fingerprint = _taskFingerprint([
      kind == 'host.notes_to_todo' ? 'notes.cancel' : 'find.cancel',
      taskId,
      expectedTaskRev,
      messageId,
      expectedSourceRev,
      itemNo,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return hostTask(repeated['task_id']! as String)!;
      }
      final current = _hostCurrent(taskId, expectedTaskRev, kind);
      if (current['cancel_requested'] == 1) {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != current['source_session_id'] || itemNo < 0) {
        throw _hostTaskInvalid;
      }
      final agreement = current['agreement']! as MemoryRow;
      final mayHaveSent = _db
          .select(
            '''
        SELECT 1 FROM companion_host_commands WHERE task_id=? AND possible_sent_at_ms IS NOT NULL LIMIT 1
      ''',
            [taskId],
          )
          .isNotEmpty;
      final revision = expectedTaskRev + 1;
      final operation = _createId();
      final at = _checkedNow();
      _insertHostRevision(
        taskId,
        revision,
        'cancel',
        source,
        itemNo,
        fingerprint,
        current['host_key']! as String,
        agreement,
        at: at,
        cancel: true,
        state: mayHaveSent ? 'unknown' : 'cancelled',
        reason: mayHaveSent ? 'host_cancel_pending' : null,
      );
      _db.execute(
        '''
        INSERT INTO companion_host_commands(task_id,task_rev,operation_id,request_json) VALUES(?,?,?,?)
      ''',
        [
          taskId,
          revision,
          operation,
          _canonicalJson({
            'v': 1,
            'operationId': operation,
            if (kind == 'host.find_draft') 'kind': kind,
            'expectedTaskRev': expectedTaskRev,
            'taskRev': revision,
          }),
        ],
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [revision, at, taskId]);
      return hostTask(taskId)!;
    });
  }

  MemoryRow? hostTask(String taskId) {
    final current = task(taskId);
    if (current == null || !_hostTaskKinds.contains(current['kind'])) {
      return null;
    }
    final binding = _db.select('SELECT * FROM companion_host_tasks WHERE task_id=?', [taskId]).single;
    final command = _db
        .select(
          '''
      SELECT r.operation,c.request_json,c.display_json FROM companion_host_commands c
      JOIN companion_task_revisions r ON r.task_id=c.task_id AND r.task_rev=c.task_rev
      WHERE c.task_id=? AND r.operation<>'cancel' ORDER BY c.task_rev DESC LIMIT 1
    ''',
          [taskId],
        )
        .single;
    final request = Map<String, Object?>.from(jsonDecode(command['request_json']! as String) as Map);
    final agreement = command['operation'] == 'create'
        ? <String, Object?>{for (final key in _hostAgreementKeys) key: request[key]}
        : Map<String, Object?>.from(request['changes']! as Map);
    return {
      ...current,
      for (final key in binding.keys)
        if (key != 'snapshot_json') key: binding[key],
      'agreement': agreement,
      'directory_labels': jsonDecode(command['display_json']! as String),
      'snapshot': binding['snapshot_json'] == null ? null : jsonDecode(binding['snapshot_json']! as String),
    };
  }

  /// Unfinished find tasks for this actual Host, including an earlier light
  /// room and a pending remote cancellation. This query grants no dispatch.
  List<MemoryRow> pendingFindDraftTasks({required String hostKey}) => [
    for (final row in _db.select('''
      SELECT t.task_id FROM companion_tasks t
      JOIN companion_task_revisions r ON r.task_id=t.task_id AND r.task_rev=t.current_rev
      WHERE t.kind='host.find_draft' AND t.host_key=?
        AND r.state IN ('queued','waiting','running','unknown')
      ORDER BY t.created_at_ms,t.task_id
    ''', [hostKey]))
      hostTask(row['task_id']! as String)!,
  ];

  /// Previously selected source directories on this original Host. These
  /// saved labels are choices for a new explicit task, not an access grant.
  List<MemoryRow> hostTaskDirectories({required String hostKey}) {
    final rows = _db.select('''
      SELECT h.host_store_id,c.request_json,c.display_json,r.operation
      FROM companion_tasks t JOIN companion_host_tasks h ON h.task_id=t.task_id
      JOIN companion_host_commands c ON c.task_id=t.task_id
      JOIN companion_task_revisions r ON r.task_id=c.task_id AND r.task_rev=c.task_rev
      WHERE t.host_key=? AND t.kind IN ('host.notes_to_todo','host.find_draft')
        AND h.host_store_id IS NOT NULL AND r.operation IN ('create','amend')
      ORDER BY t.updated_at_ms DESC,c.task_rev DESC,t.task_id
    ''', [hostKey]);
    final seen = <(String, String)>{};
    final result = <MemoryRow>[];
    for (final row in rows) {
      final request = jsonDecode(row['request_json']! as String) as MemoryRow;
      final display = jsonDecode(row['display_json']! as String) as MemoryRow;
      final path = display['source'];
      if (path is! String || path.isEmpty) {
        continue;
      }
      final args = (row['operation'] == 'create' ? request['args'] :
        (request['changes']! as MemoryRow)['args'])! as MemoryRow;
      final hostStoreId = row['host_store_id']! as String;
      final folderRef = args['folderRef']! as String;
      if (seen.add((hostStoreId, folderRef))) {
        result.add({'hostStoreId': hostStoreId, 'folderRef': folderRef, 'displayPath': path});
      }
    }
    return result;
  }

  List<MemoryRow> hostTaskCommands(String taskId) => [
    for (final row in _db.select(
      '''
      SELECT c.*,r.operation FROM companion_host_commands c
      JOIN companion_task_revisions r ON r.task_id=c.task_id AND r.task_rev=c.task_rev
      WHERE c.task_id=? ORDER BY c.task_rev
    ''',
      [taskId],
    ))
      {
        for (final key in row.keys)
          if (key != 'request_json' && key != 'display_json') key: row[key],
        'request': jsonDecode(row['request_json']! as String),
        'directory_labels': jsonDecode(row['display_json']! as String),
      },
  ];

  /// Commit the original-store binding and possible handoff before HTTP. A
  /// previous handoff must first be queried on that same store. The caller may
  /// replay the same immutable package after that actual read, never a new ID.
  MemoryRow? prepareHostTaskOperation({
    required String taskId,
    required int taskRev,
    required String hostKey,
    required String hostStoreId,
    required bool initialOpportunity,
    bool replayAfterRead = false,
    bool retryWaiting = false,
  }) => _transaction(() {
    final current = hostTask(taskId);
    if (current == null || current['host_key'] != hostKey || !_hostId(hostStoreId)) {
      throw _conflict;
    }
    final boundStore = current['host_store_id'];
    if (boundStore != null && boundStore != hostStoreId) {
      throw const DshRemoteException('companion/task-store-mismatch', 'The original task store changed', {
        'status': 409,
      });
    }
    final commands = hostTaskCommands(taskId);
    final matching = commands.where((row) => row['task_rev'] == taskRev).toList();
    if (matching.length != 1) {
      throw _conflict;
    }
    final command = matching.single;
    final operation = command['operation'];
    final snapshot = current['snapshot'] as Map?;
    final currentRevision = current['task_rev']! as int;
    final currentOperation = commands.last['operation'];
    final originalAfterAmend =
        taskRev == 1 &&
        operation == 'create' &&
        currentOperation == 'amend' &&
        snapshot?['taskRev'] == currentRevision &&
        snapshot?['originalCreatePresent'] == false;
    final originalForWake =
        retryWaiting &&
        replayAfterRead &&
        taskRev == 1 &&
        operation == 'create' &&
        snapshot?['taskRev'] == currentRevision &&
        snapshot?['state'] == 'waiting' &&
        current['state'] == 'waiting' &&
        current['cancel_requested'] == 0;
    if (retryWaiting && !originalForWake) {
      return null;
    }
    if (taskRev != currentRevision && !originalAfterAmend && !originalForWake) {
      throw _conflict;
    }
    if (current['state'] == 'cancelled' || (current['cancel_requested'] == 1 && operation != 'cancel')) {
      return null;
    }
    if (snapshot != null &&
        (snapshot['taskRev']! as int) >= taskRev &&
        (operation != 'create' || snapshot['originalCreatePresent'] == true) &&
        !originalForWake) {
      // The current complete snapshot already accounts for this operation.
      return null;
    }
    final at = _checkedNow();
    final agreement = current['agreement']! as MemoryRow;
    final deadline = agreement['deadlineAtMs'] as int?;
    final anyPossible = commands.any((row) => row['possible_sent_at_ms'] != null);
    String? blocked;
    if (operation == 'create' && deadline != null && at >= deadline) {
      blocked = 'host_deadline';
    } else if (operation != 'cancel' && !initialOpportunity && agreement['allowQueue'] != true && !anyPossible) {
      blocked = 'host_initial_opportunity_lost';
    }
    if (blocked != null) {
      _db.execute(
        'UPDATE companion_task_revisions SET state=?,wait_reason=?,updated_at_ms=? WHERE task_id=? AND task_rev=?',
        [
          blocked == 'host_deadline' ? (anyPossible ? 'unknown' : 'failed') : 'waiting',
          blocked,
          at,
          taskId,
          currentRevision,
        ],
      );
      return null;
    }
    if (command['possible_sent_at_ms'] != null && !replayAfterRead) {
      throw const DshRemoteException('companion/task-read-required', 'Read the original task before replay', {
        'status': 409,
      });
    }
    _db.execute('UPDATE companion_host_tasks SET host_store_id=COALESCE(host_store_id,?) WHERE task_id=?', [
      hostStoreId,
      taskId,
    ]);
    _db.execute(
      '''
      UPDATE companion_host_commands SET possible_sent_at_ms=COALESCE(possible_sent_at_ms,?)
      WHERE task_id=? AND task_rev=?
    ''',
      [at, taskId, taskRev],
    );
    _db.execute(
      "UPDATE companion_task_revisions SET state='unknown',wait_reason='host_receipt_unknown',updated_at_ms=? "
      'WHERE task_id=? AND task_rev=?',
      [at, taskId, currentRevision],
    );
    return {
      ...command,
      'possible_sent_at_ms': command['possible_sent_at_ms'] ?? at,
      'newlyClaimed': command['possible_sent_at_ms'] == null,
      'request': {...(command['request']! as Map<String, Object?>), 'hostStoreId': hostStoreId},
    };
  });

  /// Save every old-revision effect and the head projection before advancing
  /// the Host watermark. HTTP errors or wake notifications never call this.
  MemoryRow importHostTaskSnapshot({required String taskId, required String hostKey, required MemoryRow snapshot}) {
    _validateHostSnapshot(snapshot);
    final encoded = _canonicalJson(snapshot);
    return _transaction(() {
      final current = hostTask(taskId);
      if (current == null ||
          current['host_key'] != hostKey ||
          snapshot['taskId'] != taskId ||
          snapshot['kind'] != current['kind'] ||
          current['host_store_id'] == null ||
          snapshot['hostStoreId'] != current['host_store_id'] ||
          (current['host_execution_id'] != null && snapshot['hostExecutionId'] != current['host_execution_id'])) {
        throw _conflict;
      }
      final original = hostTaskCommands(taskId).first['request']! as Map;
      if (snapshot['originalCreatePresent'] == true &&
          (_canonicalJson(snapshot['origin']) != _canonicalJson(original['origin']) ||
              snapshot['hostSessionId'] != original['hostSessionId'])) {
        throw _conflict;
      }
      final incomingSeq = snapshot['runnerReceiptSeq']! as int;
      final applied = current['applied_host_receipt_seq']! as int;
      if (incomingSeq < applied) {
        return current;
      }
      if (incomingSeq == applied) {
        if (_canonicalJson(current['snapshot']) != encoded) {
          throw _conflict;
        }
        if (current['wait_reason'] != 'host_receipt_unknown' || snapshot['taskRev'] != current['task_rev']) {
          return current;
        }
        // An explicit wake reuses the original create and may return the
        // exact same Host sequence. Its real reply settles this local
        // handoff projection without inventing a new Host receipt.
      }
      final previous = current['snapshot'] as Map?;
      if (previous != null) {
        if ((snapshot['taskRev']! as int) < (previous['taskRev']! as int) ||
            (previous['originalCreatePresent'] == true && snapshot['originalCreatePresent'] != true)) {
          throw _conflict;
        }
        // A complete later snapshot cannot silently lose an already observed
        // file or old step. A file's current availability is a separate GET.
        for (final old in previous['revisions']! as List) {
          final revision = old as Map;
          final matching = (snapshot['revisions']! as List).cast<Map<String, Object?>>().where(
            (item) => item['taskRev'] == revision['taskRev'],
          );
          if (matching.length != 1 ||
              revision.keys.any((key) => _canonicalJson(matching.single[key]) != _canonicalJson(revision[key]))) {
            throw _conflict;
          }
        }
        for (final old in previous['artifacts']! as List) {
          final artifact = old as Map;
          final matches = (snapshot['artifacts']! as List).where(
            (item) => (item as Map)['artifactId'] == artifact['artifactId'],
          );
          if (matches.length != 1 ||
              artifact.keys.any(
                (key) => _canonicalJson((matches.single as Map)[key]) != _canonicalJson(artifact[key]),
              )) {
            throw _conflict;
          }
        }
        for (final old in previous['steps']! as List) {
          final step = old as Map;
          final matching = (snapshot['steps']! as List).cast<Map<String, Object?>>().where(
            (item) =>
                item['taskRev'] == step['taskRev'] &&
                item['stepKey'] == step['stepKey'] &&
                item['attemptId'] == step['attemptId'],
          );
          if (matching.length != 1) {
            throw _conflict;
          }
          final completion = (step['result'] as Map<String, Object?>?)?['completion'];
          if (current['kind'] == 'host.find_draft' &&
              step['stepKey'] == 'readInputs' &&
              completion != null &&
              _canonicalJson((matching.single['result'] as Map<String, Object?>?)?['completion']) !=
                  _canonicalJson(completion)) {
            throw _conflict;
          }
        }
      }
      _db.execute(
        '''
        UPDATE companion_host_tasks SET host_execution_id=?,snapshot_json=?,applied_host_receipt_seq=? WHERE task_id=?
      ''',
        [snapshot['hostExecutionId'], encoded, incomingSeq, taskId],
      );
      final localRevision = current['task_rev']! as int;
      final remoteRevision = snapshot['taskRev']! as int;
      if (remoteRevision >= localRevision) {
        final commands = hostTaskCommands(taskId);
        final localOperation = commands.last['operation'];
        final remote = (snapshot['revisions']! as List).cast<Map<String, Object?>>().singleWhere(
          (row) => row['taskRev'] == remoteRevision,
        );
        final matches =
            remoteRevision == localRevision &&
            remote['operation'] == localOperation &&
            (localOperation == 'cancel'
                ? snapshot['cancelRequested'] == true
                : _canonicalJson(snapshot['agreement']) == _canonicalJson(current['agreement']));
        _db.execute(
          '''
          UPDATE companion_task_revisions SET state=?,wait_reason=?,updated_at_ms=? WHERE task_id=? AND task_rev=?
        ''',
          [
            matches ? snapshot['state'] : 'unknown',
            matches ? snapshot['waitReason'] : 'host_revision_conflict',
            _checkedNow(),
            taskId,
            localRevision,
          ],
        );
      }
      return hostTask(taskId)!;
    });
  }

  MemoryRow _hostCurrent(String taskId, int revision, String kind) {
    final row = hostTask(taskId);
    if (row == null || row['kind'] != kind || row['task_rev'] != revision) {
      throw _conflict;
    }
    return row;
  }

  void _insertHostRevision(
    String taskId,
    int revision,
    String operation,
    Row source,
    int itemNo,
    String fingerprint,
    String hostKey,
    MemoryRow agreement, {
    required int at,
    bool cancel = false,
    String state = 'queued',
    String? reason,
  }) {
    final args = agreement['args']! as Map;
    _db.execute(
      '''
      INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,command_source_rev,
        command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,source_offset_minutes,source_offset_seconds,
        executor_id,local_date,zone_id,state,wait_reason,cancel_requested,created_at_ms,updated_at_ms)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ''',
      [
        taskId,
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
        hostKey,
        args['localDate'],
        args['timeZone'],
        state,
        reason,
        cancel ? 1 : 0,
        at,
        at,
      ],
    );
  }
}

const _hostTaskKinds = ['host.notes_to_todo', 'host.find_draft'];
const _hostAgreementKeys = ['args', 'deadlineAtMs', 'afterExit', 'allowQueue'];
const _findArgsKeys = ['folderRef', 'scope', 'localDate', 'timeZone', 'dateBy', 'extensions'];

MemoryRow _hostAgreement(MemoryRow input, String kind) {
  final rawArgs = input['args'];
  if (input.length != _hostAgreementKeys.length ||
      !_hostAgreementKeys.every(input.containsKey) ||
      rawArgs is! Map<String, Object?> ||
      (input['deadlineAtMs'] != null &&
          (input['deadlineAtMs'] is! int ||
              (input['deadlineAtMs']! as int) < 0 ||
              (input['deadlineAtMs']! as int) > 8640000000000000)) ||
      input['allowQueue'] is! bool ||
      !const ['continue', 'pause'].contains(input['afterExit'])) {
    throw _hostTaskInvalid;
  }
  final args = Map<String, Object?>.from(rawArgs);
  final fields = kind == 'host.find_draft'
      ? _findArgsKeys
      : const ['folderRef', 'localDate', 'timeZone', 'dateBy', 'outputDirRef', 'outputName', 'writeMode'];
  if (args.length != fields.length ||
      !fields.every(args.containsKey) ||
      fields.where((key) => key != 'extensions').any(
        (key) => args[key] is! String || (args[key]! as String).trim().isEmpty,
      ) ||
      args['dateBy'] != 'modified') {
    throw _hostTaskInvalid;
  }
  for (final key in fields.where((key) => key != 'extensions')) {
    _messageText(args[key]! as String);
  }
  final date = args['localDate']! as String;
  final day = DateTime.tryParse('${date}T00:00:00Z');
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
      day == null ||
      day.toIso8601String().substring(0, 10) != date) {
    throw _hostTaskInvalid;
  }
  if (kind == 'host.find_draft') {
    final extensions = args['extensions'];
    if (!_hostId(args['folderRef']) || args['scope'] != 'currentLevel' ||
        (args['timeZone']! as String).length > 128 || RegExp(r'^[+-]').hasMatch(args['timeZone']! as String) ||
        extensions is! List<Object?> || extensions.isEmpty || extensions.toSet().length != extensions.length ||
        extensions.any((value) => !const ['md', 'txt'].contains(value))) {
      throw _hostTaskInvalid;
    }
    args['extensions'] = [for (final value in const ['md', 'txt']) if (extensions.contains(value)) value];
  } else {
    final name = args['outputName']! as String;
    if (args['writeMode'] != 'createNew' || name == '.' || name == '..' ||
        name.contains('/') || name.contains('\\') || !RegExp(r'\.(md|txt)$').hasMatch(name)) {
      throw _hostTaskInvalid;
    }
  }
  return {for (final key in _hostAgreementKeys) key: key == 'args' ? args : input[key]};
}

bool _hostId(Object? value) => value is String && value.isNotEmpty && value.length <= 128 && !value.contains('\u0000');
bool _hostCount(Object? value) => value is int && value >= 0 && value <= 9007199254740991;
bool _hostTime(Object? value) => _hostCount(value) && (value! as int) <= 8640000000000000;
bool _hostNullableText(Object? value) => value == null || value is String;
const _hostStates = ['queued', 'waiting', 'running', 'unknown', 'done', 'partial', 'failed', 'cancelled'];

void _validateHostSnapshot(MemoryRow snapshot) {
  const requiredKeys = [
    'v',
    'hostStoreId',
    'taskId',
    'hostExecutionId',
    'kind',
    'taskRev',
    'runnerReceiptSeq',
    'originalCreatePresent',
    'origin',
    'hostSessionId',
    'state',
    'waitReason',
    'cancelRequested',
    'createdAtMs',
    'updatedAtMs',
    'agreement',
    'revisions',
    'steps',
    'artifacts',
    'approval',
    'budget',
  ];
  if (!requiredKeys.every(snapshot.containsKey) ||
      snapshot['v'] != 1 ||
      !['hostStoreId', 'taskId', 'hostExecutionId'].every((key) => _hostId(snapshot[key])) ||
      !_hostTaskKinds.contains(snapshot['kind']) ||
      !_hostCount(snapshot['taskRev']) ||
      snapshot['taskRev'] == 0 ||
      !_hostCount(snapshot['runnerReceiptSeq']) ||
      snapshot['runnerReceiptSeq'] == 0 ||
      snapshot['originalCreatePresent'] is! bool ||
      snapshot['cancelRequested'] is! bool ||
      !_hostStates.contains(snapshot['state']) ||
      snapshot['state'] == 'queued' ||
      !_hostNullableText(snapshot['waitReason']) ||
      !_hostTime(snapshot['createdAtMs']) ||
      !_hostTime(snapshot['updatedAtMs']) ||
      (snapshot['hostSessionId'] != null && !_hostId(snapshot['hostSessionId'])) ||
      snapshot['revisions'] is! List ||
      snapshot['steps'] is! List ||
      snapshot['artifacts'] is! List ||
      (snapshot['agreement'] != null && snapshot['agreement'] is! Map)) {
    throw _hostTaskInvalid;
  }
  final kind = snapshot['kind']! as String;
  final origin = snapshot['origin'];
  if (snapshot['originalCreatePresent'] == true) {
    if (origin is! Map ||
        origin['sourceSessionId'] is! String ||
        (origin['sourceSessionId']! as String).isEmpty ||
        (origin['sourceSessionId']! as String).length > 256 ||
        (origin['sourceSessionId']! as String).contains('\u0000') ||
        !_hostId(origin['messageId']) ||
        !_hostCount(origin['itemNo'])) {
      throw _hostTaskInvalid;
    }
  } else if (origin != null ||
      snapshot['hostSessionId'] != null ||
      (snapshot['steps']! as List).isNotEmpty ||
      (snapshot['artifacts']! as List).isNotEmpty ||
      snapshot['approval'] != null) {
    throw _hostTaskInvalid;
  }
  if (snapshot['agreement'] != null) {
    _hostAgreement(Map<String, Object?>.from(snapshot['agreement']! as Map), kind);
  }
  final revision = snapshot['taskRev']! as int;
  final revisions = <int>{};
  final agreements = <int, MemoryRow>{};
  for (final value in snapshot['revisions']! as List) {
    if (value is! Map ||
        !_hostCount(value['taskRev']) ||
        value['taskRev'] == 0 ||
        (value['taskRev']! as int) > revision ||
        !revisions.add(value['taskRev']! as int) ||
        !const ['create', 'amend', 'cancel'].contains(value['operation']) ||
        !_hostTime(value['acceptedAtMs']) ||
        !value.containsKey('agreement') ||
        (value['agreement'] != null && value['agreement'] is! Map)) {
      throw _hostTaskInvalid;
    }
    if (value['agreement'] != null) {
      agreements[value['taskRev']! as int] = _hostAgreement(Map<String, Object?>.from(value['agreement']! as Map), kind);
    }
  }
  if (!revisions.contains(revision)) {
    throw _hostTaskInvalid;
  }
  final steps = <String>{};
  final findReports = <int, bool>{};
  final sourceRefs = <String>{};
  for (final value in snapshot['steps']! as List) {
    if (value is! Map ||
        !revisions.contains(value['taskRev']) ||
        !_hostId(value['stepKey']) ||
        !_hostId(value['attemptId']) ||
        !steps.add(jsonEncode([value['taskRev'], value['stepKey'], value['attemptId']])) ||
        !_hostStates.contains(value['state']) ||
        !_hostTime(value['startedAtMs']) ||
        !value.containsKey('finishedAtMs') ||
        (value['finishedAtMs'] != null && !_hostTime(value['finishedAtMs'])) ||
        !value.containsKey('reason') ||
        !_hostNullableText(value['reason']) ||
        !value.containsKey('result') ||
        (value['result'] != null && value['result'] is! Map)) {
      throw _hostTaskInvalid;
    }
    if (kind == 'host.find_draft' && value['stepKey'] == 'readInputs') {
      final completion = (value['result'] as Map<String, Object?>?)?['completion'];
      if (completion != null) {
        final stepRevision = value['taskRev']! as int;
        if (value['finishedAtMs'] == null || !const ['done', 'partial'].contains(value['state']) ||
            findReports.containsKey(stepRevision) || agreements[stepRevision] == null) {
          throw _hostTaskInvalid;
        }
        findReports[stepRevision] = _validateFindReport(completion,
          agreements[stepRevision]!['args']! as MemoryRow, sourceRefs);
      }
    }
  }
  final artifacts = <String>{};
  for (final value in snapshot['artifacts']! as List) {
    if (value is! Map ||
        !_hostId(value['artifactId']) ||
        !artifacts.add(value['artifactId']! as String) ||
        !revisions.contains(value['taskRev']) ||
        !_hostId(value['stepKey']) ||
        value['relativePath'] is! String ||
        (value['relativePath']! as String).isEmpty ||
        !const ['text/markdown', 'text/plain'].contains(value['mediaType']) ||
        !_hostCount(value['size']) ||
        value['sha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['sha256']! as String) ||
        !_hostTime(value['verifiedAtMs']) ||
        !_hostCount(value['sourceCount'])) {
      throw _hostTaskInvalid;
    }
  }
  if (kind == 'host.find_draft') {
    if (artifacts.isNotEmpty || (const ['done', 'partial'].contains(snapshot['state']) &&
        (findReports[revision] == null || findReports[revision] != (snapshot['state'] == 'done')))) {
      throw _hostTaskInvalid;
    }
  } else if (const ['done', 'partial'].contains(snapshot['state']) && artifacts.isEmpty) {
    throw _hostTaskInvalid;
  }
  final approval = snapshot['approval'];
  if (approval != null &&
      (approval is! Map ||
          !revisions.contains(approval['taskRev']) ||
          !['stepKey', 'agentId', 'approvalId', 'eventId'].every((key) => _hostId(approval[key])) ||
          !approval.containsKey('callId') ||
          (approval['callId'] != null && !_hostId(approval['callId'])))) {
    throw _hostTaskInvalid;
  }
  final budget = snapshot['budget'];
  if (budget is! Map ||
      budget['limitMs'] != 300000 ||
      !_hostCount(budget['spentMs']) ||
      !_hostCount(budget['heldMs'])) {
    throw _hostTaskInvalid;
  }
}

bool _validateFindReport(Object? value, MemoryRow args, Set<String> sourceRefs) {
  if (value is! MemoryRow || value['scope'] is! MemoryRow || value['coverage'] is! MemoryRow ||
      value['matches'] is! List<Object?>) {
    throw _hostTaskInvalid;
  }
  final scope = value['scope']! as MemoryRow;
  final coverage = value['coverage']! as MemoryRow;
  final matches = value['matches']! as List<Object?>;
  if (_findArgsKeys.any((key) => _canonicalJson(scope[key]) != _canonicalJson(args[key])) ||
      scope['displayPath'] is! String || (scope['displayPath']! as String).isEmpty ||
      !_findEpoch(scope['startAtMs']) || !_findEpoch(scope['endAtMs']) ||
      (scope['endAtMs']! as int) <= (scope['startAtMs']! as int) ||
      !const ['entriesChecked', 'supportedFilesChecked', 'matchingCandidates'].every((key) => _hostCount(coverage[key])) ||
      (coverage['entriesChecked']! as int) > 200 ||
      (coverage['supportedFilesChecked']! as int) > (coverage['entriesChecked']! as int) ||
      (coverage['matchingCandidates']! as int) > 21 ||
      (coverage['matchingCandidates']! as int) > (coverage['supportedFilesChecked']! as int) ||
      !const ['enumerationComplete', 'entryLimitReached', 'candidateLimitReached'].every((key) => coverage[key] is bool) ||
      coverage['gaps'] is! List<Object?> || matches.length > 20 ||
      matches.length != ((coverage['matchingCandidates']! as int) > 20 ? 20 : coverage['matchingCandidates']) ||
      (coverage['entryLimitReached'] == true && coverage['entriesChecked'] != 200) ||
      (coverage['candidateLimitReached'] == true) != (coverage['matchingCandidates'] == 21) ||
      (coverage['enumerationComplete'] == true &&
        (coverage['entryLimitReached'] == true || coverage['candidateLimitReached'] == true))) {
    throw _hostTaskInvalid;
  }
  for (final gap in coverage['gaps']! as List<Object?>) {
    if (gap is! MemoryRow || !gap.containsKey('relativePath') || !_hostNullableText(gap['relativePath']) ||
        gap['reason'] is! String || (gap['reason']! as String).isEmpty) {
      throw _hostTaskInvalid;
    }
  }
  var allOpenable = true;
  for (final match in matches) {
    if (match is! MemoryRow || !_hostId(match['sourceRef']) || !sourceRefs.add(match['sourceRef']! as String) ||
        match['relativePath'] is! String || (match['relativePath']! as String).isEmpty ||
        RegExp(r'[/\x00]').hasMatch(match['relativePath']! as String) ||
        !_hostCount(match['size']) || !_findEpoch(match['modifiedAtMs']) ||
        (match['modifiedAtMs']! as int) < (scope['startAtMs']! as int) ||
        (match['modifiedAtMs']! as int) >= (scope['endAtMs']! as int) ||
        match['modifiedOffsetSeconds'] is! int || (match['modifiedOffsetSeconds']! as int).abs() > 86400 ||
        match['version'] is! String || (match['version']! as String).isEmpty ||
        match['openable'] is! bool || !match.containsKey('reason') ||
        (match['openable'] == true ? match['reason'] != null || (match['size']! as int) > 65536 :
          match['reason'] is! String || (match['reason']! as String).isEmpty)) {
      throw _hostTaskInvalid;
    }
    allOpenable = allOpenable && match['openable'] == true;
  }
  return coverage['enumerationComplete'] == true &&
    (coverage['gaps']! as List<Object?>).isEmpty && allOpenable;
}

bool _findEpoch(Object? value) => value is int && value.abs() <= 8640000000000000;

// The Host's complete snapshot is authoritative for remote effects. Its
// watermark is independent of the phone-wide task receipt AUTOINCREMENT.
const _hostTaskSchema = '''
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
''';
