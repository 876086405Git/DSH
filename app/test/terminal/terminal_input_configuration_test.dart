import 'package:dsh_app/ui/terminal/terminal_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('a tap on the screen brings the keyboard back on a fresh connection (#1277)', (tester) async {
    final backend = FakeTerminalBackend();
    await pumpTerminalPage(tester, backend);
    final attach = backend.attachOf(backend.created.single['id']! as String);
    tester.testTextInput.log.clear();

    // What a tap on the screen calls (TerminalScreen wires onTapUp to it).
    tester.state<TerminalKeyboardState>(find.byType(TerminalKeyboard)).show();
    await tester.pump();
    expect(
      tester.testTextInput.log.map((call) => call.method),
      containsAllInOrder(['TextInput.setClient', 'TextInput.show']),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '  ls', selection: TextSelection.collapsed(offset: 4)),
    );
    await settleTerminal(tester);
    expect(attach.written, 'ls');
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
