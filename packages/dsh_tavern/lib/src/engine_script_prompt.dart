part of 'engine.dart';

extension _ScriptPromptPreparation on _ScriptCoordinator {
  /// Capture dependencies before a host filter may change a write target.
  /// The flags are conservative for macro-capable resources; literal parts
  /// never introduce a dependency, including literal text containing macros.
  _ScriptGenerationNeeds generationNeeds(
    TavernScriptGenerateRequest request,
    List<_ScriptInjectionCandidate> candidates,
  ) {
    if (request is! TavernScriptRawRequest) {
      return const _ScriptGenerationNeeds(history: true, card: true, worldInfo: true);
    }
    final kinds = {
      for (final part in request.orderedPrompts)
        if (part is TavernScriptPromptPlaceholderPart) part.kind,
    };
    final overrides = request.overrides.fields;
    var history = false;
    var card = false;
    var worldInfo = false;
    for (final kind in kinds) {
      final key = kind.name;
      if (kind == TavernScriptPromptPlaceholder.chatHistory) {
        if (overrides['withDepthEntries'] != false) worldInfo = true;
        final rows = overrides['chatHistory'];
        if (request.maxChatHistory != 0 && (rows == null || (rows as List<Object?>).isNotEmpty)) {
          history = true;
          card = true;
        }
        if (overrides['authorNote'] != '') {
          // The current author's note may need a macro environment or scan.
          history = true;
          card = true;
        }
      } else if (kind == TavernScriptPromptPlaceholder.worldInfoBefore ||
          kind == TavernScriptPromptPlaceholder.worldInfoAfter) {
        if (!overrides.containsKey(key)) {
          worldInfo = true;
        } else if (overrides[key] != '') {
          history = true;
          card = true;
        }
      } else if (kind == TavernScriptPromptPlaceholder.userInput) {
        if (request.userInput.isNotEmpty) {
          history = true;
          card = true;
        }
      } else if (!overrides.containsKey(key) || overrides[key] != '') {
        history = true;
        card = true;
      }
    }
    for (final candidate in candidates) {
      final injection = candidate.injection;
      if (injection == null) continue;
      if (injection.scan == true) worldInfo = true;
      if (injection.content.isNotEmpty &&
          (injection.scan == true || injection.position != TavernScriptInjectionPosition.scanOnly)) {
        history = true;
        card = true;
      }
    }
    return _ScriptGenerationNeeds(history: history || worldInfo, card: card || worldInfo, worldInfo: worldInfo);
  }

  Future<_ScriptPreparedGeneration> prepareGeneration(
    _ScriptGenerationCapture capture,
    ModelCancellation cancellation, {
    void Function(String)? onBudgetSource,
    void Function(String)? onPhase,
    _SlashQuietPreparation? quiet,
  }) async {
    onPhase?.call('capture');
    if (capture.config.deepseek && capture.request.samplingOverrides.containsKey('seed')) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'generate',
        'The production DeepSeek path does not send a seed override.',
        fieldPath: 'samplingOverrides.seed',
      );
    }
    for (final injection in capture.request.injects) {
      injectionRegistry.validateCallbackOwner(injection, capture.context);
    }
    if (quiet == null) {
      _scriptCheckPromptSources(capture);
    } else {
      quiet.checkSources(capture);
    }
    final worldBooks = await _scriptCaptureWorldBooks(this, capture, cancellation);
    onPhase?.call('filter');
    final uses = await injectionRegistry.filter(
      capture.injectionCandidates,
      generationId: capture.generationId,
      cancellation: cancellation,
      onObservedIssues: quiet?.spec.observeHostOutcome,
    );
    try {
      cancellation.check();
      onPhase?.call('assemble');
      final run = _ScriptPromptRun(this, capture, cancellation, uses, worldBooks, quiet: quiet);
      onBudgetSource?.call(run.budgetSource);
      try {
        return await run.prepare();
      } catch (_) {
        run.checkCharacterDependency();
        rethrow;
      }
    } on TavernScriptException catch (error) {
      final known = <TavernScriptIssue>[...uses.hookIssues];
      for (final issue in error.issues) {
        if (!known.contains(issue)) known.add(issue);
      }
      throw TavernScriptException(
        code: error.code,
        operation: error.operation,
        message: error.message,
        contextId: error.contextId ?? capture.context.value.id,
        generationId: error.generationId ?? capture.generationId,
        fieldPath: error.fieldPath,
        committed: error.committed,
        modelFailure: error.modelFailure,
        issues: known,
      );
    } on PromptBudgetExceeded {
      throw TavernScriptException(
        code: TavernScriptErrorCode.model,
        operation: 'generate',
        message: 'The prepared prompt exceeds its selected preset budget.',
        contextId: capture.context.value.id,
        generationId: capture.generationId,
        modelFailure: TavernFailure.contextTooLong,
        issues: uses.hookIssues,
      );
    } on TavernModelException catch (error) {
      throw TavernScriptException(
        code: error.kind == TavernFailure.cancelled ? TavernScriptErrorCode.cancelled : TavernScriptErrorCode.model,
        operation: 'generate',
        message: error.detail,
        modelFailure: error.kind,
        contextId: capture.context.value.id,
        generationId: capture.generationId,
        issues: uses.hookIssues,
      );
    } catch (error) {
      final failure = _scriptFailure(error);
      throw TavernScriptException(
        code: failure.code,
        operation: 'generate',
        message: failure.message,
        contextId: capture.context.value.id,
        generationId: capture.generationId,
        modelFailure: failure.modelFailure,
        issues: [...uses.hookIssues, ...failure.issues],
      );
    }
  }
}

