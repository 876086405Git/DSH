import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

String _identity(int value) => value.toRadixString(16).padLeft(64, '0');

void main() {
  const hour = 3600000, day = 24 * hour;
  late Directory directory;
  late Database db;
  late CompanionMemoryStore store;
  var now = 1800000000000;
  void open() {
    db = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(db, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow? remember(int event, {int? at, int? control, String text = 'The parcel is ready for pickup.'}) =>
      store.rememberNotice(
        eventId: _identity(event),
        notificationKey: _identity(120),
        personId: _identity(210),
        packageName: 'example.delivery',
        appName: 'Parcel',
        text: text,
        observedAtMs: at ?? now,
        expectedControlRevision: control ?? store.archive['control_revision']! as int,
      );

  void initiative() => store.initializeInitiative({'inviteAtMs': <int>[], 'signalAtMs': <int>[], 'declinedUntilMs': 0});

  String? reserve(int event, {int? person, int daily = 10, int gap = 0}) => store.reserveInitiative(
    kind: 'signal',
    nowMs: now,
    maxPerDay: daily,
    gapMs: gap,
    noticeEventId: _identity(event),
    noticePersonId: _identity(person ?? event + 50),
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('companion-notice-');
    now = 1800000000000;
    open();
  });
  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  test('a notice keeps its app and observed time without creating a chat message or user proof', () {
    final at = now - hour;
    final card = remember(1, at: at)!;
    expect(card['collection'], 'recent');
    expect(card['source'], {
      'kind': 'notice',
      'package': 'example.delivery',
      'app': 'Parcel',
      'observed_at_ms': at,
      'user_confirmed': false,
    });
    expect(card['source_at_ms'], at);
    expect(card['evidence'], isEmpty);
    expect(store.messages(), isEmpty);
    expect(db.select('SELECT * FROM memory_card_sources'), isEmpty);
    reopen();
    expect(store.noticeMemories().single, card);
    expect(remember(1, at: at, text: 'A different paraphrase.'), isNull);
  });

  test('recall expires exactly seven days after observation and late classification cannot refresh it', () {
    final at = now - 6 * day;
    final card = remember(1, at: at)!;
    expect(card['expires_at_ms'], at + 7 * day);
    expect(isMemoryContextEligible(card, nowMs: at + 7 * day - 1), isTrue);
    now = at + 7 * day;
    expect(isMemoryContextEligible(store.noticeMemories().single, nowMs: now), isFalse);
    expect(remember(2, at: at), isNull);
    expect(remember(3, at: now + 1), isNull);
  });

  test('related returns the live origin but omits even app and time after a notice expires', () {
    final id = remember(1)!['id']! as String;
    store.submitMessage(id: 'chat', sessionId: 'light:room', text: 'Hello.', saidAtUtc: now, offsetMinutes: 0);
    final turn =
        store.beginAgentTurn(messageId: 'chat', expectedSourceRev: 1, shownCardRevisions: {id: 1})['id']! as String;
    List<MemoryRow> related(String callId, MemoryRow input) =>
        store.applyAgentMemoryTool(turnId: turn, callId: callId, toolName: 'related', input: input).relatedCards!;
    final live = related('live', {'card': id}).single;
    expect(live['source'], containsPair('app', 'Parcel'));
    expect(live['text'], isNotEmpty);
    now += 7 * day;
    expect(related('expired-root', {'card': id}), isEmpty);
    expect(related('expired-all', {}), isEmpty);
    expect(store.noticeMemories().single['id'], id);
  });

  test('deleting one notice, dismissing another and clearing the rest block each opaque event across reopen', () {
    final first = remember(1)!;
    remember(2);
    final captured = store.archive['control_revision']! as int;
    store.deleteCard(id: first['id']! as String, expectedRowRev: first['row_rev']! as int);
    expect(store.noticeSuppressed(_identity(2)), isFalse);
    expect(
      () => remember(3, control: captured),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/conflict')),
    );
    store.dismissNotice(_identity(3));
    store.clearNoticeMemories();
    reopen();
    expect(store.noticeMemories(), isEmpty);
    initiative();
    for (final event in [1, 2, 3]) {
      expect(store.noticeSuppressed(_identity(event)), isTrue);
      expect(remember(event), isNull);
      expect(reserve(event), isNull);
    }
    expect(db.select('SELECT * FROM memory_notice_sources'), isEmpty);
    final beforeClear = store.archive['control_revision']! as int;
    store.clearNoticeMemories();
    expect(
      () => remember(4, control: beforeClear),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/conflict')),
    );
    expect(remember(4), isNotNull);
  });

  test('a single dismiss or notice-only clear never removes an independently saved identical sentence', () {
    const manual = '00000000-0000-4000-8000-000000000022';
    const summary = 'The parcel is ready for pickup.';
    store.saveManual(
      CompanionMemory(id: manual, text: summary),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    remember(11, text: summary);
    final second = remember(22, text: summary)!;
    store.dismissNotice(_identity(11));
    expect(store.noticeSuppressed(_identity(22)), isFalse);
    expect(store.noticeMemories().single['id'], second['id']);
    store.clearNoticeMemories();
    expect(store.cards().single['id'], manual);
  });

  test('obvious sensitive categories never create an unconfirmed recent card', () {
    for (final text in [
      'Hospital appointment.',
      'Loan approved.',
      'Church membership.',
      'Political affiliation.',
      'Sexual orientation.',
      'Spouse filed for divorce.',
      '醫院通知檢查結果。',
      '您本月的銀行帳單。',
      '這是您的驗證碼。',
      '臨時密碼。',
    ]) {
      expect(
        () => remember(1, text: text),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/notice-invalid')),
      );
    }
    expect(store.noticeMemories(), isEmpty);
  });

  test('a tool cannot revise, merge or use an observed notice as proof for a permanent card', () {
    final first = remember(1)!['id']! as String;
    final second = remember(2, text: 'A calendar invitation arrived.')!['id']! as String;
    store.submitMessage(id: 'turn', sessionId: 'light:room', text: 'Hello.', saidAtUtc: now, offsetMinutes: 0);
    final turn =
        store.beginAgentTurn(messageId: 'turn', expectedSourceRev: 1, shownCardRevisions: {first: 1, second: 1})['id']!
            as String;
    String? invoke(String name, MemoryRow input) =>
        store.applyAgentMemoryTool(turnId: turn, callId: 'try-$name', toolName: name, input: input).code;

    expect(invoke('revise', {'card': first, 'text': 'Permanent.'}), 'notice_requires_user_source');
    expect(
      invoke('remember', {
        'collection': 'about_you',
        'text': 'Permanent.',
        'references': [first],
      }),
      'notice_requires_user_source',
    );
    expect(
      invoke('merge', {
        'card': first,
        'from': [second],
      }),
      'merge_domain_changed',
    );
    expect(
      () => store.saveManual(
        CompanionMemory(id: first, text: 'Permanent.'),
        expectedRowRev: 1,
        currentValueChange: true,
        realityKnown: true,
      ),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/notice-readonly')),
    );
    expect(store.nextBatch(forceTail: true, estimateTokens: (_) => 1)!.existing, isEmpty);
    expect(db.select('SELECT * FROM memory_card_references'), isEmpty);
    expect(store.noticeMemories().map((r) => r['row_rev']), [1, 1]);
  });

  test('a notice and an ordinary initiative compete for the same spend, which a released ticket returns', () {
    initiative();
    final regular = store.reserveInitiative(kind: 'invite', nowMs: now, maxPerDay: 1, gapMs: 0)!;
    expect(reserve(1, daily: 1), isNull);
    store.settleInitiative(regular, outcome: 'released');
    final notice = reserve(1, daily: 1)!;
    expect(store.reserveInitiative(kind: 'invite', nowMs: now, maxPerDay: 1, gapMs: 0), isNull);
    store.settleInitiative(notice, outcome: 'released');
    expect(reserve(1, daily: 1), isNotNull);
  });

  test('the two-hour gate uses only the originating conversation within its app', () {
    initiative();
    store.settleInitiative(reserve(1, person: 21)!, outcome: 'shown');
    now += 31 * 60000;
    expect(reserve(2, person: 21), isNull);
    expect(reserve(1, person: 22, gap: 30 * 60000), isNotNull);
    expect(store.canSpeakNotice(eventId: _identity(2), nowMs: now), isFalse);
    now += 89 * 60000;
    expect(reserve(2, person: 21), isNotNull);
  });

  test('six notification spends survive reopening and free exactly at the rolling 24 hour boundary', () {
    initiative();
    for (int index = 0; index < 6; index++) {
      store.settleInitiative(reserve(index)!, outcome: 'shown');
    }
    reopen();
    now += day - 1;
    expect(reserve(7), isNull);
    expect(store.reserveInitiative(kind: 'invite', nowMs: now, maxPerDay: 10, gapMs: 0), isNotNull);
    now++;
    expect(reserve(7), isNotNull);
  });

  test('v16 migration preserves card children and settled request bytes, and restores the embedding trigger', () {
    const id = '00000000-0000-4000-8000-000000000011';
    store.saveManual(
      CompanionMemory(id: id, text: 'A manual note.'),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(
      store.saveMemoryEmbedding(characterId: null, cardId: id, rowRevision: 1, modelKey: 'test', vector: [1, 0]),
      isTrue,
    );
    final request = store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 1,
      outputTokens: 2,
    )!;
    store.markRequestSent(request);
    store.finishRequest(request, terminal: 'complete');
    final cards = store.cards(), receipts = store.requests();
    restoreOldMemorySchema(db, 16);
    expect(db.select('PRAGMA user_version').single['user_version'], 16);
    expect(db.select("SELECT name FROM sqlite_schema WHERE name LIKE 'memory_notice_%'"), isEmpty);
    expect(() => db.execute("UPDATE memory_cards SET collection='recent'"), throwsA(isA<SqliteException>()));
    expect(() => db.execute("UPDATE memory_requests SET category='notice'"), throwsA(isA<SqliteException>()));
    reopen();
    expect(db.select('PRAGMA user_version').single['user_version'], 17);
    expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    expect(store.cards(), cards);
    expect(store.requests(), receipts);
    expect(db.select('SELECT card_id FROM memory_embeddings').single['card_id'], id);
    store.saveManual(
      CompanionMemory(id: id, text: 'Revised.'),
      expectedRowRev: 1,
      currentValueChange: true,
      realityKnown: true,
    );
    expect(db.select('SELECT * FROM memory_embeddings'), isEmpty);
    expect(remember(2), isNotNull);
    final triage = store.reserveRequest(
      category: 'notice',
      provider: 'deepseek',
      model: 'deepseek-flash',
      inputTokens: 8,
      outputTokens: 4,
    );
    expect(triage, isNotNull);
    expect(store.requests().singleWhere((row) => row['id'] == triage)['category'], 'notice');
  });

  test('a future v18 file is refused without changing its version', () {
    final path = '${directory.path}/future.sqlite';
    final future = sqlite3.open(path)..execute('PRAGMA user_version=18');
    expect(
      () => CompanionMemoryStore(future, nowMilliseconds: () => now),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/newer-store')),
    );
    final read = sqlite3.open(path);
    try {
      expect(read.select('PRAGMA user_version').single['user_version'], 18);
    } finally {
      read.close();
    }
  });
}
