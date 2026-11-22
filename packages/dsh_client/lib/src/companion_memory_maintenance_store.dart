part of 'companion_memory_store.dart';

extension CompanionMemoryMaintenanceStore on CompanionMemoryStore {
  /// A parent is an actual queue/day opportunity, not a fabricated user row.
  /// Its child contexts keep private roles separate and share one write budget.
  MemoryRow? nextAgentMaintenance({
    required String kind,
    required int offsetMinutes,
    required int Function(String) estimateTokens,
    bool forceTail = false,
    int Function(MemoryRow context)? estimateContextTokens,
  }) {
    if (!const ['extract', 'organize'].contains(kind) || offsetMinutes.abs() > 1440) {
      throw ArgumentError('Invalid maintenance opportunity');
    }
    MemoryRow context(
      List<MemoryRow> sources,
      List<MemoryRow> cards,
      String? character, {
      String? localDay,
      String? zoneId,
    }) => _planAgentMaintenanceContext(
      kind: kind,
      characterId: character,
      localDay: localDay,
      zoneId: zoneId,
      sources: sources,
      cards: cards,
      estimateTokens: estimateTokens,
      estimateContextTokens: estimateContextTokens,
    );
    int size(List<MemoryRow> sources, List<MemoryRow> cards, {String? localDay, String? zoneId}) {
      final scopes = <String?>{
        if (kind == 'organize') null,
        for (final source in sources) source['character_id'] as String?,
      };
      var maximum = 0;
      for (final character in scopes) {
        maximum = math.max(
          maximum,
          _agentContextTokens(
            context(sources, cards, character, localDay: localDay, zoneId: zoneId),
            estimateTokens,
            estimateContextTokens,
          ),
        );
      }
      return maximum;
    }

    final existing = _db.select(
      "SELECT * FROM memory_agent_maintenance_claims WHERE kind=? AND state='claimed' ORDER BY created_at_ms",
      [kind],
    );
    for (final claim in existing) {
      if (_agentParentCurrent(claim)) return _agentClaimView(claim);
      _transaction(() {
        for (final turn in _db.select('SELECT * FROM memory_agent_turns WHERE claim_id=? AND closed=0', [
          claim['id'],
        ])) {
          if (kind == 'organize' && _agentMaintenanceEffectPossible(turn)) {
            _markAgentOrganizeExamined(turn);
          }
        }
        _db.execute("UPDATE memory_agent_maintenance_claims SET state='interrupted' WHERE id=?", [claim['id']]);
        _db.execute('UPDATE memory_agent_turns SET closed=1 WHERE claim_id=?', [claim['id']]);
        if (kind == 'extract') _dropBatch(claim['id'] as String);
      });
    }
    // A body whose definitions alone do not fit is not a long user message.
    // Keep that pending input untouched and do not allocate a maintenance claim.
    if (kind == 'extract') {
      for (final row in _db.select('''
        SELECT DISTINCT m.character_id FROM memory_events e JOIN memory_messages m
          ON m.id=e.message_id AND m.source_rev=e.source_rev AND m.event_seq=e.seq
        WHERE e.state='pending'
      ''')) {
        if (_agentContextTokens(
              context(const [], const [], row['character_id'] as String?),
              estimateTokens,
              estimateContextTokens,
            ) >
            memoryBatchInputTokens) {
          return null;
        }
      }
    }
    // Keep the original queue/readiness/whole-source selection. Only its size
    // callback changes to the complete body that the actual scoped lane sends.
    final batch = kind == 'extract'
        ? _nextBatch(
            forceTail: forceTail,
            estimateTokens: estimateTokens,
            estimateInputTokens: (sources, cards) => size(sources, cards),
          )
        : null;
    if (kind == 'extract' && batch == null) return null;
    return _transaction(() {
      final at = _checkedNow();
      final meta = archive;
      final String id;
      final String? localDay;
      final sources = <MemoryRow>[];
      final examinedSources = <String, Map<String, int>>{};
      if (batch != null) {
        if (!isBatchCurrent(batch)) return null;
        id = batch.id;
        localDay = null;
        sources.addAll(batch.sources);
        // The prior reply is optional context, never an invented question.
        // Its whole body and actual display ticket must fit the same request.
        for (final user in batch.sources) {
          if (user['character_id'] == null) continue;
          final prior = _db.select(
            '''
            SELECT m.* FROM memory_affinity_presentations p JOIN memory_messages m ON m.id=p.assistant_source_id
            WHERE p.character_id=? AND m.character_id=? AND m.session_id=?
              AND m.scope='real' AND m.role='assistant' AND m.first_seq>? AND m.first_seq<?
              AND p.presented_at_ms<=? ORDER BY m.first_seq DESC LIMIT 1
          ''',
            [
              user['character_id'],
              user['character_id'],
              user['session_id'],
              meta['history_after_seq'],
              user['first_seq'],
              user['said_at_utc'],
            ],
          );
          if (prior.isEmpty || sources.any((source) => source['id'] == prior.single['id'])) continue;
          final candidate = [...sources, Map<String, Object?>.from(prior.single)]
            ..sort((a, b) => (a['first_seq'] as int).compareTo(b['first_seq'] as int));
          if (size(candidate, const []) <= memoryBatchInputTokens) {
            sources
              ..clear()
              ..addAll(candidate);
          }
        }
      } else {
        // A changed timezone cannot buy a second daily model opportunity.
        if (_db.select(
          "SELECT 1 FROM memory_agent_maintenance_claims WHERE kind='organize' AND state!='not_sent' AND created_at_ms>? LIMIT 1",
          [at - 86400000],
        ).isNotEmpty) {
          return null;
        }
        final local = DateTime.fromMillisecondsSinceEpoch(at + offsetMinutes * 60000, isUtc: true);
        final today = DateTime.utc(local.year, local.month, local.day);
        localDay = today.subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
        if (_db.select(
          "SELECT 1 FROM memory_agent_maintenance_claims WHERE kind='organize' AND state!='not_sent' AND local_day=?",
          [localDay],
        ).isNotEmpty) {
          return null;
        }
        if (_agentContextTokens(
              context(const [], const [], null, localDay: localDay, zoneId: 'offset:$offsetMinutes'),
              estimateTokens,
              estimateContextTokens,
            ) >
            memoryBatchInputTokens) {
          return null;
        }
        // Compare local calendar coordinates with each original source's
        // stored offset; today's offset may have changed at a DST boundary.
        final end = today.millisecondsSinceEpoch;
        for (final row in _db.select(
          '''
          SELECT * FROM memory_messages WHERE scope='real' AND first_seq>?
            AND said_at_utc+offset_minutes*60000>=?
            AND said_at_utc+offset_minutes*60000<? ORDER BY first_seq DESC
        ''',
          [meta['history_after_seq'], end - 86400000, end],
        )) {
          if (row['role'] == 'assistant' && row['character_id'] == null) continue;
          final candidate = [...sources, Map<String, Object?>.from(row)]
            ..sort((a, b) => (a['first_seq'] as int).compareTo(b['first_seq'] as int));
          if (size(candidate, const [], localDay: localDay, zoneId: 'offset:$offsetMinutes') <=
              memoryBatchInputTokens) {
            sources
              ..clear()
              ..addAll(candidate);
          }
        }
        // These are the original captured IDs/revisions, not another queue or
        // a replay of a closed turn. A served scope consumes only its sources.
        final history = _db.select(
          "SELECT * FROM memory_agent_maintenance_claims WHERE kind='organize' AND archive_id=? "
          "AND state!='not_sent' ORDER BY created_at_ms,id",
          [meta['id']],
        );
        for (final prior in history) {
          final revisions = _agentRevisions(prior['source_revisions'] as String);
          for (final scope in _agentIds(prior['completed_scopes'] as String)) {
            final seen = examinedSources.putIfAbsent(scope, () => <String, int>{});
            for (final source in _agentMaintenanceSources(prior, scope.isEmpty ? null : scope)) {
              final sourceId = source['id'] as String;
              seen[sourceId] = math.max(seen[sourceId] ?? 0, revisions[sourceId]!);
            }
          }
        }
        // A three-card parent may finish before reaching another role. Keep
        // that role's still-current captured input, without giving its old day
        // to the shared diary scope or resending an already served revision.
        for (final prior in history) {
          final completed = _agentIds(prior['completed_scopes'] as String);
          for (final scope in (jsonDecode(prior['scope_characters'] as String) as List).cast<String?>()) {
            if (scope == null || completed.contains(scope)) continue;
            for (final source in _agentMaintenanceSources(prior, scope)) {
              if (examinedSources[scope]?[source['id']] == source['source_rev'] ||
                  sources.any((row) => row['id'] == source['id'])) {
                continue;
              }
              final candidate = [...sources, source]
                ..sort((a, b) => (a['first_seq'] as int).compareTo(b['first_seq'] as int));
              if (size(candidate, const [], localDay: localDay, zoneId: 'offset:$offsetMinutes') <=
                  memoryBatchInputTokens) {
                sources
                  ..clear()
                  ..addAll(candidate);
              }
            }
          }
        }
        id = _createId();
      }
      if (_db.select('SELECT 1 FROM memory_agent_maintenance_claims WHERE id=?', [id]).isNotEmpty) return null;
      final possibleCharacters = <String?>{};
      if (kind == 'organize') possibleCharacters.add(null);
      if (kind == 'extract') {
        for (final source in sources) {
          possibleCharacters.add(source['character_id'] as String?);
        }
      }
      if (kind == 'organize') {
        for (final row in _db.select('''
          SELECT c.id,COALESCE(MAX(p.created_at_ms),0) AS examined
          FROM memory_characters c LEFT JOIN memory_agent_turns t ON t.character_id=c.id AND t.closed=1
          LEFT JOIN memory_agent_maintenance_claims p ON p.id=t.claim_id AND p.kind='organize'
          WHERE EXISTS(SELECT 1 FROM memory_messages m WHERE m.character_id=c.id AND m.scope='real')
            OR EXISTS(SELECT 1 FROM memory_cards m WHERE m.character_id=c.id AND m.status!='withdrawn')
          GROUP BY c.id ORDER BY examined,c.first_seen_at_ms,c.id
        ''')) {
          possibleCharacters.add(row['id'] as String);
        }
      }
      final characters = <String?>{};
      final selectedCards = <String, int>{};
      final scopedCards = <String, Map<String, int>>{};
      final scopedPresentations = <String, List<String>>{};
      for (final character in possibleCharacters) {
        final selected = <MemoryRow>[];
        final zoneId = localDay == null ? null : 'offset:$offsetMinutes';
        for (final card in _memoryDomainCards(character)) {
          if ((kind == 'organize' ? !isMemoryContextEligible(card, nowMs: at) : card['status'] == 'withdrawn') ||
              !_memoryReferencesCurrent(card['id'] as String)) {
            continue;
          }
          final candidate = context(sources, [...selected, card], character, localDay: localDay, zoneId: zoneId);
          if (_agentContextTokens(candidate, estimateTokens, estimateContextTokens) > memoryBatchInputTokens) continue;
          selected.add(card);
        }
        final selectedContext = context(sources, selected, character, localDay: localDay, zoneId: zoneId);
        if (kind == 'organize') {
          final sourceWork = (selectedContext['sources'] as List<MemoryRow>).any(
            (source) => examinedSources[character ?? '']?[source['id']] != source['source_rev'],
          );
          final cardWork = selected.any(
            (card) => card['character_id'] == character && card['maintenance_row_rev'] != card['row_rev'],
          );
          if (!sourceWork && !cardWork) continue;
        }
        characters.add(character);
        for (final card in selected) {
          selectedCards[card['id'] as String] = card['row_rev'] as int;
        }
        scopedCards[character ?? ''] = {for (final card in selected) card['id'] as String: card['row_rev'] as int};
        scopedPresentations[character ?? ''] = [
          for (final ticket in selectedContext['presentations'] as List<MemoryRow>) ticket['id'] as String,
        ];
      }
      if (characters.isEmpty) return null;
      _db.execute(
        '''
        INSERT INTO memory_agent_maintenance_claims(
          id,kind,archive_id,control_revision,memory_revision,source_revisions,event_sequences,card_revisions,
          scope_card_revisions,scope_presentations,scope_characters,completed_scopes,changed_cards,local_day,zone_id,created_at_ms,state)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,'[]','[]',?,?,?,'claimed')
      ''',
        [
          id,
          kind,
          meta['id'],
          meta['control_revision'],
          meta['memory_revision'],
          _canonicalJson({for (final row in sources) row['id'] as String: row['source_rev']}),
          _canonicalJson({
            for (final row in batch?.sources ?? const <MemoryRow>[]) row['id'] as String: row['event_seq'],
          }),
          _canonicalJson(selectedCards),
          _canonicalJson(scopedCards),
          _canonicalJson(scopedPresentations),
          jsonEncode(characters.toList()),
          localDay,
          localDay == null ? null : 'offset:$offsetMinutes',
          at,
        ],
      );
      return _agentClaimView(_agentClaim(id));
    });
  }

