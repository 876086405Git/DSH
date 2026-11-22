import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_notes_peer.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const raw = '等家里电脑开了，在“演讲稿”这一层找昨天改的稿子，不用翻别处，我先去布场，19:00以前把能打开的入口留在小屋';

  test('H finite command preserves explicit directory scope formats queue exit and deadline', () {
    expect(parseCompanionFind(raw), {
      'kind': 'host.find_draft',
      'operation': 'create',
      'directory': '演讲稿',
      'day': '昨天',
      'afterExit': 'continue',
      'allowQueue': true,
      'deadlineTime': '19:00',
      'extensions': ['md', 'txt'],
    });
    expect(parseCompanionFind('请电脑在「演讲稿」本层找2026-11-20修改过的文件，只查txt，我离开就停'), {
      'kind': 'host.find_draft',
      'operation': 'create',
      'directory': '演讲稿',
      'day': '2026-11-20',
      'afterExit': 'pause',
      'allowQueue': false,
      'deadlineTime': null,
      'extensions': ['txt'],
    });
    expect(parseCompanionFind(findSpokenExample), {
      'kind': 'host.find_draft',
      'operation': 'create',
      'directory': '演讲稿',
      'day': '昨天',
      'afterExit': 'continue',
      'allowQueue': true,
      'deadlineTime': null,
      'deadlineChoices': ['07:00', '19:00'],
      'extensions': ['md', 'txt'],
    });
    expect(parseCompanionFind('别找了'), {'kind': 'host.find_draft', 'operation': 'cancel'});
  });

  for (final value in ['“$raw”', '不要$raw', '故事台词：$raw']) {
    test('H quoted or negated command is not accepted: $value', () {
      expect(parseCompanionFind(value), isNull);
    });
  }
  for (final value in [
    '请电脑在“演讲稿”找昨天改的稿子，离开后继续',
    '请电脑在“演讲稿”本层找昨天改的稿子',
    '请电脑在“演讲稿”本层找昨天改的稿子，离开后继续，明早七点以前完成',
    '请电脑在“演讲稿”本层找昨天改的稿子，离开后继续，还要翻所有子目录',
  ]) {
    test('H an unparsed scope or condition asks instead of silently broadening: $value', () {
      expect(parseCompanionFind(value)?['operation'], 'clarify');
    });
  }

  test('H yesterday uses the original civil date across DST and deadline stays on the original source day', () async {
    const channel = MethodChannel('dsh/companion_reminders');
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'kind': 'unique',
        'moments': [
          {'epochMs': DateTime.utc(2026, 3, 9, 23).millisecondsSinceEpoch, 'offsetSeconds': -14400},
        ],
      };
    });
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final source = <String, Object?>{
      'said_at_utc': DateTime.utc(2026, 3, 9, 4, 30).millisecondsSinceEpoch,
      'offset_seconds': -14400,
      'zone_id': 'America/New_York',
    };
    final agreement = await companionHostAgreement(source, parseCompanionFind(raw)!, const CompanionReminders());
    expect(agreement, {
      'localDate': '2026-03-08',
      'timeZone': 'America/New_York',
      'deadlineAtMs': DateTime.utc(2026, 3, 9, 23).millisecondsSinceEpoch,
      'afterExit': 'continue',
      'allowQueue': true,
    });
    expect(calls.single.method, 'resolve');
    expect(calls.single.arguments, {'localDate': '2026-03-09', 'localTime': '19:00', 'zoneId': 'America/New_York'});
    expect(
      await companionHostAgreement({...source, 'zone_id': null}, parseCompanionFind(raw)!, const CompanionReminders()),
      isNull,
    );
    expect(calls, hasLength(1));
  });

  group('H actual coordinator', () {
    late Directory directory;
    late CompanionMemoryStore store;
    late CompanionHostTasks coordinator;
    late NotesPeer peer;
    final retained = <Future<void>>[];
    var now = 1795219200000;

    void open() {
      store = CompanionMemoryStore(sqlite3.open('${directory.path}/memory.sqlite'), nowMilliseconds: () => now);
      coordinator = CompanionHostTasks(
        store: store,
        changed: () {},
        retainReceipt: (future) {
          retained.add(future);
          unawaited(future.catchError((Object _) {}));
        },
      );
    }

    MemoryRow create({int? deadline}) {
      store.submitMessage(
        id: 'original-source',
        sessionId: 'light:original-room',
        text: raw,
        saidAtUtc: now,
        offsetMinutes: 480,
        offsetSeconds: 28800,
        zoneId: 'Asia/Shanghai',
      );
      return store.createFindDraftTaskFromMessage(
        messageId: 'original-source',
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        hostKey: 'original-host',
        directoryHostStoreId: 'original-store',
        agreement: {...findAgreement(queue: true), 'deadlineAtMs': deadline},
        directoryLabels: {'source': '/本人选的稿件'},
      );
    }

    Future<MemoryRow> run(MemoryRow row, {bool submit = true}) =>
        coordinator.run(row, client: peer.client, hostKey: 'original-host', submitPending: submit);

    setUp(() async {
      now = 1795219200000;
      directory = await Directory.systemTemp.createTemp('find-coordinator-');
      peer = await NotesPeer.open();
      peer.capability = findCapability;
      retained.clear();
      open();
    });
    tearDown(() async {
      await Future.wait(retained.map((future) => future.catchError((Object _) {})));
      store.close();
      await peer.close();
      await directory.delete(recursive: true);
    });

    test('reopened offline task checks original capability and store before its one first immutable POST', () async {
      final captured = create();
      final id = captured['task_id']! as String;
      expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      store.close();
      now += 86400000;
      open();
      peer.respond = (request, body) {
        if (request.method == 'GET') {
          expect(request.uri.queryParameters, {'hostStoreId': 'original-store'});
          return NotesPeer.json(request, {
            'error': {'code': 'companion/task-not-found', 'message': 'missing'},
          }, status: 404);
        }
        expect(request.uri.path, notesPath);
        expect(store.hostTaskCommands(id).single['possible_sent_at_ms'], now);
        expect(body!['origin'], {
          'sourceSessionId': 'light:original-room',
          'messageId': 'original-source',
          'itemNo': 0,
        });
        expect(body['hostSessionId'], isNull);
        expect(body['args'], findAgreement()['args']);
        return NotesPeer.json(request, notesSnapshot(body), status: 201);
      };
      final result = await run(store.hostTask(id)!);
      expect(result['state'], 'running');
      expect(peer.calls.map((call) => call.method), ['GET', 'GET', 'POST']);
      expect(store.hostTaskCommands(id), hasLength(1));
      expect(store.messages().single['said_at_utc'], 1795219200000);
      expect(store.requests(), isEmpty);
    });

    for (final blocked in ['changed-store', 'deadline', 'unsupported']) {
      test('$blocked retains the original agreement and makes no task POST', () async {
        final row = create(deadline: blocked == 'deadline' ? now + 1000 : null);
        if (blocked == 'changed-store') {
          peer.capability = {...findCapability, 'hostStoreId': 'different-store'};
        } else if (blocked == 'unsupported') {
          peer.capability = notesCapability;
        } else {
          now += 2000;
        }
        if (blocked == 'deadline') {
          await run(row);
        } else {
          await expectLater(run(row), throwsA(isA<DshRemoteException>()));
        }
        expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
        final current = store.hostTask(row['task_id']! as String)!;
        expect(current['host_store_id'], 'original-store');
        expect((current['agreement']! as MemoryRow)['args'], findAgreement()['args']);
        expect(store.hostTaskCommands(row['task_id']! as String).single['possible_sent_at_ms'], isNull);
      });
    }

    test('possible first delivery reopens with an original execution GET and no automatic replay', () async {
      final row = create();
      final id = row['task_id']! as String;
      final request =
          store.prepareHostTaskOperation(
                taskId: id,
                taskRev: 1,
                hostKey: 'original-host',
                hostStoreId: 'original-store',
                initialOpportunity: true,
              )!['request']!
              as MemoryRow;
      store.close();
      open();
      peer.respond = (http, _) =>
          NotesPeer.json(http, {...notesSnapshot(request, state: 'unknown'), 'waitReason': 'scan_interrupted'});
      final result = await run(store.hostTask(id)!, submit: false);
      expect(result['state'], 'unknown');
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(store.hostTaskCommands(id), hasLength(1));
      expect(store.requests(), isEmpty);
    });

    for (final operation in ['amend', 'cancel']) {
      test('a real $operation committed during the original read prevents the stale first POST', () async {
        final row = create();
        final id = row['task_id']! as String;
        final reached = Completer<void>();
        final release = Completer<void>();
        peer.respond = (request, _) async {
          reached.complete();
          await release.future;
          await NotesPeer.json(request, {
            'error': {'code': 'companion/task-not-found', 'message': 'missing'},
          }, status: 404);
        };
        final pending = run(row);
        await reached.future;
        store.submitMessage(
          id: 'new-source',
          sessionId: 'light:original-room',
          text: operation == 'cancel' ? '取消这次找稿' : '改查今天的 txt，离开后继续',
          saidAtUtc: now + 1,
          offsetMinutes: 480,
          offsetSeconds: 28800,
          zoneId: 'Asia/Shanghai',
        );
        if (operation == 'cancel') {
          store.cancelFindDraftTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'new-source',
            expectedSourceRev: 1,
            itemNo: 0,
          );
        } else {
          store.amendFindDraftTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'new-source',
            expectedSourceRev: 1,
            itemNo: 0,
            agreement: findAgreement(queue: true, day: '2026-11-21', extensions: ['txt']),
          );
        }
        release.complete();
        expect((await pending)['task_rev'], 2);
        expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
        expect(store.hostTaskCommands(id), hasLength(2));
        expect(store.hostTaskCommands(id).every((command) => command['possible_sent_at_ms'] == null), isTrue);
      });
    }
  });
}
