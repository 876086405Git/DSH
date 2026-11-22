part of 'engine.dart';

class _ToolApiAdoption {
  bool? committed = false;
  String? executionId;
  String? proposalId;
  TavernMemoryDecisionRef? decisionRef;
}

class _ToolLoopFailure implements Exception {
  const _ToolLoopFailure(this.code, this.detail);
  final String code, detail;
}

String? _ordinaryFailureCode(Object error) => switch (error) {
  _ToolLoopFailure(:final code) => code,
  StoredToolOwnershipException() => 'anchor_changed',
  StoredToolBudgetException() => 'budget_exhausted',
  _ => null,
};

String _ordinaryFailureOutcome(_Turn turn, TavernTurnInspection inspection) =>
    turn.toolFailureCode ?? inspection.failure?.name ?? 'failed';

Map<String, Object?> _ordinaryTurnSummary(_Turn turn) => {
  'version': 1,
  'requestCount': turn.toolRequests.length,
  'providerFinishReason': turn.finishReason,
  'toolFailureCode': turn.toolFailureCode,
  'usageSummary': _ordinaryUsageSummary(turn),
};

class _ToolFinalAdoption {
  _ToolFinalAdoption(this.message, this.inspection, this.state, this.variables);
  final TavernMessage message;
  final TavernTurnInspection inspection;
  final Map<String, Object?> state, variables;
}

void _commitOrdinaryToolFinal(
  TavernEngine engine,
  _Turn turn,
  TavernTurnInspection inspection,
  Map<String, Object?> state,
  Map<String, Object?>? ownAudit,
  _StateSettlement? stateSettlement,
  _StorySettlement? storySettlement,
) {
  final started = turn.profile?.now;
  try {
    final onTiming = turn.profile?.stageRecorder('final_');
    final message = engine._buffered(turn);
    final successful = inspection.status == TavernInspectionStatus.completed;
    final kind = !successful
        ? StoredToolFinishKind.failedPartial
        : turn.modelTerminal
        ? StoredToolFinishKind.modelTerminal
        : StoredToolFinishKind.normal;
    final outcome = kind == StoredToolFinishKind.normal
        ? 'normal'
        : kind == StoredToolFinishKind.modelTerminal
        ? 'model_terminal'
        : _ordinaryFailureOutcome(turn, inspection);
    final terminal = engine._store.finishToolTurn<_ToolFinalAdoption>(
      turn.toolOwner!,
      kind: kind,
      outcome: outcome,
      summary: _ordinaryTurnSummary(turn),
      onTiming: onTiming,
      stateSettlements: stateSettlement?.toolSettlements ?? const [],
      action: () {
        if (successful) {
          _ensureAdoptedGameplay(engine, turn, state, stateSettlement, storySettlement);
        }
        final inspectionStarted = turn.profile?.now;
        final extra = engine._inspectionExtra(engine._store.node(turn.chat.id, message.nodeId).extra, inspection);
        extra['dshgo'] = {
          ...(extra['dshgo'] as Map<String, Object?>),
          ...?ownAudit,
          ...?storySettlement?.ownAudit,
          'tavernState': state,
        };
        turn.profile?.record('final_inspection', inspectionStarted!);
        final nodeStarted = turn.profile?.now;
        final stored = engine._store.updateMessage(
          turn.chat.id,
          message.nodeId,
          text: message.text,
          reasoning: message.reasoning,
          clearReasoning: message.reasoning == null,
          usage: message.usage,
          clearUsage: message.usage == null,
          extra: extra,
        );
        turn.profile?.record('final_node_write', nodeStarted!);
        final metadataStarted = turn.profile?.now;
        engine._store.updateChat(
          turn.chat.id,
          variables: _copy(turn.variables),
          metadata: engine._latestInspectionMetadata(
            _runtimeMetadata(engine._store.chat(turn.chat.id).metadata, state),
            inspection,
          ),
        );
        turn.profile?.record('final_metadata', metadataStarted!);
        final stateRunsAt = turn.profile?.now;
        _writeStateRuns(engine._store, turn, stateSettlement, message.nodeId);
        _writeStoryRun(engine._store, turn, storySettlement, message.nodeId);
        final prepared = _ToolFinalAdoption(stored, inspection, _copy(state), _runtimeCopy(turn.variables));
        turn.profile?.record('final_state_runs_prepare', stateRunsAt!);
        return prepared;
      },
      onCommitted: (committed) {
        final prepared = committed.value;
        turn.terminalStorageAdopted = true;
        turn.replyCommitAdopted = committed.snapshot.replyCommitAdopted;
        turn.normalFinalAdopted = committed.snapshot.normalFinalAdopted;
        turn.toolPhase = committed.ownership.phase;
        turn.lastCommitted = prepared.message;
        turn.state = prepared.state;
        turn.dirty = false;
        if (stateSettlement != null) turn.stateRunsWritten = true;
        if (storySettlement != null) turn.storyRunWritten = true;
        if (successful) turn.modelCommitted = true;
        engine._liveVariables[turn.chat.id] = (leaf: prepared.message.nodeId, values: prepared.variables);
        engine._setInspection(turn, prepared.inspection);
      },
    );
    for (final id in terminal.affectedReceiptIds) {
      _toolActivity(turn, executionId: id);
    }
    for (final id in terminal.affectedProposalIds) {
      _toolActivity(turn, proposalId: id);
    }
    onTiming?.call('activity');
  } finally {
    turn.profile?.record('final_store', started!);
  }
}

class _ToolCleanupAdoption {
  _ToolCleanupAdoption(this.inspection, this.variables);
  final TavernTurnInspection inspection;
  final Map<String, Object?> variables;
}

void _rollbackOrdinaryToolTurn(
  TavernEngine engine,
  _Turn turn,
  TavernTurnInspection failed,
  _StateSettlement? stateSettlement,
  _StorySettlement? storySettlement,
) {
  if (turn.terminalStorageAdopted) return;
  final owner = turn.toolOwner!;
  final outcome = _ordinaryFailureOutcome(turn, failed);
  if (turn.toolPhase == StoredToolPhase.hooks) {
    engine._store.terminateToolTurnAudit(
      owner,
      outcome: outcome,
      summary: _ordinaryTurnSummary(turn),
      audit: () {
        engine._writeLatestInspection(turn.chat.id, failed);
        return failed;
      },
      onCommitted: (committed) {
        turn.terminalStorageAdopted = true;
        turn.toolPhase = committed.ownership.phase;
        engine._setInspection(turn, committed.value);
      },
    );
    return;
  }
  final first = turn.originalFirstMessage;
  final restoreFirst =
      turn.firstMessageCommitted &&
      first != null &&
      first.message.nodeId != turn.newUserId &&
      !(turn.kind == _TurnKind.continueReply && first.message.nodeId == turn.reply?.nodeId);
  final plan = StoredToolRollbackPlan(
    appendedUserSource: turn.newUserSource,
    continuationRestore: turn.toolPhase == StoredToolPhase.owned && turn.kind == _TurnKind.continueReply
        ? turn.originalTarget
        : null,
    firstMessageRestore: restoreFirst
        ? StoredToolBodyRewrite(source: turn.committedFirstMessageSource!, text: first.message.text)
        : null,
    previousSelections: turn.previousSelections,
    selectedLeafId: turn.chat.currentLeafId,
    variables: turn.chat.variables,
  );
  _ToolCleanupAdoption audit(StoredToolCleanupFacts facts) {
    final auditNodeId = facts.continueRestored ? facts.visibleReply?.nodeId : null;
    final actualFailure = facts.casMatched
        ? failed
        : failed.copyWith(failure: TavernFailure.toolFailure, detail: 'tool_anchor_changed (${facts.mismatchReason})');
    // Restoring an old reply does not give this empty failed attempt a node.
    // Keep its latest snapshot separate from that reply's restored inspection.
    final inspection = actualFailure.copyWith(clearNodeId: true);
    engine._writeLatestInspection(turn.chat.id, inspection);
    _writeStateRuns(engine._store, turn, stateSettlement, auditNodeId);
    _writeStoryRun(engine._store, turn, storySettlement, auditNodeId);
    return _ToolCleanupAdoption(inspection, _runtimeCopy(turn.originalVariables));
  }

  void adopted(StoredToolCleanup<_ToolCleanupAdoption> committed) {
    turn.terminalStorageAdopted = true;
    turn.replyCommitAdopted = committed.snapshot.replyCommitAdopted;
    turn.normalFinalAdopted = committed.snapshot.normalFinalAdopted;
    turn.toolPhase = committed.ownership.phase;
    turn.toolCleanupFacts = committed.facts;
    if (!committed.facts.casMatched) turn.toolFailureCode = 'anchor_changed';
    turn.lastCommitted = committed.facts.visibleReply ?? committed.facts.visibleUser;
    turn.dirty = false;
    if (stateSettlement != null) turn.stateRunsWritten = true;
    if (storySettlement != null) turn.storyRunWritten = true;
    if (committed.facts.casMatched) {
      engine._liveVariables[turn.chat.id] = (
        leaf: committed.facts.currentContextAnchor.selectedLeaf?.nodeId,
        values: committed.value.variables,
      );
    } else {
      engine._liveVariables.remove(turn.chat.id);
    }
    engine._setInspection(turn, committed.value.inspection);
  }

  if (turn.toolPhase == StoredToolPhase.owned) {
    engine._store.rollbackOwnedToolTurn<_ToolCleanupAdoption>(
      owner,
      plan: plan,
      outcome: outcome,
      summary: _ordinaryTurnSummary(turn),
      audit: audit,
      onCommitted: adopted,
    );
  } else {
    engine._store.rollbackPreparingToolTurn<_ToolCleanupAdoption>(
      owner,
      plan: plan,
      outcome: outcome,
      summary: _ordinaryTurnSummary(turn),
      audit: audit,
      onCommitted: adopted,
    );
  }
}

