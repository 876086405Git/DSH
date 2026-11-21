// 伙伴小屋 on the home screen (android companion/CompanionWidget.kt): what the
// room looks like, sent whenever it changes. iOS publishes the same display
// snapshot through WidgetKit. A missing/older native side cannot acknowledge
// a durable memory clear; the database keeps that operation pending.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class CompanionWidget {
  CompanionWidget([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/companion_widget');

  final MethodChannel _channel;
  Future<void> _writes = Future<void>.value();
  String? _archive;
  int _control = -1;

  /// Keys the widget reads: name, status, activity, untilMs, statusAsleep,
  /// statusWaiting, bond (0–3), line, saidAt. A null value clears its key.
  Future<bool> update(Map<String, Object?> values) {
    final copy = Map<String, Object?>.unmodifiable(values);
    final archive = copy['memoryArchiveId'] as String?;
    final control = copy['memoryControlRevision'] as int?;
    if (archive != null && control != null && (_archive == null || _archive == archive) && control > _control) {
      _archive = archive;
      _control = control;
    }
    final result = _writes.then((_) async {
      if ((archive != null && (_archive != archive || control == null || control < _control)) ||
          (archive == null && _archive != null && (copy.containsKey('line') || copy.containsKey('saidAt')))) {
        return false;
      }
      try {
        return await _channel.invokeMethod<Object?>('update', copy) == true;
      } on MissingPluginException {
        return false;
      } on PlatformException {
        return false;
      }
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> clearMemoryLine({required String archiveId, required int controlRevision}) =>
      update({'memoryArchiveId': archiveId, 'memoryControlRevision': controlRevision, 'line': null, 'saidAt': null});
}

final companionWidgetProvider = Provider<CompanionWidget>((ref) => CompanionWidget());
