import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

MemoryRow _copy(MemoryRow value) => jsonDecode(jsonEncode(value)) as MemoryRow;

// These SQLite cases use synthetic Host envelopes. The exact difference ranges
// come from the actual pure comparator, not an imitation of its algorithm.
void main() {
  final fixture =
      jsonDecode(File('test/fixtures/companion_compare_draft/comparator-output.json').readAsStringSync()) as MemoryRow;
  final comparison = fixture['comparison']! as MemoryRow;
  late Directory directory;
  late Database database;
  late CompanionMemoryStore store;
  var now = 1795219200000;

  MemoryRow inputs({
    String hostStore = 'original-store',
    String aRef = 'input-A',
    String bRef = 'input-B',
    String aVersion = 'original-version-A',
    String bVersion = 'original-version-B',
  }) => {
    'a': {
      'v': 1,
      'hostStoreId': hostStore,
      'sourceRef': aRef,
      'version': aVersion,
      'displayName': 'A.md',
      'size': utf8.encode(fixture['a']! as String).length,
      'mediaType': 'text/markdown',
    },
    'b': {
      'v': 1,
      'hostStoreId': hostStore,
      'sourceRef': bRef,
      'version': bVersion,
      'displayName': 'B.txt',
      'size': utf8.encode(fixture['b']! as String).length,
      'mediaType': 'text/plain',
    },
  };

  MemoryRow agreement({MemoryRow? selected, bool allowQueue = true, int? deadline}) {
    final value = selected ?? inputs();
    return {
      'args': {
        for (final side in ['a', 'b'])
          side: {
            'sourceRef': (value[side]! as MemoryRow)['sourceRef'],
            'version': (value[side]! as MemoryRow)['version'],
          },
        'maxHighlights': 3,
      },
      'deadlineAtMs': deadline,
      'afterExit': 'continue',
      'allowQueue': allowQueue,
    };
  }

  void open() {
    database = sqlite3.open('${directory.path}/memory.sqlite');
    store = CompanionMemoryStore(database, nowMilliseconds: () => now);
  }

  void reopen() {
    store.close();
    open();
  }

  void say(
    String id, {
    String session = 'light:original-room',
    String role = 'user',
    String scope = 'real',
    String zone = 'Asia/Shanghai',
    int offset = 28800,
  }) {
    store.submitMessage(
      id: id,
      sessionId: session,
      role: role,
      scope: scope,
      text: '这两份是 A 旧稿和 B 新稿，电脑上线后帮我比较，我离开也继续，不修改原件。',
      saidAtUtc: now,
      offsetMinutes: offset ~/ 60,
      zoneId: zone,
      offsetSeconds: offset,
    );
  }

  MemoryRow create(
    String message, {
    MemoryRow? selected,
    MemoryRow? plan,
    String hostKey = 'ssh:original-host',
    int itemNo = 0,
  }) => store.createCompareDraftTaskFromMessage(
    messageId: message,
    expectedSourceRev: 1,
    itemNo: itemNo,
    roomMode: 'light',
    hostKey: hostKey,
    inputs: selected ?? inputs(),
    agreement: plan ?? agreement(selected: selected),
  );

  MemoryRow? prepare(
    String id,
    int revision, {
    String hostStore = 'original-store',
    bool replay = false,
    bool initial = true,
  }) => store.prepareHostTaskOperation(
    taskId: id,
    taskRev: revision,
    hostKey: 'ssh:original-host',
    hostStoreId: hostStore,
    initialOpportunity: initial,
    replayAfterRead: replay,
  );

  MemoryRow report({
    MemoryRow? selected,
    MemoryRow? compared,
    bool advice = true,
    bool identical = false,
    bool complete = true,
    bool changed = false,
    bool published = true,
  }) {
    final chosen = selected ?? inputs();
    final actualComparison = compared ?? comparison;
    final differences = complete && !identical
        ? (jsonDecode(jsonEncode(actualComparison['changes'])) as List<Object?>).take(3).toList()
        : <Object?>[];
    final suggestionStatus = identical
        ? 'not_needed'
        : advice && complete
        ? 'available'
        : 'unavailable';
    final suggestionReason = suggestionStatus != 'unavailable'
        ? null
        : complete
        ? 'model_unavailable'
        : 'comparison_incomplete';
    return {
      'sources': [
        for (final side in ['a', 'b'])
          {
            'side': side,
            for (final key in ['sourceRef', 'version', 'displayName', 'mediaType', 'size'])
              key: (chosen[side]! as MemoryRow)[key],
            'readComplete': complete || side == 'a',
            'verifiedAtPublish': side == 'a' || complete && !changed,
            'reason': side == 'a'
                ? null
                : !complete
                ? 'read_interrupted'
                : changed
                ? 'original_changed'
                : null,
          },
      ],
      'coverage': {
        'aComplete': true,
        'bComplete': complete,
        'comparisonComplete': complete,
        'totalChangeGroups': complete ? (identical ? 0 : actualComparison['totalChanges']) : null,
        'displayedChangeGroups': differences.length,
        'algorithm': complete ? actualComparison['algorithm'] : null,
        'gaps': [
          if (!complete || changed) {'side': 'b', 'reason': changed ? 'original_changed' : 'read_interrupted'},
          if (!complete) {'side': null, 'reason': 'comparison_incomplete'},
          if (suggestionStatus == 'unavailable') {'side': null, 'reason': suggestionReason},
        ],
      },
      'identical': complete ? identical : null,
      'differences': differences,
      'selection': differences.isEmpty
          ? 'none'
          : advice
          ? 'model'
          : 'source_order',
      'suggestions': {
        'status': suggestionStatus,
        'reason': suggestionReason,
        'items': [
          if (advice)
            for (final difference in differences)
              {'differenceId': (difference! as MemoryRow)['id'], 'practice': '可以重练这一处的停顿。'},
        ],
      },
      'published': published,
    };
  }

  MemoryRow snapshot(
    String id, {
    int revision = 1,
    int seq = 1,
    String state = 'running',
    bool original = true,
    Map<int, MemoryRow> reports = const {},
    List<MemoryRow> extraSteps = const [],
  }) {
    final commands = store.hostTaskCommands(id);
    final first = commands.first['request']! as MemoryRow;
    MemoryRow? plan(MemoryRow command) {
      final request = command['request']! as MemoryRow;
      return switch (command['operation']) {
        'create' => {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
        },
        'amend' => Map<String, Object?>.from(request['changes']! as MemoryRow),
        _ => null,
      };
    }

    final revisions = commands
        .where((command) => (command['task_rev']! as int) <= revision && (original || command['operation'] != 'create'))
        .toList();
    final active = revisions.last;
    return {
      'v': 1,
      'hostStoreId': 'original-store',
      'taskId': id,
      'hostExecutionId': 'original-execution',
      'kind': 'host.compare_drafts',
      'taskRev': revision,
      'runnerReceiptSeq': seq,
      'originalCreatePresent': original,
      'origin': original ? first['origin'] : null,
      'hostSessionId': null,
      'state': state,
      'waitReason': original ? null : 'original_create_missing',
      'cancelRequested': active['operation'] == 'cancel',
      'createdAtMs': now,
      'updatedAtMs': now,
      'agreement': revisions.reversed.map(plan).whereType<MemoryRow>().firstOrNull,
      'revisions': [
        for (final command in revisions)
          {
            'taskRev': command['task_rev'],
            'operation': command['operation'],
            'acceptedAtMs': now,
            'agreement': plan(command),
          },
      ],
      'steps': [
        ...extraSteps,
        for (final entry in reports.entries)
          {
            'taskRev': entry.key,
            'stepKey': 'report',
            'attemptId': 'report-${entry.key}',
            'state':
                entry.value['published'] == true &&
                    (entry.value['coverage']! as MemoryRow)['comparisonComplete'] == true &&
                    (entry.value['sources']! as List<Object?>).every(
                      (source) => (source! as MemoryRow)['verifiedAtPublish'] == true,
                    ) &&
                    (entry.value['identical'] == true ||
                        ((entry.value['suggestions']! as MemoryRow)['status'] == 'available' &&
                            ((entry.value['coverage']! as MemoryRow)['gaps']! as List<Object?>).isEmpty))
                ? 'done'
                : 'partial',
            'startedAtMs': now,
            'finishedAtMs': now,
            'reason': null,
            'result': {'completion': entry.value},
          },
      ],
      'artifacts': <Object?>[],
      'approval': null,
      'budget': {'limitMs': 300000, 'spentMs': 120, 'heldMs': 0},
    };
  }

  MemoryRow accept(String id, MemoryRow value) =>
      store.importHostTaskSnapshot(taskId: id, hostKey: 'ssh:original-host', snapshot: value);

  final conflict = throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/conflict'));
  final invalid = throwsA(
    isA<DshRemoteException>().having((error) => error.code, 'code', 'companion/task-invalid-request'),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('companion-compare-draft-');
    now = 1795219200000;
    open();
  });

  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  test('I binds two selected originals without claiming a socket or inventing a file date', () {
    say('source');
    final task = create('source'), id = task['task_id']! as String;
    expect(task['kind'], 'host.compare_drafts');
    expect(task['host_store_id'], 'original-store');
    expect(task['source_zone_id'], 'Asia/Shanghai');
    expect(task['source_offset_seconds'], 28800);
    expect(task['local_date'], isNull);
    expect(task['zone_id'], isNull);
    expect(task['epoch_ms'], isNull);
    expect(task['directory_labels'], {'inputs': inputs()});
    final command = store.hostTaskCommands(id).single;
    expect(command['possible_sent_at_ms'], isNull);
    expect((command['request']! as MemoryRow).containsKey('hostStoreId'), isFalse);
    expect((command['request']! as MemoryRow)['args'], agreement()['args']);
    store.deleteMessage(id: 'source', expectedSourceRev: 1);
    reopen();
    expect(create('source'), task);
    expect(store.hostTaskCommands(id).single, command);
    expect(database.select('PRAGMA user_version').single['user_version'], 16);
    expect(store.hostTaskDirectories(hostKey: 'ssh:original-host'), isEmpty);
  });

  test('I source item retry stays one task while new source or item remains independent', () {
    say('one');
    say('two');
    final first = create('one');
    expect(create('one')['task_id'], first['task_id']);
    expect(create('two')['task_id'], isNot(first['task_id']));
    expect(create('one', itemNo: 1)['task_id'], isNot(first['task_id']));
    expect(() => create('one', selected: inputs(hostStore: 'replacement-store')), conflict);
    expect(() => create('one', selected: inputs(aRef: 'different-input')), conflict);
    expect(store.tasks(), hasLength(3));
  });

  for (final provenance in [(role: 'assistant', scope: 'real'), (role: 'user', scope: 'story')]) {
    test('I ${provenance.role}/${provenance.scope} cannot grant a comparison', () {
      say('source', role: provenance.role, scope: provenance.scope);
      expect(() => create('source'), throwsA(isA<DshRemoteException>()));
      expect(store.tasks(), isEmpty);
    });
  }

  test('I rejects mixed stores, changed versions and extra paths before creating any task', () {
    say('source');
    final mixed = inputs();
    (mixed['b']! as MemoryRow)['hostStoreId'] = 'other-store';
    expect(() => create('source', selected: mixed), invalid);
    expect(
      () => create(
        'source',
        selected: inputs(bVersion: 'other'),
        plan: agreement(),
      ),
      invalid,
    );
    final expanded = agreement();
    (expanded['args']! as MemoryRow)['path'] = '/not-selected/third.md';
    expect(() => create('source', plan: expanded), invalid);
    final large = agreement();
    (large['args']! as MemoryRow)['maxHighlights'] = 4;
    expect(() => create('source', plan: large), invalid);
    final content = inputs();
    (content['a']! as MemoryRow)['content'] = 'An input binding cannot smuggle a whole source';
    expect(() => create('source', selected: content), invalid);
    expect(store.tasks(), isEmpty);
  });

  test('I command insert failure rolls back task revision and store binding together', () {
    say('source');
    database.execute('''CREATE TRIGGER fail_compare BEFORE INSERT ON companion_host_commands
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(() => create('source'), throwsA(isA<SqliteException>()));
    expect(store.tasks(), isEmpty);
    expect(database.select('SELECT * FROM companion_host_tasks'), isEmpty);
    expect(database.select('SELECT * FROM companion_task_revisions'), isEmpty);
  });

  test('I first handoff binds original store before network and restart requires original read before replay', () {
    say('source');
    final id = create('source')['task_id']! as String;
    expect(() => prepare(id, 1, hostStore: 'replacement'), throwsA(isA<DshRemoteException>()));
    expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
    final sent = prepare(id, 1)!;
    expect((sent['request']! as MemoryRow)['hostStoreId'], 'original-store');
    expect(store.hostTask(id)!['state'], 'unknown');
    reopen();
    expect(() => prepare(id, 1), throwsA(isA<DshRemoteException>()));
    expect(prepare(id, 1, replay: true)!['request'], sent['request']);
  });

  test('I offline first dispatch needs original queue permission and deadline does not move on restart', () {
    say('now-only');
    final nowOnly = create('now-only', plan: agreement(allowQueue: false))['task_id']! as String;
    expect(prepare(nowOnly, 1, initial: false), isNull);
    expect(store.hostTask(nowOnly)!['wait_reason'], 'host_initial_opportunity_lost');
    expect(store.hostTaskCommands(nowOnly).single['possible_sent_at_ms'], isNull);
    say('queued');
    final queued = create('queued')['task_id']! as String;
    expect(prepare(queued, 1, initial: false), isNotNull);
    say('due');
    final due = create('due', plan: agreement(deadline: now + 1))['task_id']! as String;
    now += 2;
    reopen();
    expect(prepare(due, 1, initial: false), isNull);
    expect(store.hostTask(due)!['state'], 'failed');
    expect(store.hostTaskCommands(due).single['possible_sent_at_ms'], isNull);
  });

  test('I retained inputs and pending original room survive one hundred unrelated later tasks', () {
    say('original');
    final id = create('original')['task_id']! as String;
    for (var index = 0; index < 100; index++) {
      now++;
      say('other-$index', session: 'full:other-room');
      create('other-$index', hostKey: 'ssh:another-host');
    }
    expect(store.tasks().any((task) => task['task_id'] == id), isFalse);
    expect(store.pendingCompareDraftTasks(hostKey: 'ssh:original-host').single['task_id'], id);
    expect(store.hostTaskInputs(hostKey: 'ssh:original-host'), [inputs()['a'], inputs()['b']]);
    expect(store.hostTaskInputs(hostKey: 'ssh:unknown'), isEmpty);
    expect(store.hostTask(id)!['source_session_id'], 'light:original-room');
  });

  test('I amended input history retains old versions without rebinding to another store or room', () {
    say('source');
    final id = create('source')['task_id']! as String;
    say('wrong-room', session: 'full:another');
    expect(
      () => store.amendCompareDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'wrong-room',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(),
        inputs: inputs(),
      ),
      invalid,
    );
    say('amend', zone: 'America/New_York', offset: -18000);
    final selected = inputs(bRef: 'input-B-new', bVersion: 'new-original-version');
    final amended = store.amendCompareDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(selected: selected),
      inputs: selected,
    );
    expect(amended['task_rev'], 2);
    expect(amended['source_zone_id'], 'America/New_York');
    expect(amended['local_date'], isNull);
    expect(
      store.amendCompareDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'amend',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(selected: selected),
        inputs: selected,
      )['task_rev'],
      2,
    );
    expect(store.hostTaskInputs(hostKey: 'ssh:original-host'), [selected['a'], selected['b'], inputs()['b']]);
    final changedStore = inputs(hostStore: 'replacement', bRef: 'input-B-new', bVersion: 'new-original-version');
    expect(
      () => store.amendCompareDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'amend',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(selected: selected),
        inputs: changedStore,
      ),
      conflict,
    );
    say('another-amend');
    expect(
      () => store.amendCompareDraftTask(
        taskId: id,
        expectedTaskRev: 2,
        messageId: 'another-amend',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(selected: selected),
        inputs: changedStore,
      ),
      conflict,
    );
  });

  test('I amend arriving before create carries the actual kind and only replays immutable original create', () {
    say('source');
    final id = create('source')['task_id']! as String;
    say('amend');
    store.amendCompareDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(allowQueue: false),
      inputs: inputs(),
    );
    final command = prepare(id, 2)!;
    expect((command['request']! as MemoryRow)['kind'], 'host.compare_drafts');
    accept(id, snapshot(id, revision: 2, state: 'waiting', original: false));
    final original = prepare(id, 1, replay: true)!['request']! as MemoryRow;
    expect(original['taskRev'], 1);
    expect(original['allowQueue'], isTrue);
    expect(store.hostTask(id)!['task_rev'], 2);
    expect((store.hostTask(id)!['agreement']! as MemoryRow)['allowQueue'], isFalse);
  });

  test('I imports the actual two-group comparator facts separately from suggestions and persists them', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final receipt = snapshot(id, state: 'done', reports: {1: report()});
    final accepted = accept(id, receipt);
    expect(accepted['state'], 'done');
    expect(accepted['applied_host_receipt_seq'], 1);
    expect((receipt['steps']! as List<Object?>).single, isNotNull);
    final facts = report()['differences']! as List<Object?>;
    expect(facts, hasLength(2));
    expect(((facts.first! as MemoryRow)['a']! as MemoryRow)['paragraphs'], {'from': 1, 'to': 1});
    expect(((facts.last! as MemoryRow)['b']! as MemoryRow)['paragraphs'], {'from': 3, 'to': 3});
    reopen();
    expect(store.hostTask(id)!['snapshot'], receipt);
    expect(store.hostTask(id)!['state'], 'done');
    expect(store.taskReceipts(id), isEmpty);
  });

  test('I identical complete files are done without model advice or a third artifact', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final receipt = snapshot(id, state: 'done', reports: {1: report(identical: true)});
    expect(accept(id, receipt)['state'], 'done');
    expect(receipt['artifacts'], isEmpty);
    expect((report(identical: true)['suggestions']! as MemoryRow)['status'], 'not_needed');
  });

  final rangeFixture =
      jsonDecode(File('test/fixtures/companion_compare_draft/range-cases.json').readAsStringSync()) as MemoryRow;
  for (final entry in (rangeFixture['cases']! as List<Object?>).cast<MemoryRow>()) {
    test('I imports actual comparator ranges for ${entry['name']} without changing their positions', () {
      final actual = entry['comparison']! as MemoryRow;
      final selected = inputs();
      for (final side in const ['a', 'b']) {
        (selected[side]! as MemoryRow)['size'] = (actual[side]! as MemoryRow)['utf8Bytes'];
      }
      say('source');
      final id = create('source', selected: selected)['task_id']! as String;
      prepare(id, 1);
      final result = report(selected: selected, compared: actual, identical: actual['identical']! as bool);
      final received = snapshot(id, state: 'done', reports: {1: result});
      expect(accept(id, received)['state'], 'done');
      expect(result['differences'], actual['changes']);
      reopen();
      expect(store.hostTask(id)!['snapshot'], received);
    });
  }

  for (final condition in ['no-advice', 'changed-B', 'incomplete-B']) {
    test('I $condition remains a partial result and cannot become fully done', () {
      say('source');
      final id = create('source')['task_id']! as String;
      prepare(id, 1);
      final result = report(
        advice: condition != 'no-advice',
        changed: condition == 'changed-B',
        complete: condition != 'incomplete-B',
      );
      final receipt = snapshot(id, state: 'partial', reports: {1: result});
      expect(accept(id, receipt)['state'], 'partial');
      final falseDone = _copy(receipt)
        ..['state'] = 'done'
        ..['runnerReceiptSeq'] = 2;
      expect(() => accept(id, falseDone), invalid);
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
    });
  }

  final corruptions = <String, void Function(MemoryRow)>{
    'replacement-source': (value) =>
        ((value['sources']! as List<Object?>).first! as MemoryRow)['sourceRef'] = 'replacement',
    'reversed-sides': (value) =>
        (value['sources']! as List<Object?>).setAll(0, (value['sources']! as List<Object?>).reversed.toList()),
    'fabricated-suggestion-id': (value) =>
        (((value['suggestions']! as MemoryRow)['items']! as List<Object?>).first! as MemoryRow)['differenceId'] =
            'invented',
    'duplicate-fact-id': (value) {
      final facts = value['differences']! as List<Object?>;
      (facts.last! as MemoryRow)['id'] = (facts.first! as MemoryRow)['id'];
    },
    'invented-third': (value) {
      final facts = value['differences']! as List<Object?>;
      facts.add(_copy(facts.last! as MemoryRow)..['id'] = 'third');
      (value['coverage']! as MemoryRow)['displayedChangeGroups'] = 3;
    },
    'quote-outside-span': (value) {
      final side = ((value['differences']! as List<Object?>).first! as MemoryRow)['a']! as MemoryRow;
      ((side['excerpts']! as List<Object?>).first! as MemoryRow)['to'] = 65537;
    },
    'quote-not-contiguous-length': (value) {
      final side = ((value['differences']! as List<Object?>).first! as MemoryRow)['b']! as MemoryRow;
      ((side['excerpts']! as List<Object?>).first! as MemoryRow)['text'] = '拼接的句子……不是原范围';
    },
    'range-outside-original-size': (value) => ((value['sources']! as List<Object?>).first! as MemoryRow)['size'] = 0,
    'whole-coverage-not-proved': (value) => (value['coverage']! as MemoryRow)['bComplete'] = false,
  };
  for (final entry in corruptions.entries) {
    test('I rejects ${entry.key} without moving the complete snapshot watermark', () {
      say('source');
      final id = create('source')['task_id']! as String;
      prepare(id, 1);
      final initial = snapshot(id);
      accept(id, initial);
      final malformed = report();
      entry.value(malformed);
      expect(() => accept(id, snapshot(id, seq: 2, state: 'done', reports: {1: malformed})), invalid);
      expect(store.hostTask(id)!['snapshot'], initial);
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
    });
  }

  test('I delayed old report stays with its revision while a new agreement remains queued', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    say('amend');
    final selected = inputs(bRef: 'new-B', bVersion: 'new-B-version');
    store.amendCompareDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(selected: selected),
      inputs: selected,
    );
    final old = snapshot(id, state: 'done', reports: {1: report()});
    final received = accept(id, old);
    expect(received['task_rev'], 2);
    expect(received['state'], 'queued');
    expect(received['snapshot'], old);
    expect(received['agreement'], agreement(selected: selected));
    final next = snapshot(id, revision: 2, seq: 2, reports: {1: report()});
    expect(accept(id, next)['state'], 'running');
    final withoutOld = _copy(next)
      ..['runnerReceiptSeq'] = 3
      ..['steps'] = <Object?>[];
    expect(() => accept(id, withoutOld), conflict);
    final changedOld = _copy(next)..['runnerReceiptSeq'] = 3;
    final oldReport =
        (((changedOld['steps']! as List<Object?>).single! as MemoryRow)['result']! as MemoryRow)['completion']!
            as MemoryRow;
    (((oldReport['suggestions']! as MemoryRow)['items']! as List<Object?>).first! as MemoryRow)['practice'] = '改写旧建议';
    expect(() => accept(id, changedOld), conflict);
    expect(accept(id, old)['applied_host_receipt_seq'], 2);
    expect(store.hostTask(id)!['snapshot'], next);
  });

  test('I ordinary unpublished report cannot be rewritten as owner stopped to authorize another attempt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final original = snapshot(id, state: 'partial', reports: {1: report(published: false)});
    ((original['steps']! as List<Object?>).single! as MemoryRow)['reason'] = 'report_not_published';
    accept(id, original);
    final rewritten = _copy(original)
      ..['runnerReceiptSeq'] = 2
      ..['state'] = 'done';
    final attempts = rewritten['steps']! as List<Object?>;
    (attempts.single! as MemoryRow)['reason'] = 'report_owner_stopped';
    final completed = snapshot(id, state: 'done', reports: {1: report()});
    attempts.add(
      _copy((completed['steps']! as List<Object?>).single! as MemoryRow)..['attemptId'] = 'report-recovered',
    );
    expect(() => accept(id, rewritten), conflict);
    reopen();
    expect(store.hostTask(id)!['snapshot'], original);
    expect(store.hostTask(id)!['state'], 'partial');
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
  });

  test('I report persistence failure leaves head and watermark at the prior complete snapshot', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final old = snapshot(id);
    accept(id, old);
    database.execute('''CREATE TRIGGER fail_compare_snapshot BEFORE UPDATE OF snapshot_json ON companion_host_tasks
      BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
    expect(
      () => accept(id, snapshot(id, seq: 2, state: 'done', reports: {1: report()})),
      throwsA(isA<SqliteException>()),
    );
    expect(store.hostTask(id)!['state'], 'running');
    expect(store.hostTask(id)!['snapshot'], old);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);
  });

  test('I retains original unknown usage and cumulative held budget without accepting a second model attempt', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    final usage = <String, Object?>{
      'raw': null,
      'input_tokens': null,
      'output_tokens': null,
      'runtime_normalized_usage': {'outputTokens': 123},
    };
    final model = <String, Object?>{
      'taskRev': 1,
      'stepKey': 'model',
      'attemptId': 'model-once',
      'state': 'unknown',
      'startedAtMs': now,
      'finishedAtMs': now,
      'reason': 'stream_interrupted',
      'result': {
        'completion': {'usage': usage, 'dispatched': null},
      },
    };
    final originalReport = report(advice: false);
    (originalReport['suggestions']! as MemoryRow)
      ..['status'] = 'unknown'
      ..['reason'] = 'stream_interrupted';
    (originalReport['coverage']! as MemoryRow)['gaps'] = [
      {'side': null, 'reason': 'stream_interrupted'},
    ];
    final received = snapshot(id, state: 'partial', reports: {1: originalReport}, extraSteps: [model]);
    received['budget'] = {'limitMs': 300000, 'spentMs': 120, 'heldMs': 60000};
    accept(id, received);
    reopen();
    expect(store.hostTask(id)!['snapshot'], received);
    final twice = _copy(received)..['runnerReceiptSeq'] = 2;
    (twice['steps']! as List<Object?>).add(_copy(model)..['attemptId'] = 'another-model-attempt');
    expect(() => accept(id, twice), invalid);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 1);

    say('amend-after-unknown');
    final selected = inputs(bRef: 'new-original-B', bVersion: 'new-original-version-B');
    store.amendCompareDraftTask(
      taskId: id,
      expectedTaskRev: 1,
      messageId: 'amend-after-unknown',
      expectedSourceRev: 1,
      itemNo: 0,
      agreement: agreement(selected: selected),
      inputs: selected,
    );
    prepare(id, 2);
    final laterReport = report(selected: selected, advice: false);
    (laterReport['suggestions']! as MemoryRow)['reason'] = 'model_attempt_used';
    (laterReport['coverage']! as MemoryRow)['gaps'] = [
      {'side': null, 'reason': 'model_attempt_used'},
    ];
    final next = snapshot(
      id,
      revision: 2,
      seq: 2,
      state: 'partial',
      reports: {1: originalReport, 2: laterReport},
      extraSteps: [model],
    );
    next['budget'] = {'limitMs': 300000, 'spentMs': 240, 'heldMs': 60000};
    expect(accept(id, next)['state'], 'partial');
    final newRevisionRetry = _copy(next)..['runnerReceiptSeq'] = 3;
    (newRevisionRetry['steps']! as List<Object?>).add(
      _copy(model)
        ..['taskRev'] = 2
        ..['attemptId'] = 'new-revision-model-attempt',
    );
    expect(() => accept(id, newRevisionRetry), invalid);
    reopen();
    expect(store.hostTask(id)!['snapshot'], next);
    expect(store.hostTask(id)!['applied_host_receipt_seq'], 2);
  });

  test('I cancellation during an old report stores unpublished facts without reviving the current head', () {
    say('source');
    final id = create('source')['task_id']! as String;
    prepare(id, 1);
    accept(id, snapshot(id));
    say('cancel');
    store.cancelCompareDraftTask(taskId: id, expectedTaskRev: 1, messageId: 'cancel', expectedSourceRev: 1, itemNo: 0);
    prepare(id, 2);
    final oldReport = report(published: false);
    final received = snapshot(id, revision: 2, seq: 2, state: 'cancelled', reports: {1: oldReport});
    expect(accept(id, received)['state'], 'cancelled');
    final persisted = (received['steps']! as List<Object?>).single! as MemoryRow;
    expect(persisted['taskRev'], 1);
    expect(persisted['state'], 'partial');
    expect(((persisted['result']! as MemoryRow)['completion']! as MemoryRow)['published'], isFalse);
    final falseCurrentDone = _copy(received)
      ..['runnerReceiptSeq'] = 3
      ..['state'] = 'done';
    expect(() => accept(id, falseCurrentDone), invalid);
    reopen();
    expect(store.hostTask(id)!['task_rev'], 2);
    expect(store.hostTask(id)!['state'], 'cancelled');
    expect(store.hostTask(id)!['snapshot'], received);
  });

  test('I cancellation before and after possible dispatch keeps the old report and never reopens by amend', () {
    say('unsent');
    final unsent = create('unsent')['task_id']! as String;
    say('cancel-unsent');
    expect(
      store.cancelCompareDraftTask(
        taskId: unsent,
        expectedTaskRev: 1,
        messageId: 'cancel-unsent',
        expectedSourceRev: 1,
        itemNo: 0,
      )['state'],
      'cancelled',
    );
    expect(() => prepare(unsent, 1), conflict);
    expect(prepare(unsent, 2), isNull);
    say('sent');
    final id = create('sent')['task_id']! as String;
    prepare(id, 1);
    accept(id, snapshot(id, state: 'partial', reports: {1: report(advice: false)}));
    say('cancel');
    expect(
      store.cancelCompareDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'cancel',
        expectedSourceRev: 1,
        itemNo: 0,
      )['state'],
      'unknown',
    );
    final cancellation = prepare(id, 2)!;
    expect((cancellation['request']! as MemoryRow)['kind'], 'host.compare_drafts');
    final ended = snapshot(id, revision: 2, seq: 2, state: 'cancelled', reports: {1: report(advice: false)});
    expect(accept(id, ended)['state'], 'cancelled');
    say('reopen');
    expect(
      () => store.amendCompareDraftTask(
        taskId: id,
        expectedTaskRev: 2,
        messageId: 'reopen',
        expectedSourceRev: 1,
        itemNo: 0,
        agreement: agreement(),
        inputs: inputs(),
      ),
      conflict,
    );
    expect(store.hostTask(id)!['snapshot'], ended);
    expect(store.hostTaskInputs(hostKey: 'ssh:original-host'), [inputs()['a'], inputs()['b']]);
  });
}
