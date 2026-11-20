// What keeps cards' heavy pages light (tavern_page_perf.dart): its helpers
// run under Node (support/page_perf_test.mjs), and where the canvas and the
// islands put them; 省电渲染 in 酒馆设置; the [tavern-perf] line.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas.dart';
import 'package:dsh_app/tavern/tavern_islands.dart';
import 'package:dsh_app/tavern/tavern_page_perf.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

String _canvas({bool lowPower = false, bool perf = false, bool noScripts = false}) => tavernCanvasDocument(
  text: const Color(0xff112233),
  accent: const Color(0xff445566),
  muted: const Color(0xff778899),
  quote: const Color(0xffaa5500),
  emphasis: const Color(0xff556677),
  userTint: const Color(0x22445566),
  fontSize: 15,
  lineHeight: 1.6,
  nonce: 'n0nce',
  noScripts: noScripts,
  lowPower: lowPower,
  perf: perf,
);

String _island({bool lowPower = false, bool perf = false}) => tavernIslandDocument(
  '<div class="glass">x</div>',
  text: const Color(0xff112233),
  accent: const Color(0xff445566),
  fontSize: 15,
  nonce: 'n0nce',
  lowPower: lowPower,
  perf: perf,
);

void main() {
  test('the helpers do what they say (under Node)', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-page-perf-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/scripts.json')
      ..writeAsStringSync(jsonEncode({'calm': tavernCalmJs, 'offscreen': tavernOffscreenJs, 'perf': tavernPerfJs, 'scope': tavernScopeJs}));
    final result = await Process.run(
      'node',
      ['--test', 'test/tavern/support/page_perf_test.mjs'],
      environment: {'DSH_PAGE_SCRIPTS': file.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('the canvas: messages out of sight skipped and paused, the latest always drawn', () {
    final page = _canvas();
    expect(page, contains('.mes{display:flex;flex-direction:column;contain-intrinsic-size:auto 160px;}'));
    expect(page, contains('.mes.dsh-off{content-visibility:auto;}'));
    expect(page, contains('.mes.dsh-off *{animation-play-state:paused!important;}'));
    // The reply being written does not reach out to the pages above it.
    expect(page, contains('.mes[data-streaming]{contain:content;}'));
    expect(page, contains('function dshOffscreen(){'));
    expect(page, contains('sight.watch(m,i>=list.length-$tavernCanvasTail)'));
    expect(page, contains('{sight.unwatch(chat.lastElementChild);chat.lastElementChild.remove();}'));
    // Our class is ours: none a card's CSS (Font Awesome's .far) would take.
    expect(page, isNot(contains("'far'")));
    // Off unless chosen.
    expect(page, contains('var lowPower=false;'));
    expect(page, isNot(contains('function dshCalm(')));
    expect(page, isNot(contains(tavernCalmCss)));
    expect(page, isNot(contains('function dshPerf(')));
  });

  test('the canvas with 省电渲染 and the frame log', () {
    final page = _canvas(lowPower: true, perf: true);
    expect(page, contains(tavernCalmCss));
    expect(page, contains('var lowPower=true;'));
    expect(page, contains('function dshCalm(root){'));
    // On what is drawn, what is being written, and what scripts drew.
    expect(page, contains('if(lowPower)dshCalm();'));
    expect(page, contains('if(lowPower)dshCalm(stream);'));
    expect(page, contains('if(lowPower)running.then(function(){dshCalm();});'));
    expect(page, contains('dshPerf(post,function(){return {mes:chat.children.length,'));
    // Ours run with no card scripts too (under the page's nonce).
    expect(_canvas(lowPower: true, noScripts: true), contains('var lowPower=true;'));
  });

  test('an island with 省电渲染 and the frame log', () {
    expect(_island(), isNot(contains('dshCalm')));
    expect(_island(), isNot(contains('dshPerf')));
    final page = _island(lowPower: true, perf: true);
    expect(page, contains(tavernCalmCss));
    expect(page, contains("dshCalm();window.addEventListener('load',function(){dshCalm();});"));
    expect(page, contains('dshPerf(function(o){TavernIsland.postMessage(JSON.stringify(o));}'));
    // After the card's HTML, under our nonce.
    expect(page.indexOf('<script nonce="n0nce">(function(){function dshCalm'), greaterThan(page.indexOf('glass')));
  });

  test('one [tavern-perf] line per report', () {
    expect(
      tavernPerfLine('canvas', {
        'span': 5012,
        'frames': 240,
        'long': 3,
        'worst': 84,
        'mes': 24,
        'off': 21,
      }, lowPower: false),
      '[tavern-perf] canvas 5.0s frames=240 fps=47.9 long=3 worst=84ms mes=24 off=21 lowPower=false',
    );
    expect(
      tavernPerfLine('island:0a1b', {'span': 5000, 'frames': 300, 'long': 0, 'worst': 17}, lowPower: true),
      '[tavern-perf] island:0a1b 5.0s frames=300 fps=60.0 long=0 worst=17ms lowPower=true',
    );
    expect(tavernPerfLog, isFalse, reason: 'off unless built with --dart-define=DSH_TAVERN_PERF=true');
  });

  testWidgets('酒馆设置 › 显示 has 省电渲染, off until chosen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const TavernSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const key = ValueKey('tavern-low-power');
    await tester.scrollUntilVisible(find.byKey(key), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('省电渲染'), findsOneWidget);
    expect(find.text('去掉卡片网页里的模糊和循环动画，手机更流畅'), findsOneWidget);
    final tile = find.descendant(of: find.byKey(key), matching: find.byType(Switch));
    expect(tester.widget<Switch>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(TavernSettingsController.lowPowerKey), isTrue);
  });
}
