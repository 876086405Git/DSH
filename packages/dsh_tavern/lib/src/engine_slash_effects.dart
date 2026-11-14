part of 'engine.dart';

/// A literal plan shared by macro units and the existing B2 acceptance wrapper.
/// There is no generation id, injection claim or model operation in this plan.
class _ScriptEffectPlan {
  _ScriptEffectPlan({
    required this.context,
    required this.operation,
    required this.global,
    required this.local,
    required this.observation,
    this.chatId,
    this.anchor,
    this.capturedChatState = false,
    Map<String, Object?> stateUpdates = const {},
    this.stChatIdHash,
    this.hasHashUpdate = false,
    this.gameplayCapture,
    this.packWorldInfo,
  }) : stateUpdates = _runtimeCopy(stateUpdates);
  final _ScriptContextState context;
  final String operation;
  final _ScriptRuntimeIntentMap global, local;
  final _ScriptGenerationObservation observation;
  final String? chatId, anchor;
  final bool capturedChatState, hasHashUpdate;
  final Map<String, Object?> stateUpdates;
  final num? stChatIdHash;
  final _GameplayResourceCapture? gameplayCapture;
  final state_core.StatePackWorldInfoDelta? packWorldInfo;
  Set<String> get chatTargets => {
    if (local.hasIntents) 'local',
    ...stateUpdates.keys,
    if (packWorldInfo?.isEmpty == false) 'dshgoPackWorldInfo',
    if (hasHashUpdate) 'stChatIdHash',
  };
  Set<String> get carriers => {if (global.hasIntents) 'global', if (chatTargets.isNotEmpty) 'chat'};
}

/// An immutable observation after an actual runtime/file/SQL adoption.
/// runtimeVersion observes live runtime, which can also contain later pending
/// native writes. targetVersions identifies the committed target projection.
class _ScriptCarrierAdoption {
  _ScriptCarrierAdoption({
    required this.targetKind,
    required this.status,
    this.chatId,
    this.nodeId,
    Map<String, String> targetVersions = const {},
    this.runtimeVersion,
  }) : targetVersions = Map.unmodifiable(targetVersions);
  final String targetKind, status;
  final String? chatId, nodeId, runtimeVersion;
  final Map<String, String> targetVersions;
}

/// onCommitted is deliberately first: a later version/observer failure cannot
/// erase the already completed rename or outer SQL COMMIT.
class _ScriptCarrierSignals {
  const _ScriptCarrierSignals({
    required this.onStarted,
    required this.onCommitted,
    required this.onAdopted,
    required this.onFinished,
    this.onEntering,
  });
  final void Function(String targetKind) onStarted, onFinished;
  final void Function(String targetKind)? onEntering;
  final void Function(String targetKind, String status) onCommitted;
  final void Function(_ScriptCarrierAdoption adoption) onAdopted;
}

