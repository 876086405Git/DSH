// Signals in her room (Pro C902): another conversation's end reaches her only
// through the gate and the invitation owner, as a local line; nothing when the
// person said no. The consents themselves: defaults and what is kept.
//
// The host is the SDK's loopback signal host (real HTTP, real mux), the alert
// tracker is the real one, and its deliveries go on the real pet event bus.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_signal_consent.dart';
import 'package:dsh_app/companion/companion_signals.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/companion_signal_host.dart';
import 'initiative_memory.dart';

const _done = '你那边的任务跑完啦。';

class _Loopback extends HttpOverrides {}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Source extends DshAlertSource {
  _Source(super.client);
  String reason = 'completed';
  int seq = 10;
  @override
  Future<List<SessionSummary>> listSessions() async => [
    SessionSummary.fromJson({
      'sessionId': 's-photos',
      'running': false,
      'blank': false,
      'agentAvailable': true,
      'updatedAt': 1794090000000,
      'projections': {'title': '整理照片'},
    }),
  ];
  @override
  Future<TurnOutcome?> lastTurn(String sessionId) async => outcomeFromEvents([
    TurnEndedEvent(seq, DateTime.utc(2026, 11, 7), const {}, turn: 2, reason: TurnEndReason(reason)),
  ], title: '整理照片');
}

class _Room {
  _Room(this.tester, this.root);
  final WidgetTester tester;
  final Directory root;
  late CompanionSignalTestHost host;
  late DshClient client;
  late HostConnection connection;
  late _Source source;
  late HostAlertTracker tracker;
  late ProviderContainer container;
  late CompanionMemoryOwner memory;
  final deliveries = <CompanionAlertDelivery>[];
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;