  int _agentContextTokens(
    MemoryRow context,
    int Function(String) estimateTokens,
    int Function(MemoryRow)? estimateContextTokens,
  ) {
    final value = estimateContextTokens?.call(context) ?? estimateTokens(jsonEncode(context));
    if (value < 0) throw ArgumentError('Negative maintenance token estimate');
    return value;
  }

  MemoryRow _planAgentMaintenanceContext({
    required String kind,
    required String? characterId,
    required String? localDay,
    required String? zoneId,
    required List<MemoryRow> sources,
    required List<MemoryRow> cards,
    required int Function(String) estimateTokens,
    required int Function(MemoryRow)? estimateContextTokens,
  }) {
    final scopedSources = _agentSourcesForScope(sources, characterId, kind, localDay: localDay);
    final revisions = {for (final card in cards) card['id']: card['row_rev']};
    final selected = [
      for (final card in _memoryDomainCards(characterId))
        if (revisions[card['id']] == card['row_rev'] &&
            card['status'] != 'withdrawn' &&
            _memoryReferencesCurrent(card['id'] as String))
          card,
    ];
    final context = _agentContext(characterId, localDay, zoneId, scopedSources, selected, const []);
    if (_agentContextTokens(context, estimateTokens, estimateContextTokens) > memoryBatchInputTokens) return context;
    final tickets = <MemoryRow>[];
    // Presentation metadata is optional, selected newest first and then sent
    // chronologically. Save only its real IDs so begin sees this exact selection.
    for (final ticket in _agentPresentationCandidates(scopedSources, characterId).reversed) {
      final candidate = [...tickets, ticket]
        ..sort((a, b) => (a['presented_at_ms'] as int).compareTo(b['presented_at_ms'] as int));
      final withTicket = {...context, 'presentations': candidate};
      if (_agentContextTokens(withTicket, estimateTokens, estimateContextTokens) <= memoryBatchInputTokens) {
        tickets
          ..clear()
          ..addAll(candidate);
      }
    }
    return {...context, 'presentations': tickets};
  }

