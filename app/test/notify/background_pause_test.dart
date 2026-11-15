// HarmonyOS's quiet line about a pause in the background
// (lib/runtime/background_pause.dart, lib/ui/notify/background_pause_host.dart):
// when it shows, when it doesn't, where it sits and how it goes. The shell
// shows it only where Android's line isn't.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/background_pause.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart' show appForegroundProvider, launchNoticeShownProvider;
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/notify/background_net_host.dart';
import 'package:dsh_app/ui/notify/background_pause_host.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show FakeChatController;
import '../phone/support.dart' show FixedActiveHost;
import '../shell/golden_harness.dart' as shell;

const _session = 's1';

class _Current extends CurrentSessionController {
  _Current(this.id);

  final String? id;

  @override
  String? build() => id;
}

class _Fixed extends BackgroundPauseController {
  _Fixed(this.initial);

  final bool initial;

  @override
  bool build() => initial;
}

void main() {
  group('policy', () {
    bool due({
      Duration away = const Duration(seconds: 30),
      bool local = true,
      bool wasRunning = true,
      bool running = true,
    }) => BackgroundPausePolicy.onReturn(away: away, local: local, wasRunning: wasRunning, running: running);

    test('on-device, a turn running, away long enough to be suspended', () => expect(due(), isTrue));

    test('a quick look at another app says nothing', () {
      expect(due(away: BackgroundPausePolicy.suspendedAfter), isTrue);
      expect(due(away: BackgroundPausePolicy.suspendedAfter - const Duration(milliseconds: 1)), isFalse);
      expect(BackgroundPausePolicy.suspendedAfter, const Duration(seconds: 10));
    });

    test('a remote host kept going', () => expect(due(local: false), isFalse));

    test('nothing was running, or it ended before the app was suspended', () {
      expect(due(wasRunning: false), isFalse);
      expect(due(running: false), isFalse);
    });

    test('the system is still letting it run: it never paused', () {
      expect(
        BackgroundPausePolicy.onReturn(
          away: const Duration(minutes: 5),
          local: true,
          wasRunning: true,
          running: true,
          continued: true,
        ),
        isFalse,
      );
    });
  });

  group('controller', () {
    late DateTime clock;
    late FakeChatController chat;

    ProviderContainer container({HostRef host = HostRef.local, String? session = _session, bool running = true}) {
      final c = ProviderContainer(
        overrides: [
          activeHostProvider.overrideWith(() => FixedActiveHost(host)),
          currentSessionProvider.overrideWith(() => _Current(session)),
          chatProvider.overrideWith2((id) => chat = FakeChatController(id, ChatState(running: running))),
        ],
      );
      addTearDown(c.dispose);
      c.listen(backgroundPauseProvider, (_, _) {});
      if (session != null) c.read(chatProvider(session));
      return c;
    }

    void leave(ProviderContainer c) => c.read(appForegroundProvider.notifier).set(false);

    void comeBack(ProviderContainer c, {Duration after = const Duration(seconds: 30)}) {
      clock = clock.add(after);
      c.read(appForegroundProvider.notifier).set(true);
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      clock = DateTime(2026, 11, 3, 12);
      BackgroundPauseController.now = () => clock;
    });
    tearDown(() {
      BackgroundPauseController.now = DateTime.now;
      BackgroundPauseController.shownFor = const Duration(seconds: 8);
    });

    test('a running turn on the on-device engine, away long enough: the line', () {
      final c = container();
      leave(c);
      expect(c.read(backgroundPauseProvider), isFalse);
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isTrue);
      // It counts as this launch's unbidden notice, as Android's line does.
      expect(c.read(launchNoticeShownProvider), isTrue);
    });

    test('a short trip: nothing', () {
      final c = container();
      leave(c);
      comeBack(c, after: const Duration(seconds: 4));
      expect(c.read(backgroundPauseProvider), isFalse);
      expect(c.read(launchNoticeShownProvider), isFalse);
    });

    test('a remote host: nothing', () {
      final c = container(host: const HostRef.relay('r1'));
      leave(c);
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isFalse);
    });

    test('no turn running on leaving: nothing, even if one is running now', () {
      final c = container(running: false);
      leave(c);
      chat.emit(const ChatState(running: true));
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isFalse);
    });

    test('the turn ended before the app was suspended: nothing', () {
      final c = container();
      leave(c);
      chat.emit(const ChatState());
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isFalse);
    });

    test('no conversation open: nothing', () {
      final c = container(session: null);
      leave(c);
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isFalse);
    });

    test('dismissed, it stays gone until the next time', () {
      final c = container();
      leave(c);
      comeBack(c);
      c.read(backgroundPauseProvider.notifier).dismiss();
      expect(c.read(backgroundPauseProvider), isFalse);
      leave(c);
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isTrue);
    });

    test('leaving again takes it away', () {
      final c = container();
      leave(c);
      comeBack(c);
      leave(c);
      expect(c.read(backgroundPauseProvider), isFalse);
    });

    test('it goes by itself', () async {
      BackgroundPauseController.shownFor = Duration.zero;
      final c = container();
      leave(c);
      comeBack(c);
      expect(c.read(backgroundPauseProvider), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(backgroundPauseProvider), isFalse);
    });
  });

  group('host', () {
    final zh = lookupL10n(AppLocale.zhCN);

    Widget app(bool paused) => ProviderScope(
      overrides: [backgroundPauseProvider.overrideWith(() => _Fixed(paused))],
      child: MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: BackgroundPauseHost()),
      ),
    );

    testWidgets('under the chat header in the shape of Android\'s line; a tap clears it', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      final finder = find.byType(BackgroundLinePill);
      expect(find.text(zh.harmonyPausedInBackground), findsOneWidget);
      final pill = tester.getRect(finder);
      expect(pill.top, moreOrLessEquals(ChatHeader.heightOf(tester.element(finder)), epsilon: 0.01));
      expect(pill.center.dx, moreOrLessEquals(390 / 2, epsilon: 0.01));
      expect(pill.height, greaterThanOrEqualTo(BackgroundLinePill.minHeight));
      // Nothing to go and set, so no action to offer.
      expect(find.byKey(const ValueKey('background-net-action')), findsNothing);

      await tester.tap(finder);
      await tester.pumpAndSettle();
      expect(finder, findsNothing);
    });

    testWidgets('waits while a page covers the chat', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(BackgroundPauseHost)))
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('设置'))));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundLinePill), findsNothing);
      Navigator.of(tester.element(find.text('设置'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundLinePill), findsOneWidget);
    });

    testWidgets('nothing to say: draws nothing', (tester) async {
      shell.usePhoneSurface(tester);
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(find.byType(BackgroundLinePill), findsNothing);
    });

    for (final locale in [AppLocale.zhCN, AppLocale.en]) {
      testWidgets('one whole line in ${locale.languageCode} on a narrow phone', (tester) async {
        final text = lookupL10n(locale).harmonyPausedInBackground;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 700);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: Stack(
                children: [
                  BackgroundLineSlot(
                    child: BackgroundLinePill(icon: Icons.pause, text: text, onDismiss: () {}),
                  ),
                ],
              ),
            ),
          ),
        );
        final line = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text(text), matching: find.byType(RichText)),
        );
        expect(line.didExceedMaxLines, isFalse, reason: text);
      });
    }
  });
}
