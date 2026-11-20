import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/tavern/deferred_tavern.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_character_page.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_home_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Widget _app() => ProviderScope(
  overrides: [tavernProvider.overrideWith((ref) => PreviewTavern(tick: const Duration(milliseconds: 1)))],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const TavernHomePage(),
  ),
);

/// Lets a preview reply stream to the end.
Future<void> _finishReply(WidgetTester tester) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the home lists the characters', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('酒馆'), findsWidgets);
    expect(find.text('林晚'), findsOneWidget);
    expect(find.text('星图'), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-continue')), findsNothing);
  });

  testWidgets('start a chat, send a line, swipe to a new reply', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tavern-character-sample-innkeeper')));
    await tester.pumpAndSettle();
    expect(find.text('开场白 1/2'), findsOneWidget);

    // To the middle: scrolled to the top it would sit under the glass header.
    unawaited(Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('tavern-start'))), alignment: 0.5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-start')));
    await tester.pumpAndSettle();
    expect(find.byType(TavernChatPage), findsOneWidget);
    expect(find.textContaining('炉子还热着'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _finishReply(tester);

    expect(find.text('外面怎么了？'), findsOneWidget);
    expect(find.textContaining('地下室'), findsOneWidget);
    expect(find.text('1/1'), findsNothing); // one version: only ↻

    // Past the last alternative, › writes a new one.
    await tester.tap(find.byKey(const ValueKey('tavern-next')).first);
    await _finishReply(tester);
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tavern-prev')).first);
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsNWidgets(2)); // the greeting and the reply
    expect(find.textContaining('地下室'), findsOneWidget);
  });

  testWidgets('swiping the reply sideways steps through its alternatives', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-character-sample-innkeeper')));
    await tester.pumpAndSettle();
    // To the middle: scrolled to the top it would sit under the glass header.
    unawaited(Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('tavern-start'))), alignment: 0.5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-start')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await _finishReply(tester);
    expect(find.text('1/1'), findsNothing); // one version: only ↻

    // Left past the last alternative writes a new one.
    await tester.drag(find.textContaining('地下室'), const Offset(-200, 0));
    await _finishReply(tester);
    expect(find.text('2/2'), findsOneWidget);

    // Right goes back to the first. The list is newest first: .first is the reply.
    final swipes = find.byWidgetPredicate(
      (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('tavern-swipe-'),
    );
    await tester.drag(swipes.first, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('地下室'), findsOneWidget);
    expect(find.text('1/2'), findsNWidgets(2)); // the greeting and the reply
  });

  testWidgets('long-press a character to delete it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('tavern-character-sample-navigator')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除角色'));
    await tester.pumpAndSettle();
    expect(find.text('删除「星图」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('星图'), findsNothing);
    expect(find.text('林晚'), findsOneWidget);
  });

  testWidgets('search and tags narrow the characters', (tester) async {
    TavernHomePage.searchFrom = 2;
    addTearDown(() => TavernHomePage.searchFrom = 6);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '星');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-navigator')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('悬疑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-character-sample-navigator')), findsNothing);

    await tester.enterText(find.byType(TextField), '没有这个人');
    await tester.pumpAndSettle();
    expect(find.text('没有符合的角色'), findsOneWidget);
  });

  testWidgets('tags show on a small shelf, without one every card has', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    // Two characters: no search yet, but the tags that split them.
    expect(find.byKey(const ValueKey('tavern-search')), findsNothing);
    final tags = find.byKey(const ValueKey('tavern-tags'));
    expect(find.descendant(of: tags, matching: find.text('悬疑')), findsOneWidget);
    expect(find.descendant(of: tags, matching: find.text('科幻')), findsOneWidget);
    // Both are 示例: picking it would narrow nothing.
    expect(find.descendant(of: tags, matching: find.text('示例')), findsNothing);

    await tester.tap(find.descendant(of: tags, matching: find.text('科幻')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-navigator')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsNothing);
    await tester.tap(find.descendant(of: tags, matching: find.text('全部')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-character-sample-innkeeper')), findsOneWidget);
  });

  testWidgets('a chat to continue shows when it was last touched', (tester) async {
    final tavern = PreviewTavern(tick: const Duration(milliseconds: 1));
    await tavern.createChat('sample-navigator');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tavernProvider.overrideWith((ref) => tavern)],
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
    expect(find.byKey(const ValueKey('tavern-continue')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-continue')), matching: find.text('刚刚')),
      findsOneWidget,
    );
  });

  testWidgets('a tavern that could not open says so, and retry opens it again', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tavernProvider.overrideWith(
            (ref) => ++opens == 1
                ? DeferredTavern(Future<Tavern>.error(StateError('no sqlite')))
                : PreviewTavern(tick: const Duration(milliseconds: 1)),
          ),
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

    expect(find.byKey(const ValueKey('tavern-open-failed')), findsOneWidget);
    expect(find.text('酒馆没能打开'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(opens, 2);
    expect(find.byKey(const ValueKey('tavern-open-failed')), findsNothing);
    expect(find.text('林晚'), findsOneWidget);
  });

  testWidgets('an empty tavern offers the sample card, and trying it opens the card', (tester) async {
    final tavern = _Importing();
    await tavern.deleteCharacter('sample-innkeeper');
    await tavern.deleteCharacter('sample-navigator');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tavernProvider.overrideWith((ref) => tavern)],
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
    expect(find.text('还没有角色'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tavern-try-sample')));
    await tester.pumpAndSettle();

    expect(tavern.imported.single.fileName, 'sample_innkeeper.json');
    final card = jsonDecode(utf8.decode(tavern.imported.single.bytes)) as Map<String, Object?>;
    expect(card['spec'], 'chara_card_v3');
    expect((card['data']! as Map)['name'], '林晚');
    expect(find.byType(TavernCharacterPage), findsOneWidget);
  });
}

/// The preview, accepting a card import.
class _Importing extends PreviewTavern {
  _Importing() : super(tick: const Duration(milliseconds: 1));

  final imported = <({String? fileName, Uint8List bytes})>[];

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async {
    imported.add((fileName: fileName, bytes: bytes));
    return TavernCharacter(id: 'imported', name: '林晚', greetings: const [], importedAt: DateTime.now());
  }
}
