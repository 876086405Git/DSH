import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// True for the two failures trying again can't fix: the saved credentials
/// don't decrypt, or the system key they need is gone. Only the OH channel
/// reports them. Everything else (`secrets_unavailable`, `secrets_io`) may pass.
bool credentialsUnreadable(Object? error) =>
    error is PlatformException && (error.code == 'secrets_unreadable' || error.code == 'secrets_key_missing');

/// Secret-storage operations and explicit OH credential recovery.
///
/// OH uses the app's HUKS channel. Other platforms and explicit test injections
/// keep the original flutter_secure_storage implementation and options, except
/// that on iOS an item stays on this device instead of following a backup to the
/// next one.
class AppSecureStorage {
  const AppSecureStorage([this._injected]) : _platform = null;

  const AppSecureStorage.forPlatform(String operatingSystem, [this._injected]) : _platform = operatingSystem;

  final FlutterSecureStorage? _injected;
  final String? _platform;
  static const _channel = MethodChannel('dsh/secrets');

  bool get _ohos => _injected == null && (_platform ?? Platform.operatingSystem) == 'ohos';
  FlutterSecureStorage get _fallback =>
      _injected ??
      const FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device));

  Future<String?> read({required String key}) async {
    if (!_ohos) return _fallback.read(key: key);
    final value = await _channel.invokeMethod<Object?>('read', {'key': key});
    if (value == null || value is String) return value as String?;
    throw const FormatException('Invalid secret-storage response');
  }

  Future<void> write({required String key, required String? value}) async {
    if (!_ohos) return _fallback.write(key: key, value: value);
    if (value == null) return delete(key: key);
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  Future<void> delete({required String key}) async {
    if (!_ohos) return _fallback.delete(key: key);
    await _channel.invokeMethod<void>('delete', {'key': key});
  }

  /// Call only after the user confirms clearing all locally saved credentials.
  /// Native recovery keeps host configuration and shares the read/write queue.
  Future<void> recover({required bool confirmed}) async {
    if (!_ohos) throw UnsupportedError('Credential recovery is only available on OHOS');
    if (!confirmed) throw ArgumentError.value(confirmed, 'confirmed', 'Explicit confirmation required');
    await _channel.invokeMethod<void>('recover', {'confirmed': true});
  }

  Future<Map<String, String>> readAll() async {
    if (!_ohos) return _fallback.readAll();
    final value = await _channel.invokeMethod<Object?>('readAll');
    if (value is! Map) throw const FormatException('Invalid secret-storage response');
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('Invalid secret-storage response');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }
}