extension _ScriptEffectCarriers on _ScriptCoordinator {
  void _checkScriptEffectTargets(_ScriptEffectPlan plan, {bool global = true, bool chat = true}) {
    final currentContext = _context(plan.context.value.id);
    if (!identical(currentContext, plan.context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        plan.operation,
        'The captured context instance is no longer active.',
      );
    }
    _checkScriptGameplayResources(engine, plan.gameplayCapture, plan.operation);
    if (global && plan.global.hasIntents) {
      final committed = _variableVersion(
        const TavernVariableTarget(scope: TavernVariableScope.global),
        _fieldVariable(engine._document, 'globalVariables'),
      );
      if (plan.observation.globalRuntime != engine._globalVariables.observation ||
          plan.observation.globalCommitted != committed) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          plan.operation,
          'Global runtime, pending intent or committed value changed.',
        );
      }
    }
    if (!chat || plan.chatTargets.isEmpty) return;
    final chatId = plan.chatId;
    if (chatId == null || !plan.capturedChatState) {
      throw _scriptError(TavernScriptErrorCode.noContext, plan.operation, 'This effect needs a captured chat state.');
    }
    _checkScriptLocalOwner(chatId, plan.operation);
    if (plan.observation.selection != _generationFieldVersion(chatId, 'selection')) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, plan.operation, 'The captured selection changed.');
    }
    for (final target in plan.chatTargets) {
      if (!const {'local', 'timedWorldInfo', 'decoratorState', 'stChatIdHash', 'dshgoPackWorldInfo'}.contains(target)) {
        throw _scriptError(
          TavernScriptErrorCode.reservedField,
          plan.operation,
          'This effect cannot replace that state field.',
        );
      }
      if (plan.observation.targets[target] != _generationFieldVersion(chatId, target)) {
        throw _scriptError(TavernScriptErrorCode.revisionConflict, plan.operation, 'An effect target changed.');
      }
    }
  }

  void _checkScriptLocalOwner(String chatId, String operation) {
    final active = engine._turns[chatId];
    if (active != null && active.nativePreparationStarted && !active.modelDrained.isCompleted) {
      throw _scriptError(TavernScriptErrorCode.busy, operation, 'A native turn still owns the preparation state.');
    }
  }

  /// Same short non-cancelling gate as B2. Never wait on our own turn.done.
  Future<T> _scriptEffectChatWrite<T>(
    String chatId,
    T Function(_ToolPreparationPermit? permit) action, {
    bool metadataOnly = false,
  }) {
    final permit = _captureToolPreparationPermit(engine, chatId, metadataOnly: metadataOnly);
    final previous = engine._mutations[chatId] ?? Future<void>.value();
    final released = Completer<void>();
    engine._mutations[chatId] = released.future;
    return () async {
      try {
        await previous;
        _checkToolPreparationPermit(engine, permit);
        return action(permit);
      } finally {
        if (identical(engine._mutations[chatId], released.future)) {
          unawaited(engine._mutations.remove(chatId));
        }
        released.complete();
      }
    }();
  }

  /// The caller owns the real storage operation and the cancellation check.
  /// No cancellation race can return before a started carrier actually settles.
  Future<void> _commitScriptEffectPlan(
    _ScriptEffectPlan plan, {
    required void Function() checkAlive,
    required _ScriptCarrierSignals signals,
  }) async {
    if (plan.global.hasIntents) {
      signals.onEntering?.call('global');
      checkAlive();
      await engine._settingsDocument((document) async {
        checkAlive();
        signals.onStarted('global');
        _checkScriptEffectTargets(plan, chat: false);
        final through = engine._globalVariables.revision;
        final runtime = plan.global.applyTo(engine._globalVariables.project(through));
        await _persistScriptEffectGlobals(document, runtime, through, signals);
        signals.onFinished('global');
      });
    }
    if (plan.chatTargets.isNotEmpty) {
      signals.onEntering?.call('chat');
      checkAlive();
      final chatId = plan.chatId!;
      await _scriptEffectChatWrite(chatId, (permit) {
        checkAlive();
        signals.onStarted('chat');
        _checkScriptEffectTargets(plan, global: false);
        final chat = engine._store.chat(chatId);
        final group = engine._store.groupChat(chatId);
        final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
        final state = plan.anchor == null && group == null
            ? _emptyChatState(metadata)
            : engine._stateAt(chatId, plan.anchor);
        final live = engine._liveVariables[chatId];
        final current = live != null && live.leaf == plan.anchor
            ? live.values
            : state.containsKey('variables')
            ? _map(state['variables'])
            : chat.variables;
        final local = plan.local.hasIntents ? plan.local.applyTo(current) : _runtimeCopy(current);
        if (plan.local.hasIntents) state['variables'] = _copy(local);
        for (final entry in plan.stateUpdates.entries) {
          state[entry.key] = _copy({'value': entry.value})['value'];
        }
        if (plan.hasHashUpdate) state['stChatIdHash'] = plan.stChatIdHash;
        _persistScriptEffectChat(
          chat,
          plan.anchor,
          state,
          local,
          plan.chatTargets,
          signals,
          permit,
          gameplayCapture: plan.gameplayCapture,
          packWorldInfo: plan.packWorldInfo,
          operation: plan.operation,
        );
        signals.onFinished('chat');
      });
    }
  }

  /// Called only while the actual settings queue is owned. The cutoff is the
  /// actual queue cutoff; native intents after it survive the later adoption.
  Future<void> _persistScriptEffectGlobals(
    Map<String, Object?> document,
    Map<String, Object?> runtime,
    int through,
    _ScriptCarrierSignals signals,
  ) async {
    final value = _copy(runtime);
    void adopted(String status) {
      signals.onCommitted('global', status);
      final version = _variableVersion(
        const TavernVariableTarget(scope: TavernVariableScope.global),
        _fieldVariable(engine._document, 'globalVariables'),
      );
      final runtimeSerial = engine._globalVariables.observation;
      signals.onAdopted(
        _ScriptCarrierAdoption(
          targetKind: 'global',
          status: status,
          targetVersions: {'global': version},
          runtimeVersion: '$epoch:globalRuntime:$runtimeSerial',
        ),
      );
    }

    if (_stateJsonEqual(value, document['globalVariables'])) {
      engine._adoptGlobals(runtime, through);
      adopted('adopted');
    } else {
      final next = _copy(document)..['globalVariables'] = value;
      await engine._commitSettingsDocument(
        next,
        globals: (runtime: runtime, through: through),
        onCommitted: () => adopted('written'),
      );
    }
  }

  /// Synchronous inside the short chat gate. SQL and portable state are one
  /// outer transaction; live runtime is installed only by its onCommitted.
  void _persistScriptEffectChat(
    StoredChat chat,
    String? anchor,
    Map<String, Object?> state,
    Map<String, Object?> local,
    Set<String> targets,
    _ScriptCarrierSignals signals,
    _ToolPreparationPermit? permit, {
    _GameplayResourceCapture? gameplayCapture,
    state_core.StatePackWorldInfoDelta? packWorldInfo,
    String operation = 'generate',
  }) {
    final chatId = chat.id;
    final group = engine._store.groupChat(chatId);
    final adopted = (leaf: anchor, values: _runtimeCopy(local));
    final storedLocal = _copy(local);
    final targetFingerprints = <String, String>{};
    _toolPreparationSql(
      engine,
      permit,
      () {
        _checkScriptGameplayResources(engine, gameplayCapture, operation);
        if (packWorldInfo != null && !packWorldInfo.isEmpty) {
          final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
          final latest = anchor == null && group == null ? _emptyChatState(metadata) : engine._stateAt(chatId, anchor);
          final merged = state_core.mergeStatePackWorldInfo(
            exists: latest.containsKey('dshgoPackRuntime'),
            raw: latest['dshgoPackRuntime'],
            delta: packWorldInfo,
          );
          if (merged.issues.isNotEmpty) {
            throw TavernScriptException(
              code: TavernScriptErrorCode.shapeMismatch,
              operation: operation,
              message: 'The gameplay world-info runtime cannot be adopted.',
              issues: [
                for (final issue in merged.issues)
                  TavernScriptIssue(
                    code: 'gameplay_world_info_runtime',
                    message: 'The saved gameplay runtime does not match this captured source.',
                    committed: false,
                    stage: 'worldInfo',
                    details: issue,
                  ),
              ],
            );
          }
          if (merged.exists) {
            state['dshgoPackRuntime'] = merged.raw;
          } else {
            state.remove('dshgoPackRuntime');
          }
        }
        if (anchor != null) {
          engine._store.writeNodeState(chatId, anchor, state);
          engine._writeNodeState(chatId, anchor, state);
        } else if (group != null) {
          engine._store.setGroupInitialState(chatId, state);
        }
        engine._store.updateChat(chatId, variables: storedLocal, metadata: _runtimeMetadata(chat.metadata, state));
        for (final target in targets) {
          targetFingerprints[target] = target == 'local'
              ? _scriptRuntimeFingerprint([storedLocal, adopted.values])
              : _generationFieldFingerprint(chatId, target);
        }
      },
      onCommitted: () {
        engine._liveVariables[chatId] = adopted;
        signals.onCommitted('chat', 'written');
        final versions = <String, String>{
          for (final target in targets)
            target: target == 'local'
                ? _variableVersion(
                    TavernVariableTarget(scope: TavernVariableScope.chat, chatId: chatId),
                    _ScriptRawVariable(true, storedLocal),
                  )
                : _generationFieldVersionForFingerprint(chatId, target, targetFingerprints[target]!),
        };
        signals.onAdopted(
          _ScriptCarrierAdoption(
            targetKind: 'chat',
            status: 'written',
            chatId: chatId,
            nodeId: anchor,
            targetVersions: versions,
            runtimeVersion: targets.contains('local')
                ? _generationFieldVersionForFingerprint(chatId, 'local', targetFingerprints['local']!)
                : null,
          ),
        );
      },
    );
  }
}

/// A propagated error is another view of already observed diagnostics. Preserve
/// the greatest observed multiplicity of each immutable Issue object.
void _appendScriptIssuePropagation(List<TavernScriptIssue> target, Iterable<TavernScriptIssue> incoming) {
  final available = HashMap<TavernScriptIssue, int>.identity();
  for (final issue in target) {
    available[issue] = (available[issue] ?? 0) + 1;
  }
  final seen = HashMap<TavernScriptIssue, int>.identity();
  for (final issue in incoming) {
    final ordinal = (seen[issue] ?? 0) + 1;
    seen[issue] = ordinal;
    if (ordinal > (available[issue] ?? 0)) target.add(issue);
  }
}

