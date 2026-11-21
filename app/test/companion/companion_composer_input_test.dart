// The composer owns its own text: a key rebuilds it, not her room. The send /
// stop / voice key follows the field (a composing IME included) and a clear.

import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildDarkTheme(),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('zh'),
    home: Scaffold(
      body: Align(alignment: Alignment.bottomCenter, child: child),
    ),
  ),
);

/// Counts its own builds: what the composer must not drag along.
class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.child});

  final Widget child;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int builds = 0;

  @override
  Widget build(BuildContext context) {
    builds++;
    return widget.child;
  }
}

void main() {
  testWidgets('typing builds the composer alone, and its key follows the text', (tester) async {
    final input = TextEditingController();
    final focus = FocusNode();
    addTearDown(input.dispose);
    addTearDown(focus.dispose);
    var sent = 0;
    final probe = GlobalKey<_ProbeState>();
    Widget composer() => _app(
      _Probe(
        key: probe,
        child: CompanionComposer(
          input: input,
          focus: focus,
          hint: '和她说点什么',
          running: false,
          busy: false,
          listening: false,
          voiceAvailable: true,
          onSend: () => sent++,
          onStop: () {},
          onVoice: () {},
        ),
      ),
    );
    await tester.pumpWidget(composer());
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final parentBuilds = probe.currentState!.builds;

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    // The page around the composer is not built for a key.
    expect(probe.currentState!.builds, parentBuilds);

    // An IME still composing counts as text: the key can send it.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'nihao', composing: TextRange(start: 0, end: 5)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(probe.currentState!.builds, parentBuilds);

    await tester.pump(const Duration(milliseconds: 300)); // The key's switch.
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    expect(sent, 1);

    // Cleared: her voice key is back, still without the page.
    input.clear();
    await tester.pump();
    // The key's switch-out animation keeps the old key a moment.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('send')), findsNothing);
    expect(find.byKey(const ValueKey('voice')), findsOneWidget);
    expect(probe.currentState!.builds, parentBuilds);
  });

  testWidgets('while she answers the key is stop until the person writes again', (tester) async {
    final input = TextEditingController();
    final focus = FocusNode();
    addTearDown(input.dispose);
    addTearDown(focus.dispose);
    var stopped = 0;
    await tester.pumpWidget(
      _app(
        CompanionComposer(
          input: input,
          focus: focus,
          hint: '和她说点什么',
          running: true,
          busy: false,
          listening: false,
          voiceAvailable: true,
          onSend: () {},
          onStop: () => stopped++,
          onVoice: () {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('stop')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('stop')));
    await tester.pump();
    expect(stopped, 1);

    // Typing takes the key back: stop is for nobody writing.
    await tester.enterText(find.byType(TextField), '等等');
    await tester.pump();
    // Let the stop key's switch-out animation finish before the negative read.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
    expect(find.byKey(const ValueKey('stop')), findsNothing);
  });
}
