part of 'engine.dart';

const _secretRuntimeKey = 'dshgoSecretRuntime';

bool _secretsEnabled(Map<String, Object?> settings) =>
    settings['stateEnabled'] != false &&
    _map(settings['director'])['enabled'] == true &&
    _map(settings['director'])['secretsEnabled'] == true;

state_core.SecretDefinition _secretDefinition(Map<String, Object?> data) {
  final own = _readMap(_readMap(data['extensions'])['dshgo']);
  return state_core.SecretDefinition.parse(
    _readMap(own['director'])['secretSlots'],
    state: _stateDefinition(data),
    version: own.containsKey('v') ? own['v'] : 1,
  );
}

Object? _secretCopy(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _gameplayDirectorCard(Map<String, Object?> data, _GameplayRuntime? gameplay) {
  final card = _directorCard(data);
  if (gameplay == null) {
    return card;
  }
  final effective = gameplay.effectiveDefinitions['effective']! as Map<String, Object?>;
  for (final field in const [('state', 'stateDefinition'), ('story', 'story'), ('director', 'director')]) {
    if (effective.containsKey(field.$1)) {
      card[field.$2] = _secretCopy(effective[field.$1]);
    } else {
      card.remove(field.$2);
    }
  }
  return card;
}

Map<String, Object?> _currentSecretPersona(TavernEngine engine, StoredChat chat, Map<String, Object?> settings) {
  final selection = engine._personas.resolve(personaId: chat.personaId);
  return _directorPersona(selection, _personaSettings(settings, selection));
}

/// The portable ledger is evidence to check, never an instruction to execute.
/// Malformed or future data remains on disk and closes automatic carriers.
class _SecretLedger {
  _SecretLedger(Map<String, Object?> saved)
    : exists = saved.containsKey(_secretRuntimeKey),
      raw = _secretCopy(saved[_secretRuntimeKey]) {
    if (!exists) return;
    final object = raw;
    if (object is! Map<String, Object?> || object['version'] != 1 || object['bindings'] is! List<Object?>) {
      valid = false;
    } else {
      final keys = <String>{}, ids = <String>{};
      for (final item in object['bindings']! as List<Object?>) {
        if (item is! Map<String, Object?>) {
          valid = false;
          continue;
        }
        final path = item['path'];
        if (path is String) {
          try {
            if (_statePointerTokens(path).isNotEmpty) {
              paths.add(path);
            } else {
              valid = false;
            }
          } on FormatException {
            valid = false;
          }
        } else {
          valid = false;
        }
        const strings = [
          'bindingId',
          'bindingKey',
          'slotId',
          'entityId',
          'path',
          'definitionFingerprint',
          'valueHash',
          'sourceNodeId',
          'inputSourceFingerprint',
          'boundNodeId',
          'beforeStateFingerprint',
          'afterStateFingerprint',
          'generationInvocationId',
          'bindReceiptId',
          'proposalRunId',
          'characterId',
        ];
        if (strings.any((key) => item[key] is! String || (item[key]! as String).isEmpty) ||
            item['valueType'] != 'string' ||
            item['policyVersion'] != 1 ||
            item['proposalIndex'] is! int ||
            (item['proposalIndex']! as int) < 0) {
          valid = false;
          continue;
        }
        final source = item.containsKey('executionSource')
            ? _savedGameplayExecutionSource(item['executionSource'])
            : const state_core.StateExecutionSource.legacy();
        final key = item['bindingKey']! as String;
        if (source == null ||
            key !=
                state_core.secretBindingKey(item['slotId']! as String, item['entityId']! as String, source: source) ||
            !keys.add(key) ||
            !ids.add(item['bindingId']! as String)) {
          valid = false;
          continue;
        }
        bindings.add(_copy(item));
      }
    }
    if (!valid) issues.add(_directorIssue('secret_ledger_unavailable'));
  }
  final bool exists;
  final Object? raw;
  bool valid = true;
  final bindings = <Map<String, Object?>>[];
  final paths = <String>{};
  final issues = <Map<String, Object?>>[];
  List<String> get boundKeys => [for (final row in bindings) row['bindingKey']! as String];

  Map<String, Object?> adding(List<Map<String, Object?>> rows) {
    if (!valid) throw const FormatException('Cannot extend an unavailable secret ledger.');
    return {
      ...?(raw as Map<String, Object?>?),
      'version': 1,
      'bindings': [...bindings, ...rows],
    };
  }
}

class _SecretProtection {
  _SecretProtection(Map<String, Object?> data, Map<String, Object?> saved, {this.gameplay})
    : definition = gameplay?.secrets ?? _secretDefinition(data),
      ledger = _SecretLedger(saved) {
    paths.addAll(definition.protectedPaths);
    paths.addAll(ledger.paths);
    unknown = !ledger.valid || definition.issues.any((issue) => issue['code'] == 'secret_protection_unknown');
  }
  final _GameplayRuntime? gameplay;
  final state_core.SecretDefinition definition;
  final _SecretLedger ledger;
  final paths = <String>{};
  late final bool unknown;
  bool get active => definition.defined || ledger.exists;
  List<Map<String, Object?>> get issues => [...definition.issues, ...ledger.issues];

  Object? masked(Object? value) {
    if (unknown) return null;
    final next = _secretCopy(value);
    for (final path in paths) {
      final tokens = _statePointerTokens(path);
      if (tokens.isEmpty) return null;
      Object? parent = next;
      for (final token in tokens.take(tokens.length - 1)) {
        if (parent is List<Object?>) return null;
        parent = parent is Map<String, Object?> ? parent[token] : null;
      }
      if (parent is List<Object?>) return null;
      if (parent is Map<String, Object?>) parent.remove(tokens.last);
    }
    return next;
  }

  bool allowsTool(state_core.StateDefinition state, _StateInput input) {
    if (unknown) return false;
    final hidden = state.project(input.value, valueExists: input.valueExists).hiddenPaths;
    return paths.every(
      (path) => hidden.any((parent) => parent.isEmpty || path == parent || path.startsWith('$parent/')),
    );
  }
}

List<state_core.SecretRelease> _secretReleases(
  TavernEngine engine,
  String chatId,
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> saved,
  _SecretProtection protection,
) {
  final input = _secretReleaseInput(data, settings, saved, protection);
  if (input == null) {
    return [];
  }
  final result = <state_core.SecretRelease>[];
  for (final binding in protection.ledger.bindings) {
    StoredAgentRun? proof;
    final release = _secretReleaseForBinding(
      characterId,
      input,
      protection,
      binding,
      resolveBoundDefinition: () {
        proof ??= engine._store.agentRunById(chatId, binding['bindReceiptId']! as String);
        if (!_secretProofMatches(proof, binding) || proof?.result['proposalRunId'] != binding['proposalRunId']) {
          return null;
        }
        final proposal = engine._store.agentRunById(chatId, binding['proposalRunId']! as String);
        final configId = _secretBindingConfigId(binding, proposal);
        if (configId == null) {
          return null;
        }
        return _gameplayHistoricalConfig(engine, {'dshgoPackDefinitionConfigId': configId}).config?.secrets;
      },
    );
    if (release == null) {
      continue;
    }
    // The unchanged-definition path still reads its proof after the value gate.
    // Historical resolution has already authenticated the same real bind row.
    // The native verifier never accepts a preview proof reader.
    proof ??= engine._store.agentRunById(chatId, binding['bindReceiptId']! as String);
    if (_secretProofMatches(proof, binding)) {
      result.add(release);
    }
  }
  return result;
}

_StateInput? _secretReleaseInput(
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> saved,
  _SecretProtection protection,
) {
  if (!_secretsEnabled(settings) ||
      protection.unknown ||
      !protection.definition.executable ||
      (protection.gameplay?.story ?? _storyDefinition(data)).defined) {
    return null;
  }
  final input = _StateInput(saved);
  return input.writable ? input : null;
}

state_core.SecretRelease? _secretReleaseForBinding(
  String characterId,
  _StateInput input,
  _SecretProtection protection,
  Map<String, Object?> binding, {
  state_core.SecretDefinition? Function()? resolveBoundDefinition,
}) {
  if (binding['characterId'] != characterId) {
    return null;
  }
  var definition = protection.definition;
  if (binding['definitionFingerprint'] != definition.fingerprint) {
    final bound = resolveBoundDefinition?.call();
    if (bound == null || binding['definitionFingerprint'] != bound.fingerprint) {
      return null;
    }
    definition = bound;
  }
  final release = definition.releaseFor(
    slotId: binding['slotId']! as String,
    entityId: binding['entityId']! as String,
    characterId: characterId,
    value: input.value,
    valueExists: input.valueExists,
  );
  return release == null || release.path != binding['path'] || release.valueHash != binding['valueHash']
      ? null
      : release;
}

/// Callers first authenticate the same-chat bind receipt. Only its original
/// proposal can name the immutable configuration that authorized this binding.
String? _secretBindingConfigId(Map<String, Object?> binding, StoredAgentRun? proposal) {
  if (proposal == null ||
      proposal.id != binding['proposalRunId'] ||
      _secretProposalShapeReason(proposal, binding['characterId']! as String) != null ||
      proposal.result['sourceFingerprint'] != binding['inputSourceFingerprint'] ||
      _map(proposal.result['capability'])['definitionFingerprint'] != binding['definitionFingerprint']) {
    return null;
  }
  final id = proposal.result['effectiveConfigId'];
  return id is String && id.isNotEmpty ? id : null;
}

bool _secretProofMatches(StoredAgentRun? proof, Map<String, Object?> binding) =>
    proof != null &&
    proof.kind == 'director.secret_bind' &&
    proof.result['version'] == 1 &&
    proof.result['committed'] == true &&
    _stateRows(proof.result['bindings']).any((row) => _stateJsonEqual(row, binding));

/// What an ordinary helper actually knows is distinct from its full source
/// authentication. In particular old notes cannot survive a narrower release.
class _SecretInput {
  _SecretInput({
    required this.card,
    required this.state,
    required this.releases,
    required this.policy,
    required this.issues,
  });
  final Map<String, Object?> card;
  final Map<String, Object?> state;
  final List<state_core.SecretRelease> releases;
  final Map<String, Object?>? policy;
  final List<Map<String, Object?>> issues;
}

_SecretInput _ordinarySecretInput(
  TavernEngine engine,
  String chatId,
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> source, {
  Map<String, Object?>? authorizationSource,
  _GameplayRuntime? gameplay,
}) {
  final prepared = _prepareSecretInput(data, source, authorizationSource: authorizationSource, gameplay: gameplay);
  if (!prepared.active) {
    return _finishSecretInput(prepared, const {}, const []);
  }
  final currentReleases = prepared.unavailable
      ? <state_core.SecretRelease>[]
      : _secretReleases(
          engine,
          chatId,
          characterId,
          data,
          settings,
          prepared.authorizationSaved,
          prepared.currentProtection,
        );
  final currentKnowledge = {for (final release in currentReleases) _directorHash(_secretKnowledge(release))};
  final releases = prepared.unavailable
      ? <state_core.SecretRelease>[]
      : _secretReleases(engine, chatId, characterId, data, settings, prepared.saved, prepared.protection);
  return _finishSecretInput(prepared, currentKnowledge, releases);
}

typedef _SecretInputPreparation = ({
  Map<String, Object?> state,
  Map<String, Object?> card,
  Map<String, Object?> saved,
  Map<String, Object?> authorizationSaved,
  _SecretProtection protection,
  _SecretProtection currentProtection,
  bool active,
  bool unavailable,
});

_SecretInputPreparation _prepareSecretInput(
  Map<String, Object?> data,
  Map<String, Object?> source, {
  Map<String, Object?>? authorizationSource,
  _GameplayRuntime? gameplay,
}) {
  final state = _copy(_map(source['state']));
  final saved = <String, Object?>{
    'messageVariables': {if (state['valueExists'] == true) 'dshgo': state['value']},
    if (source.containsKey('secretRuntime')) _secretRuntimeKey: source['secretRuntime'],
  };
  final protection = _SecretProtection(data, saved, gameplay: gameplay);
  final authorization = authorizationSource ?? source;
  final authorizationState = _map(authorization['state']);
  final authorizationSaved = <String, Object?>{
    'messageVariables': {if (authorizationState['valueExists'] == true) 'dshgo': authorizationState['value']},
    if (authorization.containsKey('secretRuntime')) _secretRuntimeKey: authorization['secretRuntime'],
  };
  final currentProtection = _SecretProtection(data, authorizationSaved, gameplay: gameplay);
  protection.paths.addAll(currentProtection.paths);
  final card = _gameplayDirectorCard(data, gameplay);
  if (!protection.active && !currentProtection.active) {
    return (
      state: state,
      card: card,
      saved: saved,
      authorizationSaved: authorizationSaved,
      protection: protection,
      currentProtection: currentProtection,
      active: false,
      unavailable: false,
    );
  }
  final unavailable =
      protection.unknown ||
      currentProtection.unknown ||
      _stateRows(state['issues']).isNotEmpty ||
      _stateRows(authorizationState['issues']).isNotEmpty;
  card.remove('stateDefinition');
  if (card['director'] is Map<String, Object?>) {
    final director = _copy(card['director']! as Map<String, Object?>)..remove('secretSlots');
    card['director'] = director;
  }
  if (unavailable) {
    state.remove('value');
    state['valueExists'] = false;
  } else if (state['valueExists'] == true) {
    state['value'] = protection.masked(state['value']);
  }
  return (
    state: state,
    card: card,
    saved: saved,
    authorizationSaved: authorizationSaved,
    protection: protection,
    currentProtection: currentProtection,
    active: true,
    unavailable: unavailable,
  );
}

_SecretInput _finishSecretInput(
  _SecretInputPreparation prepared,
  Set<String> currentKnowledge,
  List<state_core.SecretRelease> sourceReleases,
) {
  if (!prepared.active) {
    return _SecretInput(card: prepared.card, state: prepared.state, releases: [], policy: null, issues: []);
  }
  final releases = [
    for (final release in sourceReleases)
      if (currentKnowledge.contains(_directorHash(_secretKnowledge(release)))) release,
  ];
  final paths = prepared.protection.paths.toList()..sort();
  final knowledge = [for (final release in releases) _secretKnowledge(release)]
    ..sort((a, b) => _directorHash(a).compareTo(_directorHash(b)));
  return _SecretInput(
    card: prepared.card,
    state: prepared.state,
    releases: releases,
    policy: {'version': 1, 'protectedPaths': paths, 'unavailable': prepared.unavailable, 'knowledge': knowledge},
    issues: [
      ...prepared.protection.issues,
      ...prepared.currentProtection.ledger.issues,
      if (prepared.unavailable) _directorIssue('secret_input_unavailable'),
    ],
  );
}

Map<String, Object?> _secretKnowledge(state_core.SecretRelease release) => {
  'slotId': release.slotId,
  'entityId': release.entityId,
  'path': release.path,
  'releaseId': release.releaseId,
  'characterId': release.characterId,
  'definitionFingerprint': release.definitionFingerprint,
  'valueHash': release.valueHash,
};

Map<String, Object?> _secretStateSource(Map<String, Object?> saved) {
  final input = _StateInput(saved);
  return {
    'state': {
      'valueExists': input.valueExists,
      if (input.valueExists) 'value': input.value,
      'variables': saved['variables'],
      'issues': input.issues,
    },
    if (saved.containsKey(_secretRuntimeKey)) 'secretRuntime': saved[_secretRuntimeKey],
  };
}

/// Current authorization needs the selected saved state, not unrelated later
/// ancestor bodies or their extra/original JSON. Source provenance is separate.
Map<String, Object?> _secretAuthorizationSource(TavernEngine engine, String chatId, String? nodeId) {
  final saved = nodeId == null && engine._store.groupChat(chatId) == null
      ? _emptyChatState(engine._chatCodec.metadataForNode(engine._store, chatId))
      : engine._stateAt(chatId, nodeId);
  return _secretStateSource(saved);
}

String? _secretTurnContextReason(TavernEngine engine, _Turn turn, Map<String, Object?> settings) {
  final cardReason = _secretCardRevisionReason(turn, engine._directors._cardRevisions[turn.chat.characterId] ?? 0);
  if (cardReason != null) {
    return cardReason;
  }
  final admission = turn.gameplayAdmission;
  if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
    return 'secret_gameplay_changed';
  }
  final chat = engine._store.chat(turn.chat.id);
  return _secretPersonaReason(turn, _currentSecretPersona(engine, chat, settings));
}

