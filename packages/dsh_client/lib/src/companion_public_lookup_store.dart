part of 'companion_memory_store.dart';

class CompanionLookupSpec {
  const CompanionLookupSpec({
    required this.placeName,
    this.city,
    required this.localDate,
    required this.zoneId,
    required this.question,
    required this.deadlineAtMs,
  });

  final String placeName, localDate, zoneId, question;
  final String? city;
  final int deadlineAtMs;

  List<Object?> get _values => [placeName, city, localDate, zoneId, question, deadlineAtMs];

  void _validate() {
    _messageText(placeName);
    _messageText(question);
    final day = DateTime.tryParse('${localDate}T00:00:00Z');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(localDate) ||
        day == null ||
        day.toIso8601String().substring(0, 10) != localDate ||
        zoneId.trim().isEmpty ||
        (city != null && city!.trim().isEmpty) ||
        deadlineAtMs < 0 ||
        deadlineAtMs > 8640000000000000) {
      throw _lookupInvalid;
    }
  }
}

const _lookupInvalid = DshRemoteException('companion/lookup-invalid-request', 'Invalid public lookup', {'status': 400});

extension CompanionPublicLookupStore on CompanionMemoryStore {
  MemoryRow createLookupFromMessage({
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
    required String roomMode,
    String? hostKey,
    String? hostSessionId,
    required String executorId,
    required CompanionLookupSpec lookup,
  }) {
    if (itemNo < 0 ||
        expectedSourceRev < 1 ||
        executorId.trim().isEmpty ||
        !const ['light', 'full'].contains(roomMode) ||
        (roomMode == 'light' && (hostKey != null || hostSessionId != null)) ||
        (roomMode == 'full' &&
            (hostKey == null || hostKey.trim().isEmpty || hostSessionId == null || hostSessionId.trim().isEmpty))) {
      throw _lookupInvalid;
    }
    final fingerprint = _taskFingerprint([
      'lookup.create',
      messageId,
      expectedSourceRev,
      itemNo,
      roomMode,
      hostKey,
      hostSessionId,
      executorId,
      ...lookup._values,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return lookupTask(repeated['task_id'] as String)!;
      }
      lookup._validate();
      final source = _taskSource(messageId, expectedSourceRev);
      final at = _checkedNow();
      final id = _createId();
      _db.execute(
        '''
        INSERT INTO companion_tasks(task_id,archive_id,source_message_id,source_session_id,item_no,kind,
          room_mode,host_key,host_session_id,current_rev,created_at_ms,updated_at_ms)
        VALUES(?,?,?,?,?,'public.lookup',?,?,?,1,?,?)
      ''',
        [id, archive['id'], messageId, source['session_id'], itemNo, roomMode, hostKey, hostSessionId, at, at],
      );
      _insertLookupRevision(
        id,
        1,
        source,
        itemNo,
        fingerprint,
        executorId,
        lookup,
        at: at,
        state: at < lookup.deadlineAtMs ? 'queued' : 'failed',
        reason: at < lookup.deadlineAtMs ? null : 'lookup_deadline',
      );
      return lookupTask(id)!;
    });
  }

  MemoryRow? lookupTask(String taskId, {int? taskRev}) {
    final head = task(taskId);
    if (head == null || head['kind'] != 'public.lookup') {
      return null;
    }
    final row = <String, Object?>{...head};
    if (taskRev != null && taskRev != head['task_rev']) {
      final revisions = _db.select('SELECT * FROM companion_task_revisions WHERE task_id=? AND task_rev=?', [
        taskId,
        taskRev,
      ]);
      if (revisions.isEmpty) {
        return null;
      }
      row.addAll(revisions.single);
    }
    return {
      for (final entry in row.entries)
        if (entry.key != 'lookup_result_json') entry.key: entry.value,
      'result': row['lookup_result_json'] == null ? null : jsonDecode(row['lookup_result_json'] as String),
      'isCurrent': row['task_rev'] == head['task_rev'],
    };
  }

  /// Two matching current lookups are enough to establish ambiguity.
  List<MemoryRow> lookupTargets({required String sourceSessionId, String? placeName}) {
    final rows = _db.select(
      '''
      $_taskRead
      WHERE t.source_session_id=? AND t.kind='public.lookup' AND r.cancel_requested=0
        AND r.state IN ('queued','waiting','running','unknown')
        ${placeName == null ? '' : 'AND r.lookup_place_name=?'}
      LIMIT 2
    ''',
      [sourceSessionId, ?placeName],
    );
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  List<MemoryRow> lookupAttempts(String taskId, {int? taskRev}) => [
    for (final row in _db.select(
      '''
      SELECT * FROM companion_lookup_attempts WHERE task_id=? ${taskRev == null ? '' : 'AND task_rev=?'}
      ORDER BY rowid
    ''',
      [taskId, ?taskRev],
    ))
      _lookupAttemptRow(row),
  ];

  bool lookupIsCurrent(String taskId, int taskRev) {
    final row = lookupTask(taskId);
    return row != null &&
        row['task_rev'] == taskRev &&
        row['cancel_requested'] == 0 &&
        const ['queued', 'waiting', 'running'].contains(row['state']) &&
        _checkedNow() < (row['lookup_deadline_ms'] as int);
  }

  /// A repeated claim is readback only; callers must require newlyClaimed=true.
  MemoryRow claimLookupAttempt({
    required String taskId,
    required int expectedTaskRev,
    required String requestId,
    required String kind,
    required MemoryRow input,
    required String executorId,
    required String executionMode,
    String? instanceId,
    String? provider,
    String? model,
    int? toolUnitPriceMicroCny,
    String? toolPriceAsOf,
  }) {
    if (requestId.trim().isEmpty ||
        !const ['search', 'fetch', 'answer'].contains(kind) ||
        !const ['phone', 'host'].contains(executionMode) ||
        (executionMode == 'host' &&
            (instanceId == null ||
                instanceId.trim().isEmpty ||
                provider == null ||
                provider.trim().isEmpty ||
                model == null ||
                model.trim().isEmpty)) ||
        (executionMode == 'phone' && instanceId != null) ||
        (kind == 'answer' && (provider == null || model == null)) ||
        (toolUnitPriceMicroCny != null && (toolUnitPriceMicroCny < 0 || toolPriceAsOf == null))) {
      throw _lookupInvalid;
    }
    final normalized = _lookupInput(kind, input);
    final fingerprint = _lookupFingerprint([
      taskId,
      expectedTaskRev,
      kind,
      normalized,
      executorId,
      executionMode,
      instanceId,
      provider,
      model,
      toolUnitPriceMicroCny,
      toolPriceAsOf,
    ]);
    return _transaction(() {
      final old = _db.select('SELECT * FROM companion_lookup_attempts WHERE request_id=?', [requestId]);
      if (old.isNotEmpty) {
        if (old.single['request_fingerprint'] != fingerprint) {
          throw _conflict;
        }
        return {..._lookupAttemptRow(old.single), 'newlyClaimed': false};
      }
      final current = lookupTask(taskId);
      if (current == null ||
          !lookupIsCurrent(taskId, expectedTaskRev) ||
          current['executor_id'] != executorId ||
          (current['room_mode'] == 'light' ? 'phone' : 'host') != executionMode) {
        throw _conflict;
      }
      final attempts = lookupAttempts(taskId);
      if (attempts.any((row) => row['finished_at_ms'] == null)) {
        throw _conflict;
      }
      final used = attempts
          .where((row) => row['kind'] == kind && !(row['dispatched'] == 0 && row['finished_at_ms'] != null))
          .length;
      if (used >= (kind == 'answer' ? 1 : 2)) {
        throw const DshRemoteException('companion/lookup-attempt-limit', 'This lookup has used its attempts', {
          'status': 409,
        });
      }
      final inputJson = jsonEncode(normalized);
      if (attempts.any(
        (row) =>
            row['kind'] == kind &&
            jsonEncode(row['input']) == inputJson &&
            row['dispatched'] != 0 &&
            (row['valid_result'] == 1 || !_lookupRetryableStatus(row['http_status'] as int?)),
      )) {
        throw _conflict;
      }
      final isRetry = attempts.any(
        (row) => row['kind'] == kind && jsonEncode(row['input']) == inputJson && row['dispatched'] != 0,
      );
      if (isRetry) {
        final seen = <String>{};
        if (attempts
            .where((row) => row['dispatched'] != 0)
            .any((row) => !seen.add('${row['kind']}:${jsonEncode(row['input'])}'))) {
          throw _conflict;
        }
      }
      if (kind == 'fetch') {
        final urls = <String>{};
        for (final row in attempts.where((row) => row['kind'] == 'search' && row['valid_result'] == 1)) {
          final raw = row['toolResponse'];
          if (raw is Map && raw['results'] is List) {
            for (final hit in raw['results'] as List) {
              if (hit is Map && hit['url'] is String) {
                urls.add(hit['url'] as String);
              }
            }
          }
        }
        if (!urls.contains(normalized['url'])) {
          throw _conflict;
        }
      }
      if (kind == 'answer') {
        for (final id in normalized['fetchRequestIds'] as List) {
          final pages = attempts.where(
            (row) =>
                row['request_id'] == id &&
                row['task_rev'] == expectedTaskRev &&
                row['kind'] == 'fetch' &&
                row['valid_result'] == 1,
          );
          if (pages.length != 1 ||
              pages.single['toolResponse'] is! Map ||
              (pages.single['toolResponse'] as Map)['content'] is! String ||
              ((pages.single['toolResponse'] as Map)['content'] as String).trim().isEmpty) {
            throw _conflict;
          }
        }
      }
      final at = _checkedNow();
      final number = attempts.where((row) => row['kind'] == kind).length + 1;
      _db.execute(
        '''
        INSERT INTO companion_lookup_attempts(request_id,task_id,task_rev,kind,attempt_no,input_json,
          request_fingerprint,execution_mode,instance_id,provider,model,unit_price_micro_cny,price_as_of,
          created_at_ms,updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ''',
        [
          requestId,
          taskId,
          expectedTaskRev,
          kind,
          number,
          inputJson,
          fingerprint,
          executionMode,
          instanceId,
          provider,
          model,
          toolUnitPriceMicroCny,
          toolPriceAsOf,
          at,
          at,
        ],
      );
      _db.execute(
        "UPDATE companion_task_revisions SET state='running',wait_reason=NULL,updated_at_ms=? WHERE task_id=? AND task_rev=?",
        [at, taskId, expectedTaskRev],
      );
      _lookupReceipt(
        taskId,
        expectedTaskRev,
        kind,
        requestId,
        'claimed',
        (executionMode == 'host' ? current['host_key'] : current['executor_id']) as String,
        at,
        detail: {'executionMode': executionMode, 'instanceId': instanceId},
      );
      return {..._lookupAttempt(requestId), 'newlyClaimed': true};
    });
  }

  void observeLookupAttempt(
    String requestId, {
    bool? dispatched,
    int? httpStatus,
    MemoryRow? toolResponse,
    MemoryRow? rawUsage,
    MemoryRow? normalizedUsage,
  }) {
    if (httpStatus != null && (httpStatus < 100 || httpStatus > 599)) {
      throw _lookupInvalid;
    }
    _transaction(() {
      final row = _lookupAttempt(requestId);
      final sent = dispatched == null ? null : (dispatched ? 1 : 0);
      if ((sent != null && row['dispatched'] != null && sent != row['dispatched']) ||
          (httpStatus != null && row['http_status'] != null && httpStatus != row['http_status'])) {
        throw _conflict;
      }
      final bodyFingerprint = toolResponse == null ? null : _lookupFingerprint(toolResponse);
      if (toolResponse != null &&
          (row['kind'] == 'answer' ||
              (row['tool_response_fingerprint'] != null && row['tool_response_fingerprint'] != bodyFingerprint))) {
        throw _conflict;
      }
      final raw = _lookupMergeUsage(row['rawUsage'], rawUsage);
      final normalized = _lookupMergeUsage(row['normalizedUsage'], normalizedUsage);
      final task = lookupTask(row['task_id'] as String)!;
      final retainBody =
          task['task_rev'] == row['task_rev'] &&
          task['cancel_requested'] == 0 &&
          task['lookup_result_fingerprint'] == null;
      final at = _checkedNow();
      _db.execute(
        '''
        UPDATE companion_lookup_attempts SET dispatched=COALESCE(dispatched,?),
          http_status=COALESCE(http_status,?),tool_response_fingerprint=COALESCE(tool_response_fingerprint,?),
          tool_response_json=COALESCE(tool_response_json,?),source_metadata_json=COALESCE(source_metadata_json,?),
          raw_usage_json=?,normalized_usage_json=?,updated_at_ms=? WHERE request_id=?
      ''',
        [
          sent,
          httpStatus,
          bodyFingerprint,
          !retainBody || toolResponse == null ? null : jsonEncode(toolResponse),
          toolResponse == null ? null : jsonEncode(_lookupSourceMetadata(row, toolResponse, at)),
          raw == null ? null : jsonEncode(raw),
          normalized == null ? null : jsonEncode(normalized),
          at,
          requestId,
        ],
      );
    });
  }

  /// A lost host stream is not a final provider receipt. Keep its original
  /// claim and observed material for readback from that same host instance.
  MemoryRow markLookupUncertain(String requestId, {String reason = 'lookup_receipt_unknown'}) {
    return _transaction(() {
      final attempt = _lookupAttempt(requestId);
      final taskId = attempt['task_id'] as String;
      final revision = attempt['task_rev'] as int;
      final task = lookupTask(taskId)!;
      if (attempt['execution_mode'] != 'host' || attempt['finished_at_ms'] != null) {
        throw _conflict;
      }
      if (task['task_rev'] == revision && task['cancel_requested'] == 0 && task['lookup_result_fingerprint'] == null) {
        final at = _checkedNow();
        _db.execute(
          "UPDATE companion_task_revisions SET state='unknown',wait_reason=?,updated_at_ms=? WHERE task_id=? AND task_rev=?",
          [reason, at, taskId, revision],
        );
      }
      return lookupTask(taskId)!;
    });
  }

  /// Tool responses are original provider JSON, never normalized website status.
  MemoryRow finishLookupAttempt(
    String requestId, {
    required String terminal,
    required bool? dispatched,
    required bool complete,
    MemoryRow? toolResponse,
    String? answerText,
    MemoryRow? rawUsage,
    MemoryRow? normalizedUsage,
  }) {
    if (terminal.isEmpty) {
      throw _lookupInvalid;
    }
    return _transaction(() {
      final old = _lookupAttempt(requestId);
      final fingerprint = _lookupFingerprint([
        terminal,
        dispatched,
        complete,
        toolResponse,
        answerText,
        rawUsage,
        normalizedUsage,
      ]);
      if (old['finished_at_ms'] != null) {
        if (old['finish_fingerprint'] != fingerprint) {
          throw _conflict;
        }
        return old;
      }
      final sent = dispatched == null ? old['dispatched'] as int? : (dispatched ? 1 : 0);
      if ((old['dispatched'] != null && sent != old['dispatched']) ||
          (complete && sent == 0) ||
          (old['kind'] != 'answer' && answerText != null) ||
          (old['kind'] == 'answer' && toolResponse != null)) {
        throw _lookupInvalid;
      }
      final status = old['http_status'] as int?;
      final response = toolResponse ?? (old['toolResponse'] as Map?)?.cast<String, Object?>();
      final bodyFingerprint = response == null ? null : _lookupFingerprint(response);
      if (old['tool_response_fingerprint'] != null &&
          bodyFingerprint != null &&
          old['tool_response_fingerprint'] != bodyFingerprint) {
        throw _conflict;
      }
      final raw = _lookupMergeUsage(old['rawUsage'], rawUsage);
      final normalized = _lookupMergeUsage(old['normalizedUsage'], normalizedUsage);
      final knownEmptyFetch =
          complete &&
          status == 200 &&
          old['kind'] == 'fetch' &&
          response?['content'] is String &&
          (response!['content'] as String).trim().isEmpty;
      final knownFailure = sent == 0 || (status != null && (status < 200 || status >= 300)) || knownEmptyFetch;
      final validResult =
          complete &&
          terminal == 'complete' &&
          !knownFailure &&
          (old['kind'] == 'answer'
              ? answerText != null && answerText.trim().isNotEmpty
              : status == 200 && _lookupValidTool(old['kind'] as String, response));
      int? units;
      if (old['kind'] != 'answer') {
        if (knownFailure) {
          units = 0;
        } else if (validResult && response != null) {
          units = old['kind'] == 'search' && response['results'] is List && (response['results'] as List).isEmpty
              ? 0
              : 1;
        }
      }
      final price = old['unit_price_micro_cny'] as int?;
      final cost = units == 0 ? 0 : (units == null || price == null ? null : units * price);
      final at = _checkedNow();
      final taskId = old['task_id'] as String;
      final revision = old['task_rev'] as int;
      final current = lookupTask(taskId)!;
      final retainBody =
          current['task_rev'] == revision &&
          current['cancel_requested'] == 0 &&
          current['lookup_result_fingerprint'] == null;
      _db.execute(
        '''
        UPDATE companion_lookup_attempts SET dispatched=?,terminal=?,complete=?,valid_result=?,tool_response_json=?,
          answer_text=?,raw_usage_json=?,normalized_usage_json=?,tool_success_units=?,estimated_tool_micro_cny=?,
          source_metadata_json=COALESCE(source_metadata_json,?),tool_response_fingerprint=COALESCE(tool_response_fingerprint,?),
          finish_fingerprint=?,finished_at_ms=?,updated_at_ms=? WHERE request_id=?
      ''',
        [
          sent,
          terminal,
          complete ? 1 : 0,
          validResult ? 1 : 0,
          !retainBody || response == null ? null : jsonEncode(response),
          answerText,
          raw == null ? null : jsonEncode(raw),
          normalized == null ? null : jsonEncode(normalized),
          units,
          cost,
          response == null ? null : jsonEncode(_lookupSourceMetadata(old, response, at)),
          bodyFingerprint,
          fingerprint,
          at,
          at,
          requestId,
        ],
      );
      final original = lookupTask(taskId, taskRev: revision)!;
      _lookupReceipt(
        taskId,
        revision,
        old['kind'] as String,
        requestId,
        validResult ? 'returned' : 'failed',
        (old['execution_mode'] == 'host' ? original['host_key'] : original['executor_id']) as String,
        at,
        outcome: validResult ? 'succeeded' : (knownFailure ? 'not_performed' : 'unknown'),
        detail: {
          'terminal': terminal,
          'dispatched': sent,
          'httpStatus': status,
          'validResult': validResult,
          'toolSuccessUnits': units,
          'estimatedToolMicroCny': cost,
        },
      );
      if (!validResult && !knownFailure) {
        _db.execute(
          '''
          UPDATE companion_task_revisions SET state='unknown',wait_reason='lookup_receipt_unknown',updated_at_ms=?
          WHERE task_id=? AND task_rev=? AND cancel_requested=0
            AND state IN ('queued','waiting','running')
        ''',
          [at, taskId, revision],
        );
      } else if (current['task_rev'] == revision &&
          current['cancel_requested'] == 0 &&
          current['lookup_result_fingerprint'] == null &&
          at < (current['lookup_deadline_ms'] as int)) {
        _db.execute(
          '''
          UPDATE companion_task_revisions SET state='running',wait_reason=NULL,updated_at_ms=?
          WHERE task_id=? AND task_rev=? AND state='unknown' AND wait_reason='lookup_receipt_unknown'
        ''',
          [at, taskId, revision],
        );
      }
      return _lookupAttempt(requestId);
    });
  }

  MemoryRow finishLookup({
    required String taskId,
    required int expectedTaskRev,
    required String state,
    MemoryRow? result,
    String? reason,
  }) {
    if (!const ['done', 'partial', 'failed', 'unknown'].contains(state) || (state == 'done' && result == null)) {
      throw _lookupInvalid;
    }
    final fingerprint = _lookupFingerprint([state, result, reason]);
    return _transaction(() {
      final current = lookupTask(taskId);
      if (current == null || current['task_rev'] != expectedTaskRev || current['cancel_requested'] != 0) {
        throw _conflict;
      }
      if (current['lookup_result_fingerprint'] != null) {
        if (current['lookup_result_fingerprint'] != fingerprint) {
          throw _conflict;
        }
        return current;
      }
      final attempts = lookupAttempts(taskId, taskRev: expectedTaskRev);
      final evidence = <MemoryRow>[];
      if (result != null) {
        if (result.length != 4 ||
            result['status'] != (state == 'unknown' ? 'failed' : state) ||
            result['conclusion'] is! String ||
            (result['conclusion'] as String).trim().isEmpty ||
            result['applicable_date'] != current['local_date'] ||
            result['evidence'] is! List) {
          throw _lookupInvalid;
        }
        for (final item in result['evidence'] as List) {
          if (item is! Map ||
              item.length != 2 ||
              item['fetchRequestId'] is! String ||
              item['quote'] is! String ||
              (item['quote'] as String).trim().isEmpty) {
            throw _lookupInvalid;
          }
          final found = attempts.where(
            (row) => row['request_id'] == item['fetchRequestId'] && row['kind'] == 'fetch' && row['valid_result'] == 1,
          );
          if (found.length != 1) {
            throw _lookupInvalid;
          }
          final page = found.single;
          final raw = page['toolResponse'];
          if (raw is! Map ||
              raw['content'] is! String ||
              !(raw['content'] as String).contains(item['quote'] as String)) {
            throw _lookupInvalid;
          }
          evidence.add({
            'fetchRequestId': item['fetchRequestId'],
            'quote': item['quote'],
            'url': (page['input'] as Map)['url'],
            'title': raw['title'],
            'fetchedAtMs': ((page['sourceMetadata'] as List).single as Map)['observedAtMs'],
          });
        }
        if (state == 'done') {
          final answers = attempts.where(
            (row) => row['kind'] == 'answer' && row['valid_result'] == 1 && row['answer_text'] != null,
          );
          if (evidence.isEmpty || answers.length != 1) {
            throw _lookupInvalid;
          }
          Object? proposal;
          try {
            proposal = jsonDecode(answers.single['answer_text'] as String);
          } on FormatException {
            throw _lookupInvalid;
          }
          final inputs = (answers.single['input'] as Map)['fetchRequestIds'] as List;
          if (_lookupFingerprint(proposal) != _lookupFingerprint(result) ||
              evidence.any((row) => !inputs.contains(row['fetchRequestId']))) {
            throw _lookupInvalid;
          }
        }
      }
      final stored = result == null ? null : {...result, 'evidence': evidence};
      final at = _checkedNow();
      _db.execute(
        '''
        UPDATE companion_task_revisions SET state=?,wait_reason=?,lookup_result_json=?,
          lookup_result_fingerprint=?,updated_at_ms=? WHERE task_id=? AND task_rev=?
      ''',
        [state, reason, stored == null ? null : jsonEncode(stored), fingerprint, at, taskId, expectedTaskRev],
      );
      _db.execute('UPDATE companion_lookup_attempts SET tool_response_json=NULL WHERE task_id=?', [taskId]);
      return lookupTask(taskId)!;
    });
  }

  MemoryRow cancelLookup({
    required String taskId,
    required int expectedTaskRev,
    required String messageId,
    required int expectedSourceRev,
    required int itemNo,
  }) {
    if (itemNo < 0 || expectedTaskRev < 1 || expectedSourceRev < 1) {
      throw _lookupInvalid;
    }
    final fingerprint = _taskFingerprint([
      'lookup.cancel',
      taskId,
      expectedTaskRev,
      messageId,
      expectedSourceRev,
      itemNo,
    ]);
    return _transaction(() {
      final repeated = _repeatTaskCommand(messageId, itemNo, fingerprint);
      if (repeated != null) {
        return lookupTask(repeated['task_id'] as String)!;
      }
      final previous = lookupTask(taskId);
      if (previous == null || previous['task_rev'] != expectedTaskRev) {
        throw _conflict;
      }
      final source = _taskSource(messageId, expectedSourceRev);
      if (source['session_id'] != previous['source_session_id']) {
        throw _conflict;
      }
      final uncertainHost = lookupAttempts(
        taskId,
      ).any((row) => row['execution_mode'] == 'host' && row['dispatched'] != 0 && row['finished_at_ms'] == null);
      final at = _checkedNow();
      _insertLookupRevision(
        taskId,
        expectedTaskRev + 1,
        source,
        itemNo,
        fingerprint,
        previous['executor_id'] as String,
        CompanionLookupSpec(
          placeName: previous['lookup_place_name'] as String,
          city: previous['lookup_city'] as String?,
          localDate: previous['local_date'] as String,
          zoneId: previous['zone_id'] as String,
          question: previous['lookup_question'] as String,
          deadlineAtMs: previous['lookup_deadline_ms'] as int,
        ),
        at: at,
        cancel: true,
        state: uncertainHost ? 'unknown' : 'cancelled',
        reason: uncertainHost ? 'lookup_stop_unconfirmed' : null,
      );
      _db.execute('UPDATE companion_tasks SET current_rev=?,updated_at_ms=? WHERE task_id=?', [
        expectedTaskRev + 1,
        at,
        taskId,
      ]);
      _db.execute('UPDATE companion_lookup_attempts SET tool_response_json=NULL WHERE task_id=?', [taskId]);
      return lookupTask(taskId)!;
    });
  }

  void confirmLookupCancellation(String taskId, int expectedTaskRev, {String? instanceId}) {
    _transaction(() {
      final current = lookupTask(taskId);
      if (current == null || current['task_rev'] != expectedTaskRev || current['cancel_requested'] != 1) {
        throw _conflict;
      }
      final hostAttempts = lookupAttempts(
        taskId,
      ).where((row) => row['execution_mode'] == 'host' && row['dispatched'] != 0).toList();
      final instances = hostAttempts
          .where((row) => row['finished_at_ms'] == null)
          .map((row) => row['instance_id'] as String)
          .toSet();
      final received = _db
          .select(
            '''
        SELECT attempt_id FROM companion_task_receipts
        WHERE task_id=? AND task_rev=? AND step_key='lookup.stop' AND event_kind='returned'
      ''',
            [taskId, expectedTaskRev],
          )
          .map((row) => row['attempt_id'])
          .toSet();
      if (instanceId != null) {
        if (!hostAttempts.any((row) => row['instance_id'] == instanceId)) {
          throw _conflict;
        }
        final attemptId = 'stop:$instanceId';
        if (!received.contains(attemptId)) {
          _lookupReceipt(
            taskId,
            expectedTaskRev,
            'stop',
            attemptId,
            'returned',
            current['host_key'] as String,
            _checkedNow(),
            outcome: 'succeeded',
            detail: {'instanceId': instanceId, 'received': true, 'cancelled': true},
          );
          received.add(attemptId);
        }
      } else if (instances.any((instance) => !received.contains('stop:$instance'))) {
        throw _conflict;
      }
      if (instances.any((instance) => !received.contains('stop:$instance'))) return;
      _db.execute(
        "UPDATE companion_task_revisions SET state='cancelled',wait_reason=NULL,updated_at_ms=? WHERE task_id=? AND task_rev=?",
        [_checkedNow(), taskId, expectedTaskRev],
      );
    });
  }

  MemoryRow _lookupAttempt(String requestId) {
    final rows = _db.select('SELECT * FROM companion_lookup_attempts WHERE request_id=?', [requestId]);
    if (rows.isEmpty) {
      throw _conflict;
    }
    return _lookupAttemptRow(rows.single);
  }

  void _lookupReceipt(
    String taskId,
    int revision,
    String kind,
    String requestId,
    String event,
    String executor,
    int at, {
    String? outcome,
    required MemoryRow detail,
  }) {
    _db.execute(
      '''
      INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,executor_id,
        occurred_at_ms,outcome,detail_json) VALUES(?,?,?,?,?,?,?,?,?)
    ''',
      [taskId, revision, 'lookup.$kind', requestId, event, executor, at, outcome, jsonEncode(detail)],
    );
  }

  void _insertLookupRevision(
    String taskId,
    int revision,
    Row source,
    int itemNo,
    String fingerprint,
    String executorId,
    CompanionLookupSpec lookup, {
    required int at,
    required String state,
    String? reason,
    bool cancel = false,
  }) {
    _db.execute(
      '''
      INSERT INTO companion_task_revisions(task_id,task_rev,operation,command_message_id,command_source_rev,
        command_item_no,request_fingerprint,source_said_at_utc,source_zone_id,source_offset_minutes,source_offset_seconds,
        executor_id,local_date,zone_id,state,wait_reason,cancel_requested,created_at_ms,updated_at_ms,
        lookup_place_name,lookup_city,lookup_question,lookup_deadline_ms)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ''',
      [
        taskId,
        revision,
        cancel ? 'cancel' : 'create',
        source['id'],
        source['source_rev'],
        itemNo,
        fingerprint,
        source['said_at_utc'],
        source['zone_id'],
        source['offset_minutes'],
        source['offset_seconds'],
        executorId,
        lookup.localDate,
        lookup.zoneId,
        state,
        reason,
        cancel ? 1 : 0,
        at,
        at,
        lookup.placeName,
        lookup.city,
        lookup.question,
        lookup.deadlineAtMs,
      ],
    );
  }
}

