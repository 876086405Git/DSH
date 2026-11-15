// Signing in to the forum with a Discourse User API Key, the mechanism the
// official DiscourseHub app uses.
//
// ```text
// signIn() ─► key pair (made once, kept in secure storage) + nonce
//          ─► Custom Tab: <forum>/user-api-key/new?public_key=…&nonce=…
//               &auth_redirect=dshgo://forum/auth&scopes=…&padding=oaep
//             the user logs in (GitHub / LINUX DO / Gitee / e-mail) and approves
//          ─► dshgo://forum/auth?payload=<base64 RSA>   (lib/links router)
// handleRedirect() ─► decrypt, check the nonce, keep the key ─► /session/current.json
// signOut() ─► POST /user-api-key/revoke, forget the key
// ```
//
// The pending nonce is stored too: Android may kill the app while the browser
// is up, and the redirect then cold-starts it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../remote/secret_store.dart' show SecretStore;
import '../secrets/secure_storage.dart';
import '../state/account_state.dart' show accountBrowserProvider;
import '../l10n/l10n.dart';
import 'discourse_client.dart';
import 'forum_config.dart';
import 'forum_crypto.dart';
import 'forum_models.dart';
import 'forum_state.dart';

/// Platform secure storage for the forum's key pair and API key.
class SecureForumStore implements SecretStore {
  SecureForumStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage);

  final AppSecureStorage _storage;

  static String _k(String key) => 'forum.$key';

  @override
  Future<String?> read(String key) => _storage.read(key: _k(key));

  @override
  Future<void> write(String key, String value) => _storage.write(key: _k(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _k(key));
}

final forumSecretStoreProvider = Provider<SecretStore>((ref) => SecureForumStore());

/// Makes (or, in tests, hands out) the install's RSA key pair.
final forumKeyPairFactoryProvider = Provider<Future<ForumKeyPair> Function()>((ref) => generateForumKeyPair);

enum ForumAuthPhase {
  /// Reading the stored key at startup.
  restoring,
  signedOut,

  /// The browser is open on the approval page.
  waiting,
  signedIn,
}

class ForumAuthState {
  const ForumAuthState({this.phase = ForumAuthPhase.restoring, this.credentials, this.user, this.error});

  final ForumAuthPhase phase;
  final ForumCredentials? credentials;

  /// Null right after sign-in until `/session/current.json` answers.
  final ForumCurrentUser? user;

  /// The last sign-in problem, one short line.
  final String? error;

  bool get signedIn => phase == ForumAuthPhase.signedIn && credentials != null;

  /// The number on the bell.
  int get unread => user?.allUnread ?? 0;

  ForumAuthState copyWith({
    ForumAuthPhase? phase,
    ForumCredentials? credentials,
    ForumCurrentUser? user,
    String? error,
    bool clearError = false,
  }) => ForumAuthState(
    phase: phase ?? this.phase,
    credentials: credentials ?? this.credentials,
    user: user ?? this.user,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Storage keys (namespaced `forum.` by [SecureForumStore]).
abstract final class _Keys {
  static const keyPair = 'rsa';
  static const clientId = 'client';
  static const pending = 'pending';
  static String session(String base) => 'session:$base';
}

class ForumAuthController extends Notifier<ForumAuthState> {
  late String _base;
  ForumKeyPair? _keys;

  SecretStore get _store => ref.read(forumSecretStoreProvider);

  @override
  ForumAuthState build() {
    _base = ref.watch(forumBaseUrlProvider);
    // A rebuild keeps this object: the pair is read again, not remembered past
    // the saved credentials being cleared.
    _keys = null;
    unawaited(_restore(_base));
    return const ForumAuthState();
  }

  Future<void> _restore(String base) async {
    ForumCredentials? credentials;
    try {
      final raw = await _store.read(_Keys.session(base));
      final json = raw == null ? null : jsonDecode(raw);
      if (json is Map && json['key'] is String && json['client'] is String) {
        credentials = ForumCredentials(key: json['key'] as String, clientId: json['client'] as String);
      }
    } catch (_) {
      credentials = null;
    }
    if (!ref.mounted || base != _base || state.phase != ForumAuthPhase.restoring) return;
    if (credentials == null) {
      state = const ForumAuthState(phase: ForumAuthPhase.signedOut);
      return;
    }
    state = ForumAuthState(phase: ForumAuthPhase.signedIn, credentials: credentials);
    unawaited(refreshUser());
  }

  ForumApi _api(ForumCredentials? credentials) => ref.read(forumApiFactoryProvider)(Uri.parse(_base), credentials);

  Future<ForumKeyPair> _keyPair() async {
    if (_keys case final keys?) return keys;
    try {
      final raw = await _store.read(_Keys.keyPair);
      final keys = raw == null ? null : ForumKeyPair.fromJson(jsonDecode(raw));
      if (keys != null && keys.bits >= 2048) return _keys = keys;
    } catch (_) {
      // Unreadable: make a new pair.
    }
    final keys = await ref.read(forumKeyPairFactoryProvider)();
    await _store.write(_Keys.keyPair, jsonEncode(keys.toJson()));
    return _keys = keys;
  }

  Future<String> _clientId() async {
    final stored = await _store.read(_Keys.clientId);
    if (stored != null && stored.isNotEmpty) return stored;
    final id = randomHex(16);
    await _store.write(_Keys.clientId, id);
    return id;
  }

  /// The approval page for a fresh nonce.
  Future<Uri> authorizeUrl() async {
    final keys = await _keyPair();
    final clientId = await _clientId();
    final nonce = randomHex(16);
    await _store.write(_Keys.pending, jsonEncode({'nonce': nonce, 'base': _base}));
    final base = Uri.parse(_base);
    final path = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(
      path: '$path/user-api-key/new',
      queryParameters: {
        'application_name': forumApplicationName,
        'client_id': clientId,
        'scopes': forumScopes.join(','),
        'public_key': keys.publicPem,
        'nonce': nonce,
        'auth_redirect': forumAuthRedirect,
        'padding': 'oaep',
      },
    );
  }

  /// Opens the approval page in a Custom Tab. False when no browser opened.
  Future<bool> signIn() async {
    state = state.copyWith(phase: ForumAuthPhase.waiting, clearError: true);
    try {
      final url = await authorizeUrl();
      if (await ref.read(accountBrowserProvider).open(url)) return true;
      if (ref.mounted) state = state.copyWith(phase: ForumAuthPhase.signedOut, error: appL10n.stateBrowserOpenFailed);
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: ForumAuthPhase.signedOut,
          error: credentialsUnreadable(e) ? appL10n.harmonyCredentialsUnreadableHint : appL10n.stateSignInStartFailed,
        );
      }
    }
    return false;
  }