String? _secretCardRevisionReason(_Turn turn, int revision) =>
    turn.secretCardRevision == revision ? null : 'secret_card_changed';

String? _secretPersonaReason(_Turn turn, Map<String, Object?> persona) =>
    _stateJsonEqual(persona, _directorPersona(turn.personaSelection, turn.settings)) ? null : 'secret_persona_changed';

/// The full source was authenticated at admission. Later checks compare the
/// actual knowledge policy against this request's state, without treating our
/// own newly-created reply or macro writes as a new historical source.
String? _secretDirectorTurnReason(TavernEngine engine, _Turn turn, Map<String, Object?> saved) {
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible) return null;
  final prior = prepared.stored.result['secretPolicy'];
  if (prior == null && turn.secretProtection?.active != true) return null;
  final data = turn.directorCard;
  if (data == null) return 'secret_card_unavailable';
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (reason != null) return reason;
  final current = _ordinarySecretInput(
    engine,
    turn.chat.id,
    turn.chat.characterId,
    data,
    settings,
    _secretStateSource(saved),
    gameplay: turn.gameplay,
  ).policy;
  return _secretKnowledgeReason(current, prior);
}

String? _secretKnowledgeReason(Map<String, Object?>? current, Object? prior) =>
    current?['unavailable'] == true || !_stateJsonEqual(current, prior) ? 'director_secret_knowledge_changed' : null;

