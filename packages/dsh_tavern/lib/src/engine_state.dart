part of 'engine.dart';

state_core.StateDefinition _stateDefinition(Map<String, Object?> data) {
  final dshgo = _readMap(_readMap(data['extensions'])['dshgo']);
  return state_core.StateDefinition.parse(dshgo['state'], version: dshgo.containsKey('v') ? dshgo['v'] : 1);
}

/// Saved source identity is evidence, never inferred from the current binding.
state_core.StateExecutionSource? _savedGameplayExecutionSource(Object? raw) {
  if (raw is! Map<String, Object?>) {
    return null;
  }
  if (raw['kind'] == 'legacy') {
    return const state_core.StateExecutionSource.legacy();
  }
  final installed = raw['installedPackId'], binding = raw['bindingId'], epoch = raw['onceEpoch'];
  if (raw['kind'] != 'pack' ||
      installed is! String ||
      installed.isEmpty ||
      binding is! String ||
      binding.isEmpty ||
      epoch is! int ||
      epoch < 0) {
    return null;
  }
  return state_core.StateExecutionSource.pack(installedPackId: installed, bindingId: binding, onceEpoch: epoch);
}

Map<String, Object?> _stateIssue(String code, String path, String message) => {
  'code': code,
  'path': path,
  'message': message,
  'kind': 'state',
};

/// Reading these carriers never substitutes an empty object for a malformed
/// saved value. In particular a broken once ledger must not rerun once rules.
class _StateInput {
  _StateInput(Map<String, Object?> state) {
    final messages = state['messageVariables'];
    if (messages is Map<String, Object?>) {
      valueExists = messages.containsKey('dshgo');
      value = messages['dshgo'];
    } else if (state.containsKey('messageVariables')) {
      issues.add(
        _stateIssue(
          'message-variables-shape',
          '/messageVariables',
          'Saved message variables are not an object; the original is read-only.',
        ),
      );
    }
    packRuntimeExists = state.containsKey('dshgoPackRuntime');
    packRuntime = state['dshgoPackRuntime'];
    runtimeExists = state.containsKey('dshgoStateRuntime');
    runtime = state['dshgoStateRuntime'];
    if (!runtimeExists) return;
    if (runtime is! Map<String, Object?> || (runtime as Map<String, Object?>)['version'] != 1) {
      issues.add(
        _stateIssue(
          'runtime-version',
          '/dshgoStateRuntime',
          'The saved state runtime is not a supported version 1 object.',
        ),
      );
      return;
    }
    final object = runtime as Map<String, Object?>;
    final fired = object['firedRules'];
    if (object.containsKey('firedRules') && (fired is! List<Object?> || fired.any((item) => item is! String))) {
      issues.add(
        _stateIssue(
          'runtime-fired-rules',
          '/dshgoStateRuntime/firedRules',
          'The saved once ledger must be a list of strings.',
        ),
      );
    }
    final pending = object['pendingPrompts'];
    if (object.containsKey('pendingPrompts')) {
      final ids = <String>{};
      if (pending is! List<Object?> ||
          pending.any(
            (item) =>
                item is! Map<String, Object?> ||
                item['id'] is! String ||
                item['text'] is! String ||
                !ids.add(item['id']! as String),
          )) {
        issues.add(
          _stateIssue(
            'runtime-pending-prompts',
            '/dshgoStateRuntime/pendingPrompts',
            'Pending prompts must have unique string ids and string text.',
          ),
        );
      }
    }
  }
  bool valueExists = false;
  Object? value;
  bool runtimeExists = false;
  Object? runtime;
  bool packRuntimeExists = false;
  Object? packRuntime;
  final issues = <Map<String, Object?>>[];
  bool get writable => issues.isEmpty;
}

Future<TavernStateSnapshot> _readSavedState(TavernEngine engine, String chatId) async {
  final chat = engine._store.chat(chatId);
  final leaf = chat.currentLeafId;
  final saved = engine._stateAt(chatId, leaf);
  final extra = leaf == null ? <String, Object?>{} : engine._store.node(chatId, leaf).extra;
  final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
  final settings = engine._effectiveSettings(chat, metadata);
  final historical = _gameplayHistoricalConfig(engine, saved);
  if (historical.referenced) {
    final config = historical.config;
    return _statePanel(
      chatId,
      leaf,
      saved,
      extra,
      config?.state ?? state_core.StateDefinition.parse(null),
      settings,
      dshgoOnly: config == null || config.state.hasSchema || _StateInput(saved).valueExists,
      allowInitialPreview: false,
      interpretationIssues: historical.issues,
      protection: config == null ? null : _SecretProtection(const {}, saved, gameplay: config),
    );
  }
  final record = await engine._record(chat.characterId);
  if (record == null) {
    throw const TavernImportError('角色不存在。');
  }
  return _statePanel(
    chatId,
    leaf,
    saved,
    extra,
    _stateDefinition(record.card.data),
    settings,
    protection: _SecretProtection(record.card.data, saved),
  );
}

