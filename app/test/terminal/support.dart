// A scripted terminal Host for the terminal page tests: real
// TerminalAttachment protocol handling over in-memory pipes, frames shaped like
// DSH 0.2.1-rc.2's (recorded from a throwaway `dsh web`).

import 'dart:async';

import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

Map<String, Object?> infoJson(
  String id, {
  String title = 'bash',
  int cols = 80,
  int rows = 24,
  String state = 'running',
  int? exitCode,
  String cwd = '/root/work/dsh-app',
}) => {
  'id': id,
  'shell': {
    'path': '/bin/bash',
    'name': 'bash',
    'args': ['-i'],
  },
  'title': title,
  'cwd': cwd,
  'cols': cols,
  'rows': rows,
  'state': state,
  'exitCode': exitCode,
};

/// One `terminal/attach` stream as the fake Host sees it.
class FakeAttach {
  FakeAttach(this.id);

  final String id;
  final down = StreamController<Object?>();
  final sent = <Map<String, Object?>>[];
  int _sequence = 0;
  bool cancelled = false;
  bool autoAck = true;

  /// Everything written so far, in order.
  String get written => [
    for (final c in sent)
      if (c['type'] == 'write') c['data']! as String,
  ].join();

  List<Map<String, Object?>> get resizes => [
    for (final c in sent)
      if (c['type'] == 'resize') c,
  ];

  void snapshot(Map<String, Object?> info, {String screen = '', bool writable = true}) {
    _sequence = 3;
    down.add({
      'type': 'snapshot',
      'sequence': _sequence,
      'screen': screen,
      'info': info,
      'writable': writable,
      'inputWindow': {'maxBytes': 262144, 'frameOverheadBytes': 74},
    });
  }

  void output(String data) => down.add({'type': 'output', 'sequence': ++_sequence, 'data': data});

  void state(Map<String, Object?> info, {bool writable = true}) =>
      down.add({'type': 'state', 'info': info, 'writable': writable});

  void lose() => down.addError(const DshCarrierLostException('socket closed'));

  void end() => down.close();

  void receive(Object? value) {
    final command = (value! as Map).cast<String, Object?>();
    sent.add(command);
    if (autoAck) scheduleMicrotask(() => down.add({'type': 'ack', 'sequence': command['sequence']}));
  }
}

class FakeTerminalBackend implements TerminalBackend {
  FakeTerminalBackend({List<Map<String, Object?>> terminals = const [], this.supported = true}) {
    for (final t in terminals) {
      host[t['id']! as String] = t;
    }
  }

  @override
  bool supported;

  @override
  bool offOnHost = false;

  /// Terminals the Host keeps (id → info JSON).
  final Map<String, Map<String, Object?>> host = {};
  final calls = <String>[];
  final attaches = <FakeAttach>[];
  final reconnects = StreamController<void>.broadcast();
  final shellList = const [
    TerminalShell(path: '/bin/bash', name: 'bash', args: ['-i']),
    TerminalShell(path: '/usr/bin/fish', name: 'fish', args: ['-i']),
  ];

  /// Screens the next snapshot of each terminal shows.
  final Map<String, String> screens = {};

  /// Screen of terminals created through the page.
  String createdScreen = '';

  TerminalEnvironment env = const TerminalEnvironment(cwd: '/root/work/dsh-app');
  Object? listError;
  Object? createError;
  bool autoSnapshot = true;
  final created = <Map<String, Object?>>[];

  FakeAttach attachOf(String id) => attaches.lastWhere((a) => a.id == id);

  @override
  Stream<void> get reconnected => reconnects.stream;

  @override
  Future<TerminalEnvironment> environment() async {
    calls.add('environment');
    return env;
  }

  @override
  Future<List<TerminalShell>> shells() async {
    calls.add('shells');
    return shellList;
  }

  @override
  Future<List<TerminalInfo>> list() async {
    calls.add('list');
    if (listError case final error?) throw error;
    return [for (final t in host.values) TerminalInfo.fromJson(t)!];
  }

  @override
  Future<TerminalInfo> create(String id, {required int cols, required int rows, String? shellPath}) async {
    calls.add('create');
    created.add({'id': id, 'cols': cols, 'rows': rows, 'shellPath': shellPath});
    if (createError case final error?) throw error;
    final info = infoJson(id, title: shellPath?.split('/').last ?? 'bash', cols: cols, rows: rows);
    host[id] = info;
    screens.putIfAbsent(id, () => createdScreen);
    return TerminalInfo.fromJson(info)!;
  }

  @override
  Future<void> rename(String id, String title) async {
    calls.add('rename');
    final info = host[id];
    if (info != null) host[id] = {...info, 'title': title};
  }

  @override
  Future<void> close(String id) async {
    calls.add('close:$id');
    host.remove(id);
  }

  @override
  Stream<void> retain(String id) {
    calls.add('retain:$id');
    if (!host.containsKey(id)) {
      return Stream.error(const DshRemoteException('terminal/unavailable', 'Terminal is closing or unavailable'));
    }
    final controller = StreamController<void>();
    controller.onListen = () => controller.add(null);
    return controller.stream;
  }

  @override
  TerminalAttachment attach(String id, TerminalEnvironment environment) {
    calls.add('attach:$id');
    final fake = FakeAttach(id);
    attaches.add(fake);
    final attachment = TerminalAttachment.over(
      items: fake.down.stream,
      send: fake.receive,
      cancel: () async => fake.cancelled = true,
      environment: environment,
    );
    final info = host[id];
    if (info == null) {
      fake.down.addError(const DshRemoteException('terminal/unavailable', 'Terminal no longer exists in this Session'));
    } else if (autoSnapshot) {
      fake.snapshot(info, screen: screens[id] ?? '', writable: info['state'] == 'running');
    }
    return attachment;
  }
}

List<Override> terminalOverrides(FakeTerminalBackend backend) => [
  terminalBackendProvider.overrideWith((ref, sessionId) => backend),
];

/// A prompt and a short listing, as bash would leave the screen.
const sampleScreen =
    '\x1b[1;32mroot@phone\x1b[0m:\x1b[1;34m~/work/dsh-app\x1b[0m\$ git status --short\r\n'
    ' M app/lib/ui/terminal/terminal_page.dart\r\n'
    '\x1b[32m?? app/test/terminal/\x1b[0m\r\n'
    '\x1b[1;32mroot@phone\x1b[0m:\x1b[1;34m~/work/dsh-app\x1b[0m\$ ls\r\n'
    'README.md  \x1b[1;34mapp\x1b[0m  \x1b[1;34mdocs\x1b[0m  \x1b[1;34mpackages\x1b[0m  pubspec.yaml\r\n'
    '\x1b[1;32mroot@phone\x1b[0m:\x1b[1;34m~/work/dsh-app\x1b[0m\$ ';

/// The terminal page on the phone surface of the golden harness.
Future<void> pumpTerminalPage(
  WidgetTester tester,
  FakeTerminalBackend backend, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  List<Override> overrides = const [],
}) async {
  // Real fonts: the key row measures its labels (the test font draws every
  // glyph 1em wide).
  await tester.runAsync(loadGoldenFonts);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: brightness,
      overrides: [...terminalOverrides(backend), ...overrides],
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: const TerminalPage(sessionId: 's1'),
      ),
    ),
  );
  await settleTerminal(tester);
}

/// Lets the fake Host's microtasks and the page's frames run.
Future<void> settleTerminal(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
}