/// Read once before host filters. A read failure belongs only to a request
/// which ultimately consumes this source; a false filter can exclude its WI
/// dependency without converting an unused book's failure into a new failure.
class _ScriptWorldBooksSnapshot {
  _ScriptWorldBooksSnapshot.loaded(this.books, {this.resources = const _GameplayResources()})
    : error = null,
      stack = null;
  _ScriptWorldBooksSnapshot.failed(this.error, this.stack) : books = const [], resources = const _GameplayResources();
  final List<WorldInfoBook> books;
  final _GameplayResources resources;
  final Object? error;
  final StackTrace? stack;
  List<WorldInfoBook> read() {
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
    return books;
  }
}

Future<_ScriptWorldBooksSnapshot?> _scriptCaptureWorldBooks(
  _ScriptCoordinator owner,
  _ScriptGenerationCapture capture,
  ModelCancellation cancellation,
) async {
  final request = capture.request;
  var needed = request is! TavernScriptRawRequest;
  if (request is TavernScriptRawRequest) {
    final kinds = {
      for (final part in request.orderedPrompts)
        if (part is TavernScriptPromptPlaceholderPart) part.kind,
    };
    final overrides = request.overrides.fields;
    final history = kinds.contains(TavernScriptPromptPlaceholder.chatHistory);
    final note = _map(capture.settings['authorNote']);
    final interval = note['interval'];
    final users = capture.history.where((node) => node.message.role == TavernRole.user).length;
    final noteDue =
        interval == null || interval == 1 || (interval is num && interval > 0 && users > 0 && users % interval == 0);
    needed =
        (history && overrides['withDepthEntries'] != false) ||
        (kinds.contains(TavernScriptPromptPlaceholder.worldInfoBefore) && !overrides.containsKey('worldInfoBefore')) ||
        (kinds.contains(TavernScriptPromptPlaceholder.worldInfoAfter) && !overrides.containsKey('worldInfoAfter')) ||
        capture.injectionCandidates.any((candidate) => candidate.injection?.scan == true) ||
        (history && note['enabled'] != false && note['scan'] == true && noteDue);
  }
  if (!needed) return null;
  try {
    cancellation.check();
    if (capture.chat == null || !capture.capturedChatState) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'generate',
        'The requested worldInfo source has no captured chat.',
        contextId: capture.context.value.id,
      );
    }
    final activeWorldName = capture.metadata['world_info'];
    final activeBookId = activeWorldName is String
        ? _map(capture.chat!.settings['stLorebookIds'])[activeWorldName]
        : null;
    final gameplayCapture = capture.gameplayCapture;
    final resources = gameplayCapture == null
        ? const _GameplayResources()
        : _resolveGameplayResources(
            gameplayCapture,
            capture.settings,
            actorId: capture.actorId,
            kinds: const {'lorebook'},
          );
    final books = await cancellation.wait(
      owner.engine._trackOperation(
        owner.engine._loadBooks(
          capture.actorId ?? '',
          capture.card,
          capture.settings,
          group: capture.groupView,
          personaId: capture.personaId,
          gameplayResources: resources,
          stWorldNames: {if (activeWorldName is String && activeBookId is String) activeBookId: activeWorldName},
          checkCancelled: cancellation.check,
        ),
      ),
    );
    cancellation.check();
    return _ScriptWorldBooksSnapshot.loaded(List.unmodifiable(books.loaded), resources: resources);
  } catch (error, stack) {
    cancellation.check();
    return _ScriptWorldBooksSnapshot.failed(error, stack);
  }
}

void _scriptCheckPromptSources(_ScriptGenerationCapture capture) {
  final request = capture.request;
  Never missing(String source) => throw _scriptError(
    TavernScriptErrorCode.noContext,
    'generate',
    'The requested $source source has no captured context.',
    contextId: capture.context.value.id,
  );
  if (request is! TavernScriptRawRequest) {
    if (capture.chat == null) missing('chat');
    if (capture.actorId == null) missing('character');
    return;
  }
  final overrides = request.overrides.fields;
  final kinds = {
    for (final part in request.orderedPrompts)
      if (part is TavernScriptPromptPlaceholderPart) part.kind,
  };
  final history = kinds.contains(TavernScriptPromptPlaceholder.chatHistory);
  if (history && !overrides.containsKey('chatHistory') && request.maxChatHistory != 0 && capture.chat == null) {
    missing('chatHistory');
  }
  final explicitWorld =
      (history && overrides['withDepthEntries'] != false) ||
      (kinds.contains(TavernScriptPromptPlaceholder.worldInfoBefore) && !overrides.containsKey('worldInfoBefore')) ||
      (kinds.contains(TavernScriptPromptPlaceholder.worldInfoAfter) && !overrides.containsKey('worldInfoAfter'));
  if (explicitWorld && capture.chat == null) missing('worldInfo');
  for (final kind in [
    TavernScriptPromptPlaceholder.charDescription,
    TavernScriptPromptPlaceholder.charPersonality,
    TavernScriptPromptPlaceholder.scenario,
    TavernScriptPromptPlaceholder.dialogueExamples,
  ]) {
    if (kinds.contains(kind) && !overrides.containsKey(kind.name) && capture.actorId == null) missing(kind.name);
  }
}

