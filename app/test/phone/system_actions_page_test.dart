// 系统操作's page and handoff prompt: true about what it can and can't do, no
// switch without the disclosure, and only continue tells the AI to go on.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/system_actions_state.dart';
import 'package:dsh_app/phone/phone_channel.dart' show PhoneLogEntry;
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_app/ui/phone/action_log_page.dart';
import 'package:dsh_app/ui/phone/phone_disclosure_sheet.dart';
import 'package:dsh_app/ui/phone/system_actions_host.dart';
import 'package:dsh_app/ui/phone/system_actions_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart' show FixedActiveHost, FixedHosts;

final _zh = lookupL10n(AppLocale.zhCN);

class _Actions extends SystemActionsController {
  _Actions(this.initial);
  final SystemActionsState initial;
  final answers = <String>[];
  bool counts = true;

  @override
  SystemActionsState build() => initial;

  @override
  Future<void> acceptDisclosure() async => state = state.copyWith(disclosureAccepted: true);

  @override
  Future<bool> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled, link: enabled ? SystemActionsLink.ready : SystemActionsLink.off);
    return true;
  }

  @override
  Future<bool> continueHandoff() async {
    answers.add('continue');
    if (counts) state = state.copyWith(clearHandoff: true);
    return counts;
  }

  @override
  Future<bool> stopHandoff() async {
    answers.add('stop');
    state = state.copyWith(clearHandoff: true);
    return true;
  }

  void ask(DshPhoneRequest request) => state = state.copyWith(handoff: request);
  void end() => state = state.copyWith(clearHandoff: true);
}

class _Reminders extends RuntimeBridge {
  _Reminders(this.answer);

  final String answer;

  @override
  Future<String?> reminderAccess() async => answer;

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
}

