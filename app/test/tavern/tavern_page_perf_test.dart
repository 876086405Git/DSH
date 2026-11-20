// What keeps cards' heavy pages light (tavern_page_perf.dart): its helpers
// run under Node (support/page_perf_test.mjs), and where the canvas puts
// them.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas.dart';
import 'package:dsh_app/tavern/tavern_page_perf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _canvas() => tavernCanvasDocument(
  text: const Color(0xff112233),
  accent: const Color(0xff445566),
  muted: const Color(0xff778899),
  quote: const Color(0xffaa5500),
  emphasis: const Color(0xff556677),
  userTint: const Color(0x22445566),
  fontSize: 15,
  lineHeight: 1.6,
  nonce: 'n0nce',
);

void main() {
  test('the helpers do what they say (under Node)', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-page-perf-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/scripts.json')..writeAsStringSync(jsonEncode({'offscreen': tavernOffscreenJs}));
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
  });
}
