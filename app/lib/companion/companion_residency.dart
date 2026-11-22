import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The native switch is authoritative; the Dart object never auto-enables it.
class CompanionAlwaysOnStatus {
  const CompanionAlwaysOnStatus({
    this.available = false,
    this.enabled = false,
    this.running = false,
    this.notificationAvailable = false,
    this.epoch = 0,
    this.failure,
    this.batteryLow,
    this.powerSave = false,
  });

  final bool available;
  final bool enabled;
  final bool running;
  final bool notificationAvailable;
  final int epoch;
  final String? failure;
  // API 26/27 has no public sticky low-battery field. Unknown stays unknown
  // until an actual system LOW/OKAY broadcast arrives; no percentage is guessed.
  final bool? batteryLow;
  final bool powerSave;
  bool get reducedPower => batteryLow == true || powerSave;

  factory CompanionAlwaysOnStatus.fromMap(Map<Object?, Object?> value) => CompanionAlwaysOnStatus(
    available: true,
    enabled: value['enabled'] == true,
    running: value['running'] == true,
    notificationAvailable: value['notificationAvailable'] == true,
    epoch: value['epoch'] as int? ?? 0,
    failure: value['failure'] as String?,
    batteryLow: value['batteryLow'] as bool?,
    powerSave: value['powerSave'] == true,
  );
}

class CompanionResidentInput {
  const CompanionResidentInput(this.id, this.text, this.epoch);
  final String id;
  final String text;
  final int epoch;
}

final companionResidencyProvider = NotifierProvider<CompanionResidency, CompanionAlwaysOnStatus>(
  CompanionResidency.new,
);

/// One method handler for the lifetime of dsh-main, including Activity changes.
class CompanionResidency extends Notifier<CompanionAlwaysOnStatus> {
  static const channel = MethodChannel('dsh/companion/always_on');
  final _inputs = StreamController<CompanionResidentInput>.broadcast();
  final _pending = <CompanionResidentInput>[];
  bool _receiving = false;
  bool _disposed = false;

  @override
  CompanionAlwaysOnStatus build() {
    channel.setMethodCallHandler((call) async {
      if (_disposed) return false;
      final value = call.arguments;
      switch (call.method) {
        case 'status':
          if (value is Map) state = CompanionAlwaysOnStatus.fromMap(value);
        case 'reply':
          if (value is! Map || value['id'] is! String || value['text'] is! String || value['epoch'] is! int) {
            return false;
          }
          final input = CompanionResidentInput(value['id'] as String, value['text'] as String, value['epoch'] as int);
          if (state.available && (!state.enabled || input.epoch != state.epoch)) return false;
          if (_receiving) {
            _inputs.add(input);
          } else {
            _pending.add(input);
          }
          return true;
      }
      return null;
    });
    ref.onDispose(() {
      _disposed = true;
      channel.setMethodCallHandler(null);
      unawaited(_inputs.close());
    });
    unawaited(_call('ready'));
    return const CompanionAlwaysOnStatus();
  }

  StreamSubscription<CompanionResidentInput> listenInputs(void Function(CompanionResidentInput) receive) {
    final subscription = _inputs.stream.listen(receive);
    _receiving = true;
    for (final input in List.of(_pending)) {
      receive(input);
    }
    _pending.clear();
    return subscription;
  }

  Future<void> setEnabled(bool enabled) => _call('setEnabled', {'enabled': enabled});
  Future<void> refresh() => _call('status');
  Future<void> reportFailure(String? code) => _call('failure', {'code': code});

  Future<void> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      final result = await channel.invokeMapMethod<Object?, Object?>(method, arguments);
      if (!_disposed && result != null) state = CompanionAlwaysOnStatus.fromMap(result);
    } on MissingPluginException {
      if (!_disposed) state = const CompanionAlwaysOnStatus();
    } on PlatformException catch (error) {
      if (!_disposed) {
        state = CompanionAlwaysOnStatus(
          available: true,
          enabled: state.enabled,
          running: false,
          epoch: state.epoch,
          failure: error.code,
          batteryLow: state.batteryLow,
          powerSave: state.powerSave,
        );
      }
    }
  }

  Future<bool> update({
    required int epoch,
    required String name,
    required String text,
    required String id,
    bool user = false,
    bool quiet = true,
  }) async {
    if (!state.enabled || state.epoch != epoch) return false;
    try {
      return await channel.invokeMethod<bool>('update', {
            'epoch': epoch,
            'name': name,
            'text': text,
            'id': id,
            'user': user,
            'quiet': quiet,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// For an already-reserved business opportunity an exception is unknown,
  /// not evidence that a native notification never appeared.
  Future<bool> deliver({required int epoch, required String name, required String text, required String id}) async {
    if (!state.enabled || state.epoch != epoch || !state.notificationAvailable) return false;
    try {
      return await channel.invokeMethod<bool>('update', {
            'epoch': epoch,
            'name': name,
            'text': text,
            'id': id,
            'user': false,
            'quiet': false,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> clear(int epoch) async {
    try {
      await channel.invokeMethod<void>('clear', {'epoch': epoch});
    } on MissingPluginException {
      /* No native notification was shown. */
    } on PlatformException {
      /* A failed clear is not a delivery receipt. */
    }
  }
}
