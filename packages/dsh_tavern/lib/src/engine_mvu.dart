part of 'engine.dart';

const _mvuFields = ['stat_data', 'schema', 'initialized_lorebooks', 'display_data', 'delta_data'];

bool _mvuDeclared(Map<String, Object?> data) => _map(_map(_map(data['extensions'])['dshgo'])['mvu'])['enabled'] == true;

List<TavernScriptIssue> _mvuIssues(
  List<mvu_core.MvuIssue> issues, {
  required bool committed,
  TavernScriptMessageRef? nodeRef,
  String? generationId,
}) => [
  for (final issue in issues)
    TavernScriptIssue(
      code: issue.code,
      message: issue.message,
      committed: committed,
      nodeRef: nodeRef,
      generationId: generationId,
      stage: 'mvu',
      details: {'source': ?issue.source, 'offset': ?issue.offset},
    ),
];

/// One real caller owns waits across every same-chat phase recipient.
class _MvuCaller {
  _MvuCaller(this.coordinator, this.capture) : hostVersion = coordinator._hostVersion {
    capture.context.callbacks.add(token);
    unawaited(
      token.whenCancelled.then((_) {
        cancellation.cancel();
      }),
    );
  }
  final _ScriptCoordinator coordinator;
  final _ScriptChatCapture capture;
  final int hostVersion;
  final token = _ScriptCancellation();
  final cancellation = ModelCancellation();

  void check() {
    final id = capture.context.value.id;
    if (token.isCancelled) {
      throw _scriptError(TavernScriptErrorCode.cancelled, 'mvu', 'The MVU caller was closed.', contextId: id);
    }
    if (!identical(coordinator._context(id), capture.context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'mvu',
        'The MVU caller is no longer current.',
        contextId: id,
      );
    }
    if (hostVersion != coordinator._hostVersion) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'mvu',
        'The script host changed during MVU processing.',
        contextId: id,
      );
    }
  }

  void finish() {
    capture.context.callbacks.remove(token);
    token.cancel();
  }
}

extension _NativeMvu on _ScriptCoordinator {
  Future<TavernMvuParseResult> _parseMvuMessage(String contextId, String message, TavernJsonObject previousData) async {
    final owner = _MvuCaller(this, _captureChat(contextId));
    var effectsCommitted = false;
    try {
      final result = await mvu_core.updateMvu(
        message,
        previousData,
        expand: (source) async {
          owner.check();
          final expanded = await _substitutePublicMacros(
            contextId,
            source,
            onEffectsCommitted: () {
              effectsCommitted = true;
            },
          );
          owner.check();
          return expanded;
        },
        onPhase: (phase) async {
          owner.check();
          await _dispatchMvuPhase(owner.capture.chatId, phase, cancellation: owner.cancellation);
          owner.check();
        },
      );
      owner.check();
      return TavernMvuParseResult(
        data: result.data,
        issues: _mvuIssues(result.issues, committed: effectsCommitted),
      );
    } catch (error, stack) {
      Error.throwWithStackTrace(_mvuFailure(this, error, committed: effectsCommitted, contextId: contextId), stack);
    } finally {
      owner.finish();
    }
  }
}

/// A physical variable carrier. Null node is reserved for a real group root.
class _MvuFrame {
  _MvuFrame(this.chat, this.node, this.state, this.data, this.version, this.pathRevision);
  final StoredChat chat;
  final StoredNode? node;
  final Map<String, Object?> state;
  final TavernJsonObject data;
  final String version;
  final String pathRevision;
  String? get nodeId => node?.message.nodeId;
  TavernScriptMessageRef? get ref => nodeId == null ? null : TavernScriptMessageRef(chatId: chat.id, nodeId: nodeId!);
}

class _MvuTurnBase {
  _MvuTurnBase(
    this.resources,
    this.frame,
    this.replyId,
    this.parentId,
    this.hostVersion,
    this.actorRevision, {
    required this.rootGreeting,
  });
  final _MvuResources resources;
  final _MvuFrame? frame;
  final String replyId;
  final String? parentId;
  final int hostVersion;
  final int actorRevision;
  final bool rootGreeting;
}

