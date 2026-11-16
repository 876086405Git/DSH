part of 'engine.dart';

// A captured model describes assembly only. It cannot call the live key
// supplier, retain transport headers, or choose an auxiliary transport.
Future<String?> _noAuthoringTransportKey() async => null;

final class _AuthoringPromptTask implements TavernAuthoringTask<TavernAuthoringPromptPreview> {
  _AuthoringPromptTask(this.request, this.captureId, {ModelCancellation? cancellation, TavernAuthoringPromptHost? host})
    : cancellation = cancellation ?? ModelCancellation() {
    unawaited(_result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    unawaited(drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    if (host != null) {
      hostOwner = _AuthoringPromptHostOwner(host, this.cancellation);
    }
  }
  final TavernAuthoringPromptRequest request;
  final String captureId;
  final ModelCancellation cancellation;
  _AuthoringPromptHostOwner? hostOwner;
  final drained = Completer<void>();
  final _result = Completer<TavernAuthoringPromptPreview>();
  @override
  String get requestId => request.requestId;
  @override
  Future<TavernAuthoringPromptPreview> get result => _result.future;
  @override
  Future<void> cancel() {
    cancellation.cancel();
    hostOwner?.stop();
    return drained.future;
  }

  TavernAuthoringPromptPreview value(
    TavernAuthoringPreviewStatus status, {
    Map<String, Object?> origin = const {},
    PromptAssembly? assembly,
    Map<String, Object?> worldInfo = const {},
    List<Map<String, Object?>> regexTrace = const [],
    Map<String, Object?> secretTrace = const {},
    List<TavernAuthoringIssue> issues = const [],
  }) => TavernAuthoringPromptPreview(
    requestId: requestId,
    draftId: request.draftId,
    draftRevision: request.draftRevision,
    changeIds: List<String>.of(request.changeIds),
    captureId: captureId,
    origin: {
      'context': request.context.toJson(),
      'at': request.at.toIso8601String(),
      'atIsUtc': request.at.isUtc,
      'seed': request.seed,
      'sealed': false,
      ...origin,
      if (hostOwner case final owner?)
        'scriptPreparation': {
          'calls': owner.calls,
          'effects': owner.workspace?.effects ?? const [],
          'scope': 'preview',
        },
    },
    status: status,
    assembly: assembly,
    worldInfo: worldInfo,
    regexTrace: regexTrace,
    secretTrace: secretTrace,
    issues: [
      ...issues,
      if (hostOwner?.workspace case final workspace?)
        for (final issue in workspace.turn.hookIssues) TavernAuthoringIssue(type: issue.code, message: issue.message),
    ],
  );
}

extension _AuthoringPromptPreviews on TavernEngine {
  TavernAuthoringTask<TavernAuthoringPromptPreview> _previewAuthoringPrompt(
    TavernAuthoringPromptRequest input, {
    TavernAuthoringPromptHost? host,
  }) {
    _ensureAdmission();
    return _startAuthoringPrompt(input, host: host);
  }

  // An already-admitted author run may continue while backup waits for its
  // owner. Share the real task/driver without opening external admission.
  _AuthoringPromptTask _startAuthoringPrompt(
    TavernAuthoringPromptRequest input, {
    ModelCancellation? cancellation,
    TavernAuthoringPromptHost? host,
  }) {
    cancellation?.check();
    _ensureOpen();
    final TavernAuthoringPromptRequest request;
    try {
      request = TavernAuthoringPromptRequest.fromJson(_captureScriptObject(input.toJson()));
    } on TavernScriptException {
      _authoringInvalid('Authoring preview inputs must be finite JSON.');
    }
    if (request.requestId.isEmpty ||
        request.draftId.isEmpty ||
        request.draftRevision < 1 ||
        request.changeIds.any((id) => id.isEmpty) ||
        request.changeIds.toSet().length != request.changeIds.length) {
      _authoringInvalid('Use valid request, draft, revision and distinct change identifiers.');
    }
    final task = _AuthoringPromptTask(
      request,
      'authoring:${_directorHash(request.toJson())}',
      cancellation: cancellation,
      host: host,
    );
    _operations.add(task.drained.future);
    _authoringPreviewCancellations.add(task.cancellation);
    // Capture starts in this admission's synchronous slice. Delaying it to a
    // later event would silently select a newer current leaf or draft.
    unawaited(_driveAuthoringPrompt(task));
    return task;
  }

  Future<void> _driveAuthoringPrompt(_AuthoringPromptTask task) async {
    TavernAuthoringPromptPreview? result;
    Object? failure;
    StackTrace? failureStack;
    var closeFailed = false;
    var origin = <String, Object?>{};
    _AuthoringPromptContextCapture? capture;
    try {
      // Type checking the built-in final implementation executes no callback
      // counter getter or count function, even on the unsupported path.
      if (_counter is! EstimatedTokenCounter) {
        throw const TavernAuthoringException(
          'unsupported_counter',
          'This token counter has no isolated authoring adapter.',
        );
      }
      task.cancellation.check();
      final captured = await _captureAuthoringPromptContext(
        task.request,
        task.captureId,
        task.cancellation,
        hostOwner: task.hostOwner,
      );
      capture = captured;
      origin = {...captured.origin, 'sealed': true};
      task.cancellation.check();
      await task.hostOwner?.closeAndDrain();
      task.cancellation.check();
      final regexTrace = <Map<String, Object?>>[...captured.preparedGroupRegexTrace];
      captured.prepareGroupUser(task.request.text, task.captureId, regexTrace);
      captured.prepareBeforeUser();
      result = await _assembleAuthoringPrompt(task, captured, origin, regexTrace);
    } on TavernAuthoringException catch (error) {
      final status = switch (error.code) {
        'unsupported_preview' ||
        'unsupported_counter' ||
        'secret_bind_required' => TavernAuthoringPreviewStatus.unsupported,
        'capture_conflict' || 'revision_conflict' => TavernAuthoringPreviewStatus.conflict,
        'cancelled' => TavernAuthoringPreviewStatus.cancelled,
        _ => TavernAuthoringPreviewStatus.failed,
      };
      result = task.value(
        status,
        origin: origin,
        secretTrace: capture?.secretTrace ?? const {},
        issues: [TavernAuthoringIssue(type: error.code, message: error.message)],
      );
    } on TavernModelException catch (error, stack) {
      if (error.kind == TavernFailure.cancelled) {
        result = task.value(
          TavernAuthoringPreviewStatus.cancelled,
          origin: origin,
          secretTrace: capture?.secretTrace ?? const {},
          issues: [const TavernAuthoringIssue(type: 'cancelled', message: 'The authoring preview was cancelled.')],
        );
      } else {
        failure = error;
        failureStack = stack;
      }
    } on PromptBudgetExceeded catch (error) {
      result = task.value(
        TavernAuthoringPreviewStatus.failed,
        origin: origin,
        secretTrace: capture?.secretTrace ?? const {},
        issues: [TavernAuthoringIssue(type: 'prompt_budget_exceeded', message: error.toString())],
      );
    } on TavernScriptException catch (error) {
      result = task.value(
        error.code == TavernScriptErrorCode.revisionConflict
            ? TavernAuthoringPreviewStatus.conflict
            : TavernAuthoringPreviewStatus.failed,
        origin: origin,
        secretTrace: capture?.secretTrace ?? const {},
        issues: [TavernAuthoringIssue(type: error.code.name, message: error.message)],
      );
    } catch (error, stack) {
      // Preserve unexpected storage/codec failures. A preview's lack of
      // writes does not justify replacing the actual failure with success.
      failure = error;
      failureStack = stack;
    } finally {
      try {
        await task.hostOwner?.closeAndDrain();
      } catch (error, stack) {
        if (task.hostOwner?.closeFailed == true) {
          closeFailed = true;
          failure = error;
          failureStack = stack;
        } else {
          failure ??= error;
          failureStack ??= stack;
        }
      }
      if (!closeFailed) {
        _authoringPreviewCancellations.remove(task.cancellation);
        _operations.remove(task.drained.future);
        task.drained.complete();
      }
    }
    if (closeFailed) {
      task.drained.completeError(failure!, failureStack!);
    }
    if (failure != null) {
      task._result.completeError(failure, failureStack!);
    } else {
      task._result.complete(result!);
    }
  }

  Future<TavernAuthoringPromptPreview> _assembleAuthoringPrompt(
    _AuthoringPromptTask task,
    _AuthoringPromptContextCapture capture,
    Map<String, Object?> origin,
    List<Map<String, Object?>> regexTrace,
  ) async {
    final turn = capture.turn;
    final history = capture.history;
    final branch = _AuthoringPromptBranch(history, capture.parent);
    final presetRaw = _map(turn.settings['preset']);
    final preset = ChatPreset({
      ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
      'show_thoughts': turn.config.thinking,
    });
    final worldSettings = WorldInfoSettings.fromJson(_map(turn.settings['worldInfo']));
    var userMessageCount = history.where((node) => node.message.role == TavernRole.user).length;
    var eligibleMessageCount = history.where((node) => !node.message.hidden && !_systemMessage(node)).length;
    final assistantMessageCount = history
        .where((node) => node.message.role == TavernRole.character && !node.message.hidden && !_systemMessage(node))
        .length;
    final environment = _MacroEnvironment(
      capture.actorData,
      turn.settings,
      turn.variables,
      capture.global,
      history,
      turn.config,
      task.request.at,
      capture.random.nextDouble,
      capture.macroChatIdentity,
      turn.input,
      turn.generationType,
      chatIdHash: _finiteNumber(turn.metadata['chat_id_hash']),
      pickRerollSeed: turn.metadata['pick_reroll_seed'],
      characterId: turn.actorId,
      groupNames: turn.groupView?.names,
      groupNotMuted: turn.groupView?.enabledNames,
      preset: preset,
      packRegex: turn.gameplayResources.regex,
      messageVariables: turn.state['messageVariables'],
      messageVariablesExists: turn.state.containsKey('messageVariables'),
    );
    turn.environment = environment;
    if (turn.kind == _TurnKind.send && turn.input.isNotEmpty) {
      branch.appendUser(
        turn,
        _preparePromptUser(environment, turn.input, regexTrace: regexTrace),
        environment.userName,
        task.captureId,
        siblingIndex: capture.userSiblingIndex,
      );
      userMessageCount++;
      eligibleMessageCount++;
    }
    final prepared = prepareCharacterFields(
      capture.actorData,
      persona: environment.persona,
      expand: environment.baseExpand,
    );
    _expandPromptFirst(history, history.firstOrNull, environment);
    final promptHistory = _preparePromptHistory(
      history,
      environment,
      continuing: turn.kind == _TurnKind.continueReply,
      regexTrace: regexTrace,
    );
    final eligibleHistory = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
    final books = capture.directorBooks();
    final initialInjections = _configuredInjections(
      turn.settings,
      prepared,
      capture.actorData,
      userMessageCount: userMessageCount,
    );
    final scriptInjections = _prepareScriptInjections(capture.scripts.uses, environment);
    final scanInjections = <String>[];
    for (final item in initialInjections) {
      if (item.scan) {
        final content = environment.expand(item.injection.fragment.content, const {});
        if (content.isNotEmpty) {
          scanInjections.add(content);
        }
      }
    }
    scanInjections.addAll(scriptInjections.scanTexts);
    var world = await _evaluatePreparedWorld(
      worldEngine: _worldInfoEngine,
      turn: turn,
      environment: environment,
      prepared: prepared,
      books: books,
      eligibleHistory: eligibleHistory,
      messageCount: eligibleMessageCount,
      assistantMessageCount: assistantMessageCount,
      preset: preset,
      worldSettings: worldSettings,
      counter: _counter,
      scanInjections: scanInjections,
      regexTrace: regexTrace,
    );
    turn.cancellation.check();
    final preparedUiHits = world.activated.where((hit) => hit.disabledUiPrompt != null).toList();
    environment.outlets.addAll({
      for (final entry in world.outlets.entries) entry.key: entry.value.map((hit) => hit.content).join('\n'),
    });
    final injections = [
      ..._finishInjections(initialInjections, world, deepseek: turn.config.deepseek),
      ...scriptInjections.prompts,
      ..._stateTurnInjections(turn),
      ..._cardEventTurnInjections(turn),
      ...capture.secretInjections(),
      ..._directorInjections(turn),
    ];
    final assembly = _assemblePreparedPrompt(
      turn: turn,
      data: capture.actorData,
      environment: environment,
      preset: preset,
      world: world,
      promptHistory: promptHistory,
      prepared: prepared,
      injections: injections,
      counter: _counter,
    );
    final excluded = <(String, String)>{
      for (final exclusion in assembly.excluded)
        if (exclusion.reason == 'v3-ignore-on-max-context')
          for (final source in exclusion.sources)
            if (source.kind == 'worldInfo' && source.details['bookId'] is String && source.details['uid'] is String)
              (source.details['bookId']! as String, source.details['uid']! as String),
    };
    world = world.withoutEntries(excluded);
    turn.state['timedWorldInfo'] = _copy(world.timedWorldInfo);
    turn.state['decoratorState'] = _copy(world.decoratorState);
    _adoptGameplayWorldInfo(turn, world);
    final worldTrace = _worldInfoTrace(
      world,
      preparedUiHits: preparedUiHits,
      missingBooks: capture.missingBooks,
      packSources: turn.gameplayResources.packSources,
    );
    turn.inspection = turn.inspection.copyWith(
      worldInfo: worldTrace,
      prompt: assembly,
      status: TavernInspectionStatus.ready,
    );
    _captureStateAssembly(turn, assembly);
    _captureCardEventAssembly(turn, assembly);
    _captureSecretAssembly(turn, assembly);
    capture.captureAssembly(assembly, world);
    if (turn.stateDefinition != null || _hasSecretTrace(turn)) {
      turn.inspection = turn.inspection.copyWith(state: _statePreparationTrace(turn));
    }
    turn.cancellation.check();
    turn.postfix = presetString(preset.settings['continue_postfix']);
    branch.bindReply(turn, capture.actorData, task.captureId);
    capture.scripts.claim(turn);
    final reply = branch.reply!;
    capture.finalSecretCheck(currentLeafId: branch.leaf, replyState: _map(_map(reply.extra['dshgo'])['tavernState']));
    turn.cancellation.check();
    return task.value(
      TavernAuthoringPreviewStatus.complete,
      origin: origin,
      assembly: assembly,
      worldInfo: worldTrace,
      regexTrace: regexTrace,
      secretTrace: capture.secretTrace,
      issues: _authoringPreparationIssues(turn),
    );
  }
}

/// The prepared user/reply really inhabit this task's branch. Final secret
/// checks read its installed reply state, never a live store or invented audit.
final class _AuthoringPromptBranch {
  _AuthoringPromptBranch(this.history, this.leaf);
  final List<StoredNode> history;
  String? leaf;
  StoredNode? reply;

  void appendUser(_Turn turn, String text, String speaker, String captureId, {required int siblingIndex}) {
    final message = TavernMessage(
      nodeId: '$captureId:user',
      parentId: leaf,
      role: TavernRole.user,
      speaker: speaker,
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(turn.at.millisecondsSinceEpoch, isUtc: true),
      siblingIndex: siblingIndex,
      siblingCount: siblingIndex + 1,
    );
    history.add(
      StoredNode(
        message: message,
        depth: history.isEmpty ? 1 : history.last.depth + 1,
        extra: {
          'dshgo': {'tavernState': turn.currentState},
        },
        original: const {},
      ),
    );
    leaf = message.nodeId;
    turn.newUserId = leaf;
  }

  void bindReply(_Turn turn, Map<String, Object?> actorData, String captureId) {
    final continuing = turn.kind == _TurnKind.continueReply;
    final old = continuing
        ? history.firstWhere((node) => node.message.nodeId == turn.originalTarget!.message.nodeId)
        : null;
    final original = old?.message;
    final nickname = actorData['nickname'];
    final speaker = nickname is String && nickname.isNotEmpty ? nickname : actorData['name']! as String;
    final message = original == null
        ? TavernMessage(
            nodeId: '$captureId:reply',
            parentId: leaf,
            role: turn.kind == _TurnKind.impersonate ? TavernRole.user : TavernRole.character,
            speaker: turn.kind == _TurnKind.impersonate ? turn.environment!.userName : speaker,
            speakerCharacterId: turn.kind == _TurnKind.impersonate ? null : turn.actorId,
            text: '',
            at: turn.kind == _TurnKind.impersonate
                ? turn.at
                : DateTime.fromMillisecondsSinceEpoch(turn.at.millisecondsSinceEpoch, isUtc: true),
          )
        : TavernMessage(
            nodeId: original.nodeId,
            parentId: original.parentId,
            role: original.role,
            speaker: original.speaker,
            speakerCharacterId: turn.actorId,
            text: original.text,
            reasoning: original.reasoning,
            at: original.at,
            siblingIndex: original.siblingIndex,
            siblingCount: original.siblingCount,
            hidden: original.hidden,
            usage: original.usage,
            reportedUsage: original.reportedUsage,
          );
    final extra = old == null ? _copy(_groupReplyExtra(turn)) : _copy(old.extra);
    extra['dshgo'] = {..._map(extra['dshgo']), 'tavernState': turn.currentState};
    if (continuing && turn.groupView != null) {
      final own = _map(extra['dshgo']);
      own['group'] = {
        ..._map(own['group']),
        'version': 1,
        'actorCharacterId': turn.actorId,
        'model': turn.config.model,
        'deepseek': turn.config.deepseek,
      };
      extra['dshgo'] = own;
    }
    final node = StoredNode(
      message: message,
      depth: old?.depth ?? (history.isEmpty ? 1 : history.last.depth + 1),
      extra: extra,
      original: old?.original ?? const {},
    );
    if (old == null) {
      history.add(node);
    } else {
      history[history.indexOf(old)] = node;
    }
    reply = node;
    leaf = message.nodeId;
    turn.begin(message);
    turn.inspection = turn.inspection.copyWith(nodeId: message.nodeId);
  }
}

List<TavernAuthoringIssue> _authoringPreparationIssues(_Turn turn) => [
  for (final issue in [
    ...turn.statePreparationIssues,
    ...turn.cardEventPreparationIssues,
    ...turn.secretIssues,
    ..._stateRows(turn.inspection.director['issues']),
  ])
    TavernAuthoringIssue(
      type: issue['code'] is String ? issue['code']! as String : 'preparation',
      message: issue['message'] is String ? issue['message']! as String : jsonEncode(issue),
    ),
];
