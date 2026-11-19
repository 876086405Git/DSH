part of 'engine.dart';

TavernModelConfig _auxiliaryModelConfig(TavernModelConfig config) =>
    config.auxiliary ??
    TavernModelConfig(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
      model: config.deepseek ? 'deepseek-flash' : config.model,
      deepseek: config.deepseek,
      headers: config.headers,
    );

Map<String, Object?> _directorIssue(String code, {String? id}) => {'kind': 'director', 'code': code, 'id': ?id};

Object? _directorCanonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _directorCanonical(value[key])};
  }
  if (value is List<Object?>) {
    return [for (final item in value) _directorCanonical(item)];
  }
  return value;
}

String _directorHash(Object? value) =>
    crypto.sha256.convert(utf8.encode(jsonEncode(_directorCanonical(value)))).toString();

Map<String, Object?> _directorCard(Map<String, Object?> data) {
  final own = _readMap(_readMap(data['extensions'])['dshgo']);
  return _copy({
    for (final key in const [
      'name',
      'description',
      'personality',
      'scenario',
      'mes_example',
      'creator_notes',
      'first_mes',
      'system_prompt',
      'post_history_instructions',
    ])
      if (data.containsKey(key)) key: data[key],
    if (own.containsKey('story')) 'story': own['story'],
    if (own.containsKey('state')) 'stateDefinition': own['state'],
    if (own.containsKey('director')) 'director': own['director'],
  });
}

Map<String, Object?> _directorPersona(PersonaSelection selection, Map<String, Object?> settings) => {
  'id': selection.persona?.id,
  'name': settings['userName'] is String ? settings['userName'] : 'User',
  'description': settings['persona'] is String ? settings['persona'] : '',
};

Map<String, Object?> _directorSource(TavernEngine engine, String chatId, String? nodeId) {
  final history = engine._store.historyTo(chatId, nodeId);
  final visible = history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
  final group = engine._store.groupChat(chatId);
  final saved = nodeId == null && group == null
      ? _emptyChatState(engine._chatCodec.metadataForNode(engine._store, chatId))
      : engine._stateAt(chatId, nodeId);
  return _directorSourceFromFacts(nodeId, history, group, saved, visible: visible);
}

Map<String, Object?> _directorSourceFromFacts(
  String? nodeId,
  List<StoredNode> history,
  TavernGroupChat? group,
  Map<String, Object?> saved, {
  List<StoredNode>? visible,
}) {
  visible ??= history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
  final input = _StateInput(saved);
  return _copy({
    'kind': nodeId == null ? 'empty' : 'node', 'nodeId': nodeId,
    if (group != null)
      'groupMembers': [
        for (final member in group.members) {'characterId': member.characterId, 'muted': member.muted},
      ],
    // Include every ancestor id to invalidate deletion/reparenting without
    // comparing a later descendant's state with this immutable source.
    'path': [for (final node in history) node.message.nodeId],
    // Older source ancestors may be represented by a saved summary. Keep
    // their body/visibility revision in the eligibility hash without sending
    // their complete text to the helper or comparing later descendants.
    'historyFingerprint': _directorHash([
      for (final node in history)
        {
          'nodeId': node.message.nodeId,
          'role': node.message.role.name,
          'speaker': node.message.speaker,
          'text': node.message.text,
          if (group != null) 'speakerCharacterId': node.message.speakerCharacterId,
          'hidden': node.message.hidden,
          'system': _systemMessage(node),
        },
    ]),
    'recent': [
      for (final node in visible.skip(max(0, visible.length - 12)))
        {
          'nodeId': node.message.nodeId,
          'role': node.message.role.name,
          'speaker': node.message.speaker,
          'text': node.message.text,
          if (group != null) 'speakerCharacterId': node.message.speakerCharacterId,
        },
    ],
    'state': {
      'valueExists': input.valueExists,
      if (input.valueExists) 'value': input.value,
      'variables': saved['variables'],
      'issues': input.issues,
      if (saved.containsKey('dshgoPackDefinitionConfigId')) 'definitionConfigId': saved['dshgoPackDefinitionConfigId'],
    },
    if (saved.containsKey(_storyRuntimeKey)) 'storyRuntime': saved[_storyRuntimeKey],
    if (saved.containsKey(_secretRuntimeKey)) 'secretRuntime': saved[_secretRuntimeKey],
  });
}

String _directorSourceFingerprint(
  Map<String, Object?> source,
  Map<String, Object?> card,
  Map<String, Object?> persona, {
  String? effectiveConfigId,
}) => _directorHash({'source': source, 'card': card, 'persona': persona, 'effectiveConfigId': ?effectiveConfigId});

String? _directorPathReason(TavernDirectorRun run, String? contextNodeId, List<String> path) =>
    run.sourceKind == 'empty'
    ? contextNodeId == null
          ? null
          : 'director_source_not_on_path'
    : path.contains(run.sourceNodeId)
    ? null
    : 'director_source_not_on_path';

String? _directorSourceReason(
  TavernDirectorRun run,
  Map<String, Object?> data,
  Map<String, Object?> persona,
  Map<String, Object?> source, {
  String? effectiveConfigId,
}) =>
    _directorSourceFingerprint(source, _directorCard(data), persona, effectiveConfigId: effectiveConfigId) ==
        run.sourceFingerprint
    ? null
    : 'director_source_changed';

TavernUsage? _directorUsage(Map<String, Object?>? value) {
  if (value == null) {
    return null;
  }
  if (value['promptTokens'] is! int || value['cacheHitTokens'] is! int || value['completionTokens'] is! int) {
    throw const FormatException('Invalid saved director usage.');
  }
  return TavernUsage(
    promptTokens: value['promptTokens']! as int,
    cacheHitTokens: value['cacheHitTokens']! as int,
    completionTokens: value['completionTokens']! as int,
    model: value['model'] as String?,
  );
}

Map<String, Object?>? _directorUsageJson(TavernUsage? usage) => usage == null
    ? null
    : {
        'promptTokens': usage.promptTokens,
        'cacheHitTokens': usage.cacheHitTokens,
        'completionTokens': usage.completionTokens,
        'model': usage.model,
      };

TavernDirectorRun _directorRun(StoredAgentRun stored) {
  final raw = stored.result;
  if (raw['version'] != 1 ||
      raw['sourceKind'] is! String ||
      raw['sourceFingerprint'] is! String ||
      raw['automatic'] is! bool ||
      raw['success'] is! bool ||
      raw['startedAt'] is! String ||
      raw['finishedAt'] is! String ||
      (raw['sourceNodeId'] != null && raw['sourceNodeId'] is! String)) {
    throw const FormatException('Unsupported or invalid saved director run.');
  }
  final success = raw['success']! as bool;
  if ((raw['sourceKind'] != 'node' && raw['sourceKind'] != 'empty') ||
      (raw['sourceKind'] == 'node' && raw['sourceNodeId'] == null) ||
      (raw['sourceKind'] == 'empty' && raw['sourceNodeId'] != null) ||
      stored.kind != (success ? 'director.success' : 'director.failure')) {
    throw const FormatException('Invalid saved director source.');
  }
  if (success) {
    _directorAllowedReferences(stored);
  }
  final output = success ? director_core.DirectOutput.parse(_map(raw['output'])).toJson() : null;
  return TavernDirectorRun(
    id: stored.id,
    chatId: stored.chatId,
    sourceKind: raw['sourceKind']! as String,
    sourceNodeId: raw['sourceNodeId'] as String?,
    sourceFingerprint: raw['sourceFingerprint']! as String,
    startedAt: DateTime.parse(raw['startedAt']! as String),
    finishedAt: DateTime.parse(raw['finishedAt']! as String),
    success: success,
    automatic: raw['automatic']! as bool,
    output: output,
    reportedUsage: _directorUsage(stored.usage),
    failure: raw['failure'] as String?,
    issues: _stateRows(raw['issues']),
  );
}