TavernStateSnapshot _statePanel(
  String chatId,
  String? leaf,
  Map<String, Object?> saved,
  Map<String, Object?> extra,
  state_core.StateDefinition definition,
  Map<String, Object?> settings, {
  _SecretProtection? protection,
  bool dshgoOnly = false,
  bool allowInitialPreview = true,
  List<Map<String, Object?>> interpretationIssues = const [],
}) {
  final own = _map(extra['dshgo']);
  final changes = _stateRows(own['stateChanges']);
  final effects = _stateRows(own['stateEffects']);
  final ownIssues = _stateRows(own['stateIssues']);
  if (!definition.hasSchema && !dshgoOnly) {
    final exists = saved.containsKey('variables');
    final values = exists ? saved['variables'] : <String, Object?>{};
    return TavernStateSnapshot(
      chatId: chatId,
      nodeId: leaf,
      legacy: true,
      initialized: exists,
      valueExists: exists,
      automaticEnabled: false,
      values: values,
      changes: changes,
      effects: effects,
      issues: [
        ...ownIssues,
        ...?protection?.issues,
        if (exists && values is! Map<String, Object?>)
          _stateIssue('legacy-variables-shape', '/variables', 'Saved local variables are not an object.'),
      ],
    );
  }
  final input = _StateInput(saved);
  final projection = definition.project(input.value, valueExists: input.valueExists);
  final initial = input.valueExists || !allowInitialPreview || !definition.hasSchema
      ? null
      : definition.initialPreview();
  return TavernStateSnapshot(
    chatId: chatId,
    nodeId: leaf,
    legacy: false,
    initialized: input.valueExists,
    valueExists: input.valueExists,
    automaticEnabled: settings['stateEnabled'] != false && definition.executable,
    schema: definition.schema,
    values: input.value,
    initialValuesAvailable: input.writable && initial != null && initial.valid && initial.valueExists,
    initialValues: initial?.value,
    hiddenPaths: {...projection.hiddenPaths, ...?protection?.paths}.toList(),
    pinPaths: projection.pinPaths,
    changes: changes,
    effects: effects,
    issues: [
      ...interpretationIssues,
      ...definition.issues,
      ...input.issues,
      ...projection.issues,
      ...ownIssues,
      ...?protection?.issues,
      if (input.valueExists) ...definition.validate(input.value),
      if (initial != null) ...initial.issues,
    ],
  );
}

List<Map<String, Object?>> _stateRows(Object? value) => value is List<Object?>
    ? [
        for (final item in value)
          if (item is Map<String, Object?>) _copy(item),
      ]
    : [];

/// Initialization belongs to the caller's existing message SQL operation.
/// It derives defaults but never executes plot rules or consumes prompts.
void _initializeDshState(
  state_core.StateDefinition definition,
  Map<String, Object?> saved,
  bool enabled, {
  _GameplayRuntime? gameplay,
}) {
  if (!enabled || !definition.hasSchema || !definition.executable) {
    return;
  }
  final input = _StateInput(saved);
  if (!input.writable || input.valueExists || saved.containsKey('dshgoPackDefinitionConfigId')) {
    return;
  }
  final result = definition
      .startSession(
        valueExists: false,
        runtimeExists: input.runtimeExists,
        runtime: input.runtime,
        packRuntimeExists: input.packRuntimeExists,
        packRuntime: input.packRuntime,
      )
      .finish(runRules: false);
  if (!result.valid || !result.valueExists) {
    return;
  }
  saved['messageVariables'] = {..._map(saved['messageVariables']), 'dshgo': result.value};
  if (result.runtimeExists) {
    saved['dshgoStateRuntime'] = result.runtime;
  }
  if (result.packRuntimeExists) {
    saved['dshgoPackRuntime'] = result.packRuntime;
  }
  _stampGameplayConfig(gameplay, saved);
}

