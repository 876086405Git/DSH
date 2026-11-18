part of 'engine.dart';

const _cardEventRuntimeKey = 'dshgoDirectorEventRuntime';
typedef _CardEventPrepared = ({_DirectorPrepared run, Map<String, state_core.StateEventTarget>? targets});

state_core.CardEventDefinition _cardEventDefinition(Map<String, Object?> data) {
  final own = _readMap(_readMap(data['extensions'])['dshgo']);
  return state_core.CardEventDefinition.parse(
    _readMap(own['director'])['eventRules'],
    version: own.containsKey('v') ? own['v'] : 1,
  );
}

/// This records the fixed card vocabulary seen by this helper. It does not
/// enable automatic execution: the main turn must still pass its current gate.
Map<String, Object?>? _cardEventCapability(
  Map<String, Object?> data,
  Map<String, Object?> settings, {
  _GameplayRuntime? gameplay,
}) {
  final definition = gameplay?.events ?? _cardEventDefinition(data);
  if (!definition.executable) {
    return null;
  }
  if (gameplay != null) {
    return _gameplayEventCapability(gameplay, settings);
  }
  final state = _stateDefinition(data);
  return {
    'version': 1,
    'mode': 'literal',
    'registryFingerprint': definition.fingerprint,
    'stateDefinitionFingerprint': state.hasSchema ? state.fingerprint : null,
    'handlerIds': definition.handlerIds,
    'automaticEnabledAtCapture': _map(settings['director'])['enabled'] == true,
  };
}

Map<String, Object?>? _cardEventSnapshot(
  TavernEngine engine,
  StoredChat chat,
  Map<String, Object?> data,
  Map<String, Object?> settings, {
  _GameplayRuntime? gameplay,
}) {
  final definition = gameplay?.events ?? _cardEventDefinition(data);
  final leaf = chat.currentLeafId;
  final saved = leaf == null ? <String, Object?>{} : engine._stateAt(chat.id, leaf);
  if (!definition.defined && !saved.containsKey(_cardEventRuntimeKey) && !_hasGameplayEventRuntime(saved, gameplay)) {
    return null;
  }
  final snapshot = _inspectGameplayEvents(definition, saved, gameplay);
  final own = leaf == null ? <String, Object?>{} : _map(engine._store.node(chat.id, leaf).extra['dshgo']);
  return {
    ...snapshot.toJson(),
    'nodeId': leaf,
    'automaticEnabled': _map(settings['director'])['enabled'] == true,
    'receipts': _stateRows(own['directorEventReceipts']),
    'effects': _stateRows(own['directorEventEffects']),
    'pendingConsumed': _strings(own['directorEventPendingConsumed']),
    if (gameplay != null) ...{
      'effectiveConfigId': gameplay.effectiveConfigId,
      'packPendingConsumed': _stateRows(own['directorEventPackPendingConsumed']),
      'packPendingPrompts': [
        if (snapshot.valid)
          for (final row in _gameplayPendingEventPrompts(snapshot.packRuntime, gameplay))
            {..._gameplayEventPromptRefJson(row.ref), 'prompt': row.prompt},
      ],
    },
    'issues': [...snapshot.issues, ..._stateRows(own['directorEventIssues'])],
  };
}

void _prepareCardEventTurn(TavernEngine engine, _Turn turn, Map<String, Object?> data) {
  final prepared = _prepareCardEventCapability(turn, data);
  if (prepared == null) {
    return;
  }
  final events = prepared.run.output!.events;
  for (var index = 0; index < events.length; index++) {
    final id = '${prepared.run.stored.id}:event:$index';
    final proposal = engine._store.agentRunById(turn.chat.id, id);
    _prepareCardEventProposal(turn, prepared.run.stored, index, events[index], proposal, targets: prepared.targets);
  }
}

void _prepareCardEventTurnFromFacts(_Turn turn, Map<String, Object?> data, Map<String, StoredAgentRun> proposals) {
  final prepared = _prepareCardEventCapability(turn, data);
  if (prepared == null) {
    return;
  }
  final events = prepared.run.output!.events;
  for (var index = 0; index < events.length; index++) {
    _prepareCardEventProposal(
      turn,
      prepared.run.stored,
      index,
      events[index],
      proposals['${prepared.run.stored.id}:event:$index'],
      targets: prepared.targets,
    );
  }
}

