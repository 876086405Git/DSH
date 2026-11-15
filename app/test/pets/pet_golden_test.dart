// The chat page's pet, light and dark: both pets on the composer at the
// three sizes, held up high (the lifted pose whole), on the run strip (the
// whale tail steps aside), its bubble. Regenerate with
// `flutter test --update-goldens test/pets/pet_golden_test.dart`.
//
// With `--dart-define=PET_PREVIEW_OUT=/abs/dir` it also writes phone-sized
// screenshots (the review set) to that folder.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _out = String.fromEnvironment('PET_PREVIEW_OUT');

late TestClock clock;

Future<ProviderContainer> scene(
  WidgetTester tester, {
  PetPack? pack,
  PetSize size = PetSize.medium,
  Brightness brightness = Brightness.light,
  HarnessConfig config = const HarnessConfig(),
  double position = 0.25,
  Size view = const Size(390, 280),
  double dpr = 2,
  Iterable<String> warm = const [],
}) async {
  final p = pack ?? deepy;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = view * dpr;
  tester.view.padding = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
  await warmSheets(tester, p, [p.animFor(PetStateName.idle), for (final n in warm) p.animations[n]!]);
  await tester.pumpWidget(
    testApp(
      const ChatBottomHarness(),
      brightness: brightness,
      overrides: [
        ...petOverrides(pack: p, clock: clock, size: size, position: position),
        harnessConfigProvider.overrideWith(() => HarnessConfigController(config)),
      ],
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
  return ProviderScope.containerOf(tester.element(find.byType(ChatBottomHarness)));
}

/// The whole view → `$_out/<name>.png`, at the view's own device pixels
/// (so the art pixels are exactly as a phone shows them).
Future<void> shoot(WidgetTester tester, String name) async {
  if (_out.isEmpty) return;
  await tester.pump();
  await tester.runAsync(() async {
    final view = RendererBinding.instance.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final image = await layer.toImage(view.paintBounds);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('$_out/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
}

/// At the view's own device pixels (2×): the art pixels as a phone shows
/// them, not resampled to 1×.
Future<void> golden(WidgetTester tester, String name) async {
  await tester.pump();
  final image = await tester.runAsync(() {
    final view = RendererBinding.instance.renderViews.first;
    return (view.debugLayer! as OffsetLayer).toImage(view.paintBounds);
  });
  await expectLater(image, matchesGoldenFile('goldens/$name.png'));
  image!.dispose();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = TestClock();
    runClock = clock.call;
    PetLayer.random = math.Random(3);
  });
  tearDown(() {
    runClock = DateTime.now;
    PetSheets.instance.clear();
  });

  for (final brightness in Brightness.values) {
    final tone = brightness.name;
    for (final (pack, short) in [(deepy, 'deepy'), (girl, 'girl')]) {
      for (final size in PetSize.presets) {
        testWidgets('$short on the composer, ${size.name}, $tone', (tester) async {
          await scene(tester, pack: pack, size: size, brightness: brightness);
          await golden(tester, 'pet_composer_${short}_${size.name}_$tone');
        });
      }
    }

    // Held up as high as it goes (the drag reaction is the lifted pose):
    // the whole pose is drawn, nothing above the head or at the sides cut.
    for (final (pack, short) in [(deepy, 'deepy'), (girl, 'girl')]) {
      testWidgets('$short held up high, the lifted pose whole, $tone', (tester) async {
        final drag = pack.reaction('drag')!;
        await scene(tester, pack: pack, brightness: brightness, warm: [drag.name]);
        final gesture = await tester.startGesture(petCanvas(tester).center + const Offset(0, 8));
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
        await gesture.moveBy(const Offset(60, -200));
        await tester.pump(const Duration(milliseconds: 300));
        final canvas = petCanvas(tester);
        final s = canvas.width / pack.canvas.width;
        final pose = Rect.fromLTWH(
          canvas.left + drag.box.left * s,
          canvas.top + drag.box.top * s,
          drag.box.width * s,
          drag.box.height * s,
        );
        final view = Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
        expect(
          view.left <= pose.left && view.top <= pose.top && pose.right <= view.right && pose.bottom <= view.bottom,
          isTrue,
          reason: 'lifted pose $pose inside the view $view',
        );
        expect(petLayer(tester).playing?.name, drag.name);
        await golden(tester, 'pet_held_${short}_$tone');
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));
      });
    }

    testWidgets('on the run strip, the whale tail aside, $tone', (tester) async {
      final c = await scene(tester, brightness: brightness, config: const HarnessConfig(strip: true), warm: ['typing']);
      c
          .read(testSignalsProvider.notifier)
          .set(
            PetSignals(
              lastInteraction: clock.now,
              focus: const PetFocus(host: HostRef.local, sessionId: 'a', activity: PetActivity.working),
              runs: const [PetRun(HostRef.local, 'a')],
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await golden(tester, 'pet_strip_$tone');
    });

    testWidgets('a bubble for another conversation, $tone', (tester) async {
      final c = await scene(tester, brightness: brightness, warm: ['error']);
      c
          .read(petEventBusProvider)
          .add(
            PetEvent(
              kind: PetEventKind.failed,
              host: HostRef.local,
              sessionId: 'b',
              key: 'turn',
              title: '修复登录重复提交',
              at: clock.now,
              bubble: true,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await golden(tester, 'pet_bubble_$tone');
    });
  }

  group('review screenshots', () {
    testWidgets('previews', (tester) async {
      if (_out.isEmpty) return;
      const phone = Size(390, 844);
      // A vivo-like screen: 2.75 device pixels per dp.
      Future<ProviderContainer> shot({
        PetPack? pack,
        Brightness brightness = Brightness.light,
        HarnessConfig config = const HarnessConfig(),
        Iterable<String> warm = const [],
      }) => scene(tester, view: phone, dpr: 2.75, pack: pack, brightness: brightness, config: config, warm: warm);
      Future<void> fresh() async {
        // A new provider scope for each scene.
        await tester.pumpWidget(const SizedBox());
        PetSheets.instance.clear();
        clock = TestClock();
        runClock = clock.call;
      }

      // 1. On the composer.
      await shot();
      await shoot(tester, '01-composer');

      // 2. On the run strip, working (the whale tail aside).
      await fresh();
      var c = await shot(config: const HarnessConfig(strip: true), warm: ['typing']);
      c
          .read(testSignalsProvider.notifier)
          .set(
            PetSignals(
              lastInteraction: clock.now,
              focus: const PetFocus(host: HostRef.local, sessionId: 'a', activity: PetActivity.working),
              runs: const [PetRun(HostRef.local, 'a')],
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await shoot(tester, '02-strip');

      // 3. A bubble.
      await fresh();
      c = await shot(warm: ['happy']);
      c
          .read(petEventBusProvider)
          .add(
            PetEvent(
              kind: PetEventKind.done,
              host: HostRef.local,
              sessionId: 'b',
              key: 'turn',
              title: '修复登录重复提交',
              at: clock.now,
              bubble: true,
            ),
          );
      clock.advance(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 400));
      await shoot(tester, '03-bubble');

      // 4. Asleep.
      await fresh();
      c = await shot(warm: ['sleeping']);
      clock.advance(const Duration(seconds: 61));
      c.read(petMoodProvider(PetScope.global).notifier).refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await shoot(tester, '04-sleeping');

      // 5. Held and dragged along.
      await fresh();
      await shot(warm: ['react-drag']);
      final start = petCanvas(tester).center + const Offset(0, 8);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(40, -16));
      await tester.pump();
      await gesture.moveBy(const Offset(60, -10));
      await tester.pump(const Duration(milliseconds: 300));
      await shoot(tester, '05-dragging');
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));

      // 6. Dark, on the strip, 鲸娘.
      await fresh();
      c = await shot(
        pack: girl,
        brightness: Brightness.dark,
        config: const HarnessConfig(strip: true),
        warm: ['thinking'],
      );
      c
          .read(testSignalsProvider.notifier)
          .set(
            PetSignals(
              lastInteraction: clock.now,
              focus: const PetFocus(host: HostRef.local, sessionId: 'a', activity: PetActivity.thinking),
              runs: const [PetRun(HostRef.local, 'a')],
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await shoot(tester, '06-dark-girl-strip');

      // 7. Dark, Deepy, with a waiting request's bubble.
      await fresh();
      c = await shot(brightness: Brightness.dark, warm: ['notification']);
      c
          .read(testSignalsProvider.notifier)
          .set(
            PetSignals(
              lastInteraction: clock.now,
              pending: const [PetPending(host: HostRef.local, sessionId: 'b', key: 'e1')],
            ),
          );
      c
          .read(petEventBusProvider)
          .add(
            PetEvent(
              kind: PetEventKind.approval,
              host: HostRef.local,
              sessionId: 'b',
              key: 'e1',
              title: '整理发布说明',
              at: clock.now,
              bubble: true,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await shoot(tester, '07-dark-notification');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