class _DirectorJob {
  _DirectorJob({
    required this.chatId,
    required this.characterId,
    required this.nodeId,
    required this.source,
    required this.settings,
    required this.persona,
    required this.originalConfig,
    required this.at,
    required this.automatic,
    required this.cardRevision,
    this.card,
    this.secret = false,
    this.group,
    this.gameplay,
    this.gameplayAdmission,
  }) : id = 'director-${_newStateId()}',
       requestKey = _directorHash({
         'source': source,
         'settings': settings,
         'persona': persona,
         'secret': secret,
         if (gameplayAdmission != null) 'gameplayAdmission': gameplayAdmission.identity,
         if (gameplay != null) 'effectiveConfigId': gameplay.effectiveConfigId,
       });
  final String id;
  final String chatId;
  final String characterId;
  final TavernGroupChat? group;
  final String? nodeId;
  final Map<String, Object?> source;
  final Map<String, Object?> settings;
  final Map<String, Object?> persona;
  final TavernModelConfig originalConfig;
  final DateTime at;
  final bool automatic;
  final bool secret;
  final int cardRevision;
  final String requestKey;
  Map<String, Object?>? card;
  _GameplayRuntime? gameplay;
  _GameplayAdmission? gameplayAdmission;
  String fingerprint = '';
  final cancellation = ModelCancellation();
  final result = Completer<TavernDirectorRun>();
  final done = Completer<void>();
  final issues = <Map<String, Object?>>[];
  List<Map<String, Object?>> catalog = [];
  List<Map<String, Object?>> allowedReferences = [];
  Map<String, Object?>? storyPhase;
  Map<String, Object?>? eventCapability;
  state_core.SecretCapability? secretCapability;
  Map<String, Object?>? secretPolicy;
  TavernUsage? usage;
  String? finishReason;
  bool running = false;
  bool discarded = false;
}

/// Apply before constructing a request's existing ModelRequestContext, so
/// native raw-usage observation still sees that outer context unchanged.
ModelCancellation _gameplayRequestCancellation(
  TavernEngine engine,
  _GameplayAdmission? admission,
  ModelCancellation original,
) => admission == null
    ? original
    : _GameplayRequestCancellation(() => _gameplayAdmissionCurrent(engine, admission), original);

ModelCancellation _gameplayResourceRequestCancellation(
  TavernEngine engine,
  _GameplayResourceCapture? capture,
  ModelCancellation original,
) => capture == null
    ? original
    : _GameplayRequestCancellation(() => _gameplayResourcesCurrent(engine, capture), original);

/// Native transport checks after its key await and before each send. Source
/// changes also revoke the rest of an admitted request through its real token.
final class _GameplayRequestCancellation extends ModelCancellation {
  _GameplayRequestCancellation(this.current, this.original);
  final bool Function() current;
  final ModelCancellation original;

  @override
  bool get isCancelled => original.isCancelled;
  @override
  Future<void> get whenCancelled => original.whenCancelled;
  @override
  void cancel() => original.cancel();
  @override
  Future<T> wait<T>(Future<T> operation) {
    check();
    return original.wait(operation);
  }

  @override
  void check() {
    original.check();
    if (!current()) {
      original.cancel();
      original.check();
    }
  }
}

class _DirectorPrepared {
  _DirectorPrepared(this.stored, this.output, this.eligible, this.issues, this.allowed);
  final StoredAgentRun stored;
  final director_core.DirectOutput? output;
  final bool eligible;
  final List<Map<String, Object?>> issues;
  final Set<String> allowed;
  final external = <WorldInfoEntryRef>{};
  final references = <Map<String, Object?>>[];
  String get sourceId => 'dshgo.director.beat:${stored.id}';
}

class _DirectorCoordinator {
  _DirectorCoordinator(this.engine);
  final TavernEngine engine;
  final _changes = StreamController<String>.broadcast();
  final _queues = <String, List<_DirectorJob>>{};
  final _preparations = <_DirectorJob, Future<void>>{};
  final _transient = <String, TavernDirectorRun>{};
  final _transientIssues = <String, List<Map<String, Object?>>>{};
  final _cardRevisions = <String, int>{};
  final _watchHubs = <String, _DirectorWatchHub>{};
  bool _closed = false;
  Stream<String> get changes => _changes.stream;
  Stream<TavernDirectorSnapshot> watch(String chatId) => _DirectorWatcher(this, chatId).stream;
  bool get hasJobs => _queues.values.any((jobs) => jobs.isNotEmpty) || _preparations.isNotEmpty;

  Future<T> _prepareIO<T>(_DirectorJob job, Future<T> operation) {
    // Cancellation stops using the result, but cannot abort filesystem IO.
    // Keep the actual operation (not just its cancellation race) owned until
    // completion so close, deletion and backup cannot race a late tidy/read.
    final tracked = engine._trackOperation(operation);
    final drained = tracked.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _preparations[job] = drained;
    unawaited(
      drained.then<void>((_) {
        if (identical(_preparations[job], drained)) {
          _preparations.remove(job);
        }
        changed(job.chatId);
      }),
    );
    return tracked;
  }

  void changed(String chatId) {
    if (!_closed && !engine._closing && !engine._closed) {
      _changes.add(chatId);
    }
  }

  void changedAll() {
    if (_closed || engine._closing || engine._closed) {
      return;
    }
    for (final chat in engine._store.listChats()) {
      changed(chat.id);
    }
  }

  void characterChanged(String characterId) {
    _cardRevisions.update(characterId, (value) => value + 1, ifAbsent: () => 1);
    if (_closed || engine._closing || engine._closed) {
      return;
    }
    for (final chat in engine._store.listChats(characterId: characterId)) {
      changed(chat.id);
    }
  }

  StoredAgentRun? latestSuccess(String chatId) =>
      engine._store.agentRunsByKind(chatId, const {'director.success'}, limit: 1).firstOrNull;

  bool _enabled(Map<String, Object?> settings) => _map(settings['director'])['enabled'] == true;

  _DirectorJob _capture(
    String chatId, {
    required bool automatic,
    String? nodeId,
    Map<String, Object?>? card,
    Map<String, Object?>? settings,
    PersonaSelection? selection,
    TavernModelConfig? config,
    bool secret = false,
    int? cardRevision,
    _GameplayRuntime? gameplay,
    _GameplayAdmission? gameplayAdmission,
  }) {
    final chat = engine._store.chat(chatId);
    final chosen = selection ?? engine._personas.resolve(personaId: chat.personaId);
    final options = settings ?? _personaSettings(engine._effectiveSettings(chat), chosen);
    final leaf = nodeId ?? chat.currentLeafId;
    final source = _directorSource(engine, chatId, leaf);
    final admission =
        gameplayAdmission ??
        _captureGameplayAdmission(engine, characterId: chat.characterId, chatId: chatId, settings: options);
    return _DirectorJob(
      chatId: chatId,
      characterId: chat.characterId,
      nodeId: leaf,
      source: source,
      settings: _copy(options),
      persona: _directorPersona(chosen, options),
      originalConfig: config ?? engine._config,
      at: engine._clock(),
      automatic: automatic,
      secret: secret,
      cardRevision: cardRevision ?? _cardRevisions[chat.characterId] ?? 0,
      card: card == null ? null : _copy(card),
      group: engine._store.groupChat(chatId),
      gameplay: gameplay,
      gameplayAdmission: admission,
    );
  }

  Future<TavernDirectorRun> manual(String chatId) {
    engine._ensureAdmission();
    final chat = engine._store.chat(chatId);
    if (engine._mainBusy(chatId) ||
        engine._mutations.containsKey(chatId) ||
        engine._deletingCharacters.contains(chat.characterId)) {
      throw const TavernModelException(TavernFailure.busy, 'director_context_busy');
    }
    final job = _capture(chatId, automatic: false);
    for (final current in _queues[chatId] ?? const <_DirectorJob>[]) {
      if (!current.automatic &&
          !current.cancellation.isCancelled &&
          current.requestKey == job.requestKey &&
          current.cardRevision == job.cardRevision &&
          identical(current.originalConfig, job.originalConfig)) {
        return current.result.future;
      }
    }
    _admit(job);
    return job.result.future;
  }