TavernMessage? _currentOrdinaryPartial(TavernEngine engine, _Turn turn) {
  for (final id in [turn.reply?.nodeId, turn.newUserId]) {
    if (id == null) continue;
    try {
      return engine._store.message(turn.chat.id, id);
    } on StateError {
      /* This originally named node is no longer visible. */
    }
  }
  return null;
}

void _terminateOrdinaryFailureAudit(
  TavernEngine engine,
  _Turn turn,
  TavernTurnInspection inspection,
  _StateSettlement? stateSettlement,
  _StorySettlement? storySettlement,
) {
  if (turn.terminalStorageAdopted) return;
  engine._store.terminateToolTurnAudit(
    turn.toolOwner!,
    outcome: _ordinaryFailureOutcome(turn, inspection),
    summary: _ordinaryTurnSummary(turn),
    audit: () {
      engine._writeLatestInspection(turn.chat.id, inspection);
      _writeStateRuns(engine._store, turn, stateSettlement, null);
      _writeStoryRun(engine._store, turn, storySettlement, null);
      return (inspection: inspection, partial: _currentOrdinaryPartial(engine, turn));
    },
    onCommitted: (committed) {
      turn.terminalStorageAdopted = true;
      turn.replyCommitAdopted = committed.snapshot.replyCommitAdopted;
      turn.normalFinalAdopted = committed.snapshot.normalFinalAdopted;
      turn.toolPhase = committed.ownership.phase;
      turn.lastCommitted = committed.value.partial;
      if (stateSettlement != null) turn.stateRunsWritten = true;
      if (storySettlement != null) turn.storyRunWritten = true;
      engine._liveVariables.remove(turn.chat.id);
      engine._setInspection(turn, committed.value.inspection);
    },
  );
}

