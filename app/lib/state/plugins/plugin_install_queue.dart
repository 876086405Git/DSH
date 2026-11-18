part of '../plugins_state.dart';

// ── Install queue ────────────────────────────────────────────────────────────

/// What to install. [replaceInstalled] removes the installed copy first
/// (DSH has no in-place upgrade).
class PluginInstallRequest {
  const PluginInstallRequest({
    required this.name,
    required this.spec,
    this.title,
    this.registry,
    this.replaceInstalled = false,
    this.finishesUpdate = false,
    this.approvedBuilds = const [],
    this.published,
    this.integrity,
  });

  final String name;
  final String spec;
  final String? title;
  final String? registry;
  final bool replaceInstalled;

  /// A retry of an update whose first attempt already removed the old copy.
  final bool finishesUpdate;
  final List<String> approvedBuilds;
  final DateTime? published;

  /// What the official market recorded for the npm version being installed:
  /// checked against what the registry reports before anything is removed or
  /// installed ([PluginInstallPhase.verifying]).
  final ({String version, String integrity})? integrity;

  /// An update needs an engine restart even when the Host answers `applied`:
  /// the running engine keeps executing the old module (Node's module cache)
  /// until it restarts.
  bool needsRestartAfter(PluginOperationResult result) =>
      result.needsRestart || ((replaceInstalled || finishesUpdate) && result.application == PluginApplication.applied);

  PluginInstallRequest withApprovedBuilds(List<String> builds) => PluginInstallRequest(
    name: name,
    spec: spec,
    title: title,
    registry: registry,
    finishesUpdate: replaceInstalled || finishesUpdate,
    approvedBuilds: builds,
    published: published,
    integrity: integrity,
  );
}

enum PluginInstallPhase { queued, verifying, removing, installing, applying, cancelling, succeeded, failed, cancelled }

class PluginInstallJob {
  const PluginInstallJob({
    required this.request,
    required this.requestId,
    this.phase = PluginInstallPhase.queued,
    this.registry,
    this.attempt,
    this.attempts,
    this.log = '',
    this.result,
    this.failure,
  });

  final PluginInstallRequest request;
  final String requestId;
  final PluginInstallPhase phase;

  /// Registry of the current attempt (`null` = the host's default).
  final String? registry;
  final int? attempt;
  final int? attempts;

  /// Tail of the pnpm output streamed so far.
  final String log;
  final PluginOperationResult? result;
  final PluginFailure? failure;

  bool get isActive => switch (phase) {
    PluginInstallPhase.queued ||
    PluginInstallPhase.verifying ||
    PluginInstallPhase.removing ||
    PluginInstallPhase.installing ||
    PluginInstallPhase.applying ||
    PluginInstallPhase.cancelling => true,
    _ => false,
  };

  bool get needsRestart {
    final result = this.result;
    return result != null && request.needsRestartAfter(result);
  }

  /// Cancellable until the bundle is being applied.
  bool get cancellable =>
      phase == PluginInstallPhase.queued ||
      phase == PluginInstallPhase.verifying ||
      phase == PluginInstallPhase.installing ||
      phase == PluginInstallPhase.removing;

  String get phaseLabel => switch (phase) {
    PluginInstallPhase.queued => appL10n.statePluginQueued,
    PluginInstallPhase.verifying => appL10n.marketVerifying,
    PluginInstallPhase.removing => appL10n.statePluginRemoving,
    PluginInstallPhase.installing =>
      (attempt ?? 1) > 1
          ? (attempts == null
                ? appL10n.statePluginRegistryProgressUnknown(_registryName(registry), attempt!)
                : appL10n.statePluginRegistryProgress(_registryName(registry), attempt!, attempts!))
          : appL10n.statePluginInstalling,
    PluginInstallPhase.applying => appL10n.statePluginApplying,
    PluginInstallPhase.cancelling => appL10n.statePluginCancelling,
    PluginInstallPhase.succeeded => needsRestart ? appL10n.statePluginInstalledRestart : appL10n.commonInstalled,
    PluginInstallPhase.failed => failure?.title ?? appL10n.statePluginInstallFailed,
    PluginInstallPhase.cancelled => appL10n.commonCancelled,
  };