MemoryRow _lookupAttemptRow(Row row) => {
  for (final key in row.keys)
    if (!const [
      'input_json',
      'tool_response_json',
      'raw_usage_json',
      'normalized_usage_json',
      'source_metadata_json',
    ].contains(key))
      key: row[key],
  'input': jsonDecode(row['input_json'] as String),
  'toolResponse': row['tool_response_json'] == null ? null : jsonDecode(row['tool_response_json'] as String),
  'rawUsage': row['raw_usage_json'] == null ? null : jsonDecode(row['raw_usage_json'] as String),
  'normalizedUsage': row['normalized_usage_json'] == null ? null : jsonDecode(row['normalized_usage_json'] as String),
  'sourceMetadata': row['source_metadata_json'] == null ? const [] : jsonDecode(row['source_metadata_json'] as String),
  'bodyRetained': row['tool_response_json'] != null,
};

bool _lookupValidTool(String kind, MemoryRow? raw) {
  if (kind == 'search') {
    return raw?['results'] is List &&
        (raw!['results'] as List).every((hit) => hit is Map && hit['url'] is String && hit['title'] is String);
  }
  return (raw?['title'] == null || raw?['title'] is String) &&
      raw?['content'] is String &&
      (raw!['content'] as String).trim().isNotEmpty;
}