List<PromptInjection> _secretTurnInjections(TavernEngine engine, _Turn turn, Map<String, Object?> data) {
  if (turn.kind == _TurnKind.impersonate || !_secretsEnabled(turn.settings) || !turn.gameplayValueEligible) {
    return [];
  }
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (reason != null) {
    if (turn.secretProtection?.active == true) turn.secretIssues.add(_directorIssue(reason));
    return [];
  }
  final saved = turn.currentState;
  final protection = _SecretProtection(data, saved, gameplay: turn.gameplay);
  final releases = _secretReleases(engine, turn.chat.id, turn.chat.characterId, data, settings, saved, protection);
  return _secretReleaseInjections(turn, releases);
}

List<PromptInjection> _secretReleaseInjections(_Turn turn, List<state_core.SecretRelease> releases) {
  final result = <PromptInjection>[];
  for (final release in releases) {
    final sourceId = 'dshgo.secret.release:${_directorHash(_secretKnowledge(release))}';
    turn.secretOffered[sourceId] = {...release.toJson(), 'sourceId': sourceId, 'knowledge': _secretKnowledge(release)};
    if (release.text.isEmpty) continue;
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          release.text,
          PromptSource('secretFact', sourceId, label: '公开事实'),
          trimOnOverflow: true,
          expandMacros: false,
        ),
        depth: 1,
        order: 203,
      ),
    );
  }
  return result;
}

