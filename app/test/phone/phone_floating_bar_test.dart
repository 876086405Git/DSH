// 设置 → 手机操控 → 悬浮条 (lib/ui/phone/phone_control_screen.dart): 闲置时不透明度
// (30–100 %, 70 % by default, sent to the native side on every step so a showing
// pill follows), 闲置时自动收起 (on by default), 屏幕边缘光效 (on by default) and
// 完成后返回 DSH Go, shown
// once phone control is on.

import 'dart:ui' show Tristate;

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/state/phone_overlay_prefs.dart';
import 'package:dsh_app/state/phone_turn_end.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/english_preview.dart';
import 'harness.dart';
import 'support.dart';

const _group = '悬浮条';
const _opacity = '闲置时不透明度';
const _auto = '闲置时自动收起';
const _glow = '屏幕边缘光效';
const _return = '完成后返回 DSH Go';

Finder _row(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow)).first;

Switch _switch(WidgetTester tester, String title) =>
    tester.widget<Switch>(find.descendant(of: _row(title), matching: find.byType(Switch)));

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PhoneControlScreen)));

Future<void> _reveal(WidgetTester tester) async {
  await tester.ensureVisible(find.text(_return));
  await settlePhone(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('rows', () {
    testWidgets('one group, three rows, in this order; defaults: 70 %, auto on, return on', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      expect(find.text(_group), findsOneWidget);
      final ys = [
        for (final t in [_group, _opacity, _auto, _return]) tester.getTopLeft(find.text(t)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(find.text('70%'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 70);
      expect(_switch(tester, _auto).value, isTrue);
      expect(_switch(tester, _return).value, isTrue);
      // The rules card keeps only the rules.
      final rulesBottom = tester.getBottomLeft(find.text('确认方式')).dy;
      expect(rulesBottom, lessThan(tester.getTopLeft(find.text(_group)).dy));
    });

    testWidgets('hidden while phone control is off', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus(enabled: false)));
      await openPhoneFold(tester, 'phone-more-options');
      expect(find.text('规则'), findsOneWidget);
      for (final t in [_group, _opacity, _auto, _return]) {
        expect(find.text(t), findsNothing);
      }
    });

    testWidgets('reads what the native side keeps', (tester) async {
      final native = FakePhoneNative(status: phoneStatus())..overlay = {'idleOpacity': 0.45, 'autoCollapse': true};
      await pumpPhone(tester, const PhoneControlScreen(), native: native);
      await openPhoneFold(tester, 'phone-more-options');
      expect(find.text('45%'), findsOneWidget);
      expect(_switch(tester, _auto).value, isTrue);
    });
  });

  group('changes', () {
    testWidgets('the slider moves in 5 % steps down to 30 %, each step sent at once', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      final slider = find.byType(Slider);
      // Center the gesture target, not a later row that can scroll it under the app bar.
      await Scrollable.ensureVisible(tester.element(slider), alignment: 0.5);
      await settlePhone(tester);
      expect(slider.hitTestable(), findsOneWidget);
      await tester.drag(slider, const Offset(-600, 0));
      await settlePhone(tester);
      expect(find.text('30%'), findsOneWidget);
      expect(h.native!.overlay['idleOpacity'], 0.3);
      final sent = [
        for (final c in h.native!.callsOf('setOverlayPrefs')) (c.arguments as Map)['idleOpacity'] as double,
      ];
      // Every value a step: whole multiples of 5 %, falling.
      expect(sent, isNotEmpty);
      for (final v in sent) {
        expect(((v * 100).round() % 5), 0, reason: '$v');
      }
      expect(sent, orderedEquals([...sent]..sort((a, b) => b.compareTo(a))));

      await tester.drag(slider, const Offset(900, 0));
      await settlePhone(tester);
      expect(find.text('100%'), findsOneWidget);
      expect(h.native!.overlay['idleOpacity'], 1.0);
      expect(_container(tester).read(phoneOverlayPrefsProvider).idleOpacity, 1.0);
    });

    testWidgets('闲置时自动收起: the row or the switch toggles it on the native side', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      await _reveal(tester);
      // On until the person turns it off.
      expect(_switch(tester, _auto).value, isTrue);
      await tester.tap(find.text(_auto));
      await settlePhone(tester);
      expect(_switch(tester, _auto).value, isFalse);
      expect(h.native!.overlay['autoCollapse'], isFalse);
      await tester.tap(find.descendant(of: _row(_auto), matching: find.byType(Switch)));
      await settlePhone(tester);
      expect(_switch(tester, _auto).value, isTrue);
      expect(h.native!.overlay['autoCollapse'], isTrue);
    });

    testWidgets('屏幕边缘光效: on by default, the row turns it off on the native side', (tester) async {
      final h = await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      await _reveal(tester);
      expect(_switch(tester, _glow).value, isTrue);
      await tester.tap(find.text(_glow));
      await settlePhone(tester);
      expect(_switch(tester, _glow).value, isFalse);
      expect(h.native!.overlay['edgeGlow'], isFalse);
      expect(_container(tester).read(phoneOverlayPrefsProvider).edgeGlow, isFalse);
    });

    testWidgets('完成后返回 DSH Go: toggled and kept in the app', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      await _reveal(tester);
      await tester.tap(find.text(_return));
      await settlePhone(tester);
      expect(_switch(tester, _return).value, isFalse);
      expect(_container(tester).read(phoneReturnPrefProvider), isFalse);
      expect((await SharedPreferences.getInstance()).getBool(PhoneReturnPrefController.key), isFalse);
    });

    testWidgets('without the native side a change still shows for this run', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      removePhoneNative();
      await _reveal(tester);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(55);
      await settlePhone(tester);
      expect(find.text('55%'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('the slider reads its name and percent; switches read their state', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative(status: phoneStatus()));
      await openPhoneFold(tester, 'phone-more-options');
      final slider = tester.getSemantics(find.byType(Slider)).getSemanticsData();
      expect(slider.label, contains(_opacity));
      expect(slider.value, '70%');
      final auto = tester.getSemantics(find.text(_auto)).getSemanticsData();
      expect(auto.label, contains('收成小球，点按展开'));
      expect(auto.flagsCollection.isToggled, Tristate.isTrue);
      final back = tester.getSemantics(find.text(_return)).getSemanticsData();
      expect(back.flagsCollection.isToggled, Tristate.isTrue);
      semantics.dispose();
    });
  });

  group('model', () {
    test('opacity stays within 30–100 % on whole percents', () {
      expect(PhoneOverlayPrefs.clampOpacity(0.1), 0.3);
      expect(PhoneOverlayPrefs.clampOpacity(1.3), 1.0);
      expect(PhoneOverlayPrefs.clampOpacity(0.6666), 0.67);
      expect(PhoneOverlayPrefs.fromMap(const {}).idleOpacity, 0.7);
      // 闲置时自动收起 is on unless the native side says it was turned off.
      expect(PhoneOverlayPrefs.fromMap(const {}).autoCollapse, isTrue);
      expect(const PhoneOverlayPrefs().autoCollapse, isTrue);
      expect(PhoneOverlayPrefs.fromMap(const {'autoCollapse': false}).autoCollapse, isFalse);
      expect(PhoneOverlayPrefs.fromMap(const {'idleOpacity': 0.5, 'autoCollapse': true}).percent, 50);
      // 屏幕边缘光效 likewise.
      expect(PhoneOverlayPrefs.fromMap(const {}).edgeGlow, isTrue);
      expect(PhoneOverlayPrefs.fromMap(const {'edgeGlow': false}).edgeGlow, isFalse);
    });
  });

  group('golden', () {
    Future<void> shoot(WidgetTester tester, Brightness brightness, String name, {bool english = false}) async {
      if (english) useEnglish();
      await tester.runAsync(loadGoldenFonts);
      final native = FakePhoneNative(status: phoneStatus())..overlay = {'idleOpacity': 0.45, 'autoCollapse': true};
      await pumpPhone(
        tester,
        english ? inEnglish(const PhoneControlScreen()) : const PhoneControlScreen(),
        native: native,
        size: const Size(390, 844),
        brightness: brightness,
      );
      await openPhoneFold(tester, 'phone-more-options');
      // The whole group in view, a little above the middle.
      await tester.scrollUntilVisible(find.byType(Slider), 200, scrollable: find.byType(Scrollable).first);
      await Scrollable.ensureVisible(tester.element(find.byType(Slider)), alignment: 0.4);
      await settlePhone(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    }

    testWidgets('phone_floating_bar (light)', (tester) => shoot(tester, Brightness.light, 'phone_floating_bar_light'));
    testWidgets('phone_floating_bar (dark)', (tester) => shoot(tester, Brightness.dark, 'phone_floating_bar_dark'));
    testWidgets(
      'en_phone_floating_bar (light)',
      (tester) => shoot(tester, Brightness.light, 'en_phone_floating_bar_light', english: true),
    );
    testWidgets(
      'en_phone_floating_bar (dark)',
      (tester) => shoot(tester, Brightness.dark, 'en_phone_floating_bar_dark', english: true),
    );
  });
}
