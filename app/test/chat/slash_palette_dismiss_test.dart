import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/slash_palette.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  final composerInput = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));

  Future<ChatHarness> mount(
    WidgetTester tester, {
    bool running = false,
    List<UserQuestionRequest> questions = const [],
  }) async {
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': ChatState(loading: false, running: running, questions: questions)},
    );
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 8);
    return harness;
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(composerInput, text);
    await pumpFrames(tester, 3);
  }

  TextEditingController input(WidgetTester tester) => tester.widget<TextField>(composerInput).controller!;

  testWidgets('ordinary typing and selection leave the closed palette idle', (tester) async {
    await mount(tester);
    await enter(tester, '/');
    final slot = tester.element(find.byType(SlashPalette)).findAncestorWidgetOfExactType<LayoutId>()!.id;
    await enter(tester, '字' * 2048);
    final controller = input(tester);
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.findAncestorWidgetOfExactType<LayoutId>()?.id == slot) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    final counts = <int>[];
    for (final typing in [true, false]) {
      builds = 0;
      for (var i = 0; i < 20; i++) {
        final text = typing ? '${controller.text}字' : controller.text;
        final value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: typing ? text.length : text.length - i - 1),
        );
        tester.testTextInput.updateEditingValue(value);
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.value, value);
      }
      counts.add(builds);
    }
    expect(counts, [0, 0], reason: 'closed palette builds for 20 keystrokes and 20 caret moves');

    // A slash draft still reaches the palette.
    builds = 0;
    await enter(tester, '/');
    expect(builds, greaterThan(0));
    expect(find.byType(SlashPalette), findsOneWidget);
  });

  testWidgets('picking an input command closes its hint and preserves explicit sending', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/per');
    await tester.tap(find.descendant(of: find.byType(SlashPalette), matching: find.textContaining('/permission')));
    await pumpFrames(tester, 3);
    expect(input(tester).text, '/permission ');
    expect(find.byType(SlashPalette), findsNothing);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);

    await enter(tester, '/permission read-only');
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 3);
    expect(harness.controllers['s1']!.commandLines, ['/permission read-only']);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('an outside touch closes the palette until a new slash is entered', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/permission ');
    expect(find.byType(SlashPalette), findsOneWidget);
    await tester.tapAt(const Offset(195, 350));
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    expect(input(tester).text, '/permission ');
    await enter(tester, '/permission \t');
    expect(find.byType(SlashPalette), findsNothing);
    await enter(tester, '');
    await enter(tester, '/permission ');
    expect(find.byType(SlashPalette), findsOneWidget);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('touching the input is inside its palette group', (tester) async {
    await mount(tester);
    await enter(tester, '/permission ');
    await tester.tap(find.byType(TextField));
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsOneWidget);
  });

  testWidgets('a pending question answer is outside the composer palette group', (tester) async {
    final harness = await mount(
      tester,
      questions: const [
        UserQuestionRequest(
          eventId: 'question-1',
          sessionId: 's1',
          questions: [UserQuestion(id: 'answer', question: 'Which option should we use?')],
        ),
      ],
    );
    final answer = find.descendant(of: find.byType(QuestionCard), matching: find.byType(TextField));
    expect(answer, findsOneWidget);
    await enter(tester, '/permission ');
    expect(find.byType(SlashPalette), findsOneWidget);
    await tester.tap(answer);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    expect(input(tester).text, '/permission ');
    final editor = tester.widget<EditableText>(find.descendant(of: answer, matching: find.byType(EditableText)));
    expect(editor.focusNode.hasFocus, isTrue);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('keyboard dismissal closes a hint without deleting the focused draft', (tester) async {
    await mount(tester);
    await enter(tester, '/permission ');
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsOneWidget);
    tester.view.viewInsets = const FakeViewPadding();
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    expect(input(tester).text, '/permission ');
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
  });

  testWidgets('a covered chat keeps its palette when the new route changes keyboard metrics', (tester) async {
    await mount(tester);
    await enter(tester, '/permission ');
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await pumpFrames(tester, 3);
    final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
    final covered = navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Covered route'))),
    );
    // The route changes synchronously; ChatScreen has not rebuilt its cached
    // route state before the covering page's keyboard notification arrives.
    tester.view.viewInsets = const FakeViewPadding();
    await pumpFrames(tester, 6);
    navigator.pop();
    await covered;
    await pumpFrames(tester, 6);
    expect(find.byType(SlashPalette), findsOneWidget);
    expect(input(tester).text, '/permission ');
  });

  testWidgets('Back dismisses a palette while retaining the page and draft', (tester) async {
    await mount(tester);
    await enter(tester, '/permission ');
    await tester.binding.handlePopRoute();
    await pumpFrames(tester, 3);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(SlashPalette), findsNothing);
    expect(input(tester).text, '/permission ');
  });

  testWidgets('Escape closes a palette without stopping a running turn', (tester) async {
    final harness = await mount(tester, running: true);
    await enter(tester, '/permission ');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    expect(input(tester).text, '/permission ');
    expect(harness.controllers['s1']!.cancels, 0);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('Escape while composing stays with the IME', (tester) async {
    final harness = await mount(tester, running: true);
    await enter(tester, '/permission ');
    input(tester).value = const TextEditingValue(
      text: '/permission ',
      selection: TextSelection.collapsed(offset: 12),
      composing: TextRange(start: 1, end: 11),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsOneWidget);
    expect(harness.controllers['s1']!.cancels, 0);
  });

  testWidgets('typing a new slash over a selected dismissed draft reopens the palette', (tester) async {
    final harness = await mount(tester);
    await enter(tester, '/permission ');
    expect(find.byType(SlashPalette), findsOneWidget);
    await tester.tapAt(const Offset(195, 350));
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    final controller = input(tester);
    expect(controller.text, '/permission ');

    await tester.tap(composerInput);
    await pumpFrames(tester, 3);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: controller.text,
        selection: TextSelection(baseOffset: 0, extentOffset: controller.text.length),
      ),
    );
    await tester.pump();
    expect(find.byType(SlashPalette), findsNothing);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '/', selection: TextSelection.collapsed(offset: 1)),
    );
    await pumpFrames(tester, 3);
    expect(controller.text, '/');
    expect(find.byType(SlashPalette), findsOneWidget);

    // Dismissing this new slash still survives caret and whitespace edits.
    await tester.tapAt(const Offset(195, 350));
    await pumpFrames(tester, 3);
    expect(find.byType(SlashPalette), findsNothing);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(find.byType(SlashPalette), findsNothing);
    await enter(tester, '/ \t');
    expect(find.byType(SlashPalette), findsNothing);
    expect(harness.controllers['s1']!.commandLines, isEmpty);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });
}
