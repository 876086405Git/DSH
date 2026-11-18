// A long or streamed reply is drawn in blocks (#1469): new text re-renders
// only the last block, and the blocks lay out exactly as one GptMarkdown.

import 'package:dsh_app/ui/chat/render/markdown_blocks.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_split.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'support/harness.dart';
import 'support/markdown_samples.dart';

final _html = GptMarkdownConfig(
  htmlTags: {'details': const HtmlTag.block(MarkdownDisclosure.build), 'summary': const HtmlTag.block()},
).markdownHtml;

MarkdownBlockSplit _split([int minLength = 0]) => MarkdownBlockSplit(html: _html, minLength: minLength);

final _paragraphs = [for (var i = 0; i < 12; i++) '第 $i 段：${'正文写长一点，' * 4}结束。'];

/// Every construct the samples have, with prose between them.
final _reply = [
  headingsReply,
  _paragraphs[0],
  listsReply,
  _paragraphs[1],
  mathReply,
  _paragraphs[2],
  codeReply,
  _paragraphs[3],
  tableReply,
  _paragraphs[4],
  quotesReply,
  _paragraphs[5],
  '- 松散列表一\n\n- 松散列表二\n\n  缩进的续行\n\n- 松散列表三',
  _paragraphs[6],
].join('\n\n');

