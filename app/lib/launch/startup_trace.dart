// How far the app has got on its way to its first page, on iOS. A step that hangs before runApp
// would otherwise leave the launch screen up for good, and with a TestFlight build there's no
// console to read: StartupWatch (ios/Runner/LaunchChannel.swift) puts this on the screen if the
// app doesn't get there. Other platforms run the steps as they always did.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

abstract final class StartupTrace {
  static const _channel = MethodChannel('dsh/startup');

  /// How long one step may hold up the first frame. Each normally takes a few milliseconds.
  @visibleForTesting
  static Duration limit = const Duration(seconds: 4);

  static bool get _on => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool _over = false;
  static String? _last;

  static void mark(String stage) {
    if (!_on || _over || stage == _last) return;
    _last = stage;
    debugPrint('[dsh-startup] $stage');
    unawaited(_send('mark', stage));
  }

  /// An error on the way there: its first line, already redacted (diagnostics/app_error_log.dart).
  static void error(String message) {
    final line = message.split('\n').first;
    mark('error: ${line.length > 160 ? '${line.substring(0, 159)}…' : line}');
  }

  /// The first page is up and nothing lies over it any more. The watch has done its job, and
  /// nothing is noted after this.
  static void finished() {
    if (!_on || _over) return;
    _over = true;
    unawaited(_send('finished', null));
  }

  /// One thing the first frame waits for. On iOS it can't stop the app from starting: a step that
  /// hangs or throws is noted and the app goes on without it, with [onLate] called when it hung,
  /// since it may yet finish later (the app has moved on by then).
  static Future<void> step(String name, Future<Object?> Function() run, {void Function()? onLate}) async {
    if (!_on) {
      await run();
      return;
    }
    mark('$name…');
    try {
      await run().timeout(limit);
      mark('$name ok');
    } on TimeoutException {
      onLate?.call();
      mark('$name timed out');
    } on Object catch (error) {
      mark('$name failed: $error');
    }
  }

  @visibleForTesting
  static void reset() {
    _over = false;
    _last = null;
  }

  static Future<void> _send(String method, String? stage) async {
    try {
      await _channel.invokeMethod<void>(method, stage);
    } on Object {
      // Only ever a note: no native side here means nothing to tell.
    }
  }
}
