import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/github_device_flow.dart' show githubWebOrigin;
import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart' show workshopLocalError;
import 'workshop_account_state.dart';
import 'workshop_dependencies.dart';
import 'workshop_preferences.dart';

/// Display both sources and return this exact object when confirming.
class WorkshopDisclosure {
  const WorkshopDisclosure._(this.worker, this.account);
  final Uri worker, account;
}

class WorkshopAccessState {
  const WorkshopAccessState({required this.session, this.loading = false,
    this.accountRestoring = false, this.signedIn = false, this.worker, this.account, this.accountId,
    this.capabilities, this.disclosure, this.disclosureAccepted = false,
    this.disclosureSaved = false, this.savingDisclosure = false,
    this.error, this.preferenceError});

  /// In-memory account/deployment generation. It contains no credential.
  final Object session;
  final bool loading, accountRestoring, signedIn;
  final Uri? worker, account;
  final int? accountId;
  final WorkshopCapabilities? capabilities;
  final WorkshopDisclosure? disclosure;
  final bool disclosureAccepted, disclosureSaved, savingDisclosure;
  final WorkshopException? error, preferenceError;

  bool get canAuthenticate => !loading && signedIn && error == null &&
      capabilities != null && disclosureAccepted;
  bool get uploadsEnabled => capabilities?.features.uploads ?? false;
  /// The deployment registered a GitHub OAuth App, so signing in can work.
  bool get signInAvailable => capabilities?.account.clientId != null;
  bool get companionEnabled => capabilities?.features.companion ?? false;
  bool canSubmit(String kind) => canAuthenticate && accountId != null && uploadsEnabled &&
      capabilities!.kinds.contains(kind) &&
      (kind == 'pet' || kind == 'theme' || kind == 'companion' && companionEnabled);

  WorkshopAccessState copyWith({bool? loading, bool? disclosureAccepted,
    bool? disclosureSaved, bool? savingDisclosure, WorkshopException? error,
    bool clearError = false, WorkshopException? preferenceError,
    bool clearPreferenceError = false}) => WorkshopAccessState(
    session: session, loading: loading ?? this.loading,
    accountRestoring: accountRestoring, signedIn: signedIn, worker: worker, account: account, accountId: accountId,
    capabilities: capabilities, disclosure: disclosure,
    disclosureAccepted: disclosureAccepted ?? this.disclosureAccepted,
    disclosureSaved: disclosureSaved ?? this.disclosureSaved,
    savingDisclosure: savingDisclosure ?? this.savingDisclosure,
    error: clearError ? null : error ?? this.error,
    preferenceError: clearPreferenceError ? null : preferenceError ?? this.preferenceError,
  );
}

/// One operation's captured context; never put this object in page state.
class WorkshopAuthorization {
  const WorkshopAuthorization({required this.session, required this.client,
    required this.credential, required this.requestScope, this.accountId});
  final Object session;
  final WorkshopClient client;
  final WorkshopCredential credential;
  /// Stable public account identity. Signing in again with the same GitHub
  /// account must not create a new idempotency scope.
  final String? requestScope;
  final int? accountId;
}

class _AccessContext {
  _AccessContext({required this.session, required this.client, required this.credential,
    required this.signedIn, required this.restoring, required this.preferences, required this.userId});
  final Object session;
  final Future<WorkshopClient> client;
  final WorkshopAccountCredential? credential;
  final bool signedIn, restoring;
  final int? userId;
  final WorkshopPreferences preferences;
}

class WorkshopAccessController extends Notifier<WorkshopAccessState> {
  _AccessContext? _context;
  Future<void> _loaded = Future<void>.value();
  int _load = 0;
  int? _knownUserId;
  final _confirmedHere = <String>{};

  @override
  WorkshopAccessState build() {
    // Only a signed-in account's credential counts; waiting for a code is
    // still signed out and must not start a new session.
    final auth = ref.watch(workshopAccountProvider.select((value) => (
      value.phase == WorkshopAccountPhase.signedIn ? value.credential : null,
      value.phase == WorkshopAccountPhase.restoring, value.id)));
    final client = ref.watch(workshopClientProvider.future);
    final preferences = ref.watch(workshopPreferencesProvider);
    final profileId = auth.$3;
    final userId = profileId != null && profileId > 0 ? profileId : null;
    final previous = _context;
    final sameAccount = previous != null &&
        identical(previous.credential, auth.$1) && identical(previous.client, client) &&
        identical(previous.preferences, preferences) &&
        (_knownUserId == null || userId == null || _knownUserId == userId);
    _knownUserId = sameAccount ? userId ?? _knownUserId : userId;
    final context = _AccessContext(session: sameAccount ? previous.session : Object(),
      client: client, credential: auth.$1, signedIn: auth.$1 != null,
      restoring: auth.$2, preferences: preferences, userId: userId);
    _context = context;
    _loaded = _refresh(context, ++_load);
    return WorkshopAccessState(session: context.session, loading: true,
      accountRestoring: context.restoring, signedIn: context.signedIn, accountId: context.userId);
  }

