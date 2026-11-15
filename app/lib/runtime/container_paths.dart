import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native-validated roots, read before preference consumers use saved paths.
/// The snapshot never guesses a container UUID or rewrites user content.
class ContainerPaths {
  ContainerPaths._(this.guest, this.previous, this.support, this.previousSupport, this.workspaceAliases);

  final Map<String, String> workspaceAliases;
  final String? guest;
  final List<String> previous;
  final String? support;
  final List<String> previousSupport;
  static Future<ContainerPaths>? _loading;
  static bool get enabled => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<ContainerPaths> load() => _loading ??= _read();

  /// Reload after native startup has completed its relocation preflight.
  static Future<ContainerPaths> refresh() => _loading = _read();

  static Future<ContainerPaths> _read() async {
    try {
      final map = await const MethodChannel('dsh/runtime').invokeMapMethod<String, Object?>('containerPaths');
      String? root(Object? value) => value is String && _validRoot(value) ? value : null;
      List<String> roots(Object? value) => value is List ? [for (final v in value) ?root(v)] : [];
      return ContainerPaths._(
        root(map?['guestRoot']),
        roots(map?['previousRoots']),
        root(map?['supportRoot']),
        roots(map?['previousSupportRoots']),
        {
          if (map?['workspaceAliases'] case final Map aliases)
            for (final MapEntry(:key, :value) in aliases.entries)
              if (key is String && value is String) key: value,
        },
      );
    } on Object {
      return ContainerPaths._(null, const [], null, const [], const {});
    }
  }

  static bool _validRoot(String path) =>
      path.startsWith('/') &&
      path != '/' &&
      !path.contains('\x00') &&
      path.substring(1).split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');

  String workspaceId(String id) => workspaceAliases[id] ?? id;

  String guestPath(String path) => _map(path, guest, previous);

  static String _map(String path, String? current, List<String> oldRoots) {
    if (current == null || path == current || path.startsWith('$current/')) return path;
    final sorted = [...oldRoots]..sort((a, b) => b.length.compareTo(a.length));
    for (final old in sorted) {
      if (path == old || path.startsWith('$old/')) return '$current${path.substring(old.length)}';
    }
    return path;
  }

  static bool _relative(String value) =>
      value.isNotEmpty &&
      !value.startsWith('/') &&
      !value.contains('\x00') &&
      value.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..');

  Future<String?> _ownedFile(String path, String folder) async {
    if (support == null) return null;
    final owned = '$support/$folder';
    try {
      final root = await Directory(owned).resolveSymbolicLinks();
      final file = await File(path).resolveSymbolicLinks();
      return root == owned && file.startsWith('$owned/') && await File(file).exists() ? file : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Resolve only the importer's own folder; unknown absolute paths stay literal.
  Future<Map<String, Object?>?> decodeOwned(Map<String, Object?> json, String folder) async {
    final result = Map<String, Object?>.of(json);
    final relative = json['iosOwnedPaths'] == 1;
    for (final key in ['path', 'poster']) {
      final value = json[key];
      if (value == null && key == 'poster') continue;
      if (value is! String) return null;
      if (relative) {
        if (support == null || !_relative(value)) return null;
        final path = '$support/$folder/$value';
        if (await _ownedFile(path, folder) == null) return null;
        result[key] = path;
      } else {
        final path = _map(value, support, previousSupport);
        if (path != value) {
          if (await _ownedFile(path, folder) == null) return null;
          result[key] = path;
        }
      }
    }
    return result;
  }

  Future<Map<String, Object?>> encodeOwned(Map<String, Object?> json, String folder) async {
    final result = Map<String, Object?>.of(json);
    for (final key in ['path', 'poster']) {
      final value = json[key];
      if (value == null && key == 'poster') continue;
      if (value is! String) return json;
      final owned = await _ownedFile(value, folder);
      if (owned == null) return json;
      result[key] = owned.substring('$support/$folder/'.length);
    }
    result['iosOwnedPaths'] = 1;
    return result;
  }

  @visibleForTesting
  static void resetForTest() => _loading = null;
}
