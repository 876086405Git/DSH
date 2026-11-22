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
    this.recallSelection,
    this.relatedCards,
  });

  final String turnId, callId, state;
  final String? code, targetId, taskId;
  final int itemNo, beforeControlRevision, controlRevision;
  final int? taskRev;
  final bool replayed;
  final List<String> changedCardIds;
  final Map<String, int> currentCardRevisions;
  final MemorySelection? recallSelection;
  final List<MemoryRow>? relatedCards;
  bool get applied => state == 'applied';
}

class _AgentMemoryRejected implements Exception {
  const _AgentMemoryRejected(this.code);
  final String code;
}

class _AgentEntryWrite {
  const _AgentEntryWrite({
    required this.id,
    required this.previous,
    required this.collection,
    required this.characterId,
    required this.text,
    required this.kind,
    required this.keywords,
    required this.proofGroups,
    required this.cleanupSources,
    required this.references,
    required this.aliases,
    required this.basis,
    required this.sourceAt,
    required this.cleanupComplete,
    this.localDay,
    this.zoneId,
    this.eventTime,
    this.controlledTopic,
  });
  final String id, collection, text, kind;
  final String? characterId, localDay, zoneId, controlledTopic;
  final MemoryRow? eventTime;
  final Row? previous;
  final List<String> keywords, aliases;
  final List<List<MemoryRow>> proofGroups;
  final List<MemoryRow> cleanupSources;
  final Map<String, int> references;
  final int basis, sourceAt;
  final bool cleanupComplete;
}