void _captureSecretAssembly(_Turn turn, PromptAssembly assembly) {
  for (final segment in assembly.afterPostProcessing) {
    final content = segment.message['content'];
    if (content is! String || content.isEmpty) continue;
    for (final source in segment.sources) {
      if (source.kind == 'secretFact' && turn.secretOffered.containsKey(source.id)) {
        turn.secretIncluded.add(source.id);
      }
    }
  }
}

bool _hasSecretTrace(_Turn turn) =>
    turn.secretProtection?.active == true ||
    turn.secretAttempt != null ||
    turn.secretIssues.isNotEmpty ||
    turn.secretOffered.isNotEmpty;

Map<String, Object?> _secretTurnTrace(_Turn turn, {bool? attempted}) => {
  'version': 1,
  if (turn.secretAttempt != null) 'binding': _copy(turn.secretAttempt!),
  'protectedPaths': turn.secretProtection?.paths.toList() ?? <String>[],
  'protectionUnknown': turn.secretProtection?.unknown ?? false,
  'offered': [for (final item in turn.secretOffered.values) _copy(item)],
  'included': turn.secretIncluded.toList(),
  // This is an attempted client call, never proof of provider receipt or of
  // character knowledge. A crash before terminal persistence may leave no log.
  'attempted': (attempted ?? turn.secretRequestAttempted) ? turn.secretIncluded.toList() : <String>[],
  'issues': [for (final issue in turn.secretIssues) _copy(issue)],
};

/// Called after other request preparation, immediately before generate(). No
/// async gap is permitted between this check and that client-call attempt.
TavernTurnInspection? _prepareSecretRequest(TavernEngine engine, _Turn turn) {
  final directorIncluded = _secretDirectorIncluded(turn);
  final directorReason = _secretDirectorTurnReason(engine, turn, turn.currentState);
  if (directorIncluded && directorReason != null) {
    turn.secretIssues.add(_directorIssue(directorReason));
    throw StateError('Director knowledge authorization changed before the request.');
  }
  if (turn.secretIncluded.isEmpty) return null;
  final data = turn.directorCard;
  final chat = engine._store.chat(turn.chat.id);
  final settings = engine._effectiveSettings(chat);
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (data == null ||
      reason != null ||
      !_secretsEnabled(turn.settings) ||
      !_secretsEnabled(settings) ||
      !turn.gameplayValueEligible ||
      turn.reply == null ||
      chat.currentLeafId != turn.reply!.nodeId) {
    turn.secretIssues.add(_directorIssue(reason ?? 'secret_release_revoked'));
    throw StateError('Secret release authorization changed before the request.');
  }
  final saved = engine._stateAt(chat.id, turn.reply!.nodeId);
  final current = _secretReleases(
    engine,
    chat.id,
    chat.characterId,
    data,
    settings,
    saved,
    _SecretProtection(data, saved, gameplay: turn.gameplay),
  );
  _checkSecretIncluded(turn, current);
  // Construct potentially fallible inspection data before marking attempted.
  return turn.inspection.copyWith(
    state: {..._statePreparationTrace(turn), 'secrets': _secretTurnTrace(turn, attempted: true)},
  );
}

