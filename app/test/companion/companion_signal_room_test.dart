// Signals in her room (Pro C902): another conversation's end reaches her only
// through the gate and the invitation owner, then the shared Agent decides
// whether to say a line; nothing when the person said no. The consents
// themselves: defaults and what is kept.
//
// The host is the SDK's loopback signal host (real HTTP, real mux), the alert
// tracker is the real one, and its deliveries go on the real pet event bus.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/companion/companion_signal_consent.dart';
import 'package:dsh_app/companion/companion_signals.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/companion_agent_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/companion_signal_host.dart';
import 'initiative_memory.dart';

const _done = '你那边的任务跑完啦。';

http.Response _signalReply(Map<String, Object?> decision) {
  final events = <Map<String, Object?>>[
    {
      'type': 'message_start',
      'message': {
        'id': 'controlled-signal-message',
        'role': 'assistant',
        'content': <Object?>[],
        'usage': {'input_tokens': 12, 'output_tokens': 0},
      },
    },
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': jsonEncode(decision)},
    },
    {'type': 'content_block_stop', 'index': 0},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
      'usage': {'input_tokens': 12, 'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0, 'output_tokens': 8},
    },
    {'type': 'message_stop'},
  ];
  return http.Response.bytes(
    utf8.encode([for (final event in events) 'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n'].join()),
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );
}

Map _context(Map<String, Object?> request) {
  final texts = <String>[
    for (final message in (request['messages']! as List).cast<Map>())
      if (message['role'] == 'user' && message['content'] is List)
        for (final block in (message['content']! as List).cast<Map>())
          if (block['type'] == 'text') block['text']! as String,
  ];
  final text = texts.singleWhere((text) => text.startsWith('<companion_context>'));
  return jsonDecode(text.substring('<companion_context>'.length, text.length - '</companion_context>'.length)) as Map;
}

class _ModelSettings extends SettingsController {
  @override
  AppSettings build() => AppSettings(loaded: true, apiKey: 'controlled-test-key');
}

class _ObservedModelClient extends MockClient {
  _ObservedModelClient(Future<http.Response> Function(http.Request) respond) : super(respond);
  var closeCalls = 0;

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

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
  _Room(this.tester, this.root, {this.modelClient});
  final WidgetTester tester;
  final Directory root;
  final http.Client? modelClient;
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
          if (modelClient != null) ...[
            settingsProvider.overrideWith(_ModelSettings.new),
            companionLightClientProvider.overrideWithValue(() => modelClient!),
          ],
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