  PluginInstallJob copyWith({
    PluginInstallPhase? phase,
    String? Function()? registry,
    int? attempt,
    int? attempts,
    String? log,
    PluginOperationResult? result,
    PluginFailure? failure,
  }) => PluginInstallJob(
    request: request,
    requestId: requestId,
    phase: phase ?? this.phase,
    registry: registry == null ? this.registry : registry(),
    attempt: attempt ?? this.attempt,
    attempts: attempts ?? this.attempts,
    log: log ?? this.log,
    result: result ?? this.result,
    failure: failure ?? this.failure,
  );
}

/// Per-plugin installs on the active host, run one at a time (DSH holds a
/// profile lock anyway). Keyed by package name.
class PluginInstallsController extends Notifier<Map<String, PluginInstallJob>> {
  static const _logLimit = 16 * 1024;
  static final _random = Random();

  PluginHost? _host;
  int _generation = 0;
  Future<void> _tail = Future.value();
  final Set<String> _cancelledQueued = {};
  final Set<String> _cancelledRemovals = {};
  final Map<String, List<Completer<PluginInstallJob>>> _waiters = {};

  @override
  Map<String, PluginInstallJob> build() {
    _host = ref.watch(pluginHostProvider);
    _generation++;
    _tail = Future.value();
    _cancelledQueued.clear();
    return const {};
  }

  /// Queues [request]; resolves with the finished job. A plugin that is
  /// already being installed returns its running job.
  Future<PluginInstallJob> install(PluginInstallRequest request) {
    if (ref.exists(installedPluginsProvider)) {
      final removals = ref.read(installedPluginsProvider.notifier);
      if (removals._removals[request.name]?._committing == true) throw StateError('uninstall in progress');
      removals.cancelRemoval(request.name);
    }
    final host = _host;
    final running = state[request.name];
    if (running != null && running.isActive) return _waitFor(running.requestId);
    final job = PluginInstallJob(
      request: request,
      requestId: 'dsh-app-${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}',
    );
    if (host == null || !host.canInstall) {
      final failed = job.copyWith(
        phase: PluginInstallPhase.failed,
        failure: host == null
            ? PluginFailure(
                PluginFailureKind.connection,
                appL10n.commonEngineUnreachable,
                appL10n.statePluginConnectFirst,
              )
            : host.installRefused
            ? _installRefusedFailure()
            : describePluginError(const DshRemoteException('METHOD_NOT_ALLOWED', 'install not allowed')),
      );
      _put(failed);
      return Future.value(failed);
    }
    _put(job);
    final generation = _generation;
    final done = Completer<PluginInstallJob>();
    _tail = _tail.then((_) async {
      final finished = await _run(host, generation, job);
      done.complete(finished);
    });
    return done.future;
  }

  /// Stops a queued or running install (no effect once it is being applied).
  Future<void> cancel(String name) async {
    final job = state[name];
    final host = _host;
    if (job == null || !job.cancellable || host == null) return;
    if (job.phase == PluginInstallPhase.queued || job.phase == PluginInstallPhase.verifying) {
      _cancelledQueued.add(job.requestId);
      _put(job.copyWith(phase: PluginInstallPhase.cancelled, failure: describeCancelled));
      return;
    }
    if (job.phase == PluginInstallPhase.removing && host.isLocal && ref.read(operatingSystemProvider) == 'ohos') {
      // Removal has no install request to abort. Stop before the next install.
      _cancelledRemovals.add(job.requestId);
      _put(job.copyWith(phase: PluginInstallPhase.cancelling));
      return;
    }
    _put(job.copyWith(phase: PluginInstallPhase.cancelling));
    try {
      final status = await host.client.cancelInstall(job.requestId);
      if (status == PluginCancelStatus.tooLate) {
        _update(name, job.requestId, (j) => j.copyWith(phase: PluginInstallPhase.applying));
      }
    } on Object {
      _update(name, job.requestId, (j) => j.phase == PluginInstallPhase.cancelling ? j.copyWith(phase: job.phase) : j);
    }
  }

