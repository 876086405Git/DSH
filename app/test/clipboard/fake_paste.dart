// `dsh/paste` as the native window answers it, and Flutter's clipboard, so a test
// can tell which of the two a field read.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePaste {
  FakePaste(WidgetTester tester, {this.reply = const {'status': 'cancelled'}, this.flutterText}) {
    const channel = MethodChannel('dsh/paste');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map)['requestId'] as String;
      if (call.method == 'cancel') {
        cancels.add(id);
        return true;
      }
      reads.add(id);
      await gate?.future;
      return reply;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      flutterReads++;
      return flutterText == null ? null : {'text': flutterText};
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  /// What the next read answers.
  Map<String, Object?> reply;

  /// What Flutter's clipboard holds.
  final String? flutterText;

  /// Holds the native reply back, as an open window does.
  Completer<void>? gate;

  final reads = <String>[];
  final cancels = <String>[];
  int flutterReads = 0;

  static Map<String, Object?> text(String text) => {'status': 'text', 'text': text};
}
