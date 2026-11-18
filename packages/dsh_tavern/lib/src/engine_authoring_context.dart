part of 'engine.dart';

/// Only owned data crosses the seal. These methods cannot read an engine,
/// execute a host callback, or turn a sample ledger into a real bind proof.
final class _AuthoringPromptContextCapture {
  _AuthoringPromptContextCapture({
    required this.turn,
    required List<StoredNode> history,
    required this.parent,
    required this.userSiblingIndex,
    required this.actorData,
    required this.hostData,
    required this.global,
    required this.macroChatIdentity,
    required this.random,
    required this.books,
    required this.missingBooks,
    required this.origin,
    required this.scripts,
    required _AuthoringSecretFacts secretFacts,
    required List<String> contextPath,
    required Map<String, Object?>? directorSource,
    required Map<String, Object?>? capturedDirectorSource,
    required Map<String, Object?> authorizationSource,
    required Map<String, Object?> storyState,
    required Map<String, StoredAgentRun> audits,
    required _AuthoringCapturedLegacy legacy,
    required List<StoredRememberMemory> remembered,
    required Set<String> physicalParents,
    required StoredAgentRun? persistedProposal,
    required Map<String, Object?>? bindingSource,
    required Map<String, Object?>? bindingState,
    required Map<String, Object?>? bindingExtra,
    bool groupUserPrepared = false,
    this.preparedGroupRegexTrace = const [],
    this.simulationSeed,
  }) : _history = history,
       _secretFacts = secretFacts,
       _contextPath = contextPath,
       _directorSource = directorSource,
       _capturedDirectorSource = capturedDirectorSource,
       _authorizationSource = authorizationSource,
       _storyState = storyState,
       _audits = audits,
       _legacy = legacy,
       _remembered = remembered,
       _physicalParents = physicalParents,
       _persistedProposal = persistedProposal,
       _bindingSource = bindingSource,
       _bindingState = bindingState,
       _bindingExtra = bindingExtra,
       _groupUserPrepared = groupUserPrepared;

  final _Turn turn;
  final List<StoredNode> _history;
  List<StoredNode> get history => _secretFacts.proofs.frame?.history ?? _history;
  String? parent;
  final int userSiblingIndex;
  final Map<String, Object?> actorData, hostData, global, origin;
  String macroChatIdentity;
  final Random random;
  final List<WorldInfoBook> books;
  final List<Map<String, Object?>> missingBooks;
  final _AuthoringScriptCapture scripts;
  final _AuthoringSecretFacts _secretFacts;
  final List<String> _contextPath;
  Map<String, Object?>? _directorSource;
  final Map<String, Object?>? _capturedDirectorSource, _bindingSource, _bindingState, _bindingExtra;
  Map<String, Object?> _authorizationSource, _storyState;
  final Map<String, StoredAgentRun> _audits;
  final _AuthoringCapturedLegacy _legacy;
  final List<StoredRememberMemory> _remembered;
  final Set<String> _physicalParents;
  final StoredAgentRun? _persistedProposal;
  bool _groupUserPrepared;
  final List<Map<String, Object?>> preparedGroupRegexTrace;
  final _AuthoringSimulationSeed? simulationSeed;

  // A native group round appends its user before constructing the actor's
  // empty-input turn. This local branch follows that same preparation order.
  void prepareGroupUser(String input, String captureId, List<Map<String, Object?>> regexTrace) {
    if (_groupUserPrepared) {
      return;
    }
    final prepared = _prepareAuthoringGroupUser(
      turn,
      history: history,
      parent: parent,
      actorData: actorData,
      global: global,
      random: random,
      macroChatIdentity: macroChatIdentity,
      input: input,
      captureId: captureId,
      userSiblingIndex: userSiblingIndex,
      regexTrace: regexTrace,
    );
    if (prepared == null) {
      return;
    }
    _groupUserPrepared = true;
    parent = prepared.parent;
    _contextPath.add(prepared.parent);
    macroChatIdentity = prepared.macroChatIdentity;
    _directorSource = _capturedDirectorSource;
    _authorizationSource = _secretStateSource(turn.state);
    _storyState = turn.state;
  }

  void prepareBeforeUser() {
    turn.gameplayInitializing = parent == null && turn.chat.currentLeafId == null;
    final gameplayIssues = _gameplayValueIssues(
      turn.gameplay,
      turn.currentState,
      initializing: turn.gameplayInitializing,
      previousConfig: turn.gameplayPreviousConfig,
    );
    turn.gameplayValueEligible = gameplayIssues.isEmpty;
    turn.statePreparationIssues.addAll(gameplayIssues);
    final preparation = _prepareSecretBindingFromFacts(
      turn,
      hostData,
      parent,
      currentChat: turn.chat,
      physicalParents: _physicalParents,
      persistedProposal: _persistedProposal,
      source: _bindingSource,
      saved: _bindingState,
      rawExtra: _bindingExtra,
      facts: _secretFacts,
    );
    var source = _directorSource;
    var authorization = _authorizationSource;
    var story = _storyState;
    if (preparation != null && preparation.prepared.accepted) {
      _secretFacts.proofs.adopt(turn, preparation, _history);
      final persistent = _secretFacts.proofs.frame!.candidate.persistent;
      // An A-only proof error may have closed eligibility while the source
      // itself was read successfully. B re-evaluates that knowledge gate.
      source = _capturedDirectorSource;
      // B changes the current authorization, even when the director's source
      // is an unchanged earlier ancestor. If that source is B's anchor,
      // recompute its fingerprint input from the updated local history too.
      final director = turn.directorCaptured;
      if (director != null &&
          director.result['sourceKind'] == 'node' &&
          director.result['sourceNodeId'] == preparation.anchor) {
        source = _directorSourceFromFacts(preparation.anchor, history, turn.groupView?.group, persistent);
      }
      authorization = _secretStateSource(persistent);
      story = persistent;
      if (turn.gameplay case final config?) {
        turn.gameplayPreviousConfig = config;
      }
    }
    _prepareStateTurn(turn, hostData);
    turn.directorPrepared = _prepareDirectorFromFacts(
      turn,
      hostData,
      parent,
      contextPath: _contextPath,
      source: source,
      currentSettings: _secretFacts.settings,
      authorizationSource: authorization,
      storyState: story,
      proofs: _secretFacts.proofs,
    );
    _prepareCardEventTurnFromFacts(turn, hostData, _audits);
  }

  Map<String, Object?> get secretTrace => _secretFacts.proofs.trace(turn, parent);

  List<WorldInfoBook> directorBooks() {
    final prepared = _directorBooksFromFacts(
      turn,
      books,
      legacy: turn.directorPrepared?.eligible == true ? _legacy.read() : const [],
      remembered: _remembered,
    );
    if (prepared.inspection case final inspection?) {
      turn.inspection = inspection;
    }
    return prepared.books;
  }

  List<PromptInjection> secretInjections() => _secretTurnInjectionsFromFacts(turn, hostData, _secretFacts);

  void captureAssembly(PromptAssembly assembly, WorldInfoResult world) {
    final inspection = _directorAssemblyInspection(turn, assembly, world);
    if (inspection != null) {
      turn.inspection = inspection;
    }
  }

  void finalSecretCheck({required String? currentLeafId, required Map<String, Object?> replyState}) {
    final inspection = _prepareSecretRequestFromFacts(
      turn,
      _secretFacts,
      currentLeafId: currentLeafId,
      replyState: replyState,
    );
    if (inspection != null) {
      turn.inspection = inspection;
    }
    turn.inspection = _gameplayInspection(turn.inspection, turn.gameplay);
  }
}

