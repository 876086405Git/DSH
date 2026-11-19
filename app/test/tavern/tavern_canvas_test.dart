import 'dart:convert';

import 'package:dsh_app/tavern/tavern_canvas.dart';
import 'package:dsh_app/tavern/tavern_canvas_calls.dart';
import 'package:dsh_app/tavern/tavern_card_scripts.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_script_wire.dart' show tavernScriptKey;
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/tavern/tavern_canvas_view.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// What the canvas was last handed.
class _Canvas {
  List<TavernCanvasEntry> entries = const [];
  ValueListenable<(String, String)?>? streaming;
  void Function(String nodeId)? onMenu;
  TavernCanvasCalls? calls;
  var builds = 0;
}

/// A script the chat runs: the card's, unless [kind] says otherwise.
TavernRunnableScript _script(
  String id, {
  TavernScriptOwnerKind kind = TavernScriptOwnerKind.character,
  List<String> buttons = const [],
}) => TavernRunnableScript(
  owner: TavernScriptOwner(
    kind: kind,
    scriptId: id,
    assetId: kind == TavernScriptOwnerKind.character ? 'sample-innkeeper' : null,
  ),
  name: id,
  content: 'x',
  buttons: [for (final b in buttons) TavernScriptButton(name: b, visible: true)],
);

/// Every chat runs [scripts].
Override _scripts(List<TavernRunnableScript> scripts) => tavernChatScriptsProvider.overrideWith(
  (ref, chat) => Stream.value(TavernChatScripts(chatId: chat.$1, characterId: chat.$2, scripts: scripts)),
);

Future<(PreviewTavern, String, _Canvas)> _chat(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  bool group = false,
  Duration tick = Duration.zero,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({TavernSettingsController.canvasKey: true, ...prefs});
  final tavern = PreviewTavern(tick: tick);
  final String chat;
  if (group) {
    chat = (await tester.runAsync(
      () => tavern.createGroupChat(
        ['sample-innkeeper', 'sample-navigator'],
        activation: TavernGroupActivation.listOrder,
        addGreetings: false,
      ),
    ))!;
  } else {
    chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
    await tester.runAsync(() => tavern.narrate(chat, '*雨停了。*\n\n"进来吧，" 她说。'));
  }
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final canvas = _Canvas();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        ...overrides,
        tavernCanvasBuilderProvider.overrideWithValue(({required entries, required streaming, required onMenu, calls}) {
          canvas
            ..entries = entries
            ..streaming = streaming
            ..onMenu = onMenu
            ..calls = calls
            ..builds += 1;
          return const SizedBox.expand(key: ValueKey('fake-canvas'));
        }),
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
  return (tavern, chat, canvas);
}

