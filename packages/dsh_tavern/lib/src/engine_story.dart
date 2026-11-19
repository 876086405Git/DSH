part of 'engine.dart';

const _storyRuntimeKey = 'dshgoStoryRuntime';

story_core.StoryDefinition _storyDefinition(Map<String, Object?> data) {
  final own = _readMap(_readMap(data['extensions'])['dshgo']);
  final version = own.containsKey('v') ? own['v'] : 1;
  return story_core.StoryDefinition.parse(own['story'], version: version);
}

Map<String, Object?>? _storySnapshot(
  TavernEngine engine,
  StoredChat chat,
  Map<String, Object?> data,
  Map<String, Object?> settings,
) {
  final leaf = chat.currentLeafId;
  final saved = engine._stateAt(chat.id, leaf);
  final own = leaf == null ? <String, Object?>{} : _map(engine._store.node(chat.id, leaf).extra['dshgo']);
  final historical = _gameplayHistoricalConfig(engine, saved);
  if (historical.referenced && historical.config == null) {
    return {
      'unresolved': true,
      'executable': false,
      'valid': false,
      'automaticEnabled': false,
      'nodeId': leaf,
      'runtimeExists': saved.containsKey(_storyRuntimeKey),
      if (saved.containsKey(_storyRuntimeKey)) 'runtime': saved[_storyRuntimeKey],
      'changes': _stateRows(own['storyChanges']),
      'effects': _stateRows(own['storyEffects']),
      'issues': [...historical.issues, ..._stateRows(own['storyIssues'])],
    };
  }
  final definition = historical.config?.story ?? _storyDefinition(data);
  if (!definition.defined) {
    return null;
  }
  final snapshot = definition.inspect(
    runtimeExists: saved.containsKey(_storyRuntimeKey),
    runtime: saved[_storyRuntimeKey],
  );
  return {
    ...snapshot.toJson(),
    if (historical.config case final config?) 'effectiveConfigId': config.effectiveConfigId,
    'nodeId': leaf,
    'automaticEnabled': _map(settings['director'])['enabled'] == true,
    'changes': _stateRows(own['storyChanges']),
    'effects': _stateRows(own['storyEffects']),
    'issues': [...snapshot.issues, ..._stateRows(own['storyIssues'])],
  };
}

/// A helper retains its real input source. Phase is checked separately against
/// the next main turn's context: ordinary turns within one act can reuse a
/// result, while an intervening act completion or ending makes it obsolete.
Map<String, Object?> _storyDirectorPhase(
  story_core.StoryDefinition definition,
  story_core.StorySnapshot snapshot, {
  _GameplayRuntime? gameplay,
}) => {
  'version': 1,
  'definitionFingerprint': definition.fingerprint,
  if (gameplay != null) 'effectiveConfigId': gameplay.effectiveConfigId,
  'valid': snapshot.valid,
  'currentActId': snapshot.currentActId,
  'completed': snapshot.completed,
  'unlockedEndings': snapshot.unlockedEndings,
};

({Map<String, Object?>? progress, Map<String, Object?>? phase}) _storyDirectorContext(
  Map<String, Object?> data,
  Map<String, Object?> source, {
  _GameplayRuntime? gameplay,
}) {
  final definition = gameplay?.story ?? _storyDefinition(data);
  if (!definition.defined) {
    return (progress: null, phase: null);
  }
  final snapshot = definition.inspect(
    runtimeExists: source.containsKey('storyRuntime'),
    runtime: source['storyRuntime'],
  );
  return (
    progress: snapshot.toJson(),
    phase: definition.executable ? _storyDirectorPhase(definition, snapshot, gameplay: gameplay) : null,
  );
}

String? _storyDirectorEligibility(
  TavernEngine engine,
  StoredAgentRun stored,
  Map<String, Object?> data,
  String? contextNodeId, {
  _GameplayRuntime? gameplay,
}) {
  final definition = gameplay?.story ?? _storyDefinition(data);
  if (!definition.defined) {
    return null;
  }
  if (!definition.executable) {
    return 'director_story_unavailable';
  }
  final saved = contextNodeId == null ? <String, Object?>{} : engine._stateAt(stored.chatId, contextNodeId);
  return _storyDirectorEligibilityFromState(stored, data, saved, definition: definition, gameplay: gameplay);
}

String? _storyDirectorEligibilityFromState(
  StoredAgentRun stored,
  Map<String, Object?> data,
  Map<String, Object?> saved, {
  story_core.StoryDefinition? definition,
  _GameplayRuntime? gameplay,
}) {
  definition ??= gameplay?.story ?? _storyDefinition(data);
  if (!definition.defined) {
    return null;
  }
  if (!definition.executable) {
    return 'director_story_unavailable';
  }
  final snapshot = definition.inspect(
    runtimeExists: saved.containsKey(_storyRuntimeKey),
    runtime: saved[_storyRuntimeKey],
  );
  final current = _storyDirectorPhase(definition, snapshot, gameplay: gameplay);
  if (current['valid'] != true) {
    return 'director_story_unavailable';
  }
  // T18a runs did not capture a chapter phase. Keep them readable, without
  // inventing a phase or retrospectively authorizing story-dependent input.
  if (stored.result['storyPhase'] is! Map<String, Object?>) {
    return 'director_story_context_missing';
  }
  return _stateJsonEqual(current, stored.result['storyPhase']) ? null : 'director_story_changed';
}

