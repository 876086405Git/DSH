// Private /gen and /genraw adaptation of SillyTavern
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// These are engine-private flavors. Public B2 request shapes and decoding do
// not select them, and the original hot record owns acceptance and transport.
part of 'engine.dart';

class _SlashGenerationSpec {
  _SlashGenerationSpec(
    this.invocation, {
    required this.raw,
    required this.prompt,
    required this.system,
    required this.prefill,
    required this.quietToLoud,
    required this.trimNames,
    required this.trimToSentence,
    required this.ephemeralStops,
    this.maxTokens,
    this.speakerCharacterId,
    this.quietName,
  });
  final _SlashInvocation invocation;
  final bool raw, quietToLoud, trimNames, trimToSentence;
  final String prompt, system, prefill;
  final List<String> ephemeralStops;
  final num? maxTokens;
  final String? speakerCharacterId, quietName;
  late final _SlashOutputPolicy outputPolicy;
  _ScriptGenerationCapture? captured;
  _ScriptPreparedGeneration? prepared;
  final _adopted = <String>{};
  bool _terminalObserved = false;

  _SlashExecutionOwner get owner => invocation.owner;
  // D-B3-COMPOSER-INPUT-01: this input slot is neither a host composer read
  // nor an alias for the explicit quiet/raw prompt.
  TavernScriptGenerateRequest get request => TavernScriptGenerateRequest(
    speakerCharacterId: speakerCharacterId,
    userInput: '',
    stream: false,
    includeReasoning: false,
  );

  TavernJsonObject _childTarget(_ScriptGenerationRecord child) => {
    'generationId': child.id,
    'contextId': child.context.value.id,
    'instanceId': child.context.value.instanceId,
  };

  void _generationFact(
    _ScriptGenerationRecord child,
    TavernSlashEffectState state,
    TavernSlashEffectStage stage, {
    TavernJsonObject details = const {},
  }) {
    owner.recordEffect(
      kind: TavernSlashEffectKind.backgroundGeneration,
      state: state,
      stage: stage,
      operation: 'generate',
      target: _childTarget(child),
      sourceSpan: invocation.sourceSpan,
      details: {'flavor': raw ? 'slashRaw' : 'slashQuiet', ...details},
    );
  }

  void observeHostOutcome(Object request, List<TavernScriptIssue> issues, bool committed) {
    owner.observeIssues(issues, committed: committed, observationKey: request);
  }

  void onRequested(_ScriptGenerationRecord child) =>
      _generationFact(child, TavernSlashEffectState.requested, TavernSlashEffectStage.preparation);

  void onPreparationAccepted(_ScriptGenerationRecord child, _ScriptPreparedGeneration prepared) {
    this.prepared = prepared;
    // Real host receptions already own their observation keys. This is only
    // propagation of the child's existing public aggregation.
    owner.observeIssues(child.hookIssues);
    _generationFact(
      child,
      TavernSlashEffectState.accepted,
      TavernSlashEffectStage.preparation,
      details: {'budgetSource': child.receipt.budgetSource},
    );
    for (final claimed in child.receipt.claimedInjectionVersions) {
      final source = claimed['sourceRef'];
      if (source is! Map<String, Object?>) {
        throw StateError('A claimed injection must retain its actual sourceRef.');
      }
      owner.recordEffect(
        kind: TavernSlashEffectKind.injection,
        state: TavernSlashEffectState.adopted,
        stage: TavernSlashEffectStage.preparation,
        operation: 'claim',
        target: {'sourceRef': source},
        committed: true,
        version: source['registrationVersion'] as String?,
        sourceSpan: invocation.sourceSpan,
        details: {'generationId': child.id},
      );
    }
  }

  Iterable<(String, TavernJsonObject)> _storageTargets(String carrier) sync* {
    final capture = captured;
    if (capture == null) return;
    if (carrier == 'global' && capture.global.hasIntents) {
      yield (
        'global',
        {
          'kind': 'variables',
          'target': {'scope': 'global'},
        },
      );
    } else if (carrier == 'chat') {
      final chatId = capture.chat?.id;
      if (chatId == null) return;
      final targets = prepared?.chatTargets ?? {if (capture.local.hasIntents) 'local'};
      for (final field in targets) {
        if (field == 'local') {
          yield (
            field,
            {
              'kind': 'variables',
              'target': {'scope': 'chat', 'chatId': chatId},
            },
          );
        } else if (field == 'stChatIdHash') {
          yield (field, {'kind': 'stChatIdHash', 'chatId': chatId});
        } else {
          yield (field, {'kind': 'chatState', 'chatId': chatId});
        }
      }
    }
  }

