// A reply's long-press menu with plugins: one group per plugin under its
// name, after the menu's own; a tap goes to the plugin with the reply's id
// (and its text, only after the one-time 「要读取这条回复」).

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/plugins/native/native_composer_bar.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _reply = AssistantChatItem(id: 'a18', seq: 18, text: '这是**回复**正文。', reasoning: '');

Future<FakeComposer> pumpReply(WidgetTester tester, FakeBridge bridge, {bool inChat = true}) async {
  usePhoneView(tester);
  final composer = FakeComposer();
  const body = SingleChildScrollView(
    padding: EdgeInsets.all(16),
    child: AssistantMessage(item: _reply, showActions: true),
  );
  // As on the chat screen, the bar above the composer keeps the plugins read.
  final chat = Column(
    children: [
      Expanded(child: body),
      const NativeComposerBar(sessionId: 's1', visible: true),
    ],
  );
  await tester.pumpWidget(
    testApp(
      Scaffold(body: SafeArea(child: inChat ? withComposer(composer, chat) : body)),
      overrides: [
        ...nativeOverrides(bridge),
        chatProvider.overrideWith2(
          (id) => FakeChatController(id, const ChatState(loading: false))..replyIds[18] = 'm18',
        ),
      ],
    ),
  );
  await pumpFrames(tester);
  return composer;
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.longPress(find.textContaining('正文'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('each plugin is a group under its name, after the menu\'s own cards', (tester) async {
    final bridge = FakeBridge(
      contributions([
        quickPlugin(),
        plugin(
          'reader',
          title: '朗读助手',
          menu: [
            {'id': 'read', 'label': '朗读'},
          ],
        ),
      ]),
    );
    await pumpReply(tester, bridge);
    await openMenu(tester);
    final groups = tester.widgetList<SheetGroup>(find.byType(SheetGroup)).toList();
    expect(groups.map((g) => g.title), [null, '快捷指令', '朗读助手']);
    // The app's own 朗读 and each plugin's.
    expect(find.text('朗读'), findsNWidgets(3));
    expect(find.text('要点'), findsOneWidget);
    // The plugin groups come after 复制.
    expect(tester.getTopLeft(find.text('要点')).dy, greaterThan(tester.getTopLeft(find.text('复制')).dy));
  });

  testWidgets('a tap sends the reply id; the plugin answer runs in the chat', (tester) async {
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'effects': [
          {'type': 'insert', 'text': '要点：一、二、三'},
        ],
      });
    final composer = await pumpReply(tester, bridge);
    await openMenu(tester);
    await tester.tap(find.text('要点'));
    await tester.pumpAndSettle();
    final call = bridge.invocations.single;
    expect((call.pkg, call.id, call.surface), ('dsh-go-example-quick', 'summary', 'message.actions'));
    expect(call.scope, const DshGoScope(sessionId: 's1', messageId: 'm18'));
    expect(call.message, isNull, reason: 'the text only for a plugin that wants it');
    expect(composer.inserted, ['要点：一、二、三']);
  });

  testWidgets('wants: message — asks once, then sends the reply text', (tester) async {
    final bridge = FakeBridge(
      contributions([
        plugin(
          'reader',
          title: '朗读助手',
          wants: ['message'],
          menu: [
            {'id': 'read', 'label': '朗读'},
          ],
        ),
      ]),
    );
    await pumpReply(tester, bridge);
    await openMenu(tester);
    // The plugin's, under its name (after the app's own 朗读).
    await tester.tap(find.text('朗读').last);
    await tester.pumpAndSettle();
    expect(find.text('「朗读助手」要读取这条回复'), findsOneWidget);
    await tester.tap(find.text('允许'));
    await tester.pumpAndSettle();
    expect(bridge.invocations.single.message, '这是**回复**正文。');

    await openMenu(tester);
    // The plugin's, under its name (after the app's own 朗读).
    await tester.tap(find.text('朗读').last);
    await tester.pumpAndSettle();
    expect(find.text('「朗读助手」要读取这条回复'), findsNothing);
    expect(bridge.invocations, hasLength(2));
  });

  testWidgets('outside the chat (no composer lent) or without plugins: the menu is as before', (tester) async {
    await pumpReply(tester, FakeBridge(contributions([quickPlugin()])), inChat: false);
    await openMenu(tester);
    expect(find.text('要点'), findsNothing);
    expect(tester.widgetList<SheetGroup>(find.byType(SheetGroup)).map((g) => g.title), [null]);
  });
}
