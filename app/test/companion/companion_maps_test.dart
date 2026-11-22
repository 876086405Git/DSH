import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_maps.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_map_platform_peer.dart';
import 'companion_test_settle.dart';

const _now = 1795219200000;
const _address = ' 文华路 18 号东门 & A座（入口😀）；不走西门 ';

class _Memory extends CompanionMemoryOwner {
  _Memory(super.store, super.legacy);
  late Future<void> settled;
  @override
  void retainReceipt(Future<void> work) {
    super.retainReceipt(work);
    settled = work;
  }
}

void main() {
  test('G finite map grammar preserves the complete quoted address and mixed item identity', () {
    final raw = '在地图打开“$_address”，我自己看路线；我午后练长笛';
    final parts = parseCompanionReminders(raw);
    expect(parts, hasLength(2));
    final command = parseCompanionMap(parts.first.raw)!;
    expect(command, {'operation': 'create', 'address': _address, 'target': null});
    expect(parts.first.itemNo, 0);
    expect(parseCompanionMap(parts.last.raw), isNull);
    expect(parseCompanionMap('把“$_address”的地图地址改成“文华路 19 号南门”'), {
      'operation': 'amend',
      'address': '文华路 19 号南门',
      'target': _address,
    });
    expect(parseCompanionMap('重新打开地图'), {'operation': 'reopen', 'target': null});
  });

  for (final raw in ['“在地图打开“文华路 18 号””', '不要在地图打开“文华路 18 号”', '故事里，在地图打开“文华路 18 号”', '他说在地图打开“文华路 18 号”']) {
    test('G finite map grammar does not execute quoted denied or story wording: $raw', () {
      expect(parseCompanionMap(raw), isNull);
    });
  }
  for (final address in ['东门', '东门或者西门', '两个同名入口']) {
    test('G finite map grammar asks about an unresolved explicit target: $address', () {
      expect(parseCompanionMap('在地图打开“$address”'), {'operation': 'clarify'});
    });
  }

  group('G actual task page', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    const reminders = MethodChannel('dsh/companion_reminders');
    late Directory root;
    late Database db;
    late _Memory memory;
    late MapPlatformPeer peer;
    late List<String> reminderCalls;

    void restore() {
      db = sqlite3.open('${root.path}/memory.sqlite');
      memory = _Memory(CompanionMemoryStore(db, nowMilliseconds: () => _now), CompanionLocal.at(root));
      peer = MapPlatformPeer(db, memory.store);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(MapPlatformPeer.channel, peer.handle);
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      root = Directory.systemTemp.createTempSync('map-page-');
      restore();
      reminderCalls = [];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(reminders, (call) async {
        reminderCalls.add(call.method);
        return {'utcMs': _now + 60000, 'zoneId': 'Asia/Shanghai', 'offsetSeconds': 28800};
      });
    });
    tearDown(() {
      memory.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(MapPlatformPeer.channel, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(reminders, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      root.deleteSync(recursive: true);
      expect(
        reminderCalls,
        everyElement('clock'),
        reason: 'Map identity must not create reminder notification channels',
      );
    });

    MemoryRow original() {
      memory.store.submitMessage(
        id: 'original',
        sessionId: 'light:original-room',
        text: '在地图打开“$_address”',
        saidAtUtc: _now,
        offsetMinutes: 480,
      );
      return memory.store.createMapOpenFromMessage(
        messageId: 'original',
        expectedSourceRev: 1,
        itemNo: 0,
        roomMode: 'light',
        executorId: 'installation-A',
        map: const CompanionMapSpec(
          address: _address,
          targetKind: 'selected',
          packageName: 'test.maps',
          componentName: 'test.maps.View',
          packageUid: 12001,
          targetLabel: '实际候选地图',
        ),
      );
    }

    Future<void> open(WidgetTester tester, String id) async {
      final before = binding.lifecycleState;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(() {
        if (before != null) {
          binding.handleAppLifecycleStateChanged(before);
        } else {
          binding.resetInternalState();
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))],
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: CompanionTasksPage(memory: memory, taskId: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final action in ['reopen', 'cancel']) {
      testWidgets('reopened SQLite keeps unknown without dispatch until the explicit $action action', (tester) async {
        final task = original();
        final id = task['task_id']! as String;
        final attempt = peer.claim(task); // Simulated native claim lost its return receipt.
        memory.dispose();
        restore();
        await open(tester, id);
        expect(peer.calls.map((call) => call.method), ['capabilities']);
        expect(find.text('还不能确定地图有没有打开，不会自动再打开。'), findsOneWidget);
        String? copied;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object?, Object?>)['text']! as String;
          }
          return null;
        });
        await tester.tap(find.text('复制原地址'));
        await tester.pump();
        expect(copied, _address);
        expect(peer.calls.where((call) => call.method == 'handoff'), isEmpty);
        peer.onHandoff = (row) async => peer.returned(row, peer.claim(row));
        await tester.tap(find.text(action == 'reopen' ? '再打开一次' : '取消这次打开'));
        await settleMixed(tester, memory.settled);
        await tester.pumpAndSettle();
        final rows = memory.store.tasks();
        final source = memory.store.messages().singleWhere((row) => row['id'] != 'original');
        expect(source['session_id'], 'light:original-room');
        expect(source['said_at_utc'], _now + 60000);
        expect(
          source['text'],
          isNot(contains(_address)),
          reason: 'The new UI command is not a fabricated address quote',
        );
        if (action == 'reopen') {
          expect(rows, hasLength(2));
          final created = memory.store.mapTask(rows.singleWhere((row) => row['task_id'] != id)['task_id']! as String)!;
          expect(created['reopens_task_id'], id);
          expect(created['address'], _address);
          expect(created['state'], 'done');
          expect(created['source_message_id'], source['id']);
          expect(memory.store.mapTask(id)!['state'], 'unknown');
          expect(peer.calls.where((call) => call.method == 'handoff'), hasLength(1));
          expect(find.text('地址已交给地图打开。'), findsOneWidget);
        } else {
          expect(rows, hasLength(1));
          expect(memory.store.mapTask(id)!['state'], 'cancelled');
          expect(memory.store.mapTask(id)!['task_rev'], 2);
          expect(peer.calls.where((call) => call.method == 'handoff'), isEmpty);
          expect(find.text('已取消这次打开。如果地图已经打开，不会替你关闭。'), findsOneWidget);
          expect(find.byType(ExpansionTile), findsNothing);
        }
        final originalReceipts = memory.store.taskReceipts(id).where((row) => row['attempt_id'] == attempt).toList();
        expect(originalReceipts, hasLength(1));
        expect(originalReceipts.single['event_kind'], 'claimed');
        expect(originalReceipts.single['outcome'], isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('a normal channel acknowledgement does not become a successful map handoff', (tester) async {
      final task = original();
      final id = task['task_id']! as String;
      await open(tester, id);
      await tester.tap(find.text('再打开一次'));
      await settleMixed(tester, memory.settled);
      await tester.pumpAndSettle();
      final created = memory.store.tasks().singleWhere((row) => row['task_id'] != id);
      expect(peer.calls.where((call) => call.method == 'handoff'), hasLength(1));
      expect(created['state'], 'queued');
      expect(memory.store.taskReceipts(created['task_id']! as String), isEmpty);
      expect(find.text('地址记下了，还没打开地图。'), findsOneWidget);
      expect(find.text('地址已交给地图打开。'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('an installation change keeps the old handoff evidence and original address visible', (tester) async {
      final task = original();
      peer.returned(task, peer.claim(task));
      peer.executorId = 'new-installation';
      await open(tester, task['task_id']! as String);
      expect(find.text('地址已交给地图打开。'), findsOneWidget);
      expect(find.text('这是之前留下的记录。需要的话，可以复制地址或再打开一次。'), findsOneWidget);
      expect(find.text(_address), findsOneWidget);
      expect(peer.calls.where((call) => call.method == 'handoff'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a failed synchronous scope transaction is reported and still attempts native close', (tester) async {
      final task = original();
      final entered = Completer<void>();
      final release = Completer<void>();
      peer.onHandoff = (_) async {
        entered.complete();
        await release.future;
      };
      final owner = CompanionMapHandoff(const CompanionMaps());
      final operation = owner.execute(memory.store, task, isCurrent: () => true);
      await settleMixed(tester, entered.future);
      db.execute(
        "CREATE TRIGGER reject_scope_close BEFORE UPDATE OF closed ON companion_map_scopes BEGIN SELECT RAISE(ABORT,'fixture'); END",
      );
      final errors = <FlutterErrorDetails>[];
      final priorError = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        owner.close();
        await tester.pump();
        expect(errors, hasLength(1));
        expect(errors.single.exception, isA<SqliteException>());
        expect(db.select('SELECT closed FROM companion_map_scopes').single['closed'], 0);
        expect(peer.calls.where((call) => call.method == 'closeScope'), hasLength(1));
        expect(memory.store.mapTask(task['task_id']! as String)!['state'], 'queued');
        expect(memory.store.taskReceipts(task['task_id']! as String), isEmpty);
        final checked = expectLater(operation, throwsA(isA<SqliteException>()));
        release.complete();
        await settleMixed(tester, checked);
        expect(peer.calls.where((call) => call.method == 'closeScope'), hasLength(2));
      } finally {
        FlutterError.onError = priorError;
        if (!release.isCompleted) {
          release.complete();
        }
      }
    });
  });
}
