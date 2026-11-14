part of 'engine.dart';

/// The real host owns definitions. Each actor keeps its own prompt and regex.
class _GroupView {
  _GroupView(this.group, this.host, this.cards);
  final TavernGroupChat group;
  final StoredCharacter host;
  final Map<String, StoredCharacter> cards;
  List<String> get names => [
    for (final member in group.members)
      if (cards[member.characterId] case final card?) card.card.promptName,
  ];
  List<String> get enabledNames => [
    for (final member in group.members)
      if (!member.muted && cards[member.characterId] != null) cards[member.characterId]!.card.promptName,
  ];
}

/// Name-only consumers do not load every member's original card and media.
class _GroupNames {
  _GroupNames(List<String> names, List<String> enabledNames)
    : names = List.unmodifiable(names),
      enabledNames = List.unmodifiable(enabledNames);
  final List<String> names;
  final List<String> enabledNames;
}

TavernGroupChat _groupCopy(
  TavernGroupChat value, {
  String? title,
  List<TavernGroupMember>? members,
  TavernGroupActivation? activation,
  int? limit,
  bool? selfResponses,
}) => TavernGroupChat(
  chatId: value.chatId,
  title: title ?? value.title,
  hostCharacterId: value.hostCharacterId,
  members: members ?? value.members,
  activation: activation ?? value.activation,
  maxSpeakersPerTurn: limit ?? value.maxSpeakersPerTurn,
  allowSelfResponses: selfResponses ?? value.allowSelfResponses,
);

TavernModelConfig _groupModelConfig(TavernModelConfig config, TavernGroupModelRole role) =>
    role == TavernGroupModelRole.main ? config : _auxiliaryModelConfig(config);

class _GroupCoordinator {
  _GroupCoordinator(this.engine);
  final TavernEngine engine;
  final rounds = <String, _GroupRound>{};

  TavernGroupChat require(String id) =>
      engine._store.groupChat(id) ?? (throw TavernGroupException(TavernGroupError.notGroup, chatId: id));

  Future<TavernGroupChat?> read(String id) async {
    final group = engine._store.groupChat(id);
    if (group == null) return null;
    final existing = {for (final card in await engine._characters()) card.id};
    return _groupCopy(
      group,
      members: [
        for (final member in group.members)
          TavernGroupMember(
            characterId: member.characterId,
            talkativeness: member.talkativeness,
            muted: member.muted,
            modelRole: member.modelRole,
            available: existing.contains(member.characterId),
          ),
      ],
    );
  }

  Future<List<Map<String, Object?>>> directory(TavernGroupChat group) async {
    final names = {for (final card in await engine._characters()) card.id: card.name};
    return [
      for (final member in group.members)
        {'characterId': member.characterId, 'name': names[member.characterId], 'muted': member.muted},
    ];
  }

  Future<_GroupNames> captureNames(TavernGroupChat group) async {
    if (engine._deletingCharacters.contains(group.hostCharacterId)) {
      throw TavernGroupException(TavernGroupError.characterNotFound, characterId: group.hostCharacterId);
    }
    final cards = {for (final card in await engine._characters()) card.id: card};
    if (!cards.containsKey(group.hostCharacterId) || engine._deletingCharacters.contains(group.hostCharacterId)) {
      throw TavernGroupException(TavernGroupError.characterNotFound, characterId: group.hostCharacterId);
    }
    final names = <String>[];
    final enabled = <String>[];
    for (final member in group.members) {
      final card = cards[member.characterId];
      if (card == null || engine._deletingCharacters.contains(member.characterId)) continue;
      final nickname = card.nickname;
      final name = nickname != null && nickname.isNotEmpty ? nickname : card.name;
      names.add(name);
      if (!member.muted) enabled.add(name);
    }
    return _GroupNames(names, enabled);
  }

  void _title(String value) {
    if (value.trim().isEmpty) throw TavernGroupException(TavernGroupError.invalidTitle);
  }

  void _limit(int value) {
    if (value < 1) throw TavernGroupException(TavernGroupError.invalidLimit);
  }

  void _talk(double? value) {
    if (value != null && (!value.isFinite || value < 0 || value > 1)) {
      throw TavernGroupException(TavernGroupError.invalidTalkativeness);
    }
  }

  double _initialTalk(StoredCharacter card) {
    final value = card.card.data['talkativeness'] ?? _map(card.card.data['extensions'])['talkativeness'];
    final number = presetJsNumber(value);
    return value == null || !number.isFinite ? 0.5 : number.clamp(0, 1).toDouble();
  }