({String parent, String macroChatIdentity})? _prepareAuthoringGroupUser(
  _Turn turn, {
  required List<StoredNode> history,
  required String? parent,
  required Map<String, Object?> actorData,
  required Map<String, Object?> global,
  required Random random,
  required String macroChatIdentity,
  required String input,
  required String captureId,
  required int userSiblingIndex,
  required List<Map<String, Object?>> regexTrace,
  void Function()? saveGlobals,
}) {
  final view = turn.groupView;
  if (view == null || turn.kind != _TurnKind.send || input.isEmpty) {
    return null;
  }
  final presetRaw = _map(turn.settings['preset']);
  final preset = ChatPreset({
    ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
    'show_thoughts': turn.config.thinking,
  });
  final environment = _MacroEnvironment(
    actorData,
    turn.settings,
    turn.variables,
    global,
    history,
    turn.config,
    turn.at,
    random.nextDouble,
    macroChatIdentity,
    input,
    'normal',
    chatIdHash: _finiteNumber(turn.metadata['chat_id_hash']),
    pickRerollSeed: turn.metadata['pick_reroll_seed'],
    characterId: turn.actorId,
    groupNames: view.names,
    groupNotMuted: view.enabledNames,
    preset: preset,
    messageVariables: turn.state['messageVariables'],
    messageVariablesExists: turn.state.containsKey('messageVariables'),
    packRegex: turn.gameplayResources.regex,
  );
  final text = _preparePromptUser(environment, input, regexTrace: regexTrace);
  saveGlobals?.call();
  final state = _prepareAppendedMessageState(
    turn.state,
    environment,
    stateCardData: view.host.card.data,
    stateEnabled:
        turn.settings['stateEnabled'] != false &&
        (turn.gameplay == null ||
            parent == null &&
                turn.chat.currentLeafId == null &&
                _gameplayValueIssues(
                  turn.gameplay,
                  turn.state,
                  initializing: true,
                  previousConfig: turn.gameplayPreviousConfig,
                ).isEmpty),
    gameplay: turn.gameplay,
  );
  turn.cancellation.check();
  final at = DateTime.fromMillisecondsSinceEpoch(turn.at.millisecondsSinceEpoch, isUtc: true);
  final message = TavernMessage(
    nodeId: '$captureId:user',
    parentId: parent,
    role: TavernRole.user,
    speaker: environment.userName,
    text: text,
    at: at,
    siblingIndex: userSiblingIndex,
    siblingCount: userSiblingIndex + 1,
  );
  final saved = _copy(state);
  final node = StoredNode(
    message: message,
    depth: history.isEmpty ? 1 : history.last.depth + 1,
    extra: {
      'dshgo': {'tavernState': saved},
    },
    original: const {},
  );
  history.add(node);
  final before = turn.chat;
  turn.chat = StoredChat(
    id: before.id,
    characterId: before.characterId,
    title: before.title,
    createdAt: before.createdAt,
    updatedAt: at,
    metadata: _runtimeMetadata(before.metadata, state),
    variables: _copy(turn.variables),
    settings: before.settings,
    personaId: before.personaId,
    presetId: before.presetId,
    currentLeafId: message.nodeId,
    selectedRootId: history.first.message.nodeId,
  );
  turn.metadata = ChatJsonlCodec().metadataForState(turn.chat, saved);
  turn.state = state;
  if (turn.gameplay case final config?) {
    if (state['dshgoPackDefinitionConfigId'] == config.effectiveConfigId) {
      turn.gameplayPreviousConfig = config;
    }
  }
  turn.inspection = turn.inspection.copyWith(contextNodeId: message.nodeId);
  return (
    parent: message.nodeId,
    macroChatIdentity: _macroChatIdentity(turn.chat, saved, turn.metadata, turn.sourceFile, node: node),
  );
}

/// B or a prepared group user can change current director eligibility. Capture that
/// possible dependency without moving a failed read ahead of its real gate.
final class _AuthoringCapturedLegacy {
  const _AuthoringCapturedLegacy(this.rows, {this.error, this.stack});
  final List<({String id, Map<String, Object?> entry, bool valid})> rows;
  final Object? error;
  final StackTrace? stack;
  List<({String id, Map<String, Object?> entry, bool valid})> read() {
    if (error case final failure?) {
      Error.throwWithStackTrace(failure, stack!);
    }
    return rows;
  }
}

typedef _AuthoringAuditRead = ({StoredAgentRun? row, Object? error, StackTrace? stack});

/// Audits may become relevant only after local state initialization. A failed
/// read is retained as that dependency's error, not treated as an absent proof
/// or thrown before the original definition/path/value gate reaches it.
final class _AuthoringCapturedAudits extends MapBase<String, StoredAgentRun> {
  _AuthoringCapturedAudits(this.reads);
  final Map<String, _AuthoringAuditRead> reads;
  @override
  StoredAgentRun? operator [](Object? key) {
    final value = reads[key];
    if (value == null) {
      return null;
    }
    final error = value.error;
    if (error != null) {
      Error.throwWithStackTrace(error, value.stack!);
    }
    return value.row;
  }

  @override
  Iterable<String> get keys =>
      reads.entries.where((entry) => entry.value.row != null || entry.value.error != null).map((entry) => entry.key);
  @override
  void operator []=(String key, StoredAgentRun value) => throw UnsupportedError('Captured audits are read-only.');
  @override
  void clear() => throw UnsupportedError('Captured audits are read-only.');
  @override
  StoredAgentRun? remove(Object? key) => throw UnsupportedError('Captured audits are read-only.');
}

