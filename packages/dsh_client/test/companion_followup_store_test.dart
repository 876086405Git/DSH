import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

int utc(String value) => DateTime.parse(value).millisecondsSinceEpoch;

MemoryRow emptyInitiative() => {
  'v': 2,
  'lastGreetingAtMs': null,
  'inviteAtMs': <int>[],
  'signalAtMs': <int>[],
  'declinedUntilMs': 0,
  'night': null,
};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 0, nextId = 0;
  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(
      database,
      nowMilliseconds: () => now,
      createId: () => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}',
    );
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow submit(String id, String text, {int? saidAt, String role = 'user', String scope = 'real'}) =>
      store.submitMessage(
        id: id,
        sessionId: 'light:fixture',
        text: text,
        role: role,
        scope: scope,
        saidAtUtc: saidAt ?? now,
        offsetMinutes: 480,
      );
  MemoryRow invite({
    String id = 'invitation',
    String raw = '我周四去修琴，周五可以问我修琴的进展',
    String text = '我周四去修琴',
    String? keyword = '修琴',
    String kind = 'episode',
    String wording = '周五可以问我修琴的进展',
    String? date = '2026-11-20',
    String precision = 'day',
    MemoryRow? eventTime,
    MemoryRow? replace,
    int? saidAt,
    bool submitSource = true,
  }) {
    if (submitSource) submit(id, raw, saidAt: saidAt);
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => (text.runes.length / 4).ceil())!;
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'covered_message_ids': [for (final source in batch.sources) source['id']],
        'completion': 'complete',
        'operations': [
          {
            'op': replace == null ? 'create' : 'replace',
            'kind': kind,
            'text': text,
            'keywords': [?keyword],
            if (replace != null) 'target_id': replace['id'],
            if (replace != null) 'expected_row_rev': replace['row_rev'],
            'evidence': [
              {'message_id': id, 'quote': raw},
            ],
            'event_time': ?eventTime,
            'followup': {
              'local_date': date,
              'precision': precision,
              'wording': wording,
              'basis': 'explicit_invitation',
            },
          },
        ],
      }),
      batch,
    );
    expect(store.commitExtraction(batch, proposal), isTrue);
    return store.cards().singleWhere(
      (card) => (card['evidence'] as List).any((proof) => (proof as Map)['message_id'] == id),
    );
  }

  String? reserve({String kind = 'followup', MemoryRow? opportunity, int maximum = 2, int gap = 21600000}) =>
      store.reserveInitiative(
        kind: kind,
        nowMs: now,
        maxPerDay: maximum,
        gapMs: gap,
        followupId: opportunity?['id'] as String?,
      );
  List<MemoryRow> spends() => [
    for (final row in database.select('SELECT * FROM memory_initiative_spends ORDER BY reserved_at_ms,id')) {...row},
  ];
  String? request(String category, {int input = 10, int output = 20}) => store.reserveRequest(
    category: category,
    provider: 'deepseek',
    model: 'deepseek-flash',
    inputTokens: input,
    outputTokens: output,
    batchId: category == 'followup' ? 'followup:fixture:1' : null,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-followup-');
    now = utc('2026-11-16T04:00:00Z');
    nextId = 0;
    open();
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  group('B03 followup generation shares the auxiliary ledger', () {
    test('followup attempts do not consume extract or organize count slots', () {
      for (var index = 0; index < 2; index++) {
        final id = request('followup')!;
        store.markRequestSent(id);
        store.finishRequest(id, terminal: 'network');
      }
      for (var index = 0; index < 10; index++) {
        expect(request('extract'), isNotNull);
      }
      expect(request('extract'), isNull);
      expect(request('organize'), isNotNull);
      expect(request('organize'), isNull);
      expect(request('followup'), isNotNull);
      expect(store.requests().where((row) => row['category'] == 'followup'), hasLength(3));
      expect(store.requests().where((row) => row['category'] == 'followup').first['batch_id'], 'followup:fixture:1');
      expect(spends(), isEmpty, reason: 'generating a line is not presenting an initiative');
    });

    test('uncertain followup holds shared tokens through restart; only proved unsent can release', () {
      final id = request('followup', input: 24000, output: 3000)!;
      store.markRequestUncertain(id);
      store.finishRequest(id, terminal: 'network');
      reopen();
      expect(store.requests().single['terminal'], 'dispatch_unknown');
      for (final category in ['followup', 'extract', 'organize']) {
        expect(request(category), isNull, reason: category);
      }
      expect(request('chat'), isNotNull, reason: 'the auxiliary cap does not block a real chat');
      store.finishRequest(id, terminal: 'not_sent');
      expect(request('followup'), isNotNull);
    });

    test('followup raw usage remains charged to the default route for thirty rolling days', () {
      final id = request('followup')!;
      store.markRequestSent(id);
      store.recordUsage(id, {
        'usage_semantics': 'cumulative',
        'input_uncached': 0,
        'input_cache_read': 0,
        'input_cache_write': 0,
        'output_tokens': 400000,
      });
      store.finishRequest(id, terminal: 'complete');
      expect(store.requests().single['estimated_cny'], 3.2);
      now += 86400000;
      expect(request('extract'), isNull, reason: 'daily tokens expired, but the real observed cost did not');
      expect(request('followup'), isNull);
      now += 29 * 86400000;
      expect(request('followup'), isNotNull);
    });

    test('v6 migration preserves receipts and shown opportunities while removing the fixed line', () {
      store.initializeInitiative(emptyInitiative());
      invite();
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      store.settleInitiative(reserve(opportunity: opportunity)!, outcome: 'shown');
      final sent = request('extract')!;
      store.markRequestSent(sent);
      store.recordUsage(sent, {'usage_semantics': 'unknown', 'output_tokens': 8});
      store.finishRequest(sent, terminal: 'incomplete');
      final uncertain = request('organize')!;
      store.markRequestUncertain(uncertain);
      database.execute("UPDATE memory_followups SET local_line='上次提到的这件事，现在想聊聊吗？'");
      final beforeRequests = store.requests();
      final beforeSpends = spends();
      final beforeCards = store.cards();
      final beforeArchive = store.archive;
      restoreOldMemorySchema(database, 6);
      reopen();
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
      expect(store.requests(), beforeRequests);
      expect(spends(), beforeSpends);
      expect(store.cards(), [
        for (final card in beforeCards) {...card, 'cleanup_history_complete': 0},
      ]);
      expect(store.archive, beforeArchive);
      expect(store.followups().single['local_line'], isNull);
      expect(store.followups().single['state'], 'asked');
      expect(store.followups().single['row_rev'], opportunity['row_rev']);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(request('followup'), isNotNull);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    });

    test('failed v7 migration rolls the request CHECK and fixed-line cleanup back together', () {
      invite();
      now = utc('2026-11-20T01:00:00Z');
      store.nextFollowup(nowMs: now);
      database.execute("UPDATE memory_followups SET local_line='old fixed line'");
      restoreOldMemorySchema(database, 6);
      database.execute(
        "CREATE TRIGGER fail_line_cleanup BEFORE UPDATE ON memory_followups "
        "BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      store.close();
      expect(open, throwsA(isA<SqliteException>()));
      database = sqlite3.open('${directory.path}/memory.sqlite');
      expect(database.select('PRAGMA user_version').single['user_version'], 6);
      expect(database.select('SELECT local_line FROM memory_followups').single['local_line'], 'old fixed line');
      expect(database.select("SELECT name FROM sqlite_master WHERE name='memory_requests_v7'"), isEmpty);
      expect(
        database.select("SELECT sql FROM sqlite_master WHERE name='memory_requests'").single['sql'],
        isNot(contains("'followup'")),
      );
      database.execute('DROP TRIGGER fail_line_cleanup');
      database.close();
      open();
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
    });
  });

  group('one durable initiative ledger', () {
    test('v5 upgrade preserves memory and receipts and leaves old preference import uninitialized', () {
      invite();
      final before = store.archive;
      final cards = store.cards();
      final request = store.reserveRequest(
        category: 'chat',
        provider: 'other',
        model: 'model',
        inputTokens: 10,
        outputTokens: 20,
      )!;
      store.markRequestSent(request);
      store.finishRequest(request, terminal: 'incomplete');
      final requests = store.requests();
      restoreOldMemorySchema(database, 5);
      reopen();
      expect(database.select('PRAGMA user_version').single['user_version'], 17);
      expect(store.archive, before);
      expect(store.cards(), [
        for (final card in cards) {...card, 'cleanup_history_complete': 0},
      ]);
      expect(store.requests(), requests);
      expect(store.initiativeRecord(), isNull);
    });

    test('legacy kinds and timestamps survive restart; stale RAM can only update metadata', () {
      final night = <String, Object?>{
        'offsetMinutes': 480,
        'stableAfterMs': now - 3600000,
        'lastNightKey': null,
        'lastNightAtMs': null,
        'lastNightOffsetMinutes': null,
        'changedSinceLast': false,
      };
      final legacy = {
        ...emptyInitiative(),
        'lastGreetingAtMs': now - 3600000,
        'inviteAtMs': [now - 7200000],
        'signalAtMs': [now - 3600000],
        'night': night,
      };
      expect(store.initializeInitiative(legacy), legacy);
      expect(store.initializeInitiative(emptyInitiative()), legacy);
      now += 21600000;
      final reserved = reserve(kind: 'signal', maximum: 6)!;
      store.settleInitiative(reserved, outcome: 'shown');
      store.writeInitiativeMetadata({...legacy, 'declinedUntilMs': now + 600000});
      final actual = store.initiativeRecord()!;
      expect(actual['inviteAtMs'], legacy['inviteAtMs']);
      expect(actual['signalAtMs'], [...(legacy['signalAtMs'] as List), now]);
      expect(actual['declinedUntilMs'], now + 600000);
      expect(actual['night'], night);
      reopen();
      expect(store.initiativeRecord(), actual);
      expect(spends().map((row) => row['kind']), ['invite', 'signal', 'signal']);
    });

    test('failed first import rolls back metadata and every imported spend', () {
      database.execute(
        "CREATE TRIGGER fail_import BEFORE INSERT ON memory_initiative_spends BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      expect(
        () => store.initializeInitiative({
          ...emptyInitiative(),
          'inviteAtMs': [now - 3600000],
        }),
        throwsA(isA<SqliteException>()),
      );
      expect(store.initiativeRecord(), isNull);
      expect(spends(), isEmpty);
      database.execute('DROP TRIGGER fail_import');
      store.initializeInitiative({
        ...emptyInitiative(),
        'inviteAtMs': [now - 3600000],
      });
      expect(store.initiativeRecord()!['inviteAtMs'], [now - 3600000]);
    });

    test('ordinary invitation and followup share both gap and rolling daily allowance', () {
      store.initializeInitiative(emptyInitiative());
      invite();
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final original = reserve(kind: 'invite')!;
      store.settleInitiative(original, outcome: 'shown');
      expect(reserve(opportunity: opportunity), isNull);
      now += 21600000;
      final followup = reserve(opportunity: opportunity)!;
      store.settleInitiative(followup, outcome: 'shown');
      now += 21600000;
      expect(
        reserve(kind: 'invite'),
        isNull,
        reason: 'both original invitation and followup occupy the same two slots',
      );
      expect(store.initiativeRecord()!['inviteAtMs'], hasLength(1));
      expect(store.initiativeRecord()!['signalAtMs'], hasLength(1));
    });

    test('followup independently caps one per rolling day, without making ordinary invitations free', () {
      store.initializeInitiative(emptyInitiative());
      invite();
      invite(id: 'second', raw: '我周四去看陶杯，周五你可以问问我', text: '我周四去看陶杯', keyword: '陶杯', wording: '周五你可以问问我');
      now = utc('2026-11-20T01:00:00Z');
      final first = store.nextFollowup(nowMs: now)!;
      store.settleInitiative(reserve(opportunity: first, maximum: 6)!, outcome: 'shown');
      now += 21600000;
      final second = store.nextFollowup(nowMs: now)!;
      expect(second['id'], isNot(first['id']));
      expect(reserve(opportunity: second, maximum: 6), isNull);
      store.settleInitiative(reserve(kind: 'invite', maximum: 6)!, outcome: 'shown');
      now += 18 * 3600000;
      expect(
        reserve(opportunity: second, maximum: 6),
        isNotNull,
        reason: 'the first followup leaves the rolling day exactly at 24 hours',
      );
    });

    test('a known false render releases both reservation and opportunity; insert failure rolls both back', () {
      store.initializeInitiative(emptyInitiative());
      invite();
      now = utc('2026-11-20T01:00:00Z');
      final original = store.nextFollowup(nowMs: now)!;
      database.execute(
        "CREATE TRIGGER fail_reserve BEFORE INSERT ON memory_initiative_spends BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      expect(() => reserve(opportunity: original), throwsA(isA<SqliteException>()));
      expect(store.followups().single['state'], 'pending');
      expect(spends(), isEmpty);
      database.execute('DROP TRIGGER fail_reserve');
      final reservation = reserve(opportunity: original)!;
      expect(store.isFollowupCurrent(original, nowMs: now), isTrue);
      store.settleInitiative(reservation, outcome: 'released');
      expect(store.isFollowupCurrent(original, nowMs: now), isFalse);
      expect(store.initiativeRecord()!['signalAtMs'], isEmpty);
      final fresh = store.nextFollowup(nowMs: now)!;
      expect(fresh['id'], original['id']);
      expect(fresh['row_rev'], greaterThan(original['row_rev'] as int));
      expect(reserve(opportunity: fresh), isNotNull);
    });

    test('process death with a reservation becomes unknown, never a replay or a free slot', () {
      store.initializeInitiative(emptyInitiative());
      invite();
      now = utc('2026-11-20T01:00:00Z');
      final original = store.nextFollowup(nowMs: now)!;
      reserve(opportunity: original);
      reopen();
      expect(spends().single['state'], 'unknown');
      expect(store.followups().single['state'], 'maybe_shown');
      expect(store.followups().single['presented_at_ms'], isNull);
      expect(store.initiativeRecord()!['signalAtMs'], [now]);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.isFollowupCurrent(original, nowMs: now), isFalse);
    });
  });

  group('current invitation, one presentation, original time', () {
    setUp(() {
      store.initializeInitiative(emptyInitiative());
    });

    test('fixture 9 authorizes a direct question but a date with a mistaken model label does not', () {
      invite(id: 'authorized', raw: '周五可以问我琴修好没', text: '周五可以问我琴修好没', keyword: '琴', wording: '周五可以问我琴修好没');
      invite(id: 'plan-only', raw: '周五去修琴', text: '周五去修琴', wording: '周五');
      now = utc('2026-11-20T01:00:00Z');
      expect(store.nextFollowup(nowMs: now)!['message_id'], 'authorized');
      expect(store.followups(), hasLength(1));
    });

    for (final recipient in ['医生', '我妈', '老师', '他', '王总', '我的老师']) {
      test('a question to $recipient keeps its factual card without creating a followup', () {
        const fact = '我周四去修琴';
        final wording = '周五可以问$recipient修琴的进展';
        final raw = '$fact，$wording';
        final saved = invite(raw: raw, text: fact, wording: wording);
        expect(store.cards(), hasLength(1));
        expect(saved['text'], fact);
        expect(saved['eligible'], isTrue);
        final proof = (saved['evidence']! as List<Object?>).cast<MemoryRow>().single;
        expect(proof['quote'], raw);
        now = utc('2026-11-20T01:00:00Z');
        expect(store.nextFollowup(nowMs: now), isNull);
        expect(store.followups(), isEmpty);
        reopen();
        expect(store.cards().single['id'], saved['id']);
        expect(store.cards().single['text'], fact);
        expect(store.nextFollowup(nowMs: now), isNull);
        expect(store.followups(), isEmpty);
        expect(store.requests(), isEmpty);
        expect(spends(), isEmpty);
      });
    }

    test('wording limits stay in the complete invitation for generation; no local question is substituted', () {
      const question = '周五可以问我琴修好没';
      final examples = ['$question，只问修好没，不问想不想聊。', '只问修好没，不问想不想聊。$question。', '$question但不问想不想聊'];
      for (var index = 0; index < examples.length; index++) {
        invite(
          id: 'limited-$index',
          raw: examples[index],
          text: question,
          keyword: '琴',
          wording: index == 2 ? examples[index] : question,
        );
      }
      invite(
        id: 'constraint-card',
        raw: '周五可以问问我，不问想不想聊。',
        text: '不问想不想聊',
        keyword: null,
        kind: 'preference',
        wording: '周五可以问问我',
      );
      now = utc('2026-11-20T01:00:00Z');
      expect(store.nextFollowup(nowMs: now), isNotNull);
      expect(store.followups(), hasLength(4));
      for (final opportunity in store.followups()) {
        expect(opportunity['state'], 'pending');
        expect(opportunity['reason'], isNull);
        expect(opportunity['local_line'], isNull);
        expect(opportunity['invitation'], contains('不问想不想聊'));
      }
      expect(store.requests(), isEmpty);
      expect(spends(), isEmpty);
    });

    test('an unsupported longer time token cannot be shortened to a familiar weekday', () {
      invite(
        raw: '下下周五去面试，过后你可以问问我。',
        text: '下下周五去面试',
        keyword: '面试',
        wording: '过后你可以问问我',
        date: null,
        precision: 'unspecified',
        eventTime: {'local_date': null, 'precision': 'unspecified', 'wording': '下下周五'},
      );
      now = utc('2026-11-28T01:00:00Z');
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().single['opens_at_ms'], isNull);
      expect(store.followups().single['state'], 'waiting');
      expect(store.requests(), isEmpty);
    });

    test('shown stays current for its existing bubble but cannot be reserved again after silence or restart', () {
      invite();
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final reservation = reserve(opportunity: opportunity)!;
      now += 50;
      store.settleInitiative(reservation, outcome: 'shown');
      store.settleInitiative(reservation, outcome: 'shown');
      expect(store.followups().single['presented_at_ms'], now);
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isTrue);
      expect(reserve(opportunity: opportunity), isNull);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(() => store.settleInitiative(reservation, outcome: 'released'), throwsA(isA<DshRemoteException>()));
      reopen();
      now += 86400000;
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().single['state'], 'asked');
    });

    test('cancel after reserve invalidates captured content; release does not reopen it', () {
      final card = invite(eventTime: {'local_date': '2026-11-19', 'precision': 'day', 'wording': '周四'});
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final reservation = reserve(opportunity: opportunity)!;
      submit('cancel', '修琴取消了');
      store.applyControl(topicIds: [card['topic_id'] as String], kind: 'cancel', controlMessageId: 'cancel');
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isFalse);
      store.settleInitiative(reservation, outcome: 'released');
      expect(store.followups().single['state'], 'closed');
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.cards().single['plan_state'], 'cancelled');
      expect(store.cards().single['text'], card['text']);
      expect(store.cards().single['event_time'], card['event_time']);
      expect(store.followups().single['invitation'], isEmpty);
      expect(store.followups().single['local_line'], isNull);
    });

    test('a true render remains charged if its callback reenters a forget operation', () {
      final card = invite();
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final reservation = reserve(opportunity: opportunity)!;
      store.deleteCard(id: card['id'] as String, expectedRowRev: card['row_rev'] as int);
      store.settleInitiative(reservation, outcome: 'shown');
      expect(store.followups(), isEmpty);
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isFalse);
      expect(store.initiativeRecord()!['signalAtMs'], [now]);
      expect(spends().single['state'], 'shown');
      expect(spends().single.keys, isNot(contains('invitation')));
    });

    test('postponement drops only the selected old date and requires a new explicit arrangement', () {
      final card = invite(eventTime: {'local_date': '2026-11-19', 'precision': 'day', 'wording': '周四'});
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final command = submit('postpone', '修琴改期了，时间还没定');
      final parsed = parseMemoryControl(command['text'] as String, store.cards())!;
      expect(parsed['kind'], 'postpone');
      expect(parsed['target_card_ids'], [card['id']]);
      store.applyControl(
        topicIds: (parsed['topic_ids'] as List).cast<String>(),
        kind: 'postpone',
        controlMessageId: 'postpone',
      );
      final postponed = store.cards().single;
      expect(postponed['plan_state'], 'postponed');
      expect(postponed['event_time'], isNull);
      expect(postponed['followup'], isNull);
      expect(postponed['text'], card['text']);
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isFalse);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(
        selectMemoryContext(
          store.cards(),
          input: '修琴',
          nowMs: now,
          controlRevision: store.archive['control_revision'] as int,
        ).ids,
        isEmpty,
      );
      invite(id: 'rescheduled', raw: '我周日去修琴，周一可以问我修琴的进展', date: '2026-11-23', text: '我周日去修琴', wording: '周一可以问我修琴的进展');
      now = utc('2026-11-23T01:00:00Z');
      expect(store.nextFollowup(nowMs: now)!['message_id'], 'rescheduled');
    });

    test('an unresolved control closes existing invitations without changing cards or pretending to forget', () {
      final card = invite();
      now = utc('2026-11-20T01:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      final before = store.archive;
      submit('unclear', '忘掉那件事');
      store.finishUnresolvedControl(messageId: 'unclear', expectedSourceRev: 1);
      expect(store.cards(), [card]);
      expect(store.archive['history_after_seq'], before['history_after_seq']);
      expect(store.followups().single['reason'], 'unresolved_control');
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isFalse);
      store.applyControl(topicIds: [card['topic_id'] as String], kind: 'normal');
      expect(store.nextFollowup(nowMs: now), isNull);
      invite(id: 'renewed', raw: '我周四去修琴，周六可以问我修琴的进展', wording: '周六可以问我修琴的进展', date: '2026-11-21', replace: card);
      now = utc('2026-11-21T01:00:00Z');
      expect(store.nextFollowup(nowMs: now)!['message_id'], 'renewed');
    });

    test('unresolved scope also fences unmaterialized invitations and ones extracted only after restart', () {
      final existing = invite(id: 'not-refreshed');
      const lateRaw = '周五可以问我琴修好没';
      submit('late-extraction', lateRaw);
      final command = submit('unclear', '忘掉那件事');
      store.finishUnresolvedControl(messageId: 'unclear', expectedSourceRev: 1);
      expect(store.archive['history_after_seq'], 0);
      expect(store.archive['followup_after_seq'], command['first_seq']);
      expect(store.cards(), [existing]);
      expect(store.followups(), isEmpty);
      reopen();
      final late = invite(
        id: 'late-extraction',
        raw: lateRaw,
        text: lateRaw,
        keyword: '琴',
        wording: lateRaw,
        submitSource: false,
      );
      expect(store.cards(), hasLength(2), reason: 'the invitation fence does not discard the ordinary facts');
      now = utc('2026-11-20T01:00:00Z');
      expect(store.nextFollowup(nowMs: now), isNull);
      invite(
        id: 'new-invitation',
        raw: '周六可以问我琴修好没',
        text: '周六可以问我琴修好没',
        keyword: '琴',
        wording: '周六可以问我琴修好没',
        date: '2026-11-21',
        replace: late,
      );
      now = utc('2026-11-21T01:00:00Z');
      expect(store.nextFollowup(nowMs: now)!['message_id'], 'new-invitation');
    });

    test('pin changes invalidate the captured revision without changing the opportunity or extending its window', () {
      final card = invite();
      now = utc('2026-11-20T01:00:00Z');
      final old = store.nextFollowup(nowMs: now)!;
      store.setPinned(id: card['id'] as String, expectedRowRev: card['row_rev'] as int, pinned: true);
      expect(store.isFollowupCurrent(old, nowMs: now), isFalse);
      final fresh = store.nextFollowup(nowMs: now)!;
      expect(fresh['id'], old['id']);
      expect(fresh['expires_at_ms'], old['expires_at_ms']);
      expect(fresh['card_rev'], (card['row_rev'] as int) + 1);
    });

    test('expiry is exactly 72 hours from the original opening, not extraction or restart', () {
      invite();
      final opening = utc('2026-11-19T16:00:00Z');
      now = opening - 1;
      expect(store.nextFollowup(nowMs: now), isNull);
      now = opening;
      final opportunity = store.nextFollowup(nowMs: now)!;
      expect(opportunity['expires_at_ms'], opening + memoryFollowupWindowMs);
      now = opening + memoryFollowupWindowMs - 1;
      reopen();
      expect(store.nextFollowup(nowMs: now)!['expires_at_ms'], opportunity['expires_at_ms']);
      now++;
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().single['reason'], 'expired');
      now -= 60000;
      expect(
        store.nextFollowup(nowMs: now),
        isNull,
        reason: 'a clock rollback cannot reopen an already closed opportunity',
      );
    });

    test('a second invitation for the known same card and date cannot reset asked; a new explicit date can', () {
      var card = invite(
        raw: '我周四去修琴，过后你可以问问我',
        wording: '过后你可以问问我',
        date: null,
        precision: 'unspecified',
        eventTime: {'local_date': '2026-11-19', 'precision': 'day', 'wording': '周四'},
      );
      now = utc('2026-11-20T01:00:00Z');
      final first = store.nextFollowup(nowMs: now)!;
      expect(first['time_key'], 'day:2026-11-20');
      store.settleInitiative(reserve(opportunity: first)!, outcome: 'shown');
      card = invite(id: 'repeat', replace: card);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().where((row) => row['reason'] == 'already_presented'), hasLength(1));
      invite(id: 'new-date', raw: '我周四去修琴，周六可以问我修琴的进展', wording: '周六可以问我修琴的进展', date: '2026-11-21', replace: card);
      now = utc('2026-11-21T01:00:00Z');
      final next = store.nextFollowup(nowMs: now)!;
      expect(next['id'], isNot(first['id']));
      expect(reserve(opportunity: next), isNotNull);
    });

    test('D4 waits for a later firsthand completion and an edit invalidates that exact support', () {
      submit('older', '那本册子的校对结束了。', saidAt: now - 1000);
      invite(
        raw: '册子校对的事，等我说结束再问我想不想聊。',
        text: '我在校对册子',
        keyword: '册子',
        wording: '等我说结束再问我想不想聊',
        date: null,
        precision: 'unspecified',
      );
      now = utc('2026-11-19T09:30:00Z');
      submit('assistant', '那本册子的校对结束了。', role: 'assistant');
      submit('story', '那本册子的校对结束了。', scope: 'story');
      submit('unrelated', '那件外套的修补结束了。');
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().single['reason'], 'waiting_for_completion');
      final completionAt = now;
      submit('completed', '那本册子的校对结束了。');
      now = utc('2026-11-20T06:00:00Z');
      final opportunity = store.nextFollowup(nowMs: now)!;
      expect(opportunity['support_message_id'], 'completed');
      expect(opportunity['support_quote'], '那本册子的校对结束了。');
      expect(opportunity['opens_at_ms'], completionAt);
      expect(opportunity['expires_at_ms'], completionAt + memoryFollowupWindowMs);
      submit('repeated', '那本册子的校对结束了。');
      expect(store.nextFollowup(nowMs: now)!['support_message_id'], 'completed');
      store.editMessage(id: 'completed', expectedSourceRev: 1, text: '那本册子的校对还没结束。');
      expect(store.isFollowupCurrent(opportunity, nowMs: now), isFalse);
      final renewed = store.nextFollowup(nowMs: now)!;
      expect(
        renewed['support_message_id'],
        'repeated',
        reason: 'a different surviving direct statement must be checked as its own support',
      );
      store.editMessage(id: 'repeated', expectedSourceRev: 1, text: '那本册子的校对还没结束。');
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups().single['support_quote'], isNull);

      // Reuse the real D4 extraction path: a second current card can make an
      // already reserved completion ambiguous without changing its identities.
      submit('completed-once-more', '那本册子的校对结束了。');
      final reservedOpportunity = store.nextFollowup(nowMs: now)!;
      expect(reservedOpportunity['support_message_id'], 'completed-once-more');
      final reservation = reserve(opportunity: reservedOpportunity)!;
      expect(store.isFollowupCurrent(reservedOpportunity, nowMs: now), isTrue);
      final second = invite(
        id: 'second-book-invitation',
        raw: '册子校对的事，等我说结束再问我想不想聊。',
        text: '我在校对册子',
        keyword: '册子',
        wording: '等我说结束再问我想不想聊',
        date: null,
        precision: 'unspecified',
      );
      expect(second['id'], isNot(reservedOpportunity['card_id']));
      expect(store.archive['control_revision'], reservedOpportunity['control_revision']);
      expect(
        store.cards().singleWhere((card) => card['id'] == reservedOpportunity['card_id'])['row_rev'],
        reservedOpportunity['card_rev'],
      );
      expect(
        store.isFollowupCurrent(reservedOpportunity, nowMs: now),
        isFalse,
        reason: 'currentness must reject ambiguity before any next-followup poll',
      );
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.isFollowupCurrent(reservedOpportunity, nowMs: now), isFalse);
      store.settleInitiative(reservation, outcome: 'released');
      expect(spends().single['state'], 'released');
      expect(store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(store.nextFollowup(nowMs: now), isNull);
      expect(store.followups(), hasLength(2));
      expect(store.followups().every((row) => row['state'] == 'waiting'), isTrue);
    });

    test('D5 retains the missing-name restriction for generation without inventing a local line', () {
      invite(
        raw: '周六可以问问陶杯烧得怎样。开口第一句必须先叫它我给它取的小名，别另起名字。',
        text: '我等陶杯烧好',
        keyword: '陶杯',
        wording: '周六可以问问陶杯烧得怎样',
        date: '2026-11-21',
      );
      now = utc('2026-11-21T03:00:00Z');
      expect(store.nextFollowup(nowMs: now), isNotNull);
      expect(store.followups().single['state'], 'pending');
      expect(store.followups().single['reason'], isNull);
      expect(store.followups().single['local_line'], isNull);
      expect(store.followups().single['invitation'], contains('必须先叫它我给它取的小名，别另起名字'));
      expect(store.requests(), isEmpty);
      expect(spends(), isEmpty);
    });
  });
}