  Future<StoredCharacter> _card(String id) async {
    if (engine._deletingCharacters.contains(id)) {
      throw TavernGroupException(TavernGroupError.characterNotFound, characterId: id);
    }
    final value = await engine._record(id);
    if (value == null || engine._deletingCharacters.contains(id)) {
      throw TavernGroupException(TavernGroupError.characterNotFound, characterId: id);
    }
    return value;
  }

  Future<_GroupView> capture(TavernGroupChat group, {void Function()? checkCancelled}) async {
    checkCancelled?.call();
    final host = await _card(group.hostCharacterId);
    checkCancelled?.call();
    final cards = <String, StoredCharacter>{};
    for (final member in group.members) {
      checkCancelled?.call();
      final card = member.characterId == host.id ? host : await engine._record(member.characterId);
      checkCancelled?.call();
      if (card != null && !engine._deletingCharacters.contains(member.characterId)) cards[member.characterId] = card;
    }
    return _GroupView(group, host, cards);
  }

  Future<String> create(
    List<String> ids, {
    String? hostCharacterId,
    String? title,
    required TavernGroupActivation activation,
    required int maxSpeakersPerTurn,
    required bool allowSelfResponses,
    required bool addGreetings,
  }) async {
    _limit(maxSpeakersPerTurn);
    if (ids.toSet().length != ids.length || ids.any((id) => id.isEmpty) || (hostCharacterId == null && ids.isEmpty)) {
      throw TavernGroupException(TavernGroupError.invalidMembers);
    }
    final hostId = hostCharacterId ?? ids.first;
    final gameplayAdmission = _captureGameplayAdmission(
      engine,
      characterId: hostId,
      newGroupCharacterIds: ids,
      settings: const {},
    );
    final host = await _card(hostId);
    final resolvedTitle = title ?? host.card.name;
    _title(resolvedTitle);
    final cards = <String, StoredCharacter>{};
    for (final id in ids) {
      cards[id] = id == host.id ? host : await _card(id);
    }
    final selection = engine._personas.resolve();
    final settings = _personaSettings(engine._effectiveSettings(), selection);
    final gameplay = gameplayAdmission.hasActivePacks
        ? await _prepareGameplayRuntime(
            engine,
            gameplayAdmission,
            hostData: host.card.data,
            settings: settings,
            capturedCards: {
              host.id: host.card.data,
              for (final entry in cards.entries) entry.key: entry.value.card.data,
            },
          )
        : null;
    // Keep the original resource gates after the final asynchronous preparation.
    if (engine._deletingCharacters.contains(host.id) || ids.any(engine._deletingCharacters.contains)) {
      throw TavernGroupException(TavernGroupError.characterNotFound);
    }
    if (engine._deletingPersonas.contains(selection.persona?.id) ||
        engine._globalPresetUpdate ||
        engine._deletingPresets.contains(engine._resolvePreset().selection.effectivePresetId)) {
      throw StateError('Group creation resources are changing.');
    }
    final variables = <String, Object?>{};
    final beforeGlobals = engine._globalVariables.revision;
    late final String id;
    try {
      id = engine._store.transaction(() {
        if (!_gameplayAdmissionCurrent(engine, gameplayAdmission)) {
          _gameplayCaptureConflict();
        }
        final id = engine._store.createChat(characterId: host.id, title: resolvedTitle);
        final group = TavernGroupChat(
          chatId: id,
          title: resolvedTitle,
          hostCharacterId: host.id,
          members: [
            for (final memberId in ids)
              TavernGroupMember(
                characterId: memberId,
                talkativeness: _initialTalk(cards[memberId]!),
                muted: false,
                modelRole: memberId == host.id ? TavernGroupModelRole.main : TavernGroupModelRole.helper,
              ),
          ],
          activation: activation,
          maxSpeakersPerTurn: maxSpeakersPerTurn,
          allowSelfResponses: allowSelfResponses,
        );
        engine._store.saveGroup(group);
        final view = _GroupView(group, host, cards);
        var state = <String, Object?>{
          'variables': variables,
          'timedWorldInfo': <String, Object?>{},
          'decoratorState': <String, Object?>{},
          'stChatId': id,
        };
        _initializeDshState(
          gameplay?.state ?? _stateDefinition(host.card.data),
          state,
          settings['stateEnabled'] != false,
          gameplay: gameplay,
        );
        if (gameplay != null && state['dshgoPackDefinitionConfigId'] == gameplay.effectiveConfigId) {
          _ensureGameplayConfig(engine, gameplay);
        }
        engine._store.setGroupInitialState(id, state);
        final history = <StoredNode>[];
        if (addGreetings) {
          for (final member in group.members) {
            final card = cards[member.characterId]!;
            final data = card.card.data;
            var greeting = _string(data['first_mes']);
            if (data['alternate_greetings'] is List) {
              final choices = [
                greeting,
                ..._strings(data['alternate_greetings']),
              ].where((value) => trimJsWhitespace(value).isNotEmpty).toList();
              greeting = choices.isEmpty ? '' : choices[(engine._random() * choices.length).floor()];
            }
            greeting = trimJsWhitespace(greeting);
            if (greeting.isEmpty) continue;
            final gameplayResources = _resolveGameplayResources(
              _GameplayResourceCapture.fromAdmission(gameplayAdmission),
              settings,
              actorId: member.characterId,
              kinds: const {'regex'},
            );
            final environment = _MacroEnvironment(
              data,
              settings,
              variables,
              engine._globalVariables,
              history,
              engine._config,
              engine._clock(),
              engine._random,
              id,
              '',
              'normal',
              characterId: member.characterId,
              groupNames: view.names,
              groupNotMuted: view.enabledNames,
              messageVariables: state['messageVariables'],
              messageVariablesExists: state.containsKey('messageVariables'),
              packRegex: gameplayResources.regex,
            );
            final text = environment
                .expand(
                  environment.regex.apply(
                    greeting,
                    placement: RegexPlacement.aiOutput,
                    expand: environment.regexExpand,
                  ),
                  const {},
                )
                .replaceAll('\r', '');
            state = {...state, 'variables': _copy(variables), 'stChatIdHash': environment.chatIdHash};
            final message = engine._store.append(
              id,
              parentId: history.lastOrNull?.message.nodeId,
              role: TavernRole.character,
              speaker: card.card.promptName,
              speakerCharacterId: member.characterId,
              text: text,
              state: state,
            );
            history.add(engine._store.node(id, message.nodeId));
          }
        }
        engine._store.updateChat(
          id,
          variables: _copy(variables),
          settings: {if (_mvuDeclared(host.card.data)) 'mvuEnabled': true},
          metadata: _runtimeMetadata(engine._store.chat(id).metadata, state),
        );
        return id;
      });
    } catch (createError, createStackTrace) {
      try {
        if (engine._globalVariables.changedSince(beforeGlobals)) {
          await engine._saveDocument();
        }
      } catch (saveError, saveStackTrace) {
        Error.throwWithStackTrace(
          _PreparationSaveFailure(
            createError,
            createStackTrace,
            saveError,
            saveStackTrace,
            operation: 'createGroupChat',
          ),
          saveStackTrace,
        );
      }
      Error.throwWithStackTrace(createError, createStackTrace);
    }
    engine._liveVariables[id] = (leaf: engine._store.chat(id).currentLeafId, values: _runtimeCopy(variables));
    if (engine._globalVariables.changedSince(beforeGlobals)) {
      await engine._saveDocument();
    }
    engine._notifyLists();
    return id;
  }

