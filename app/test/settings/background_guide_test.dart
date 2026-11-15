import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/notify_state.dart' show notifyChannelProvider;
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _BatteryBridge extends RuntimeBridge {
  bool exempt = false;
  int requests = 0;
  @override
  Future<bool?> batteryExempt() async => exempt;
  @override
  Future<bool?> requestBatteryExempt() async {
    requests++;
    return true;
  }
}

class _VendorBridge extends _BatteryBridge {
  _VendorBridge(this.vendor);

  final String? vendor;
  int opened = 0;

  @override
  Future<BackgroundSettingsInfo?> backgroundSettings() async => BackgroundSettingsInfo(vendor: vendor, label: 'DSH');

  @override
  Future<String?> openBackgroundSettings() async {
    opened++;
    return 'vendor';
  }
}

class _Notify extends NotifyChannel {
  _Notify(this.system);

  NotifySystemStatus system;
  bool opens = true;
  int opened = 0;

  @override
  Future<NotifySystemStatus> status() async => system;

  @override
  Future<bool> openSettings({String? channel}) async {
    opened++;
    return opens;
  }
}

const _makers = [
  'vivo / iQOO（OriginOS）',
  '小米 / Redmi（HyperOS、MIUI）',
  '华为 / 荣耀（HarmonyOS、MagicOS）',
  'OPPO / 一加 / realme（ColorOS）',
  '三星（One UI）',
];

void main() {
  // vivo: its own switch on top.
  goldenBoth(
    'background_guide_vivo',
    () => const BackgroundGuidePage(),
    overrides: () => [runtimeBridgeProvider.overrideWithValue(_VendorBridge('vivo'))],
  );

  testWidgets('this phone\'s maker first: its switch opens in one tap, the others below', (tester) async {
    final bridge = _VendorBridge('vivo');
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(bridge)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('vivo / iQOO'), findsOneWidget);
    expect(find.text('电池 › 后台耗电管理 › DSH'), findsOneWidget);
    expect(tester.getRect(find.text('允许后台高耗电')).top, lessThan(tester.getRect(find.text('系统电池优化')).top));
    expect(find.text('其他品牌'), findsOneWidget);
    expect(find.text(_makers.first), findsNothing);
    for (final maker in _makers.skip(1)) {
      expect(find.text(maker), findsOneWidget);
    }
    await tester.tap(find.text('允许后台高耗电'));
    await tester.pumpAndSettle();
    expect(bridge.opened, 1);
  });

  testWidgets('honor shares Huawei\'s row title and is left out below', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(_VendorBridge('honor'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('荣耀'), findsOneWidget);
    expect(find.text('允许后台活动'), findsOneWidget);
    expect(find.text('华为 / 荣耀（HarmonyOS、MagicOS）'), findsNothing);
  });

  testWidgets('other phones: no maker row, every maker listed', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(_VendorBridge(null))],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('各品牌'), findsOneWidget);
    for (final maker in _makers) {
      expect(find.text(maker), findsOneWidget);
    }
  });

  testWidgets('request once, resume refreshes exemption and disables row', (tester) async {
    final bridge = _BatteryBridge();
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.light,
        overrides: [runtimeBridgeProvider.overrideWithValue(bridge)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未关闭'), findsOneWidget);
    await tester.tap(find.text('系统电池优化'));
    await tester.pumpAndSettle();
    expect(bridge.requests, 1);
    // Back from the system dialog.
    bridge.exempt = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);
    final tile = tester.widget<SettingsTile>(find.widgetWithText(SettingsTile, '系统电池优化'));
    expect(tile.onTap, isNull);
    await tester.tap(find.text('系统电池优化'));
    expect(bridge.requests, 1);
  });

  testWidgets('unsupported platform hides system battery row', (tester) async {
    await tester.pumpWidget(
      goldenApp(
        home: const BackgroundGuidePage(),
        brightness: Brightness.dark,
        overrides: [batteryExemptProvider.overrideWith((ref) async => null)],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('系统电池优化'), findsNothing);
  });

  group('on HarmonyOS', () {
    final zh = lookupL10n(AppLocale.zhCN);
    const row = ValueKey('background-notifications');

    Future<void> pump(WidgetTester tester, _Notify notify, {String os = 'ohos'}) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const BackgroundGuidePage(),
          brightness: Brightness.light,
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            // A phone that would say "not exempt", and a maker to name: none of it shows.
            runtimeBridgeProvider.overrideWithValue(_VendorBridge('huawei')),
            notifyChannelProvider.overrideWithValue(notify),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says what happens: nothing about batteries or makers', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus()));
      for (final text in [
        zh.harmonyBackgroundSubtitle,
        zh.harmonyBackgroundLocal,
        zh.harmonyBackgroundRemote,
        zh.harmonyBackgroundStay,
        zh.harmonyBackgroundUseRemote,
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      for (final text in [
        zh.pluginsSystemBatteryOptimization,
        zh.pluginsStayOnline,
        zh.pluginsOtherBrands,
        zh.pluginsBackgroundDescription,
      ]) {
        expect(find.text(text), findsNothing, reason: text);
      }
    });

    testWidgets('iOS suspends the same way: the same page', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus()), os: 'ios');
      expect(find.text(zh.harmonyBackgroundSubtitle), findsOneWidget);
      expect(find.text(zh.pluginsSystemBatteryOptimization), findsNothing);
    });

    testWidgets('the notifications row shows where they stand', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus()));
      expect(find.descendant(of: find.byKey(row), matching: find.text(zh.accessStateOn)), findsOneWidget);
    });

    testWidgets('off, or a slot closed: it says off', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus(enabled: false)));
      expect(find.descendant(of: find.byKey(row), matching: find.text(zh.accessStateOff)), findsOneWidget);
    });

    testWidgets('unknown: no value rather than a wrong one', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus.unavailable()));
      expect(find.descendant(of: find.byKey(row), matching: find.text(zh.accessStateOn)), findsNothing);
      expect(find.descendant(of: find.byKey(row), matching: find.text(zh.accessStateOff)), findsNothing);
    });

    testWidgets('a tap opens settings, and what came of it shows without a resume', (tester) async {
      final notify = _Notify(const NotifySystemStatus(enabled: false));
      await pump(tester, notify);
      notify.system = const NotifySystemStatus();
      await tester.tap(find.byKey(row));
      await tester.pumpAndSettle();
      expect(notify.opened, 1);
      expect(find.descendant(of: find.byKey(row), matching: find.text(zh.accessStateOn)), findsOneWidget);
    });

    testWidgets('settings that won\'t open say so', (tester) async {
      final notify = _Notify(const NotifySystemStatus())..opens = false;
      await pump(tester, notify);
      await tester.tap(find.byKey(row));
      await tester.pump();
      expect(find.text(zh.accessOpenFailed), findsOneWidget);
    });

    testWidgets('on Android the same page is still the guide', (tester) async {
      await pump(tester, _Notify(const NotifySystemStatus()), os: 'android');
      expect(find.text(zh.harmonyBackgroundSubtitle), findsNothing);
      expect(find.byKey(row), findsNothing);
      expect(find.text(zh.pluginsSystemBatteryOptimization), findsOneWidget);
      expect(find.text(zh.pluginsBackgroundDescription), findsOneWidget);
    });
  });
}
