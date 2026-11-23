// The room's WebView shares its renderer with the floating window's
// (docs/design/companion-floating.md, 小屋接线合同): the real CompanionStage
// guards it before loading, leaves for good when the renderer dies or the
// pack is about to change, and closes its server before the store moves on.
// The WebView platform is a fake; the server and the store are real.

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../plugins/islands/support/fakes.dart';

/// As webview_flutter_android's controller: it has the native WebView's id.
class _Page extends FakeWebViewController {
  _Page(super.params) : webViewIdentifier = _next++;

  static int _next = 1;
  final int webViewIdentifier;
}

class _Web extends FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final page = _Page(params);
    controllers.add(page);
    return page;
  }
}

class _Islands extends FakeIslandPlatform {
  bool guards = true;
  final attached = <int>[];
  final destroyed = <int>[];

  /// Holds [device] back: a start parked right after its server came up.
  Completer<void>? deviceGate;

  @override
  Future<IslandDevice> device() async {
    await deviceGate?.future;
    return deviceInfo;
  }

  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async {
    attached.add(webViewId);
    return guards;
  }

  @override
  Future<void> destroy(int webViewId) async => destroyed.add(webViewId);
}

/// Whether anything still listens where [page] was served from.
Future<bool> _listening(Uri page) async {
  try {
    (await Socket.connect(page.host, page.port, timeout: const Duration(seconds: 5))).destroy();
    return true;
  } on SocketException {
    return false;
  }
}

class _Room {
  _Room(this.root);
  final Directory root;
  final web = _Web();
  final islands = _Islands();
  final controller = CompanionStageController();
  final failures = <String>[];
  int readyCount = 0;

  _Page get page => web.controllers.single as _Page;
  Uri get url => page.loads.single;

  Future<void> open(WidgetTester tester, {bool Function()? until}) async {
    WebViewPlatform.instance = web;
    IslandPlatform.instance = islands;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompanionStage(
            store: CompanionPackStore(root),
            controller: controller,
            events: CompanionStageEvents(
              onReady: () => readyCount++,
              onFailed: failures.add,
              onTouch: (_, _) {},
              onWake: () {},
              onMood: (_) {},
              onObject: (_) {},
              onActivity: (_) {},
            ),
          ),
        ),
      ),
    );
    until ??= () => web.controllers.isNotEmpty && page.loads.isNotEmpty;
    await settle(tester, until: until);
  }

  /// Real socket and file work, then the frames it causes.
  Future<void> settle(WidgetTester tester, {bool Function()? until}) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (until?.call() ?? i >= 2) break;
    }
  }

  void ready() =>
      page.channels['DshCompanion']!.onMessageReceived(const JavaScriptMessage(message: '{"type":"ready"}'));

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }
}

void main() {
  late Directory root;
  late IslandPlatform previousPlatform;
  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-guard-');
    previousPlatform = IslandPlatform.instance;
  });
  tearDown(() {
    IslandPlatform.instance = previousPlatform;
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  testWidgets('guarded after the navigation delegate and before the load', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    expect(room.failures, isEmpty);
    expect(room.islands.attached, [room.page.webViewIdentifier]);
    expect(room.page.delegate, isNotNull);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);
    await room.close(tester);
  });

  testWidgets('leaving the room destroys her WebView', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    final id = room.page.webViewIdentifier;
    await room.close(tester);
    expect(room.islands.destroyed, [id]);
  });

  testWidgets('a WebView that could not be guarded is never loaded or shown', (tester) async {
    final room = _Room(root)..islands.guards = false;
    await room.open(tester, until: () => room.failures.isNotEmpty);
    expect(room.failures, ['guard']);
    expect(room.page.loads, isEmpty);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    await room.close(tester);
  });

  testWidgets('the renderer dying retires her WebView, closes its server and says so once', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    room.ready();
    await tester.pump();
    expect(room.readyCount, 1);
    final id = room.page.webViewIdentifier;
    final url = room.url;
    expect(await tester.runAsync(() => _listening(url)), isTrue);

    // Reported for another WebView of the app: the renderer is hers too.
    room.islands.emit(const IslandRendererGone(webViewId: 99, crashed: true));
    await room.settle(tester, until: () => room.failures.isNotEmpty);
    await tester.pump();
    expect(room.failures, ['renderer gone']);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(room.islands.destroyed, [id]);
    expect(await tester.runAsync(() => _listening(url)), isFalse);

    // The dead page is no longer heard, nor spoken to; a second report is not hers.
    room.page.scripts.clear();
    room.ready();
    room.controller.command('emotion', {'name': 'happy'});
    room.islands.emit(IslandRendererGone(webViewId: id, crashed: false));
    await room.settle(tester);
    expect(room.readyCount, 1);
    expect(room.page.scripts, isEmpty);
    expect(room.failures, ['renderer gone']);
    expect(room.web.controllers, hasLength(1), reason: 'the dead stage does not load again');
    await room.close(tester);
  });

  testWidgets('a pack change waits until her server has closed', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    room.ready();
    final id = room.page.webViewIdentifier;
    final url = room.url;
    final store = CompanionPackStore(root);
    // Hooks run in order: this one sees what the stage's left behind.
    bool? closedBeforeNextHook;
    final unhook = store.beforeChanges(() async => closedBeforeNextHook = !await _listening(url));
    await tester.runAsync(store.remove);
    unhook();
    expect(closedBeforeNextHook, isTrue);
    await tester.pump();
    await tester.pump();
    expect(room.failures, ['pack changed']);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(room.islands.destroyed, [id]);
    await room.close(tester);
  });

  testWidgets('a start overtaken by a pack change gives up: no WebView, no open server', (tester) async {
    final room = _Room(root)..islands.deviceGate = Completer<void>();
    await room.open(tester, until: () => true);
    await room.settle(tester); // The server is up; the start waits for the device.
    await tester.runAsync(CompanionPackStore(root).remove);
    room.islands.deviceGate!.complete();
    await room.settle(tester);
    expect(room.failures, ['pack changed']);
    expect(room.web.controllers, isEmpty);
    await room.close(tester);
  });

  testWidgets('leaving the room closes the server and lets the pack change', (tester) async {
    final room = _Room(root);
    await room.open(tester);
    final url = room.url;
    await room.close(tester);
    expect(await tester.runAsync(() => _listening(url)), isFalse);
    await tester.runAsync(CompanionPackStore(root).remove);
    expect(room.failures, isEmpty);
  });
}
