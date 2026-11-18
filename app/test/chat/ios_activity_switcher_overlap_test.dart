import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  testWidgets('iOS activity can recur while its previous fade is still leaving', (tester) async {
    final clock = runClock;
    final now = DateTime(2026, 11, 5, 12);
    runClock = () => now;
    addTearDown(() {
      runClock = clock;
    });
    usePhoneView(tester);
    final writing = RunActivity(kind: ActivityKind.writing, title: '写回复中', since: now, turnStart: now);
    final activity = ValueNotifier(writing);
    addTearDown(activity.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<RunActivity>(
            valueListenable: activity,
            builder: (_, value, _) => ActivityStrip(activity: value, whale: false),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // The real queue/withdraw/interrupt chain first exposed this overlap.
    // This focused test advances Flutter's animation clock, without a model or network gate.
    for (final next in [
      RunActivity(kind: ActivityKind.stopping, title: '正在停止', since: now, turnStart: now),
      writing,
      RunActivity(kind: ActivityKind.waiting, title: '思考中', since: now, turnStart: now),
    ]) {
      activity.value = next;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('思考中'), findsOneWidget);
    expect(find.text('写回复中'), findsNothing);
    expect(find.text('正在停止'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
