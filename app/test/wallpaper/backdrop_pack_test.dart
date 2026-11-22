// A theme pack's own backdrop (where its glows sit, its texture, its picture) is painted by the
// page's one painter: a band of the page a BackdropVeil repaints over the content carries the
// same texture and picture on the same pixels. A texture is there on the first frame; a blurred
// still is softened once; the picture stays up while another size of it decodes and under a
// covered page, which lets its decoder go.

import 'dart:io';

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/wallpaper/wallpaper_frames.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _page = ValueKey('page');
const _ink = Color(0xFFFF0000);
const _content = Color(0xFF0000FF);

ThemeData _theme(ThemeSurfaceSpec surfaces, {String? folder, int revision = 0}) => buildLightTheme(
  themePack: ThemePack(
    id: 'seams',
    name: 'Seams',
    palette: const ThemePaletteSpec(light: ThemeColorOverrides(patternInk: 0xFFFF0000)),
    surfaces: surfaces,
    folderPath: folder,
    assetRevision: revision,
  ),
);

/// Content all over the page, and the bottom 100 dp of the backdrop repainted over it.
Widget _veiled() => Stack(
  fit: StackFit.expand,
  children: [
    const ColoredBox(color: _content),
    BackdropVeil(solidHeight: ValueNotifier(100), feather: 0),
  ],
);