/// A key denotes one actual received ordered series, never an arbitrary catch.
/// Distinct deliveries may legitimately contain the same immutable Issue.
/// Repeated snapshots of one series must extend its unchanged original prefix.
void _appendScriptIssueObservation(
  List<TavernScriptIssue> target,
  Map<Object, List<TavernScriptIssue>> observations,
  Iterable<TavernScriptIssue> incoming, {
  Object? observationKey,
}) {
  if (observationKey == null) {
    _appendScriptIssuePropagation(target, incoming);
    return;
  }
  final next = List<TavernScriptIssue>.of(incoming);
  final previous = observations[observationKey] ?? const <TavernScriptIssue>[];
  if (next.length < previous.length) {
    throw StateError('An issue observation cannot retract an already received prefix.');
  }
  for (var index = 0; index < previous.length; index++) {
    if (!identical(previous[index], next[index])) {
      throw StateError('An issue observation must retain its original ordered prefix.');
    }
  }
  target.addAll(next.skip(previous.length));
  observations[observationKey] = List.unmodifiable(next);
}

class _ScriptEffectWaitOutcome<T> {
  const _ScriptEffectWaitOutcome.withValue(this.value) : error = null, stack = null, cancelled = false;
  const _ScriptEffectWaitOutcome.withError(this.error, this.stack) : value = null, cancelled = false;
  const _ScriptEffectWaitOutcome.cancelSignal() : value = null, error = null, stack = null, cancelled = true;
  final T? value;
  final Object? error;
  final StackTrace? stack;
  final bool cancelled;
}

/// Per-operation ownership. Public substituteMacros owns a real cancellable
/// operation, not a fabricated Slash execution or background generation.
class _ScriptEffectScope {
  _ScriptEffectScope.slash(this.coordinator, _SlashExecutionOwner owner)
    : context = owner.context,
      execution = owner,
      token = null;
  _ScriptEffectScope.publicMacro(this.coordinator, this.context) : execution = null, token = _ScriptCancellation() {
    context.callbacks.add(token!);
  }
  final _ScriptCoordinator coordinator;
  final _ScriptContextState context;
  final _SlashExecutionOwner? execution;
  final _ScriptCancellation? token;
  final issues = <TavernScriptIssue>[];
  final issueObservations = HashMap<Object, List<TavernScriptIssue>>.identity();
  bool knownCommitted = false;
  bool ended = false;
  bool cacheWaitCancelled = false;
  Future<void>? cacheRun;
  bool get committed => knownCommitted || execution?.committed == true;
  bool get cancelled =>
      token?.isCancelled == true || execution?.token.isCancelled == true || context.closed || coordinator._closed;

  void checkAlive() {
    execution?.checkAlive();
    final slash = execution;
    if (ended ||
        cancelled ||
        slash?.terminal == true ||
        (slash != null && !identical(coordinator._slashExecutions[slash.id], slash.record))) {
      throw _scriptError(
        TavernScriptErrorCode.cancelled,
        'substituteMacros',
        'The effect owner was cancelled.',
        contextId: context.value.id,
        committed: committed,
      );
    }
    if (!identical(coordinator._context(context.value.id), context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'substituteMacros',
        'The captured context instance is no longer active.',
        contextId: context.value.id,
      );
    }
  }

  void observeReceivedIssues(
    Iterable<TavernScriptIssue> values, {
    required bool committed,
    required Object observationKey,
  }) {
    if (ended || execution?.terminal == true || cacheWaitCancelled) return;
    final captured = List<TavernScriptIssue>.of(values);
    knownCommitted = knownCommitted || committed || captured.any((issue) => issue.committed);
    _appendScriptIssueObservation(issues, issueObservations, captured, observationKey: observationKey);
    execution?.observeIssues(captured, committed: committed, observationKey: observationKey);
  }

  void observe(Object error) {
    if (ended || execution?.terminal == true || error is! TavernScriptException) return;
    knownCommitted = knownCommitted || error.committed || error.issues.any((issue) => issue.committed);
    _appendScriptIssuePropagation(issues, error.issues);
    execution?.observeIssues(error.issues, committed: error.committed);
  }

  void adopted() {
    if (ended || execution?.terminal == true) return;
    knownCommitted = true;
    execution?.observeIssues(const [], committed: true);
  }

  Future<T> drain<T>(Future<T> future) => execution == null ? future : execution!.storage(future);

  Future<T> waitCache<T>(Future<T> future) async {
    try {
      checkAlive();
    } catch (_) {
      future.ignore();
      rethrow;
    }
    final cancellation = execution?.token ?? token!;
    final completed = Completer<_ScriptEffectWaitOutcome<T>>();
    void settle(_ScriptEffectWaitOutcome<T> outcome) {
      if (completed.isCompleted) return;
      if (outcome.cancelled) cacheWaitCancelled = true;
      completed.complete(outcome);
    }

    unawaited(
      future.then<void>(
        (value) {
          settle(_ScriptEffectWaitOutcome<T>.withValue(value));
        },
        onError: (Object error, StackTrace stack) {
          settle(_ScriptEffectWaitOutcome<T>.withError(error, stack));
        },
      ),
    );
    unawaited(
      cancellation.whenCancelled.then<void>((_) {
        settle(_ScriptEffectWaitOutcome<T>.cancelSignal());
      }),
    );
    execution?.record.waiting(TavernSlashWaitKind.storage);
    try {
      final outcome = await completed.future;
      if (outcome.cancelled) {
        checkAlive();
        throw _scriptError(
          TavernScriptErrorCode.cancelled,
          'substituteMacros',
          'The cache wait was cancelled.',
          contextId: context.value.id,
          committed: committed,
        );
      }
      final error = outcome.error;
      if (error != null) {
        // Actual ACK facts were observed at _deliverCaptured through the
        // registered scope. This aggregate is only propagation, not a new ACK.
        observe(error);
        Error.throwWithStackTrace(error, outcome.stack!);
      }
      checkAlive();
      return outcome.value as T;
    } finally {
      final slash = execution;
      if (slash != null && !slash.terminal) slash.record.status = TavernSlashStatus.running;
    }
  }

  void finish() {
    coordinator._detachScriptEffectCacheScope(this);
    if (token != null) context.callbacks.remove(token);
    ended = true;
  }
}

class _MacroEffectTarget {
  _MacroEffectTarget(TavernJsonObject json, Iterable<String> versionKeys)
    : json = _captureScriptObject(json),
      versionKeys = List.unmodifiable(versionKeys);
  final TavernJsonObject json;
  final List<String> versionKeys;
}

class _MacroEffectReceipt {
  _MacroEffectReceipt(this.operation, this.stage, this.targets);
  final String operation;
  final TavernSlashEffectStage stage;
  final Map<String, List<_MacroEffectTarget>> targets;
  final started = <String>{};
  final adopted = <TavernJsonObject>[];
  final publishedAdoptions = <String>{};
  final skipped = <TavernJsonObject>[];
  String phase = 'validation';
  String? activeCarrier, failedTarget;
  bool get committed => adopted.isNotEmpty;
  bool wasAdopted(String carrier) => adopted.any((item) => item['targetKind'] == carrier);

