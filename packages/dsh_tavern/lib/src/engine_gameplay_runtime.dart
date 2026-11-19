part of 'engine.dart';

/// One synchronous database admission, retained across all later IO.
final class _GameplayAdmission {
  const _GameplayAdmission(this.request, this.snapshot, this.settings, {this.newGroupCharacterIds});
  final TavernGameplayContext request;
  final StoredGameplaySnapshot snapshot;
  final Map<String, Object?> settings;
  final List<String>? newGroupCharacterIds;
  String get hostCharacterId => snapshot.chat?.characterId ?? request.characterId;
  bool get isGroup => snapshot.group != null || newGroupCharacterIds != null;
  List<String> get rosterCharacterIds =>
      newGroupCharacterIds ??
      [for (final member in snapshot.group?.members ?? const <TavernGroupMember>[]) member.characterId];
  bool get hasActivePacks => snapshot.resolvedScopes.any((scope) => scope.bindings.any((binding) => binding.enabled));
  String get identity => _directorHash(_gameplayBindingIdentity(snapshot));
}

_GameplayAdmission _captureGameplayAdmission(
  TavernEngine engine, {
  required String characterId,
  String? chatId,
  Map<String, Object?>? settings,
  List<String>? newGroupCharacterIds,
}) {
  final roster = newGroupCharacterIds == null ? null : List<String>.of(newGroupCharacterIds);
  final snapshot = engine._store.readGameplaySnapshot(
    characterId: characterId,
    chatId: chatId,
    readBindings: true,
    readContext: false,
    additionalCharacterIds: roster ?? const [],
    deferResourceErrors: true,
  );
  final options =
      settings ?? (snapshot.chat == null ? engine._effectiveSettings() : engine._effectiveSettings(snapshot.chat));
  return _GameplayAdmission(
    TavernGameplayContext(characterId: characterId, chatId: chatId),
    snapshot,
    options,
    newGroupCharacterIds: roster,
  );
}

Map<String, Object?> _gameplayBindingIdentity(StoredGameplaySnapshot snapshot) => _gameplayBindingFactsIdentity(
  snapshot.domainId,
  snapshot.scopeSnapshots,
  snapshot.resolvedScopes,
  (ref) => snapshot.packs[(ref.installedPackId, ref.packVersion)]!.version,
);

Map<String, Object?> _gameplayBindingFactsIdentity(
  String domainId,
  List<TavernPackScopeSnapshot> scopeSnapshots,
  List<TavernPackScopePreview> resolvedScopes,
  TavernPackVersion? Function(TavernPackVersionRef) version,
) {
  final savedScopes = {for (final scope in scopeSnapshots) (scope.scope.kind, scope.scope.targetId): scope};
  return {
    'domainId': domainId,
    'scopes': [
      for (final scope in resolvedScopes)
        {
          'scope': scope.scope.name,
          'targetId': scope.targetId,
          'token': savedScopes[(scope.scope, scope.targetId)]?.token.toJson(),
          'bindings': [
            for (final binding in scope.bindings)
              _gameplayBindingIdentityRow(
                binding,
                savedScopes[(scope.scope, scope.targetId)]?.bindings ?? const [],
                version(binding.packRef),
              ),
          ],
        },
    ],
  };
}

Map<String, Object?> _gameplayBindingIdentityRow(
  TavernPackBindingPreview binding,
  List<TavernPackBinding> saved,
  TavernPackVersion? version,
) {
  final adopted = saved
      .where(
        (row) => row.bindingId == binding.bindingId && row.packRef.installedPackId == binding.packRef.installedPackId,
      )
      .firstOrNull;
  return {
    'bindingId': binding.bindingId,
    'packRef': binding.packRef.toJson(),
    'enabled': binding.enabled,
    'aliases': binding.aliases,
    'bindingRevision': adopted?.bindingRevision,
    'onceEpoch': adopted?.onceEpoch,
    'removed': adopted?.removed,
    'sourceMap': adopted?.sourceMap ?? const <Map<String, Object?>>[],
    'availability': version?.availability.toJson(),
    'available': version != null,
    'versionRemoved': version?.removed,
    'digest': version?.digest,
  };
}

bool _gameplayAdmissionCurrent(TavernEngine engine, _GameplayAdmission admission) => _gameplaySnapshotCurrent(
  engine,
  admission.snapshot,
  characterId: admission.request.characterId,
  chatId: admission.request.chatId,
  newGroupCharacterIds: admission.newGroupCharacterIds,
);

