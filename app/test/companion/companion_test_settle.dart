import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Waits for [work] that mixes real I/O with futures the page started on the
/// fake clock (the page may already be running the same memoized migration).
/// `runAsync` alone would wait forever for the fake-clock half.
///
/// Bounded: work that never finishes fails this test instead of holding the
/// whole file until the runner's timeout and failing every later test.
///
/// [step] moves the fake clock each turn, for work that waits on fake-clock
/// timers as well (the default leaves it still).
Future<T> settleMixed<T>(
  WidgetTester tester,
  Future<T> work, {
  Duration limit = const Duration(seconds: 20),
  Duration? step,
}) async {
  var done = false;
  unawaited(work.whenComplete(() => done = true).then((_) {}, onError: (_) {}));
  final watch = Stopwatch()..start();
  while (!done) {
    if (watch.elapsed > limit) fail('settleMixed: work did not finish within $limit');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(step);
  }
  return work;
}
