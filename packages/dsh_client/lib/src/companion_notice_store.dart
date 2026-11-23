part of 'companion_memory_store.dart';

/// Only validated summaries enter this port. Notification text is never a
/// memory_message, proof quote, tool source or request body in this database.
extension CompanionNoticeStore on CompanionMemoryStore {
  MemoryRow? rememberNotice({
    required String eventId,
    required String notificationKey,
    required String packageName,
    required String appName,
    required String text,
    required int observedAtMs,
    required int expectedControlRevision,
    String? personId,
  }) {
    _noticeIdentity(eventId);
    _noticeIdentity(notificationKey);
    if (personId != null) _noticeIdentity(personId);
    _messageText(text);
    if (packageName.isEmpty ||
        packageName.length > 255 ||
        appName.trim().isEmpty ||
        appName.runes.length > 100 ||
        text.runes.length > 120 ||
        companionNoticeContainsSecret(text) ||
        companionNoticeContainsSensitiveTopic(text)) {
      throw const DshRemoteException('companion/notice-invalid', 'Invalid notice summary', {'status': 400});
    }
    return _transaction(() {
      final at = _checkedNow();
      if (archive['control_revision'] != expectedControlRevision) throw _conflict;
      if (observedAtMs < 0 || observedAtMs > at || at - observedAtMs >= _noticeLifetimeMs) return null;
      if (noticeSuppressed(eventId)) return null;
      final existing = _db.select('SELECT card_id FROM memory_notice_sources WHERE event_id=?', [eventId]);
      if (existing.isNotEmpty) return null;
      final id = _createId();
      final topic = _createId();
      _db.execute('INSERT INTO memory_topics(id) VALUES(?)', [topic]);
      _db.execute(
        '''
        INSERT INTO memory_cards(id,row_rev,kind,text,keywords,pinned,scope,eligible,status,manual,
          topic_id,source_at_ms,created_at_ms,updated_at_ms,expires_at_ms,cleanup_history_complete,
          collection,maintenance_row_rev)
        VALUES(?,1,'episode',?, ?,0,'real',1,'current',0,?,?,?,?,?,1,'recent',1)
      ''',
        [
          id,
          text,
          jsonEncode([text]),
          topic,
          observedAtMs,
          at,
          at,
          observedAtMs + _noticeLifetimeMs,
        ],
      );
      _db.execute(
        '''
        INSERT INTO memory_notice_sources(card_id,event_id,notification_key,package_name,app_name,observed_at_ms,person_id)
        VALUES(?,?,?,?,?,?,?)
      ''',
        [id, eventId, notificationKey, packageName, appName, observedAtMs, personId],
      );
      _bumpMemory();
      return _card(
        _db.select(
          'SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id WHERE c.id=?',
          [id],
        ).single,
      );
    });
  }

  bool noticeSuppressed(String eventId) =>
      _db.select('SELECT 1 FROM memory_notice_tombstones WHERE event_id=?', [eventId]).isNotEmpty;

  /// The same opaque event is not proposed again after "leave this alone".
  /// No sender name, notification text or model wording is retained here.
  void dismissNotice(String eventId) {
    _noticeIdentity(eventId);
    _transaction(() {
      _db.execute('INSERT OR IGNORE INTO memory_notice_tombstones(event_id) VALUES(?)', [eventId]);
      final ids = _db.select('SELECT card_id FROM memory_notice_sources WHERE event_id=?', [eventId]);
      if (ids.isNotEmpty) {
        _deleteCards({for (final row in ids) row['card_id'] as String});
        _bumpMemory();
      }
      _bumpControl();
    });
  }

  /// A single control transaction also invalidates a batch already in flight.
  void clearNoticeMemories() => _transaction(() {
    final ids = {for (final row in _db.select('SELECT card_id FROM memory_notice_sources')) row['card_id'] as String};
    if (ids.isNotEmpty) {
      _deleteCards(ids);
      _bumpMemory();
    }
    _bumpControl();
  });

  /// The summary may stay on the memory page for deletion, but is never
  /// eligible for recall after its original seven-day window.
  List<MemoryRow> noticeMemories() => [
    for (final row in _db.select('''
      SELECT c.*,t.mode AS topic_mode FROM memory_cards c JOIN memory_topics t ON t.id=c.topic_id
      WHERE c.collection='recent' AND c.status!='withdrawn' ORDER BY c.source_at_ms DESC,c.id
    '''))
      _card(row),
  ];