  void onCarrierStarted(_ScriptGenerationRecord child, String targetKind) {
    for (final (field, target) in _storageTargets(targetKind)) {
      owner.recordEffect(
        kind: TavernSlashEffectKind.storage,
        state: TavernSlashEffectState.started,
        stage: TavernSlashEffectStage.preparation,
        operation: 'generate',
        target: target,
        sourceSpan: invocation.sourceSpan,
        details: {'generationId': child.id, 'field': field, 'carrier': targetKind == 'global' ? 'global' : 'sql'},
      );
    }
  }

  void onCarrierAdopted(_ScriptGenerationRecord child, _ScriptCarrierAdoption adoption) {
    for (final (field, target) in _storageTargets(adoption.targetKind)) {
      if (!adoption.targetVersions.containsKey(field)) continue;
      _adopted.add(field);
      owner.recordEffect(
        kind: TavernSlashEffectKind.storage,
        state: TavernSlashEffectState.adopted,
        stage: TavernSlashEffectStage.preparation,
        operation: 'generate',
        target: target,
        committed: true,
        version: adoption.targetVersions[field],
        sourceSpan: invocation.sourceSpan,
        details: {
          'generationId': child.id,
          'field': field,
          'carrier': adoption.targetKind == 'global'
              ? adoption.status == 'adopted'
                    ? 'runtime'
                    : 'file'
              : 'sql',
          'nodeId': ?adoption.nodeId,
          'runtimeVersion': ?adoption.runtimeVersion,
        },
      );
    }
  }

  /// Invoked only from the actual production client.send call boundary.
  /// It reports an invocation, not server receipt or a billable response.
  void onModelStarted(_ScriptGenerationRecord child, int attempt) => _generationFact(
    child,
    TavernSlashEffectState.started,
    TavernSlashEffectStage.model,
    details: {'attempt': attempt},
  );

  void onChildTerminal(_ScriptGenerationRecord child, {TavernScriptException? error}) {
    if (_terminalObserved) return;
    _terminalObserved = true;
    owner.observeIssues(child.hookIssues, committed: child.committed);
    if (error != null) owner.observeIssues(error.issues, committed: error.committed);
    final receipt = child.receipt;
    final failed = receipt.failedTarget;
    if (failed != null) {
      for (final (field, target) in _storageTargets(failed)) {
        if (_adopted.contains(field)) continue;
        owner.recordEffect(
          kind: TavernSlashEffectKind.storage,
          state: TavernSlashEffectState.failed,
          stage: TavernSlashEffectStage.preparation,
          operation: 'generate',
          target: target,
          sourceSpan: invocation.sourceSpan,
          details: {'generationId': child.id, 'field': field, if (error != null) 'code': error.code.name},
        );
      }
    }
    for (final skipped in receipt.skippedTargets) {
      final carrier = skipped['targetKind'];
      if (carrier is! String) continue;
      for (final (field, target) in _storageTargets(carrier)) {
        if (_adopted.contains(field)) continue;
        owner.recordEffect(
          kind: TavernSlashEffectKind.storage,
          state: TavernSlashEffectState.skipped,
          stage: TavernSlashEffectStage.preparation,
          operation: 'generate',
          target: target,
          sourceSpan: invocation.sourceSpan,
          details: {'generationId': child.id, 'field': field, 'reason': skipped['reason']},
        );
      }
    }
    final phase = receipt.phase == 'key' || receipt.phase == 'model'
        ? TavernSlashEffectStage.model
        : TavernSlashEffectStage.preparation;
    _generationFact(
      child,
      error == null
          ? TavernSlashEffectState.completed
          : error.code == TavernScriptErrorCode.cancelled
          ? TavernSlashEffectState.cancelled
          : TavernSlashEffectState.failed,
      error == null ? TavernSlashEffectStage.model : phase,
      details: {'preparation': receipt.details(error?.code.name ?? 'completed')},
    );
  }

  void applyWireOptions(Map<String, Object?> body, TavernModelConfig config) {
    body['stream'] = false;
    if (maxTokens != null) body['max_tokens'] = maxTokens;
    if (config.deepseek) {
      body['thinking'] = {'type': config.thinking ? 'enabled' : 'disabled'};
      if (!config.thinking) body.remove('reasoning_effort');
    }
  }
}