  void _admit(_DirectorJob job) {
    engine._ensureAdmission();
    if (_closed) {
      throw StateError('The director is closed.');
    }
    final queue = _queues.putIfAbsent(job.chatId, () => []);
    final owned = {
      ...queue,
      for (final pending in _preparations.keys)
        if (pending.chatId == job.chatId) pending,
    };
    if (owned.length >= 32) {
      if (job.secret) {
        _publishSecretDirector(this, job, failure: 'director_queue_full');
      } else {
        job.result.complete(_publish(job, failure: 'director_queue_full'));
      }
      job.done.complete();
      return;
    }
    queue.add(job);
    changed(job.chatId);
    if (queue.length == 1) {
      scheduleMicrotask(() => unawaited(_run(job)));
    }
  }

  void afterTurn(_Turn turn) {
    if (_closed ||
        engine._closing ||
        engine._capturingBackup ||
        turn.kind == _TurnKind.impersonate ||
        (turn.finishReason != 'stop' && turn.finishReason != 'tool_calls') ||
        turn.reply == null) {
      return;
    }
    final started = turn.profile?.now;
    try {
      final chat = engine._store.chat(turn.chat.id);
      final selection = engine._personas.resolve(personaId: chat.personaId);
      final settings = _personaSettings(engine._effectiveSettings(chat), selection);
      // A global settings update need not cancel a main turn. Recheck the
      // current effective switch before admitting a newly billable helper.
      if (!_enabled(settings) ||
          engine._mutations.containsKey(chat.id) ||
          engine._deletingCharacters.contains(chat.characterId)) {
        return;
      }
      final lastTick = engine._store.agentRunsByKind(chat.id, const {'director.tick'}, limit: 1).firstOrNull;
      final old = lastTick?.result;
      if (old != null && (old['version'] != 1 || old['count'] is! int || (old['count']! as int) < 0)) {
        _transientIssues[chat.id] = [_directorIssue('invalid_saved_director_counter')];
        changed(chat.id);
        return;
      }
      final count = (old?['count'] as int? ?? 0) + 1;
      final own = _map(settings['director']);
      final cardOptions = turn.gameplay == null
          ? _map(_map(_map(turn.directorCard?['extensions'])['dshgo'])['director'])
          : _map(_map(turn.gameplay!.effectiveDefinitions['effective'])['director']);
      final cadence = director_core.directorEvery(settings: own, card: cardOptions);
      final every = cadence.every;
      final tickId = 'director-tick-${_newStateId()}';
      engine._store.writeAgentRun(
        StoredAgentRun(
          id: tickId,
          chatId: chat.id,
          nodeId: turn.reply!.nodeId,
          kind: 'director.tick',
          at: engine._clock(),
          result: {
            'version': 1,
            'count': count,
            'every': every,
            'scheduled': count % every == 0,
            if (cadence.invalid) 'issue': 'invalid_director_every',
          },
        ),
      );
      if (count % every != 0) {
        return;
      }
      // The frozen card keeps its original revision even if the user edited
      // the live card while this main response was streaming.
      final job = _capture(
        chat.id,
        automatic: true,
        nodeId: turn.reply!.nodeId,
        card: turn.directorCard,
        settings: settings,
        selection: selection,
        cardRevision: turn.secretCardRevision,
        gameplay: turn.gameplay,
        gameplayAdmission: turn.gameplayAdmission,
      );
      if (cadence.invalid) {
        job.issues.add(_directorIssue('invalid_director_every'));
      }
      _admit(job);
      // This separate opt-in spends at most one extra request per due tick.
      // Ordinary output owns the last queue slot when only one remains.
      if (_secretsEnabled(settings) && turn.directorCard != null) {
        final secret = _capture(
          chat.id,
          automatic: true,
          nodeId: turn.reply!.nodeId,
          card: turn.directorCard,
          settings: settings,
          selection: selection,
          secret: true,
          cardRevision: turn.secretCardRevision,
          gameplay: turn.gameplay,
          gameplayAdmission: turn.gameplayAdmission,
        );
        secret.secretCapability = _captureSecretCapability(secret);
        if (secret.secretCapability?.slotIds.isNotEmpty == true) {
          _admit(secret);
        }
      }
    } catch (_) {
      // The main response is already committed and terminal. Its success
      // cannot be undone by an optional background-trigger storage failure.
      _transientIssues[turn.chat.id] = [_directorIssue('director_trigger_failed')];
      changed(turn.chat.id);
    } finally {
      turn.profile?.record('director_after_turn', started!);
    }
  }

