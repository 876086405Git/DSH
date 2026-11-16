// OH incoming cache ownership only. A channel receipt is not file consumption.
import 'package:flutter/services.dart';

class ShareConsumption {
  ShareConsumption._(this.id, this._channel, Set<String> paths) : _remaining = Set.of(paths), _paths = paths;

  static final _byId = <String, ShareConsumption>{};
  static final _byPath = <String, ShareConsumption>{};
  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  /// Only ShareIntake's OH branch registers paths from a native-owned batch.
  /// Reject partial/duplicate registrations instead of assigning ownership
  /// to an arbitrary file URI later encountered by the link router.
  static ShareConsumption? register(Object? id, List<String> paths, MethodChannel channel) {
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        paths.isEmpty ||
        paths.length > 9 ||
        _byId.containsKey(id) ||
        _byId.length >= 8) {
      return null;
    }
    final unique = paths.toSet();
    if (unique.length != paths.length ||
        unique.any((p) => !p.startsWith('/') || p.contains('\u0000') || _byPath.containsKey(p))) {
      return null;
    }
    final lease = ShareConsumption._(id, channel, unique);
    _byId[id] = lease;
    for (final path in unique) {
      _byPath[path] = lease;
    }
    return lease;
  }

  static ShareConsumption? forUri(Uri uri) {
    if (uri.scheme != 'file') return null;
    try {
      return _byPath[uri.toFilePath()];
    } on UnsupportedError {
      return null;
    }
  }

  final String id;
  final MethodChannel _channel;
  final Set<String> _paths;
  final Set<String> _remaining;
  Future<void>? _completion;

  /// All readers have finished (or explicitly discarded) this batch.
  /// A failed ACK is not retried and never falls back to deleting by path.
  Future<void> finish() {
    final pending = _completion;
    if (pending != null) return pending;
    // These indices track unread files, not ACK delivery. Native alone owns
    // its outstanding quota: a lost reply must not create a second quota here.
    if (identical(_byId[id], this)) _byId.remove(id);
    for (final path in _paths) {
      if (identical(_byPath[path], this)) _byPath.remove(path);
    }
    _remaining.clear();
    return _completion = _acknowledge();
  }

  Future<void> finishPath(String path) async {
    if (!_remaining.remove(path)) return;
    if (_remaining.isEmpty) await finish();
  }

  Future<void> _acknowledge() async {
    try {
      await _channel.invokeMethod<bool>('consumed', {'shareId': id});
      // True settles the native owner; false does not. Neither outcome makes
      // Dart delete files or retry work whose readers have already finished.
    } catch (_) {
      // Native retains any unsettled ownership. Do not repeat application work.
    }
  }
}
