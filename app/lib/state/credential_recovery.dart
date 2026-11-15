// 清除已保存的密钥, HarmonyOS only: the way out when the credential vault
// can't be decrypted or its system key is gone (app/ohos/secrets.md). Every
// save fails until then, and nothing clears it without the person asking
// (ui/settings/credential_recovery_dialog.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../forum/forum_auth.dart';
import '../secrets/secure_storage.dart';
import '../share_hosted/hosted_links_state.dart';
import 'android_features.dart';
import 'hosts_state.dart';
import 'read_list_epoch.dart';
import 'settings_state.dart';

final credentialStorageProvider = Provider<AppSecureStorage>(
  (ref) => AppSecureStorage.forPlatform(ref.watch(operatingSystemProvider)),
);

/// Whether the saved credentials can't be read right now. Reading any key
/// authenticates the whole vault, and this one holds nothing, so no secret comes
/// over the channel. Never asks anything off HarmonyOS.
final credentialsUnreadableProvider = FutureProvider.autoDispose<bool>((ref) async {
  if (ref.watch(operatingSystemProvider) != 'ohos') return false;
  try {
    await ref.watch(credentialStorageProvider).read(key: 'credential_recovery_probe');
    return false;
  } catch (e) {
    return credentialsUnreadable(e);
  }
});

final credentialRecoveryProvider = Provider<CredentialRecovery>(CredentialRecovery.new);

class CredentialRecovery {
  const CredentialRecovery(this._ref);

  final Ref _ref;

  /// Call only after the person confirmed. Throws what the vault reports.
  ///
  /// What holds saved values in memory: [hostedLinksProvider] rewrites its whole
  /// list on any change, [relayBackendProvider]'s account rotates tokens into
  /// the store, [forumAuthProvider] has the session and key pair, and
  /// [settingsProvider] the API key and provider ids. They let go before the
  /// vault is cleared, so nothing can write old values into the new one, and read
  /// again after. The stores themselves cache nothing, and saved SSH hosts keep
  /// only their configuration here.
  Future<void> recover() async {
    _release();
    await _ref.read(credentialStorageProvider).recover(confirmed: true);
    _release();
    _ref.invalidate(credentialsUnreadableProvider);
    // As signing out does: a relay host can't be connected to any more.
    await _ref.read(activeHostProvider.notifier).forget((host) => host.kind == HostKind.relay);
    await _ref.read(settingsProvider.notifier).reloadCredentials();
  }

  void _release() {
    _ref.read(readListCredentialEpochProvider.notifier).advance();
    _ref
      ..invalidate(hostedLinksProvider)
      ..invalidate(relayBackendProvider)
      ..invalidate(forumAuthProvider);
  }
}