void main() {
  test(
    "the personas as the page is told them: each one's id, name, description, position; this chat's, the default",
    () {
      final traveller = TavernPersona(id: 'p1', name: '旅人', description: '背着包');
      final quiet = TavernPersona(id: 'p2', name: '阿青', descriptionPosition: PersonaDescriptionPosition.atDepth);
      expect(
        tavernCanvasPersonas(
          [traveller, quiet],
          PersonaSelection(
            persona: traveller,
            source: PersonaSelectionSource.chat,
            boundPersonaId: 'p1',
            defaultPersonaId: 'p2',
          ),
        ),
        {
          'list': [
            {'id': 'p1', 'name': '旅人', 'description': '背着包', 'position': 0},
            {'id': 'p2', 'name': '阿青', 'description': '', 'position': 4},
          ],
          'current': 'p1',
          'default': 'p2',
        },
      );
      expect(tavernCanvasPersonas(const [], null), {'list': <Object?>[], 'current': null, 'default': null});
    },
  );

  test("a card's toastr reads title over text, cut when long, up longer for more and for trouble", () {
    expect(tavernToast({'type': 'toast', 'level': 'info', 'title': '', 'message': '  '}), isNull);
    expect(tavernToast({'type': 'toast'}), isNull);
    final short = tavernToast({'level': 'success', 'title': ' 存档 ', 'message': '已保存'})!;
    expect((short.title, short.message), ('存档', '已保存'));
    expect(short.duration, const Duration(milliseconds: 2000));
    final text = tavernToast({'level': 'info', 'message': '只有内容'})!;
    expect((text.title, text.message), ('', '只有内容'));
    final title = tavernToast({'level': 'info', 'title': '只有标题', 'message': 3})!;
    expect((title.title, title.message), ('只有标题', ''));
    expect(tavernToast({'level': 'error', 'message': '坏了'})!.duration, const Duration(milliseconds: 4000));
    expect(tavernToast({'level': 'warning', 'message': '小心'})!.duration, const Duration(milliseconds: 4000));
    final long = tavernToast({'level': 'info', 'title': '题' * 80, 'message': '长' * 400})!;
    expect(long.title, '${'题' * tavernToastTitleMax}…');
    expect(long.message, '${'长' * tavernToastMax}…');
    expect(long.duration, const Duration(milliseconds: 6000));
    expect(tavernToast({'level': 'error', 'message': '长' * 400})!.duration, const Duration(milliseconds: 8000));
    // Characters, not UTF-16 units: an emoji is not split.
    expect(tavernToast({'level': 'info', 'message': '😀' * 301})!.message, '${'😀' * 300}…');
  });

  test('a message reads as ST would draw it: paragraphs, emphasis, what is said in <q>', () {
    expect(
      tavernStoryHtml('她笑了。\n第二行\n\n*点头*，**很重要**。'),
      '<p>她笑了。<br>第二行</p>\n<p><em>点头</em>，<strong>很重要</strong>。</p>',
    );
    expect(tavernStoryHtml('"进来吧，" 她说。「好。」'), '<p><q>"进来吧，"</q> 她说。<q>「好。」</q></p>');
    // A tag's attributes are left as written; its words are formatted.
    expect(tavernStoryHtml('看<span title="a *b*">"这里"</span>'), '<p>看<span title="a *b*"><q>"这里"</q></span></p>');
    // Code keeps its marks; an ```html block and block HTML go as written.
    expect(tavernStoryHtml('用 `*x*` 吧'), '<p>用 <code>*x*</code> 吧</p>');
    expect(
      tavernStoryHtml('```js\nif (a < b) *c*\n```'),
      '<pre><code class="language-js">if (a &lt; b) *c*</code></pre>',
    );
    expect(tavernStoryHtml('```html\n<div class="bar">"x"</div>\n```'), '<div class="bar">"x"</div>');
    expect(tavernStoryHtml('<div class="bar">\n"好感" 42\n</div>'), '<div class="bar">\n"好感" 42\n</div>');
    expect(tavernStoryHtml('## 第一章'), '<h2>第一章</h2>');
    expect(tavernStoryHtml('> 引文\n> 第二行'), '<blockquote><p>引文<br>第二行</p></blockquote>');
    expect(tavernStoryHtml('a_b_c 和 _斜_'), '<p>a_b_c 和 <em>斜</em></p>');
  });

  test('the page has ST structure and colour variables, our script by nonce, and the chosen guards', () {
    String page({
      bool noScripts = false,
      bool offline = false,
      List<String> libraries = const [],
      String themeCss = '',
    }) => tavernCanvasDocument(
      text: const Color(0xff112233),
      accent: const Color(0xff445566),
      muted: const Color(0xff778899),
      quote: const Color(0xffaa5500),
      emphasis: const Color(0xff556677),
      userTint: const Color(0x22445566),
      fontSize: 15,
      lineHeight: 1.65,
      nonce: 'n0nce',
      userLabel: '你',
      labels: const TavernCanvasLabels(letterFrom: '{from}的信', taken: '获得'),
      noScripts: noScripts,
      offline: offline,
      libraries: libraries,
      themeCss: themeCss,
    );
    final open = page();
    expect(open, contains('<div id="chat"></div>'));
    // A long story: only the latest messages are always laid out, and one
    // drawn as it was is kept (the script itself was checked in Edge).
    expect(open, contains('.mes.far{content-visibility:auto;'));
    expect(open, contains("m.classList.toggle('far',i<list.length-$tavernCanvasNear)"));
    expect(open, contains('if(m&&m._dsh===key)'));
    // A card's scripts run unless 不运行卡的脚本 is on; never with our nonce.
    expect(open, contains('var runScripts=true'));
    expect(page(noScripts: true), contains('var runScripts=false'));
    expect(open, contains("if(at.name!=='nonce')"));
    // The libraries card scripts expect go in first, under our nonce; not
    // when card scripts do not run. A stray closing tag in one cannot end it.
    final withLibs = page(libraries: ['window.__lib=1', 'var s="</script>"']);
    expect(withLibs, contains('<script nonce="n0nce">window.__lib=1</script>'));
    expect(withLibs, contains(r'var s="<\/script>"'));
    expect(withLibs.indexOf('window.__lib=1'), lessThan(withLibs.indexOf('window.dsh={')));
    expect(page(noScripts: true, libraries: ['window.__lib=1']), isNot(contains('window.__lib=1')));
    // 酒馆助手's page API, from the page's own copy (checked in Edge).
    for (final name in ['getVariables', 'replaceVariables', 'getChatMessages', 'eventOn', 'tavern_events']) {
      expect(open, contains('if(!window.$name)window.$name='));
    }
    for (final name in [
      'setChatMessages',
      'createChatMessages',
      'deleteChatMessages',
      'rotateChatMessages',
      'updateVariablesWith',
      'insertOrAssignVariables',
      'insertVariables',
      'deleteVariable',
    ]) {
      expect(open, contains("['$name',$name]"));
    }
    expect(open, contains('--SmartThemeQuoteColor:rgba(170,85,0,1.000)'));
    expect(open, contains('--SmartThemeEmColor:rgba(85,102,119,1.000)'));
    expect(open, contains('font:var(--mainFontSize)/1.65'));
    expect(open, contains('<script nonce="n0nce">'));
    expect(open, contains("m.className='mes'"));
    expect(open, contains("m.setAttribute('mesid'"));
    expect(open, contains('DshTavern.postMessage'));
    expect(open, contains('var userLabel="你"'));
    expect(open, isNot(contains('Content-Security-Policy')));
    // Component tags are Web Components there, in the reader's words.
    for (final tag in ['dsh-letter', 'dsh-item', 'dsh-clue', 'dsh-phone', 'dsh-roll', 'dsh-notice', 'dsh-game']) {
      expect(open, contains("define('$tag'"));
    }
    expect(open, contains('"letterFrom":"{from}的信"'));
    expect(open, contains('"taken":"获得"'));
    // To a screen reader (roleplay-ui §12; the tree itself was read in
    // Edge): each message an article named by who speaks; a component a
    // group named by its head, the head not said twice; the reply being
    // written busy, and only its arrival said, in a live region.
    expect(open, contains("m.setAttribute('role','article');"));
    expect(open, contains("m.setAttribute('aria-label',nameText.textContent);"));
    expect(open, contains('<div id="dsh-live" aria-live="polite" aria-atomic="true"></div>'));
    expect(open, contains("stream.setAttribute('aria-busy','true')"));
    expect(open, contains("say(fill(L.replied,'name',last.getAttribute('aria-label')||''))"));
    expect(open, contains('"replied":"{name} replied"'));
    expect(open, contains("if(!this.hasAttribute('role'))this.setAttribute('role',a[0]);"));
    expect('<div part="head" aria-hidden="true">'.allMatches(open).length, 4);
    expect(open, contains(r'content:"\25CF" / "";'));
    // Prompt injections and asking the model, 酒馆助手's names (the page's
    // behaviour was checked in Edge against a stub engine).
    for (final name in ['generate', 'generateRaw', 'stopGenerationById', 'stopAllGeneration']) {
      expect(open, contains("['$name',"));
    }
    expect(open, contains("if(d.kind==='generation'){generationEvent(d);return;}"));
    expect(open, contains("if(d.kind==='invoke'){invoke(d);return;}"));
    expect(open, contains("['custom_api','tools','tool_choice','json_schema','image']"));
    expect(open, contains('if(!window.iframe_events)window.iframe_events=iframe_events;'));
    expect(open, contains('if(!window.injectPrompts)window.injectPrompts=injectPrompts;'));
    // The rest of 酒馆助手's events and its displayed messages (their
    // behaviour checked in Edge); floors numbered as ST numbers them; a
    // message's script gone from it once run.
    for (final name in [
      'eventMakeFirst',
      'eventMakeLast',
      'eventEmitAndWait',
      'eventClearEvent',
      'eventClearListener',
      'eventClearAll',
      'retrieveDisplayedMessage',
      'renderOneMessage',
    ]) {
      expect(open, contains("['$name',$name]"));
    }
    expect(open, contains('if(loaded)renumber();'));
    expect(open, contains('var gone=function(){s.remove();};'));
    // SillyTavern: only what the page can truly give (checked in Edge).
    expect(open, contains("Object.defineProperty(SillyTavern,'chat',{get:function(){return msgs.map(stMessage);}"));
    expect(open, contains('if(!window.SillyTavern)window.SillyTavern=SillyTavern;'));
    // The chat's scripts come later (dsh.setScripts), each kept in its frame
    // by its whole owner's key while its code stays the same.
    expect(open, contains('var scripts=[],frames={},frameAt=[],started=null,drawn=false;'));
    expect(open, contains('dsh.setScripts=function(list){scripts=list;if(started)started.then(syncFrames);'));
    expect(open, contains("if(!want[k]||want[k].content!==frames[k].content)stopFrame(k);"));
    String withScripts({
      bool noScripts = false,
      Map<String, Object?> card = const {'name': '林晚', 'description': '店主</script>'},
    }) => tavernCanvasDocument(
      text: const Color(0xff112233),
      accent: const Color(0xff445566),
      muted: const Color(0xff778899),
      quote: const Color(0xffaa5500),
      emphasis: const Color(0xff556677),
      userTint: const Color(0x22445566),
      fontSize: 15,
      lineHeight: 1.65,
      nonce: 'n0nce',
      noScripts: noScripts,
      card: card,
      characterId: 'char-1',
    );
    // The chat's card likewise (its questions checked in Edge); none for a
    // group, or when scripts do not run.
    expect(withScripts(), contains(r'var card={"name":"林晚","description":"店主\u003c/script>"},cardId="char-1";'));
    // A comment opener and a script opener in a card's text cannot derail ours.
    final opener = withScripts(card: const {'description': '<!--<script>'});
    expect(opener, isNot(contains('<!--<script>')));
    expect(opener, contains(r'"description":"\u003c!--\u003cscript>"'));
    expect(withScripts(noScripts: true), contains('var card=null,cardId=null;'));
    expect(open, contains('var card=null,cardId=null;'));
    expect(open, contains(r"el.textContent=withoutMvuImport(s.content)+'\n//# sourceURL=dsh-script-'+f.n+'.js';"));
    // MVU: on for a card that uses it, Mvu shared once the engine has it on;
    // off otherwise, and when scripts do not run.
    expect(open, contains('var mvuWanted=false;'));
    final mvu = withScripts(
      card: const {
        'name': '林晚',
        'extensions': {
          'dshgo': {
            'mvu': {'enabled': true},
          },
        },
      },
    );
    expect(mvu, contains('var mvuWanted=true;'));
    expect(mvu, contains("ask('setMvuEnabled',{enabled:true})"));
    expect(mvu, contains("initializeGlobal('Mvu',Mvu)"));
    expect(mvu, contains('started=dsh.scripts.ready().then(go,go);'));
    // Its events answered with the candidate; the engine's resources kept
    // from the snapshot and each delivery, before a same-revision return.
    expect(mvu, contains('if(mvu)ack.mvu=mvu;'));
    expect(mvu, contains('adoptResources(s.resourceRefs,s.context);'));
    expect(
      mvu.indexOf('adoptResources(x.resourceRefs);'),
      lessThan(mvu.indexOf('if(x.baseRevision===x.newRevision)return;')),
    );
    for (final name in [
      'getWorldbook',
      'replaceWorldbook',
      'getLorebookEntries',
      'getPreset',
      'replaceTavernRegexes',
      'replaceScriptButtons',
      'substitudeMacros',
      'formatAsTavernRegexedString',
      'replaceCharacter',
      'waitGlobalInitialized',
    ]) {
      expect(mvu, matches(RegExp("share\\('$name'|\\['$name',")), reason: name);
    }
    expect(page(noScripts: true), contains("script-src 'nonce-n0nce'"));
    expect(page(offline: true), contains("default-src 'none'"));
    // Offline with scripts on: no nonce beside 'unsafe-inline', or a card's
    // own scripts and handlers would be refused.
    expect(page(offline: true), contains("script-src 'unsafe-inline' 'unsafe-eval'\">"));
    expect(page(offline: true), isNot(contains("'unsafe-eval' 'nonce-")));
    // A card's inline script is named after its message, for its floor.
    expect(open, contains(r"s.text=old.text+'\n//# sourceURL=dsh-mes-'+mark(m)+'.js'"));
    for (final name in ['getLastMessageId', 'getCurrentMessageId', 'getIframeName', 'getMessageId']) {
      expect(open, contains("['$name',$name]"));
    }
    // toastr is the app's notice, its HTML read apart from the page.
    expect(open, contains("post({type:'toast',level:level,title:t,message:m,id:id})"));
    // clear and remove put away the notice a call showed, or with none named whichever is up.
    expect(open, contains('clear:clearToast,remove:clearToast'));
    expect(open, contains("new DOMParser().parseFromString(String(s),'text/html')"));
    expect(open, contains('if(!window.toastr)window.toastr=toastr;'));
    // An ST theme's custom CSS comes after our styles, so it wins as in ST;
    // a closing tag in it cannot end it. None given, none there.
    expect(open, isNot(contains('st-theme-css')));
    expect(page(themeCss: '  \n'), isNot(contains('st-theme-css')));
    final themed = page(themeCss: '#chat .mes{border:1px solid gold}</STYLE><script>x()</script>');
    final ours = themed.indexOf('</style>');
    final theirs = themed.indexOf('<style id="st-theme-css">');
    expect(ours, greaterThan(0));
    expect(theirs, greaterThan(ours));
    expect(theirs, lessThan(themed.indexOf('</head>')));
    expect(
      themed,
      contains('<style id="st-theme-css">#chat .mes{border:1px solid gold}<\\/style><script>x()</script></style>'),
    );

    final json = jsonDecode(
      tavernCanvasJson(const [
        TavernCanvasEntry(mesid: 0, nodeId: 'n1', name: '林晚', html: '<p>好</p>'),
        TavernCanvasEntry(mesid: 1, nodeId: 'n2', name: '你', html: '<p>嗯</p>', isUser: true),
      ]),
    );
    expect(json, [
      {'mesid': 0, 'node': 'n1', 'name': '林晚', 'html': '<p>好</p>', 'user': false, 'system': false},
      {'mesid': 1, 'node': 'n2', 'name': '你', 'html': '<p>嗯</p>', 'user': true, 'system': false},
    ]);
  });

  testWidgets('with 整页画布 on, the story is the canvas, each message as shown', (tester) async {
    final (tavern, chat, canvas) = await _chat(tester);
    expect(find.byKey(const ValueKey('fake-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-transcript')), findsNothing);
    final path = (await tester.runAsync(() => tavern.path(chat)))!;
    expect(canvas.entries.map((e) => e.nodeId), path.map((m) => m.nodeId));
    expect(canvas.entries.map((e) => e.mesid), List.generate(path.length, (i) => i));
    final narration = canvas.entries.last;
    expect(narration.isSystem, isTrue);
    expect(narration.name, '旁白');
    expect(narration.html, '<p><em>雨停了。</em></p>\n<p><q>"进来吧，"</q> 她说。</p>');
    expect(canvas.streaming!.value, isNull);

    // The page's dsh.call is answered: here the preview, which says it
    // simulates no card scripts.
    final reply = (await tester.runAsync(
      () => canvas.calls!.handle({
        'id': 1,
        'method': 'getVariables',
        'params': {
          'target': {'scope': 'chat'},
        },
      }),
    ))!;
    expect(reply['id'], 1);
    expect((reply['error']! as Map)['code'], 'unsupportedCapability');

    // Holding a message on the canvas opens the app's own menu for it.
    canvas.onMenu!(narration.nodeId);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('in a group, the reply being written goes under whoever speaks now', (tester) async {
    final (tavern, chat, canvas) = await _chat(tester, group: true, tick: const Duration(milliseconds: 1));
    final writers = <String>{};
    void seen() {
      if (canvas.streaming!.value case (final name, _)) writers.add(name);
    }

    canvas.streaming!.addListener(seen);
    addTearDown(() => canvas.streaming!.removeListener(seen));
    await tester.enterText(find.byType(TextField), '大家好');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    await tester.pumpAndSettle();

    // Each member under their own name; never the group's title (林晚、星图).
    expect(writers, containsAll(['林晚', '星图']));
    expect(writers, isNot(contains('林晚、星图')));
    final path = (await tester.runAsync(() => tavern.path(chat)))!;
    expect(path.map((m) => m.speakerCharacterId), [null, 'sample-innkeeper', 'sample-navigator']);
    expect(canvas.entries.skip(1).map((e) => e.name), ['林晚', '星图']);
    expect(canvas.streaming!.value, isNull);
  });

  testWidgets('视觉小说 keeps its own view', (tester) async {
    await _chat(tester, prefs: {TavernSettingsController.layoutKey: TavernLayout.visualNovel.name});
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);
  });

  testWidgets('with the switch off, the native list', (tester) async {
    await _chat(tester, prefs: {TavernSettingsController.canvasKey: false});
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);
    expect(find.byKey(const ValueKey('tavern-transcript')), findsOneWidget);
  });

  testWidgets("the chat's script buttons sit above the composer, before 掷骰; a tap is pressed in the page, by owner", (
    tester,
  ) async {
    final global = _script('s1', kind: TavernScriptOwnerKind.global, buttons: ['全局']);
    final card = _script('s1', buttons: ['前往', '查看背包']);
    final (_, _, canvas) = await _chat(
      tester,
      overrides: [
        _scripts([global, card, _script('s2')]),
      ],
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('tavern-quick-replies'));
    expect(find.descendant(of: row, matching: find.text('前往')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('查看背包')), findsOneWidget);
    // In order: global, then the card's, then 掷骰.
    final first = tester.getTopLeft(find.byKey(const ValueKey('tavern-script-button-0'))).dx;
    final second = tester.getTopLeft(find.byKey(const ValueKey('tavern-script-button-1'))).dx;
    final dice = tester.getTopLeft(find.byKey(const ValueKey('tavern-dice'))).dx;
    expect(first < second && second < dice, isTrue);

    final pressed = <Map<String, Object?>>[];
    canvas.calls!.deliver = (d) async {
      pressed.add(d);
      return true;
    };
    // The same script id in two places: each button goes to its own.
    await tester.tap(find.byKey(const ValueKey('tavern-script-button-2')));
    await tester.tap(find.byKey(const ValueKey('tavern-script-button-0')));
    await tester.pump();
    expect(pressed, [
      {'kind': 'button', 'key': tavernScriptKey(card.owner), 'name': '查看背包'},
      {'kind': 'button', 'key': tavernScriptKey(global.owner), 'name': '全局'},
    ]);
  });

  testWidgets('no script buttons where the scripts do not run: 不运行卡的脚本 on, or the native list', (tester) async {
    final override = _scripts([
      _script('s1', buttons: ['前往']),
    ]);
    await _chat(tester, prefs: {TavernSettingsController.islandNoScriptsKey: true}, overrides: [override]);
    expect(find.byKey(const ValueKey('tavern-script-button-0')), findsNothing);
    expect(find.byKey(const ValueKey('tavern-dice')), findsOneWidget);

    await _chat(tester, prefs: {TavernSettingsController.canvasKey: false}, overrides: [override]);
    expect(find.byKey(const ValueKey('tavern-script-button-0')), findsNothing);
  });

  testWidgets("with the switch off, a card's scripts are said to wait on it; 打开 turns it on", (tester) async {
    // The card's own are counted; a global one is not the card's.
    final override = _scripts([_script('g', kind: TavernScriptOwnerKind.global), _script('s1'), _script('s2')]);
    final (_, _, canvas) = await _chat(
      tester,
      prefs: {TavernSettingsController.canvasKey: false},
      overrides: [override],
    );
    await tester.pumpAndSettle();
    final hint = find.byKey(const ValueKey('tavern-scripts-hint'));
    expect(find.descendant(of: hint, matching: find.text('这张卡带了 2 个脚本，打开「整页画布（试用）」才会运行')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);

    await tester.tap(find.descendant(of: hint, matching: find.text('打开')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-canvas')), findsOneWidget);
    expect(canvas.builds, greaterThan(0));
    expect(hint, findsNothing);
    // For this card only: 酒馆设置 stay as they were.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TavernCharacterRenderController.keyFor('sample-innkeeper')), 'canvas');
    expect(prefs.getBool(TavernSettingsController.canvasKey), isFalse);
  });

  testWidgets("a character's own 整页画布 puts its chat on the canvas, the settings' off", (tester) async {
    await _chat(
      tester,
      prefs: {
        TavernSettingsController.canvasKey: false,
        TavernCharacterRenderController.keyFor('sample-innkeeper'): 'canvas',
      },
    );
    expect(find.byKey(const ValueKey('fake-canvas')), findsOneWidget);
  });

  testWidgets("a character's own 文字 keeps it off the canvas, the settings' on", (tester) async {
    await _chat(tester, prefs: {TavernCharacterRenderController.keyFor('sample-innkeeper'): 'text'});
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);
  });

  testWidgets('put away, it is not said again for that card', (tester) async {
    final override = _scripts([_script('s1')]);
    await _chat(tester, prefs: {TavernSettingsController.canvasKey: false}, overrides: [override]);
    await tester.pumpAndSettle();
    final hint = find.byKey(const ValueKey('tavern-scripts-hint'));
    expect(find.descendant(of: hint, matching: find.text('这张卡带了 1 个脚本，打开「整页画布（试用）」才会运行')), findsOneWidget);
    await tester.tap(find.descendant(of: hint, matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    expect((await SharedPreferences.getInstance()).getBool('${tavernScriptsHintOffKey}sample-innkeeper'), isTrue);

    // Opened again, as kept: not said.
    await _chat(
      tester,
      prefs: {TavernSettingsController.canvasKey: false, '${tavernScriptsHintOffKey}sample-innkeeper': true},
      overrides: [override],
    );
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
  });

  testWidgets('not said where it would not help: no scripts, 不运行卡的脚本 on, or 视觉小说', (tester) async {
    final override = _scripts([_script('s1')]);
    final hint = find.byKey(const ValueKey('tavern-scripts-hint'));
    await _chat(tester, prefs: {TavernSettingsController.canvasKey: false}, overrides: [_scripts(const [])]);
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    await _chat(
      tester,
      prefs: {TavernSettingsController.canvasKey: false, TavernSettingsController.islandNoScriptsKey: true},
      overrides: [override],
    );
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    await _chat(
      tester,
      prefs: {TavernSettingsController.canvasKey: false, 'tavern.layout': 'visualNovel'},
      overrides: [override],
    );
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    // On: they run, nothing to say.
    await _chat(tester, overrides: [override]);
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
  });

  test('the setting is off until chosen, and kept', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(tavernSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(tavernSettingsProvider).canvas, isFalse);
    await container.read(tavernSettingsProvider.notifier).setCanvas(true);
    expect(container.read(tavernSettingsProvider).canvas, isTrue);
    expect((await SharedPreferences.getInstance()).getBool(TavernSettingsController.canvasKey), isTrue);
  });
}
