// The GitHub account a person publishes to the Creative Workshop as
// (docs/design/workshop-app.md「作者登录」). Only this file touches the token:
// it lives in secure storage and reaches workshopAccessProvider as an opaque
// credential object, never as text a page could show.
//
//   restoring ─► signedOut ─startSignIn()─► awaitingCode ─approved─► signedIn
//                   ▲  ◄── cancelSignIn() / expired / denied ──┘          │
//                   └──────────────── signOut() / markInvalid() ◄──────────┘
//
// Signing out only forgets the token on this phone. Revoking the App's access
// is done on GitHub (Settings → Applications), which the page tells the person.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/secret_store.dart' show SecretStore;
import '../secrets/secure_storage.dart';
import '../workshop/github_device_flow.dart';
import '../workshop/workshop_models.dart';
import 'workshop_dependencies.dart';

enum WorkshopAccountPhase { restoring, signedOut, awaitingCode, signedIn }

/// Why the last sign-in attempt ended without an account.
enum WorkshopAccountError { expired, denied, network, unconfigured }

/// Compared by identity: a new sign-in is a new account session even for the
/// same GitHub user, so nothing captured for the old token carries over.
class WorkshopAccountCredential {
  const WorkshopAccountCredential(this.token);
  final String token;
  @override
  String toString() => 'WorkshopAccountCredential(redacted)';
}

class WorkshopAccountState {
  const WorkshopAccountState({required this.phase, this.userCode, this.verificationUri,
    this.expiresAt, this.id, this.login, this.credential, this.error});
  final WorkshopAccountPhase phase;
  /// While [WorkshopAccountPhase.awaitingCode]: what to type, and where.
  final String? userCode;
  final Uri? verificationUri;
  final DateTime? expiresAt;
  /// While [WorkshopAccountPhase.signedIn].
  final int? id;
  final String? login;
  final WorkshopAccountCredential? credential;
  /// The last failed attempt; cleared when the next one starts.
  final WorkshopAccountError? error;
}

const workshopAccountKey = 'workshop.github.account.v1';

class _SecureAccountStore implements SecretStore {
  const _SecureAccountStore();
  static const _storage = AppSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Tests use MemorySecretStore.
final workshopAccountStoreProvider = Provider<SecretStore>((ref) => const _SecureAccountStore());

final workshopGitHubProvider = Provider<GitHubDeviceFlow>((ref) {
  final flow = GitHubDeviceFlow(ref.watch(workshopHttpFactoryProvider));
  ref.onDispose(flow.close);
  return flow;
});

/// The pause between token polls; tests make it immediate.
final workshopAccountWaitProvider = Provider<Future<void> Function(Duration)>(
  (ref) => (interval) => Future<void>.delayed(interval),
);

class WorkshopAccountController extends Notifier<WorkshopAccountState> {
  /// Bumped by every start, cancel and sign-out, so a poll that is still
  /// running for an earlier attempt can tell it no longer applies.
  int _attempt = 0;

  static const _signedOut = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut);

  @override
  WorkshopAccountState build() {
    unawaited(_restore(ref.read(workshopAccountStoreProvider), _attempt));
    return const WorkshopAccountState(phase: WorkshopAccountPhase.restoring);
  }

  SecretStore get _store => ref.read(workshopAccountStoreProvider);
  bool _live(int attempt) => ref.mounted && attempt == _attempt;

  /// Changes to the stored account, one after another: a cancelled attempt's
  /// write and its clean-up finish before a later attempt's write starts, so
  /// the clean-up can never delete what the later one saved.
  Future<void> _stored = Future<void>.value();
  Future<void> _inOrder(Future<void> Function() change) {
    final done = _stored.then((_) => change());
    _stored = done.catchError((Object _) {});
    return done;
  }

  Future<void> _restore(SecretStore store, int attempt) async {
    var next = _signedOut;
    try {
      final saved = jsonDecode(await store.read(workshopAccountKey) ?? 'null');
      if (saved case {'token': final String token, 'id': final int id, 'login': final String login}
          when RegExp(r'^[A-Za-z0-9_]{1,255}$').hasMatch(token) && id > 0) {
        next = WorkshopAccountState(phase: WorkshopAccountPhase.signedIn, id: id, login: login,
          credential: WorkshopAccountCredential(token));
      }
    } on Object {
      // An unreadable record reads as signed out; the next sign-in replaces it.
    }
    if (_live(attempt)) state = next;
  }

