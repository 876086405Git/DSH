import 'package:flutter/services.dart';

/// Counts calls in the OH Controller. These are not CPU time or device rates.
class OhosIdleDiagnosticsWindow {
  OhosIdleDiagnosticsWindow._({
    required this.id,
    required this.startedAtMs,
    required this.stoppedAtMs,
    required this.counters,
  });

  static const counterNames = [
    'pollTicks',
    'collectCalls',
    'snapshotCalls',
    'emitStatusCalls',
    'lifecycleRefreshRequests',
    'manifestPairChecks',
  ];

  factory OhosIdleDiagnosticsWindow.fromMap(Map<Object?, Object?> map) {
    final id = map['id'];
    final rawCounters = map['counters'];
    if (id is! String || id.isEmpty || rawCounters is! Map) {
      throw const FormatException('Invalid OH idle diagnostics window');
    }
    return OhosIdleDiagnosticsWindow._(
      id: id,
      startedAtMs: _integer(map['startedAtMs'], 'startedAtMs'),
      stoppedAtMs: map['stoppedAtMs'] == null ? null : _integer(map['stoppedAtMs'], 'stoppedAtMs'),
      counters: Map.unmodifiable({for (final name in counterNames) name: _integer(rawCounters[name], name)}),
    );
  }

  final String id;

  /// Unix wall-clock milliseconds; clock adjustments can affect these values.
  final int startedAtMs;
  final int? stoppedAtMs;
  final Map<String, int> counters;
}

class OhosIdleDiagnosticsSnapshot {
  const OhosIdleDiagnosticsSnapshot._({required this.enabled, required this.observedAtMs, required this.window});

  factory OhosIdleDiagnosticsSnapshot.fromMap(Map<Object?, Object?> map) {
    final enabled = map['enabled'];
    final rawWindow = map['window'];
    if (map['schema'] != 1 || enabled is! bool || (rawWindow != null && rawWindow is! Map)) {
      throw const FormatException('Invalid OH idle diagnostics snapshot');
    }
    final window = rawWindow == null ? null : OhosIdleDiagnosticsWindow.fromMap(rawWindow as Map);
    if ((window == null && enabled) || (window != null && enabled != (window.stoppedAtMs == null))) {
      throw const FormatException('Inconsistent OH idle diagnostics window state');
    }
    return OhosIdleDiagnosticsSnapshot._(
      enabled: enabled,
      observedAtMs: _integer(map['observedAtMs'], 'observedAtMs'),
      window: window,
    );
  }

  final bool enabled;
  final int observedAtMs;

  /// Null means no window has been started, rather than a measured zero.
  final OhosIdleDiagnosticsWindow? window;
}

int _integer(Object? value, String field) {
  if (value is num && value.isFinite && value >= 0 && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw FormatException('Invalid OH idle diagnostics integer: $field');
}

/// OH-only diagnostics entry points. Nothing enables collection automatically.
/// Unsupported native versions keep their MissingPluginException.
class OhosIdleDiagnosticsChannel {
  const OhosIdleDiagnosticsChannel([this.channel = const MethodChannel('dsh/runtime')]);

  final MethodChannel channel;

  Future<OhosIdleDiagnosticsSnapshot> read() => _invoke('getIdleDiagnostics');

  /// Repeated true keeps the current window; false retains its final counts.
  /// Enabling again after a stop starts a new window with a new identity.
  Future<OhosIdleDiagnosticsSnapshot> setEnabled(bool enabled) =>
      _invoke('setIdleDiagnosticsEnabled', {'enabled': enabled});

  Future<OhosIdleDiagnosticsSnapshot> _invoke(String method, [Map<String, Object?>? arguments]) async {
    final map = await channel.invokeMapMethod<Object?, Object?>(method, arguments);
    if (map == null) throw const FormatException('Missing OH idle diagnostics snapshot');
    return OhosIdleDiagnosticsSnapshot.fromMap(map);
  }
}
