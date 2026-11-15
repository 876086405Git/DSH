// Non-visual channel/storage tests have no font or asset dependency. Keep the
// app-wide visual test configuration unchanged; this scope does not render UI.
import 'dart:async';

import 'package:dsh_app/performance/performance_state.dart';

import '../support/quiet_performance.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PerformanceChannel.create = QuietPerformanceChannel.new;
  await testMain();
}