  MemoryRow _agentContext(
    String? characterId,
    String? localDay,
    String? zoneId,
    List<MemoryRow> sources,
    List<MemoryRow> cards,
    List<MemoryRow> presentations,
  ) {
    final cutoff = archive['history_after_seq'] as int;
    return {
      'character_id': characterId,
      'local_day': localDay,
      'zone_id': zoneId,
      'processed_at_utc': DateTime.fromMillisecondsSinceEpoch(_checkedNow(), isUtc: true).toIso8601String(),
      'source_coverage': 'selected_original_messages',
      'sources': sources,
      'cards': [
        for (final card in cards)
          {
            ...card,
            // Independent facts keep their full local proofs. A model input
            // may only see complete AND groups beyond the current cutoff;
            // other legal OR groups, including our_story assistant proofs,
            // remain intact. This projection never changes stored evidence.
            'evidence': [
              for (final group in _supportGroups(card).values)
                if (group.every((proof) => (proof['first_seq'] as int) > cutoff)) ...group,
            ],
          },
      ],
      'presentations': presentations,
    };
  }

  MemoryRow beginAgentMaintenance({required String kind, required String claimId, String? characterId}) =>
      _transaction(() {
        _checkMemoryCharacter(characterId);
        final claim = _agentClaim(claimId);
        if (claim['kind'] != kind ||
            !_agentParentCurrent(claim) ||
            !(jsonDecode(claim['scope_characters'] as String) as List).contains(characterId)) {
          throw _conflict;
        }
        final existing = _db.select('SELECT * FROM memory_agent_turns WHERE claim_id=? AND character_id IS ?', [
          claimId,
          characterId,
        ]);
        if (existing.isNotEmpty) return _agentMaintenanceView(existing.single);
        if (_db.select('SELECT 1 FROM memory_agent_turns WHERE claim_id=? AND closed=0', [claimId]).isNotEmpty ||
            _agentIds(claim['changed_cards'] as String).length >= 3) {
          throw _conflict;
        }
        final completed = _agentIds(claim['completed_scopes'] as String);
        final remaining = (jsonDecode(claim['scope_characters'] as String) as List)
            .where((scope) => !completed.contains(scope ?? ''))
            .toList();
        if (remaining.isEmpty || remaining.first != characterId) throw _conflict;
        final id = _createId();
        _db.execute(
          '''
      INSERT INTO memory_agent_turns(id,origin_kind,claim_id,character_id,archive_id,memory_revision,
        control_revision,shown_cards,changed_cards)
      VALUES(?,?,?,?,?,?,?,'{}','[]')
    ''',
          [id, kind, claimId, characterId, claim['archive_id'], claim['memory_revision'], claim['control_revision']],
        );
        return _agentMaintenanceView(_agentTurn(id));
      });

