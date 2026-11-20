import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_slash.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, noting which reply was regenerated or continued.
class _Noting extends PreviewTavern {
  _Noting() : super(tick: const Duration(milliseconds: 1));

  final calls = <String>[];

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) {
    calls.add('regen $nodeId');
    return super.regenerate(chatId, nodeId);
  }

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) {
    calls.add('continue $nodeId');
    return super.continueReply(chatId, nodeId);
  }
}

Future<(_Noting, String)> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final tavern = _Noting();
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
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
  return (tavern, chat);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.bySemanticsLabel('发送'));
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
}

void main() {
  test('a slash command is known by its word; anything else is a line', () {
    expect(tavernSlashOf('/sys 雨停了。'), (command: TavernSlash.narrate, rest: '雨停了。'));
    expect(tavernSlashOf('/NAR\n门开了'), (command: TavernSlash.narrate, rest: '门开了'));
    expect(tavernSlashOf('  /send 你好  '), (command: TavernSlash.sendOnly, rest: '你好'));
    expect(tavernSlashOf('/continue'), (command: TavernSlash.continueReply, rest: ''));
    expect(tavernSlashOf('/regen'), (command: TavernSlash.regenerate, rest: ''));
    expect(tavernSlashOf('/imp'), (command: TavernSlash.impersonate, rest: ''));
    for (final line in ['/sys', '/send   ', '/regen now', '/hello there', 'a /sys b', '/', '//sys x', '你好']) {
      expect(tavernSlashOf(line), isNull, reason: line);
    }
  });

  testWidgets('a slash in the box shows the commands; one picked fills the box', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('tavern-slash-row')), findsNothing);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('tavern-slash-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-quick-replies')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tavern-slash-sys')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '/sys ');
  });

  testWidgets('/sys narrates and /send goes in as yours, neither with a reply', (tester) async {
    final (tavern, chat) = await _open(tester);
    await _send(tester, '/sys 雨停了。');
    await _send(tester, '/send 我把伞收起来。');
    final path = (await tester.runAsync(() => tavern.path(chat)))!;
    expect(path.map((m) => (m.role, m.text)).skip(1), [(TavernRole.narrator, '雨停了。'), (TavernRole.user, '我把伞收起来。')]);
  });

  testWidgets('/regen and /continue act on the latest reply; an unknown one is a line', (tester) async {
    final (tavern, chat) = await _open(tester);
    final greeting = (await tester.runAsync(() => tavern.path(chat)))!.single.nodeId;
    await _send(tester, '/continue');
    expect(tavern.calls, ['continue $greeting']);
    await _send(tester, '/regen');
    expect(tavern.calls.last, startsWith('regen '));

    await _send(tester, '/hello 你好');
    final path = (await tester.runAsync(() => tavern.path(chat)))!;
    expect(path.where((m) => m.role == TavernRole.user).single.text, '/hello 你好');
  });

  testWidgets('a reply being continued keeps what it said while the rest comes', (tester) async {
    final (tavern, chat) = await _open(tester);
    final greeting = (await tester.runAsync(() => tavern.path(chat)))!.single;
    final opening = greeting.text.trim().split('\n').first.replaceAll('*', '').substring(0, 6);
    await tester.enterText(find.byType(TextField), '/continue');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('发送'));
    // Part way: the added words have begun, the old ones are still there.
    final row = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_StreamingReply' && w.key == ValueKey('stream-${greeting.nodeId}'),
    );
    for (var i = 0; i < 200 && row.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining(opening, findRichText: true)), findsWidgets);
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    await tester.pumpAndSettle();
  });
}
