import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, a piece of the reply every 20 ms, counting the pieces.
class _Counted extends PreviewTavern {
  _Counted() : super(tick: const Duration(milliseconds: 20));

  int pieces = 0;

  @override
  Stream<TavernEvent> send(String chatId, String text) => super.send(chatId, text).map((event) {
    if (event is TavernTextDelta) pieces++;
    return event;
  });
}

Future<void> _open(
  WidgetTester tester,
  PreviewTavern tavern, {
  Map<String, Object> prefs = const {},
  Size size = const Size(390, 844),
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = size * 2;
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
}

/// Sends a line and lets the whole reply arrive, a frame for each piece;
/// returns how many times a message row was rebuilt meanwhile.
Future<int> _sendCountingRows(WidgetTester tester) async {
  var rows = 0;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget.runtimeType.toString() == '_MessageRow') rows++;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = null);
  await tester.enterText(find.byType(TextField), '外面怎么了？');
  await tester.pump();
  await tester.tap(find.byIcon(AppIcons.send));
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
  debugOnRebuildDirtyWidget = null;
  return rows;
}

void main() {
  testWidgets('a reply that grows past the top shades the header, though nothing was scrolled', (tester) async {
    // Short enough that the reply outgrows it; the list stays at its newest end.
    await _open(tester, _Counted(), size: const Size(390, 420));
    double shade() => tester.widget<BotChatHeader>(find.byType(BotChatHeader)).scrolledUnder!.value;
    expect(shade(), 0);

    await _sendCountingRows(tester);
    expect(find.textContaining('地下室'), findsOneWidget);
    expect(shade(), greaterThan(0));

    // Scrolled back to the oldest message, and pulled past it: still shaded.
    await tester.drag(find.byKey(const ValueKey('tavern-transcript')), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(shade(), 1);
  });

  testWidgets('a piece of the reply rebuilds the reply, not the messages above it', (tester) async {
    final tavern = _Counted();
    await _open(tester, tavern);
    final rows = await _sendCountingRows(tester);

    expect(find.textContaining('地下室'), findsOneWidget); // the whole reply arrived
    expect(tavern.pieces, greaterThan(10));
    // The rows rebuild when the turn starts, settles and ends, not once per
    // piece (two rows on screen, a rebuild each piece, would be twice the pieces).
    expect(rows, lessThan(tavern.pieces));
  });

  testWidgets('in 视觉小说 the page being written still follows the reply', (tester) async {
    final tavern = _Counted();
    await _open(tester, tavern, prefs: {'tavern.layout': 'visualNovel'});
    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    // Part way: the reply's first page is there, still being written.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.textContaining('这个问题', findRichText: true), findsWidgets);
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('地下室', findRichText: true), findsWidgets);
  });
}