  // Model preparation also awaits real local I/O. Reuse the existing mixed
  // settle, and measure the fake clock instead of rushing through the TTL.
  Future<Duration?> untilReady(bool Function() ready, Duration most) async {
    final started = tester.binding.clock.now();
    while (tester.binding.clock.now().difference(started) <= most) {
      if (ready()) return tester.binding.clock.now().difference(started);
      await settle();
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
    const modelLine = '这边告一段落啦，等你有空再看。';
    final posts = <Map<String, Object?>>[];
    final release = Completer<void>();
    final model = MockClient((request) async {
      posts.add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
      if (posts.length == 1) return _signalReply({'action': 'silent'});
      if (posts.length == 2) {
        await release.future;
        return _signalReply({'action': 'line', 'text': modelLine});
      }
      return http.Response('Unexpected extra model request', 503);
    });
    addTearDown(model.close);
    final room = _Room(tester, root, modelClient: model);
    await room.open();
    try {
      // A touch first: this visit then has no invitation, which would share the allowance.
      room.events!.onTouch('head', 'pat');
      await room.wait(const Duration(seconds: 6));
      room.commands.clear();
      final agent = room.container.read(companionAgentProvider);
      final pageUi = tester.state(find.byType(CompanionPage)) as CompanionAgentRoomUi;
      final history = room.memory.store.messages();
      expect(posts, isEmpty);
      expect(room.memory.store.requests(), isEmpty);
      await room.otherConversationEnds();
      await tester.pump(const Duration(milliseconds: 300));
      // Not quiet long enough yet: nothing said; the pill is there at once and
      // does not drop what she is holding.
      expect(find.text(_done), findsNothing);
      expect(find.text('去看看 · 整理照片'), findsOneWidget);
      expect(posts, isEmpty);
      // Quiet gates the actual preparation now; this first model decision is
      // silence, so a template appearing cannot satisfy the waiting oracle.
      final heldFor = await room.untilReady(() => posts.isNotEmpty, const Duration(seconds: 70));
      expect(heldFor, greaterThan(const Duration(seconds: 35)));
      expect(await room.untilReady(
        () => !agent.running && room.memory.store.requests().every((row) => row['state'] == 'finished'),
        const Duration(seconds: 5),
      ), isNotNull);
      expect(posts, hasLength(1));
      final silent = room.memory.store.requests().single;
      expect(silent['terminal'], 'complete');
      expect(silent['sent_at_ms'], isNotNull);
      expect(silent['input_uncached'], 12);
      expect(silent['output_tokens'], 8);
      expect(silent['raw_usage'], isNotNull);
      expect(find.text(_done), findsNothing);
      expect(find.text(modelLine), findsNothing);
      expect(room.commands.where((c) => c.$1 == 'say'), isEmpty);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);

      // A distinct live sequence may prepare a line; silence did not spend
      // the shared display allowance. The real Page remains the recipient.
      await room.otherConversationEnds();
      expect(await room.untilReady(() => posts.length == 2, const Duration(seconds: 70)), isNotNull);
      expect(agent.running, isTrue);
      expect(pageUi.initiativeView.blocked, isFalse);
      room.container.read(companionInitiativeProvider).observe(pageUi.initiativeRoom, pageUi.initiativeView);
      await tester.pump();
      await tester.pump();
      expect(agent.running, isTrue, reason: 'its own preparation must survive a same-view observation');
      expect(posts, hasLength(2));
      expect(room.memory.store.requests().where((row) => row['id'] != silent['id']).single['terminal'], isNull);
      expect(find.text(modelLine), findsNothing);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      release.complete();
      expect(await room.untilReady(() => find.text(modelLine).evaluate().isNotEmpty, const Duration(seconds: 5)), isNotNull);
      expect(find.text(modelLine), findsOneWidget);
      expect(find.text(_done), findsNothing, reason: 'the Agent line, not the old fixed template, is presented');
      expect(agent.running, isFalse);
      expect(room.commands.where((c) => c.$1 == 'emotion').single.$2['name'], 'happy');
      // Her voice was not allowed for it: her mouth keeps the text's rhythm.
      expect(room.commands.where((c) => c.$1 == 'say'), isNotEmpty);
      final ledger = room.memory.store.initiativeRecord()!;
      expect(ledger['signalAtMs'], hasLength(1));
      final lineReceipt = room.memory.store.requests().singleWhere((row) => row['id'] != silent['id']);
      expect(lineReceipt['state'], 'finished');
      expect(lineReceipt['terminal'], 'complete');
      expect(lineReceipt['sent_at_ms'], isNotNull);
      expect(lineReceipt['input_uncached'], 12);
      expect(lineReceipt['output_tokens'], 8);
      for (final body in posts) {
        expect(body.containsKey('tools'), isFalse);
        expect(body['max_tokens'], 800);
        expect(_context(body)['window'], 'room');
        expect(_context(body)['taskObservation'], {'kind': 'task.terminal', 'phase': 'completed'});
        expect(jsonEncode(body), isNot(contains('s-photos')));
        expect(jsonEncode(body), isNot(contains('整理照片')));
      }
      expect(room.memory.store.messages(), history);
      expect(agent.sourceId, isNull);
      expect(agent.replyId, isNull);
      expect(agent.text, isEmpty);
      expect(room.memory.store.tasks(), isEmpty);

      // The allowance is shared and spent: the next one is not said.
      await room.wait(const Duration(seconds: 10));
      await room.otherConversationEnds(reason: 'error');
      expect(await room.until(find.textContaining('出错了'), const Duration(seconds: 70)), isNull);
      expect(posts, hasLength(2));
      expect(room.memory.store.requests(), hasLength(2));
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], hasLength(1));
    } finally {
      if (!release.isCompleted) release.complete();
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
    const lateLine = '迟到的任务提示不该出现在这里。';
    final posts = <Map<String, Object?>>[];
    final release = Completer<void>();
    final model = _ObservedModelClient((request) async {
      posts.add(Map<String, Object?>.from(jsonDecode(request.body) as Map));
      if (posts.length != 1) return http.Response('Unexpected extra model request', 503);
      await release.future;
      return _signalReply({'action': 'line', 'text': lateLine});
    });
    addTearDown(model.close);
    final room = _Room(tester, root, modelClient: model);
    await room.open();
    try {
      room.events!.onTouch('head', 'pat');
      await room.wait(const Duration(seconds: 56));
      await room.otherConversationEnds();
      expect(await room.until(find.text(_done), const Duration(seconds: 70)), isNull);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(posts, isEmpty);
      expect(room.memory.store.requests(), isEmpty);

      // Keep the original denial above, then change the actual public consent.
      // A fresh live event starts a model request through this same Page.
      final agent = room.container.read(companionAgentProvider);
      final pageUi = tester.state(find.byType(CompanionPage)) as CompanionAgentRoomUi;
      final history = room.memory.store.messages();
      final consent = room.container.read(companionSignalConsentProvider.notifier);
      await consent.set(const CompanionSignalConsent(state: true, optionalSpeech: true, voice: false, nightCare: false));
      await room.settle();
      room.commands.clear();
      await room.otherConversationEnds();
      expect(await room.untilReady(() => posts.isNotEmpty, const Duration(seconds: 70)), isNotNull);
      expect(posts, hasLength(1));
      final pendingReceipt = room.memory.store.requests().single;
      expect(pendingReceipt['sent_at_ms'], isNotNull);
      expect(pendingReceipt['terminal'], isNull);
      expect(agent.running, isTrue);
      expect(pageUi.initiativeView.blocked, isFalse);
      expect(_context(posts.single)['window'], 'room');
      expect(_context(posts.single)['taskObservation'], {'kind': 'task.terminal', 'phase': 'completed'});
      expect(posts.single.containsKey('tools'), isFalse);
      expect(jsonEncode(posts.single), isNot(contains('s-photos')));
      expect(jsonEncode(posts.single), isNot(contains('整理照片')));

      // The Page's consent listener invalidates its real gate and observes the
      // changed room. Closing MockClient need not interrupt a held handler:
      // physical settlement is checked only after that old response is released.
      final closesBeforeRevoke = model.closeCalls;
      expect(closesBeforeRevoke, 0);
      await consent.set(const CompanionSignalConsent(state: false, optionalSpeech: true, voice: false, nightCare: false));
      await tester.pump();
      await tester.pump();
      expect(room.container.read(companionSignalConsentProvider)!.state, isFalse);
      expect(model.closeCalls, greaterThan(closesBeforeRevoke));
      expect(find.text(lateLine), findsNothing);
      expect(find.text(_done), findsNothing);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      release.complete();
      expect(await room.untilReady(
        () => !agent.running && room.memory.store.requests().every((row) => row['state'] == 'finished'),
        const Duration(seconds: 5),
      ), isNotNull);
      final cancelled = room.memory.store.requests().single;
      expect(cancelled['id'], pendingReceipt['id']);
      expect(cancelled['state'], 'finished');
      expect(cancelled['terminal'], 'cancelled');
      expect(cancelled['sent_at_ms'], pendingReceipt['sent_at_ms']);
      expect(agent.running, isFalse);
      expect(pageUi.initiativeView.visible, isTrue);
      expect(pageUi.initiativeView.resumed, isTrue);
      expect(pageUi.initiativeView.blocked, isFalse);
      expect(find.text(lateLine), findsNothing);
      expect(find.text(_done), findsNothing);
      expect(room.commands.where((c) => c.$1 == 'say'), isEmpty);
      expect(room.memory.store.initiativeRecord()!['signalAtMs'], isEmpty);
      expect(posts, hasLength(1));
      expect(room.memory.store.messages(), history);
      expect(agent.sourceId, isNull);
      expect(agent.replyId, isNull);
      expect(agent.text, isEmpty);
      expect(room.memory.store.tasks(), isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await room.close();
    }
  });
}
