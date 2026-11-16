// Shared pieces of the launch screen tests: a native side that records what it is asked, the
// shipped launcher icon drawn the way the system splash draws it, and a pump.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/ui/launch/launch_overlay.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

class FakeLaunchChannel extends LaunchChannel {
  FakeLaunchChannel({this.answer});

  final Map<Object?, Object?>? answer;
  final calls = <String>[];
  final marks = <String>[];
  void Function(Rect? icon, {bool removed})? onSystemSplash;

  /// Holds `reveal` until completed (the native fade).
  Completer<void>? fading;

  @override
  Future<Map<Object?, Object?>?> begin() async {
    calls.add('begin');
    return answer;
  }

  @override
  Future<bool> reveal() async {
    calls.add('reveal');
    if (fading case final f?) await f.future;
    return true;
  }

  @override
  Future<void> mark(String name) async => marks.add(name);

  @override
  Future<void> done() async => calls.add('done');

  @override
  void listen(void Function(Rect? icon, {bool removed}) onSystemSplash) => this.onSystemSplash = onSystemSplash;

  @override
  void stopListening() => calls.add('stopListening');
}

/// The 桌面图标 a launcher entry shows (mist, night, frost, ink), straight from res: its
/// background layer's gradient under its xxxhdpi foreground, cut to a circle, [px] square, as
/// the splash draws it on a Pixel. Call inside `tester.runAsync`.
Future<ui.Image> shippedIcon(int px, {String variant = 'mist'}) async {
  final suffix = variant == 'mist' ? '' : '_$variant';
  final xml = File('android/app/src/main/res/drawable/ic_launcher${suffix}_background.xml').readAsStringSync();
  final colours = [
    for (final m in RegExp(r'android:color="#([0-9A-Fa-f]{8})"').allMatches(xml))
      Color(int.parse(m.group(1)!, radix: 16)),
  ];
  final bytes = File('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher${suffix}_foreground.png').readAsBytesSync();
  final codec = await ui.instantiateImageCodec(bytes);
  final foreground = (await codec.getNextFrame()).image;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = px.toDouble();
  canvas.clipPath(Path()..addOval(Rect.fromLTWH(0, 0, side, side)));
  // The visible 72 of the 108 grid fills the square.
  canvas
    ..save()
    ..scale(side / 72)
    ..translate(-18, -18)
    ..drawRect(
      const Rect.fromLTWH(0, 0, 108, 108),
      Paint()..shader = ui.Gradient.linear(const Offset(7.57, -5.87), const Offset(100.43, 113.87), colours),
    )
    ..drawImageRect(
      foreground,
      Rect.fromLTWH(0, 0, foreground.width.toDouble(), foreground.height.toDouble()),
      const Rect.fromLTWH(0, 0, 108, 108),
      Paint()..filterQuality = FilterQuality.high,
    )
    ..restore();
  final image = await recorder.endRecording().toImage(px, px);
  foreground.dispose();
  return image;
}

/// A plain square in [color], for tests that only measure.
Future<ui.Image> flatImage(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

LaunchSnapshot snapshotFor({
  ui.Image? icon,
  int sdk = 35,
  bool systemSplash = true,
  bool dark = false,
  int iconPx = 320,
  bool coldEngine = false,
  bool systemIcon = true,
  bool motionAfterReady = false,
  Color? background,
}) => LaunchSnapshot(
  sdk: sdk,
  systemSplash: systemSplash,
  iconPx: iconPx,
  icon: icon,
  background: background ?? (dark ? LaunchColors.nightTop : LaunchColors.mistTop),
  backgroundBottom: dark ? LaunchColors.nightBottom : LaunchColors.mistBottom,
  dark: dark,
  coldEngine: coldEngine,
  systemIcon: systemIcon,
  motionAfterReady: motionAfterReady,
);

/// The phone the goldens are drawn on: 390 × 844 at 2× (the shell goldens' surface).
void usePhone(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
}

/// The overlay over a stand-in home, as the app root stacks it.
Widget launchApp(
  LaunchController controller, {
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  Widget home = const Scaffold(body: Center(child: Text('home'))),
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: withTestFonts(buildLightTheme()),
  darkTheme: withTestFonts(buildDarkTheme()),
  themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: Stack(
      fit: StackFit.expand,
      children: [
        child!,
        LaunchOverlay(controller: controller),
      ],
    ),
  ),
  home: home,
);

/// Rect of [finder] rounded to 1/1000 of a logical pixel, to compare geometry.
Rect rectOf(WidgetTester tester, Finder finder) {
  final r = tester.getRect(finder);
  double round(double v) => (v * 1000).roundToDouble() / 1000;
  return Rect.fromLTRB(round(r.left), round(r.top), round(r.right), round(r.bottom));
}

double opacityOf(WidgetTester tester, Finder finder) => tester.widget<Opacity>(finder).opacity;

/// Angle helper for the sweep geometry.
double degrees(double radians) => radians * 180 / math.pi;