  bool _current(_AccessContext context, [int? load]) {
    if (!ref.mounted) return false;
    final current = state;
    return identical(current.session, context.session) && identical(_context, context) &&
        (load == null || load == _load);
  }

  static String _pair(Uri worker, Uri account) => jsonEncode([worker.toString(), account.toString()]);

  Future<void> refresh() async {
    retryWorkshopDependencies(ref);
    final current = state;
    final context = _context!;
    state = current.copyWith(loading: true, clearError: true);
    _loaded = _refresh(context, ++_load);
    await _loaded;
  }

  Future<void> confirmDisclosure(WorkshopDisclosure offered) async {
    final current = state;
    final context = _context!;
    if (!identical(offered, current.disclosure) || current.loading || !current.signedIn) {
      state = state.copyWith(error: const WorkshopException('workshop_confirmation_stale'));
      return;
    }
    if (state.savingDisclosure) return;
    _confirmedHere.add(_pair(offered.worker, offered.account));
    state = state.copyWith(disclosureAccepted: true, disclosureSaved: false,
      savingDisclosure: true, clearPreferenceError: true, clearError: true);
    try {
      await context.preferences.acceptDisclosure(offered.worker, offered.account);
      if (_current(context) && identical(state.disclosure, offered)) {
        state = state.copyWith(disclosureSaved: true, savingDisclosure: false);
      }
    } on Object {
      if (_current(context) && identical(state.disclosure, offered)) {
        state = state.copyWith(savingDisclosure: false,
          preferenceError: const WorkshopException('workshop_preferences'));
      }
    }
  }

  /// Sign-in/sign-out stay in workshopAccountProvider. Capture this once and
  /// ignore its results after the account/deployment session is replaced.
  Future<WorkshopAuthorization> authorize() async {
    final session = state.session;
    final context = _context!;
    final load = _load;
    await _loaded;
    if (!identical(session, context.session) || !_current(context, load)) workshopInvalid('workshop_cancelled');
    final current = state;
    if (!context.signedIn || context.credential == null) workshopInvalid('workshop_account_auth_required');
    if (current.error case final error?) throw error;
    if (current.account == null || current.capabilities == null) workshopInvalid('workshop_account_origin');
    if (!current.disclosureAccepted) workshopInvalid('workshop_consent_required');
    final client = await context.client;
    if (!_current(context, load)) workshopInvalid('workshop_cancelled');
    final credential = WorkshopCredential.forConsentedWorker(worker: client.origin, account: current.account!,
      token: context.credential!.token, disclosureAccepted: true);
    final scope = context.userId == null ? null : jsonEncode([
      client.origin.toString(), current.account.toString(), context.userId,
    ]);
    return WorkshopAuthorization(session: context.session, client: client,
      credential: credential, requestScope: scope, accountId: context.userId);
  }

  Future<void> _refresh(_AccessContext context, int load) async {
    try {
      final client = await context.client;
      if (!_current(context, load)) return;
      final capabilities = await client.capabilities();
      if (!_current(context, load)) return;
      // This App signs in with GitHub only; a Worker expecting another
      // account system could not use its tokens.
      final account = githubWebOrigin;
      if (capabilities.account.origin != account) workshopInvalid('workshop_account_origin');
      var saved = false;
      WorkshopException? preferenceError;
      try {
        saved = await context.preferences.disclosureAccepted(client.origin, account);
      } on Object {
        preferenceError = const WorkshopException('workshop_preferences');
      }
      if (!_current(context, load)) return;
      state = WorkshopAccessState(session: context.session, signedIn: context.signedIn,
        accountRestoring: context.restoring, worker: client.origin, account: account, accountId: context.userId,
        capabilities: capabilities,
        disclosure: context.signedIn ? WorkshopDisclosure._(client.origin, account) : null,
        disclosureAccepted: saved || _confirmedHere.contains(_pair(client.origin, account)),
        disclosureSaved: saved, preferenceError: preferenceError);
    } on Object catch (error) {
      if (_current(context, load)) {
        state = WorkshopAccessState(session: context.session, signedIn: context.signedIn,
          accountRestoring: context.restoring, accountId: context.userId, error: workshopLocalError(error));
      }
    }
  }
}

final workshopAccessProvider = NotifierProvider<WorkshopAccessController, WorkshopAccessState>(
  WorkshopAccessController.new,
);

/// Where an author operation records its failure, while its session is still
/// current: a token the Worker refused is forgotten so the page asks for a new
/// sign-in instead of offering to retry with it.
void workshopForgetRefusedAccount(Ref ref, WorkshopException failure) {
  if (failure.code == 'workshop_account_auth_invalid') {
    unawaited(ref.read(workshopAccountProvider.notifier).markInvalid());
  }
}