  /// Reading a saved receipt is permitted after close; issuing a new tool or
  /// physical request requires this exact live source/claim watermark.
  bool isAgentTurnCurrent(String turnId) {
    try {
      _agentCheckCurrent(_agentTurn(turnId));
      return true;
    } on _AgentMemoryRejected {
      return false;
    } on DshRemoteException {
      return false;
    }
  }

  String? reserveAgentMaintenanceRequest({
    required String turnId,
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
  }) => _transaction(() {
    final turn = _agentTurn(turnId);
    _agentCheckCurrent(turn);
    if (turn['origin_kind'] == 'chat') throw _conflict;
    if (_db
        .select(
          '''
      SELECT 1 FROM memory_agent_maintenance_requests a JOIN memory_requests r ON r.id=a.request_id
      WHERE a.claim_id=? AND r.state IN ('reserved','sent') AND r.terminal IS NULL LIMIT 1
    ''',
          [turn['claim_id']],
        )
        .isNotEmpty) {
      return null;
    }
    final id = _reserveMemoryRequest(
      category: turn['origin_kind'] as String,
      provider: provider,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      batchId: turn['claim_id'] as String,
      maintenanceClaimId: turn['claim_id'] as String,
    );
    if (id != null) {
      _db.execute('INSERT INTO memory_agent_maintenance_requests(request_id,turn_id,claim_id) VALUES(?,?,?)', [
        id,
        turnId,
        turn['claim_id'],
      ]);
    }
    return id;
  });

