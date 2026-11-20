import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_arrive.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

const _transcript = ValueKey('tavern-transcript');

Future<void> _open(WidgetTester tester, PreviewTavern tavern) async {
  SharedPreferences.setMockInitialValues({});
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
}

/// The fades of the transcript's rows that arrived.
List<FadeTransition> _fades(WidgetTester tester) => [
  for (final row in find.descendant(of: find.byKey(_transcript), matching: find.byType(TavernArrive)).evaluate())
    if (_built(row) case final FadeTransition fade) fade,
];

Widget? _built(Element element) {
  Widget? built;
  element.visitChildElements((child) => built = child.widget);
  return built;
}

void main() {
  testWidgets('what is there on opening just is; a line sent and its reply fade in once', (tester) async {
    await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 20)));
    expect(find.byKey(_transcript), findsOneWidget);
    expect(_fades(tester), isEmpty);

    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    // Your line, and the reply's row before its words, fading in.
    await tester.pump(const Duration(milliseconds: 20));
    expect(_fades(tester).map((f) => f.opacity.value), [lessThan(1), lessThan(1)]);

    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('地下室'), findsOneWidget);
    // Your line faded in; the reply, written live and then in, did not play again.
    final fades = _fades(tester);
    expect(fades, hasLength(1));
    expect(fades.single.opacity.value, 1);
    expect(find.descendant(of: find.byWidget(fades.single), matching: find.text('外面怎么了？')), findsOneWidget);
    expect(fades.single.child, isA<AnimatedBuilder>()); // it rose too

    // Another reply, then back to the first: it only fades in where the other was.
    await tester.tap(find.byKey(const ValueKey('tavern-next')));
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tavern-prev')));
    // The greeting has two as well: until both say 1/2.
    for (var i = 0; i < 20 && find.text('1/2').evaluate().length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    final swapped = _fades(tester).where((f) => f.opacity.value < 1).single;
    expect(swapped.child, isA<RepaintBoundary>());
    expect(find.descendant(of: find.byWidget(swapped), matching: find.textContaining('地下室')), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a reply being continued does not fade in again', (tester) async {
    await _open(tester, PreviewTavern(tick: const Duration(milliseconds: 20)));
    await tester.enterText(find.byType(TextField), '/continue');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    // The greeting goes on as it is written: its row was there, it does not arrive.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      expect(_fades(tester).where((f) => f.opacity.value < 1), isEmpty);
    }
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
  });

  testWidgets('with motion reduced nothing fades', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester, PreviewTavern(tick: Duration.zero));
    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();
    expect(_fades(tester), isEmpty);
    await tester.pumpAndSettle();
    expect(_fades(tester), isEmpty);
  });
}