  Future<void> _run(_DirectorJob job) async {
    if (job.running || job.done.isCompleted) {
      return;
    }
    job.running = true;
    changed(job.chatId);
    if (job.secret) {
      try {
        await _runSecretDirector(this, job);
      } catch (error) {
        final failure = job.cancellation.isCancelled
            ? 'cancelled:cancelled'
            : error is FormatException
            ? 'invalid_secret_output'
            : 'secret_preparation_failed';
        _publishSecretDirector(this, job, failure: failure);
      }
      _release(job);
      return;
    }
    TavernDirectorRun result;
    try {
      job.cancellation.check();
      if (job.card == null) {
        final record = await job.cancellation.wait(_prepareIO(job, engine._record(job.characterId)));
        if (record == null) {
          throw const TavernModelException(TavernFailure.invalidCard, 'director_character_missing');
        }
        job.card = _effectiveCard(record.card.data, job.settings);
      }
      job.cancellation.check();
      final admission = job.gameplayAdmission!;
      final forceGameplay = _map(job.source['state']).containsKey('definitionConfigId');
      if (job.gameplay == null && (admission.hasActivePacks || forceGameplay)) {
        job.gameplay = await job.cancellation.wait(
          _prepareIO(
            job,
            _prepareGameplayRuntime(
              engine,
              admission,
              hostData: job.card!,
              settings: job.settings,
              force: forceGameplay,
            ),
          ),
        );
        job.cancellation.check();
      }
      final card = _directorCard(job.card!);
      job.fingerprint = _directorSourceFingerprint(
        job.source,
        card,
        job.persona,
        effectiveConfigId: job.gameplay?.effectiveConfigId,
      );
      final resources = _resolveGameplayResources(
        _GameplayResourceCapture.fromAdmission(admission),
        job.settings,
        actorId: job.characterId,
        worldInfoCharacterIds: [job.characterId],
        kinds: const {'lorebook'},
      );
      final loaded = await job.cancellation.wait(
        _prepareIO(
          job,
          engine._loadBooks(
            job.characterId,
            job.card!,
            job.settings,
            gameplayResources: resources,
            personaId: job.persona['id'] as String?,
            checkCancelled: job.cancellation.check,
          ),
        ),
      );
      job.cancellation.check();
      final memory = _directorMemoryBook(engine, job.chatId, job.at);
      job.issues.addAll(memory.issues);
      final withLegacy = [...loaded.loaded, if (memory.book != null) memory.book!];
      final remembered = _rememberMemoryBook(engine, job.chatId, job.nodeId, withLegacy);
      job.issues.addAll(remembered.issues);
      final books = [...withLegacy, if (remembered.book != null) remembered.book!];
      final memoryOwners = <String, WorldInfoBook>{
        if (memory.book case final book?)
          for (final entry in book.entries) entry.uid: book,
        ...remembered.owners,
      };
      final catalog = _directorCatalog(
        books,
        job.chatId,
        strategy: WorldInfoSettings.fromJson(_map(job.settings['worldInfo'])).strategy,
        memoryBook: memory.book,
        memoryOwners: memoryOwners,
      );
      job.catalog = catalog.entries;
      job.issues.addAll(catalog.issues);
      job.issues.addAll([
        for (final missing in loaded.missing) _directorIssue('catalog_book_missing', id: missing['bookId'] as String?),
      ]);
      // An older unprotected card can become protected while this job waits.
      // Read that changed definition before deciding whether the legacy frozen
      // input is still usable; a second edit during this read is unavailable.
      if ((_cardRevisions[job.characterId] ?? 0) != job.cardRevision &&
          !(job.gameplay?.secrets ?? _secretDefinition(job.card!)).defined &&
          !job.source.containsKey('secretRuntime')) {
        final revision = _cardRevisions[job.characterId] ?? 0;
        final current = await job.cancellation.wait(_prepareIO(job, engine._record(job.characterId)));
        job.cancellation.check();
        if (current == null ||
            (_cardRevisions[job.characterId] ?? 0) != revision ||
            _secretDefinition(current.card.data).defined) {
          throw const FormatException('Director protection changed before the request.');
        }
      }
      final currentChat = engine._store.chat(job.chatId);
      final currentSettings = engine._effectiveSettings(currentChat);
      final currentSource = _secretAuthorizationSource(engine, job.chatId, currentChat.currentLeafId);
      final secretInput = _ordinarySecretInput(
        engine,
        job.chatId,
        job.characterId,
        job.card!,
        currentSettings,
        job.source,
        authorizationSource: currentSource,
        gameplay: job.gameplay,
      );
      if (secretInput.policy != null && (_cardRevisions[job.characterId] ?? 0) != job.cardRevision) {
        throw const FormatException('Protected director card changed before the request.');
      }
      if (secretInput.policy != null &&
          !_stateJsonEqual(_currentSecretPersona(engine, currentChat, currentSettings), job.persona)) {
        throw const FormatException('Protected director persona changed before the request.');
      }
      job.secretPolicy = secretInput.policy;
      job.issues.addAll(secretInput.issues);
      String previousNotes = '';
      final previous = latestSuccess(job.chatId);
      if (previous != null) {
        try {
          final run = _directorRun(previous);
          final priorPolicy = previous.result['secretPolicy'];
          // Unprotected ordinary notes keep their established inheritance.
          // Any protected side requires both provenance and current knowledge.
          if ((job.gameplay == null &&
                  !previous.result.containsKey('effectiveConfigId') &&
                  priorPolicy == null &&
                  secretInput.policy == null) ||
              (_eligibility(run, previous, job.card!, job.persona, job.nodeId, gameplay: job.gameplay) == null &&
                  _stateJsonEqual(priorPolicy, secretInput.policy))) {
            previousNotes = run.notes ?? '';
          } else {
            job.issues.add(_directorIssue('previous_notes_context_changed', id: previous.id));
          }
        } catch (_) {
          job.issues.add(_directorIssue('previous_notes_unavailable'));
        }
      }
      final path = (job.source['path']! as List<Object?>).cast<String>();
      final summaries = engine._store.directorSummaries(job.chatId, path, limit: 21);
      if (summaries.length > 20) {
        job.issues.add(_directorIssue('summary_catalog_truncated'));
      }
      final story = _storyDirectorContext(job.card!, job.source, gameplay: job.gameplay);
      job.storyPhase = story.phase;
      job.eventCapability = _cardEventCapability(job.card!, job.settings, gameplay: job.gameplay);
      final groupDirectory = job.group == null
          ? null
          : await job.cancellation.wait(_prepareIO(job, engine._groups.directory(job.group!)));
      final input = jsonEncode({
        'groupMembers': ?groupDirectory,
        'card': secretInput.card,
        'persona': job.persona,
        'summaries': summaries.skip(max(0, summaries.length - 20)).toList(),
        'recent': job.source['recent'],
        'state': secretInput.state,
        'previousNotes': previousNotes,
        'catalog': job.catalog,
        if (secretInput.policy != null) 'releasedFacts': [for (final release in secretInput.releases) release.text],
        if (story.progress != null) 'storyProgress': story.progress,
        if (job.eventCapability != null) 'eventCapability': job.eventCapability,
      });
      if (input.length > 1024 * 1024 || utf8.encode(input).length > 1024 * 1024) {
        throw const TavernModelException(TavernFailure.contextTooLong, 'director_input_limit');
      }
      final config = _auxiliaryModelConfig(job.originalConfig);
      final body = <String, Object?>{
        'messages': [
          {'role': 'system', 'content': director_core.directorSystemPrompt},
          {'role': 'user', 'content': input},
        ],
        'stream': false,
        'max_tokens': 4096,
        if (config.deepseek) 'thinking': {'type': config.thinking ? 'enabled' : 'disabled'},
        'tools': [_gameplayDirectToolDefinition(job.eventCapability, strict: config.deepseek)],
        'tool_choice': config.deepseek && config.thinking
            ? 'auto'
            : {
                'type': 'function',
                'function': {'name': 'direct'},
              },
      };
      final batch = await _receive(job, config, body);
      job.cancellation.check();
      if ((job.finishReason != 'stop' && job.finishReason != 'tool_calls') ||
          !batch.eligibleStructure ||
          batch.issues.isNotEmpty ||
          batch.calls.length != 1) {
        throw const FormatException('A director result requires one complete normal tool call.');
      }
      final call = batch.calls.single;
      if (!call.valid || call.name != 'direct' || call.type != 'function' || call.parameters == null) {
        throw const FormatException('Invalid director tool call.');
      }
      final output = director_core.DirectOutput.parse(call.parameters!, personaName: _string(job.persona['name']));
      job.issues.addAll(output.issues);
      final allowed = {for (final item in job.catalog) _directorRefKey(_map(item['reference']))};
      job.allowedReferences = [
        for (final reference in output.prefetch)
          if (allowed.contains(_directorRefKey(reference))) reference,
      ];
      for (var i = 0; i < output.prefetch.length; i++) {
        if (!allowed.contains(_directorRefKey(output.prefetch[i]))) {
          job.issues.add({'kind': 'director', 'code': 'prefetch_not_in_sent_catalog', 'index': i});
        }
      }
      result = _publish(job, output: output.toJson());
    } catch (error) {
      // A provider can echo its input in an error body. Persist a category,
      // plus only our fixed internal details, never arbitrary provider text.
      const safeDetails = {
        'cancelled',
        'director_character_missing',
        'director_input_limit',
        'no_api_key',
        'request_timeout',
        'http_transport_failed',
        'invalid_response_format',
        'invalid_base_url',
        'model_call_failed',
        'stream_ended_before_finish',
        'invalid_completion_response',
      };
      final failure = error is TavernModelException
          ? '${error.kind.name}:${safeDetails.contains(error.detail) ? error.detail : 'director_model_failed'}'
          : error is FormatException
          ? 'invalid_director_output'
          : 'director_preparation_failed';
      result = _publish(job, failure: failure);
    }
    if (!job.result.isCompleted) {
      job.result.complete(result);
    }
    _release(job);
  }

