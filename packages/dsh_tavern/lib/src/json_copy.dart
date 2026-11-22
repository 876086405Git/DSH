import 'dart:convert';

/// A detached mutable JSON tree without re-encoding immutable string payloads.
/// Non-JSON values still pass through Dart's encoder, preserving its toJson
/// boundary and rejection of non-finite numbers, unsupported values and cycles.
Map<String, Object?> copyJsonObject(Map<String, Object?> value) => _JsonCopy().copy(value) as Map<String, Object?>;

final class _JsonCopy {
  final _active = Set<Object>.identity();

  Object? copy(Object? value) {
    if (value == null || value is String || value is bool || (value is num && value.isFinite)) return value;
    if (value is Map<String, Object?>) {
      if (!_active.add(value)) return jsonDecode(jsonEncode(value));
      try {
        return <String, Object?>{for (final entry in value.entries) entry.key: copy(entry.value)};
      } finally {
        _active.remove(value);
      }
    }
    if (value is List<Object?>) {
      if (!_active.add(value)) return jsonDecode(jsonEncode(value));
      try {
        return <Object?>[for (final item in value) copy(item)];
      } finally {
        _active.remove(value);
      }
    }
    return jsonDecode(jsonEncode(value));
  }
}
