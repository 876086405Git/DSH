// 宠物设置's 「App 外显示」 group and the overlay flavour of the restricted-settings
// guide (docs/design/pets.md §6.4, §8).

import 'package:dsh_app/companion/companion_float.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/pets/overlay_settings_tile.dart';
import 'package:dsh_app/ui/phone/restricted_settings_guide.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../phone/harness.dart';
import '../../shell/golden_harness.dart';
import 'fake_overlay_native.dart';

Widget _page() => const Scaffold(
  body: SafeArea(child: SingleChildScrollView(child: PetOverlaySettingsSection())),
);

class _QuietFloatController extends CompanionFloatController {
  _QuietFloatController([this.initial = const CompanionFloatState()]);

  final CompanionFloatState initial;
  int retries = 0;

  @override
  CompanionFloatState build() => initial;

  @override
  Future<void> retry() async => retries++;
}

Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double height = 520,
  String? companionProblem = 'companion_runtime_missing',
  _QuietFloatController? float,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390, height) * 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: _page(),
      brightness: brightness,
      overrides: [
        companionFloatAvailabilityProvider.overrideWith((ref) => Stream.value(companionProblem)),
        companionFloatProvider.overrideWith(() => float ?? _QuietFloatController()),
      ],
    ),
  );
  await settlePhone(tester);
}

/// 「悬浮窗里显示」 and 「取景」.
final _renderer = find.byType(SettingsSegmentTile<PetOverlayRenderer>);
final _framing = find.byType(SettingsSegmentTile<PetOverlayFraming>);

PetPrefs _prefs(WidgetTester tester) => ProviderScope.containerOf(tester.element(_renderer)).read(petPrefsProvider);

/// She was picked before this visit.
void _companionChosen() => SharedPreferences.setMockInitialValues({PetPrefsController.keys.renderer: 'companion'});

/// 「App 外显示」 without the permission: the first-time notice, then 去设置.
Future<void> _turnOnThroughNotice(WidgetTester tester) async {
  await tester.tap(find.text('App 外显示'));
  await settlePhone(tester);
  await tester.pumpAndSettle();
  expect(find.text('显示在其他应用上层？'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('risk-confirm')));
  await tester.pumpAndSettle();
  await settlePhone(tester);
}