extension CompanionAgentMemoryStore on CompanionMemoryStore {
  /// One source revision owns one budget across all model continuation calls.
  /// Reading an existing closed turn does not grant a new execution opportunity.
  MemoryRow beginAgentTurn({
    required String messageId,
    required int expectedSourceRev,
    required Map<String, int> shownCardRevisions,
  }) => _transaction(() {
    final source = _taskSource(messageId, expectedSourceRev);
    final previous = _db.select('SELECT * FROM memory_agent_turns WHERE source_message_id=? AND source_rev=?', [
      messageId,
      expectedSourceRev,
    ]);
    if (previous.isNotEmpty) return _agentTurnView(previous.single);
    _checkAgentReferences(shownCardRevisions, characterId: source['character_id'] as String?);
    final id = _createId();
    _db.execute(
      '''
      INSERT INTO memory_agent_turns(id,origin_kind,source_message_id,source_rev,character_id,
        archive_id,memory_revision,control_revision,shown_cards,changed_cards)
      VALUES(?,'chat',?,?,?,?,?,?,?,'[]')
    ''',
      [
        id,
        messageId,
        expectedSourceRev,
        source['character_id'],
        archive['id'],
        archive['memory_revision'],
        archive['control_revision'],
        _canonicalJson(shownCardRevisions),
      ],
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
      _agentCheckCurrent(turn);
    } on _AgentMemoryRejected {
      throw _conflict;
    }
    _checkAgentReferences(cardRevisions, characterId: turn['character_id'] as String?);
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
    List<String>? rankedRecallIds,
  }) => _transaction(() {
    final turn = _agentTurn(turnId);
    final (call, repeated) = _agentCall(turn, callId, toolName, input);
    if (repeated) {
      MemorySelection? selection;
      List<MemoryRow>? related;
      if (toolName == 'recall' && call['state'] == 'applied') {
        try {
          _agentCheckCurrent(turn);
          selection = _agentRecallSelection(turn, input, rankedRecallIds);
          _grantAgentSelection(turn, selection);
        } on _AgentMemoryRejected {
          // A saved read receipt is not permission to revive a closed turn.
        }
      }
      if (toolName == 'related' && call['state'] == 'applied') {
        try {
          _agentCheckCurrent(turn);
          related = _agentRelated(turn, input);
        } on _AgentMemoryRejected {
          /* A saved read is not a new grant. */
        }
      }
      return _agentResult(call, replayed: true, recallSelection: selection, relatedCards: related);
    }
    final before = archive['control_revision']! as int;
    MemorySelection? recallSelection;
    List<MemoryRow>? relatedCards;
    var forgotten = false;
    try {
      _agentCheckCurrent(turn);
      final ({Set<String> changed, String? target}) effect;
      switch (toolName) {
        case 'remember':
          effect = _agentRemember(turn, input);
        case 'forget':
          final result = _agentControlGroup(turn, input, forgetting: true);
          effect = (changed: result.changed, target: result.target);
          forgotten = result.forgotten;
        case 'revise':
          final result = _agentControlGroup(turn, input, forgetting: false);
          effect = (changed: result.changed, target: result.target);
          forgotten = result.forgotten;
        case 'person':
          effect = _agentRemember(turn, {...input, 'collection': 'person'});
        case 'diary':
          effect = _agentRemember(turn, {...input, 'collection': 'diary'});
        case 'impression':
          effect = _agentRemember(turn, {...input, 'collection': 'impression'});
        case 'merge':
          effect = _agentMerge(turn, input);
        case 'related':
          relatedCards = _agentRelated(turn, input);
          effect = (changed: <String>{}, target: null);
        case 'relationship':
          effect = _agentRelationship(turn, input);
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
          effect = _agentAskLater(turn, _agentToolSource(turn, input), callId, input);
        case 'recall':
          recallSelection = _agentRecallSelection(turn, input, rankedRecallIds);
          effect = (changed: <String>{}, target: null);
        default:
          throw const _AgentMemoryRejected('unknown_memory_tool');
      }
      final changed = {..._agentIds(turn['changed_cards'] as String), ...effect.changed};
      // A read tool can grant a fresh related set in this same transaction.
      final shown = _agentRevisions(_agentTurn(turnId)['shown_cards'] as String);
      if (recallSelection != null) {
        for (final id in recallSelection.ids) {
          shown[id] = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [id]).single['row_rev']! as int;
        }
      }
      for (final id in effect.changed) {
        final card = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [id]);
        if (card.isEmpty) {
          shown.remove(id);
        } else {
          shown[id] = card.single['row_rev']! as int;
        }
      }
      final after = archive['control_revision']! as int;
      _advanceAgentMaintenanceCommit(turn, effect.changed);
      _db.execute(
        'UPDATE memory_agent_turns SET control_revision=?,memory_revision=?,shown_cards=?,changed_cards=? WHERE id=?',
        [after, archive['memory_revision'], _canonicalJson(shown), jsonEncode(changed.toList()..sort()), turnId],
      );
      _finishAgentCall(
        turnId,
        callId,
        state: 'applied',
        before: before,
        after: after,
        changed: effect.changed,
        targetId: effect.target,
        code: forgotten ? 'forgotten' : null,
      );
    } on _AgentMemoryRejected catch (error) {
      _finishAgentCall(turnId, callId, state: 'ignored', before: before, after: before, code: error.code);
    }
    return _agentResult(
      _agentStoredCall(turnId, callId),
      replayed: false,
      recallSelection: recallSelection,
      relatedCards: relatedCards,
    );
  });

  MemorySelection _agentRecallSelection(Row turn, MemoryRow input, List<String>? rankedIds) {
    final query = _agentText(input, 'query');
    final candidates = memoryRetrievalCandidates(characterId: turn['character_id'] as String?, input: query);
    final explicit = explicitMemoryTopics(query, candidates);
    final revision = archive['control_revision']! as int;
    return rankedIds == null
        ? selectMemoryContext(
            candidates,
            input: query,
            nowMs: _checkedNow(),
            controlRevision: revision,
            explicitTopicIds: explicit,
          )
        : selectRankedMemoryContext(
            candidates,
            rankedIds: rankedIds,
            nowMs: _checkedNow(),
            controlRevision: revision,
            explicitTopicIds: explicit,
          );
  }

  void _grantAgentSelection(Row turn, MemorySelection selection) {
    final shown = _agentRevisions(turn['shown_cards'] as String);
    for (final id in selection.ids) {
      shown[id] = _db.select('SELECT row_rev FROM memory_cards WHERE id=?', [id]).single['row_rev']! as int;
    }
    _db.execute('UPDATE memory_agent_turns SET shown_cards=? WHERE id=?', [_canonicalJson(shown), turn['id']]);
  }

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
    _agentCheckCurrent(turn);
    if (turn['origin_kind'] != 'chat') throw const _AgentMemoryRejected('not_a_chat_turn');
    return _db.select('SELECT * FROM memory_messages WHERE id=?', [turn['source_message_id']]).single;
  }

  void _agentCheckCurrent(Row turn) {
    if (turn['closed'] != 0) throw const _AgentMemoryRejected('turn_closed');
    if (turn['archive_id'] != archive['id']) throw const _AgentMemoryRejected('archive_changed');
    if (turn['control_revision'] != archive['control_revision']) {
      throw const _AgentMemoryRejected('control_changed');
    }
    if (turn['origin_kind'] == 'chat') {
      final sources = _db.select('SELECT * FROM memory_messages WHERE id=?', [turn['source_message_id']]);
      if (sources.isEmpty ||
          sources.single['source_rev'] != turn['source_rev'] ||
          sources.single['character_id'] != turn['character_id']) {
        throw const _AgentMemoryRejected('source_changed');
      }
    } else {
      final claim = _agentClaim(turn['claim_id'] as String);
      if (!_agentParentCurrent(claim) || claim['kind'] != turn['origin_kind']) {
        throw const _AgentMemoryRejected('maintenance_changed');
      }
    }
  }

  MemoryRow _agentToolSource(Row turn, MemoryRow input) {
    if (turn['origin_kind'] == 'chat') return _agentCurrentSource(turn);
    final sourceId = input['source'];
    final claim = _agentClaim(turn['claim_id'] as String);
    final sources = _agentMaintenanceSources(claim, turn['character_id'] as String?);
    final matches = sources.where((source) => source['id'] == sourceId);
    if (matches.length != 1) throw const _AgentMemoryRejected('source_not_in_turn');
    return matches.single;
  }

  void _checkAgentReferences(Map<String, int> references, {required String? characterId}) {
    for (final entry in references.entries) {
      final rows = _db.select('SELECT row_rev,character_id FROM memory_cards WHERE id=?', [entry.key]);
      if (rows.isEmpty ||
          rows.single['row_rev'] != entry.value ||
          (rows.single['character_id'] != null && rows.single['character_id'] != characterId) ||
          !_memoryReferencesCurrent(entry.key)) {
        throw _conflict;
      }
    }
  }

  Row _agentCard(Row turn, String id) {
    final shown = _agentRevisions(turn['shown_cards'] as String);
    if (!shown.containsKey(id)) throw const _AgentMemoryRejected('card_not_in_turn');
    final rows = _db.select('SELECT * FROM memory_cards WHERE id=?', [id]);
    if (rows.isEmpty ||
        rows.single['row_rev'] != shown[id] ||
        (rows.single['character_id'] != null && rows.single['character_id'] != turn['character_id'])) {
      throw const _AgentMemoryRejected('card_changed');
    }
    return rows.single;
  }

  void _agentBudget(Row turn, Set<String> changed, {Set<String> creating = const {}}) {
    for (final id in changed.difference(creating)) {
      _agentCard(turn, id);
    }
    final prior = turn['origin_kind'] == 'chat'
        ? _agentIds(turn['changed_cards'] as String)
        : _agentIds(_agentClaim(turn['claim_id'] as String)['changed_cards'] as String);
    if ({...prior, ...changed}.length > 3) {
      throw const _AgentMemoryRejected('card_limit');
    }
  }

  ({Set<String> changed, String? target}) _agentRemember(Row turn, MemoryRow input) {
    final collection = input['collection'] ?? 'about_you';
    if (collection is! String ||
        !const ['about_you', 'person', 'our_story', 'diary', 'impression'].contains(collection)) {
      throw const _AgentMemoryRejected('invalid_collection');
    }
    final character = const ['our_story', 'impression'].contains(collection) ? turn['character_id'] as String? : null;
    if (const ['our_story', 'impression'].contains(collection) && character == null) {
      throw const _AgentMemoryRejected('character_missing');
    }
    String? day;
    if (collection == 'diary') {
      if (turn['origin_kind'] != 'organize') throw const _AgentMemoryRejected('diary_needs_daily_claim');
      day = _agentClaim(turn['claim_id'] as String)['local_day'] as String;
    }
    final existing = collection == 'diary'
        ? _db.select("SELECT id FROM memory_cards WHERE collection='diary' AND local_day=?", [day])
        : collection == 'impression'
        ? _db.select("SELECT id FROM memory_cards WHERE collection='impression' AND character_id=?", [character])
        : const <Row>[];
    final requested = input['card'];
    if (existing.isNotEmpty && requested != existing.single['id']) {
      throw const _AgentMemoryRejected('existing_entry_not_supplied');
    }
    if (requested != null) {
      final card = _agentCard(turn, _agentText(input, 'card'));
      if (card['collection'] != collection) throw const _AgentMemoryRejected('collection_changed');
      if (collection == 'diary') {
        if (card['local_day'] != day) throw const _AgentMemoryRejected('diary_wrong_day');
        final raw = input['sources'] ?? [input['source']];
        if (raw is! List || raw.any((value) => value is! String)) {
          throw const _AgentMemoryRejected('diary_day_source_required');
        }
        _agentCheckDiarySources(
          turn,
          _agentMaintenanceSources(
            _agentClaim(turn['claim_id'] as String),
            turn['character_id'] as String?,
          ).where((source) => raw.contains(source['id'])),
        );
      }
      final result = _agentControlGroup(turn, input, forgetting: false);
      return (changed: result.changed, target: result.target);
    }
    final id = _createId();
    final write = _agentPrepareEntry(turn, id, null, {...input, 'collection': collection}, const {}, const {});
    _agentBudget(turn, {id}, creating: {id});
    _agentValidateReferencePlan({id: write.references}, const {});
    _agentApplyEntries([write]);
    _bumpMemory();
    _bumpControl();
    return (changed: {id}, target: id);
  }

  /// The read phase contains every refusal. No public transaction is called
  /// from the write phase and no later _AgentMemoryRejected can commit a prefix.
  ({Set<String> changed, String? target, bool forgotten}) _agentControlGroup(
    Row turn,
    MemoryRow input, {
    required bool forgetting,
  }) {
    final raw = input['changes'];
    final List<MemoryRow> changes;
    if (raw == null) {
      changes = [
        {...input, if (forgetting) 'forget': true},
      ];
    } else {
      if (raw is! List || raw.isEmpty || raw.any((item) => item is! Map<String, Object?>)) {
        throw const _AgentMemoryRejected('invalid_changes');
      }
      changes = raw.cast<MemoryRow>();
    }
    final originals = <String, Row>{};
    final deleted = <String>{};
    final revised = <String, MemoryRow>{};
    for (final change in changes) {
      final id = _agentText(change, 'card');
      if (originals.containsKey(id)) throw const _AgentMemoryRejected('duplicate_card');
      originals[id] = _agentCard(turn, id);
      if (change['forget'] == true) {
        if (change['text'] != null) throw const _AgentMemoryRejected('ambiguous_change');
        deleted.add(id);
      } else {
        _agentText(change, 'text');
        revised[id] = change;
      }
    }
    final affected = _agentEffectSet(turn, originals.keys.toSet());
    _agentBudget(turn, affected);
    if (!originals.keys.toSet().containsAll(affected)) {
      throw const _AgentMemoryRejected('incomplete_effect_set');
    }
    final planned = {for (final id in revised.keys) id: (originals[id]!['row_rev'] as int) + 1};
    final prepared = <String, _AgentEntryWrite>{};
    final preparing = <String>{};
    _AgentEntryWrite? prepare(String id) {
      final change = revised[id];
      if (change == null) return null;
      final existing = prepared[id];
      if (existing != null) return existing;
      if (!preparing.add(id)) throw const _AgentMemoryRejected('reference_cycle');
      // Resolve each referenced member's validated final basis and source time
      // before the dependent's current-value check, regardless of input order.
      final write = _agentPrepareEntry(
        turn,
        id,
        originals[id],
        change,
        planned,
        deleted,
        preserveProof: deleted.isNotEmpty && raw != null,
        plannedReference: (reference) {
          final parent = prepare(reference);
          return parent == null ? null : (basis: parent.basis, sourceAt: parent.sourceAt);
        },
      );
      preparing.remove(id);
      return prepared[id] = write;
    }

    final writes = [for (final id in revised.keys) prepare(id)!];
    _agentValidateReferencePlan({for (final write in writes) write.id: write.references}, deleted);
    // Every ID/revision, retained nonempty body, reference and shared budget
    // above is settled before the first card is touched.
    _deleteCards(deleted);
    _agentApplyEntries(writes);
    for (final id in revised.keys) {
      _closeAgentFollowups(id, 'revised');
    }
    _bumpMemory();
    _bumpControl(historyAfterSeq: deleted.isEmpty ? null : _sequence());
    return (changed: affected, target: originals.keys.first, forgotten: deleted.isNotEmpty);
  }

  Set<String> _agentEffectSet(Row turn, Set<String> roots) {
    final domain = _memoryDomainCards(turn['character_id'] as String?);
    final current = domain.where((card) => _memoryReferencesCurrent(card['id'] as String)).toList();
    final affected = {...roots};
    for (final root in current.where((card) => roots.contains(card['id']))) {
      final ownRole = root['character_id'];
      // A private story cannot be a hidden author of a shared entry. Shared
      // facts may affect this captured role, never a different private role.
      final eligible = ownRole == null ? current : current.where((card) => card['character_id'] == ownRole).toList();
      affected.addAll(_planFactRelations({root['id'] as String}, domainSnapshot: eligible).cards);
    }
    final ids = domain.map((card) => card['id'] as String).toSet();
    final edges = _db.select('SELECT card_id,parent_card_id FROM memory_card_references');
    var added = true;
    while (added) {
      added = false;
      for (final edge in edges) {
        if (ids.contains(edge['card_id']) &&
            affected.contains(edge['parent_card_id']) &&
            affected.add(edge['card_id'] as String)) {
          added = true;
        }
      }
    }
    return affected;
  }

  List<MemoryRow> _agentRelated(Row turn, MemoryRow input) {
    final character = turn['character_id'] as String?;
    final domain = _memoryDomainCards(character);
    final wanted = <String>{};
    final requiredEffects = <String>{};
    final root = input['card'];
    if (root != null) {
      final card = _agentCard(turn, _agentText(input, 'card'));
      requiredEffects.addAll(_agentEffectSet(turn, {card['id'] as String}));
      wanted.addAll(requiredEffects);
      final sources = _db
          .select('SELECT DISTINCT message_id FROM memory_card_sources WHERE card_id=?', [root])
          .map((row) => row['message_id'])
          .toSet();
      for (final candidate in domain) {
        if (!_memoryReferencesCurrent(candidate['id'] as String)) continue;
        if (_db
            .select('SELECT message_id FROM memory_card_sources WHERE card_id=?', [candidate['id']])
            .any((proof) => sources.contains(proof['message_id']))) {
          wanted.add(candidate['id'] as String);
        }
      }
    }
    final shown = _agentRevisions(turn['shown_cards'] as String);
    final result = <MemoryRow>[];
    for (final card in domain) {
      final id = card['id'] as String;
      final stale = !_memoryReferencesCurrent(id);
      if (card['status'] == 'withdrawn' || (!wanted.contains(id) && !stale)) continue;
      shown[id] = card['row_rev'] as int;
      result.add({
        'id': id,
        'row_rev': card['row_rev'],
        'collection': card['collection'],
        'layer': card['layer'],
        'stale': stale,
        'required_effect': requiredEffects.contains(id),
        if (stale) 'reason': 'reference_changed',
        if (!stale) ...{
          'text': card['text'],
          'keywords': card['keywords'],
          'aliases': [
            for (final row in _db.select('SELECT alias FROM memory_person_aliases WHERE card_id=? ORDER BY alias', [
              id,
            ]))
              row['alias'],
          ],
        },
      });
    }
    _db.execute('UPDATE memory_agent_turns SET shown_cards=? WHERE id=?', [_canonicalJson(shown), turn['id']]);
    return result;
  }

  _AgentEntryWrite _agentPrepareEntry(
    Row turn,
    String id,
    Row? previous,
    MemoryRow input,
    Map<String, int> planned,
    Set<String> deleted, {
    bool preserveProof = false,
    ({int basis, int sourceAt})? Function(String)? plannedReference,
  }) {
    final text = _agentText(input, 'text');
    final collection = previous?['collection'] as String? ?? input['collection'] as String? ?? 'about_you';
    final private = const ['our_story', 'impression'].contains(collection);
    final character = private ? turn['character_id'] as String? : null;
    if (private && character == null) throw const _AgentMemoryRejected('character_missing');
    if (previous != null &&
        (previous['character_id'] != character || (input['collection'] != null && input['collection'] != collection))) {
      throw const _AgentMemoryRejected('collection_changed');
    }
    final kind = input['kind'] ?? previous?['kind'] ?? 'fact';
    if (kind is! String || !const ['fact', 'preference', 'episode'].contains(kind)) {
      throw const _AgentMemoryRejected('invalid_kind');
    }
    final references = <String, int>{};
    final preserve = preserveProof && previous != null && input['sources'] == null && input['source'] == null;
    final retained = preserve ? previous : null;
    if (retained != null && (!_memoryReferencesCurrent(id) || retained['status'] != 'current')) {
      throw const _AgentMemoryRejected('retained_proof_not_current');
    }
    final rawRefs =
        input['references'] ??
        (preserve
            ? [
                for (final row in _db.select('SELECT parent_card_id FROM memory_card_references WHERE card_id=?', [id]))
                  row['parent_card_id'] as String,
              ]
            : const <String>[]);
    if (rawRefs is! List || rawRefs.any((value) => value is! String)) {
      throw const _AgentMemoryRejected('invalid_references');
    }
    var cleanup = true;
    var basis = 0;
    var sourceAt = 0;
    for (final reference in rawRefs.cast<String>()) {
      if (reference == id || deleted.contains(reference)) throw const _AgentMemoryRejected('invalid_reference');
      final card = _agentCard(turn, reference);
      if ((card['character_id'] != null && card['character_id'] != character) ||
          (!planned.containsKey(reference) && !_memoryReferencesCurrent(reference))) {
        throw const _AgentMemoryRejected('reference_not_current');
      }
      references[reference] = planned[reference] ?? card['row_rev'] as int;
      cleanup = cleanup && card['cleanup_history_complete'] == 1;
      final preparedReference = plannedReference?.call(reference);
      basis = math.max(basis, preparedReference?.basis ?? card['current_basis_seq'] as int? ?? 0);
      sourceAt = math.max(sourceAt, preparedReference?.sourceAt ?? card['source_at_ms'] as int);
    }
    final sources = <MemoryRow>[];
    final rawSources = input['sources'] ?? (input['source'] == null ? null : [input['source']]);
    if (rawSources != null && (rawSources is! List || rawSources.any((value) => value is! String))) {
      throw const _AgentMemoryRejected('invalid_sources');
    }
    final available = turn['origin_kind'] == 'chat'
        ? <MemoryRow>[_agentCurrentSource(turn)]
        : _agentMaintenanceSources(_agentClaim(turn['claim_id'] as String), turn['character_id'] as String?);
    final wanted = rawSources == null
        ? !preserve && turn['origin_kind'] == 'chat'
              ? [turn['source_message_id'] as String]
              : <String>[]
        : (rawSources as List).cast<String>();
    for (final sourceId in wanted.toSet()) {
      final matches = available.where((row) => row['id'] == sourceId);
      if (matches.length != 1) throw const _AgentMemoryRejected('source_not_in_turn');
      final source = matches.single;
      if ((!private && source['role'] != 'user') || (private && source['character_id'] != character)) {
        throw const _AgentMemoryRejected('source_wrong_domain');
      }
      sources.add(source);
      basis = math.max(basis, source['first_seq'] as int);
      sourceAt = math.max(sourceAt, (source['edited_at_utc'] ?? source['said_at_utc']) as int);
    }
    final proofGroups = <List<MemoryRow>>[
      if (sources.isNotEmpty)
        [
          for (final source in sources)
            {'message_id': source['id'], 'source_rev': source['source_rev'], 'quote': source['text']},
        ],
    ];
    final cleanupSources = <MemoryRow>[
      for (final source in sources) {'message_id': source['id'], 'proof_withdrawn': 0},
    ];
    if (retained != null) {
      // Only this already-read card's current proofs are retained. Keep each
      // AND group and each OR alternative; the control utterance is not Y's
      // evidence. No old source body is returned to the model by this path.
      for (final group in _supportGroups(_card(retained)).values) {
        for (final proof in group) {
          final actual = _db.select('SELECT * FROM memory_messages WHERE id=? AND source_rev=? AND scope=?', [
            proof['message_id'],
            proof['source_rev'],
            'real',
          ]);
          if (actual.isEmpty ||
              !(actual.single['text'] as String).contains(proof['quote'] as String) ||
              (!private && actual.single['role'] != 'user') ||
              (private && actual.single['character_id'] != character)) {
            throw const _AgentMemoryRejected('retained_proof_not_current');
          }
        }
        proofGroups.add([for (final proof in group) Map<String, Object?>.from(proof)]);
      }
      cleanupSources.addAll([
        for (final row in _db.select(
          'SELECT message_id,proof_withdrawn FROM memory_card_cleanup_sources WHERE card_id=?',
          [id],
        ))
          Map<String, Object?>.from(row),
      ]);
      cleanup = cleanup && retained['cleanup_history_complete'] == 1;
      basis = math.max(basis, retained['current_basis_seq'] as int? ?? 0);
      sourceAt = math.max(sourceAt, retained['source_at_ms'] as int);
    }
    if (proofGroups.isEmpty && references.isEmpty) throw const _AgentMemoryRejected('source_not_in_turn');
    if (previous != null &&
        !canApplyMemoryCurrentValue(
          proposedBasisSeq: basis,
          currentBasisSeq: previous['current_basis_seq'] as int? ?? 0,
        )) {
      throw const _AgentMemoryRejected('older_than_current');
    }
    final rawAliases = input['aliases'];
    final aliases = collection != 'person'
        ? const <String>[]
        : rawAliases == null && previous != null
        ? [
            for (final row in _db.select('SELECT alias FROM memory_person_aliases WHERE card_id=?', [id]))
              row['alias'] as String,
          ]
        : rawAliases is List && rawAliases.every((value) => value is String && value.trim().isNotEmpty)
        ? rawAliases.cast<String>().toSet().toList()
        : <String>[];
    if (collection == 'person' && aliases.isEmpty) throw const _AgentMemoryRejected('person_alias_required');
    for (final alias in aliases) {
      _agentText({'alias': alias}, 'alias');
    }
    String? day = previous?['local_day'] as String?;
    String? zone = previous?['day_zone_id'] as String?;
    if (collection == 'diary' && previous == null) {
      if (turn['origin_kind'] != 'organize') throw const _AgentMemoryRejected('diary_needs_daily_claim');
      final claim = _agentClaim(turn['claim_id'] as String);
      _agentCheckDiarySources(turn, sources);
      day = claim['local_day'] as String;
      zone = claim['zone_id'] as String;
    }
    MemoryRow? eventTime;
    if (input.containsKey('event_time')) {
      if (sources.isEmpty) throw const _AgentMemoryRejected('invalid_event_time');
      try {
        validateMemoryEventTime(input['event_time'], sourceText: sources.first['text'] as String);
      } on FormatException {
        throw const _AgentMemoryRejected('invalid_event_time');
      }
      eventTime = Map<String, Object?>.from(input['event_time'] as MemoryRow);
    }
    final controlled = previous == null
        ? _controlledTopics(
            // A full source can contain several independent facts. Only this card's
            // wording may match a saved control, not another clause in that source.
            {'text': text, 'evidence': const <MemoryRow>[]},
            controls: [
              for (final row in _db.select(
                "SELECT id,control_anchors FROM memory_topics WHERE character_id IS ? AND mode IN ('less','never')",
                [character],
              ))
                {
                  'topic_id': row['id'],
                  'anchors': (jsonDecode(row['control_anchors'] as String) as List).cast<String>(),
                },
            ],
          )
        : const <String>[];
    if (controlled.length > 1) throw const _AgentMemoryRejected('ambiguous_controlled_topic');
    var keywords = _agentKeywords(input, text);
    if (retained != null && input['keywords'] == null) {
      // Omitted keywords follow the rewritten fact, not a removed old clause.
      // Keep old terms still present in that body; otherwise use its text.
      final previousKeywords = (jsonDecode(retained['keywords'] as String) as List).cast<String>();
      final normalizedText = normalizeMemoryText(text);
      final safeKeywords = previousKeywords
          .where((word) => normalizedText.contains(normalizeMemoryText(word)))
          .toList();
      if (previousKeywords.isEmpty || safeKeywords.isNotEmpty) keywords = safeKeywords;
    }
    return _AgentEntryWrite(
      id: id,
      previous: previous,
      collection: collection,
      characterId: character,
      text: text,
      kind: kind,
      keywords: keywords,
      proofGroups: proofGroups,
      cleanupSources: cleanupSources,
      references: references,
      aliases: aliases,
      basis: basis,
      sourceAt: sourceAt,
      cleanupComplete: cleanup,
      localDay: day,
      zoneId: zone,
      eventTime: eventTime,
      controlledTopic: controlled.isEmpty ? null : controlled.single,
    );
  }

  void _agentCheckDiarySources(Row turn, Iterable<MemoryRow> sources) {
    final claim = _agentClaim(turn['claim_id'] as String);
    if (!sources.any((source) => source['role'] == 'user' && _agentSourceOnDay(source, claim['local_day'] as String))) {
      throw const _AgentMemoryRejected('diary_day_source_required');
    }
  }

  void _agentValidateReferencePlan(Map<String, Map<String, int>> planned, Set<String> deleted) {
    final done = <String>{};
    void visit(String id, Set<String> visiting) {
      if (deleted.contains(id) || !visiting.add(id)) throw const _AgentMemoryRejected('reference_cycle');
      if (done.contains(id)) {
        visiting.remove(id);
        return;
      }
      final parents =
          planned[id]?.keys ??
          _db
              .select('SELECT parent_card_id FROM memory_card_references WHERE card_id=?', [id])
              .map((row) => row['parent_card_id'] as String);
      for (final parent in parents) {
        visit(parent, visiting);
      }
      visiting.remove(id);
      done.add(id);
    }

    for (final id in planned.keys) {
      visit(id, <String>{});
    }
  }

  void _agentApplyEntries(List<_AgentEntryWrite> writes) {
    final remaining = {for (final write in writes) write.id: write};
    final at = _checkedNow();
    while (remaining.isNotEmpty) {
      // Acyclicity was checked while still read-only. This ordering also lets
      // cleanup origins follow another member's planned final revision.
      final ready = remaining.values.firstWhere((write) => !write.references.keys.any(remaining.containsKey));
      final previous = ready.previous;
      final topic = previous?['topic_id'] as String? ?? ready.controlledTopic ?? _createId();
      if (previous == null) {
        if (ready.controlledTopic == null) {
          _db.execute('INSERT INTO memory_topics(id,character_id) VALUES(?,?)', [topic, ready.characterId]);
        }
        _db.execute(
          '''
          INSERT INTO memory_cards(id,row_rev,kind,text,keywords,pinned,scope,eligible,status,manual,topic_id,
            current_basis_seq,source_at_ms,event_time,created_at_ms,updated_at_ms,cleanup_history_complete,
            collection,character_id,local_day,day_zone_id)
          VALUES(?,1,?,?,?,0,'real',1,'current',0,?,?,?,?,?,?,?,?,?,?,?)
        ''',
          [
            ready.id,
            ready.kind,
            ready.text,
            jsonEncode(ready.keywords),
            topic,
            ready.basis,
            ready.sourceAt,
            ready.eventTime == null ? null : jsonEncode(ready.eventTime),
            at,
            at,
            ready.cleanupComplete ? 1 : 0,
            ready.collection,
            ready.characterId,
            ready.localDay,
            ready.zoneId,
          ],
        );
      } else {
        _db.execute(
          '''
          UPDATE memory_cards SET row_rev=row_rev+1,kind=?,text=?,keywords=?,scope='real',eligible=1,status='current',
            manual=0,current_basis_seq=?,source_at_ms=?,event_time=?,followup=NULL,plan_state=NULL,expires_at_ms=NULL,
            maintenance_row_rev=0,updated_at_ms=?,cleanup_history_complete=? WHERE id=?
        ''',
          [
            ready.kind,
            ready.text,
            jsonEncode(ready.keywords),
            ready.basis,
            ready.sourceAt,
            ready.eventTime == null ? null : jsonEncode(ready.eventTime),
            at,
            ready.cleanupComplete ? 1 : 0,
            ready.id,
          ],
        );
        _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [ready.id]);
        _db.execute('DELETE FROM memory_card_cleanup_sources WHERE card_id=?', [ready.id]);
        _db.execute('DELETE FROM memory_card_references WHERE card_id=?', [ready.id]);
        _db.execute('DELETE FROM memory_person_aliases WHERE card_id=?', [ready.id]);
      }
      for (final proofs in ready.proofGroups) {
        final group = _createId();
        for (final proof in proofs) {
          _db.execute(
            'INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)',
            [ready.id, group, proof['message_id'], proof['source_rev'], proof['quote']],
          );
        }
      }
      for (final origin in ready.cleanupSources) {
        _db.execute(
          'INSERT OR IGNORE INTO memory_card_cleanup_sources(card_id,message_id,proof_withdrawn) VALUES(?,?,?)',
          [ready.id, origin['message_id'], origin['proof_withdrawn']],
        );
      }
      for (final reference in ready.references.entries) {
        _db.execute('INSERT INTO memory_card_references(card_id,parent_card_id,parent_row_rev) VALUES(?,?,?)', [
          ready.id,
          reference.key,
          reference.value,
        ]);
        _db.execute(
          '''
          INSERT INTO memory_card_cleanup_sources(card_id,message_id,proof_withdrawn)
          SELECT ?,message_id,proof_withdrawn FROM memory_card_cleanup_sources WHERE card_id=?
          ON CONFLICT(card_id,message_id) DO UPDATE SET
            proof_withdrawn=MAX(memory_card_cleanup_sources.proof_withdrawn,excluded.proof_withdrawn)
        ''',
          [ready.id, reference.key],
        );
      }
      for (final alias in ready.aliases) {
        _db.execute('INSERT INTO memory_person_aliases(card_id,alias,normalized_alias) VALUES(?,?,?)', [
          ready.id,
          alias,
          normalizeMemoryText(alias),
        ]);
      }
      remaining.remove(ready.id);
    }
  }

  ({Set<String> changed, String? target}) _agentMerge(Row turn, MemoryRow input) {
    final targetId = _agentText(input, 'card');
    final rawFrom = input['from'];
    if (rawFrom is! List || rawFrom.isEmpty || rawFrom.any((value) => value is! String)) {
      throw const _AgentMemoryRejected('invalid_merge');
    }
    final fromIds = rawFrom.cast<String>().toSet();
    if (fromIds.contains(targetId) || fromIds.length != rawFrom.length) {
      throw const _AgentMemoryRejected('duplicate_card');
    }
    final rows = {
      for (final id in [targetId, ...fromIds]) id: _agentCard(turn, id),
    };
    final target = rows[targetId]!;
    for (final row in rows.values) {
      if (row['collection'] != target['collection'] ||
          row['character_id'] != target['character_id'] ||
          !_memoryReferencesCurrent(row['id'] as String)) {
        throw const _AgentMemoryRejected('merge_domain_changed');
      }
    }
    final rawUpdates = input['updates'] ?? const <MemoryRow>[];
    if (rawUpdates is! List || rawUpdates.any((value) => value is! Map<String, Object?>)) {
      throw const _AgentMemoryRejected('invalid_changes');
    }
    final updateInputs = <String, MemoryRow>{};
    for (final update in rawUpdates.cast<MemoryRow>()) {
      final id = _agentText(update, 'card');
      if (rows.containsKey(id) || updateInputs.containsKey(id) || update['forget'] == true) {
        throw const _AgentMemoryRejected('invalid_merge_update');
      }
      updateInputs[id] = update;
      rows[id] = _agentCard(turn, id);
    }
    final affected = _agentEffectSet(turn, rows.keys.toSet());
    _agentBudget(turn, affected);
    if (!rows.keys.toSet().containsAll(affected)) throw const _AgentMemoryRejected('incomplete_effect_set');
    final planned = {
      targetId: (target['row_rev'] as int) + 1,
      for (final id in updateInputs.keys) id: (rows[id]!['row_rev'] as int) + 1,
    };
    final mergedRows = [target, for (final id in fromIds) rows[id]!];
    final basis = mergedRows.map((row) => row['current_basis_seq'] as int? ?? 0).reduce(math.max);
    final sourceAt = mergedRows.map((row) => row['source_at_ms'] as int).reduce(math.max);
    final writes = {
      for (final entry in updateInputs.entries)
        entry.key: _agentPrepareEntry(
          turn,
          entry.key,
          rows[entry.key],
          entry.value,
          planned,
          fromIds,
          plannedReference: (reference) => reference == targetId ? (basis: basis, sourceAt: sourceAt) : null,
        ),
    };
    final targetRefs = <String, int>{};
    for (final row in mergedRows) {
      for (final reference in _db.select(
        'SELECT parent_card_id,parent_row_rev FROM memory_card_references WHERE card_id=?',
        [row['id']],
      )) {
        final id = reference['parent_card_id'] as String;
        if (id == targetId || fromIds.contains(id)) continue;
        targetRefs[id] = planned[id] ?? reference['parent_row_rev'] as int;
      }
    }
    final referencePlan = {targetId: targetRefs, for (final write in writes.values) write.id: write.references};
    _agentValidateReferencePlan(referencePlan, fromIds);
    final text = input['text'] == null ? target['text'] as String : _agentText(input, 'text');
    final words = input['keywords'] == null
        ? <String>{
            for (final row in mergedRows) ...(jsonDecode(row['keywords'] as String) as List).cast<String>(),
          }.toList()
        : _agentKeywords(input, text);
    final aliases = <String>{
      for (final row in mergedRows)
        for (final alias in _db.select('SELECT alias FROM memory_person_aliases WHERE card_id=?', [row['id']]))
          alias['alias'] as String,
    };
    final proofKeys = <String>{};
    final proofs = <List<MemoryRow>>[];
    for (final row in mergedRows) {
      for (final group in _supportGroups(_card(row)).values) {
        if (proofKeys.add(_mergeProofKey(group))) proofs.add(group);
      }
    }
    final at = _checkedNow();
    void mergeBody() {
      // The original AND groups remain AND groups; distinct support groups
      // remain alternatives. A merge never masquerades as revise then forget.
      _db.execute('DELETE FROM memory_card_sources WHERE card_id=?', [targetId]);
      for (final group in proofs) {
        final groupId = _createId();
        for (final proof in group) {
          _db.execute(
            'INSERT INTO memory_card_sources(card_id,support_group,message_id,source_rev,quote) VALUES(?,?,?,?,?)',
            [targetId, groupId, proof['message_id'], proof['source_rev'], proof['quote']],
          );
        }
      }
      _db.execute(
        '''
        UPDATE memory_cards SET row_rev=?,text=?,keywords=?,pinned=?,current_basis_seq=?,source_at_ms=?,
          updated_at_ms=?,maintenance_row_rev=0,cleanup_history_complete=? WHERE id=?
      ''',
        [
          planned[targetId],
          text,
          jsonEncode(words),
          mergedRows.any((row) => row['pinned'] == 1) ? 1 : 0,
          basis,
          sourceAt,
          at,
          mergedRows.every((row) => row['cleanup_history_complete'] == 1) ? 1 : 0,
          targetId,
        ],
      );
      _db.execute('DELETE FROM memory_card_references WHERE card_id=?', [targetId]);
      for (final reference in targetRefs.entries) {
        _db.execute('INSERT INTO memory_card_references(card_id,parent_card_id,parent_row_rev) VALUES(?,?,?)', [
          targetId,
          reference.key,
          reference.value,
        ]);
      }
      _db.execute('DELETE FROM memory_person_aliases WHERE card_id=?', [targetId]);
      for (final alias in aliases) {
        _db.execute('INSERT INTO memory_person_aliases(card_id,alias,normalized_alias) VALUES(?,?,?)', [
          targetId,
          alias,
          normalizeMemoryText(alias),
        ]);
      }
      for (final fromId in fromIds) {
        _db.execute(
          '''
          INSERT INTO memory_card_cleanup_sources(card_id,message_id,proof_withdrawn)
          SELECT ?,message_id,proof_withdrawn FROM memory_card_cleanup_sources WHERE card_id=?
          ON CONFLICT(card_id,message_id) DO UPDATE SET
            proof_withdrawn=MAX(memory_card_cleanup_sources.proof_withdrawn,excluded.proof_withdrawn)
        ''',
          [targetId, fromId],
        );
        _db.execute('UPDATE memory_migrations SET local_card_id=? WHERE local_card_id=?', [targetId, fromId]);
      }
      for (final id in [targetId, ...fromIds]) {
        _db.execute('UPDATE memory_followups SET card_id=?,card_rev=?,row_rev=row_rev+1 WHERE card_id=?', [
          targetId,
          planned[targetId],
          id,
        ]);
      }
      for (final fromId in fromIds) {
        _db.execute('DELETE FROM memory_cards WHERE id=?', [fromId]);
        final topic = rows[fromId]!['topic_id'];
        _db.execute(
          'DELETE FROM memory_topics WHERE id=? AND NOT EXISTS(SELECT 1 FROM memory_cards WHERE topic_id=?)',
          [topic, topic],
        );
      }
      // Keep the selected target's topic and anchors. In particular, a
      // surviving from-topic never donates its independent anchors to it.
    }

    final pending = referencePlan.keys.toSet();
    while (pending.isNotEmpty) {
      final id = pending.firstWhere((id) => !referencePlan[id]!.keys.any(pending.contains));
      if (id == targetId) {
        mergeBody();
      } else {
        _agentApplyEntries([writes[id]!]);
        _closeAgentFollowups(id, 'revised');
      }
      pending.remove(id);
    }
    _bumpMemory();
    _bumpControl();
    return (changed: affected, target: targetId);
  }

  ({Set<String> changed, String? target}) _agentRelationship(Row turn, MemoryRow input) {
    final character = turn['character_id'] as String?;
    if (turn['origin_kind'] == 'chat' || character == null) {
      throw const _AgentMemoryRejected('relationship_needs_maintenance');
    }
    final kind = input['kind'];
    if (!const ['question', 'confiding', 'answered_question', 'answered_followup'].contains(kind)) {
      throw const _AgentMemoryRejected('invalid_relationship_event');
    }
    final claim = _agentClaim(turn['claim_id'] as String);
    MemoryRow? source;
    if (kind != 'question') {
      final id = _agentText(input, 'source');
      final matches = _agentMaintenanceSources(
        claim,
        character,
      ).where((row) => row['id'] == id && row['role'] == 'user');
      if (matches.length != 1) throw const _AgentMemoryRejected('source_not_in_turn');
      source = matches.single;
      final settled = companionAffinity(characterId: character)?['settled_through_day'] as String?;
      if (settled != null &&
          _memoryLocalDay(source['said_at_utc'] as int, source['offset_minutes'] as int).compareTo(settled) <= 0) {
        throw const _AgentMemoryRejected('affinity_day_settled');
      }
    }
    MemoryRow? ticket;
    if (kind != 'confiding') {
      final id = _agentText(input, 'presentation');
      final matches = _agentMaintenancePresentations(claim, character).where((row) => row['id'] == id);
      if (matches.length != 1) throw const _AgentMemoryRejected('presentation_not_in_turn');
      ticket = matches.single;
      if ((kind == 'answered_followup' && ticket['kind'] != 'followup') ||
          (kind != 'answered_followup' && !const ['assistant', 'question'].contains(ticket['kind'])) ||
          (source != null && (ticket['presented_at_ms'] as int) > (source['said_at_utc'] as int))) {
        throw const _AgentMemoryRejected('presentation_not_current');
      }
    }
    // All source/ticket/closed-day checks precede the first change. A model
    // can classify an actual display, never manufacture its receipt or time.
    if (ticket != null && ticket['kind'] == 'assistant') {
      _db.execute("UPDATE memory_affinity_presentations SET kind='question' WHERE id=?", [ticket['id']]);
    }
    if (source != null) {
      _recordCompanionInteraction(
        characterId: character,
        eventId: 'agent:${turn['id']}:$kind:${source['id']}',
        kind: kind as String,
        atMs: source['said_at_utc'] as int,
        offsetMinutes: source['offset_minutes'] as int,
        sourceId: source['id'] as String,
        presentationId: ticket?['id'] as String?,
      );
    }
    return (changed: <String>{}, target: ticket?['id'] as String? ?? source?['id'] as String?);
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

  ({Set<String> changed, String? target}) _agentAskLater(Row turn, MemoryRow source, String callId, MemoryRow input) {
    if (source['role'] != 'user') throw const _AgentMemoryRejected('followup_requires_user_source');
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
          WHERE t.source_message_id=? OR t.id=?
      )
    ''',
                  [turn['source_message_id'], turn['source_message_id'], turn['id']],
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

  CompanionAgentMemoryResult _agentResult(
    Row call, {
    required bool replayed,
    MemorySelection? recallSelection,
    List<MemoryRow>? relatedCards,
  }) {
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
      recallSelection: recallSelection,
      relatedCards: relatedCards,
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