extension _SlashGenerationOperations on _ScriptCoordinator {
  Future<String> _executeSlashGeneration(_SlashInvocation invocation) async {
    final owner = invocation.owner;
    owner.checkAlive();
    final raw = invocation.command == 'genraw';
    final prompt = _slashBody(invocation);
    if (raw && prompt.isEmpty) return '';

    // The language layer already rejected unknown options before their AST
    // effects. Validate only this non-early-return handler's actual arguments.
    final named = <String, String>{
      for (final key in invocation.named.keys) key: _slashString(invocation, invocation.argument(key), key),
    };
    final variableKeys = raw ? const ['system', 'prefill', 'length', 'stop'] : const ['length', 'stop'];
    final needsVariables = variableKeys.any(named.containsKey);
    final values = needsVariables
        ? await _readSlashVariables(owner, chat: owner.context.value.chatId != null, global: true)
        : const _SlashVariablePair();
    owner.checkAlive();
    Object? resolve(String key) {
      final text = named[key]!;
      final chat = values.chat;
      if (chat != null && chat.containsKey(text)) return ScriptCoercion.variable(chat[text]);
      final global = values.global;
      if (global != null && global.containsKey(text)) return ScriptCoercion.variable(global[text]);
      return text;
    }

    String optionalText(String key) {
      if (!named.containsKey(key)) return '';
      final value = resolve(key);
      if (!ScriptCoercion.truthy(value)) return '';
      return _slashString(invocation, value, key);
    }

    num? maxTokens;
    if (named.containsKey('length')) {
      final number = ScriptCoercion.number(resolve('length'));
      if (!number.isNaN && !number.isFinite) {
        throw _slashArgument(invocation, 'length', 'The response length must be finite.');
      }
      if (!number.isNaN && number > 0) {
        if (number != number.truncateToDouble()) {
          throw _slashArgument(invocation, 'length', 'A positive response length must be an integer.');
        }
        // Keep Number semantics without silently clamping a large finite
        // integral double to the platform's signed integer range.
        final integer = number.toInt();
        maxTokens = integer.toDouble() == number ? integer : number;
      }
    }
    final stops = <String>[];
    if (named.containsKey('stop')) {
      final value = resolve('stop');
      if (value != '') {
        final source = _slashString(invocation, value, 'stop');
        Object? parsed;
        try {
          parsed = jsonDecode(source);
        } on FormatException {
          throw _slashArgument(invocation, 'stop', 'Expected a JSON array of stopping strings.');
        }
        if (parsed is! List<Object?> || parsed.any((item) => item is! String)) {
          throw _slashArgument(invocation, 'stop', 'Expected a JSON array containing only strings.');
        }
        final seen = <String>{};
        for (final item in parsed.cast<String>()) {
          if (item.isNotEmpty && seen.add(item)) stops.add(item);
        }
      }
    }
    final quietName = raw ? null : named['name'];
    final speaker = quietName == null || quietName.isEmpty ? null : await _slashGenerationActor(invocation, quietName);
    owner.checkAlive();
    final spec = _SlashGenerationSpec(
      invocation,
      raw: raw,
      prompt: prompt,
      system: raw ? optionalText('system') : '',
      prefill: raw ? optionalText('prefill') : '',
      quietToLoud: named['as'] == 'char',
      trimNames: !ScriptCoercion.falseBoolean(named['trim'] ?? ''),
      trimToSentence: !raw && ScriptCoercion.trueBoolean(named['trim'] ?? ''),
      maxTokens: maxTokens,
      speakerCharacterId: speaker,
      quietName: quietName,
      ephemeralStops: List.unmodifiable(stops),
    );
    // CC instruct is an accepted spelling with no TC selector. Its value was
    // validated as a String, and no metadata default is injected.
    final lock = ScriptCoercion.trueBoolean(named['lock'] ?? '');
    _SlashGenerationLease? lease;
    try {
      if (lock) lease = await _acquireSlashLease(invocation);
      owner.checkAlive();
      final child = _startSlashGeneration(owner, spec);
      late final TavernScriptGenerationResult decoded;
      owner.record.waiting(TavernSlashWaitKind.generation);
      try {
        // Stop owns this record, and the record's cancellation drains already
        // started input carriers. Do not race it with an earlier Slash terminal.
        decoded = await child.result;
        spec.onChildTerminal(child);
        owner.partialGeneration = decoded;
      } on TavernScriptException catch (error) {
        spec.onChildTerminal(child, error: error);
        rethrow;
      } finally {
        owner.children.remove(child);
        if (!owner.terminal) owner.record.status = TavernSlashStatus.running;
      }
      owner.checkAlive();
      final output = await _finishSlashGenerationOutput(invocation, child, decoded);
      owner.checkAlive();
      if (lease != null) await _releaseSlashLease(lease);
      owner.checkAlive();
      return output;
    } catch (error) {
      if (error is TavernScriptException) {
        owner.observeIssues(error.issues, committed: error.committed);
      }
      if (lease != null) _cleanupSlashLease(lease);
      rethrow;
    }
  }