bool _secretDirectorIncluded(_Turn turn) {
  final director = turn.inspection.director;
  return _map(director['beat'])['finalSourceObserved'] == true ||
      _stateRows(director['prefetch']).any((item) => item['finalSourceObserved'] == true);
}

void _checkSecretIncluded(_Turn turn, List<state_core.SecretRelease> current) {
  final authorized = {for (final release in current) _directorHash(_secretKnowledge(release))};
  for (final id in turn.secretIncluded) {
    final offered = turn.secretOffered[id]!;
    if (!authorized.contains(_directorHash(offered['knowledge']))) {
      turn.secretIssues.add(_directorIssue('secret_release_revoked', id: id));
      throw StateError('An included secret fact is no longer authorized.');
    }
  }
}

String? _secretDirectorEligibility(
  TavernEngine engine,
  StoredAgentRun stored,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  String? contextNodeId, {
  _GameplayRuntime? gameplay,
}) {
  final chat = engine._store.chat(stored.chatId);
  final source = _secretAuthorizationSource(engine, chat.id, contextNodeId);
  final current = _ordinarySecretInput(
    engine,
    chat.id,
    chat.characterId,
    data,
    settings,
    source,
    gameplay: gameplay,
  ).policy;
  final prior = stored.result['secretPolicy'];
  if (current == null && prior == null) return null;
  return prior is! Map<String, Object?> ? 'director_secret_knowledge_changed' : _secretKnowledgeReason(current, prior);
}

state_core.SecretCapability? _captureSecretCapability(_DirectorJob job) {
  final data = job.card;
  if (data == null ||
      job.nodeId == null ||
      !_secretsEnabled(job.settings) ||
      (job.gameplay?.story ?? _storyDefinition(data)).defined) {
    return null;
  }
  final state = _map(job.source['state']);
  if (_stateRows(state['issues']).isNotEmpty || state['valueExists'] != true) return null;
  final saved = <String, Object?>{
    'messageVariables': {'dshgo': state['value']},
    if (job.source.containsKey('secretRuntime')) _secretRuntimeKey: job.source['secretRuntime'],
  };
  final protection = _SecretProtection(data, saved, gameplay: job.gameplay);
  if (protection.unknown || !protection.definition.executable) return null;
  final capability = protection.definition.capture(
    value: state['value'],
    valueExists: true,
    boundKeys: protection.ledger.boundKeys,
    characterId: job.characterId,
  );
  return capability.slotIds.isEmpty ? null : capability;
}

Map<String, Object?> _secretCapabilityJson(state_core.SecretCapability capability) => {
  'version': 1,
  'fingerprint': capability.fingerprint,
  'definitionFingerprint': capability.definitionFingerprint,
  'stateDefinitionFingerprint': capability.stateDefinitionFingerprint,
  'baselineFingerprint': capability.baselineFingerprint,
  'characterId': capability.characterId,
  'slotIds': capability.slotIds,
  'catalog': capability.catalog,
};

Future<void> _runSecretDirector(_DirectorCoordinator coordinator, _DirectorJob job) async {
  final engine = coordinator.engine;
  job.cancellation.check();
  final chat = engine._store.chat(job.chatId);
  final settings = engine._effectiveSettings(chat);
  if (!_secretsEnabled(settings)) throw const FormatException('Secret helper has been disabled.');
  if ((coordinator._cardRevisions[job.characterId] ?? 0) != job.cardRevision ||
      !_stateJsonEqual(_currentSecretPersona(engine, chat, settings), job.persona)) {
    throw const FormatException('Secret helper card or persona changed before the request.');
  }
  final capability = job.secretCapability;
  final data = job.card;
  if (capability == null || data == null) throw const FormatException('Secret capability is unavailable.');
  final card = _gameplayDirectorCard(data, job.gameplay);
  job.fingerprint = _directorSourceFingerprint(
    job.source,
    _directorCard(data),
    job.persona,
    effectiveConfigId: job.gameplay?.effectiveConfigId,
  );
  final path = (job.source['path']! as List<Object?>).cast<String>();
  final summaries = engine._store.directorSummaries(job.chatId, path, limit: 20);
  final input = jsonEncode({
    'card': card,
    'persona': job.persona,
    'summaries': summaries,
    'recent': job.source['recent'],
    'state': job.source['state'],
    'slots': capability.catalog,
  });
  if (utf8.encode(input).length > 1024 * 1024) throw const FormatException('Secret input exceeds 1 MiB.');
  final config = _auxiliaryModelConfig(job.originalConfig);
  final tool = capability.strictTool();
  if (tool == null) throw const FormatException('No secret slot is available.');
  if (!config.deepseek) tool['function'] = _map(tool['function'])..remove('strict');
  final body = <String, Object?>{
    'messages': [
      {
        'role': 'system',
        'content':
            '你是故事的私密事实整理者。只通过 propose_secrets 提议尚未确定的固定槽值。'
            '依据提供的卡、最近剧情和实体身份保持一致；有疑问就省略该槽。不要写角色正文，不替用户行动。'
            '事实尚未提交，不在其他通道宣称已经成立或已经公开；notes 只供剧透审计。',
      },
      {'role': 'user', 'content': input},
    ],
    'stream': false,
    'max_tokens': 4096,
    if (config.deepseek) 'thinking': {'type': config.thinking ? 'enabled' : 'disabled'},
    'tools': [tool],
    'tool_choice': config.deepseek && config.thinking
        ? 'auto'
        : {
            'type': 'function',
            'function': {'name': 'propose_secrets'},
          },
  };
  final admission = job.gameplayAdmission;
  if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
    throw const FormatException('Secret helper gameplay sources changed before the request.');
  }
  final batch = await coordinator._receive(job, config, body);
  job.cancellation.check();
  if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
    throw const FormatException('Secret helper gameplay sources changed during the request.');
  }
  if ((job.finishReason != 'stop' && job.finishReason != 'tool_calls') ||
      !batch.eligibleStructure ||
      batch.issues.isNotEmpty ||
      batch.calls.length != 1) {
    throw const FormatException('A secret proposal requires one complete normal tool call.');
  }
  final call = batch.calls.single;
  if (!call.valid || call.type != 'function' || call.name != 'propose_secrets' || call.parameters == null) {
    throw const FormatException('Invalid secret proposal tool call.');
  }
  final output = capability.parseProposal(call.parameters!);
  _publishSecretDirector(coordinator, job, output: output.toJson());
}

