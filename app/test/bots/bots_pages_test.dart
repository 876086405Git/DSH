// Flows of the Bot pages against a scripted DS Bot: the home opens chats,
// a message goes out and comes back, the @ picker writes a member's name,
// the new Bot form and the new group sheet create, memory is edited in place,
// a member's work is stopped.

import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bots_page.dart';
import 'package:dsh_app/ui/bots/drawer_row.dart';
import 'package:dsh_app/ui/bots/new_bot_page.dart';
import 'package:dsh_app/ui/bots/new_room_sheet.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeDsBotTransport> open(WidgetTester tester, Widget page, {FakeDsBotTransport? transport}) async {
    final fake = transport ?? FakeDsBotTransport();
    usePhoneView(tester);
    await tester.pumpWidget(goldenApp(home: page, brightness: Brightness.light, overrides: dsBotOverrides(fake)));
    await frames(tester);
    return fake;
  }

  testWidgets('the home lists the Main Bot first, then the others and the group; a row opens its chat', (tester) async {
    await open(tester, const BotsPage());
    expect(tester.widget<AppPage>(find.byType(AppPage)).title, 'DS Bot');
    expect(find.text('本机 · 3 个 Bot · 1 个群聊'), findsOneWidget);
    final chief = tester.getTopLeft(find.text('Chief'));
    final writer = tester.getTopLeft(find.text('Writer'));
    final room = tester.getTopLeft(find.text('发布会'));
    expect(chief.dy, lessThan(writer.dy));
    expect(writer.dy, lessThan(room.dy));
    expect(find.text('主'), findsOneWidget);
    expect(find.text('正在运行命令'), findsOneWidget);
    expect(find.text('Writer：初稿写好了，放在 docs/launch.md'), findsOneWidget);

    await tester.tap(find.text('发布会'));
    await frames(tester);
    expect(find.byType(RoomChatPage), findsOneWidget);
    expect(find.text('收到，我先列个提纲。'), findsOneWidget);
  });

  testWidgets('Bot and group rows expose a semantic tap action', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, const BotsPage());
    for (final prefix in ['Chief，', '发布会，']) {
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^$prefix')));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
    }
    handle.dispose();
  });

  testWidgets('a message to a Bot shows at once and settles when the chat echoes it', (tester) async {
    final fake = await open(tester, const BotChatPage(botId: 'b2'));
    expect(find.text('Writer 说海报文案今晚能给出。要我先把演示脚本交给 Coder 吗？'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '海报文案今晚给我');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    expect(fake.calls.last.$1, 'send');
    expect(fake.calls.last.$2, {'sessionId': 'b2', 'text': '海报文案今晚给我'});
    expect(find.text('发送中'), findsOneWidget);

    fake.emit('message', {
      'botId': 'b2',
      'sessionId': 'b2-c',
      'item': {'kind': 'user', 'text': '海报文案今晚给我', 'time': DateTime.now().millisecondsSinceEpoch},
    });
    await frames(tester, 3);
    expect(find.text('发送中'), findsNothing);
    expect(find.text('海报文案今晚给我'), findsOneWidget);
  });

  // #1395: a card in a Bot's reply answers like one in a chat, and the answer reads as a tag.
  const card = '''选一个：

```dsh-ui
{"type":"stack","title":"选一个方案","children":[
 {"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}]}
```''';

  testWidgets('a card in a Bot reply answers through the Bot', (tester) async {
    final fake = FakeDsBotTransport()
      ..chatItems = [
        {'id': 'v1', 'kind': 'bot', 'botId': 'b2', 'text': card, 'time': DateTime.now().millisecondsSinceEpoch},
      ];
    await open(tester, const BotChatPage(botId: 'b2'), transport: fake);
    expect(find.byType(DshUiBlock), findsOneWidget);
    await tester.tap(find.text('方案 B'));
    await frames(tester);
    expect(fake.calls.last.$1, 'send');
    final sent = (fake.calls.last.$2 as Map)['text'] as String;
    expect(parseDshUiReply(sent)?.chipLabel, contains('方案 B'));
    expect(find.byType(DshUiReplyChip), findsOneWidget);
    expect(find.textContaining('[dsh-ui reply]'), findsNothing);
  });

  testWidgets('an answer from elsewhere reads as a tag, and the card is done', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final fake = FakeDsBotTransport()
      ..chatItems = [
        {'id': 'v1', 'kind': 'bot', 'botId': 'b2', 'text': card, 'time': now - 2000},
        {'kind': 'user', 'text': '[dsh-ui reply] 选一个方案\n选择：方案 B', 'time': now - 1000},
      ];
    await open(tester, const BotChatPage(botId: 'b2'), transport: fake);
    expect(find.byType(DshUiReplyChip), findsOneWidget);
    expect(find.textContaining('[dsh-ui reply]'), findsNothing);
    final sends = fake.calls.where((c) => c.$1 == 'send').length;
    await tester.tap(find.text('方案 A').first);
    await frames(tester);
    expect(fake.calls.where((c) => c.$1 == 'send').length, sends);
  });

  testWidgets('choosing a model without thinking levels clears the old Bot effort', (tester) async {
    final fake = FakeDsBotTransport();
    fake.handlers['update-bot'] = (_) => true;
    usePhoneView(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const BotDetailsPage(botId: 'm1'),
        brightness: Brightness.light,
        overrides: [
          ...dsBotOverrides(fake),
          modelCatalogProvider.overrideWith(
            (_) async => const ModelCatalog(
              defaultSelection: null,
              groups: [
                ProviderGroup('deepseek', 'DeepSeek', [
                  ModelInfo(provider: 'deepseek', id: 'plain-model', name: 'Plain model'),
                ]),
              ],
              routableProviders: ['deepseek'],
              failures: [],
            ),
          ),
        ],
      ),
    );
    await frames(tester);
    await tester.tap(find.text('模型'));
    await frames(tester);
    await tester.tap(find.text('Plain Model'));
    await frames(tester);
    expect(fake.calls.lastWhere((call) => call.$1 == 'update-bot').$2, {
      'id': 'm1',
      'model': 'deepseek/plain-model',
      'effort': '',
    });
  });

  testWidgets('a question card answers through DS Bot', (tester) async {
    final fake = FakeDsBotTransport(
      team: sampleTeam(
        working: false,
        questions: {
          'm1c': {
            'id': 'q1',
            'question': '演示脚本交给 Coder 吗？',
            'options': [
              {'label': '交给 Coder'},
              {'label': '我自己写'},
            ],
          },
        },
      ),
    );
    fake.handlers['answer-question'] = (_) => true;
    await open(tester, const BotChatPage(botId: 'm1'), transport: fake);
    expect(find.text('等你回答'), findsOneWidget);
    await tester.tap(find.text('交给 Coder'));
    await tester.pump();
    await tester.tap(find.text('发送'));
    await frames(tester, 3);
    final call = fake.calls.lastWhere((c) => c.$1 == 'answer-question');
    expect(call.$2, {
      'sessionId': 'm1c',
      'questionId': 'q1',
      'answer': {
        'selected': ['交给 Coder'],
      },
    });
  });

  testWidgets('in a group, @ lists the members and a pick writes the name', (tester) async {
    final fake = await open(tester, const RoomChatPage(roomId: 'r1'));
    expect(find.text('管理员'), findsWidgets);
    await tester.enterText(find.byType(TextField), '@Co');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('mention-Coder')), findsOneWidget);
    expect(find.byKey(const ValueKey('mention-Writer')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mention-Coder')));
    await tester.pump(const Duration(milliseconds: 300));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '@Coder ');
    expect(find.byKey(const ValueKey('mention-Coder')), findsNothing);

    await tester.enterText(find.byType(TextField), '@Coder 演示环境好了吗');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    expect(fake.calls.last.$2, {'sessionId': 'r1', 'text': '@Coder 演示环境好了吗'});
  });

  testWidgets('the new Bot form asks for a name, then creates and opens the chat', (tester) async {
    final fake = FakeDsBotTransport();
    fake.handlers['create-bot'] = (payload) => {'id': 'b9', 'name': payload['name'], 'sessionId': 'b9'};
    await open(tester, const NewBotPage(), transport: fake);
    await tester.tap(find.byKey(const ValueKey('bot-create')));
    await tester.pump();
    expect(find.text('起个名字'), findsOneWidget);
    expect(fake.endpoints, isNot(contains('create-bot')));

    await tester.enterText(find.byKey(const ValueKey('bot-name')), '设计师');
    await tester.enterText(find.byKey(const ValueKey('bot-role')), '画海报');
    await tester.tap(find.byKey(const ValueKey('color-green')));
    await tester.tap(find.byKey(const ValueKey('bot-create')));
    await frames(tester);
    final call = fake.calls.firstWhere((c) => c.$1 == 'create-bot');
    expect(call.$2, {'name': '设计师', 'role': '画海报', 'color': 'green', 'model': 'deepseek/deepseek-v4-flash'});
    expect(find.byType(BotChatPage), findsOneWidget);
  });

  testWidgets('a new group needs two Bots and opens when made', (tester) async {
    final fake = FakeDsBotTransport();
    fake.handlers['create-room'] = (payload) => {'id': 'r1', 'name': '新群', 'members': payload['members']};
    await open(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () => showNewRoomSheet(context), child: const Text('open')),
          ),
        ),
      ),
      transport: fake,
    );
    await tester.tap(find.text('open'));
    await frames(tester);
    expect(find.text('至少选两个 Bot'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('member-b2')));
    await tester.tap(find.byKey(const ValueKey('member-b3')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('room-create')));
    await frames(tester);
    final call = fake.calls.firstWhere((c) => c.$1 == 'create-room');
    expect(call.$2['members'], ['b2', 'b3']);
    expect(call.$2['greet'], isTrue);
    expect(find.byType(RoomChatPage), findsOneWidget);
  });

  testWidgets('a memory entry is edited in place', (tester) async {
    final fake = await open(tester, const BotDetailsPage(botId: 'm1'));
    await tester.scrollUntilVisible(find.text('发布会定在周五下午三点'), 200);
    await tester.tap(find.text('发布会定在周五下午三点'));
    await frames(tester, 4);
    await tester.tap(find.text('编辑'));
    await frames(tester, 4);
    await tester.enterText(find.byType(TextField).last, '发布会改到周六上午');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await frames(tester, 4);
    final call = fake.calls.lastWhere((c) => c.$1 == 'memory-edit');
    expect(call.$2, {'botId': 'm1', 'scope': 'own', 'topic': null, 'text': '发布会定在周五下午三点', 'next': '发布会改到周六上午'});
  });

  testWidgets('a member at work in a group can be stopped from the group\'s details', (tester) async {
    final team = sampleTeam(working: false);
    final now = DateTime.now().millisecondsSinceEpoch;
    (team['work']! as Map<String, Object?>)['rooms'] = {
      'r1': [
        {'botId': 'b3', 'since': now - 20000, 'tool': 'bash'},
      ],
    };
    final fake = FakeDsBotTransport(team: team);
    fake.handlers['stop-member-work'] = (_) => true;
    // Every read answers the whole team, so the work stays listed.
    fake.handlers['state'] = (_) => team;
    await open(tester, const RoomDetailsPage(roomId: 'r1'), transport: fake);
    expect(find.text('正在运行命令'), findsOneWidget);
    await tester.tap(find.text('停下'));
    await frames(tester, 3);
    expect(fake.calls.lastWhere((c) => c.$1 == 'stop-member-work').$2, {'roomId': 'r1', 'botId': 'b3'});
  });

  testWidgets('a host without DS Bot offers to install it', (tester) async {
    final fake = FakeDsBotTransport();
    fake.handlers['hello'] = (_) => throw const DshHttpException(404, 'missing');
    await open(tester, const BotsPage(), transport: fake);
    expect(find.text('安装 DS Bot'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装'), findsOneWidget);
  });

  testWidgets('the drawer folds the team into one 「DS Bot」 row that opens the Bots home', (tester) async {
    await open(tester, const Scaffold(body: Column(children: [DsBotDrawerRow()])));
    expect(find.byKey(const ValueKey('dsbot-drawer-row')), findsOneWidget);
    expect(find.textContaining('3 个 Bot'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dsbot-drawer-row')));
    await frames(tester, 4);
    expect(find.byType(BotsPage), findsOneWidget);
    expect(tester.widget<AppPage>(find.byType(AppPage)).title, 'DS Bot');
  });

  testWidgets('without DS Bot the drawer row draws nothing', (tester) async {
    final fake = FakeDsBotTransport();
    fake.handlers['hello'] = (_) => throw const DshHttpException(404, 'missing');
    await open(
      tester,
      const Scaffold(body: Column(children: [DsBotDrawerRow()])),
      transport: fake,
    );
    expect(find.byKey(const ValueKey('dsbot-drawer-row')), findsNothing);
  });
}
