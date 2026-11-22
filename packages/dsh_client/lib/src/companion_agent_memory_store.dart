part of 'companion_memory_store.dart';

/// A receipt contains identities and effects, never a second copy of a reply.
class CompanionAgentMemoryResult {
  const CompanionAgentMemoryResult({
    required this.turnId,
    required this.callId,
    required this.itemNo,
    required this.state,
    required this.code,
    required this.replayed,
    required this.beforeControlRevision,
    required this.controlRevision,
    required this.changedCardIds,
    required this.currentCardRevisions,
    this.targetId,
    this.taskId,
    this.taskRev,
  });

  final String turnId, callId, state;
  final String? code, targetId, taskId;
  final int itemNo, beforeControlRevision, controlRevision;
  final int? taskRev;
  final bool replayed;
  final List<String> changedCardIds;
  final Map<String, int> currentCardRevisions;
  bool get applied => state == 'applied';
}

class _AgentMemoryRejected implements Exception {
  const _AgentMemoryRejected(this.code);
  final String code;
}

extension CompanionAgentMemoryStore on CompanionMemoryStore {
  /// One source revision owns one budget across all model continuation calls.
  /// Reading an existing closed turn does not grant a new execution opportunity.
  MemoryRow beginAgentTurn({
    required String messageId,
    required int expectedSourceRev,
    required Map<String, int> shownCardRevisions,
  }) => _transaction(() {
    _taskSource(messageId, expectedSourceRev);
    final previous = _db.select('SELECT * FROM memory_agent_turns WHERE source_message_id=? AND source_rev=?', [
      messageId,
      expectedSourceRev,
    ]);
    if (previous.isNotEmpty) return _agentTurnView(previous.single);
    _checkAgentReferences(shownCardRevisions);
    final id = _createId();
    _db.execute(
      '''
      INSERT INTO memory_agent_turns(id,source_message_id,source_rev,control_revision,shown_cards,changed_cards)
      VALUES(?,?,?,?,?,'[]')
    ''',
      [id, messageId, expectedSourceRev, archive['control_revision'], _canonicalJson(shownCardRevisions)],
    );
    return _agentTurnView(_agentTurn(id));
  });

  void closeAgentTurn(String turnId) => _transaction(() {
    _db.execute('UPDATE memory_agent_turns SET closed=1 WHERE id=?', [turnId]);
  });

  /// Only the caller that actually supplied these cards to the model grants them.
  void grantAgentCards({required String turnId, required Map<String, int> cardRevisions}) => _transaction(() {
    final turn = _agentTurn(turnId);
    try {
      _agentCurrentSource(turn);
    } on _AgentMemoryRejected {
      throw _conflict;
    }
    _checkAgentReferences(cardRevisions);
    final shown = _agentRevisions(turn['shown_cards'] as String)..addAll(cardRevisions);
    _db.execute('UPDATE memory_agent_turns SET shown_cards=? WHERE id=?', [_canonicalJson(shown), turnId]);
  });

  CompanionAgentMemoryResult? agentToolCall({required String turnId, required String callId}) {
    final rows = _db.select('SELECT * FROM memory_agent_calls WHERE turn_id=? AND call_id=?', [turnId, callId]);
    return rows.isEmpty ? null : _agentResult(rows.single, replayed: true);
  }