Future<TavernStateEditResult> _editSavedState(
  TavernEngine engine,
  String chatId,
  String path,
  Object? value, {
  String? expectedNodeId,
}) {
  // Strict JSON copy before either operation or chat mutation can await.
  // Unlike legacy macro persistence, this rejects non-finite caller input.
  final captured = jsonDecode(jsonEncode(value));
  return engine._operation(
    () => engine._withMutation(chatId, () async {
      final chat = engine._store.chat(chatId);
      final leaf = chat.currentLeafId;
      final saved = engine._stateAt(chatId, leaf);
      final extra = leaf == null ? <String, Object?>{} : engine._store.node(chatId, leaf).extra;
      final settings = engine._effectiveSettings(chat, engine._chatCodec.metadataForNode(engine._store, chatId));
      final admission = _captureGameplayAdmission(engine, characterId: chat.characterId, chatId: chatId);
      final historical = _gameplayHistoricalConfig(engine, saved);
      final previousConfig = historical.config;
      final record = await engine._record(chat.characterId);
      if (record == null) {
        throw const TavernImportError('角色不存在。');
      }
      final gameplay = admission.hasActivePacks || historical.referenced
          ? await _prepareGameplayRuntime(engine, admission, hostData: record.card.data, force: historical.referenced)
          : null;
      final definition = gameplay?.state ?? _stateDefinition(record.card.data);
      final stateInput = _StateInput(saved);
      final legacyDomain =
          !definition.hasSchema &&
          ((gameplay == null && !historical.referenced) ||
              (!stateInput.valueExists &&
                  (!historical.referenced || (previousConfig != null && !previousConfig.state.hasSchema))));
      final invocation = _newStateId();
      final elapsed = Stopwatch()..start();
      var next = _copy(saved);
      var applied = false;
      var changed = false;
      var changes = <Map<String, Object?>>[];
      var effects = <Map<String, Object?>>[];
      var receipts = <Map<String, Object?>>[];
      final issues = <Map<String, Object?>>[];
      if (leaf == null) {
        issues.add(_stateIssue('empty-path', '', 'There is no selected message to edit.'));
      } else if (expectedNodeId != null && expectedNodeId != leaf) {
        issues.add(_stateIssue('stale-node', '', 'The selected message changed before this edit was admitted.'));
      } else if (!legacyDomain && (gameplay != null || historical.referenced) && !definition.executable) {
        issues.addAll(definition.issues);
        issues.add(
          _stateIssue(
            'gameplay_state_unavailable',
            '',
            'The prospective gameplay state definition is not executable; the saved value is preserved.',
          ),
        );
      } else if (!definition.hasSchema) {
        try {
          final edited = _editLegacyValue(
            saved.containsKey('variables') ? saved['variables'] : <String, Object?>{},
            path,
            captured,
            valueExists: saved.containsKey('variables'),
          );
          applied = true;
          changed = edited.changes.isNotEmpty;
          changes = edited.changes;
          next['variables'] = edited.value;
          receipts = [
            {
              'index': 0,
              'source': 'user',
              'actor': 'user',
              'operation': {'op': 'set', 'path': path, 'value': captured, 'why': '你改的'},
              'accepted': true,
              'changed': changed,
              'clamps': <Object?>[],
              'issues': <Object?>[],
            },
          ];
        } on FormatException catch (error) {
          issues.add(_stateIssue('legacy-pointer', path, error.message));
        }
      } else {
        final input = _StateInput(saved);
        issues.addAll(input.issues);
        if (input.writable) {
          final session = definition.startSession(
            valueExists: input.valueExists,
            value: input.value,
            runtimeExists: input.runtimeExists,
            runtime: input.runtime,
            packRuntimeExists: input.packRuntimeExists,
            packRuntime: input.packRuntime,
          );
          final operation = session.apply(
            [
              {'op': 'set', 'path': path, 'value': captured, 'why': '你改的'},
            ],
            actor: state_core.StateActor.user,
            source: 'user',
          );
          final result = session.finish(runRules: operation.acceptedCount > 0);
          receipts = result.receipts;
          issues.addAll(result.issues);
          applied = operation.acceptedCount > 0 && result.valid;
          if (applied) {
            changed = result.changed;
            changes = result.changes;
            effects = _identifiedEffects(result.effects, invocation);
            next = _stateResultSnapshot(saved, result, effects, const {});
            _stampGameplayConfig(gameplay, next);
          }
        }
      }
      final own = applied ? _stateOwnAudit(invocation, changes, effects, issues) : null;
      final nextExtra = own == null ? extra : _stateNodeExtra(extra, next, own);
      final resultJson = <String, Object?>{
        'version': 1,
        'invocationId': invocation,
        'source': 'user',
        if (definition.hasSchema) 'definitionFingerprint': definition.fingerprint,
        'path': path,
        'value': captured,
        'expectedNodeId': expectedNodeId,
        'committed': applied,
        'changed': changed,
        'receipts': receipts,
        'changes': changes,
        'effects': effects,
        'issues': issues,
        'elapsedMs': elapsed.elapsedMilliseconds,
      };
      engine._store.transaction(() {
        if (!_gameplayAdmissionCurrent(engine, admission)) {
          _gameplayCaptureConflict();
        }
        if (applied) {
          if (gameplay != null && next['dshgoPackDefinitionConfigId'] == gameplay.effectiveConfigId) {
            _ensureGameplayConfig(engine, gameplay);
          }
          engine._store.updateMessage(chatId, leaf!, extra: nextExtra);
          engine._store.updateChat(
            chatId,
            variables: _map(next['variables']),
            metadata: _runtimeMetadata(engine._store.chat(chatId).metadata, next),
          );
        }
        engine._store.writeAgentRun(
          StoredAgentRun(
            id: '$invocation:user',
            chatId: chatId,
            nodeId: leaf,
            kind: 'state.user',
            at: engine._clock(),
            result: resultJson,
          ),
        );
      });
      if (applied) engine._liveVariables[chatId] = (leaf: leaf, values: _map(next['variables']));
      return TavernStateEditResult(
        applied: applied,
        changed: changed,
        snapshot: _statePanel(
          chatId,
          leaf,
          applied ? next : saved,
          nextExtra,
          applied
              ? definition
              : historical.referenced
              ? historical.config?.state ?? state_core.StateDefinition.parse(null)
              : _stateDefinition(record.card.data),
          settings,
          dshgoOnly: applied
              ? gameplay != null && !legacyDomain
              : historical.referenced &&
                    (previousConfig == null || previousConfig.state.hasSchema || stateInput.valueExists),
          allowInitialPreview: !historical.referenced,
          interpretationIssues: applied ? const [] : historical.issues,
          protection: !applied && historical.referenced && historical.config == null
              ? null
              : _SecretProtection(
                  record.card.data,
                  applied ? next : saved,
                  gameplay: applied ? gameplay : historical.config,
                ),
        ),
        receipts: receipts,
        issues: issues,
      );
    }),
  );
}

({Map<String, Object?> value, List<Map<String, Object?>> changes}) _editLegacyValue(
  Object? original,
  String pointer,
  Object? value, {
  bool valueExists = true,
}) {
  final root = jsonDecode(jsonEncode(original));
  final tokens = _statePointerTokens(pointer);
  var oldExists = true;
  Object? old;
  late final Map<String, Object?> result;
  if (tokens.isEmpty) {
    if (value is! Map<String, Object?>) throw const FormatException('Local variables must remain an object.');
    old = root;
    oldExists = valueExists;
    result = _copy(value);
  } else {
    if (root is! Map<String, Object?>) throw const FormatException('Local variables are not an object.');
    Object? parent = root;
    for (final token in tokens.take(tokens.length - 1)) {
      if (parent is Map<String, Object?> && parent.containsKey(token)) {
        parent = parent[token];
      } else if (parent is List<Object?>) {
        parent = parent[_stateArrayIndex(token, parent.length)];
      } else {
        throw const FormatException('The pointer has a missing or non-container parent.');
      }
    }
    final key = tokens.last;
    if (parent is Map<String, Object?>) {
      oldExists = parent.containsKey(key);
      old = parent[key];
      parent[key] = value;
    } else if (parent is List<Object?>) {
      final index = _stateArrayIndex(key, parent.length);
      old = parent[index];
      parent[index] = value;
    } else {
      throw const FormatException('The pointer parent is not a container.');
    }
    result = root;
  }
  return (
    value: result,
    changes: [
      if (!oldExists || !_stateJsonEqual(old, value))
        {
          'path': pointer,
          'oldExists': oldExists,
          'old': old,
          'newExists': true,
          'new': value,
          'actor': 'user',
          'why': '你改的',
        },
    ],
  );
}