  TavernJsonObject details() => {
    'requiredTargets': targets.keys.toList(),
    'startedTargets': started.toList(),
    'persistedTargets': adopted,
    'skippedTargets': skipped,
    if (failedTarget != null) 'failedTarget': failedTarget,
    'phase': phase,
  };
}

/// A dependency failure is sticky because the selected legacy compatibility
/// engine can catch ordinary macro-handler exceptions.
class _MacroEffectDependencies {
  _MacroEffectDependencies(this.scope);
  final _ScriptEffectScope scope;
  TavernScriptException? failure;

  Never reject(TavernScriptErrorCode code, String message, {String? fieldPath}) {
    final current = failure ??= _scriptError(
      code,
      'substituteMacros',
      message,
      contextId: scope.context.value.id,
      fieldPath: fieldPath,
    );
    throw current;
  }

  void check() {
    final current = failure;
    if (current != null) throw current;
  }
}

class _MacroEffectVariables extends MapBase<String, Object?> {
  _MacroEffectVariables(this._delegate, this.dependencies, {this.problem, this.fieldPath});
  final _ScriptRuntimeIntentMap _delegate;
  final _MacroEffectDependencies dependencies;
  final TavernScriptErrorCode? problem;
  final String? fieldPath;
  void _check() {
    if (problem case final code?) {
      dependencies.reject(
        code,
        code == TavernScriptErrorCode.noContext
            ? 'A local-variable macro requires a captured chat.'
            : 'The stored variable target is not an object.',
        fieldPath: fieldPath,
      );
    }
  }

  @override
  Object? operator [](Object? key) {
    _check();
    return _delegate[key];
  }

  @override
  void operator []=(String key, Object? value) {
    _check();
    _delegate[key] = value;
  }

  @override
  Object? remove(Object? key) {
    _check();
    return _delegate.remove(key);
  }

  @override
  void clear() {
    _check();
    _delegate.clear();
  }

  @override
  Iterable<String> get keys {
    _check();
    return _delegate.keys;
  }

  @override
  bool containsKey(Object? key) {
    _check();
    return _delegate.containsKey(key);
  }
}

class _MacroEffectHistoryUnavailable extends ListBase<MacroMessage> {
  _MacroEffectHistoryUnavailable(this.dependencies);
  final _MacroEffectDependencies dependencies;
  Never _missing() => dependencies.reject(TavernScriptErrorCode.noContext, 'A history macro requires a captured chat.');
  @override
  int get length => _missing();
  @override
  set length(int value) => _missing();
  @override
  MacroMessage operator [](int index) => _missing();
  @override
  void operator []=(int index, MacroMessage value) => _missing();
}

class _ScriptMacroCapture extends _MacroEffectCapture {
  _ScriptMacroCapture({
    required this.scope,
    required this.dependencies,
    required this.initialHash,
    required this.actorId,
    required this.characterName,
    required super.context,
    required super.environment,
    required super.global,
    required super.local,
    required super.observation,
    required super.state,
    super.chatId,
    super.anchor,
    this.gameplayCapture,
  });
  final _ScriptEffectScope scope;
  final _MacroEffectDependencies dependencies;
  final num? initialHash;
  final String? actorId;
  final String characterName;
  final _GameplayResourceCapture? gameplayCapture;
  bool commitEntered = false;
  @override
  bool get hasHashUpdate => chatId != null && environment.chatIdHash != initialHash;
  @override
  void checkDependencies() {
    dependencies.check();
    _checkScriptGameplayResources(scope.coordinator.engine, gameplayCapture, 'substituteMacros');
  }

  @override
  String requireCharacterName() {
    if (actorId == null) {
      dependencies.reject(TavernScriptErrorCode.noContext, 'The requested character name requires an actor.');
    }
    return characterName;
  }
}

Map<String, Object?> _scriptRuntimeVariableObject(
  _ScriptRawVariable raw, {
  required String operation,
  String? fieldPath,
}) {
  if (!raw.present) return <String, Object?>{};
  final value = raw.value;
  if (value is! Map<String, Object?>) {
    throw _scriptError(
      TavernScriptErrorCode.shapeMismatch,
      operation,
      'The stored variable target is not an object.',
      fieldPath: fieldPath,
    );
  }
  return _runtimeCopy(value);
}

_ScriptRuntimeIntentMap _copyScriptEffectIntents(_ScriptRuntimeIntentMap source) {
  final copy = _ScriptRuntimeIntentMap(_runtimeCopy(source));
  for (final write in source.writes) {
    copy.writes.add(_GlobalWrite(write.revision, write.key, write.present, _runtimeValue(write.value)));
  }
  return copy;
}

extension _ScriptMacroEffects on _ScriptCoordinator {
  Future<_MacroEffectCapture> _captureMacroUnit(
    _SlashExecutionOwner owner, {
    bool? collapseNewlinesOverride,
    bool prepareCharacterFieldsOnDemand = false,
    String input = '',
    String generationType = 'normal',
    _ScriptGenerationCapture? frozenGeneration,
  }) {
    final scope = _ScriptEffectScope.slash(this, owner);
    return _bridgeOperation(() async {
      try {
        return await _captureScriptMacroUnit(
          scope,
          collapseNewlinesOverride: collapseNewlinesOverride,
          prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
          input: input,
          generationType: generationType,
          frozenGeneration: frozenGeneration,
        );
      } catch (error) {
        scope.observe(error);
        scope.finish();
        rethrow;
      }
    });
  }

