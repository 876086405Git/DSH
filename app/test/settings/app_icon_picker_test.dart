// 桌面图标: the picker switches the launcher icon through the native side and
// says so; the row is measured; the previews match the shipped icon layers.
// Goldens:
//
//   flutter test --update-goldens test/settings/app_icon_picker_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/ui/settings/appearance/app_icon_picker.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _FakeLauncher extends LauncherIconChannel {
  _FakeLauncher({this.current = AppIcon.mist, this.mask});

  AppIcon current;
  final List<double>? mask;
  bool fail = false;
  Completer<void>? gate;
  final sets = <AppIcon>[];

  @override
  Future<AppIconState?> state() async => AppIconState(current: current, mask: mask);

  @override
  Future<AppIcon?> set(AppIcon icon) async {
    sets.add(icon);
    if (gate case final gate?) await gate.future;
    if (fail) return null;
    return current = icon;
  }
}

/// A circle (a Pixel's mask), [n] points.
List<double> _circle([int n = 240]) => [
  for (var i = 0; i < n; i++) ...[0.5 + 0.5 * math.cos(2 * math.pi * i / n), 0.5 + 0.5 * math.sin(2 * math.pi * i / n)],
];

Widget _page() => Scaffold(
  body: SafeArea(
    child: ListView(
      children: const [
        SettingsSection(title: '桌面图标', children: [AppIconPicker()]),
      ],
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _FakeLauncher launcher, {
  Brightness brightness = Brightness.light,
  String os = 'android',
}) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: _page(),
      brightness: brightness,
      overrides: [launcherIconChannelProvider.overrideWithValue(launcher), operatingSystemProvider.overrideWithValue(os)],
    ),
  );
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, AppIcon icon) =>
    tester.getSemantics(find.bySemanticsLabel(icon.label)).getSemanticsData().flagsCollection.isSelected ==
    ui.Tristate.isTrue;

AppIcon? _chosen(WidgetTester tester) {
  final on = AppIcon.values.where((icon) => _selected(tester, icon)).toList();
  expect(on.length, lessThanOrEqualTo(1));
  return on.firstOrNull;
}