void _publishSecretDirector(
  _DirectorCoordinator coordinator,
  _DirectorJob job, {
  Map<String, Object?>? output,
  String? failure,
}) {
  final engine = coordinator.engine;
  if (job.discarded || engine._closed) return;
  DateTime now;
  try {
    now = engine._clock();
  } catch (_) {
    now = job.at;
  }
  final raw = <String, Object?>{
    'version': 1,
    'mode': 'secrets',
    'sourceKind': job.nodeId == null ? 'empty' : 'node',
    'sourceNodeId': job.nodeId,
    'sourceFingerprint': job.fingerprint,
    if (job.gameplay case final gameplay?) 'effectiveConfigId': gameplay.effectiveConfigId,
    'characterId': job.characterId,
    'automatic': job.automatic,
    'startedAt': job.at.toUtc().toIso8601String(),
    'finishedAt': now.toUtc().toIso8601String(),
    'success': output != null && failure == null,
    'failure': failure,
    if (job.secretCapability != null) 'capability': _secretCapabilityJson(job.secretCapability!),
    'output': ?output,
    'issues': job.issues,
  };
  try {
    String? physical = job.nodeId;
    if (physical != null) {
      try {
        engine._store.node(job.chatId, physical);
      } catch (_) {
        physical = null;
      }
    }
    engine._store.transaction(() {
      if (output != null && failure == null) {
        final admission = job.gameplayAdmission;
        if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
          _gameplayCaptureConflict();
        }
        _ensureGameplayConfig(engine, job.gameplay);
      }
      engine._store.writeAgentRun(
        StoredAgentRun(
          id: job.id,
          chatId: job.chatId,
          nodeId: physical,
          kind: output == null ? 'director.secret_failure' : 'director.secret_proposal',
          at: now,
          usage: _directorUsageJson(job.usage),
          result: raw,
        ),
      );
    });
  } catch (_) {
    coordinator._transientIssues[job.chatId] = [_directorIssue('secret_result_not_persisted', id: job.id)];
  }
  coordinator.changed(job.chatId);
}

String? _secretBindingReason(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  String? parent,
  StoredAgentRun proposal,
) {
  final chat = engine._store.chat(turn.chat.id);
  final settings = engine._effectiveSettings(chat);
  final disabled = _secretBindingDisabled(turn, data, settings);
  if (disabled != null) {
    return disabled;
  }
  final contextReason = _secretTurnContextReason(engine, turn, settings);
  if (contextReason != null) return contextReason;
  final anchorReason = _secretBindingAnchorReason(turn, parent, proposal, chat.currentLeafId);
  if (anchorReason != null) {
    return anchorReason;
  }
  if (engine._store.hasPhysicalChildren(chat.id, parent!)) {
    return 'secret_source_not_current_physical_leaf';
  }
  final raw = proposal.result;
  final proposalReason = _secretProposalShapeReason(proposal, chat.characterId);
  if (proposalReason != null) {
    return proposalReason;
  }
  final persisted = engine._store.agentRunById(chat.id, proposal.id);
  if (!_secretProposalPersisted(proposal, persisted)) {
    return 'secret_proposal_not_persisted';
  }
  final selection = engine._personas.resolve(personaId: chat.personaId);
  final persona = _directorPersona(selection, _personaSettings(settings, selection));
  final personaReason = _secretPersonaReason(turn, persona);
  if (personaReason != null) {
    return personaReason;
  }
  final source = _directorSource(engine, chat.id, parent);
  if (_directorSourceFingerprint(
        source,
        _directorCard(data),
        persona,
        effectiveConfigId: turn.gameplay?.effectiveConfigId,
      ) !=
      raw['sourceFingerprint']) {
    return 'secret_source_changed';
  }
  return null;
}

String? _secretBindingDisabled(_Turn turn, Map<String, Object?> data, Map<String, Object?> settings) =>
    !_secretsEnabled(turn.settings) ||
        !_secretsEnabled(settings) ||
        turn.kind == _TurnKind.impersonate ||
        !turn.gameplayValueEligible ||
        (turn.gameplay?.story ?? _storyDefinition(data)).defined
    ? 'secret_binding_disabled'
    : null;

String? _secretBindingAnchorReason(_Turn turn, String? parent, StoredAgentRun proposal, String? currentLeafId) =>
    parent == null ||
        parent != currentLeafId ||
        parent != turn.chat.currentLeafId ||
        proposal.result['sourceNodeId'] != parent
    ? 'secret_source_not_current_physical_leaf'
    : null;