  void finishAgentMaintenance({required String turnId, required bool complete}) => _transaction(() {
    final turn = _agentTurn(turnId);
    if (turn['origin_kind'] == 'chat') throw _conflict;
    if (turn['closed'] != 0) return;
    if (_db
        .select(
          '''
      SELECT 1 FROM memory_agent_maintenance_requests a JOIN memory_requests r ON r.id=a.request_id
      WHERE a.turn_id=? AND r.state IN ('reserved','sent') AND r.terminal IS NULL LIMIT 1
    ''',
          [turnId],
        )
        .isNotEmpty) {
      throw _conflict;
    }
    final claim = _agentClaim(turn['claim_id'] as String);
    final current = _agentParentCurrent(claim) && turn['control_revision'] == archive['control_revision'];
    final successful =
        complete &&
        current &&
        _db.select("SELECT 1 FROM memory_agent_calls WHERE turn_id=? AND state='pending' LIMIT 1", [turnId]).isEmpty;
    if (successful && claim['kind'] == 'extract') {
      final events = _agentRevisions(claim['event_sequences'] as String);
      for (final source in _agentMaintenanceSources(claim, turn['character_id'] as String?)) {
        final seq = events[source['id']];
        if (seq == null) continue;
        _db.execute(
          "UPDATE memory_events SET state='done',reason=NULL,batch_id=NULL "
          "WHERE seq=? AND message_id=? AND source_rev=? AND state='pending'",
          [seq, source['id'], source['source_rev']],
        );
      }
      _advanceCursor();
    } else if (claim['kind'] == 'extract' && _agentMaintenanceEffectPossible(turn)) {
      _skipIncompleteAgentSources(claim, turn['character_id'] as String?);
    }
    final examined = successful || _agentMaintenanceEffectPossible(turn);
    if (turn['origin_kind'] == 'organize' && examined) {
      _markAgentOrganizeExamined(turn);
    }
    _db.execute('UPDATE memory_agent_turns SET closed=1 WHERE id=?', [turnId]);
    final completed = {
      ..._agentIds(_agentClaim(claim['id'] as String)['completed_scopes'] as String),
      if (turn['origin_kind'] != 'organize' || examined) turn['character_id'] as String? ?? '',
    };
    final scopes = (jsonDecode(claim['scope_characters'] as String) as List).map((value) => value ?? '').toSet();
    final finished = completed.containsAll(scopes) || _agentIds(claim['changed_cards'] as String).length >= 3;
    final notSent =
        !complete &&
        _agentIds(claim['changed_cards'] as String).isEmpty &&
        _db
            .select(
              '''
      SELECT 1 FROM memory_agent_maintenance_requests a JOIN memory_requests r ON r.id=a.request_id
      WHERE a.claim_id=? AND (r.sent_at_ms IS NOT NULL OR r.uncertain_at_ms IS NOT NULL OR r.state!='released')
      LIMIT 1
    ''',
              [claim['id']],
            )
            .isEmpty;
    _db.execute('UPDATE memory_agent_maintenance_claims SET completed_scopes=?,state=? WHERE id=?', [
      jsonEncode(completed.toList()),
      notSent
          ? 'not_sent'
          : !current || (turn['origin_kind'] == 'organize' && !examined)
          ? 'interrupted'
          : finished
          ? 'finished'
          : 'claimed',
      claim['id'],
    ]);
    if ((notSent || !current || finished) && claim['kind'] == 'extract') _dropBatch(claim['id'] as String);
  });

  bool _agentMaintenanceEffectPossible(Row turn) =>
      _agentIds(turn['changed_cards'] as String).isNotEmpty ||
      _db
          .select(
            '''
        SELECT 1 FROM memory_agent_maintenance_requests a JOIN memory_requests r ON r.id=a.request_id
        WHERE a.turn_id=? AND (r.sent_at_ms IS NOT NULL OR r.uncertain_at_ms IS NOT NULL) LIMIT 1
      ''',
            [turn['id']],
          )
          .isNotEmpty;

  void _markAgentOrganizeExamined(Row turn) {
    // Only this actually served scope, never the parent's unserved roles.
    // A later external edit remains unexamined even if the old request ends.
    for (final card in _agentRevisions(turn['shown_cards'] as String).entries) {
      _db.execute('UPDATE memory_cards SET maintenance_row_rev=row_rev WHERE id=? AND row_rev=?', [
        card.key,
        card.value,
      ]);
    }
    final claim = _agentClaim(turn['claim_id'] as String);
    final completed = {..._agentIds(claim['completed_scopes'] as String), turn['character_id'] as String? ?? ''};
    _db.execute('UPDATE memory_agent_maintenance_claims SET completed_scopes=? WHERE id=?', [
      jsonEncode(completed.toList()),
      claim['id'],
    ]);
  }

