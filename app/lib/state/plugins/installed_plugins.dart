part of '../plugins_state.dart';

// ── Active host ──────────────────────────────────────────────────────────────

/// What plugins can be managed on: the active host's client and what its
/// carrier allows.
class PluginHost {
  const PluginHost({
    required this.client,
    required this.label,
    required this.kind,
    this.safeMode = false,
    this.installRefused = false,
  });

  factory PluginHost.of(HostConnection connection, {bool safeMode = false, bool installRefused = false}) => PluginHost(
    client: connection.client,
    label: connection.label,
    kind: connection.kind,
    safeMode: safeMode,
    installRefused: installRefused,
  );

  final DshClient client;
  final String label;
  final HostKind kind;

  bool get isLocal => kind == HostKind.local;

  /// The local engine runs a clean repair profile with the plugin manager off:
  /// no installs or removals until it's back to normal.
  final bool safeMode;

  /// The engine says it takes no market installs, updates or removals
  /// (HarmonyOS's own), so there is nothing to offer and no command to show.
  final bool installRefused;

  /// The relay's allow-list has no install/remove; there the app shows the
  /// command to run on that computer instead.
  bool get canInstall => !safeMode && !installRefused && client.canInstallPlugins;
}

/// The on-device engine runs in safe mode. A seam of its own so plugin state
/// doesn't need the native runtime (tests override it).
final localSafeModeProvider = Provider<bool>(
  (ref) => ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode)),
);

final pluginHostProvider = Provider<PluginHost?>((ref) {
  final connection = ref.watch(readListLiveConnectionProvider);
  if (connection == null) return null;
  final safeMode = connection.isLocal && ref.watch(localSafeModeProvider);
  final installRefused = ref.watch(operatingSystemProvider) == 'ohos' && ref.watch(marketInstallRefusedProvider);
  return PluginHost.of(connection, safeMode: safeMode, installRefused: installRefused);
});

// ── Installed bundles ────────────────────────────────────────────────────────

/// How a bundle shows up on 「已安装」.
enum BundleGroup {
  /// Third-party bundles the profile depends on (and selected names with a
  /// problem).
  installed,

  /// Official optional bundles shipped with DSH: switch only.
  official,

  /// Official on-demand entries not installed yet.
  onDemand,

  /// Installation-provided infrastructure (dsh-base, web-app, ...): hidden.
  hidden,
}

BundleGroup bundleGroup(PluginBundle bundle) {
  if (bundle.installed) {
    return bundle.official ? BundleGroup.official : BundleGroup.installed;
  }
  if (bundle.optional) return BundleGroup.official;
  if (bundle.isOnDemand) return BundleGroup.onDemand;
  // Selected but broken names (`not-bundle`, unreadable files) stay visible.
  if (bundle.error != null && bundle.enabled && !bundle.official) {
    return BundleGroup.installed;
  }
  return BundleGroup.hidden;
}

/// A confirmed uninstall waiting out its undo window: nothing reaches the
/// Host before the window ends. [undo] drops it; [commitNow] ends the window
/// early.
class PendingPluginRemoval {
  PendingPluginRemoval(this.bundle, this.cancel);
  final PluginBundle bundle;

  /// Drops the plan if nothing has been sent yet.
  final bool Function() cancel;
  final _done = Completer<PluginOperationResult?>();
  final _windowClosed = Completer<void>();
  Timer? _timer;
  bool _started = false;
  bool _committing = false;
  bool _undone = false;
  late bool Function() _commitNow;
  bool get canUndo => !_windowClosed.isCompleted;
  Future<void> get windowClosed => _windowClosed.future;

  /// The Host's answer; null when the plan was dropped before sending.
  Future<PluginOperationResult?> get done => _done.future;

  /// 撤销: [cancel], remembered as the user's choice.
  bool undo() {
    if (!canUndo || _committing) return false;
    _undone = true;
    if (cancel()) return true;
    _undone = false;
    return false;
  }

  /// Uninstalls now instead of when the window ends: the app is leaving the
  /// screen, or a newer undo notice takes this one's place.
  bool commitNow() => _commitNow();

  /// Dropped with 撤销.
  bool get undone => _undone;

  /// The removal has been sent to the Host; it can no longer be taken back.
  bool get sent => _committing;
  void _closeWindow() {
    _timer?.cancel();
    if (!_windowClosed.isCompleted) _windowClosed.complete();
  }
}

