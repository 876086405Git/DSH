// Where the person is told and can say no: first run's welcome page (over
// 「开始」) and 设置 › 隐私与分享 › 改进 DSH Go. Measured, not eyeballed: the
// welcome row's text starts 16 in from the button's left edge and the switch
// track ends 16 in from its right, both centred on the row, the row as far
// from either screen edge; at 320 dp with large text in both languages
// nothing overflows or is cut. Seeing either one is what starts the
// counting; the switch turns it all off.
//
//   flutter test --update-goldens test/usage/usage_ui_test.dart

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/onboarding/usage_notice_row.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/settings/usage_stats_section.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart' as engine;
import '../shell/golden_harness.dart';
import '../support/english_preview.dart';

const _row = ValueKey('usage-notice');
const _switch = ValueKey('usage-notice-switch');

Future<void> _pumpWelcome(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool english = false,
  Brightness brightness = Brightness.light,
}) async {
  if (english) useEnglish();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final page = WelcomePage(onStart: () {});
  await tester.pumpWidget(goldenApp(home: english ? inEnglish(page) : page, brightness: brightness));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

Future<Map<String, Object?>> _stored() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final k in prefs.getKeys()) k: prefs.get(k)};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('welcome, in English (light)', (tester) async {
    await tester.runAsync(loadGoldenFonts);
    await _pumpWelcome(tester, english: true);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_welcome_light.png'));
  });

  group('the welcome row', () {
    for (final english in [false, true]) {
      testWidgets('lines up with the button, centred, mirrored (${english ? 'en' : 'zh'})', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        await _pumpWelcome(tester, english: english);
        final button = tester.getRect(find.byType(FilledButton));
        final row = tester.getRect(find.byKey(_row));
        final sw = tester.getRect(find.byKey(_switch));
        final title = tester.getRect(find.text(appL10n.usageStatsTitle));
        final body = tester.getRect(find.text(appL10n.usageNoticeBody));
        // As wide as the button, as far from either screen edge.
        expect(row.left, moreOrLessEquals(button.left, epsilon: 0.01));
        expect(row.right, moreOrLessEquals(button.right, epsilon: 0.01));
        expect(row.left, moreOrLessEquals(390 - row.right, epsilon: 0.01));
        // Text 16 in on the left; the M3 track (4 inside the switch box) 16 in on the right.
        expect(title.left - button.left, moreOrLessEquals(16, epsilon: 0.01));
        expect(body.left, moreOrLessEquals(title.left, epsilon: 0.01));
        expect(button.right - (sw.right - 4), moreOrLessEquals(16, epsilon: 0.01));
        // The switch and the two lines centred on the row.
        expect(sw.center.dy, moreOrLessEquals(row.center.dy, epsilon: 0.01));
        expect((title.top + body.bottom) / 2, moreOrLessEquals(row.center.dy, epsilon: 0.6));
        // Over the button, clear of it.
        expect(button.top - row.bottom, moreOrLessEquals(20, epsilon: 0.01));
        expect(tester.takeException(), isNull);
      });
    }

    for (final (english, scale) in [(false, 1.3), (false, 2.0), (true, 1.3), (true, 2.0)]) {
      testWidgets('320 dp, ×$scale (${english ? 'en' : 'zh'}): nothing overflows or is cut', (tester) async {
        await tester.runAsync(loadGoldenFonts);
        await _pumpWelcome(tester, size: const Size(320, 640), scale: scale, english: english);
        expect(tester.takeException(), isNull);
        for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
          expect(paragraph.didExceedMaxLines, isFalse, reason: paragraph.text.toPlainText());
        }
        // The button is still reachable, with the row over it.
        final row = tester.getRect(find.byKey(_row));
        expect(row.bottom, lessThanOrEqualTo(tester.getRect(find.byType(FilledButton)).top));
      });
    }

    testWidgets('seeing it starts the counting; on by default', (tester) async {
      await _pumpWelcome(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final state = _container(tester).read(usageStatsProvider);
      expect(state.enabled, isTrue);
      expect(state.noticed, isTrue);
      expect(tester.widget<Switch>(find.byKey(_switch)).value, isTrue);
      expect((await tester.runAsync(_stored))![UsageStatsController.noticedKey], isTrue);
    });

    testWidgets('one tap anywhere on the row turns it off, and back on', (tester) async {
      await _pumpWelcome(tester);
      await tester.tap(find.text(appL10n.usageNoticeBody));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(_container(tester).read(usageStatsProvider).enabled, isFalse);
      expect(tester.widget<Switch>(find.byKey(_switch)).value, isFalse);
      expect((await tester.runAsync(_stored))![UsageStatsController.enabledKey], isFalse);

      await tester.tap(find.byKey(_switch));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(_container(tester).read(usageStatsProvider).enabled, isTrue);
    });

    testWidgets('reads as one switch to a screen reader', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpWelcome(tester);
      final node = tester.getSemantics(find.byKey(_switch));
      expect(node.label, contains(appL10n.usageStatsTitle));
      expect(node.label, contains(appL10n.usageNoticeBody));
      semantics.dispose();
    });
  });

  group('设置 › 隐私与分享', () {
    Future<void> pumpPrivacy(WidgetTester tester) => engine.pumpPage(
      tester,
      const PrivacyPage(),
      overrides: engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
    );

    testWidgets('the page counts as being told; the switch turns it all off', (tester) async {
      await pumpPrivacy(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(PrivacyPage)));
      expect(container.read(usageStatsProvider).noticed, isTrue);
      final tile = find.widgetWithText(InkWell, appL10n.usageStatsTitle);
      expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isTrue);
      expect(find.text(appL10n.usageStatsFooter), findsOneWidget);

      await tester.tap(tile);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(container.read(usageStatsProvider).enabled, isFalse);
      expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isFalse);
      final stored = (await tester.runAsync(_stored))!;
      expect(stored[UsageStatsController.enabledKey], isFalse);
      for (final key in [UsageStatsController.iidKey, UsageStatsController.daysKey]) {
        expect(stored.containsKey(key), isFalse, reason: key);
      }
    });

    testWidgets('a cold start shows it off once it was turned off', (tester) async {
      SharedPreferences.setMockInitialValues({
        UsageStatsController.enabledKey: false,
        UsageStatsController.noticedKey: true,
      });
      await pumpPrivacy(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final tile = find.widgetWithText(InkWell, appL10n.usageStatsTitle);
      expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isFalse);
    });
  });

  group('on HarmonyOS, where nothing is sent yet', () {
    final zh = lookupL10n(AppLocale.zhCN);
    Future<void> pump(WidgetTester tester, Widget home, String os) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: home,
          brightness: Brightness.light,
          overrides: [
            ...engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
            operatingSystemProvider.overrideWithValue(os),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Widget section() => const Scaffold(body: SingleChildScrollView(child: UsageStatsSection()));

    testWidgets('settings says so, with the switch off and locked', (tester) async {
      await pump(tester, section(), 'ohos');
      expect(find.text(zh.harmonyUsageNotSent), findsOneWidget);
      expect(find.text(zh.usageStatsFooter), findsNothing);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNull);
    });

    testWidgets('on Android: as ever', (tester) async {
      await pump(tester, section(), 'android');
      expect(find.text(zh.usageStatsFooter), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
    });

    testWidgets('first run doesn\'t ask about it', (tester) async {
      await pump(tester, const Scaffold(body: UsageNoticeRow()), 'ohos');
      expect(find.byKey(_row), findsNothing);
    });

    testWidgets('on Android first run still does', (tester) async {
      await pump(tester, const Scaffold(body: UsageNoticeRow()), 'android');
      expect(find.byKey(_row), findsOneWidget);
    });
  });
}
