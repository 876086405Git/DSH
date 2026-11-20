// The app's notes to the model (a call's instructions, a persona sent inline)
// go out with the message and are never shown as what the person said.

import 'package:dsh_app/state/app_notes.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

final _sent = '${appNote('（这是语音通话，请口语化回答。）')}\n${appNote('（你说到「好的」时我打断了你。）')}\n周末去哪儿玩';

void main() {
  setUpAll(loadTestFonts);

  test('what is shown is what the person said; the model gets the notes too', () {
    expect(_sent, contains('（这是语音通话，请口语化回答。）'));
    expect(withoutAppNotes(_sent), '周末去哪儿玩');
    expect(withoutAppNotes('${appNote('设定第一行\n第二行')}\n你好'), '你好');
    expect(withoutAppNotes('没有提示的话'), '没有提示的话');
  });

  test('a closing tag inside a note does not end it early', () {
    const persona = '她说话时爱写 </dsh-note> 这种怪东西';
    final sent = '${appNote(persona)}\n你好';
    expect(withoutAppNotes(sent), '你好');
    expect(sent, contains(r'<\/dsh-note>'));
  });

  test('an edited resend keeps the notes it began with', () {
    expect(
      withAppNotesOf(_sent, '周末去哪儿玩比较好'),
      '${appNote('（这是语音通话，请口语化回答。）')}\n${appNote('（你说到「好的」时我打断了你。）')}\n周末去哪儿玩比较好',
    );
    expect(withAppNotesOf('只是话', '改过的话'), '改过的话');
  });

  testWidgets('the bubble and 编辑后重发 show only what was said', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(
          items: [
            UserChatItem(seq: 1, time: DateTime(2026, 11, 14, 9), text: _sent, images: const [], files: const []),
            AssistantChatItem(id: 'a2', seq: 2, time: DateTime(2026, 11, 14, 9), text: '去郊外走走吧。', reasoning: ''),
          ],
          title: '周末',
          loading: false,
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final chat = harness.controllers['s1']!;
    chat.branchPoints[2] = 7;
    chat.emit(chat.state.copyWith());
    await pumpFrames(tester);

    expect(find.text('周末去哪儿玩'), findsOneWidget);
    expect(find.textContaining('语音通话'), findsNothing);

    await tester.longPress(find.text('周末去哪儿玩'));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(SettingsTile, '编辑后重发'));
    await pumpFrames(tester);
    final field = tester.widget<TextField>(
      find.descendant(of: find.byType(Composer), matching: find.byType(TextField)),
    );
    expect(field.controller!.text, '周末去哪儿玩');
  });
}
