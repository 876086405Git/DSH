import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_tasks_page.dart';
import 'package:dsh_app/ui/shell/system_entry_host.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'companion_test_settle.dart';

const _channel = MethodChannel('dsh/companion_reminders');
const _raw = '2026-03-08 03:10 America/Los_Angeles提醒我带钥匙';
const _clock = {'utcMs': 1772877000000, 'zoneId': 'America/Los_Angeles', 'offsetSeconds': -28800};
const _unique = {
  'kind': 'unique',
  'moments': [
    {'epochMs': 1772964600000, 'offsetSeconds': -25200},
  ],
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  late CompanionMemoryStore store;
  CompanionMemoryOwner? owner;
  late List<MethodCall> calls;
  late Map<String, Object?> resolution;
  late Map<String, Object?> clock;
  late String executor;
  var unavailable = false;
  const reminders = CompanionReminders();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('companion-reminder');
    db = sqlite3.open('${root.path}/memory.sqlite');
    clock = {..._clock};
    store = CompanionMemoryStore(db, nowMilliseconds: () => clock['utcMs']! as int);
    calls = [];
    resolution = _unique;
    executor = 'installation-A';
    unavailable = false;
    owner = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'clock' => clock,
        'resolve' => resolution,
        'capabilities' =>
          unavailable
              ? throw PlatformException(code: 'reminder_platform')
              : {'executorId': executor, 'exact': true, 'notifications': true},
        'wake' => {'wakeCompleted': true},
        _ => throw StateError('Unexpected platform method ${call.method}'),
      };
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    if (owner == null) {
      store.close();
    } else {
      owner!.dispose();
    }
    root.deleteSync(recursive: true);
  });

  Future<MemoryRow> source(String id, String raw) async {
    final at = await reminders.clock();
    return store.submitMessage(
      id: id,
      sessionId: store.lightSessionId,
      text: raw,
      saidAtUtc: at.utcMs,
      offsetMinutes: at.offsetSeconds ~/ 60,
      zoneId: at.zoneId,
      offsetSeconds: at.offsetSeconds,
    );
  }

  Future<CompanionReminderResult> submit(MemoryRow source, {MemoryRow? previous}) => reminders.submit(
    store: store,
    source: source,
    part: parseCompanionReminders(source['text']! as String).single,
    roomMode: 'light',
    previous: previous,
    isCurrent: () => true,
  );

  // Synthetic input at the native receipt boundary. These rows do not claim
  // that Kotlin, AlarmManager or a physical notification ran in this test.
  void registered(MemoryRow task) {
    for (final event in ['claimed', 'returned']) {
      db.execute(
        '''
        INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
          executor_id,occurred_at_ms,outcome)
        VALUES(?,?,'alarm.register','native-fixture',?,?,?,?)
      ''',
        [
          task['task_id'],
          task['task_rev'],
          event,
          task['executor_id'],
          1772877000000,
          event == 'returned' ? 'succeeded' : null,
        ],
      );
    }
    db.execute("UPDATE companion_task_revisions SET state='done' WHERE task_id=? AND task_rev=?", [
      task['task_id'],
      task['task_rev'],
    ]);
  }

  test('D complete reminder commands do not execute quoted story clauses or ordinary intentions', () {
    for (final raw in [
      '故事里她说：“明早八点提醒我带书；明晚八点提醒我带证件。”',
      '她说："明早八点提醒我带书;明晚八点提醒我带证件"',
      '小说台词：「明早八点提醒我带书\n明晚八点提醒我带证件」',
      '故事里她说：“明早八点提醒我带书；明晚八点提醒我带证件',
      '你说可以明早八点提醒我带证件。',
      '我明早八点记得带证件。',
      '明早八点不要提醒我带证件。',
    ]) {
      expect(
        parseCompanionReminders(raw).every((part) => part.command == null || part.command!.operation == 'clarify'),
        isTrue,
        reason: raw,
      );
    }
    const raw = '明早八点提醒我带“证件；钥匙”；现实里明晚八点提醒我带书';
    final parts = parseCompanionReminders(raw);
    expect(parts.map((part) => part.itemNo), [0, 1]);
    expect(parts.map((part) => part.command!.text), ['带“证件；钥匙”', '带书']);
    expect(parts.map((part) => part.command!.operation), everyElement('create'));
    final english = parseCompanionReminders(
      "remind me at tomorrow 08:00 to bring dad's keys;remind me at tomorrow 09:00 to bring books",
    );
    expect(english.map((part) => part.command!.text), ["bring dad's keys", 'bring books']);
    expect(parseCompanionReminders('2026-03-08 08:00 Etc/GMT-8提醒我带书').single.command?.operation, 'create');
  });

  test('D a missing reminder subject is persisted as waiting without resolving or scheduling', () async {
    final original = await source('missing-subject', '明早八点提醒我');
    final result = await submit(original);
    expect(result.task['reminder_text'], isNull);
    expect(result.task['state'], 'waiting');
    expect(result.task['wait_reason'], 'text_missing');
    expect(result.task['epoch_ms'], isNull);
    expect(calls.where((call) => call.method == 'resolve' || call.method == 'wake'), isEmpty);
    expect(store.messages().single['text'], '明早八点提醒我');
  });

  test('D native wake acknowledgement alone does not confirm a reminder', () async {
    final original = await source('one', _raw);
    final result = await submit(original);
    expect(result.task['state'], 'queued');
    expect(store.taskReceipts(result.task['task_id']! as String), isEmpty);
    expect(calls.singleWhere((call) => call.method == 'resolve').arguments, {
      'localDate': '2026-03-08',
      'localTime': '03:10',
      'zoneId': 'America/Los_Angeles',
    });
    expect(result.task['epoch_ms'], 1772964600000);
    expect(result.task['source_offset_seconds'], -28800);
    expect(result.task['offset_seconds'], -25200);
    expect(result.executorId, 'installation-A');
    final beforeResolve = calls.where((call) => call.method == 'resolve').length;
    final replay = await submit(original);
    expect(replay.task['task_id'], result.task['task_id']);
    expect(replay.task['task_rev'], 1);
    expect(calls.where((call) => call.method == 'resolve'), hasLength(beforeResolve));
    expect(store.tasks(), hasLength(1));
  });

  test('D unresolved amendment and integer cancellation wake the same existing task', () async {
    final created = (await submit(await source('create', _raw))).task;
    registered(created);
    resolution = {'kind': 'gap', 'moments': <Object?>[]};
    final changed = (await submit(
      await source('amend', '把带钥匙的提醒改到2026-03-08 02:30 America/Los_Angeles'),
      previous: store.task(created['task_id']! as String),
    )).task;
    expect(changed['task_id'], created['task_id']);
    expect(changed['task_rev'], 2);
    expect(changed['state'], 'waiting');
    expect(changed['wait_reason'], 'time_gap');
    expect(changed['epoch_ms'], isNull);
    expect(changed['cancel_requested'], 0);
    expect(
      calls.where((call) => call.method == 'wake'),
      hasLength(2),
      reason: 'the missing new instant does not remove the need to stop an older registration',
    );
    final cancelled = (await submit(await source('cancel', '取消带钥匙的提醒'), previous: changed)).task;
    expect(cancelled['task_rev'], 3);
    expect(cancelled['cancel_requested'], 1);
    expect(cancelled['state'], 'queued');
    expect(cancelled['epoch_ms'], isNull);
    final wakes = calls.where((call) => call.method == 'wake');
    expect(wakes, hasLength(3));
    expect(wakes.map((call) => (call.arguments as Map)['taskId']), everyElement(created['task_id']));
    expect(
      reminders.target(store, store.lightSessionId, (operation: 'cancel', text: null, when: null, target: '带钥匙')),
      isNull,
    );
    expect(store.taskReceipts(created['task_id']! as String), hasLength(2));
  });

  test('D a restored agreement cannot be amended or adopted by a new executor', () async {
    final original = await source('create', _raw);
    final created = (await submit(original)).task;
    registered(created);
    final saved = store.task(created['task_id']! as String)!;
    final receipts = store.taskReceipts(created['task_id']! as String);
    executor = 'installation-B';
    calls.clear();
    await expectLater(
      submit(await source('amend', '改到四点'), previous: saved),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'reminder_executor_changed')),
    );
    expect(store.task(created['task_id']! as String), saved);
    expect(store.taskReceipts(created['task_id']! as String), receipts);
    final replay = await submit(original);
    expect(replay.task, saved);
    expect(replay.executorId, 'installation-B');
    expect(calls.where((call) => call.method == 'wake' || call.method == 'resolve'), isEmpty);
  });

  test('D mixed reminder clauses retain the independent original for extraction', () async {
    final raw = '$_raw；我现在咖啡喝无糖';
    final original = await source('mixed', raw);
    final parts = parseCompanionReminders(raw);
    expect(parts, hasLength(2));
    expect(parts.first.itemNo, 0);
    expect(parts.last.itemNo, 1);
    expect(parts.last.command, isNull);
    await reminders.submit(store: store, source: original, part: parts.first, roomMode: 'light', isCurrent: () => true);
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    expect(batch.sources.single['id'], 'mixed');
    expect(batch.sources.single['text'], raw);
    expect(store.tasks(), hasLength(1));
  });

  for (final missing in [false, true]) {
    testWidgets(
      'D ${missing ? 'unavailable executor' : 'restored executor'} shows history without claiming a current registration',
      (tester) async {
        final created = (await submit(await source('create', _raw))).task;
        registered(created);
        final task = store.task(created['task_id']! as String)!;
        final receipts = store.taskReceipts(created['task_id']! as String);
        executor = 'installation-B';
        unavailable = missing;
        calls.clear();
        owner = CompanionMemoryOwner(store, CompanionLocal.at(root));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildDarkTheme(),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              locale: const Locale('zh'),
              home: CompanionTasksPage(memory: owner, taskId: created['task_id']! as String),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(missing ? '现在看不到手机上的提醒，等会儿再看看？' : '这条不是在这台手机上设的，我在这儿改不了也撤不了。'), findsOneWidget);
        expect(find.text('之前是设好过的。'), findsOneWidget);
        expect(find.text('设好了，到点我叫你。'), findsNothing);
        expect(find.byType(OutlinedButton), findsNothing);
        await tester.tap(find.byIcon(AppIcons.refresh));
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.method == 'wake'), isEmpty);
        expect(store.task(created['task_id']! as String), task);
        expect(store.taskReceipts(created['task_id']! as String), receipts);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('D a real integer cancellation row shows its unknown stop and offers no amendment', (tester) async {
    final created = (await submit(await source('create', _raw))).task;
    registered(created);
    final stopped = (await submit(await source('cancel', '取消带钥匙的提醒'), previous: created)).task;
    db.execute(
      '''
      INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,executor_id,occurred_at_ms)
      VALUES(?,?,'alarm.cancel:1','cancel-fixture','claimed','installation-A',1772877000000)
    ''',
      [stopped['task_id'], stopped['task_rev']],
    );
    db.execute("UPDATE companion_task_revisions SET state='unknown' WHERE task_id=? AND task_rev=?", [
      stopped['task_id'],
      stopped['task_rev'],
    ]);
    expect(store.task(stopped['task_id']! as String)!['cancel_requested'], 1);
    owner = CompanionMemoryOwner(store, CompanionLocal.at(root));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionTasksPage(memory: owner, taskId: stopped['task_id']! as String),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我在撤了，但不太确定撤干净没；要是到点还响，别理它就好。'), findsOneWidget);
    expect(find.text('这条提醒我不太确定设上没，你看一眼系统闹钟？'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final scenario in [
    'old_unknown_new_returned',
    'old_opened_new_unknown',
    'old_skipped',
    'old_active_observed',
    'old_unknown_new_active_observed',
    'old_failed_unknown',
  ]) {
    testWidgets('D notification receipt display keeps revision and claim evidence separate: $scenario', (tester) async {
      final first = (await submit(await source('first', _raw))).task;
      registered(first);
      clock = {..._clock, 'utcMs': 1772964600000, 'offsetSeconds': -25200};

      void receipt(MemoryRow task, String attempt, String event, {String? outcome}) {
        final effect = 'dsh-reminder:${task['task_id']}:${task['task_rev']}';
        if (event == 'claimed') {
          db.execute(
            '''
            UPDATE companion_task_revisions SET notification_claim_id=?,notification_claimed_at_ms=?
            WHERE task_id=? AND task_rev=?
          ''',
            [attempt, clock['utcMs'], task['task_id'], task['task_rev']],
          );
        }
        db.execute(
          '''
          INSERT INTO companion_task_receipts(task_id,task_rev,step_key,attempt_id,event_kind,
            executor_id,occurred_at_ms,effect_id,outcome)
          VALUES(?,?,'notification',?,?,?, ?,?,?)
        ''',
          [task['task_id'], task['task_rev'], attempt, event, task['executor_id'], clock['utcMs'], effect, outcome],
        );
      }

      receipt(first, 'claim-old', 'claimed');
      if (scenario == 'old_opened_new_unknown') {
        receipt(first, 'claim-old', 'opened');
      } else if (scenario == 'old_active_observed') {
        // Native active_observed has a distinct observation UUID, not claim-old.
        receipt(first, 'observation-old', 'active_observed');
      } else if (scenario == 'old_failed_unknown') {
        receipt(first, 'claim-old', 'failed', outcome: 'unknown');
      }
      clock = {...clock, 'utcMs': 1772964601000};
      resolution = {
        'kind': 'unique',
        'moments': [
          {'epochMs': 1772964900000, 'offsetSeconds': -25200},
        ],
      };
      final changed = (await submit(
        await source('amend', '把带钥匙的提醒改到2026-03-08 03:15 America/Los_Angeles'),
        previous: first,
      )).task;
      expect(changed['task_rev'], 2);
      registered(changed);
      if (scenario == 'old_skipped') {
        // The final native check observed the revision change before notify.
        receipt(first, 'claim-old', 'skipped', outcome: 'not_performed');
      }
      if (scenario == 'old_unknown_new_returned' ||
          scenario == 'old_opened_new_unknown' ||
          scenario == 'old_unknown_new_active_observed') {
        clock = {...clock, 'utcMs': 1772964900000};
        receipt(changed, 'claim-new', 'claimed');
        if (scenario == 'old_unknown_new_returned') {
          receipt(changed, 'claim-new', 'returned', outcome: 'succeeded');
        } else if (scenario == 'old_unknown_new_active_observed') {
          receipt(changed, 'observation-new', 'active_observed');
        }
      }
      final before = store.taskReceipts(first['task_id']! as String);
      owner = CompanionMemoryOwner(store, CompanionLocal.at(root));
      calls.clear();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildDarkTheme(),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: const Locale('zh'),
            home: CompanionTasksPage(memory: owner, taskId: first['task_id']! as String),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = L10n.of(tester.element(find.byType(CompanionTasksPage)));
      expect(
        find.text(l10n.companionReminderUnknownNotification),
        scenario == 'old_skipped' || scenario == 'old_active_observed' ? findsNothing : findsOneWidget,
      );
      expect(store.taskReceipts(first['task_id']! as String), before);
      expect(calls.where((call) => call.method == 'wake' || call.method == 'resolve'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('D actual notification entry opens its original task and keeps a later revision without dispatch', (
    tester,
  ) async {
    final first = (await submit(await source('first', _raw))).task;
    registered(first);
    final changed = (await submit(
      await source('amend', '把带钥匙的提醒改到2026-03-08 03:10 America/Los_Angeles'),
      previous: first,
    )).task;
    await submit(await source('other', _raw.replaceFirst('带钥匙', '带书')));
    final before = store.tasks();
    final receipts = store.taskReceipts(first['task_id']! as String);
    owner = CompanionMemoryOwner(store, CompanionLocal.at(root));
    calls.clear();
    const entries = MethodChannel('dsh/shortcuts');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(entries, (_) async => true);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (call) async {
      expect(call.method, 'getApplicationSupportDirectory');
      return root.path;
    });
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(entries, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    });
    const keptHost = HostRef.ssh('current-unrelated-host');
    SharedPreferences.setMockInitialValues({ActiveHostController.prefsKey: keptHost.encode()});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
          companionMemoryOwnerProvider('${root.path}/companion').overrideWith((ref) => owner!),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: const Scaffold(body: SystemEntryHost()),
        ),
      ),
    );
    await tester.pump();
    final scope = ProviderScope.containerOf(tester.element(find.byType(SystemEntryHost)));
    await settleMixed(tester, scope.read(activeHostProvider.notifier).ready);
    expect(scope.read(activeHostProvider), keptHost);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      entries.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('entry', {'kind': 'companion_task', 'taskId': first['task_id'], 'taskRev': 1}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.byType(CompanionTasksPage), findsOneWidget);
    final page = tester.widget<CompanionTasksPage>(find.byType(CompanionTasksPage));
    expect(page.taskId, first['task_id']);
    expect(page.openedRevision, 1);
    expect(find.text('带钥匙'), findsOneWidget);
    expect(find.text('带书'), findsNothing);
    final l10n = L10n.of(tester.element(find.byType(CompanionTasksPage)));
    expect(find.text(l10n.companionTaskChanged), findsOneWidget);
    expect(changed['task_rev'], 2);
    expect(store.tasks(), before);
    expect(store.taskReceipts(first['task_id']! as String), receipts);
    expect(calls.where((call) => call.method == 'wake' || call.method == 'resolve'), isEmpty);
    expect(scope.read(activeHostProvider), keptHost);
    await tester.pumpWidget(const SizedBox());
  });
}