  void _skipIncompleteAgentSources(Row claim, String? characterId) {
    final events = _agentRevisions(claim['event_sequences'] as String);
    final revisions = _agentRevisions(claim['source_revisions'] as String);
    for (final entry in events.entries) {
      final current = _db.select(
        '''
        SELECT 1 FROM memory_messages WHERE id=? AND source_rev=? AND event_seq=?
          AND character_id IS ? AND scope='real' AND role='user'
      ''',
        [entry.key, revisions[entry.key], entry.value, characterId],
      );
      if (current.isEmpty) continue;
      _db.execute(
        "UPDATE memory_events SET state='skipped',reason='maintenance_incomplete',batch_id=NULL "
        "WHERE seq=? AND message_id=? AND source_rev=? AND state='pending'",
        [entry.value, entry.key, revisions[entry.key]],
      );
    }
    _advanceCursor();
  }

  void _retireAgentMaintenanceOnOpen() {
    for (final turn in _db.select("SELECT * FROM memory_agent_turns WHERE origin_kind!='chat' AND closed=0")) {
      if (turn['origin_kind'] == 'extract' && _agentMaintenanceEffectPossible(turn)) {
        _skipIncompleteAgentSources(_agentClaim(turn['claim_id'] as String), turn['character_id'] as String?);
      } else if (turn['origin_kind'] == 'organize' && _agentMaintenanceEffectPossible(turn)) {
        _markAgentOrganizeExamined(turn);
      }
    }
    for (final claim in _db.select("SELECT * FROM memory_agent_maintenance_claims WHERE state='claimed'")) {
      final sent = _db
          .select(
            '''
        SELECT 1 FROM memory_agent_maintenance_requests a JOIN memory_requests r ON r.id=a.request_id
        WHERE a.claim_id=? AND (r.sent_at_ms IS NOT NULL OR r.uncertain_at_ms IS NOT NULL) LIMIT 1
      ''',
            [claim['id']],
          )
          .isNotEmpty;
      final notSent = !sent && _agentIds(claim['changed_cards'] as String).isEmpty;
      _db.execute('UPDATE memory_agent_maintenance_claims SET state=? WHERE id=?', [
        notSent ? 'not_sent' : 'interrupted',
        claim['id'],
      ]);
      if (claim['kind'] == 'extract') _dropBatch(claim['id'] as String);
    }
  }

  Row _agentClaim(String id) {
    final rows = _db.select('SELECT * FROM memory_agent_maintenance_claims WHERE id=?', [id]);
    if (rows.isEmpty) throw _conflict;
    return rows.single;
  }

  bool _agentParentCurrent(Row claim) =>
      claim['state'] == 'claimed' &&
      claim['archive_id'] == archive['id'] &&
      claim['control_revision'] == archive['control_revision'];

  MemoryRow _agentClaimView(Row row) => {
    ...row,
    'scope_characters': (jsonDecode(row['scope_characters'] as String) as List).cast<String?>(),
    'completed_scopes': _agentIds(row['completed_scopes'] as String),
    'changed_cards': _agentIds(row['changed_cards'] as String),
    'source_revisions': _agentRevisions(row['source_revisions'] as String),
    'card_revisions': _agentRevisions(row['card_revisions'] as String),
  };

  MemoryRow _agentMaintenanceView(Row turn) {
    final claim = _agentClaim(turn['claim_id'] as String);
    final character = turn['character_id'] as String?;
    final byScope = jsonDecode(claim['scope_card_revisions'] as String) as Map<String, Object?>;
    final revisions = (byScope[character ?? ''] as Map<String, dynamic>).cast<String, int>();
    final current = turn['closed'] == 0 && _agentParentCurrent(claim);
    final sources = current ? _agentMaintenanceSources(claim, character) : const <MemoryRow>[];
    return {
      ..._agentTurnView(turn),
      ..._agentContext(character, claim['local_day'] as String?, claim['zone_id'] as String?, sources, [
        if (current)
          for (final card in _memoryDomainCards(character))
            if (revisions[card['id']] == card['row_rev'] &&
                card['status'] != 'withdrawn' &&
                _memoryReferencesCurrent(card['id'] as String))
              card,
      ], current ? _agentMaintenancePresentations(claim, character) : const <MemoryRow>[]),
    };
  }

  List<MemoryRow> _agentMaintenanceSources(Row claim, String? characterId) {
    final captured = _agentRevisions(claim['source_revisions'] as String);
    final cutoff = archive['history_after_seq'] as int;
    final sources = <MemoryRow>[];
    for (final entry in captured.entries) {
      final rows = _db.select('SELECT * FROM memory_messages WHERE id=? AND source_rev=? AND scope=? AND first_seq>?', [
        entry.key,
        entry.value,
        'real',
        cutoff,
      ]);
      if (rows.isNotEmpty) sources.add(Map<String, Object?>.from(rows.single));
    }
    sources.sort((a, b) => (a['first_seq'] as int).compareTo(b['first_seq'] as int));
    return _agentSourcesForScope(
      sources,
      characterId,
      claim['kind'] as String,
      localDay: claim['local_day'] as String?,
    );
  }