  /// Asks GitHub for a code, shows it (awaitingCode), then polls until the
  /// person approves it in the browser. Returns once the attempt has ended.
  Future<void> startSignIn() async {
    if (state.phase == WorkshopAccountPhase.signedIn || state.phase == WorkshopAccountPhase.awaitingCode) return;
    final attempt = ++_attempt;
    state = _signedOut;
    final github = ref.read(workshopGitHubProvider);
    final wait = ref.read(workshopAccountWaitProvider);
    final store = _store;
    try {
      final client = await ref.read(workshopClientProvider.future);
      final clientId = (await client.capabilities()).account.clientId;
      if (!_live(attempt)) return;
      if (clientId == null) workshopInvalid('workshop_account_unconfigured');
      final code = await github.requestCode(clientId);
      if (!_live(attempt)) return;
      state = WorkshopAccountState(phase: WorkshopAccountPhase.awaitingCode, userCode: code.userCode,
        verificationUri: code.verificationUri, expiresAt: DateTime.now().add(code.expiresIn));
      var interval = code.interval;
      while (true) {
        await wait(interval);
        if (!_live(attempt)) return;
        final poll = await github.pollToken(clientId, code);
        if (!_live(attempt)) return;
        switch (poll.status) {
          case GitHubPollStatus.pending:
            continue;
          case GitHubPollStatus.slowDown:
            interval += const Duration(seconds: 5);
            continue;
          case GitHubPollStatus.expired || GitHubPollStatus.denied:
            state = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut,
              error: poll.status == GitHubPollStatus.expired ? WorkshopAccountError.expired : WorkshopAccountError.denied);
            return;
          case GitHubPollStatus.token:
            final token = poll.token!;
            final user = await github.user(token);
            if (!_live(attempt)) return;
            // Written before the state changes, so a sign-out that arrives
            // meanwhile deletes after this write rather than before it.
            await _inOrder(() async {
              try {
                await store.write(workshopAccountKey, jsonEncode({'token': token, 'id': user.id, 'login': user.login}));
              } on Object {
                // Still signed in for this run; the next start asks again.
              }
              // Cancelled while the write ran: what was just stored must not
              // sign the person in on the next start.
              if (!_live(attempt)) {
                try {
                  await store.delete(workshopAccountKey);
                } on Object {
                  // Restored next start; the person can sign out from there.
                }
              }
            });
            if (!_live(attempt)) return;
            state = WorkshopAccountState(phase: WorkshopAccountPhase.signedIn, id: user.id, login: user.login,
              credential: WorkshopAccountCredential(token));
            return;
        }
      }
    } on Object catch (error) {
      if (!_live(attempt)) return;
      final code = error is WorkshopException ? error.code : null;
      state = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut,
        error: code == 'workshop_account_unconfigured' || code == 'workshop_unconfigured'
            ? WorkshopAccountError.unconfigured : WorkshopAccountError.network);
    }
  }

  /// Stops waiting for approval. A code already approved on GitHub just
  /// expires unused. A sheet closing as the app shuts down may call this late.
  void cancelSignIn() {
    if (!ref.mounted || state.phase == WorkshopAccountPhase.restoring || state.phase == WorkshopAccountPhase.signedIn) return;
    _attempt++;
    state = _signedOut;
  }

  /// Forgets the token on this phone. Throws, and stays signed in, when the
  /// stored copy cannot be deleted: it would come back on the next start.
  Future<void> signOut() async {
    _attempt++;
    final store = _store;
    await _inOrder(() => store.delete(workshopAccountKey));
    if (ref.mounted) state = _signedOut;
  }

  /// The Worker answered account_auth_invalid: GitHub no longer accepts this
  /// token (revoked, or the App's access removed), so ask for a new sign-in.
  Future<void> markInvalid() async {
    if (state.phase != WorkshopAccountPhase.signedIn) return;
    _attempt++;
    state = _signedOut;
    final store = _store;
    try {
      await _inOrder(() => store.delete(workshopAccountKey));
    } on Object {
      // The next start restores it, the Worker refuses it again, and it ends here.
    }
  }
}

final workshopAccountProvider = NotifierProvider<WorkshopAccountController, WorkshopAccountState>(
  WorkshopAccountController.new,
);
