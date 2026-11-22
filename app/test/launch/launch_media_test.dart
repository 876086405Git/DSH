// Real GIF decoding through LaunchMedia: the final frame belongs to the round,
// including its hold time. These fixtures are tiny, synthetic, and asset-free.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_media.dart';
import 'package:dsh_app/launch/launch_motion.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/launch/launch_video.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A 1 x 1 GIF, alternating red and blue, with delays in centiseconds.
Uint8List _gif(List<int> delays) {
  final bytes = <int>[...ascii.encode('GIF89a'), 1, 0, 1, 0, 0x80, 0, 0, 255, 0, 0, 0, 0, 255];
  for (var i = 0; i < delays.length; i++) {
    bytes.addAll([
      0x21,
      0xf9,
      4,
      0,
      delays[i] & 255,
      delays[i] >> 8,
      0,
      0,
      0x2c,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      i.isEven ? 0x44 : 0x4c,
      1,
      0,
    ]);
  }
  return Uint8List.fromList([...bytes, 0x3b]);
}

/// Observes, but does not replace, the production decoder, timers or view.
class _ObservedMedia extends LaunchMedia {
  _ObservedMedia(this.inner, this.custom, this.durations) {
    inner.addListener(_changed);
  }

  final LaunchMedia inner;
  final CustomLaunch custom;
  final List<int> durations;
  int frameChanges = 0;
  int completions = 0;
  bool disposed = false;

  void _changed() {
    frameChanges++;
    notifyListeners();
  }

  @override
  Size get size => inner.size;

  @override
  Widget view() => inner.view();

  @override
  void play({VoidCallback? onDone}) => inner.play(
    onDone: () {
      completions++;
      onDone?.call();
    },
  );

  @override
  void dispose() {
    disposed = true;
    inner.removeListener(_changed);
    inner.dispose();
    super.dispose();
  }
}

Future<_ObservedMedia> _open(WidgetTester tester, List<int> delays) async {
  final dir = Directory.systemTemp.createTempSync('dsh-launch-frames-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/frames.gif')..writeAsBytesSync(_gif(delays));
  final media = (await tester.runAsync(() async {
    // Check the fixture using Flutter's real codec, independent of LaunchMedia.
    final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
    final durations = <int>[];
    expect(codec.frameCount, delays.length);
    for (var i = 0; i < codec.frameCount; i++) {
      final frame = await codec.getNextFrame();
      durations.add(frame.duration.inMilliseconds);
      frame.image.dispose();
    }
    codec.dispose();
    final custom = CustomLaunch(kind: LaunchMediaKind.animation, path: file.path, width: 1, height: 1);
    final inner = await LaunchMedia.open(custom, screen: const Size(100, 100));
    expect(inner, isNotNull);
    return _ObservedMedia(inner!, custom, durations);
  }))!;
  addTearDown(() {
    if (!media.disposed) media.dispose();
  });
  return media;
}

/// Native image decoding needs a real event loop. This wait never advances the
/// test clock: the deadline assertions below still land at exact milliseconds.
Future<void> _frame(WidgetTester tester, _ObservedMedia media, int number, int elapsedMs) async {
  await tester.pump(Duration(milliseconds: elapsedMs));
  for (var i = 0; i < 100 && media.frameChanges < number; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump();
  }
  expect(media.frameChanges, number, reason: 'The real codec must deliver the requested frame.');
}