bool _gameplaySnapshotCurrent(
  TavernEngine engine,
  StoredGameplaySnapshot snapshot, {
  String? characterId,
  String? chatId,
  List<String>? newGroupCharacterIds,
}) {
  if (engine._authoringAuthority.domainId != snapshot.domainId) {
    return false;
  }
  final current = engine._store.readGameplayBindingFacts(
    characterId: characterId,
    chatId: chatId,
    additionalCharacterIds: newGroupCharacterIds ?? const [],
  );
  return _stateJsonEqual(
        _gameplayBindingFactsIdentity(
          current.domainId,
          current.scopeSnapshots,
          current.resolvedScopes,
          (ref) => current.versions[(ref.installedPackId, ref.packVersion)],
        ),
        _gameplayBindingIdentity(snapshot),
      ) &&
      current.hostCharacterId == snapshot.chat?.characterId &&
      _stateJsonEqual(
        newGroupCharacterIds ?? current.groupCharacterIds ?? const <String>[],
        newGroupCharacterIds ??
            [for (final member in snapshot.group?.members ?? const <TavernGroupMember>[]) member.characterId],
      ) &&
      (current.groupCharacterIds != null) == (snapshot.group != null);
}

List<_GameplayPackInput> _gameplayPackInputs(StoredGameplaySnapshot snapshot) => [
  for (final scope in snapshot.resolvedScopes)
    for (final binding in scope.bindings)
      (
        scope: scope.scope,
        targetId: scope.targetId,
        binding: binding,
        version: snapshot.packs[(binding.packRef.installedPackId, binding.packRef.packVersion)]!.version,
        files: snapshot.packs[(binding.packRef.installedPackId, binding.packRef.packVersion)]!.files,
      ),
];

/// Carries definitions, not a new state session or an initialized value.
final class _GameplayRuntime {
  const _GameplayRuntime({
    required this.effectiveConfigId,
    required this.state,
    required this.events,
    required this.secrets,
    required this.story,
    required this.activeSources,
    required this.sourceVector,
    required this.effectiveDefinitions,
    required this.sourceMap,
    required this.issues,
  });
  final String effectiveConfigId;
  final state_core.StateDefinition state;
  final state_core.CardEventDefinition events;
  final state_core.SecretDefinition secrets;
  final story_core.StoryDefinition story;
  final Set<state_core.StateExecutionSource> activeSources;
  final Map<String, Object?> sourceVector, effectiveDefinitions;
  final List<Map<String, Object?>> sourceMap, issues;
}

Future<_GameplayRuntime?> _prepareGameplayRuntime(
  TavernEngine engine,
  _GameplayAdmission admission, {
  required Map<String, Object?> hostData,
  bool force = false,
  Map<String, Object?>? settings,
  Map<String, Map<String, Object?>?>? capturedCards,
}) async {
  if (!admission.hasActivePacks && !force) {
    return null;
  }
  // The host can be an actual C2 candidate. Never replace it with a live read.
  final cards = <String, Map<String, Object?>?>{admission.hostCharacterId: hostData};
  for (final id in <String>{admission.request.characterId, ...admission.rosterCharacterIds}) {
    if (!cards.containsKey(id)) {
      cards[id] = capturedCards != null && capturedCards.containsKey(id)
          ? capturedCards[id]
          : (await engine._record(id))?.card.data;
    }
  }
  if (!_gameplayAdmissionCurrent(engine, admission)) {
    _gameplayCaptureConflict();
  }
  final options = settings ?? admission.settings;
  final context = (
    request: admission.request,
    hostCharacterId: admission.hostCharacterId,
    rosterCharacterIds: admission.rosterCharacterIds,
    isGroup: admission.isGroup,
    regexEnabled: options['regexEnabled'] != false,
    characterRegexEnabled:
        options['regexEnabled'] != false &&
        options['characterRegexEnabled'] != false &&
        !_strings(options['disabledCharacterRegex']).contains(admission.request.characterId),
    legacyResources: <_GameplayLegacyResource>[],
    currentState: null,
    validateCurrentState: false,
  );
  final bindingIdentity = _gameplayBindingIdentity(admission.snapshot);
  final resolution = _composeGameplayData(
    _gameplayPackInputs(admission.snapshot),
    cards,
    context,
    bindingIdentity: bindingIdentity,
    includeResources: false,
  );
  final identity = _gameplayConfigurationIdentity(
    cards,
    context,
    resolution.sources,
    resolution.effective! as Map<String, Object?>,
    resolution.definitions,
    resolution.fieldSources,
    resolution.conflicts,
    bindingIdentity: bindingIdentity,
  );
  final sourceVector = <String, Object?>{'v': 1, 'identity': identity, 'sources': identity['sources']};
  final definitions = <String, Object?>{
    'v': 1,
    'effective': resolution.effective,
    'definitions': resolution.definitions,
    'fieldSources': resolution.fieldSources,
    'conflicts': resolution.conflicts,
  };
  final sourceMap = <Map<String, Object?>>[
    for (final scope in admission.snapshot.scopeSnapshots)
      for (final binding in scope.bindings)
        for (final row in binding.sourceMap) {'bindingId': binding.bindingId, ...row},
  ];
  return _compileGameplayRuntime(resolution.effectiveConfigId, sourceVector, definitions, sourceMap);
}

