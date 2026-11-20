import 'package:dsh_app/ui/tavern/tavern_arrive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _row(List<String> items, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Row(
      children: [for (final (i, item) in items.indexed) TavernArrive(key: ValueKey(item), index: i, child: Text(item))],
    ),
  ),
);

/// How far [text] has faded in: 1 when nothing fades it.
double _shown(WidgetTester tester, String text) {
  final fades = find.ancestor(of: find.text(text), matching: find.byType(FadeTransition));
  return fades.evaluate().isEmpty ? 1 : tester.widget<FadeTransition>(fades.first).opacity.value;
}

void main() {
  testWidgets('siblings fade in one beat apart, then stay', (tester) async {
    await tester.pumpWidget(_row(['A', 'B', 'C']));
    expect(_shown(tester, 'A'), 0);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_shown(tester, 'A'), greaterThan(_shown(tester, 'B')));
    expect(_shown(tester, 'B'), greaterThan(0));
    expect(_shown(tester, 'C'), 0); // still waiting its turn
    await tester.pumpAndSettle();
    expect([_shown(tester, 'A'), _shown(tester, 'B'), _shown(tester, 'C')], [1, 1, 1]);

    // Built again, the same ones do not play again; a new one does.
    await tester.pumpWidget(_row(['A', 'B', 'D']));
    expect(_shown(tester, 'A'), 1);
    expect(_shown(tester, 'D'), 0);
    await tester.pumpAndSettle();
    expect(_shown(tester, 'D'), 1);
  });

  testWidgets('with motion reduced they are there at once', (tester) async {
    await tester.pumpWidget(_row(['A', 'B'], reduced: true));
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.text('B'), findsOneWidget);
  });
}
