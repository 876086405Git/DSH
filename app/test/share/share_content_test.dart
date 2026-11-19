// What goes on a share card: masking, images, code segments, the question
// and stats from the conversation, keeping long replies whole.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('shareMarkdown', () {
    test('masks keys with • (Markdown leaves it alone) and keeps the prefix', () {
      final out = shareMarkdown('用 `sk-abcdef1234567890abcdef` 调用，别外传。');
      expect(out, contains('sk-abcde'));
      expect(out, isNot(contains('1234567890')));
      expect(out, isNot(contains('*')));
    });

    test('images become their alt text; code fences are untouched', () {
      final out = shareMarkdown('看图：![流程图](/root/a.png)\n\n![](x.png)\n\n```md\n![keep](me.png)\n```');
      expect(out, startsWith('看图：〔流程图〕'));
      expect(out, contains('![keep](me.png)'));
      expect(out, isNot(contains('x.png')));
    });

    test('with pictures: kept as written, never masked, their alt text dropped', () {
      const data = 'data:image/png;base64,c2stYWJjZGVmMTIzNDU2Nzg5MGFiY2RlZg==';
      final out = shareMarkdown(
        '图：![草图 sk-abcdef1234567890abcdef](chart.png "标题")\n\n![]($data)\n\n'
        '密钥 sk-abcdef1234567890abcdef 别外传\n\n[![徽章](https://x.dev/b.png)](https://x.dev)',
        images: true,
      );
      expect(out, contains('![](chart.png)'));
      expect(out, contains('![]($data)'), reason: 'a data: payload is not taken for a key');
      expect(out, contains('![](https://x.dev/b.png)'));
      expect(out, isNot(contains('草图')));
      expect(out, isNot(contains('1234567890abcdef 别外传')));
    });

    test('a visual reply shares its one-line summary, not its JSON', () {
      const reply = '结果如下：\n\n```dsh-ui\n{"type":"chart","title":"销量","data":[1,2,3]}\n```';
      expect(shareMarkdown(reply), isNot(contains('"type"')));
    });
  });

  test('segments: text runs and top-level code blocks', () {
    final segments = shareSegments('一段话。\n\n```dart\nvoid main() {}\n```\n\n- 列表\n- 两项\n\n~~~\nplain\n~~~');
    expect(
      [for (final s in segments) (s.code, s.language)],
      [(false, null), (true, 'dart'), (false, null), (true, null)],
    );
    expect(segments[1].text, 'void main() {}');
    expect(segments[2].text, '- 列表\n- 两项');
  });

  group('pictures in a reply', () {
    test('follow their passage; pictures with no text between share a gallery', () {
      final segments = shareSegments(
        '先看效果：\n\n![](a.png)\n\n![](b.png)\n![](c.png)\n\n'
        '对比一下，左边 ![](d.png) 是原图。\n\n```md\n![](kept.png)\n```\n\n- ![](e.png)\n- 最后一条',
      );
      expect(
        [for (final s in segments) s.isImages ? s.images : (s.code ? 'code' : s.text)],
        [
          '先看效果：',
          ['a.png', 'b.png', 'c.png'],
          '对比一下，左边  是原图。',
          ['d.png'],
          'code',
          '- 最后一条',
          ['e.png'],
        ],
      );
      expect(segments[4].text, '![](kept.png)', reason: 'code is left alone');
    });

    test('an address with parentheses is read whole', () {
      final segments = shareSegments('![](https://x.dev/a_(1).png)');
      expect(segments.single.images, ['https://x.dev/a_(1).png']);
    });
  });

  group('long share content', () {
    test('all list items survive preparation', () {
      final text = longAnswer();
      expect(shareMarkdown(text), text);
      final segments = shareSegments(shareMarkdown(text));
      expect(segments.single.text, text);
      expect(segments.single.text, contains('第 24 步'));
    });

    test('a huge paragraph retains its last sentence without an ellipsis', () {
      final text = List.filled(120, '这是一句很长的说明，用来把卡片撑满。').join();
      expect(shareSegments(shareMarkdown(text)).single.text, text);
    });

    test('a long code block retains every line', () {
      final body = [for (var i = 0; i < 200; i++) 'print($i)'].join('\n');
      final code = '```python\n$body\n```';
      final segment = shareSegments(shareMarkdown(code)).single;
      expect(segment.code, isTrue);
      expect(segment.text, body);
      expect(segment.language, 'python');
    });
  });

  group('from the conversation', () {
    test('a reply brings its question, title, model and turn stats', () {
      final state = shareChatState();
      final content = shareContentForReply(state, firstReply(state), sessionId: 's1');
      expect(content.title, sampleTitle);
      expect((content.blocks.first as ShareQuestion).text, sampleQuestion);
      expect(content.model, 'deepseek-v4-pro');
      expect(content.stats, '53 秒 · 8 步');
      expect(content.metaPills, ['deepseek-v4-pro', '53 秒', '8 步']);
      expect(content.sessionId, 's1');
    });

    test('what the turn did: tools counted by kind, most first, bookkeeping left out', () {
      final state = shareChatState();
      final content = shareContentForReply(state, firstReply(state));
      expect(content.process.map((p) => '$p'), ['查看文件 4', '修改文件 2', '运行命令 1']);
      expect(content.process.first.tool, 'read');
    });

    test('a prompt\'s pictures come along, and a pictures-only prompt counts', () {
      final state = shareChatState();
      final items = [
        UserChatItem(
          seq: 20,
          time: DateTime(2026),
          text: '',
          images: const [ImageAttachment(attachmentId: 'img1', mediaType: 'image/png', width: 800, height: 600)],
          files: const [],
        ),
        const AssistantChatItem(id: 'a21', seq: 21, text: '是一只猫。\n\n![](cat_box.png)', reasoning: ''),
      ];
      final chat = ChatState(items: [...state.items, ...items], title: sampleTitle, loading: false);
      expect(shareableItems(chat.items).map((i) => i.key), contains('u20'));
      final content = shareContentForReply(chat, items.last as AssistantChatItem);
      final question = content.blocks.first as ShareQuestion;
      expect(question.text, isEmpty);
      expect((question.images.single as ShareAttachmentImage).attachmentId, 'img1');
      expect(question.images.single.aspect, closeTo(4 / 3, 1e-9));
      expect((content.blocks.last as ShareAnswer).markdown, contains('![](cat_box.png)'));
    });

    test('time and steps add up over several turns, only when every reply has one', () {
      final t0 = DateTime(2026);
      TurnTrace turn(int n, int seconds, int steps) => TurnTrace(
        turn: n,
        startSeq: n * 10,
        start: t0,
        end: t0.add(Duration(seconds: seconds)),
        endSeq: n * 10 + 9,
        spans: [
          for (var i = 0; i < steps; i++)
            TraceSpan(kind: TraceKind.model, step: i + 1, seq: n * 10 + i, start: t0, end: t0),
        ],
      );
      final first = turn(1, 50, 3);
      // Two replies of the first turn count it once.
      expect(shareStatsOf([first, turn(2, 40, 5), first]), '1 分 30 秒 · 8 步');
      expect(shareStatsOf([first, null]), isNull);
    });

    test('visual-reply answers are not taken for the question', () {
      final state = shareChatState();
      final items = [
        ...state.items.take(2),
        UserChatItem(seq: 11, time: DateTime(2026), text: '[dsh-ui reply] 计划\n确认', images: const [], files: const []),
        const AssistantChatItem(id: 'a12', seq: 12, text: '好的。', reasoning: ''),
      ];
      expect(questionFor(items, items.last)?.text, sampleQuestion);
    });

    test('picked messages keep their order; secrets in prompts are masked', () {
      final state = shareChatState();
      final keys = {for (final item in state.items) item.key};
      final content = shareContentForItems(state, keys);
      expect(content.blocks.map((b) => b.runtimeType), [ShareQuestion, ShareAnswer, ShareQuestion, ShareAnswer]);
      expect((content.blocks[2] as ShareQuestion).text, isNot(contains('1234567890abcdef')));
    });

    test('privacy: no pictures, no work; home folders go as on a shared file', () {
      final state = shareChatState();
      final items = [
        UserChatItem(
          seq: 20,
          time: DateTime(2026),
          text: '看看 /home/alice/app 里的截图',
          images: const [ImageAttachment(attachmentId: 'img1', mediaType: 'image/png', width: 800, height: 600)],
          files: const [],
        ),
        const AssistantChatItem(id: 'a21', seq: 21, text: '图里是 /Users/alice/x：\n\n![走势](chart.png)', reasoning: ''),
      ];
      final chat = ChatState(items: [...state.items, ...items], title: sampleTitle, loading: false, turns: state.turns);
      final full = shareContentForReply(chat, items.last as AssistantChatItem);
      expect((full.blocks.first as ShareQuestion).text, '看看 ~/app 里的截图');
      expect((full.blocks.last as ShareAnswer).markdown, startsWith('图里是 ~/x'));
      expect((full.blocks.last as ShareAnswer).markdown, contains('![](chart.png)'));

      final bare = shareContentForReply(chat, items.last as AssistantChatItem, images: false);
      expect((bare.blocks.first as ShareQuestion).images, isEmpty);
      expect((bare.blocks.last as ShareAnswer).markdown, contains('〔走势〕'));
      expect((bare.blocks.last as ShareAnswer).markdown, isNot(contains('chart.png')));

      final reply = firstReply(state);
      expect(shareContentForReply(state, reply).process, isNotEmpty);
      expect(shareContentForReply(state, reply, tools: false).process, isEmpty);
      final keys = {for (final item in state.items) item.key};
      expect(shareContentForItems(state, keys, tools: false).process, isEmpty);
      expect(shareContentForItems(state, keys, images: false).blocks, hasLength(4));
    });
  });
}