  Future<_ScriptMacroCapture> _captureScriptMacroUnit(
    _ScriptEffectScope scope, {
    bool? collapseNewlinesOverride,
    bool prepareCharacterFieldsOnDemand = false,
    String input = '',
    String generationType = 'normal',
    _ScriptGenerationCapture? frozenGeneration,
  }) async {
    scope.checkAlive();
    final context = scope.context;
    final frozen = frozenGeneration;
    if (frozen != null && !identical(frozen.context, context)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'substituteMacros',
        'Frozen output resources belong to a different context instance.',
        contextId: context.value.id,
      );
    }
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final anchor = chat?.currentLeafId;
    final group = chatId == null ? null : engine._store.groupChat(chatId);
    final metadata = chatId == null ? <String, Object?>{} : engine._chatCodec.metadataForNode(engine._store, chatId);
    final state = chatId == null
        ? <String, Object?>{}
        : anchor == null && group == null
        ? _emptyChatState(metadata)
        : engine._stateAt(chatId, anchor);
    final history = chatId == null ? <StoredNode>[] : engine._historyTo(chatId, anchor);
    final live = chatId == null ? null : engine._liveVariables[chatId];
    final rawLocal = chat == null
        ? const _ScriptRawVariable(false, null)
        : live != null && live.leaf == anchor
        ? _ScriptRawVariable(true, live.values)
        : anchor == null && group == null && metadata.containsKey('variables')
        ? _fieldVariable(metadata, 'variables')
        : state.containsKey('variables')
        ? _fieldVariable(state, 'variables')
        : _ScriptRawVariable(true, chat.variables);
    final rawGlobal = _fieldVariable(engine._document, 'globalVariables');
    final localProblem = chat == null
        ? TavernScriptErrorCode.noContext
        : rawLocal.present && rawLocal.value is! Map<String, Object?>
        ? TavernScriptErrorCode.shapeMismatch
        : null;
    final globalProblem = rawGlobal.present && rawGlobal.value is! Map<String, Object?>
        ? TavernScriptErrorCode.shapeMismatch
        : null;
    final local = _ScriptRuntimeIntentMap(
      localProblem == null ? _scriptRuntimeVariableObject(rawLocal, operation: 'substituteMacros') : {},
    );
    final global = _ScriptRuntimeIntentMap(_runtimeCopy(engine._globalVariables));
    final observation = _ScriptGenerationObservation(
      globalRuntime: engine._globalVariables.observation,
      globalCommitted: _variableVersion(const TavernVariableTarget(scope: TavernVariableScope.global), rawGlobal),
      selection: chatId == null ? null : _generationFieldVersion(chatId, 'selection'),
      targets: {
        if (chatId != null)
          for (final target in const ['local', 'stChatIdHash']) target: _generationFieldVersion(chatId, target),
      },
    );
    final at = engine._clock();
    final config = frozen?.config ?? engine._config;
    final capturedConfig = TavernModelConfig(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
      model: config.model,
      deepseek: config.deepseek,
      thinking: config.thinking,
      headers: config.headers,
      auxiliary: config.auxiliary,
    );
    late final Map<String, Object?> settings, card, regexPreset;
    late final ChatPreset promptPreset;
    String? actorId;
    _GameplayResourceCapture? gameplayCapture;
    List<String>? groupNames, groupNotMuted;
    if (frozen != null) {
      settings = _runtimeCopy(frozen.settings);
      card = _runtimeCopy(frozen.card);
      actorId = frozen.actorId;
      gameplayCapture = frozen.gameplayCapture;
      final selected = frozen.promptPreset;
      final raw = _map(settings['preset']);
      promptPreset = selected != null
          ? ChatPreset(selected.raw)
          : raw.isEmpty
          ? ChatPreset.stDefault()
          : ChatPreset(raw);
      regexPreset = _runtimeCopy(frozen.contextRegexPresetSettings);
      groupNames = frozen.groupView == null ? null : List.of(frozen.groupView!.names);
      groupNotMuted = frozen.groupView == null ? null : List.of(frozen.groupView!.enabledNames);
    } else {
      final persona = engine._personas.resolve(personaId: chat?.personaId);
      settings = _runtimeCopy(_personaSettings(engine._effectiveSettings(chat, metadata), persona));
      final raw = _map(settings['preset']);
      promptPreset = raw.isEmpty ? ChatPreset.stDefault() : ChatPreset(raw);
      regexPreset = _runtimeCopy(promptPreset.settings);
      actorId = context.value.characterId ?? (group == null ? chat?.characterId : null);
      gameplayCapture = _captureGameplayResources(
        engine,
        characterId: actorId,
        chatId: chatId,
        deferResourceErrors: true,
      );
      StoredCharacter? actor;
      if (actorId != null) {
        actor = await scope.drain(engine._record(actorId));
        scope.checkAlive();
        if (actor == null) {
          throw _scriptError(
            TavernScriptErrorCode.notFound,
            'substituteMacros',
            'The captured character no longer exists.',
            contextId: context.value.id,
          );
        }
      }
      card = actor == null ? <String, Object?>{} : _effectiveCard(actor.card.data, settings);
      if (group != null) {
        final view = await scope.drain(engine._groups.capture(group, checkCancelled: scope.checkAlive));
        scope.checkAlive();
        groupNames = List.of(view.names);
        groupNotMuted = List.of(view.enabledNames);
      }
    }
    scope.checkAlive();
    _checkScriptGameplayResources(engine, gameplayCapture, 'substituteMacros');
    final dependencies = _MacroEffectDependencies(scope);
    final initialHash = _finiteNumber(metadata['chat_id_hash']);
    void characterDependency(String field) {
      if (actorId == null) {
        dependencies.reject(
          TavernScriptErrorCode.noContext,
          'The requested character source requires an actor.',
          fieldPath: field,
        );
      }
    }

    final environment = _MacroEnvironment(
      card,
      settings,
      _MacroEffectVariables(local, dependencies, problem: localProblem, fieldPath: 'variables'),
      _MacroEffectVariables(global, dependencies, problem: globalProblem, fieldPath: 'globalVariables'),
      List.of(history),
      capturedConfig,
      at,
      engine._random,
      chat == null
          ? ''
          : _macroChatIdentity(
              chat,
              state,
              metadata,
              state['chatJsonlSourceFile'] as String?,
              node: history.lastOrNull,
            ),
      input,
      generationType,
      chatIdHash: initialHash,
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: actorId ?? '',
      groupNames: groupNames,
      groupNotMuted: groupNotMuted,
      preset: promptPreset,
      regexPresetSettings: regexPreset,
      gameplayCapture: gameplayCapture,
      messageVariables: state['messageVariables'],
      messageVariablesExists: state.containsKey('messageVariables'),
      macroHistory: chat == null ? _MacroEffectHistoryUnavailable(dependencies) : null,
      onCharacterDependency: actorId == null ? characterDependency : null,
      prepareCharacterFieldsOnDemand: prepareCharacterFieldsOnDemand,
      collapseNewlinesOverride: collapseNewlinesOverride,
    );
    return _ScriptMacroCapture(
      scope: scope,
      dependencies: dependencies,
      initialHash: initialHash,
      actorId: actorId,
      characterName: _string(card['name']),
      context: context,
      environment: environment,
      global: global,
      local: local,
      observation: observation,
      state: _runtimeCopy(state),
      chatId: chatId,
      anchor: anchor,
      gameplayCapture: gameplayCapture,
    );
  }

  Future<void> _commitMacroUnit(
    _SlashExecutionOwner owner,
    _MacroEffectCapture source, {
    required TavernSlashEffectStage stage,
    required String operation,
  }) async {
    if (source is! _ScriptMacroCapture ||
        !identical(source.scope.execution, owner) ||
        !identical(source.context, owner.context)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        operation,
        'The macro capture does not belong to this execution.',
      );
    }
    await _commitCapturedMacroUnit(source, stage: stage, operation: operation);
  }

  /// A failed synchronous expansion owns no carrier. Once commit entered,
  /// its own finally retains responsibility for draining and closing the scope.
  void _discardMacroUnit(_SlashExecutionOwner owner, _MacroEffectCapture source) {
    if (source is! _ScriptMacroCapture || !identical(source.scope.execution, owner)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'substituteMacros',
        'The macro capture does not belong to this execution.',
      );
    }
    if (!source.commitEntered) {
      source.commitEntered = true;
      source.scope.finish();
    }
  }

  Future<String> _substitutePublicMacros(String contextId, String text, {void Function()? onEffectsCommitted}) async {
    final context = _context(contextId);
    if (text.isEmpty) return '';
    final scope = _ScriptEffectScope.publicMacro(this, context);
    try {
      final capture = await _bridgeOperation(() => _captureScriptMacroUnit(scope));
      scope.checkAlive();
      late final String result;
      try {
        result = capture.environment.expand(text, const {});
      } catch (_) {
        capture.checkDependencies();
        rethrow;
      }
      capture.checkDependencies();
      scope.checkAlive();
      await _commitCapturedMacroUnit(capture, stage: TavernSlashEffectStage.handler, operation: 'substituteMacros');
      if (scope.committed) {
        onEffectsCommitted?.call();
      }
      return result;
    } catch (error, stack) {
      scope.observe(error);
      final failure = _scriptFailure(error);
      Error.throwWithStackTrace(_scriptEffectException(scope, failure), stack);
    } finally {
      scope.finish();
    }
  }
}