List<String> _statePointerTokens(String pointer) {
  if (pointer.isEmpty) return [];
  if (!pointer.startsWith('/')) throw const FormatException('A JSON Pointer starts with / or is empty.');
  return [for (final raw in pointer.substring(1).split('/')) _statePointerToken(raw)];
}

String _statePointerToken(String raw) {
  final result = StringBuffer();
  for (var index = 0; index < raw.length; index++) {
    if (raw[index] != '~') {
      result.write(raw[index]);
      continue;
    }
    if (++index >= raw.length || (raw[index] != '0' && raw[index] != '1')) {
      throw const FormatException('A JSON Pointer escape is ~0 or ~1.');
    }
    result.write(raw[index] == '0' ? '~' : '/');
  }
  return result.toString();
}

int _stateArrayIndex(String token, int length) {
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(token)) {
    throw const FormatException('An array pointer requires a canonical existing index.');
  }
  final index = int.tryParse(token);
  if (index == null || index >= length) throw const FormatException('The array index does not exist.');
  return index;
}

bool _stateJsonEqual(Object? left, Object? right) {
  if (left is num && right is num) return left == right;
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!_stateJsonEqual(left[i], right[i])) return false;
    }
    return true;
  }
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) || !_stateJsonEqual(entry.value, right[entry.key])) return false;
    }
    return true;
  }
  return left == right;
}