/// `pluginManager/listBundles` of the active host; refreshed on
/// `plugin-manager/changed`. Null while disconnected.
class InstalledPluginsController extends AsyncNotifier<List<PluginBundle>?> {
  DshClient? _client;
  int _loadSeq = 0;
  Future<List<PluginBundle>>? _buildRead;
  List<PluginBundle> _latest = const [];
  final _removals = <String, PendingPluginRemoval>{};
  static const removalUndoWindow = Duration(seconds: 4);

  List<PluginBundle> _visible(List<PluginBundle> bundles) {
    final cache = ref.read(readListCacheProvider);
    return cache.derive([
      for (final b in bundles)
        if (!_removals.containsKey(b.name)) b,
    ], cache.origin(bundles));
  }

  void _showLatest() {
    if (ref.mounted && state.hasValue) state = AsyncData(_visible(_latest));
  }

  bool cancelRemoval(String name) {
    final pending = _removals[name];
    if (pending == null || pending._committing) return false;
    _removals.remove(name);
    pending._closeWindow();
    pending._done.complete(null);
    _showLatest();
    return true;
  }

  static Object _bundleIdentity(PluginBundle b) => (
    b.name,
    b.version,
    b.source,
    b.installTargetSpec,
    b.installTargetVersion,
    b.installed,
    b.enabled,
    b.removable,
    b.official,
    b.availability,
  );

  /// Keep the real inventory separate: refreshes must not resurrect waiting rows.
  PendingPluginRemoval scheduleRemoval(PluginBundle bundle) {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.hidden ||
        lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.detached) {
      throw const DshClosedException('app is not visible');
    }
    final existing = _removals[bundle.name];
    if (existing != null) {
      if (!existing.canUndo) throw StateError('uninstall in progress');
      return existing;
    }
    final host = ref.read(pluginHostProvider);
    final client = _client;
    final installing =
        ref.exists(pluginInstallsProvider) && (ref.read(pluginInstallsProvider)[bundle.name]?.isActive ?? false);
    final current = _latest.where((b) => b.name == bundle.name).firstOrNull;
    if (host == null ||
        client == null ||
        !host.canInstall ||
        !bundle.removable ||
        installing ||
        current == null ||
        _bundleIdentity(current) != _bundleIdentity(bundle)) {
      throw const DshClosedException('plugin owner or bundle changed');
    }
    final generation = client.mux.generation;
    final ready = client.mux.lastReadyGenerationNumber;
    late final PendingPluginRemoval pending;
    pending = PendingPluginRemoval(
      bundle,
      () => identical(_removals[bundle.name], pending) && cancelRemoval(bundle.name),
    );
    bool currentOwner() =>
        ref.mounted &&
        identical(_removals[bundle.name], pending) &&
        identical(ref.read(pluginHostProvider), host) &&
        identical(_client, client) &&
        identical(client.mux.generation, generation) &&
        client.mux.lastReadyGenerationNumber == ready;
    Future<void> commit() async {
      if (pending._started) return;
      pending._started = true;
      if (!currentOwner()) {
        pending.cancel();
        return;
      }
      try {
        // The remove API has no expectedRevision. Re-read immediately before
        // dispatch; a race with an external process after this read is a Host limit.
        final inventory = await client.listBundles();
        if (!currentOwner() || !pending.canUndo) {
          pending.cancel();
          return;
        }
        final fresh = inventory.where((b) => b.name == bundle.name).firstOrNull;
        if (fresh == null || _bundleIdentity(fresh) != _bundleIdentity(bundle)) {
          _latest = inventory;
          pending.cancel();
          return;
        }
        pending._committing = true;
        pending._closeWindow();
        final result = await client.removeBundle(bundle.name);
        if (result.succeeded && currentOwner()) {
          final cache = ref.read(readListCacheProvider);
          _latest = cache.derive([
            for (final b in _latest)
              if (b.name != bundle.name) b,
          ], cache.origin(_latest));
        }
        if (!pending._done.isCompleted) pending._done.complete(result);
      } on Object catch (error, stack) {
        if (!pending._done.isCompleted) pending._done.completeError(error, stack);
      } finally {
        pending._closeWindow();
        if (identical(_removals[bundle.name], pending)) {
          _removals.remove(bundle.name);
          _showLatest();
          if (ref.mounted && identical(_client, client)) {
            unawaited(refresh().catchError((Object _) {}));
          }
        }
      }
    }