bool _switchOn(WidgetTester tester) => tester
    .widget<Switch>(
      find.descendant(of: find.widgetWithText(SettingsSwitchTile, 'App 外显示'), matching: find.byType(Switch)),
    )
    .value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('nothing without the native side', (tester) async {
    removeOverlayNative();
    await _pump(tester);
    expect(find.text('App 外显示'), findsNothing);
  });

  testWidgets('off: one switch; on: 有事时显示 / 一直显示', (tester) async {
    final native = FakeOverlayNative(permission: 'granted')..install();
    await _pump(tester);
    expect(_switchOn(tester), isFalse);
    expect(find.text('一直显示'), findsNothing);

    await tester.tap(find.text('App 外显示'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    // Already allowed: nothing to say first.
    expect(find.byType(RiskNoticeSheet), findsNothing);
    expect(native.enabled, isTrue);
    expect(_switchOn(tester), isTrue);
    expect(find.text('有事时显示'), findsOneWidget);

    await tester.tap(find.text('一直显示'));
    await settlePhone(tester);
    expect(native.alwaysShow, isTrue);
  });

  testWidgets('悬浮窗里显示: the pixel pet by default; she can be picked and taken back', (tester) async {
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null);
    expect(find.text('悬浮窗里显示'), findsOneWidget);
    final row = tester.widget<SettingsSegmentTile<PetOverlayRenderer>>(_renderer);
    expect(row.selected, PetOverlayRenderer.pixel);
    expect(row.subtitle, isNull);
    expect(_framing, findsNothing);

    await tester.tap(find.text('小屋里的她'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(_prefs(tester).overlayRenderer, PetOverlayRenderer.companion);
    expect(find.text('点一下和她互动，连点两下打开对话。比像素宠物更耗电，熄屏和隐藏时会停下来'), findsOneWidget);
    expect(_framing, findsOneWidget);

    await tester.tap(find.text('像素宠物'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(_prefs(tester).overlayRenderer, PetOverlayRenderer.pixel);
    expect(find.text('点一下和她互动，连点两下打开对话。比像素宠物更耗电，熄屏和隐藏时会停下来'), findsNothing);
    expect(_framing, findsNothing);
  });

  testWidgets('iOS PiP does not offer the unimplemented WebView companion renderer', (tester) async {
    FakeOverlayNative(platform: 'ios', permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null);
    expect(find.text('App 外显示'), findsOneWidget);
    expect(_renderer, findsNothing);
  });

  testWidgets('the name she was given in her room is the one on the choice', (tester) async {
    SharedPreferences.setMockInitialValues({'companion_name': '小蓝'});
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null);
    expect(find.text('小屋里的小蓝'), findsOneWidget);
    expect(find.text('小屋里的她'), findsNothing);
  });

  for (final (reason, says) in const [
    ('companion_runtime_missing', '先去伙伴小屋里请一位角色'),
    ('companion_runtime_mismatch', '角色包不完整，去伙伴小屋里重新导入'),
    ('companion_missing_texture', '角色包不完整，去伙伴小屋里重新导入'),
    ('companion_storage', '这台手机暂时请不出她'),
    ('companion_some_new_code', '这台手机暂时请不出她'),
  ]) {
    testWidgets('$reason: the row stays, she cannot be picked, and it says why', (tester) async {
      final native = FakeOverlayNative(permission: 'granted', enabled: true)..install();
      await _pump(tester, companionProblem: reason);
      final row = tester.widget<SettingsSegmentTile<PetOverlayRenderer>>(_renderer);
      expect(row.selected, PetOverlayRenderer.pixel);
      expect(row.onChanged, isNull);
      expect(find.text(says), findsOneWidget);
      await tester.tap(find.text('小屋里的她'));
      await settlePhone(tester);
      expect(_prefs(tester).overlayRenderer, PetOverlayRenderer.pixel);
      expect(native.methods, isNot(contains('configureCompanion')));
    });
  }

  testWidgets('a native side that fails: this phone cannot show her, and the choice can be taken back', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(
      tester,
      companionProblem: null,
      float: _QuietFloatController(const CompanionFloatState(problem: 'companion_native_unavailable')),
    );
    expect(find.text('这台手机暂时请不出她'), findsOneWidget);
    await tester.tap(find.text('像素宠物'));
    await settlePhone(tester);
    expect(_prefs(tester).overlayRenderer, PetOverlayRenderer.pixel);
  });

  testWidgets('while her page is being brought up the row says so', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null, float: _QuietFloatController(const CompanionFloatState(loading: true)));
    expect(find.text('正在请她出来…'), findsOneWidget);
    expect(find.text('点一下和她互动，连点两下打开对话。比像素宠物更耗电，熄屏和隐藏时会停下来'), findsNothing);
  });

  testWidgets('fallen back to the pixel pet: the row says so, and 重试 after it asks for her again', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true, companionFallback: true).install();
    final float = _QuietFloatController(const CompanionFloatState(configured: true));
    await _pump(tester, companionProblem: null, float: float);
    expect(tester.widget<SettingsSegmentTile<PetOverlayRenderer>>(_renderer).selected, PetOverlayRenderer.companion);
    expect(find.text('她没能出来，先由像素宠物顶班'), findsOneWidget);
    final retry = find.descendant(of: _renderer, matching: find.widgetWithText(TextButton, '重试'));
    expect(retry, findsOneWidget);
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(40));
    // One way in: the line and the title are not buttons.
    await tester.tap(find.text('她没能出来，先由像素宠物顶班'));
    await tester.tap(find.text('悬浮窗里显示'));
    await settlePhone(tester);
    expect(float.retries, 0);

    await tester.tap(retry);
    await settlePhone(tester);
    expect(float.retries, 1);
    expect(_prefs(tester).overlayRenderer, PetOverlayRenderer.companion);
  });

  testWidgets('重试 is only there after a fallback', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(
      tester,
      companionProblem: null,
      float: _QuietFloatController(const CompanionFloatState(configured: true)),
    );
    expect(find.text('点一下和她互动，连点两下打开对话。比像素宠物更耗电，熄屏和隐藏时会停下来'), findsOneWidget);
    expect(find.descendant(of: _renderer, matching: find.byType(TextButton)), findsNothing);
  });

  testWidgets('a narrow, large-text screen puts 重试 on its own line, at the left edge', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true, companionFallback: true).install();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pump(
      tester,
      companionProblem: null,
      height: 900,
      float: _QuietFloatController(const CompanionFloatState(configured: true)),
    );
    final line = tester.getRect(find.text('她没能出来，先由像素宠物顶班'));
    final retry = tester.getRect(find.descendant(of: _renderer, matching: find.widgetWithText(TextButton, '重试')));
    expect(retry.top, greaterThanOrEqualTo(line.bottom));
    expect(retry.left, line.left);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取景: 全身 by default, 半身 and back, each kept as one preset', (tester) async {
    _companionChosen();
    FakeOverlayNative(permission: 'granted', enabled: true).install();
    await _pump(tester, companionProblem: null, height: 640);
    expect(find.text('取景'), findsOneWidget);
    expect(find.text('换取景会重新加载她'), findsOneWidget);
    expect(tester.widget<SettingsSegmentTile<PetOverlayFraming>>(_framing).selected, PetOverlayFraming.full);
    expect((_prefs(tester).floatZoom, _prefs(tester).floatY), (PetOverlayFraming.full.zoom, PetOverlayFraming.full.y));

    await tester.tap(find.text('半身'));
    await settlePhone(tester);
    expect((_prefs(tester).floatZoom, _prefs(tester).floatY), (PetOverlayFraming.half.zoom, PetOverlayFraming.half.y));
    expect(tester.widget<SettingsSegmentTile<PetOverlayFraming>>(_framing).selected, PetOverlayFraming.half);

    await tester.tap(find.text('全身'));
    await settlePhone(tester);
    expect((_prefs(tester).floatZoom, _prefs(tester).floatY), (0.9, 0.0));
  });

  testWidgets('refused: back off, 「未授权」, then the restricted-settings guide', (tester) async {
    final native = FakeOverlayNative(sdk: 34)..install();
    // Tall enough for the whole guide page.
    await _pump(tester, height: 2400);
    await _turnOnThroughNotice(tester);
    expect(native.methods, contains('requestPermission'));
    // Back from system settings without it.
    await leaveAndResume(tester);
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);
    expect(find.text('未授权'), findsOneWidget);
    expect(find.text('开关点不动'), findsOneWidget);

    await tester.tap(find.text('开关点不动'));
    await tester.pumpAndSettle();
    expect(find.byType(RestrictedSettingsGuidePage), findsOneWidget);
    expect(find.text('侧载的 App 要先放行这一项，悬浮窗开关才点得动'), findsOneWidget);
    expect(find.textContaining('先去「悬浮窗」设置里点一次 DSH Go 的开关'), findsOneWidget);
    expect(find.text('回到「悬浮窗」设置，打开 DSH Go。'), findsOneWidget);
    expect(find.text('去开悬浮窗'), findsOneWidget);
  });

  testWidgets('failed accessibility overlay offers permission and recovers', (tester) async {
    final native = FakeOverlayNative(permission: 'accessibility', enabled: true, sdk: 32)..install();
    await _pump(tester);
    // A normally hidden window (the fake reports showing=false) still has permission.
    expect(_switchOn(tester), isTrue);
    expect(find.text('未授权'), findsNothing);

    native.permission = 'denied';
    await native.emitStatus();
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);
    expect(find.text('未授权'), findsOneWidget);
    expect(native.enabled, isTrue);
    expect(native.methods, isNot(contains('requestPermission')));

    // The existing cooldown ending or a service reconnect clears the refusal.
    native.permission = 'accessibility';
    await native.emitStatus();
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isTrue);
    expect(find.text('未授权'), findsNothing);

    native.permission = 'denied';
    await native.emitStatus();
    await settlePhone(tester);
    await tester.pumpAndSettle();
    await _turnOnThroughNotice(tester);
    expect(native.methods, contains('requestPermission'));
    expect(native.methods, isNot(contains('openAppDetails')));
    native.permission = 'granted';
    await leaveAndResume(tester);
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isTrue);
    expect(find.text('未授权'), findsNothing);
  });

  testWidgets('no restricted-settings row before Android 13 or for a vendor block', (tester) async {
    final native = FakeOverlayNative(sdk: 32)..install();
    await _pump(tester);
    await _turnOnThroughNotice(tester);
    await leaveAndResume(tester);
    expect(find.text('未授权'), findsOneWidget);
    expect(find.text('开关点不动'), findsNothing);
    expect(native.enabled, isFalse);
  });

  testWidgets('the permission is explained once: × stays off, 不再提示 goes straight on next time', (tester) async {
    final native = FakeOverlayNative()..install();
    await _pump(tester);
    await tester.tap(find.text('App 外显示'));
    await tester.pumpAndSettle();
    expect(find.text('显示在其他应用上层？'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(RiskNoticeSheet), matching: find.byTooltip('关闭')));
    await tester.pumpAndSettle();
    expect(native.methods, isNot(contains('requestPermission')));
    expect(native.enabled, isFalse);

    await _turnOnThroughNotice(tester);
    expect(native.methods, contains('requestPermission'));
    await leaveAndResume(tester);
    await tester.pumpAndSettle();

    // 不再提示 was ticked: the next try goes to system settings at once.
    native.calls.clear();
    await tester.tap(find.text('App 外显示'));
    await settlePhone(tester);
    await tester.pumpAndSettle();
    expect(find.byType(RiskNoticeSheet), findsNothing);
    expect(native.methods, contains('requestPermission'));
  });

  testWidgets('今天不再显示 shows while snoozed and 恢复 ends it', (tester) async {
    final native = FakeOverlayNative(permission: 'granted', enabled: true, snoozed: true)..install();
    await _pump(tester);
    expect(find.text('今天不再显示'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await settlePhone(tester);
    expect(native.snoozed, isFalse);
    expect(find.text('今天不再显示'), findsNothing);
  });

  testWidgets('the overlay guide turns the switch on, opens the setting, and says when done', (tester) async {
    final native = FakeOverlayNative()..install();
    await pumpPhone(tester, const RestrictedSettingsGuidePage(target: RestrictedTarget.overlay));
    expect(find.text('悬浮窗已开好，可以返回了'), findsNothing);
    await tester.ensureVisible(find.text('去开悬浮窗'));
    await tester.tap(find.text('去开悬浮窗'));
    await settlePhone(tester);
    expect(native.enabled, isTrue);
    expect(native.methods, contains('requestPermission'));
    native.permission = 'granted';
    await leaveAndResume(tester);
    expect(find.text('悬浮窗已开好，可以返回了'), findsOneWidget);
    expect(native.enabled, isTrue);
  });

  testWidgets('the accessibility guide is unchanged', (tester) async {
    await pumpPhone(tester, const RestrictedSettingsGuidePage());
    expect(find.text('侧载的 App 要先放行这一项，无障碍开关才点得动'), findsOneWidget);
    expect(find.text('去开无障碍'), findsOneWidget);
    expect(find.textContaining('先去「无障碍」里点一次 DSH 的开关'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden: on, 有事时显示, snoozed ($mode)', (tester) async {
      await tester.runAsync(loadGoldenFonts);
      FakeOverlayNative(permission: 'granted', enabled: true, snoozed: true).install();
      await _pump(tester, brightness: brightness);
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/overlay_settings_$mode.png'));
    });
  }
}