final _stateIds = Random.secure();
String _newStateId() => List.generate(16, (_) => _stateIds.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

Map<String, Object?> _stateNodeExtra(
  Map<String, Object?> extra,
  Map<String, Object?> state,
  Map<String, Object?> own,
) => {
  ..._copy(extra),
  'dshgo': {..._map(extra['dshgo']), ..._copy(own), 'tavernState': _copy(state)},
};

Map<String, Object?> _stateOwnAudit(
  String invocation,
  List<Map<String, Object?>> changes,
  List<Map<String, Object?>> effects,
  List<Map<String, Object?>> issues,
) => {
  'stateInvocation': {'version': 1, 'id': invocation},
  'stateChanges': changes,
  'stateEffects': effects,
  'stateIssues': issues,
};

List<Map<String, Object?>> _identifiedEffects(List<Map<String, Object?>> effects, String invocation) => [
  for (var i = 0; i < effects.length; i++)
    {..._copy(effects[i]), 'effectId': '$invocation:effect:$i', 'invocationId': invocation},
];

Map<String, Object?> _stateResultSnapshot(
  Map<String, Object?> previous,
  state_core.StateResult result,
  List<Map<String, Object?>> effects,
  Set<String> consumed,
) {
  final next = _copy(previous);
  if (result.valueExists) next['messageVariables'] = {..._map(next['messageVariables']), 'dshgo': result.value};
  if (result.runtimeExists) {
    next['dshgoStateRuntime'] = result.runtime;
  }
  if (result.packRuntimeExists) {
    next['dshgoPackRuntime'] = result.packRuntime;
  }
  final input = _StateInput(next);
  if (!input.writable) return next;
  final prompts = effects.where((effect) => effect['type'] == 'prompt' && effect['source'] != 'directorEvent').toList();
  if (consumed.isEmpty && prompts.isEmpty) return next;
  final runtime = input.runtimeExists ? _copy(input.runtime as Map<String, Object?>) : <String, Object?>{'version': 1};
  runtime['pendingPrompts'] = [
    for (final prompt in _stateRows(runtime['pendingPrompts']))
      if (!consumed.contains(prompt['id'])) prompt,
    for (final prompt in prompts)
      {
        'id': prompt['effectId'],
        'text': prompt['text'],
        'invocationId': prompt['invocationId'],
        if (prompt.containsKey('ruleId')) 'ruleId': prompt['ruleId'],
        if (prompt.containsKey('executionSource')) 'executionSource': _secretCopy(prompt['executionSource']),
        if (prompt.containsKey('localId')) 'localId': prompt['localId'],
      },
  ];
  next['dshgoStateRuntime'] = runtime;
  return next;
}

void _prepareStateTurn(_Turn turn, Map<String, Object?> data) {
  if (turn.kind == _TurnKind.impersonate) return;
  turn.secretProtection = _SecretProtection(data, turn.state, gameplay: turn.gameplay);
  turn.secretIssues.addAll(turn.secretProtection!.issues);
  final definition = turn.gameplay?.state ?? _stateDefinition(data);
  if (!definition.hasSchema) {
    return;
  }
  turn.stateDefinition = definition;
  turn.stateWatch = Stopwatch()..start();
  turn.stateAutomatic = turn.settings['stateEnabled'] != false && definition.executable && turn.gameplayValueEligible;
  _initializeDshState(
    definition,
    turn.state,
    turn.stateAutomatic && (turn.gameplay == null || turn.gameplayInitializing),
    gameplay: turn.gameplay,
  );
  turn.statePreparationIssues.addAll(definition.issues);
  turn.statePreparationIssues.addAll(_StateInput(turn.state).issues);
}

List<PromptInjection> _stateTurnInjections(_Turn turn) {
  final definition = turn.stateDefinition;
  if (definition == null || !turn.stateAutomatic) return [];
  final input = _StateInput(turn.state);
  final protection = turn.secretProtection;
  if (protection?.unknown == true) return [];
  final projectedInput = protection != null && protection.active ? protection.masked(input.value) : input.value;
  final projection = definition.project(projectedInput, valueExists: input.valueExists);
  turn.statePreparationIssues.addAll(projection.issues);
  final result = <PromptInjection>[
    if (projection.valueExists && projection.summary.isNotEmpty)
      PromptInjection(
        fragment: PromptFragment(
          projection.summary,
          const PromptSource('state', 'dsh-state', label: '状态'),
          expandMacros: false,
        ),
        role: projection.role,
        depth: projection.depth,
        order: 200,
      ),
  ];
  if (input.writable && input.runtimeExists) {
    final runtime = input.runtime as Map<String, Object?>;
    for (final prompt in _stateRows(runtime['pendingPrompts'])) {
      if (prompt.containsKey('executionSource')) {
        final source = _savedGameplayExecutionSource(prompt['executionSource']);
        if (source == null) {
          turn.statePreparationIssues.add(
            _stateIssue(
              'state_prompt_source',
              '/dshgoStateRuntime/pendingPrompts',
              'A saved prompt has an unsupported execution source; it is preserved without injection.',
            ),
          );
          continue;
        }
        if (source.isPack && !(turn.gameplay?.activeSources.contains(source) ?? false)) {
          continue;
        }
      }
      final id = prompt['id']! as String;
      // Ledger IDs are imported user data. Keep them out of the assembler's
      // native extension-ID namespace (for example 2_floating_prompt).
      final sourceId = 'dshgo.state.prompt:$id';
      turn.stateOfferedPrompts[sourceId] = id;
      result.add(
        PromptInjection(
          fragment: PromptFragment(
            prompt['text']! as String,
            PromptSource('statePrompt', sourceId, label: '规则提示'),
            trimOnOverflow: true,
            expandMacros: false,
          ),
          depth: 1,
          order: 201,
        ),
      );
    }
  }
  return result;
}

List<Map<String, Object?>> _stateTurnTools(_Turn turn) {
  final definition = turn.stateDefinition;
  if (definition == null || !turn.stateAutomatic || turn.effectiveThinking || turn.kind == _TurnKind.impersonate) {
    return [];
  }
  final input = _StateInput(turn.state);
  if (!input.writable) return [];
  final protection = turn.secretProtection;
  if (protection != null && protection.active && !protection.allowsTool(definition, input)) {
    turn.secretIssues.add(_directorIssue('secret_state_tool_unavailable'));
    return [];
  }
  final strict = definition.strictTool(value: input.value, valueExists: input.valueExists);
  turn.statePreparationIssues.addAll(strict.issues);
  final tool = strict.tool;
  if (tool == null) return [];
  if (!turn.config.deepseek) {
    final function = _map(tool['function'])..remove('strict');
    tool['function'] = function;
  }
  return [tool];
}

void _captureStateAssembly(_Turn turn, PromptAssembly assembly) {
  turn.stateToolAllowed =
      turn.stateAutomatic &&
      !turn.effectiveThinking &&
      turn.kind != _TurnKind.impersonate &&
      _finalStateToolAllowed(assembly.body);
  if (turn.stateOfferedPrompts.isEmpty) return;
  for (final segment in assembly.afterPostProcessing) {
    if (segment.message['content'] == '') continue;
    for (final source in segment.sources) {
      final ledgerId = turn.stateOfferedPrompts[source.id];
      if (source.kind == 'statePrompt' && ledgerId != null) {
        turn.stateSentPrompts.add(ledgerId);
      }
    }
  }
}

bool _finalStateToolAllowed(Map<String, Object?> body) {
  if (body.containsKey('thinking')) {
    final thinking = body['thinking'];
    if (thinking is! Map<String, Object?> || thinking['type'] != 'disabled') return false;
  }
  final tools = body['tools'];
  if (tools is! List<Object?> ||
      !tools.any(
        (item) =>
            item is Map<String, Object?> &&
            item['type'] == 'function' &&
            _map(item['function'])['name'] == 'update_state',
      )) {
    return false;
  }
  final messages = body['messages'];
  if (messages is List<Object?> && messages.any((item) => item is Map<String, Object?> && item['prefix'] == true)) {
    return false;
  }
  final choice = body['tool_choice'];
  if (choice == null || choice == 'auto' || choice == 'required') return true;
  return choice is Map<String, Object?> &&
      choice['type'] == 'function' &&
      _map(choice['function'])['name'] == 'update_state';
}

Map<String, Object?> _statePreparationTrace(_Turn turn) => {
  'version': 1,
  if (turn.stateDefinition != null) 'definitionFingerprint': turn.stateDefinition!.fingerprint,
  'automaticEnabled': turn.stateAutomatic,
  'modelToolAllowed': turn.stateToolAllowed,
  'pendingOffered': turn.stateOfferedPrompts.values.toList(),
  'pendingIncluded': turn.stateSentPrompts.toList(),
  'issues': turn.statePreparationIssues,
  if (_hasSecretTrace(turn)) 'secrets': _secretTurnTrace(turn),
};

class _StateRun {
  _StateRun(this.id, this.kind, this.result);
  final String id;
  final String kind;
  final Map<String, Object?> result;
}

/// Candidate data is deliberately separate from turn.state. The normal SQL
/// attempt may roll back and be followed by the existing partial-body commit.
class _StateSettlement {
  _StateSettlement({
    required this.state,
    required this.runs,
    required this.trace,
    this.ownAudit,
    this.events,
    this.toolSettlements = const [],
  });
  final Map<String, Object?> state;
  final Map<String, Object?>? ownAudit;
  final List<_StateRun> runs;
  final Map<String, Object?> trace;
  final _CardEventSettlement? events;
  final List<StoredToolStateSettlement> toolSettlements;
}

class _StagedStateCall {
  _StagedStateCall(this.call, this.problems, this.execution, {this.requestId, this.requestIndex});
  final ModelToolCall call;
  final List<Map<String, Object?>> problems;
  final state_core.StateApplyResult? execution;
  final String? requestId;
  final int? requestIndex;
  TavernToolReceipt? receipt;
}

class _StagedStateBatch {
  _StagedStateBatch(this.requestId, this.requestIndex, this.batch);
  final String requestId;
  final int requestIndex;
  final ModelToolBatch batch;
}

state_core.StateSession? _ordinaryStateSession(_Turn turn) {
  final definition = turn.stateDefinition;
  final input = _StateInput(turn.currentState);
  if (!turn.stateAutomatic ||
      definition == null ||
      !definition.executable ||
      !input.writable ||
      turn.kind == _TurnKind.impersonate) {
    return null;
  }
  return turn.stateSession ??= definition.startSession(
    valueExists: input.valueExists,
    value: input.value,
    runtimeExists: input.runtimeExists,
    runtime: input.runtime,
    packRuntimeExists: input.packRuntimeExists,
    packRuntime: input.packRuntime,
  );
}

_StagedStateCall _evaluateStateCall(
  ModelToolCall call, {
  required bool normal,
  required bool toolAllowed,
  required bool eligibleStructure,
  required state_core.StateSession? session,
  String? requestId,
  int? requestIndex,
}) {
  final problems = <Map<String, Object?>>[...call.issues];
  // A custom transport can provide typed rejection facts without also
  // filling the legacy issue list. Unknown provenance alone is still allowed.
  if (!call.identityComplete && call.issues.isEmpty) {
    problems.add(_stateIssue('invalid-tool-identity', '', 'The tool call has no complete unique identity.'));
  }
  if (!call.originalArgumentsStringComplete && call.issues.isEmpty) {
    problems.add(_stateIssue('incomplete-tool-arguments', '', 'The original tool argument string is not complete.'));
  }
  if (call.unsupportedEnvelope) {
    problems.add(_stateIssue('unsupported-tool-envelope', '', 'The tool call envelope is not supported.'));
  }
  if (!normal) {
    problems.add(
      _stateIssue(
        'terminal-not-normal',
        '',
        'Only a successful stop or tool_calls terminal can commit state operations.',
      ),
    );
  }
  if (!toolAllowed || session == null) {
    problems.add(
      _stateIssue('tool-not-offered', '', 'This captured request does not authorize update_state execution.'),
    );
  }
  if (!eligibleStructure) {
    problems.add(
      _stateIssue('batch-resource-limit', '', 'A response resource limit prevents every tool call in this batch.'),
    );
  }
  if (call.name != 'update_state') {
    problems.add(_stateIssue('unknown-state-tool', '', 'The state executor only accepts update_state.'));
  }
  final parameters = call.parameters;
  if (parameters != null && (parameters.length != 1 || !parameters.containsKey('ops'))) {
    problems.add(_stateIssue('tool-parameters', '', 'update_state requires exactly one ops field.'));
  }
  final execution = problems.isEmpty && call.valid && session != null && parameters != null
      ? session.apply(
          parameters['ops'],
          actor: state_core.StateActor.model,
          source: requestId == null ? 'tool:${call.index}:${call.id}' : '$requestId:tool:${call.index}:${call.id}',
        )
      : null;
  return _StagedStateCall(call, problems, execution, requestId: requestId, requestIndex: requestIndex);
}

void _stageOrdinaryStateBatchTrace(_Turn turn, _OrdinaryToolRequest request) {
  if (turn.stagedStateBatches.any((item) => item.requestId == request.snapshot.requestId)) return;
  turn.stagedStateBatches.add(
    _StagedStateBatch(
      request.snapshot.requestId,
      request.snapshot.requestIndex,
      request.batch ?? request.accumulator.finish(),
    ),
  );
}

_StagedStateCall _stageOrdinaryStateCall(
  _Turn turn,
  _OrdinaryToolRequest request,
  ModelToolCall call, {
  required bool normal,
}) {
  final previous = turn.stagedStateCalls
      .where((item) => item.requestId == request.snapshot.requestId && item.call.index == call.index)
      .firstOrNull;
  if (previous != null) return previous;
  final staged = _evaluateStateCall(
    call,
    normal: normal,
    toolAllowed: request.stateAllowed,
    eligibleStructure: (request.batch ?? request.accumulator.finish()).eligibleStructure,
    session: normal ? _ordinaryStateSession(turn) : null,
    requestId: request.snapshot.requestId,
    requestIndex: request.snapshot.requestIndex,
  );
  turn.stagedStateCalls.add(staged);
  return staged;
}

void _stageOrdinaryStateDiagnostics(_Turn turn, _OrdinaryToolRequest request, {required bool normal}) {
  _stageOrdinaryStateBatchTrace(turn, request);
  for (final call in (request.batch ?? request.accumulator.finish()).calls) {
    if (call.name != 'roll' && call.name != 'remember') {
      _stageOrdinaryStateCall(turn, request, call, normal: normal);
    }
  }
}

Map<String, Object?> _stateToolWire(_StagedStateCall staged, String status) => {
  'status': status,
  'acceptedCount': staged.execution?.acceptedCount ?? 0,
  'rejectedCount': staged.execution?.rejectedCount ?? (staged.problems.isEmpty ? 0 : 1),
  'issues': [
    for (final issue in [...staged.problems, ...?staged.execution?.issues].take(32))
      {'code': issue['code'], 'path': issue['path']},
  ],
};

_StateSettlement? _settleStateTurn(TavernEngine engine, _Turn turn, {required bool successful}) {
  final batch = turn.stateTools.finish();
  final ordinary = turn.toolOwner != null;
  if (ordinary && turn.toolRequest != null && turn.toolFailureCode == null) {
    // A transport failure can leave unprocessed calls. They are diagnostics,
    // never another opportunity to apply a staged operation.
    _stageOrdinaryStateDiagnostics(turn, turn.toolRequest!, normal: false);
  }
  final definition = turn.stateDefinition;
  if (definition == null &&
      (ordinary ? turn.stagedStateCalls.isEmpty : batch.calls.isEmpty) &&
      (ordinary ? turn.stagedStateBatches.every((item) => item.batch.issues.isEmpty) : batch.issues.isEmpty) &&
      turn.cardEventDefinition == null &&
      !_hasSecretTrace(turn)) {
    return null;
  }
  if (turn.stateSettlementStarted) throw StateError('State terminal settlement has already started.');
  turn.stateSettlementStarted = true;
  final invocation = turn.stateInvocationId ??= _newStateId();
  final before = turn.currentState;
  final input = _StateInput(before);
  final normal = successful && (turn.finishReason == 'stop' || turn.finishReason == 'tool_calls');
  state_core.StateSession? session;
  if (normal &&
      turn.stateAutomatic &&
      definition != null &&
      definition.executable &&
      input.writable &&
      turn.kind != _TurnKind.impersonate) {
    session = turn.stateSession ??= definition.startSession(
      valueExists: input.valueExists,
      value: input.value,
      runtimeExists: input.runtimeExists,
      runtime: input.runtime,
      packRuntimeExists: input.packRuntimeExists,
      packRuntime: input.packRuntime,
    );
  }
  final runs = <_StateRun>[];
  final callResults = ordinary
      ? turn.stagedStateCalls
      : [
          for (final call in batch.calls)
            _evaluateStateCall(
              call,
              normal: normal,
              toolAllowed: turn.stateToolAllowed,
              eligibleStructure: batch.eligibleStructure,
              session: session,
            ),
        ];
  // Exactly one pass after all model calls, including a normal reply with no
  // tools, thinking, or prefill. The pure layer never infers from body text.
  final eventInvocation = _cardEventInvocation(engine, turn, before, normal: normal, sharedSession: session != null);
  state_core.StateResult? result;
  state_core.CardEventResult? eventResult;
  final eventConditionIssues = <Map<String, Object?>>[];
  if (session != null && eventInvocation != null) {
    final combined = session.finishWithEvents(eventInvocation);
    result = combined.state;
    eventResult = combined.events;
  } else if (session != null) {
    result = session.finish(runRules: true);
  } else if (normal && eventInvocation != null) {
    eventConditionIssues.addAll(input.issues);
    Object? conditionState;
    if (definition != null && definition.hasSchema) {
      if (!definition.executable) {
        eventConditionIssues.add(_directorIssue('director_event_state_definition_unavailable'));
        eventConditionIssues.addAll(definition.issues);
      } else {
        eventConditionIssues.addAll(definition.validate(input.value, valueExists: input.valueExists));
        if (!input.valueExists) {
          eventConditionIssues.add(_directorIssue('director_event_state_value_unavailable'));
        }
        conditionState = input.value;
      }
    }
    if (eventConditionIssues.isEmpty) {
      eventResult = state_core.settleCardEventsEffectsOnly(eventInvocation, conditionState: conditionState);
    }
  }
  // prepare retained A's capabilities and budget, but B was committed in a
  // separate transaction. Read the actual B-to-C phase only after sealing.
  if (session != null && turn.secretPrepared != null && result != null) {
    result = session.secretTerminalPhase(turn.secretPrepared!);
  }
  final acceptedResult = result != null && result.valid ? result : null;
  final effects = acceptedResult != null
      ? _identifiedEffects(acceptedResult.effects, invocation)
      : result == null && eventResult != null && eventResult.valid
      ? _identifiedEffects(eventResult.effects, invocation)
      : <Map<String, Object?>>[];
  var next = acceptedResult == null
      ? before
      : _stateResultSnapshot(before, acceptedResult, effects, turn.stateSentPrompts);
  final events = _finishCardEventTurn(
    turn,
    before,
    next,
    eventResult,
    effects,
    normal: normal,
    sharedStateAccepted: result == null || result.valid,
    sharedSession: session != null,
    conditionIssues: eventConditionIssues,
  );
  if (events != null) {
    next = events.state;
    runs.add(_StateRun(events.runId, 'director.event_apply', events.result));
  }
  if (acceptedResult != null) {
    _stampGameplayConfig(turn.gameplay, next);
  }
  final changes = acceptedResult?.changes ?? <Map<String, Object?>>[];
  final issues = <Map<String, Object?>>[
    ...turn.statePreparationIssues,
    ...input.issues,
    if (result != null) ...result.issues,
  ];
  final elapsedMs = turn.stateWatch?.elapsedMilliseconds ?? 0;
  final common = <String, Object?>{
    'version': 1,
    'invocationId': invocation,
    'finishReason': turn.finishReason,
    if (definition != null) 'definitionFingerprint': definition.fingerprint,
    'elapsedMs': elapsedMs,
  };
  final toolSettlements = <StoredToolStateSettlement>[];
  for (final staged in callResults) {
    final call = staged.call;
    final execution = staged.execution;
    final parameters = call.parameters;
    final receipt = staged.receipt;
    final runId = receipt != null
        ? '${receipt.executionId}:state-tool'
        : staged.requestId != null
        ? '${staged.requestId}:state-diagnostic:${call.index}'
        : '$invocation:tool:${call.index}';
    runs.add(
      _StateRun(runId, 'state.tool', {
        ...common,
        if (staged.requestIndex != null) 'requestIndex': staged.requestIndex,
        'tool': {'index': call.index, 'id': call.id, 'type': call.type, 'name': call.name},
        'parameters': ?parameters,
        if (parameters == null) 'argumentsPrefix': String.fromCharCodes(call.arguments.runes.take(16384)),
        if (parameters == null) 'argumentsTruncated': call.arguments.runes.length > 16384,
        'committed': acceptedResult != null && execution != null && execution.acceptedCount > 0,
        'execution': execution?.toJson(),
        'issues': [
          ...staged.problems,
          if (!normal && !staged.problems.any((issue) => issue['code'] == 'terminal-not-normal'))
            _stateIssue('terminal-not-normal', '', 'The logical turn did not adopt model staging.'),
        ],
      }),
    );
    if (receipt != null && receipt.status == 'staged') {
      final changed = execution?.receipts.any((item) => item['accepted'] == true && item['changed'] == true) ?? false;
      final status = acceptedResult == null || execution == null
          ? 'discarded'
          : execution.acceptedCount == 0 && execution.rejectedCount > 0
          ? 'rejected'
          : changed
          ? 'committed'
          : 'completed_no_change';
      toolSettlements.add(
        StoredToolStateSettlement(
          executionId: receipt.executionId,
          status: status,
          result: _stateToolWire(staged, status),
        ),
      );
    }
  }
  if (ordinary) {
    for (final item in turn.stagedStateBatches) {
      if (item.batch.issues.isEmpty) continue;
      runs.add(
        _StateRun('${item.requestId}:state-batch', 'state.tool_batch', {
          ...common,
          'requestIndex': item.requestIndex,
          'committed': false,
          'eligibleStructure': item.batch.eligibleStructure,
          'issues': item.batch.issues,
        }),
      );
    }
  } else if (batch.issues.isNotEmpty) {
    runs.add(
      _StateRun('$invocation:batch', 'state.tool_batch', {
        ...common,
        'committed': false,
        'eligibleStructure': batch.eligibleStructure,
        'issues': batch.issues,
      }),
    );
  }
  if (result != null) {
    runs.add(
      _StateRun('$invocation:rules', 'state.rules', {
        ...common,
        'committed': acceptedResult != null,
        'receipts': [
          for (final receipt in result.receipts)
            if (receipt['actor'] != 'model') receipt,
        ],
        'changes': changes,
        'effects': effects,
        'issues': result.issues,
      }),
    );
  }
  final stateOwn = acceptedResult == null ? null : _stateOwnAudit(invocation, changes, effects, issues);
  return _StateSettlement(
    state: next,
    runs: runs,
    events: events,
    toolSettlements: toolSettlements,
    ownAudit: stateOwn == null && events?.ownAudit == null ? null : {...?stateOwn, ...?events?.ownAudit},
    trace: {
      ..._statePreparationTrace(turn),
      'invocationId': invocation,
      'normalTerminal': normal,
      'rulesInvoked': result != null,
      'stateCommitted': acceptedResult != null,
      'changes': changes,
      'effects': effects,
      'issues': issues,
      'runIds': [for (final run in runs) run.id],
      'elapsedMs': elapsedMs,
    },
  );
}

_StateSettlement? _failedStateSettlement(TavernEngine engine, _Turn turn, TavernTurnInspection inspection) {
  if (turn.stateRunsWritten) return null;
  final attempt = turn.stateAttempt ??= turn.stateSettlementStarted
      ? _interruptedStateSettlement(turn)
      : _settleStateTurn(engine, turn, successful: false);
  if (attempt == null) return null;
  final events = _failedCardEventSettlement(turn, attempt.events, inspection);
  return _StateSettlement(
    state: turn.currentState,
    events: events,
    runs: [
      for (final run in attempt.runs)
        if (events != null && run.id == events.runId)
          _StateRun(run.id, run.kind, events.result)
        else
          _StateRun(run.id, run.kind, {
            ..._copy(run.result),
            'committed': false,
            'failure': inspection.failure?.name,
            'detail': inspection.detail,
            'outcome': 'not-committed',
          }),
    ],
    trace: {
      ..._copy(attempt.trace),
      'stateCommitted': false,
      'outcome': 'not-committed',
      'changes': <Object?>[],
      'effects': <Object?>[],
    },
  );
}

/// An exception before finish returns must not reopen the retained session.
/// This receipt records only that interruption, never a second rule pass.
_StateSettlement _interruptedStateSettlement(_Turn turn) {
  final invocation = turn.stateInvocationId ??= _newStateId();
  final issue = _stateIssue(
    'terminal-interrupted',
    '',
    'State terminal settlement began but did not produce a candidate.',
  );
  return _StateSettlement(
    state: turn.currentState,
    runs: [
      _StateRun('$invocation:terminal', 'state.terminal', {
        'version': 1,
        'invocationId': invocation,
        'committed': false,
        'issues': [issue],
      }),
    ],
    trace: {
      ..._statePreparationTrace(turn),
      'invocationId': invocation,
      'stateCommitted': false,
      'outcome': 'interrupted',
      'issues': [issue],
    },
  );
}

void _writeStateRuns(ChatStore store, _Turn turn, _StateSettlement? settlement, String? nodeId) {
  if (settlement == null || turn.stateRunsWritten) return;
  final usage = turn.inspection.reportedUsage;
  final usageJson = usage == null
      ? null
      : <String, Object?>{
          'promptTokens': usage.promptTokens,
          'cacheHitTokens': usage.cacheHitTokens,
          'completionTokens': usage.completionTokens,
          'model': usage.model,
        };
  for (final run in settlement.runs) {
    store.writeAgentRun(
      StoredAgentRun(
        id: run.id,
        chatId: turn.chat.id,
        nodeId: nodeId,
        kind: run.kind,
        at: turn.at,
        usage: usageJson,
        result: run.result,
      ),
    );
  }
}
