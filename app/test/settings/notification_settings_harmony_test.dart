// 通知 on HarmonyOS: what the page says must be true there. Live activities
// aren't available in this version, an alert needs the app running, and the
// way to the switch is that system's. Its half-sheet may bring no resume, so
// the status is read again when it closes.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/notify_state.dart' show notifyChannelProvider;
import 'package:dsh_app/ui/settings/notification_settings.dart';
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

  testWidgets('on HarmonyOS: not available in this version, with no Android to talk about', (tester) async {
    await pump(tester, 'ohos');
    expect(find.text(zh.harmonyLiveUnavailable), findsOneWidget);
    expect(find.text(zh.liveUnsupported), findsNothing);
    expect(find.text(zh.liveSettingsFooter), findsNothing);
    expect(find.text(zh.liveSettingsSubtitle), findsNothing);
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