  /// Nonempty gen.name resolves one actual stable identity. A miss retains the
  /// label/current actor, while ambiguity cannot silently pick a first card.
  Future<String?> _slashGenerationActor(_SlashInvocation invocation, String name) => _bridgeOperation(() async {
    final owner = invocation.owner;
    owner.checkAlive();
    final chatId = owner.context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final metadata = chat == null ? <String, Object?>{} : engine._chatCodec.metadataForNode(engine._store, chat.id);
    final settings = _runtimeCopy(engine._effectiveSettings(chat, metadata));
    final currentActor =
        owner.context.value.characterId ??
        (chat != null && engine._store.groupChat(chat.id) == null ? chat.characterId : null);
    final found = await engine._libraryOperation(() async {
      final cards = await engine._characterSummaries();
      owner.checkAlive();
      final matches = <String>{};
      for (final card in cards) {
        final identity = _map(_map(settings['characterIdentities'])[card.id]);
        if (card.id == currentActor) identity.addAll(_map(settings['characterIdentity']));
        final avatar = identity['avatarFilename'];
        if (card.id == name || card.name == name || avatar == name) matches.add(card.id);
      }
      if (matches.length > 1) {
        throw _slashArgument(
          invocation,
          'name',
          'The character name is ambiguous.',
          code: TavernScriptErrorCode.ambiguousName,
        );
      }
      return matches.firstOrNull;
    });
    owner.checkAlive();
    return found;
  });

  _ScriptGenerationRecord _startSlashGeneration(_SlashExecutionOwner owner, _SlashGenerationSpec spec) {
    owner.checkAlive();
    final context = _context(owner.context.value.id);
    if (!identical(context, owner.context)) {
      throw _slashArgument(
        spec.invocation,
        'context',
        'The execution context was replaced.',
        code: TavernScriptErrorCode.cancelled,
      );
    }
    if (!spec.raw && context.value.chatId == null) {
      throw _slashArgument(
        spec.invocation,
        'context',
        'Quiet generation requires a chat.',
        code: TavernScriptErrorCode.noContext,
      );
    }
    final request = _captureGenerationRequest(spec.request);
    final config = engine._config;
    final suffix = _newStateId();
    final id = 'background-$suffix';
    if (_generations.containsKey(id)) {
      throw _slashArgument(
        spec.invocation,
        'generationId',
        'The generated identity is already active.',
        code: TavernScriptErrorCode.duplicateId,
      );
    }
    final child = _ScriptGenerationRecord(
      this,
      id,
      context,
      request,
      TavernModelConfig(
        apiKey: config.apiKey,
        baseUrl: config.baseUrl,
        model: config.model,
        deepseek: config.deepseek,
        thinking: config.thinking,
        headers: config.headers,
        auxiliary: config.auxiliary,
      ),
      engine._clock(),
      slashSpec: spec,
    );
    _generations[id] = child;
    owner.children.add(child);
    spec.onRequested(child);
    // The existing hot runner synchronously acquires preparation ownership.
    // This is the only starter; observers never instantiate or run another one.
    unawaited(_runGeneration(child));
    return child;
  }

  Future<_ScriptGenerationCapture> _captureSlashGeneration(_ScriptGenerationRecord record) async {
    final spec = record.slashSpec!;
    final capture = await _captureGeneration(
      record,
      includeInjections: !spec.raw,
      needsOverride: spec.raw ? const _ScriptGenerationNeeds(history: true, card: true) : null,
    );
    record.cancellation.check();
    spec.captured = capture;
    spec.outputPolicy = _SlashOutputPolicy.capture(capture);
    return capture;
  }