String? _secretProposalShapeReason(StoredAgentRun proposal, String characterId) {
  final raw = proposal.result;
  return proposal.kind != 'director.secret_proposal' ||
          raw['version'] != 1 ||
          raw['mode'] != 'secrets' ||
          raw['success'] != true ||
          raw['sourceKind'] != 'node' ||
          raw['characterId'] != characterId ||
          raw['capability'] is! Map<String, Object?> ||
          raw['output'] is! Map<String, Object?>
      ? 'secret_proposal_unavailable'
      : null;
}

bool _secretProposalPersisted(StoredAgentRun proposal, StoredAgentRun? persisted) =>
    persisted != null && persisted.kind == proposal.kind && _stateJsonEqual(persisted.result, proposal.result);

({_StateInput input, _SecretProtection protection})? _secretBindingState(
  _Turn turn,
  Map<String, Object?> data,
  StoredAgentRun proposal,
  Map<String, Object?> saved,
) {
  final input = _StateInput(saved);
  final protection = _SecretProtection(data, saved, gameplay: turn.gameplay);
  if (!input.writable || !input.valueExists || protection.unknown || !protection.definition.executable) {
    turn.secretIssues.add(_directorIssue('secret_state_unavailable', id: proposal.id));
    return null;
  }
  return (input: input, protection: protection);
}

state_core.SecretCapability? _secretBindingCapability(
  _Turn turn,
  StoredAgentRun proposal,
  _StateInput input,
  _SecretProtection protection,
  Map<String, Object?> rawExtra,
) {
  if (rawExtra.containsKey('dshgo') && rawExtra['dshgo'] is! Map<String, Object?>) {
    turn.secretIssues.add(_directorIssue('secret_extra_unavailable', id: proposal.id));
    return null;
  }
  final capability = protection.definition.capture(
    value: input.value,
    valueExists: true,
    boundKeys: protection.ledger.boundKeys,
    characterId: turn.chat.characterId,
  );
  if (!_stateJsonEqual(_secretCapabilityJson(capability), proposal.result['capability'])) {
    turn.secretIssues.add(_directorIssue('secret_capability_changed', id: proposal.id));
    return null;
  }
  return capability;
}

({state_core.StateSecretPlan plan, state_core.StateSecretPrepared prepared})? _prepareSecretBindingPlan(
  _Turn turn,
  Map<String, Object?> data,
  StoredAgentRun proposal,
  _StateInput input,
  state_core.SecretCapability capability,
  String invocation,
) {
  final state_core.StateSecretPlan plan;
  try {
    final output = capability.parseProposal(proposal.result['output']);
    if (output.facts.isEmpty) {
      return null;
    }
    plan = capability.plan(output, id: '$invocation:secret:${proposal.id}');
  } on FormatException {
    turn.secretIssues.add(_directorIssue('secret_proposal_invalid', id: proposal.id));
    return null;
  }
  final session = (turn.gameplay?.state ?? _stateDefinition(data)).startSession(
    valueExists: true,
    value: input.value,
    runtimeExists: input.runtimeExists,
    runtime: input.runtime,
    packRuntimeExists: input.packRuntimeExists,
    packRuntime: input.packRuntime,
  );
  final prepared = session.prepareSecretFacts(plan);
  turn.stateSession = session;
  turn.secretPrepared = prepared;
  turn.secretAttempt = {'version': 1, 'proposalRunId': proposal.id, 'committed': false, 'prepare': prepared.toJson()};
  return (plan: plan, prepared: prepared);
}

/// The three descendants are constructed before either writer adopts them.
/// This helper has no clock, store, receipt publication or session restart.
final class _SecretBindingCandidate {
  const _SecretBindingCandidate({
    required this.persistent,
    required this.extra,
    required this.generation,
    required this.restored,
    required this.bindings,
  });
  final Map<String, Object?> persistent, extra, generation;
  final StoredNode? restored;
  final List<Map<String, Object?>> bindings;
}

_SecretBindingCandidate _buildSecretBindingCandidate(
  _Turn turn, {
  required StoredAgentRun proposal,
  required String anchor,
  required String invocation,
  required String receiptId,
  required state_core.StateSecretPlan plan,
  required state_core.StateSecretPrepared prepared,
  required state_core.SecretCapability capability,
  required _SecretProtection protection,
  required Map<String, Object?> saved,
  required Map<String, Object?> rawExtra,
  required StoredNode? target,
}) {
  final facts = plan.facts;
  final bindings = <Map<String, Object?>>[
    for (var index = 0; index < facts.length; index++)
      {
        'bindingId': '$receiptId:$index',
        'bindingKey': state_core.secretBindingKey(
          facts[index].slotId,
          facts[index].entityId,
          source: protection.definition.source,
        ),
        if (protection.definition.source.isPack) 'executionSource': protection.definition.source.toJson(),
        'slotId': facts[index].slotId, 'entityId': facts[index].entityId, 'path': facts[index].path,
        'definitionFingerprint': capability.definitionFingerprint,
        // A string has identical canonicalization in the two hash domains.
        'valueHash': _directorHash(facts[index].value), 'valueType': 'string',
        'sourceNodeId': anchor, 'inputSourceFingerprint': proposal.result['sourceFingerprint'],
        'boundNodeId': anchor, 'beforeStateFingerprint': plan.baselineFingerprint,
        'afterStateFingerprint': prepared.valueFingerprint, 'generationInvocationId': invocation,
        'bindReceiptId': receiptId, 'proposalRunId': proposal.id, 'proposalIndex': index,
        'characterId': turn.chat.characterId, 'policyVersion': 1,
      },
  ];
  final persistent = _copy(saved);
  persistent['messageVariables'] = {..._map(persistent['messageVariables']), 'dshgo': prepared.value};
  if (prepared.runtimeExists) {
    persistent['dshgoStateRuntime'] = prepared.runtime;
  }
  if (prepared.packRuntimeExists) {
    persistent['dshgoPackRuntime'] = prepared.packRuntime;
  }
  persistent[_secretRuntimeKey] = protection.ledger.adding(bindings);
  _stampGameplayConfig(turn.gameplay, persistent);
  final extra = _stateNodeExtra(rawExtra, persistent, {
    'secretBinding': {'version': 1, 'runId': receiptId, 'proposalRunId': proposal.id},
  });
  final generation = _copy(turn.state);
  generation['messageVariables'] = _copy(_map(persistent['messageVariables']));
  if (persistent.containsKey('dshgoStateRuntime')) {
    generation['dshgoStateRuntime'] = _secretCopy(persistent['dshgoStateRuntime']);
  }
  if (persistent.containsKey('dshgoPackRuntime')) {
    generation['dshgoPackRuntime'] = _secretCopy(persistent['dshgoPackRuntime']);
  }
  generation[_secretRuntimeKey] = _secretCopy(persistent[_secretRuntimeKey]);
  _stampGameplayConfig(turn.gameplay, generation);
  final restored = target == null
      ? null
      : StoredNode(
          message: target.message,
          depth: target.depth,
          extra: _copy(extra),
          original: _copy(target.original),
          selectedChildId: target.selectedChildId,
        );
  return _SecretBindingCandidate(
    persistent: persistent,
    extra: extra,
    generation: generation,
    restored: restored,
    bindings: bindings,
  );
}

