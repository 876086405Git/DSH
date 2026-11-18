// 通知 on HarmonyOS: what the page says must be true there. A running turn gets
// a plain progress notification rather than a live card, an alert needs the app
// running, and the way to the switch is that system's. Its half-sheet may bring
// no resume, so the status is read again when it closes.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/notify_state.dart' show notifyChannelProvider;
import 'package:dsh_app/ui/settings/notification_settings.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/support.dart' show FakeNotifyChannel;
import '../shell/golden_harness.dart';

class _Unsupported extends FakeNotifyChannel {
  _Unsupported({super.system});

  @override
  Future<LiveSystemStatus> liveStatus() async => const LiveSystemStatus();
}

/// What NotifyPlugin.ets reports: no live card, a plain notification instead.
class _Ordinary extends FakeNotifyChannel {
  @override
  Future<LiveSystemStatus> liveStatus() async =>
      const LiveSystemStatus(settings: true, ordinaryFallback: true, ordinaryAllowed: true, backend: 'ordinary');
}

/// The notification slot is off in the system; the panel turns it back on.
class _SlotOff extends FakeNotifyChannel {
  _SlotOff() : super(system: const NotifySystemStatus(done: false, attention: false));

  bool allowed = false;

  @override
  Future<LiveSystemStatus> liveStatus() async =>
      LiveSystemStatus(settings: true, ordinaryFallback: true, ordinaryAllowed: allowed, backend: 'ordinary');

  @override
  Future<bool> openLiveSettings() async {
    allowed = true;
    return true;
  }
}

/// The native side is there and the read threw.
class _ReadFailed extends FakeNotifyChannel {
  @override
  Future<LiveSystemStatus> liveStatus() async => const LiveSystemStatus(readFailed: true);
}

/// What Android's page does with a live activity the system holds back.
class _AndroidBlocked extends FakeNotifyChannel {
  @override
  Future<LiveSystemStatus> liveStatus() async => const LiveSystemStatus(supported: true, settings: true);
}

/// Notifications off; the system's panel either turns them on or won't open.
class _Blocked extends _Unsupported {
  _Blocked({required this.opens}) : super(system: const NotifySystemStatus(enabled: false));

  final bool opens;

  @override
  Future<bool> openSettings({String? channel}) async {
    await super.openSettings(channel: channel);
    if (opens) system = const NotifySystemStatus();
    return opens;
  }
}