class _StorySettlement {
  _StorySettlement({
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

/// The caller already owns the main turn. No awaits, mutations, model calls or
/// public state APIs belong here. This private candidate is installed only by
/// the existing terminal transaction; failed/partial storage uses the original.
_StorySettlement? _settleStoryTurn(TavernEngine engine, _Turn turn, Map<String, Object?> before) {
  if (turn.kind == _TurnKind.impersonate || (turn.finishReason != 'stop' && turn.finishReason != 'tool_calls')) {
    return null;
  }
  final data = turn.directorCard;
  if (data == null) {
    return null;
  }
  final definition = turn.gameplay?.story ?? _storyDefinition(data);
  if (!definition.defined) {
    return null;
  }
  final currentSettings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  if (_map(currentSettings['director'])['enabled'] != true) {
    return null;
  }
  final invocation = turn.storyInvocationId ??= _newStateId();
  final runId = '$invocation:story';
  final input = _StateInput(before);
  final stateDefinition = turn.gameplay?.state ?? _stateDefinition(data);
  final issues = <Map<String, Object?>>[
    ...input.issues,
    if (!turn.gameplayValueEligible) _directorIssue('story_gameplay_state_unavailable'),
  ];
  Object? conditionState;
  if (stateDefinition.hasSchema) {
    if (!stateDefinition.executable) {
      issues.addAll(stateDefinition.issues);
      issues.add(_directorIssue('story_state_definition_unavailable'));
    } else {
      issues.addAll(stateDefinition.validate(input.value, valueExists: input.valueExists));
      conditionState = input.value;
    }
  }
  // No schema means no DSH condition document. In particular, do not silently
  // reinterpret ST local variables as DSH state or derive defaults on a read.
  story_core.StoryResult? candidate;
  if (issues.isEmpty) {
    candidate = definition.settle(
      state: conditionState,
      runtimeExists: before.containsKey(_storyRuntimeKey),
      runtime: before[_storyRuntimeKey],
      invocationId: invocation,
      countTurn: true,
    );
    issues.addAll(candidate.issues);
  }
  final accepted = candidate != null && candidate.valid ? candidate : null;
  final next = _copy(before);
  if (accepted != null && accepted.runtimeExists) {
    next[_storyRuntimeKey] = accepted.runtime;
    _stampGameplayConfig(turn.gameplay, next);
  }
  final changes = accepted?.changes ?? <Map<String, Object?>>[];
  final effects = accepted == null
      ? <Map<String, Object?>>[]
      : [
          for (final effect in accepted.effects) {..._copy(effect), 'invocationId': invocation},
        ];
  final result = <String, Object?>{
    'version': 1,
    'invocationId': invocation,
    'definitionFingerprint': definition.fingerprint,
    'committed': accepted != null,
    'changed': accepted?.changed ?? false,
    'countTurn': accepted != null,
    'generationType': turn.generationType,
    'finishReason': turn.finishReason,
    'changes': changes,
    'effects': effects,
    'issues': issues,
    if (candidate != null) 'settlement': candidate.toJson(),
  };
  return _StorySettlement(
    state: next,
    runId: runId,
    result: result,
    trace: {
      'version': 1,
      'runId': runId,
      'definitionFingerprint': definition.fingerprint,
      'automaticEnabled': true,
      'committed': accepted != null,
      'changes': changes,
      'effects': effects,
      'issues': issues,
    },
    ownAudit: accepted == null
        ? null
        : {
            'storyInvocation': {'version': 1, 'id': invocation},
            'storyChanges': changes,
            'storyEffects': effects,
            'storyIssues': issues,
          },
  );
}

_StorySettlement? _failedStorySettlement(_Turn turn, TavernTurnInspection inspection) {
  final attempt = turn.storyAttempt;
  if (attempt == null || turn.storyRunWritten) {
    return null;
  }
  return _StorySettlement(
    state: turn.currentState,
    runId: attempt.runId,
    result: {
      ..._copy(attempt.result),
      'committed': false,
      'changed': false,
      'countTurn': false,
      'outcome': 'not-committed',
      'failure': inspection.failure?.name,
      'detail': inspection.detail,
      'changes': <Object?>[],
      'effects': <Object?>[],
    },
    trace: {
      ..._copy(attempt.trace),
      'committed': false,
      'outcome': 'not-committed',
      'changes': <Object?>[],
      'effects': <Object?>[],
    },
  );
}

void _writeStoryRun(ChatStore store, _Turn turn, _StorySettlement? settlement, String? nodeId) {
  if (settlement == null || turn.storyRunWritten) {
    return;
  }
  store.writeAgentRun(
    StoredAgentRun(
      id: settlement.runId,
      chatId: turn.chat.id,
      nodeId: nodeId,
      kind: 'story.rules',
      at: turn.at,
      result: settlement.result,
    ),
  );
}
