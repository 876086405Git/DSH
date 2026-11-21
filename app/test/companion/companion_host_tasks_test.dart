import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_notes_peer.dart';

void main() {
  group('F actual coordinator', () {
    late Directory directory;
    late Database database;
    late CompanionMemoryStore store;
    late CompanionHostTasks tasks;
    late NotesPeer peer;
    late List<Future<void>> retained;
    var now = 1795219200000;

    void open() {
      database = sqlite3.open('${directory.path}/memory.sqlite');
      store = CompanionMemoryStore(database, nowMilliseconds: () => now);
      tasks = CompanionHostTasks(
        store: store,
        changed: () {},
        retainReceipt: (work) {
          retained.add(work);
          unawaited(work.catchError((Object _) {}));
        },
      );
    }

    MemoryRow source(String id) => store.submitMessage(
      id: id,
      sessionId: 'light:original-room',
      text: '请电脑把今天的笔记另存成一页待办，原件别动',
      saidAtUtc: now,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
    MemoryRow create({bool queue = false, String afterExit = 'continue'}) {
      final message = source('create');
      return store.createNotesTaskFromMessage(
        messageId: message['id']! as String,
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        hostKey: 'local:original',
        agreement: notesAgreement(queue: queue, afterExit: afterExit),
        directoryLabels: {'source': '/实际/笔记', 'output': '/实际/笔记'},
      );
    }

    Future<MemoryRow> run(
      MemoryRow row, {
      bool initial = true,
      bool submit = true,
      bool retry = false,
      bool recover = false,
      bool resend = false,
    }) => tasks.run(
      row,
      client: peer.client,
      hostKey: 'local:original',
      initialOpportunity: initial,
      submitPending: submit,
      retryWaiting: retry,
      replayMissing: recover,
      resendPendingCommand: resend,
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('notes-coordinator-');
      now = 1795219200000;
      retained = [];
      peer = await NotesPeer.open();
      open();
    });
    tearDown(() async {
      await Future.wait(retained.map((work) => work.catchError((Object _) {})));
      store.close();
      await peer.close();
      await directory.delete(recursive: true);
    });

    for (final ending in ['truncated-frame', 'normal-eof']) {
      test('F foreground actual HTTP $ending preserves its last snapshot across SQLite reopen', () async {
        peer.capability = {...notesCapability, 'notesForeground': true};
        final row = create(afterExit: 'pause');
        final id = row['task_id']! as String;
        final release = Completer<void>();
        final firstFrame = Completer<void>();
        late MemoryRow current;
        peer.respond = (request, body) async {
          if (request.method == 'GET') {
            await NotesPeer.json(request, current);
          } else if (request.uri.path == notesPath) {
            current = {...notesSnapshot(body!, state: 'waiting'), 'waitReason': 'foreground_required'};
            await NotesPeer.json(request, current, status: 201);
          } else {
            current = {...current, 'runnerReceiptSeq': 2, 'updatedAtMs': now + 2};
            request.response
              ..bufferOutput = false
              ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8')
              ..write('${jsonEncode(current)}\n');
            await request.response.flush();
            await release.future;
            if (ending == 'truncated-frame') request.response.write('{"v":1');
            await request.response.close();
          }
        };
        final accepted = await run(row);
        final capability = (await peer.client.readCompanionTasksCapability())!;
        var observations = 0;
        final owned = tasks.foreground(
          accepted,
          client: peer.client,
          hostKey: 'local:original',
          capability: capability,
          isCurrent: () => true,
          observed: (_) {
            observations++;
            if (observations == 2) firstFrame.complete();
          },
        );
        try {
          await firstFrame.future;
          expect(observations, 2);
          expect(store.hostTask(id)!['state'], 'waiting');
          final commands = jsonEncode(store.hostTaskCommands(id));
          release.complete();
          if (ending == 'truncated-frame') {
            await expectLater(owned.finished, throwsA(isA<DshProtocolException>()));
          } else {
            await owned.finished;
          }
          store.close();
          open();
          expect(store.hostTask(id)!['state'], ending == 'truncated-frame' ? 'unknown' : 'waiting');
          expect(store.hostTask(id)!['snapshot'], current);
          expect(store.hostTask(id)!['applied_host_receipt_seq'], 2);
          expect(jsonEncode(store.hostTaskCommands(id)), commands);
          expect((await run(store.hostTask(id)!, initial: false, submit: false))['state'], 'waiting');
          expect(peer.calls.where((call) => call.uri.path.endsWith('/foreground')), hasLength(1));
          expect(store.hostTaskCommands(id), hasLength(1));
        } finally {
          if (!release.isCompleted) release.complete();
          owned.close();
          await owned.finished.catchError((Object _) {});
        }
      });
    }

    test('F foreground a later same-sequence GET survives old response retirement', () async {
      peer.capability = {...notesCapability, 'notesForeground': true};
      final row = create(afterExit: 'pause');
      final id = row['task_id']! as String;
      final releaseServer = Completer<void>();
      final firstFrame = Completer<void>();
      late MemoryRow current;
      peer.respond = (request, body) async {
        if (request.method == 'GET') {
          await NotesPeer.json(request, current);
        } else if (request.uri.path == notesPath) {
          current = {...notesSnapshot(body!, state: 'waiting'), 'waitReason': 'foreground_required'};
          await NotesPeer.json(request, current, status: 201);
        } else {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8')
            ..write('${jsonEncode(current)}\n');
          await request.response.flush();
          await releaseServer.future;
          try {
            await request.response.close();
          } on Object {
            // The original reader has already retired through its real abort.
          }
        }
      };
      final accepted = await run(row);
      final delayed = DelayedNotesForegroundRetirement(peer.client.connection);
      final client = DshClient(delayed);
      final capability = (await client.readCompanionTasksCapability())!;
      var observations = 0;
      final owned = tasks.foreground(
        accepted,
        client: client,
        hostKey: 'local:original',
        capability: capability,
        isCurrent: () => true,
        observed: (_) {
          observations++;
          if (observations == 2) firstFrame.complete();
        },
      );
      var finished = false;
      unawaited(owned.finished.then<void>((_) => finished = true));
      try {
        await firstFrame.future;
        owned.close();
        expect(store.hostTask(id)!['state'], 'unknown');
        await delayed.retired.future;
        expect(finished, isFalse);
        final read = await run(store.hostTask(id)!, initial: false, submit: false);
        expect(read['state'], 'waiting');
        expect(read['applied_host_receipt_seq'], 1);
        delayed.release.complete();
        await owned.finished;
        expect(store.hostTask(id)!['state'], 'waiting');
        expect(store.hostTask(id)!['wait_reason'], 'foreground_required');
        expect(store.hostTask(id)!['snapshot'], current);
        expect(peer.calls.where((call) => call.uri.path.endsWith('/foreground')), hasLength(1));
      } finally {
        if (!delayed.release.isCompleted) delayed.release.complete();
        if (!releaseServer.isCompleted) releaseServer.complete();
        owned.close();
        await owned.finished.catchError((Object _) {});
        await client.close();
      }
    });

    test('first actual POST sees durable possible handoff and the original immutable command', () async {
      final row = create();
      peer.respond = (request, body) {
        expect(request.uri.path, notesPath);
        expect(store.hostTask(row['task_id']! as String)!['host_store_id'], 'original-store');
        expect(store.hostTaskCommands(row['task_id']! as String).single['possible_sent_at_ms'], now);
        expect(retained, hasLength(1));
        expect(body!['deadlineAtMs'], isNull);
        expect(body['hostSessionId'], isNull);
        expect(jsonEncode(body), isNot(contains('/实际/笔记')));
        return NotesPeer.json(request, notesSnapshot(body), status: 201);
      };
      final result = await run(row);
      expect(result['state'], 'running');
      expect(result['applied_host_receipt_seq'], 1);
      expect(result['directory_labels'], {'source': '/实际/笔记', 'output': '/实际/笔记'});
      expect(peer.calls.map((call) => call.uri.path), ['$notesPath/capabilities', notesPath]);
    });

    test('handoff transaction failure causes zero task POST at the real connection', () async {
      final row = create();
      database.execute('''CREATE TRIGGER reject_handoff BEFORE UPDATE ON companion_host_commands
        BEGIN SELECT RAISE(ABORT,'disk full'); END;''');
      await expectLater(run(row), throwsA(isA<SqliteException>()));
      expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
      expect(store.hostTask(row['task_id']! as String)!['host_store_id'], isNull);
      expect(store.hostTaskCommands(row['task_id']! as String).single['possible_sent_at_ms'], isNull);
    });

    test('lost acceptance response reopens SQLite and only GETs the original task before applying effects', () async {
      final row = create();
      MemoryRow? committed;
      peer.respond = (request, body) async {
        if (request.method == 'POST') {
          committed = notesSnapshot(body!, seq: 7, state: 'done', artifacts: [notesArtifact()]);
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
        } else {
          expect(request.uri.queryParameters, {'hostStoreId': 'original-store'});
          await NotesPeer.json(request, committed!);
        }
      };
      await expectLater(run(row), throwsA(isA<DshException>()));
      final id = row['task_id']! as String;
      expect(store.hostTask(id)!['state'], 'unknown');
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 0);
      store.close();
      now += const Duration(days: 1).inMilliseconds;
      open();
      final result = await run(store.hostTask(id)!, initial: false);
      expect(result['state'], 'done');
      expect(result['applied_host_receipt_seq'], 7);
      expect((result['snapshot']! as Map)['artifacts'], [notesArtifact()]);
      expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
      expect(((result['agreement']! as Map)['args']! as Map)['localDate'], '2026-11-21');
    });

    test('same-store missing observation keeps possible dispatch unknown without recreating the task', () async {
      final row = create();
      final id = row['task_id']! as String;
      final first = store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: 'local:original',
        hostStoreId: 'original-store',
        initialOpportunity: true,
      )!;
      // This represents the persisted-before-dispatch crash window. The real
      // recovery GET must not mistake a missing observation for permission to
      // start the unknown task again.
      peer.respond = (request, body) => request.method == 'GET'
          ? NotesPeer.json(request, {
              'error': {'code': 'companion/task-not-found', 'message': 'missing'},
            }, status: 404)
          : NotesPeer.json(request, notesSnapshot(body!), status: 201);
      final result = await run(store.hostTask(id)!, initial: false);
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(store.hostTaskCommands(id).single['request'], {
        for (final entry in (first['request']! as Map).entries)
          if (entry.key != 'hostStoreId') entry.key as String: entry.value,
      });
      expect(result['task_id'], id);
      expect(result['state'], 'unknown');
      final restored = await run(result, initial: false, submit: false, recover: true);
      expect(peer.calls.map((call) => call.method), ['GET', 'GET', 'POST']);
      expect(peer.calls.last.body, first['request']);
      expect(restored['state'], 'running');
      expect(restored['task_id'], id);
    });

    test(
      'viewing a waiting task is read only while explicit retry reuses its original create and Host sequence',
      () async {
        final row = create();
        MemoryRow? saved;
        MemoryRow? original;
        peer.respond = (request, body) {
          if (request.method == 'POST') {
            original ??= body;
            expect(body, original);
          }
          saved ??= {...notesSnapshot(body!, state: 'waiting'), 'waitReason': 'model_preflight_waiting'};
          return NotesPeer.json(request, saved!);
        };
        final accepted = await run(row);
        final viewed = await run(accepted, initial: false, submit: false);
        expect(viewed['state'], 'waiting');
        expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
        final retried = await run(viewed, initial: false, submit: false, retry: true);
        expect(retried['task_rev'], 1);
        expect(retried['state'], 'waiting');
        expect(retried['applied_host_receipt_seq'], 1);
        expect(store.hostTaskCommands(row['task_id']! as String), hasLength(1));
        expect(peer.calls.where((call) => call.method == 'POST'), hasLength(2));
      },
    );

    for (final operation in ['amend', 'cancel']) {
      test(
        'explicit missing acceptance recovery sends the highest $operation barrier before any original create',
        () async {
          final row = create();
          final id = row['task_id']! as String;
          final original =
              store.prepareHostTaskOperation(
                    taskId: id,
                    taskRev: 1,
                    hostKey: 'local:original',
                    hostStoreId: 'original-store',
                    initialOpportunity: true,
                  )!['request']!
                  as Map<String, Object?>;
          source('change');
          final changedAgreement = {
            ...notesAgreement(),
            'args': {...(notesAgreement()['args']! as Map<String, Object?>), 'outputName': '新约定.md'},
          };
          final changed = operation == 'cancel'
              ? store.cancelNotesTask(
                  taskId: id,
                  expectedTaskRev: 1,
                  messageId: 'change',
                  expectedSourceRev: 1,
                  itemNo: 0,
                )
              : store.amendNotesTask(
                  taskId: id,
                  expectedTaskRev: 1,
                  messageId: 'change',
                  expectedSourceRev: 1,
                  itemNo: 0,
                  agreement: changedAgreement,
                );
          var barrierSeen = false;
          peer.respond = (request, body) async {
            if (request.method == 'GET') {
              await NotesPeer.json(request, {
                'error': {'code': 'companion/task-not-found', 'message': 'missing'},
              }, status: 404);
            } else if (request.uri.path == '$notesPath/$id/$operation') {
              barrierSeen = true;
              expect(body!['taskRev'], 2);
              expect(body['operationId'], store.hostTaskCommands(id).last['operation_id']);
              await NotesPeer.json(
                request,
                notesSnapshot(
                  original,
                  rev: 2,
                  original: false,
                  state: operation == 'cancel' ? 'cancelled' : 'waiting',
                  agreement: changedAgreement,
                  revisions: [
                    {
                      'taskRev': 2,
                      'operation': operation,
                      'acceptedAtMs': now,
                      'agreement': operation == 'cancel' ? null : changedAgreement,
                    },
                  ],
                ),
              );
            } else {
              expect(operation, 'amend');
              expect(barrierSeen, isTrue);
              expect(request.uri.path, notesPath);
              expect(body, original);
              await NotesPeer.json(
                request,
                notesSnapshot(
                  original,
                  rev: 2,
                  seq: 2,
                  agreement: changedAgreement,
                  revisions: [
                    {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': now, 'agreement': notesAgreement()},
                    {'taskRev': 2, 'operation': 'amend', 'acceptedAtMs': now, 'agreement': changedAgreement},
                  ],
                ),
              );
            }
          };
          final result = await run(changed, submit: false, initial: false, recover: true);
          expect(peer.calls.map((call) => call.uri.path), [
            '$notesPath/$id',
            '$notesPath/$id/$operation',
            if (operation == 'amend') notesPath,
          ]);
          expect(result['task_id'], id);
          expect(result['task_rev'], 2);
          expect(result['state'], operation == 'cancel' ? 'cancelled' : 'running');
          expect(store.tasks(), hasLength(1));
        },
      );
    }

    test('changed task library never accepts an original command under a replacement store identity', () async {
      final row = create();
      peer.respond = (request, body) => NotesPeer.json(request, notesSnapshot(body!));
      final initial = await run(row);
      peer.respond = (request, _) => NotesPeer.json(request, {
        'error': {'code': 'companion/task-store-mismatch', 'message': 'different store'},
      }, status: 409);
      await expectLater(run(initial, initial: false), throwsA(isA<DshRemoteException>()));
      expect(store.hostTask(initial['task_id']! as String), initial);
      expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
    });

    test('cancel can overtake an in-flight create and its late original receipt does not revive the task', () async {
      final row = create();
      final id = row['task_id']! as String;
      final received = Completer<void>();
      final release = Completer<void>();
      MemoryRow? original;
      late MemoryRow cancelledSnapshot;
      peer.respond = (request, body) async {
        if (request.uri.path == notesPath) {
          original = body!;
          received.complete();
          await release.future;
          await NotesPeer.json(request, {
            ...cancelledSnapshot,
            'runnerReceiptSeq': 2,
            'originalCreatePresent': true,
            'origin': original!['origin'],
            'hostSessionId': original!['hostSessionId'],
            'revisions': [
              {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': now, 'agreement': notesAgreement()},
              ...(cancelledSnapshot['revisions']! as List),
            ],
          });
        } else if (request.method == 'GET') {
          await NotesPeer.json(request, {
            'error': {'code': 'companion/task-not-found', 'message': 'not accepted yet'},
          }, status: 404);
        } else {
          expect(request.uri.path, '$notesPath/$id/cancel');
          cancelledSnapshot = notesSnapshot(
            original!,
            rev: 2,
            state: 'cancelled',
            original: false,
            revisions: [
              {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': now, 'agreement': null},
            ],
          );
          await NotesPeer.json(request, cancelledSnapshot);
        }
      };
      final pending = run(row);
      await received.future;
      source('cancel');
      final cancelled = store.cancelNotesTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'cancel',
        expectedSourceRev: 1,
        itemNo: 0,
      );
      final stopped = await run(cancelled);
      expect(stopped['state'], 'cancelled');
      release.complete();
      await pending;
      expect(store.hostTask(id)!['state'], 'cancelled');
      expect(store.hostTask(id)!['task_rev'], 2);
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 2);
      expect(peer.calls.where((call) => call.method == 'POST'), hasLength(2));
    });

    test('complete receipt persistence failure is recovered by GET without a second create', () async {
      final row = create();
      MemoryRow? snapshot;
      peer.respond = (request, body) async {
        snapshot ??= notesSnapshot(body!, seq: 7, state: 'done', artifacts: [notesArtifact()]);
        if (request.method == 'POST') {
          database.execute(
            '''CREATE TRIGGER reject_snapshot BEFORE UPDATE OF applied_host_receipt_seq ON companion_host_tasks
            BEGIN SELECT RAISE(ABORT,'disk full'); END;''',
          );
        }
        await NotesPeer.json(request, snapshot!);
      };
      await expectLater(run(row), throwsA(isA<SqliteException>()));
      final id = row['task_id']! as String;
      expect(store.hostTask(id)!['applied_host_receipt_seq'], 0);
      expect(store.hostTask(id)!['snapshot'], isNull);
      database.execute('DROP TRIGGER reject_snapshot');
      store.close();
      open();
      expect((await run(store.hostTask(id)!, initial: false))['state'], 'done');
      expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
    });

    test(
      'explicit saved cancellation is not posted again when the fresh original read already accounts for it',
      () async {
        final row = create();
        late MemoryRow committed;
        late MemoryRow original;
        peer.respond = (request, body) async {
          if (request.method == 'POST' && request.uri.path == notesPath) {
            original = body!;
            committed = notesSnapshot(original);
            await NotesPeer.json(request, committed, status: 201);
          } else if (request.method == 'POST') {
            expect(request.uri.path, '$notesPath/${row['task_id']}/cancel');
            committed = notesSnapshot(
              original,
              rev: 2,
              seq: 2,
              state: 'cancelled',
              revisions: [
                {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': now, 'agreement': notesAgreement()},
                {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': now, 'agreement': notesAgreement()},
              ],
            );
            final socket = await request.response.detachSocket(writeHeaders: false);
            socket.destroy();
          } else {
            await NotesPeer.json(request, committed);
          }
        };
        await run(row);
        store.submitMessage(
          id: 'saved-cancel',
          sessionId: 'light:original-room',
          text: '取消这次笔记整理',
          saidAtUtc: now,
          offsetMinutes: 480,
        );
        final cancel = store.cancelNotesTask(
          taskId: row['task_id']! as String,
          expectedTaskRev: 1,
          messageId: 'saved-cancel',
          expectedSourceRev: 1,
          itemNo: 0,
        );
        await expectLater(run(cancel), throwsA(isA<DshException>()));
        expect(store.hostTask(row['task_id']! as String)!['state'], 'unknown');
        final posts = peer.calls.where((call) => call.method == 'POST').length;
        final current = await run(
          store.hostTask(row['task_id']! as String)!,
          initial: false,
          submit: false,
          resend: true,
        );
        expect(current['state'], 'cancelled');
        expect(current['task_rev'], 2);
        expect(current['applied_host_receipt_seq'], 2);
        expect(peer.calls.where((call) => call.method == 'POST'), hasLength(posts));
        expect(store.hostTaskCommands(row['task_id']! as String), hasLength(2));
      },
    );
  });

  test('F finite commands retain explicit continue pause and queue conditions without an invented deadline', () {
    final plain = parseCompanionNotes('请电脑把今天的笔记另存成一页待办，原件别动。')!;
    expect(plain['deadlineTime'], isNull);
    expect(plain['afterExit'], 'continue');
    expect(plain['allowQueue'], isFalse);
    final paused = parseCompanionNotes('请电脑把今天的笔记另存成一页待办，我离开就停，电脑上线以后再做')!;
    expect(paused['afterExit'], 'pause');
    expect(paused['allowQueue'], isTrue);
    expect(parseCompanionNotes('请电脑把今天的笔记另存成一页待办，偷偷覆盖原件')!['operation'], 'clarify');
    expect(parseCompanionNotes('不用整理笔记了')!['operation'], 'cancel');
    expect(parseCompanionNotes('“请电脑把今天的笔记另存成一页待办”'), isNull);
    expect(parseCompanionNotes('不要请电脑把今天的笔记另存成一页待办'), isNull);
  });
}
