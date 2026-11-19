import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/tavern/tavern_file_kind.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_quick_replies.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_files.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/tavern/tavern_report_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Uint8List _bytes(Object json, {bool bom = false}) => Uint8List.fromList([
  if (bom) ...[0xEF, 0xBB, 0xBF],
  ...utf8.encode(jsonEncode(json)),
]);

TavernChatFile _file(String name, Object json) => TavernChatFile(fileName: name, bytes: _bytes(json));

final _preset = {
  'temperature': 1.0,
  'openai_max_context': 16384,
  'prompts': [
    {'identifier': 'main', 'name': '主提示', 'content': '你是{{char}}。'},
  ],
};

final _helperScript = {'type': 'script', 'id': 's1', 'name': '状态栏', 'enabled': true, 'content': 'x'};

final _quickReplies = {
  'version': 2,
  'name': '常用',
  'qrList': [
    {'id': 1, 'label': '看看四周', 'message': '我看了看四周。'},
    {'id': 2, 'label': '生成', 'message': '/gen 继续'},
    {'id': 3, 'label': '空', 'message': '  '},
  ],
};

/// An ST chat: its header line names 林晚, then one message.
TavernChatFile _chat(String character) => TavernChatFile(
  fileName: 'chat.jsonl',
  bytes: Uint8List.fromList(
    utf8.encode(
      '${jsonEncode({'user_name': 'User', 'character_name': character})}\n'
      '${jsonEncode({'name': character, 'is_user': false, 'mes': '你来了。', 'send_date': '2026-11-11'})}\n',
    ),
  ),
);

/// The preview, which records chats brought over instead of refusing them.
class _Importing extends PreviewTavern {
  _Importing() : super(tick: Duration.zero);

  final chats = <(String, String)>[];

  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async {
    for (final f in files) {
      chats.add((characterId, f.fileName));
    }
    return TavernChatImportResult(chatIds: ['imported'], chatsByFile: {files.first.fileName: 'imported'}, notices: []);
  }
}

Future<ProviderContainer> _home(WidgetTester tester, PreviewTavern tavern, List<TavernChatFile> picked) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        tavernChatPickerProvider.overrideWithValue(() async => picked),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const TavernHomePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(TavernHomePage)));
}

Future<void> _importFromFile(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('tavern-import')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('tavern-import-file')));
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  test('a picked file is told by its name and contents', () {
    TavernFileKind kind(String name, Object json, {bool bom = false}) => tavernFileKindOf(name, _bytes(json, bom: bom));
    expect(
      kind('a.json', {
        'spec': 'chara_card_v2',
        'data': {'name': 'A', 'first_mes': 'hi'},
      }),
      TavernFileKind.card,
    );
    expect(kind('a.json', {'name': 'A', 'first_mes': 'hi'}), TavernFileKind.card);
    expect(kind('a.json', _preset), TavernFileKind.preset);
    expect(kind('a.dsh-preset.json', {'format': 'dsh-preset-enhance', 'version': 1}), TavernFileKind.preset);
    expect(
      kind('world.json', {
        'entries': {
          '0': {
            'key': ['x'],
            'content': 'y',
          },
        },
      }),
      TavernFileKind.lorebook,
    );
    expect(
      kind('book.json', {
        'spec': 'lorebook_v3',
        'data': {'entries': []},
      }),
      TavernFileKind.lorebook,
    );
    expect(kind('r.json', {'scriptName': 'x', 'findRegex': '/a/g'}), TavernFileKind.regex);
    expect(
      kind('r.json', [
        {'findRegex': '/a/'},
        {'findRegex': '/b/'},
      ]),
      TavernFileKind.regex,
    );
    expect(kind('qr.json', _quickReplies), TavernFileKind.quickReplies);
    // 酒馆助手's scripts: one, a folder of them, or a list of either.
    expect(kind('s.json', _helperScript), TavernFileKind.helperScripts);
    final folder = {
      'type': 'folder',
      'id': 'f1',
      'name': '工具',
      'scripts': [_helperScript],
    };
    expect(kind('f.json', folder), TavernFileKind.helperScripts);
    expect(kind('all.json', [folder, _helperScript]), TavernFileKind.helperScripts);
    expect(kind('a.json', {'type': 'script', 'name': 'no code'}), TavernFileKind.unknown);
    expect(kind('a.json', _preset, bom: true), TavernFileKind.preset);
    expect(kind('a.json', {'hello': 1}), TavernFileKind.unknown);
    expect(kind('a.json', [1, 2]), TavernFileKind.unknown);

    expect(tavernFileKindOf('a.charx', Uint8List(4)), TavernFileKind.card);
    expect(tavernFileKindOf('c.jsonl', Uint8List(0)), TavernFileKind.chat);
    expect(tavernFileKindOf('notes.txt', Uint8List.fromList(utf8.encode('just words'))), TavernFileKind.unknown);
    // A PNG is a card only with a chara / ccv3 text chunk.
    final png = Uint8List.fromList([
      0x89,
      ...'PNG'.codeUnits,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      9,
      ...'tEXtchara\u0000eyJ9'.codeUnits,
    ]);
    expect(tavernFileKindOf('card.png', png), TavernFileKind.card);
    expect(
      tavernFileKindOf('photo.png', Uint8List.fromList([0x89, ...'PNG'.codeUnits, ...List.filled(20, 0)])),
      TavernFileKind.unknown,
    );
  });

  test("an ST chat names its character; a quick reply set gives its messages, not ST's commands", () {
    expect(tavernChatCharacterName(_chat('林晚').bytes), '林晚');
    expect(tavernChatCharacterName(Uint8List.fromList(utf8.encode('not json'))), isNull);
    final (:replies, :skipped) = tavernQuickRepliesOf(_bytes(_quickReplies));
    expect(replies, ['我看了看四周。']);
    expect(skipped, 1);
  });

  testWidgets('one preset from a file goes to the library, and its 体检 opens', (tester) async {
    final tavern = _Importing();
    await _home(tester, tavern, [_file('长篇小说.json', _preset)]);
    await _importFromFile(tester);
    final presets = (await tester.runAsync(() => tavern.watchPresets().first))!;
    expect(presets.map((p) => p.name), ['长篇小说']);
    expect(find.byType(TavernImportReportPage), findsOneWidget);
  });

  testWidgets('several files at once each go where they belong', (tester) async {
    final tavern = _Importing();
    final container = await _home(tester, tavern, [
      _file('长篇小说.json', _preset),
      _file('常用.json', _quickReplies),
      _chat('林晚'),
      _chat('不在书架上'),
      _file('状态栏.json', _helperScript),
      TavernChatFile(fileName: 'notes.txt', bytes: Uint8List.fromList(utf8.encode('hello'))),
    ]);
    await _importFromFile(tester);

    expect((await tester.runAsync(() => tavern.watchPresets().first))!.map((p) => p.name), ['长篇小说']);
    expect((await tester.runAsync(tavern.listGlobalScripts))!.map((s) => s.name), ['状态栏']);
    expect(container.read(tavernQuickRepliesProvider), ['我看了看四周。']);
    // The chat naming 林晚 went to her; the other found no one.
    expect(tavern.chats, [('sample-innkeeper', 'chat.jsonl')]);
    // Several files: no report page in the way.
    expect(find.byType(TavernImportReportPage), findsNothing);
    expect(find.byType(TavernHomePage), findsOneWidget);
  });
}