  /// This transaction is the shared path for chat and the memory keeper.
  /// The model decides meaning; this layer validates identities and write bounds.
  CompanionAgentMemoryResult applyAgentMemoryTool({
    required String turnId,
    required String callId,
    required String toolName,
    required MemoryRow input,
  }) => _transaction(() {
    final turn = _agentTurn(turnId);
    final (call, repeated) = _agentCall(turn, callId, toolName, input);
    if (repeated) return _agentResult(call, replayed: true);
    final before = archive['control_revision']! as int;
    try {
      final source = _agentCurrentSource(turn);
      final ({Set<String> changed, String? target}) effect;
      switch (toolName) {
        case 'remember':
          effect = _agentRemember(turn, source, input);
        case 'forget':
          final card = _agentCard(turn, _agentText(input, 'card'));
          final id = card['id']! as String;
          final changed = _removeFactRelations({id}, beforeWrite: (ids) => _agentBudget(turn, ids));
          _bumpMemory();
          _bumpControl(historyAfterSeq: _sequence());
          effect = (changed: changed, target: id);
        case 'revise':
          effect = _agentRevise(turn, source, input);
        case 'quiet':
          effect = _agentQuiet(turn, input);
        case 'cancel' || 'postpone':
          final card = _agentCard(turn, _agentText(input, 'card'));
          final id = card['id']! as String;
          final state = toolName == 'cancel' ? 'cancelled' : 'postponed';
          _agentBudget(turn, {id});
          _db.execute(
            'UPDATE memory_cards SET plan_state=?,followup=NULL,row_rev=row_rev+1,updated_at_ms=? WHERE id=?',
            [state, _checkedNow(), id],
          );
          _closeAgentFollowups(id, state);
          _bumpMemory();
          _bumpControl();
          effect = (changed: {id}, target: id);
        case 'ask_later':
          effect = _agentAskLater(turn, source, callId, input);
        case 'recall':
          _agentText(input, 'query');
          effect = (changed: <String>{}, target: null);
        default:
          throw const _AgentMemoryRejected('unknown_memory_tool');
      }
      final changed = {..._agentIds(turn['changed_cards'] as String), ...effect.changed};
      final shown = _agentRevisions(turn['shown_cards'] as String);
      for (final id in effect.changed) {
        final card = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [id]);
        if (card.isEmpty) {
          shown.remove(id);
        } else {
          shown[id] = card.single['row_rev']! as int;
        }
      }
      final after = archive['control_revision']! as int;
      _db.execute('UPDATE memory_agent_turns SET control_revision=?,shown_cards=?,changed_cards=? WHERE id=?', [
        after,
        _canonicalJson(shown),
        jsonEncode(changed.toList()..sort()),
        turnId,
      ]);
      _finishAgentCall(
        turnId,
        callId,
        state: 'applied',
        before: before,
        after: after,
        changed: effect.changed,
        targetId: effect.target,
      );
    } on _AgentMemoryRejected catch (error) {
      _finishAgentCall(turnId, callId, state: 'ignored', before: before, after: before, code: error.code);
    }
    return _agentResult(_agentStoredCall(turnId, callId), replayed: false);
  });

  /// Task adapters use this durable ordinal with the existing task fingerprint.
  /// A pending cold receipt is a lookup target, not permission to invent a call.
  CompanionAgentMemoryResult reserveAgentTaskCall({
    required String turnId,
    required String callId,
    required String toolName,
    required MemoryRow input,
  }) => _transaction(() {
    final turn = _agentTurn(turnId);
    final (call, repeated) = _agentCall(turn, callId, toolName, input);
    if (repeated) return _agentResult(call, replayed: true);
    try {
      _agentCurrentSource(turn);
    } on _AgentMemoryRejected catch (error) {
      final control = archive['control_revision']! as int;
      _finishAgentCall(turnId, callId, state: 'ignored', before: control, after: control, code: error.code);
    }
    return _agentResult(_agentStoredCall(turnId, callId), replayed: false);
  });

  /// An accepted original task can settle after its window/turn has closed.
  CompanionAgentMemoryResult finishAgentTaskCall({
    required String turnId,
    required String callId,
    String? taskId,
    String? ignoredCode,
  }) => _transaction(() {
    final turn = _agentTurn(turnId);
    final call = _agentStoredCall(turnId, callId);
    if (call['state'] != 'pending') return _agentResult(call, replayed: true);
    final task = taskForCommand(turn['source_message_id']! as String, call['item_no']! as int);
    if (taskId == null) {
      if (ignoredCode == null || task != null) throw _conflict;
    } else if (ignoredCode != null || task == null || task['task_id'] != taskId) {
      throw _conflict;
    }
    _db.execute('UPDATE memory_agent_calls SET state=?,code=?,task_id=?,task_rev=? WHERE turn_id=? AND call_id=?', [
      taskId == null ? 'ignored' : 'accepted',
      ignoredCode,
      taskId,
      task?['task_rev'],
      turnId,
      callId,
    ]);
    return _agentResult(_agentStoredCall(turnId, callId), replayed: false);
  });

  Row _agentTurn(String turnId) {
    final rows = _db.select('SELECT * FROM memory_agent_turns WHERE id=?', [turnId]);
    if (rows.isEmpty) throw _conflict;
    return rows.single;
  }

  MemoryRow _agentTurnView(Row row) => {
    ...row,
    'shown_cards': _agentRevisions(row['shown_cards'] as String),
    'changed_cards': _agentIds(row['changed_cards'] as String),
  };

  Row _agentCurrentSource(Row turn) {
    if (turn['closed'] != 0) throw const _AgentMemoryRejected('turn_closed');
    if (turn['control_revision'] != archive['control_revision']) {
      throw const _AgentMemoryRejected('control_changed');
    }
    final sources = _db.select('SELECT * FROM memory_messages WHERE id=?', [turn['source_message_id']]);
    if (sources.isEmpty || sources.single['source_rev'] != turn['source_rev']) {
      throw const _AgentMemoryRejected('source_changed');
    }
    return sources.single;
  }

  void _checkAgentReferences(Map<String, int> references) {
    for (final entry in references.entries) {
      final rows = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [entry.key]);
      if (rows.isEmpty || rows.single['row_rev'] != entry.value) throw _conflict;
    }
  }

  Row _agentCard(Row turn, String id) {
    final shown = _agentRevisions(turn['shown_cards'] as String);
    if (!shown.containsKey(id)) throw const _AgentMemoryRejected('card_not_in_turn');
    final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]);
    if (rows.isEmpty || rows.single['row_rev'] != shown[id]) {
      throw const _AgentMemoryRejected('card_changed');
    }
    return rows.single;
  }

  void _agentBudget(Row turn, Set<String> changed, {Set<String> creating = const {}}) {
    for (final id in changed.difference(creating)) {
      _agentCard(turn, id);
    }
    if ({..._agentIds(turn['changed_cards'] as String), ...changed}.length > 3) {
      throw const _AgentMemoryRejected('card_limit');
    }
  }

  ({Set<String> changed, String? target}) _agentRemember(Row turn, Row source, MemoryRow input) {
    final text = _agentText(input, 'text');
    final kind = input['kind'] ?? 'fact';
    if (!const ['fact', 'preference', 'episode'].contains(kind)) {
      throw const _AgentMemoryRejected('invalid_kind');
    }
    final keywords = _agentKeywords(input, text);
    final id = _createId();
    _agentBudget(turn, {id}, creating: {id});
    final topic = _createId();
    final at = _checkedNow();
    _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
    _db.execute(
      '''
      INSERT INTO memory_cards(id,row_rev,kind,text,keywords,pinned,scope,eligible,status,manual,topic_id,
        current_basis_seq,source_at_ms,created_at_ms,updated_at_ms,cleanup_history_complete)
      VALUES(?,1,?,?,?,0,'real',1,'current',0,?,?,?,?,?,1)
    ''',
      [
        id,
        kind,
        text,
        jsonEncode(keywords),
        topic,
        source['first_seq'],
        source['edited_at_utc'] ?? source['said_at_utc'],
        at,
        at,
      ],
    );
    _agentSourceProof(id, source);
    _bumpMemory();
    _bumpControl();
    return (changed: {id}, target: id);
  }

  ({Set<String> changed, String? target}) _agentRevise(Row turn, Row source, MemoryRow input) {
    final card = _agentCard(turn, _agentText(input, 'card'));
    final text = _agentText(input, 'text');
    final keywords = _agentKeywords(input, text);
    final id = card['id']! as String;
    final changed = _removeFactRelations({id}, retainTargetId: id, beforeWrite: (ids) => _agentBudget(turn, ids));
    _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [id]);
    _db.execute('DELETE FROM memory_card_cleanup_sources WHERE card_id=?', [id]);
    _db.execute(
      '''
      UPDATE memory_cards SET text=?,keywords=?,row_rev=row_rev+1,scope='real',eligible=1,status='current',manual=0,
        current_basis_seq=?,source_at_ms=?,event_time=NULL,followup=NULL,plan_state=NULL,expires_at_ms=NULL,
        updated_at_ms=?,cleanup_history_complete=1 WHERE id=?
    ''',
      [
        text,
        jsonEncode(keywords),
        source['first_seq'],
        source['edited_at_utc'] ?? source['said_at_utc'],
        _checkedNow(),
        id,
      ],
    );
    _agentSourceProof(id, source);
    _closeAgentFollowups(id, 'revised');
    _bumpMemory();
    _bumpControl();
    return (changed: changed, target: id);
  }

  void _agentSourceProof(String cardId, Row source) {
    _db.execute(
      'INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)',
      [cardId, _createId(), source['id'], source['source_rev'], source['text']],
    );
    _db.execute('INSERT OR IGNORE INTO memory_card_cleanup_sources(card_id,message_id) VALUES(?,?)', [
      cardId,
      source['id'],
    ]);
  }

  ({Set<String> changed, String? target}) _agentQuiet(Row turn, MemoryRow input) {
    final selected = _agentCard(turn, _agentText(input, 'card'));
    final topic = selected['topic_id']! as String;
    final mode = input['mode'];
    if (mode != 'less' && mode != 'never') throw const _AgentMemoryRejected('invalid_mode');
    final cards = _db.select('SELECT id FROM memory_cards WHERE topic_id=?', [topic]);
    if (cards.isEmpty) throw const _AgentMemoryRejected('topic_not_in_turn');
    final ids = cards.map((row) => row['id']! as String).toSet();
    _agentBudget(turn, ids);
    final anchors = _controlAnchors(topic);
    _db.execute('UPDATE memory_topics SET mode=?,control_anchors=? WHERE id=?', [mode, jsonEncode(anchors), topic]);
    _db.execute(
      'UPDATE memory_cards SET followup=NULL,maintenance_row_rev=0,row_rev=row_rev+1,updated_at_ms=? WHERE topic_id=?',
      [_checkedNow(), topic],
    );
    for (final id in ids) {
      _closeAgentFollowups(id, 'quiet');
    }
    _bumpMemory();
    _bumpControl(historyAfterSeq: mode == 'never' ? _sequence() : null);
    return (changed: ids, target: topic);
  }

  ({Set<String> changed, String? target}) _agentAskLater(Row turn, Row source, String callId, MemoryRow input) {
    final card = _agentCard(turn, _agentText(input, 'card'));
    final when = input['whenMs'];
    final at = _checkedNow();
    if (when is! int || when < at || when > 8640000000000000 - memoryFollowupWindowMs) {
      throw const _AgentMemoryRejected('invalid_time');
    }
    final id = card['id']! as String;
    _agentBudget(turn, {id});
    final topic = _db.select('SELECT mode FROM memory_topics WHERE id=?', [card['topic_id']]).single;
    if (topic['mode'] != 'normal') throw const _AgentMemoryRejected('topic_quiet');
    _db.execute('UPDATE memory_cards SET followup=NULL,plan_state=NULL,row_rev=row_rev+1,updated_at_ms=? WHERE id=?', [
      at,
      id,
    ]);
    _closeAgentFollowups(id, 'rescheduled');
    _bumpMemory();
    _bumpControl();
    final opportunity = sha256.convert(utf8.encode(_canonicalJson(['agent', turn['id'], callId]))).toString();
    _db.execute(
      '''
      INSERT INTO memory_followups(id,row_rev,time_key,card_id,card_rev,control_revision,message_id,source_rev,
        invitation,source_first_seq,said_at_utc,offset_minutes,opens_at_ms,expires_at_ms,state,agent_origin)
      VALUES(?,1,?,?,?,?,?,?,?,?,?,?,?,?,'pending',1)
    ''',
      [
        opportunity,
        'agent:$when',
        id,
        (card['row_rev']! as int) + 1,
        archive['control_revision'],
        source['id'],
        source['source_rev'],
        source['text'],
        source['first_seq'],
        source['said_at_utc'],
        source['offset_minutes'],
        when,
        when + memoryFollowupWindowMs,
      ],
    );
    return (changed: {id}, target: opportunity);
  }

  void _closeAgentFollowups(String cardId, String reason) => _db.execute(
    "UPDATE memory_followups SET state='closed',reason=?,row_rev=row_rev+1,local_line=NULL "
    "WHERE card_id=? AND agent_origin=1 AND state IN ('pending','reserved','asked')",
    [reason, cardId],
  );

  void _refreshAgentFollowups(int at) => _db.execute(
    '''
    UPDATE memory_followups SET state='closed',reason='agent_invitation_stale',row_rev=row_rev+1,local_line=NULL
    WHERE agent_origin=1 AND state IN ('pending','reserved') AND (expires_at_ms<=? OR NOT EXISTS(
      SELECT 1 FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id
      JOIN memory_messages m ON m.id=memory_followups.message_id
      WHERE c.id=memory_followups.card_id AND c.row_rev=memory_followups.card_rev
        AND c.scope='real' AND c.eligible=1 AND c.status='current' AND t.mode='normal'
        AND (c.plan_state IS NULL OR c.plan_state NOT IN ('cancelled','postponed'))
        AND (c.expires_at_ms IS NULL OR c.expires_at_ms>?)
        AND m.source_rev=memory_followups.source_rev AND m.role='user' AND m.scope='real'
    ))
  ''',
    [at, at],
  );

  (Row, bool) _agentCall(Row turn, String callId, String name, MemoryRow input) {
    if (callId.isEmpty || name.isEmpty) throw ArgumentError('A tool call needs its original identity');
    final digest = sha256.convert(utf8.encode(_canonicalJson(input))).toString();
    final rows = _db.select('SELECT * FROM memory_agent_calls WHERE turn_id=? AND call_id=?', [turn['id'], callId]);
    if (rows.isNotEmpty) {
      final row = rows.single;
      if (row['tool_name'] != name || row['input_sha256'] != digest) throw _conflict;
      return (row, true);
    }
    final maximum =
        _db
                .select(
                  '''
      SELECT MAX(item_no) AS maximum FROM (
        SELECT command_item_no AS item_no FROM companion_task_revisions WHERE command_message_id=?
        UNION ALL SELECT c.item_no FROM memory_agent_calls c JOIN memory_agent_turns t ON t.id=c.turn_id
          WHERE t.source_message_id=?
      )
    ''',
                  [turn['source_message_id'], turn['source_message_id']],
                )
                .single['maximum']
            as int?;
    final control = archive['control_revision']! as int;
    _db.execute(
      '''
      INSERT INTO memory_agent_calls(turn_id,call_id,tool_name,input_sha256,item_no,state,changed_cards,
        before_control_revision,after_control_revision) VALUES(?,?,?,?,?,'pending','[]',?,?)
    ''',
      [turn['id'], callId, name, digest, (maximum ?? -1) + 1, control, control],
    );
    return (_agentStoredCall(turn['id']! as String, callId), false);
  }

  Row _agentStoredCall(String turnId, String callId) =>
      _db.select('SELECT * FROM memory_agent_calls WHERE turn_id=? AND call_id=?', [turnId, callId]).single;

  void _finishAgentCall(
    String turnId,
    String callId, {
    required String state,
    required int before,
    required int after,
    Set<String> changed = const {},
    String? targetId,
    String? code,
  }) => _db.execute(
    'UPDATE memory_agent_calls SET state=?,code=?,target_id=?,changed_cards=?,before_control_revision=?,after_control_revision=? '
    'WHERE turn_id=? AND call_id=?',
    [state, code, targetId, jsonEncode(changed.toList()..sort()), before, after, turnId, callId],
  );

  CompanionAgentMemoryResult _agentResult(Row call, {required bool replayed}) {
    final ids = _agentIds(call['changed_cards'] as String);
    final current = <String, int>{};
    for (final id in ids) {
      final rows = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [id]);
      if (rows.isNotEmpty) current[id] = rows.single['row_rev']! as int;
    }
    return CompanionAgentMemoryResult(
      turnId: call['turn_id']! as String,
      callId: call['call_id']! as String,
      itemNo: call['item_no']! as int,
      state: call['state']! as String,
      code: call['code'] as String?,
      replayed: replayed,
      beforeControlRevision: call['before_control_revision']! as int,
      controlRevision: call['after_control_revision']! as int,
      changedCardIds: List.unmodifiable(ids),
      currentCardRevisions: Map.unmodifiable(current),
      targetId: call['target_id'] as String?,
      taskId: call['task_id'] as String?,
      taskRev: call['task_rev'] as int?,
    );
  }
}