void main() {
  group('MarkdownBlockSplit', () {
    test('a text shorter than a block is one block, the text itself', () {
      const text = '一段。\n\n两段。';
      final blocks = _split(100).update(text);
      expect(blocks, hasLength(1));
      expect(identical(blocks.single, text), isTrue);
    });

    test('cuts between paragraphs once a block is long enough', () {
      final text = _paragraphs.join('\n\n');
      final blocks = _split(60).update(text);
      expect(blocks.length, greaterThan(2));
      expect(blocks.join(), text);
      for (final block in blocks.take(blocks.length - 1)) {
        expect(block.length, greaterThanOrEqualTo(60));
        expect(block, endsWith('\n\n'));
      }
    });

    test('keeps lists, fences, tables, quotes, maths and details whole', () {
      const text =
          'Intro.\n\n'
          '1. one\n\n2. two\n\n   more of two\n\n- three\n\n'
          'Middle.\n\n'
          '```dart\nvoid a() {}\n\nvoid b() {}\n```\n\n'
          'After code.\n\n'
          '| a | b |\n|---|---|\n| 1 | 2 |\n\n'
          'After table.\n\n'
          '> quoted\n\n'
          'After quote.\n\n'
          '\$\$\nx\n\ny\n\$\$\n\n'
          'After maths.\n\n'
          '<details>\n<summary>More</summary>\n\nInside.\n\n</details>\n\n'
          'End.';
      final blocks = _split().update(text);
      expect(blocks.join(), text);
      expect(blocks.take(4), [
        'Intro.\n\n',
        '1. one\n\n2. two\n\n   more of two\n\n- three\n\n',
        'Middle.\n\n',
        '```dart\nvoid a() {}\n\nvoid b() {}\n```\n\n',
      ]);
      // A table, a quote, maths and HTML draw to their edges: no cut next to
      // any of them, so the rest is one block.
      expect(blocks, hasLength(5));
      expect(blocks.last, startsWith('After code.'));
    });

    test('no cut next to a dsh-ui view or an image', () {
      const text = 'Before.\n\n```dsh-ui\n{"type":"card"}\n```\n\nBetween.\n\n![pic](a.png)\n\nAfter.';
      expect(_split().update(text), [text]);
    });

    test('a reply with link or footnote definitions stays whole', () {
      final text = 'See [the docs][d] and a note[^1].\n\n${_paragraphs.join('\n\n')}\n\n[d]: https://example.com';
      expect(_split().update(text), [text]);
      expect(_split().update(miscReply), [miscReply]);
    });

    test('a streamed reply splits as a fresh split would, keeping earlier blocks as they were', () {
      for (final text in [_reply, '$_reply\n\n$miscReply']) {
        final streamed = _split(80);
        List<String>? previous;
        for (var end = 1; end <= text.length; end++) {
          final prefix = text.substring(0, end);
          final blocks = streamed.update(prefix);
          expect(blocks, _split(80).update(prefix), reason: 'after $end');
          final before = previous;
          if (before != null && blocks.length >= before.length) {
            for (var i = 0; i < before.length - 2; i++) {
              expect(identical(blocks[i], before[i]), isTrue, reason: 'block $i after $end');
            }
          }
          previous = blocks;
        }
      }
    });
  });

  group('MarkdownBody in blocks', () {
    late int blockLength;
    setUp(() => blockLength = MarkdownBody.blockLength);
    tearDown(() => MarkdownBody.blockLength = blockLength);

    Widget host(ValueNotifier<String> text, {bool reveal = false}) => testApp(
      Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (_, value, _) => MarkdownBody(text: value, streaming: true, reveal: reveal, selectable: false),
          ),
        ),
      ),
    );

    List<GptMarkdown> markdowns(WidgetTester tester) =>
        tester.widgetList<GptMarkdown>(find.byType(GptMarkdown)).toList();

    testWidgets('new text rebuilds only the last block', (tester) async {
      usePhoneView(tester);
      MarkdownBody.blockLength = 80;
      final text = ValueNotifier(_paragraphs.join('\n\n'));
      addTearDown(text.dispose);
      await tester.pumpWidget(host(text));
      final before = markdowns(tester);
      expect(before.length, greaterThan(2));

      var builds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is GptMarkdown) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var token = 0; token < 10; token++) {
        text.value = '${text.value}再加几个字';
        await tester.pump(const Duration(milliseconds: 32));
      }
      debugOnRebuildDirtyWidget = previous;

      final after = markdowns(tester);
      expect(after, hasLength(before.length));
      for (var i = 0; i < before.length - 1; i++) {
        expect(identical(after[i], before[i]), isTrue, reason: 'block $i');
      }
      expect(after.last.data, contains('再加几个字'));
      expect(builds, 10, reason: 'one block per update, however long the reply');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the reveal: earlier blocks stay, a new block mounts empty and then fades in', (tester) async {
      usePhoneView(tester);
      MarkdownBody.blockLength = 30;
      final first = _paragraphs[0];
      final text = ValueNotifier(first);
      addTearDown(text.dispose);
      await tester.pumpWidget(host(text, reveal: true));
      await tester.pump(const Duration(seconds: 1));
      expect(markdowns(tester), hasLength(1));

      text.value = '$first\n\n第二段。';
      await tester.pump();
      var blocks = markdowns(tester);
      expect(blocks, hasLength(2));
      expect(blocks.first.isStreaming, isFalse, reason: 'only the last block is still arriving');
      expect(blocks.last.data, isEmpty, reason: 'mounted empty, so its words are revealed');
      await tester.pump();
      blocks = markdowns(tester);
      expect(blocks.last.data, '第二段。');
      expect(blocks.last.isStreaming, isTrue);

      final settled = blocks.first;
      for (var token = 0; token < 5; token++) {
        text.value = '${text.value}又一句。';
        await tester.pump(const Duration(milliseconds: 32));
        expect(identical(markdowns(tester).first, settled), isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('blocks lay out exactly as one GptMarkdown', (tester) async {
      usePhoneView(tester);
      Future<(int, double, List<(String, Rect)>)> layout(int length) async {
        MarkdownBody.blockLength = length;
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: SingleChildScrollView(
                child: MarkdownBody(key: UniqueKey(), text: _reply, selectable: false),
              ),
            ),
          ),
        );
        await pumpFrames(tester, 3);
        expect(tester.takeException(), isNull);
        final paragraphs = [
          for (final paragraph in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
            (
              paragraph.text.toPlainText(),
              MatrixUtils.transformRect(paragraph.getTransformTo(null), Offset.zero & paragraph.size),
            ),
        ];
        final result = (
          find.byType(GptMarkdown).evaluate().length,
          tester.getSize(find.byType(MarkdownBody)).height,
          paragraphs,
        );
        await tester.pumpWidget(const SizedBox());
        return result;
      }

      final (one, height, whole) = await layout(1 << 20);
      final (many, blocksHeight, blocks) = await layout(0);
      expect(one, 1);
      expect(many, greaterThan(3));
      expect(blocksHeight, moreOrLessEquals(height, epsilon: 1e-6));
      expect(blocks.map((p) => p.$1), whole.map((p) => p.$1));
      for (var i = 0; i < whole.length; i++) {
        final (text, rect) = whole[i];
        final other = blocks[i].$2;
        for (final (a, b) in [
          (rect.left, other.left),
          (rect.top, other.top),
          (rect.width, other.width),
          (rect.height, other.height),
        ]) {
          expect(b, moreOrLessEquals(a, epsilon: 1e-6), reason: text);
        }
      }
    });

    testWidgets("an app's own inline patterns keep the text one GptMarkdown", (tester) async {
      usePhoneView(tester);
      MarkdownBody.blockLength = 0;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: MarkdownPatterns(
                patterns: const [],
                child: MarkdownBody(text: _paragraphs.join('\n\n'), selectable: false),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(GptMarkdown), findsOneWidget);
    });
  });
}