class _MvuExpansion {
  _MvuExpansion(this.engine, this.environment, this.check)
    : localBefore = _copy(environment.local),
      hashBefore = environment.chatIdHash;
  final TavernEngine engine;
  final _MacroEnvironment environment;
  final void Function() check;
  final Map<String, Object?> localBefore;
  final num? hashBefore;
  bool globalsChanged = false;
  bool globalsAdopted = false;
  bool _saveAttempted = false;

  String expand(String source) {
    check();
    final before = engine._globalVariables.revision;
    try {
      return environment.expand(source, const {});
    } finally {
      globalsChanged = globalsChanged || engine._globalVariables.changedSince(before);
    }
  }

  Future<void> flushGlobals() async {
    if (!globalsChanged || _saveAttempted) {
      return;
    }
    _saveAttempted = true;
    await engine._saveDocument(
      onGlobalsAdopted: () {
        globalsAdopted = true;
      },
    );
  }

  Future<({Object error, StackTrace stack})> failure(Object error, StackTrace stack) async {
    try {
      await flushGlobals();
    } catch (saveError, saveStack) {
      return (error: _PreparationSaveFailure(error, stack, saveError, saveStack, operation: 'mvu'), stack: saveStack);
    }
    return (error: error, stack: stack);
  }
}

TavernScriptException _mvuFailure(
  _ScriptCoordinator coordinator,
  Object error, {
  required bool committed,
  String? contextId,
  String? generationId,
}) {
  final failure = coordinator._scriptFailure(error);
  return TavernScriptException(
    code: failure.code,
    operation: failure.operation,
    message: failure.message,
    contextId: failure.contextId ?? contextId,
    nodeId: failure.nodeId,
    generationId: failure.generationId ?? generationId,
    executionId: failure.executionId,
    fieldPath: failure.fieldPath,
    sourceSpan: failure.sourceSpan,
    committed: committed || failure.committed || failure.issues.any((issue) => issue.committed),
    modelFailure: failure.modelFailure,
    issues: failure.issues,
    stateEdit: failure.stateEdit,
  );
}

