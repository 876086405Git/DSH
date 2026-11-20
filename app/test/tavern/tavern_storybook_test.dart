import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_storybook.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_files.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_storybook_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

final _t = DateTime(2026, 11, 9, 22);

TavernMessage _m(TavernRole role, String text, {String speaker = '林晚', bool hidden = false, int day = 0}) =>
    TavernMessage(
      nodeId: 'n${text.hashCode}',
      role: role,
      speaker: speaker,
      text: text,
      at: _t.add(Duration(days: day)),
      hidden: hidden,
    );

const _words = TavernBookWords(language: 'zh-CN', contents: '目录', chapter: _chapter, madeWith: '用 DSH Go 酒馆写成');
String _chapter(int n) => '第 $n 章';

final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);

void main() {
  group('the story', () {
    test('is the path as it reads: no hidden, system or empty lines; yours under your name', () {
      final story = TavernStory.of(
        [
          _m(TavernRole.character, '「炉子还热着。」'),
          _m(TavernRole.system, '（系统）'),
          _m(TavernRole.user, '外面怎么了？', speaker: 'You'),
          _m(TavernRole.character, '不该看的', hidden: true),
          _m(TavernRole.character, '   '),
          _m(TavernRole.character, '「地下室。」', day: 1),
        ],
        title: '雨夜',
        byline: '林晚 和 阿青',
        you: '阿青',
      );
      expect(story.lines.map((l) => l.speaker), ['林晚', '阿青', '林晚']);
      expect(story.lines[1].you, isTrue);
      expect(story.dates, '2026-11-09 – 2026-11-10');
    });

    test('reads without a card frontend\'s markup, blank lines dropped', () {
      expect(tavernStoryParagraphs('*推开门*\n\n<div class="status">HP 10</div>\n「进来吧。」'), ['*推开门*', 'HP 10', '「进来吧。」']);
    });

    test('becomes XHTML with actions in italics and everything else escaped', () {
      expect(tavernStoryXhtml('*她笑了* 「a < b & **c**」'), '<em>她笑了</em> 「a &lt; b &amp; <strong>c</strong>」');
    });

    test('as plain text: the title, who and when, each line under its speaker', () {
      final story = TavernStory.of(
        [_m(TavernRole.character, '「炉子还热着。」'), _m(TavernRole.user, '外面怎么了？')],
        title: '雨夜',
        byline: '林晚 和 你',
        you: '你',
      );
      expect(
        buildTavernStoryText(story, madeWith: '用 DSH Go 酒馆写成'),
        '雨夜\n\n林晚 和 你 · 2026-11-09\n\n林晚：\n「炉子还热着。」\n\n你：\n外面怎么了？\n\n—— 用 DSH Go 酒馆写成\n',
      );
    });
  });

  group('the EPUB', () {
    Archive book(TavernStory story) =>
        ZipDecoder().decodeBytes(buildTavernEpub(story, _words, id: 'b1d2', modified: DateTime.utc(2026, 11, 10)));
    String text(Archive a, String name) => utf8.decode(a.findFile(name)!.content);

    test('starts with its stored mimetype and points at its package', () {
      final a = book(const TavernStory(title: '雨夜', byline: '林晚 和 你', lines: []));
      expect(a.files.first.name, 'mimetype');
      expect(a.files.first.compression, CompressionType.none);
      expect(text(a, 'mimetype'), 'application/epub+zip');
      expect(text(a, 'META-INF/container.xml'), contains('full-path="OEBPS/content.opf"'));
    });

    test('has a chapter for every forty lines, listed in the spine and both tables of contents', () {
      final story = TavernStory.of(
        [for (var i = 0; i < 85; i++) _m(i.isEven ? TavernRole.character : TavernRole.user, '第 $i 句 <b>x</b>')],
        title: '雨夜 & 雪',
        byline: '林晚 和 你',
        you: '你',
      );
      final a = book(story);
      for (final n in [1, 2, 3]) {
        expect(a.findFile('OEBPS/chapter-$n.xhtml'), isNotNull);
        expect(text(a, 'OEBPS/content.opf'), contains('<itemref idref="c$n"/>'));
        expect(text(a, 'OEBPS/nav.xhtml'), contains('<a href="chapter-$n.xhtml">第 $n 章</a>'));
        expect(text(a, 'OEBPS/toc.ncx'), contains('<content src="chapter-$n.xhtml"/>'));
      }
      expect(a.findFile('OEBPS/chapter-4.xhtml'), isNull);
      final opf = text(a, 'OEBPS/content.opf');
      expect(opf, contains('<dc:title>雨夜 &amp; 雪</dc:title>'));
      expect(opf, contains('<dc:identifier id="bookid">urn:uuid:b1d2</dc:identifier>'));
      expect(opf, contains('<meta property="dcterms:modified">2026-11-10T00:00:00Z</meta>'));
      final last = text(a, 'OEBPS/chapter-3.xhtml');
      expect(last, contains('<p class="who">林晚</p>'));
      expect(last, contains('<p>第 84 句 x</p>'));
      expect(text(a, 'OEBPS/title.xhtml'), contains('<h1 class="book">雨夜 &amp; 雪</h1>'));
      expect(a.findFile('OEBPS/cover.xhtml'), isNull); // no picture, no cover page
    });

    test('takes the character\'s picture as its cover', () {
      final a = book(TavernStory(title: '雨夜', byline: '林晚 和 你', lines: const [], cover: _png));
      expect(a.findFile('OEBPS/images/cover.png'), isNotNull);
      expect(text(a, 'OEBPS/content.opf'), contains('properties="cover-image"'));
      expect(text(a, 'OEBPS/cover.xhtml'), contains('<img src="images/cover.png"'));
    });

    test('gets a fresh version 4 UUID', () {
      final id = tavernBookId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(tavernBookId(), isNot(id));
    });
  });

  test('a long image keeps within what a phone draws in one piece', () {
    expect(tavernStoryPixelRatio(1000), 3);
    expect(tavernStoryPixelRatio(6000), 2);
    expect(tavernStoryPixelRatio(30000), 1);
  });

  group('the page', () {
    late PreviewTavern tavern;
    late String chat;
    late List<TavernChatFile> handed;

    Future<void> open(WidgetTester tester, Widget home) async {
      SharedPreferences.setMockInitialValues({});
      handed = [];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tavernProvider.overrideWith((ref) => tavern),
            tavernChatSinkProvider.overrideWithValue((files) async => handed.addAll(files)),
          ],
          child: MaterialApp(
            theme: withTestFonts(buildLightTheme()),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: home,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> converse(int turns) async {
      for (var i = 0; i < turns; i++) {
        await tavern.send(chat, '第 $i 问').drain<void>();
      }
    }

    setUp(() async {
      tavern = PreviewTavern(tick: Duration.zero);
      chat = await tavern.createChat('sample-innkeeper');
    });

    testWidgets('舞台 › 本局 opens it', (tester) async {
      await open(tester, TavernChatPage(chatId: chat));
      await tester.tap(find.byKey(const ValueKey('bot-action')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('tavern-chat-storybook')),
        200,
        scrollable: find.descendant(of: find.byKey(const ValueKey('tavern-stage')), matching: find.byType(Scrollable)),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('tavern-chat-storybook')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tavern-chat-storybook')));
      await tester.pumpAndSettle();
      expect(find.byType(TavernStorybookPage), findsOneWidget);
      expect(find.text('林晚的故事'), findsWidgets); // the title until one is typed
    });

    testWidgets('the whole story goes out as an EPUB or as text, under the title typed', (tester) async {
      await tester.runAsync(() => converse(2));
      await open(tester, TavernStorybookPage(chatId: chat, character: '林晚'));
      expect(find.text('一共 5 句，隐藏的消息不放进去'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('tavern-book-title')), '雨夜');
      await tester.pump();
      expect(find.byKey(const ValueKey('tavern-book-card-title')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('tavern-book-card-title'))).data, '雨夜');

      await tester.tap(find.byKey(const ValueKey('tavern-book-epub')));
      await tester.pumpAndSettle();
      expect(handed.single.fileName, '雨夜.epub');
      final book = ZipDecoder().decodeBytes(handed.single.bytes);
      expect(utf8.decode(book.findFile('OEBPS/content.opf')!.content), contains('<dc:title>雨夜</dc:title>'));
      expect(tavernFileMime(handed.single.fileName), 'application/epub+zip');

      handed.clear();
      await tester.tap(find.byKey(const ValueKey('tavern-book-text')));
      await tester.pumpAndSettle();
      expect(handed.single.fileName, '雨夜.txt');
      final text = utf8.decode(handed.single.bytes);
      expect(text, startsWith('雨夜\n\n林晚 和 你'));
      expect(text, contains('你：\n第 1 问'));
    });

    testWidgets('the long image holds the latest lines and says how many came before', (tester) async {
      await tester.runAsync(() => converse(6)); // the greeting and twelve more
      await open(tester, TavernStorybookPage(chatId: chat, character: '林晚'));
      await tester.ensureVisible(find.byKey(const ValueKey('tavern-book-excerpt')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('tavern-book-excerpt')), matching: find.text('10 句')),
      );
      await tester.pumpAndSettle();
      expect(find.text('前面还有 3 句没放进图里，整段请导出电子书。'), findsOneWidget);
      expect(find.text('…… 前面还有 3 句 ……'), findsOneWidget);
      final card = tester.widget<TavernStoryCard>(find.byType(TavernStoryCard));
      expect(card.lines, hasLength(10));
      expect(card.lines.last.text, isNot(isEmpty));

      await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('tavern-book-excerpt')), matching: find.text('20 句')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TavernStoryCard>(find.byType(TavernStoryCard)).lines, hasLength(13));
      expect(find.text('…… 前面还有 3 句 ……'), findsNothing);
    });
  });
}
