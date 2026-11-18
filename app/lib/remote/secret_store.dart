import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secrets/secure_storage.dart';

/// Where remote-access secrets live: SSH passwords and private keys, relay
/// device credentials. Never SharedPreferences.
///
/// Injectable so state and tests can swap in [MemorySecretStore], and so the
/// relay package (`dsh_remote`) can be handed the same store.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore storage, or the OH app's HUKS-backed secret channel.
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage);

  final AppSecureStorage _storage;

  /// Every key is namespaced so remote secrets never collide with app settings.
  static String _k(String key) => 'remote.$key';

  @override
  Future<String?> read(String key) => _storage.read(key: _k(key));

  @override
  Future<void> write(String key, String value) => _storage.write(key: _k(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _k(key));
}

/// In-memory store for tests and previews.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