    pending._commitNow = () {
      if (!identical(_removals[bundle.name], pending) || !pending.canUndo || pending._started) return false;
      pending._timer?.cancel();
      unawaited(commit());
      return true;
    };
    _removals[bundle.name] = pending;
    // Leaving the screen (Home, recents, another app on top; the process may be
    // killed from there) uninstalls at once: the notice said 已卸载, and the
    // undo it offered is gone with the screen.
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) pending.commitNow();
      },
    );
    unawaited(pending.windowClosed.then((_) => lifecycle.dispose()));
    pending._timer = Timer(removalUndoWindow, () => unawaited(commit()));
    _showLatest();
    return pending;
  }

  @override
  Future<List<PluginBundle>?> build() async {
    final r = ref;
    // Provider rebuild means the previous owner lease ended. No deferred work
    // is persisted across app exit or a new Host connection.
    for (final pending in _removals.values.toList()) {
      pending._closeWindow();
      if (!pending._done.isCompleted) pending._done.complete(null);
    }
    _removals.clear();
    final seq = ++_loadSeq;
    final host = r.watch(pluginHostProvider);
    final identity = r.watch(readListIdentityProvider);
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next) {
        for (final name in _removals.keys.toList()) {
          cancelRemoval(name);
        }
      }
    });
    _client = host?.client;
    if (host == null) {
      _buildRead = null;
      return null;
    }
    final ownerChanges = host.client.mux.states.listen((_) {
      if (seq != _loadSeq) return;
      for (final name in _removals.keys.toList()) {
        cancelRemoval(name);
      }
    });
    Timer? debounce;
    Future<void> refreshChanged() async {
      final before = _loadSeq;
      if (state.isLoading) {
        try {
          await future;
        } on Object {
          // The failed initial read is already in state. This later Host event
          // still requires a fresh read, just as it does after an old success.
        }
      }
      if (r.mounted && before == _loadSeq) await refresh();
    }

    void scheduleRefresh() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 300), () => unawaited(refreshChanged().catchError((Object _) {})));
    }

    final sub = host.client.pluginManagerEvents.listen((event) {
      if (event is PluginManagerChangedEvent) scheduleRefresh();
    });
    final ready = host.client.hostEvents.listen((event) {
      if (event is HostReadyEvent) scheduleRefresh();
    });
    ref.onDispose(() {
      unawaited(ownerChanges.cancel());
      for (final pending in _removals.values.toList()) {
        pending._closeWindow();
        if (!pending._done.isCompleted) pending._done.complete(null);
      }
      _removals.clear();
      debounce?.cancel();
      unawaited(sub.cancel());
      unawaited(ready.cancel());
    });
    final bundles = await (_buildRead = host.client.listBundles());
    if (!r.mounted) return null;
    if (seq != _loadSeq) return state.value;
    final cache = r.read(readListCacheProvider);
    cache.stamp(bundles, identity, host.client);
    cache.put(readListKey(identity, ReadListKind.plugins), bundles, () => CachedPlugins(bundles));
    _latest = bundles;
    _counted(bundles);
    return _visible(bundles);
  }

  /// How many plugins 「已安装」 lists, for the usage statistics.
  void _counted(List<PluginBundle> bundles) => ref
      .read(usageStatsProvider.notifier)
      .plugins(bundles.where((b) => bundleGroup(b) == BundleGroup.installed && b.installed).length);

  /// Re-reads the list; keeps the old one (and rethrows) on failure.
  Future<void> refresh() async {
    final r = ref;
    final client = _client;
    if (client == null) return;
    // A build is already a refresh. Coalesce entry/HostReady kicks until
    // that build settles, so its Future cannot later overwrite a manual read.
    if (state.isLoading && _buildRead != null) {
      await _buildRead;
      return;
    }
    final identity = r.read(readListIdentityProvider);
    final seq = ++_loadSeq;
    final cache = r.read(readListCacheProvider);
    final activity = cache.beginRefresh(ReadListKind.plugins, identity);
    try {
      final bundles = await client.listBundles();
      if (r.mounted && seq == _loadSeq && identical(client, _client)) {
        final cache = r.read(readListCacheProvider);
        cache.stamp(bundles, identity, client);
        cache.put(readListKey(identity, ReadListKind.plugins), bundles, () => CachedPlugins(bundles));
        _latest = bundles;
        for (final pending in _removals.values.toList()) {
          final fresh = bundles.where((b) => b.name == pending.bundle.name).firstOrNull;
          if (fresh == null || _bundleIdentity(fresh) != _bundleIdentity(pending.bundle)) {
            cancelRemoval(pending.bundle.name);
          }
        }
        state = AsyncData(_visible(bundles));
        cache.finishRefresh(ReadListKind.plugins, activity);
        _counted(bundles);
      }
    } on Object catch (error, stack) {
      if (r.mounted && seq == _loadSeq && identical(client, _client)) {
        cache.finishRefresh(ReadListKind.plugins, activity, failed: true);
        if (!state.hasValue) state = AsyncError(error, stack);
      }
      rethrow;
    }
  }

  /// Switches a bundle layer (optimistic; reverts and rethrows on failure).
  Future<PluginOperationResult> setEnabled(PluginBundle bundle, bool enabled) async {
    if (_removals[bundle.name]?._committing == true) throw StateError('uninstall in progress');
    cancelRemoval(bundle.name);
    final r = ref;
    final client = _client;
    if (client == null) throw const DshClosedException('not connected');
    _patch(bundle.name, enabled);
    try {
      final result = await client.setBundleEnabled(bundle.name, enabled);
      if (!r.mounted || !identical(client, _client)) return result;
      if (!result.succeeded) _patch(bundle.name, bundle.enabled);
      unawaited(refresh().catchError((Object _) {}));
      return result;
    } on Object {
      if (r.mounted && identical(client, _client)) _patch(bundle.name, bundle.enabled);
      rethrow;
    }
  }

  /// Removes a profile bundle (files and selection; settings stay).
  Future<PluginOperationResult> remove(PluginBundle bundle) async {
    if (_removals[bundle.name]?._committing == true) throw StateError('uninstall in progress');
    cancelRemoval(bundle.name);
    final r = ref;
    final client = _client;
    if (client == null) throw const DshClosedException('not connected');
    final result = await client.removeBundle(bundle.name);
    if (r.mounted && identical(client, _client)) await refresh().catchError((Object _) {});
    return result;
  }

  void _patch(String name, bool enabled) {
    if (!ref.mounted || !state.hasValue) return;
    final cache = ref.read(readListCacheProvider);
    _latest = cache.derive(
      [for (final b in _latest) b.name == name ? _withEnabled(b, enabled) : b],
      cache.origin(_latest),
      confirmed: false,
    );
    _showLatest();
  }

  static PluginBundle _withEnabled(PluginBundle b, bool enabled) => PluginBundle(
    name: b.name,
    official: b.official,
    availability: b.availability,
    installTargetSpec: b.installTargetSpec,
    installTargetVersion: b.installTargetVersion,
    version: b.version,
    meta: b.meta,
    description: b.description,
    enabled: enabled,
    installed: b.installed,
    source: b.source,
    optional: b.optional,
    removable: b.removable,
    readOnlyReason: b.readOnlyReason,
    error: b.error,
    rows: b.rows,
    overrides: b.overrides,
  );
}