  MemoryRow _noticeSource(String cardId) {
    final row = _db.select('SELECT * FROM memory_notice_sources WHERE card_id=?', [cardId]).single;
    return {
      'kind': 'notice',
      'package': row['package_name'],
      'app': row['app_name'],
      'observed_at_ms': row['observed_at_ms'],
      'user_confirmed': false,
    };
  }

  void _forgetNoticeCard(String cardId) => _db.execute(
    '''
    INSERT OR IGNORE INTO memory_notice_tombstones(event_id)
    SELECT event_id FROM memory_notice_sources WHERE card_id=?
  ''',
    [cardId],
  );

  /// Called in the shared initiative reservation transaction, before writing
  /// any spend. A notice debit is a normal signal debit with these extra gates.
  bool _noticeMaySpeak({required String eventId, String? personId, required int nowMs}) {
    if (personId == null || noticeSuppressed(eventId)) return false;
    final spent = _db.select(
      '''
      SELECT n.*,COALESCE(s.presented_at_ms,s.reserved_at_ms) AS at
      FROM memory_notice_spends n JOIN memory_initiative_spends s ON s.id=n.spend_id
      WHERE s.state!='released' AND COALESCE(s.presented_at_ms,s.reserved_at_ms)>?
    ''',
      [nowMs - 86400000],
    );
    if (spent.length >= 6) return false;
    return !spent.any((row) => nowMs - (row['at'] as int) < 7200000 && row['person_id'] == personId);
  }

  /// Used to avoid repeatedly offering a ticket whose narrower quota is full.
  /// reserveInitiative still repeats the check atomically at presentation.
  bool canSpeakNotice({required String eventId, String? personId, required int nowMs}) =>
      _noticeMaySpeak(eventId: eventId, personId: personId, nowMs: nowMs);

  void _migrateNotices() {
    // Rebuilding the CHECK for the new collection must not cascade-delete
    // proofs/tasks in other tables. This connection holds the write lock for
    // the complete rebuild and checks every foreign key before committing.
    _db.execute('PRAGMA foreign_keys=OFF');
    try {
      _transaction(() {
        final triggers = [
          for (final row in _db.select(
            "SELECT sql FROM sqlite_master WHERE type='trigger' AND tbl_name='memory_cards'",
          ))
            row['sql'] as String,
        ];
        _db.execute(_noticeSchema17);
        for (final trigger in triggers) {
          _db.execute(trigger);
        }
        if (_db.select('PRAGMA foreign_key_check').isNotEmpty) throw _conflict;
        _db.execute('PRAGMA user_version=17');
      });
    } finally {
      _db.execute('PRAGMA foreign_keys=ON');
    }
  }
}

const _noticeLifetimeMs = 7 * 86400000;
final _noticeDigest = RegExp(r'^[a-f0-9]{64}$');
void _noticeIdentity(String value) {
  if (!_noticeDigest.hasMatch(value)) throw ArgumentError('Invalid notice identity');
}

final _noticeSecret = RegExp(
  r'验证码|校验码|校驗碼|动态码|動態碼|口令|密码|密碼|驗證碼|\bone[- ]time\b|\b(?:otp|passcode|password|verification code)\b',
  caseSensitive: false,
);
// A second, deterministic boundary for recognizable sensitive source or output.
// The prompt also restricts semantic classification to mundane, affirmative topics.
final _noticeSensitive = RegExp(
  r'健康|医疗|醫療|医院|醫院|门诊|門診|看病|诊断|診斷|病历|病歷|药物|藥物|用药|用藥|治疗|治療|体检|體檢|血压|血壓|血糖|抑郁|抑鬱|怀孕|懷孕|自杀|自殺|'
  r'财务|金融|银行|銀行|账单|帳單|余额|餘額|信用卡|还款|還款|贷款|貸款|转账|轉帳|交易|账户|帳戶|投资|投資|工资|工資|薪资|薪資|薪水|'
  r'政治|选举|選舉|投票|政党|政黨|宗教|信仰|教会|教會|教堂|清真寺|佛教|基督|伊斯兰|'
  r'性取向|同性恋|同性戀|双性恋|雙性戀|伴侣|伴侶|配偶|夫妻|婚姻|离婚|離婚|丈夫|妻子|老婆|老公|女友|男友|男朋友|女朋友|恋爱|戀愛|分手|约会|'
  r'\b(?:medical|health|clinic|doctor|hospital|diagnosis|prescription|therapy|depression|insulin|disease|pregnan\w*|suicid\w*|'
  r'financial|bank|banking|salary|loan|mortgage|credit card|balance|payment|debt|invoice|invest\w*|'
  r'politic\w*|election|ballot|religio\w*|church|mosque|temple|sexual orientation|gay|lesbian|bisexual|'
  r'girlfriend|boyfriend|spouse|husband|wife|partner|marriage|divorce|dating)\b',
  caseSensitive: false,
);

