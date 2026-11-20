import 'dart:async';

import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_quick_replies.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_reading.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

Future<void> _open(WidgetTester tester, PreviewTavern tavern, Widget home) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
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

/// The body style the story's text is drawn with, under [of].
TextStyle _story(WidgetTester tester, Finder of) =>
    Theme.of(tester.element(find.descendant(of: of, matching: find.byType(MarkdownBody)).first)).textTheme.bodyLarge!;

void main() {
  test('the story starts a step smaller and tighter than the app', () {
    const s = TavernSettings();
    expect(s.textSize, 15);
    expect(s.lineHeight, 1.5);
  });

  test('the reading theme is one object per size and spacing', () {
    final base = buildLightTheme();
    final a = tavernReadingTheme(base, size: 14, height: 1.5);
    expect(identical(a, tavernReadingTheme(base, size: 14, height: 1.5)), isTrue);
    expect(a.textTheme.bodyLarge!.fontSize, 14);
    expect(a.textTheme.bodyLarge!.height, 1.5);
    expect(identical(a, tavernReadingTheme(base, size: 16, height: 1.5)), isFalse);
  });

  testWidgets('酒馆设置 sets the story\'s size and spacing, kept, and the chat reads by them', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tavern = PreviewTavern(tick: Duration.zero);
    await _open(tester, tavern, const TavernSettingsPage());

    final preview = find.byKey(const ValueKey('tavern-reading-preview'));
    // Further down the (lazy) list than it is built at first.
    await tester.scrollUntilVisible(preview, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(preview);
    await tester.pumpAndSettle();
    expect(_story(tester, preview).fontSize, 15);

    // Each row to the middle first: on this short window the others pass
    // under the glass header.
    Future<void> pick(String row, String label) async {
      unawaited(Scrollable.ensureVisible(tester.element(find.byKey(ValueKey(row))), alignment: 0.5));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byKey(ValueKey(row)), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    await pick('tavern-text-size', '小');
    await pick('tavern-line-height', '宽松');
    expect(_story(tester, preview).fontSize, 14);
    expect(_story(tester, preview).height, 1.8);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(TavernSettingsController.textSizeKey), 14);
    expect(prefs.getDouble(TavernSettingsController.lineHeightKey), 1.8);

    final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
    await _open(tester, tavern, TavernChatPage(chatId: chat));
    expect(_story(tester, find.byKey(const ValueKey('tavern-transcript'))).fontSize, 14);
  });

  testWidgets('only the newest reply has ‹ ›; an older one with others shows a count', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tavern = PreviewTavern(tick: Duration.zero);
    final chat = (await tester.runAsync(() async {
      final id = await tavern.createChat('sample-innkeeper');
      await tavern.send(id, '外面怎么了？').drain<void>();
      return id;
    }))!;
    await _open(tester, tavern, TavernChatPage(chatId: chat));

    // The greeting has two (1/2) and is older: its count, no keys.
    expect(find.text('1/2'), findsOneWidget);
    // The reply has one version: no ‹ and no 1/1, only ↻.
    expect(find.byKey(const ValueKey('tavern-prev')), findsNothing);
    expect(find.text('1/1'), findsNothing);
    expect(find.byKey(const ValueKey('tavern-next')), findsOneWidget);
  });

  testWidgets('the chips fold away while you read back, and come back to type', (tester) async {
    SharedPreferences.setMockInitialValues({
      TavernQuickReplies.key: ['你叫什么名字？'],
    });
    final tavern = PreviewTavern(tick: Duration.zero);
    final chat = (await tester.runAsync(() async {
      final id = await tavern.createChat('sample-innkeeper');
      for (var i = 0; i < 6; i++) {
        await tavern.send(id, '第 $i 问：外面怎么了？').drain<void>();
      }
      return id;
    }))!;
    await _open(tester, tavern, TavernChatPage(chatId: chat));
    expect(find.byKey(const ValueKey('tavern-quick-replies')), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('tavern-transcript')), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-quick-replies')), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-quick-replies')), findsOneWidget);

    // Back at the newest lines they stay too.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.drag(find.byKey(const ValueKey('tavern-transcript')), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-quick-replies')), findsOneWidget);
  });
}