class _ScriptPromptRun {
  _ScriptPromptRun(this.owner, this.capture, this.cancellation, this.uses, this.worldBooks, {this.quiet})
    : overrides = capture.request.overrides.fields,
      macroHistory = List.of(capture.history),
      promptHistory = List.of(capture.history),
      card = _runtimeCopy(capture.card),
      settings = _runtimeCopy(capture.settings) {
    final request = capture.request;
    if (request is TavernScriptRawRequest) {
      requested.addAll([
        for (final part in request.orderedPrompts)
          if (part is TavernScriptPromptPlaceholderPart) part.kind,
      ]);
    } else {
      requested.addAll(TavernScriptPromptPlaceholder.values);
    }
    for (final entry in _cardFields.entries) {
      if (requested.any((kind) => kind.name == entry.key) && overrides.containsKey(entry.key)) {
        card[entry.value] = overrides[entry.key];
        _overriddenCardFields.add(entry.value);
      }
    }
    if (requested.contains(TavernScriptPromptPlaceholder.personaDescription) &&
        overrides.containsKey('personaDescription')) {
      settings['persona'] = overrides['personaDescription'];
    }
    if (hasHistory && overrides.containsKey('authorNote')) {
      settings['authorNote'] = {..._map(settings['authorNote']), 'content': overrides['authorNote']};
    }
    final selected = capture.promptPreset;
    promptPreset = selected == null
        ? null
        : ChatPreset({...selected.raw, 'stream_openai': request.stream, 'show_thoughts': capture.config.thinking});
    final macroPreset = promptPreset ?? ChatPreset({'openai_max_context': 4095, 'openai_max_tokens': 300});
    initialHash = _finiteNumber(capture.metadata['chat_id_hash']);
    environment = _MacroEnvironment(
      card,
      settings,
      capture.chat == null ? unavailableLocal : capture.local,
      capture.global,
      macroHistory,
      capture.config,
      capture.at,
      owner.engine._random,
      capture.chat == null
          ? ''
          : _macroChatIdentity(
              capture.chat!,
              capture.state,
              capture.metadata,
              capture.state['chatJsonlSourceFile'] as String?,
              node: capture.history.lastOrNull,
            ),
      inputRequested ? request.userInput : '',
      generationType,
      chatIdHash: initialHash,
      pickRerollSeed: capture.metadata['pick_reroll_seed'],
      characterId: capture.actorId ?? '',
      groupNames: capture.groupView?.names,
      groupNotMuted: capture.groupView?.enabledNames,
      preset: macroPreset,
      regexPresetSettings: capture.contextRegexPresetSettings,
      gameplayCapture: capture.gameplayCapture,
      messageVariables: capture.state['messageVariables'],
      messageVariablesExists: capture.state.containsKey('messageVariables'),
      macroHistory: capture.chat == null ? unavailableHistory : null,
      onCharacterDependency: capture.actorId == null ? _observeCharacterDependency : null,
      prepareCharacterFieldsOnDemand: raw,
      collapseNewlinesOverride: quiet?.policy.cleanup.collapseNewlines,
    );
  }

  final _ScriptCoordinator owner;
  final _ScriptGenerationCapture capture;
  final ModelCancellation cancellation;
  final _ScriptInjectionUseSet uses;
  final _ScriptWorldBooksSnapshot? worldBooks;
  final _SlashQuietPreparation? quiet;
  final Map<String, Object?> overrides, card, settings;
  final List<StoredNode> macroHistory;
  final List<StoredNode> promptHistory;
  final requested = <TavernScriptPromptPlaceholder>{};
  final _preparedFields = <String, String>{};
  final _overriddenCardFields = <String>{};
  String? _missingActorField;
  final _rawSources = <TavernScriptPromptPlaceholder, List<_ScriptRawPiece>>{};
  final unavailableLocal = _ScriptUnavailableVariables();
  final unavailableHistory = _ScriptUnavailableHistory();
  late final _MacroEnvironment environment;
  late final ChatPreset? promptPreset;
  late final num? initialHash;
  WorldInfoResult? world;
  var preparedInput = '';
  PreparedCharacterFields? ordinaryFields;
  List<PromptHistoryMessage>? _preparedHistory;
  List<_ConfiguredInjection> configured = const [];
  late _ScriptPreparedInjections shared;
  final configuredScan = <String>[];
  int _pieceSerial = 0;
  bool get raw => capture.request is TavernScriptRawRequest;
  String get generationType => quiet == null ? 'normal' : 'quiet';
  bool get hasHistory => requested.contains(TavernScriptPromptPlaceholder.chatHistory);
  bool get inputRequested => requested.contains(TavernScriptPromptPlaceholder.userInput);
  bool get ordinaryInputSlot => !raw && inputRequested && capture.request.userInput.isNotEmpty;
  bool get depthRequested => hasHistory && overrides['withDepthEntries'] != false;
  String get budgetSource => promptPreset == null
      ? requested.isEmpty &&
                uses.used.every(
                  (candidate) =>
                      candidate.injection!.position == TavernScriptInjectionPosition.scanOnly &&
                      candidate.injection!.scan != true,
                )
            ? 'none'
            : 'rawProjectDefault'
      : capture.request.presetId == null
      ? 'effectivePreset'
      : 'explicitPreset';
  List<StoredNode> get eligibleRealHistory =>
      capture.history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();

  static const _cardFields = {
    'charDescription': 'description',
    'charPersonality': 'personality',
    'scenario': 'scenario',
    'dialogueExamples': 'mes_example',
  };

