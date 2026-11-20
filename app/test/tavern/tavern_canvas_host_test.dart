// ST's own page as far as preset and card scripts reach for it
// (tavern_canvas_host.dart): its piece of the canvas page runs under Node
// (support/canvas_host_test.mjs); here, where the canvas puts it.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/tavern/tavern_canvas.dart';
import 'package:dsh_app/tavern/tavern_canvas_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _canvas({bool noScripts = false}) => tavernCanvasDocument(
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
);

void main() {
  test('the piece does what it says (under Node)', () async {
    final dir = Directory.systemTemp.createTempSync('dsh-canvas-host-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/host.json')..writeAsStringSync(jsonEncode({'host': tavernCanvasHostJs}));
    final result = await Process.run(
      'node',
      ['--test', 'test/tavern/support/canvas_host_test.mjs'],
      environment: {'DSH_HOST_SCRIPT': file.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test("on the canvas: after the helpers, the preset delivered through it, ST's places made by the first script", () {
    final page = _canvas();
    expect(page, contains(tavernCanvasHostJs));
    expect(page.indexOf(tavernCanvasHostJs), greaterThan(page.indexOf('function adoptResources(')));
    expect(page, contains('res=r;\n    presetDelivered(was,r.preset);'));
    expect(page, contains('function startFrame(s){\n    hostAnchors();'));
    expect(page, contains("if(d.kind==='press'){press(d.id);return;}"));
  });
}
