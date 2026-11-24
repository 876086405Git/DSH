part of 'companion_memory_store.dart';

String _memoryLayer(String collection) => switch (collection) {
  'diary' => 'diary',
  'impression' => 'impression',
  _ => 'card',
};

extension CompanionMemoryScopeStore on CompanionMemoryStore {
  /// The application obtains this key from the actual installed pack. Display
  /// names, model-supplied role names and package versions are not identities.
  MemoryRow ensureCompanionCharacter({required String sourceKey}) {
    if (sourceKey.isEmpty || sourceKey.trim() != sourceKey || sourceKey.length > 4096 || sourceKey.contains('\u0000')) {
      throw ArgumentError.value(sourceKey, 'sourceKey');
    }
    return _transaction(() {
      final rows = _db.select('SELECT * FROM memory_characters WHERE source_key=?', [sourceKey]);
      final at = _checkedNow();
      if (rows.isNotEmpty) {
        final id = rows.single['id'] as String;
        _db.execute('UPDATE memory_characters SET last_seen_at_ms=MAX(last_seen_at_ms,?) WHERE id=?', [at, id]);
        return Map<String, Object?>.from(_db.select('SELECT * FROM memory_characters WHERE id=?', [id]).single);
      }
      final id = _createId();
      _db.execute('INSERT INTO memory_characters(id,source_key,first_seen_at_ms,last_seen_at_ms) VALUES(?,?,?,?)', [
        id,
        sourceKey,
        at,
        at,
      ]);
      return Map<String, Object?>.from(_db.select('SELECT * FROM memory_characters WHERE id=?', [id]).single);
    });
  }