extension _NativeMvuStorage on _ScriptCoordinator {
  _MvuFrame _mvuFrame(String chatId, String? nodeId) {
    final chat = engine._store.chat(chatId);
    if (nodeId == null && engine._store.groupChat(chatId) == null) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'mvu', 'This chat has no physical message to initialize.');
    }
    final node = nodeId == null ? null : engine._store.node(chatId, nodeId);
    final state = node == null
        ? engine._store.groupInitialState(chatId)
        : engine._stateFromNode(chatId, node, chat: chat);
    final raw = _fieldVariable(state, 'messageVariables');
    final data = _variableObject(raw);
    final version = nodeId == null
        ? _variableFingerprint(raw)
        : _variableVersion(
            TavernVariableTarget(
              scope: TavernVariableScope.message,
              messageRef: TavernScriptMessageRef(chatId: chatId, nodeId: nodeId),
            ),
            raw,
          );
    return _MvuFrame(chat, node, state, data, version, _pathRevision(chatId));
  }

  void _checkMvuFrame(_MvuFrame frame, {bool samePath = true, bool sameBody = true}) {
    final current = _mvuFrame(frame.chat.id, frame.nodeId);
    final beforeMessage = frame.node?.message;
    final afterMessage = current.node?.message;
    if (current.chat.characterId != frame.chat.characterId ||
        (samePath && current.pathRevision != frame.pathRevision) ||
        current.version != frame.version ||
        beforeMessage?.parentId != afterMessage?.parentId ||
        beforeMessage?.role != afterMessage?.role ||
        (sameBody && beforeMessage?.text != afterMessage?.text) ||
        frame.chat.settings.containsKey('mvuEnabled') != current.chat.settings.containsKey('mvuEnabled') ||
        !_stateJsonEqual(frame.chat.settings['mvuEnabled'], current.chat.settings['mvuEnabled'])) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'mvu',
        'The captured MVU message, variables, selection or enable choice changed.',
        nodeId: frame.nodeId,
      );
    }
  }

  bool _mvuNeedsInitialization(_MvuFrame frame, _MvuResources resources) {
    final markers = frame.data['initialized_lorebooks'];
    return !frame.data.containsKey('stat_data') ||
        !frame.data.containsKey('schema') ||
        markers is! Map<String, Object?> ||
        resources.books.any((book) => !markers.containsKey(book.name));
  }

  void _checkMvuTurn(_Turn turn, int hostVersion) {
    turn.cancellation.check();
    if (!identical(engine._turns[turn.chat.id], turn) ||
        turn.terminal ||
        _closed ||
        engine._closing ||
        engine._closed ||
        hostVersion != _hostVersion) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'mvu',
        'The native MVU turn or script host changed.',
        generationId: turn.generationId,
      );
    }
  }

  Future<T> _mvuTurnWrite<T>(_Turn turn, int hostVersion, T Function(_ToolPreparationPermit? permit) action) async {
    _checkMvuTurn(turn, hostVersion);
    final permit = _captureToolPreparationPermit(engine, turn.chat.id);
    final previous = engine._mutations[turn.chat.id] ?? Future<void>.value();
    final released = Completer<void>();
    engine._mutations[turn.chat.id] = released.future;
    try {
      await turn.cancellation.wait(previous);
      _checkMvuTurn(turn, hostVersion);
      _checkToolPreparationPermit(engine, permit);
      return action(permit);
    } finally {
      if (identical(engine._mutations[turn.chat.id], released.future)) {
        unawaited(engine._mutations.remove(turn.chat.id));
      }
      released.complete();
    }
  }

  void _adoptMvu(
    _MvuResources resources,
    _MvuFrame frame,
    TavernJsonObject candidate,
    _MvuExpansion expansion, {
    bool? enabled,
  }) {
    _checkMvuResources(resources);
    _checkMvuFrame(frame);
    final state = engine._stateAt(frame.chat.id, frame.nodeId);
    final data = _variableObject(_fieldVariable(state, 'messageVariables'));
    for (final field in _mvuFields) {
      if (candidate.containsKey(field)) {
        data[field] = candidate[field];
      } else {
        data.remove(field);
      }
    }
    final prepared = _prepareMessageData(
      resources.dataContext,
      nodeId: frame.nodeId,
      baseline: state,
      data: data,
      extra: frame.nodeId == null ? const {} : engine._store.rawNodeExtra(frame.chat.id, frame.nodeId!),
    );
    if (!_stateJsonEqual(expansion.localBefore, expansion.environment.local)) {
      if (!_stateJsonEqual(_map(state['variables']), expansion.localBefore)) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'mvu',
          'Local macro variables changed before MVU adoption.',
          nodeId: frame.nodeId,
        );
      }
      prepared.state['variables'] = _copy(expansion.environment.local);
    }
    if (expansion.environment.chatIdHash != expansion.hashBefore) {
      if (_finiteNumber(state['stChatIdHash']) != expansion.hashBefore) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'mvu',
          'The macro chat identity changed before MVU adoption.',
          nodeId: frame.nodeId,
        );
      }
      prepared.state['stChatIdHash'] = expansion.environment.chatIdHash;
    }
    if (frame.nodeId == null) {
      _ensurePreparedGameplay(prepared);
      engine._store.setGroupInitialState(frame.chat.id, prepared.state);
    } else {
      _commitMessageData(frame.chat.id, frame.nodeId!, prepared);
    }
    if (enabled != null) {
      final chat = engine._store.chat(frame.chat.id);
      engine._store.updateChat(chat.id, settings: {...chat.settings, 'mvuEnabled': enabled});
    }
    engine._restoreVariables(frame.chat.id);
  }

  Future<void> _refreshMvuChat(String chatId, ModelCancellation cancellation) async {
    for (final context in contexts.values.where((item) => !item.closed && item.value.chatId == chatId).toList()) {
      await cancellation.wait(_refreshContext(context));
      cancellation.check();
    }
  }
}

