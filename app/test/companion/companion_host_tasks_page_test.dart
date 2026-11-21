import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/notify/chat_alerts.dart' show companionHostKey;
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_notes_peer.dart';
import 'companion_test_settle.dart';

const _now = 1795219200000;

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Memory extends CompanionMemoryOwner {
  _Memory(super.store, super.legacy, {super.nowMilliseconds});
  late Future<void> settled;
  @override
  void retainReceipt(Future<void> work) {
    super.retainReceipt(work);
    settled = work;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/companion_reminders');
  late Directory root;
  late NotesPeer peer;
  late _Memory memory;
  var now = _now;
  final hostKey = companionHostKey(HostRef.local);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = _now;
    root = Directory.systemTemp.createTempSync('notes-page-');
    peer = await NotesPeer.open();
    memory = _Memory(
      CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
      CompanionLocal.at(root),
      nowMilliseconds: () => now,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'clock');
      now = _now + 60000;
      return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
    });
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    memory.dispose();
    await peer.close();
    root.deleteSync(recursive: true);
  });

  MemoryRow command() {
    memory.store.submitMessage(
      id: 'original-source',
      sessionId: 'light:original-room',
      text: '请电脑把今天的笔记整理成一页待办，原件别动',
      saidAtUtc: _now,
      offsetMinutes: 480,
      offsetSeconds: 28800,
      zoneId: 'Asia/Shanghai',
    );
    final task = memory.store.createNotesTaskFromMessage(
      messageId: 'original-source',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: hostKey,
      agreement: notesAgreement(),
      directoryLabels: {'source': '/本人选的笔记', 'output': '/本人选的输出'},
    );
    return memory.store.prepareHostTaskOperation(
          taskId: task['task_id']! as String,
          taskRev: 1,
          hostKey: hostKey,
          hostStoreId: 'original-store',
          initialOpportunity: true,
        )!['request']!
        as MemoryRow;
  }

  Future<void> open(WidgetTester tester, String id, {bool connected = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(
            connected ? AsyncData(HostConnection(client: peer.client, isLocal: true)) : const AsyncData(null),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionTasksPage(memory: memory, taskId: id),
        ),
      ),
    );
    // The actual task page registers its read before dispatch. Wait for that
    // production owner future, rather than guessing when HTTP/import finished.
    if (connected) {
      await settleMixed(tester, memory.settled);
    }
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // dart:io keeps an idle loopback connection for 15 s on the fake clock.
    await tester.pump(const Duration(seconds: 16));
  }

  for (final status in ['available', 'missing', 'changed', 'unknown']) {
    testWidgets(
      'F task page keeps an old revision artifact after cancellation and reads its $status result without POST',
      (tester) async {
        final create = command();
        final id = create['taskId']! as String;
        memory.store.submitMessage(
          id: 'cancel-source',
          sessionId: 'light:original-room',
          text: '取消这次笔记整理',
          saidAtUtc: _now + 1,
          offsetMinutes: 480,
        );
        memory.store.cancelNotesTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'cancel-source',
          expectedSourceRev: 1,
          itemNo: 0,
        );
        final snapshot = notesSnapshot(
          create,
          seq: 7,
          rev: 2,
          state: 'cancelled',
          artifacts: [notesArtifact()],
          revisions: [
            {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': notesAgreement()},
            {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': _now + 1, 'agreement': null},
          ],
        );
        peer.respond = (request, _) {
          expect(request.method, 'GET');
          expect(request.uri.queryParameters, {'hostStoreId': 'original-store'});
          if (request.uri.path == '$notesPath/$id') {
            return NotesPeer.json(request, snapshot);
          }
          expect(request.uri.path, '$notesPath/$id/artifacts/file-original');
          return NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'taskId': id,
            'hostExecutionId': 'actual-execution',
            'artifactId': 'file-original',
            'status': status,
            'mediaType': 'text/markdown',
            'content': status == 'available' ? '# 原任务产物\n- 核对材料' : null,
            'reason': status == 'available' ? null : 'observed-$status',
          });
        };
        await open(tester, id);
        try {
          expect(find.text('好，不整理了，已经写好的文件还在。'), findsOneWidget);
          expect(find.textContaining('版本'), findsNothing);
          expect(find.text('笔记在：/本人选的笔记'), findsOneWidget);
          expect(find.text('存到：/本人选的输出'), findsOneWidget);
          expect(find.text('让电脑接着做'), findsNothing);
          await tester.ensureVisible(find.text('看看这页待办'));
          await tester.tap(find.text('看看这页待办'));
          final expected = switch (status) {
            'available' => '# 原任务产物\n- 核对材料',
            'missing' => '这个文件找不到了，我没重新生成。',
            'changed' => '这个文件后来被改过，已经不是我当时写的样子了。',
            _ => '这个文件现在打不开。',
          };
          for (var i = 0; i < 200 && find.text(expected).evaluate().isEmpty; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
            await tester.pump();
          }
          expect(find.text(expected), findsOneWidget);
          expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
          expect(memory.store.hostTask(id)!['state'], 'cancelled');
          expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 7);
          expect((memory.store.hostTask(id)!['snapshot']! as Map)['artifacts'], [notesArtifact()]);
        } finally {
          await close(tester);
        }
      },
    );
  }

  testWidgets('F task page explicitly resends the same persisted command only after an original-store missing read', (
    tester,
  ) async {
    final create = command();
    final id = create['taskId']! as String;
    // Reopen the real database in the persisted-before-POST crash window.
    memory.dispose();
    now += 86400000;
    memory = _Memory(
      CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
      CompanionLocal.at(root),
      nowMilliseconds: () => now,
    );
    peer.respond = (request, body) => request.method == 'GET'
        ? NotesPeer.json(request, {
            'error': {'code': 'companion/task-not-found', 'message': 'missing'},
          }, status: 404)
        : NotesPeer.json(request, notesSnapshot(body!), status: 201);
    await open(tester, id);
    try {
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(memory.store.hostTask(id)!['state'], 'unknown');
      await tester.ensureVisible(find.text('再交给电脑一次'));
      await tester.tap(find.text('再交给电脑一次'));
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      expect(peer.calls.map((call) => call.method), ['GET', 'GET', 'POST']);
      expect(peer.calls.last.body, create);
      expect(memory.store.tasks(), hasLength(1));
      expect(memory.store.hostTaskCommands(id), hasLength(1));
      expect(memory.store.hostTask(id)!['task_rev'], 1);
      expect(((memory.store.hostTask(id)!['agreement']! as Map)['args']! as Map)['localDate'], '2026-11-21');
      expect(find.text('电脑接手了，正在整理。'), findsOneWidget);
    } finally {
      await close(tester);
    }
  });

  for (final state in ['unknown', 'waiting']) {
    testWidgets('F task page reads Host $state without execution and only waiting offers an explicit same-task retry', (
      tester,
    ) async {
      final create = command();
      final id = create['taskId']! as String;
      final snapshot = {
        ...notesSnapshot(create, state: state),
        'waitReason': state == 'waiting' ? 'model_preflight_waiting' : 'publish_uncertain',
      };
      peer.respond = (request, body) {
        if (request.method == 'POST') {
          expect(body, create);
        }
        return NotesPeer.json(request, snapshot);
      };
      await open(tester, id);
      try {
        expect(peer.calls.map((call) => call.method), ['GET']);
        expect(find.text('再交给电脑一次'), findsNothing);
        if (state == 'unknown') {
          expect(find.text('让电脑接着做'), findsNothing);
        } else {
          await tester.ensureVisible(find.text('让电脑接着做'));
          await tester.tap(find.text('让电脑接着做'));
          await settleMixed(tester, memory.settled);
          await tester.pumpAndSettle();
          expect(peer.calls.map((call) => call.method), ['GET', 'GET', 'POST']);
          expect(memory.store.hostTask(id)!['state'], 'waiting');
          expect(memory.store.hostTask(id)!['task_rev'], 1);
          expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 1);
          expect(memory.store.hostTaskCommands(id), hasLength(1));
        }
      } finally {
        await close(tester);
      }
    });
  }

  for (final completed in [false, true]) {
    testWidgets('F task page keeps step and model usage records off the page: completion=$completed', (tester) async {
      final create = command();
      final id = create['taskId']! as String;
      final snapshot = notesSnapshot(
        create,
        state: 'unknown',
        steps: [
          {
            'taskRev': 1,
            'stepKey': 'model',
            'attemptId': 'actual-model-step',
            'state': completed ? 'done' : 'unknown',
            'startedAtMs': _now,
            'finishedAtMs': completed ? _now + 1 : null,
            'reason': completed ? null : 'receipt_unknown',
            'result': {
              'observations': [
                {
                  'type': 'model-finish',
                  'usage': {
                    'input_uncached': 11,
                    'input_cache_read': null,
                    'input_cache_write': null,
                    'output_tokens': 7,
                    'runtime_normalized_usage': [
                      {'inputTokens': 9999, 'outputTokens': 8888},
                    ],
                  },
                },
              ],
              if (completed)
                'completion': {
                  'sourceCount': 2,
                  'itemCount': 1,
                  'inputBudget': {'estimatedTokens': 900},
                  'usage': {
                    'input_uncached': 11,
                    'input_cache_read': null,
                    'input_cache_write': null,
                    'output_tokens': 7,
                    'start_usage': {'input_tokens': 11},
                    'final_usage': {'output_tokens': 7},
                    'runtime_normalized_usage': [
                      {'inputTokens': 9999, 'outputTokens': 8888},
                    ],
                  },
                },
            },
          },
        ],
      );
      peer.respond = (request, _) => NotesPeer.json(request, snapshot);
      await open(tester, id);
      try {
        expect(find.text('电脑那边现在什么情况，我还不太清楚。'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.textContaining('9999'), findsNothing);
        expect(find.textContaining('8888'), findsNothing);
        expect(find.textContaining('用量'), findsNothing);
        expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
      } finally {
        await close(tester);
      }
    });
  }

  for (final operation in ['amend', 'cancel']) {
    testWidgets('F task page $operation saves a new original-room source before the actual immutable operation POST', (
      tester,
    ) async {
      final create = command();
      final id = create['taskId']! as String;
      var snapshot = <String, Object?>{
        ...notesSnapshot(create, state: 'waiting'),
        'waitReason': 'model_preflight_waiting',
      };
      final returned = Completer<void>();
      peer.respond = (request, body) async {
        if (request.method == 'POST') {
          expect(request.uri.path, '$notesPath/$id/$operation');
          final row = memory.store.hostTask(id)!;
          final commands = memory.store.hostTaskCommands(id);
          expect(row['task_rev'], 2);
          expect(commands.last['possible_sent_at_ms'], _now + 60000);
          expect(body!['operationId'], commands.last['operation_id']);
          expect(body['expectedTaskRev'], 1);
          expect(body['taskRev'], 2);
          final raw = memory.store.messages().last;
          expect(raw['session_id'], 'light:original-room');
          expect(raw['said_at_utc'], _now + 60000);
          expect(row['command_message_id'], raw['id']);
          expect(raw['text'], contains(operation == 'cancel' ? '取消《今日待办.md》' : '新清单.md'));
          final changes = operation == 'cancel' ? notesAgreement() : Map<String, Object?>.from(body['changes']! as Map);
          if (operation == 'amend') {
            expect((changes['args']! as Map)['folderRef'], 'bound-source');
            expect((changes['args']! as Map)['outputDirRef'], 'bound-source');
            expect((changes['args']! as Map)['outputName'], '新清单.md');
            expect(changes['deadlineAtMs'], isNull);
          }
          snapshot = notesSnapshot(
            create,
            rev: 2,
            seq: 2,
            state: operation == 'cancel' ? 'cancelled' : 'running',
            agreement: changes,
            revisions: [
              {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': notesAgreement()},
              {'taskRev': 2, 'operation': operation, 'acceptedAtMs': _now + 60000, 'agreement': changes},
            ],
          );
        }
        await NotesPeer.json(request, snapshot);
        if (request.method == 'POST') {
          returned.complete();
        }
      };
      await open(tester, id);
      try {
        if (operation == 'amend') {
          await tester.ensureVisible(find.text('改一下'));
          await tester.tap(find.text('改一下'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextFormField).at(1), '新清单.md');
          await tester.tap(find.widgetWithText(FilledButton, '保存'));
        } else {
          await tester.ensureVisible(find.text('不用整理了'));
          await tester.tap(find.text('不用整理了'));
        }
        await settleMixed(tester, returned.future);
        await settleMixed(tester, memory.settled);
        await tester.pumpAndSettle();
        expect(memory.store.tasks(), hasLength(1));
        expect(memory.store.messages(), hasLength(2));
        final commands = memory.store.hostTaskCommands(id);
        expect(commands, hasLength(2));
        expect(commands.first['request'], {
          for (final entry in create.entries)
            if (entry.key != 'hostStoreId') entry.key: entry.value,
        });
        expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
        expect(
          peer.calls.any((call) => call.uri.path.endsWith('/folders') || call.uri.path.contains('directoryPicker')),
          isFalse,
        );
        expect(memory.store.hostTask(id)!['state'], operation == 'cancel' ? 'cancelled' : 'running');
      } finally {
        await close(tester);
      }
    });
  }

  for (final reason in ['no_matching_inputs', 'output_exists', 'input_file_count_limit']) {
    testWidgets('F task page renders the observed $reason without claiming a file or sending another operation', (
      tester,
    ) async {
      final create = command();
      final id = create['taskId']! as String;
      final snapshot = {
        ...notesSnapshot(create, state: reason == 'no_matching_inputs' ? 'failed' : 'waiting'),
        'waitReason': reason,
      };
      peer.respond = (request, _) => NotesPeer.json(request, snapshot);
      await open(tester, id);
      try {
        final expected = switch (reason) {
          'no_matching_inputs' => '那天这个文件夹里没有改过的笔记，所以没写待办。',
          'output_exists' => '已经有同名文件了，我没覆盖它。改个新文件名就好。',
          _ => '符合的笔记超过 20 份，有点多。换个小点的文件夹，或者分几次来？',
        };
        expect(find.text(expected), findsOneWidget);
        expect(find.text('看看这页待办'), findsNothing);
        expect(peer.calls.map((call) => call.method), ['GET']);
        expect((memory.store.hostTask(id)!['snapshot']! as Map)['artifacts'], isEmpty);
      } finally {
        await close(tester);
      }
    });
  }

  for (final operation in ['amend', 'cancel']) {
    for (final prepared in [false, true]) {
      testWidgets(
        'F task page reopens an offline saved $operation and explicitly resends only that original command: prepared=$prepared',
        (tester) async {
          final create = command();
          final id = create['taskId']! as String;
          var snapshot = <String, Object?>{
            ...notesSnapshot(create, state: 'waiting'),
            'waitReason': 'model_preflight_waiting',
          };
          MemoryRow? expectedCommand;
          peer.respond = (request, body) async {
            if (request.method == 'POST') {
              expect(request.uri.path, '$notesPath/$id/$operation');
              expect(body, expectedCommand);
              final saved = memory.store.hostTaskCommands(id).last;
              expect(saved['task_rev'], 2);
              expect(body!['operationId'], saved['operation_id']);
              final agreement = operation == 'cancel'
                  ? notesAgreement()
                  : Map<String, Object?>.from(body['changes']! as Map);
              snapshot = notesSnapshot(
                create,
                rev: 2,
                seq: 2,
                state: operation == 'cancel' ? 'cancelled' : 'running',
                agreement: agreement,
                revisions: [
                  {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': notesAgreement()},
                  {'taskRev': 2, 'operation': operation, 'acceptedAtMs': _now + 60000, 'agreement': agreement},
                ],
              );
            }
            await NotesPeer.json(request, snapshot);
          };

          // Obtain a real complete rev1 response before the connection goes away.
          await open(tester, id);
          await close(tester);
          expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 1);
          await open(tester, id, connected: false);
          if (operation == 'amend') {
            await tester.ensureVisible(find.text('改一下'));
            await tester.tap(find.text('改一下'));
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextFormField).at(1), '离线修改.md');
            await tester.tap(find.widgetWithText(FilledButton, '保存'));
          } else {
            await tester.ensureVisible(find.text('不用整理了'));
            await tester.tap(find.text('不用整理了'));
          }
          await tester.pumpAndSettle();
          expect(memory.store.hostTask(id)!['task_rev'], 2);
          expect(memory.store.messages(), hasLength(2));
          expect(peer.calls.map((call) => call.method), ['GET']);
          final original = memory.store.hostTaskCommands(id).last;
          expect(original['possible_sent_at_ms'], isNull);
          expectedCommand = {...(original['request']! as Map<String, Object?>), 'hostStoreId': 'original-store'};
          if (prepared) {
            // The real synchronous SDK handoff transaction commits, then this
            // fixture stops before any POST: this is the precise crash boundary.
            expect(
              memory.store.prepareHostTaskOperation(
                taskId: id,
                taskRev: 2,
                hostKey: hostKey,
                hostStoreId: 'original-store',
                initialOpportunity: true,
                replayAfterRead: true,
              )!['request'],
              expectedCommand,
            );
          }
          await close(tester);
          memory.dispose();
          now += const Duration(days: 1).inMilliseconds;
          memory = _Memory(
            CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
            CompanionLocal.at(root),
            nowMilliseconds: () => now,
          );

          await open(tester, id);
          try {
            // Viewing after restart stays GET-only even with a higher local
            // cancellation/amendment. The explicit button submits that command.
            expect(peer.calls.map((call) => call.method), ['GET', 'GET']);
            expect(memory.store.hostTask(id)!['task_rev'], 2);
            expect((memory.store.hostTask(id)!['snapshot']! as Map)['taskRev'], 1);
            final label = operation == 'cancel' ? '再跟电脑说一次不做了' : '再把改动发给电脑';
            expect(find.text('让电脑接着做'), findsNothing);
            await tester.ensureVisible(find.text(label));
            await tester.tap(find.text(label));
            await settleMixed(tester, memory.settled);
            await tester.pumpAndSettle();
            expect(peer.calls.map((call) => call.method), ['GET', 'GET', 'GET', 'POST']);
            expect(peer.calls.last.body, expectedCommand);
            expect(memory.store.hostTask(id)!['state'], operation == 'cancel' ? 'cancelled' : 'running');
            expect(memory.store.hostTask(id)!['task_rev'], 2);
            expect(memory.store.hostTaskCommands(id), hasLength(2));
            expect(memory.store.hostTaskCommands(id).last['operation_id'], original['operation_id']);
            expect(memory.store.messages(), hasLength(2));
            expect(memory.store.tasks(), hasLength(1));
            expect(find.text(label), findsNothing);
            expect(peer.calls.where((call) => call.method == 'POST' && call.uri.path == notesPath), isEmpty);
          } finally {
            await close(tester);
          }
        },
      );
    }
  }
}