TavernJsonObject _scriptEffectVariableTarget(TavernVariableTarget target) {
  if (target.scope == TavernVariableScope.global) {
    return {
      'kind': 'variables',
      'target': {'scope': 'global'},
    };
  }
  if (target.scope == TavernVariableScope.chat && target.chatId != null) {
    return {
      'kind': 'variables',
      'target': {'scope': 'chat', 'chatId': target.chatId},
    };
  }
  throw _scriptError(
    TavernScriptErrorCode.invalidArgument,
    'variableEffect',
    'This effect port requires an already resolved global or chat target.',
  );
}

Map<String, List<_MacroEffectTarget>> _macroEffectTargets(_ScriptEffectPlan plan) {
  final chatId = plan.chatId;
  final stateFields = plan.stateUpdates.keys.toList();
  return {
    if (plan.global.hasIntents)
      'global': [
        _MacroEffectTarget(
          _scriptEffectVariableTarget(const TavernVariableTarget(scope: TavernVariableScope.global)),
          const ['global'],
        ),
      ],
    if (plan.chatTargets.isNotEmpty)
      'chat': [
        if (chatId != null && plan.local.hasIntents)
          _MacroEffectTarget(
            _scriptEffectVariableTarget(TavernVariableTarget(scope: TavernVariableScope.chat, chatId: chatId)),
            const ['local'],
          ),
        if (chatId != null && stateFields.isNotEmpty)
          _MacroEffectTarget({'kind': 'chatState', 'chatId': chatId}, stateFields),
        if (chatId != null && plan.hasHashUpdate)
          _MacroEffectTarget({'kind': 'stChatIdHash', 'chatId': chatId}, const ['stChatIdHash']),
      ],
  };
}

TavernScriptException _scriptEffectException(
  _ScriptEffectScope scope,
  TavernScriptException original, {
  _MacroEffectReceipt? receipt,
}) {
  final issues = <TavernScriptIssue>[...original.issues];
  _appendScriptIssuePropagation(issues, scope.issues);
  final committed =
      scope.committed ||
      original.committed ||
      original.issues.any((issue) => issue.committed) ||
      receipt?.committed == true;
  if (receipt != null) {
    issues.add(
      TavernScriptIssue(
        code: 'macroEffects',
        message: 'The effect unit did not finish normally.',
        committed:
            receipt.committed ||
            scope.knownCommitted ||
            original.committed ||
            original.issues.any((issue) => issue.committed),
        contextId: scope.context.value.id,
        sourceSpan: original.sourceSpan ?? scope.execution?.currentSpan,
        stage: receipt.stage.name,
        cancelled: original.code == TavernScriptErrorCode.cancelled || scope.cancelled,
        details: receipt.details(),
      ),
    );
  }
  return TavernScriptException(
    code: original.code,
    operation: original.operation,
    message: original.message,
    contextId: original.contextId ?? scope.context.value.id,
    nodeId: original.nodeId,
    generationId: original.generationId,
    executionId: original.executionId ?? scope.execution?.id,
    fieldPath: original.fieldPath,
    sourceSpan: original.sourceSpan,
    committed: committed,
    modelFailure: original.modelFailure,
    issues: issues,
    stateEdit: original.stateEdit,
  );
}

extension _ScriptEffectAccounting on _ScriptCoordinator {
  _ScriptCarrierSignals _macroEffectSignals(_ScriptEffectScope scope, _MacroEffectReceipt receipt) =>
      _ScriptCarrierSignals(
        onEntering: (kind) {
          receipt.phase = kind;
        },
        onStarted: (kind) {
          receipt.phase = kind;
          receipt.activeCarrier = kind;
          receipt.failedTarget = kind;
          receipt.started.add(kind);
          for (final target in receipt.targets[kind] ?? const <_MacroEffectTarget>[]) {
            scope.execution?.recordEffect(
              kind: TavernSlashEffectKind.storage,
              stage: receipt.stage,
              state: TavernSlashEffectState.started,
              operation: receipt.operation,
              target: target.json,
              details: {'targetKind': kind},
            );
          }
        },
        onCommitted: (kind, status) {
          receipt.adopted.add({'targetKind': kind, 'status': status});
          // Mark known adoption before deriving versions or publishing observers.
          scope.adopted();
        },
        onAdopted: (adoption) {
          final index = receipt.adopted.indexWhere((item) => item['targetKind'] == adoption.targetKind);
          if (index >= 0) {
            receipt.adopted[index] = {
              ...receipt.adopted[index],
              if (adoption.chatId != null) 'chatId': adoption.chatId,
              if (adoption.nodeId != null) 'nodeId': adoption.nodeId,
              if (adoption.targetVersions.isNotEmpty) 'targetVersions': adoption.targetVersions,
              if (adoption.runtimeVersion != null) 'runtimeVersion': adoption.runtimeVersion,
            };
          }
          _publishMacroAdoption(scope, receipt, adoption);
        },
        onFinished: (kind) {
          if (receipt.activeCarrier == kind) receipt.activeCarrier = null;
          if (receipt.failedTarget == kind) receipt.failedTarget = null;
        },
      );