  Future<_ScriptPreparedGeneration> prepare() async {
    quiet?.prepareLeading(this);
    if (inputRequested && capture.request.userInput.isNotEmpty) {
      final regexed = environment.regex.apply(
        capture.request.userInput,
        placement: RegexPlacement.userInput,
        expand: environment.regexExpand,
      );
      preparedInput = environment.expand(regexed, const {});
    }
    if (!raw) {
      ordinaryFields =
          quiet?.prepareFields(this) ??
          prepareCharacterFields(card, persona: environment.persona, expand: environment.baseExpand);
      // Retain the ordinary eager phase in a private prompt copy. It never
      // edits the actual greeting or changes the independent WI clock input.
      if (promptHistory.isNotEmpty && !overrides.containsKey('chatHistory') && capture.request.maxChatHistory != 0) {
        final first = promptHistory.first;
        promptHistory[0] = _nodeWithText(first, environment.expand(first.message.text, const {}));
      }
      configured = _configuredInjections(
        settings,
        ordinaryFields!,
        card,
        userMessageCount: capture.history.where((node) => node.message.role == TavernRole.user).length,
      );
    }
    if (preparedInput.isNotEmpty) {
      preparedInput = environment.regex.apply(
        preparedInput,
        placement: RegexPlacement.userInput,
        phase: RegexPhase.prompt,
        depth: 0,
        expand: environment.regexExpand,
      );
    }
    if (hasHistory) _history();
    if (raw && hasHistory) configured = _rawAuthorNote();
    shared = owner.injectionRegistry.prepareInjections(uses, environment);
    for (final item in configured) {
      if (item.scan) {
        final text = item.injection.fragment.expandMacros
            ? environment.expand(item.injection.fragment.content, const {})
            : item.injection.fragment.content;
        if (text.isNotEmpty) configuredScan.add(text);
      }
    }
    quiet?.prepareWorldScan(this);
    final needWorld =
        !raw ||
        (requested.contains(TavernScriptPromptPlaceholder.worldInfoBefore) &&
            !overrides.containsKey('worldInfoBefore')) ||
        (requested.contains(TavernScriptPromptPlaceholder.worldInfoAfter) &&
            !overrides.containsKey('worldInfoAfter')) ||
        depthRequested ||
        uses.used.any((candidate) => candidate.injection!.scan == true) ||
        configured.any((injection) => injection.scan);
    if (needWorld) await _evaluateWorld();
    cancellation.check();
    final body = raw ? _rawBody() : _ordinaryBody();
    // Legacy macro passes catch handler exceptions to preserve ST behavior.
    // Remember actual unavailable reads so that catch cannot turn a missing
    // source into an accepted request with a silently unresolved macro.
    if (unavailableLocal.accessed) _noContext('local-variable macro');
    if (unavailableHistory.accessed) _noContext('history macro');
    checkCharacterDependency();
    _applyFinalOptions(body);
    quiet?.spec.applyWireOptions(body, capture.config);
    cancellation.check();
    final stateUpdates = <String, Object?>{};
    final evaluated = world;
    if (evaluated != null) {
      if (!_stateJsonEqual(capture.state['timedWorldInfo'], evaluated.timedWorldInfo)) {
        stateUpdates['timedWorldInfo'] = evaluated.timedWorldInfo;
      }
      if (!_stateJsonEqual(capture.state['decoratorState'], evaluated.decoratorState)) {
        stateUpdates['decoratorState'] = evaluated.decoratorState;
      }
    }
    return _ScriptPreparedGeneration(
      capture: capture,
      body: body,
      budgetSource: budgetSource,
      injectionUses: uses,
      stateUpdates: stateUpdates,
      packWorldInfo: evaluated?.packWorldInfo,
      stChatIdHash: environment.chatIdHash,
      hasHashUpdate: capture.chat != null && environment.chatIdHash != initialHash,
      hookIssues: [
        ...uses.hookIssues,
        for (final issue in evaluated?.packIssues ?? const <Map<String, Object?>>[])
          TavernScriptIssue(
            code: 'gameplay_world_info_runtime',
            message: 'A gameplay world-info runtime source could not be used.',
            committed: false,
            generationId: capture.generationId,
            stage: 'worldInfo',
            details: issue,
          ),
      ],
    );
  }

  Never _noContext(String source) => throw _scriptError(
    TavernScriptErrorCode.noContext,
    'generate',
    'The requested $source source has no captured context.',
    contextId: capture.context.value.id,
  );

  void _observeCharacterDependency(String field) {
    if (capture.actorId != null || _overriddenCardFields.contains(field)) return;
    _missingActorField ??= field;
    checkCharacterDependency();
  }

  void checkCharacterDependency() {
    final field = _missingActorField;
    if (field == null) return;
    throw _scriptError(
      TavernScriptErrorCode.noContext,
      'generate',
      'The requested character source "$field" requires an actor; this captured context has no actor.',
      contextId: capture.context.value.id,
    );
  }

  List<_ConfiguredInjection> _rawAuthorNote() {
    final note = _map(settings['authorNote']);
    if (note.isEmpty || note['enabled'] == false) return const [];
    final interval = note['interval'];
    final users = capture.history.where((node) => node.message.role == TavernRole.user).length;
    if (interval != null && interval != 1 && !(interval is num && interval > 0 && users > 0 && users % interval == 0)) {
      return const [];
    }
    final source = _injection(note, '2_floating_prompt', kind: 'authorNote');
    // One prepared value is shared by scan and prompt. Explicit empty note
    // does not evaluate the previous stored note.
    final text = source.fragment.content.isEmpty ? '' : environment.expand(source.fragment.content, const {});
    return [
      _ConfiguredInjection(
        _copyPromptInjection(source, fragment: _preparedFragment(source.fragment, text: text)),
        scan: note['scan'] == true,
        authorNote: true,
      ),
    ];
  }

  String _field(String name) => _preparedFields.putIfAbsent(name, () {
    Object? value;
    if (name == 'persona') {
      value = settings['persona'];
    } else {
      _observeCharacterDependency(name);
      value = name == 'charDepthPrompt' ? _map(_map(card['extensions'])['depth_prompt'])['prompt'] : card[name];
    }
    final text = value is String ? trimJsWhitespace(value) : '';
    return text.isEmpty ? '' : environment.baseExpand(text, const {}).replaceAll('\r', '');
  });