  List<MemoryRow> _agentMaintenancePresentations(Row claim, String? characterId) {
    final scopes = jsonDecode(claim['scope_presentations'] as String) as Map<String, dynamic>;
    final captured = (scopes[characterId ?? ''] as List).cast<String>().toSet();
    return [
      for (final ticket in _agentPresentationCandidates(_agentMaintenanceSources(claim, characterId), characterId))
        if (captured.contains(ticket['id'])) ticket,
    ];
  }

  List<MemoryRow> _agentPresentationCandidates(List<MemoryRow> sources, String? characterId) {
    if (characterId == null) return const [];
    final sourceIds = sources.map((row) => row['id']).toSet();
    final users = sources.where((row) => row['role'] == 'user').toList();
    if (users.isEmpty) return const [];
    final latest = users.map((row) => row['said_at_utc'] as int).reduce(math.max);
    final result = <MemoryRow>[];
    for (final ticket in _db.select(
      'SELECT * FROM memory_affinity_presentations WHERE character_id=? AND presented_at_ms<=? ORDER BY presented_at_ms,id',
      [characterId, latest],
    )) {
      if (ticket['assistant_source_id'] != null) {
        if (sourceIds.contains(ticket['assistant_source_id'])) result.add(Map<String, Object?>.from(ticket));
        continue;
      }
      final followup = _db.select(
        '''
        SELECT c.id FROM memory_followups f JOIN memory_cards c ON c.id=f.card_id
          JOIN memory_messages m ON m.id=f.message_id
          LEFT JOIN memory_messages support ON support.id=f.support_message_id
        WHERE f.id=? AND f.state='asked' AND c.status!='withdrawn'
          AND (c.character_id IS NULL OR c.character_id=?)
          AND (m.character_id IS NULL OR m.character_id=?)
          AND (f.support_message_id IS NULL OR support.character_id IS NULL OR support.character_id=?)
      ''',
        [ticket['opportunity_id'], characterId, characterId, characterId],
      );
      if (followup.isNotEmpty && _memoryReferencesCurrent(followup.single['id'] as String)) {
        result.add(Map<String, Object?>.from(ticket));
      }
    }
    return result;
  }

  List<MemoryRow> _agentSourcesForScope(
    List<MemoryRow> sources,
    String? characterId,
    String kind, {
    String? localDay,
  }) => [
    for (final source in sources)
      if (characterId == null
          ? source['role'] == 'user' &&
                (kind == 'organize' ? _agentSourceOnDay(source, localDay!) : source['character_id'] == null)
          : source['character_id'] == characterId)
        source,
  ];

  bool _agentSourceOnDay(MemoryRow source, String localDay) =>
      source['scope'] == 'real' &&
      _memoryLocalDay(source['said_at_utc'] as int, source['offset_minutes'] as int) == localDay;

  void _advanceAgentMaintenanceCommit(Row turn, Set<String> changed) {
    if (turn['origin_kind'] == 'chat') return;
    final claim = _agentClaim(turn['claim_id'] as String);
    final ids = {..._agentIds(claim['changed_cards'] as String), ...changed};
    final revisions = _agentRevisions(claim['card_revisions'] as String);
    final scopes = (jsonDecode(claim['scope_card_revisions'] as String) as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, (value as Map<String, dynamic>).cast<String, int>()),
    );
    for (final id in changed) {
      final cards = _db.select('SELECT row_rev,character_id FROM memory_cards WHERE id=?', [id]);
      if (cards.isEmpty) {
        revisions.remove(id);
        for (final scope in scopes.values) {
          scope.remove(id);
        }
      } else {
        if (turn['origin_kind'] == 'organize') {
          // The keeper's own output is not a fresh input on tomorrow's tick.
          _db.execute('UPDATE memory_cards SET maintenance_row_rev=row_rev WHERE id=?', [id]);
        }
        revisions[id] = cards.single['row_rev'] as int;
        for (final scope in scopes.entries) {
          if (cards.single['character_id'] == null || cards.single['character_id'] == scope.key) {
            scope.value[id] = cards.single['row_rev'] as int;
          }
        }
      }
    }
    _db.execute(
      'UPDATE memory_agent_maintenance_claims SET control_revision=?,memory_revision=?,changed_cards=?,'
      'card_revisions=?,scope_card_revisions=? WHERE id=?',
      [
        archive['control_revision'],
        archive['memory_revision'],
        jsonEncode(ids.toList()..sort()),
        _canonicalJson(revisions),
        _canonicalJson(scopes),
        claim['id'],
      ],
    );
  }

  void _migrateAgentMemory16() {
    // Back up values without FKs, then drop the child before its parent. This
    // does not rely on SQLite rename rewriting a live call/task reference.
    _db.execute('CREATE TEMP TABLE agent_turns_before16 AS SELECT * FROM memory_agent_turns');
    _db.execute('CREATE TEMP TABLE agent_calls_before16 AS SELECT * FROM memory_agent_calls');
    _db.execute('DROP TABLE memory_agent_calls');
    _db.execute('DROP TABLE memory_agent_turns');
    _db.execute(_agentMaintenanceSchema16);
    _db.execute('''
      INSERT INTO memory_agent_turns(
        id,origin_kind,source_message_id,source_rev,claim_id,character_id,archive_id,memory_revision,
        control_revision,shown_cards,changed_cards,closed)
      SELECT t.id,'chat',t.source_message_id,t.source_rev,NULL,m.character_id,a.id,a.memory_revision,
        t.control_revision,t.shown_cards,t.changed_cards,t.closed
      FROM agent_turns_before16 t JOIN memory_messages m ON m.id=t.source_message_id
        CROSS JOIN memory_archive a
    ''');
    _db.execute('''
      INSERT INTO memory_agent_calls(
        turn_id,call_id,tool_name,input_sha256,item_no,state,code,target_id,changed_cards,
        before_control_revision,after_control_revision,task_id,task_rev)
      SELECT turn_id,call_id,tool_name,input_sha256,item_no,state,code,target_id,changed_cards,
        before_control_revision,after_control_revision,task_id,task_rev FROM agent_calls_before16
    ''');
    _db.execute('DROP TABLE agent_calls_before16');
    _db.execute('DROP TABLE agent_turns_before16');
  }
}