Future<_Actions> _pump(
  WidgetTester tester,
  Widget home, {
  SystemActionsState state = const SystemActionsState(loaded: true),
  HostRef host = HostRef.local,
  String? reminders,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 2000 * 2);
  addTearDown(tester.view.reset);
  final actions = _Actions(state);
  await tester.pumpWidget(
    goldenApp(
      home: home,
      brightness: Brightness.light,
      overrides: [
        operatingSystemProvider.overrideWithValue('ohos'),
        if (reminders != null) runtimeBridgeProvider.overrideWithValue(_Reminders(reminders)),
        systemActionsProvider.overrideWith(() => actions),
        activeHostProvider.overrideWith(() => FixedActiveHost(host)),
        hostsProvider.overrideWith(FixedHosts.new),
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return actions;
}

DshPhoneRequest _handoff([String id = '11111111-1111-4111-8111-111111111111']) => DshPhoneRequest.fromJson({
  'v': 1,
  'engineId': 'engine',
  'bridgeGeneration': 1,
  'requestId': id,
  'sessionId': 'session',
  'callId': 'call',
  'tool': 'mcp__phone__handoff',
  'args': {'reason': '请完成短信验证'},
  'timeoutMs': 600000,
  'deadlineMs': 601000,
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('says what it can do, what it can\'t, and that it needs the screen', (tester) async {
    await _pump(tester, const SystemActionsPage());
    expect(find.text(_zh.systemActionsTitle), findsWidgets);
    for (final text in [
      _zh.systemActionsCanOpen,
      _zh.systemActionsCanPages,
      _zh.systemActionsCanNotify,
      _zh.systemActionsCanClipboard,
      _zh.systemActionsCanHandoff,
      _zh.systemActionsCannotScreen,
      _zh.systemActionsCannotOther,
      _zh.systemActionsOnScreenTitle,
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // The name and the promise of Android's page are nowhere on it.
    expect(find.text('手机操控'), findsNothing);
    expect(find.textContaining('无障碍'), findsNothing);
    expect(find.textContaining('悬浮'), findsNothing);
  });

  group('闹钟和计时器 say what is true of this build', () {
    Finder under(String card, String title) => find.descendant(
      of: find.ancestor(of: find.text(card), matching: find.byType(ListPageCard)),
      matching: find.text(title),
    );

    for (final (native, card, hint) in [
      ('granted', _zh.systemActionsCanTitle, _zh.harmonyRemindersCanHint),
      ('denied', _zh.systemActionsCannotTitle, _zh.harmonyRemindersNoBuild),
      ('unsupported', _zh.systemActionsCannotTitle, _zh.harmonyRemindersNoDevice),
    ]) {
      testWidgets('$native: under 「$card」', (tester) async {
        await _pump(tester, const SystemActionsPage(), reminders: native);
        expect(find.text(_zh.harmonyRemindersTitle), findsOneWidget);
        expect(under(card, _zh.harmonyRemindersTitle), findsOneWidget);
        expect(find.text(hint), findsOneWidget);
      });
    }

    testWidgets('a native side that can\'t say: no claim either way', (tester) async {
      await _pump(tester, const SystemActionsPage());
      expect(find.text(_zh.harmonyRemindersTitle), findsNothing);
    });
  });

  test('what the native side refuses isn\'t on the can-do list', () {
    final can = [_zh.systemActionsCanOpen, _zh.systemActionsCanPages, _zh.systemActionsCanSettings];
    for (final line in can) {
      expect(line, isNot(contains('短信')), reason: 'sms_draft says unsupported');
      expect(line, isNot(contains('闹钟')), reason: 'alarms have their own row, by what this build can do');
    }
    expect(_zh.systemActionsCannotOther, allOf(contains('短信'), contains('读剪贴板')));
    expect(_zh.systemActionsCannotOther, isNot(contains('闹钟')), reason: 'there is a public way now');
  });

  group('the switch', () {
    testWidgets('the first time it shows what this does, and only agreeing turns it on', (tester) async {
      final actions = await _pump(tester, const SystemActionsPage());
      await tester.tap(find.byKey(const ValueKey('system-actions-switch')));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneDisclosureSheet), findsOneWidget);
      expect(find.text(_zh.systemActionsDisclosureNeverBody), findsOneWidget);
      expect(find.text(_zh.phoneDisclosureWhatBody), findsNothing, reason: 'there is no screen reading here');
      await tester.tap(find.text(_zh.phoneDisclosureNotNow));
      await tester.pumpAndSettle();
      expect(actions.state.enabled, isFalse);

      await tester.tap(find.byKey(const ValueKey('system-actions-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_zh.phoneDisclosureAgreeEnable));
      await tester.pumpAndSettle();
      expect(actions.state.enabled, isTrue);
      expect(actions.state.disclosureAccepted, isTrue);
      expect(find.text(_zh.systemActionsReady), findsOneWidget);
    });

    testWidgets('after that it doesn\'t ask again', (tester) async {
      final actions = await _pump(
        tester,
        const SystemActionsPage(),
        state: const SystemActionsState(loaded: true, disclosureAccepted: true),
      );
      await tester.tap(find.byKey(const ValueKey('system-actions-switch')));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneDisclosureSheet), findsNothing);
      expect(actions.state.enabled, isTrue);
    });

    for (final (link, line) in [
      (SystemActionsLink.waitingEngine, _zh.systemActionsWaitingEngine),
      (SystemActionsLink.offScreen, _zh.systemActionsOffScreen),
      (SystemActionsLink.unavailable, _zh.systemActionsUnavailable),
      (SystemActionsLink.unsupported, _zh.systemActionsUnsupported),
    ]) {
      testWidgets('its line says $link', (tester) async {
        await _pump(
          tester,
          const SystemActionsPage(),
          state: SystemActionsState(loaded: true, enabled: true, link: link),
        );
        expect(find.text(line), findsOneWidget);
      });
    }

    testWidgets('on a remote host it says those chats aren\'t covered', (tester) async {
      await _pump(tester, const SystemActionsPage(), host: const HostRef.ssh('s'));
      expect(find.text(_zh.systemActionsRemoteTitle), findsOneWidget);
    });
  });

  group('the log', () {
    PhoneLogEntry entry(String decision) => PhoneLogEntry.fromMap({
      'time': DateTime(2026, 11, 4, 9).millisecondsSinceEpoch,
      'tool': 'mcp__phone__open',
      'decision': decision,
    });

    for (final (decision, word) in [
      ('opened_ui', _zh.systemActionsOpenedUi),
      ('reminder_scheduled', _zh.harmonyReminderSet),
      ('result_unknown', _zh.systemActionsResultUnknown),
      ('unsupported', _zh.systemActionsNotSupported),
      ('continue', _zh.phoneDecisionContinued),
      ('timeout', _zh.phoneDecisionTimeout),
    ]) {
      test('$decision reads as $word, not as done', () {
        expect(phoneDecisionLabel(entry(decision)), word);
      });
    }

    testWidgets('the page shows the recent ones and opens the rest', (tester) async {
      await _pump(
        tester,
        const SystemActionsPage(),
        state: SystemActionsState(loaded: true, log: [for (var i = 0; i < 5; i++) entry('opened_ui')]),
      );
      expect(find.byType(ActionLogRow), findsNWidgets(SystemActionsPage.recentCount));
      await tester.tap(find.text(_zh.phoneActionLogTitle));
      await tester.pumpAndSettle();
      expect(find.byType(SystemActionsLogPage), findsOneWidget);
      expect(find.byType(ActionLogRow), findsNWidgets(5));
    });

    testWidgets('empty, it says so', (tester) async {
      await _pump(tester, const SystemActionsLogPage());
      expect(find.text(_zh.phoneActionLogEmpty), findsOneWidget);
    });
  });

  testWidgets('confirmation goes through the permission page, not a setting of its own', (tester) async {
    await _pump(tester, const SystemActionsPage());
    await tester.tap(find.text(_zh.systemActionsConfirmTitle));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionPage), findsOneWidget);
  });

  group('the handoff prompt', () {
    Future<_Actions> prompt(WidgetTester tester) async {
      final actions = await _pump(tester, const Scaffold(body: SystemActionsHost()));
      actions.ask(_handoff());
      await tester.pumpAndSettle();
      return actions;
    }

    testWidgets('shows the reason and both answers; continue closes it', (tester) async {
      final actions = await prompt(tester);
      expect(find.text('请完成短信验证'), findsOneWidget);
      expect(find.text(_zh.systemActionsHandoffNote), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('handoff-continue')));
      await tester.pumpAndSettle();
      expect(actions.answers, ['continue']);
      expect(find.byType(HandoffSheet), findsNothing);
    });

    testWidgets('stop is its own answer', (tester) async {
      final actions = await prompt(tester);
      await tester.tap(find.byKey(const ValueKey('handoff-stop')));
      await tester.pumpAndSettle();
      expect(actions.answers, ['stop']);
      expect(find.byType(HandoffSheet), findsNothing);
    });

    testWidgets('back doesn\'t dismiss it: without an answer the AI just waits', (tester) async {
      await prompt(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HandoffSheet), findsOneWidget);
    });

    testWidgets('a press that didn\'t count stays up and says so', (tester) async {
      final actions = await prompt(tester);
      actions.counts = false;
      await tester.tap(find.byKey(const ValueKey('handoff-continue')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HandoffSheet), findsOneWidget);
      expect(find.text(_zh.systemActionsHandoffFailed), findsOneWidget);
    });

    testWidgets('the call ending elsewhere (expiry, engine gone) takes it down', (tester) async {
      final actions = await prompt(tester);
      actions.end();
      await tester.pumpAndSettle();
      expect(find.byType(HandoffSheet), findsNothing);
      expect(actions.answers, isEmpty);
    });

    testWidgets('a handoff already waiting when the host comes up still gets its prompt', (tester) async {
      await _pump(
        tester,
        const Scaffold(body: SystemActionsHost()),
        state: SystemActionsState(loaded: true, handoff: _handoff()),
      );
      expect(find.byType(HandoffSheet), findsOneWidget);
    });

    testWidgets('the next handoff gets its own prompt', (tester) async {
      final actions = await prompt(tester);
      actions.end();
      await tester.pumpAndSettle();
      actions.ask(_handoff('22222222-2222-4222-8222-222222222222'));
      await tester.pumpAndSettle();
      expect(find.byType(HandoffSheet), findsOneWidget);
    });
  });
}
