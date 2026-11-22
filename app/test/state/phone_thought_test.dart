import 'package:dsh_app/state/phone_thought.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

UserChatItem _user(String text, int seq) =>
    UserChatItem(seq: seq, time: DateTime(2026), text: text, images: const [], files: const []);

AssistantChatItem _say(String text, {String reasoning = '', String id = 'a1'}) =>
    AssistantChatItem(id: id, text: text, reasoning: reasoning);

ToolChatItem _tool(String name) =>
    ToolChatItem(callId: name, name: name, arguments: '{}', status: ToolStatus.succeeded);

void main() {
  group('phoneThoughtOf — what the island card says DSH thinks', () {
    test('the newest reply in this turn, its last paragraph, on one line', () {
      final items = [
        _user('给张三发明天见', 1),
        _say('好的，我来操作微信。', id: 'a1'),
        _tool('phone_open'),
        _say('找到了和张三的对话。\n\n现在输入**明天见**，\n然后点发送。', id: 'a2'),
        _tool('phone_tap'),
      ];
      expect(phoneThoughtOf(items), '现在输入明天见， 然后点发送。');
    });

    test("an older turn's words don't count once the person spoke again", () {
      final items = [_user('第一件', 1), _say('做完了'), _user('再看一下设置', 2), _tool('phone_screen')];
      expect(phoneThoughtOf(items), isNull);
    });

    test('reasoning stands in while the reply is still empty', () {
      final items = [
        _user('打开设置', 1),
        _say('', reasoning: 'The user wants Settings.\n\nI should open the Settings app first.'),
      ];
      expect(phoneThoughtOf(items), 'I should open the Settings app first.');
    });

    test('Markdown marks, list markers and links go; code blocks say nothing', () {
      expect(phoneThoughtOf([_user('x', 1), _say('- 点 [发送](https://x) 按钮 `ok`')]), '点 发送 按钮 ok');
      expect(phoneThoughtOf([_user('x', 1), _say('先看一下\n\n```\nadb shell\n```')]), isNull);
    });

    test('a long paragraph keeps its end, where the newest words are', () {
      final long = '甲' * 700 + '乙';
      final thought = phoneThoughtOf([_user('x', 1), _say(long)])!;
      expect(thought.length, maxPhoneThought);
      expect(thought.endsWith('乙'), isTrue);
    });
  });
}
