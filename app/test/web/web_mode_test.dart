// 网页模式: the official DSH Web as the app's home. Where the native handle
// sits in every layout (against the room the injected CSS reserves in the
// page), how the two modes hand the conversation over, and how the rest of
// the phone (shares, launcher shortcuts, 「在网页版打开」) lands in the page.

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_app/ui/web/mode_home.dart';
import 'package:dsh_app/ui/web/web_back.dart';
import 'package:dsh_app/ui/web/web_handle.dart';
import 'package:dsh_app/ui/web/web_home.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_app/ui/web/web_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../chat/support/harness.dart';
import '../pets/overlay/fake_overlay_native.dart';
import '../support/english_preview.dart';
import 'support/fake_webview.dart';

final _url = Uri.parse('http://127.0.0.1:41234/?token=t');

typedef _Window = ({String name, Size size, EdgeInsets padding});

/// The four widths and a phone on its side (emulator punch-hole on the left).
const _windows = <_Window>[
  (name: 'phone', size: Size(411.4, 914.3), padding: EdgeInsets.fromLTRB(0, 52, 0, 24)),
  (name: 'phone on its side', size: Size(914.3, 411.4), padding: EdgeInsets.fromLTRB(52, 28, 0, 24)),
  (name: '600', size: Size(600, 960), padding: EdgeInsets.fromLTRB(0, 24, 0, 32)),
  (name: '840', size: Size(840, 1200), padding: EdgeInsets.fromLTRB(0, 24, 0, 32)),
  (name: '1280', size: Size(1280, 800), padding: EdgeInsets.fromLTRB(0, 24, 0, 32)),
];

void _useWindow(WidgetTester tester, _Window w) {
  const dpr = 2.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = w.size * dpr;
  final p = FakeViewPadding(
    left: w.padding.left * dpr,
    top: w.padding.top * dpr,
    right: w.padding.right * dpr,
    bottom: w.padding.bottom * dpr,
  );
  tester.view.padding = p;
  tester.view.viewPadding = p;
  addTearDown(tester.view.reset);
}

/// A native plugin channel (SharePlugin.kt / ShortcutsPlugin.kt): pushes
/// once Dart says `ready`.
class _Native {
  _Native(this.tester, String name, this.method) : channel = MethodChannel(name) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => true);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  }

  final WidgetTester tester;
  final MethodChannel channel;
  final String method;

  Future<void> push(Map<String, Object?> args) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

late FakeWebViewPlatform _platform;
late _Native _shares;
late _Native _entries;
late List<MethodCall> _platformCalls;

FakeWebViewController get _page => _platform.controllers.last;

/// The page's open-bridge calls, as targets.
List<Map<String, Object?>> _opened() => [
  for (final s in _page.scripts)
    if (s.startsWith('window.__dshAppOpen && window.__dshAppOpen('))
      jsonDecode(s.substring('window.__dshAppOpen && window.__dshAppOpen('.length, s.length - 2))
          as Map<String, Object?>,
];

Iterable<String> _composeCalls() =>
    _page.scripts.where((s) => s.startsWith('window.__dshAppCompose && window.__dshAppCompose('));

