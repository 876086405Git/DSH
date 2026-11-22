import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Waits for [work] that mixes real I/O with futures the page started on the
/// fake clock (the page may already be running the same memoized migration).
/// `runAsync` alone would wait forever for the fake-clock half.
Future<T> settleMixed<T>(WidgetTester tester, Future<T> work) async {
  var done = false;
  unawaited(work.whenComplete(() => done = true).then((_) {}, onError: (_) {}));
  // Returning an unfinished fake-zone future would stop the pumps it still needs.
  // Keep its existing test timeout; do not impose a separate polling window.
  while (!done) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  return work;
}