  Future<ModelToolBatch> _receive(_DirectorJob job, TavernModelConfig config, Map<String, Object?> body) async {
    final complete = Completer<void>();
    final accumulator = ModelToolAccumulator();
    var finishes = 0;
    var badTerminal = false;
    void fail(Object error, StackTrace stack) {
      if (job.cancellation.isCancelled) {
        error = const TavernModelException(TavernFailure.cancelled, 'cancelled');
      }
      if (!complete.isCompleted) {
        complete.completeError(error, stack);
      }
    }

    unawaited(
      job.cancellation.whenCancelled.then<void>(
        (_) => fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'), StackTrace.current),
      ),
    );
    StreamSubscription<ModelDelta>? subscription;
    try {
      final cancellation = _gameplayRequestCancellation(engine, job.gameplayAdmission, job.cancellation);
      cancellation.check();
      subscription = engine._modelClient
          .generate(config: config, body: _copy(body), cancellation: cancellation)
          .listen(
            (delta) {
              if (complete.isCompleted || job.cancellation.isCancelled) {
                return;
              }
              try {
                switch (delta) {
                  case ModelToolFragment():
                    if (finishes != 0) {
                      badTerminal = true;
                    }
                    accumulator.add(delta);
                  case ModelUsage(:final usage):
                    job.usage = usage;
                  case ModelFinished(:final reason):
                    finishes++;
                    job.finishReason = reason;
                  case ModelText():
                  case ModelReasoning():
                    // These channels are neither the direct output nor chat text.
                    if (finishes != 0) {
                      badTerminal = true;
                    }
                }
              } catch (error, stack) {
                fail(error, stack);
              }
            },
            onError: (Object error, StackTrace stack) => fail(error, stack),
            onDone: () {
              if (!complete.isCompleted) {
                complete.complete();
              }
            },
          );
      await complete.future;
      cancellation.check();
      if (finishes != 1 || badTerminal) {
        throw const FormatException('Invalid director terminal sequence.');
      }
      return accumulator.finish();
    } finally {
      // A test/plugin client may ignore cancellation or return a cancel Future
      // that never settles. No late callback can write through this receiver.
      if (!complete.isCompleted) {
        complete.complete();
      }
      if (subscription != null) {
        unawaited(subscription.cancel().then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      }
    }
  }

  TavernDirectorRun _publish(_DirectorJob job, {Map<String, Object?>? output, String? failure}) {
    DateTime now;
    try {
      now = engine._clock();
    } catch (_) {
      now = job.at;
      job.issues.add(_directorIssue('director_clock_unavailable'));
    }
    final raw = <String, Object?>{
      'version': 1,
      'sourceKind': job.nodeId == null ? 'empty' : 'node',
      'sourceNodeId': job.nodeId,
      'sourceFingerprint': job.fingerprint,
      'automatic': job.automatic,
      'startedAt': job.at.toUtc().toIso8601String(),
      'finishedAt': now.toUtc().toIso8601String(),
      'success': output != null && failure == null,
      'failure': failure,
      'output': ?output,
      'allowedReferences': job.allowedReferences,
      'issues': job.issues,
      if (job.storyPhase != null) 'storyPhase': job.storyPhase,
      if (job.eventCapability != null) 'eventCapability': job.eventCapability,
      if (job.secretPolicy != null) 'secretPolicy': job.secretPolicy,
      if (job.gameplay != null) 'effectiveConfigId': job.gameplay!.effectiveConfigId,
    };
    var record = StoredAgentRun(
      id: job.id,
      chatId: job.chatId,
      nodeId: job.nodeId,
      kind: output == null ? 'director.failure' : 'director.success',
      at: now,
      usage: _directorUsageJson(job.usage),
      result: raw,
    );
    if (!job.discarded && !engine._closed) {
      try {
        // Deleting an individual source node keeps an unanchored audit, while
        // sourceNodeId in the result still identifies the now-stale source.
        String? physical = job.nodeId;
        if (physical != null) {
          try {
            engine._store.node(job.chatId, physical);
          } catch (_) {
            physical = null;
          }
        }
        record = StoredAgentRun(
          id: record.id,
          chatId: record.chatId,
          nodeId: physical,
          kind: record.kind,
          at: record.at,
          usage: record.usage,
          result: raw,
        );
        engine._store.transaction(() {
          if (output != null && failure == null) {
            final admission = job.gameplayAdmission;
            if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
              _gameplayCaptureConflict();
            }
            _ensureGameplayConfig(engine, job.gameplay);
          }
          engine._store.writeAgentRun(record);
          if (output != null) {
            final events = _stateRows(output['events']);
            for (var i = 0; i < events.length; i++) {
              final eventTarget = _gameplayPersistedEventTarget(job.eventCapability, events[i]['name']! as String);
              engine._store.writeAgentRun(
                StoredAgentRun(
                  id: '${job.id}:event:$i',
                  chatId: job.chatId,
                  nodeId: physical,
                  kind: 'director.event',
                  at: now,
                  result: {
                    'version': 1, 'runId': job.id, 'source': 'director', 'status': 'pending',
                    'sourceKind': raw['sourceKind'], 'sourceNodeId': job.nodeId,
                    'sourceFingerprint': job.fingerprint, 'createdAt': now.toUtc().toIso8601String(),
                    // Group routing authenticates this position even when the
                    // host defines no executable card event rules.
                    if (job.eventCapability != null || job.group != null) 'outputIndex': i,
                    'name': events[i]['name'], 'data': events[i]['data'],
                    'eventTarget': ?eventTarget,
                  },
                ),
              );
            }
          }
        });
        _transient.remove(job.chatId);
        _transientIssues.remove(job.chatId);
      } catch (_) {
        raw['success'] = false;
        raw['failure'] = 'director_write_failed';
        raw.remove('output');
        raw['issues'] = [...job.issues, _directorIssue('director_result_not_persisted')];
        record = StoredAgentRun(
          id: job.id,
          chatId: job.chatId,
          kind: 'director.failure',
          at: now,
          usage: _directorUsageJson(job.usage),
          result: raw,
        );
        final failed = _directorRun(record);
        _transient[job.chatId] = failed;
        changed(job.chatId);
        return failed;
      }
    }
    changed(job.chatId);
    return _directorRun(record);
  }

  void _release(_DirectorJob job) {
    final queue = _queues[job.chatId];
    queue?.remove(job);
    if (queue?.isEmpty == true) {
      _queues.remove(job.chatId);
    }
    if (!job.done.isCompleted) {
      job.done.complete();
    }
    changed(job.chatId);
    if (queue != null && queue.isNotEmpty && !queue.first.running) {
      final next = queue.first;
      scheduleMicrotask(() => unawaited(_run(next)));
    }
  }

  Future<void> _cancel(List<_DirectorJob> jobs, {bool discard = false}) async {
    for (final job in jobs) {
      job.discarded = discard || job.discarded;
      job.cancellation.cancel();
      if (!job.running && !job.done.isCompleted) {
        if (job.secret) {
          _publishSecretDirector(this, job, failure: 'cancelled:cancelled');
        } else {
          final result = _publish(job, failure: 'cancelled:cancelled');
          if (!job.result.isCompleted) job.result.complete(result);
        }
        _release(job);
      }
    }
    await Future.wait([for (final job in jobs) job.done.future]);
  }

  Future<void> cancelChat(String chatId) async {
    await _cancel(List.of(_queues[chatId] ?? const <_DirectorJob>[]), discard: true);
    await Future.wait([
      for (final entry in _preparations.entries)
        if (entry.key.chatId == chatId) entry.value,
    ]);
    _transient.remove(chatId);
    _transientIssues.remove(chatId);
  }

