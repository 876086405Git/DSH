import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  testWidgets('page title is a route heading and scrolled content has a backdrop veil', (tester) async {
    final semantics = tester.ensureSemantics();
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: AppPage.list(
          title: '设置',
          children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('正文 $i'))],
        ),
      ),
    );
    expect(tester.getSemantics(find.text('设置').first), isSemantics(label: '设置', isHeader: true, namesRoute: true));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropVeil), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.byType(BackdropVeil), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a hero scrolled out of sight stops asking for frames', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        animations: true,
        home: AppPage(
          title: '引擎',
          hero: const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
          slivers: [
            SliverList.list(children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('日志 $i'))]),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    Opacity header() => tester.widget<Opacity>(
      find.ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(Opacity)).first,
    );
    // Half faded: still spinning.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -30));
    await tester.pump(const Duration(seconds: 1));
    expect(header().opacity, inExclusiveRange(0, 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    // Settles only because the faded-out spinner holds still.
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });
}
