import 'dart:ui' show PointerDeviceKind;

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/terminal/terminal_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('terminal commands request plain text without IME learning or autocorrect', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final attach = backend.attachOf(backend.created.single['id']! as String);
    final configuration = tester.testTextInput.setClientArgs!;

    expect(configuration['inputType']['name'], 'TextInputType.text');
    expect(configuration['obscureText'], isFalse);
    // Flutter's Android bridge also sets VISIBLE_PASSWORD when suggestions
    // are disabled, even when the Dart input type is ordinary text.
    expect(configuration['enableSuggestions'], isTrue);
    expect(configuration['autocorrect'], isFalse);
    expect(configuration['enableIMEPersonalizedLearning'], isFalse);
    expect(configuration['inputAction'], 'TextInputAction.newline');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  zhong',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 2, end: 7),
      ),
    );
    await settleTerminal(tester);
    expect(attach.written, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '  中', selection: TextSelection.collapsed(offset: 3)),
    );
    await settleTerminal(tester);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await settleTerminal(tester);
    expect(attach.written, '中\r');
  });

  testWidgets('a real touch reopens Android IME; copy, scrolling and mouse selection do not', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final backend = FakeTerminalBackend()..createdScreen = 'hello world\r\n\$ ';
    await pumpTerminalPage(tester, backend, overrides: [operatingSystemProvider.overrideWithValue('android')]);
    final attach = backend.attachOf(backend.created.single['id']! as String);
    final keyboard = tester.state<TerminalKeyboardState>(find.byType(TerminalKeyboard));
    addTearDown(tester.view.resetViewInsets);

    // Model the geometry that Android Back produces, without faking focus loss.
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await settleTerminal(tester);
    expect(keyboard.hasConnection, isTrue);
    tester.testTextInput.log.clear();
    tester.view.viewInsets = FakeViewPadding.zero;
    await settleTerminal(tester);
    expect(keyboard.hasConnection, isTrue, reason: 'zero inset alone is not a detach signal');
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.log.map((call) => call.method), isNot(contains('TextInput.show')));

    final point = tester.getCenter(find.byType(TerminalView));
    // A scroll, a long-press selection and multiple fingers must not behave
    // like ordinary taps while the keyboard is closed.
    await tester.dragFrom(point, const Offset(0, -80));
    await settleTerminal(tester);
    final view = tester.getRect(find.byType(TerminalView));
    await tester.longPressAt(view.topLeft + const Offset(14, 8));
    await settleTerminal(tester);
    await tester.tap(find.text('复制'));
    await settleTerminal(tester);
    expect(copied, 'hello');
    expect(attach.written, isEmpty);
    final first = await tester.startGesture(point + const Offset(30, 0));
    final second = await tester.startGesture(point - const Offset(30, 0));
    await second.up();
    await first.up();
    await settleTerminal(tester);
    final mouse = await tester.startGesture(view.topLeft + const Offset(12, 8), kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(12, 0));
    await mouse.up();
    await settleTerminal(tester);
    expect(find.text('复制'), findsOneWidget, reason: 'the precise drag still selects characters');
    expect(tester.testTextInput.log.map((call) => call.method), isNot(contains('TextInput.show')));

    tester.testTextInput.log.clear();
    await tester.tap(find.byType(TerminalView));
    await settleTerminal(tester);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      containsAllInOrder(['TextInput.setClient', 'TextInput.setEditingState', 'TextInput.show']),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '  ls', selection: TextSelection.collapsed(offset: 4)),
    );
    await settleTerminal(tester);
    expect(attach.written, 'ls');
  });

  for (final inset in [0.0, 240.0]) {
    testWidgets('a tap preserves composition with an Android IME inset of $inset', (tester) async {
      final backend = FakeTerminalBackend();
      await pumpTerminalPage(tester, backend, overrides: [operatingSystemProvider.overrideWithValue('android')]);
      final attach = backend.attachOf(backend.created.single['id']! as String);
      addTearDown(tester.view.resetViewInsets);
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await settleTerminal(tester);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  zhong',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        ),
      );
      await settleTerminal(tester);
      tester.testTextInput.log.clear();

      await tester.tap(find.byType(TerminalView));
      await settleTerminal(tester);
      expect(tester.testTextInput.log.map((call) => call.method), isNot(contains('TextInput.setClient')));
      expect(find.text('zhong'), findsOneWidget);
      expect(attach.written, isEmpty);
    });
  }

  testWidgets('switching the Android IME from docked to floating keeps the composing client', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend, overrides: [operatingSystemProvider.overrideWithValue('android')]);
    final attach = backend.attachOf(backend.created.single['id']! as String);
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await settleTerminal(tester);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  zhong',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 2, end: 7),
      ),
    );
    await settleTerminal(tester);
    tester.testTextInput.log.clear();

    tester.view.viewInsets = FakeViewPadding.zero;
    await settleTerminal(tester);
    final methods = tester.testTextInput.log.map((call) => call.method);
    expect(methods, isNot(contains('TextInput.clearClient')));
    expect(methods, isNot(contains('TextInput.hide')));
    expect(find.text('zhong'), findsOneWidget);
    expect(attach.written, isEmpty);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '  中', selection: TextSelection.collapsed(offset: 3)),
    );
    await settleTerminal(tester);
    expect(attach.written, '中');
  });

  testWidgets('the terminal actions can reopen a dismissed keyboard', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend, overrides: [operatingSystemProvider.overrideWithValue('android')]);
    addTearDown(tester.view.resetViewInsets);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await settleTerminal(tester);
    tester.view.viewInsets = FakeViewPadding.zero;
    await settleTerminal(tester);

    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    tester.testTextInput.log.clear();
    await tester.tap(find.text('唤起键盘'));
    await settleTerminal(tester);
    expect(find.text('唤起键盘'), findsNothing);
    expect(
      tester.testTextInput.log.map((call) => call.method),
      containsAllInOrder(['TextInput.setClient', 'TextInput.setEditingState', 'TextInput.show']),
    );
  });

  testWidgets('terminal rename keeps ordinary text input while editing a Chinese name', (tester) async {
    final backend = FakeTerminalBackend(terminals: [infoJson('a', title: 'build')]);
    await pumpTerminalPage(tester, backend);
    await tester.tap(find.byKey(const ValueKey('terminal-more')));
    await settleTerminal(tester);
    await tester.tap(find.text('重命名'));
    await settleTerminal(tester);
    final configuration = tester.testTextInput.setClientArgs!;

    expect(configuration['inputType']['name'], 'TextInputType.text');
    expect(configuration['obscureText'], isFalse);
    expect(configuration['enableSuggestions'], isTrue);
    await tester.enterText(find.byType(TextField), '编译终端');
    await settleTerminal(tester);
    expect(find.text('编译终端'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleTerminal(tester);
  });
}
