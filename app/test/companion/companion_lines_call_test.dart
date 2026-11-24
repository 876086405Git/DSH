// Her own lines (from a pack), her marks kept out of the main chat, and a
// call in her room ending each turn once.

import 'package:dsh_app/companion/companion_call.dart';
import 'package:dsh_app/companion/companion_lines.dart';
import 'package:dsh_app/companion/companion_reply.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a pack brings lines for known moments only', () {
    final lines = CompanionLines.parse({
      'pat': ['  嘿嘿 ', ''],
      'tapTail': '别碰我的翅膀！',
      'dance': ['不认识的场景'],
    });
    expect(lines['pat'], ['嘿嘿']);
    expect(lines['tapTail'], ['别碰我的翅膀！']);
    expect(lines['dance'], isNull);
    expect(CompanionLines.parse(null).isEmpty, isTrue);
  });

  test('her marks come out of the words, half- and full-width', () {
    const text = '【表情：歪头】嗯？[动作:点头] 好呀。';
    expect(companionHasMarks(text), isTrue);
    expect(companionWithoutMarks(text), '嗯？好呀。');
    expect(companionHasMarks('普通的话'), isFalse);
    // While she is still talking, a mark half arrived stays out of sight.
    expect(companionWithoutMarks('好呀。[表情:开', streaming: true), '好呀。');
    expect(companionWithoutMarks('好呀。[表情:开'), '好呀。[表情:开');
  });

  test('a call hears each reply once and ends the turn when she stops', () async {
    final sent = <String>[];
    final call = CompanionCallConversation((text) async {
      sent.add(text);
      return true;
    }, () async {});
    final replies = <CallReplyView>[];
    final sub = call.replies.listen((r) => replies.add((r.text, r.done)));
    call.reply('早', running: true);
    expect(await call.send('你好'), isTrue);
    call.reply('你', running: true);
    call.reply('你好呀', running: false);
    call.reply('你好呀', running: false);
    await Future<void>.delayed(Duration.zero);
    expect(sent, ['你好']);
    expect(replies, [('你', false), ('你好呀', false), ('你好呀', true)]);
    await sub.cancel();
    call.dispose();
  });
}

typedef CallReplyView = (String, bool);