  Future<void> _evaluateWorld() async {
    if (capture.chat == null || !capture.capturedChatState) _noContext('worldInfo');
    final snapshot = worldBooks;
    if (snapshot == null) {
      throw StateError('A requested world-info source was not captured before filtering.');
    }
    final books = snapshot.read();
    cancellation.check();
    if (raw) {
      const scanFields = {
        'matchPersonaDescription': ('match_persona_description', 'persona'),
        'matchCharacterDescription': ('match_character_description', 'description'),
        'matchCharacterPersonality': ('match_character_personality', 'personality'),
        'matchCharacterDepthPrompt': ('match_character_depth_prompt', 'charDepthPrompt'),
        'matchScenario': ('match_scenario', 'scenario'),
        'matchCreatorNotes': ('match_creator_notes', 'creator_notes'),
      };
      for (final field in scanFields.entries) {
        if (books.any(
          (book) => book.entries.any(
            (entry) =>
                !entry.disabled &&
                !entry.constant &&
                (book.raw['entries'] is List<Object?>
                    ? _map(entry.raw['extensions'])[field.value.$1] == true
                    : entry.raw[field.key] == true),
          ),
        )) {
          _field(field.value.$2);
        }
      }
      // These fields decide V3 section availability as well as printed text.
      if (requested.contains(TavernScriptPromptPlaceholder.charPersonality)) _field('personality');
      if (requested.contains(TavernScriptPromptPlaceholder.scenario)) _field('scenario');
    }
    final prepared =
        ordinaryFields ?? PreparedCharacterFields(_preparedFields, _preparedFields['persona'] ?? '', const []);
    final real = eligibleRealHistory;
    world = await owner.engine._worldInfoEngine.evaluate(
      WorldInfoInput(
        books: books,
        messages: [for (final node in real) WorldInfoMessage(node.message.text, speaker: node.message.speaker)],
        maxContext: environment.maxContext - environment.maxResponse,
        tokenCount: owner.engine._counter.countText,
        random: owner.engine._random,
        checkCancelled: cancellation.check,
        expand: (text) => environment.expand(text, const {}),
        settings: WorldInfoSettings.fromJson(_map(settings['worldInfo'])),
        scanInjections: [
          if (inputRequested && preparedInput.isNotEmpty) preparedInput,
          ...configuredScan,
          ...shared.scanTexts,
          if (quiet != null && quiet!.scanText.isNotEmpty) quiet!.scanText,
        ],
        personaDescription: prepared.persona,
        characterDescription: prepared['description'],
        characterPersonality: prepared['personality'],
        characterDepthPrompt: prepared['charDepthPrompt'],
        scenario: prepared['scenario'],
        creatorNotes: prepared['creator_notes'],
        trigger: generationType,
        characterName: _characterFilename(settings, capture.actorId ?? ''),
        characterTags: _characterTags(settings, capture.actorId ?? ''),
        timedWorldInfo: _map(capture.state['timedWorldInfo']),
        decoratorState: _map(capture.state['decoratorState']),
        packSources: snapshot.resources.packSources,
        packWorldInfo: _gameplayWorldInfoSnapshot(capture.state, snapshot.resources),
        assistantMessageCount: real.where((node) => node.message.role == TavernRole.character).length,
        greetingIndex: capture.state['greetingIndex'] is int ? capture.state['greetingIndex'] as int : null,
        userIconName: settings['userIconName'] as String?,
        contextAtCapacity: false,
        availablePromptSections: raw
            ? {
                if (requested.contains(TavernScriptPromptPlaceholder.charPersonality)) 'personality',
                if (requested.contains(TavernScriptPromptPlaceholder.scenario)) 'scenario',
              }
            : _availableWorldSections(promptPreset!, generationType),
        postProcessContent: (entry, content, depth) => environment.regex.apply(
          content,
          placement: RegexPlacement.worldInfo,
          phase: RegexPhase.prompt,
          depth: depth,
          expand: environment.regexExpand,
        ),
      ),
    );
    cancellation.check();
    environment.outlets.addAll({
      for (final entry in world!.outlets.entries) entry.key: entry.value.map((hit) => hit.content).join('\n'),
    });
  }

  List<PromptHistoryMessage> _history() => _preparedHistory ??= _prepareHistory();

  List<PromptHistoryMessage> _prepareHistory() {
    final maximum = capture.request.maxChatHistory;
    if (maximum == 0) return const [];
    final replacement = overrides['chatHistory'];
    if (replacement is List<Object?>) {
      var rows = replacement.cast<Map<String, Object?>>();
      if (maximum != null && rows.length > maximum) rows = rows.sublist(rows.length - maximum);
      return [
        for (final (index, row) in rows.indexed)
          PromptHistoryMessage(
            id: 'scriptHistory$index',
            role: row['role']! as String,
            content: row['role'] == 'system'
                ? row['content']! as String
                : environment.regex.apply(
                    row['content']! as String,
                    placement: row['role'] == 'user' ? RegexPlacement.userInput : RegexPlacement.aiOutput,
                    phase: RegexPhase.prompt,
                    depth: rows.length - index - 1 + (ordinaryInputSlot ? 1 : 0),
                    expand: environment.regexExpand,
                  ),
          ),
      ];
    }
    var selected = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
    if (maximum != null && selected.length > maximum) selected = selected.sublist(selected.length - maximum);
    final prepared = _preparePromptHistory(
      selected,
      environment,
      continuing: false,
      depthOffset: ordinaryInputSlot ? 1 : 0,
    );
    return [for (final node in prepared) _promptHistory(node)];
  }