_CardEventPrepared? _prepareCardEventCapability(_Turn turn, Map<String, Object?> data) {
  if (turn.kind == _TurnKind.impersonate) {
    return null;
  }
  final gameplay = turn.gameplay;
  final definition = gameplay?.events ?? _cardEventDefinition(data);
  if (!definition.defined &&
      !turn.state.containsKey(_cardEventRuntimeKey) &&
      !_hasGameplayEventRuntime(turn.state, gameplay)) {
    return null;
  }
  turn.cardEventDefinition = definition;
  final snapshot = _inspectGameplayEvents(definition, turn.state, gameplay);
  turn.cardEventPreparationIssues.addAll(snapshot.issues);
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible || prepared.output == null) {
    return null;
  }
  final stored = prepared.stored;
  final capability = stored.result['eventCapability'];
  final state = gameplay?.state ?? _stateDefinition(data);
  final targets = gameplay == null ? null : _gameplayEventWireTargets(gameplay);
  if (capability is! Map<String, Object?> ||
      !definition.executable ||
      (gameplay == null
          ? capability['version'] != 1 ||
                capability['mode'] != 'literal' ||
                capability['registryFingerprint'] != definition.fingerprint ||
                !capability.containsKey('stateDefinitionFingerprint') ||
                capability['stateDefinitionFingerprint'] != (state.hasSchema ? state.fingerprint : null) ||
                !_stateJsonEqual(capability['handlerIds'], definition.handlerIds)
          : !_gameplayEventCapabilityMatches(capability, gameplay, targets!))) {
    turn.cardEventPreparationIssues.add(_directorIssue('director_event_capability_unavailable', id: stored.id));
    return null;
  }
  if (gameplay == null) {
    turn.cardEventAuthorizedHandlers.addAll(definition.handlerIds);
  } else {
    turn.cardEventAuthorizedHandlerRefs.addAll(definition.handlerRefs);
  }
  turn.cardEventSource = {
    'runId': stored.id,
    'sourceKind': stored.result['sourceKind'],
    'sourceNodeId': stored.result['sourceNodeId'],
    'sourceFingerprint': stored.result['sourceFingerprint'],
    'capability': _copy(capability),
  };
  return (run: prepared, targets: targets);
}

void _prepareCardEventProposal(
  _Turn turn,
  StoredAgentRun stored,
  int index,
  Map<String, Object?> event,
  StoredAgentRun? proposal, {
  Map<String, state_core.StateEventTarget>? targets,
}) {
  final id = '${stored.id}:event:$index';
  final raw = proposal?.result;
  final decoded = proposal == null ? null : _directorEvent(proposal);
  // The original durable proposal is authority. Never synthesize it from
  // the output alone or substitute a newer run found during asynchronous IO.
  if (proposal == null ||
      proposal.kind != 'director.event' ||
      decoded == null ||
      !decoded.available ||
      raw == null ||
      raw['outputIndex'] != index ||
      decoded.runId != stored.id ||
      decoded.sourceKind != stored.result['sourceKind'] ||
      decoded.sourceNodeId != stored.result['sourceNodeId'] ||
      decoded.sourceFingerprint != stored.result['sourceFingerprint'] ||
      raw['createdAt'] != stored.result['finishedAt'] ||
      decoded.name != event['name'] ||
      decoded.data != event['data']) {
    turn.cardEventPreparationIssues.add(_directorIssue('director_event_proposal_unavailable', id: id));
    return;
  }
  var target = (source: const state_core.StateExecutionSource.legacy(), name: decoded.name!);
  if (targets != null) {
    final expected = _gameplayPersistedEventTarget(
      stored.result['eventCapability']! as Map<String, Object?>,
      decoded.name!,
    );
    if (!_stateJsonEqual(raw['eventTarget'], expected)) {
      turn.cardEventPreparationIssues.add(_directorIssue('director_event_proposal_unavailable', id: id));
      return;
    }
    target = targets[decoded.name] ?? target;
  }
  turn.cardEventProposals.add(
    state_core.CardEventProposal(
      eventId: id,
      runId: stored.id,
      source: target.source,
      name: target.name,
      data: decoded.data!,
    ),
  );
}

