import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secrets/secure_storage.dart';
import 'provider_backend.dart';

/// The API keys of custom providers created on the **local** engine, kept in
/// the Android Keystore-backed secure storage under `provider_key_<id>`.
///
/// The engine's own credential store (`$DSH_HOME/.credentials.yaml`) is what
/// serves requests; this copy only exists so a key that went missing there
/// (a reset runtime, a restored profile) can be put back on the next connect
/// ([healProviderKeys]), the way the DeepSeek key is re-pushed. Keys typed
/// while a remote host is active go to that host only and are never kept here:
/// its credential store is as durable as ours, and a copy here could end up
/// pushed to the wrong engine.
abstract class ProviderKeyVault {
  static const prefix = 'provider_key_';

  /// Every stored key by provider id.
  Future<Map<String, String>> readAll();

  Future<void> write(String id, String key);

  Future<void> delete(String id);
}

class SecureProviderKeyVault implements ProviderKeyVault {
  const SecureProviderKeyVault([this._injected]);

  final FlutterSecureStorage? _injected;
  AppSecureStorage get _storage => AppSecureStorage(_injected);

  @override
  Future<Map<String, String>> readAll() async {
    final all = await _storage.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(ProviderKeyVault.prefix) && entry.value.isNotEmpty)
          entry.key.substring(ProviderKeyVault.prefix.length): entry.value,
    };
  }

  @override
  Future<void> write(String id, String key) => _storage.write(key: '${ProviderKeyVault.prefix}$id', value: key);

  @override
  Future<void> delete(String id) => _storage.delete(key: '${ProviderKeyVault.prefix}$id');
}

final providerKeyVaultProvider = Provider<ProviderKeyVault>((ref) => const SecureProviderKeyVault());

/// Puts saved custom-provider keys back into a freshly connected **local**
/// engine, but only where they are missing: a key that is present (maybe
/// replaced in the web Models page since) is left alone, and keys of providers
/// the engine no longer declares are not pushed anywhere.
///
/// Returns the credential references that were written.
Future<List<String>> healProviderKeys(ProviderBackend backend, ProviderKeyVault vault) async {
  final keys = await vault.readAll();
  if (keys.isEmpty) return const [];
  final settings = await backend.read();
  if (settings == null) return const [];
  final wanted = <String, String>{};
  for (final MapEntry(key: id, value: key) in keys.entries) {
    final ref = settings.byRoute(id)?.apiKeyEnv;
    if (ref != null && ref.isNotEmpty) wanted[ref] = key;
  }
  if (wanted.isEmpty) return const [];
  final status = await backend.credentials(wanted.keys.toList());
  final written = <String>[];
  for (final MapEntry(key: ref, value: key) in wanted.entries) {
    final s = status[ref];
    if (s != null && (s.configured || !s.writable)) continue;
    await backend.storeKey(ref, key);
    written.add(ref);
  }
  return written;
}