extension _NativeMvuLifecycle on _ScriptCoordinator {
  Future<TavernMvuInitialization> _setMvuEnabled(String contextId, bool enabled) async {
    final owner = _MvuCaller(this, _captureChat(contextId));
    final chatId = owner.capture.chatId;
    var adopted = false;
    _MvuExpansion? expansion;
    try {
      if (!enabled) {
        await _dataWrite(
          owner.capture,
          (permit) => _toolPreparationSql(
            engine,
            permit,
            () {
              owner.check();
              final chat = engine._store.chat(chatId);
              engine._store.updateChat(chatId, settings: {...chat.settings, 'mvuEnabled': false});
            },
            onCommitted: () {
              adopted = true;
            },
          ),
        );
        await _refreshMvuChat(chatId, owner.cancellation);
        owner.check();
        return TavernMvuInitialization(chatId: chatId, enabled: false);
      }
      final frame = _mvuFrame(chatId, engine._store.chat(chatId).currentLeafId);
      void check() {
        owner.check();
        _checkMvuFrame(frame);
      }

      final resources = await _captureMvuResources(chatId, state: frame.state, check: check);
      check();
      final needed = _mvuNeedsInitialization(frame, resources);
      final environment = _mvuEnvironment(
        resources,
        state: frame.state,
        history: engine._historyTo(chatId, frame.nodeId),
        at: engine._clock(),
      );
      final computation = _MvuExpansion(engine, environment, check);
      expansion = computation;
      mvu_core.MvuResult? result;
      if (needed) {
        result = await mvu_core.initializeMvu(
          frame.data,
          resources.books,
          greeting:
              frame.node?.message.parentId == null &&
                  frame.node?.message.role == TavernRole.character &&
                  !frame.data.containsKey('stat_data')
              ? frame.node!.message.text
              : null,
          swipeId: frame.node?.message.siblingIndex ?? 0,
          expand: computation.expand,
          onPhase: (phase) async {
            check();
            _checkMvuResources(resources);
            await _dispatchMvuPhase(chatId, phase, nodeRef: frame.ref, cancellation: owner.cancellation);
            check();
          },
        );
      }
      await computation.flushGlobals();
      check();
      final candidate = result?.data;
      await _dataWrite(
        owner.capture,
        (permit) => _toolPreparationSql(
          engine,
          permit,
          () {
            check();
            _checkMvuResources(resources);
            if (candidate != null) {
              _adoptMvu(resources, frame, candidate, computation, enabled: true);
            } else {
              final chat = engine._store.chat(chatId);
              engine._store.updateChat(chatId, settings: {...chat.settings, 'mvuEnabled': true});
            }
          },
          onCommitted: () {
            adopted = true;
            engine._liveVariables.remove(chatId);
          },
        ),
      );
      await _refreshMvuChat(chatId, owner.cancellation);
      owner.check();
      return TavernMvuInitialization(
        chatId: chatId,
        enabled: true,
        initializedRefs: [if (needed && frame.ref != null) frame.ref!],
        issues: [
          ...resources.issues,
          if (result != null) ..._mvuIssues(result.issues, committed: adopted, nodeRef: frame.ref),
        ],
      );
    } catch (error, stack) {
      final failure = expansion == null ? (error: error, stack: stack) : await expansion.failure(error, stack);
      Error.throwWithStackTrace(
        _mvuFailure(this, failure.error, committed: adopted || expansion?.globalsAdopted == true, contextId: contextId),
        failure.stack,
      );
    } finally {
      owner.finish();
    }
  }

