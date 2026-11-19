import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/companion/companion_log.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/tavern/tavern_vn_view.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

const _box = ValueKey('tavern-vn-box');

Widget _app(Widget home, {PreviewTavern? tavern}) => ProviderScope(
  overrides: [if (tavern != null) tavernProvider.overrideWith((ref) => tavern)],
  child: MaterialApp(
    theme: withTestFonts(buildLightTheme()),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: home,
  ),
);

/// The sample chat in 视觉小说, its greeting's two pages, the newest showing.
Future<void> _open(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({'tavern.layout': 'visualNovel', ...prefs});
  final tavern = PreviewTavern(tick: const Duration(milliseconds: 1));
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(TavernChatPage(chatId: chat), tavern: tavern));
  await tester.pumpAndSettle();
  expect(find.text('2/2'), findsOneWidget);
}

/// Back to the first page: stepping back shows a page whole.
Future<void> _back(WidgetTester tester) async {
  await tester.fling(find.byKey(_box), const Offset(300, 0), 1000);
  await tester.pumpAndSettle();
  expect(find.text('1/2'), findsOneWidget);
}

Iterable<MarkdownBody> _bodies(WidgetTester tester) =>
    tester.widgetList<MarkdownBody>(find.descendant(of: find.byKey(_box), matching: find.byType(MarkdownBody)));

/// The part typed so far, or null when the page shows whole.
String? _typed(WidgetTester tester) => _bodies(tester).where((b) => b.streaming).map((b) => b.text).firstOrNull;

/// The page whole (the last: the page left may still be fading out).
String _whole(WidgetTester tester) => _bodies(tester).lastWhere((b) => !b.streaming).text;

void main() {
  testWidgets('the next page is typed out; a tap while it types shows it whole', (tester) async {
    await _open(tester);
    expect(_typed(tester), isNull); // what was there on opening shows whole
    await _back(tester);
    expect(_typed(tester), isNull);

    await tester.tap(find.byKey(_box));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('2/2'), findsOneWidget);
    final typed = _typed(tester)!;
    final whole = _whole(tester);
    expect(typed.length, lessThan(whole.length));
    expect(whole.startsWith(typed), isTrue);

    await tester.tap(find.byKey(_box));
    await tester.pump();
    expect(_typed(tester), isNull);
    expect(find.text('2/2'), findsOneWidget); // the tap only finished the page
    await tester.pumpAndSettle();
  });

  testWidgets('left alone, the page finishes typing', (tester) async {
    await _open(tester);
    await _back(tester);
    await tester.tap(find.byKey(_box));
    await tester.pump();
    expect(_typed(tester), isNotNull);
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    expect(_typed(tester), isNull);
  });

  testWidgets('typing builds the typed words again, not the stage around them', (tester) async {
    await _open(tester);
    await _back(tester);
    var views = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is TavernVisualNovelView) views++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await tester.tap(find.byKey(_box));
    String? last;
    var typed = 0;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = _typed(tester);
      if (now != null && now != last) typed++;
      last = now;
    }
    debugOnRebuildDirtyWidget = null;
    expect(typed, greaterThan(10));
    expect(views, lessThan(5));
    await tester.pumpAndSettle();
  });

  testWidgets('自动 turns the page once it has been read', (tester) async {
    await _open(tester);
    await _back(tester);
    await tester.tap(find.byKey(const ValueKey('tavern-vn-auto')));
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(tester.getSemantics(find.byKey(const ValueKey('tavern-vn-auto'))), isSemantics(isToggled: true));

    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_typed(tester), isNull);
  });

  testWidgets('paging back hides the header and the box; the newest page brings them back', (tester) async {
    bool hidden(String key) => tester
        .widget<IgnorePointer>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(IgnorePointer)).first,
        )
        .ignoring;
    await _open(tester);
    expect(hidden('tavern-chrome-top'), isFalse);
    expect(hidden('tavern-chrome-bottom'), isFalse);

    await _back(tester);
    expect(hidden('tavern-chrome-top'), isTrue);
    expect(hidden('tavern-chrome-bottom'), isTrue);

    await tester.tap(find.byKey(const ValueKey('tavern-vn-skip')));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(hidden('tavern-chrome-top'), isFalse);
    expect(hidden('tavern-chrome-bottom'), isFalse);
  });

  testWidgets("the backlog follows the story's look, not 伙伴小屋's night blue", (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('tavern-vn-log')));
    await tester.pumpAndSettle();
    final log = tester.widget<CompanionLog>(find.byType(CompanionLog));
    final theme = Theme.of(tester.element(find.byType(CompanionLog)));
    expect(theme.brightness, Brightness.light); // the app's, not a dark theme laid over it
    expect(log.scrim, isNotNull);
    expect(log.scrim!.first.withValues(alpha: 1), theme.colorScheme.surface.withValues(alpha: 1));
    expect(log.herTone, theme.colorScheme.primary);
  });

  testWidgets('跳过 goes to the newest page, whole; on it there is nothing to skip', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('tavern-vn-skip')), findsNothing);
    await _back(tester);
    await tester.tap(find.byKey(const ValueKey('tavern-vn-skip')));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(_typed(tester), isNull);
    expect(find.byKey(const ValueKey('tavern-vn-skip')), findsNothing);
  });

  testWidgets('at 立即 each page shows whole', (tester) async {
    await _open(tester, prefs: {TavernSettingsController.textSpeedKey: 'instant'});
    await _back(tester);
    await tester.tap(find.byKey(_box));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(_typed(tester), isNull);
  });

  test('a tag, an image or a link is typed at once, whole', () {
    const text = '她<b>笑</b>了![图](a.png)';
    final cuts = tavernTypingCuts(text);
    final pieces = [for (final c in cuts) text.substring(0, c)];
    expect(pieces, ['她', '她<b>', '她<b>笑', '她<b>笑</b>', '她<b>笑</b>了', '她<b>笑</b>了![图](a.png)']);
    // Characters, not code units: an emoji is never cut in half.
    expect(tavernTypingCuts('a👋🏽b'), ['a'.length, 'a👋🏽'.length, 'a👋🏽b'.length]);
  });

  testWidgets('酒馆设置 picks the speed, kept', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const TavernSettingsPage()));
    await tester.pumpAndSettle();
    // Further down the (lazy) list than it is built at first.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tavern-text-speed')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('tavern-text-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-text-speed')), matching: find.text('快')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TavernSettingsController.textSpeedKey), 'fast');
    expect(TavernTextSpeed.fast.charactersPerSecond, greaterThan(TavernTextSpeed.normal.charactersPerSecond!));
  });
}