extension _AuthoringPromptContexts on TavernEngine {
  Future<_AuthoringPromptContextCapture> _captureAuthoringPromptContext(
    TavernAuthoringPromptRequest request,
    String captureId,
    ModelCancellation cancellation, {
    _AuthoringPromptHostOwner? hostOwner,
    bool simulationBootstrap = false,
  }) async {
    cancellation.check();
    final storedDraft = _requireAuthoringDraft(request.draftId, request.draftRevision);
    final draft = _authoringView(storedDraft);
    final candidates = _materializeAuthoring(draft, request.changeIds.toSet(), includeDiffs: false).candidates;
    final draftText = jsonEncode(storedDraft.data);
    final sourceById = {for (final source in draft.sources) source.physicalResourceId: source};
    final simulationSources = simulationBootstrap
        ? <String, Map<String, Object?>>{
            for (final source in (storedDraft.data['sources']! as List<Object?>).cast<Map<String, Object?>>())
              _authoringTarget(source['target']! as Map<String, Object?>).physicalResourceId: source,
          }
        : null;
    final simulationSettings = simulationBootstrap ? _copy(_document) : null;
    final domain = _authoringAuthority.domainId;
    final configVersion = _authoringConfigVersion;
    final personaVersion = _personas.authoringVersion;
    final settingsIdentity = _document['settings'];
    final globalSettings = _map(settingsIdentity);
    final settingsText = jsonEncode(globalSettings);
    final globalObservation = _globalVariables.observation;
    Map<String, Object?> global = _runtimeCopy(_globalVariables);
    final capturedGlobal = hostOwner == null
        ? null
        : _ScriptRawVariable(
            _document.containsKey('globalVariables'),
            _copy({'value': _document['globalVariables']})['value'],
          );
    final defaultPresetId = _store.defaultPresetId;
    final context = request.context;
    final real = context is TavernAuthoringChatContext;
    StoredChat chat;
    final TavernGroupChat? group;
    final _TurnKind kind;
    StoredNode? target;
    final String actorId;
    String? parent, sourceFile;
    Map<String, Object?> metadata, initialState, identityState, local;
    final List<StoredNode> history;
    final PersonaSelection persona;
    final TavernModelConfig selectedConfig;
    final ChatJsonlMetadataSource? metadataSource;
    final String versionKey;
    final Object chatVersion;
    final ({String? leaf, Map<String, Object?> values})? liveLocal;
    final String? liveLocalFingerprint;

    // All selected chat facts and identities are captured before the first
    // await. Later conditional reads must pass this same admission guard.
    if (context is TavernAuthoringChatContext) {
      kind = switch (context.generationType) {
        'normal' => _TurnKind.send,
        'regenerate' => _TurnKind.regenerate,
        'continue' => _TurnKind.continueReply,
        'impersonate' => _TurnKind.impersonate,
        _ => throw const TavernAuthoringException('invalid_change', 'Unknown preview generation type.'),
      };
      if (kind != _TurnKind.send && request.text.isNotEmpty) {
        _authoringInvalid('Only normal previews accept new input text.');
      }
      if ((kind == _TurnKind.send || kind == _TurnKind.impersonate) && context.nodeId != null ||
          (kind == _TurnKind.regenerate || kind == _TurnKind.continueReply) && context.nodeId == null) {
        _authoringInvalid('Only regenerate/continue contexts take a required target node.');
      }
      chat = _store.chat(context.chatId);
      versionKey = chat.id;
      chatVersion = _store.displayVersion(versionKey);
      group = _store.groupChat(chat.id);
      target = context.nodeId == null ? null : _store.node(chat.id, context.nodeId!);
      if (target != null && target.message.role != TavernRole.character) {
        _authoringInvalid('The target must be a character message.');
      }
      if (group == null) {
        if (context.actorId != null && context.actorId != chat.characterId) {
          _authoringInvalid('A single chat uses its own character.');
        }
        actorId = chat.characterId;
        selectedConfig = _config;
      } else {
        if (kind == _TurnKind.impersonate) {
          throw const TavernAuthoringException('unsupported_preview', 'Group impersonation is unsupported.');
        }
        final member = group.members.where((value) => value.characterId == context.actorId).firstOrNull;
        if (member == null || target != null && target.message.speakerCharacterId != member.characterId) {
          _authoringInvalid('Select the actual roster actor for this group context.');
        }
        actorId = member.characterId;
        selectedConfig = _groupModelConfig(_config, member.modelRole);
      }
      parent = kind == _TurnKind.regenerate
          ? target!.message.parentId
          : kind == _TurnKind.continueReply
          ? target!.message.nodeId
          : chat.currentLeafId;
      final sourceNode = target ?? (chat.currentLeafId == null ? null : _store.node(chat.id, chat.currentLeafId!));
      metadata = _chatCodec.metadataForCapturedNode(_store, chat, sourceNode);
      final sourceState = sourceNode == null
          ? _store.groupInitialState(chat.id)
          : _stateFromNode(chat.id, sourceNode, chat: chat);
      final rawSource =
          sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
      sourceFile = rawSource is String ? rawSource : null;
      metadataSource = _chatCodec.metadataSourceTargetForState(chat, sourceState);
      initialState = group != null && parent == null
          ? _store.groupInitialState(chat.id)
          : parent == null && chat.currentLeafId == null && kind != _TurnKind.regenerate
          ? _emptyChatState(metadata)
          : _stateAt(chat.id, parent);
      identityState = _stateAt(chat.id, context.nodeId ?? parent);
      liveLocal = _liveVariables[chat.id];
      liveLocalFingerprint = liveLocal == null ? null : _scriptRuntimeFingerprint(liveLocal.values);
      local = kind != _TurnKind.regenerate && liveLocal != null && liveLocal.leaf == parent
          ? _runtimeCopy(liveLocal.values)
          : initialState.containsKey('variables')
          ? _map(initialState['variables'])
          : kind == _TurnKind.regenerate || parent != null && sourceFile != null
          ? <String, Object?>{}
          : _copy(chat.variables);
      history = _historyTo(chat.id, parent);
      persona = _personas.resolve(personaId: chat.personaId);
    } else {
      final sample = context as TavernAuthoringSampleContext;
      final source = sourceById[sample.characterResourceId];
      if (source == null || source.target.kind != TavernAuthoringTargetKind.character) {
        _authoringInvalid('A sample character must be a character source in this draft.');
      }
      actorId = source.target.id;
      kind = _TurnKind.send;
      group = null;
      target = null;
      selectedConfig = _config;
      metadata = <String, Object?>{};
      sourceFile = null;
      metadataSource = null;
      initialState = _copy(sample.state);
      identityState = _copy(sample.state);
      local = _copy(sample.variables);
      history = _authoringSampleHistory(sample, captureId, request.at);
      parent = history.lastOrNull?.message.nodeId;
      chat = StoredChat(
        id: '$captureId:chat',
        characterId: actorId,
        title: '',
        createdAt: request.at,
        updatedAt: request.at,
        metadata: metadata,
        variables: _copy(sample.variables),
        settings: _copy(sample.settings),
        currentLeafId: parent,
        selectedRootId: history.firstOrNull?.message.nodeId,
        personaId: sample.personaId,
        presetId: sample.presetId,
      );
      // Preset commits already invalidate every display token. One fixed
      // cache-only key also covers sample selection without creating a chat.
      versionKey = '\u0000authoring:presets';
      chatVersion = _store.displayVersion(versionKey);
      liveLocal = null;
      liveLocalFingerprint = null;
      persona = _personas.resolve(personaId: sample.personaId);
    }
    final simulationPresets = simulationBootstrap
        ? _store.readAuthoringSimulationPresetRows({?chat.presetId, ?defaultPresetId})
        : null;
    final simulationPersonas = simulationBootstrap
        ? <String, Object?>{
            'version': 1,
            'defaultPersonaId': _personas.defaultPersonaId,
            'personas': [
              for (final id in {?chat.personaId, ?_personas.defaultPersonaId})
                if (_personas.get(id) case final value?) value.toJson(),
            ],
          }
        : null;
    final admissionChat = chat;
    final admissionParent = parent;
    final selectedPath = hostOwner == null || parent == chat.currentLeafId
        ? history
        : real
        ? _historyTo(chat.id, chat.currentLeafId)
        : history;
    final initialGroupState = hostOwner == null
        ? const <String, Object?>{}
        : real
        ? _store.groupInitialState(chat.id)
        : _copy(initialState);
    String? selectedPresetId;
    Map<String, Object?>? presetRaw;
    final presetRows = <String, Map<String, Object?>?>{};
    bool selectPreset(String id) {
      final candidate = candidates['preset:$id'];
      // Retain the native stored-row validation when no draft replaces it.
      final current = candidate == null ? _store.preset(id) : null;
      presetRows[id] = _store.readAuthoringPresetData(id);
      if (candidate == null && current == null) {
        return false;
      }
      selectedPresetId = id;
      if (candidate == null) {
        presetRaw = current!.raw;
      } else {
        final raw = _authoringObject(candidate['raw'], 'The preset raw value must be an object.');
        final envelope = candidate['envelope'] == null
            ? null
            : _authoringObject(candidate['envelope'], 'The preset envelope must be an object.');
        const PresetCodec().validate(raw, envelope: envelope);
        presetRaw = raw;
      }
      return true;
    }

    // Match native bound/inline/default precedence, resolving each referenced
    // ID against the saved candidate before considering a lower fallback.
    // The current row or its absence remains separate seal evidence.
    final boundPresetId = chat.presetId;
    if ((boundPresetId == null || !selectPreset(boundPresetId)) &&
        !chat.settings.containsKey('preset') &&
        defaultPresetId != null) {
      selectPreset(defaultPresetId);
    }
    final presetWorking = _captureAuthoringPresetWorking(globalSettings, admissionChat, selectedPresetId, real: real);
    final director = real ? _directors.latestSuccess(chat.id) : null;
    final rawTurnSettings = _authoringContextSettings(
      globalSettings,
      chat,
      metadata,
      selectedPreset: presetRaw,
      selectedPresetId: selectedPresetId,
      presetWorking: presetWorking,
      managedRegex: const [],
    );
    final admissionSettings = _personaSettings(rawTurnSettings, persona);
    final gameplayAdmission = _captureGameplayAdmission(
      this,
      characterId: actorId,
      chatId: real ? chat.id : null,
      settings: admissionSettings,
    );
    final historicalGameplay = _gameplayHistoricalConfig(this, initialState);
    final savedConfigId = initialState['dshgoPackDefinitionConfigId'];
    final gameplayConfigRows = _store.readGameplayConfigurationRows([
      if (savedConfigId is String && savedConfigId.isNotEmpty) savedConfigId,
    ]);
    final secret = real && kind != _TurnKind.impersonate && _secretsEnabled(admissionSettings)
        ? _store.agentRunsByKind(chat.id, const {'director.secret_proposal'}, limit: 1).firstOrNull
        : null;
    final cardRevision = real ? _directors._cardRevisions[chat.characterId] ?? 0 : 0;
    final links = real && (secret != null || kind == _TurnKind.send && request.text.isNotEmpty)
        ? _store.treeLinks(chat.id).values.toList()
        : <StoredTreeLink>[];
    final physicalParents = {
      for (final link in links)
        if (link.parentId != null) link.parentId!,
    };
    final userSiblingIndex = kind == _TurnKind.send && request.text.isNotEmpty
        ? links.where((link) => !link.deleted && link.parentId == parent).length
        : 0;
    final policyScope = kind == _TurnKind.impersonate ? null : _toolScope(this, chat);
    final scripts = _scripts.captureAuthoringScripts(
      captureId: captureId,
      chatId: real ? chat.id : null,
      metadata: metadata,
      persistentSource: metadataSource,
      isolatedHost: hostOwner != null,
    );
    final resources = <String, _AuthoringCapturedResource>{};
    final pendingResources = <String, Future<_AuthoringCapturedResource>>{};
    final auditReads = <String, _AuthoringAuditRead>{};
    final audits = _AuthoringCapturedAudits(auditReads);
    final secretDefinitions = <String, _AuthoringSecretDefinitionRead>{};
    final reservedProofIds = <String>{if (director != null) director.id, if (secret != null) secret.id};
    final proofs = _AuthoringSecretProofs(
      captureId: captureId,
      chatId: real ? chat.id : null,
      captured: audits,
      capturedDefinitions: secretDefinitions,
      reservedIds: reservedProofIds,
    );

    void checkAdmission() {
      cancellation.check();
      if (real && !_store.toolChatExists(admissionChat.id) ||
          _captureAuthoringPresetWorking(globalSettings, admissionChat, selectedPresetId, real: real).token !=
              presetWorking.token) {
        _authoringContextConflict();
      }
      if (!_gameplayAdmissionCurrent(this, gameplayAdmission)) {
        _authoringContextConflict();
      }
      final currentConfigRows = _store.readGameplayConfigurationRows(gameplayConfigRows.keys);
      for (final entry in gameplayConfigRows.entries) {
        if (currentConfigRows[entry.key] != entry.value) {
          _authoringContextConflict();
        }
      }
      if (_authoringAuthority.domainId != domain ||
          !identical(_authoringConfigVersion, configVersion) ||
          !identical(_personas.authoringVersion, personaVersion) ||
          !identical(_document['settings'], settingsIdentity) ||
          jsonEncode(_map(_document['settings'])) != settingsText ||
          _globalVariables.observation != globalObservation ||
          !identical(_store.displayVersion(versionKey), chatVersion) ||
          _store.defaultPresetId != defaultPresetId) {
        _authoringContextConflict();
      }
      if (real) {
        final current = _liveVariables[chat.id];
        if (current == null || liveLocal == null) {
          if ((current == null) != (liveLocal == null)) {
            _authoringContextConflict();
          }
        } else if (current.leaf != liveLocal.leaf ||
            !identical(current.values, liveLocal.values) ||
            _scriptRuntimeFingerprint(current.values) != liveLocalFingerprint) {
          _authoringContextConflict();
        }
        if ((_directors._cardRevisions[chat.characterId] ?? 0) != cardRevision) {
          _authoringContextConflict();
        }
      }
    }

    Future<_AuthoringCapturedResource> capture(TavernAuthoringTarget target) async {
      final previous = resources[target.physicalResourceId];
      if (previous != null) {
        return previous;
      }
      return pendingResources.putIfAbsent(target.physicalResourceId, () async {
        cancellation.check();
        final value = await _captureAuthoringResource(target, seedDraft: storedDraft);
        cancellation.check();
        resources[target.physicalResourceId] = value;
        return value;
      });
    }

    void captureAudit(String id) {
      if (!real || auditReads.containsKey(id)) {
        return;
      }
      reservedProofIds.add(id);
      try {
        final row = _store.agentRunById(chat.id, id);
        auditReads[id] = (row: row, error: null, stack: null);
        final bindings = row?.result['bindings'];
        if (bindings is List<Object?>) {
          for (final binding in bindings) {
            if (binding is Map<String, Object?>) {
              if (binding['bindingId'] case final String value) {
                reservedProofIds.add(value);
              }
              if (binding['bindReceiptId'] case final String value) {
                reservedProofIds.add(value);
              }
            }
          }
        }
      } catch (error, stack) {
        auditReads[id] = (row: null, error: error, stack: stack);
      }
    }

    void captureSecretDefinition(String id) {
      if (secretDefinitions.containsKey(id)) {
        return;
      }
      try {
        // The raw row, including absence, is independent seal evidence.
        // A parse/read failure stays deferred at this definition's own slot.
        final rows = _store.readGameplayConfigurationRows([id]);
        for (final entry in rows.entries) {
          gameplayConfigRows.putIfAbsent(entry.key, () => entry.value);
        }
        final historical = _gameplayHistoricalConfig(this, {'dshgoPackDefinitionConfigId': id});
        secretDefinitions[id] = (definition: historical.config?.secrets, error: null, stack: null);
      } catch (error, stack) {
        secretDefinitions[id] = (definition: null, error: error, stack: stack);
      }
    }

    void captureLedger(Map<String, Object?> saved) {
      if (!real) {
        return;
      }
      final ledger = _SecretLedger(saved);
      for (final binding in ledger.bindings) {
        reservedProofIds.add(binding['bindingId']! as String);
        final receiptId = binding['bindReceiptId']! as String;
        captureAudit(receiptId);
        final receipt = auditReads[receiptId]?.row;
        if (!_secretProofMatches(receipt, binding)) {
          continue;
        }
        final proposalId = receipt!.result['proposalRunId'];
        if (proposalId is! String || proposalId != binding['proposalRunId']) {
          continue;
        }
        // Child reads keep separate missing/error facts. They cannot erase a
        // successfully captured committed bind receipt.
        captureAudit(proposalId);
        final configId = _secretBindingConfigId(binding, auditReads[proposalId]?.row);
        if (configId != null) {
          captureSecretDefinition(configId);
        }
      }
    }

    if (kind != _TurnKind.impersonate && _secretsEnabled(admissionSettings)) {
      captureLedger(initialState);
    }
    final cards = <String, StoredCharacter>{};
    final cardDocuments = <String, Map<String, Object?>>{};
    for (final id in {chat.characterId, actorId, ...?group?.members.map((value) => value.characterId)}) {
      final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id));
      final document = candidates[resource.target.physicalResourceId] ?? resource.document;
      if (resource.document == null || document == null) {
        continue;
      }
      cardDocuments[id] = document;
      cards[id] = _authoringRuntimeCharacter(resource, document, request.at);
    }
    final host = cards[chat.characterId], actor = cards[actorId];
    if (host == null || actor == null) {
      throw const TavernImportError('角色不存在。');
    }

    for (final id in presetRows.keys) {
      final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: id));
      if (!_stateJsonEqual(resource.document, presetRows[id])) {
        _authoringContextConflict();
      }
    }
    final regex = await capture(
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global'),
    );
    final managedRegex = simulationBootstrap
        ? <Map<String, Object?>>[]
        : candidates['regex-library'] == null
        ? [
            for (final script in regex._regexRecords!) {...script.raw, if (!script.compatible) 'disabled': true},
          ]
        : await _authoringContextRegex(
            candidates['regex-library']!,
            sourceById['regex-library']!.base,
            _regexWorker,
            cancellation,
          );
    final settings = _personaSettings(
      _authoringContextSettings(
        globalSettings,
        chat,
        metadata,
        selectedPreset: presetRaw,
        selectedPresetId: selectedPresetId,
        presetWorking: presetWorking,
        managedRegex: managedRegex,
      ),
      persona,
    );
    _GameplayRuntime? prospectiveGameplay;
    if (gameplayAdmission.hasActivePacks || historicalGameplay.referenced || hostOwner != null) {
      checkAdmission();
      prospectiveGameplay = await _prepareGameplayRuntime(
        this,
        gameplayAdmission,
        hostData: host.card.data,
        settings: settings,
        force: historicalGameplay.referenced || hostOwner != null,
        capturedCards: {
          for (final id in {chat.characterId, actorId, ...?group?.members.map((member) => member.characterId)})
            id: cards[id]?.card.data,
        },
      );
      cancellation.check();
    }
    final gameplay = gameplayAdmission.hasActivePacks || historicalGameplay.referenced ? prospectiveGameplay : null;
    final config = TavernModelConfig(
      apiKey: _noAuthoringTransportKey,
      model: selectedConfig.model,
      deepseek: selectedConfig.deepseek,
      thinking: selectedConfig.thinking,
    );
    final turn = _Turn(
      chat,
      kind,
      group != null && kind == _TurnKind.send ? '' : request.text,
      target?.message.nodeId,
      null,
      config,
      settings,
      request.at,
      persona,
      metadata,
      sourceFile,
      selectedPresetId,
      actorId: actorId,
      groupView: group == null ? null : _GroupView(group, host, cards),
      previewId: captureId,
      previewCancellation: cancellation,
      gameplayAdmission: gameplayAdmission,
      gameplay: gameplay,
    );
    turn.gameplayPreviousConfig = historicalGameplay.config;
    turn.gameplayResources = _resolveGameplayResources(
      _GameplayResourceCapture.fromAdmission(gameplayAdmission),
      settings,
      actorId: actorId,
    );
    turn.originalTarget = target;
    turn.directorCaptured = director;
    turn.secretCaptured = secret;
    turn.secretCardRevision = cardRevision;
    turn.variables = local;
    turn.state = _copy(initialState);
    if (sourceFile != null) {
      turn.state['chatJsonlSourceFile'] = sourceFile;
    }
    turn.inspection = turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null);
    turn.scriptInjectionUses = scripts.uses;
    final data = _effectiveCard(actor.card.data, settings);
    final hostData = _effectiveCard(host.card.data, settings);
    turn.directorCard = _copy(hostData);
    if (kind != _TurnKind.impersonate) {
      final roundPolicy = group != null && kind == _TurnKind.send;
      final hostPolicy = captureToolCardPolicy(
        roundPolicy ? host.card.data : _authoringPolicyCard(cardDocuments[host.id]!, host),
        characterId: host.id,
      );
      final actorPolicy = actor.id == host.id
          ? hostPolicy
          : captureToolCardPolicy(
              roundPolicy ? actor.card.data : _authoringPolicyCard(cardDocuments[actor.id]!, actor),
              characterId: actor.id,
            );
      turn.toolPolicyScope = policyScope;
      turn.toolPolicy = captureToolPolicy(scope: policyScope!, host: hostPolicy, actor: actorPolicy);
    }

    final random = Random(request.seed);
    String? macroChatIdentity;
    final preparedGroupRegexTrace = <Map<String, Object?>>[];
    var groupUserPrepared = false;
    _AuthoringScriptWorkspace? workspace;
    if (hostOwner != null) {
      checkAdmission();
      final localWorkspace = workspace = _AuthoringScriptWorkspace(
        turn: turn,
        scripts: scripts,
        history: history,
        currentPath: selectedPath,
        global: global,
        storedGlobal: capturedGlobal!,
        groupInitial: initialGroupState,
        liveLocal: liveLocal == null ? null : (leaf: liveLocal.leaf, values: _runtimeCopy(liveLocal.values)),
        rawHostData: host.card.data,
        prospectiveGameplay: prospectiveGameplay,
        settingsForMetadata: (currentChat, currentMetadata) => _authoringContextSettings(
          globalSettings,
          currentChat,
          currentMetadata,
          selectedPreset: presetRaw,
          selectedPresetId: selectedPresetId,
          presetWorking: presetWorking,
          managedRegex: managedRegex,
        ),
        readNode: (id) {
          checkAdmission();
          if (!real) {
            final node = selectedPath.firstWhere((value) => value.message.nodeId == id);
            return (node: node, state: _copy(initialState), rawExtra: node.extra);
          }
          final node = _store.node(chat.id, id);
          return (
            node: node,
            state: _stateFromNode(chat.id, node, chat: admissionChat),
            rawExtra: _store.rawNodeExtra(chat.id, id),
          );
        },
      );
      global = localWorkspace.globals;
      macroChatIdentity = _macroChatIdentity(
        chat,
        identityState,
        metadata,
        sourceFile,
        node: target ?? history.lastOrNull,
      );
      final beforeGlobals = localWorkspace.globals.revision;
      final prepared = _prepareAuthoringGroupUser(
        turn,
        history: history,
        parent: parent,
        actorData: data,
        global: global,
        random: random,
        macroChatIdentity: macroChatIdentity,
        input: request.text,
        captureId: captureId,
        userSiblingIndex: userSiblingIndex,
        regexTrace: preparedGroupRegexTrace,
        saveGlobals: () => localWorkspace.saveGroupGlobals(beforeGlobals),
      );
      if (prepared != null) {
        groupUserPrepared = true;
        if (parent != null) {
          physicalParents.add(parent);
        }
        parent = prepared.parent;
        macroChatIdentity = prepared.macroChatIdentity;
        localWorkspace.adoptGroupUser();
      }
      final reader = hostOwner.reader = _AuthoringRenderReader(cancellation, candidates, capture);
      await hostOwner.open(
        TavernAuthoringPromptHostCapture(
          request: TavernAuthoringPromptRequest.fromJson(_copy(request.toJson())),
          captureId: captureId,
          contexts: scripts.activeContexts,
          workspace: localWorkspace.publicView(),
          resources: {
            for (final resource in resources.values)
              resource.target.physicalResourceId: _renderResourceView(
                resource,
                candidates[resource.target.physicalResourceId],
              ),
          },
          reader: reader,
        ),
        localWorkspace,
      );
      await hostOwner.prepare(request.requestId, captureId);
      final metadataNode = target?.message.nodeId ?? localWorkspace.chat.currentLeafId;
      final postHookMetadata = localWorkspace.metadataFor(metadataNode);
      final postHookSource = _chatCodec.metadataSourceTargetForState(
        localWorkspace.chat,
        metadataNode == null ? const {} : localWorkspace.stateAt(metadataNode),
      );
      await hostOwner.filter(request.requestId, captureId, postHookMetadata, postHookSource);
      // Native preparation rereads its operation target and parent after the
      // scripts. Message writes change only their physical local carrier.
      // A sample has no active live contexts. Merely supplying a reader host
      // must retain its independent state and variables inputs unchanged.
      if (real) {
        chat = localWorkspace.chat;
        if (target != null) {
          target = localWorkspace.node(target.message.nodeId).node;
        }
        parent = kind == _TurnKind.regenerate
            ? target!.message.parentId
            : kind == _TurnKind.continueReply
            ? target!.message.nodeId
            : chat.currentLeafId;
        final sourceNodeId = target?.message.nodeId ?? chat.currentLeafId;
        final sourceState = localWorkspace.stateAt(sourceNodeId);
        metadata = localWorkspace.metadataFor(sourceNodeId);
        final rawSource =
            sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
        sourceFile = rawSource is String ? rawSource : null;
        initialState = parent == null && group == null && chat.currentLeafId == null && kind != _TurnKind.regenerate
            ? _emptyChatState(metadata)
            : localWorkspace.stateAt(parent);
        identityState = localWorkspace.stateAt(target?.message.nodeId ?? parent);
        final runtimeLocal = localWorkspace.liveLocal;
        local = kind != _TurnKind.regenerate && runtimeLocal != null && runtimeLocal.leaf == parent
            ? _runtimeCopy(runtimeLocal.values)
            : initialState.containsKey('variables')
            ? _map(initialState['variables'])
            : kind == _TurnKind.regenerate || parent != null && sourceFile != null
            ? <String, Object?>{}
            : _copy(chat.variables);
        turn.originalTarget = target;
        turn.metadata = metadata;
        turn.sourceFile = sourceFile;
        turn.variables = local;
        turn.state = _copy(initialState);
        turn.gameplay = gameplayAdmission.hasActivePacks || initialState.containsKey('dshgoPackDefinitionConfigId')
            ? prospectiveGameplay
            : null;
        turn.gameplayPreviousConfig =
            prospectiveGameplay != null &&
                initialState['dshgoPackDefinitionConfigId'] == prospectiveGameplay.effectiveConfigId
            ? prospectiveGameplay
            : historicalGameplay.config;
        if (sourceFile != null) {
          turn.state['chatJsonlSourceFile'] = sourceFile;
        }
        turn.inspection = turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null);
        macroChatIdentity = _macroChatIdentity(
          chat,
          identityState,
          metadata,
          sourceFile,
          node: target ?? history.lastOrNull,
        );
      }
    }

    checkAdmission();
    Map<String, Object?> readState(String? id) => workspace?.stateAt(id) ?? _stateAt(chat.id, id);
    Map<String, Object?> readDirectorSource(String? id) {
      final localWorkspace = workspace;
      if (localWorkspace == null) {
        return _directorSource(this, chat.id, id);
      }
      final sourceHistory = id == null
          ? <StoredNode>[]
          : history.take(history.indexWhere((node) => node.message.nodeId == id) + 1).toList();
      final saved = id == null && group == null
          ? _emptyChatState(localWorkspace.metadataFor(chat.currentLeafId))
          : localWorkspace.stateAt(id);
      return _directorSourceFromFacts(id, sourceHistory, group, saved);
    }

    Map<String, Object?>? currentSettings;
    Map<String, Object?> readCurrentSettings() {
      if (currentSettings case final value?) {
        return value;
      }
      final currentMetadata = real
          ? workspace?.metadataFor(chat.currentLeafId) ?? _chatCodec.metadataForNode(_store, chat.id)
          : metadata;
      return currentSettings = _authoringContextSettings(
        globalSettings,
        chat,
        currentMetadata,
        selectedPreset: presetRaw,
        selectedPresetId: selectedPresetId,
        presetWorking: presetWorking,
        managedRegex: managedRegex,
      );
    }

    turn.gameplayInitializing = parent == null && chat.currentLeafId == null;
    turn.gameplayValueEligible = _gameplayValueIssues(
      turn.gameplay,
      turn.currentState,
      initializing: turn.gameplayInitializing,
      previousConfig: turn.gameplayPreviousConfig,
    ).isEmpty;

    // The binding wrapper reads current settings before its disabled gate;
    // final injections read them only when this turn enabled secrets.
    if (secret != null || kind != _TurnKind.impersonate && _secretsEnabled(settings)) {
      readCurrentSettings();
    }
    final contextPath = history.map((node) => node.message.nodeId).toList();
    Map<String, Object?>? directorSource, capturedDirectorSource;
    var authorizationSource = <String, Object?>{};
    var storyState = <String, Object?>{};
    var directorEligible = false;
    TavernDirectorRun? directorOnPath;
    if (director != null && kind != _TurnKind.impersonate) {
      try {
        final run = _directorRun(director);
        if (!(run.sourceKind == 'empty' && kind == _TurnKind.regenerate) &&
            _directorPathReason(run, parent, contextPath) == null) {
          directorOnPath = run;
          directorSource = readDirectorSource(run.sourceNodeId);
          capturedDirectorSource = directorSource;
          if (_directorSourceReason(
                run,
                hostData,
                _directorPersona(persona, settings),
                directorSource,
                effectiveConfigId: turn.gameplay?.effectiveConfigId,
              ) ==
              null) {
            final current = readCurrentSettings();
            final authorizationState = parent == null && group == null
                ? _emptyChatState(
                    workspace?.metadataFor(chat.currentLeafId) ?? _chatCodec.metadataForNode(_store, chat.id),
                  )
                : readState(parent);
            authorizationSource = _secretStateSource(authorizationState);
            captureLedger(authorizationState);
            final policy = _ordinarySecretInputFromFacts(
              chat.characterId,
              hostData,
              current,
              authorizationSource,
              proofs,
              gameplay: turn.gameplay,
            ).policy;
            final prior = director.result['secretPolicy'];
            final reason = policy == null && prior == null
                ? null
                : prior is! Map<String, Object?>
                ? 'director_secret_knowledge_changed'
                : _secretKnowledgeReason(policy, prior);
            if (reason == null) {
              final definition = turn.gameplay?.story ?? _storyDefinition(hostData);
              if (definition.defined && definition.executable) {
                storyState = parent == null ? <String, Object?>{} : readState(parent);
              }
              directorEligible =
                  _storyDirectorEligibilityFromState(
                    director,
                    hostData,
                    storyState,
                    definition: definition,
                    gameplay: turn.gameplay,
                  ) ==
                  null;
            }
          }
        }
      } catch (_) {
        // This is precisely the native director eligibility catch, not a
        // fallback for main state, secret binding, or resource I/O errors.
        directorSource = null;
      }
    }
    final current = currentSettings ?? settings;
    final secretFacts = _AuthoringSecretFacts(
      settings: current,
      persona: _directorPersona(persona, _personaSettings(current, persona)),
      cardRevision: cardRevision,
      proofs: proofs,
    );
    final groupUser = group != null && kind == _TurnKind.send && request.text.isNotEmpty;
    StoredAgentRun? persistedProposal;
    Map<String, Object?>? bindingSource, bindingState, bindingExtra;
    // The frozen proposal predates the new group user. Native child binding
    // rejects that old anchor before reading its persisted proposal/extra.
    if (!groupUser &&
        secret != null &&
        _secretBindingDisabled(turn, hostData, current) == null &&
        _secretContextReasonFromFacts(turn, secretFacts) == null &&
        _secretBindingAnchorReason(turn, parent, secret, chat.currentLeafId) == null &&
        !physicalParents.contains(parent) &&
        _secretProposalShapeReason(secret, chat.characterId) == null) {
      captureAudit(secret.id);
      persistedProposal = audits[secret.id];
      if (_secretProposalPersisted(secret, persistedProposal) &&
          _secretPersonaReason(turn, secretFacts.persona) == null) {
        bindingSource = readDirectorSource(parent);
        if (_directorSourceFingerprint(
              bindingSource,
              _directorCard(hostData),
              secretFacts.persona,
              effectiveConfigId: turn.gameplay?.effectiveConfigId,
            ) ==
            secret.result['sourceFingerprint']) {
          bindingState = readState(parent);
          final input = _StateInput(bindingState);
          final protection = _SecretProtection(hostData, bindingState, gameplay: turn.gameplay);
          if (input.writable && input.valueExists && !protection.unknown && protection.definition.executable) {
            bindingExtra = workspace?.node(parent!).rawExtra ?? _store.rawNodeExtra(chat.id, parent!);
          }
        }
      }
    }
    if (kind != _TurnKind.impersonate && _secretsEnabled(settings)) {
      captureLedger(initialState);
    }
    // All finite ledger dependencies are now captured. Include the same old
    // definition rows in the isolated seed without rereading global settings.
    final simulationGameplay = simulationBootstrap
        ? _store.readGameplaySimulationData(gameplayAdmission.snapshot, configIds: gameplayConfigRows.keys)
        : null;
    // The added user preserves every old ancestor but ends an empty source.
    // Default state initialization can change current knowledge; defer these
    // possible reads until the recomputed director's actual consumption gate.
    final captureDirectorDependencies = groupUser
        ? directorOnPath != null && directorOnPath.sourceKind == 'node'
        : directorEligible || bindingExtra != null && directorOnPath != null;
    if (captureDirectorDependencies) {
      final savedDirector = director!;
      final events = directorOnPath!.events;
      for (var index = 0; index < events.length; index++) {
        captureAudit('${savedDirector.id}:event:$index');
      }
    }

    final linked = <WorldInfoBook>[];
    final missing = <Map<String, Object?>>[];
    final bindings = _map(settings['lorebooks']);
    final activeWorldName = metadata['world_info'];
    final activeBookId = activeWorldName is String ? _map(chat.settings['stLorebookIds'])[activeWorldName] : null;
    for (final source in WorldInfoSource.values) {
      final ids = <String>[
        ..._strings(bindings[source.name]),
        if (source == WorldInfoSource.character)
          for (final id in group == null ? [actorId] : [for (final member in group.members) member.characterId])
            ..._characterLinkedBookIds(
              settings,
              id,
              embedded: group == null
                  ? data.containsKey('character_book')
                  : (cards[id]?.card.data.containsKey('character_book') ?? false),
            ),
        if (source == WorldInfoSource.persona && persona.persona != null)
          ..._strings(_map(settings['personaLorebooks'])[persona.persona!.id]),
      ];
      for (final id in ids) {
        final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: id));
        final document = candidates[resource.target.physicalResourceId] ?? resource.document;
        if (document == null) {
          missing.add({'bookId': id, 'source': source.name, 'reason': 'missing'});
          continue;
        }
        final raw = _authoringBook(document);
        final envelope = !document.containsKey('entries') && document['format'] == 'dshgo-lorebook';
        linked.add(
          WorldInfoBook.fromJson(
            id: id,
            source: source,
            json: raw,
            stWorldName: activeBookId == id && activeWorldName is String
                ? activeWorldName
                : envelope
                ? document['stWorldName'] as String?
                : null,
          ),
        );
      }
    }
    final embeddedBooks = <WorldInfoBook>[];
    final embedded = group == null
        ? <String, Map<String, Object?>>{actorId: data}
        : {
            for (final member in group.members)
              if (cards[member.characterId] case final value?) member.characterId: value.card.data,
          };
    for (final entry in embedded.entries) {
      if (entry.value['character_book'] case final Map<String, Object?> book) {
        embeddedBooks.add(
          WorldInfoBook.fromJson(id: '${entry.key}:card', source: WorldInfoSource.character, json: book),
        );
      }
    }
    final loaded = _mergeGameplayBooks(linked, embeddedBooks, turn.gameplayResources);
    checkAdmission();
    var legacy = const _AuthoringCapturedLegacy([]);
    if (real && captureDirectorDependencies) {
      try {
        legacy = _AuthoringCapturedLegacy(_store.directorMemories(chat.id));
      } catch (error, stack) {
        legacy = _AuthoringCapturedLegacy(const [], error: error, stack: stack);
      }
    }
    // Appending a local group user changes no existing source body/epoch or
    // ancestor membership, so the captured remember qualification is stable.
    final remembered = real
        ? _store.rememberMemories(chat.id, requestedLeafId: admissionParent)
        : <StoredRememberMemory>[];
    final legacyText = _authoringLegacyText(legacy.rows), rememberedText = _authoringRememberedText(remembered);
    if (hostOwner != null) {
      hostOwner.reader!.closeAdmission();
      await hostOwner.reader!.drain();
    }
    await _recheckCapturedAuthoringResources(
      resources.values,
      check: () {
        checkAdmission();
        final freshDraft = _store.readAuthoringDraftData(request.draftId);
        if (freshDraft == null ||
            freshDraft.revision != request.draftRevision ||
            jsonEncode(freshDraft.data) != draftText) {
          _authoringContextConflict();
        }
        if (simulationPresets != null &&
            !_stateJsonEqual(simulationPresets, _store.readAuthoringSimulationPresetRows(simulationPresets.keys))) {
          _authoringContextConflict();
        }
        if (simulationGameplay != null) {
          final currentCastRows = _store.readGameplayCastImportRows([
            for (final scope in simulationGameplay.scopes)
              for (final binding in scope.bindings) ...binding.castImports.values,
          ]);
          for (final entry in simulationGameplay.castImports.entries) {
            if (!_stateJsonEqual(entry.value, currentCastRows[entry.key])) {
              _authoringContextConflict();
            }
          }
        }
        if (real) {
          if (_authoringAuditText(_directors.latestSuccess(chat.id)) != _authoringAuditText(director)) {
            _authoringContextConflict();
          }
          if (kind != _TurnKind.impersonate &&
              _secretsEnabled(admissionSettings) &&
              _authoringAuditText(
                    _store.agentRunsByKind(chat.id, const {'director.secret_proposal'}, limit: 1).firstOrNull,
                  ) !=
                  _authoringAuditText(secret)) {
            _authoringContextConflict();
          }
          for (final entry in auditReads.entries) {
            // An unreadable dependency is not absent evidence. Its original
            // error remains deferred until an actual pure consumer reaches it.
            if (entry.value.error != null) {
              continue;
            }
            if (_authoringAuditText(_store.agentRunById(chat.id, entry.key)) != _authoringAuditText(entry.value.row)) {
              _authoringContextConflict();
            }
          }
          if (captureDirectorDependencies &&
                  legacy.error == null &&
                  _authoringLegacyText(_store.directorMemories(chat.id)) != legacyText ||
              _authoringRememberedText(_store.rememberMemories(chat.id, requestedLeafId: admissionParent)) !=
                  rememberedText) {
            _authoringContextConflict();
          }
        }
        _scripts.recheckAuthoringScripts(scripts);
        hostOwner?.checkSource();
      },
    );
    return _AuthoringPromptContextCapture(
      turn: turn,
      history: history,
      parent: parent,
      userSiblingIndex: userSiblingIndex,
      actorData: data,
      hostData: hostData,
      global: global,
      random: random,
      macroChatIdentity:
          macroChatIdentity ??
          _macroChatIdentity(chat, identityState, metadata, sourceFile, node: target ?? history.lastOrNull),
      books: loaded,
      missingBooks: missing,
      groupUserPrepared: groupUserPrepared,
      preparedGroupRegexTrace: preparedGroupRegexTrace,
      simulationSeed: simulationBootstrap
          ? _AuthoringSimulationSeed(
              resources: resources,
              candidates: candidates,
              sources: simulationSources!,
              settingsDocument: simulationSettings!,
              global: global,
              personas: simulationPersonas!,
              presetRows: simulationPresets!,
              defaultPresetId: defaultPresetId,
              presetWorking: presetWorking,
              chat: chat,
              history: history,
              state: initialState,
              gameplay: simulationGameplay!,
            )
          : null,
      scripts: scripts,
      secretFacts: secretFacts,
      contextPath: contextPath,
      directorSource: directorSource,
      capturedDirectorSource: capturedDirectorSource,
      authorizationSource: authorizationSource,
      storyState: storyState,
      audits: audits,
      legacy: legacy,
      remembered: remembered,
      physicalParents: physicalParents,
      persistedProposal: persistedProposal,
      bindingSource: bindingSource,
      bindingState: bindingState,
      bindingExtra: bindingExtra,
      origin: {
        'kind': real ? 'chat' : 'sample',
        'chatId': real ? chat.id : null,
        'contextNodeId': parent,
        'gameplay': {
          'domainId': gameplayAdmission.snapshot.domainId,
          'admissionIdentity': gameplayAdmission.identity,
          'effectiveConfigId': turn.gameplay?.effectiveConfigId,
          'historicalReferenced': historicalGameplay.referenced,
          'historicalConfigId': historicalGameplay.config?.effectiveConfigId,
          'historicalIssues': historicalGameplay.issues,
        },
        if (simulationBootstrap) 'semantics': 'captured-file-fresh-open',
        if (simulationBootstrap)
          'regexLoadedRuntimeHash': _directorHash([
            for (final record in regex._regexRecords!)
              {
                'id': record.id,
                'raw': record.raw,
                'diagnostics': [for (final diagnostic in record.diagnostics) diagnostic.toJson()],
              },
          ]),
        'actorId': actorId,
        'generationType': turn.generationType,
        'model': config.model,
        'deepseek': config.deepseek,
        'thinking': config.thinking,
        'presetId': selectedPresetId,
        'presetWorking': {
          'token': presetWorking.token,
          'global': presetWorking.global != null,
          'chat': presetWorking.chat != null,
        },
        'resources': [
          for (final resource in resources.values)
            {
              'physicalResourceId': resource.target.physicalResourceId,
              'seedDraftId': resource.seedDraftId,
              'capturedSnapshot': {
                'origin': resource.seedDraftId == null ? 'existing' : 'seed',
                'present': resource.snapshot.present,
                'hash': _directorHash(resource.snapshot.toJson()),
              },
              'knownAuthority': resource.ledger == null
                  ? null
                  : {
                      'domainId': resource.ledger!.domainId,
                      'revision': resource.ledger!.revision,
                      'snapshotHash': resource.ledger!.snapshot == null
                          ? null
                          : _directorHash(resource.ledger!.snapshot!.toJson()),
                    },
              'candidate': {
                'origin': candidates.containsKey(resource.target.physicalResourceId) ? 'draft' : 'capture',
                if (candidates.containsKey(resource.target.physicalResourceId)) 'draftRevision': request.draftRevision,
                'documentHash': _directorHash(candidates[resource.target.physicalResourceId] ?? resource.document),
              },
            },
        ],
      },
    );
  }
}