  Future<void> settingsChanged(String? chatId) async {
    final jobs = <_DirectorJob>[];
    for (final entry in _queues.entries) {
      if (chatId != null && entry.key != chatId) {
        continue;
      }
      final settings = engine._effectiveSettings(engine._store.chat(entry.key));
      if (!_enabled(settings)) {
        jobs.addAll(entry.value.where((job) => job.automatic));
      } else if (!_secretsEnabled(settings)) {
        jobs.addAll(entry.value.where((job) => job.secret));
      }
    }
    await _cancel(jobs);
    if (chatId != null) {
      changed(chatId);
    } else {
      for (final chat in engine._store.listChats()) {
        changed(chat.id);
      }
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await Future.wait([for (final hub in _watchHubs.values.toList()) hub.close()]);
    await _cancel([for (final queue in _queues.values) ...queue]);
    await Future.wait(_preparations.values.toList());
    unawaited(_changes.close());
  }

  // Simulation waits for the finite work admitted by its real turn. This
  // does not cancel a helper or prove its ignored transport cancel drained;
  // the simulation's recording client owns that separate original Future.
  Future<void> drainNaturally(String chatId) async {
    while (true) {
      final pending = <Future<void>>[
        for (final job in _queues[chatId] ?? const <_DirectorJob>[]) job.done.future,
        for (final entry in _preparations.entries)
          if (entry.key.chatId == chatId) entry.value,
      ];
      if (pending.isEmpty) {
        return;
      }
      await Future.wait(pending);
    }
  }

  Future<TavernDirectorSnapshot> read(String chatId) async {
    var chat = engine._store.chat(chatId);
    Map<String, Object?>? readSaved() {
      try {
        return engine._stateAt(chatId, chat.currentLeafId);
      } on StateError {
        // An unreadable ancestry is unknown history, never an empty carrier.
        return null;
      }
    }

    var observedState = readSaved();
    var observedHistory = observedState == null ? null : _gameplayHistoricalConfig(engine, observedState);
    StoredCharacter? record;
    if (observedHistory?.referenced != true) {
      record = await engine._record(chat.characterId);
      // A read may await IO while close has begun. Re-read the actual
      // selection; a newly adopted reference must not fall back to that card.
      engine._ensureOpen();
      chat = engine._store.chat(chatId);
      observedState = readSaved();
      observedHistory = observedState == null ? null : _gameplayHistoricalConfig(engine, observedState);
    }
    final saved = observedState;
    final historical = observedHistory;
    final currentData = historical != null && !historical.referenced ? record?.card.data : null;
    final selection = engine._personas.resolve(personaId: chat.personaId);
    final issues = <Map<String, Object?>>[
      ...?_transientIssues[chatId],
      ...?historical?.issues,
      if (saved == null) ...[
        _directorIssue('director_source_unavailable'),
        _directorIssue('director_story_snapshot_unavailable'),
        _directorIssue('director_event_snapshot_unavailable'),
      ],
    ];
    final groupSelection = engine._store.agentRunsByKind(chatId, const {'group.selection'}, limit: 1).firstOrNull;
    if (groupSelection != null) {
      issues.addAll(_stateRows(groupSelection.result['issues']));
    }
    Map<String, Object?>? readSettings() {
      try {
        return _personaSettings(engine._effectiveSettings(chat), selection);
      } catch (_) {
        // Metadata can require the current state chain. An unreadable chain
        // cannot be replaced by global/default settings or grant eligibility.
        issues.add(_directorIssue('director_settings_unavailable'));
        return null;
      }
    }

    final settings = readSettings();
    final storedSuccess = latestSuccess(chatId);
    final storedAttempt = engine._store.agentRunsByKind(chatId, const {
      'director.success',
      'director.failure',
    }, limit: 1).firstOrNull;
    TavernDirectorRun? decode(StoredAgentRun? stored) {
      if (stored == null) {
        return null;
      }
      try {
        return _directorRun(stored);
      } catch (_) {
        issues.add(_directorIssue('saved_director_run_unavailable', id: stored.id));
        return null;
      }
    }

    final success = decode(storedSuccess);
    final attempt = _transient[chatId] ?? (storedAttempt?.id == storedSuccess?.id ? success : decode(storedAttempt));
    var stale = storedSuccess != null;
    if (success != null) {
      // The saved definition contains no complete historical prose card.
      // It can interpret the ledger, but cannot prove a helper's full input.
      final reason = historical == null || historical.referenced
          ? 'director_source_unavailable'
          : currentData == null
          ? 'director_character_missing'
          : settings == null
          ? 'director_source_unavailable'
          : _eligibility(
              success,
              storedSuccess!,
              _effectiveCard(currentData, settings),
              _directorPersona(selection, settings),
              chat.currentLeafId,
            );
      stale = reason != null;
      if (reason != null && saved != null) {
        issues.add(_directorIssue(reason, id: success.id));
      }
    }
    final queue = _queues[chatId] ?? const <_DirectorJob>[];
    final owned = {
      ...queue,
      for (final job in _preparations.keys)
        if (job.chatId == chatId) job,
    };
    Map<String, Object?>? readSnapshot(String issue, Map<String, Object?>? Function(Map<String, Object?>) read) {
      if (settings == null && historical?.referenced != true) {
        issues.add(_directorIssue(issue));
        return null;
      }
      try {
        // A historical view can still expose its raw carrier and diagnostics.
        // Missing current settings never grants automatic execution.
        return read(settings ?? const {});
      } catch (_) {
        // An unavailable auxiliary view is not an empty or disabled ledger.
        // Keep the main source diagnosis and report this read failure apart.
        issues.add(_directorIssue(issue));
        return null;
      }
    }

    final story = saved == null
        ? null
        : historical != null && historical.referenced
        ? readSnapshot(
            'director_story_snapshot_unavailable',
            (settings) => _storySnapshot(engine, chat, const {}, settings),
          )
        : currentData == null
        ? null
        : readSnapshot(
            'director_story_snapshot_unavailable',
            (settings) => _storySnapshot(engine, chat, _effectiveCard(currentData, settings), settings),
          );
    final eventRules = saved == null
        ? null
        : historical != null && historical.referenced
        ? readSnapshot('director_event_snapshot_unavailable', (settings) {
            final config = historical.config;
            if (config != null) {
              return _cardEventSnapshot(engine, chat, const {}, settings, gameplay: config);
            }
            final leaf = chat.currentLeafId;
            final own = leaf == null ? <String, Object?>{} : _map(engine._store.node(chat.id, leaf).extra['dshgo']);
            return _unresolvedGameplayEventSnapshot(leaf, saved, own, historical.issues);
          })
        : currentData == null
        ? null
        : readSnapshot(
            'director_event_snapshot_unavailable',
            (settings) => _cardEventSnapshot(engine, chat, _effectiveCard(currentData, settings), settings),
          );
    return TavernDirectorSnapshot(
      chatId: chatId,
      automaticEnabled: saved != null && settings != null && _enabled(settings),
      pendingJobs: owned.length,
      running: queue.any((job) => job.running),
      latestSuccess: success,
      latestAttempt: attempt,
      stale: stale,
      issues: issues,
      story: story,
      eventRules: eventRules,
    );
  }

  String? _eligibility(
    TavernDirectorRun run,
    StoredAgentRun stored,
    Map<String, Object?> data,
    Map<String, Object?> persona,
    String? contextNodeId, {
    _GameplayRuntime? gameplay,
  }) {
    try {
      // Do not fetch a source, settings, secret proof or story state before
      // the preceding gate: an unavailable later carrier is not an earlier
      // path failure. Preview uses the same predicates on captured facts.
      final path = run.sourceKind == 'empty' ? const <String>[] : engine._store.ancestorIds(run.chatId, contextNodeId);
      final pathReason = _directorPathReason(run, contextNodeId, path);
      if (pathReason != null) {
        return pathReason;
      }
      final source = _directorSource(engine, run.chatId, run.sourceNodeId);
      final sourceReason = _directorSourceReason(
        run,
        data,
        persona,
        source,
        effectiveConfigId: gameplay?.effectiveConfigId,
      );
      if (sourceReason != null) {
        return sourceReason;
      }
      final secretReason = _secretDirectorEligibility(
        engine,
        stored,
        data,
        engine._effectiveSettings(engine._store.chat(run.chatId)),
        contextNodeId,
        gameplay: gameplay,
      );
      return secretReason ?? _storyDirectorEligibility(engine, stored, data, contextNodeId, gameplay: gameplay);
    } catch (_) {
      return 'director_source_unavailable';
    }
  }

  _DirectorPrepared? prepare(_Turn turn, Map<String, Object?> data, String? parent) {
    final stored = turn.directorCaptured;
    if (stored == null || turn.kind == _TurnKind.impersonate) {
      return null;
    }
    try {
      final run = _directorRun(stored);
      // A first-root regenerate can have an empty prompt prefix, even while
      // the selected path is empty. It starts fresh instead of resuming the
      // saved empty-chat variables that an empty-source director captured.
      final reason = run.sourceKind == 'empty' && turn.kind == _TurnKind.regenerate
          ? 'director_source_not_on_path'
          : _eligibility(
              run,
              stored,
              data,
              _directorPersona(turn.personaSelection, turn.settings),
              parent,
              gameplay: turn.gameplay,
            );
      return _directorPreparation(stored, run, reason);
    } catch (_) {
      return _DirectorPrepared(stored, null, false, [
        _directorIssue('saved_director_run_unavailable', id: stored.id),
      ], const {});
    }
  }

  List<TavernDirectorEvent> events(String chatId, {int limit = 50, String? beforeEventId}) => [
    for (final stored in engine._store.agentRunsByKind(
      chatId,
      const {'director.event'},
      limit: limit,
      beforeId: beforeEventId,
    ))
      _event(stored),
  ];

  TavernDirectorEvent _event(StoredAgentRun stored) => _directorEvent(stored);
}

_DirectorPrepared _directorPreparation(StoredAgentRun stored, TavernDirectorRun run, String? reason) {
  final output = director_core.DirectOutput.parse(run.output!);
  return _DirectorPrepared(stored, output, reason == null, [
    if (reason != null) _directorIssue(reason, id: stored.id),
  ], _directorAllowedReferences(stored));
}

TavernDirectorEvent _directorEvent(StoredAgentRun stored) {
  try {
    final raw = stored.result;
    if (raw['version'] != 1 ||
        raw['source'] != 'director' ||
        raw['status'] != 'pending' ||
        raw['runId'] is! String ||
        raw['name'] is! String ||
        raw['data'] is! String ||
        raw['createdAt'] is! String ||
        raw['sourceFingerprint'] is! String ||
        (raw['sourceKind'] != 'node' && raw['sourceKind'] != 'empty') ||
        (raw['sourceKind'] == 'node' ? raw['sourceNodeId'] is! String : raw['sourceNodeId'] != null)) {
      throw const FormatException('Invalid saved director event.');
    }
    final name = raw['name']! as String;
    final data = raw['data']! as String;
    if (name.isEmpty ||
        name.length > 1024 ||
        utf8.encode(name).length > 1024 ||
        data.length > 16 * 1024 ||
        utf8.encode(data).length > 16 * 1024) {
      throw const FormatException('Invalid saved director event text.');
    }
    return TavernDirectorEvent(
      id: stored.id,
      runId: raw['runId']! as String,
      chatId: stored.chatId,
      name: name,
      data: data,
      createdAt: DateTime.parse(raw['createdAt']! as String),
      sourceKind: raw['sourceKind']! as String,
      sourceNodeId: raw['sourceNodeId'] as String?,
      sourceFingerprint: raw['sourceFingerprint']! as String,
    );
  } catch (_) {
    return TavernDirectorEvent.unavailable(
      id: stored.id,
      chatId: stored.chatId,
      reason: 'invalid_or_unsupported_saved_director_event',
    );
  }
}

String _directorMemoryId(String chatId) => 'dshgo:memory:$chatId';

({WorldInfoBook? book, List<Map<String, Object?>> issues}) _directorMemoryBook(
  TavernEngine engine,
  String chatId,
  DateTime at,
) => _directorMemoryBookFromRows(chatId, at, engine._store.directorMemories(chatId));

({WorldInfoBook? book, List<Map<String, Object?>> issues}) _directorMemoryBookFromRows(
  String chatId,
  DateTime at,
  List<({String id, Map<String, Object?> entry, bool valid})> rows,
) {
  final entries = <String, Object?>{};
  final issues = <Map<String, Object?>>[];
  final id = _directorMemoryId(chatId);
  for (final row in rows) {
    if (!row.valid) {
      issues.add(_directorIssue('memory_json_unavailable', id: row.id));
      continue;
    }
    final entry = row.entry;
    final expires = entry['expiresAt'];
    if (expires != null && expires is! int) {
      issues.add(_directorIssue('memory_expiry_invalid', id: row.id));
      continue;
    }
    if (expires is int && expires <= at.millisecondsSinceEpoch) {
      issues.add(_directorIssue('memory_expired', id: row.id));
      continue;
    }
    // Native fields win over compatibility aliases. Never write this
    // projection back to entry_json or allow entry text to rename its row.
    entries[row.id] = {
      ...entry,
      if (!entry.containsKey('key') && entry.containsKey('keywords')) 'key': entry['keywords'],
      if (!entry.containsKey('constant') && entry.containsKey('pinned')) 'constant': entry['pinned'],
      'uid': row.id,
      'world': id,
    };
  }
  return (
    book: entries.isEmpty
        ? null
        : WorldInfoBook.fromJson(
            id: id,
            source: WorldInfoSource.memory,
            stWorldName: id,
            json: {'name': 'Memory', 'entries': entries},
          ),
    issues: issues,
  );
}

({WorldInfoBook? book, Map<String, WorldInfoBook> owners, List<Map<String, Object?>> issues}) _rememberMemoryBook(
  TavernEngine engine,
  String chatId,
  String? requestedLeafId,
  List<WorldInfoBook> loaded,
) {
  final id = _rememberMemoryBookId(chatId, loaded);
  return _rememberMemoryBookFromRows(id, engine._store.rememberMemories(chatId, requestedLeafId: requestedLeafId));
}

String _rememberMemoryBookId(String chatId, List<WorldInfoBook> loaded) {
  final occupied = {for (final book in loaded) book.id};
  final base = 'dshgo:remember:$chatId';
  var id = base;
  var suffix = 1;
  while (occupied.contains(id)) {
    id = '$base:${suffix++}';
  }
  return id;
}

({WorldInfoBook? book, Map<String, WorldInfoBook> owners, List<Map<String, Object?>> issues})
_rememberMemoryBookFromRows(String id, List<StoredRememberMemory> rows) {
  final entries = <String, Object?>{};
  final issues = <Map<String, Object?>>[];
  for (final row in rows) {
    if (!row.available) {
      issues.add({..._directorIssue('remember_unavailable', id: row.id), 'reason': row.unavailableReason});
      continue;
    }
    entries[row.id] = {...row.entry, 'position': 0, 'uid': row.id, 'world': id};
  }
  if (entries.isEmpty) return (book: null, owners: const <String, WorldInfoBook>{}, issues: issues);
  final book = WorldInfoBook.fromJson(
    id: id,
    source: WorldInfoSource.memory,
    stWorldName: id,
    json: {'name': 'Remembered facts', 'entries': entries},
  );
  // Only a real row projected into this exact book can own a memory reference.
  return (book: book, owners: {for (final entry in book.entries) entry.uid: book}, issues: issues);
}

String _directorRefKey(Map<String, Object?> reference) {
  if (reference['kind'] == 'memory' && reference.length == 2 && reference['id'] is String) {
    return jsonEncode(['memory', reference['id']]);
  }
  if (reference['kind'] == 'worldInfo' &&
      reference.length == 3 &&
      reference['bookId'] is String &&
      reference['uid'] is String) {
    return jsonEncode(['worldInfo', reference['bookId'], reference['uid']]);
  }
  throw const FormatException('Invalid saved director reference.');
}

Set<String> _directorAllowedReferences(StoredAgentRun stored) {
  final references = stored.result['allowedReferences'];
  if (references is! List<Object?> ||
      references.length > 64 ||
      references.any((value) => value is! Map<String, Object?>)) {
    throw const FormatException('Invalid saved director catalog references.');
  }
  return {for (final reference in references) _directorRefKey(reference! as Map<String, Object?>)};
}

({List<Map<String, Object?>> entries, List<Map<String, Object?>> issues}) _directorCatalog(
  List<WorldInfoBook> books,
  String chatId, {
  required WorldInfoStrategy strategy,
  WorldInfoBook? memoryBook,
  Map<String, WorldInfoBook> memoryOwners = const {},
}) {
  final entries = worldInfoExecutionEntries(books, strategy: strategy);
  final counts = <WorldInfoEntryRef, int>{};
  for (final entry in entries) {
    counts.update(entry.identity, (count) => count + 1, ifAbsent: () => 1);
  }
  final result = <Map<String, Object?>>[];
  final issues = <Map<String, Object?>>[];
  final ambiguous = <WorldInfoEntryRef>{};
  var omitted = 0;
  for (final entry in entries) {
    if (counts[entry.identity] != 1) {
      if (ambiguous.add(entry.identity)) {
        issues.add({
          'kind': 'director',
          'code': 'catalog_reference_ambiguous',
          'bookId': entry.book.id,
          'uid': entry.uid,
        });
      }
      continue;
    }
    if (result.length == 512) {
      omitted++;
      continue;
    }
    result.add({
      'reference': identical(entry.book, memoryBook) || identical(entry.book, memoryOwners[entry.uid])
          ? {'kind': 'memory', 'id': entry.uid}
          : {'kind': 'worldInfo', 'bookId': entry.book.id, 'uid': entry.uid},
      'title': entry.comment,
      'bookTitle': entry.book.name,
      'disabled': entry.disabled,
    });
  }
  if (omitted != 0) {
    issues.add({'kind': 'director', 'code': 'director_catalog_truncated', 'omitted': omitted});
  }
  if (books.any((book) => book.id == _directorMemoryId(chatId) && !identical(book, memoryBook))) {
    issues.add(_directorIssue('memory_book_identity_collision'));
  }
  return (entries: result, issues: issues);
}

List<WorldInfoBook> _directorBooks(
  TavernEngine engine,
  _Turn turn,
  List<WorldInfoBook> loaded, {
  required String? requestedLeafId,
}) {
  final prepared = turn.directorPrepared;
  // Legacy eligibility is unchanged. Remembered facts also participate in an
  // ordinary turn with no eligible director result, using its actual branch.
  final legacy = prepared != null && prepared.eligible
      ? _directorMemoryBook(engine, turn.chat.id, turn.at)
      : (book: null, issues: <Map<String, Object?>>[]);
  final withLegacy = [...loaded, if (legacy.book != null) legacy.book!];
  final remembered = _rememberMemoryBook(engine, turn.chat.id, requestedLeafId, withLegacy);
  final result = _directorBooksPrepared(turn, loaded, legacy, remembered);
  if (result.inspection case final inspection?) {
    engine._setInspection(turn, inspection);
  }
  return result.books;
}

({List<WorldInfoBook> books, TavernTurnInspection? inspection}) _directorBooksPrepared(
  _Turn turn,
  List<WorldInfoBook> loaded,
  ({WorldInfoBook? book, List<Map<String, Object?>> issues}) legacy,
  ({WorldInfoBook? book, Map<String, WorldInfoBook> owners, List<Map<String, Object?>> issues}) remembered,
) {
  final prepared = turn.directorPrepared;
  final withLegacy = [...loaded, if (legacy.book != null) legacy.book!];
  final books = [...withLegacy, if (remembered.book != null) remembered.book!];
  TavernTurnInspection? inspection;
  if (prepared != null) {
    prepared.issues.addAll([...legacy.issues, ...remembered.issues]);
  } else if (remembered.issues.isNotEmpty) {
    inspection = turn.inspection.copyWith(
      director: {
        ...turn.inspection.director,
        'remember': {'issues': remembered.issues},
      },
    );
  }
  if (prepared == null || !prepared.eligible) {
    return (books: books, inspection: inspection);
  }
  final memoryOwners = <String, WorldInfoBook>{
    if (legacy.book case final book?)
      for (final entry in book.entries) entry.uid: book,
    ...remembered.owners,
  };
  final view = worldInfoExecutionEntries(
    books,
    strategy: WorldInfoSettings.fromJson(_map(turn.settings['worldInfo'])).strategy,
  );
  final byIdentity = <WorldInfoEntryRef, List<WorldInfoEntry>>{};
  for (final entry in view) {
    byIdentity.putIfAbsent(entry.identity, () => []).add(entry);
  }
  final seen = <String, int>{};
  final references = prepared.output!.prefetch;
  for (var index = 0; index < references.length; index++) {
    final reference = references[index];
    final key = _directorRefKey(reference);
    final previous = seen[key];
    seen.putIfAbsent(key, () => index);
    final memoryReference = reference['kind'] == 'memory';
    final memoryOwner = memoryReference ? memoryOwners[reference['id']] : null;
    final identity = memoryReference
        ? (memoryOwner?.id ?? _directorMemoryId(turn.chat.id), reference['id']! as String)
        : (reference['bookId']! as String, reference['uid']! as String);
    final matches = memoryReference && memoryOwner == null
        ? const <WorldInfoEntry>[]
        : byIdentity[identity] ?? const <WorldInfoEntry>[];
    final inCatalog = prepared.allowed.contains(key);
    final resolved =
        inCatalog &&
        matches.length == 1 &&
        (memoryReference
            ? identical(matches.single.book, memoryOwner)
            : !memoryOwners.values.any((book) => identical(matches.single.book, book)));
    final reason = !inCatalog
        ? 'not_in_sent_catalog'
        : matches.isEmpty
        ? 'entry_not_available'
        : matches.length != 1
        ? 'entry_ambiguous'
        : !resolved
        ? 'entry_kind_changed'
        : null;
    prepared.references.add({
      'index': index,
      'reference': reference,
      'inSentCatalog': inCatalog,
      'resolved': resolved,
      'duplicateOf': ?previous,
      'reason': ?reason,
      if (resolved) 'bookId': identity.$1,
      if (resolved) 'uid': identity.$2,
    });
    if (resolved) {
      prepared.external.add(identity);
    }
  }
  if (loaded.any((book) => book.id == _directorMemoryId(turn.chat.id))) {
    prepared.issues.add(_directorIssue('memory_book_identity_collision'));
  }
  return (books: books, inspection: inspection);
}

List<PromptInjection> _directorInjections(_Turn turn) {
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible || prepared.output!.beat.isEmpty) {
    return [];
  }
  return [
    PromptInjection(
      depth: 1,
      fragment: PromptFragment(
        prepared.output!.beat,
        PromptSource('directorBeat', prepared.sourceId),
        trimOnOverflow: true,
        expandMacros: false,
      ),
    ),
  ];
}