_GameplayRuntime _compileGameplayRuntime(
  String configId,
  Map<String, Object?> sourceVector,
  Map<String, Object?> definitions,
  List<Map<String, Object?>> sourceMap,
) {
  final identity = sourceVector['identity']! as Map<String, Object?>;
  final bindingIdentity = identity['bindings']! as Map<String, Object?>;
  final bindings = <String, Map<String, Object?>>{
    for (final scope in (bindingIdentity['scopes']! as List<Object?>).cast<Map<String, Object?>>())
      for (final row in (scope['bindings']! as List<Object?>).cast<Map<String, Object?>>())
        row['bindingId']! as String: row,
  };
  state_core.StateExecutionSource executionSource(Map<String, Object?> source) {
    if (source['kind'] == 'card') {
      return const state_core.StateExecutionSource.legacy();
    }
    final binding = bindings[source['bindingId']]!;
    final ref = binding['packRef']! as Map<String, Object?>;
    return state_core.StateExecutionSource.pack(
      installedPackId: ref['installedPackId']! as String,
      bindingId: binding['bindingId']! as String,
      onceEpoch: binding['onceEpoch']! as int,
    );
  }

  final sources = (sourceVector['sources']! as List<Object?>).cast<Map<String, Object?>>();
  final byBinding = <String, Map<String, Object?>>{
    for (final source in sources)
      if (source['kind'] == 'pack') source['bindingId']! as String: source,
  };
  final host = sources.firstWhere((row) => row['kind'] == 'card' && (row['roles']! as List<Object?>).contains('host'));
  Map<String, Object?> owner(Map<String, Object?>? source) =>
      source?['kind'] == 'pack' ? byBinding[source!['bindingId']]! : host;
  Object? version(Map<String, Object?> source) {
    final raw = source['raw'];
    return raw is Map<String, Object?> && raw.containsKey('v') ? raw['v'] : 1;
  }

  bool eligible(Map<String, Object?> source) =>
      (source['rawPresent'] != true || source['raw'] is Map<String, Object?>) && version(source) == 1;
  final declared = <Map<String, Object?>>[
    host,
    for (final source in sources)
      if (source['kind'] == 'pack' &&
          (source['roles']! as List<Object?>).contains('definition') &&
          source['enabled'] == true &&
          source['available'] == true &&
          source['removed'] != true)
        source,
  ];
  final facts = {
    for (final row in (definitions['definitions']! as List<Object?>).cast<Map<String, Object?>>())
      row['path']! as String: row,
  };
  final effective = definitions['effective']! as Map<String, Object?>;
  final references = (facts['/references']!['items']! as List<Object?>).cast<Map<String, Object?>>();
  final ruleActions = <state_core.StateExecutionSource, Map<(int, int), state_core.StateEventTarget>>{};
  final eventActions = <state_core.StateExecutionSource, Map<(int, int), state_core.StateEventTarget>>{};
  final eventTargets = <state_core.StateExecutionSource, Map<int, state_core.StateEventTarget>>{};
  var stateReferencesEligible = true;
  var eventReferencesEligible = true;
  for (final reference in references) {
    if (reference['kind'] != 'event') {
      continue;
    }
    final source = executionSource(reference['source']! as Map<String, Object?>);
    final tokens = _authoringPointer(reference['pointer']! as String);
    if (reference['resolved'] != true) {
      if (tokens.first == 'state') {
        stateReferencesEligible = false;
      } else {
        eventReferencesEligible = false;
      }
      continue;
    }
    final target = (
      source: executionSource(reference['target']! as Map<String, Object?>),
      name: reference['localId']! as String,
    );
    if (tokens.length == 5) {
      (eventTargets[source] ??= {})[int.parse(tokens[3])] = target;
    } else if (tokens.first == 'state') {
      (ruleActions[source] ??= {})[(int.parse(tokens[2]), int.parse(tokens[4]))] = target;
    } else {
      (eventActions[source] ??= {})[(int.parse(tokens[3]), int.parse(tokens[5]))] = target;
    }
  }
  final state = state_core.StateDefinition.compose(
    effective['state'],
    version: version(host),
    effectiveConfigId: configId,
    compositionEligible: facts['/state']!['compositionEligible'] == true && stateReferencesEligible,
    sources: [
      for (final source in declared)
        if (eligible(source) && _map(source['raw'])['state'] is Map<String, Object?>)
          state_core.StateRuleSource(
            source: executionSource(source),
            state: _map(source['raw'])['state']! as Map<String, Object?>,
            actionTargets: ruleActions[executionSource(source)] ?? const {},
          ),
    ],
  );
  final registries = (facts['/director/eventRules']!['registries']! as List<Object?>).cast<Map<String, Object?>>();
  final events = state_core.CardEventDefinition.compose(
    [
      for (final row in registries)
        state_core.CardEventRegistrySource(
          source: executionSource(row['source']! as Map<String, Object?>),
          raw: row['raw'],
          version: version(owner(row['source']! as Map<String, Object?>)),
          eventTargets: eventTargets[executionSource(row['source']! as Map<String, Object?>)] ?? const {},
          actionTargets: eventActions[executionSource(row['source']! as Map<String, Object?>)] ?? const {},
        ),
    ],
    effectiveConfigId: configId,
    compositionEligible: facts['/director/eventRules']!['compositionEligible'] == true && eventReferencesEligible,
  );
  final secretSource = owner(facts['/director/secretSlots']!['source'] as Map<String, Object?>?);
  final storySource = owner(facts['/story']!['source'] as Map<String, Object?>?);
  final secrets = state_core.SecretDefinition.parse(
    _map(effective['director'])['secretSlots'],
    state: state,
    version: version(secretSource),
    source: executionSource(secretSource),
    effectiveConfigId: configId,
  );
  return _GameplayRuntime(
    effectiveConfigId: configId,
    state: state,
    events: events,
    secrets: secrets,
    story: story_core.StoryDefinition.parse(effective['story'], version: version(storySource)),
    activeSources: {
      for (final source in declared)
        if (source['kind'] == 'pack' && eligible(source)) executionSource(source),
    },
    sourceVector: sourceVector,
    effectiveDefinitions: definitions,
    sourceMap: sourceMap,
    issues: (definitions['conflicts']! as List<Object?>).cast<Map<String, Object?>>(),
  );
}

