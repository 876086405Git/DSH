import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// iOS-only Linux installation contract. Calling it never changes another host's
/// runtime or chooses a download URL. The UI supplies its own localized wording.
final class IosGuestStatus {
  const IosGuestStatus({required this.phase, required this.available,
    required this.installed, required this.usable, required this.busy,
    this.suspended = false, this.suspendedReason,
    this.version, this.errorCode, this.errorMessage});
  final String phase;
  final bool available, installed, usable, busy, suspended;
  final String? suspendedReason;
  final String? version, errorCode, errorMessage;
  factory IosGuestStatus.fromMap(Map<Object?, Object?> map) {
    final error = map['error'];
    final errors = error is Map ? error : const {};
    return IosGuestStatus(phase: map['phase'] as String,
      available: map['available'] == true, installed: map['installed'] == true,
      usable: map['usable'] == true, busy: map['busy'] == true,
      suspended: map['suspended'] == true, suspendedReason: map['suspendedReason'] as String?,
      version: map['version'] as String?, errorCode: errors['code'] as String?,
      errorMessage: errors['message'] as String?);
  }
}

final class IosGuestBridge {
  static const _methods = MethodChannel('dsh/guest');
  static const _events = EventChannel('dsh/guest/events');
  Stream<Map<Object?, Object?>>? _stream;
  void _requireIos() {
    if (!Platform.isIOS) {
      throw UnsupportedError('Linux guest installation is an iOS-only interface.');
    }
  }
  Stream<Map<Object?, Object?>> get events {
    _requireIos();
    return _stream ??= _events.receiveBroadcastStream().map((event) =>
      Map<Object?, Object?>.from(event as Map));
  }
  Future<IosGuestStatus> _statusMethod(String name) async {
    _requireIos();
    final value = await _methods.invokeMapMethod<Object?, Object?>(name);
    if (value == null) throw StateError('Missing Linux guest status.');
    return IosGuestStatus.fromMap(value);
  }
  Future<IosGuestStatus> status() => _statusMethod('status');
  Future<IosGuestStatus> install() => _statusMethod('install');
  Future<IosGuestStatus> uninstall() => _statusMethod('uninstall');
  /// Clears the prior crash record. Restart the local engine to apply this;
  /// a running engine keeps its immutable startup routing snapshot.
  Future<IosGuestStatus> resume() => _statusMethod('resume');
  Future<bool> cancel() async {
    _requireIos();
    final value = await _methods.invokeMapMethod<Object?, Object?>('cancel');
    return value?['cancelled'] == true;
  }
  /// Logical file bytes; excludes directory allocation overhead. Includes
  /// retained archive, staging and deletion remnants; never follows symlinks.
  Future<Map<String, int>> usage() async {
    _requireIos();
    final value = await _methods.invokeMapMethod<Object?, Object?>('usage');
    if (value == null) throw StateError('Missing Linux guest usage.');
    return value.map((key, value) => MapEntry(key as String, value as int));
  }
}