Future<void> _failOrdinaryToolTurn(TavernEngine engine, _Turn turn, Object error, int beforeGlobals) async {
  turn.toolFailureCode ??= _ordinaryFailureCode(error);
  var failure = turn.toolFailureCode != null
      ? TavernFailure.toolFailure
      : error is TavernModelException
      ? error.kind
      : error is PromptBudgetExceeded
      ? TavernFailure.contextTooLong
      : error is TavernImportError || error is FormatException
      ? TavernFailure.invalidCard
      : TavernFailure.server;
  var detail = error is _ToolLoopFailure
      ? error.detail
      : error is TavernModelException
      ? error.detail
      : error is StoredToolOwnershipException
      ? 'tool_anchor_changed (${error.reason})'
      : _safeDetail(error);
  var inspection = turn.inspection.copyWith(
    status: TavernInspectionStatus.failed,
    finishedAt: engine._clock(),
    failure: failure,
    detail: detail,
  );
  TavernMessage? partial;
  _StateSettlement? stateSettlement;
  _StorySettlement? storySettlement;
  void publicationFailure(Object problem) {
    turn.hookIssues.add(
      TavernScriptIssue(
        code: 'hookFailure',
        message: 'Terminal storage was adopted before publication failed (${problem.runtimeType}).',
        committed: true,
        generationId: turn.generationId,
      ),
    );
  }

  if (!turn.terminalStorageAdopted) {
    try {
      engine._finishRegex(turn);
    } catch (problem) {
      if (turn.toolFailureCode == null) failure = TavernFailure.server;
      detail = 'writeback_failed (${problem.runtimeType})';
      inspection = inspection.copyWith(failure: failure, detail: detail);
    }
    try {
      if (engine._globalVariables.changedSince(beforeGlobals)) await engine._saveDocument();
    } catch (problem) {
      if (turn.toolFailureCode == null) failure = TavernFailure.server;
      detail = 'turn_storage_failure (${problem.runtimeType})';
      inspection = inspection.copyWith(failure: failure, detail: detail);
    }
    try {
      if (turn.nativePreparationStarted) {
        stateSettlement = _failedStateSettlement(engine, turn, inspection);
        storySettlement = _failedStorySettlement(turn, inspection);
      }
      if (turn.hasOutput && turn.toolFailureCode != 'anchor_changed') {
        engine._commitTurn(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
      } else {
        inspection = inspection.copyWith(clearNodeId: true);
        engine._rollbackEmpty(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
      }
    } catch (storageError) {
      if (turn.terminalStorageAdopted) {
        publicationFailure(storageError);
      } else {
        if (storageError is StoredToolOwnershipException) {
          turn.toolFailureCode = 'anchor_changed';
          failure = TavernFailure.toolFailure;
          detail = 'tool_anchor_changed (${storageError.reason})';
        } else {
          if (turn.toolFailureCode == null) failure = TavernFailure.server;
          detail = 'turn_storage_failure (${storageError.runtimeType})';
        }
        inspection = inspection.copyWith(failure: failure, detail: detail);
        try {
          if (storageError is StoredToolOwnershipException) {
            // The cleanup routine checks the same old expectation and records
            // actual visible facts. It never adopts a refreshed body baseline.
            inspection = inspection.copyWith(clearNodeId: true);
            engine._rollbackEmpty(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
          } else {
            _terminateOrdinaryFailureAudit(engine, turn, inspection, stateSettlement, storySettlement);
          }
        } catch (auditError) {
          if (turn.terminalStorageAdopted) {
            publicationFailure(auditError);
          } else {
            detail = 'turn_storage_unconfirmed (${auditError.runtimeType})';
            inspection = inspection.copyWith(detail: detail);
          }
        }
      }
    }
  } else {
    publicationFailure(error);
  }
  if (turn.terminalStorageAdopted) {
    final facts = turn.toolCleanupFacts;
    partial = facts == null ? turn.lastCommitted : facts.visibleReply ?? facts.visibleUser;
    inspection = turn.inspection;
    failure = inspection.failure ?? failure;
    detail = inspection.detail ?? detail;
  } else {
    try {
      partial = _currentOrdinaryPartial(engine, turn);
    } catch (_) {
      partial = turn.lastCommitted;
    }
  }
  engine._setInspection(turn, inspection);
  turn.emit(
    TavernTurnFailed(
      failure,
      detail: detail,
      partial: partial,
      logicalTurnId: turn.toolLogicalId,
      toolFailureCode: turn.toolFailureCode,
      hookIssues: turn.hookIssues,
    ),
  );
  turn.terminal = true;
}

class _OrdinaryToolRequest {
  _OrdinaryToolRequest(this.authorization, this.stateAllowed, Iterable<String> spresetNames)
    : spresetNames = Set.unmodifiable(spresetNames);
  final ToolWireAuthorization authorization;
  final bool stateAllowed;
  final Set<String> spresetNames;
  final accumulator = ModelToolAccumulator();
  final streamingUsage = StreamingToolUsage();
  late TavernToolRequestSnapshot snapshot;
  Map<String, Object?> usage = emptyToolUsageLedger();
  Map<String, Object?> diagnostics = {};
  ModelAssistantSnapshot? assistant;
  ModelToolBatch? batch;
  String? finishReason;
  bool responseComplete = false;
  bool rowFinished = false;
  int legacyObservationIndex = 0;
  final receipts = <int, TavernToolReceipt>{};
}

Map<String, Object?> _ordinaryUsageSummary(_Turn turn) => summarizeToolUsage([
  for (final request in turn.toolRequests) (requestIndex: request.snapshot.requestIndex, usage: request.usage),
]);

({TavernUsage? usage, TavernTurnInspection inspection})? _prepareOrdinaryUsage(
  _Turn turn,
  _OrdinaryToolRequest request,
  Map<String, Object?> nextLedger, {
  TavernUsage? normalizedUsage,
}) {
  // Prepare every derived value before SQL, then adopt it with the ledger.
  // A later publication failure cannot leave a formerly complete total live.
  if (turn.toolRequests.length < 2 && normalizedUsage == null) return null;
  final usage = turn.toolRequests.length < 2
      ? normalizedUsage
      : completeToolUsage(
          summarizeToolUsage([
            for (final item in turn.toolRequests)
              (requestIndex: item.snapshot.requestIndex, usage: identical(item, request) ? nextLedger : item.usage),
          ]),
          model: turn.config.model,
        );
  return (usage: usage, inspection: turn.inspection.copyWith(reportedUsage: usage, clearReportedUsage: usage == null));
}

void _adoptOrdinaryUsage(
  TavernEngine engine,
  _Turn turn,
  ({TavernUsage? usage, TavernTurnInspection inspection})? prepared,
) {
  if (prepared == null) return;
  turn.usage = prepared.usage;
  engine._setInspection(turn, prepared.inspection);
}

void _recordOrdinaryUsage(
  TavernEngine engine,
  _Turn turn,
  _OrdinaryToolRequest request,
  ModelUsageReport report, {
  TavernUsage? normalizedUsage,
}) {
  final started = turn.profile?.now;
  try {
    if (report.transport == 'streaming' && report.origin != 'legacy_normalized') {
      if (!request.streamingUsage.observe(report, normalizedUsage: normalizedUsage)) return;
      if (turn.toolRequests.length > 1) {
        final latest = request.streamingUsage.record(request.usage);
        _adoptOrdinaryUsage(
          engine,
          turn,
          _prepareOrdinaryUsage(turn, request, latest.ledger, normalizedUsage: normalizedUsage),
        );
      }
      return;
    }
    // A custom/nonstream observation keeps its immediate adoption contract.
    // Include any earlier streaming snapshots in that same write, in order.
    final pending = request.streamingUsage.record(request.usage);
    final next = recordToolUsageObservation(pending.ledger, report: report, normalizedUsage: normalizedUsage);
    if (_stateJsonEqual(next.ledger, request.usage)) {
      request.streamingUsage.clear();
      return;
    }
    final diagnostics = <String, Object?>{
      ...request.diagnostics,
      'usage': [..._stateRows(request.diagnostics['usage']), ...pending.diagnostics, ...next.diagnostics],
    };
    final preparedUsage = _prepareOrdinaryUsage(turn, request, next.ledger, normalizedUsage: normalizedUsage);
    engine._store.observeToolRequest(
      request.snapshot.requestId,
      usage: next.ledger,
      batchDiagnostics: diagnostics,
      onCommitted: (snapshot) {
        request.snapshot = snapshot;
        request.usage = next.ledger;
        request.streamingUsage.clear();
        request.diagnostics = diagnostics;
        _adoptOrdinaryUsage(engine, turn, preparedUsage);
        if (normalizedUsage != null) turn.hasOutput = true;
      },
    );
  } finally {
    turn.profile?.record('usage', started!);
  }
}

void _toolActivity(_Turn turn, {String? requestId, String? executionId, String? proposalId}) {
  turn.emit(
    TavernToolActivity(turn.toolLogicalId, requestId: requestId, executionId: executionId, proposalId: proposalId),
  );
}

_OrdinaryToolRequest _registerOrdinaryRequest(TavernEngine engine, _Turn turn, Map<String, Object?> body) {
  final started = turn.profile?.now;
  try {
    final authorization = toolWireAuthorization(
      config: turn.config,
      body: body,
      policy: turn.toolPolicy!,
      showThoughts: turn.effectiveShowThoughts,
    );
    final request = _OrdinaryToolRequest(
      authorization,
      turn.stateAutomatic && !turn.effectiveThinking && _finalStateToolAllowed(body),
      turn.spreset?.offeredNames(body) ?? const <String>[],
    );
    final requests = [...turn.toolRequests, request];
    final inspection = requests.length < 2 ? turn.inspection : turn.inspection.copyWith(clearReportedUsage: true);
    engine._store.registerToolRequest(
      turn.toolOwner!,
      offeredTools: authorization.offeredTools,
      wireAuthorization: {...authorization.toJson(), 'spresetTools': request.spresetNames.toList()},
      requestLimit: turn.spreset == null ? 4 : turn.spreset!.requestLimit,
      onCommitted: (snapshot) {
        request.snapshot = snapshot;
        turn.toolRequests = requests;
        turn.toolRequest = request;
        turn.stateTools = request.accumulator;
        turn.finishReason = null;
        if (requests.length > 1) turn.usage = null;
        engine._setInspection(turn, inspection);
      },
    );
    _toolActivity(turn, requestId: request.snapshot.requestId);
    return request;
  } finally {
    turn.profile?.record('request_register', started!);
  }
}

void _finishOrdinaryRequest(TavernEngine engine, _Turn turn, _OrdinaryToolRequest request, {Object? error}) {
  if (request.rowFinished) return;
  final started = turn.profile?.now;
  try {
    final batch = request.batch ??= request.accumulator.finish();
    final active = turn.spreset;
    // A valid SPreset follow-up keeps its own budget even if this response also
    // contains a now-exhausted native roll. Actual offer names were persisted.
    final needsSPreset =
        active != null &&
        active.permitsDepth(request.snapshot.requestIndex - 1) &&
        batch.calls.any((call) => request.spresetNames.contains(call.name));
    final rejection = _ordinaryBatchRejection(request, skipNativeBudget: needsSPreset);
    final pending = request.streamingUsage.record(request.usage);
    final diagnostics = <String, Object?>{
      ...request.diagnostics,
      'batch': batch.toJson(),
      if (!request.streamingUsage.isEmpty)
        'usage': [..._stateRows(request.diagnostics['usage']), ...pending.diagnostics],
      if (rejection != null) 'outcome': rejection.outcome,
    };
    final preparedUsage = _prepareOrdinaryUsage(
      turn,
      request,
      pending.ledger,
      normalizedUsage: request.streamingUsage.normalizedUsage,
    );
    try {
      engine._store.finishToolRequest(
        request.snapshot.requestId,
        status: request.responseComplete
            ? 'response_complete'
            : error == null
            ? 'interrupted'
            : 'failed',
        responseComplete: request.responseComplete,
        providerFinishReason: request.finishReason,
        responseSnapshot: request.assistant?.toJson(),
        usage: pending.ledger,
        batchDiagnostics: diagnostics,
        error: error == null
            ? null
            : {
                'code': error is TavernModelException ? error.kind.name : 'request_failure',
                'type': '${error.runtimeType}',
              },
        onCommitted: (snapshot) {
          request.snapshot = snapshot;
          request.usage = pending.ledger;
          request.streamingUsage.clear();
          request.diagnostics = diagnostics;
          request.rowFinished = true;
          _adoptOrdinaryUsage(engine, turn, preparedUsage);
        },
      );
    } catch (_) {
      // Only an adopted complete response can supply this primary preflight
      // failure when publication of its durable response seal itself fails.
      if (request.rowFinished) {
        turn.toolFailureCode ??= _ordinaryBatchRejection(request, skipNativeBudget: needsSPreset)?.code;
      }
      rethrow;
    }
    _toolActivity(turn, requestId: request.snapshot.requestId);
  } finally {
    turn.profile?.record('request_finish', started!);
  }
}

void _recordOrdinaryBatchOutcome(TavernEngine engine, _OrdinaryToolRequest request, String outcome) {
  final diagnostics = <String, Object?>{...request.diagnostics, 'outcome': outcome};
  engine._store.observeToolRequest(
    request.snapshot.requestId,
    batchDiagnostics: diagnostics,
    onCommitted: (snapshot) {
      request.snapshot = snapshot;
      request.diagnostics = diagnostics;
    },
  );
}

Never _rejectOrdinaryBatch(
  TavernEngine engine,
  _Turn turn,
  _OrdinaryToolRequest request,
  String code,
  String outcome,
  String detail,
) {
  // This primary failure is already certain before its diagnostic transaction.
  // A post-commit observer must not replace it with an unclassified server error.
  turn.toolFailureCode = code;
  if (request.diagnostics['outcome'] != outcome) _recordOrdinaryBatchOutcome(engine, request, outcome);
  throw _ToolLoopFailure(code, detail);
}

bool _sameAssistantCalls(ModelAssistantSnapshot snapshot, ModelToolBatch batch) {
  if (!snapshot.completeForReplay || snapshot.calls.length != batch.calls.length) return false;
  final byIndex = {for (final call in snapshot.calls) call.index: call};
  if (byIndex.length != snapshot.calls.length) return false;
  for (final call in batch.calls) {
    final actual = byIndex[call.index];
    if (actual == null ||
        actual.id != call.id ||
        actual.type != call.type ||
        actual.name != call.name ||
        actual.arguments != call.arguments) {
      return false;
    }
  }
  return true;
}

({String code, String outcome, String detail})? _ordinaryBatchRejection(
  _OrdinaryToolRequest request, {
  bool skipNativeBudget = false,
}) {
  final batch = request.batch;
  if (!request.responseComplete ||
      batch == null ||
      request.finishReason != 'stop' && request.finishReason != 'tool_calls' ||
      !request.authorization.rollAllowed ||
      !batch.rollNameObserved) {
    return null;
  }
  if (!skipNativeBudget && request.snapshot.requestIndex >= 4) {
    return (
      code: 'budget_exhausted',
      outcome: 'not_executed_budget',
      detail: 'The fourth response requires another tool request.',
    );
  }
  if (batch.resourceOverflow) {
    return (
      code: 'batch_limit',
      outcome: 'not_executed_batch_limit',
      detail: 'The tool response exceeds its resource limits.',
    );
  }
  if (!batch.finalIdentityComplete ||
      !batch.originalArgumentsStringComplete ||
      batch.hasUnassignedFragment ||
      batch.metadataConflict ||
      batch.unsupportedEnvelope) {
    return (
      code: 'protocol_invalid',
      outcome: 'not_executed_protocol',
      detail: 'The tool response cannot be replayed with its real identities.',
    );
  }
  final snapshot = request.assistant;
  if (snapshot == null || !snapshot.completeForReplay) {
    return (
      code: 'unsupported_response_snapshot',
      outcome: 'not_executed_response_snapshot',
      detail: 'A complete response-only assistant snapshot is required.',
    );
  }
  if (!_sameAssistantCalls(snapshot, batch)) {
    return (
      code: 'protocol_invalid',
      outcome: 'not_executed_protocol',
      detail: 'The assistant snapshot disagrees with its collected tool calls.',
    );
  }
  return null;
}

Future<void> _consumeOrdinaryTools(TavernEngine engine, _Turn turn, Map<String, Object?> initialBody) async {
  var body = _copy(initialBody);
  while (true) {
    final wireBody = await turn.spreset?.request(body) ?? body;
    final request = _registerOrdinaryRequest(engine, turn, wireBody);
    try {
      await engine._consume(turn, wireBody, request: request);
    } catch (error) {
      _finishOrdinaryRequest(engine, turn, request, error: error);
      rethrow;
    }
    _finishOrdinaryRequest(engine, turn, request);
    turn.cancellation.check();
    final batch = request.batch!;
    if (request.finishReason != 'stop' && request.finishReason != 'tool_calls') {
      turn.modelTerminal = true;
      _stageOrdinaryStateDiagnostics(turn, request, normal: false);
      return;
    }
    final nativeRollExhausted = request.snapshot.requestIndex >= 4;
    final needsRoll = !nativeRollExhausted && request.authorization.rollAllowed && batch.rollNameObserved;
    final spreset = turn.spreset;
    final spresetNames = request.spresetNames;
    final needsSPreset =
        spreset != null &&
        spreset.permitsDepth(request.snapshot.requestIndex - 1) &&
        batch.calls.any((call) => spresetNames.contains(call.name));
    if (needsSPreset &&
        (batch.resourceOverflow ||
            batch.hasUnassignedFragment ||
            !batch.finalIdentityComplete ||
            !batch.originalArgumentsStringComplete ||
            batch.metadataConflict ||
            batch.unsupportedEnvelope ||
            request.assistant?.completeForReplay != true ||
            !_sameAssistantCalls(request.assistant!, batch))) {
      _rejectOrdinaryBatch(
        engine,
        turn,
        request,
        'protocol_invalid',
        'not_executed_protocol',
        'SPreset tool calls require a complete replayable assistant response.',
      );
    }
    final rejection = _ordinaryBatchRejection(request, skipNativeBudget: needsSPreset);
    if (rejection != null) {
      _rejectOrdinaryBatch(engine, turn, request, rejection.code, rejection.outcome, rejection.detail);
    }
    _stageOrdinaryStateBatchTrace(turn, request);
    var stealth = false;
    for (final call in batch.calls) {
      turn.cancellation.check();
      _requireOrdinaryOwnership(engine, turn, StoredToolPhase.owned);
      if (spresetNames.contains(call.name)) {
        if (needsSPreset) {
          stealth = await _processSPresetToolCall(engine, turn, request, call, spreset) || stealth;
        } else if (call.identityComplete && call.originalArgumentsStringComplete) {
          final receipt = _prepareOrdinaryReceipt(
            engine,
            turn,
            request,
            call,
            status: 'rejected',
            error: {'code': 'spreset_recursion_limit'},
          );
          _sealOrdinaryReceipt(engine, turn, request, call, receipt);
          spreset?.diagnose(
            'ToolBindings',
            const SPresetException('ToolBindings', 'Tool recursion limit reached; no action was invoked.'),
          );
        }
      } else if (nativeRollExhausted && call.name == 'roll' && needsSPreset) {
        final receipt = _prepareOrdinaryReceipt(
          engine,
          turn,
          request,
          call,
          status: 'rejected',
          error: {'code': 'native_roll_budget_exhausted'},
        );
        _sealOrdinaryReceipt(engine, turn, request, call, receipt);
      } else {
        _processOrdinaryToolCall(engine, turn, request, call);
      }
    }
    if (stealth || !needsRoll && !needsSPreset) return;
    turn.cancellation.check();
    final messages = body['messages'];
    if (messages is! List<Object?>) {
      throw const _ToolLoopFailure('protocol_invalid', 'The original request messages are not replayable.');
    }
    final exchange = <Map<String, Object?>>[];
    for (final call in batch.calls) {
      final receipt = request.receipts[call.index];
      if (receipt == null) {
        throw const _ToolLoopFailure('receipt_failure', 'A complete batch result was not persisted.');
      }
      final wire = engine._store.toolWireResult(receipt.executionId);
      if (wire == null) throw const _ToolLoopFailure('receipt_failure', 'A batch result was not sealed.');
      final content = spresetNames.contains(call.name) ? _map(jsonDecode(wire))['spresetResult'] ?? wire : wire;
      exchange.add({'role': 'tool', 'tool_call_id': call.id, 'content': content});
    }
    body = {
      ...body,
      'messages': [...messages, request.assistant!.wireMessage, ...exchange],
    };
  }
}

StoredModelToolCall _storedModelCall(
  _OrdinaryToolRequest request,
  ModelToolCall call, {
  Map<String, Object?>? validated,
}) => StoredModelToolCall(
  requestId: request.snapshot.requestId,
  toolIndex: call.index,
  callId: call.id!,
  toolName: call.name!,
  rawArguments: call.arguments,
  capturedParameters: call.parameters ?? const {},
  validatedParameters: validated,
);

TavernToolReceipt _prepareOrdinaryReceipt(
  TavernEngine engine,
  _Turn turn,
  _OrdinaryToolRequest request,
  ModelToolCall call, {
  required String status,
  Map<String, Object?>? validated,
  Map<String, Object?>? result,
  Map<String, Object?>? error,
  _StagedStateCall? stateCall,
}) {
  return engine._store.prepareToolReceipt(
    turn.toolOwner!,
    call: _storedModelCall(request, call, validated: validated),
    status: status,
    result: result,
    error: error,
    onCommitted: (receipt) {
      request.receipts[call.index] = receipt;
      if (stateCall != null) stateCall.receipt = receipt;
    },
  );
}

void _sealOrdinaryReceipt(
  TavernEngine engine,
  _Turn turn,
  _OrdinaryToolRequest request,
  ModelToolCall call,
  TavernToolReceipt receipt,
) {
  final wire = jsonEncode({
    'version': 1,
    'executionId': receipt.executionId,
    'tool': receipt.kind,
    'status': receipt.status,
    'committed': receipt.committed,
    'result': receipt.result,
    'error': receipt.error,
  });
  engine._store.sealToolReceiptWireResult(
    receipt.executionId,
    wireResultJson: wire,
    onCommitted: (sealed) {
      request.receipts[call.index] = sealed;
    },
  );
  _toolActivity(
    turn,
    requestId: request.snapshot.requestId,
    executionId: receipt.executionId,
    proposalId: receipt.proposalId,
  );
}

void _processOrdinaryToolCall(TavernEngine engine, _Turn turn, _OrdinaryToolRequest request, ModelToolCall call) {
  final stateCall = call.name == 'roll' || call.name == 'remember'
      ? null
      : _stageOrdinaryStateCall(turn, request, call, normal: true);
  // Raw fragments without a complete unique identity are diagnostics only.
  // In particular an overflow prefix must never acquire an execution ID.
  if (!call.identityComplete || !call.originalArgumentsStringComplete || call.metadataConflict) return;
  try {
    TavernToolReceipt receipt;
    final parameters = call.parameters;
    Map<String, Object?>? rejection;
    if (!call.valid ||
        parameters == null ||
        ((call.name == 'roll' || call.name == 'remember') && call.unsupportedEnvelope)) {
      rejection = {
        'code': 'invalid_arguments',
        'issues': [
          for (final issue in call.issues) {'code': issue['code'], 'field': issue['field']},
        ],
      };
    }
    if (call.name == 'update_state' && stateCall != null) {
      final execution = stateCall.execution;
      final status = execution == null || execution.acceptedCount == 0 && execution.rejectedCount > 0
          ? 'rejected'
          : 'staged';
      receipt = _prepareOrdinaryReceipt(
        engine,
        turn,
        request,
        call,
        status: status,
        result: _stateToolWire(stateCall, status),
        error: rejection,
        stateCall: stateCall,
      );
    } else if (rejection != null) {
      receipt = _prepareOrdinaryReceipt(
        engine,
        turn,
        request,
        call,
        status: 'rejected',
        error: rejection,
        stateCall: stateCall,
      );
    } else if (call.name == 'roll') {
      if (!request.authorization.rollAllowed) {
        receipt = _prepareOrdinaryReceipt(
          engine,
          turn,
          request,
          call,
          status: 'rejected',
          error: {'code': 'tool_not_offered'},
        );
      } else {
        _RollParameters roll;
        try {
          roll = _parseRoll(parameters!);
        } on _ToolArgumentFailure catch (error) {
          receipt = _prepareOrdinaryReceipt(engine, turn, request, call, status: 'rejected', error: error.toJson());
          _sealOrdinaryReceipt(engine, turn, request, call, receipt);
          return;
        }
        try {
          receipt = _prepareOrdinaryReceipt(engine, turn, request, call, status: 'prepared', validated: roll.toJson());
        } catch (error) {
          // The intent may already be durable when its observer throws. No
          // draw has been dispatched here, so this is a known non-execution.
          final prepared = request.receipts[call.index];
          if (prepared?.status == 'prepared') {
            try {
              engine._store.cancelToolReceiptBeforeExecution(
                prepared!.executionId,
                reason: {'code': 'intent_publication_failure', 'type': '${error.runtimeType}'},
                onCommitted: (cancelled) {
                  request.receipts[call.index] = cancelled;
                },
              );
            } catch (_) {
              /* The durable intent remains available for recovery. */
            }
          }
          rethrow;
        }
        Object? beforeDrawError;
        receipt = _drawToolRoll(
          engine,
          receipt,
          roll,
          beforeDraw: () {
            try {
              turn.cancellation.check();
              _requireOrdinaryOwnership(engine, turn, StoredToolPhase.owned);
            } catch (error) {
              beforeDrawError = error;
              rethrow;
            }
          },
        );
        request.receipts[call.index] = receipt;
        if (receipt.committed != true) {
          final before = beforeDrawError;
          if (before != null) throw before;
          throw const _ToolLoopFailure('receipt_failure', 'The roll result could not be confirmed.');
        }
        if (receipt.error?['code'] == 'publication_failure') {
          throw const _ToolLoopFailure('receipt_failure', 'The roll committed but its publication failed.');
        }
      }
    } else if (call.name == 'remember') {
      if (!request.authorization.rememberAllowed) {
        receipt = _prepareOrdinaryReceipt(
          engine,
          turn,
          request,
          call,
          status: 'rejected',
          error: {'code': 'tool_not_offered'},
        );
      } else {
        ({String text, List<String> keywords}) memory;
        try {
          memory = _parseRemember(parameters!);
        } on _ToolArgumentFailure catch (error) {
          receipt = _prepareOrdinaryReceipt(engine, turn, request, call, status: 'rejected', error: error.toJson());
          _sealOrdinaryReceipt(engine, turn, request, call, receipt);
          return;
        }
        final staged = engine._store.stageMemoryProposal(
          turn.toolOwner!,
          call: _storedModelCall(request, call),
          mode: turn.toolPolicy!.rememberMode,
          text: memory.text,
          keywords: memory.keywords,
          onCommitted: (prepared) {
            request.receipts[call.index] = prepared.receipt;
          },
        );
        receipt = staged.receipt;
      }
    } else {
      receipt = _prepareOrdinaryReceipt(
        engine,
        turn,
        request,
        call,
        status: 'rejected',
        error: {'code': 'unknown_tool'},
        stateCall: stateCall,
      );
    }
    _sealOrdinaryReceipt(engine, turn, request, call, receipt);
  } on _ToolLoopFailure {
    rethrow;
  } on StoredToolOwnershipException {
    rethrow;
  } on TavernModelException {
    rethrow;
  } catch (error) {
    throw _ToolLoopFailure('receipt_failure', 'Tool receipt processing failed (${error.runtimeType}).');
  }
}

void _beginOrdinaryToolTurn(TavernEngine engine, _Turn turn) {
  if (turn.kind == _TurnKind.impersonate) return;
  final scope = turn.groupRound?.toolPolicyScope ?? _toolScope(engine, turn.chat);
  final groupView = turn.groupRound?.view;
  final captured = groupView == null
      ? null
      : captureToolPolicy(
          scope: scope,
          host: captureToolCardPolicy(groupView.host.card.data, characterId: turn.chat.characterId),
          actor: captureToolCardPolicy(groupView.cards[turn.actorId]!.card.data, characterId: turn.actorId),
        );
  final inspection = turn.inspection.copyWith(logicalTurnId: turn.toolLogicalId);
  turn.toolPolicyScope = scope;
  engine._store.beginToolTurn(
    owner: turn,
    logicalTurnId: turn.toolLogicalId,
    chatId: turn.chat.id,
    operation: switch (turn.kind) {
      _TurnKind.send => StoredToolOperation.send,
      _TurnKind.regenerate => StoredToolOperation.regenerate,
      _TurnKind.continueReply => StoredToolOperation.continueReply,
      _TurnKind.impersonate => throw StateError('Impersonation has no tool owner.'),
    },
    actorCharacterId: turn.actorId,
    hostCharacterId: turn.chat.characterId,
    groupRoundId: turn.groupRound?.id,
    operationTargetNodeId: turn.nodeId,
    policyScope: scope,
    capturedPolicy: captured?.toJson(),
    onCommitted: (committed) {
      turn.toolOwner = committed.value;
      turn.toolPhase = committed.ownership.phase;
      turn.toolAdmitted = true;
      turn.toolPolicy = captured;
      engine._setInspection(turn, inspection);
    },
  );
  if (captured == null) {
    turn.toolPolicyCapture = _captureToolPolicy(engine, scope, turn.chat.characterId, turn.actorId, turn.cancellation);
  }
}

class _ToolPreparationSnapshot {
  _ToolPreparationSnapshot(this.metadata, this.sourceFile, this.variables, this.globalRevision);
  final Map<String, Object?> metadata;
  final String? sourceFile;
  final Map<String, Object?> variables;
  final int globalRevision;
}

int _sealOrdinaryToolPreparation(TavernEngine engine, _Turn turn) {
  final started = turn.profile?.now;
  try {
    final committed = engine._store.sealToolPreparation<_ToolPreparationSnapshot>(
      turn.toolOwner!,
      onTiming: turn.profile?.stageRecorder('prepare_seal_'),
      capture: (chat, target) {
        final leaf = chat.currentLeafId;
        final sourceNode = target ?? (leaf == null ? null : engine._store.node(chat.id, leaf));
        final metadata = engine._chatCodec.metadataForCapturedNode(engine._store, chat, sourceNode);
        final sourceState = sourceNode == null
            ? engine._store.groupInitialState(chat.id)
            : engine._stateFromNode(chat.id, sourceNode, chat: chat);
        final source =
            sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
        return _ToolPreparationSnapshot(
          metadata,
          source is String ? source : null,
          _runtimeCopy(engine._liveVariables[chat.id]?.values ?? chat.variables),
          engine._globalVariables.revision,
        );
      },
      onCommitted: (prepared) {
        turn.chat = prepared.chat;
        turn.originalTarget = prepared.operationTarget;
        turn.metadata = prepared.value.metadata;
        turn.sourceFile = prepared.value.sourceFile;
        turn.originalVariables = prepared.value.variables;
        turn.nativePreparationStarted = true;
        turn.toolPhase = prepared.ownership.phase;
      },
    );
    return committed.value.globalRevision;
  } finally {
    turn.profile?.record('prepare_seal', started!);
  }
}

Future<void> _completeOrdinaryToolPolicy(TavernEngine engine, _Turn turn) async {
  final capture = turn.toolPolicyCapture;
  if (capture == null) return;
  final policy = await turn.cancellation.wait(capture.future);
  turn.cancellation.check();
  engine._store.completeToolTurnPolicy(
    turn.toolOwner!,
    capturedPolicy: policy.toJson(),
    onCommitted: (committed) {
      turn.toolPolicy = policy;
      turn.toolPhase = committed.ownership.phase;
    },
  );
}

void _requireOrdinaryOwnership(TavernEngine engine, _Turn turn, StoredToolPhase phase) {
  if (turn.toolOwner case final owner?) engine._store.requireToolOwnership(owner, phase: phase);
}

class _ToolPreparationPermit {
  const _ToolPreparationPermit(this.turn, this.owner);
  final _Turn turn;
  final StoredToolTurnOwner owner;
}

_ToolPreparationPermit? _captureToolPreparationPermit(TavernEngine engine, String chatId, {bool metadataOnly = false}) {
  if (!metadataOnly && engine._manualTools.containsKey(chatId)) {
    throw _scriptError(TavernScriptErrorCode.busy, 'write', 'A manual tool action owns this chat.');
  }
  final turn = engine._turns[chatId];
  if (turn == null || !turn.toolAdmitted) return null;
  if (turn.toolPhase == StoredToolPhase.terminal && turn.modelDrained.isCompleted) return null;
  if (turn.toolPhase == StoredToolPhase.hooks &&
      turn.scriptWritesAllowed &&
      !turn.cancellation.isCancelled &&
      turn.toolOwner!.belongsTo(turn)) {
    return _ToolPreparationPermit(turn, turn.toolOwner!);
  }
  if (metadataOnly &&
      !turn.cancellation.isCancelled &&
      (turn.toolPhase == StoredToolPhase.native || turn.toolPhase == StoredToolPhase.owned)) {
    return null;
  }
  throw _scriptError(
    TavernScriptErrorCode.busy,
    'write',
    'The ordinary turn preparation gate is closed.',
    generationId: turn.generationId,
  );
}

void _checkToolPreparationPermit(TavernEngine engine, _ToolPreparationPermit? permit) {
  if (permit == null) return;
  final turn = permit.turn;
  if (!identical(engine._turns[turn.chat.id], turn) ||
      !identical(turn.toolOwner, permit.owner) ||
      !permit.owner.belongsTo(turn) ||
      turn.toolPhase != StoredToolPhase.hooks ||
      !turn.scriptWritesAllowed ||
      turn.cancellation.isCancelled ||
      turn.terminalStorageAdopted) {
    throw _scriptError(
      TavernScriptErrorCode.busy,
      'write',
      'The captured preparation permit has expired.',
      generationId: turn.generationId,
    );
  }
}

T _toolPreparationSql<T>(
  TavernEngine engine,
  _ToolPreparationPermit? permit,
  T Function() action, {
  void Function()? onCommitted,
}) {
  _checkToolPreparationPermit(engine, permit);
  if (permit == null) return engine._store.transaction(action, onCommitted: onCommitted);
  try {
    return engine._store
        .preparationTransaction<T>(
          permit.owner,
          action: action,
          onCommitted: (committed) {
            permit.turn.toolPhase = committed.ownership.phase;
            onCommitted?.call();
          },
        )
        .value;
  } on StoredToolOwnershipException {
    throw _scriptError(
      TavernScriptErrorCode.revisionConflict,
      'write',
      'The captured ordinary turn preparation source changed.',
      generationId: permit.turn.generationId,
    );
  }
}

List<Map<String, Object?>> _ordinaryTurnTools(_Turn turn) => [
  ..._stateTurnTools(turn),
  if (turn.kind != _TurnKind.impersonate && turn.config.deepseek && !turn.effectiveThinking && turn.toolPolicy != null)
    ...ordinaryToolDefinitions(turn.toolPolicy!),
];

class _ToolUserAppend {
  _ToolUserAppend(this.message, this.source, this.node, this.sent, this.variables);
  final TavernMessage message;
  final TavernToolSourceToken source;
  final StoredNode node;
  final _ScriptSent? sent;
  final Map<String, Object?> variables;
}

_ToolUserAppend _appendOrdinaryToolUser(
  TavernEngine engine,
  _Turn turn, {
  required String? parentId,
  required String speaker,
  required String text,
}) {
  return engine._store
      .commitToolUserAppend<_ToolUserAppend>(
        turn.toolOwner!,
        parentId: parentId,
        speaker: speaker,
        text: text,
        state: turn.currentState,
        variables: _copy(turn.variables),
        prepare: (message, source) {
          if (turn.gameplayInitialized) {
            _ensureGameplayConfig(engine, turn.gameplay);
          }
          return _ToolUserAppend(
            message,
            source,
            engine._store.node(turn.chat.id, message.nodeId),
            engine._scripts.captureSent(turn.chat.id, message.nodeId),
            _runtimeCopy(turn.variables),
          );
        },
        onCommitted: (committed) {
          final prepared = committed.value;
          turn.toolPhase = committed.ownership.phase;
          turn.newUserId = prepared.message.nodeId;
          turn.newUserSource = prepared.source;
          turn.sent = prepared.sent;
          engine._liveVariables[turn.chat.id] = (leaf: prepared.message.nodeId, values: prepared.variables);
        },
      )
      .value;
}

class _ToolReplyBinding {
  _ToolReplyBinding(this.message, this.inspection, this.variables, this.firstSource, this.userSource)
    : text = StringBuffer(message.text),
      reasoning = StringBuffer(message.reasoning ?? '');
  final TavernMessage message;
  final TavernTurnInspection inspection;
  final Map<String, Object?> variables;
  final TavernToolSourceToken? firstSource, userSource;
  final StringBuffer text, reasoning;
}

void _bindOrdinaryToolReply(
  TavernEngine engine,
  _Turn turn, {
  required String? parentId,
  required String speaker,
  required StoredNode? target,
}) {
  final extra = turn.kind == _TurnKind.continueReply ? _copy(target!.extra) : _groupReplyExtra(turn);
  if (turn.kind == _TurnKind.continueReply) {
    extra['dshgo'] = {..._map(extra['dshgo']), 'tavernState': turn.currentState};
    if (turn.groupView != null) {
      final own = _map(extra['dshgo']);
      own['group'] = {
        ..._map(own['group']),
        'version': 1,
        'actorCharacterId': turn.actorId,
        'model': turn.config.model,
        'deepseek': turn.config.deepseek,
      };
      extra['dshgo'] = own;
    }
  }
  engine._store.bindToolCandidate<_ToolReplyBinding>(
    turn.toolOwner!,
    parentId: parentId,
    speaker: speaker,
    state: turn.currentState,
    variables: _copy(turn.variables),
    extra: extra,
    firstMessage: turn.firstMessageSource == null
        ? null
        : StoredToolBodyRewrite(source: turn.firstMessageSource!, text: turn.expandedFirstMessage!),
    prepare: (message, source) {
      if (turn.gameplayInitialized) {
        _ensureGameplayConfig(engine, turn.gameplay);
      }
      return _ToolReplyBinding(
        message,
        turn.inspection.copyWith(nodeId: message.nodeId),
        _runtimeCopy(turn.variables),
        turn.originalFirstMessage == null
            ? null
            : engine._store.sourceToken(turn.chat.id, turn.originalFirstMessage!.message.nodeId),
        turn.newUserId == null ? null : engine._store.sourceToken(turn.chat.id, turn.newUserId!),
      );
    },
    onCommitted: (committed) {
      final prepared = committed.value;
      turn.toolPhase = committed.ownership.phase;
      turn.firstMessageCommitted = prepared.firstSource != null;
      turn.committedFirstMessageSource = prepared.firstSource;
      turn.newUserSource = prepared.userSource;
      turn.reply = prepared.message;
      turn.lastCommitted = prepared.message;
      turn.text = prepared.text;
      turn.reasoning = prepared.reasoning;
      turn.usage = prepared.message.usage;
      engine._setInspection(turn, prepared.inspection);
      engine._liveVariables[turn.chat.id] = (leaf: prepared.message.nodeId, values: prepared.variables);
    },
  );
}

TavernToolException _toolError(
  String operation,
  TavernToolErrorCode code,
  String message, {
  bool? committed = false,
  String? fieldPath,
  String? chatId,
  String? executionId,
  String? proposalId,
  TavernMemoryDecisionRef? decisionRef,
}) => TavernToolException(
  code: code,
  operation: operation,
  message: message,
  committed: committed,
  fieldPath: fieldPath,
  chatId: chatId,
  executionId: executionId,
  proposalId: proposalId,
  decisionRef: decisionRef,
);

Future<T> _toolApi<T>(
  TavernEngine engine,
  String operation,
  _ToolApiAdoption adopted,
  FutureOr<T> Function() action, {
  String? chatId,
  bool allowBackupRead = false,
}) {
  Object classify(Object error) {
    if (error is TavernToolException) return error;
    if (error is _ToolArgumentFailure) {
      return _toolError(
        operation,
        TavernToolErrorCode.invalidArgument,
        error.message,
        fieldPath: error.fieldPath,
        chatId: chatId,
      );
    }
    if (error is TavernModelException && (error.kind == TavernFailure.busy || error.kind == TavernFailure.cancelled)) {
      return _toolError(
        operation,
        error.kind == TavernFailure.busy ? TavernToolErrorCode.busy : TavernToolErrorCode.cancelled,
        error.detail,
        committed: adopted.committed,
        chatId: chatId,
        executionId: adopted.executionId,
      );
    }
    if (error is FileSystemException ||
        error is SqliteException ||
        error is FormatException ||
        adopted.committed == true ||
        adopted.executionId != null) {
      return _toolError(
        operation,
        TavernToolErrorCode.storageFailure,
        'Tool storage or publication failed (${error.runtimeType}).',
        committed: adopted.committed,
        chatId: chatId,
        executionId: adopted.executionId,
        proposalId: adopted.proposalId,
        decisionRef: adopted.decisionRef,
      );
    }
    return error;
  }

  try {
    // An existing action is a read even while backup admission is closed.
    // A new manual action explicitly checks admission after its identity read.
    final Future<T> result;
    if (allowBackupRead) {
      engine._ensureOpen();
      result = engine._trackOperation(Future<T>.sync(action));
    } else {
      result = engine._operation(action);
    }
    return result.then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        Error.throwWithStackTrace(classify(error), stack);
      },
    );
  } catch (error, stack) {
    return Future<T>.error(classify(error), stack);
  }
}

void _toolIdentity(String value, String field) {
  if (value.isEmpty) throw _ToolArgumentFailure(field, 'An identity must not be empty.');
}

StoredChat _toolChat(TavernEngine engine, String chatId, String operation) {
  _toolIdentity(chatId, 'chatId');
  if (!engine._store.toolChatExists(chatId)) {
    throw _toolError(operation, TavernToolErrorCode.notFound, 'Chat does not exist.', chatId: chatId);
  }
  try {
    return engine._store.chat(chatId);
  } on TypeError {
    throw const FormatException('The stored chat has invalid field types.');
  }
}

Map<String, Object?> _toolGlobalSettings(TavernEngine engine, String operation) {
  final settings = engine._document['settings'];
  if (settings is! Map<String, Object?>) {
    throw _toolError(operation, TavernToolErrorCode.invalidArgument, 'invalid_stored_policy', fieldPath: 'settings');
  }
  return settings;
}

TavernToolPolicySnapshot _toolScope(TavernEngine engine, StoredChat? chat, {String operation = 'readToolPolicy'}) =>
    toolPolicySnapshot(globalSettings: _toolGlobalSettings(engine, operation), chatSettings: chat?.settings);

Future<TavernToolTurnSnapshot?> _readToolTurnApi(TavernEngine engine, String id) =>
    _toolApi(engine, 'readToolTurn', _ToolApiAdoption(), () {
      _toolIdentity(id, 'logicalTurnId');
      return engine._store.readToolTurn(id);
    });

Future<TavernToolReceipt?> _readToolReceiptApi(TavernEngine engine, String id) =>
    _toolApi(engine, 'readToolReceipt', _ToolApiAdoption(), () {
      _toolIdentity(id, 'executionId');
      return engine._store.readToolReceipt(id);
    });

Future<TavernToolPolicySnapshot> _readToolPolicyApi(TavernEngine engine, {String? chatId}) => _toolApi(
  engine,
  'readToolPolicy',
  _ToolApiAdoption(),
  () => _toolScope(engine, chatId == null ? null : _toolChat(engine, chatId, 'readToolPolicy')),
  chatId: chatId,
);

Future<TavernToolPolicyWriteResult> _setToolPolicyApi(
  TavernEngine engine,
  Map<String, Object?> patch, {
  String? chatId,
}) {
  final adopted = _ToolApiAdoption();
  return _toolApi(engine, 'setToolPolicy', adopted, () {
    final captured = captureToolPolicyPatch(patch, chatScope: chatId != null);
    if (chatId != null) {
      _toolChat(engine, chatId, 'setToolPolicy');
      return engine._store.updateToolPolicySettings<TavernToolPolicyWriteResult>(
        chatId,
        merge: (settings) => mergeToolPolicySettings(settings, captured, chatScope: true),
        prepare: (chat) => TavernToolPolicyWriteResult.fromJson({
          'snapshot': _toolScope(engine, chat, operation: 'setToolPolicy').toJson(),
          'committed': true,
          'diagnostics': <Object?>[],
        }),
        onCommitted: (_) {
          adopted.committed = true;
        },
      );
    }
    return engine._presetOperation(
      () => engine._settingsDocument((document) async {
        final current = document['settings'];
        if (current is! Map<String, Object?>) {
          throw _toolError(
            'setToolPolicy',
            TavernToolErrorCode.invalidArgument,
            'invalid_stored_policy',
            fieldPath: 'settings',
          );
        }
        final settings = mergeToolPolicySettings(current, captured, chatScope: false);
        final result = TavernToolPolicyWriteResult.fromJson({
          'snapshot': toolPolicySnapshot(globalSettings: settings).toJson(),
          'committed': true,
          'diagnostics': <Object?>[],
        });
        final next = <String, Object?>{...document, 'settings': settings};
        await engine._commitSettingsDocument(
          next,
          onCommitted: () {
            adopted.committed = true;
            engine._document['settings'] = settings;
          },
        );
        return result;
      }),
    );
  }, chatId: chatId);
}

Future<TavernMemoryDecisionReceipt> _resolveMemoryProposalApi(
  TavernEngine engine,
  String proposalId, {
  required String decisionId,
  required int expectedVersion,
  required TavernMemoryDecision decision,
  required TavernToolContextAnchor expectedContextAnchor,
}) {
  final adopted = _ToolApiAdoption()..proposalId = proposalId;
  return _toolApi(engine, 'resolveMemoryProposal', adopted, () {
    _toolIdentity(proposalId, 'proposalId');
    _toolIdentity(decisionId, 'decisionId');
    if (expectedVersion < 1) throw const _ToolArgumentFailure('expectedVersion', 'Version must be positive.');
    final anchor = TavernToolContextAnchor.fromJson(expectedContextAnchor.toJson());
    return engine._store.resolveMemoryProposal(
      proposalId,
      decisionId: decisionId,
      expectedVersion: expectedVersion,
      decision: decision,
      expectedContextAnchor: anchor,
      onCommitted: (receipt) {
        adopted.committed = true;
        adopted.decisionRef = receipt.record.decisionRef;
      },
    );
  }, chatId: expectedContextAnchor.chatId);
}

/// A queued callback is still owned by _operations after its cancelled turn
/// has released a chat barrier. It never consults a later owner in a map.
class _ToolPolicyCapture {
  _ToolPolicyCapture(this.cancellation);
  final ModelCancellation cancellation;
  late final Future<ToolCapturedPolicy> future;
  bool started = false;
  bool _closed = false;

  void check() {
    cancellation.check();
    if (_closed) throw const TavernModelException(TavernFailure.cancelled, 'policy_capture_closed');
  }

  Future<void> drainStarted() async {
    // An earlier preparation failure can finish the owner without classifying
    // its public lifecycle as cancelled. Close this original capture anyway.
    _closed = true;
    if (!started) return;
    try {
      await future;
    } catch (_) {
      /* The original caller owns this error. */
    }
  }
}

_ToolPolicyCapture _captureToolPolicy(
  TavernEngine engine,
  TavernToolPolicySnapshot scope,
  String hostId,
  String actorId,
  ModelCancellation cancellation,
) {
  final capture = _ToolPolicyCapture(cancellation);
  capture.future = engine._trackOperation(
    engine._libraryOperation(() async {
      capture.check();
      capture.started = true;
      // This marks dispatch into CharacterLibrary, which has its own local I/O
      // queue. No chat mutation is awaited by that queue's current callbacks.
      final host = await engine._library.readAuthority(
        hostId,
        (data) => captureToolCardPolicy(data, characterId: hostId),
      );
      capture.check();
      if (host == null) throw const TavernImportError('角色不存在。');
      final actor = actorId == hostId
          ? host
          : await engine._library.readAuthority(actorId, (data) => captureToolCardPolicy(data, characterId: actorId));
      capture.check();
      if (actor == null) throw const TavernImportError('角色不存在。');
      return captureToolPolicy(scope: scope, host: host, actor: actor);
    }),
  );
  return capture;
}

class _ToolArgumentFailure implements Exception {
  const _ToolArgumentFailure(this.fieldPath, this.message);
  final String fieldPath;
  final String message;
  Map<String, Object?> toJson() => {'code': 'invalid_argument', 'fieldPath': fieldPath, 'message': message};
}

class _RollParameters {
  const _RollParameters(this.dice, this.count, this.sides, this.modifier, this.label, this.target);
  final String dice;
  final int count, sides, modifier;
  final String? label;
  final int? target;
  Map<String, Object?> toJson() => {
    'dice': dice,
    'count': count,
    'sides': sides,
    'modifier': modifier,
    'label': label,
    'target': target,
  };
}

_RollParameters _parseRoll(Map<String, Object?> parameters) {
  if (!parameters.keys.every(const {'dice', 'label', 'target'}.contains)) {
    throw const _ToolArgumentFailure('', 'roll accepts only dice, label and target.');
  }
  final dice = parameters['dice'];
  if (dice is! String) throw const _ToolArgumentFailure('dice', 'dice must be a string.');
  final match = RegExp(r'^(?:([1-9][0-9]*))?d([1-9][0-9]*)(?:([+-])(0|[1-9][0-9]*))?$').firstMatch(dice);
  if (match == null || match.end != dice.length) {
    throw const _ToolArgumentFailure('dice', 'Expected [N]dM with an optional signed modifier.');
  }
  final count = match[1] == null ? 1 : int.tryParse(match[1]!);
  final sides = int.tryParse(match[2]!);
  final magnitude = match[4] == null ? 0 : int.tryParse(match[4]!);
  if (count == null ||
      count < 1 ||
      count > 100 ||
      sides == null ||
      sides < 2 ||
      sides > 1000 ||
      magnitude == null ||
      magnitude > 1000000) {
    throw const _ToolArgumentFailure('dice', 'Dice count, sides or modifier is outside its supported range.');
  }
  final label = parameters['label'];
  if (parameters.containsKey('label') && (label is! String || label.length > 256)) {
    throw const _ToolArgumentFailure('label', 'label must be a string of at most 256 UTF-16 units.');
  }
  final target = parameters['target'];
  int? normalizedTarget;
  if (parameters.containsKey('target')) {
    if (target is! num || !target.isFinite || target < -1000000 || target > 1000000 || target != target.truncate()) {
      throw const _ToolArgumentFailure('target', 'target must be an integer between -1000000 and 1000000.');
    }
    normalizedTarget = target.toInt();
  }
  return _RollParameters(
    dice,
    count,
    sides,
    match[3] == '-' ? -magnitude : magnitude,
    label as String?,
    normalizedTarget,
  );
}

({String text, List<String> keywords}) _parseRemember(Map<String, Object?> parameters) {
  if (parameters.length != 2 || !parameters.containsKey('text') || !parameters.containsKey('keywords')) {
    throw const _ToolArgumentFailure('', 'remember requires exactly text and keywords.');
  }
  final text = parameters['text'], keywords = parameters['keywords'];
  if (text is! String || text.isEmpty || text.length > 4096) {
    throw const _ToolArgumentFailure('text', 'text must contain 1 to 4096 UTF-16 units.');
  }
  if (keywords is! List<Object?> ||
      keywords.isEmpty ||
      keywords.length > 16 ||
      keywords.any((value) => value is! String || value.isEmpty || value.length > 128)) {
    throw const _ToolArgumentFailure(
      'keywords',
      'keywords must contain 1 to 16 nonempty strings of at most 128 units.',
    );
  }
  return (text: text, keywords: [for (final value in keywords) value! as String]);
}

class _ManualToolAction {
  _ManualToolAction(this.chatId, this.actionId, this.parameters, this.roll, this.anchor, this.scope);
  final String chatId, actionId;
  final Map<String, Object?> parameters;
  final _RollParameters roll;
  final TavernToolContextAnchor anchor;
  final TavernToolPolicySnapshot scope;
  final cancellation = ModelCancellation();
  final done = Completer<void>();
  final result = Completer<TavernToolReceipt>();
  _ToolPolicyCapture? policyCapture;
  TavernToolReceipt? receipt;
}

Future<TavernToolReceipt> _rollDiceApi(
  TavernEngine engine,
  String chatId, {
  required String actionId,
  required String dice,
  String? label,
  int? target,
  String? expectedNodeId,
}) {
  final adopted = _ToolApiAdoption();
  return _toolApi(
    engine,
    'rollDice',
    adopted,
    () {
      _toolIdentity(chatId, 'chatId');
      _toolIdentity(actionId, 'actionId');
      final parameters = <String, Object?>{
        'chatId': chatId,
        'actionId': actionId,
        'dice': dice,
        'label': label,
        'target': target,
        'expectedNodeId': expectedNodeId,
      };
      final old = engine._store.readManualToolReceipt(chatId, actionId: actionId, capturedParameters: parameters);
      if (old != null) return old;
      final pending = engine._manualTools[chatId];
      if (pending != null && pending.actionId == actionId) {
        if (!_stateJsonEqual(pending.parameters, parameters)) {
          throw _toolError(
            'rollDice',
            TavernToolErrorCode.actionConflict,
            'This action identity already has different parameters.',
            chatId: chatId,
          );
        }
        return pending.result.future;
      }
      if (expectedNodeId != null) _toolIdentity(expectedNodeId, 'expectedNodeId');
      final roll = _parseRoll({'dice': dice, 'label': ?label, 'target': ?target});
      engine._ensureAdmission();
      final chat = _toolChat(engine, chatId, 'rollDice');
      if (engine._mainBusy(chatId) ||
          engine._mutations.containsKey(chatId) ||
          engine._deletingCharacters.contains(chat.characterId)) {
        throw _toolError('rollDice', TavernToolErrorCode.busy, 'The chat is busy.', chatId: chatId);
      }
      final anchor = engine._store.contextAnchor(chatId);
      if (expectedNodeId != null && anchor.selectedLeaf?.nodeId != expectedNodeId) {
        throw _toolError('rollDice', TavernToolErrorCode.anchorChanged, 'The selected node changed.', chatId: chatId);
      }
      final action = _ManualToolAction(
        chatId,
        actionId,
        parameters,
        roll,
        anchor,
        _toolScope(engine, chat, operation: 'rollDice'),
      );
      engine._manualTools[chatId] = action;
      action.policyCapture = _captureToolPolicy(
        engine,
        action.scope,
        chat.characterId,
        chat.characterId,
        action.cancellation,
      );
      // The shared result follows the owner's cleanup as well as its outcome.
      action.result.complete(_runManualRoll(engine, action, adopted));
      return action.result.future;
    },
    chatId: chatId,
    allowBackupRead: true,
  );
}

Future<TavernToolReceipt> _runManualRoll(
  TavernEngine engine,
  _ManualToolAction action,
  _ToolApiAdoption adopted,
) async {
  var drawDispatched = false;
  var freshIntentAdopted = false;
  try {
    final policy = await action.cancellation.wait(action.policyCapture!.future);
    action.cancellation.check();
    void checkAdmission() {
      action.cancellation.check();
      if (!identical(engine._manualTools[action.chatId], action) ||
          engine._turns.containsKey(action.chatId) ||
          engine._groups.rounds.containsKey(action.chatId) ||
          engine._mutations.containsKey(action.chatId)) {
        throw _toolError('rollDice', TavernToolErrorCode.busy, 'The chat is busy.', chatId: action.chatId);
      }
    }

    var freshIntentChecked = false;
    engine._store.prepareManualToolReceipt(
      action.chatId,
      actionId: action.actionId,
      capturedParameters: action.parameters,
      validatedParameters: action.roll.toJson(),
      capturedPolicy: policy.toJson(),
      expectedContextAnchor: action.anchor,
      checkAdmission: () {
        checkAdmission();
        freshIntentChecked = true;
      },
      onCommitted: (receipt) {
        action.receipt = receipt;
        freshIntentAdopted = freshIntentChecked;
        adopted.executionId = receipt.executionId;
        adopted.committed = true;
      },
    );
    if (!freshIntentAdopted) {
      // The store's second identity check won a race during policy capture.
      // This call owns neither execution nor cancellation of that old intent.
      return action.receipt!;
    }
    drawDispatched = true;
    final receipt = _drawToolRoll(
      engine,
      action.receipt!,
      action.roll,
      beforeDraw: () {
        checkAdmission();
        if (!_stateJsonEqual(engine._store.contextAnchor(action.chatId).toJson(), action.anchor.toJson())) {
          throw _toolError(
            'rollDice',
            TavernToolErrorCode.anchorChanged,
            'The action anchor changed.',
            chatId: action.chatId,
          );
        }
      },
    );
    adopted.committed = true;
    return receipt;
  } catch (error, stack) {
    final receipt = action.receipt;
    if (receipt != null) {
      try {
        if (freshIntentAdopted && !drawDispatched && receipt.status == 'prepared') {
          try {
            engine._store.cancelToolReceiptBeforeExecution(
              receipt.executionId,
              reason: {'code': 'intent_publication_failure', 'type': '${error.runtimeType}'},
              onCommitted: (cancelled) {
                action.receipt = cancelled;
                adopted.committed = true;
              },
            );
          } catch (_) {
            /* Read the actual adopted result below. */
          }
        }
        final current = engine._store.readToolReceipt(receipt.executionId);
        if (current == null) throw const FormatException('A prepared tool receipt disappeared.');
        adopted.committed = true;
        return _toolReceiptDiagnostic(current, error);
      } catch (readError, readStack) {
        Error.throwWithStackTrace(
          _toolError(
            'rollDice',
            TavernToolErrorCode.storageFailure,
            'The action result could not be read (${readError.runtimeType}).',
            committed: adopted.committed,
            chatId: action.chatId,
            executionId: receipt.executionId,
          ),
          readStack,
        );
      }
    } else if (error is TavernImportError) {
      Error.throwWithStackTrace(
        _toolError(
          'rollDice',
          TavernToolErrorCode.notFound,
          'The host character is unavailable.',
          chatId: action.chatId,
        ),
        stack,
      );
    } else {
      rethrow;
    }
  } finally {
    // Waiting only after dispatch breaks library -> mutation -> manual ->
    // queued policy. _operations still owns every cancelled queued callback.
    await action.policyCapture?.drainStarted();
    if (identical(engine._manualTools[action.chatId], action)) engine._manualTools.remove(action.chatId);
    if (!action.done.isCompleted) action.done.complete();
  }
}

TavernToolReceipt _toolReceiptDiagnostic(TavernToolReceipt receipt, Object error) => TavernToolReceipt.fromJson({
  ...receipt.toJson(),
  'error': {
    ...?receipt.error,
    'code': 'publication_failure',
    'message': 'The original durable receipt was retained (${error.runtimeType}).',
  },
});

/// Intent is already durable. This function never awaits or retries RNG.
TavernToolReceipt _drawToolRoll(
  TavernEngine engine,
  TavernToolReceipt intent,
  _RollParameters roll, {
  required void Function() beforeDraw,
}) {
  TavernToolReceipt? adopted;
  var drawStarted = false;
  try {
    beforeDraw();
    drawStarted = true;
    final values = <int>[];
    var total = roll.modifier;
    for (var index = 0; index < roll.count; index++) {
      final value = engine._rollRandom(roll.sides);
      if (value < 0 || value >= roll.sides) throw StateError('The dice source returned an out-of-range integer.');
      values.add(value + 1);
      total += value + 1;
    }
    return engine._store.commitToolReceipt(
      intent.executionId,
      result: {
        ...roll.toJson(),
        'values': values,
        'total': total,
        'pass': roll.target == null ? null : total >= roll.target!,
      },
      onCommitted: (receipt) {
        adopted = receipt;
      },
    );
  } catch (error) {
    if (adopted != null) return _toolReceiptDiagnostic(adopted!, error);
    try {
      final reason = <String, Object?>{
        'code': drawStarted ? 'result_unconfirmed' : 'not_executed',
        'message': 'Dice execution stopped (${error.runtimeType}).',
      };
      return drawStarted
          ? engine._store.markToolReceiptUnresolved(
              intent.executionId,
              reason: reason,
              onCommitted: (receipt) {
                adopted = receipt;
              },
            )
          : engine._store.cancelToolReceiptBeforeExecution(
              intent.executionId,
              reason: reason,
              onCommitted: (receipt) {
                adopted = receipt;
              },
            );
    } catch (storageError) {
      if (adopted != null) return _toolReceiptDiagnostic(adopted!, storageError);
      final current = engine._store.readToolReceipt(intent.executionId);
      if (current == null) throw const FormatException('A tool intent disappeared.');
      return _toolReceiptDiagnostic(current, storageError);
    }
  }
}
