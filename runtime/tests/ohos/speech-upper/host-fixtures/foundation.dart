// Explicit annotation/type boundary; no widgets or Flutter runtime.
export 'dart:typed_data';
class _TestingMarker {
  const _TestingMarker();
}
const visibleForTesting = _TestingMarker();
const immutable = _TestingMarker();
bool mapEquals<K, V>(Map<K, V>? a, Map<K, V>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  for (final key in a.keys) { if (!b.containsKey(key) || b[key] != a[key]) return false; }
  return true;
}