  Future<TavernGroupChat> add(
    String id,
    String characterId, {
    double? talkativeness,
    required bool muted,
    TavernGroupModelRole? modelRole,
  }) async {
    _talk(talkativeness);
    final group = require(id);
    if (group.members.any((member) => member.characterId == characterId)) {
      throw TavernGroupException(TavernGroupError.memberExists, chatId: id, characterId: characterId);
    }
    final card = await _card(characterId);
    engine._store.saveGroup(
      _groupCopy(
        group,
        members: [
          ...group.members,
          TavernGroupMember(
            characterId: characterId,
            talkativeness: talkativeness ?? _initialTalk(card),
            muted: muted,
            modelRole:
                modelRole ??
                (characterId == group.hostCharacterId ? TavernGroupModelRole.main : TavernGroupModelRole.helper),
          ),
        ],
      ),
    );
    return (await read(id))!;
  }

  Future<TavernGroupChat> updateMember(
    String id,
    String characterId, {
    double? talkativeness,
    bool? muted,
    TavernGroupModelRole? modelRole,
  }) async {
    _talk(talkativeness);
    final group = require(id);
    _member(group, characterId);
    engine._store.saveGroup(
      _groupCopy(
        group,
        members: [
          for (final member in group.members)
            if (member.characterId == characterId)
              TavernGroupMember(
                characterId: characterId,
                talkativeness: talkativeness ?? member.talkativeness,
                muted: muted ?? member.muted,
                modelRole: modelRole ?? member.modelRole,
              )
            else
              member,
        ],
      ),
    );
    return (await read(id))!;
  }

