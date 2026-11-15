// Pixel art stays sharp (docs/design/pets.md §2.10, §11): at device pixel
// ratios 2.0 / 2.625 / 2.75 / 3.0 / 3.5 every art pixel of 鲸娘 is the same
// whole number of device pixels (blocks of one colour, no blending), and
// Deepy's 5× sheets are sampled nearest-neighbour: no colour on screen that
// is not in the sheet.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/ui/pets/pet_sprite.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const ratios = [2.0, 2.625, 2.75, 3.0, 3.5];

/// Renders [anim]'s first frame at [size] on a [dpr] view, at the origin of a
/// repaint boundary (a device-pixel corner), and returns its RGBA bytes.
Future<(Uint8List, int, int, int)> render(
  WidgetTester tester,
  PetPack pack,
  PetAnimation anim,
  PetSize size,
  double dpr,
) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(400 * dpr, 400 * dpr);
  addTearDown(tester.view.reset);
  await warmSheets(tester, pack, [anim]);
  final k = petDevicePixels(pack, size, dpr);
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          child: PetSprite(pack: pack, anim: anim, scale: k / dpr, still: true),
        ),
      ),
    ),
  );
  await tester.pump();
  final bytes = await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final data = await image.toByteData();
    final w = image.width;
    final h = image.height;
    image.dispose();
    return (data!.buffer.asUint8List(), w, h);
  });
  return (bytes!.$1, bytes.$2, bytes.$3, k);
}

int px(Uint8List rgba, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return rgba[i] << 24 | rgba[i + 1] << 16 | rgba[i + 2] << 8 | rgba[i + 3];
}

void main() {
  tearDown(PetSheets.instance.clear);

  for (final dpr in ratios) {
    for (final size in PetSize.presets) {
      testWidgets('鲸娘 at ${dpr}x, ${size.name}: whole device pixels per art pixel, one colour each', (tester) async {
        final anim = girl.animFor(PetStateName.idle);
        final (rgba, w, h, k) = await render(tester, girl, anim, size, dpr);
        expect(w, girl.canvas.width * k);
        expect(h, girl.canvas.height * k);
        var painted = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final c = px(rgba, w, x, y);
            if (c & 0xff != 0) painted++;
            // The art pixel's top-left device pixel holds its one colour.
            expect(c, px(rgba, w, x - x % k, y - y % k), reason: 'block at ($x, $y), k $k');
          }
        }
        expect(painted, greaterThan(500));
      });
    }

    testWidgets('Deepy at ${dpr}x: nearest-neighbour from the 5× sheet, no blended colours', (tester) async {
      final anim = deepy.animFor(PetStateName.idle);
      final (rgba, w, h, k) = await render(tester, deepy, anim, PetSize.medium, dpr);
      // Colours of the first cell on the sheet.
      final palette = await tester.runAsync(() async {
        final sheet = PetSheets.instance.peek(deepy, anim)!;
        final data = (await sheet.toByteData())!.buffer.asUint8List();
        final src = anim.sourceRect(anim.frames.first.i);
        final colours = <int>{};
        for (var y = src.top.toInt(); y < src.bottom; y++) {
          for (var x = src.left.toInt(); x < src.right; x++) {
            colours.add(px(data, sheet.width, x, y));
          }
        }
        sheet.dispose();
        return colours;
      });
      var painted = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final c = px(rgba, w, x, y);
          if (c & 0xff == 0) continue;
          painted++;
          expect(palette!.contains(c), isTrue, reason: 'blended colour at ($x, $y), k $k');
        }
      }
      expect(painted, greaterThan(500));
    });
  }

  test('sizes: whole device pixels, the three always differ', () {
    for (final dpr in ratios) {
      for (final pack in [deepy, girl]) {
        final ks = [for (final s in PetSize.presets) petDevicePixels(pack, s, dpr)];
        expect(ks[0] < ks[1] && ks[1] < ks[2], isTrue, reason: '${pack.id} at $dpr: $ks');
        // Standard is the doc's formula (round(30 dp × dpr ÷ body)) unless
        // that equals small.
        final standard = (30 * dpr / pack.contentBox.height).round();
        if (standard > ks[0]) expect(ks[1], standard);
      }
    }
  });

  test('自定义 rounds its own height to whole device pixels', () {
    for (final dpr in ratios) {
      for (final pack in [deepy, girl]) {
        for (final dp in [15.0, 30.0, 45.0, 90.0]) {
          final k = petDevicePixels(pack, PetSize.custom, dpr, customHeight: dp);
          expect(k, math.max(1, (dp * dpr / pack.contentBox.height).round()), reason: '${pack.id} at $dpr, $dp dp');
          expect(petScale(pack, PetSize.custom, dpr, customHeight: dp), k / dpr);
        }
      }
    }
  });

  test('the out-of-app overlay uses the same k: pinned here and in PetPackTest.kt', () {
    // The floating pet (Kotlin PetPack.screenScale / devicePixels) must draw
    // at these numbers too, else it is a size off from the chat page. The
    // same table is asserted in
    // app/android/app/src/test/kotlin/io/github/ccch1mneyyy/dsh_app/pet/PetPackTest.kt
    // (`screenScaleMatchesTheAppForTheShippedPacks`): change one, change both.
    const expected = [
      ('whale-girl', 2.0, [1, 2, 3]),
      ('whale-girl', 2.625, [1, 2, 3]),
      ('whale-girl', 2.75, [1, 2, 3]),
      ('whale-girl', 3.0, [1, 2, 3]),
      ('whale-girl', 3.5, [2, 3, 4]),
      ('deepy-whale', 2.0, [2, 3, 4]),
      ('deepy-whale', 2.625, [3, 4, 5]),
      ('deepy-whale', 2.75, [3, 4, 5]),
      ('deepy-whale', 3.0, [3, 4, 5]),
      ('deepy-whale', 3.5, [4, 5, 6]),
    ];
    final packs = {'whale-girl': girl, 'deepy-whale': deepy};
    for (final (id, dpr, ks) in expected) {
      final pack = packs[id]!;
      expect([for (final s in PetSize.presets) petDevicePixels(pack, s, dpr)], ks, reason: '$id at $dpr×');
    }
  });
}