List<PromptInjection> _cardEventTurnInjections(_Turn turn) {
  final definition = turn.cardEventDefinition;
  if (definition == null || _map(turn.settings['director'])['enabled'] != true || turn.kind == _TurnKind.impersonate) {
    return [];
  }
  final snapshot = _inspectGameplayEvents(definition, turn.state, turn.gameplay);
  // Validate the entire ledger, not just plausible-looking prompt rows.
  if (!snapshot.valid) {
    return [];
  }
  final injections = <PromptInjection>[];
  for (final prompt in snapshot.pendingPrompts) {
    final id = prompt['id']! as String;
    final sourceId = 'dshgo.director.event.prompt:$id';
    turn.cardEventOfferedPrompts[sourceId] = id;
    injections.add(
      PromptInjection(
        fragment: PromptFragment(
          prompt['text']! as String,
          PromptSource('directorEventPrompt', sourceId, label: '事件提示'),
          trimOnOverflow: true,
          expandMacros: false,
        ),
        depth: 1,
        order: 202,
      ),
    );
  }
  for (final row in _gameplayPendingEventPrompts(snapshot.packRuntime, turn.gameplay)) {
    final sourceId = 'dshgo.gameplay.event.prompt:${_directorHash(_gameplayEventPromptRefJson(row.ref))}';
    turn.cardEventOfferedPackPrompts[sourceId] = row.ref;
    injections.add(
      PromptInjection(
        fragment: PromptFragment(
          row.prompt['text']! as String,
          PromptSource('directorEventPrompt', sourceId, label: '事件提示'),
          trimOnOverflow: true,
          expandMacros: false,
        ),
        depth: 1,
        order: 202,
      ),
    );
  }
  return injections;
}

void _captureCardEventAssembly(_Turn turn, PromptAssembly assembly) {
  if (turn.cardEventOfferedPrompts.isEmpty && turn.cardEventOfferedPackPrompts.isEmpty) {
    return;
  }
  for (final segment in assembly.afterPostProcessing) {
    final content = segment.message['content'];
    if (content is! String || content.trim().isEmpty) {
      continue;
    }
    for (final source in segment.sources) {
      final ledgerId = turn.cardEventOfferedPrompts[source.id];
      if (source.kind == 'directorEventPrompt' && ledgerId != null) {
        turn.cardEventSentPrompts.add(ledgerId);
      }
      final packRef = turn.cardEventOfferedPackPrompts[source.id];
      if (source.kind == 'directorEventPrompt' && packRef != null) {
        turn.cardEventSentPackPrompts.add(packRef);
      }
    }
  }
}

state_core.CardEventInvocation? _cardEventInvocation(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> before, {
  required bool normal,
  required bool sharedSession,
}) {
  final definition = turn.cardEventDefinition;
  if (definition == null) {
    return null;
  }
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  turn.cardEventTerminalEnabled = _map(settings['director'])['enabled'] == true;
  final secretReason = _secretDirectorTurnReason(engine, turn, before);
  if (secretReason != null) {
    turn.cardEventPreparationIssues.add(_directorIssue(secretReason));
  }
  final invocation = turn.cardEventInvocationId ??= turn.stateInvocationId ?? _newStateId();
  if (turn.gameplay != null) {
    return state_core.CardEventInvocation.composed(
      definition: definition,
      invocationId: invocation,
      capabilityFingerprint: definition.fingerprint,
      authorizedHandlers: normal && turn.cardEventTerminalEnabled && secretReason == null && turn.gameplayValueEligible
          ? turn.cardEventAuthorizedHandlerRefs
          : const [],
      proposals: turn.cardEventProposals,
      runtimeExists: before.containsKey(_cardEventRuntimeKey),
      runtime: before[_cardEventRuntimeKey],
      packRuntimeExists: before.containsKey(_gameplayEventRuntimeKey),
      packRuntime: before[_gameplayEventRuntimeKey],
      stateActionAllowed:
          normal &&
          turn.cardEventTerminalEnabled &&
          sharedSession &&
          turn.gameplayValueEligible &&
          settings['stateEnabled'] != false,
    );
  }
  return state_core.CardEventInvocation(
    definition: definition,
    invocationId: invocation,
    capabilityFingerprint: definition.fingerprint,
    authorizedHandlerIds: normal && turn.cardEventTerminalEnabled && secretReason == null && turn.gameplayValueEligible
        ? turn.cardEventAuthorizedHandlers
        : const [],
    proposals: turn.cardEventProposals,
    runtimeExists: before.containsKey(_cardEventRuntimeKey),
    runtime: before[_cardEventRuntimeKey],
    stateActionAllowed:
        normal &&
        turn.cardEventTerminalEnabled &&
        sharedSession &&
        turn.gameplayValueEligible &&
        settings['stateEnabled'] != false,
  );
}

