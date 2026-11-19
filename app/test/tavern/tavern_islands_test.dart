import 'package:dsh_app/tavern/tavern_island_story.dart';
import 'package:dsh_app/tavern/tavern_islands.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_island.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

const _status = '<div class="bar"><b>好感</b> 42</div>';

/// What the island builder was handed: the islands on screen, by their HTML.
Widget _fakeIsland(String html) => SizedBox(key: ValueKey('island:$html'), height: 40);

Future<void> _chat(WidgetTester tester, String narration, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({...prefs});
  final tavern = PreviewTavern(tick: Duration.zero);
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  await tester.runAsync(() => tavern.narrate(chat, narration));
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        tavernIslandBuilderProvider.overrideWithValue(_fakeIsland),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TavernChatPage(chatId: chat),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('a message is cut into Markdown and islands where it carries HTML', () {
    expect(tavernParts('她笑了。*点头*'), [isA<TavernTextPart>()]);
    // An ```html block between text: three parts, the block as it is.
    final fenced = tavernParts('她推开门。\n\n```html\n$_status\n```\n\n「进来吧。」');
    expect(fenced.map((p) => p.runtimeType), [TavernTextPart, TavernIslandPart, TavernTextPart]);
    expect((fenced[1] as TavernIslandPart).html, _status);
    expect((fenced[0] as TavernTextPart).markdown, '她推开门。');
    expect(tavernParts('~~~HTML\n<p>x</p>\n~~~').single, isA<TavernIslandPart>());
    // Other code blocks and empty ones stay Markdown.
    expect(tavernParts('```js\nlet a = 1;\n```'), [isA<TavernTextPart>()]);
    expect(tavernParts('```html\n\n```'), [isA<TavernTextPart>()]);
    // Inline tags Markdown draws itself are not islands.
    expect(tavernParts('她<b>笑</b>了。'), [isA<TavernTextPart>()]);

    // Raw block HTML: the whole text becomes a page, its other paragraphs <p>.
    final raw = tavernParts('<style>.bar{color:red}</style>\n\n她*笑*了。\n第二行\n\n$_status').single as TavernIslandPart;
    expect(raw.html, contains('<style>.bar{color:red}</style>'));
    expect(raw.html, contains('<p>她<em>笑</em>了。<br>第二行</p>'));
    expect(raw.html, contains(_status));
  });

  test("a front-end card's greeting: each page an island, whatever its code block's language", () {
    // As the engine shows such a greeting (its display regexes turned the
    // tags into pages: packages/dsh_tavern/test/display_frontend_greeting_test.dart).
    const story =
        '```html\n<!DOCTYPE html>\n<html><head><style>\n.a{}\n\n.b{}\n</style></head>\n'
        "<body><script>\nvar who='User';\n\nlet x = a*b*c;\n</script></body></html>\n```";
    const status = '<!DOCTYPE html>\n<html><body><div>状态</div></body></html>';
    final parts = tavernParts('$story\n\n```\n$status\n```');
    expect(parts.map((p) => p.runtimeType), [TavernIslandPart, TavernIslandPart]);
    expect((parts[0] as TavernIslandPart).html, contains('.a{}\n\n.b{}'));
    expect((parts[0] as TavernIslandPart).html, contains("var who='User';\n\nlet x = a*b*c;"));
    expect((parts[1] as TavernIslandPart).html, status);
    // Any language, indented up to three spaces, CRLF: still a page.
    for (final text in [
      '```text\n$status\n```',
      '   ```\n$status\n   ```',
      '```\r\n${status.replaceAll('\n', '\r\n')}\r\n```',
    ]) {
      expect(tavernParts(text).single, isA<TavernIslandPart>(), reason: text);
    }
    // Code that is not a page stays code, as in 酒馆助手.
    expect(tavernParts('```\n<div>x</div>\n```'), [isA<TavernTextPart>()]);
    // Beside HTML, in its page, it is still code.
    final beside = tavernParts('<div>面板</div>\n\n```js\nif (a<b) x();\n```').single as TavernIslandPart;
    expect(beside.html, '<div>面板</div>\n<pre><code>if (a&lt;b) x();</code></pre>');

    // Unfenced, with blank lines in its CSS and code: those stay as written.
    final bare =
        tavernParts(
              '<div><details><summary>变量</summary>[1]</details></div>\n<style>\n.x{}\n\n.y{}\n</style>\n\n'
              '<script>\nvar a = 1;\n\nvar b = a*2*3;\n</script>\n\n她*笑*了。',
            ).single
            as TavernIslandPart;
    expect(bare.html, contains('<style>\n.x{}\n\n.y{}\n</style>'));
    expect(bare.html, contains('<script>\nvar a = 1;\n\nvar b = a*2*3;\n</script>'));
    expect(bare.html, contains('<p>她<em>笑</em>了。</p>'));
  });

  test('blank lines part HTML blocks, never inside a style, script, pre, textarea or comment', () {
    expect(tavernHtmlBlocks('a\n\nb'), ['a', 'b']);
    expect(tavernHtmlBlocks('<STYLE>\na\n\nb\n</style>\n\nc'), ['<STYLE>\na\n\nb\n</style>', 'c']);
    expect(tavernHtmlBlocks('<!-- a\n\nb -->\n\n<pre>c\n\n</pre>\n\nd'), ['<!-- a\n\nb -->', '<pre>c\n\n</pre>', 'd']);
    // A </style> in a script is the script's, until the script ends.
    expect(tavernHtmlBlocks('<script>\n"</style>"\n\nx\n</script>\n\ny'), [
      '<script>\n"</style>"\n\nx\n</script>',
      'y',
    ]);
    expect(tavernIsFrontend('<body>'), isTrue);
    expect(tavernIsFrontend('</html>'), isTrue);
    expect(tavernIsFrontend('<div>x</div>'), isFalse);
  });

  test('the page reports its height with our script; the protections are choices', () {
    String page({bool noScripts = false, bool offline = false}) => tavernIslandDocument(
      _status,
      text: const Color(0xff112233),
      accent: const Color(0xff445566),
      fontSize: 15,
      nonce: 'n0nce',
      noScripts: noScripts,
      offline: offline,
    );
    final open = page();
    expect(open, contains(_status));
    expect(open, contains('<script nonce="n0nce">'));
    expect(open, contains('TavernIsland.postMessage'));
    expect(open, contains('font:15.0px/1.5'));
    expect(open, isNot(contains('Content-Security-Policy')));

    final quiet = page(noScripts: true);
    expect(quiet, contains("script-src 'nonce-n0nce'"));
    expect(quiet, isNot(contains("'unsafe-inline' 'unsafe-eval'")));
    expect(quiet, isNot(contains("default-src 'none'")));

    final offline = page(offline: true);
    expect(offline, contains("default-src 'none'"));
    expect(offline, contains('img-src data: blob:'));
    expect(offline, contains("script-src 'unsafe-inline' 'unsafe-eval'\">"));
    expect(offline, isNot(contains("'unsafe-eval' 'nonce-")));
  });

  test("a status bar's island reads its floor (read only), with jQuery and lodash first", () {
    expect(tavernIslandReadsStory("<script>await waitGlobalInitialized('Mvu');</script>"), isTrue);
    expect(tavernIslandReadsStory("<script>getVariables({type:'message'})</script>"), isTrue);
    expect(tavernIslandReadsStory('<script>allVars = getAllVariables();</script>'), isTrue);
    expect(tavernIslandReadsStory('<div>Mvu</div>'), isFalse);
    expect(tavernIslandHasScript('<p>x</p>'), isFalse);
    // An inline handler runs as a script does.
    expect(tavernIslandReadsStory('<button onclick="getVariables()">看</button>'), isTrue);
    expect(tavernIslandHasScript('<p onclick="go()">x</p>'), isTrue);
    String page({bool noScripts = false}) => tavernIslandDocument(
      _status,
      text: const Color(0xff112233),
      accent: const Color(0xff445566),
      fontSize: 15,
      nonce: 'n0nce',
      noScripts: noScripts,
      libraries: const ['window.lib=1;</script>'],
      story: const {
        'messageId': 1,
        'data': {'note': '</script>'},
      },
    );
    final open = page();
    expect(open, contains(r'<script nonce="n0nce">window.lib=1;<\/script></script>'));
    expect(open, contains(r'var dshStory={"messageId":1,"data":{"note":"\u003c/script>"}};'));
    expect(open, contains("e.code='unsupportedCapability'"));
    expect(open.indexOf('var dshStory'), lessThan(open.indexOf(_status)));
    final quiet = page(noScripts: true);
    expect(quiet, isNot(contains('dshStory')));
    expect(quiet, isNot(contains('window.lib')));
  });

  test("an island's story: each message's floor and variables, the latest's, the chat's", () {
    final story = TavernIslandStory(
      floors: {
        'n0': (floor: 0, data: const {'a': 1}),
        'n1': (floor: 1, data: const {'a': 2}),
      },
      chat: const {'c': true},
      last: (floor: 1, data: const {'a': 2}),
    );
    expect(story.forMessage('n0', text: '你好', name: '林晚', user: false), {
      'messageId': 0,
      'last': 1,
      'data': {'a': 1},
      'latest': {'a': 2},
      'chat': {'c': true},
      'message': '你好',
      'name': '林晚',
      'role': 'assistant',
    });
    expect(story.forMessage('gone', text: '', name: '', user: false), isNull);
  });

  testWidgets("a message's HTML is an island; the words around it stay native", (tester) async {
    await _chat(tester, '她推开门。\n\n```html\n$_status\n```\n\n「进来吧。」');
    expect(find.byKey(const ValueKey('island:$_status')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is MarkdownBody && w.text.trim() == '她推开门。'), findsWidgets);
    expect(find.byWidgetPredicate((w) => w is MarkdownBody && w.text.trim() == '「进来吧。」'), findsWidgets);
  });

  testWidgets('with 消息里的网页 off, it is all text', (tester) async {
    await _chat(tester, '```html\n$_status\n```', prefs: {TavernSettingsController.islandsKey: false});
    expect(find.byKey(const ValueKey('island:$_status')), findsNothing);
    expect(find.byWidgetPredicate((w) => w is MarkdownBody && w.text.contains('好感')), findsOneWidget);
  });

  testWidgets('酒馆设置 › 安全 keeps the two protections, off until chosen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const TavernSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in ['tavern-island-no-scripts', 'tavern-island-offline']) {
      await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final tile = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Switch));
      expect(tester.widget<Switch>(tile).value, isFalse, reason: key);
      await tester.tap(tile);
      await tester.pumpAndSettle();
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(TavernSettingsController.islandNoScriptsKey), isTrue);
    expect(prefs.getBool(TavernSettingsController.islandOfflineKey), isTrue);
  });
}