  Map<String, Object?> _ordinaryBody() {
    final evaluated = world!;
    final fields = ordinaryFields!;
    List<PromptFragment> outlet(String name, List<WorldInfoHit> values) {
      if (!overrides.containsKey(name)) return values.map(_worldFragment).toList();
      final value = overrides[name]! as String;
      final text = value.isEmpty ? '' : environment.expand(value, const {});
      return [PromptFragment(text, PromptSource('scriptOverride', name), expandMacros: false)];
    }

    final injections = [
      ..._finishInjections(
        configured,
        evaluated,
        deepseek: capture.config.deepseek,
      ).where((injection) => depthRequested || injection.fragment.source.kind != 'worldInfo'),
      ...shared.prompts,
    ];
    final examples = [
      for (var index = 0; index < evaluated.activated.length; index++) (index, evaluated.activated[index]),
    ];
    examples.sort((a, b) {
      final byOrder = b.$2.order.compareTo(a.$2.order);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });
    final history = List<PromptHistoryMessage>.of(_history());
    if (ordinaryInputSlot) {
      history.add(
        PromptHistoryMessage(
          id: 'scriptUserInput',
          role: 'user',
          content: preparedInput,
          name: environment.userName,
          expandMacros: false,
        ),
      );
    }
    final input = PromptInput(
      preset: promptPreset!,
      card: card,
      history: history,
      model: capture.config.model,
      userName: environment.userName,
      characterId: capture.actorId ?? '',
      groupNames: capture.groupView?.names ?? const [],
      generationType: generationType,
      deepseek: capture.config.deepseek,
      persona: environment.persona,
      personaInPrompt: settings['personaInPrompt'] != false,
      worldBefore: outlet('worldInfoBefore', evaluated.before),
      worldAfter: outlet('worldInfoAfter', evaluated.after),
      worldSections: {
        for (final entry in evaluated.sections.entries) entry.key: entry.value.map(_worldFragment).toList(),
      },
      disabledUiPrompts: evaluated.disabledUiPrompts,
      assistantPrefill: [
        if (capture.config.deepseek && depthRequested)
          for (final depth in evaluated.depths)
            for (final hit in depth.entries)
              if (_worldPrefill(hit)) _worldFragment(hit),
      ],
      injections: injections,
      worldExamples: [
        for (final item in examples.reversed)
          if (item.$2.content.isNotEmpty && item.$2.section == null && (item.$2.position == 5 || item.$2.position == 6))
            PromptExample(fragment: _worldFragment(item.$2), before: item.$2.position == 5),
      ],
      pinExamples: settings['pinExamples'] == true,
      stripExamples: settings['stripExamples'] == true,
      quietPrompt: quiet?.quietPrompt ?? '',
      bias: quiet?.bias ?? _string(settings['bias']),
      stops: quiet == null ? _strings(settings['stops']) : const [],
      expansion: environment.expand,
      cardExpansion: quiet == null
          ? environment.baseExpand
          : (text, overrides) => quiet!.baseExpand(this, text, overrides),
      preparedFields: fields,
    );
    final assembler = PromptAssembler(counter: owner.engine._counter);
    final assembly = quiet == null
        ? assembler.assemble(input)
        : assembleScriptPrompt(assembler, input, preparedStops: () => quiet!.wireStops(this));
    final excluded = <(String, String)>{
      for (final exclusion in assembly.excluded)
        if (exclusion.reason == 'v3-ignore-on-max-context')
          for (final source in exclusion.sources)
            if (source.kind == 'worldInfo' && source.details['bookId'] is String && source.details['uid'] is String)
              (source.details['bookId']! as String, source.details['uid']! as String),
    };
    world = evaluated.withoutEntries(excluded);
    return _captureScriptObject(assembly.body);
  }

  Map<String, Object?> _rawBody() {
    final request = capture.request as TavernScriptRawRequest;
    final base = <_ScriptRawPiece>[];
    for (final part in request.orderedPrompts) {
      switch (part) {
        case TavernScriptPromptLiteral():
          base.add(
            _piece({
              'role': part.role.name,
              'content': part.content,
            }, PromptSource('scriptLiteral', 'literal${base.length}')),
          );
        case TavernScriptPromptPlaceholderPart():
          base.addAll(_rawSources.putIfAbsent(part.kind, () => _rawSource(part.kind)));
      }
    }
    final additions = <PromptInjection>[...shared.prompts];
    if (hasHistory) {
      final evaluated = world;
      if (evaluated == null) {
        additions.addAll(configured.map((item) => item.injection));
      } else {
        // Author-note decorations share its explicit chatHistory source. WI
        // depth outlets are independently disabled by withDepthEntries=false.
        additions.addAll(
          _finishInjections(configured, evaluated)
              .where((injection) => depthRequested || injection.fragment.source.kind != 'worldInfo')
              .map(_preparedPromptInjection),
        );
      }
    }
    for (final injection in additions) {
      if (injection.placement != PromptPlacement.inChat && injection.fragment.content.isNotEmpty) {
        throw TavernScriptException(
          code: TavernScriptErrorCode.unsupportedOption,
          operation: 'generateRaw',
          message: 'A nonempty relative injection has no main marker in an explicit raw prompt.',
          generationId: capture.generationId,
          contextId: capture.context.value.id,
          issues: [
            TavernScriptIssue(
              code: 'unsupportedOption',
              message: 'The raw source has no main marker.',
              committed: false,
              generationId: capture.generationId,
              stage: 'promptPlacement',
              details: {
                'sourceRef': injection.fragment.source.details,
                'rawId': injection.sortKey ?? injection.fragment.source.id,
                'position': injection.placement.name,
                'missingMain': true,
              },
            ),
          ],
        );
      }
    }
    final explicit = _insertDepth(base, additions.where((item) => item.placement == PromptPlacement.inChat).toList());
    final dropped = <(String, String)>{};
    List<PromptSegment> convert() => convertExplicitPromptMessages(
      [
        for (final piece in explicit)
          if (piece.worldIdentity == null || !dropped.contains(piece.worldIdentity))
            piece.segment(owner.engine._counter),
      ],
      deepseek: capture.config.deepseek,
      userName: environment.userName,
      characterName: _string(card['name']),
      groupNames: capture.groupView?.names ?? const [],
      counter: owner.engine._counter,
    );
    var converted = convert();
    if (promptPreset != null) {
      final budget = environment.maxContext - environment.maxResponse;
      int cost() => converted.fold(0, (total, item) => total + owner.engine._counter.countMessage(item.message));
      // Optional V3 fragments may be removed without replaying preparation.
      // The original explicit literal/history sequence is never cropped.
      for (final piece in explicit) {
        if (cost() < budget) break;
        if (!piece.optional || piece.worldIdentity == null || !dropped.add(piece.worldIdentity!)) continue;
        converted = convert();
      }
      if (cost() > budget) {
        throw const TavernModelException(
          TavernFailure.contextTooLong,
          'The final explicit raw messages exceed the selected parameter preset budget.',
        );
      }
    }
    if (world != null && dropped.isNotEmpty) world = world!.withoutEntries(dropped);
    return explicitPromptRequestBody(
      messages: converted,
      settings: promptPreset?.settings,
      deepseek: capture.config.deepseek,
      model: capture.config.model,
    );
  }