Future<ProviderContainer> _pumpHome(
  WidgetTester tester,
  _Window window, {
  String? session,
  DshWebTarget? initial,
  String? operatingSystem,
}) async {
  _useWindow(tester, window);
  _shares = _Native(tester, 'dsh/share', 'share');
  _entries = _Native(tester, 'dsh/shortcuts', 'entry');
  _platformCalls = [];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    _platformCalls.add(call);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  final harness = ChatHarness(session: session);
  await tester.pumpWidget(
    testApp(
      WebHome(initial: initial),
      overrides: [
        ...harness.overrides,
        if (operatingSystem != null) operatingSystemProvider.overrideWithValue(operatingSystem),
        dshWebAccessProvider.overrideWithValue(SshDshWeb(_url, 'studio')),
      ],
    ),
  );
  // The WebView loads once it is set up and guarded.
  for (var i = 0; i < 20 && _page.loads.isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  _page.finish();
  // The bridges load from the asset bundle: real time, then frames.
  for (var i = 0; i < 40 && !_page.scripts.any((s) => s.contains('window.__dshAppOpen = function')); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await pumpFrames(tester, 3);
  return ProviderScope.containerOf(tester.element(find.byType(WebHome)));
}

Finder get _handle => find.byType(WebHandleButton);

bool _inside(Rect inner, Rect outer) =>
    inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({UiModeController.key: 'web'});
    WebViewPlatform.instance = _platform = FakeWebViewPlatform();
  });

  group('the handle never covers the page', () {
    for (final w in _windows) {
      testWidgets('${w.name}: it takes the back button\'s seat, in the room the page keeps for it', (tester) async {
        await _pumpHome(tester, w);
        final padding = MirroredSideInsets.mirror(w.padding);
        final insets = WebPageInsets.resolve(size: w.size, padding: padding, keyboard: 0, dshWeb: true, adapt: true);
        final handle = tester.getRect(_handle);
        expect(handle.size, const Size.square(WebChromeMetrics.button));
        // One mark of the app, nothing else in its seat.
        expect(find.byTooltip('返回'), findsNothing);
        if (insets.chrome == WebChrome.inline) {
          // Beside the drawer button, inside the header row's leading room
          // (--dsh-app-lead / --dsh-app-lead-h): the page's title, actions,
          // composer and scroll-to-bottom key all start past it.
          final menu = tester.getRect(find.byTooltip('对话与工作区'));
          expect(handle.left, padding.left + WebChromeMetrics.edge);
          expect(handle.top, padding.top + WebChromeMetrics.inlineTop);
          expect(menu.left - handle.right, 8);
          expect(menu.center.dy, handle.center.dy);
          final room = Rect.fromLTRB(
            padding.left,
            padding.top,
            padding.left + insets.lead,
            padding.top + insets.leadHeight,
          );
          expect(_inside(handle, room), isTrue, reason: '$handle in $room');
          expect(room.right - menu.right, greaterThanOrEqualTo(8));
          expect(menu.bottom, lessThanOrEqualTo(room.bottom));
          // Full-screen layers start below both.
          expect(insets.layerTop, greaterThan(menu.bottom));
        } else {
          // Tablets: the official layout; the band above the sidebar holds
          // it, centred on the icon rail's column.
          expect(w.name, '1280');
          expect(find.byTooltip('对话与工作区'), findsNothing);
          final band = Rect.fromLTWH(padding.left, padding.top, WebChromeMetrics.rail, insets.band);
          expect(_inside(handle, band), isTrue, reason: '$handle in $band');
          expect(handle.center, band.center);
        }
      });
    }
  });

  group('the conversation follows across modes', () {
    testWidgets('the page reports where it is; the app keeps it', (tester) async {
      final container = await _pumpHome(tester, _windows.first, session: 's1');
      _page.post('DshAppState', jsonEncode({'session': 's9'}));
      await tester.pump();
      expect(container.read(currentSessionProvider), 's9');
      // Its own report doesn't send the page anywhere.
      await pumpFrames(tester, 2);
      expect(_opened().where((t) => t['session'] == 's9'), isEmpty);
    });

    testWidgets('a conversation chosen in the app (a notification, a shortcut) opens in the page', (tester) async {
      final container = await _pumpHome(tester, _windows.first);
      container.read(currentSessionProvider.notifier).select('s2');
      await pumpFrames(tester, 2);
      expect(_opened(), contains(equals({'session': 's2'})));
    });

    testWidgets('a notification tap opens its conversation in the page', (tester) async {
      final container = await _pumpHome(tester, _windows.first, session: 's1');
      // What a tap (system or banner) does: ChatAlertHost → chatAlertsProvider.
      container.read(chatAlertsProvider.notifier).open(HostRef.local, 's7');
      await pumpFrames(tester, 2);
      expect(container.read(activeHostProvider), HostRef.local);
      expect(_opened().last, {'session': 's7'});
    });

    testWidgets('a switch from native lands on its conversation', (tester) async {
      await _pumpHome(tester, _windows.first, initial: const DshWebTarget(sessionId: 's1'));
      expect(_opened(), contains(equals({'session': 's1'})));
    });

    testWidgets('the handle goes back to native with the conversation on screen', (tester) async {
      final container = await _pumpHome(tester, _windows.first, session: 's1');
      await container.read(uiModeProvider.notifier).set(UiMode.web);
      _page.post('DshAppState', jsonEncode({'session': 's4'}));
      await tester.tap(_handle);
      await tester.pumpAndSettle();
      expect(find.text('切回原生界面'), findsOneWidget);
      expect(find.text('App 设置'), findsOneWidget);
      expect(find.text('切换主机'), findsOneWidget);
      await tester.tap(find.text('切回原生界面'));
      await tester.pumpAndSettle();
      expect(container.read(uiModeProvider).mode, UiMode.native);
      expect(container.read(currentSessionProvider), 's4');
    });

    // English smoke golden (i18n): the handle and its sheet, light.
    testWidgets('the handle sheet (en)', (tester) async {
      useEnglish();
      final container = await _pumpHome(tester, _windows.first, session: 's1');
      await container.read(uiModeProvider.notifier).set(UiMode.web);
      await tester.tap(_handle);
      await tester.pumpAndSettle();
      expect(find.text('Switch to native'), findsOneWidget);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/en_web_handle_sheet_light.png'));
    });

    testWidgets('back at the page\'s root leaves the app, as on the native home', (tester) async {
      await _pumpHome(tester, _windows.first);
      await tester.binding.handlePopRoute();
      await pumpFrames(tester, 2);
      expect(_platformCalls.map((c) => c.method), contains('SystemNavigator.pop'));
    });

    // The owner's report: back in the page's settings went to the launcher.
    testWidgets('back in the page\'s settings closes them; the app is left only from the page\'s root', (tester) async {
      await _pumpHome(tester, _windows.first);
      final open = ['layer'];
      _page.results = (script) {
        if (script != WebBack.script) return false;
        return open.isEmpty ? '"none"' : '"${open.removeLast()}"';
      };
      await tester.binding.handlePopRoute();
      await pumpFrames(tester, 2);
      expect(_platformCalls.map((c) => c.method), isNot(contains('SystemNavigator.pop')));
      expect(open, isEmpty);
      await tester.binding.handlePopRoute();
      await pumpFrames(tester, 2);
      expect(_platformCalls.map((c) => c.method), contains('SystemNavigator.pop'));
    });
  });

  group('compose reply ownership', () {
    Future<List<Object?>> runPair(WidgetTester tester, {bool ios = true, bool lateFirst = false}) async {
      debugDefaultTargetPlatformOverride = ios ? TargetPlatform.iOS : TargetPlatform.android;
      try {
        await _pumpHome(tester, _windows.first, operatingSystem: ios ? 'ios' : 'android');
        for (final text in ['first ordinary draft', 'second ordinary draft']) {
          await _shares.push({'text': text, 'files': <Object>[], 'skipped': <Object>[]});
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await pumpFrames(tester, 3);
          if (lateFirst && text == 'first ordinary draft') {
            await tester.pump(const Duration(seconds: 31));
            await pumpFrames(tester, 3);
          }
        }
        expect(_composeCalls().length, 2);
        const prefix = 'window.__dshAppCompose && window.__dshAppCompose(';
        final drafts = [for (final s in _composeCalls()) jsonDecode(s.substring(prefix.length, s.length - 2))];
        final output = await tester.runAsync(
          () => Process.run('node', [
            'test/web/support/compose_pair_harness.mjs',
            'assets/web/dsh_web_open.js',
            jsonEncode(drafts),
          ]),
        );
        expect(output!.exitCode, 0, reason: output.stderr.toString());
        final actualJS = jsonDecode(output.stdout.toString()) as Map<String, dynamic>;
        final replies = actualJS['messages'] as List;
        for (final reply in lateFirst ? replies.take(1) : replies) {
          _page.post('DshAppCompose', jsonEncode(reply));
          await pumpFrames(tester, 2);
        }
        // With lateFirst, A timed out before B began; its success arrives late.
        // B's response is deliberately withheld to exercise its own timeout.
        await tester.pump(const Duration(seconds: 31));
        await pumpFrames(tester, 3);
        final copied = <Object?>[
          for (final c in _platformCalls.where((c) => c.method == 'Clipboard.setData')) (c.arguments as Map)['text'],
        ];
        debugPrint(jsonEncode({'js': actualJS, 'lateFirst': lateFirst, 'copied': copied}));
        return copied;
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('iOS two ordinary successful pastes do not falsely time out', (tester) async {
      expect(await runPair(tester), isEmpty);
    });

    testWidgets('iOS late reply cannot acknowledge the next unanswered paste', (tester) async {
      expect(await runPair(tester, lateFirst: true), ['first ordinary draft', 'second ordinary draft']);
    });

    testWidgets('Android keeps its existing uncorrelated reply contract', (tester) async {
      expect(await runPair(tester, ios: false), ['first ordinary draft']);
    });
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('composer attachment receipt option $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await _pumpHome(tester, _windows.first);
        await _shares.push({'text': 'ordinary receipt control', 'files': <Object>[], 'skipped': <Object>[]});
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await pumpFrames(tester, 3);
        final script = _composeCalls().single;
        final draft = jsonDecode(script.substring(script.indexOf('({') + 1, script.lastIndexOf(');'))) as Map;
        expect(draft['text'], 'ordinary receipt control');
        expect(draft.containsKey('composerAttachmentCount'), platform == TargetPlatform.iOS);
        if (platform == TargetPlatform.iOS) expect(draft['composerAttachmentCount'], isTrue);
        expect(draft.containsKey('requireOpenedTarget'), platform == TargetPlatform.iOS);
        if (platform == TargetPlatform.iOS) expect(draft['requireOpenedTarget'], isTrue);
        _page.post('DshAppCompose', jsonEncode({'text': true, 'files': 0, 'requestId': ?draft['requestId']}));
        await pumpFrames(tester, 2);
        expect(find.byType(SnackBar), findsNothing);
        expect(draft.containsKey('guardTextFallback'), platform == TargetPlatform.iOS);
        if (platform == TargetPlatform.iOS) expect(draft['guardTextFallback'], isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('the rest of the phone lands in the page', () {
    testWidgets('a shared text goes into a new conversation\'s composer', (tester) async {
      await _pumpHome(tester, _windows.first, session: 's1');
      await _shares.push({'text': '帮我看看这份报价', 'files': <Object>[], 'skipped': <Object>[]});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpFrames(tester, 3);
      expect(_opened().last, {'newSession': true});
      expect(_composeCalls().single, contains('"text":"帮我看看这份报价"'));
      _page.post('DshAppCompose', jsonEncode({'text': true, 'files': 0}));
      await pumpFrames(tester, 2);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('what the page can\'t take: the text to the clipboard, one short line', (tester) async {
      await _pumpHome(tester, _windows.first);
      await _shares.push({'text': '一段分享', 'skipped': <Object>[]});
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpFrames(tester, 3);
      _page.post('DshAppCompose', jsonEncode({'text': false, 'files': 0}));
      await pumpFrames(tester, 2);
      final copied = _platformCalls.where((c) => c.method == 'Clipboard.setData').single;
      expect((copied.arguments as Map)['text'], '一段分享');
      expect(find.text('文字已复制，粘贴到输入框即可'), findsOneWidget);
    });

    testWidgets('a pet screenshot reaches the web composer as an unsent image', (tester) async {
      final slot = Directory.systemTemp.createTempSync('dsh-web-screenshot');
      addTearDown(() {
        if (slot.existsSync()) slot.deleteSync(recursive: true);
      });
      final image = File('${slot.path}/screenshot.png')..writeAsBytesSync(tinyPng);
      await _pumpHome(tester, _windows.first, session: 's1');
      await _entries.push({'kind': 'screenshot', 'path': image.path});
      for (var i = 0; i < 40 && _composeCalls().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await pumpFrames(tester, 2);
      }

      expect(_opened().last, {'newSession': true});
      expect(_composeCalls().single, contains('"name":"screenshot.png"'));
      expect(_composeCalls().single, contains('"type":"image/png"'));
      expect(image.existsSync(), isFalse);
      _page.post('DshAppCompose', jsonEncode({'text': true, 'files': 1}));
      await pumpFrames(tester, 2);
    });

    testWidgets('launcher: 新对话 starts one in the page; a recent conversation opens there', (tester) async {
      final container = await _pumpHome(tester, _windows.first, session: 's1');
      await _entries.push({'kind': 'new'});
      await pumpFrames(tester, 3);
      expect(_opened().last, {'newSession': true});
      expect(_composeCalls(), isEmpty);

      await _entries.push({'kind': 'chat', 'sessionId': 's3', 'host': HostRef.local.encode()});
      await pumpFrames(tester, 3);
      expect(container.read(activeHostProvider), HostRef.local);
      expect(container.read(currentSessionProvider), 's3');
      expect(_opened().last, {'session': 's3'});
    });

    testWidgets('「在网页版打开」 from a native page goes to the home page, not a second one', (tester) async {
      final container = await _pumpHome(tester, _windows.first);
      await container.read(uiModeProvider.notifier).set(UiMode.web);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => openDshWeb(context, ref, target: const DshWebTarget(panel: DshWebPanel.plugins)),
                child: const Text('在网页版打开'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('在网页版打开'));
      await tester.pumpAndSettle();
      expect(find.text('在网页版打开'), findsNothing);
      expect(_platform.controllers, hasLength(1));
      expect(_opened().last, {'panel': 'plugins'});
    });
  });

  testWidgets('the floating pet hears every state and opens its settings from the web home', (tester) async {
    final native = FakeOverlayNative()..install();
    await _pumpHome(tester, _windows.first);
    expect(native.methods, contains('push'));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      FakeOverlayNative.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('openSettings')),
      (_) {},
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(PetSettingsPage), findsOneWidget);
  });

  group('ModeHome', () {
    Widget home() => ModeHome(native: const Text('原生首页'), web: (initial) => Text('网页首页 ${initial?.toJson()}'));

    testWidgets('opens straight into the stored mode, with no frame of the other', (tester) async {
      await tester.pumpWidget(
        testApp(home(), overrides: [currentSessionProvider.overrideWith(() => FixedSession('s1'))]),
      );
      expect(find.text('原生首页'), findsNothing);
      expect(find.textContaining('网页首页'), findsNothing);
      await tester.pumpAndSettle();
      // A cold start in web mode: the page restores its own conversation.
      expect(find.text('网页首页 null'), findsOneWidget);
      expect(find.text('原生首页'), findsNothing);
    });

    testWidgets('switching from native hands the conversation over', (tester) async {
      SharedPreferences.setMockInitialValues({UiModeController.key: 'native'});
      await tester.pumpWidget(
        testApp(home(), overrides: [currentSessionProvider.overrideWith(() => FixedSession('s1'))]),
      );
      await tester.pumpAndSettle();
      expect(find.text('原生首页'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.text('原生首页')));
      await container.read(uiModeProvider.notifier).set(UiMode.web);
      await tester.pumpAndSettle();
      expect(find.text('网页首页 {session: s1}'), findsOneWidget);
      // A new chat on the native side is a new conversation in the page.
      await container.read(uiModeProvider.notifier).set(UiMode.native);
      await tester.pumpAndSettle();
      container.read(currentSessionProvider.notifier).select(null);
      await container.read(uiModeProvider.notifier).set(UiMode.web);
      await tester.pumpAndSettle();
      expect(find.text('网页首页 {newSession: true}'), findsOneWidget);
    });

    testWidgets('the drawer\'s key switches to the web', (tester) async {
      SharedPreferences.setMockInitialValues({UiModeController.key: 'native'});
      await tester.pumpWidget(testApp(const Scaffold(body: Center(child: WebModeKey()))));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(WebModeKey)));
      expect(tester.getSize(find.byType(GlassIconButton)), const Size.square(36));
      await tester.tap(find.byType(WebModeKey));
      await tester.pumpAndSettle();
      expect(container.read(uiModeProvider).mode, UiMode.web);
    });
  });
}