  Future<_ScriptPreparedGeneration> _prepareSlashGeneration(
    _ScriptGenerationRecord record,
    _ScriptGenerationCapture capture,
  ) async {
    final spec = record.slashSpec!;
    final _ScriptPreparedGeneration prepared;
    if (!spec.raw) {
      prepared = await prepareGeneration(
        capture,
        record.cancellation,
        quiet: _SlashQuietPreparation(spec),
        spreset: record.spreset,
        onPhase: (phase) {
          record.receipt.phase = phase;
        },
        onBudgetSource: (source) {
          record.receipt.budgetSource = source;
        },
      );
    } else {
      record.receipt.phase = 'assemble';
      // The raw CC helper does no local truncation or budget gate. Its selected
      // preset still supplies parameter and macro reference values.
      record.receipt.budgetSource = 'none';
      prepared = _prepareSlashRaw(record, capture);
    }
    spec.prepared = prepared;
    return prepared;
  }
}

class _SlashQuietPreparation {
  _SlashQuietPreparation(this.spec);
  final _SlashGenerationSpec spec;
  String quietPrompt = '', bias = '', scanText = '';
  _SlashOutputPolicy get policy => spec.outputPolicy;

  void checkSources(_ScriptGenerationCapture capture) {
    if (capture.chat == null) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'generate',
        'Quiet generation requires a captured chat.',
        contextId: capture.context.value.id,
      );
    }
  }

  void prepareLeading(_ScriptPromptRun run) {
    final environment = run.environment;
    if (spec.prompt.isNotEmpty) quietPrompt = environment.expand(spec.prompt, const {});
    var selected = policy.cleanup.userPromptBias;
    for (final node in run.capture.history.reversed) {
      final message = node.message;
      if (message.role != TavernRole.user &&
          message.role != TavernRole.system &&
          message.role != TavernRole.narrator &&
          !message.hidden) {
        continue;
      }
      final value = node.extra['bias'];
      if (value != null && value is! String) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'generate',
          'The selected history bias must be a string or null.',
          contextId: run.capture.context.value.id,
          fieldPath: 'history.extra.bias',
        );
      }
      if (value is String && trimJsWhitespace(value).isNotEmpty) selected = value;
      break;
    }
    bias = selected.isEmpty ? '' : environment.expand(selected, const {});
  }

  String baseExpand(_ScriptPromptRun run, String text, Map<String, String> overrides) {
    var value = run.environment.baseExpand(text, overrides);
    if (policy.cleanup.collapseNewlines) value = stCollapseNewlines(value);
    return value;
  }

  PreparedCharacterFields prepareFields(_ScriptPromptRun run) => prepareCharacterFields(
    _SlashQuietCardFields(run),
    persona: run.environment.persona,
    expand: (text, overrides) => baseExpand(run, text, overrides),
  );

  void prepareWorldScan(_ScriptPromptRun run) {
    // Fixed M4623 -> WI4721 -> M3274: this is a separate substitute of the
    // Generate-stage value. PM later receives quietPrompt, never scanText.
    scanText = quietPrompt.isEmpty ? '' : run.environment.expand(quietPrompt, const {});
  }

  List<String> wireStops(_ScriptPromptRun run) => policy.stoppingStrings(run.environment, spec.ephemeralStops);
}

/// Observes only real eager-field reads. A real settings override supplies its
/// own source, while an unknown card field is not fabricated from an empty map.
class _SlashQuietCardFields extends MapBase<String, Object?> {
  _SlashQuietCardFields(this.run);
  final _ScriptPromptRun run;
  @override
  Object? operator [](Object? key) {
    if (key is! String) return null;
    const overrides = {
      'system_prompt': 'systemPromptOverride',
      'scenario': 'scenarioOverride',
      'mes_example': 'mesExamplesOverride',
    };
    final override = overrides[key];
    final value = override == null ? null : run.settings[override];
    if (value is String && value.isNotEmpty) return value;
    run._observeCharacterDependency(key);
    return run.card[key];
  }

  @override
  Iterable<String> get keys => run.card.keys;
  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('Read-only captured card fields.');
  @override
  Object? remove(Object? key) => throw UnsupportedError('Read-only captured card fields.');
  @override
  void clear() => throw UnsupportedError('Read-only captured card fields.');
}

class _SlashRawInputDependencies {
  _SlashRawInputDependencies(this.capture);
  final _ScriptGenerationCapture capture;
  final local = _ScriptUnavailableVariables();
  final history = _ScriptUnavailableHistory();
  String? _characterField;

  void observeCharacter(String field) {
    if (capture.actorId != null) return;
    _characterField ??= field;
    check();
  }

