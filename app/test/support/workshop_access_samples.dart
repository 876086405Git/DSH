part of 'workshop_page_samples.dart';

Future<WorkshopAccessState> _access({WorkshopAccountState? account, bool accepted = false,
  bool uploads = true, bool companion = true, Uri? responseAccount, String? failure,
  bool readPreferencesFails = false, bool unconfigured = false}) async {
  final client = AuthClient(account: responseAccount);
  client.value = WorkshopCapabilities.fromJson(workshopCaps(
    account: (responseAccount ?? authAccount).toString(), uploads: uploads, companion: companion));
  if (failure != null) client.readCapabilities = () async => throw WorkshopException(failure);
  final preferences = AuthPreferences();
  if (accepted) preferences.accepted.add(preferences.pair(authWorker, authAccount));
  if (readPreferencesFails) {
    preferences.readDisclosure = (_, _) async => throw const WorkshopException('workshop_preferences');
  }
  final harness = AuthHarness(client: client, preferences: preferences, initial: account,
    loadClient: unconfigured ? (_) async => throw const WorkshopException('workshop_unconfigured') : null);
  try {
    return await authReady(harness.container);
  } finally { harness.dispose(); }
}

Future<WorkshopAccessState> accessLoading() async {
  final harness = AuthHarness();
  final initial = harness.state;
  try { return initial; }
  finally { await authReady(harness.container); harness.dispose(); }
}

Future<WorkshopAccessState> accessAccountRestoring() => _access(account: const WorkshopAccountState(phase: WorkshopAccountPhase.restoring));
Future<WorkshopAccessState> accessSignedOut() => _access(
  account: authSignedOut);
Future<WorkshopAccessState> accessDisclosureRequired() => _access();
Future<WorkshopAccessState> accessProfilePending() => _access(account: authSignedIn(userId: null), accepted: true);
Future<WorkshopAccessState> accessUploadsDisabled() => _access(accepted: true, uploads: false);
Future<WorkshopAccessState> accessCompanionDisabled() => _access(accepted: true, companion: false);
Future<WorkshopAccessState> accessAccountMismatch() => _access(responseAccount: Uri.parse('https://another-account.example'));
Future<WorkshopAccessState> accessNetworkFailed() => _access(failure: 'workshop_network');
Future<WorkshopAccessState> accessUnconfigured() => _access(unconfigured: true);
Future<WorkshopAccessState> accessDisclosureReadFailed() => _access(readPreferencesFails: true);

Future<WorkshopAccessState> _confirmAccess({bool saving = false, bool fail = false, bool stale = false}) async {
  final gate = _SampleGate();
  final preferences = AuthPreferences()..writeDisclosure = (_, _) async {
    if (saving) await gate.wait();
    if (fail) throw const WorkshopException('workshop_preferences');
  };
  final harness = AuthHarness(preferences: preferences);
  Future<void>? pending;
  try {
    final ready = await authReady(harness.container);
    final offered = ready.disclosure;
    if (offered == null) throw StateError('Signed-in sample was not offered disclosure');
    if (stale) await harness.controller.refresh();
    pending = harness.controller.confirmDisclosure(offered);
    if (saving) return await _sampleWhile(pending, gate, () => harness.state);
    await pending;
    return harness.state;
  } finally {
    gate.release();
    if (pending != null) await authSettled(pending);
    harness.dispose();
  }
}

Future<WorkshopAccessState> accessSavingDisclosure() => _confirmAccess(saving: true);
Future<WorkshopAccessState> accessDisclosureSaved() => _confirmAccess();
Future<WorkshopAccessState> accessDisclosureSaveFailed() => _confirmAccess(fail: true);
Future<WorkshopAccessState> accessStaleDisclosure() => _confirmAccess(stale: true);

const _samplePetSource = WorkshopPublishSource(kind: 'pet', localId: 'user-moon-cat',
  name: '月白', author: '阿禾', license: 'CC-BY-4.0', source: 'https://samples.example/characters/moon-cat');
const _sampleCompanionSource = WorkshopPublishSource(kind: 'companion', localId: 'companion',
  author: '阿澄 🎨', license: 'CC-BY-4.0', source: 'https://samples.example/characters/cloud-traveller');

Future<WorkshopPublishSources> _sourcesReady(ProviderContainer container) {
  final done = Completer<WorkshopPublishSources>();
  final subscription = container.listen(workshopPublishSourcesProvider, (_, next) {
    if (!next.loading && !done.isCompleted) done.complete(next);
  }, fireImmediately: true, onError: (Object error, StackTrace stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  });
  return done.future.whenComplete(subscription.close);
}

Future<WorkshopPublishSources> _sources({bool initial = false, bool empty = false,
  String? issueKind, bool refreshFailure = false, bool refreshing = false}) async {
  final gate = _SampleGate();
  var reads = 0;
  final container = ProviderContainer(overrides: [
    workshopSourcesLoaderProvider.overrideWithValue(() async {
      reads++;
      if (reads > 1 && refreshing) await gate.wait();
      if (reads > 1 && refreshFailure) throw const WorkshopException('workshop_storage');
      return WorkshopPublishSources(values: empty ? [] : [
        if (issueKind != 'pet') _samplePetSource,
        if (issueKind != 'companion') _sampleCompanionSource,
      ], issues: issueKind == null ? {} : {
        issueKind: WorkshopException(issueKind == 'companion' ? 'workshop_companion_unavailable' : 'workshop_storage'),
      });
    }),
  ]);
  container.listen(workshopPublishSourcesProvider, (_, _) {});
  final first = container.read(workshopPublishSourcesProvider);
  Future<void>? pending;
  try {
    await _sourcesReady(container);
    if (initial) return first;
    if (refreshFailure || refreshing) {
      pending = container.read(workshopPublishSourcesProvider.notifier).refresh();
      if (refreshing) return await _sampleWhile(pending, gate, () => container.read(workshopPublishSourcesProvider));
      await pending;
    }
    return await container.read(workshopPublishSourcesProvider);
  } finally {
    gate.release();
    if (pending != null) await stateSettled(pending);
    container.dispose();
  }
}

Future<WorkshopPublishSources> publishSourcesLoading() => _sources(initial: true);
Future<WorkshopPublishSources> publishSourcesChoices() => _sources();
Future<WorkshopPublishSources> publishSourcesEmpty() => _sources(empty: true, issueKind: 'companion');
Future<WorkshopPublishSources> publishSourcesPetFailed() => _sources(issueKind: 'pet');
Future<WorkshopPublishSources> publishSourcesCompanionMissing() => _sources(issueKind: 'companion');
Future<WorkshopPublishSources> publishSourcesRefreshing() => _sources(refreshing: true);
Future<WorkshopPublishSources> publishSourcesRefreshFailedKeepsChoices() => _sources(refreshFailure: true);