// Both the triage boundary and the database write port share these rules.
// They reject recognizable terms; they do not prove semantic completeness.
String _noticePlain(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]'), '');
bool companionNoticeContainsSecret(String text) => _noticeSecret.hasMatch(_noticePlain(text));
bool companionNoticeContainsSensitiveTopic(String text) => _noticeSensitive.hasMatch(_noticePlain(text));

const _noticeSchema17 = '''
CREATE TABLE memory_cards_v17 (
  id TEXT PRIMARY KEY, row_rev INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('fact','preference','episode')), text TEXT NOT NULL,
  keywords TEXT NOT NULL DEFAULT '[]', pinned INTEGER NOT NULL DEFAULT 0,
  scope TEXT NOT NULL DEFAULT 'real' CHECK(scope IN ('real','story')), eligible INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'current' CHECK(status IN ('current','past','withdrawn')),
  manual INTEGER NOT NULL, topic_id TEXT NOT NULL REFERENCES memory_topics(id), current_basis_seq INTEGER,
  source_at_ms INTEGER NOT NULL, event_time TEXT, followup TEXT, plan_state TEXT,
  created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, expires_at_ms INTEGER,
  maintenance_row_rev INTEGER NOT NULL DEFAULT 0, cleanup_history_complete INTEGER NOT NULL DEFAULT 0,
  collection TEXT NOT NULL DEFAULT 'about_you'
    CHECK(collection IN ('about_you','person','our_story','diary','impression','recent')),
  character_id TEXT REFERENCES memory_characters(id)
    CHECK((collection IN ('about_you','person','diary','recent') AND character_id IS NULL)
       OR (collection IN ('our_story','impression') AND character_id IS NOT NULL)),
  local_day TEXT CHECK(collection!='diary' OR local_day IS NOT NULL),
  day_zone_id TEXT CHECK(collection!='diary' OR day_zone_id IS NOT NULL)
);
INSERT INTO memory_cards_v17 SELECT * FROM memory_cards;
DROP TABLE memory_cards;
ALTER TABLE memory_cards_v17 RENAME TO memory_cards;
CREATE INDEX memory_cards_domain ON memory_cards(character_id,collection,status);
CREATE UNIQUE INDEX memory_diary_day ON memory_cards(local_day) WHERE collection='diary';
CREATE UNIQUE INDEX memory_impression_character ON memory_cards(character_id) WHERE collection='impression';
CREATE TABLE memory_requests_v17 (
  id TEXT PRIMARY KEY, category TEXT NOT NULL CHECK(category IN ('chat','extract','organize','followup','notice')),
  batch_id TEXT, provider TEXT NOT NULL, model TEXT NOT NULL, reserved_at_ms INTEGER NOT NULL,
  sent_at_ms INTEGER, reserved_input INTEGER NOT NULL, reserved_output INTEGER NOT NULL,
  reserved_cny REAL, raw_usage TEXT, usage_semantics TEXT, input_uncached INTEGER,
  input_cache_read INTEGER, input_cache_write INTEGER, output_tokens INTEGER,
  estimated_cny REAL, state TEXT NOT NULL, terminal TEXT, uncertain_at_ms INTEGER
);
INSERT INTO memory_requests_v17 SELECT * FROM memory_requests;
DROP TABLE memory_requests;
ALTER TABLE memory_requests_v17 RENAME TO memory_requests;
CREATE TABLE memory_notice_sources (
  card_id TEXT PRIMARY KEY REFERENCES memory_cards(id) ON DELETE CASCADE,
  event_id TEXT NOT NULL UNIQUE, notification_key TEXT NOT NULL,
  package_name TEXT NOT NULL, app_name TEXT NOT NULL, observed_at_ms INTEGER NOT NULL, person_id TEXT
);
CREATE TABLE memory_notice_tombstones (event_id TEXT PRIMARY KEY);
CREATE TABLE memory_notice_spends (
  spend_id TEXT PRIMARY KEY REFERENCES memory_initiative_spends(id) ON DELETE CASCADE,
  person_id TEXT NOT NULL
);
''';