Map<String, Object?> _authoringContextSettings(
  Map<String, Object?> global,
  StoredChat? chat,
  Map<String, Object?> metadata, {
  required Map<String, Object?>? selectedPreset,
  required List<Map<String, Object?>> managedRegex,
  String? selectedPresetId,
  _PresetWorkingCapture? presetWorking,
}) {
  var result = chat == null
      ? _copy(global)
      : _merge(
          global,
          _chatMetadataSettings(metadata, _map(chat.settings['stLorebookIds']), _map(global['authorNote'])),
        );
  if (chat != null) {
    result = _merge(result, chat.settings);
  }
  if (selectedPreset != null) {
    result['preset'] = _copy(selectedPreset);
  } else if (chat != null && chat.settings.containsKey('preset')) {
    result['preset'] = _map(chat.settings['preset']);
  }
  result = _applyPresetWorkingSettings(
    result,
    global: global,
    chat: chat,
    selectedSource: _capturedPresetSource(global, chat, selectedPresetId),
    selectedPresetId: selectedPresetId,
    working: presetWorking,
  );
  result.remove('managedRegexScripts');
  if (managedRegex.isNotEmpty) {
    result['managedRegexScripts'] = managedRegex;
  }
  return result;
}

Future<List<Map<String, Object?>>> _authoringContextRegex(
  Map<String, Object?> document,
  Map<String, Object?> base,
  RegexExecutor worker,
  ModelCancellation cancellation,
) async {
  final records = document['scripts'];
  if (document['version'] != 1 || records is! List<Object?>) {
    _authoringInvalid('A regex candidate must contain version 1 and a scripts array.');
  }
  final savedRecords = (base['scripts']! as List<Object?>).whereType<Map<String, Object?>>();
  final result = <Map<String, Object?>>[];
  for (final record in records) {
    if (record is! Map<String, Object?> || record['raw'] is! Map<String, Object?>) {
      _authoringInvalid('A regex candidate record must contain its raw object.');
    }
    cancellation.check();
    final raw = record['raw']! as Map<String, Object?>;
    final saved = record['id'] is String
        ? savedRecords.where((value) => value['id'] == record['id']).firstOrNull
        : null;
    var incompatible = false;
    if (saved != null && _stateJsonEqual(raw, saved['raw'])) {
      // Native execution preserves a saved compatibility decision until the
      // raw script is edited or explicitly rechecked. An unrelated draft
      // change must not silently re-enable it by compiling the same raw.
      final diagnostics = record['diagnostics'];
      if (diagnostics is! List<Object?>) {
        _authoringInvalid('An unchanged regex record must retain its diagnostics array.');
      }
      for (final value in diagnostics) {
        final diagnostic = TavernRegexDiagnostic.fromJson(
          _authoringObject(value, 'A regex diagnostic must be an object.'),
        );
        if (diagnostic.status == TavernRegexCompatibility.incompatible) {
          incompatible = true;
        }
      }
    } else {
      final diagnostic = await inspectRegexScript(raw, worker);
      cancellation.check();
      incompatible = diagnostic.status == TavernRegexCompatibility.incompatible;
    }
    result.add({...raw, if (incompatible) 'disabled': true});
  }
  return result;
}

