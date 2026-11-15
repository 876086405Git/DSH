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
