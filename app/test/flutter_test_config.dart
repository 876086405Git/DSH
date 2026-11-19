// Runs around every test file under test/: real fonts first (strict: a
// missing font fails the run), so no test measures or draws the test
// engine's box font. No binding here: tests that never pump keep real
// sockets and HTTP.

import 'dart:async';

import 'support/test_defaults.dart';
import 'support/test_fonts.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await loadTestFonts();
  applyTestDefaults();
  await testMain();
}
