import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/notify/chat_alerts.dart' show companionHostKey;
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/companion/companion_draft_inputs.dart';
import 'package:dsh_app/ui/companion/companion_receipt_inputs.dart';
import 'package:dsh_app/ui/files/table_view.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_notes_peer.dart';
import '../support/companion_compare_peer.dart';
import '../support/companion_receipts_peer.dart';
import 'companion_test_settle.dart';

const _now = 1795219200000;

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Memory extends CompanionMemoryOwner {
  _Memory(super.store, super.legacy, {super.nowMilliseconds});
  late Future<void> settled;
  bool disposed = false;
  @override
  void retainReceipt(Future<void> work) {
    super.retainReceipt(work);
    settled = work;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _PushedPage extends NavigatorObserver {
  Completer<void>? next;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final pending = next;
    if (previousRoute != null && pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }
}

/// Real HTTP remains open until the test releases it. This is a transport
/// peer, not a substitute for the Host's execution/approval owner.
class _ForegroundResponse {
  final release = Completer<void>();
  final ready = Completer<void>();
  late HttpResponse response;

  Future<void> serve(HttpRequest request, MemoryRow snapshot) async {
    response = request.response
      ..bufferOutput = false
      ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
    await add(snapshot);
    ready.complete();
    await release.future;
    try {
      await response.close();
    } on Object {
      // The actual client may already have aborted this response.
    }
  }

  Future<void> add(MemoryRow snapshot) async {
    response.write('${jsonEncode(snapshot)}\n');
    await response.flush();
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
    if (!memory.disposed) memory.dispose();
    await peer.close();
    root.deleteSync(recursive: true);
  });

  MemoryRow command({String afterExit = 'continue'}) {
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
      agreement: notesAgreement(afterExit: afterExit),
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

  MemoryRow findCommand() {
    peer.capability = findCapability;
    memory.store.submitMessage(
      id: 'find-source',
      sessionId: 'light:original-room',
      text: '请电脑在“稿件”本层找昨天改的文件，离开后继续',
      saidAtUtc: _now,
      offsetMinutes: 480,
      offsetSeconds: 28800,
      zoneId: 'Asia/Shanghai',
    );
    final task = memory.store.createFindDraftTaskFromMessage(
      messageId: 'find-source',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: hostKey,
      directoryHostStoreId: 'original-store',
      agreement: findAgreement(),
      directoryLabels: {'source': '/本人选的稿件'},
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

  Future<void> open(
    WidgetTester tester,
    String id, {
    bool connected = true,
    NavigatorObserver? observer,
    DshClient? client,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(
            connected ? AsyncData(HostConnection(client: client ?? peer.client, isLocal: true)) : const AsyncData(null),
          ),
        ],
        child: MaterialApp(
          navigatorObservers: [?observer],
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

  Future<void> visible(WidgetTester tester, String text, {Finder? target}) async {
    final finder = target ?? find.text(text);
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(finder, findsOneWidget, reason: text);
  }

  MemoryRow compareCommand({int? deadline}) {
    peer.capability = compareCapability;
    memory.store.submitMessage(
      id: 'compare-source',
      sessionId: 'light:original-room',
      text: compareSpokenExample,
      saidAtUtc: _now,
      offsetMinutes: 480,
      offsetSeconds: 28800,
      zoneId: 'Asia/Shanghai',
    );
    final task = memory.store.createCompareDraftTaskFromMessage(
      messageId: 'compare-source',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: hostKey,
      agreement: compareAgreement(deadline: deadline),
      inputs: compareInputs(),
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

  testWidgets('F foreground page preserves explicit first delivery of a saved pause agreement', (tester) async {
    final previous = binding.lifecycleState;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    peer.capability = {...notesCapability, 'notesForeground': true};
    memory.store.submitMessage(
      id: 'saved-pause',
      sessionId: 'light:original-room',
      text: '请电脑把今天的笔记整理成待办，我离开就先停',
      saidAtUtc: _now,
      offsetMinutes: 480,
      offsetSeconds: 28800,
      zoneId: 'Asia/Shanghai',
    );
    final saved = memory.store.createNotesTaskFromMessage(
      messageId: 'saved-pause',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: hostKey,
      agreement: notesAgreement(afterExit: 'pause'),
    );
    final id = saved['task_id']! as String;
    MemoryRow? accepted;
    peer.respond = (request, body) async {
      if (request.method == 'POST' && request.uri.path == notesPath) {
        accepted = body;
        await NotesPeer.json(request, {
          ...notesSnapshot(body!, state: 'waiting'),
          'waitReason': 'foreground_required',
        }, status: 201);
      } else {
        await NotesPeer.json(request, {
          'error': {'code': 'companion/task-not-found', 'message': 'Not accepted'},
        }, status: 404);
      }
    };
    try {
      await open(tester, id);
      expect(memory.store.hostTask(id)!['state'], 'queued');
      expect(memory.store.hostTaskCommands(id).single['possible_sent_at_ms'], isNull);
      expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
      await tester.ensureVisible(find.text('现在交给电脑'));
      await tester.tap(find.text('现在交给电脑'));
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      expect(accepted?['taskId'], id);
      expect(accepted?['afterExit'], 'pause');
      expect(accepted?['origin'], {'sourceSessionId': 'light:original-room', 'messageId': 'saved-pause', 'itemNo': 0});
      expect(memory.store.hostTask(id)!['state'], 'waiting');
      expect(memory.store.hostTask(id)!['task_rev'], 1);
      expect(peer.calls.where((call) => call.method == 'POST').map((call) => call.uri.path), [notesPath]);
    } finally {
      await close(tester);
      if (previous != null) binding.handleAppLifecycleStateChanged(previous);
    }
  });

  for (final exit in ['route', 'background', 'host']) {
    testWidgets('F foreground page owns a real held response until $exit and never restarts on return', (tester) async {
      final previous = binding.lifecycleState;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      peer.capability = {...notesCapability, 'notesForeground': true};
      final create = command(afterExit: 'pause');
      final id = create['taskId']! as String;
      final snapshot = <String, Object?>{
        ...notesSnapshot(create, state: 'waiting'),
        'waitReason': 'foreground_required',
      };
      final exchange = _ForegroundResponse();
      final imported = Completer<void>();
      final posted = <({MemoryRow body, MemoryRow prepared})>[];
      void changed() {
        if (posted.isNotEmpty &&
            memory.store.hostTask(id)!['wait_reason'] == 'foreground_required' &&
            !imported.isCompleted) {
          imported.complete();
        }
      }

      memory.addListener(changed);
      peer.respond = (request, body) async {
        if (request.method == 'GET') {
          await NotesPeer.json(request, snapshot);
        } else {
          posted.add((body: body!, prepared: memory.store.hostTask(id)!));
          await exchange.serve(request, snapshot);
        }
      };
      try {
        await open(tester, id);
        await visible(tester, '在这里继续');
        expect(posted, isEmpty);
        expect(find.text('留在这里时，我请电脑继续做。离开后会请它先停，回来再核对进度。'), findsOneWidget);
        await tester.ensureVisible(find.text('在这里继续'));
        await tester.tap(find.text('在这里继续'));
        final foreground = memory.settled;
        var finished = false;
        unawaited(foreground.then<void>((_) => finished = true));
        await settleMixed(tester, imported.future);
        await tester.pumpAndSettle();
        expect(posted.single.body, {
          'v': 1,
          'hostStoreId': 'original-store',
          'hostExecutionId': 'actual-execution',
          'taskRev': 1,
          'sourceSessionId': 'light:original-room',
        });
        expect(posted.single.prepared['state'], 'unknown');
        expect(posted.single.prepared['wait_reason'], 'host_receipt_unknown');
        expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 1);
        expect(memory.store.hostTask(id)!['state'], 'waiting');
        await tester.pump(const Duration(seconds: 30));
        expect(finished, isFalse, reason: 'Approval waiting is not the default 20 second HTTP idle limit');
        final element = tester.element(find.byType(CompanionTasksPage));
        final container = ProviderScope.containerOf(element);
        final navigator = Navigator.of(element);
        if (exit == 'route') {
          unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一页')))));
          await tester.pumpAndSettle();
        } else if (exit == 'background') {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump();
        } else {
          container.read(activeHostProvider.notifier).select(const HostRef.ssh('different-host'));
          await tester.pump();
        }
        await settleMixed(tester, foreground);
        expect(finished, isTrue);
        expect(memory.store.hostTask(id)!['task_rev'], 1);
        expect(memory.store.hostTaskCommands(id), hasLength(1));
        expect(memory.store.hostTask(id)!['cancel_requested'], 0);
        expect(memory.store.hostTask(id)!['state'], 'unknown');
        expect(memory.store.hostTask(id)!['wait_reason'], 'host_receipt_unknown');
        expect(memory.store.hostTask(id)!['snapshot'], snapshot);
        expect(posted, hasLength(1));
        // The same authenticated connection still works after its owned
        // response has closed. There is no physical-stop claim in this read.
        expect(
          await settleMixed(tester, peer.client.readCompanionHostTask(hostStoreId: 'original-store', taskId: id)),
          snapshot,
        );
        if (exit == 'route') {
          navigator.pop();
        } else if (exit == 'background') {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        } else {
          container.read(activeHostProvider.notifier).select(HostRef.local);
        }
        await tester.pumpAndSettle();
        expect(posted, hasLength(1));
        await tester.tap(find.byTooltip('刷新'));
        await settleMixed(tester, memory.settled);
        await visible(tester, '在这里继续');
        expect(posted, hasLength(1));
        expect(memory.store.hostTask(id)!['state'], 'waiting');
      } finally {
        if (!exchange.release.isCompleted) exchange.release.complete();
        memory.removeListener(changed);
        await close(tester);
        if (previous != null) binding.handleAppLifecycleStateChanged(previous);
      }
    });
  }

  for (final disposeOwner in [false, true]) {
    testWidgets(
      'F foreground late original GET retains its receipt but sends nothing after exit, dispose=$disposeOwner',
      (tester) async {
        final previous = binding.lifecycleState;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        peer.capability = {...notesCapability, 'notesForeground': true};
        final create = command(afterExit: 'pause');
        final id = create['taskId']! as String;
        final initial = <String, Object?>{
          ...notesSnapshot(create, state: 'waiting'),
          'waitReason': 'foreground_required',
        };
        final later = <String, Object?>{
          ...notesSnapshot(create, state: 'waiting', seq: 2),
          'waitReason': 'foreground_required',
        };
        final readStarted = Completer<void>();
        final releaseRead = Completer<void>();
        var reads = 0;
        peer.respond = (request, _) async {
          reads++;
          if (reads == 1) {
            await NotesPeer.json(request, initial);
          } else {
            readStarted.complete();
            await releaseRead.future;
            await NotesPeer.json(request, later);
          }
        };
        try {
          await open(tester, id);
          await visible(tester, '在这里继续');
          await tester.ensureVisible(find.text('在这里继续'));
          await tester.tap(find.text('在这里继续'));
          final foreground = memory.settled;
          await settleMixed(tester, readStarted.future);
          if (disposeOwner) {
            await tester.pumpWidget(const SizedBox());
            memory.dispose();
          } else {
            unawaited(
              Navigator.of(tester.element(find.byType(CompanionTasksPage)))
                  .push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一页')))),
            );
            await tester.pumpAndSettle();
          }
          releaseRead.complete();
          await settleMixed(tester, foreground);
          await tester.pump();
          final reopened = CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now);
          try {
            expect(reopened.hostTask(id)!['applied_host_receipt_seq'], 2);
            expect(reopened.hostTask(id)!['snapshot'], later);
            expect(reopened.hostTask(id)!['state'], 'waiting');
            expect(reopened.hostTaskCommands(id), hasLength(1));
          } finally {
            reopened.close();
          }
          expect(reads, 2);
          expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
        } finally {
          if (!releaseRead.isCompleted) releaseRead.complete();
          await close(tester);
          if (previous != null) binding.handleAppLifecycleStateChanged(previous);
        }
      },
    );
  }

  testWidgets('F foreground final snapshot remains completed when its owned response closes', (tester) async {
    final previous = binding.lifecycleState;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    peer.capability = {...notesCapability, 'notesForeground': true};
    final create = command(afterExit: 'pause');
    final id = create['taskId']! as String;
    final waiting = <String, Object?>{...notesSnapshot(create, state: 'waiting'), 'waitReason': 'foreground_required'};
    final exchange = _ForegroundResponse();
    peer.respond = (request, _) =>
        request.method == 'GET' ? NotesPeer.json(request, waiting) : exchange.serve(request, waiting);
    try {
      await open(tester, id);
      await visible(tester, '在这里继续');
      await tester.ensureVisible(find.text('在这里继续'));
      await tester.tap(find.text('在这里继续'));
      final foreground = memory.settled;
      await settleMixed(tester, exchange.ready.future);
      final done = notesSnapshot(
        create,
        seq: 2,
        state: 'done',
        artifacts: [notesArtifact()],
        steps: [
          {
            'taskRev': 1,
            'stepKey': 'writePage',
            'attemptId': 'actual-write',
            'state': 'done',
            'startedAtMs': _now,
            'finishedAtMs': _now + 1,
            'reason': null,
            'result': null,
          },
        ],
      );
      await settleMixed(tester, exchange.add(done));
      await settleMixed(tester, foreground);
      await tester.pumpAndSettle();
      expect(memory.store.hostTask(id)!['state'], 'done');
      expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 2);
      expect(find.text('还没确认电脑现在的进度，先刷新看看。'), findsNothing);
      expect(find.text('在这里继续'), findsNothing);
      expect(find.text('看看这页待办'), findsOneWidget);
      expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
    } finally {
      if (!exchange.release.isCompleted) exchange.release.complete();
      await close(tester);
      if (previous != null) binding.handleAppLifecycleStateChanged(previous);
    }
  });

  for (final completeBadLine in [false, true]) {
    final name = completeBadLine
        ? 'F foreground a later GET remains visible after a complete bad line cancels its subscription'
        : 'F foreground a later GET remains visible after an earlier decoder failure drains';
    testWidgets(name, (tester) async {
      final previous = binding.lifecycleState;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      peer.capability = {...notesCapability, 'notesForeground': true};
      final create = command(afterExit: 'pause');
      final id = create['taskId']! as String;
      final waiting = <String, Object?>{
        ...notesSnapshot(create, state: 'waiting'),
        'waitReason': 'foreground_required',
      };
      final exchange = _ForegroundResponse();
      final delayed = DelayedNotesForegroundRetirement(peer.client.connection, holdBodyCancellation: completeBadLine);
      final client = DshClient(delayed);
      final imported = Completer<void>();
      var posts = 0;
      void changed() {
        if (posts == 1 && memory.store.hostTask(id)!['state'] == 'waiting' && !imported.isCompleted) {
          imported.complete();
        }
      }

      memory.addListener(changed);
      peer.respond = (request, _) {
        if (request.method == 'GET') return NotesPeer.json(request, waiting);
        posts++;
        return exchange.serve(request, waiting);
      };
      Future<void>? settled;
      Object? failure;
      try {
        await open(tester, id, client: client);
        await visible(tester, '在这里继续');
        await tester.ensureVisible(find.text('在这里继续'));
        await tester.tap(find.text('在这里继续'));
        settled = memory.settled.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            failure = error;
          },
        );
        await settleMixed(tester, imported.future);
        // No explicit close: both failures come from the actual decoder. A
        // complete invalid line fails inside await-for while HTTP is still open;
        // a truncated tail fails only after EOF. Hold each real reader's ACK.
        if (completeBadLine) {
          exchange.response.write('{"v":}\n');
          await settleMixed(tester, exchange.response.flush());
        } else {
          exchange.response.write('{"v":1');
          exchange.release.complete();
        }
        await settleMixed(tester, delayed.retired.future);
        expect(memory.store.hostTask(id)!['state'], 'unknown');
        expect(failure, isNull);
        await tester.tap(find.byTooltip('刷新'));
        await settleMixed(tester, memory.settled);
        await visible(tester, '留在这里时，我请电脑继续做。离开后会请它先停，回来再核对进度。');
        expect(memory.store.hostTask(id)!['state'], 'waiting');
        expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 1);
        expect(find.text('还没确认电脑现在的进度，先刷新看看。'), findsNothing);
        delayed.release.complete();
        await settleMixed(tester, settled);
        await tester.pumpAndSettle();
        expect(failure, isA<DshProtocolException>());
        expect(memory.store.hostTask(id)!['state'], 'waiting');
        expect(memory.store.hostTask(id)!['snapshot'], waiting);
        expect(find.text('还没确认电脑现在的进度，先刷新看看。'), findsNothing);
        expect(find.text('留在这里时，我请电脑继续做。离开后会请它先停，回来再核对进度。'), findsOneWidget);
        expect(posts, 1);
      } finally {
        if (!exchange.release.isCompleted) exchange.release.complete();
        if (!delayed.release.isCompleted) delayed.release.complete();
        memory.removeListener(changed);
        await close(tester);
        if (settled != null) await settleMixed(tester, settled);
        await settleMixed(tester, client.close());
        if (previous != null) binding.handleAppLifecycleStateChanged(previous);
      }
    });
  }

  testWidgets('J task page amendment and cancellation persist their own source and preserve selected originals', (
    tester,
  ) async {
    peer.capability = receiptsCapability;
    final inputs = receiptInputs();
    final agreement = receiptAgreement(inputs: inputs);
    memory.store.submitMessage(
      id: 'receipt-original',
      sessionId: 'light:original-room',
      text: receiptSpokenExample,
      saidAtUtc: _now,
      offsetMinutes: 480,
      offsetSeconds: 28800,
      zoneId: 'Asia/Shanghai',
    );
    final task = memory.store.createReceiptsTaskFromMessage(
      messageId: 'receipt-original',
      expectedSourceRev: 1,
      itemNo: 0,
      roomMode: 'light',
      hostKey: hostKey,
      agreement: agreement,
      inputs: inputs,
      outputDirectory: receiptOutput,
    );
    final id = task['task_id']! as String;
    final create =
        memory.store.prepareHostTaskOperation(
              taskId: id,
              taskRev: 1,
              hostKey: hostKey,
              hostStoreId: 'original-store',
              initialOpportunity: true,
            )!['request']!
            as MemoryRow;
    var snapshot = notesSnapshot(create);
    final amendment = Completer<void>();
    final cancellation = Completer<void>();
    final dispatched = <({MemoryRow body, MemoryRow source, MemoryRow command})>[];
    final clocks = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      clocks.add(call);
      if (call.method != 'clock') {
        throw StateError('Unexpected receipt time call ${call.method}');
      }
      now += 60000;
      return {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
    });
    peer.respond = (request, body) async {
      if (request.method == 'GET' && request.uri.path == '$notesPath/$id') {
        await NotesPeer.json(request, snapshot);
      } else if (request.uri.path == '$notesPath/$id/amend') {
        final command = body!;
        dispatched.add((
          body: command,
          source: memory.store.messages().last,
          command: memory.store.hostTaskCommands(id).last,
        ));
        final next = command['changes']! as MemoryRow;
        snapshot = notesSnapshot(
          create,
          rev: 2,
          seq: 2,
          agreement: next,
          revisions: [
            {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': agreement},
            {'taskRev': 2, 'operation': 'amend', 'acceptedAtMs': now, 'agreement': next},
          ],
        );
        await NotesPeer.json(request, snapshot);
        amendment.complete();
      } else if (request.uri.path == '$notesPath/$id/cancel') {
        dispatched.add((
          body: body!,
          source: memory.store.messages().last,
          command: memory.store.hostTaskCommands(id).last,
        ));
        snapshot = {
          ...snapshot,
          'taskRev': 3,
          'runnerReceiptSeq': 3,
          'state': 'cancelled',
          'cancelRequested': true,
          'revisions': [
            ...(snapshot['revisions']! as List<Object?>),
            {'taskRev': 3, 'operation': 'cancel', 'acceptedAtMs': now, 'agreement': snapshot['agreement']},
          ],
        };
        await NotesPeer.json(request, snapshot);
        cancellation.complete();
      } else {
        await NotesPeer.json(request, {
          'error': {'code': 'companion/not-found', 'message': 'No file or model access'},
        }, status: 404);
      }
    };
    await open(tester, id);
    try {
      await tester.ensureVisible(find.text('改一下'));
      await tester.tap(find.text('改一下'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final fields = find.descendant(of: dialog, matching: find.byType(TextFormField));
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.first, '另存差旅表.xlsx');
      await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
      await settleMixed(tester, amendment.future);
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final changed = memory.store.hostTask(id)!;
      expect(changed['task_rev'], 2);
      expect(changed['directory_labels'], {'inputs': inputs, 'outputDirectory': receiptOutput});
      expect((changed['agreement']! as MemoryRow)['args'], {
        ...(agreement['args']! as MemoryRow),
        'outputName': '另存差旅表.xlsx',
      });
      expect(find.text('另存差旅表.xlsx'), findsOneWidget);
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await settleMixed(tester, cancellation.future);
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      expect(memory.store.hostTask(id)!['state'], 'cancelled');
      expect(memory.store.hostTask(id)!['task_rev'], 3);
      expect(memory.store.hostTask(id)!['directory_labels'], {'inputs': inputs, 'outputDirectory': receiptOutput});
      expect(clocks.map((call) => call.method), ['clock', 'clock']);
      expect(dispatched, hasLength(2));
      for (final seen in dispatched) {
        expect(seen.source['session_id'], 'light:original-room');
        expect(seen.source['zone_id'], 'Asia/Shanghai');
        expect(seen.command['possible_sent_at_ms'], isNotNull);
        expect(seen.body['hostStoreId'], 'original-store');
        expect(seen.command['task_id'], id);
        expect(seen.body['operationId'], seen.command['operation_id']);
      }
      expect(dispatched.first.body['expectedTaskRev'], 1);
      expect(dispatched.last.body['expectedTaskRev'], 2);
      expect(dispatched.first.source['text'], contains('另存差旅表.xlsx'));
      expect(dispatched.last.source['text'], '取消这次整理票据，后面没做的先停，已写好的表保留。');
      expect(dispatched.first.source['said_at_utc'], _now + 60000);
      expect(dispatched.last.source['said_at_utc'], _now + 120000);
      expect(memory.store.messages().first['said_at_utc'], _now);
      expect(memory.store.hostTaskCommands(id), hasLength(3));
      expect(peer.calls.where((call) => call.method == 'POST').map((call) => call.uri.path), [
        '$notesPath/$id/amend',
        '$notesPath/$id/cancel',
      ]);
    } finally {
      await close(tester);
    }
    memory.dispose();
    memory = _Memory(
      CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
      CompanionLocal.at(root),
      nowMilliseconds: () => now,
    );
    expect(memory.store.hostTask(id)!['state'], 'cancelled');
    expect(memory.store.hostTaskCommands(id), hasLength(3));
    expect(memory.store.hostTask(id)!['directory_labels'], {'inputs': inputs, 'outputDirectory': receiptOutput});
  });

  for (final result in [
    'scan',
    'mixed',
    'cancelled-locally',
    'write-recovered',
    'read-recovered',
    'changed-artifact',
    'leave-during-download',
    'all-changed',
  ]) {
    testWidgets('J task page consumes the original Host fields and opens only its recorded workbook: $result', (
      tester,
    ) async {
      final mixed = result == 'mixed';
      final recovered = result == 'write-recovered' || result == 'read-recovered';
      final filename = switch (result) {
        'mixed' => 'companion_receipts_mixed_host_wire.json',
        'write-recovered' => 'companion_receipts_owner_stopped_host_wire.json',
        'read-recovered' => 'companion_receipts_read_stopped_host_wire.json',
        'all-changed' => 'companion_receipts_all_changed_host_wire.json',
        _ => 'companion_receipts_host_wire.json',
      };
      final wire = jsonDecode(File('../packages/dsh_client/test/fixtures/$filename').readAsStringSync()) as MemoryRow;
      final request = wire['create']! as MemoryRow;
      final origin = request['origin']! as MemoryRow;
      final id = request['taskId']! as String;
      final snapshot = wire['complete']! as MemoryRow;
      final inputs = (wire['inputs']! as List<Object?>).cast<MemoryRow>();
      final args = request['args']! as MemoryRow;
      // Some fixtures did not record the picker label. Their local display
      // label below is synthetic; all store/ref identities and the received
      // Host snapshot remain unchanged, and the label grants no file access.
      final output =
          wire['folder'] as MemoryRow? ??
          <String, Object?>{
            'v': 1,
            'hostStoreId': request['hostStoreId'],
            'folderRef': args['outputDirRef'],
            'displayPath': '/本人已选的输出目录（测试标签）',
          };
      now = snapshot['createdAtMs']! as int;
      memory.dispose();
      memory = _Memory(
        CompanionMemoryStore(
          sqlite3.open('${root.path}/memory.sqlite'),
          nowMilliseconds: () => now,
          createId: () => id,
        ),
        CompanionLocal.at(root),
        nowMilliseconds: () => now,
      );
      memory.store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        text: receiptSpokenExample.replaceFirst('今晚八点前，', ''),
        saidAtUtc: now,
        offsetMinutes: 480,
        offsetSeconds: 28800,
        zoneId: 'Asia/Shanghai',
      );
      memory.store.createReceiptsTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: hostKey,
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
        },
        inputs: inputs,
        outputDirectory: output,
      );
      expect(
        memory.store.prepareHostTaskOperation(
          taskId: id,
          taskRev: 1,
          hostKey: hostKey,
          hostStoreId: request['hostStoreId']! as String,
          initialOpportunity: true,
        )!['request'],
        request,
      );
      if (result == 'cancelled-locally') {
        memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
        memory.store.submitMessage(
          id: 'receipt-explicit-cancel',
          sessionId: origin['sourceSessionId']! as String,
          text: '取消整理票据。',
          saidAtUtc: now,
          offsetMinutes: 480,
        );
        memory.store.cancelReceiptsTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'receipt-explicit-cancel',
          expectedSourceRev: 1,
          itemNo: 0,
        );
      }
      final artifacts = (snapshot['artifacts']! as List<Object?>).cast<MemoryRow>();
      final artifact = artifacts.isEmpty ? null : artifacts.single;
      final bytes = mixed || recovered || result == 'all-changed'
          ? null
          : File('../packages/dsh_client/test/fixtures/companion_receipts_host_workbook.xlsx').readAsBytesSync();
      final downloadSeen = Completer<void>();
      final releaseDownload = Completer<void>();
      var response = recovered ? wire['before']! as MemoryRow : snapshot;
      peer.respond = (incoming, _) async {
        if (incoming.uri.path == '$notesPath/$id') {
          await NotesPeer.json(incoming, response);
        } else if (bytes != null &&
            artifact != null &&
            incoming.uri.path == '$notesPath/$id/artifacts/${artifact['artifactId']}/content') {
          downloadSeen.complete();
          if (result == 'changed-artifact') {
            await NotesPeer.json(incoming, {
              'error': {'code': 'companion/task-artifact-changed', 'message': 'The recorded workbook changed'},
            }, status: 409);
            return;
          }
          if (result == 'leave-during-download') {
            await releaseDownload.future;
          }
          incoming.response
            ..statusCode = 200
            ..headers.contentType = ContentType.parse(artifact['mediaType']! as String)
            ..contentLength = bytes.length
            ..add(bytes);
          await incoming.response.close();
        } else {
          await NotesPeer.json(incoming, {
            'error': {'code': 'companion/not-found', 'message': 'No ordinary file access'},
          }, status: 404);
        }
      };
      final pushed = _PushedPage();
      await open(tester, id, observer: pushed);
      try {
        if (recovered) {
          expect(memory.store.hostTask(id)!['snapshot'], wire['before']);
          expect(find.text('新表已经写好，还有几项没核实，表里已说明。'), findsNothing);
          expect(find.text('打开 ${artifact!['relativePath']}'), findsNothing);
          response = snapshot;
          await tester.tap(find.byIcon(AppIcons.refresh));
          await settleMixed(tester, memory.settled);
          await tester.pumpAndSettle();
          final before = ((wire['before']! as MemoryRow)['steps']! as List<Object?>).cast<MemoryRow>();
          final after = (snapshot['steps']! as List<Object?>).cast<MemoryRow>().toList();
          for (final step in before) {
            expect(after.singleWhere((row) => row['attemptId'] == step['attemptId']), step);
          }
          expect(after, hasLength(3));
        }
        final stored = memory.store.hostTask(id)!;
        expect(stored['snapshot'], snapshot);
        expect(stored['task_rev'], result == 'cancelled-locally' ? 2 : 1);
        expect(stored['cancel_requested'], result == 'cancelled-locally' ? 1 : 0);
        expect(find.text('新表已经写好，约定的字段都核实了。'), findsNothing);
        expect(find.text('已查到的票据字段'), result == 'cancelled-locally' ? findsNothing : findsOneWidget);
        expect(find.text('此前查到的票据字段'), result == 'cancelled-locally' ? findsOneWidget : findsNothing);
        final lastStep = (snapshot['steps']! as List<Object?>).cast<MemoryRow>().last;
        final completion = (lastStep['result']! as MemoryRow)['completion']! as MemoryRow;
        final report = completion['report']! as MemoryRow;
        final pdfs = (report['sources']! as List<Object?>)
            .cast<MemoryRow>()
            .where((row) => row['textLayerOnly'] == true)
            .length;
        expect(find.text('这里只读取了 PDF 的文字层，图片里的日期或其他字段没有核实。'), findsNWidgets(pdfs));
        if (result == 'all-changed') {
          expect(stored['state'], 'failed');
          expect(artifacts, isEmpty);
          expect(find.text('这四张目前没有可用于成表的已核实字段，没有创建空表。'), findsOneWidget);
          expect(find.text('这四张我都没读到可核实的字段，没有创建空表。'), findsNothing);
          expect(find.text('四份里，0 份有已核实的字段。'), findsOneWidget);
          expect(find.text('新表已经写好，还有几项没核实，表里已说明。'), findsNothing);
          expect(find.text('发布前没能核准还是原来的那份，这行不能当作已核实。'), findsNWidgets(4));
          expect(find.text('日期：未核：发布前没能核准还是原来的那份，这行不能当作已核实。'), findsNWidgets(4));
          final originalRead = (snapshot['steps']! as List<Object?>).cast<MemoryRow>().first;
          final originalReport =
              ((originalRead['result']! as MemoryRow)['completion']! as MemoryRow)['report']! as MemoryRow;
          expect((originalReport['coverage']! as MemoryRow)['rowsWithVerifiedFields'], 4);
          expect((report['coverage']! as MemoryRow)['rowsWithVerifiedFields'], 0);
          expect(
            (report['sources']! as List<Object?>).cast<MemoryRow>().every(
              (source) => source['readComplete'] == true && source['parseComplete'] == true,
            ),
            isTrue,
          );
          expect(find.byType(SheetTable), findsNothing);
        } else if (mixed) {
          expect(find.text('日期：未核：没有可核实的完整日期，或日期有歧义。'), findsOneWidget);
          final lastRow = (report['rows']! as List<Object?>).cast<MemoryRow>().last;
          expect(lastRow['date'], containsPair('state', 'unverified'));
          expect(lastRow['amount'], containsPair('state', 'verified'));
          expect(find.text('金额：${(lastRow['amount']! as MemoryRow)['value']}'), findsOneWidget);
        } else {
          expect(find.text('没有读到可用文字层，图片里的字段还没核实。'), findsOneWidget);
          expect(find.text('日期：未核：没有读到可用文字层，图片里的字段还没核实。'), findsOneWidget);
        }
        expect(find.byType(ExpansionTile), findsNothing);
        expect(find.text('改一下'), result == 'all-changed' ? findsOneWidget : findsNothing);
        for (final input in inputs) {
          expect(find.textContaining(input['sourceRef']! as String), findsNothing);
          expect(find.textContaining(input['version']! as String), findsNothing);
        }
        expect(peer.calls, hasLength(recovered ? 2 : 1));
        if (bytes != null && artifact != null) {
          final button = find.text('打开 ${artifact['relativePath']}');
          await tester.ensureVisible(button);
          // The zero-duration scroll needs a layout frame before a real hit test.
          await tester.pumpAndSettle();
          expect(button.hitTestable(), findsOneWidget);
          pushed.next = Completer<void>();
          await tester.tap(button);
          if (result == 'changed-artifact') {
            await visible(tester, '现在没能打开当时那份表。原来的完成记录仍保留，不会自动重做。');
            expect(find.byType(SheetTable), findsNothing);
            expect(pushed.next!.isCompleted, isFalse);
          } else if (result == 'leave-during-download') {
            await settleMixed(tester, downloadSeen.future);
            await tester.pump();
            final originalButton = find.ancestor(of: button, matching: find.byType(OutlinedButton));
            expect(tester.widget<OutlinedButton>(originalButton).onPressed, isNull);
            pushed.next = null;
            unawaited(
              Navigator.of(tester.element(find.byType(CompanionTasksPage)))
                  .push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('另一个页面')))),
            );
            await tester.pumpAndSettle();
            releaseDownload.complete();
            // The original offstage button becomes enabled only when the
            // actual download continuation has reached its finally block.
            final idle = find.byWidgetPredicate(
              (widget) =>
                  widget is OutlinedButton &&
                  widget.onPressed != null &&
                  widget.child is Text &&
                  (widget.child as Text).data == '打开 ${artifact['relativePath']}',
              skipOffstage: false,
            );
            await visible(tester, 'original download completed after leaving', target: idle);
            expect(find.text('另一个页面'), findsOneWidget);
            expect(find.byType(SheetTable, skipOffstage: false), findsNothing);
            expect(memory.store.hostTask(id)!['cancel_requested'], 0);
          } else {
            await settleMixed(tester, pushed.next!.future);
            await tester.pumpAndSettle();
            final grid = tester.widget<SheetTable>(find.byType(SheetTable)).grid;
            expect(grid.rows, wire['expectedCells']);
            expect(grid.truncated, isFalse);
            expect(grid.columns, 4);
          }
          expect(peer.calls, hasLength(2));
          final download = peer.calls.last;
          expect(download.method, 'GET');
          expect(download.uri.path, '$notesPath/$id/artifacts/${artifact['artifactId']}/content');
          expect(download.uri.queryParameters, {
            'hostStoreId': request['hostStoreId'],
            'hostExecutionId': snapshot['hostExecutionId'],
          });
        }
        expect(peer.calls.every((call) => call.method == 'GET'), isTrue);
        expect(
          peer.calls.where(
            (call) =>
                call.uri.path.contains('/sources/') ||
                call.uri.path.contains('/session/') ||
                call.uri.path.contains('/files/'),
          ),
          isEmpty,
        );
      } finally {
        if (!releaseDownload.isCompleted) {
          releaseDownload.complete();
        }
        await close(tester);
      }
      memory.dispose();
      memory = _Memory(
        CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
        CompanionLocal.at(root),
        nowMilliseconds: () => now,
      );
      expect(memory.store.hostTask(id)!['snapshot'], snapshot);
      expect(memory.store.hostTask(id)!['directory_labels'], {'inputs': inputs, 'outputDirectory': output});
    });
  }

  for (final operation in ['amend', 'cancel']) {
    testWidgets(
      'J task page opens the original workbook discovered after an accepted $operation without completing the new agreement',
      (tester) async {
        final wire = jsonDecode(
          File('../packages/dsh_client/test/fixtures/companion_receipts_late_${operation}_workbook_host_wire.json')
              .readAsStringSync(),
        ) as MemoryRow;
        final create = wire['create']! as MemoryRow;
        final original = wire['original']! as MemoryRow;
        final accepted = wire['accepted']! as MemoryRow;
        final complete = wire['complete']! as MemoryRow;
        final command = wire['operation']! as MemoryRow;
        final origin = create['origin']! as MemoryRow;
        final id = create['taskId']! as String;
        final inputs = (wire['inputs']! as List<Object?>).cast<MemoryRow>();
        final output = <String, Object?>{
          'v': 1, 'hostStoreId': create['hostStoreId'],
          'folderRef': (create['args']! as MemoryRow)['outputDirRef'],
          // This is a local test label, not an invented Host path grant.
          'displayPath': '/本人已选的输出目录（测试标签）',
        };
        final ids = [id, command['operationId']! as String];
        now = original['createdAtMs']! as int;
        memory.dispose();
        memory = _Memory(
          CompanionMemoryStore(
            sqlite3.open('${root.path}/memory.sqlite'),
            nowMilliseconds: () => now,
            createId: () => ids.removeAt(0),
          ),
          CompanionLocal.at(root),
          nowMilliseconds: () => now,
        );
        memory.store.submitMessage(
          id: origin['messageId']! as String,
          sessionId: origin['sourceSessionId']! as String,
          text: receiptSpokenExample.replaceFirst('今晚八点前，', ''),
          saidAtUtc: now,
          offsetMinutes: 480,
        );
        memory.store.createReceiptsTaskFromMessage(
          messageId: origin['messageId']! as String,
          expectedSourceRev: 1,
          itemNo: origin['itemNo']! as int,
          roomMode: 'light',
          hostKey: hostKey,
          agreement: {
            for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: create[key],
          },
          inputs: inputs,
          outputDirectory: output,
        );
        expect(
          memory.store.prepareHostTaskOperation(
            taskId: id,
            taskRev: 1,
            hostKey: hostKey,
            hostStoreId: create['hostStoreId']! as String,
            initialOpportunity: true,
          )!['request'],
          create,
        );
        memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: original);
        now = accepted['updatedAtMs']! as int;
        memory.store.submitMessage(
          id: 'explicit-$operation',
          sessionId: origin['sourceSessionId']! as String,
          text: operation == 'amend' ? '改为新建《新的约定.xlsx》，原来的四张票和文件夹不变。' : '取消整理票据。',
          saidAtUtc: now,
          offsetMinutes: 480,
        );
        if (operation == 'amend') {
          memory.store.amendReceiptsTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'explicit-$operation',
            expectedSourceRev: 1,
            itemNo: 0,
            agreement: command['changes']! as MemoryRow,
            inputs: inputs,
            outputDirectory: output,
          );
        } else {
          memory.store.cancelReceiptsTask(
            taskId: id,
            expectedTaskRev: 1,
            messageId: 'explicit-$operation',
            expectedSourceRev: 1,
            itemNo: 0,
          );
        }
        expect(
          memory.store.prepareHostTaskOperation(
            taskId: id,
            taskRev: 2,
            hostKey: hostKey,
            hostStoreId: create['hostStoreId']! as String,
            initialOpportunity: true,
          )!['request'],
          command,
        );
        memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: accepted);
        expect(ids, isEmpty);
        memory.dispose();
        memory = _Memory(
          CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
          CompanionLocal.at(root),
          nowMilliseconds: () => now,
        );
        expect(memory.store.hostTask(id)!['snapshot'], accepted);
        final artifact = (complete['artifacts']! as List<Object?>).cast<MemoryRow>().single;
        final bytes = base64Decode(wire['workbookBase64']! as String);
        peer.respond = (request, _) async {
          if (request.method == 'GET' && request.uri.path == '$notesPath/$id') {
            await NotesPeer.json(request, complete);
          } else if (request.method == 'GET' &&
              request.uri.path == '$notesPath/$id/artifacts/${artifact['artifactId']}/content') {
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType.parse(artifact['mediaType']! as String)
              ..contentLength = bytes.length
              ..add(bytes);
            await request.response.close();
          } else {
            await NotesPeer.json(request, {
              'error': {'code': 'companion/not-found', 'message': 'No new execution or file fallback'},
            }, status: 404);
          }
        };
        final pushed = _PushedPage();
        await open(tester, id, observer: pushed);
        try {
          final task = memory.store.hostTask(id)!;
          expect(task['snapshot'], complete);
          expect(task['task_rev'], 2);
          expect(task['state'], operation == 'amend' ? 'partial' : 'cancelled');
          expect((complete['steps']! as List<Object?>).cast<MemoryRow>().where((row) => row['taskRev'] == 2), isEmpty);
          expect(artifact['taskRev'], 1);
          expect(find.text('此前查到的票据字段'), findsOneWidget);
          expect(find.text('已查到的票据字段'), findsNothing);
          expect(find.text('新表已经写好，约定的字段都核实了。'), findsNothing);
          expect(find.text('新表已经写好，还有几项没核实，表里已说明。'), findsNothing);
          if (operation == 'amend') {
            expect(find.text('此前约定写出的表已找到；新的约定尚未完成。'), findsOneWidget);
            expect(find.text('新的约定.xlsx'), findsOneWidget);
          } else {
            expect(find.text('后面不再做了。此前已写好的表仍留着。'), findsOneWidget);
          }
          expect(find.text('改一下'), findsNothing);
          expect(find.byType(ExpansionTile), findsNothing);
          final button = find.text('打开 ${artifact['relativePath']}');
          await tester.ensureVisible(button);
          // The zero-duration scroll needs a layout frame before a real hit test.
          await tester.pumpAndSettle();
          expect(button.hitTestable(), findsOneWidget);
          pushed.next = Completer<void>();
          await tester.tap(button);
          await settleMixed(tester, pushed.next!.future);
          await tester.pumpAndSettle();
          expect(tester.widget<SheetTable>(find.byType(SheetTable)).grid.rows, wire['expectedCells']);
          expect(memory.store.hostTask(id)!['snapshot'], complete);
          expect(peer.calls.map((call) => call.method), ['GET', 'GET']);
          expect(peer.calls.last.uri.path, '$notesPath/$id/artifacts/${artifact['artifactId']}/content');
          expect(peer.calls.last.uri.queryParameters, {
            'hostStoreId': create['hostStoreId'],
            'hostExecutionId': complete['hostExecutionId'],
          });
          expect(memory.store.hostTaskCommands(id), hasLength(2));
        } finally {
          await close(tester);
        }
      },
    );
  }

  for (final scenario in ['new-version-same-name', 'other-directory-same-name', 'I-small-text-only']) {
    testWidgets('J retained input choices do not guess identity or broaden I draft limits: $scenario', (tester) async {
      final draft = scenario == 'I-small-text-only';
      for (var selection = 0; selection < (draft ? 1 : 2); selection++) {
        final inputs = receiptInputs();
        inputs[0] = {
          ...inputs[0],
          'sourceRef': scenario == 'other-directory-same-name'
              ? 'folder-$selection-input'
              : 'receipt-version-$selection',
          'version': 'actual-selected-version-$selection',
          if (draft) 'size': 65537,
        };
        // Controlled original binding metadata, persisted through the public
        // task API. This test covers SQLite→picker; the Page suite separately
        // exercises actual directory/input HTTP binding before acceptance.
        memory.store.submitMessage(
          id: 'saved-receipt-$selection',
          sessionId: 'light:previous-room',
          text: receiptSpokenExample,
          saidAtUtc: now,
          offsetMinutes: 480,
          zoneId: 'Asia/Shanghai',
          offsetSeconds: 28800,
        );
        memory.store.createReceiptsTaskFromMessage(
          messageId: 'saved-receipt-$selection',
          expectedSourceRev: 1,
          itemNo: 0,
          roomMode: 'light',
          hostKey: hostKey,
          inputs: inputs,
          outputDirectory: receiptOutput,
          agreement: receiptAgreement(inputs: inputs),
        );
      }
      final before = memory.store.hostTaskInputs(hostKey: hostKey);
      Future<Object?>? selection;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  selection = draft
                      ? chooseCompanionDraftInputs(
                          context,
                          store: memory.store,
                          hostKey: hostKey,
                          client: null,
                          capability: null,
                          isCurrent: () => true,
                        )
                      : chooseCompanionReceiptInputs(
                          context,
                          store: memory.store,
                          hostKey: hostKey,
                          client: null,
                          capability: null,
                          isCurrent: () => true,
                        );
                },
                child: const Text('选择保存的原件'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择保存的原件'));
      await tester.pumpAndSettle();
      if (draft) {
        expect(find.text('交通.txt'), findsNothing);
        expect(find.text('车票.pdf'), findsNothing);
        expect(find.text('扫描件.pdf'), findsNothing);
        expect(find.text('住宿.md'), findsOneWidget);
      } else {
        expect(find.text('这个名字对应不止一份已选稿件。请连上原来的电脑重新选。'), findsOneWidget);
        final choice = find.ancestor(of: find.text('交通.txt'), matching: find.byType(SimpleDialogOption));
        expect(tester.widget<SimpleDialogOption>(choice).onPressed, isNull);
        await tester.tap(find.text('交通.txt'));
        await tester.pump();
        expect(find.text('选之前选过的第 1 份票据'), findsOneWidget);
      }
      await tester.tap(find.text('取消'));
      expect(await settleMixed(tester, selection!), isNull);
      expect(memory.store.hostTaskInputs(hostKey: hostKey), before);
      expect(peer.calls, isEmpty);
      expect(memory.store.tasks(), hasLength(draft ? 1 : 2));
      await close(tester);
    });
  }

  for (final ambiguity in ['new-version-same-name', 'other-directory-same-name']) {
    testWidgets('I offline picker does not guess among persisted original inputs: $ambiguity', (tester) async {
      peer.capability = compareCapability;
      var aBindings = 0;
      peer.respond = (request, body) async {
        if (request.uri.path == '$notesPath/folders') {
          await NotesPeer.json(request, {
            'v': 1,
            'hostStoreId': 'original-store',
            'folderRef': body!['path'] == '/原稿目录' ? 'original-folder' : 'another-folder',
            'displayPath': body['path'],
          });
        } else if (request.uri.path == '$notesPath/inputs') {
          final side = body!['name'] == 'A.md' ? 'a' : 'b';
          final input = compareInputs()[side]! as MemoryRow;
          await NotesPeer.json(
            request,
            side == 'a'
                ? {
                    ...input,
                    'sourceRef': 'chosen-A-${aBindings++}',
                    'version': '${body['folderRef']}-version-$aBindings',
                  }
                : input,
          );
        } else {
          await NotesPeer.json(request, {
            'error': {'code': 'companion/not-found', 'message': 'No comparison route'},
          }, status: 404);
        }
      };
      await tester.runAsync(() async {
        final capability = (await peer.client.readCompanionTasksCapability())!;
        MemoryRow? retainedB;
        for (var selection = 0; selection < 2; selection++) {
          final folder = await peer.client.bindCompanionNotesDirectory(
            capability,
            selection == 1 && ambiguity == 'other-directory-same-name' ? '/另一处稿件' : '/原稿目录',
          );
          final inputs = <String, Object?>{};
          for (final side in ['a', 'b']) {
            if (side == 'b' && retainedB != null) {
              // The person retains the exact previously selected B; this is
              // not a second bind falsely returning the same random input ID.
              inputs[side] = retainedB;
            } else {
              final bound = await peer.client.bindCompanionDraftInput(
                capability,
                folderRef: folder['folderRef']! as String,
                name: side == 'a' ? 'A.md' : 'B.txt',
              );
              inputs[side] = bound;
              if (side == 'b') {
                retainedB = bound;
              }
            }
          }
          memory.store.submitMessage(
            id: 'selection-$selection',
            sessionId: 'light:previous-room',
            text: '选择这两份稿件，电脑上线后继续对照，原文件别动。',
            saidAtUtc: now,
            offsetMinutes: 480,
            offsetSeconds: 28800,
            zoneId: 'Asia/Shanghai',
          );
          memory.store.createCompareDraftTaskFromMessage(
            messageId: 'selection-$selection',
            expectedSourceRev: 1,
            itemNo: 0,
            roomMode: 'light',
            hostKey: hostKey,
            inputs: inputs,
            agreement: {
              ...compareAgreement(),
              'args': {
                for (final side in ['a', 'b'])
                  side: {
                    'sourceRef': (inputs[side]! as MemoryRow)['sourceRef'],
                    'version': (inputs[side]! as MemoryRow)['version'],
                  },
                'maxHighlights': 3,
              },
            },
          );
        }
      });
      final before = memory.store.hostTaskInputs(hostKey: hostKey);
      expect(before, hasLength(3));
      expect(before.where((row) => row['displayName'] == 'A.md'), hasLength(2));
      final folderRequests = peer.calls.where((call) => call.uri.path == '$notesPath/folders').toList();
      expect(folderRequests.map((call) => call.body!['path']), [
        '/原稿目录',
        ambiguity == 'other-directory-same-name' ? '/另一处稿件' : '/原稿目录',
      ]);
      memory.dispose();
      memory = _Memory(
        CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
        CompanionLocal.at(root),
        nowMilliseconds: () => now,
      );
      expect(memory.store.hostTaskInputs(hostKey: hostKey), before);
      final callsBeforePicker = peer.calls.length;
      Future<MemoryRow?>? selection;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () {
                  selection = chooseCompanionDraftInputs(
                    context,
                    store: memory.store,
                    hostKey: hostKey,
                    client: null,
                    capability: null,
                    isCurrent: () => context.mounted,
                  );
                },
                child: const Text('选择原稿'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择原稿'));
      await tester.pumpAndSettle();
      expect(find.text('这个名字对应不止一份已选稿件。请连上原来的电脑重新选。'), findsOneWidget);
      expect(find.text('A.md'), findsOneWidget);
      final ambiguous = find.ancestor(of: find.text('A.md'), matching: find.byType(SimpleDialogOption));
      expect(tester.widget<SimpleDialogOption>(ambiguous).onPressed, isNull);
      final unambiguous = find.ancestor(of: find.text('B.txt'), matching: find.byType(SimpleDialogOption));
      expect(tester.widget<SimpleDialogOption>(unambiguous).onPressed, isNotNull);
      await tester.tap(find.text('A.md'));
      await tester.pumpAndSettle();
      expect(find.text('选择之前选过的 A · 旧稿'), findsOneWidget);
      await tester.tap(find.text('取消'));
      expect(await settleMixed(tester, selection!), isNull);
      expect(memory.store.hostTaskInputs(hostKey: hostKey), before);
      expect(memory.store.tasks(), hasLength(2));
      expect(peer.calls, hasLength(callsBeforePicker));
      await close(tester);
    });
  }

  for (final result in ['completed', 'cancelled', 'recovered']) {
    testWidgets('I task page imports the unchanged actual Host report without reopening originals: $result', (
      tester,
    ) async {
      final cancelled = result == 'cancelled';
      final recovered = result == 'recovered';
      final filename = switch (result) {
        'cancelled' => 'companion_compare_cancelled_host_wire.json',
        'recovered' => 'companion_compare_owner_stopped_host_wire.json',
        _ => 'companion_compare_host_wire.json',
      };
      final wire = jsonDecode(File('../packages/dsh_client/test/fixtures/$filename').readAsStringSync()) as MemoryRow;
      final request = wire['create']! as MemoryRow;
      final origin = request['origin']! as MemoryRow;
      final id = request['taskId']! as String;
      final snapshot = wire['complete']! as MemoryRow;
      final selected = wire['inputs']! as MemoryRow;
      now = snapshot['createdAtMs']! as int;
      memory.dispose();
      memory = _Memory(
        CompanionMemoryStore(
          sqlite3.open('${root.path}/memory.sqlite'),
          nowMilliseconds: () => now,
          createId: () => id,
        ),
        CompanionLocal.at(root),
        nowMilliseconds: () => now,
      );
      memory.store.submitMessage(
        id: origin['messageId']! as String,
        sessionId: origin['sourceSessionId']! as String,
        text: '比较本人已选的 A 旧稿与 B 新稿，列至多三处改动，电脑上线后继续，两个原件不改。',
        saidAtUtc: now,
        offsetMinutes: 480,
        offsetSeconds: 28800,
        zoneId: 'Asia/Shanghai',
      );
      memory.store.createCompareDraftTaskFromMessage(
        messageId: origin['messageId']! as String,
        expectedSourceRev: 1,
        itemNo: origin['itemNo']! as int,
        roomMode: 'light',
        hostKey: hostKey,
        inputs: selected,
        agreement: {
          for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
        },
      );
      final prepared = memory.store.prepareHostTaskOperation(
        taskId: id,
        taskRev: 1,
        hostKey: hostKey,
        hostStoreId: request['hostStoreId']! as String,
        initialOpportunity: true,
      )!;
      expect(prepared['request'], request);
      if (cancelled) {
        memory.store.submitMessage(
          id: 'explicit-cancel-source',
          sessionId: origin['sourceSessionId']! as String,
          text: '取消这次对稿。',
          saidAtUtc: now,
          offsetMinutes: 480,
        );
        memory.store.cancelCompareDraftTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'explicit-cancel-source',
          expectedSourceRev: 1,
          itemNo: 0,
        );
        memory.store.prepareHostTaskOperation(
          taskId: id,
          taskRev: 2,
          hostKey: hostKey,
          hostStoreId: request['hostStoreId']! as String,
          initialOpportunity: false,
        );
      } else if (!recovered) {
        memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: wire['createReply']! as MemoryRow);
      }
      var response = recovered ? wire['before']! as MemoryRow : snapshot;
      peer.respond = (request, _) => NotesPeer.json(request, response);
      await open(tester, id);
      try {
        if (recovered) {
          expect(memory.store.hostTask(id)!['snapshot'], wire['before']);
          expect(memory.store.hostTask(id)!['state'], 'unknown');
          expect(find.text('未完成的对照'), findsOneWidget);
          expect(find.text('这次的文字对照'), findsNothing);
          expect(find.text('两份稿件的对照已经准备好。'), findsNothing);
          response = snapshot;
          await tester.tap(find.byIcon(AppIcons.refresh));
          await settleMixed(tester, memory.settled);
          await tester.pumpAndSettle();
          final oldReports = ((wire['before']! as MemoryRow)['steps']! as List<Object?>)
              .cast<MemoryRow>()
              .where((step) => step['stepKey'] == 'report')
              .toList();
          final reports = (snapshot['steps']! as List<Object?>)
              .cast<MemoryRow>()
              .where((step) => step['stepKey'] == 'report')
              .toList();
          expect(reports, hasLength(2));
          expect(reports.first, oldReports.single);
          expect(find.text('未完成的对照'), findsNothing);
          expect(find.text('读到过这份稿件，但交还结果时没能确认还是原来那一份。'), findsNothing);
        }
        expect(memory.store.hostTask(id)!['snapshot'], snapshot);
        expect(memory.store.hostTask(id)!['task_rev'], cancelled ? 2 : 1);
        expect(memory.store.hostTask(id)!['state'], cancelled ? 'cancelled' : 'done');
        expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], snapshot['runnerReceiptSeq']);
        expect(find.text(cancelled ? '未完成的对照' : '这次的文字对照'), findsOneWidget);
        if (cancelled) {
          expect(find.text('已停止继续对稿，之前留下的对照还在。'), findsOneWidget);
          expect(find.text('两份稿件的对照已经准备好。'), findsNothing);
          expect(find.text('读到过这份稿件，但交还结果时没能确认还是原来那一份。'), findsOneWidget);
        }
        expect(find.text('A · 旧稿：${(selected['a']! as MemoryRow)['displayName']}'), findsNWidgets(2));
        expect(find.text('B · 新稿：${(selected['b']! as MemoryRow)['displayName']}'), findsNWidgets(2));
        expect(find.text('文字变化 1'), findsOneWidget);
        expect(find.text('文字变化 2'), findsOneWidget);
        expect(find.text('文字变化 3'), findsNothing);
        expect(find.text('A · 旧稿 · 第 3 段'), findsOneWidget);
        expect(find.text('结尾原句。\n'), findsOneWidget);
        expect(find.text('结尾新句。\n'), findsOneWidget);
        expect(find.text('开场原句。\n'), findsOneWidget);
        expect(find.text('开场新句。\n'), findsOneWidget);
        expect(tester.getTopLeft(find.text('结尾原句。\n')).dy, lessThan(tester.getTopLeft(find.text('开场原句。\n')).dy));
        expect(find.text('排练建议'), findsOneWidget);
        expect(find.text('变化 1：建议按这一处的实际新句重新排练。'), findsOneWidget);
        for (final side in ['a', 'b']) {
          expect(find.textContaining((selected[side]! as MemoryRow)['version']! as String), findsNothing);
          expect(find.textContaining((selected[side]! as MemoryRow)['sourceRef']! as String), findsNothing);
        }
        expect(find.byType(ExpansionTile), findsNothing);
        expect(peer.calls, hasLength(recovered ? 2 : 1));
        for (final call in peer.calls) {
          expect(call.method, 'GET');
          expect(call.uri.path, '$notesPath/$id');
          expect(call.uri.queryParameters, {'hostStoreId': request['hostStoreId']});
        }
      } finally {
        await close(tester);
      }
      memory.dispose();
      memory = _Memory(
        CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now),
        CompanionLocal.at(root),
        nowMilliseconds: () => now,
      );
      expect(memory.store.hostTask(id)!['snapshot'], snapshot);
      expect(memory.store.hostTask(id)!['state'], cancelled ? 'cancelled' : 'done');
      expect(memory.store.hostTaskInputs(hostKey: hostKey), [selected['a'], selected['b']]);
      if (recovered) {
        await open(tester, id, connected: false);
        try {
          expect(find.text('这次的文字对照'), findsOneWidget);
          expect(find.text('未完成的对照'), findsNothing);
          expect(find.text('文字变化 1'), findsOneWidget);
          expect(memory.store.hostTask(id)!['snapshot'], snapshot);
          expect(peer.calls, hasLength(2));
        } finally {
          await close(tester);
        }
      }
    });
  }

  for (final result in [
    'identical',
    'no-model',
    'original-changed',
    'cancelled-old-report',
    'unpublished-after-deadline',
  ]) {
    testWidgets('I actual task page renders preserved facts and separate suggestions: $result', (tester) async {
      final deadline = result == 'unpublished-after-deadline' ? _now + 10 : null;
      final create = compareCommand(deadline: deadline);
      final id = create['taskId']! as String;
      final report = compareReportStep(
        advice: result != 'no-model',
        identical: result == 'identical',
        changed: result == 'original-changed',
        published: result != 'unpublished-after-deadline',
      );
      final cancelled = result == 'cancelled-old-report';
      if (cancelled) {
        memory.store.submitMessage(
          id: 'compare-cancel',
          sessionId: 'light:original-room',
          text: '取消对稿，保留已经交还的对照。',
          saidAtUtc: _now + 1,
          offsetMinutes: 480,
        );
        memory.store.cancelCompareDraftTask(
          taskId: id,
          expectedTaskRev: 1,
          messageId: 'compare-cancel',
          expectedSourceRev: 1,
          itemNo: 0,
        );
      }
      final state = cancelled
          ? 'cancelled'
          : result == 'unpublished-after-deadline'
          ? 'failed'
          : report['state']! as String;
      final snapshot = notesSnapshot(
        create,
        seq: 7,
        rev: cancelled ? 2 : 1,
        state: state,
        steps: [report],
        revisions: [
          {
            'taskRev': 1,
            'operation': 'create',
            'acceptedAtMs': _now,
            'agreement': compareAgreement(deadline: deadline),
          },
          if (cancelled) {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': _now + 1, 'agreement': null},
        ],
      );
      if (result == 'unpublished-after-deadline') {
        now = _now + 11;
        snapshot['updatedAtMs'] = now;
        snapshot['waitReason'] = 'deadline_or_agreement_changed';
      }
      peer.respond = (request, _) => NotesPeer.json(request, snapshot);
      await open(tester, id);
      try {
        expect(memory.store.hostTask(id)!['state'], state);
        expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 7);
        expect(find.text('A · 旧稿：A.md'), findsNWidgets(2));
        expect(find.text('B · 新稿：B.txt'), findsNWidgets(2));
        expect(
          find.text(
            result == 'unpublished-after-deadline'
                ? '未完成的对照'
                : cancelled
                ? '之前留下的文字对照'
                : '这次的文字对照',
          ),
          findsOneWidget,
        );
        if (result == 'unpublished-after-deadline') {
          expect(find.text('这次的文字对照'), findsNothing);
          expect(find.text('两份稿件的对照已经准备好。'), findsNothing);
        }
        if (result == 'identical') {
          expect(find.text('这次读到的两份稿件没有文字改动。'), findsOneWidget);
          expect(find.text('文字变化 1'), findsNothing);
          expect(find.text('排练建议'), findsNothing);
        } else {
          expect(find.text('文字变化 1'), findsOneWidget);
          expect(find.text('文字变化 2'), findsOneWidget);
          expect(find.text('文字变化 3'), findsNothing);
          expect(find.text('A · 旧稿 · 第 1 段'), findsOneWidget);
          expect(find.text('B · 新稿 · 第 3 段'), findsOneWidget);
          expect(find.text('周五开放。\n'), findsOneWidget);
          expect(find.text('周六开放。\n'), findsOneWidget);
          expect(find.text('最后我们再想一想？\n'), findsOneWidget);
          expect(find.text('最后我们再想一想。\n'), findsOneWidget);
          expect(find.text('这次核到 2 组文字变化，列出其中 2 组。'), findsOneWidget);
          if (result == 'no-model') {
            expect(find.text('下面按原文顺序列出已核的改动，还没排出重练重点。'), findsOneWidget);
            expect(find.text('排练建议'), findsNothing);
            expect(find.text('还没准备好排练建议，下面保留已核的文字变化。'), findsOneWidget);
          } else {
            expect(find.text('排练建议'), findsOneWidget);
            expect(find.text('变化 1：可以重练这一处的停顿。'), findsOneWidget);
          }
        }
        if (result == 'original-changed') {
          expect(find.text('读到过这份稿件，但交还结果时没能确认还是原来那一份。'), findsOneWidget);
          expect(find.text('这次还有没完成的部分，已确认的文字变化会保留。'), findsOneWidget);
          expect(find.text('两份稿件的对照已经准备好。'), findsNothing);
        }
        expect(find.textContaining('bound-version-'), findsNothing);
        expect(find.textContaining('actual-execution'), findsNothing);
        expect(find.textContaining('input-a'), findsNothing);
        expect(find.text('执行记录'), findsNothing);
        expect(find.text('费用与用量'), findsNothing);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(peer.calls.every((call) => call.method == 'GET' && call.uri.path == '$notesPath/$id'), isTrue);
        expect(peer.calls, hasLength(1));
      } finally {
        await close(tester);
      }
    });
  }

  testWidgets('I task page amendment and cancellation keep the original two bindings and earlier report', (
    tester,
  ) async {
    final create = compareCommand();
    final id = create['taskId']! as String;
    final oldReport = compareReportStep(advice: false);
    var snapshot = notesSnapshot(create, state: 'partial', steps: [oldReport]);
    final amendment = Completer<void>();
    final cancellation = Completer<void>();
    final clockCalls = <MethodCall>[];
    final sourceAtSend = <MemoryRow>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      clockCalls.add(call);
      now = _now + 60000;
      return switch (call.method) {
        'clock' => {'utcMs': now, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800},
        'resolve' => {
          'kind': 'unique',
          'moments': [
            {'epochMs': DateTime.utc(2026, 11, 22, 12).millisecondsSinceEpoch, 'offsetSeconds': 28800},
          ],
        },
        _ => throw StateError('Unexpected comparison time call ${call.method}'),
      };
    });
    peer.respond = (request, body) async {
      if (request.method == 'GET') {
        await NotesPeer.json(request, snapshot);
      } else if (request.uri.path == '$notesPath/$id/amend') {
        sourceAtSend.add(memory.store.messages().last);
        final plan = body!['changes']! as MemoryRow;
        snapshot = notesSnapshot(
          create,
          rev: 2,
          seq: 2,
          agreement: plan,
          steps: [oldReport],
          revisions: [
            {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': compareAgreement()},
            {'taskRev': 2, 'operation': 'amend', 'acceptedAtMs': now, 'agreement': plan},
          ],
        );
        await NotesPeer.json(request, snapshot);
        amendment.complete();
      } else if (request.uri.path == '$notesPath/$id/cancel') {
        sourceAtSend.add(memory.store.messages().last);
        snapshot = {
          ...snapshot,
          'taskRev': 3,
          'runnerReceiptSeq': 3,
          'state': 'cancelled',
          'cancelRequested': true,
          'revisions': [
            ...(snapshot['revisions']! as List<Object?>),
            {'taskRev': 3, 'operation': 'cancel', 'acceptedAtMs': now, 'agreement': null},
          ],
        };
        await NotesPeer.json(request, snapshot);
        cancellation.complete();
      } else {
        await NotesPeer.json(request, {
          'error': {'code': 'companion/not-found', 'message': 'Unexpected route'},
        }, status: 404);
      }
    };
    await open(tester, id);
    try {
      await tester.ensureVisible(find.text('改一下'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('改一下'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextFormField)), '2026-11-22 20:00');
      await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
      await settleMixed(tester, amendment.future);
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      final updated = memory.store.hostTask(id)!;
      expect(updated['task_rev'], 2);
      expect(updated['directory_labels'], {'inputs': compareInputs()});
      expect((updated['agreement']! as MemoryRow)['args'], compareAgreement()['args']);
      expect(
        (updated['agreement']! as MemoryRow)['deadlineAtMs'],
        DateTime.utc(2026, 11, 22, 12).millisecondsSinceEpoch,
      );
      expect(find.text('之前留下的文字对照'), findsOneWidget);
      expect(find.text('周五开放。\n'), findsOneWidget);
      expect(clockCalls.where((call) => call.method == 'resolve').single.arguments, {
        'localDate': '2026-11-22',
        'localTime': '20:00',
        'zoneId': 'Asia/Shanghai',
      });
      await tester.ensureVisible(find.text('停止对稿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止对稿'));
      await settleMixed(tester, cancellation.future);
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      expect(memory.store.hostTask(id)!['state'], 'cancelled');
      expect(memory.store.hostTask(id)!['task_rev'], 3);
      expect(sourceAtSend, hasLength(2));
      expect(sourceAtSend.every((row) => row['session_id'] == 'light:original-room'), isTrue);
      expect(sourceAtSend.first['text'], contains('2026-11-22 20:00'));
      expect(sourceAtSend.last['text'], '取消这次对稿，保留已经交还的对照。');
      expect(memory.store.messages().first['said_at_utc'], _now);
      expect(memory.store.hostTaskCommands(id), hasLength(3));
      expect(find.text('之前留下的文字对照'), findsOneWidget);
      expect(find.text('最后我们再想一想？\n'), findsOneWidget);
      expect(peer.calls.where((call) => call.method == 'POST').map((call) => call.uri.path), [
        '$notesPath/$id/amend',
        '$notesPath/$id/cancel',
      ]);
    } finally {
      await close(tester);
    }
  });

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
      expect(find.text('电脑接下这件事了，结果还没出来。'), findsOneWidget);
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

  testWidgets(
    'H task page shows a complete empty find report and repeated reads never submit or create a model receipt',
    (tester) async {
      final create = findCommand();
      final id = create['taskId']! as String;
      final report = findReportStep();
      final snapshot = notesSnapshot(create, state: 'done', steps: [report]);
      peer.respond = (request, _) => NotesPeer.json(request, snapshot);
      await open(tester, id);
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(peer.calls.single.uri.path, '$notesPath/$id');
      expect(find.text('找完了，结果在下面。'), findsOneWidget);
      expect(find.textContaining('已用执行时间'), findsNothing);
      expect(find.text('查找步骤记录'), findsNothing);
      expect(find.text('版本 1'), findsNothing);
      expect(find.text('查过的范围里，没有这一天改过的所选格式稿件。'), findsOneWidget);
      expect(find.text('打开这份原稿'), findsNothing);
      expect(find.text('打开原产物'), findsNothing);
      expect(find.text('停止找稿'), findsNothing);
      await close(tester);
      await open(tester, id);
      expect(peer.calls.map((call) => call.method), ['GET', 'GET']);
      expect(memory.store.requests(), isEmpty);
      expect((memory.store.hostTask(id)!['snapshot']! as MemoryRow)['artifacts'], isEmpty);
      expect((memory.store.hostTask(id)!['snapshot']! as MemoryRow)['steps'], [report]);
      expect((memory.store.hostTask(id)!['snapshot']! as MemoryRow)['budget'], snapshot['budget']);
      await close(tester);
    },
  );

  testWidgets('H task page keeps unreadable results after actual enumeration EOF without claiming all work complete', (
    tester,
  ) async {
    // Consume the unchanged actual H02 HTTP fixture. It reached directory EOF,
    // while one selected file was not readable and the task remained partial.
    final wire = jsonDecode(
      File('../packages/dsh_client/test/fixtures/companion_find_draft/H02-backslash-wire.json').readAsStringSync(),
    ) as MemoryRow;
    final request = wire['create']! as MemoryRow;
    final origin = request['origin']! as MemoryRow;
    final id = request['taskId']! as String;
    final snapshot = wire['complete']! as MemoryRow;
    final report =
        ((snapshot['steps']! as List<Object?>).cast<MemoryRow>().singleWhere(
                  (step) => step['stepKey'] == 'readInputs',
                )['result']!
                as MemoryRow)['completion']!
            as MemoryRow;
    expect(snapshot['state'], 'partial');
    expect((report['coverage']! as MemoryRow)['enumerationComplete'], isTrue);
    expect(
      (report['matches']! as List<Object?>).cast<MemoryRow>().where((match) => match['openable'] == false),
      hasLength(1),
    );
    memory.dispose();
    memory = _Memory(
      CompanionMemoryStore(sqlite3.open('${root.path}/memory.sqlite'), nowMilliseconds: () => now, createId: () => id),
      CompanionLocal.at(root),
      nowMilliseconds: () => now,
    );
    memory.store.submitMessage(
      id: origin['messageId']! as String,
      sessionId: origin['sourceSessionId']! as String,
      text: '在已选演讲稿目录找2026年11月20日改的md和txt。',
      saidAtUtc: now,
      offsetMinutes: 0,
      zoneId: 'UTC',
      offsetSeconds: 0,
    );
    memory.store.createFindDraftTaskFromMessage(
      messageId: origin['messageId']! as String,
      expectedSourceRev: 1,
      itemNo: origin['itemNo']! as int,
      roomMode: 'light',
      hostKey: hostKey,
      directoryHostStoreId: request['hostStoreId']! as String,
      agreement: {
        for (final key in ['args', 'deadlineAtMs', 'afterExit', 'allowQueue']) key: request[key],
      },
      directoryLabels: {'source': (wire['folder']! as MemoryRow)['displayPath']},
    );
    final prepared = memory.store.prepareHostTaskOperation(
      taskId: id,
      taskRev: 1,
      hostKey: hostKey,
      hostStoreId: request['hostStoreId']! as String,
      initialOpportunity: true,
    )!;
    expect(prepared['request'], request);
    peer.capability = wire['capabilities']! as MemoryRow;
    peer.respond = (request, _) => NotesPeer.json(request, snapshot);
    await open(tester, id);
    try {
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(peer.calls.single.uri.path, '$notesPath/$id');
      expect(peer.calls.single.uri.queryParameters, {'hostStoreId': snapshot['hostStoreId']});
      expect(find.text('这一层的文件名已检查完，能否打开见下面的结果。查找时后来加入的文件可能不在结果里。'), findsOneWidget);
      expect(find.text('这次没能全找完，已找到的稿件和没查完的地方在下面。'), findsOneWidget);
      expect(find.text(r'unsafe\name.md'), findsOneWidget);
      expect(find.text('ordinary.md'), findsOneWidget);
      expect(find.text('当时没能读到这份稿件。'), findsOneWidget);
      expect(find.textContaining('这一层已查完'), findsNothing);
      expect(find.text('找完了，结果在下面。'), findsNothing);
      expect(find.text('查过的范围里，没有这一天改过的所选格式稿件。'), findsNothing);
      expect(peer.calls.map((call) => call.method), ['GET']);
      expect(memory.store.hostTask(id)!['snapshot'], snapshot);
      expect(memory.store.hostTask(id)!['state'], 'partial');
      expect(memory.store.requests(), isEmpty);
    } finally {
      await close(tester);
    }
  });

  for (final limit in ['entries', 'candidates']) {
    testWidgets(
      'H task page keeps the actual $limit coverage limit visible instead of claiming an empty complete search',
      (tester) async {
        final create = findCommand();
        final id = create['taskId']! as String;
        final matches = limit == 'entries'
            ? <MemoryRow>[]
            : [for (var i = 0; i < 20; i++) findMatch(id: 'draft-$i', name: '稿件$i.md')];
        final step = findReportStep(matches: matches, complete: false);
        final report = (step['result']! as MemoryRow)['completion']! as MemoryRow;
        report['coverage'] = {
          'entriesChecked': limit == 'entries' ? 200 : 25,
          'supportedFilesChecked': limit == 'entries' ? 4 : 21,
          'matchingCandidates': limit == 'entries' ? 0 : 21,
          'enumerationComplete': false,
          'entryLimitReached': limit == 'entries',
          'candidateLimitReached': limit == 'candidates',
          'gaps': [],
        };
        peer.respond = (request, _) => NotesPeer.json(request, notesSnapshot(create, state: 'partial', steps: [step]));
        await open(tester, id);
        try {
          expect(find.text('这次没能全找完，已找到的稿件和没查完的地方在下面。'), findsOneWidget);
          expect(find.text('查过的范围里，没有这一天改过的所选格式稿件。'), findsNothing);
          expect(
            find.text(limit == 'entries' ? '这次最多检查 200 项，剩下的还没查。' : '符合日期的稿件超过 20 份，这次先列出其中 20 份。'),
            findsOneWidget,
          );
          if (limit == 'candidates') {
            expect(find.textContaining('找到 ≥21 份符合日期的稿件'), findsOneWidget);
            expect(find.text('打开这份原稿'), findsNWidgets(20));
          }
          expect(peer.calls.map((call) => call.method), ['GET']);
          expect(memory.store.requests(), isEmpty);
        } finally {
          await close(tester);
        }
      },
    );
  }

  for (final status in ['available', 'missing', 'changed', 'not_readable', 'unknown']) {
    testWidgets('H task page opens the original registered source after cancellation with actual $status readback', (
      tester,
    ) async {
      final create = findCommand();
      final id = create['taskId']! as String;
      final match = findMatch(openable: false);
      final report = findReportStep(matches: [match], complete: false);
      memory.store.submitMessage(
        id: 'cancel-find',
        sessionId: 'light:original-room',
        text: '取消这次找稿',
        saidAtUtc: _now + 1,
        offsetMinutes: 480,
      );
      memory.store.cancelFindDraftTask(
        taskId: id,
        expectedTaskRev: 1,
        messageId: 'cancel-find',
        expectedSourceRev: 1,
        itemNo: 0,
      );
      final snapshot = notesSnapshot(
        create,
        rev: 2,
        seq: 7,
        state: 'cancelled',
        steps: [report],
        revisions: [
          {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': findAgreement()},
          {'taskRev': 2, 'operation': 'cancel', 'acceptedAtMs': _now + 1, 'agreement': null},
        ],
      );
      peer.respond = (request, _) {
        if (request.uri.path == '$notesPath/$id') {
          return NotesPeer.json(request, snapshot);
        }
        return NotesPeer.json(request, {
          'v': 1,
          'hostStoreId': 'original-store',
          'taskId': id,
          'hostExecutionId': 'actual-execution',
          'sourceRef': 'draft-original',
          'taskRev': 1,
          'stepKey': 'readInputs',
          'relativePath': match['relativePath'],
          'version': match['version'],
          'mediaType': 'text/markdown',
          'status': status,
          'content': status == 'available' ? '# 原稿完整内容\n第二段保留。' : null,
          'reason': status == 'available' ? null : 'observed-$status',
        });
      };
      await open(tester, id);
      try {
        expect(find.text('已停止继续找，之前找到的清单还在。'), findsOneWidget);
        expect(find.text('之前找到的稿件'), findsOneWidget);
        expect(find.textContaining('Asia/Shanghai (UTC+08:00)'), findsOneWidget);
        expect(find.text('查过的范围里，没有这一天改过的所选格式稿件。'), findsNothing);
        await tester.ensureVisible(find.text('打开这份原稿'));
        await tester.tap(find.text('打开这份原稿'));
        final expected = switch (status) {
          'available' => '# 原稿完整内容\n第二段保留。',
          'missing' => '这份稿件现在找不到了，当时的清单还在。',
          'changed' => '这份稿件已被替换或修改，不能确认还是当时那一份。',
          'not_readable' => '这份稿件现在没能完整打开；没有换成别的文件。',
          _ => '现在还打不开这份稿件，请连上原来的电脑再试。',
        };
        await visible(tester, expected);
        expect(peer.calls.map((call) => call.method), ['GET', 'GET']);
        expect(peer.calls.last.uri.path, '$notesPath/$id/sources/draft-original');
        expect(peer.calls.last.uri.queryParameters, {
          'hostStoreId': 'original-store',
          'hostExecutionId': 'actual-execution',
        });
        expect(peer.calls.where((call) => call.method == 'POST'), isEmpty);
        expect(memory.store.requests(), isEmpty);
        expect(memory.store.hostTask(id)!['state'], 'cancelled');
        expect(memory.store.hostTask(id)!['applied_host_receipt_seq'], 7);
        expect((memory.store.hostTask(id)!['snapshot']! as MemoryRow)['steps'], [report]);
        expect(memory.store.hostTask(id).toString(), isNot(contains('# 原稿完整内容')));
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
      } finally {
        await close(tester);
      }
    });
  }

  testWidgets('H offline task details retain the original list but do not offer an uncached source body', (
    tester,
  ) async {
    final create = findCommand();
    final id = create['taskId']! as String;
    final snapshot = notesSnapshot(
      create,
      state: 'done',
      steps: [
        findReportStep(matches: [findMatch()]),
      ],
    );
    memory.store.importHostTaskSnapshot(taskId: id, hostKey: hostKey, snapshot: snapshot);
    await open(tester, id, connected: false);
    try {
      expect(find.text('开场 A.md'), findsOneWidget);
      expect(find.text('清单还在。连上原来的电脑后才能打开稿件。'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '打开这份原稿')).onPressed, isNull);
      expect(peer.calls, isEmpty);
      expect(memory.store.requests(), isEmpty);
    } finally {
      await close(tester);
    }
  });

  testWidgets(
    'H changing a completed report day and format uses a new original-room source and preserves the old result',
    (tester) async {
      final clockCalls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        clockCalls.add(call);
        now = _now + 60000;
        return {'utcMs': now, 'zoneId': 'America/New_York', 'offsetSeconds': -18000};
      });
      final create = findCommand();
      final id = create['taskId']! as String;
      final report = findReportStep(matches: [findMatch()]);
      var snapshot = notesSnapshot(create, state: 'done', steps: [report]);
      final returned = Completer<void>();
      MemoryRow? sourceAtAmend;
      Object? possibleSentAtAmend;
      peer.respond = (request, body) async {
        if (request.method == 'POST') {
          final agreement = body!['changes']! as MemoryRow;
          sourceAtAmend = memory.store.messages().last;
          possibleSentAtAmend = memory.store.hostTaskCommands(id).last['possible_sent_at_ms'];
          snapshot = notesSnapshot(
            create,
            rev: 2,
            seq: 2,
            agreement: agreement,
            steps: [report],
            revisions: [
              {'taskRev': 1, 'operation': 'create', 'acceptedAtMs': _now, 'agreement': findAgreement()},
              {'taskRev': 2, 'operation': 'amend', 'acceptedAtMs': _now + 60000, 'agreement': agreement},
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
        await tester.ensureVisible(find.text('改一下'));
        await tester.tap(find.text('改一下'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).first, '2026-11-21');
        await tester.tap(find.byType(DropdownButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('.txt').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await settleMixed(tester, returned.future);
        await settleMixed(tester, memory.settled);
        await tester.pumpAndSettle();
        expect(clockCalls.map((call) => call.method), ['clock']);
        final post = peer.calls.singleWhere((call) => call.method == 'POST');
        expect(post.uri.path, '$notesPath/$id/amend');
        expect(post.body!['kind'], 'host.find_draft');
        expect(post.body!['taskRev'], 2);
        final args = (post.body!['changes']! as MemoryRow)['args']! as MemoryRow;
        expect(args['localDate'], '2026-11-21');
        expect(args['timeZone'], 'Asia/Shanghai');
        expect(args['extensions'], ['txt']);
        expect(args['folderRef'], 'bound-source');
        expect(args.containsKey('outputName'), isFalse);
        expect(sourceAtAmend!['session_id'], 'light:original-room');
        expect(sourceAtAmend!['zone_id'], 'America/New_York');
        expect(sourceAtAmend!['offset_seconds'], -18000);
        expect(sourceAtAmend!['text'], contains('2026-11-21'));
        expect(sourceAtAmend!['text'], contains('txt'));
        expect(possibleSentAtAmend, _now + 60000);
        expect(find.text('之前找到的稿件'), findsOneWidget);
        expect(find.text('开场 A.md'), findsOneWidget);
        expect(memory.store.hostTask(id)!['task_rev'], 2);
        expect(memory.store.hostTaskCommands(id), hasLength(2));
        expect((memory.store.hostTask(id)!['snapshot']! as MemoryRow)['steps'], [report]);
        expect(peer.calls.where((call) => call.method == 'POST'), hasLength(1));
        expect(peer.calls.any((call) => call.uri.path.endsWith('/folders')), isFalse);
        expect(memory.store.requests(), isEmpty);
      } finally {
        await close(tester);
      }
    },
  );
}