StoredCharacter _authoringRuntimeCharacter(
  _AuthoringCapturedResource resource,
  Map<String, Object?> document,
  DateTime at,
) {
  final current = resource.character;
  if (current != null && _stateJsonEqual(document, resource.document)) {
    return current;
  }
  final parsed = const CardCodec().decode(Uint8List.fromList(utf8.encode(jsonEncode(document))));
  final format = TavernCardFormat.values.byName(resource.sourceFormat!);
  return StoredCharacter(
    id: resource.target.id,
    importedAt: current?.importedAt ?? at,
    card: TavernCard(
      json: parsed.json,
      assets: {for (final path in resource.mediaRefs) path: resource.media['resources/$path']!},
      png: resource.media['source.png'] ?? (format == TavernCardFormat.png ? resource.media['original.png'] : null),
      avatar: current?.card.avatar,
      originalBytes: resource.media['original.${format.name}'],
      sourceFormat: format,
    ),
  );
}

Map<String, Object?> _authoringPolicyCard(Map<String, Object?> document, StoredCharacter runtime) =>
    document['spec'] == 'chara_card_v3' && document['data'] is Map<String, Object?>
    ? document['data']! as Map<String, Object?>
    : runtime.card.data;

List<StoredNode> _authoringSampleHistory(TavernAuthoringSampleContext sample, String captureId, DateTime at) => [
  for (var index = 0; index < sample.history.length; index++)
    StoredNode(
      message: TavernMessage(
        nodeId: '$captureId:message:$index',
        parentId: index == 0 ? null : '$captureId:message:${index - 1}',
        role: sample.history[index].role,
        speaker:
            sample.history[index].speaker ?? (sample.history[index].role == TavernRole.user ? 'User' : 'Assistant'),
        text: sample.history[index].text,
        reasoning: sample.history[index].reasoning,
        hidden: sample.history[index].hidden,
        at: sample.history[index].at ?? at,
      ),
      depth: index + 1,
      selectedChildId: index + 1 == sample.history.length ? null : '$captureId:message:${index + 1}',
      extra: <String, Object?>{},
      original: <String, Object?>{},
    ),
];

String? _authoringAuditText(StoredAgentRun? value) => value == null
    ? null
    : jsonEncode({
        'id': value.id,
        'chatId': value.chatId,
        'nodeId': value.nodeId,
        'kind': value.kind,
        'at': value.at.microsecondsSinceEpoch,
        'usage': value.usage,
        'result': value.result,
      });
String _authoringLegacyText(List<({String id, Map<String, Object?> entry, bool valid})> values) => jsonEncode([
  for (final value in values) {'id': value.id, 'entry': value.entry, 'valid': value.valid},
]);
String _authoringRememberedText(List<StoredRememberMemory> values) => jsonEncode([
  for (final value in values)
    {
      'id': value.id,
      'rowId': value.rowId,
      'entry': value.entry,
      'available': value.available,
      'reason': value.unavailableReason,
      'source': value.source?.toJson(),
    },
]);
Never _authoringContextConflict() =>
    throw const TavernAuthoringException('capture_conflict', 'An authoring preview context changed during capture.');