  List<_ScriptRawPiece> _rawSource(TavernScriptPromptPlaceholder kind) {
    final name = kind.name;
    final source = PromptSource('scriptPlaceholder', name);
    if (kind == TavernScriptPromptPlaceholder.chatHistory) {
      final result = <_ScriptRawPiece>[];
      final names = capture.contextRegexPresetSettings['names_behavior'];
      for (final item in _history()) {
        final role = item.role == 'narrator' ? 'system' : item.role;
        var text = environment.expand(item.content, const {}).replaceAll('\r', '');
        if ((names == 2 && role != 'system') ||
            (names == 0 &&
                item.name != environment.userName &&
                (capture.groupView != null || (item.forceAvatar && role != 'system')))) {
          text = '${item.name}: $text';
        }
        result.add(
          _piece({
            'role': role,
            'content': text,
            if (names == 1 && item.name.isNotEmpty) 'name': sanitizeName(item.name),
            if (item.toolCalls != null) 'tool_calls': item.toolCalls,
            if (item.toolCallId != null) 'tool_call_id': item.toolCallId,
          }, PromptSource('history', item.id)),
        );
      }
      return result;
    }
    if (kind == TavernScriptPromptPlaceholder.userInput) {
      return preparedInput.isEmpty
          ? []
          : [
              _piece({'role': 'user', 'content': preparedInput}, source),
            ];
    }
    if (kind == TavernScriptPromptPlaceholder.worldInfoBefore || kind == TavernScriptPromptPlaceholder.worldInfoAfter) {
      if (overrides.containsKey(name)) {
        final value = overrides[name]! as String;
        if (value.isEmpty) return [];
        return [
          _piece({'role': 'system', 'content': environment.expand(value, const {})}, source),
        ];
      }
      return _worldPieces(kind == TavernScriptPromptPlaceholder.worldInfoBefore ? world!.before : world!.after);
    }
    if (kind == TavernScriptPromptPlaceholder.dialogueExamples) {
      final text = _field('mes_example');
      final result = <_ScriptRawPiece>[];
      if (!overrides.containsKey(name) && world != null) {
        for (final hit in world!.examplesBefore) {
          result.addAll(_examplePieces(hit));
        }
      }
      for (final block in parseDialogueExamples(
        text,
        userName: environment.userName,
        characterName: _string(card['name']),
        groupNames: capture.groupView?.names ?? const [],
      )) {
        for (final message in block) {
          result.add(_piece(message, source));
        }
      }
      if (!overrides.containsKey(name) && world != null) {
        for (final hit in world!.examplesAfter) {
          result.addAll(_examplePieces(hit));
        }
      }
      return result;
    }
    final field = kind == TavernScriptPromptPlaceholder.personaDescription ? 'persona' : _cardFields[name]!;
    final text = _field(field);
    final result = <_ScriptRawPiece>[];
    if (world != null && !overrides.containsKey(name) && field == 'description') {
      result.addAll(_worldPieces(world!.sections['before_desc'] ?? const []));
    }
    if (text.isNotEmpty) result.add(_piece({'role': 'system', 'content': text}, source));
    if (world != null && !overrides.containsKey(name)) {
      final section = field == 'description'
          ? 'after_desc'
          : field == 'personality' || field == 'scenario'
          ? field
          : null;
      if (section != null) result.addAll(_worldPieces(world!.sections[section] ?? const []));
    }
    return result;
  }

  List<_ScriptRawPiece> _examplePieces(WorldInfoHit hit) {
    if (hit.roleOverride != null) return _worldPieces([hit]);
    return [
      for (final block in parseDialogueExamples(
        hit.content,
        userName: environment.userName,
        characterName: _string(card['name']),
        groupNames: capture.groupView?.names ?? const [],
      ))
        for (final message in block)
          _piece(message, _worldSource(hit), worldIdentity: hit.entry.identity, optional: hit.ignoreOnMaxContext),
    ];
  }

  List<_ScriptRawPiece> _worldPieces(List<WorldInfoHit> hits) => [
    for (final hit in hits)
      if (hit.content.isNotEmpty)
        _piece(
          {'role': _role(hit.roleOverride ?? 0), 'content': hit.content},
          _worldSource(hit),
          worldIdentity: hit.entry.identity,
          optional: hit.ignoreOnMaxContext,
        ),
  ];

  _ScriptRawPiece _piece(
    Map<String, Object?> message,
    PromptSource source, {
    (String, String)? worldIdentity,
    bool optional = false,
  }) => _ScriptRawPiece(
    'scriptRaw${++_pieceSerial}',
    _captureScriptObject(message),
    source,
    worldIdentity: worldIdentity,
    optional: optional,
  );