  /// Back from the browser without a key.
  void cancel() {
    if (state.phase == ForumAuthPhase.waiting) {
      state = state.copyWith(phase: ForumAuthPhase.signedOut, clearError: true);
    }
  }

  /// `dshgo://forum/auth?payload=…`. True when it signed the user in.
  Future<bool> handleRedirect(Uri uri) async {
    final payload = uri.queryParameters['payload'];
    if (payload == null || payload.isEmpty) return false;
    try {
      final pendingRaw = await _store.read(_Keys.pending);
      final pending = pendingRaw == null ? null : jsonDecode(pendingRaw);
      if (pending is! Map || pending['nonce'] is! String) throw const FormatException('no sign-in in progress');
      final keys = await _keyPair();
      final json = jsonDecode(utf8.decode(decryptForumPayload(payload, keys)));
      if (json is! Map || json['key'] is! String || (json['key'] as String).isEmpty) {
        throw const FormatException('no key in payload');
      }
      if (json['nonce'] != pending['nonce']) throw const FormatException('nonce mismatch');
      final base = pending['base'] is String ? pending['base'] as String : _base;
      final credentials = ForumCredentials(key: json['key'] as String, clientId: await _clientId());
      await _store.write(_Keys.session(base), jsonEncode({'key': credentials.key, 'client': credentials.clientId}));
      await _store.delete(_Keys.pending);
      if (!ref.mounted) return true;
      if (base != _base) return true; // Signed in to a forum the app has since moved away from.
      state = ForumAuthState(phase: ForumAuthPhase.signedIn, credentials: credentials);
      unawaited(refreshUser());
      return true;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: ForumAuthPhase.signedOut,
          error: credentialsUnreadable(e) ? appL10n.harmonyCredentialsUnreadableHint : appL10n.stateSignInIncompleteRetry,
        );
      }
      return false;
    }
  }

  /// Re-reads the signed-in user (unread counts). A dead key signs out.
  Future<void> refreshUser() async {
    final base = _base;
    final credentials = state.credentials;
    if (credentials == null || !state.signedIn) return;
    try {
      final user = await _api(credentials).currentUser();
      if (_isCurrent(base, credentials)) state = state.copyWith(user: user);
    } on ForumException catch (e) {
      if (_isCurrent(base, credentials) &&
          (e.kind == ForumErrorKind.unauthorized ||
              e.kind == ForumErrorKind.forbidden ||
              e.kind == ForumErrorKind.notFound)) {
        await expire();
      }
    }
  }

  bool _isCurrent(String base, ForumCredentials? credentials) =>
      ref.mounted && base == _base && identical(state.credentials, credentials);

  /// The badge after reading notifications here.
  void setUnread(int count) {
    final user = state.user;
    if (user != null) state = state.copyWith(user: user.copyWith(allUnread: count < 0 ? 0 : count));
  }

  /// The key stopped working (revoked on the web, expired): forget it.
  Future<void> expire() async {
    final base = _base;
    final credentials = state.credentials;
    await _store.delete(_Keys.session(base));
    if (_isCurrent(base, credentials)) {
      state = ForumAuthState(phase: ForumAuthPhase.signedOut, error: appL10n.stateSignInExpired);
    }
  }

  /// Revokes the key on the forum (best effort) and forgets it.
  Future<void> signOut() async {
    final credentials = state.credentials;
    state = const ForumAuthState(phase: ForumAuthPhase.signedOut);
    await _store.delete(_Keys.session(_base));
    if (credentials != null) {
      try {
        await _api(credentials).revokeKey();
      } catch (_) {
        // Offline or already revoked: the key is gone from the phone either way.
      }
    }
  }
}

final forumAuthProvider = NotifierProvider<ForumAuthController, ForumAuthState>(ForumAuthController.new);
