import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/old_memory_schema.dart';

const _query = '青桥美术馆 2026-11-21 开放公告';
const _url = 'https://gallery.example/notice/20261121';
const _otherUrl = 'https://gallery.example/hours';
const _page = <String, Object?>{'title': '馆方公告', 'content': '2026年11月21日临时闭馆，11月22日恢复开放。'};

void main() {
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1795219200000; // 2026-11-21 08:00, UTC+08:00.
  var serial = 0;

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  MemoryRow say(
    String id, {
    String role = 'user',
    String scope = 'real',
    String session = 'room-one',
    String text = '帮我查今天青桥美术馆开不开，给我馆方公告。',
  }) => store.submitMessage(
    id: id,
    sessionId: session,
    text: text,
    role: role,
    scope: scope,
    saidAtUtc: now,
    offsetMinutes: 480,
    zoneId: 'Asia/Shanghai',
    offsetSeconds: 28800,
  );

  MemoryRow create(String source, {bool full = false, int? deadline, int sourceRev = 1, int itemNo = 0}) =>
      store.createLookupFromMessage(
        messageId: source,
        expectedSourceRev: sourceRev,
        itemNo: itemNo,
        roomMode: full ? 'full' : 'light',
        hostKey: full ? 'original-host' : null,
        hostSessionId: full ? 'original-host-session' : null,
        executorId: 'phone-installation',
        lookup: CompanionLookupSpec(
          placeName: '青桥美术馆',
          localDate: '2026-11-21',
          zoneId: 'Asia/Shanghai',
          question: '开不开，给我馆方公告',
          deadlineAtMs: deadline ?? 1795219320000,
        ),
      );

  MemoryRow accept({bool full = false}) {
    say('source');
    return create('source', full: full);
  }

  MemoryRow claim(
    MemoryRow task, {
    String kind = 'search',
    MemoryRow input = const {'query': _query},
    String? requestId,
    String instance = 'original-instance',
    String executor = 'phone-installation',
  }) => store.claimLookupAttempt(
    taskId: task['task_id'] as String,
    expectedTaskRev: task['task_rev'] as int,
    requestId: requestId ?? 'request-${++serial}',
    kind: kind,
    input: input,
    executorId: executor,
    executionMode: task['room_mode'] == 'full' ? 'host' : 'phone',
    instanceId: task['room_mode'] == 'full' ? instance : null,
    provider: 'deepseek',
    model: 'configured-model',
    toolUnitPriceMicroCny: kind == 'answer' ? null : 5000,
    toolPriceAsOf: kind == 'answer' ? null : '2026-11-21',
  );

  MemoryRow finishTool(MemoryRow attempt, MemoryRow raw, {int status = 200, String terminal = 'complete'}) {
    final id = attempt['request_id'] as String;
    store.observeLookupAttempt(id, dispatched: true, httpStatus: status);
    return store.finishLookupAttempt(id, terminal: terminal, dispatched: true, complete: true, toolResponse: raw);
  }

  MemoryRow search(MemoryRow task, {List<String> urls = const [_url]}) => finishTool(claim(task), {
    'results': [
      for (final url in urls) {'url': url, 'title': '馆方公告', 'snippet': '待核原文', 'date': '2026-11-20'},
    ],
  });

  MemoryRow fetch(MemoryRow task, {String url = _url, MemoryRow page = _page}) =>
      finishTool(claim(task, kind: 'fetch', input: {'url': url}), page);

  MemoryRow proposal(
    MemoryRow page, {
    String status = 'done',
    String quote = '2026年11月21日临时闭馆',
    String day = '2026-11-21',
  }) => {
    'status': status,
    'conclusion': '今天临时闭馆。',
    'applicable_date': day,
    'evidence': [
      {'fetchRequestId': page['request_id'], 'quote': quote},
    ],
  };

  MemoryRow answer(MemoryRow task, MemoryRow page, MemoryRow result) {
    final attempt = claim(
      task,
      kind: 'answer',
      input: {
        'fetchRequestIds': [page['request_id']],
      },
    );
    return store.finishLookupAttempt(
      attempt['request_id'] as String,
      terminal: 'complete',
      dispatched: true,
      complete: true,
      answerText: jsonEncode(result),
      rawUsage: const {'prompt_tokens': 77, 'completion_tokens': 12},
      normalizedUsage: const {'inputTokens': 77, 'outputTokens': 12},
    );
  }

  MemoryRow finish(MemoryRow task, {String state = 'done', MemoryRow? result, String? reason}) => store.finishLookup(
    taskId: task['task_id'] as String,
    expectedTaskRev: task['task_rev'] as int,
    state: state,
    result: result,
    reason: reason,
  );

  MemoryRow cancel(MemoryRow task, {String session = 'room-one', String command = 'cancel'}) {
    say(command, session: session);
    return store.cancelLookup(
      taskId: task['task_id'] as String,
      expectedTaskRev: task['task_rev'] as int,
      messageId: command,
      expectedSourceRev: 1,
      itemNo: 0,
    );
  }

  Matcher failure([String code = 'companion/conflict']) =>
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', code));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-public-lookup-');
    now = 1795219200000;
    serial = 0;
    open();
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  group('lookup targets', () {
    MemoryRow target(
      String source, {
      String room = 'room-one',
      String place = '青桥美术馆',
      String executor = 'phone-installation',
      bool full = false,
    }) {
      say(source, session: room, text: '帮我查今天$place开不开，给我馆方公告。');
      return store.createLookupFromMessage(
        messageId: source,
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: full ? 'full' : 'light',
        hostKey: full ? 'original-host' : null,
        hostSessionId: full ? 'original-host-session' : null,
        executorId: executor,
        lookup: CompanionLookupSpec(
          placeName: place,
          localDate: '2026-11-21',
          zoneId: 'Asia/Shanghai',
          question: '开不开，给我馆方公告',
          deadlineAtMs: now + 120000,
        ),
      );
    }

    void uncertain(MemoryRow task) {
      final request = claim(task)['request_id']! as String;
      store.observeLookupAttempt(request, dispatched: true, httpStatus: 200);
      store.markLookupUncertain(request);
    }

    Map<String, List<MemoryRow>> ledger() => {
      for (final table in [
        'companion_tasks',
        'companion_task_revisions',
        'companion_task_receipts',
        'companion_lookup_attempts',
      ])
        table: [
          for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
        ],
    };

    test('keeps two unfinished host targets across the display window, deadline and restart', () {
      final first = target('old-lookup', full: true);
      final firstId = first['task_id']! as String;
      uncertain(first);
      for (var index = 0; index < 99; index++) {
        now++;
        final source = 'later-reminder-$index';
        say(source, text: '2026-11-22 08:00提醒我处理第$index件事');
        store.createReminderFromMessage(
          messageId: source,
          expectedSourceRev: 1,
          itemNo: 0,
          roomMode: 'light',
          executorId: 'phone-installation',
          reminder: CompanionReminderSpec(
            text: '处理第$index件事',
            localDate: '2026-11-22',
            localTime: '08:00',
            zoneId: 'Asia/Shanghai',
            offsetSeconds: 28800,
            epochMs: DateTime.utc(2026, 11, 22).millisecondsSinceEpoch,
          ),
        );
      }
      now++;
      final second = target('new-lookup', full: true);
      final secondId = second['task_id']! as String;
      uncertain(second);
      final displayed = store.tasks(sourceSessionId: 'room-one');
      expect(displayed, hasLength(100));
      expect(displayed.map((row) => row['task_id']), isNot(contains(firstId)));
      expect(displayed.where((row) => row['kind'] == 'public.lookup').single['task_id'], secondId);
      final before = ledger();
      final changes = database.select('SELECT total_changes() AS n').single['n'];
      expect(
        store.lookupTargets(sourceSessionId: 'room-one').map((row) => row['task_id']),
        unorderedEquals([firstId, secondId]),
      );
      expect(
        store.lookupTargets(sourceSessionId: 'room-one', placeName: '青桥美术馆').map((row) => row['task_id']),
        unorderedEquals([firstId, secondId]),
      );
      expect(database.select('SELECT total_changes() AS n').single['n'], changes);
      expect(ledger(), before);

      now += 120001;
      reopen();
      final reopenedChanges = database.select('SELECT total_changes() AS n').single['n'];
      expect(store.lookupIsCurrent(firstId, 1), isFalse);
      expect(store.lookupIsCurrent(secondId, 1), isFalse);
      expect(
        store.lookupTargets(sourceSessionId: 'room-one').map((row) => row['task_id']),
        unorderedEquals([firstId, secondId]),
      );
      expect(database.select('SELECT total_changes() AS n').single['n'], reopenedChanges);
      expect(ledger(), before);
      for (final id in [firstId, secondId]) {
        final attempt = store.lookupAttempts(id).single;
        expect(attempt['dispatched'], 1);
        expect(attempt['finished_at_ms'], isNull);
        expect(store.lookupTask(id)!['state'], 'unknown');
      }

      final thirdId = target('third-lookup')['task_id'];
      final witnesses = store.lookupTargets(sourceSessionId: 'room-one');
      expect(witnesses, hasLength(2));
      expect(witnesses.map((row) => row['task_id']).toSet(), hasLength(2));
      expect(witnesses.every((row) => {firstId, secondId, thirdId}.contains(row['task_id'])), isTrue);
    });

    test('filters current cancellation and terminal outcomes before limiting lookup targets', () {
      final withdrawn = target('withdrawn', full: true);
      uncertain(withdrawn);
      say('withdraw-command', text: '取消青桥美术馆的查询');
      final stopped = store.cancelLookup(
        taskId: withdrawn['task_id']! as String,
        expectedTaskRev: 1,
        messageId: 'withdraw-command',
        expectedSourceRev: 1,
        itemNo: 0,
      );
      expect(stopped['state'], 'unknown');
      expect(stopped['cancel_requested'], 1);
      expect(store.lookupTask(withdrawn['task_id']! as String, taskRev: 1)!['cancel_requested'], 0);
      final failed = target('failed');
      finish(failed, state: 'failed', reason: 'lookup_no_evidence');
      final partial = target('partial');
      finish(partial, state: 'partial', reason: 'lookup_no_evidence');
      final completed = target('completed');
      search(completed);
      final page = fetch(completed);
      final result = proposal(page);
      answer(completed, page, result);
      finish(completed, result: result);
      expect(store.lookupTargets(sourceSessionId: 'room-one'), isEmpty);

      final queued = target('queued');
      final running = target('running');
      final request = claim(running)['request_id']! as String;
      store.observeLookupAttempt(request, dispatched: true, httpStatus: 200);
      final before = ledger();
      expect(
        store.lookupTargets(sourceSessionId: 'room-one').map((row) => row['task_id']),
        unorderedEquals([queued['task_id'], running['task_id']]),
      );
      expect(
        store.lookupTargets(sourceSessionId: 'room-one').map((row) => row['state']),
        unorderedEquals(['queued', 'running']),
      );
      expect(ledger(), before);
    });

    test('uses the exact original room and place while retaining other executors as candidates', () {
      target('elsewhere', room: 'another-room');
      target('other-place', place: '北岸博物馆');
      target('longer-name', place: '青桥美术馆分馆');
      final local = target('local');
      final foreign = target('other-installation', executor: 'another-phone');
      final before = ledger();
      expect(
        store.lookupTargets(sourceSessionId: 'room-one', placeName: '青桥美术馆').map((row) => row['task_id']),
        unorderedEquals([local['task_id'], foreign['task_id']]),
      );
      expect(
        store.lookupTargets(sourceSessionId: 'room-one', placeName: '青桥美术馆').map((row) => row['executor_id']),
        unorderedEquals(['phone-installation', 'another-phone']),
      );
      for (final text in ['青桥美术馆 ', '', "' OR 1=1 --"]) {
        expect(store.lookupTargets(sourceSessionId: 'room-one', placeName: text), isEmpty);
      }
      expect(store.lookupTargets(sourceSessionId: 'room-one '), isEmpty);
      expect(store.lookupTargets(sourceSessionId: 'missing-room'), isEmpty);
      expect(ledger(), before);
      final exact = target('quoted-name', place: "O'Neil美术馆");
      expect(
        store.lookupTargets(sourceSessionId: 'room-one', placeName: "O'Neil美术馆").single['task_id'],
        exact['task_id'],
      );
    });
  });

  test('accepted lookup keeps the original day, room and command across restart and source deletion', () {
    final task = accept(full: true);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    now += const Duration(days: 1).inMilliseconds;
    reopen();
    expect(create('source', full: true), task);
    final recovered = store.lookupTask(task['task_id'] as String)!;
    expect(recovered['local_date'], '2026-11-21');
    expect(recovered['host_key'], 'original-host');
    expect(recovered['source_session_id'], 'room-one');
    expect(store.tasks(), hasLength(1));
    expect(store.lookupIsCurrent(task['task_id'] as String, 1), isFalse);
  });

  for (final source in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('${source.role}/${source.scope} never accepts a real public lookup', () {
      say('source', role: source.role, scope: source.scope);
      expect(() => create('source'), failure('companion/task-source-invalid'));
      expect(store.tasks(), isEmpty);
    });
  }

  test('one mixed source keeps distinct task items and does not consume its memory event', () {
    say('source');
    final first = create('source');
    final second = create('source', itemNo: 1);
    expect(first['task_id'], isNot(second['task_id']));
    expect(store.messages(), hasLength(1));
    expect(database.select('SELECT * FROM memory_requests'), isEmpty);
    expect(database.select('SELECT * FROM memory_cards'), isEmpty);
    expect(store.nextBatch(forceTail: true, estimateTokens: (text) => text.length)?.sources.single['id'], 'source');
  });

  test('a failed acceptance transaction leaves no task or reusable command claim', () {
    say('source');
    database.execute(
      "CREATE TRIGGER deny_lookup BEFORE INSERT ON companion_task_revisions BEGIN SELECT RAISE(ABORT,'fixture'); END",
    );
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    database.execute('DROP TRIGGER deny_lookup');
    expect(create('source')['state'], 'queued');
  });

  test('a durable claim is readback on repetition and prevents a second handoff after reopening', () {
    final task = accept(full: true);
    final first = claim(task, requestId: 'same-request');
    expect(first['newlyClaimed'], isTrue);
    reopen();
    expect(claim(task, requestId: 'same-request')['newlyClaimed'], isFalse);
    expect(() => claim(task), failure());
    expect(() => claim(task, requestId: 'same-request', input: const {'query': 'different'}), failure());
    expect(store.taskReceipts(task['task_id'] as String), hasLength(1));
    expect(store.lookupAttempts(task['task_id'] as String).single['dispatched'], isNull);
    expect(() => claim(task, executor: 'different-phone'), failure());
  });

  test('unknown host dispatch survives restart and never becomes a free unused attempt', () {
    final task = accept(full: true);
    final request = claim(task)['request_id'] as String;
    store.markLookupUncertain(request);
    reopen();
    final persisted = store.lookupAttempts(task['task_id'] as String).single;
    expect(persisted['finished_at_ms'], isNull);
    expect(persisted['tool_success_units'], isNull);
    expect(persisted['estimated_tool_micro_cny'], isNull);
    expect(store.lookupTask(task['task_id'] as String)!['state'], 'unknown');
    expect(() => claim(task), failure());
    expect(database.select('SELECT * FROM memory_requests'), isEmpty);
  });

  test('known unsent preflight releases a tool slot without pretending an HTTP call happened', () {
    final task = accept();
    for (var i = 0; i < 3; i++) {
      final request = claim(task)['request_id'] as String;
      final receipt = store.finishLookupAttempt(
        request,
        terminal: 'preflight_error',
        dispatched: false,
        complete: false,
      );
      expect(receipt['tool_success_units'], 0);
      expect(receipt['estimated_tool_micro_cny'], 0);
      expect(receipt['http_status'], isNull);
    }
    expect(search(task)['valid_result'], 1);
    expect(store.lookupAttempts(task['task_id'] as String), hasLength(4));
  });

  test('two genuine empty searches consume two slots and retain known zero tool fees', () {
    final task = accept();
    final first = search(task, urls: const []);
    expect(first['valid_result'], 1);
    expect(first['tool_success_units'], 0);
    expect(() => claim(task), failure()); // Same successful input is not retried.
    finishTool(claim(task, input: const {'query': '青桥美术馆 2026-11-21 临时公告'}), const {'results': []});
    expect(() => claim(task, input: const {'query': 'third query'}), failure('companion/lookup-attempt-limit'));
    expect(() => fetch(task), failure());
  });

  test('same-clock attempts retain claim order rather than sorting their random request ids', () {
    final task = accept();
    finishTool(claim(task, requestId: 'z-first'), const {'results': []});
    finishTool(claim(task, requestId: 'a-second', input: const {'query': '青桥美术馆 2026-11-21 临时公告'}), const {
      'results': [],
    });
    reopen();
    expect(store.lookupAttempts(task['task_id'] as String).map((row) => row['request_id']), ['z-first', 'a-second']);
  });

  test('transport-complete HTTP500 is not a valid search and permits one bounded temporary retry', () {
    final task = accept();
    final bad = finishTool(claim(task), const {'error': 'temporary'}, status: 500, terminal: 'http_error');
    expect(bad['complete'], 1);
    expect(bad['valid_result'], 0);
    expect(bad['tool_success_units'], 0);
    expect(search(task)['valid_result'], 1);
    final failedPage = finishTool(
      claim(task, kind: 'fetch', input: const {'url': _url}),
      const {'error': 'temporary'},
      status: 503,
      terminal: 'http_error',
    );
    expect(failedPage['tool_success_units'], 0);
    expect(() => fetch(task), failure()); // The task already used its one retry.
  });

  for (final status in [400, 402, 404]) {
    test('HTTP$status cannot be retried with unchanged input merely by assigning a new request id', () {
      final task = accept();
      finishTool(claim(task), const {'error': 'known failure'}, status: status, terminal: 'http_error');
      expect(() => claim(task), failure());
    });
  }

  test('fetch accepts only actual search URLs and charges no success for a known empty page', () {
    final task = accept();
    search(task);
    expect(() => fetch(task, url: 'https://invented.example/notice'), failure());
    final page = fetch(task, page: const {'content': ''});
    expect(page['complete'], 1);
    expect(page['valid_result'], 0);
    expect(page['tool_success_units'], 0);
    expect(
      () => claim(
        task,
        kind: 'answer',
        input: {
          'fetchRequestIds': [page['request_id']],
        },
      ),
      failure(),
    );
  });

  test('a nonempty original Fetch content needs no invented title', () {
    final task = accept();
    search(task);
    final page = fetch(task, page: const {'content': '2026年11月21日临时闭馆。'});
    expect(page['valid_result'], 1);
    expect(page['tool_success_units'], 1);
    final result = proposal(page);
    answer(task, page, result);
    final stored = finish(task, result: result)['result'] as Map;
    final source = (stored['evidence'] as List).single as Map;
    expect(source['url'], _url);
    expect(source['title'], isNull);
  });

  test('done requires the actual answer, original date and a verbatim quote from its fetched pages', () {
    final task = accept();
    search(task, urls: const [_url, _otherUrl]);
    final page = fetch(task);
    final result = proposal(page);
    expect(() => finish(task, result: result), failure('companion/lookup-invalid-request'));
    answer(task, page, result);
    expect(() => finish(task, result: proposal(page, day: '2026-11-22')), failure('companion/lookup-invalid-request'));
    expect(() => finish(task, result: proposal(page, quote: '今天正常开放')), failure('companion/lookup-invalid-request'));
    final forged = {...result, 'conclusion': '今天开放'};
    expect(() => finish(task, result: forged), failure('companion/lookup-invalid-request'));
    expect(finish(task, result: result)['state'], 'done');
    expect(database.select('SELECT * FROM memory_requests'), isEmpty);
    expect(store.cards(), isEmpty);
  });

  test('task completion purges ordinary bodies and retains sources, evidence, usage and idempotent result', () {
    final task = accept();
    final searched = search(task);
    final page = fetch(task);
    final result = proposal(page);
    answer(task, page, result);
    final completed = finish(task, result: result);
    reopen();
    expect(finish(task, result: result), completed);
    final rows = store.lookupAttempts(task['task_id'] as String);
    expect(rows.every((row) => row['toolResponse'] == null && row['bodyRetained'] == false), isTrue);
    final metadata = rows.singleWhere((row) => row['request_id'] == searched['request_id'])['sourceMetadata'] as List;
    expect((metadata.single as Map)['url'], _url);
    expect((metadata.single as Map)['publishedAt'], '2026-11-20');
    expect(rows.singleWhere((row) => row['kind'] == 'answer')['rawUsage'], {
      'prompt_tokens': 77,
      'completion_tokens': 12,
    });
    expect(
      rows
          .where((row) => row['kind'] != 'answer')
          .fold<int>(0, (sum, row) => sum + (row['estimated_tool_micro_cny'] as int)),
      10000,
    );
    expect(() => claim(task), failure());
  });

  test('provider body and usage received before a lost host finish survive and close through original receipt', () {
    final task = accept(full: true);
    final request = claim(task)['request_id'] as String;
    const raw = <String, Object?>{
      'results': [
        {'url': _url, 'title': '馆方公告'},
      ],
    };
    const firstUsage = <String, Object?>{
      'events': [
        {
          'raw': {'search_count': 1},
        },
      ],
    };
    store.observeLookupAttempt(request, dispatched: true, httpStatus: 200, toolResponse: raw, rawUsage: firstUsage);
    store.markLookupUncertain(request);
    reopen();
    expect(store.lookupAttempts(task['task_id'] as String).single['toolResponse'], raw);
    final recovered = store.finishLookupAttempt(request, terminal: 'complete', dispatched: true, complete: true);
    expect(recovered['valid_result'], 1);
    expect(recovered['rawUsage'], firstUsage);
    expect(recovered['tool_success_units'], 1);
    expect(store.lookupTask(task['task_id'] as String)!['state'], 'running');
    expect(store.lookupAttempts(task['task_id'] as String), hasLength(1));
    expect(fetch(task)['valid_result'], 1);
  });

  test('a cached finish without an actually received Fetch body cannot synthesize evidence or a fee', () {
    final task = accept(full: true);
    search(task);
    final attempt = claim(task, kind: 'fetch', input: const {'url': _url});
    final request = attempt['request_id'] as String;
    store.observeLookupAttempt(request, dispatched: true, httpStatus: 200);
    store.markLookupUncertain(request);
    reopen();
    final recovered = store.finishLookupAttempt(request, terminal: 'complete', dispatched: true, complete: true);
    expect(recovered['valid_result'], 0);
    expect(recovered['tool_success_units'], isNull);
    expect(recovered['toolResponse'], isNull);
    expect(
      () => claim(
        task,
        kind: 'answer',
        input: {
          'fetchRequestIds': [request],
        },
      ),
      failure(),
    );
    expect(() => fetch(task), failure());
  });

  test('original page observation time survives duplicate events and a later host receipt readback', () {
    final task = accept(full: true);
    search(task);
    final attempt = claim(task, kind: 'fetch', input: const {'url': _url});
    final request = attempt['request_id'] as String;
    final fetchedAt = now;
    store.observeLookupAttempt(request, dispatched: true, httpStatus: 200, toolResponse: _page);
    store.markLookupUncertain(request);
    now += 10000;
    store.observeLookupAttempt(request, toolResponse: _page);
    reopen();
    now += 10000;
    final page = store.finishLookupAttempt(request, terminal: 'complete', dispatched: true, complete: true);
    expect(page['finished_at_ms'], now);
    expect(((page['sourceMetadata'] as List).single as Map)['observedAtMs'], fetchedAt);
    final result = proposal(page);
    answer(task, page, result);
    final stored = finish(task, result: result)['result'] as Map;
    expect(((stored['evidence'] as List).single as Map)['fetchedAtMs'], fetchedAt);
    reopen();
    expect(store.lookupTask(task['task_id'] as String)!['result'], stored);
  });

  test('observations only add usage evidence and cannot overwrite already known provider facts', () {
    final task = accept(full: true);
    final request = claim(task)['request_id'] as String;
    const event = <String, Object?>{
      'raw': {'search_count': 1},
    };
    store.observeLookupAttempt(
      request,
      dispatched: true,
      httpStatus: 200,
      rawUsage: const {
        'events': [event],
      },
      toolResponse: const {'results': []},
    );
    store.observeLookupAttempt(
      request,
      rawUsage: const {
        'events': [
          event,
          {
            'raw': {'cache': 'observed'},
          },
        ],
      },
    );
    expect(() => store.observeLookupAttempt(request, dispatched: false), failure());
    expect(() => store.observeLookupAttempt(request, httpStatus: 500), failure());
    expect(
      () => store.observeLookupAttempt(
        request,
        toolResponse: const {
          'results': [
            {'url': _url, 'title': 'new'},
          ],
        },
      ),
      failure(),
    );
    expect(() => store.observeLookupAttempt(request, rawUsage: const {'events': []}), failure());
    final finalRow = store.finishLookupAttempt(
      request,
      terminal: 'complete',
      dispatched: true,
      complete: true,
      rawUsage: const {'vendorReceipt': 'actual-receipt'},
    );
    expect((finalRow['rawUsage'] as Map)['events'], hasLength(2));
    expect((finalRow['rawUsage'] as Map)['vendorReceipt'], 'actual-receipt');
  });

  test('late known receipt after the original deadline adds facts but never enables a new request', () {
    final task = accept(full: true);
    final request = claim(task)['request_id'] as String;
    store.observeLookupAttempt(
      request,
      dispatched: true,
      httpStatus: 200,
      toolResponse: const {
        'results': [
          {'url': _url, 'title': '公告'},
        ],
      },
    );
    store.markLookupUncertain(request);
    now += const Duration(minutes: 3).inMilliseconds;
    reopen();
    final row = store.finishLookupAttempt(request, terminal: 'complete', dispatched: true, complete: true);
    expect(row['tool_success_units'], 1);
    expect(store.lookupIsCurrent(task['task_id'] as String, 1), isFalse);
    expect(() => fetch(task), failure());
  });

  test('cancel belongs to the original room and blocks late bodies without losing old usage', () {
    final task = accept(full: true);
    final attempt = claim(task);
    final request = attempt['request_id'] as String;
    expect(() => cancel(task, session: 'other-room', command: 'cancel-other-room'), failure());
    final stopped = cancel(task);
    expect(stopped['task_rev'], 2);
    expect(stopped['state'], 'unknown');
    store.observeLookupAttempt(
      request,
      dispatched: true,
      httpStatus: 200,
      toolResponse: const {
        'results': [
          {'url': _url, 'title': '公告'},
        ],
      },
    );
    final old = store.finishLookupAttempt(
      request,
      terminal: 'complete',
      dispatched: true,
      complete: true,
      toolResponse: const {
        'results': [
          {'url': _url, 'title': '公告'},
        ],
      },
      rawUsage: const {'observed': 1},
    );
    expect(old['task_rev'], 1);
    expect(old['bodyRetained'], isFalse);
    expect(old['tool_success_units'], 1);
    expect(store.lookupTask(task['task_id'] as String)!['task_rev'], 2);
    expect(store.lookupTask(task['task_id'] as String)!['state'], 'unknown');
    expect(() => finish(task, state: 'failed'), failure());
    expect(() => store.confirmLookupCancellation(task['task_id'] as String, 2, instanceId: 'new-instance'), failure());
    store.confirmLookupCancellation(task['task_id'] as String, 2, instanceId: 'original-instance');
    expect(store.lookupTask(task['task_id'] as String)!['state'], 'cancelled');
    final receipts = store.taskReceipts(task['task_id'] as String);
    expect((receipts.last['detail'] as Map)['instanceId'], 'original-instance');
    expect(receipts.last['task_rev'], 2);
    expect(receipts.where((row) => row['task_rev'] == 1 && row['event_kind'] == 'returned'), hasLength(1));
  });

  test('an old completed host instance never prevents stopping the one still in flight after restart', () {
    final task = accept(full: true);
    search(task);
    final second = claim(task, kind: 'fetch', input: const {'url': _url}, instance: 'second-instance');
    store.observeLookupAttempt(second['request_id'] as String, dispatched: true);
    final stopped = cancel(task);
    final id = stopped['task_id'] as String;
    expect(() => store.confirmLookupCancellation(id, 2), failure());
    store.confirmLookupCancellation(id, 2, instanceId: 'second-instance');
    reopen();
    store.confirmLookupCancellation(id, 2, instanceId: 'second-instance');
    expect(store.lookupTask(id)!['state'], 'cancelled');
    final receipts = store.taskReceipts(id);
    expect(receipts.where((row) => row['step_key'] == 'lookup.stop'), hasLength(1));
    expect((receipts.last['detail'] as Map)['instanceId'], 'second-instance');
    expect(store.lookupAttempts(id).first['tool_success_units'], 1);
  });

  test('a real v11 upgrade preserves reminders, original clocks and receipt history', () {
    say('reminder-source', text: '今天八点提醒我带证件。');
    final reminder = store.createReminderFromMessage(
      messageId: 'reminder-source',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      executorId: 'phone-installation',
      reminder: const CompanionReminderSpec(
        text: '带证件',
        localDate: '2026-11-21',
        localTime: '08:00',
        zoneId: 'Asia/Shanghai',
        offsetSeconds: 28800,
        epochMs: 1795219200000,
      ),
    );
    final oldMessage = store.messages().single;
    restoreOldMemorySchema(database, 11);
    expect(database.select("SELECT name FROM sqlite_schema WHERE name='companion_lookup_attempts'"), isEmpty);
    reopen();
    expect(database.select('PRAGMA user_version').single['user_version'], 16);
    expect(store.task(reminder['task_id'] as String), reminder);
    expect(store.messages().single, oldMessage);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    say('lookup-source');
    expect(create('lookup-source')['kind'], 'public.lookup');
  });

  test('v12 migration failure rolls back all six new agreement columns and retains schema11', () {
    final path = '${directory.path}/failure.sqlite';
    final beforeDatabase = sqlite3.open(path);
    final beforeStore = CompanionMemoryStore(beforeDatabase, nowMilliseconds: () => now);
    restoreOldMemorySchema(beforeDatabase, 11);
    beforeDatabase.execute('CREATE TABLE companion_lookup_attempts (fixture INTEGER)');
    beforeStore.close();
    expect(() => CompanionMemoryStore(sqlite3.open(path), nowMilliseconds: () => now), throwsA(isA<SqliteException>()));
    final failed = sqlite3.open(path);
    try {
      expect(failed.select('PRAGMA user_version').single['user_version'], 11);
      final columns = failed.select('PRAGMA table_info(companion_task_revisions)').map((row) => row['name'] as String);
      expect(columns.any((column) => column.startsWith('lookup_')), isFalse);
      expect(failed.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      failed.close();
    }
  });
}