  /// Forgets a finished job (the card goes back to its plain state).
  void dismiss(String name) {
    final job = state[name];
    if (job == null || job.isActive) return;
    state = {...state}..remove(name);
  }

  static PluginFailure get describeCancelled =>
      PluginFailure(PluginFailureKind.cancelled, appL10n.statePluginInstallCancelled, appL10n.statePluginNoChanges);

  Future<PluginInstallJob> _waitFor(String requestId) {
    final completer = Completer<PluginInstallJob>();
    (_waiters[requestId] ??= []).add(completer);
    return completer.future;
  }

  Future<PluginInstallJob> _run(PluginHost host, int generation, PluginInstallJob job) async {
    final name = job.request.name;
    final requestId = job.requestId;
    if (_cancelledQueued.remove(requestId) || generation != _generation || !ref.mounted) {
      final current = ref.mounted ? state[name] : null;
      final cancelled = current?.requestId == requestId ? current! : job.copyWith(phase: PluginInstallPhase.cancelled);
      _settle(cancelled);
      return cancelled;
    }
    final client = host.client;
    final events = client.pluginManagerEvents.listen((event) {
      if (generation != _generation) return;
      switch (event) {
        case PluginInstallStateEvent(requestId: final id) when id == requestId:
          _update(name, requestId, (j) {
            if (j.phase == PluginInstallPhase.cancelling && event.phase != 'applying') {
              return j;
            }
            return switch (event.phase) {
              'installing' => j.copyWith(
                phase: PluginInstallPhase.installing,
                registry: () => event.registry,
                attempt: event.attemptIndex,
                attempts: event.attemptTotal,
              ),
              'applying' => j.copyWith(phase: PluginInstallPhase.applying),
              'cancelling' => j.copyWith(phase: PluginInstallPhase.cancelling),
              _ => j,
            };
          });
        case PluginInstallLogEvent(requestId: final id) when id == requestId && event.text.isNotEmpty:
          _update(name, requestId, (j) {
            final log = j.log + event.text;
            return j.copyWith(log: log.length > _logLimit ? log.substring(log.length - _logLimit) : log);
          });
        default:
          break;
      }
    });
    PluginInstallJob finish(PluginInstallJob Function(PluginInstallJob) change) {
      _update(name, requestId, change);
      final current = ref.mounted ? state[name] : null;
      // A newer host may be installing the same package. Its visible job is
      // never the result of this request, including duplicate callers.
      final finished = current?.requestId == requestId ? current! : change(job);
      _settle(finished);
      return finished;
    }

    try {
      if (job.request.integrity case final expected?) {
        _update(name, requestId, (j) => j.copyWith(phase: PluginInstallPhase.verifying));
        final reported = await ref.read(npmIntegrityProvider)(name, expected.version);
        if (_cancelledQueued.remove(requestId) || generation != _generation || !ref.mounted) {
          return finish((j) => j.copyWith(phase: PluginInstallPhase.cancelled, failure: describeCancelled));
        }
        if (reported == null) {
          return finish(
            (j) => j.copyWith(
              phase: PluginInstallPhase.failed,
              failure: PluginFailure(
                PluginFailureKind.network,
                appL10n.marketVerificationUnavailableTitle,
                appL10n.marketVerificationUnavailableBody,
              ),
            ),
          );
        }
        if (reported != expected.integrity) {
          return finish(
            (j) => j.copyWith(
              phase: PluginInstallPhase.failed,
              failure: PluginFailure(
                PluginFailureKind.mismatch,
                appL10n.marketMismatchTitle,
                appL10n.marketMismatchMessage(expected.version),
                detail: 'dsh-go.json  ${expected.integrity}\nnpm          $reported',
              ),
            ),
          );
        }
      }
      if (job.request.replaceInstalled) {
        _update(name, requestId, (j) => j.copyWith(phase: PluginInstallPhase.removing));
        final removed = await client.removeBundle(name);
        if (!removed.succeeded) {
          return finish(
            (j) => j.copyWith(
              phase: PluginInstallPhase.failed,
              result: removed,
              failure: describeOperationFailure(removed, isLocal: host.isLocal),
            ),
          );
        }
        if (_cancelledRemovals.remove(requestId)) {
          return finish(
            (j) => j.copyWith(
              phase: PluginInstallPhase.cancelled,
              result: removed,
              failure: PluginFailure(
                PluginFailureKind.cancelled,
                appL10n.statePluginInstallCancelled,
                appL10n.pluginsUninstalledNamed(job.request.title ?? name),
              ),
            ),
          );
        }
        if (_cancelledQueued.remove(requestId)) {
          return finish((j) => j.copyWith(phase: PluginInstallPhase.cancelled, failure: describeCancelled));
        }
      }
      _update(
        name,
        requestId,
        (j) => j.phase == PluginInstallPhase.cancelling ? j : j.copyWith(phase: PluginInstallPhase.installing),
      );
      PluginOperationResult result;
      try {
        result = await client.installBundle(
          job.request.spec,
          requestId: requestId,
          enabled: true,
          saveExact: true,
          registry: job.request.registry,
          approvedBuilds: job.request.approvedBuilds.isEmpty ? null : job.request.approvedBuilds,
        );
      } on DshException catch (error) {
        if (error is DshRemoteException) rethrow;
        result = await _recover(
          client,
          requestId,
          name,
          requireResult: host.isLocal && ref.read(operatingSystemProvider) == 'ohos',
        );
      }
      if (result.succeeded) {
        return finish((j) => j.copyWith(phase: PluginInstallPhase.succeeded, result: result));
      }
      final failure = describeOperationFailure(result, isLocal: host.isLocal, published: job.request.published);
      return finish(
        (j) => j.copyWith(
          phase: failure.kind == PluginFailureKind.cancelled ? PluginInstallPhase.cancelled : PluginInstallPhase.failed,
          result: result,
          failure: failure,
        ),
      );
    } on Object catch (error) {
      return finish((j) => j.copyWith(phase: PluginInstallPhase.failed, failure: describePluginError(error)));
    } finally {
      _cancelledRemovals.remove(requestId);
      unawaited(events.cancel());
      if (generation == _generation && ref.mounted) {
        unawaited(ref.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
      }
    }
  }

  /// The install response was lost (timeout, dropped tunnel): ask the Host
  /// for the running install's result, then fall back to the bundle list.
  Future<PluginOperationResult> _recover(
    DshClient client,
    String requestId,
    String name, {
    required bool requireResult,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await client.waitForInstall(requestId);
        if (result != null) return result;
        break;
      } on DshRemoteException {
        break;
      } on DshException {
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    // Inventory cannot establish the outcome of a retired OH local request.
    if (requireResult) throw const _InstallResultUnknown();
    try {
      final bundles = await client.listBundles();
      if (bundles.any((b) => b.name == name && b.installed)) {
        return PluginOperationResult(application: PluginApplication.applied, target: name, bundle: name);
      }
    } on DshException {
      // fall through
    }
    throw const _InstallResultUnknown();
  }

  void _put(PluginInstallJob job) {
    if (!ref.mounted) return;
    state = {...state, job.request.name: job};
    _settle(job);
  }

  void _settle(PluginInstallJob job) {
    if (job.isActive) return;
    for (final waiter in _waiters.remove(job.requestId) ?? const <Completer<PluginInstallJob>>[]) {
      if (!waiter.isCompleted) waiter.complete(job);
    }
  }

  void _update(String name, String requestId, PluginInstallJob Function(PluginInstallJob) change) {
    if (!ref.mounted) return;
    final current = state[name];
    if (current == null || current.requestId != requestId) return;
    final next = change(current);
    state = {...state, name: next};
    _settle(next);
  }
}

final pluginInstallsProvider = NotifierProvider<PluginInstallsController, Map<String, PluginInstallJob>>(
  PluginInstallsController.new,
);
