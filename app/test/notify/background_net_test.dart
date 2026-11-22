// The quiet line about background running (lib/runtime/background_net.dart,
// lib/ui/notify/background_net_host.dart): when it shows, how often, where it
// sits, and what its two taps do.
//
//   flutter test --update-goldens test/notify/background_net_test.dart

import 'dart:async';

import 'package:dsh_app/runtime/background_net.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/notify/background_net_host.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' as shell;
import 'support.dart';

class _Bridge extends RuntimeBridge {
  bool? exempt = false;
  String? vendor = 'vivo';

  @override
  Future<bool?> batteryExempt() async => exempt;

  @override
  Future<BackgroundSettingsInfo?> backgroundSettings() async => BackgroundSettingsInfo(vendor: vendor, label: 'DSH');

  @override
  Future<String?> openBackgroundSettings() async => 'vendor';
}

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() =>
      const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.running));

  /// What DshService reports once Android blocks the app's network.
  void block() => state = state.copyWith(
    status: RuntimeStatus(phase: RuntimePhase.running, networkBlocked: true, networkBlockedAt: DateTime.now()),
  );
}

class _Fixed extends BackgroundNetController {
  _Fixed(this.initial);

  final BackgroundNetReason? initial;

  @override
  BackgroundNetReason? build() => initial;
}

LlmRetryEvent _retry(int seq, DateTime at, String code) => LlmRetryEvent(
  seq,
  at,
  const {},
  turn: 1,
  step: 1,
  retry: 1,
  delayMs: 1000,
  failure: LlmFailure(message: 'DeepSeek Messages transport failed', code: code),
);