// Give the leave animation frame ticks, including its first and completion
// frames; the media deadlines themselves are asserted at exact milliseconds.
Future<void> _finishLeaving(WidgetTester tester) async {
  for (var ms = 0; ms < LaunchMotion.leave.inMilliseconds + 40; ms += 20) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<LaunchController> _show(WidgetTester tester, _ObservedMedia media) async {
  usePhone(tester);
  final controller = LaunchController(
    snapshot: snapshotFor(sdk: 30, systemSplash: false, systemIcon: false, coldEngine: false),
    custom: media.custom,
    native: false,
  )..useMedia(media);
  addTearDown(controller.dispose);
  await tester.pumpWidget(launchApp(controller));
  controller.ready();
  await tester.pump();
  expect(controller.phase, LaunchPhase.playing);
  return controller;
}

void main() {
  testWidgets('video rotation turns only the texture and preserves displayed dimensions', (tester) async {
    final dir = Directory.systemTemp.createTempSync('dsh-launch-rotation-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final poster = File('${dir.path}/poster.gif')..writeAsBytesSync(_gif([10]));
    const channel = MethodChannel('dsh/launch_clip');
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final rotation in <int?>[90, 270, null]) {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'open' ? {'texture': 42, 'rotation': ?rotation} : null;
      });
      final media = (await tester.runAsync(() async {
        final opened = await LaunchClip.open(
          CustomLaunch(
            kind: LaunchMediaKind.video,
            path: '${dir.path}/clip.mp4',
            poster: poster.path,
            width: 90,
            height: 160,
            durationMs: 1000,
          ),
        );
        // The native `open` it started without waiting has answered.
        await Future<void>.delayed(Duration.zero);
        return opened;
      }))!;
      media.play();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 90, height: 160, child: media.view())),
        ),
      );
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('showing', {'texture': 42})),
        (_) {},
      );
      await tester.pump();
      expect(media.size, const Size(90, 160));
      expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, (rotation ?? 0) ~/ 90);
      expect(tester.getSize(find.byType(RotatedBox)), const Size(90, 160));
      expect(tester.getSize(find.byType(Texture)), rotation == null ? const Size(90, 160) : const Size(160, 90));
      expect(find.byType(RawImage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      media.dispose();
      await tester.pump();
      expect(calls, ['open', 'play', 'close']);
    }
  });

  testWidgets('two frames: 100 + 2000 ms, then exactly one completion', (tester) async {
    final media = await _open(tester, [10, 200]);
    expect(media.durations, [100, 2000]);
    media.play();
    await tester.pump(const Duration(milliseconds: 99));
    expect(media.frameChanges, 0);
    expect(media.completions, 0);
    await _frame(tester, media, 1, 1);
    debugPrint('GIF durations=${media.durations}; at 100 ms completions=${media.completions}');
    expect(media.completions, 0, reason: 'The final frame still owns its 2000 ms hold.');
    await tester.pump(const Duration(milliseconds: 1999));
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(media.completions, 1);
    debugPrint('GIF at 2100 ms completions=${media.completions}');
    // Repeated play does not start a second round or schedule a second callback.
    media.play();
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 1);
  });

  testWidgets('three frames retain the first, middle and final holds', (tester) async {
    final media = await _open(tester, [10, 20, 30]);
    expect(media.durations, [100, 200, 300]);
    media.play();
    await _frame(tester, media, 1, 100);
    expect(media.completions, 0);
    await _frame(tester, media, 2, 200);
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 299));
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(media.completions, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(media.completions, 1);
  });

  testWidgets('10 ms frames clamp to 100 ms, but a 20 ms frame keeps 20 ms', (tester) async {
    final media = await _open(tester, [1, 2, 1]);
    expect(media.durations, [10, 20, 10]);
    media.play();
    await tester.pump(const Duration(milliseconds: 99));
    expect(media.frameChanges, 0);
    await _frame(tester, media, 1, 1);
    await tester.pump(const Duration(milliseconds: 19));
    expect(media.frameChanges, 1);
    await _frame(tester, media, 2, 1);
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 99));
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(media.completions, 1);
  });

  testWidgets('a single decoded frame keeps stillRound, not the GIF delay', (tester) async {
    final media = await _open(tester, [200]);
    media.play();
    await tester.pump(LaunchMedia.stillRound - const Duration(milliseconds: 1));
    expect(media.completions, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(media.completions, 1);
    expect(media.frameChanges, 0);
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 1);
  });

  testWidgets('dispose during the first frame cancels completion', (tester) async {
    final media = await _open(tester, [10, 200]);
    media.play();
    await tester.pump(const Duration(milliseconds: 50));
    media.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 0);
    expect(media.frameChanges, 0);
  });

  testWidgets('dispose during a middle frame cancels completion', (tester) async {
    final media = await _open(tester, [10, 100, 200]);
    media.play();
    await _frame(tester, media, 1, 100);
    await tester.pump(const Duration(milliseconds: 500));
    media.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 0);
    expect(media.frameChanges, 1);
  });

  testWidgets('dispose during the final hold cancels completion', (tester) async {
    final media = await _open(tester, [10, 200]);
    media.play();
    await _frame(tester, media, 1, 100);
    await tester.pump(const Duration(milliseconds: 1000));
    media.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 0);
    expect(media.frameChanges, 1);
  });

  testWidgets('warm engine: the real GIF stays until its full round ends', (tester) async {
    final media = await _open(tester, [10, 200]);
    final controller = await _show(tester, media);
    await _frame(tester, media, 1, 100);
    expect(controller.phase, LaunchPhase.playing);
    expect(controller.holds, isTrue);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(controller.phase, LaunchPhase.playing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.phase, LaunchPhase.leaving);
    await _finishLeaving(tester);
    expect(controller.phase, LaunchPhase.gone);
    expect(media.disposed, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(media.completions, 1);
  });

  for (final finalFrame in [false, true]) {
    testWidgets('tap during the ${finalFrame ? 'final' : 'middle'} hold skips and cancels completion', (tester) async {
      final media = await _open(tester, finalFrame ? [10, 200] : [10, 200, 200]);
      final controller = await _show(tester, media);
      await _frame(tester, media, 1, 100);
      await tester.tap(find.byKey(LaunchOverlay.skipKey));
      await tester.pump();
      expect(controller.phase, LaunchPhase.leaving);
      await _finishLeaving(tester);
      expect(controller.phase, LaunchPhase.gone);
      expect(media.disposed, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(media.completions, 0);
    });
  }
}