  void _publishMacroAdoption(_ScriptEffectScope scope, _MacroEffectReceipt receipt, _ScriptCarrierAdoption adoption) {
    if (!receipt.publishedAdoptions.add(adoption.targetKind)) return;
    final carrier = adoption.targetKind == 'chat'
        ? 'sql'
        : adoption.status == 'written'
        ? 'file'
        : 'runtime';
    for (final target in receipt.targets[adoption.targetKind] ?? const <_MacroEffectTarget>[]) {
      final versions = <String, String>{for (final key in target.versionKeys) key: ?adoption.targetVersions[key]};
      scope.execution?.recordEffect(
        kind: TavernSlashEffectKind.storage,
        stage: receipt.stage,
        state: TavernSlashEffectState.adopted,
        operation: receipt.operation,
        target: target.json,
        committed: true,
        version: versions.length == 1 ? versions.values.single : null,
        details: {
          'carrier': carrier,
          if (versions.length > 1) 'targetVersions': versions,
          if (adoption.runtimeVersion != null &&
              (target.versionKeys.contains('global') || target.versionKeys.contains('local')))
            'runtimeVersion': adoption.runtimeVersion,
          if (adoption.nodeId != null) 'nodeId': adoption.nodeId,
        },
      );
    }
  }

  void _recordMacroEffectFailure(_ScriptEffectScope scope, _MacroEffectReceipt receipt, TavernScriptException failure) {
    // If post-adoption version derivation itself failed, retain the actual
    // target adoption without inventing a token or publishing it twice.
    for (final item in receipt.adopted) {
      final kind = item['targetKind']! as String;
      if (!receipt.publishedAdoptions.contains(kind)) {
        _publishMacroAdoption(
          scope,
          receipt,
          _ScriptCarrierAdoption(targetKind: kind, status: item['status']! as String),
        );
      }
    }
    final active = receipt.activeCarrier;
    if (active != null) {
      receipt.failedTarget = active;
      for (final target in receipt.targets[active] ?? const <_MacroEffectTarget>[]) {
        scope.execution?.recordEffect(
          kind: TavernSlashEffectKind.storage,
          stage: receipt.stage,
          state: TavernSlashEffectState.failed,
          operation: receipt.operation,
          target: target.json,
          details: {'targetKind': active, 'code': failure.code.name, 'afterAdoption': receipt.wasAdopted(active)},
        );
      }
    }
    final reason = failure.code == TavernScriptErrorCode.cancelled || scope.cancelled ? 'cancelled' : 'earlierFailure';
    for (final entry in receipt.targets.entries) {
      if (receipt.started.contains(entry.key)) continue;
      receipt.skipped.add({'targetKind': entry.key, 'reason': reason});
      for (final target in entry.value) {
        scope.execution?.recordEffect(
          kind: TavernSlashEffectKind.storage,
          stage: receipt.stage,
          state: TavernSlashEffectState.skipped,
          operation: receipt.operation,
          target: target.json,
          details: {'targetKind': entry.key, 'reason': reason},
        );
      }
    }
  }

  /// Registration happens synchronously inside _refreshContext, after the
  /// actual existing/new refresh future has been selected.
  void _attachScriptEffectCacheScope(Future<void> run, _ScriptEffectScope scope) {
    _detachScriptEffectCacheScope(scope);
    scope.cacheRun = run;
    scope.cacheWaitCancelled = false;
    _effectCacheScopes.putIfAbsent(run, () => <_ScriptEffectScope>{}).add(scope);
  }

  void _detachScriptEffectCacheScope(_ScriptEffectScope scope) {
    final run = scope.cacheRun;
    if (run == null) return;
    scope.cacheRun = null;
    final scopes = _effectCacheScopes[run];
    if (scopes == null) return;
    scopes.remove(scope);
    if (scopes.isEmpty && identical(_effectCacheScopes[run], scopes)) {
      _effectCacheScopes.remove(run);
    }
  }

  /// The reception closure holds a refresh-run identity, never an ambient
  /// context identity. A late join to that same run shares its actual ACK.
  void _observeScriptEffectCache(
    Future<void> run,
    TavernScriptDispatch request,
    List<TavernScriptIssue> issues,
    bool committed,
  ) {
    final scopes = _effectCacheScopes[run];
    if (scopes == null) return;
    for (final scope in scopes.toList()) {
      if (identical(scope.cacheRun, run)) {
        scope.observeReceivedIssues(issues, committed: committed, observationKey: request);
      }
    }
  }

  /// Storage has already drained. Cache acknowledgement is a separate logical
  /// wait; stop can release it without pretending that a host Future is I/O.
  Future<void> _confirmScriptEffectCaches(_ScriptEffectScope scope) async {
    for (final context in contexts.values.toList()) {
      scope.checkAlive();
      if (context.closed || !identical(contexts[context.value.id], context)) continue;
      try {
        await scope.waitCache(_refreshContext(context, effectScope: scope));
      } catch (error) {
        scope.observe(error);
        rethrow;
      } finally {
        _detachScriptEffectCacheScope(scope);
      }
    }
    scope.checkAlive();
  }

  Future<void> _commitCapturedMacroUnit(
    _ScriptMacroCapture capture, {
    required TavernSlashEffectStage stage,
    required String operation,
  }) async {
    final scope = capture.scope;
    if (capture.commitEntered) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        operation,
        'A macro effect capture can be committed only once.',
      );
    }
    capture.commitEntered = true;
    _MacroEffectReceipt? receipt;
    try {
      scope.checkAlive();
      capture.checkDependencies();
      final plan = _ScriptEffectPlan(
        context: capture.context,
        operation: operation,
        global: _copyScriptEffectIntents(capture.global),
        local: _copyScriptEffectIntents(capture.local),
        observation: capture.observation,
        chatId: capture.chatId,
        anchor: capture.anchor,
        capturedChatState: capture.chatId != null,
        stChatIdHash: capture.environment.chatIdHash,
        hasHashUpdate: capture.hasHashUpdate,
        gameplayCapture: capture.gameplayCapture,
      );
      final current = _MacroEffectReceipt(operation, stage, _macroEffectTargets(plan));
      receipt = current;
      if (plan.carriers.isEmpty) return;
      final signals = _macroEffectSignals(scope, current);
      await scope.drain(
        _bridgeOperation(() async {
          scope.checkAlive();
          _checkScriptEffectTargets(plan);
          await _commitScriptEffectPlan(plan, checkAlive: scope.checkAlive, signals: signals);
        }),
      );
      if (current.committed) {
        resourcesChanged();
        scope.checkAlive();
        current.phase = 'cache';
        await _confirmScriptEffectCaches(scope);
      }
      scope.checkAlive();
      current.phase = 'completed';
    } catch (error, stack) {
      scope.observe(error);
      final failure = _scriptFailure(error);
      if (receipt != null) {
        _recordMacroEffectFailure(scope, receipt, failure);
        if (receipt.committed) resourcesChanged();
      }
      Error.throwWithStackTrace(_scriptEffectException(scope, failure, receipt: receipt), stack);
    } finally {
      scope.finish();
    }
  }
}

