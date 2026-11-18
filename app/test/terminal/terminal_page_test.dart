// The terminal page with a scripted Host: the key row and sticky modifiers,
// the soft keyboard bridge, status rows, tabs, selection copy / paste and
// pinch to zoom.

import 'dart:ui' show Tristate;

import 'package:dsh_app/l10n/l10n.dart';

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/runtime_capabilities_state.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/terminal/terminal_keys.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dsh_client/dsh_client.dart' show RuntimeCapabilities, RuntimeShellCapabilities, RuntimeSupport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import '../clipboard/fake_paste.dart';
import 'support.dart';

Finder _key(TerminalExtraKey key) => find.byKey(ValueKey('terminal-key-${key.name}'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('modifier mapping', () {
    test('Ctrl folds into C0 controls, Alt prefixes ESC', () {
      expect(withModifiers('c', ctrl: true), '\x03');
      expect(withModifiers('C', ctrl: true), '\x03');
      expect(withModifiers('[', ctrl: true), '\x1b');
      expect(withModifiers('/', ctrl: true), '\x1f');
      expect(withModifiers('-', ctrl: true), '\x1f');
      expect(withModifiers('~', ctrl: true), '\x1e');
      expect(withModifiers(' ', ctrl: true), '\x00');
      expect(withModifiers('?', ctrl: true), '\x7f');
      expect(withModifiers('|', ctrl: true), '|');
      expect(withModifiers('b', alt: true), '\x1bb');
      expect(withModifiers('x', ctrl: true, alt: true), '\x1b\x18');
      expect(withModifiers('ls', ctrl: true), 'ls', reason: 'more than one character passes through');
      expect(withModifiers('中', ctrl: true), '中');
    });

    test('a tap arms one key, a long press locks', () {
      final modifiers = TerminalModifiers();
      modifiers.tap(TerminalExtraKey.ctrl);
      expect(modifiers.consume(), (ctrl: true, alt: false));
      expect(modifiers.consume(), (ctrl: false, alt: false));
      modifiers.lock(TerminalExtraKey.alt);
      expect(modifiers.consume(), (ctrl: false, alt: true));
      expect(modifiers.consume(), (ctrl: false, alt: true));
      modifiers.tap(TerminalExtraKey.alt);
      expect(modifiers.any, isFalse);
    });
  });

  group('what the engine says about a terminal', () {
    final zh = lookupL10n(AppLocale.zhCN);
    List<Override> on(String os, RuntimeSupport pty) => [
      operatingSystemProvider.overrideWithValue(os),
      runtimeCapabilitiesProvider.overrideWith(
        (ref) async => RuntimeCapabilities(shell: RuntimeShellCapabilities(pty: pty)),
      ),
    ];

    testWidgets('on HarmonyOS, no PTY: said up front, with no terminal card to fail', (tester) async {
      await pumpTerminalPage(tester, FakeTerminalBackend(), overrides: on('ohos', RuntimeSupport.unsupported));
      expect(find.text(zh.harmonyTerminalNoPty), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(find.text(zh.commonRetry), findsNothing);
    });

    testWidgets('on HarmonyOS, a host that has one: it opens', (tester) async {
      final backend = FakeTerminalBackend();
      await pumpTerminalPage(tester, backend, overrides: on('ohos', RuntimeSupport.supported));
      expect(find.text(zh.harmonyTerminalNoPty), findsNothing);
      expect(backend.created, hasLength(1));
    });

    testWidgets('on Android the engine is not asked: it opens as ever', (tester) async {
      final backend = FakeTerminalBackend();
      await pumpTerminalPage(tester, backend, overrides: on('android', RuntimeSupport.unsupported));
      expect(find.text(zh.harmonyTerminalNoPty), findsNothing);
      expect(backend.created, hasLength(1));
    });

    for (final (os, hint) in [('ohos', zh.harmonyTerminalSupportedHosts), ('android', zh.botsTerminalSupportedHosts)]) {
      testWidgets('on $os a connection without terminals says where they are', (tester) async {
        await pumpTerminalPage(
          tester,
          FakeTerminalBackend(supported: false),
          overrides: [operatingSystemProvider.overrideWithValue(os)],
        );
        expect(find.text(hint), findsOneWidget);
      });
    }
  });

  testWidgets('the selected terminal tab exposes its selected semantics', (tester) async {
    final handle = tester.ensureSemantics();
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final id = backend.created.single['id']! as String;
    final node = tester.getSemantics(find.byKey(ValueKey('terminal-tab-$id')));
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    expect(node.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
    handle.dispose();
  });

  testWidgets('keys send escape sequences; sticky Ctrl applies to the next typed key', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final id = backend.created.single['id']! as String;
    final attach = backend.attachOf(id);
    // Started at the measured screen size, not 80 × 24.
    final view = tester.getSize(find.byType(TerminalView));
    expect(backend.created.single['cols'], allOf(greaterThan(20), lessThan(80)));
    expect(backend.created.single['rows'], greaterThan(24));
    expect(view.width, greaterThan(300));
    expect(attach.resizes, isEmpty, reason: 'already the right size');

    for (final key in [TerminalExtraKey.esc, TerminalExtraKey.tab, TerminalExtraKey.up, TerminalExtraKey.pipe]) {
      await tester.tap(_key(key));
      await tester.pump();
    }
    await settleTerminal(tester);
    expect(attach.written, '\x1b\t\x1b[A|');

    // Ctrl, then the soft keyboard types "c".
    await tester.tap(_key(TerminalExtraKey.ctrl));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '  c', selection: TextSelection.collapsed(offset: 3)),
    );
    await settleTerminal(tester);
    expect(attach.written, endsWith('\x03'));

    // Ctrl + ← from the row itself.
    await tester.tap(_key(TerminalExtraKey.ctrl));
    await tester.pump();
    await tester.tap(_key(TerminalExtraKey.left));
    await settleTerminal(tester);
    expect(attach.written, endsWith('\x1b[1;5D'));
  });

  testWidgets('the soft keyboard: text, Backspace, Enter and composing', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final attach = backend.attachOf(backend.created.single['id']! as String);

    void edit(String text, {TextRange composing = TextRange.empty}) => tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: composing,
      ),
    );

    edit('  ls');
    await settleTerminal(tester);
    edit(' ');
    await settleTerminal(tester);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await settleTerminal(tester);
    expect(attach.written, 'ls\x7f\r');

    // Pinyin while composing shows in a pill and sends nothing.
    edit('  zhong', composing: const TextRange(start: 2, end: 7));
    await settleTerminal(tester);
    expect(find.text('zhong'), findsOneWidget);
    expect(attach.written, 'ls\x7f\r');
    edit('  中');
    await settleTerminal(tester);
    expect(find.text('zhong'), findsNothing);
    expect(attach.written, 'ls\x7f\r中');

    // A multi-line commit is lines with Enters.
    edit('  a\nb');
    await settleTerminal(tester);
    expect(attach.written, endsWith('中a\rb'));

    // A key-row key commits what is still composing first (`git ch` + Tab).
    edit('  ch', composing: const TextRange(start: 2, end: 4));
    await settleTerminal(tester);
    await tester.tap(_key(TerminalExtraKey.tab));
    await settleTerminal(tester);
    expect(attach.written, endsWith('bch\t'));
    expect(find.text('ch'), findsNothing);
  });

  testWidgets('ended: 已结束 with the exit code; 新建终端 starts a fresh one in place', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').state(infoJson('a', title: 'build', state: 'exited', exitCode: 1), writable: false);
    await settleTerminal(tester);
    expect(find.text('已结束 · 退出码 1'), findsOneWidget);
    expect(_key(TerminalExtraKey.esc), findsNothing);

    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(backend.calls, contains('close:a'));
    expect(backend.created, hasLength(1));
    expect(find.text('已结束 · 退出码 1'), findsNothing);
    expect(_key(TerminalExtraKey.esc), findsOneWidget);
  });

  testWidgets('a dropped link offers 重新连接; another device holding input offers 接管', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    expect(find.text('连接已断开'), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await settleTerminal(tester);
    expect(backend.attaches, hasLength(2));
    expect(_key(TerminalExtraKey.esc), findsOneWidget);

    backend.attachOf('a').state(infoJson('a'), writable: false);
    await settleTerminal(tester);
    expect(find.text('其他设备正在输入'), findsOneWidget);
    await tester.tap(find.text('接管'));
    await settleTerminal(tester);
    expect(backend.attaches, hasLength(3));
    expect(find.text('其他设备正在输入'), findsNothing);
  });

  testWidgets('tabs: switch, add, and the actions sheet closes one', (tester) async {
    final backend = FakeTerminalBackend(
      terminals: [
        infoJson('a', title: 'server'),
        infoJson('b', title: 'build', state: 'exited', exitCode: 0),
      ],
    );
    await pumpTerminalPage(tester, backend);
    expect(find.text('server'), findsOneWidget);
    expect(find.text('build'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-tab-b')));
    await settleTerminal(tester);
    expect(find.text('已结束'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('terminal-new')));
    await settleTerminal(tester);
    expect(backend.created, hasLength(1));
    expect(find.byKey(ValueKey('terminal-tab-${backend.created.single['id']}')), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('terminal-tab-b')));
    await settleTerminal(tester);
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('关闭终端'));
    await settleTerminal(tester);
    expect(backend.calls, contains('close:b'));
    expect(find.byKey(const ValueKey('terminal-tab-b')), findsNothing);
  });

  testWidgets('closing a running terminal asks first', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'server')]);
    await pumpTerminalPage(tester, backend);
    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    await tester.tap(find.text('关闭终端'));
    await settleTerminal(tester);
    expect(find.text('关闭「server」？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settleTerminal(tester);
    expect(backend.calls.where((c) => c.startsWith('close:')), isEmpty);
  });

  testWidgets('the shell picker starts the chosen shell', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(find.text('选择 Shell'), findsOneWidget);
    await tester.tap(find.text('fish'));
    await settleTerminal(tester);
    expect(backend.created.single['shellPath'], '/usr/bin/fish');
  });

  testWidgets('long press selects; 复制 copies the selection, 粘贴 pastes', (tester) async {
    String? clipboard = 'echo pasted';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final backend = FakeTerminalBackend(terminals: [infoJson('a')])..screens['a'] = 'hello world\r\n\$ ';
    await pumpTerminalPage(tester, backend);

    final view = tester.getRect(find.byType(TerminalView));
    await tester.longPressAt(view.topLeft + const Offset(14, 8));
    await settleTerminal(tester);
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await settleTerminal(tester);
    expect(clipboard, 'hello');
    expect(find.text('复制'), findsNothing);

    clipboard = 'echo pasted';
    await tester.longPressAt(view.topLeft + const Offset(14, 8));
    await settleTerminal(tester);
    await tester.tap(find.text('粘贴'));
    await settleTerminal(tester);
    expect(backend.attachOf('a').written, contains('echo pasted'));
  });

  group('粘贴 on HarmonyOS', () {
    Future<void> selectAndPaste(WidgetTester tester) async {
      final view = tester.getRect(find.byType(TerminalView));
      await tester.longPressAt(view.topLeft + const Offset(14, 8));
      await settleTerminal(tester);
      await tester.tap(find.text('粘贴'));
      await settleTerminal(tester);
    }

    final onHarmony = [operatingSystemProvider.overrideWithValue('ohos')];

    testWidgets('the system paste button\'s text goes in as it is', (tester) async {
      final paste = FakePaste(tester, reply: FakePaste.text('echo pasted\n'), flutterText: 'wrong');
      final backend = FakeTerminalBackend(terminals: [infoJson('a')])..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      await selectAndPaste(tester);
      expect(backend.attachOf('a').written, contains('echo pasted'));
      expect(paste.flutterReads, 0);
    });

    testWidgets('backed out of, nothing goes in and nothing is said', (tester) async {
      FakePaste(tester, reply: {'status': 'cancelled'});
      final backend = FakeTerminalBackend(terminals: [infoJson('a')])..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      final before = backend.attachOf('a').written.length;
      await selectAndPaste(tester);
      expect(backend.attachOf('a').written.length, before);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a paste still waiting is for its terminal: another tab closes the window', (tester) async {
      final paste = FakePaste(tester, reply: FakePaste.text('echo late\n'))..gate = Completer<void>();
      final backend = FakeTerminalBackend(
        terminals: [
          infoJson('a', title: 'one'),
          infoJson('b', title: 'two'),
        ],
      )..screens['a'] = 'hello world\r\n\$ ';
      await pumpTerminalPage(tester, backend, overrides: onHarmony);
      await selectAndPaste(tester);
      expect(paste.reads, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('terminal-tab-b')));
      await settleTerminal(tester);
      expect(paste.cancels, contains(paste.reads.single));
      paste.gate!.complete();
      await settleTerminal(tester);
      expect(backend.attachOf('a').written, isNot(contains('echo late')));
      expect(backend.attachOf('b').written, isNot(contains('echo late')));
    });
  });

  testWidgets('pinch changes the font size', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    final container = ProviderScope.containerOf(tester.element(find.byType(TerminalPage)));
    expect(container.read(terminalFontSizeProvider), TerminalFontSize.fallback);
    final center = tester.getCenter(find.byType(TerminalView));
    final a = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final b = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(terminalFontSizeProvider), closeTo(TerminalFontSize.fallback * 140 / 80, 0.5));
  });

  testWidgets('the PTY follows the screen once it settles', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    final attach = backend.attachOf('a');
    final before = attach.resizes.length;
    final fonts = ProviderScope.containerOf(tester.element(find.byType(TerminalPage)))
        .read(terminalFontSizeProvider.notifier);
    for (final size in [15.0, 17.0, 19.0]) {
      fonts.set(size);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settleTerminal(tester);
    expect(attach.resizes.length, before + 1);
    final last = attach.resizes.last;
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).terminal.viewWidth, last['cols']);
  });

  testWidgets('a connection without terminal support says so', (tester) async {
    await pumpTerminalPage(tester, FakeTerminalBackend(supported: false));
    expect(find.text('这个连接用不了终端'), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    expect(find.byKey(const ValueKey('terminal-more')), findsNothing);
  });

  testWidgets('a terminal the engine lost: 这个终端已不在了 → 新建终端', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a')]);
    await pumpTerminalPage(tester, backend);
    backend.host.remove('a');
    backend.attachOf('a').lose();
    await settleTerminal(tester);
    await tester.tap(find.text('重新连接'));
    await settleTerminal(tester);
    expect(find.text('这个终端已不在了'), findsOneWidget);
    await tester.tap(find.text('新建终端'));
    await settleTerminal(tester);
    expect(backend.created, hasLength(1));
    expect(find.text('这个终端已不在了'), findsNothing);
  });
}