MemoryRow? _lookupMergeUsage(Object? previous, MemoryRow? next) {
  if (previous == null) return next;
  final merged = Map<String, Object?>.from(previous as Map);
  if (next == null) return merged;
  for (final entry in next.entries) {
    final old = merged[entry.key];
    if (merged.containsKey(entry.key) && _lookupFingerprint(old) != _lookupFingerprint(entry.value)) {
      final value = entry.value;
      if (entry.key != 'events' ||
          old is! List ||
          value is! List ||
          old.length > value.length ||
          _lookupFingerprint(old) != _lookupFingerprint(value.sublist(0, old.length))) {
        throw _conflict;
      }
    }
    merged[entry.key] = entry.value;
  }
  return merged;
}

List<MemoryRow> _lookupSourceMetadata(MemoryRow attempt, MemoryRow? raw, int at) {
  if (attempt['kind'] == 'search' && raw?['results'] is List) {
    return [
      for (final hit in raw!['results'] as List)
        if (hit is Map && hit['url'] is String && hit['title'] is String)
          {
            'requestId': attempt['request_id'],
            'kind': 'search',
            'url': hit['url'],
            'title': hit['title'],
            'snippet': hit['snippet'] is String ? hit['snippet'] : null,
            'publishedAt': hit['date'] is String ? hit['date'] : null,
            'observedAtMs': at,
          },
    ];
  }
  if (attempt['kind'] == 'fetch') {
    return [
      {
        'requestId': attempt['request_id'],
        'kind': 'fetch',
        'url': (attempt['input'] as Map)['url'],
        'title': raw?['title'] is String ? raw!['title'] : null,
        'observedAtMs': at,
      },
    ];
  }
  return [];
}