void main() {
  group('policy', () {
    final since = DateTime(2026, 10, 25, 10);
    const none = <BackgroundNetReason, int>{};

    test('says something only when not exempt', () {
      for (final exempt in [true, null]) {
        expect(BackgroundNetPolicy.onReturn(since: since, exempt: exempt, shown: none, blockedAt: since), isNull);
      }
      expect(
        BackgroundNetPolicy.onReturn(since: since, exempt: false, shown: none, blockedAt: since),
        BackgroundNetReason.blocked,
      );
    });

    test('a block from before the app left is not news; failures count on their own', () {
      final before = since.subtract(const Duration(seconds: 1));
      expect(BackgroundNetPolicy.onReturn(since: since, exempt: false, shown: none, blockedAt: before), isNull);
      expect(
        BackgroundNetPolicy.onReturn(
          since: since,
          exempt: false,
          shown: none,
          blockedAt: before,
          transportFailed: () => true,
        ),
        BackgroundNetReason.failures,
      );
    });

    test('reads the conversation only when transport evidence can decide the reason', () {
      var reads = 0;
      BackgroundNetReason? reason(bool? exempt, {DateTime? blockedAt}) => BackgroundNetPolicy.onReturn(
        since: since,
        exempt: exempt,
        shown: none,
        blockedAt: blockedAt,
        transportFailed: () {
          reads++;
          return true;
        },
      );
      expect(reason(true), isNull);
      expect(reason(null), isNull);
      expect(reason(false, blockedAt: since), BackgroundNetReason.blocked);
      expect(reads, 0);
      expect(reason(false), BackgroundNetReason.failures);
      expect(reads, 1);
    });

    test('each reason at most twice', () {
      const twice = {BackgroundNetReason.blocked: 2};
      expect(BackgroundNetPolicy.onReturn(since: since, exempt: false, shown: twice, blockedAt: since), isNull);
      // Another reason still has its own two.
      expect(
        BackgroundNetPolicy.onReturn(since: since, exempt: false, shown: twice, transportFailed: () => true),
        BackgroundNetReason.failures,
      );
    });

    test('transport retries inside the background window', () {
      final events = <SessionLogEvent>[
        _retry(1, since.subtract(const Duration(minutes: 1)), 'TRANSPORT'),
        UnknownEvent(2, since.add(const Duration(seconds: 5)), 'system/message', const {}),
        _retry(3, since.add(const Duration(seconds: 9)), 'RATE_LIMIT'),
      ];
      final until = since.add(const Duration(minutes: 1));
      expect(BackgroundNetPolicy.transportFailedIn(events, since, until), isFalse);
      events.add(_retry(4, since.add(const Duration(seconds: 20)), 'TRANSPORT'));
      expect(BackgroundNetPolicy.transportFailedIn(events, since, until), isTrue);
      // After the app came back: a foreground failure is not ours to explain.
      expect(BackgroundNetPolicy.transportFailedIn(events, since, since.add(const Duration(seconds: 10))), isFalse);
    });

    test('intro only on strict makers, not exempt, nothing shown yet', () {
      bool due({
        bool introduced = false,
        String? vendor = 'vivo',
        bool? exempt = false,
        Map<BackgroundNetReason, int> shown = none,
      }) => BackgroundNetPolicy.introDue(introduced: introduced, vendor: vendor, exempt: exempt, shown: shown);
      expect(due(), isTrue);
      expect(due(vendor: 'xiaomi'), isTrue);
      expect(due(vendor: 'samsung'), isFalse);
      expect(due(vendor: null), isFalse);
      expect(due(exempt: true), isFalse);
      expect(due(introduced: true), isFalse);
      expect(due(shown: {BackgroundNetReason.failures: 1}), isFalse);
    });
  });

  group('controller', () {
    late _Bridge bridge;
    late StreamController<HostEvent> events;

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          runtimeBridgeProvider.overrideWithValue(bridge),
          localRuntimeProvider.overrideWith(_Runtime.new),
          localHostEventsProvider.overrideWithValue(events.stream),
          activeConnectionProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(backgroundNetProvider, (_, _) {});
      return c;
    }

    /// Home, the engine's network cut meanwhile, back.
    Future<BackgroundNetReason?> leaveBlockedAndReturn(ProviderContainer c) async {
      final net = c.read(backgroundNetProvider.notifier);
      net.setVisible(false);
      (c.read(localRuntimeProvider.notifier) as _Runtime).block();
      net.setVisible(true);
      await settle();
      final shown = c.read(backgroundNetProvider);
      net.dismiss();
      return shown;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      bridge = _Bridge();
      events = StreamController<HostEvent>.broadcast(sync: true);
    });

    test('blocked in the background: the line twice, then quiet; kept across launches', () async {
      final c = container();
      await settle();
      expect(await leaveBlockedAndReturn(c), BackgroundNetReason.blocked);
      expect(await leaveBlockedAndReturn(c), BackgroundNetReason.blocked);
      expect(await leaveBlockedAndReturn(c), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('background_net.shown.blocked'), 2);
      // A new launch remembers.
      final again = container();
      await settle();
      expect(await leaveBlockedAndReturn(again), isNull);
    });

    test('a return without a block or failure says nothing', () async {
      final c = container();
      await settle();
      final net = c.read(backgroundNetProvider.notifier);
      net.setVisible(false);
      net.setVisible(true);
      await settle();
      expect(c.read(backgroundNetProvider), isNull);
    });

    test('exempt: nothing, and the count starts over for a later revoke', () async {
      SharedPreferences.setMockInitialValues({'background_net.shown.blocked': 2});
      bridge.exempt = true;
      final c = container();
      await settle();
      expect(await leaveBlockedAndReturn(c), isNull);
      expect((await SharedPreferences.getInstance()).getInt('background_net.shown.blocked'), 0);
      bridge.exempt = false;
      expect(await leaveBlockedAndReturn(c), BackgroundNetReason.blocked);
    });

    test('first finished turn on a strict maker: the intro, once', () async {
      final c = container();
      await settle();
      events
        ..add(const SessionStatusEvent('s1', true))
        ..add(const SessionStatusEvent('s1', false));
      await settle();
      expect(c.read(backgroundNetProvider), BackgroundNetReason.intro);
      c.read(backgroundNetProvider.notifier).dismiss();
      events
        ..add(const SessionStatusEvent('s1', true))
        ..add(const SessionStatusEvent('s1', false));
      await settle();
      expect(c.read(backgroundNetProvider), isNull);
      expect((await SharedPreferences.getInstance()).getBool('background_net.intro'), isTrue);
    });

    test('no intro on other makers', () async {
      bridge.vendor = 'samsung';
      final c = container();
      await settle();
      events
        ..add(const SessionStatusEvent('s1', true))
        ..add(const SessionStatusEvent('s1', false));
      await settle();
      expect(c.read(backgroundNetProvider), isNull);
    });

    test('no intro for a turn that ended while the app was away', () async {
      final c = container();
      await settle();
      final net = c.read(backgroundNetProvider.notifier);
      events.add(const SessionStatusEvent('s2', true));
      net.setVisible(false);
      events.add(const SessionStatusEvent('s2', false));
      await settle();
      expect(c.read(backgroundNetProvider), isNull);
    });
  });

  group('pill', () {
    Widget app(Widget child, {double textScale = 1}) => MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Center(child: child)),
      ),
    );

    for (final scale in [1.0, 1.3]) {
      testWidgets('glyph and action sit 12 from their ends, centred (text ×$scale)', (tester) async {
        await tester.pumpWidget(
          app(
            BackgroundNetPill(reason: BackgroundNetReason.blocked, onDismiss: () {}, onOpen: () {}),
            textScale: scale,
          ),
        );
        final pill = tester.getRect(find.byType(GlassSurface));
        final glyph = tester.getRect(find.byKey(const ValueKey('background-net-glyph')));
        final action = tester.getRect(find.byKey(const ValueKey('background-net-action')));
        final text = tester.getRect(find.text('后台联网被系统限制'));
        expect(glyph.left - pill.left, moreOrLessEquals(12, epsilon: 0.01));
        expect(pill.right - action.right, moreOrLessEquals(12, epsilon: 0.01));
        for (final part in [glyph, action, text]) {
          expect(part.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.5));
        }
        expect(pill.height, greaterThanOrEqualTo(BackgroundNetPill.minHeight));
        // One line: the label never wraps under the glyph.
        expect(text.height, lessThan(pill.height));
      });
    }

    testWidgets('a tap dismisses; 去放行 opens 后台保活', (tester) async {
      var dismissed = 0;
      var opened = 0;
      await tester.pumpWidget(
        app(
          BackgroundNetPill(reason: BackgroundNetReason.failures, onDismiss: () => dismissed++, onOpen: () => opened++),
        ),
      );
      await tester.tap(find.text('后台联网被系统限制'));
      expect((dismissed, opened), (1, 0));
      await tester.tap(find.text('去放行'));
      expect((dismissed, opened), (1, 1));
    });
  });

  group('host', () {
    Widget app(BackgroundNetReason? reason) => ProviderScope(
      overrides: [
        backgroundNetProvider.overrideWith(() => _Fixed(reason)),
        batteryExemptProvider.overrideWith((ref) async => false),
        backgroundSettingsProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: BackgroundNetHost()),
      ),
    );

    testWidgets('under the chat header; a tap anywhere on it clears it', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(BackgroundNetReason.blocked));
      await tester.pumpAndSettle();
      final pill = tester.getRect(find.byType(BackgroundNetPill));
      final context = tester.element(find.byType(BackgroundNetPill));
      expect(pill.top, moreOrLessEquals(ChatHeader.heightOf(context), epsilon: 0.01));
      expect(pill.center.dx, moreOrLessEquals(390 / 2, epsilon: 0.01));
      await tester.tap(find.byType(BackgroundNetPill));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundNetPill), findsNothing);
    });

    testWidgets('去放行 opens 后台保活 and the line is gone on the way back', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(BackgroundNetReason.failures));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去放行'));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundGuidePage), findsOneWidget);
      expect(find.byType(BackgroundNetPill), findsNothing);
      Navigator.of(tester.element(find.byType(BackgroundGuidePage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundNetPill), findsNothing);
    });

    testWidgets('waits while a page covers the chat', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(BackgroundNetReason.intro));
      await tester.pumpAndSettle();
      expect(find.text('让对话在后台也能跑完'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BackgroundNetHost)))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('设置'))));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundNetPill), findsNothing);
      Navigator.of(tester.element(find.text('设置'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('让对话在后台也能跑完'), findsOneWidget);
    });
  });

  group('golden', () {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      for (final reason in [BackgroundNetReason.blocked, BackgroundNetReason.intro]) {
        testWidgets('${reason.name} ($mode)', (tester) async {
          await tester.runAsync(shell.loadGoldenFonts);
          shell.usePhoneSurface(tester);
          await tester.pumpWidget(
            shell.goldenApp(
              home: const AppBackdrop(
                child: Scaffold(backgroundColor: Colors.transparent, body: BackgroundNetHost()),
              ),
              brightness: brightness,
              overrides: [backgroundNetProvider.overrideWith(() => _Fixed(reason))],
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/background_net_${reason.name}_$mode.png'),
          );
        });
      }
    }
  });
}