Map<String, int> _agentRevisions(String raw) => (jsonDecode(raw) as Map<String, dynamic>).cast<String, int>();
List<String> _agentIds(String raw) => (jsonDecode(raw) as List).cast<String>();

String _agentText(MemoryRow input, String key) {
  final value = input[key];
  if (value is! String || value.trim().isEmpty) throw const _AgentMemoryRejected('content_empty');
  try {
    _messageText(value);
  } on DshRemoteException {
    throw const _AgentMemoryRejected('invalid_text');
  }
  return value;
}

List<String> _agentKeywords(MemoryRow input, String text) {
  final value = input['keywords'];
  // Keep the existing finite selector. This fallback enables an exact-text
  // query; it is not semantic retrieval or a new source/intent rule.
  if (value == null) return [text];
  if (value is! List || value.any((word) => word is! String || word.trim().isEmpty)) {
    throw const _AgentMemoryRejected('invalid_keywords');
  }
  return value.cast<String>();
}

const _agentMemorySchema = '''
CREATE TABLE memory_agent_turns (
  id TEXT PRIMARY KEY,
  source_message_id TEXT NOT NULL REFERENCES memory_messages(id) ON DELETE CASCADE,
  source_rev INTEGER NOT NULL, control_revision INTEGER NOT NULL,
  shown_cards TEXT NOT NULL, changed_cards TEXT NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0 CHECK(closed IN (0,1)),
  UNIQUE(source_message_id,source_rev)
);
CREATE TABLE memory_agent_calls (
  turn_id TEXT NOT NULL REFERENCES memory_agent_turns(id) ON DELETE CASCADE,
  call_id TEXT NOT NULL, tool_name TEXT NOT NULL, input_sha256 TEXT NOT NULL,
  item_no INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','applied','ignored','accepted')),
  code TEXT, target_id TEXT, changed_cards TEXT NOT NULL,
  before_control_revision INTEGER NOT NULL, after_control_revision INTEGER NOT NULL,
  task_id TEXT, task_rev INTEGER,
  PRIMARY KEY(turn_id,call_id)
);
''';