class _ScriptEffectChatValue {
  const _ScriptEffectChatValue(this.chat, this.state, this.local);
  final StoredChat chat;
  final Map<String, Object?> state, local;
}

extension _ScriptSlashVariables on _ScriptCoordinator {
  /// A target-only read. It does not load an actor, preset, book or model.
  _ScriptEffectChatValue _readScriptEffectChatValue(String chatId, String? anchor, {required String operation}) {
    final chat = engine._store.chat(chatId);
    final group = engine._store.groupChat(chatId);
    final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
    final state = anchor == null && group == null ? _emptyChatState(metadata) : engine._stateAt(chatId, anchor);
    final live = engine._liveVariables[chatId];
    final raw = live != null && live.leaf == anchor
        ? _ScriptRawVariable(true, live.values)
        : anchor == null && group == null && metadata.containsKey('variables')
        ? _fieldVariable(metadata, 'variables')
        : state.containsKey('variables')
        ? _fieldVariable(state, 'variables')
        : _ScriptRawVariable(true, chat.variables);
    final local = _scriptRuntimeVariableObject(raw, operation: operation, fieldPath: 'variables');
    return _ScriptEffectChatValue(chat, _runtimeCopy(state), local);
  }

  Future<_SlashVariablePair> _readSlashVariables(
    _SlashExecutionOwner owner, {
    bool chat = false,
    bool global = false,
  }) async {
    final scope = _ScriptEffectScope.slash(this, owner);
    try {
      final result = await _bridgeOperation(() {
        scope.checkAlive();
        Map<String, Object?>? localValues, globalValues;
        if (chat) {
          final chatId = scope.context.value.chatId;
          if (chatId == null) {
            throw _scriptError(
              TavernScriptErrorCode.noContext,
              'readSlashVariables',
              'This command requires chat variables.',
              contextId: scope.context.value.id,
            );
          }
          final current = engine._store.chat(chatId);
          localValues = _readScriptEffectChatValue(
            chatId,
            current.currentLeafId,
            operation: 'readSlashVariables',
          ).local;
        }
        if (global) {
          _scriptRuntimeVariableObject(
            _fieldVariable(engine._document, 'globalVariables'),
            operation: 'readSlashVariables',
            fieldPath: 'globalVariables',
          );
          globalValues = _runtimeCopy(engine._globalVariables);
        }
        // No await occurs between these two requested target reads.
        scope.checkAlive();
        return _SlashVariablePair(chat: localValues, global: globalValues);
      });
      scope.checkAlive();
      return result;
    } catch (error, stack) {
      scope.observe(error);
      Error.throwWithStackTrace(_scriptEffectException(scope, _scriptFailure(error)), stack);
    } finally {
      scope.finish();
    }
  }

  Future<T> _transformSlashVariables<T>(
    _SlashExecutionOwner owner, {
    required bool global,
    required String operation,
    required ({bool changed, T value}) Function(Map<String, Object?> current) transform,
  }) async {
    final scope = _ScriptEffectScope.slash(this, owner);
    _MacroEffectReceipt? receipt;
    late T result;
    try {
      await scope.drain(
        _bridgeOperation(() async {
          scope.checkAlive();
          if (global) {
            final currentReceipt = _MacroEffectReceipt(operation, TavernSlashEffectStage.handler, {
              'global': [
                _MacroEffectTarget(
                  _scriptEffectVariableTarget(const TavernVariableTarget(scope: TavernVariableScope.global)),
                  const ['global'],
                ),
              ],
            });
            receipt = currentReceipt;
            final signals = _macroEffectSignals(scope, currentReceipt);
            currentReceipt.phase = 'global';
            await engine._settingsDocument((document) async {
              scope.checkAlive();
              signals.onStarted('global');
              _scriptRuntimeVariableObject(
                _fieldVariable(document, 'globalVariables'),
                operation: operation,
                fieldPath: 'globalVariables',
              );
              final through = engine._globalVariables.revision;
              final candidate = engine._globalVariables.project(through);
              final changed = transform(candidate);
              result = changed.value;
              scope.checkAlive();
              if (changed.changed) {
                await _persistScriptEffectGlobals(document, candidate, through, signals);
              }
              signals.onFinished('global');
            });
          } else {
            final chatId = scope.context.value.chatId;
            if (chatId == null) {
              throw _scriptError(
                TavernScriptErrorCode.noContext,
                operation,
                'This command requires chat variables.',
                contextId: scope.context.value.id,
              );
            }
            final chat = engine._store.chat(chatId);
            final anchor = chat.currentLeafId;
            final selection = _generationFieldVersion(chatId, 'selection');
            final currentReceipt = _MacroEffectReceipt(operation, TavernSlashEffectStage.handler, {
              'chat': [
                _MacroEffectTarget(
                  _scriptEffectVariableTarget(TavernVariableTarget(scope: TavernVariableScope.chat, chatId: chatId)),
                  const ['local'],
                ),
              ],
            });
            receipt = currentReceipt;
            final signals = _macroEffectSignals(scope, currentReceipt);
            currentReceipt.phase = 'chat';
            await _scriptEffectChatWrite(chatId, (permit) {
              scope.checkAlive();
              signals.onStarted('chat');
              _checkScriptLocalOwner(chatId, operation);
              if (selection != _generationFieldVersion(chatId, 'selection')) {
                throw _scriptError(
                  TavernScriptErrorCode.revisionConflict,
                  operation,
                  'The selected state changed before the variable transform.',
                );
              }
              final current = _readScriptEffectChatValue(chatId, anchor, operation: operation);
              final changed = transform(current.local);
              result = changed.value;
              scope.checkAlive();
              if (changed.changed) {
                current.state['variables'] = _copy(current.local);
                _persistScriptEffectChat(
                  current.chat,
                  anchor,
                  current.state,
                  current.local,
                  const {'local'},
                  signals,
                  permit,
                );
              }
              signals.onFinished('chat');
            });
          }
        }),
      );
      final current = receipt;
      if (current != null && current.committed) {
        resourcesChanged();
        scope.checkAlive();
        current.phase = 'cache';
        await _confirmScriptEffectCaches(scope);
      }
      scope.checkAlive();
      if (current != null) current.phase = 'completed';
      return result;
    } catch (error, stack) {
      scope.observe(error);
      final failure = _scriptFailure(error);
      final current = receipt;
      if (current != null) {
        _recordMacroEffectFailure(scope, current, failure);
        if (current.committed) resourcesChanged();
      }
      Error.throwWithStackTrace(_scriptEffectException(scope, failure, receipt: receipt), stack);
    } finally {
      scope.finish();
    }
  }
}