  Future<void> open() async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // A phone reports this long before the room opens; an unknown state never permits a line.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // Widget tests answer every HTTP request with 400; this host is real, on loopback.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        host = await CompanionSignalTestHost.start();
        client = await host.connect();
        connection = HostConnection(client: client, isLocal: true);
        source = _Source(client);
        tracker = HostAlertTracker(
          host: HostRef.local,
          source: source,
          companionConnection: connection,
          isCompanionAttached: () => true,
          onCompanionSignal: deliveries.add,
          onAlert: (_) {},
          onWithdraw: (_, _, _) {},
          onSessionGone: (_, _) {},
          announceDelay: Duration.zero,
          reconcileDelay: const Duration(milliseconds: 1),
        )..start();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, _Loopback()),
    );
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    // Both clocks follow the test's fake time, in the afternoon.
    final start = tester.binding.clock.now();
    CompanionInitiativeClock clock() {
      final ms = tester.binding.clock.now().difference(start).inMilliseconds;
      return CompanionInitiativeClock(wallMs: 1793899800000 + ms, monoMs: ms);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWithValue(AsyncData(connection)),
          companionInitiativeClockProvider.overrideWithValue(clock),
          initiativeMemory(clock),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
            stageBuilder: (_, next) {
              events = next;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await settle();
    }
    expect(events, isNotNull, reason: 'the stage was never built');
    container = ProviderScope.containerOf(tester.element(find.byType(CompanionPage)));
    memory = (await tester.runAsync(() => container.read(companionMemoryOwnerProvider(root.absolute.path).future)))!;
    events!.onReady();
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> wait(Duration time) async {
    for (var left = time; left > Duration.zero; left -= const Duration(seconds: 1)) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  /// How long until [finder] shows, a second at a time; null if it never does within [most].
  Future<Duration?> until(Finder finder, Duration most) async {
    for (var waited = Duration.zero; waited <= most; waited += const Duration(seconds: 1)) {
      if (finder.evaluate().isNotEmpty) return waited;
      await tester.pump(const Duration(seconds: 1));
    }
    return null;
  }

  /// Another conversation on this host runs and ends; the tracker's
  /// delivery goes on the bus the way the alerts controller hands it over,
  /// and right after it the alert itself (which brings the pill).
  Future<void> otherConversationEnds({String reason = 'completed'}) async {
    source
      ..reason = reason
      ..seq += 1;
    final before = deliveries.length;
    await tester.runAsync(() async {
      await host.proof(client, session: 's-photos', running: true);
      await host.proof(client, session: 's-photos', running: false);
      for (var i = 0; i < 50 && deliveries.length == before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(deliveries, hasLength(before + 1), reason: 'the tracker published no signal');
    final bus = container.read(petEventBusProvider)..companionSignal(deliveries.last);
    bus.add(
      PetEvent(
        kind: reason == 'completed' ? PetEventKind.done : PetEventKind.failed,
        host: HostRef.local,
        sessionId: 's-photos',
        key: 'turn',
        at: DateTime.now(),
        title: '整理照片',
      ),
    );
    await tester.pump();
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() async {
      await tracker.dispose();
      await host.close();
    });
  }
}

void main() {
  AppLocale.use(AppLocale.zhCN);
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-signal-room');
    SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  group('consents', () {
    test('today stays as it was: she keeps track and may say a line; voice and night care wait for a yes', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(companionSignalConsentProvider), isNull, reason: 'unread lets nothing in');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final consent = container.read(companionSignalConsentProvider)!;
      expect([consent.state, consent.optionalSpeech, consent.voice, consent.nightCare], [true, true, false, false]);
    });

    test('a change is kept and read back', () async {
      final first = ProviderContainer();
      first.read(companionSignalConsentProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await first
          .read(companionSignalConsentProvider.notifier)
          .set(const CompanionSignalConsent(state: true, optionalSpeech: false, voice: false, nightCare: true));
      first.dispose();
      final saved = jsonDecode((await SharedPreferences.getInstance()).getString('companion_signal_consent')!);
      expect(saved, {'state': true, 'optionalSpeech': false, 'voice': false, 'nightCare': true});

      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(companionSignalConsentProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final consent = second.read(companionSignalConsentProvider)!;
      expect([consent.state, consent.optionalSpeech, consent.voice, consent.nightCare], [true, false, false, true]);
    });

    testWidgets('她会提起什么 in her menu: the four switches, each needing the one above', (tester) async {
      final room = _Room(tester, root);
      await room.open();
      try {
        await room.wait(const Duration(seconds: 8));
        await tester.tap(find.byIcon(AppIcons.more));
        await tester.pumpAndSettle();
        await tester.tap(find.text('她会提起什么'));
        await tester.pumpAndSettle();
        Switch row(String title) => tester.widget<Switch>(
          find.descendant(
            of: find.ancestor(of: find.text(title), matching: find.byType(MergeSemantics)).first,
            matching: find.byType(Switch),
          ),
        );
        expect(find.textContaining('不会发给模型'), findsOneWidget);
        expect(row('留意别的对话').value, isTrue);
        expect(row('提一句').value, isTrue);
        expect(row('用声音说出来').value, isFalse);
        expect(row('深夜提醒你休息').value, isFalse);

        await tester.tap(find.text('留意别的对话'));
        await tester.pumpAndSettle();
        expect(row('留意别的对话').value, isFalse);
        expect(row('提一句').onChanged, isNull);
        expect(row('用声音说出来').onChanged, isNull);
        expect(room.container.read(companionSignalConsentProvider)!.state, isFalse);
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
      } finally {
        await room.close();
      }
    });
  });

  testWidgets('她多主动 in her menu: quiet or one of three paces, quiet being the old switch off', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    try {
      await room.wait(const Duration(seconds: 8));
      Future<void> pick(String choice) async {
        await tester.tap(find.byIcon(AppIcons.more));
        await tester.pumpAndSettle();
        expect(find.text('她多主动'), findsOneWidget);
        await tester.tap(find.text('她多主动'));
        await tester.pumpAndSettle();
        expect(find.text('一天最多 6 次，至少隔 2 小时'), findsOneWidget);
        await tester.tap(find.text(choice));
        await tester.pumpAndSettle();
      }

      await pick('常常');
      expect(room.container.read(companionInitiativePaceProvider), CompanionInitiativePace.often);
      expect(room.container.read(companionInitiativeEnabledProvider), isTrue);
      await pick('安静');
      expect(room.container.read(companionInitiativeEnabledProvider), isFalse);
      expect(room.container.read(companionInitiativePaceProvider), CompanionInitiativePace.often);
      await pick('话多');
      expect(room.container.read(companionInitiativeEnabledProvider), isTrue);
      expect(room.container.read(companionInitiativePaceProvider), CompanionInitiativePace.chatty);
    } finally {
      await room.close();
    }
  });

  testWidgets('another conversation ends: she holds it until you have been quiet, then says it once', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    try {
      // A touch first: this visit then has no invitation, which would share the allowance.
      room.events!.onTouch('head', 'pat');
      await room.wait(const Duration(seconds: 6));
      room.commands.clear();
      await room.otherConversationEnds();
      await tester.pump(const Duration(milliseconds: 300));
      // Not quiet long enough yet: nothing said; the pill is there at once and
      // does not drop what she is holding.
      expect(find.text(_done), findsNothing);
      expect(find.text('去看看 · 整理照片'), findsOneWidget);
      final heldFor = await room.until(find.text(_done), const Duration(seconds: 70));
      expect(heldFor, greaterThan(const Duration(seconds: 35)));
      expect(room.commands.where((c) => c.$1 == 'emotion').single.$2['name'], 'happy');
      // Her voice was not allowed for it: her mouth keeps the text's rhythm.
      expect(room.commands.where((c) => c.$1 == 'say'), isNotEmpty);
      final ledger = room.memory.store.initiativeRecord()!;
      expect(ledger['signalAtMs'], hasLength(1));

      // The allowance is shared and spent: the next one is not said.
      await room.wait(const Duration(seconds: 10));
      await room.otherConversationEnds(reason: 'error');
      expect(await room.until(find.textContaining('出错了'), const Duration(seconds: 70)), isNull);
    } finally {
      await room.close();
    }
  });

  testWidgets('keeping track switched off: the same end gets no line', (tester) async {
    SharedPreferences.setMockInitialValues({
      'companion_touch_hint_done': true,
      'companion_home_hint_done': true,
      'companion_signal_consent': jsonEncode({
        'state': false,
        'optionalSpeech': true,
        'voice': false,
        'nightCare': false,
      }),
    });
    final room = _Room(tester, root);
    await room.open();
    try {
      room.events!.onTouch('head', 'pat');
      await room.wait(const Duration(seconds: 56));
      await room.otherConversationEnds();
      expect(await room.until(find.text(_done), const Duration(seconds: 70)), isNull);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
    } finally {
      await room.close();
    }
  });
}
