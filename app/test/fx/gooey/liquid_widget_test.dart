// Portions derived from Libraries.dev Gooey (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:ui' as ui;

import 'package:dsh_app/ui/fx/gooey/gooey.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

const _fill = Color(0xFF3A4FB0);
const _page = Color(0xFFFFFFFF);

/// A ＋ with one satellite that flies [dy] up when [open].
class _Menu extends StatelessWidget {
  const _Menu({required this.open, this.dy = -64});

  final bool open;
  final double dy;

  @override
  Widget build(BuildContext context) {
    Widget round(Key key) => LiquidItem(
      key: key,
      y: key == const ValueKey('sat') && open ? dy : 0,
      transition: open ? LiquidMenu.open : LiquidMenu.close,
      radius: BorderRadius.circular(999),
      child: const SizedBox.square(dimension: 40),
    );
    return Liquid(
      fill: _fill,
      child: SizedBox(
        width: 200,
        height: 140,
        child: Stack(
          children: [
            Positioned(left: 80, top: 80, child: round(const ValueKey('sat'))),
            Positioned(left: 80, top: 80, child: round(const ValueKey('main'))),
          ],
        ),
      ),
    );
  }
}

Widget _app(Widget child, {bool reduced = false, double devicePixelRatio = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced, devicePixelRatio: devicePixelRatio),
    child: Center(
      child: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ColoredBox(color: _page, child: child),
      ),
    ),
  ),
);

Future<ui.Image> _shot(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  return (await tester.runAsync(() => boundary.toImage()))!;
}

