// 伙伴小屋 on the home screen (android companion/CompanionWidget.kt): what the
// room looks like, sent whenever it changes. iOS publishes the same display
// snapshot through WidgetKit. Without a native side (desktop/tests), skip it.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CompanionWidget {
  CompanionWidget([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/companion_widget');

  final MethodChannel _channel;

  /// Keys the widget reads: name, status, activity, untilMs, statusAsleep,
  /// statusWaiting, bond (0–3), line, saidAt. A null value clears its key.
  Future<void> update(Map<String, Object?> values) async {
    try {
      await _channel.invokeMethod<void>('update', values);
    } on Object {
      // No widget here.
    }
  }
}

final companionWidgetProvider = Provider<CompanionWidget>((ref) => CompanionWidget());