void main() {
  final zh = lookupL10n(AppLocale.zhCN);
  final en = lookupL10n(AppLocale.en);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, String os, {NotifyChannel? channel}) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: const NotificationSettingsPage(),
        brightness: Brightness.light,
        overrides: [
          operatingSystemProvider.overrideWithValue(os),
          notifyChannelProvider.overrideWithValue(channel ?? _Unsupported()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on HarmonyOS: the progress notification is on and says what it is', (tester) async {
    await pump(tester, 'ohos', channel: _Ordinary());
    expect(find.text(zh.harmonyLiveTitle), findsOneWidget);
    expect(find.text(zh.harmonyLiveSwitch), findsOneWidget);
    expect(find.text(zh.harmonyLiveSubtitle), findsOneWidget);
    expect(find.text(zh.harmonyLiveFooter), findsOneWidget);
    expect(find.text(zh.harmonyLiveUnavailable), findsNothing);
    expect(find.text(zh.liveUnsupported), findsNothing);
    expect(find.text(zh.liveSettingsFooter), findsNothing);
    expect(find.text(zh.liveSettingsSubtitle), findsNothing);
    final toggle = tester.widget<Switch>(
      find.descendant(
        of: find.ancestor(of: find.text(zh.harmonyLiveSwitch), matching: find.byType(SettingsSwitchTile)),
        matching: find.byType(Switch),
      ),
    );
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNotNull);
  });

  testWidgets('on HarmonyOS: a build without it says not available, with no Android to talk about', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyLiveUnavailable), findsOneWidget);
    expect(find.text(zh.liveUnsupported), findsNothing);
    expect(find.text(zh.liveSettingsFooter), findsNothing);
    expect(find.text(zh.liveSettingsSubtitle), findsNothing);
  });

  Switch progressSwitch(WidgetTester tester) => tester.widget<Switch>(
    find.descendant(
      of: find.ancestor(of: find.text(zh.harmonyLiveSwitch), matching: find.byType(SettingsSwitchTile)),
      matching: find.byType(Switch),
    ),
  );

  group('the slot is off', () {
    testWidgets('on HarmonyOS: it warns by the switch, in its own words, and reads again after the panel', (
      tester,
    ) async {
      await pump(tester, 'ohos', channel: _SlotOff());
      expect(find.text(zh.harmonyLiveBlockedTitle), findsOneWidget);
      expect(find.text(zh.harmonyLiveBlockedText), findsOneWidget);
      expect(find.text(zh.liveBlockedText), findsNothing, reason: '流体云 is someone else\'s word');
      await tester.tap(find.widgetWithText(TextButton, zh.pluginsTurnOn).last);
      await tester.pumpAndSettle();
      expect(find.text(zh.harmonyLiveBlockedTitle), findsNothing);
    });

    testWidgets('on HarmonyOS: one title, since one slot carries both kinds of alert', (tester) async {
      await pump(tester, 'ohos', channel: _SlotOff());
      expect(find.text(zh.harmonyAlertsOffTitle), findsOneWidget);
      expect(find.text(zh.pluginsApprovalNotificationsOff), findsNothing);
      expect(find.text(zh.pluginsDoneNotificationsOff), findsNothing);
    });

    testWidgets('on Android: each channel by name, and its live activity note', (tester) async {
      await pump(tester, 'android', channel: _SlotOff());
      expect(find.text(zh.pluginsApprovalNotificationsOff), findsOneWidget);
      expect(find.text(zh.harmonyAlertsOffTitle), findsNothing);
      expect(find.text(zh.harmonyLiveBlockedTitle), findsNothing);
    });

    testWidgets('on Android: a live activity held back still says 流体云', (tester) async {
      await pump(tester, 'android', channel: _AndroidBlocked());
      expect(find.text(zh.liveBlockedText), findsOneWidget);
    });
  });

  group('a status read that failed', () {
    testWidgets('on HarmonyOS: unknown, not "no such feature"; the switch still works', (tester) async {
      await pump(tester, 'ohos', channel: _ReadFailed());
      expect(find.text(zh.harmonyLiveUnavailable), findsNothing);
      expect(find.text(zh.harmonyLiveSubtitle), findsOneWidget);
      expect(find.text(zh.harmonyLiveBlockedTitle), findsNothing);
      expect(progressSwitch(tester).value, isTrue);
      expect(progressSwitch(tester).onChanged, isNotNull);
    });

    testWidgets('on Android: as it was', (tester) async {
      await pump(tester, 'android', channel: _ReadFailed());
      expect(find.text(zh.liveUnsupported), findsOneWidget);
    });
  });

  testWidgets('on HarmonyOS: the banner hint names that system\'s switch', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyEnableBanner), findsOneWidget);
    expect(find.text(zh.pluginsEnableFloatingNotifications), findsNothing);
  });

  testWidgets('on Android: the banner hint stays', (tester) async {
    await pump(tester, 'android');
    expect(find.text(zh.pluginsEnableFloatingNotifications), findsOneWidget);
    expect(find.text(zh.harmonyEnableBanner), findsNothing);
  });

  test('the footer keeps what is true and promises no roadmap', () {
    expect(zh.harmonyLiveFooter, contains('不再更新'));
    expect(zh.harmonyLiveFooter, isNot(contains('实况窗')));
    expect(en.harmonyLiveFooter, isNot(contains('Live View')));
  });

  testWidgets('on HarmonyOS: a build that may ask for a long task says alerts go on with the turn', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 2400 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: const NotificationSettingsPage(),
        brightness: Brightness.light,
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          notifyChannelProvider.overrideWithValue(_Ordinary()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(
              const LocalRuntimeState(
                loaded: true,
                status: RuntimeStatus(phase: RuntimePhase.running, longTaskEligible: true),
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(zh.harmonyAlertsRequirementLong), findsOneWidget);
    expect(find.text(zh.harmonyAlertsRequirement), findsNothing);
  });

  testWidgets('on HarmonyOS: alerts need the app running, wherever the reply runs', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyAlertsRequirement), findsOneWidget);
    expect(find.text(zh.pluginsRemoteAlertsRequirement), findsNothing);
  });

  testWidgets('on Android: its own words', (tester) async {
    await pump(tester, 'android');
    expect(find.text(zh.liveUnsupported), findsOneWidget);
    expect(find.text(zh.liveSettingsFooter), findsOneWidget);
    expect(find.text(zh.pluginsRemoteAlertsRequirement), findsOneWidget);
    expect(find.text(zh.harmonyLiveUnavailable), findsNothing);
    expect(find.text(zh.harmonyAlertsRequirement), findsNothing);
  });

  testWidgets('on HarmonyOS: it doesn\'t claim the lock screen hides anything; the system decides', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyLockScreenPrivacy), findsOneWidget);
    expect(find.text(zh.pluginsLockScreenPrivacy), findsNothing);
  });

  testWidgets('on Android: the lock screen line stays, it is true there', (tester) async {
    await pump(tester, 'android');
    expect(find.text(zh.pluginsLockScreenPrivacy), findsOneWidget);
    expect(find.text(zh.harmonyLockScreenPrivacy), findsNothing);
  });

  testWidgets('on HarmonyOS: the status is read again when the panel closes', (tester) async {
    await pump(tester, 'ohos', channel: _Blocked(opens: true));
    await tester.tap(find.text(zh.pluginsTurnOn));
    await tester.pumpAndSettle();
    expect(find.text(zh.pluginsSystemNotificationsOff), findsNothing);
  });

  testWidgets('on Android: the status waits for the app to come back from settings', (tester) async {
    await pump(tester, 'android', channel: _Blocked(opens: true));
    await tester.tap(find.text(zh.pluginsTurnOn).first);
    await tester.pumpAndSettle();
    expect(find.text(zh.pluginsSystemNotificationsOff), findsOneWidget);
  });

  testWidgets('on HarmonyOS: a panel that won\'t open gives that system\'s way there', (tester) async {
    await pump(tester, 'ohos', channel: _Blocked(opens: false));
    await tester.tap(find.text(zh.pluginsTurnOn));
    await tester.pumpAndSettle();
    expect(find.text(zh.harmonyNotificationSettingsFailed), findsOneWidget);
    expect(find.text(zh.pluginsNotificationSettingsFailed), findsNothing);
  });

  testWidgets('on Android: a panel that won\'t open gives its own', (tester) async {
    await pump(tester, 'android', channel: _Blocked(opens: false));
    await tester.tap(find.text(zh.pluginsTurnOn).first);
    await tester.pumpAndSettle();
    expect(find.text(zh.pluginsNotificationSettingsFailed), findsOneWidget);
    expect(find.text(zh.harmonyNotificationSettingsFailed), findsNothing);
  });

  test('none of it names Android or a maker', () {
    for (final l in [zh, en]) {
      for (final text in [
        l.harmonyLiveUnavailable,
        l.harmonyAlertsRequirement,
        l.harmonyNotificationSettingsFailed,
        l.harmonySearchUnavailable,
      ]) {
        for (final word in ['Android', 'Xiaomi', 'OPPO', '小米']) {
          expect(text, isNot(contains(word)), reason: text);
        }
      }
    }
  });
}
