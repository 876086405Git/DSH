// A moving picture's frames: one at a time, each held for its own time (30 a second at most,
// 100 ms when it doesn't say), the one before let go as the next goes up; paused and resumed,
// stopped for good when disposed. A real GIF through the shared provider: its frames one after
// another, paused while the app is off screen (not while it is only out of focus).
//
// On the page: a frame is painted the way the bake draws the still (same framing, blur and
// tone), and an animated wallpaper plays over that bake unless motion is reduced. A scene's
// picture (a tavern chat's) never plays. A new frame repaints the backdrop's own layers only.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/wallpaper/wallpaper_backdrop.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_frames.dart';
import 'package:dsh_app/wallpaper/wallpaper_look.dart';
import 'package:dsh_app/wallpaper/wallpaper_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Frame implements ui.FrameInfo {
  _Frame(this.image, this.duration);

  @override
  final ui.Image image;
  @override
  final Duration duration;
}

/// Hands out clones of [stills] in a loop, each lasting [duration].
class _Codec implements ui.Codec {
  _Codec(this.stills, this.duration);

  final List<ui.Image> stills;
  Duration duration;
  final served = <ui.Image>[];
  bool disposed = false;

  @override
  int get frameCount => stills.length;

  @override
  int get repetitionCount => -1;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final image = stills[served.length % stills.length].clone();
    served.add(image);
    return _Frame(image, duration);
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  Future<_Codec> codecOf(WidgetTester tester, int frames, Duration duration) async {
    final stills = [
      for (var i = 0; i < frames; i++) (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!,
    ];
    addTearDown(() {
      for (final still in stills) {
        still.dispose();
      }
    });
    return _Codec(stills, duration);
  }

  testWidgets('one frame at a time, each for its own time; paused, resumed, disposed', (tester) async {
    final codec = await codecOf(tester, 3, Duration.zero);
    final loop = FrameLoop(() async => codec);
    var painted = 0;
    loop.addListener(() => painted++);
    expect(loop.value, isNull);

    loop.playing = true;
    await tester.pump();
    expect(loop.value, same(codec.served.single));
    // A frame that doesn't say how long: 100 ms.
    await tester.pump(const Duration(milliseconds: 60));
    expect(codec.served, hasLength(1));
    await tester.pump(const Duration(milliseconds: 40));
    expect(codec.served, hasLength(2));
    expect(loop.value, same(codec.served.last));
    expect(codec.served.first.debugDisposed, isTrue, reason: 'only the frame up is kept');
    expect(painted, 2);

    // Faster than 30 a second: held to 33 ms.
    codec.duration = const Duration(milliseconds: 10);
    await tester.pump(const Duration(milliseconds: 100));
    expect(codec.served, hasLength(3));
    await tester.pump(const Duration(milliseconds: 20));
    expect(codec.served, hasLength(3));
    await tester.pump(const Duration(milliseconds: 13));
    expect(codec.served, hasLength(4));

    loop.playing = false;
    await tester.pump(const Duration(seconds: 2));
    expect(codec.served, hasLength(4));
    expect(loop.value!.debugDisposed, isFalse, reason: 'the frame up stays up');
    loop.playing = true;
    await tester.pump();
    expect(codec.served, hasLength(5));

    final up = loop.value!;
    loop.dispose();
    expect(up.debugDisposed, isTrue);
    expect(codec.disposed, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(codec.served, hasLength(5));
    expect(codec.served.every((frame) => frame.debugDisposed), isTrue);
  });

  testWidgets('a still, or an animation asked for its first frame: one frame, then the decoder goes', (tester) async {
    for (final (frames, loops) in [(1, true), (3, false)]) {
      final codec = await codecOf(tester, frames, const Duration(milliseconds: 40));
      // Not playing (made while the app is hidden): the one frame comes all the same.
      final loop = FrameLoop(() async => codec, loop: loops);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(codec.served, hasLength(1));
      expect(loop.value, isNotNull);
      expect(codec.disposed, isTrue);
      loop.dispose();
    }
  });

  testWidgets('a GIF through the provider: frame after frame, paused with the app', (tester) async {
    final container = ProviderContainer();
    const source = FrameSource(path: gifFixture, coverWidth: 120, coverHeight: 200);
    final frames = container.listen(pictureFramesProvider(source), (_, _) {}).read();
    // The decoder answers in real time; the frame's own time is the test clock's.
    Future<void> wait(bool Function() until) async {
      for (var i = 0; i < 200 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await wait(() => frames.value != null);
    final first = frames.value!;
    expect((first.width, first.height), (120, 200));
    await wait(() => !identical(frames.value, first));
    expect(first.debugDisposed, isTrue);
    expect(frames.value, isNotNull);

    // Out of focus (the other half of a split screen has it) is still on screen; hidden isn't.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(frames.playing, isTrue);
    const away = [AppLifecycleState.hidden, AppLifecycleState.paused];
    away.forEach(tester.binding.handleAppLifecycleStateChanged);
    expect(frames.playing, isFalse);
    const back = [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed];
    back.forEach(tester.binding.handleAppLifecycleStateChanged);
    expect(frames.playing, isTrue);

    container.dispose();
    expect(frames.value, isNull);
  });

  testWidgets('a frame is painted as the bake draws the still: framing, blur, tone', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.reset);
    const w = CustomWallpaper(
      path: brightFixture,
      width: 720,
      height: 1280,
      zoom: 1.6,
      alignX: 0.6,
      alignY: -0.4,
      blur: 0.2,
      lighten: 0.5,
    );
    final look = WallpaperLook.forAccent(AppAccent.mist, Brightness.light);
    final frame = WallpaperFrame(size: const Size(200, 300), pixelRatio: 2, look: look);
    final bake = (await tester.runAsync(() => WallpaperRenderer().bake(w, frame, moving: true)))!;
    final still = (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File(brightFixture).readAsBytesSync());
      return (await codec.getNextFrame()).image;
    }))!;
    addTearDown(bake.dispose);
    addTearDown(still.dispose);
    final window = w.window(frame.size);
    final live = BackdropLive(
      frames: ValueNotifier(still),
      window: Rect.fromLTRB(window.left / 720, window.top / 1280, window.right / 720, window.bottom / 1280),
      veilTop: look.veilTop,
      veilBottom: look.veilBottom,
      sigma: WallpaperBake.sigmaFor(w.blur),
      tone: 0.5 * WallpaperBake.maxTone,
    );

    const page = ValueKey('page');
    Future<Pixels> shot(BackdropPicture picture) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: RepaintBoundary(
            key: page,
            child: AppBackdrop(picture: picture, child: const SizedBox.expand()),
          ),
        ),
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(page));
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final pixels = await Pixels.of(image);
        image.dispose();
        return pixels;
      }))!;
    }

    final baked = await shot(BackdropPicture(image: bake));
    final played = await shot(BackdropPicture(image: bake, live: live));
    // The sun, the rocks and the shoreline land in the same cells at the same strength.
    for (var row = 0; row < 6; row++) {
      for (var col = 0; col < 4; col++) {
        final cell = Rect.fromLTWH(col * 100.0, row * 100.0, 100, 100);
        final a = baked.mean(cell);
        final b = played.mean(cell);
        for (final (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)]) {
          expect(x, moreOrLessEquals(y, epsilon: 3 / 255), reason: '$cell: $a, $b');
        }
      }
    }
  });

  testWidgets('an animated wallpaper plays over its bake; with motion reduced, the bake alone', (tester) async {
    const w = CustomWallpaper(path: gifFixture, width: 120, height: 200, animated: true);
    SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: jsonOf(w)});
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const WallpaperBackdrop(child: SizedBox.expand()),
        ),
      ),
    );
    BackdropPicture? picture() => tester.widget<AppBackdrop>(find.byType(AppBackdrop)).picture;
    Future<void> wait(bool Function() until) async {
      for (var i = 0; i < 200 && !until(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await wait(() => picture()?.live?.frames.value != null);
    expect(picture()!.image, isNotNull, reason: 'the first frame, baked, under the frames');
    final frames = picture()!.live!.frames;
    expect(frames.value, isNotNull);

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    await wait(() => picture()?.image != null && picture()!.live == null);
    expect(picture()!.image, isNotNull);
    expect(picture()!.live, isNull);
    // Nothing shows it now: the decoder is let go.
    await wait(() => frames.value == null);
    expect(frames.value, isNull);
  });

  testWidgets('a scene\'s picture never plays and is always guarded, whatever it says of itself', (tester) async {
    // A tavern chat's GIF as the import hands it over, and unguarded besides: its page has no
    // switch for either.
    const w = CustomWallpaper(path: gifFixture, width: 120, height: 200, blur: 0, dim: 0, guard: false, animated: true);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(400, 600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const WallpaperBackdrop.scene(picture: w, child: SizedBox.expand()),
        ),
      ),
    );
    BackdropPicture? picture() => tester.widget<AppBackdrop>(find.byType(AppBackdrop)).picture;
    for (var i = 0; i < 200 && picture()?.image == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(picture()!.live, isNull);
    // The pale first frame under a dark page: veiled, as any still is.
    final pixels = (await tester.runAsync(() => Pixels.of(picture()!.image!)))!;
    final mean = pixels.mean(Rect.fromLTWH(0, 0, pixels.width.toDouble(), pixels.height.toDouble()));
    expect(mean.computeLuminance(), lessThan(0.2));
  });

  testWidgets('a new frame repaints the backdrop and its bands, not the page between them', (tester) async {
    final stills = [for (var i = 0; i < 2; i++) (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!];
    addTearDown(() {
      for (final still in stills) {
        still.dispose();
      }
    });
    final frames = ValueNotifier<ui.Image?>(stills.first);
    const black = Color(0xFF000000);
    final live = BackdropLive(
      frames: frames,
      window: Offset.zero & const Size(1, 1),
      veilTop: black,
      veilBottom: black,
    );
    var painted = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: AppBackdrop(
          picture: BackdropPicture(image: stills.first, live: live),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(painter: _Counted(() => painted++)),
              BackdropVeil(solidHeight: ValueNotifier(40)),
              // A page's top bar before anything has scrolled under it.
              Opacity(opacity: 0, child: BackdropVeil.top(height: 40)),
            ],
          ),
        ),
      ),
    );
    final before = painted;
    for (final still in stills.reversed) {
      frames.value = still;
      await tester.pump();
    }
    expect(painted, before);
  });
}

class _Counted extends CustomPainter {
  _Counted(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_Counted old) => false;
}