  TavernGroupMember _member(TavernGroupChat group, String id) =>
      group.members.where((member) => member.characterId == id).firstOrNull ??
      (throw TavernGroupException(TavernGroupError.memberNotFound, chatId: group.chatId, characterId: id));
  Future<TavernGroupChat> remove(String id, String characterId) async {
    final group = require(id);
    _member(group, characterId);
    engine._store.saveGroup(
      _groupCopy(group, members: group.members.where((member) => member.characterId != characterId).toList()),
    );
    return (await read(id))!;
  }

  Future<TavernGroupChat> reorder(String id, List<String> ids) async {
    final group = require(id);
    if (ids.length != group.members.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !group.members.any((member) => member.characterId == id))) {
      throw TavernGroupException(TavernGroupError.invalidOrder, chatId: id);
    }
    engine._store.saveGroup(_groupCopy(group, members: [for (final id in ids) _member(group, id)]));
    return (await read(id))!;
  }

  Stream<TavernGroupEvent> send(
    String chatId,
    String input, {
    String? speakerCharacterId,
    void Function(_GroupRound)? onAdmitted,
  }) {
    late StreamController<TavernGroupEvent> controller;
    _GroupRound? admitted;
    controller = StreamController<TavernGroupEvent>(
      onListen: () {
        try {
          engine._ensureOpen();
          if (engine._mainBusy(chatId) || engine._mutations.containsKey(chatId)) {
            throw const TavernModelException(TavernFailure.busy, 'chat_busy');
          }
          final group = require(chatId);
          final chat = engine._store.chat(chatId);
          final persona = engine._personas.resolve(personaId: chat.personaId);
          final preset = engine._resolvePreset(chat).selection;
          if (engine._capturingBackup ||
              engine._mainBusy(chatId) ||
              engine._mutations.containsKey(chatId) ||
              engine._globalPresetUpdate ||
              engine._deletingPresets.contains(preset.effectivePresetId) ||
              engine._deletingPersonas.contains(persona.persona?.id) ||
              engine._deletingCharacters.contains(group.hostCharacterId) ||
              group.members.any((member) => engine._deletingCharacters.contains(member.characterId))) {
            throw const TavernModelException(TavernFailure.busy, 'chat_busy');
          }
          if (speakerCharacterId != null) _member(group, speakerCharacterId);
          final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
          final at = engine._clock();
          final config = engine._config;
          final settings = _personaSettings(engine._effectiveSettings(chat, metadata), persona);
          final gameplayAdmission = _captureGameplayAdmission(
            engine,
            characterId: group.hostCharacterId,
            chatId: chatId,
            settings: settings,
          );
          final round = _GroupRound(
            group,
            input,
            speakerCharacterId,
            at,
            config,
            settings,
            persona,
            preset.effectivePresetId,
            engine._directors.latestSuccess(chatId),
            engine._store.agentRunsByKind(chatId, const {'director.secret_proposal'}, limit: 1).firstOrNull,
            engine._directors._cardRevisions[group.hostCharacterId] ?? 0,
            _toolScope(engine, chat),
            gameplayAdmission,
          );
          admitted = round;
          round.observers.add(controller);
          rounds[chatId] = round;
          onAdmitted?.call(round);
          round.emit(TavernGroupStarted(round.progress));
          unawaited(_run(round));
        } catch (error) {
          final failure = error is TavernModelException
              ? error.kind
              : error is TavernGroupException
              ? TavernFailure.invalidParameters
              : TavernFailure.server;
          final code = error is TavernModelException
              ? error.detail
              : error is TavernGroupException
              ? error.code.name
              : 'group_admission_failed';
          controller.add(
            TavernGroupFinished(
              chatId: chatId,
              reason: TavernGroupEndReason.failed,
              failure: failure,
              code: code,
              detail: _safeDetail(error),
            ),
          );
          unawaited(controller.close());
        }
      },
      onCancel: () {
        admitted?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  Stream<TavernGroupEvent> resume(String id) {
    late StreamController<TavernGroupEvent> controller;
    _GroupRound? observed;
    controller = StreamController<TavernGroupEvent>(
      onListen: () {
        try {
          engine._ensureOpen();
          final round = rounds[id];
          if (round == null) {
            unawaited(controller.close());
            return;
          }
          observed = round;
          round.observers.add(controller);
          final child = round.child;
          controller.add(
            TavernGroupSnapshot(
              progress: round.progress,
              message: child?.reply == null ? null : engine._buffered(child!),
            ),
          );
        } catch (error) {
          controller.add(
            TavernGroupFinished(
              chatId: id,
              reason: TavernGroupEndReason.failed,
              failure: TavernFailure.server,
              code: 'group_resume_failed',
              detail: _safeDetail(error),
            ),
          );
          unawaited(controller.close());
        }
      },
      onCancel: () {
        observed?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  Future<void> _run(_GroupRound round) async {
    _Turn? last;
    try {
      // Finish actual local reads before releasing a cancelled batch.
      round.view = await capture(round.group, checkCancelled: round.cancellation.check);
      round.cancellation.check();
      final view = round.view!;
      final saved = engine._stateAt(round.group.chatId, engine._store.chat(round.group.chatId).currentLeafId);
      final referenced = saved.containsKey('dshgoPackDefinitionConfigId');
      round.gameplay = round.gameplayAdmission.hasActivePacks || referenced
          ? await _prepareGameplayRuntime(
              engine,
              round.gameplayAdmission,
              hostData: view.host.card.data,
              settings: round.settings,
              force: referenced,
              capturedCards: {
                view.host.id: view.host.card.data,
                for (final member in view.group.members) member.characterId: view.cards[member.characterId]?.card.data,
              },
            )
          : null;
      round.cancellation.check();
      final history = engine._historyTo(round.group.chatId, engine._store.chat(round.group.chatId).currentLeafId);
      round.planned.addAll(_select(round, history));
      round.remaining.addAll(round.planned);
      if (round.explicitActor == null && round.group.activation == TavernGroupActivation.director) {
        engine._store.writeAgentRun(
          StoredAgentRun(
            id: '${round.id}:selection',
            chatId: round.group.chatId,
            nodeId: history.lastOrNull?.message.nodeId,
            kind: 'group.selection',
            at: round.at,
            result: {
              'version': 1,
              'roundId': round.id,
              'sourceRunId': round.directorCaptured?.id,
              'plannedCharacterIds': round.planned,
              'issues': round.issues,
            },
          ),
        );
        engine._directors.changed(round.group.chatId);
      }
      if (round.input.isNotEmpty) {
        final actor = round.planned.isEmpty ? round.view!.host : round.view!.cards[round.planned.first]!;
        final config = round.planned.isEmpty
            ? round.config
            : _groupModelConfig(round.config, _member(round.group, round.planned.first).modelRole);
        final message = await engine._appendMessage(
          round.group.chatId,
          round.input,
          narrator: false,
          groupView: round.view,
          actor: actor,
          settingsOverride: round.settings,
          configOverride: config,
          cancellation: round.cancellation,
          gameplayAdmission: round.gameplayAdmission,
          gameplayOverride: round.gameplay,
        );
        round.userNodeId = message.nodeId;
        round.sent = engine._scripts.captureSent(round.group.chatId, message.nodeId);
      }
      round.cancellation.check();
      round.phase = TavernGroupPhase.ready;
      round.emit(TavernGroupProgressChanged(round.progress));
      if (round.planned.isEmpty) {
        _finish(round, TavernGroupEndReason.noSpeakers, detail: round.issues.isEmpty ? null : jsonEncode(round.issues));
        return;
      }
      for (final actorId in round.planned) {
        round.cancellation.check();
        await engine._scripts.drainWrites(round.group.chatId, round.cancellation);
        final chat = engine._store.chat(round.group.chatId);
        final metadata = engine._chatCodec.metadataForNode(engine._store, chat.id);
        final source =
            engine._stateAt(chat.id, chat.currentLeafId)['chatJsonlSourceFile'] ??
            _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
        final member = _member(round.group, actorId);
        final config = _groupModelConfig(round.config, member.modelRole);
        final child = _Turn(
          chat,
          _TurnKind.send,
          '',
          null,
          null,
          config,
          _copy(round.settings),
          engine._clock(),
          round.persona,
          metadata,
          source is String ? source : null,
          round.presetId,
          actorId: actorId,
          groupView: round.view,
          groupRound: round,
          gameplayAdmission: round.gameplayAdmission,
          gameplay: round.gameplay,
        );
        child.directorCaptured = round.directorCaptured;
        child.secretCaptured = _secretsEnabled(round.settings) ? round.secretCaptured : null;
        child.secretCardRevision = round.hostRevision;
        round.child = child;
        round.current = actorId;
        round.generationId = child.generationId;
        round.remaining.removeAt(0);
        round.phase = TavernGroupPhase.speaking;
        round.failed = null;
        child.onEvent = (event) {
          if (event is TavernTurnFailed) round.failed = event;
          round.emit(TavernGroupMemberEvent(progress: round.progress, characterId: actorId, event: event));
        };
        engine._turns[chat.id] = child;
        engine._setInspection(child, child.inspection);
        round.emit(TavernGroupProgressChanged(round.progress));
        await engine._run(child);
        final failure = round.failed;
        if (failure != null) {
          _finish(
            round,
            failure.kind == TavernFailure.cancelled ? TavernGroupEndReason.cancelled : TavernGroupEndReason.failed,
            failure: failure.kind,
            code: failure.kind == TavernFailure.toolFailure
                ? failure.toolFailureCode ?? failure.kind.name
                : failure.kind == TavernFailure.server
                ? 'group_actor_failed'
                : failure.kind.name,
            detail: failure.detail,
            partial: failure.partial,
          );
          return;
        }
        last = child;
        if (child.reply != null) round.completed.add(child.reply!.nodeId);
        round.child = null;
        round.current = null;
        round.generationId = null;
        round.cancellation.check();
      }
      if (last != null) {
        await engine._scripts.drainWrites(round.group.chatId, round.cancellation);
        // Only a complete batch advances the chapter and automatic helper tick.
        last.state = engine._stateAt(last.chat.id, last.reply!.nodeId);
        last.variables = _runtimeCopy(_map(last.state['variables']));
        last.gameplayPreviousConfig = _gameplayHistoricalConfig(engine, last.state).config;
        final gameplayIssues = _gameplayValueIssues(
          last.gameplay,
          last.currentState,
          previousConfig: last.gameplayPreviousConfig,
        );
        last.gameplayValueEligible = gameplayIssues.isEmpty;
        last.statePreparationIssues.addAll(gameplayIssues);
        final story = _settleStoryTurn(engine, last, last.currentState);
        last.storyAttempt = story;
        if (story != null) engine._commitGroupStory(last, story);
        engine._directors.afterTurn(last);
        await engine._scripts.groupSettled(round.group.chatId, round.cancellation);
        round.cancellation.check();
      }
      _finish(round, TavernGroupEndReason.completed);
    } catch (error) {
      final failure = error is TavernModelException
          ? error.kind
          : error is TavernGroupException || error is TavernImportError || error is FormatException
          ? TavernFailure.invalidCard
          : TavernFailure.server;
      _finish(
        round,
        failure == TavernFailure.cancelled ? TavernGroupEndReason.cancelled : TavernGroupEndReason.failed,
        failure: failure,
        code: failure == TavernFailure.server ? 'group_storage_failure' : failure.name,
        detail: _safeDetail(error),
        partial: round.child?.lastCommitted,
      );
    } finally {
      if (identical(rounds[round.group.chatId], round)) rounds.remove(round.group.chatId);
      if (!round.done.isCompleted) round.done.complete();
      for (final observer in round.observers) {
        unawaited(observer.close());
      }
      round.observers.clear();
      engine._scripts.publishSent(round.sent, cancellation: round.cancellation);
      engine._notifyLists();
    }
  }

  void _finish(
    _GroupRound round,
    TavernGroupEndReason reason, {
    TavernFailure? failure,
    String? code,
    String? detail,
    TavernMessage? partial,
  }) {
    if (round.finished) return;
    final attempted = round.current;
    round.current = null;
    round.generationId = null;
    round.phase = TavernGroupPhase.finished;
    if (reason == TavernGroupEndReason.completed || reason == TavernGroupEndReason.noSpeakers) round.remaining.clear();
    round.emit(
      TavernGroupFinished(
        chatId: round.group.chatId,
        reason: reason,
        progress: round.progress,
        failure: failure,
        code: code,
        detail: detail,
        attemptedCharacterId: attempted,
        partial: partial,
      ),
    );
    round.finished = true;
  }

  List<String> _select(_GroupRound round, List<StoredNode> history) {
    final view = round.view!;
    if (round.explicitActor case final id?) {
      if (!view.cards.containsKey(id)) {
        throw const TavernModelException(TavernFailure.invalidCard, 'group_actor_missing');
      }
      return [id];
    }
    final members = round.group.members
        .where((member) => !member.muted && view.cards.containsKey(member.characterId))
        .toList();
    final ids = [for (final member in members) member.characterId];
    final selected = <String>[];
    final last = history.lastOrNull;
    switch (round.group.activation) {
      case TavernGroupActivation.manual:
        return [];
      case TavernGroupActivation.listOrder:
        selected.addAll(ids);
        break;
      case TavernGroupActivation.director:
        selected.addAll(_directorSelection(round, history, ids));
        break;
      case TavernGroupActivation.randomPool:
        if (ids.isEmpty) return [];
        final spoken = <String>{};
        if (round.input.isEmpty) {
          for (final node in history.reversed) {
            if (node.message.role == TavernRole.user) break;
            if (_systemMessage(node) || node.message.role == TavernRole.narrator) continue;
            if (node.message.speakerCharacterId case final id?) spoken.add(id);
          }
        }
        var pool = ids.where((id) => !spoken.contains(id)).toList();
        if (pool.isEmpty) {
          final prior = ids.length > 1 && last?.message.role != TavernRole.user
              ? last?.message.speakerCharacterId
              : null;
          pool = prior == null ? ids : ids.where((id) => id != prior).toList();
        }
        if (pool.isNotEmpty) selected.add(pool[(engine._random() * pool.length).floor()]);
        break;
      case TavernGroupActivation.natural:
        // Adapted from ST 7e8663cd group-chats.js / utils.js (AGPL-3.0).
        // Last system supplies no text, but its name can still ban a speaker.
        final banned =
            !round.group.allowSelfResponses &&
                round.input.isEmpty &&
                last != null &&
                last.message.role != TavernRole.user
            ? last.message.speaker
            : null;
        final text = round.input.isNotEmpty
            ? round.input
            : last == null || _systemMessage(last)
            ? ''
            : last.message.text;
        final words = RegExp(r'\b\w+\b', caseSensitive: false);
        List<String> tokens(String value) => [for (final match in words.allMatches(value)) match[0]!.toLowerCase()];
        for (final word in tokens(text)) {
          for (final id in ids) {
            final name = view.cards[id]!.card.name;
            if (name != banned && tokens(name).contains(word)) {
              selected.add(id);
              break;
            }
          }
        }
        final shuffled = [...members];
        for (var count = shuffled.length; count > 0;) {
          final index = (engine._random() * count).floor();
          count--;
          final value = shuffled[count];
          shuffled[count] = shuffled[index];
          shuffled[index] = value;
        }
        final chatty = <String>[];
        for (final member in shuffled) {
          if (view.cards[member.characterId]!.card.name == banned) continue;
          if (member.talkativeness >= engine._random()) selected.add(member.characterId);
          if (member.talkativeness > 0) chatty.add(member.characterId);
        }
        final naturalPool = chatty.isEmpty ? ids : chatty;
        if (selected.isEmpty && naturalPool.isNotEmpty) {
          selected.add(naturalPool[(engine._random() * naturalPool.length).floor()]);
        }
        break;
    }
    return selected.toSet().take(round.group.maxSpeakersPerTurn).toList();
  }

  List<String> _directorSelection(_GroupRound round, List<StoredNode> history, List<String> enabled) {
    final saved = round.directorCaptured;
    if (saved == null) return [];
    try {
      final run = _directorRun(saved);
      final reason = engine._directors._eligibility(
        run,
        saved,
        _effectiveCard(round.view!.host.card.data, round.settings),
        _directorPersona(round.persona, round.settings),
        history.lastOrNull?.message.nodeId,
        gameplay: round.gameplay,
      );
      if (reason != null) {
        round.issues.add(_directorIssue(reason, id: saved.id));
        return [];
      }
      final output = director_core.DirectOutput.parse(run.output!);
      final consumed = <String>{
        for (final node in history) ..._strings(_map(_map(node.extra['dshgo'])['group'])['directorEventIds']),
      };
      final selected = <String>[];
      for (var index = 0; index < output.events.length; index++) {
        final expected = output.events[index];
        if (expected['name'] != 'group.speaker') continue;
        final eventId = '${saved.id}:event:$index';
        final stored = engine._store.agentRunById(round.group.chatId, eventId);
        final event = stored == null ? null : engine._directors._event(stored);
        if (stored == null ||
            stored.kind != 'director.event' ||
            event == null ||
            !event.available ||
            event.runId != saved.id ||
            event.name != expected['name'] ||
            event.data != expected['data'] ||
            event.sourceKind != run.sourceKind ||
            event.sourceNodeId != run.sourceNodeId ||
            event.sourceFingerprint != run.sourceFingerprint ||
            stored.result['outputIndex'] != index ||
            stored.result['createdAt'] != saved.result['finishedAt']) {
          round.issues.add(_directorIssue('group_speaker_proposal_unavailable', id: eventId));
          continue;
        }
        if (consumed.contains(eventId)) continue;
        Object? data;
        try {
          data = jsonDecode(event.data!);
        } catch (_) {
          /* Report below. */
        }
        final id = data is Map<String, Object?> ? data['characterId'] : null;
        if (id is! String || !enabled.contains(id) || selected.contains(id)) {
          round.issues.add(_directorIssue('group_speaker_not_eligible', id: eventId));
          continue;
        }
        selected.add(id);
        round.directorEvents[id] = eventId;
      }
      return selected;
    } catch (_) {
      round.issues.add(_directorIssue('group_speaker_source_unavailable', id: saved.id));
      return [];
    }
  }

  void cancel(String id) => rounds[id]?.cancel();

  void actorCommitted(_Turn turn) {
    final round = turn.groupRound;
    if (round == null) return;
    // The script-bridge layer can extend this post-SQL boundary. This layer
    // has no script host and does not manufacture a successful hook Ack.
    round.phase = TavernGroupPhase.settling;
    round.emit(TavernGroupProgressChanged(round.progress));
  }

  Future<TavernGroupChat> update(
    String id, {
    String? title,
    TavernGroupActivation? activation,
    int? maxSpeakersPerTurn,
    bool? allowSelfResponses,
  }) async {
    if (title != null) _title(title);
    if (maxSpeakersPerTurn != null) _limit(maxSpeakersPerTurn);
    engine._store.saveGroup(
      _groupCopy(
        require(id),
        title: title,
        activation: activation,
        limit: maxSpeakersPerTurn,
        selfResponses: allowSelfResponses,
      ),
    );
    return (await read(id))!;
  }
}

Map<String, Object?> _groupReplyExtra(_Turn turn) {
  if (turn.groupView == null) return const {};
  final round = turn.groupRound;
  return {
    'dshgo': {
      'group': {
        'version': 1,
        'actorCharacterId': turn.actorId,
        'model': turn.config.model,
        'deepseek': turn.config.deepseek,
        if (round != null) 'roundId': round.id,
        if (round != null) 'generationId': round.generationId,
        if (round != null) 'memberIndex': round.planned.indexOf(turn.actorId),
        'directorEventIds': <String>[?round?.directorEvents[turn.actorId]],
      },
    },
  };
}

class _GroupRound {
  _GroupRound(
    this.group,
    this.input,
    this.explicitActor,
    this.at,
    this.config,
    this.settings,
    this.persona,
    this.presetId,
    this.directorCaptured,
    this.secretCaptured,
    this.hostRevision,
    this.toolPolicyScope,
    this.gameplayAdmission,
  );
  final TavernGroupChat group;
  final String input;
  final String? explicitActor;
  final DateTime at;
  final TavernModelConfig config;
  final Map<String, Object?> settings;
  final PersonaSelection persona;
  final String? presetId;
  final StoredAgentRun? directorCaptured;
  final StoredAgentRun? secretCaptured;
  final int hostRevision;
  final TavernToolPolicySnapshot toolPolicyScope;
  final _GameplayAdmission gameplayAdmission;
  _GameplayRuntime? gameplay;
  final String id = 'group-${_newStateId()}';
  final cancellation = ModelCancellation();
  final done = Completer<void>();
  final observers = <StreamController<TavernGroupEvent>>{};
  final planned = <String>[];
  final remaining = <String>[];
  final completed = <String>[];
  final issues = <Map<String, Object?>>[];
  final directorEvents = <String, String>{};
  _GroupView? view;
  _Turn? child;
  TavernTurnFailed? failed;
  TavernGroupPhase phase = TavernGroupPhase.preparing;
  String? current;
  String? generationId;
  String? userNodeId;
  _ScriptSent? sent;
  bool finished = false;
  TavernGroupProgress get progress => TavernGroupProgress(
    chatId: group.chatId,
    roundId: id,
    startedAt: at,
    phase: phase,
    userNodeId: userNodeId,
    speakerCharacterId: current,
    replyNodeId: current == null ? null : child?.reply?.nodeId,
    generationId: generationId,
    plannedCharacterIds: planned,
    remainingCharacterIds: remaining,
    completedNodeIds: completed,
  );
  void cancel() {
    cancellation.cancel();
    child?.cancellation.cancel();
  }

  void emit(TavernGroupEvent event) {
    if (finished) return;
    for (final observer in observers) {
      if (!observer.isClosed) observer.add(event);
    }
  }
}