  List<_ScriptRawPiece> _insertDepth(List<_ScriptRawPiece> base, List<PromptInjection> injections) {
    final at = <int, List<({PromptInjection injection, PromptFragment fragment, int index})>>{};
    for (final injection in injections) {
      if (injection.depth < 0 || (!injection.v3Depth && injection.depth > 10000)) continue;
      final boundary = injection.depth >= base.length ? 0 : base.length - injection.depth;
      final bucket = at.putIfAbsent(boundary, () => []);
      final fragments = injection.fragments.isEmpty ? [injection.fragment] : injection.fragments;
      for (final fragment in fragments) {
        if (fragment.content.isNotEmpty) bucket.add((injection: injection, fragment: fragment, index: bucket.length));
      }
    }
    final result = <_ScriptRawPiece>[];
    for (var index = 0; index <= base.length; index++) {
      final bucket = at[index];
      if (bucket != null) {
        bucket.sort((a, b) {
          // Different depths clipped at the head retain the reversed-history
          // algorithm's deeper-first order, then order/role/key/source ties.
          final byDepth = b.injection.depth.compareTo(a.injection.depth);
          if (byDepth != 0) return byDepth;
          final byOrder = a.injection.order.compareTo(b.injection.order);
          if (byOrder != 0) return byOrder;
          int role(String name) => switch (name) {
            'assistant' => 0,
            'user' => 1,
            _ => 2,
          };
          final byRole = role(a.fragment.role ?? a.injection.role).compareTo(role(b.fragment.role ?? b.injection.role));
          if (byRole != 0) return byRole;
          final byKey = (a.injection.sortKey ?? a.injection.fragment.source.id).compareTo(
            b.injection.sortKey ?? b.injection.fragment.source.id,
          );
          if (byKey != 0) return byKey;
          final bySource = a.injection.sourceOrder.compareTo(b.injection.sourceOrder);
          return bySource != 0 ? bySource : a.index.compareTo(b.index);
        });
        var start = 0;
        while (start < bucket.length) {
          final first = bucket[start];
          final role = first.fragment.role ?? first.injection.role;
          var end = start + 1;
          while (end < bucket.length &&
              bucket[end].injection.depth == first.injection.depth &&
              bucket[end].injection.order == first.injection.order &&
              (bucket[end].fragment.role ?? bucket[end].injection.role) == role) {
            end++;
          }
          final group = bucket.sublist(start, end);
          final split = group.any((item) => item.fragment.role != null || item.fragment.trimOnOverflow);
          if (!split) {
            final text = group
                .map((item) => trimJsWhitespace(item.fragment.content))
                .where((text) => text.isNotEmpty)
                .join('\n');
            if (text.isNotEmpty) {
              result.add(
                _piece(
                  {'role': role, 'content': text},
                  PromptSource(
                    'scriptDepth',
                    'depth${first.injection.depth}',
                    details: {
                      'sources': [for (final item in group) item.fragment.source.toJson()],
                    },
                  ),
                ),
              );
            }
          } else {
            for (final item in group) {
              final text = trimJsWhitespace(item.fragment.content);
              if (text.isEmpty) continue;
              final source = item.fragment.source;
              final bookId = source.details['bookId'];
              final uid = source.details['uid'];
              result.add(
                _piece(
                  {'role': role, 'content': text},
                  source,
                  worldIdentity: bookId is String && uid is String ? (bookId, uid) : null,
                  optional: item.fragment.trimOnOverflow,
                ),
              );
            }
          }
          start = end;
        }
      }
      if (index < base.length) result.add(base[index]);
    }
    return result;
  }

  void _applyFinalOptions(Map<String, Object?> body) {
    body['model'] = capture.config.model;
    for (final entry in capture.request.samplingOverrides.entries) {
      body[entry.key] = capture.config.deepseek && entry.key == 'top_p' && entry.value == 0
          ? 2.220446049250313e-16
          : entry.value;
    }
    body['stream'] = capture.request.stream;
    if (capture.config.deepseek) {
      body['thinking'] = {'type': capture.config.thinking ? 'enabled' : 'disabled'};
      if (!capture.config.thinking) body.remove('reasoning_effort');
    }
  }
}

class _ScriptRawPiece {
  const _ScriptRawPiece(this.id, this.message, this.source, {this.worldIdentity, this.optional = false});
  final String id;
  final Map<String, Object?> message;
  final PromptSource source;
  final (String, String)? worldIdentity;
  final bool optional;
  PromptSegment segment(PromptTokenCounter counter) =>
      PromptSegment(id: id, message: message, sources: [source], tokens: counter.countMessage(message));
}

PromptFragment _preparedFragment(PromptFragment fragment, {String? text}) => PromptFragment(
  text ?? fragment.content,
  fragment.source,
  role: fragment.role,
  trimOnOverflow: fragment.trimOnOverflow,
  expandMacros: false,
);

PromptInjection _copyPromptInjection(
  PromptInjection injection, {
  PromptFragment? fragment,
  List<PromptFragment>? fragments,
}) => PromptInjection(
  fragment: fragment ?? injection.fragment,
  fragments: fragments ?? injection.fragments,
  role: injection.role,
  placement: injection.placement,
  depth: injection.depth,
  order: injection.order,
  v3Depth: injection.v3Depth,
  sortKey: injection.sortKey,
  sourceOrder: injection.sourceOrder,
);

PromptInjection _preparedPromptInjection(PromptInjection injection) => _copyPromptInjection(
  injection,
  fragment: _preparedFragment(injection.fragment),
  fragments: [for (final fragment in injection.fragments) _preparedFragment(fragment)],
);

class _ScriptUnavailableVariables extends MapBase<String, Object?> {
  bool accessed = false;
  Never _missing() {
    accessed = true;
    throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'A local-variable macro requires a captured chat.');
  }

  @override
  Object? operator [](Object? key) => _missing();
  @override
  void operator []=(String key, Object? value) => _missing();
  @override
  Iterable<String> get keys => _missing();
  @override
  Object? remove(Object? key) => _missing();
  @override
  void clear() => _missing();
}

class _ScriptUnavailableHistory extends ListBase<MacroMessage> {
  bool accessed = false;
  Never _missing() {
    accessed = true;
    throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'A history macro requires a captured chat.');
  }

  @override
  int get length => _missing();
  @override
  set length(int value) => _missing();
  @override
  MacroMessage operator [](int index) => _missing();
  @override
  void operator []=(int index, MacroMessage value) => _missing();
}