void main() {
  /// A 200 × 300 dp page at 2×.
  void phone(WidgetTester tester) {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.reset);
  }

  /// The page as it is drawn now.
  Future<Pixels> drawn(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_page));
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final pixels = await Pixels.of(image);
      image.dispose();
      return pixels;
    }))!;
  }

  /// Real time for a decode or a bake, then a frame.
  Future<void> wait(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The page under [theme] on its first frame, or (a picture is decoded off the frame, in real
  /// time: however long a busy machine takes) once [landed] says it is in.
  Future<Pixels> shot(
    WidgetTester tester,
    ThemeData theme, {
    Widget? over,
    bool scoped = true,
    bool Function(Pixels)? landed,
  }) async {
    phone(tester);
    final app = MaterialApp(
      // A new app each time: the same one would fade from the last theme.
      key: UniqueKey(),
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: _page,
        child: AppBackdrop(child: over ?? const SizedBox.expand()),
      ),
    );
    await tester.pumpWidget(scoped ? ProviderScope(child: app) : app);
    var pixels = await drawn(tester);
    for (var i = 0; i < 150 && landed != null && !landed(pixels); i++) {
      await wait(tester);
      pixels = await drawn(tester);
    }
    return pixels;
  }

  /// How many pixels differ, in rows [from] up to [to]. Not by one level: the band's layer
  /// rounds a pixel of the plain gradient that way now and then.
  int differing(Pixels a, Pixels b, {int from = 0, int to = 600}) {
    var n = 0;
    for (var i = from * 400 * 4; i < to * 400 * 4; i += 4) {
      for (var c = i; c < i + 3; c++) {
        if ((a.rgba[c] - b.rgba[c]).abs() > 1) {
          n++;
          break;
        }
      }
    }
    return n;
  }

  testWidgets('textures: each is there on the first frame; dots sit on the page\'s grid, in a veil\'s band too', (
    tester,
  ) async {
    final plain = await shot(tester, _theme(const ThemeSurfaceSpec()));
    for (final pattern in ThemeBackdropPattern.values.skip(1)) {
      final textured = await shot(tester, _theme(ThemeSurfaceSpec(pattern: pattern, patternOpacity: 1)));
      expect(differing(textured, plain), greaterThan(400), reason: pattern.name);
    }
    expect(tester.takeException(), isNull);

    // 24 dp apart from the page's corner: at 2×, a dot on (24, 24) and every 48 px on.
    const dots = ThemeSurfaceSpec(pattern: ThemeBackdropPattern.dots, patternOpacity: 1);
    final page = await shot(tester, _theme(dots));
    expect(page.at(24, 24), _ink);
    expect(page.at(48, 48), plain.at(48, 48));
    final veiled = await shot(tester, _theme(dots), over: _veiled());
    expect(veiled.at(24, 24), _content, reason: 'above the band, the content');
    // The band is the bottom 200 px: the same dots on the same pixels, the page between them.
    expect(veiled.at(24, 552), _ink);
    expect(veiled.at(48, 576), page.at(48, 576));
    expect(differing(veiled, page, from: 402), 0, reason: 'the band is the page, pixel for pixel');
  });

  testWidgets('glows: each layout puts the two somewhere else', (tester) async {
    final shots = {
      for (final layout in ThemeGlowLayout.values)
        layout: await shot(tester, _theme(ThemeSurfaceSpec(glowLayout: layout))),
    };
    final corners = shots[ThemeGlowLayout.corners]!;
    // The secondary glow leaves the bottom left for the top; the primary one the top right.
    expect(shots[ThemeGlowLayout.top]!.at(0, 599), isNot(corners.at(0, 599)));
    expect(shots[ThemeGlowLayout.top]!.at(399, 0), corners.at(399, 0));
    expect(shots[ThemeGlowLayout.bottom]!.at(399, 0), isNot(corners.at(399, 0)));
    expect(shots[ThemeGlowLayout.bottom]!.at(0, 599), corners.at(0, 599));
    expect(shots[ThemeGlowLayout.center]!.at(399, 0), isNot(corners.at(399, 0)));
    expect(shots[ThemeGlowLayout.center]!.at(0, 599), isNot(corners.at(0, 599)));
  });

  testWidgets('the pack\'s picture: covering or tiled a pixel a dp, blurred once, and in a veil\'s band too', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('backdrop-pack');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/bg.png').writeAsBytesSync(File(pngFixture).readAsBytesSync());
    final plain = await shot(tester, _theme(const ThemeSurfaceSpec()));
    bool pictured(Pixels p) => differing(p, plain) > 400 * 300;
    for (final (repeat, blur) in [(false, 0.0), (false, 6.0), (true, 0.0), (true, 6.0)]) {
      final surfaces = ThemeSurfaceSpec(
        backdropImage: 'bg.png',
        backdropOpacity: 1,
        backdropRepeat: repeat,
        backdropBlur: blur,
      );
      final theme = _theme(surfaces, folder: dir.path);
      final softened = AppBackdrop.softened;
      final page = await shot(tester, theme, landed: pictured);
      expect(pictured(page), isTrue, reason: 'repeat $repeat, blur $blur');
      final veiled = await shot(tester, theme, over: _veiled(), landed: (p) => differing(p, page, from: 402) == 0);
      expect(differing(veiled, page, from: 402), 0, reason: 'repeat $repeat, blur $blur: the band is the page');
      expect(veiled.at(200, 100), _content);
      // Not as the page and each band are painted: once, for all of them.
      expect(AppBackdrop.softened - softened, blur > 0 ? 1 : 0, reason: 'repeat $repeat');
      if (repeat && blur == 0) {
        // The fixture (yellow down to teal, 200 px tall) from the page's corner, a pixel a dp:
        // its seam is 200 dp down, 400 px here, and there is none at 200 px.
        double jump(int y) => (page.at(100, y - 4).r - page.at(100, y + 4).r).abs();
        expect(jump(400), greaterThan(0.3));
        expect(jump(200), lessThan(0.1));
      }
    }
    // Outside a ProviderScope (a bare preview) the picture is left out; nothing is thrown.
    const surfaces = ThemeSurfaceSpec(backdropImage: 'bg.png', backdropOpacity: 1);
    final bare = await shot(tester, _theme(surfaces, folder: dir.path), scoped: false);
    expect(differing(bare, plain), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picture stays up while another size of it decodes, and under a covered page (no decoder then)', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('backdrop-pack');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/bg.gif').writeAsBytesSync(File(gifFixture).readAsBytesSync());
    final plain = await shot(tester, _theme(const ThemeSurfaceSpec()));
    bool pictured(Pixels p) => differing(p, plain) > 400 * 300;
    var opened = 0, closed = 0;
    final decoders = pictureFramesProvider.overrideWith((ref, source) {
      opened++;
      final frames = FrameLoop(() => openFrames(source), loop: source.loop)..playing = true;
      ref.onDispose(() {
        closed++;
        frames.dispose();
      });
      return frames;
    });
    Future<void> show({int revision = 0, bool covered = false}) => tester.pumpWidget(
      ProviderScope(
        // Not the scope the plain page above was drawn in.
        key: const ValueKey('counted'),
        overrides: [decoders],
        child: MaterialApp(
          theme: _theme(
            const ThemeSurfaceSpec(backdropImage: 'bg.gif', backdropOpacity: 1),
            folder: dir.path,
            revision: revision,
          ),
          themeAnimationDuration: Duration.zero,
          home: RepaintBoundary(
            key: _page,
            child: TickerMode(
              enabled: !covered,
              child: const AppBackdrop(child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 150 && !done(); i++) {
        await wait(tester);
      }
    }

    await show();
    var page = await drawn(tester);
    for (var i = 0; i < 150 && !pictured(page); i++) {
      await wait(tester);
      page = await drawn(tester);
    }
    expect(pictured(page), isTrue);

    // The file changed: decoded anew, and on this very frame nothing of the new one is in yet.
    await show(revision: 1);
    expect(opened, 2);
    expect(pictured(await drawn(tester)), isTrue, reason: 'the frame that was up stays until the next is in');
    await until(() => closed == 1);

    await show(revision: 1, covered: true);
    await until(() => closed == 2);
    expect((opened, closed), (2, 2), reason: 'nobody watches: no decoder');
    expect(pictured(await drawn(tester)), isTrue, reason: 'its frame is still up for when the page is back');

    await show(revision: 1);
    expect(opened, 3);
    expect(pictured(await drawn(tester)), isTrue);
  });
}