({bool referenced, _GameplayRuntime? config, List<Map<String, Object?>> issues}) _gameplayHistoricalConfig(
  TavernEngine engine,
  Map<String, Object?> saved,
) {
  if (!saved.containsKey('dshgoPackDefinitionConfigId')) {
    return (referenced: false, config: null, issues: []);
  }
  final id = saved['dshgoPackDefinitionConfigId'];
  Map<String, Object?> issue(String code, String message) => {
    'code': code,
    'path': '/dshgoPackDefinitionConfigId',
    'message': message,
  };
  if (id is! String || id.isEmpty) {
    return (
      referenced: true,
      config: null,
      issues: [
        issue('gameplay_config_reference', 'The saved definition reference is malformed; raw state is read-only.'),
      ],
    );
  }
  try {
    final stored = engine._store.readGameplayEffectiveConfigData(id);
    if (stored == null) {
      return (
        referenced: true,
        config: null,
        issues: [issue('gameplay_config_unresolved', 'The saved definition configuration is not in this database.')],
      );
    }
    final vector = stored['sourceVector']! as Map<String, Object?>;
    final definitions = stored['effectiveDefinitions']! as Map<String, Object?>;
    final sourceMap = (stored['sourceMap']! as List<Object?>).cast<Map<String, Object?>>();
    final identity = vector['identity']! as Map<String, Object?>;
    if (vector['v'] != 1 ||
        definitions['v'] != 1 ||
        _directorHash(identity) != id ||
        !_stateJsonEqual(vector['sources'], identity['sources']) ||
        !_stateJsonEqual(definitions['effective'], identity['effective']) ||
        !_stateJsonEqual(definitions['definitions'], identity['definitions']) ||
        !_stateJsonEqual(definitions['fieldSources'], identity['fieldSources']) ||
        !_stateJsonEqual(definitions['conflicts'], identity['conflicts'])) {
      throw const FormatException('Invalid saved gameplay configuration.');
    }
    final bindings = identity['bindings']! as Map<String, Object?>;
    final expectedMap = [
      for (final scope in (bindings['scopes']! as List<Object?>).cast<Map<String, Object?>>())
        for (final binding in (scope['bindings']! as List<Object?>).cast<Map<String, Object?>>())
          for (final row in (binding['sourceMap']! as List<Object?>).cast<Map<String, Object?>>())
            {'bindingId': binding['bindingId'], ...row},
    ];
    if (!_stateJsonEqual(sourceMap, expectedMap)) {
      throw const FormatException('Invalid saved gameplay source map.');
    }
    final _GameplayRuntime compiled;
    try {
      compiled = _compileGameplayRuntime(id, vector, definitions, sourceMap);
    } on StateError {
      // Missing host/definition rows are malformed persisted structure.
      // This boundary does not catch failures of the SQL read above.
      throw const FormatException('Incomplete saved gameplay configuration.');
    }
    return (referenced: true, config: compiled, issues: []);
  } on FormatException {
    return (
      referenced: true,
      config: null,
      issues: [
        issue('gameplay_config_invalid', 'The saved definition configuration is malformed; raw state is read-only.'),
      ],
    );
  } on TypeError {
    return (
      referenced: true,
      config: null,
      issues: [
        issue('gameplay_config_invalid', 'The saved definition configuration is malformed; raw state is read-only.'),
      ],
    );
  }
}

