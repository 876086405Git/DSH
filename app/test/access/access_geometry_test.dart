// Measured, not eyeballed: a feature row's icon and checkbox sit the same 16
// in from the card's edges and centred on the row; the step's counter is
// level with its tile and as far in from the right as the tile is from the
// left; the buttons under a step are mirror images; the restricted steps'
// marks line up; and every page of the walk at 320 dp with 1.3× and 2× text,
// in both languages, has nothing overflowing or cut short.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/ui/access/access_pick_page.dart';
import 'package:dsh_app/ui/access/access_summary_page.dart';
import 'package:dsh_app/ui/access/access_walk.dart';
import 'package:dsh_app/ui/access/access_widgets.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/settings/system_access_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/test_fonts.dart';
import 'support.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  FakeAccessDriver driver, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool english = false,
}) async {
  if (english) AppLocale.use(AppLocale.en);
  addTearDown(() => AppLocale.use(AppLocale.zhCN));
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
        localConnectionProvider.overrideWith(FakeConnection.new),
        ...accessOverrides(driver),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withTestFonts(buildLightTheme()),
        locale: english ? AppLocale.en : AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: MirroredSideInsets(child: child!),
        ),
        home: home,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// No line on screen cut short by its line limit. Text drawn at opacity 0 is
/// not on screen: a page's collapsed bar title waits there, ellipsised by
/// design, until the page scrolls.
void _expectNothingCut(WidgetTester tester, String where) {
  bool hidden(RenderObject o) {
    for (RenderObject? p = o; p != null; p = p.parent) {
      if (p is RenderOpacity && p.opacity == 0) return true;
      if (p is RenderAnimatedOpacity && p.opacity.value == 0) return true;
    }
    return false;
  }

  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (hidden(paragraph)) continue;
    expect(paragraph.didExceedMaxLines, isFalse, reason: '$where: "${paragraph.text.toPlainText()}" is cut');
  }
}

Widget _walk(List<AccessItem> items) => AccessWalk(items: items, onDone: () {});