  MemoryRow? companionCharacter(String id) {
    final rows = _db.select('SELECT * FROM memory_characters WHERE id=?', [id]);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  /// Null is an explicit shared-only domain, never an all-characters wildcard.
  /// This is the input to either automatic ranking or an explicit recall.
  /// Ranking cannot grant IDs or make stale references current.
  List<MemoryRow> memoryRetrievalCandidates({
    required String? characterId,
    String? input,
    Set<String> explicitTopicIds = const {},
  }) {
    _checkMemoryCharacter(characterId);
    final at = _checkedNow();
    final domain = _memoryDomainCards(characterId, includeEvidence: false);
    _loadRetrievalEvidence(domain);
    final explicit = {...explicitTopicIds, if (input != null) ...explicitMemoryTopics(input, domain)};
    final candidates = [
      for (final card in domain)
        if (card['layer'] == 'card' && isMemoryContextEligible(card, nowMs: at, explicitTopicIds: explicit)) card,
    ];
    if (candidates.isEmpty) return candidates;
    final stale = _staleReferenceRoots([for (final card in candidates) card['id'] as String]);
    return candidates..removeWhere((card) => stale.contains(card['id']));
  }

  void _loadRetrievalEvidence(Iterable<MemoryRow> cards) {
    final evidence = {for (final card in cards) card['id']: card['evidence'] as List<MemoryRow>};
    if (evidence.isEmpty) return;
    final statement = _db.prepare('''
      $_memoryEvidenceSelect
      WHERE s.card_id IN (SELECT value FROM json_each(?))
      ORDER BY s.card_id, s.support_group, m.first_seq
    ''');
    try {
      final rows = statement.selectCursor([jsonEncode(evidence.keys.toList())]);
      while (rows.moveNext()) {
        final source = rows.current;
        evidence[source['card_id']]!.add(Map<String, Object?>.from(source));
      }
    } finally {
      statement.close();
    }
  }

  /// A presentation query is deliberately separate from the model's grant
  /// path: hidden stories can still be recalled and forgotten in their domain.
  List<MemoryRow> memoryPageCards({required String? characterId}) {
    _checkMemoryCharacter(characterId);
    return [
      for (final card in _memoryDomainCards(characterId))
        if (card['collection'] != 'our_story' &&
            card['status'] != 'withdrawn' &&
            _memoryReferencesCurrent(card['id'] as String))
          card,
    ];
  }

  /// The rows of [memoryPageCards] the agent always carries: [characterId]'s
  /// impression and the diaries of local days from [fromDay] up to
  /// [beforeDay]. Narrowed in SQL, since reading and checking a card takes
  /// several queries of its own and the domain holds every card.
  List<MemoryRow> memoryFixedLayerCards({
    required String? characterId,
    required String fromDay,
    required String beforeDay,
    String? explicitUserInput,
  }) {
    _checkMemoryCharacter(characterId);
    final fixed = [
      for (final card in _memoryDomainCards(
        characterId,
        where:
            "AND c.status!='withdrawn' AND ((c.collection='impression' AND c.character_id=?) "
            "OR (c.collection='diary' AND c.local_day>=? AND c.local_day<?))",
        args: [characterId, fromDay, beforeDay],
      ))
        if (_memoryReferencesCurrent(card['id'] as String)) card,
    ];
    var explicit = const <String>{};
    if (explicitUserInput != null && fixed.any((card) => card['topic_mode'] == 'never')) {
      // Only an invitation needs the whole domain to resolve ambiguity. Matching
      // reads text, keywords and aliases, so the domain need not load evidence.
      Iterable<MemoryRow> domain() sync* {
        yield* _memoryDomainCards(characterId, includeEvidence: false);
      }
      explicit = explicitMemoryTopics(explicitUserInput, domain());
    }
    final at = _checkedNow();
    return [
      for (final card in fixed)
        if (isMemoryContextEligible(card, nowMs: at, explicitTopicIds: explicit)) card,
    ];
  }

  /// A stale private entry is removable, but its obsolete body must not return
  /// to a model through a management lookup after a shared fact was forgotten.
  List<MemoryRow> staleMemoryTargets({required String characterId}) {
    _checkMemoryCharacter(characterId);
    return [
      for (final row in _db.select(
        'SELECT id,row_rev,collection FROM memory_cards WHERE character_id=? AND status!=? ORDER BY id',
        [characterId, 'withdrawn'],
      ))
        if (!_memoryReferencesCurrent(row['id'] as String))
          {
            'id': row['id'],
            'row_rev': row['row_rev'],
            'collection': row['collection'],
            'layer': _memoryLayer(row['collection'] as String),
            'character_id': characterId,
            'stale': true,
            'reason': 'reference_changed',
          },
    ];
  }

  /// A failed candidate is skipped only for the caller's current opportunity;
  /// it is not marked asked and cannot prevent a later eligible candidate.
  MemoryRow? nextAgentFollowup({
    required int nowMs,
    required String? characterId,
    Set<String> excludedIds = const {},
  }) => _transaction(() {
    _checkMemoryCharacter(characterId);
    _refreshFollowups(nowMs);
    for (final row in _db.select("SELECT * FROM memory_followups WHERE state='pending' ORDER BY opens_at_ms,id")) {
      if (!excludedIds.contains(row['id']) && isAgentFollowupCurrent(row, nowMs: nowMs, characterId: characterId)) {
        return Map<String, Object?>.from(row);
      }
    }
    return null;
  });

  /// Recheck both the old receipt/currentness contract and the captured role.
  /// A shared fact does not grant another role's original invitation.
  bool isAgentFollowupCurrent(MemoryRow captured, {required int nowMs, required String? characterId}) {
    _checkMemoryCharacter(characterId);
    if (!isFollowupCurrent(captured, nowMs: nowMs)) return false;
    final rows = _db.select(
      '''
      SELECT 1 FROM memory_followups f JOIN memory_cards c ON c.id=f.card_id
        JOIN memory_messages m ON m.id=f.message_id
        LEFT JOIN memory_messages support ON support.id=f.support_message_id
      WHERE f.id=? AND (c.character_id IS NULL OR c.character_id=?)
        AND (m.character_id IS NULL OR m.character_id=?)
        AND (f.support_message_id IS NULL OR support.character_id IS NULL OR support.character_id=?)
    ''',
      [captured['id'], characterId, characterId, characterId],
    );
    return rows.isNotEmpty && _memoryReferencesCurrent(captured['card_id'] as String);
  }

  void _checkMemoryCharacter(String? characterId) {
    if (characterId != null && _db.select('SELECT 1 FROM memory_characters WHERE id=?', [characterId]).isEmpty) {
      throw _conflict;
    }
  }

  List<MemoryRow> _memoryDomainCards(
    String? characterId, {
    String where = '',
    List<Object?> args = const [],
    bool includeEvidence = true,
  }) => [
    for (final row in _db.select(
      '''
      SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id
      WHERE (c.character_id IS NULL OR c.character_id=?) $where ORDER BY c.id
    ''',
      [characterId, ...args],
    ))
      _memoryDomainCard(row, includeEvidence: includeEvidence),
  ];

  MemoryRow _memoryDomainCard(Row row, {required bool includeEvidence}) {
    final card = _card(row, includeEvidence: includeEvidence);
    if (card['collection'] != 'person') return card;
    final aliases = [
      for (final alias in _db.select('SELECT alias FROM memory_person_aliases WHERE card_id=? ORDER BY alias', [
        card['id'],
      ]))
        alias['alias'] as String,
    ];
    return {
      ...card,
      'aliases': aliases,
      // Aliases are model-written names for this exact person card. They aid
      // the existing lexical fallback, without becoming a merge decision.
      'keywords': <String>{...(card['keywords'] as List<String>), ...aliases}.toList(),
    };
  }

  bool _memoryReferencesCurrent(String cardId) => _staleReferenceRoots([cardId]).isEmpty;

  /// The [cardIds] that are missing, or that reach an ancestor which is
  /// missing, at another revision than referenced, or private to a different
  /// character than the root. Only current nodes are expanded; UNION keeps
  /// traversal finite even if an old stored graph contains a cycle.
  Set<Object?> _staleReferenceRoots(List<String> cardIds) => {
    for (final row in _db.select(
      '''
      WITH RECURSIVE ancestors(root,id,root_character,current) AS (
        SELECT j.value,j.value,c.character_id,c.id IS NOT NULL
          FROM json_each(?) j LEFT JOIN memory_cards c ON c.id=j.value
        UNION
        SELECT a.root,r.parent_card_id,a.root_character,
               p.id IS NOT NULL AND p.row_rev=r.parent_row_rev
                 AND (p.character_id IS NULL OR p.character_id IS a.root_character)
          FROM ancestors a JOIN memory_card_references r ON r.card_id=a.id
          LEFT JOIN memory_cards p ON p.id=r.parent_card_id
          WHERE a.current
      )
      SELECT DISTINCT root FROM ancestors WHERE NOT current
    ''',
      [jsonEncode(cardIds)],
    ))
      row['root'],
  };
}

const _memoryScopeSchema16 = '''
CREATE TABLE memory_characters (
  id TEXT PRIMARY KEY, source_key TEXT NOT NULL UNIQUE,
  first_seen_at_ms INTEGER NOT NULL, last_seen_at_ms INTEGER NOT NULL
);
ALTER TABLE memory_messages ADD COLUMN character_id TEXT REFERENCES memory_characters(id);
ALTER TABLE memory_topics ADD COLUMN character_id TEXT REFERENCES memory_characters(id);
ALTER TABLE memory_cards ADD COLUMN collection TEXT NOT NULL DEFAULT 'about_you'
  CHECK(collection IN ('about_you','person','our_story','diary','impression'));
ALTER TABLE memory_cards ADD COLUMN character_id TEXT REFERENCES memory_characters(id)
  CHECK((collection IN ('about_you','person','diary') AND character_id IS NULL)
     OR (collection IN ('our_story','impression') AND character_id IS NOT NULL));
ALTER TABLE memory_cards ADD COLUMN local_day TEXT CHECK(collection!='diary' OR local_day IS NOT NULL);
ALTER TABLE memory_cards ADD COLUMN day_zone_id TEXT CHECK(collection!='diary' OR day_zone_id IS NOT NULL);
CREATE INDEX memory_cards_domain ON memory_cards(character_id,collection,status);
CREATE INDEX memory_messages_character ON memory_messages(character_id,session_id,first_seq);
CREATE UNIQUE INDEX memory_diary_day ON memory_cards(local_day) WHERE collection='diary';
CREATE UNIQUE INDEX memory_impression_character ON memory_cards(character_id) WHERE collection='impression';
CREATE TABLE memory_card_references (
  card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
  parent_card_id TEXT NOT NULL, parent_row_rev INTEGER NOT NULL CHECK(parent_row_rev>=1),
  PRIMARY KEY(card_id,parent_card_id)
);
CREATE INDEX memory_references_parent ON memory_card_references(parent_card_id,card_id);
CREATE TABLE memory_person_aliases (
  card_id TEXT NOT NULL REFERENCES memory_cards(id) ON DELETE CASCADE,
  alias TEXT NOT NULL, normalized_alias TEXT NOT NULL,
  PRIMARY KEY(card_id,alias)
);
CREATE INDEX memory_person_alias_lookup ON memory_person_aliases(normalized_alias,card_id);
''';