void _ensureGameplayConfig(TavernEngine engine, _GameplayRuntime? config) {
  if (config == null) {
    return;
  }
  engine._store.ensureGameplayEffectiveConfigData(
    config.effectiveConfigId,
    sourceVector: config.sourceVector,
    effectiveDefinitions: config.effectiveDefinitions,
    sourceMap: config.sourceMap,
  );
}

void _stampGameplayConfig(_GameplayRuntime? config, Map<String, Object?> saved) {
  if (config != null) {
    saved['dshgoPackDefinitionConfigId'] = config.effectiveConfigId;
  }
}

List<Map<String, Object?>> _gameplayValueIssues(
  _GameplayRuntime? config,
  Map<String, Object?> saved, {
  bool initializing = false,
  _GameplayRuntime? previousConfig,
}) {
  if (config == null) {
    return [];
  }
  final input = _StateInput(saved);
  if (!config.state.hasSchema &&
      !input.valueExists &&
      (!saved.containsKey('dshgoPackDefinitionConfigId') ||
          previousConfig != null && !previousConfig.state.hasSchema)) {
    return input.issues;
  }
  if (!config.state.executable) {
    return [
      {
        'code': 'gameplay_value_definition',
        'path': '/messageVariables/dshgo',
        'message':
            'The prospective definition is not executable; the prior value and definition reference are retained.',
        'effectiveConfigId': config.effectiveConfigId,
      },
    ];
  }
  if (initializing && !input.valueExists && !saved.containsKey('dshgoPackDefinitionConfigId')) {
    return input.issues;
  }
  return [
    ...input.issues,
    for (final issue in config.state.validate(input.value, valueExists: input.valueExists))
      {
        ...issue,
        'path': '/messageVariables/dshgo${issue['path']! as String}',
        'transition': 'gameplay_value',
        'effectiveConfigId': config.effectiveConfigId,
      },
  ];
}

TavernTurnInspection _gameplayInspection(TavernTurnInspection inspection, _GameplayRuntime? config) => config == null
    ? inspection
    : inspection.copyWith(state: {...inspection.state, 'admissionConfigId': config.effectiveConfigId});

/// Only a settlement that was actually accepted can ensure new explanation
/// data. The caller must already be inside its real state-adoption transaction.
void _ensureAdoptedGameplay(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> state,
  _StateSettlement? stateSettlement,
  _StorySettlement? storySettlement,
) {
  final config = turn.gameplay;
  final admission = turn.gameplayAdmission;
  if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
    turn.cancellation.cancel();
    turn.cancellation.check();
  }
  if (config != null &&
      state['dshgoPackDefinitionConfigId'] == config.effectiveConfigId &&
      (stateSettlement?.trace['stateCommitted'] == true ||
          stateSettlement?.events?.result['committed'] == true ||
          storySettlement?.result['committed'] == true)) {
    _ensureGameplayConfig(engine, config);
  }
}