final _restricted = readingsWith(offPhone, notifications: true, restricted: RestrictedSettingsState.guarded);

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a feature row', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('icon and checkbox 16 in from either edge, both centred on the row (×$scale)', (tester) async {
        await _pump(
          tester,
          AccessPickPage(onPicked: (_, _) {}, onSkip: () {}),
          FakeAccessDriver(offPhone),
          scale: scale,
        );
        final card = tester.getRect(find.byKey(const ValueKey('access-pick-card')));
        for (final feature in accessFeaturesFor('android')) {
          final row = find.byKey(ValueKey('access-feature-${feature.name}'));
          final rowRect = tester.getRect(row);
          final icon = tester.getRect(find.descendant(of: row, matching: find.byType(SettingsLineIcon)));
          final check = tester.getRect(find.byKey(ValueKey('access-check-${feature.name}')));
          expect(icon.left - card.left, moreOrLessEquals(SettingsMetrics.inset, epsilon: 0.01), reason: feature.name);
          expect(card.right - check.right, moreOrLessEquals(SettingsMetrics.inset, epsilon: 0.01), reason: feature.name);
          expect(icon.center.dy, moreOrLessEquals(rowRect.center.dy, epsilon: 0.01), reason: feature.name);
          expect(check.center.dy, moreOrLessEquals(rowRect.center.dy, epsilon: 0.01), reason: feature.name);
        }
        // The card is as far from either screen edge.
        expect(card.left, moreOrLessEquals(390 - card.right, epsilon: 0.01));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a step', () {
    testWidgets('the counter is level with the tile, as far in on the right as the tile on the left', (tester) async {
      await _pump(tester, _walk([AccessItem.mic, AccessItem.notifications]), FakeAccessDriver(offPhone));
      final tile = tester.getRect(find.byKey(const ValueKey('access-tile')));
      final counter = tester.getRect(find.byKey(const ValueKey('access-counter')));
      expect(counter.center.dy, moreOrLessEquals(tile.center.dy, epsilon: 0.01));
      expect(390 - counter.right, moreOrLessEquals(tile.left, epsilon: 0.01));
      expect(tile.width, moreOrLessEquals(AccessHeader.tile, epsilon: 0.01));
      expect(tile.height, moreOrLessEquals(AccessHeader.tile, epsilon: 0.01));
    });

    testWidgets('one quiet way on: full width under the main key, both centred', (tester) async {
      await _pump(tester, _walk([AccessItem.mic]), FakeAccessDriver(offPhone));
      final primary = tester.getRect(find.byKey(const ValueKey('access-primary')));
      final skip = tester.getRect(find.byKey(const ValueKey('access-secondary-0')));
      expect(primary.left, moreOrLessEquals(390 - primary.right, epsilon: 0.01));
      expect(skip.left, primary.left);
      expect(skip.right, primary.right);
      expect(find.byKey(const ValueKey('access-secondary-1')), findsNothing);
    });

    testWidgets('two quiet ways on: equal halves, mirrored under the main key', (tester) async {
      await _pump(tester, _walk([AccessItem.accessibility]), FakeAccessDriver(_restricted));
      final primary = tester.getRect(find.byKey(const ValueKey('access-primary')));
      final a = tester.getRect(find.byKey(const ValueKey('access-secondary-0')));
      final b = tester.getRect(find.byKey(const ValueKey('access-secondary-1')));
      expect(a.width, moreOrLessEquals(b.width, epsilon: 0.01));
      expect(a.top, b.top);
      expect(a.left, moreOrLessEquals(primary.left, epsilon: 0.01));
      expect(b.right, moreOrLessEquals(primary.right, epsilon: 0.01));
      expect(b.left - a.right, moreOrLessEquals(0, epsilon: 0.01));
      expect(a.left, moreOrLessEquals(390 - b.right, epsilon: 0.01));
    });

    testWidgets('the restricted steps: marks in one column, the card centred', (tester) async {
      await _pump(tester, _walk([AccessItem.accessibility]), FakeAccessDriver(_restricted));
      final card = tester.getRect(find.byKey(const ValueKey('access-restricted')));
      expect(card.left, moreOrLessEquals(390 - card.right, epsilon: 0.01));
      for (var i = 1; i <= 3; i++) {
        final mark = tester.getRect(
          find.descendant(of: find.byKey(ValueKey('access-step-mark-$i')), matching: find.byType(DecoratedBox)).first,
        );
        expect(mark.left - card.left, moreOrLessEquals(16, epsilon: 0.01), reason: '$i');
        expect(mark.width, moreOrLessEquals(22, epsilon: 0.01), reason: '$i');
        expect(mark.height, moreOrLessEquals(22, epsilon: 0.01), reason: '$i');
      }
    });

    testWidgets('the status line keeps its room: the keys don\'t move when it appears', (tester) async {
      await _pump(
        tester,
        _walk([AccessItem.battery]),
        FakeAccessDriver(offPhone, answer: (_, r) => r),
      );
      final before = tester.getRect(find.byKey(const ValueKey('access-primary')));
      await tester.tap(find.byKey(const ValueKey('access-primary')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('还没开启'), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('access-primary'))), before);
      // In line with the title and the tile, not centred.
      final tile = tester.getRect(find.byKey(const ValueKey('access-tile')));
      expect(tester.getRect(find.text('还没开启')).left, moreOrLessEquals(tile.left, epsilon: 0.01));
      expect(tester.getRect(find.text('允许在后台运行')).left, moreOrLessEquals(tile.left, epsilon: 0.01));
    });
  });

  group('320 dp, large text: nothing overflows or is cut', () {
    final screens = <String, (Widget Function(), AccessReadings, Future<void> Function(WidgetTester)?)>{
      'pick, on mobile data': (
        () => AccessPickPage(onPicked: (_, _) {}, onSkip: () {}),
        readingsWith(offPhone, metered: true),
        null,
      ),
      'a maker\'s switch, back from it': (
        () => _walk([AccessItem.vendorBackground, AccessItem.autostart, AccessItem.popup]),
        offPhone,
        (tester) async {
          await tester.ensureVisible(find.byKey(const ValueKey('access-primary')));
          await tester.tap(find.byKey(const ValueKey('access-primary')));
          await awayAndBack(tester);
        },
      ),
      'restricted': (() => _walk([AccessItem.accessibility]), _restricted, null),
      'summary': (
        () => AccessSummaryPage(items: accessWalk(AccessFeature.values, 'vivo'), voice: true, onDone: () {}),
        readingsWith(offPhone, mic: true, notifications: true),
        null,
      ),
      'settings': (() => const SystemAccessPage(), offPhone, null),
    };
    for (final MapEntry(key: name, value: (home, readings, before)) in screens.entries) {
      for (final (english, scale) in [(false, 1.3), (false, 2.0), (true, 1.3), (true, 2.0)]) {
        testWidgets('$name (${english ? 'en' : 'zh'}, ×$scale)', (tester) async {
          await _pump(
            tester,
            home(),
            FakeAccessDriver(readings, answer: (_, r) => r),
            size: const Size(320, 640),
            scale: scale,
            english: english,
          );
          if (before != null) await before(tester);
          expect(tester.takeException(), isNull);
          _expectNothingCut(tester, name);
        });
      }
    }
  });
}
