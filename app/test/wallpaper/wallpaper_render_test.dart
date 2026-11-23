// The wallpaper bake: the screen's part of the picture, blurred, and calmed only as far as the
// page's text needs — every pixel of the result, bright picture or dark, light page or dark,
// keeps the text colours at 4.5:1 or more; the bars at the top and bottom get more. Decoded
// once, its first frame only; lighter on a lightweight device; a picture that can't be read
// bakes to nothing (the default backdrop).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/theme/palette.dart';
import 'package:dsh_app/ui/theme/semantic_colors.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_look.dart';
import 'package:dsh_app/wallpaper/wallpaper_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

ThemeData buildThemeFor(Brightness b) => b == Brightness.dark ? buildDarkTheme() : buildLightTheme();

void main() {
  Future<ui.Image> bake(WidgetTester tester, CustomWallpaper w, WallpaperFrame frame, {double? density}) async =>
      (await tester.runAsync(() => WallpaperRenderer().bake(w, frame, density: density)))!;

  for (final (name, path) in [('bright', brightFixture), ('dark', darkFixture)]) {
    for (final brightness in Brightness.values) {
      final mode = brightness.name;
      testWidgets('$name picture, $mode page: every pixel keeps the text readable', (tester) async {
        final frame = phoneFrame(brightness);
        final image = await bake(tester, fixtureWallpaper(path, tone: 0), frame);
        await tester.runAsync(() => dump(image, 'bake_${name}_$mode'));
        final pixels = (await tester.runAsync(() => Pixels.of(image)))!;
        image.dispose();
        final dark = brightness == Brightness.dark;
        final scheme = dark ? DshPalette.darkScheme(AppAccent.mist) : DshPalette.lightScheme(AppAccent.mist);
        final colors = DshColors.forAccent(brightness, AppAccent.mist);
        final look = frame.look;
        final whole = Rect.fromLTWH(0, 0, pixels.width.toDouble(), pixels.height.toDouble());
        for (final (label, color) in [
          ('primary text', scheme.onSurface),
          ('secondary text', scheme.onSurfaceVariant),
          ('tertiary text (guarded)', look.guard(colors.textTertiary)),
          ('accent (guarded)', look.guard(scheme.primary)),
          ('danger (guarded)', look.guard(colors.danger)),
          ('warning (guarded)', look.guard(colors.warning)),
          ('info (guarded)', look.guard(colors.info)),
          ('success (guarded)', look.guard(colors.success)),
        ]) {
          // On the page itself, and (dark) on a card's or pill's thin white over it.
          for (final lift in {0.0, look.lift}) {
            final worst = pixels.worstContrast(color, whole, lift: lift);
            expect(worst, greaterThanOrEqualTo(4.5), reason: '$label on the $name picture, $mode, lift $lift: $worst');
          }
        }
      });

      testWidgets('$name picture, $mode page: the bars at the top and bottom are calmer still', (tester) async {
        final frame = phoneFrame(brightness);
        final image = await bake(tester, fixtureWallpaper(path, tone: 0), frame);
        final pixels = (await tester.runAsync(() => Pixels.of(image)))!;
        image.dispose();
        final look = frame.look;
        final k = pixels.width / frame.size.width;
        final w = pixels.width.toDouble();
        final h = pixels.height.toDouble();
        for (final band in [
          Rect.fromLTWH(0, 0, w, frame.top * k),
          Rect.fromLTWH(0, h - frame.bottom * k, w, frame.bottom * k),
        ]) {
          final (lo, hi) = pixels.luminanceRange(band, lift: look.lift);
          if (look.dark) {
            expect(hi, lessThanOrEqualTo(look.edgeBound + 0.003), reason: '$band');
          } else {
            expect(lo, greaterThanOrEqualTo(look.edgeBound - 0.01), reason: '$band');
          }
        }
      });
    }
  }

  testWidgets('every palette keeps its secondary text readable on both pictures', (tester) async {
    for (final accent in AppAccent.presets) {
      for (final brightness in Brightness.values) {
        final frame = phoneFrame(brightness, accent: accent);
        for (final path in [brightFixture, darkFixture]) {
          final image = await bake(tester, fixtureWallpaper(path, tone: 0), frame, density: 0.5);
          final pixels = (await tester.runAsync(() => Pixels.of(image)))!;
          image.dispose();
          final scheme = brightness == Brightness.dark ? DshPalette.darkScheme(accent) : DshPalette.lightScheme(accent);
          final whole = Rect.fromLTWH(0, 0, pixels.width.toDouble(), pixels.height.toDouble());
          final worst = pixels.worstContrast(scheme.onSurfaceVariant, whole, lift: frame.look.lift);
          expect(worst, greaterThanOrEqualTo(4.5), reason: '${accent.id} ${brightness.name} $path: $worst');
        }
      }
    }
  });

  testWidgets('the softer it is, the smaller it bakes; sharp, the screen\'s own pixels', (tester) async {
    final frame = phoneFrame(Brightness.light);
    final sharp = await bake(tester, fixtureWallpaper(brightFixture, blur: 0), frame);
    final soft = await bake(tester, fixtureWallpaper(brightFixture, blur: 1), frame);
    expect((sharp.width, sharp.height), (780, 1688));
    expect(soft.width, (390 * 0.75).round());
    sharp.dispose();
    soft.dispose();
  });

  testWidgets('lightweight: half the blur, at most σ 12, one pixel a dp', (tester) async {
    expect(WallpaperBake.sigmaFor(1), WallpaperBake.maxSigma);
    expect(WallpaperBake.sigmaFor(1, lightweight: true), WallpaperBake.lightSigma);
    expect(WallpaperBake.sigmaFor(0.3, lightweight: true), moreOrLessEquals(0.3 * WallpaperBake.maxSigma / 2));
    final frame = phoneFrame(Brightness.dark, lightweight: true);
    expect(WallpaperBake.densityFor(frame, 0), 1);
    final image = await bake(tester, fixtureWallpaper(darkFixture, blur: 0), frame);
    expect((image.width, image.height), (390, 844));
    image.dispose();
  });

  testWidgets('unguarded: no veil, and at 0 / 0 the picture itself at the screen\'s own pixels', (tester) async {
    // A bright picture on a dark page, on a lightweight device: everything the guard would calm.
    final frame = phoneFrame(Brightness.dark, lightweight: true);
    final w = fixtureWallpaper(brightFixture, blur: 0, tone: 0);
    final guarded = await bake(tester, w, frame);
    final plain = await bake(tester, w.copyWith(guard: false), frame);
    expect((guarded.width, guarded.height), (390, 844));
    expect((plain.width, plain.height), (780, 1688), reason: 'not the lightweight profile\'s fewer pixels');
    final source = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File(brightFixture).readAsBytesSync());
      return (await codec.getNextFrame()).image;
    }))!;
    final veiled = (await tester.runAsync(() => Pixels.of(guarded)))!;
    final baked = (await tester.runAsync(() => Pixels.of(plain)))!;
    final file = (await tester.runAsync(() => Pixels.of(source)))!;
    for (final image in [guarded, plain, source]) {
      image.dispose();
    }
    final look = frame.look;
    final (_, top) = veiled.luminanceRange(Rect.fromLTWH(0, 0, 390, frame.top), lift: look.lift);
    expect(top, lessThanOrEqualTo(look.edgeBound + 0.003));
    // The screen's window of the file, and nothing over it.
    final window = w.window(frame.size);
    final ours = baked.mean(Rect.fromLTWH(0, 0, 780, 1688));
    final theirs = file.mean(window);
    for (final (a, b) in [(ours.r, theirs.r), (ours.g, theirs.g), (ours.b, theirs.b)]) {
      expect(a, moreOrLessEquals(b, epsilon: 2 / 255));
    }
    // Only the slider: 压暗 at 50% lays 40% of the page's veil over it.
    final toned = await bake(tester, w.copyWith(guard: false, dim: 0.5), frame, density: 0.5);
    final dim = (await tester.runAsync(() => Pixels.of(toned)))!.mean(const Rect.fromLTWH(0, 0, 195, 20));
    toned.dispose();
    final sky = baked.mean(const Rect.fromLTWH(0, 0, 780, 80));
    final expected = Color.lerp(sky, look.veilTop, 0.5 * WallpaperBake.maxTone)!;
    expect(dim.computeLuminance(), moreOrLessEquals(expected.computeLuminance(), epsilon: 0.02));
    // And the blur slider's own σ, where a guarded picture gets the lightweight profile's.
    expect(WallpaperBake.sigmaOf(w.copyWith(blur: 1), frame), WallpaperBake.lightSigma);
    expect(WallpaperBake.sigmaOf(w.copyWith(blur: 1, guard: false), frame), WallpaperBake.maxSigma);
  });

  testWidgets('decoded once: both modes and the small phones reuse it; zooming in decodes larger', (tester) async {
    final renderer = WallpaperRenderer();
    addTearDown(renderer.release);
    final w = fixtureWallpaper(brightFixture);
    Future<void> run(CustomWallpaper w, WallpaperFrame frame, {double? density}) async =>
        (await tester.runAsync(() => renderer.bake(w, frame, density: density)))!.dispose();
    await run(w, phoneFrame(Brightness.light));
    await run(w, phoneFrame(Brightness.dark));
    await run(w.copyWith(blur: 0.8, lighten: 0.6), phoneFrame(Brightness.light));
    await run(w, phoneFrame(Brightness.light), density: 0.6);
    expect(renderer.decodes, 1);
    await run(w.copyWith(zoom: 3), phoneFrame(Brightness.light));
    expect(renderer.decodes, 2);
    await run(w, phoneFrame(Brightness.dark));
    expect(renderer.decodes, 2);
  });

  testWidgets('an animation bakes its first frame', (tester) async {
    final frame = phoneFrame(Brightness.light);
    final image = await bake(tester, fixtureWallpaper(gifFixture, blur: 0, tone: 0), frame, density: 0.5);
    final pixels = (await tester.runAsync(() => Pixels.of(image)))!;
    image.dispose();
    // The pale first frame (#DDE8F7), not the black second one.
    final mean = pixels.mean(Rect.fromLTWH(0, 0, pixels.width.toDouble(), pixels.height.toDouble()));
    expect(mean.computeLuminance(), greaterThan(0.6));
  });

  testWidgets('a broken picture or a missing file bakes to nothing; the next one still bakes', (tester) async {
    final renderer = WallpaperRenderer();
    addTearDown(renderer.release);
    final frame = phoneFrame(Brightness.light);
    expect(await tester.runAsync(() => renderer.bake(fixtureWallpaper(brokenFixture), frame)), isNull);
    expect(
      await tester.runAsync(() => renderer.bake(fixtureWallpaper('test/wallpaper/fixtures/gone.png'), frame)),
      isNull,
    );
    final image = await tester.runAsync(() => renderer.bake(fixtureWallpaper(pngFixture), frame));
    expect(image, isNotNull);
    image!.dispose();
  });

  test('guarded colours read at 4.6 on the bound; the ones that already did are untouched', () {
    for (final brightness in Brightness.values) {
      final look = WallpaperLook.forAccent(AppAccent.mist, brightness);
      final scheme = brightness == Brightness.dark
          ? DshPalette.darkScheme(AppAccent.mist)
          : DshPalette.lightScheme(AppAccent.mist);
      final colors = DshColors.forAccent(brightness, AppAccent.mist);
      expect(look.guard(scheme.onSurface), scheme.onSurface);
      expect(look.guard(scheme.onSurfaceVariant), scheme.onSurfaceVariant);
      for (final c in [colors.textTertiary, scheme.primary, colors.danger, colors.warning, colors.info]) {
        expect(look.worstContrast(look.guard(c)), greaterThanOrEqualTo(wallpaperContrast - 0.01));
      }
      final guarded = look.guardTheme(buildThemeFor(brightness));
      expect(guarded.extension<DshColors>()!.textTertiary, look.guard(colors.textTertiary));
      expect(guarded.colorScheme.primary, look.guard(scheme.primary));
    }
  });
}