  void check() {
    final missing = local.accessed
        ? 'local-variable macro'
        : history.accessed
        ? 'history macro'
        : _characterField;
    if (missing == null) return;
    throw _scriptError(
      TavernScriptErrorCode.noContext,
      'generate',
      'The requested source "$missing" has no captured context.',
      contextId: capture.context.value.id,
    );
  }
}

extension _SlashRawGenerationPreparation on _ScriptCoordinator {
  _ScriptPreparedGeneration _prepareSlashRaw(_ScriptGenerationRecord record, _ScriptGenerationCapture capture) {
    final spec = record.slashSpec!;
    final dependencies = _SlashRawInputDependencies(capture);
    final preset = capture.promptPreset;
    if (preset == null) {
      throw StateError('A Slash raw request must capture its effective CC parameter preset.');
    }
    final initialHash = _finiteNumber(capture.metadata['chat_id_hash']);
    final environment = _MacroEnvironment(
      capture.card,
      capture.settings,
      capture.chat == null ? dependencies.local : capture.local,
      capture.global,
      capture.history,
      capture.config,
      capture.at,
      engine._random,
      capture.chat == null
          ? ''
          : _macroChatIdentity(
              capture.chat!,
              capture.state,
              capture.metadata,
              capture.state['chatJsonlSourceFile'] as String?,
              node: capture.history.lastOrNull,
            ),
      // D-B3-COMPOSER-INPUT-01: no host composer snapshot, no prompt alias.
      '',
      'normal',
      chatIdHash: initialHash,
      pickRerollSeed: capture.metadata['pick_reroll_seed'],
      characterId: capture.actorId ?? '',
      groupNames: capture.groupView?.names,
      groupNotMuted: capture.groupView?.enabledNames,
      preset: preset,
      regexPresetSettings: capture.contextRegexPresetSettings,
      gameplayCapture: capture.gameplayCapture,
      messageVariables: capture.state['messageVariables'],
      messageVariablesExists: capture.state.containsKey('messageVariables'),
      macroHistory: capture.chat == null ? dependencies.history : null,
      onCharacterDependency: capture.actorId == null ? dependencies.observeCharacter : null,
      collapseNewlinesOverride: spec.outputPolicy.cleanup.collapseNewlines,
      // This is an ordinary Slash substitute, not public B2 raw's lazy flavor.
      prepareCharacterFieldsOnDemand: false,
    );
    try {
      record.cancellation.check();
      final originalUser = trimJsWhitespace(spec.prompt);
      String expand(String text) => text.isEmpty ? '' : environment.expand(text, const {});
      // Evaluation order is prefill -> user -> system, not wire order.
      final prefill = expand(spec.prefill);
      final user = expand(originalUser);
      final String? system = spec.system.isEmpty ? null : trimJsWhitespace(expand(spec.system));
      final messages = <PromptSegment>[];
      void add(String role, String content, String id) {
        final message = <String, Object?>{'role': role, 'content': content};
        messages.add(
          PromptSegment(
            id: id,
            message: message,
            sources: [PromptSource('slashRaw', id)],
            tokens: engine._counter.countMessage(message),
          ),
        );
      }

      if (system != null) add('system', system, 'slashRawSystem');
      add('user', user, 'slashRawUser');
      if (prefill.isNotEmpty) add('assistant', prefill, 'slashRawPrefill');
      final converted = convertExplicitPromptMessages(
        messages,
        deepseek: capture.config.deepseek,
        userName: environment.userName,
        characterName: capture.actorId == null ? '' : _string(capture.card['name']),
        groupNames: capture.groupView?.names ?? const [],
        counter: engine._counter,
      );
      final stops = spec.outputPolicy.stoppingStrings(environment, spec.ephemeralStops);
      final body = explicitPromptRequestBody(
        messages: converted,
        settings: preset.settings,
        deepseek: capture.config.deepseek,
        model: capture.config.model,
        preparedStops: stops,
      );
      spec.applyWireOptions(body, capture.config);
      dependencies.check();
      record.cancellation.check();
      return _ScriptPreparedGeneration(
        capture: capture,
        body: body,
        budgetSource: 'none',
        injectionUses: _ScriptInjectionUseSet(const <_ScriptInjectionCandidate>[]),
        stChatIdHash: environment.chatIdHash,
        hasHashUpdate: capture.chat != null && environment.chatIdHash != initialHash,
      );
    } catch (_) {
      dependencies.check();
      rethrow;
    }
  }
}
