// 冷启动与热启动：自定义画面每次 App 冷启动都按它本身的长度播完一轮，不设上限，引擎在跑、现起、
// 没开，首页连远程主机，轻量模式都一样，只有系统要求减少动画时停在首帧、不等；默认动画只在引擎
// 这次现起时播完（1.36 s，引擎先就绪就提前收），引擎早已在跑、首页连的是远程主机、或减少动画时，
// 界面可用就收，一刻不拖。轻点随时跳过；热启动（进程还在）没有启动画面。时间点都按帧量出来。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_media.dart';
import 'package:dsh_app/launch/launch_motion.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// A custom picture that ends its round when the test says so.
class _Clip extends LaunchMedia {
  VoidCallback? onDone;
  bool started = false;

  @override
  Size get size => const Size(90, 160);

  @override
  Widget view() => const ColoredBox(color: Color(0xFF2E5C8A));

  @override
  void play({VoidCallback? onDone}) {
    started = true;
    this.onDone = onDone;
  }

  void finish() => onDone?.call();
}

const _custom = CustomLaunch(kind: LaunchMediaKind.video, path: '/clip.mp4', width: 90, height: 160);

void main() {
  late FakeLaunchChannel channel;
  setUp(() => channel = FakeLaunchChannel());

  /// Android 8–11 (no system splash to wait for): the motion starts with the first frame.
  Future<LaunchController> start(
    WidgetTester tester, {
    required bool cold,
    bool reduceMotion = false,
    CustomLaunch? custom,
    bool systemSplash = false,
  }) async {
    usePhone(tester);
    final ui.Image icon = (await tester.runAsync(() => flatImage(320, 320, const Color(0xFF4F68B7))))!;
    final c = LaunchController(
      snapshot: snapshotFor(icon: icon, sdk: systemSplash ? 35 : 30, systemSplash: systemSplash, coldEngine: cold),
      custom: custom,
      channel: channel,
    );
    await tester.pumpWidget(launchApp(c, reduceMotion: reduceMotion));
    await tester.pump();
    return c;
  }

  /// Advances [ms] in 20 ms frames, so animations and timers land in order.
  Future<void> wait(WidgetTester tester, int ms) async {
    for (var t = 0; t < ms; t += 20) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  test('begin says whether the engine is starting cold', () async {
    final cold = await LaunchSnapshot.fromMap({
      'active': true,
      'sdk': 35,
      'iconPx': 420,
      'background': 0xFFEBF1FE,
      'coldEngine': true,
    });
    expect(cold!.coldEngine, isTrue);
    final warm = await LaunchSnapshot.fromMap({'active': true, 'sdk': 35, 'iconPx': 420, 'background': 0xFFEBF1FE});
    expect(warm!.coldEngine, isFalse);
  });

  group('cold start', () {
    testWidgets('plays the whole motion although the app was ready early, then goes at once', (tester) async {
      final c = await start(tester, cold: true);
      expect(c.phase, LaunchPhase.playing);
      await wait(tester, 200);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.playing);
      expect(c.holds, isTrue);
      // Through the settle, the wordmark and the light: still there just before the end.
      await wait(tester, 1100);
      expect(c.phase, LaunchPhase.playing);
      expect(find.byKey(LaunchMark.wordmarkKey), findsOneWidget);
      // The motion has come to rest: it leaves without waiting for the engine.
      await wait(tester, 120);
      expect(c.phase, LaunchPhase.leaving);
      await wait(tester, LaunchMotion.leave.inMilliseconds + 40);
      expect(c.phase, LaunchPhase.gone);
    });

    testWidgets('a layer remounted mid-motion plays on and goes', (tester) async {
      final c = await start(tester, cold: true);
      c.ready();
      await wait(tester, 100);
      expect(c.phase, LaunchPhase.playing);
      // A new State under the same controller, as swapping a widget above it makes. iOS holds a
      // cold start for the motion alone until the engine runs, and a first run has no engine.
      await tester.pumpWidget(KeyedSubtree(key: const ValueKey('remounted'), child: launchApp(c)));
      await wait(tester, (LaunchMotion.total + LaunchMotion.leave).inMilliseconds + 200);
      expect(c.phase, LaunchPhase.gone);
      expect(channel.calls, contains('done'));
    });

    testWidgets('the engine up before the motion ends: it goes then', (tester) async {
      final c = await start(tester, cold: true);
      await wait(tester, 200);
      c.ready();
      await wait(tester, 300);
      expect(c.phase, LaunchPhase.playing);
      c.engineReady();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
      expect(channel.marks, containsAllInOrder(['firstFrame', 'ready', 'engine']));
    });

    testWidgets('the engine up before the app is ready: ready goes at once', (tester) async {
      final c = await start(tester, cold: true);
      c.engineReady();
      await wait(tester, 100);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('a first page on a remote host doesn\'t wait for this phone\'s engine', (tester) async {
      final c = await start(tester, cold: true);
      await wait(tester, 100);
      c.ready(waitsForEngine: false);
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('Android 12+: waits for the splash before it plays, then plays it all', (tester) async {
      final c = await start(tester, cold: true, systemSplash: true);
      c.ready();
      // Not the warm start's 200 ms: the motion must not start under the splash.
      await wait(tester, 300);
      expect(c.phase, LaunchPhase.cover);
      await c.handOver(const Rect.fromLTWH(115, 342, 160, 160), removed: true);
      await tester.pump();
      expect(c.phase, LaunchPhase.playing);
      await wait(tester, 1300);
      expect(c.phase, LaunchPhase.playing);
      await wait(tester, 100);
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('custom: one round, then goes', (tester) async {
      final c = await start(tester, cold: true, custom: _custom);
      final clip = _Clip();
      c.useMedia(clip);
      await tester.pump();
      expect(clip.started, isTrue);
      c.ready();
      await wait(tester, 1500);
      expect(c.phase, LaunchPhase.playing);
      clip.finish();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('custom: as long as it is, no cap; the engine answering doesn\'t cut it', (tester) async {
      final c = await start(tester, cold: true, custom: _custom);
      final clip = _Clip();
      c.useMedia(clip);
      await tester.pump();
      c.ready();
      await wait(tester, 400);
      c.engineReady();
      await tester.pump();
      // A 10 s clip: still there at 9.9 s.
      await wait(tester, 9500);
      expect(c.phase, LaunchPhase.playing);
      clip.finish();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('custom still opening: waited for, the engine answering or not; then its whole round', (tester) async {
      final c = await start(tester, cold: true, custom: _custom);
      c.ready();
      await wait(tester, 400);
      c.engineReady();
      await wait(tester, 400);
      expect(c.phase, LaunchPhase.playing);
      final clip = _Clip();
      c.useMedia(clip);
      await tester.pump();
      expect(clip.started, isTrue);
      await wait(tester, 3000);
      expect(c.phase, LaunchPhase.playing);
      clip.finish();
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('custom that can\'t be read: the default motion\'s rules', (tester) async {
      // A clip without its poster doesn't open.
      final c = await start(tester, cold: false, custom: _custom);
      c.ready();
      await wait(tester, 200);
      expect(c.phase, LaunchPhase.playing);
      await c.openMedia(const Size(780, 1688));
      await tester.pump();
      expect(c.mediaFailed, isTrue);
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('a tap skips it: custom', (tester) async {
      final c = await start(tester, cold: true, custom: _custom);
      c.useMedia(_Clip());
      await tester.pump();
      c.ready();
      await wait(tester, 1000);
      expect(c.phase, LaunchPhase.playing);
      await tester.tap(find.byKey(LaunchOverlay.skipKey));
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
      expect(channel.marks, contains('skipped'));
    });

    testWidgets('a tap skips it: the default motion, even before the app is ready', (tester) async {
      final c = await start(tester, cold: true);
      await wait(tester, 300);
      await tester.tap(find.byKey(LaunchOverlay.skipKey));
      await tester.pump();
      expect(c.phase, LaunchPhase.leaving);
      await wait(tester, LaunchMotion.leave.inMilliseconds + 40);
      expect(c.phase, LaunchPhase.gone);
    });

    testWidgets('a custom still stays as long as the default motion', (tester) async {
      final c = await start(tester, cold: true, custom: _custom);
      final ui.Image still = (await tester.runAsync(() => flatImage(90, 160, const Color(0xFF2E5C8A))))!;
      c.useMedia(StillLaunchMedia(still));
      c.ready();
      await wait(tester, 1300);
      expect(c.phase, LaunchPhase.playing);
      await wait(tester, 100);
      expect(c.phase, LaunchPhase.leaving);
    });
  });

  group('custom, whatever the engine is doing', () {
    /// A 5 s clip, the app ready 200 ms in: the layer stays until the clip ends, then goes.
    Future<void> wholeRound(WidgetTester tester, LaunchController c, {bool waitsForEngine = true}) async {
      final clip = _Clip();
      c.useMedia(clip);
      await tester.pump();
      expect(clip.started, isTrue);
      await wait(tester, 200);
      c.ready(waitsForEngine: waitsForEngine);
      await tester.pump();
      expect(c.holds, isTrue);
      await wait(tester, 4600);
      expect(c.phase, LaunchPhase.playing);
      expect(find.byType(CustomLaunchView), findsOneWidget);
      clip.finish();
      await tester.pump();
      // A light phone: straight onto the app, no fade.
      expect(c.phase, isIn([LaunchPhase.leaving, LaunchPhase.gone]));
    }

    testWidgets('the engine already running (or not started at all): its whole round', (tester) async {
      await wholeRound(tester, await start(tester, cold: false, custom: _custom));
    });

    testWidgets('a first page on a remote host: its whole round', (tester) async {
      await wholeRound(tester, await start(tester, cold: true, custom: _custom), waitsForEngine: false);
    });

    testWidgets('a light phone (the app\'s own 减少动画, not the system\'s): its whole round', (tester) async {
      await wholeRound(tester, await start(tester, cold: false, reduceMotion: true, custom: _custom));
    });

    testWidgets('Android 12+: waits for the splash, then its whole round', (tester) async {
      final c = await start(tester, cold: false, systemSplash: true, custom: _custom);
      c.ready();
      await wait(tester, 300);
      expect(c.phase, LaunchPhase.cover);
      await c.handOver(null, removed: true);
      await tester.pump();
      await wholeRound(tester, c);
    });

    testWidgets('a tap skips it', (tester) async {
      final c = await start(tester, cold: false, reduceMotion: true, custom: _custom);
      c.useMedia(_Clip());
      await tester.pump();
      c.ready();
      await wait(tester, 1000);
      expect(c.phase, LaunchPhase.playing);
      await tester.tap(find.byKey(LaunchOverlay.skipKey));
      await tester.pump();
      expect(c.phase, isIn([LaunchPhase.leaving, LaunchPhase.gone]));
      expect(channel.marks, contains('skipped'));
    });
  });

  group('no waiting', () {
    test('a warm start of the app (its process still there): no launch screen, a custom one set or not', () async {
      final dir = Directory.systemTemp.createTempSync('launch_warm');
      addTearDown(() => dir.deleteSync(recursive: true));
      final clip = File('${dir.path}/clip.mp4')..writeAsBytesSync([0]);
      SharedPreferences.setMockInitialValues({
        CustomLaunch.prefsKey: jsonEncode(
          CustomLaunch(kind: LaunchMediaKind.video, path: clip.path, width: 90, height: 160).toJson(),
        ),
      });
      expect(await CustomLaunch.load(), isNotNull);
      final warm = FakeLaunchChannel(answer: {'active': false});
      expect(await LaunchController.begin(channel: warm), isNull);
      expect(LaunchController.active.value, isNull);
    });

    testWidgets('系统的减少动画 with a custom picture: its first frame, not played, not waited for', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final c = await start(tester, cold: true, reduceMotion: true, custom: _custom);
      final clip = _Clip();
      c.useMedia(clip);
      await tester.pump();
      expect(clip.started, isFalse);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.gone);
    });

    testWidgets('warm start (the engine already ran): goes the moment the app is ready', (tester) async {
      final c = await start(tester, cold: false);
      await wait(tester, 200);
      c.ready();
      await tester.pump();
      expect(c.holds, isFalse);
      expect(c.phase, LaunchPhase.leaving);
    });

    testWidgets('a light phone keeps the default motion to its first frame: gone the moment the app is ready', (
      tester,
    ) async {
      final c = await start(tester, cold: false, reduceMotion: true);
      await wait(tester, 200);
      expect(find.byKey(LaunchMark.wordmarkKey), findsNothing);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.gone);
    });

    testWidgets('减少动画 on a cold start: nothing plays, nothing is waited for', (tester) async {
      final c = await start(tester, cold: true, reduceMotion: true);
      await tester.pump();
      expect(c.reduced, isTrue);
      await wait(tester, 100);
      c.ready();
      await tester.pump();
      expect(c.phase, LaunchPhase.gone);
    });

    testWidgets('减少动画 arriving late (a light phone\'s own setting) releases a held cold start', (tester) async {
      usePhone(tester);
      final ui.Image icon = (await tester.runAsync(() => flatImage(320, 320, const Color(0xFF4F68B7))))!;
      final c = LaunchController(
        snapshot: snapshotFor(icon: icon, sdk: 30, systemSplash: false, coldEngine: true),
        channel: channel,
      );
      await tester.pumpWidget(launchApp(c));
      await tester.pump();
      c.ready();
      await wait(tester, 200);
      expect(c.phase, LaunchPhase.playing);
      await tester.pumpWidget(launchApp(c, reduceMotion: true));
      await tester.pump();
      await tester.pump();
      expect(c.phase, isIn([LaunchPhase.leaving, LaunchPhase.gone]));
    });
  });
}