final installedPluginsProvider = AsyncNotifierProvider<InstalledPluginsController, List<PluginBundle>?>(
  InstalledPluginsController.new,
  retry: (_, _) => null,
);

final pluginListViewProvider = Provider.autoDispose<ReadListView<CachedPlugins>>((ref) {
  final source = ref.watch(installedPluginsProvider);
  final identity = ref.watch(readListIdentityProvider);
  final host = ref.watch(pluginHostProvider);
  final cache = ref.watch(readListCacheProvider);
  ref.watch(readListCacheChangesProvider);
  final raw = source.value;
  final activity = cache.refresh(ReadListKind.plugins, identity, raw);
  final current = raw != null && cache.current(raw, identity, host?.client);
  final ready =
      current && !source.isLoading && !source.hasError && activity?.pending != true && activity?.failed != true;
  final status = source.hasError || activity?.failed == true
      ? ReadListStatus.failed
      : host == null
      ? ReadListStatus.offline
      : ReadListStatus.updating;
  if (current) {
    return ReadListView(authoritative: true, readOnly: !ready, status: ready ? ReadListStatus.current : status);
  }
  return ReadListView(
    value: cache.get<CachedPlugins>(readListKey(identity, ReadListKind.plugins)),
    readOnly: true,
    status: status,
  );
});

/// Install state of a market entry against the installed list.
enum MarketInstallStatus { notInstalled, installed, updateAvailable }

MarketInstallStatus marketInstallStatus(MarketPlugin plugin, List<PluginBundle>? bundles) {
  if (bundles == null) return MarketInstallStatus.notInstalled;
  for (final bundle in bundles) {
    if (bundle.name != plugin.name || !(bundle.installed || bundle.availability == 'profile')) {
      continue;
    }
    final installed = bundle.version;
    if (installed != null && isExactSemver(installed) && compareSemver(plugin.latest.version, installed) > 0) {
      return MarketInstallStatus.updateAvailable;
    }
    return MarketInstallStatus.installed;
  }
  return MarketInstallStatus.notInstalled;
}