  Future<void> _ensureMvuTurn(_Turn turn) async {
    final chat = engine._store.chat(turn.chat.id);
    if (turn.kind == _TurnKind.impersonate || chat.settings['mvuEnabled'] != true) {
      return;
    }
    final nodeId = turn.nodeId ?? chat.currentLeafId;
    if (nodeId == null && engine._store.groupChat(chat.id) == null) {
      return;
    }
    final hostVersion = _hostVersion;
    final frame = _mvuFrame(chat.id, nodeId);
    void check() {
      _checkMvuTurn(turn, hostVersion);
      _checkMvuFrame(frame);
    }

    final resources = await _captureMvuResources(chat.id, state: frame.state, check: check);
    check();
    turn.mvuResources = resources;
    turn.hookIssues.addAll(resources.issues);
    if (!_mvuNeedsInitialization(frame, resources)) {
      return;
    }
    final environment = _mvuEnvironment(
      resources,
      state: frame.state,
      history: engine._historyTo(chat.id, nodeId),
      at: turn.at,
      input: turn.input,
      generationType: turn.generationType,
    );
    final computation = _MvuExpansion(engine, environment, check);
    var adopted = false;
    try {
      final result = await mvu_core.initializeMvu(
        frame.data,
        resources.books,
        greeting:
            frame.node?.message.parentId == null &&
                frame.node?.message.role == TavernRole.character &&
                !frame.data.containsKey('stat_data')
            ? frame.node!.message.text
            : null,
        swipeId: frame.node?.message.siblingIndex ?? 0,
        expand: computation.expand,
        onPhase: (phase) async {
          check();
          _checkMvuResources(resources);
          await _dispatchMvuPhase(
            chat.id,
            phase,
            nodeRef: frame.ref,
            generationId: turn.generationId,
            cancellation: turn.cancellation,
          );
          check();
        },
      );
      await computation.flushGlobals();
      check();
      await _mvuTurnWrite(
        turn,
        hostVersion,
        (permit) => _toolPreparationSql(
          engine,
          permit,
          () {
            check();
            _adoptMvu(resources, frame, result.data, computation);
          },
          onCommitted: () {
            adopted = true;
            engine._liveVariables.remove(chat.id);
          },
        ),
      );
      turn.hookIssues.addAll(
        _mvuIssues(result.issues, committed: adopted, nodeRef: frame.ref, generationId: turn.generationId),
      );
    } catch (error, stack) {
      final failure = await computation.failure(error, stack);
      Error.throwWithStackTrace(
        _mvuFailure(
          this,
          failure.error,
          committed: adopted || computation.globalsAdopted,
          generationId: turn.generationId,
        ),
        failure.stack,
      );
    }
  }

  Future<void> _captureMvuTurnBase(_Turn turn) async {
    final chat = engine._store.chat(turn.chat.id);
    if (turn.kind == _TurnKind.impersonate || chat.settings['mvuEnabled'] != true) {
      return;
    }
    final hostVersion = _hostVersion;
    void check() => _checkMvuTurn(turn, hostVersion);
    check();
    final reply = turn.reply!;
    final original = turn.originalTarget?.message;
    final rootGreeting =
        original != null &&
        original.parentId == null &&
        original.role == TavernRole.character &&
        (turn.kind == _TurnKind.regenerate || turn.kind == _TurnKind.continueReply);
    final noCarrier = reply.parentId == null && engine._store.groupChat(chat.id) == null;
    final frame = rootGreeting || noCarrier ? null : _mvuFrame(chat.id, reply.parentId);
    final resources =
        turn.mvuResources ??
        await _captureMvuResources(
          chat.id,
          state: frame?.state ?? engine._stateAt(chat.id, reply.nodeId),
          check: check,
        );
    check();
    _checkMvuResources(resources);
    if (frame != null) {
      _checkMvuFrame(frame);
    }
    turn.mvuBase = _MvuTurnBase(
      resources,
      frame,
      reply.nodeId,
      reply.parentId,
      hostVersion,
      engine._directors._cardRevisions[turn.actorId] ?? 0,
      rootGreeting: rootGreeting,
    );
  }