const _agentMaintenanceSchema16 = '''
CREATE TABLE memory_agent_maintenance_claims (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('extract','organize')),
  archive_id TEXT NOT NULL, control_revision INTEGER NOT NULL, memory_revision INTEGER NOT NULL,
  source_revisions TEXT NOT NULL, event_sequences TEXT NOT NULL, card_revisions TEXT NOT NULL,
  scope_card_revisions TEXT NOT NULL, scope_presentations TEXT NOT NULL, scope_characters TEXT NOT NULL, completed_scopes TEXT NOT NULL,
  changed_cards TEXT NOT NULL, local_day TEXT, zone_id TEXT,
  created_at_ms INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('claimed','finished','interrupted','not_sent')),
  CHECK(kind!='organize' OR local_day IS NOT NULL)
);
CREATE UNIQUE INDEX memory_agent_organize_day
  ON memory_agent_maintenance_claims(local_day) WHERE kind='organize' AND state!='not_sent';
CREATE TABLE memory_agent_turns (
  id TEXT PRIMARY KEY, origin_kind TEXT NOT NULL CHECK(origin_kind IN ('chat','extract','organize')),
  source_message_id TEXT REFERENCES memory_messages(id) ON DELETE CASCADE, source_rev INTEGER,
  claim_id TEXT REFERENCES memory_agent_maintenance_claims(id),
  character_id TEXT REFERENCES memory_characters(id),
  archive_id TEXT NOT NULL, memory_revision INTEGER NOT NULL, control_revision INTEGER NOT NULL,
  shown_cards TEXT NOT NULL, changed_cards TEXT NOT NULL,
  closed INTEGER NOT NULL DEFAULT 0 CHECK(closed IN (0,1)),
  UNIQUE(source_message_id,source_rev),
  CHECK((origin_kind='chat' AND source_message_id IS NOT NULL AND source_rev IS NOT NULL AND claim_id IS NULL)
    OR (origin_kind IN ('extract','organize') AND source_message_id IS NULL AND source_rev IS NULL AND claim_id IS NOT NULL))
);
CREATE UNIQUE INDEX memory_agent_claim_scope
  ON memory_agent_turns(claim_id,COALESCE(character_id,'')) WHERE claim_id IS NOT NULL;
CREATE TABLE memory_agent_calls (
  turn_id TEXT NOT NULL REFERENCES memory_agent_turns(id) ON DELETE CASCADE,
  call_id TEXT NOT NULL, tool_name TEXT NOT NULL, input_sha256 TEXT NOT NULL,
  item_no INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','applied','ignored','accepted')),
  code TEXT, target_id TEXT, changed_cards TEXT NOT NULL,
  before_control_revision INTEGER NOT NULL, after_control_revision INTEGER NOT NULL,
  task_id TEXT, task_rev INTEGER,
  PRIMARY KEY(turn_id,call_id)
);
CREATE TABLE memory_agent_maintenance_requests (
  request_id TEXT PRIMARY KEY REFERENCES memory_requests(id),
  turn_id TEXT NOT NULL REFERENCES memory_agent_turns(id),
  claim_id TEXT NOT NULL REFERENCES memory_agent_maintenance_claims(id)
);
CREATE INDEX memory_agent_claim_requests ON memory_agent_maintenance_requests(claim_id,request_id);
''';
