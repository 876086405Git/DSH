// What makes the HarmonyOS build feel like the Android one, where it can be
// tested without oh-flutter: the theme's platform, keyboard motion and cutouts.

import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:dsh_app/ui/common/keyboard_motion.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Material behaves as Android on HarmonyOS and is left alone elsewhere', () {
    expect(themePlatformFor('ohos'), TargetPlatform.android);
    expect(themePlatformFor('android'), isNull);
    expect(themePlatformFor('linux'), isNull);
  });

  group('EasedKeyboardInset', () {
    late MediaQueryData seen;

    Future<void> pump(WidgetTester tester, double keyboard, {bool still = false}) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          viewInsets: EdgeInsets.only(bottom: keyboard),
          viewPadding: const EdgeInsets.only(top: 30, bottom: 20),
          padding: EdgeInsets.only(top: 30, bottom: keyboard > 0 ? 0 : 20),
          disableAnimations: still,
        ),
        child: EasedKeyboardInset(
          child: Builder(
            builder: (context) {
              seen = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    testWidgets('a one-shot report eases up and back', (tester) async {
      await pump(tester, 0);
      expect(seen.viewInsets.bottom, 0);

      await pump(tester, 300);
      expect(seen.viewInsets.bottom, 0, reason: 'it starts where it was');
      expect(seen.padding.bottom, 20);
      await tester.pump(const Duration(milliseconds: 100));
      final partway = seen.viewInsets.bottom;
      expect(partway, inExclusiveRange(0, 300));
      await tester.pumpAndSettle();
      expect(seen.viewInsets.bottom, 300);
      expect(seen.padding.bottom, 0);

      await pump(tester, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(seen.viewInsets.bottom, inExclusiveRange(0, 300));
      await tester.pumpAndSettle();
      expect(seen.viewInsets.bottom, 0);
      expect(seen.padding.bottom, 20);
    });

    testWidgets('left alone it is exactly easeOutCubic', (tester) async {
      await pump(tester, 0);
      await pump(tester, 300);
      for (final (ms, t) in [(50, 0.2), (50, 0.4), (100, 0.8)]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(seen.viewInsets.bottom, moreOrLessEquals(300 * Curves.easeOutCubic.transform(t), epsilon: 0.01));
      }
    });

    testWidgets('a change of mind keeps its speed', (tester) async {
      await pump(tester, 0);
      await pump(tester, 300);
      await tester.pump(const Duration(milliseconds: 134));
      final before = seen.viewInsets.bottom;
      await tester.pump(const Duration(milliseconds: 16));
      final at = seen.viewInsets.bottom;
      await pump(tester, 600);
      await tester.pump(const Duration(milliseconds: 16));
      expect(seen.viewInsets.bottom - at, moreOrLessEquals(at - before, epsilon: (at - before) * 0.5));
      await tester.pumpAndSettle();
      expect(seen.viewInsets.bottom, 600);
    });

    testWidgets('a nearer target stops at it, never past it', (tester) async {
      await pump(tester, 0);
      await pump(tester, 300);
      await tester.pump(const Duration(milliseconds: 40));
      final at = seen.viewInsets.bottom;
      await pump(tester, at + 20);
      var last = at;
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(seen.viewInsets.bottom, greaterThanOrEqualTo(last - 0.01));
        expect(seen.viewInsets.bottom, lessThanOrEqualTo(at + 20 + 0.01));
        last = seen.viewInsets.bottom;
      }
      expect(last, moreOrLessEquals(at + 20, epsilon: 0.01));
    });

    testWidgets('turning back carries on only a little the old way', (tester) async {
      await pump(tester, 0);
      await pump(tester, 300);
      await tester.pump(const Duration(milliseconds: 25));
      final at = seen.viewInsets.bottom;
      await pump(tester, 0);
      var furthest = at;
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        furthest = furthest < seen.viewInsets.bottom ? seen.viewInsets.bottom : furthest;
      }
      expect(furthest, greaterThan(at), reason: 'it did not stop dead');
      expect(furthest, lessThan(at * 1.3));
      expect(seen.viewInsets.bottom, moreOrLessEquals(0, epsilon: 0.01));
    });

    testWidgets('rising again just as it lands never goes below the bottom', (tester) async {
      await pump(tester, 300);
      await pump(tester, 0);
      await tester.pump(const Duration(milliseconds: 200));
      await pump(tester, 300);
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(seen.viewInsets.bottom, greaterThanOrEqualTo(0));
      }
      expect(seen.viewInsets.bottom, moreOrLessEquals(300, epsilon: 0.01));
    });

    testWidgets('a change of mind continues from where it is', (tester) async {
      await pump(tester, 0);
      await pump(tester, 300);
      await tester.pump(const Duration(milliseconds: 100));
      final partway = seen.viewInsets.bottom;
      await pump(tester, 0);
      expect(seen.viewInsets.bottom, moreOrLessEquals(partway, epsilon: 0.01));
      await tester.pumpAndSettle();
      expect(seen.viewInsets.bottom, 0);
    });

    testWidgets('the first report and reduced motion jump', (tester) async {
      await pump(tester, 300);
      expect(seen.viewInsets.bottom, 300, reason: 'a keyboard already up at start');

      await pump(tester, 0, still: true);
      expect(seen.viewInsets.bottom, 0);
    });
  });

  group('MirroredSideInsets.cutoutInset', () {
    DisplayFeature cutout(Rect bounds) =>
        DisplayFeature(bounds: bounds, type: DisplayFeatureType.cutout, state: DisplayFeatureState.unknown);

    MediaQueryData on(Size size, List<DisplayFeature> features) =>
        MediaQueryData(size: size, displayFeatures: features);

    test('reaches in from whichever side the camera is on', () {
      const size = Size(800, 400);
      expect(MirroredSideInsets.cutoutInset(on(size, [cutout(const Rect.fromLTRB(10, 170, 50, 230))])), 50);
      expect(MirroredSideInsets.cutoutInset(on(size, [cutout(const Rect.fromLTRB(750, 170, 790, 230))])), 50);
    });

    test('counts for nothing upright, or when it is not a cutout', () {
      expect(MirroredSideInsets.cutoutInset(on(const Size(400, 800), [cutout(const Rect.fromLTRB(180, 10, 220, 50))])), 0);
      final fold = DisplayFeature(
        bounds: const Rect.fromLTRB(10, 0, 50, 400),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      );
      expect(MirroredSideInsets.cutoutInset(on(const Size(800, 400), [fold])), 0);
    });

    test('never narrows what the padding already keeps clear', () {
      expect(MirroredSideInsets.mirror(const EdgeInsets.only(left: 60), 50).right, 60);
      expect(MirroredSideInsets.mirror(EdgeInsets.zero, 50).left, 50);
    });
  });
}