void main() {
  group('picker', () {
    testWidgets('four icons in order, the one on the phone chosen', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _FakeLauncher(current: AppIcon.night));
      final xs = [for (final icon in AppIcon.values) tester.getCenter(find.text(icon.label)).dx];
      expect(xs, orderedEquals([...xs]..sort()));
      expect(AppIcon.values.map((i) => i.label), ['雾蓝', '夜幕', '霜白', '墨']);
      expect(_chosen(tester), AppIcon.night);
      handle.dispose();
    });

    testWidgets('picking one switches the launcher and says so', (tester) async {
      final handle = tester.ensureSemantics();
      final launcher = _FakeLauncher();
      await _pump(tester, launcher);
      await tester.tap(find.text('霜白'));
      await tester.pumpAndSettle();
      expect(launcher.sets, [AppIcon.frost]);
      expect(_chosen(tester), AppIcon.frost);
      expect(find.text('桌面图标已选择，回到桌面后更新'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a switch that fails shows the launcher as it is and says so', (tester) async {
      final handle = tester.ensureSemantics();
      final launcher = _FakeLauncher()..fail = true;
      await _pump(tester, launcher);
      await tester.tap(find.text('墨'));
      await tester.pumpAndSettle();
      expect(launcher.sets, [AppIcon.ink]);
      expect(_chosen(tester), AppIcon.mist);
      expect(find.text('没能更换，稍后再试'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('on HarmonyOS a refusal says why trying again won\'t help', (tester) async {
      final handle = tester.ensureSemantics();
      final launcher = _FakeLauncher()..fail = true;
      await _pump(tester, launcher, os: 'ohos');
      await tester.tap(find.text('墨'));
      await tester.pumpAndSettle();
      expect(_chosen(tester), AppIcon.mist);
      expect(find.text('没能更换。使用自定义主题或应用分身时不能换桌面图标'), findsOneWidget);
      expect(find.text('没能更换，稍后再试'), findsNothing);
      handle.dispose();
    });

    testWidgets('the current icon does nothing', (tester) async {
      final launcher = _FakeLauncher();
      await _pump(tester, launcher);
      await tester.tap(find.text('雾蓝'));
      await tester.pumpAndSettle();
      expect(launcher.sets, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('picks run in order and the last one stays', (tester) async {
      final handle = tester.ensureSemantics();
      final launcher = _FakeLauncher()..gate = Completer<void>();
      await _pump(tester, launcher);
      await tester.tap(find.text('夜幕'));
      await tester.pump();
      // Shown at once, before the launcher answers.
      expect(_chosen(tester), AppIcon.night);
      await tester.tap(find.text('墨'));
      await tester.pump();
      expect(_chosen(tester), AppIcon.ink);
      expect(launcher.sets, [AppIcon.night]);
      launcher.gate!.complete();
      launcher.gate = null;
      await tester.pumpAndSettle();
      expect(launcher.sets, [AppIcon.night, AppIcon.ink]);
      expect(_chosen(tester), AppIcon.ink);
      expect(launcher.current, AppIcon.ink);
      handle.dispose();
    });
  });

  group('geometry', () {
    Future<void> measure(WidgetTester tester, {required double width, required double textScale}) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        goldenApp(
          home: _page(),
          brightness: Brightness.light,
          overrides: [launcherIconChannelProvider.overrideWithValue(_FakeLauncher(mask: _circle()))],
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final picker = tester.getRect(find.byType(AppIconPicker));
      final boxes = [for (final icon in AppIcon.values) tester.getRect(find.byKey(ValueKey('app-icon-${icon.name}')))];
      final icons = [
        for (final icon in AppIcon.values)
          tester.getRect(find.byWidgetPredicate((w) => w is AppIconPreview && w.icon == icon)),
      ];
      final labels = [for (final icon in AppIcon.values) tester.getRect(find.text(icon.label))];

      // Same size everywhere, at most a launcher's own, ring room on every side.
      for (final (i, box) in boxes.indexed) {
        expect(box.width, closeTo(boxes.first.width, 1e-6));
        expect(box.height, closeTo(box.width, 1e-6));
        expect(icons[i].width, closeTo(icons[i].height, 1e-6));
        expect(icons[i].width, lessThanOrEqualTo(AppIconPicker.maxIcon));
        expect(box.width, closeTo(AppIconPicker.extent(icons[i].width), 1e-6));
        // Icon and ring share a centre.
        expect((icons[i].center - box.center).distance, lessThan(1e-6));
        // Label centred under its icon, all on one line.
        expect(labels[i].center.dx, closeTo(box.center.dx, 0.01));
        expect(labels[i].top, closeTo(labels.first.top, 1e-6));
        expect(labels[i].top - box.bottom, closeTo(AppIconPicker.labelGap, 1e-6));
      }
      // Evenly spread; the row mirrors (as far in from the left as from the right).
      final step = boxes[1].center.dx - boxes[0].center.dx;
      for (var i = 1; i < boxes.length; i++) {
        expect(boxes[i].center.dx - boxes[i - 1].center.dx, closeTo(step, 1e-6));
      }
      expect(boxes.first.left - picker.left, closeTo(picker.right - boxes.last.right, 1e-6));
      expect(boxes.first.top - picker.top, closeTo(16, 1e-6));
    }

    testWidgets('phone width', (tester) => measure(tester, width: 390, textScale: 1));
    testWidgets('narrow, large text', (tester) => measure(tester, width: 320, textScale: 1.3));
  });

  group('mask', () {
    test("the system's outline, scaled", () {
      final path = launcherMaskPath(_circle(), 60);
      expect(path.getBounds().width, closeTo(60, 0.01));
      expect(path.contains(const Offset(30, 30)), isTrue);
      expect(path.contains(const Offset(3, 3)), isFalse);
      expect(path.contains(const Offset(1, 30)), isTrue);
    });

    test('a rounded square without one', () {
      final path = launcherMaskPath(null, 60);
      expect(path.getBounds(), const Rect.fromLTWH(0, 0, 60, 60));
      expect(path.contains(const Offset(0.5, 0.5)), isFalse);
      expect(path.contains(const Offset(3, 30)), isTrue);
      expect(launcherMaskPath(const [0.5, 0.5], 60).getBounds().width, closeTo(60, 0.01));
    });
  });

  group('channel', () {
    const name = 'dsh/launcher_icon';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(const MethodChannel(name), null));

    void answer(Object? Function(MethodCall call) reply) =>
        messenger.setMockMethodCallHandler(const MethodChannel(name), (call) async => reply(call));

    test('state', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      answer((_) => {'current': 'frost', 'mask': _circle(8)});
      final state = await const LauncherIconChannel().state();
      expect(state?.current, AppIcon.frost);
      expect(state?.mask, hasLength(16));
      answer((_) => {'current': 'ink', 'mask': null});
      expect((await const LauncherIconChannel().state())?.mask, isNull);
      answer(
        (_) => {
          'current': 'ink',
          'mask': [0.1, 'x'],
        },
      );
      expect((await const LauncherIconChannel().state())?.mask, isNull);
      answer((_) => {'current': 'rainbow'});
      expect(await const LauncherIconChannel().state(), isNull);
      answer((_) => throw PlatformException(code: 'failed'));
      expect(await const LauncherIconChannel().state(), isNull);
      messenger.setMockMethodCallHandler(const MethodChannel(name), null);
      expect(await const LauncherIconChannel().state(), isNull);
    });

    test('set', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      MethodCall? seen;
      answer((call) {
        seen = call;
        return {'current': 'night'};
      });
      expect(await const LauncherIconChannel().set(AppIcon.night), AppIcon.night);
      expect(seen?.method, 'set');
      expect(seen?.arguments, {'id': 'night'});
      answer((_) => throw PlatformException(code: 'failed'));
      expect(await const LauncherIconChannel().set(AppIcon.ink), isNull);
    });
  });

  group('the previews match the shipped icons', () {
    const res = 'android/app/src/main/res';

    test('background gradients', () {
      for (final icon in AppIcon.values) {
        final file = icon == AppIcon.mist ? 'ic_launcher_background' : 'ic_launcher_${icon.name}_background';
        final xml = File('$res/drawable/$file.xml').readAsStringSync();
        double attr(String a) => double.parse(RegExp('android:$a="([-0-9.]+)"').firstMatch(xml)!.group(1)!);
        final colors = [
          for (final m in RegExp('android:color="#([0-9A-Fa-f]{8})"').allMatches(xml))
            Color(int.parse(m.group(1)!, radix: 16)),
        ];
        final art = AppIconArt.of(icon);
        expect(colors, [art.from, art.to], reason: file);
        expect(Offset(attr('startX'), attr('startY')), AppIconArt.start, reason: file);
        expect(Offset(attr('endX'), attr('endY')), AppIconArt.end, reason: file);
      }
    });

    testWidgets("墨's glyph colour", (tester) async {
      final bytes = File('$res/mipmap-xxxhdpi/ic_launcher_ink_foreground.png').readAsBytesSync();
      final rgba = await tester.runAsync(() async {
        final frame = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
        return (await frame.image.toByteData())!;
      });
      // Inside the body (108 grid (53.5, 70)), at 4 px per unit.
      final at = (280 * 432 + 214) * 4;
      final pixel = [for (var i = 0; i < 4; i++) rgba!.getUint8(at + i)];
      final mono = AppIconArt.of(AppIcon.ink).mono!;
      expect(pixel[3], 255);
      expect(pixel[0], closeTo((mono.r * 255).round(), 2));
      expect(pixel[1], closeTo((mono.g * 255).round(), 2));
      expect(pixel[2], closeTo((mono.b * 255).round(), 2));
    });
  });

  goldenBoth(
    'app_icon_picker',
    _page,
    overrides: () => [launcherIconChannelProvider.overrideWithValue(_FakeLauncher(current: AppIcon.night))],
  );
}