/// Only the proposal frozen by onListen is considered. Called synchronously
/// before history, macros, user-node creation or provider preparation.
void _bindSecretTurn(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  String? parent,
  StoredNode? target,
  void Function(Map<String, Object?> state, StoredNode? target) adopt,
) {
  final proposal = turn.secretCaptured;
  if (proposal == null) {
    return;
  }
  final reason = _secretBindingReason(engine, turn, data, parent, proposal);
  if (reason != null) {
    turn.secretIssues.add(_directorIssue(reason, id: proposal.id));
    return;
  }
  turn.cancellation.check();
  final anchor = parent!;
  final saved = engine._stateAt(turn.chat.id, anchor);
  final state = _secretBindingState(turn, data, proposal, saved);
  if (state == null) {
    return;
  }
  final rawExtra = engine._store.rawNodeExtra(turn.chat.id, anchor);
  final capability = _secretBindingCapability(turn, proposal, state.input, state.protection, rawExtra);
  if (capability == null) {
    return;
  }
  final invocation = turn.stateInvocationId ??= _newStateId();
  final preparation = _prepareSecretBindingPlan(turn, data, proposal, state.input, capability, invocation);
  if (preparation == null || !preparation.prepared.accepted) {
    return;
  }
  final plan = preparation.plan;
  final prepared = preparation.prepared;

  // Build all three detached descendants before COMMIT: persistent B,
  // continuation restoration B, and mutable generation G. A later error ends
  // this main turn and never opens a second session with a reset budget.
  final receiptId = '$invocation:secret_bind';
  final candidate = _buildSecretBindingCandidate(
    turn,
    proposal: proposal,
    anchor: anchor,
    invocation: invocation,
    receiptId: receiptId,
    plan: plan,
    prepared: prepared,
    capability: capability,
    protection: state.protection,
    saved: saved,
    rawExtra: rawExtra,
    target: target,
  );
  final bindings = candidate.bindings, extra = candidate.extra, generation = candidate.generation;
  final restored = candidate.restored;
  final audit = StoredAgentRun(
    id: receiptId,
    chatId: turn.chat.id,
    nodeId: anchor,
    kind: 'director.secret_bind',
    at: engine._clock(),
    result: {
      'version': 1,
      'committed': true,
      'proposalRunId': proposal.id,
      'generationInvocationId': invocation,
      'sourceNodeId': anchor,
      'sourceFingerprint': proposal.result['sourceFingerprint'],
      'capabilityFingerprint': capability.fingerprint,
      'bindings': bindings,
      'beforeStateFingerprint': plan.baselineFingerprint,
      'afterStateFingerprint': prepared.valueFingerprint,
      'changes': prepared.changes,
      'receipts': prepared.receipts,
      'issues': prepared.issues,
    },
  );
  final committedTrace = <String, Object?>{...turn.secretAttempt!, 'committed': true, 'bindReceiptId': receiptId};
  void checkBinding() {
    turn.cancellation.check();
    if (_secretBindingReason(engine, turn, data, anchor, proposal) != null ||
        !_stateJsonEqual(engine._store.rawNodeExtra(turn.chat.id, anchor), rawExtra)) {
      throw StateError('Secret source changed after preparation.');
    }
    _ensureGameplayConfig(engine, turn.gameplay);
  }

  if (turn.toolOwner case final owner?) {
    engine._store.commitToolSecretBinding(
      owner,
      anchorNodeId: anchor,
      expectedExtra: rawExtra,
      extra: extra,
      audit: audit,
      checkBinding: checkBinding,
      prepared: (generation, restored, committedTrace),
      onCommitted: (committed) {
        turn.toolPhase = committed.ownership.phase;
        turn.secretAttempt = committed.value.$3;
        adopt(committed.value.$1, committed.value.$2);
      },
    );
  } else {
    engine._store.transaction(
      () {
        checkBinding();
        engine._store.updateMessage(turn.chat.id, anchor, extra: extra);
        engine._store.writeAgentRun(audit);
      },
      onCommitted: () {
        turn.secretAttempt = committedTrace;
        adopt(generation, restored);
      },
    );
  }
}
