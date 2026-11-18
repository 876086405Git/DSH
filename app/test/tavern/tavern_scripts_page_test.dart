import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_files.dart';
import 'package:dsh_app/ui/tavern/tavern_scripts_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart' show TavernChatFile;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// A 酒馆助手 export: a folder with one script, and one script on its own.
final _export = jsonEncode([
  {
    'type': 'folder',
    'id': 'f1',
    'name': '工具',
    'enabled': true,
    'scripts': [
      {'type': 'script', 'id': 's2', 'name': '掷骰', 'enabled': true, 'content': 'y'},
    ],
  },
  {'type': 'script', 'id': 's1', 'name': '状态栏', 'enabled': true, 'content': 'x'},
]);

Future<List<List<TavernChatFile>>> _open(WidgetTester tester, PreviewTavern tavern) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final shared = <List<TavernChatFile>>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        tavernChatPickerProvider.overrideWithValue(
          () async => [TavernChatFile(fileName: 'scripts.json', bytes: Uint8List.fromList(utf8.encode(_export)))],
        ),
        tavernChatSinkProvider.overrideWithValue((files) async => shared.add(files)),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const TavernScriptsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return shared;
}

void main() {
  testWidgets('imported, the library lists its tree; a script turned off, a folder opened, one deleted', (
    tester,
  ) async {
    final tavern = PreviewTavern(tick: Duration.zero);
    final shared = await _open(tester, tavern);
    expect(find.byKey(const ValueKey('tavern-scripts-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tavern-scripts-import')));
    await tester.pumpAndSettle();
    expect(find.text('2 个脚本加入了脚本库'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('状态栏'), findsOneWidget);

    // Off: it says so, and the chat no longer runs it.
    await tester.tap(find.byKey(const ValueKey('tavern-script-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('停用'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-script-s1')), matching: find.text('关')),
      findsOneWidget,
    );
    expect([for (final s in (await tavern.chatScripts('c')).scripts) s.owner.scriptId], ['s2']);

    // Exported as the engine gives it.
    await tester.tap(find.byKey(const ValueKey('tavern-script-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();
    expect(shared.single.single.fileName, '状态栏.json');
    expect(jsonDecode(utf8.decode(shared.single.single.bytes)), containsPair('enabled', false));

    // A folder opens on its own scripts.
    await tester.tap(find.byKey(const ValueKey('tavern-script-f1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开文件夹'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-script-s2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tavern-script-s2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-script-s2')), findsNothing);
    expect(tavernScriptCount(await tavern.listGlobalScripts()), 1);
  });
}