bool _lookupRetryableStatus(int? status) => status == 408 || status == 429 || (status != null && status >= 500);

MemoryRow _lookupInput(String kind, MemoryRow input) {
  if (kind == 'search' && input.length == 1 && input['query'] is String) {
    final query = input['query'] as String;
    if (query.trim().isNotEmpty && query.runes.length <= 128) {
      return {'query': query};
    }
  } else if (kind == 'fetch' && input.length == 1 && input['url'] is String) {
    final url = input['url'] as String;
    final uri = Uri.tryParse(url);
    if (url.runes.length <= 8192 &&
        uri != null &&
        const ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return {'url': url};
    }
  } else if (kind == 'answer' && input.length == 1 && input['fetchRequestIds'] is List) {
    final ids = input['fetchRequestIds'] as List;
    if (ids.isNotEmpty &&
        ids.length <= 2 &&
        ids.every((id) => id is String && id.isNotEmpty) &&
        ids.toSet().length == ids.length) {
      return {'fetchRequestIds': List<String>.from(ids)};
    }
  }
  throw _lookupInvalid;
}

Object? _lookupCanonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _lookupCanonical(value[key])};
  }
  if (value is List) {
    return [for (final item in value) _lookupCanonical(item)];
  }
  return value;
}

String _lookupFingerprint(Object? value) => sha256.convert(utf8.encode(jsonEncode(_lookupCanonical(value)))).toString();

const _lookupSchema = '''
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
''';