  Future<void> _afterMvuMessage(_Turn turn) async {
    if (engine._store.chat(turn.chat.id).settings['mvuEnabled'] != true) {
      return;
    }
    final base = turn.mvuBase;
    final reply = turn.lastCommitted!;
    final ref = TavernScriptMessageRef(chatId: turn.chat.id, nodeId: reply.nodeId);
    _MvuExpansion? computation;
    try {
      if (base == null ||
          (!base.rootGreeting &&
              (base.frame == null ||
                  !base.frame!.data.containsKey('stat_data') ||
                  !base.frame!.data.containsKey('schema')))) {
        turn.hookIssues.add(
          TavernScriptIssue(
            code: 'mvu_base_unavailable',
            message: 'The direct physical page before this reply has no captured MVU baseline.',
            committed: true,
            stage: 'mvu',
            nodeRef: ref,
            generationId: turn.generationId,
          ),
        );
        return;
      }
      final target = _mvuFrame(turn.chat.id, reply.nodeId);
      void check() {
        _checkMvuTurn(turn, base.hostVersion);
        _checkMvuResources(base.resources);
        if (reply.nodeId != base.replyId ||
            target.node!.message.parentId != base.parentId ||
            (engine._directors._cardRevisions[turn.actorId] ?? 0) != base.actorRevision) {
          throw _scriptError(
            TavernScriptErrorCode.revisionConflict,
            'mvu',
            'The captured MVU reply edge or actor changed.',
            generationId: turn.generationId,
          );
        }
        if (base.frame != null) {
          _checkMvuFrame(base.frame!, samePath: false, sameBody: false);
        }
        _checkMvuFrame(target);
      }

      check();
      final environment = _mvuEnvironment(
        base.resources,
        state: target.state,
        history: engine._historyTo(turn.chat.id, target.nodeId),
        at: turn.at,
        turnEnvironment: turn.environment,
      );
      final expansion = _MvuExpansion(engine, environment, check);
      computation = expansion;
      Future<void> phase(mvu_core.MvuPhase phase) async {
        check();
        await _dispatchMvuPhase(
          turn.chat.id,
          phase,
          nodeRef: ref,
          generationId: turn.generationId,
          cancellation: turn.cancellation,
        );
        check();
      }

      final mvu_core.MvuResult result;
      if (base.rootGreeting) {
        final previous = _copy(target.data);
        for (final field in _mvuFields) {
          previous.remove(field);
        }
        result = await mvu_core.initializeMvu(
          previous,
          base.resources.books,
          greeting: target.node!.message.text,
          swipeId: target.node!.message.siblingIndex,
          expand: expansion.expand,
          onPhase: phase,
        );
      } else {
        result = await mvu_core.updateMvu(
          target.node!.message.text,
          base.frame!.data,
          blocksOnly: true,
          expand: expansion.expand,
          onPhase: phase,
        );
      }
      await expansion.flushGlobals();
      check();
      await _mvuTurnWrite(
        turn,
        base.hostVersion,
        (permit) => _toolPreparationSql(
          engine,
          permit,
          () {
            check();
            _adoptMvu(base.resources, target, result.data, expansion);
          },
          onCommitted: () {
            engine._liveVariables.remove(turn.chat.id);
          },
        ),
      );
      turn.hookIssues.addAll(_mvuIssues(result.issues, committed: true, nodeRef: ref, generationId: turn.generationId));
    } catch (error, stack) {
      final failure = computation == null ? (error: error, stack: stack) : await computation.failure(error, stack);
      final reported = _mvuFailure(this, failure.error, committed: true, generationId: turn.generationId);
      turn.hookIssues.addAll(reported.issues);
      turn.hookIssues.add(
        TavernScriptIssue(
          code: 'mvu_update_failed',
          message: reported.message,
          committed: true,
          stage: 'mvu',
          nodeRef: ref,
          generationId: turn.generationId,
          cancelled: turn.cancellation.isCancelled,
        ),
      );
    }
  }
}