void _captureDirectorAssembly(TavernEngine engine, _Turn turn, PromptAssembly assembly, WorldInfoResult world) {
  final inspection = _directorAssemblyInspection(turn, assembly, world);
  if (inspection != null) {
    engine._setInspection(turn, inspection);
  }
}

TavernTurnInspection? _directorAssemblyInspection(_Turn turn, PromptAssembly assembly, WorldInfoResult world) {
  final prepared = turn.directorPrepared;
  if (prepared == null) {
    return null;
  }
  final observed = <WorldInfoEntryRef>{};
  var beatObserved = false;
  void source(Map<String, Object?> value) {
    if (value['kind'] == 'directorBeat' && value['id'] == prepared.sourceId) {
      beatObserved = true;
    }
    final details = value['details'];
    if (details is! Map<String, Object?>) {
      return;
    }
    if (value['kind'] == 'worldInfo' && details['bookId'] is String && details['uid'] is String) {
      observed.add((details['bookId']! as String, details['uid']! as String));
    }
    for (final key in const ['worldInfo', 'entries']) {
      final nested = details[key];
      if (nested is List<Object?>) {
        for (final item in nested) {
          if (item is Map<String, Object?>) {
            source(item);
          }
        }
      }
    }
  }

  for (final segment in assembly.afterPostProcessing) {
    if (segment.message['content'] == null || segment.message['content'] == '') {
      continue;
    }
    for (final item in segment.sources) {
      source(item.toJson());
    }
  }
  final decisions = {for (final decision in world.externalActivations) (decision.bookId, decision.uid): decision};
  final references = <Map<String, Object?>>[];
  for (final reference in prepared.references) {
    final bookId = reference['bookId'];
    final uid = reference['uid'];
    final identity = bookId is String && uid is String ? (bookId, uid) : null;
    final decision = identity == null ? null : decisions[identity];
    final retained = identity != null && observed.contains(identity);
    references.add({
      ...reference,
      if (decision != null) 'worldInfo': decision.toJson(),
      'finalSourceObserved': retained,
      if (!retained) 'finalReason': 'source_not_observed_in_final_messages',
    });
  }
  return turn.inspection.copyWith(
    director: {
      'version': 1,
      'runId': prepared.stored.id,
      'eligible': prepared.eligible,
      'issues': prepared.issues,
      'beat': {'offered': prepared.eligible && prepared.output!.beat.isNotEmpty, 'finalSourceObserved': beatObserved},
      'prefetch': references,
    },
  );
}