class _CardEventSettlement {
  _CardEventSettlement({
    required this.state,
    required this.runId,
    required this.result,
    required this.trace,
    this.ownAudit,
  });
  final Map<String, Object?> state;
  final String runId;
  final Map<String, Object?> result;
  final Map<String, Object?> trace;
  final Map<String, Object?>? ownAudit;
}

/// New ledger changes and literal effects require final shared-state validity.
/// Confirmation of an already-sent prompt is independent of a newly revoked
/// dispatch gate, but still requires a normal terminal and a valid old ledger.
_CardEventSettlement? _finishCardEventTurn(
  _Turn turn,
  Map<String, Object?> before,
  Map<String, Object?> stateAfter,
  state_core.CardEventResult? candidate,
  List<Map<String, Object?>> effects, {
  required bool normal,
  required bool sharedStateAccepted,
  bool sharedSession = false,
  List<Map<String, Object?>> conditionIssues = const [],
}) {
  final definition = turn.cardEventDefinition;
  if (definition == null) {
    return null;
  }
  final invocation = turn.cardEventInvocationId ??= turn.stateInvocationId ?? _newStateId();
  final accepted = normal && sharedStateAccepted && candidate != null && candidate.valid ? candidate : null;
  final snapshot = _inspectGameplayEvents(definition, before, turn.gameplay);
  final consumed = normal && snapshot.valid
      ? {
          for (final prompt in snapshot.pendingPrompts)
            if (turn.cardEventSentPrompts.contains(prompt['id'])) prompt['id']! as String,
        }
      : <String>{};
  final packConsumed = normal && snapshot.valid
      ? {
          for (final row in _gameplayPendingEventPrompts(snapshot.packRuntime, turn.gameplay))
            if (turn.cardEventSentPackPrompts.contains(row.ref)) row.ref,
        }
      : <_GameplayEventPromptRef>{};
  final eventEffects = accepted == null
      ? <Map<String, Object?>>[]
      : effects.where((effect) => effect['source'] == 'directorEvent').toList();
  final next = _copy(stateAfter);
  if (turn.gameplay != null && accepted != null && accepted.packRuntimeExists) {
    next[_gameplayEventRuntimeKey] = accepted.packRuntime;
  }
  final acceptedRuntime = accepted != null && accepted.runtimeExists ? accepted.runtime : null;
  Map<String, Object?>? runtime = acceptedRuntime is Map<String, Object?>
      ? _copy(acceptedRuntime)
      : snapshot.valid && before[_cardEventRuntimeKey] is Map<String, Object?>
      ? _copy(before[_cardEventRuntimeKey]! as Map<String, Object?>)
      : null;
  final prompts = eventEffects
      .where((effect) => effect['type'] == 'prompt' && _gameplayEventEffectSource(effect) == null)
      .toList();
  if (consumed.isNotEmpty || prompts.isNotEmpty) {
    runtime ??= {'version': 1};
    runtime['pendingPrompts'] = [
      for (final prompt in _stateRows(runtime['pendingPrompts']))
        if (!consumed.contains(prompt['id'])) prompt,
      for (final prompt in prompts)
        {
          'id': prompt['effectId'],
          'text': prompt['text'],
          'invocationId': prompt['invocationId'],
          'source': 'directorEvent',
          'eventId': prompt['eventId'],
          'runId': prompt['runId'],
          'handlerId': prompt['handlerId'],
          'actionIndex': prompt['actionIndex'],
        },
    ];
  }
  final legacyChanged =
      runtime != null &&
      (!before.containsKey(_cardEventRuntimeKey) || !_stateJsonEqual(before[_cardEventRuntimeKey], runtime));
  if (legacyChanged) {
    next[_cardEventRuntimeKey] = runtime;
  }
  final packPromptChanged = _settleGameplayEventPrompts(next, packConsumed, eventEffects);
  final changed = legacyChanged || packPromptChanged || (turn.gameplay != null && accepted?.changed == true);
  final committed = normal && (changed || eventEffects.isNotEmpty);
  if (accepted != null && committed && !sharedSession && turn.gameplayValueEligible) {
    _stampGameplayConfig(turn.gameplay, next);
  }
  final receipts = candidate?.receipts ?? <Map<String, Object?>>[];
  final issues = <Map<String, Object?>>[
    ...turn.cardEventPreparationIssues,
    ...conditionIssues,
    if (candidate != null) ...candidate.issues,
    if (!sharedStateAccepted) _directorIssue('director_event_state_not_committed'),
    if (!normal) _directorIssue('director_event_terminal_not_normal'),
  ];
  final runId = '$invocation:events';
  final result = <String, Object?>{
    'version': 1, 'invocationId': invocation, 'registryFingerprint': definition.fingerprint,
    'committed': committed, 'changed': changed, 'handlerCandidateAccepted': accepted != null,
    'automaticEnabled': turn.cardEventTerminalEnabled, 'generationType': turn.generationType,
    'finishReason': turn.finishReason, if (turn.cardEventSource != null) 'source': _copy(turn.cardEventSource!),
    'receipts': receipts, 'effects': eventEffects, 'pendingConsumed': consumed.toList(),
    if (turn.gameplay != null) ...{
      'effectiveConfigId': turn.gameplay!.effectiveConfigId,
      'packPendingConsumed': [for (final ref in packConsumed) _gameplayEventPromptRefJson(ref)],
    },
    'issues': issues,
    // The portable node owns the historical ledger. Audit only this batch,
    // rather than duplicating its growing runtime in every run and inspection.
    if (candidate != null)
      'settlement': {
        'valid': candidate.valid,
        'runtimeExists': candidate.runtimeExists,
        'initialized': candidate.initialized,
        'changed': candidate.changed,
        if (turn.gameplay != null) 'packRuntimeExists': candidate.packRuntimeExists,
      },
  };
  return _CardEventSettlement(
    state: next,
    runId: runId,
    result: result,
    trace: {
      ..._copy(result),
      'runId': runId,
      'pendingOffered': turn.cardEventOfferedPrompts.values.toList(),
      'pendingIncluded': turn.cardEventSentPrompts.toList(),
      if (turn.gameplay != null) ...{
        'packPendingOffered': [
          for (final ref in turn.cardEventOfferedPackPrompts.values) _gameplayEventPromptRefJson(ref),
        ],
        'packPendingIncluded': [for (final ref in turn.cardEventSentPackPrompts) _gameplayEventPromptRefJson(ref)],
      },
    },
    ownAudit: committed
        ? {
            'directorEventInvocation': {'version': 1, 'id': invocation},
            'directorEventReceipts': receipts,
            'directorEventEffects': eventEffects,
            'directorEventPendingConsumed': consumed.toList(),
            if (turn.gameplay != null)
              'directorEventPackPendingConsumed': [for (final ref in packConsumed) _gameplayEventPromptRefJson(ref)],
            'directorEventIssues': issues,
          }
        : null,
  );
}

_CardEventSettlement? _failedCardEventSettlement(
  _Turn turn,
  _CardEventSettlement? attempt,
  TavernTurnInspection inspection,
) {
  if (attempt == null) {
    return null;
  }
  final failed = <String, Object?>{
    ..._copy(attempt.result),
    'committed': false,
    'changed': false,
    'handlerCandidateAccepted': false,
    'outcome': 'not-committed',
    'failure': inspection.failure?.name,
    'detail': inspection.detail,
    'attemptedReceipts': attempt.result['receipts'],
    'attemptedEffects': attempt.result['effects'],
    'receipts': <Object?>[],
    'effects': <Object?>[],
    'pendingConsumed': <Object?>[],
    if (attempt.result.containsKey('packPendingConsumed')) 'packPendingConsumed': <Object?>[],
  };
  return _CardEventSettlement(
    state: turn.currentState,
    runId: attempt.runId,
    result: failed,
    trace: {..._copy(attempt.trace), ...failed},
  );
}