Future<Color> _pixel(WidgetTester tester, ui.Image image, Offset at) async {
  final data = (await tester.runAsync(() => image.toByteData()))!;
  final i = (at.dy.round() * image.width + at.dx.round()) * 4;
  return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

/// Same colour, give or take 8-bit rounding through the blur.
Matcher _is(Color c) => predicate<Color>(
  (got) => (got.r - c.r).abs() < 0.01 && (got.g - c.g).abs() < 0.01 && (got.b - c.b).abs() < 0.01,
  'about $c',
);

/// The lowest liquid pixel in column [x], scanning down from [from].
Future<int> _bottom(WidgetTester tester, ui.Image image, int x, int from) async {
  final data = (await tester.runAsync(() => image.toByteData()))!;
  var last = from;
  for (var y = from; y < image.height; y++) {
    final i = (y * image.width + x) * 4;
    // The fill is blue, the page white: a pixel is liquid while its red is low.
    if (data.getUint8(i) < 160) last = y;
  }
  return last;
}

/// [n] frames of 16 ms: the engine caps a frame's step at 0.25 s, as the
/// original does, so a long pump is not a long simulation.
Future<void> _frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

double _satY(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(
    find.descendant(of: find.byKey(const ValueKey('sat')), matching: find.byType(SizedBox)),
  );
  return box.localToGlobal(Offset.zero).dy;
}

void main() {
  testWidgets('morph: the satellite springs out, the liquid follows it, the ＋ stays', (tester) async {
    await tester.pumpWidget(_app(const _Menu(open: false)));
    final closedY = _satY(tester);
    await tester.pumpWidget(_app(const _Menu(open: true)));
    await tester.pump(const Duration(milliseconds: 120));
    final midY = _satY(tester);
    expect(midY, lessThan(closedY));
    expect(midY, greaterThan(closedY - 64));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_satY(tester), closeTo(closedY - 64, 1e-6));
    expect(SchedulerBinding.instance.transientCallbackCount, 0);

    // Group 200×140: the ＋ centre is at (100, 100), the satellite's at (100, 36),
    // and 30 px right of the satellite is bare page.
    final image = await _shot(tester);
    expect(await _pixel(tester, image, const Offset(100, 100)), _is(_fill));
    expect(await _pixel(tester, image, const Offset(100, 36)), _is(_fill));
    expect(await _pixel(tester, image, const Offset(150, 36)), _is(_page));
    // Between them (40 px gap, blur 6) the goo has let go.
    expect(await _pixel(tester, image, const Offset(100, 68)), _is(_page));
    image.dispose();
  });

  testWidgets('morph: close pieces merge through a neck', (tester) async {
    await tester.pumpWidget(_app(const _Menu(open: false, dy: -44)));
    await tester.pumpWidget(_app(const _Menu(open: true, dy: -44)));
    await tester.pump(const Duration(seconds: 1));
    // 4 px apart: the goo bridges them at blur 6.
    final image = await _shot(tester);
    expect(await _pixel(tester, image, const Offset(100, 78)), _is(_fill));
    image.dispose();
  });

  testWidgets('reduced motion: morph snaps and nothing keeps ticking', (tester) async {
    await tester.pumpWidget(_app(const _Menu(open: false), reduced: true));
    final closedY = _satY(tester);
    await tester.pumpWidget(_app(const _Menu(open: true), reduced: true));
    expect(_satY(tester), closeTo(closedY - 64, 1e-6));
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  Widget slider(double left, {bool reduced = false, double devicePixelRatio = 1}) => _app(
    Liquid(
      fill: _fill,
      blur: LiquidTabs.blur,
      child: SizedBox(
        width: 240,
        height: 40,
        child: Stack(
          children: [
            Positioned(
              left: left,
              top: 5,
              child: LiquidItem(
                key: const ValueKey('thumb'),
                effect: LiquidEffect.move,
                radius: BorderRadius.circular(999),
                child: const SizedBox(width: 60, height: 30),
              ),
            ),
          ],
        ),
      ),
    ),
    reduced: reduced,
    devicePixelRatio: devicePixelRatio,
  );

  testWidgets('move: the liquid trails a jump, then the group falls asleep', (tester) async {
    await tester.pumpWidget(slider(0));
    await tester.pumpWidget(slider(160));
    // The piece jumped; its liquid has not caught up yet: the new spot's far
    // end is still bare, the old spot is still liquid.
    var image = await _shot(tester);
    expect(await _pixel(tester, image, const Offset(30, 20)), _is(_fill));
    expect(await _pixel(tester, image, const Offset(200, 20)), _is(_page));
    image.dispose();
    expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));
    await _frames(tester, 90);
    image = await _shot(tester);
    expect(await _pixel(tester, image, const Offset(190, 20)), _is(_fill));
    expect(await _pixel(tester, image, const Offset(30, 20)), _is(_page));
    image.dispose();
    // 30 still frames after it settles the ticker stops.
    await _frames(tester, 40);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('reduced motion: move stays glued to its piece', (tester) async {
    await tester.pumpWidget(slider(0, reduced: true));
    await tester.pumpWidget(slider(160, reduced: true));
    final image = await _shot(tester);
    expect(await _pixel(tester, image, const Offset(190, 20)), _is(_fill));
    expect(await _pixel(tester, image, const Offset(30, 20)), _is(_page));
    image.dispose();
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('bend: a dragged piece bows and settles back flat', (tester) async {
    Widget card(double dy) => _app(
      Liquid(
        fill: _fill,
        child: SizedBox(
          width: 320,
          height: 210,
          child: Center(
            child: Transform.translate(
              offset: Offset(0, dy),
              child: LiquidItem(
                effect: LiquidEffect.bend,
                radius: BorderRadius.circular(54),
                child: const SizedBox(width: 261, height: 46),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(card(0));
    for (var i = 1; i <= 6; i++) {
      await tester.pumpWidget(card(i * 8.0), duration: const Duration(milliseconds: 16));
    }
    // Dragged down fast: the middle of the bottom edge sags below its ends.
    var image = await _shot(tester);
    final middle = await _bottom(tester, image, 160, 105);
    final end = await _bottom(tester, image, 70, 105);
    expect(middle - end, greaterThan(3));
    image.dispose();
    await _frames(tester, 80);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
    image = await _shot(tester);
    expect(await _bottom(tester, image, 160, 105), await _bottom(tester, image, 70, 105));
    image.dispose();
  });

  testWidgets('theme fill follows the colour scheme', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32))),
        home: Builder(
          builder: (context) {
            final p = LiquidPalette.of(context);
            final hsl = HSLColor.fromColor(p.indicator);
            final seed = HSLColor.fromColor(Theme.of(context).colorScheme.primary);
            expect(hsl.hue, closeTo(seed.hue, 1));
            expect(hsl.saturation, lessThan(seed.saturation));
            expect(HSLColor.fromColor(p.surface).lightness, greaterThan(0.9));
            return const SizedBox();
          },
        ),
      ),
    );
  });

  testWidgets('a translucent fill keeps its alpha instead of being thresholded away', (tester) async {
    const page = Color(0xFF101010);
    const fill = Color(0x33FFFFFF); // 20% white, as the dark thumb
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('shot'),
            child: ColoredBox(
              color: page,
              child: Liquid(
                fill: fill,
                blur: LiquidTabs.blur,
                child: SizedBox(
                  width: 200,
                  height: 40,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 20,
                        top: 5,
                        child: LiquidItem(
                          key: const ValueKey('thumb'),
                          effect: LiquidEffect.move,
                          radius: BorderRadius.circular(999),
                          child: const SizedBox(width: 60, height: 30),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final image = await _shot(tester);
    final got = await _pixel(tester, image, const Offset(50, 20));
    // 20% white over the near-black page: the thumb is painted, not cut away.
    expect(got.r, closeTo(0.25, 0.02), reason: '20% white composited on the page');
    image.dispose();
  });

  testWidgets('the liquid edge is cut about one device pixel wide, not blurred', (tester) async {
    // A 3× screen, and captured at 3×.
    await tester.pumpWidget(slider(20, devicePixelRatio: 3));
    expect(MediaQuery.devicePixelRatioOf(tester.element(find.byType(Liquid))), 3);
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
    final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 3)))!;
    final data = (await tester.runAsync(() => image.toByteData()))!;
    int red(int x) => data.getUint8((60 * image.width + x) * 4); // the thumb's middle row, y 20
    // Across the thumb's left end (x 20 → 60 device px): page, then fill.
    expect(red(30), greaterThan(250));
    expect(red(90), lessThan(64));
    // Pixels part page, part fill. The 0.6 px softening blur this replaced left
    // about five; a one-pixel ramp leaves at most two.
    final lo = _fill.r * 255 + (255 - _fill.r * 255) * 0.1;
    final hi = 255 - (255 - _fill.r * 255) * 0.1;
    final partial = [for (var x = 30; x <= 90; x++) red(x)].where((r) => r > lo && r < hi).length;
    expect(partial, lessThanOrEqualTo(2));
    image.dispose();
  });

  test('the threshold steepens with the screen, never below the given contrast', () {
    expect(Liquid.slopeFor(18, LiquidTabs.blur, 1), 18);
    expect(Liquid.slopeFor(18, LiquidTabs.blur, 3), closeTo(26.9, 0.1));
  });

  testWidgets('an item outside a group is an error', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: LiquidItem(child: SizedBox()),
      ),
    );
    expect(tester.takeException(), isA<FlutterError>());
  });
}
