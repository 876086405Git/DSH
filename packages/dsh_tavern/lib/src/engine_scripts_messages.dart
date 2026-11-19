part of 'engine.dart';

TavernScriptRole _scriptRole(TavernRole role) => switch (role) {
  TavernRole.user => TavernScriptRole.user,
  TavernRole.character => TavernScriptRole.assistant,
  TavernRole.narrator || TavernRole.system => TavernScriptRole.system,
};

TavernRole _scriptNativeRole(TavernScriptRole role) => switch (role) {
  TavernScriptRole.user => TavernRole.user,
  TavernScriptRole.assistant => TavernRole.character,
  TavernScriptRole.system => TavernRole.system,
};

TavernScriptMessageRef _scriptRef(String chatId, String nodeId) =>
    TavernScriptMessageRef(chatId: chatId, nodeId: nodeId);

TavernScriptException _messageScriptError(
  String contextId,
  String operation,
  TavernScriptErrorCode code,
  String message, {
  String? nodeId,
  String? fieldPath,
}) => TavernScriptException(
  code: code,
  operation: operation,
  message: message,
  contextId: contextId,
  nodeId: nodeId,
  fieldPath: fieldPath,
);

Map<String, Object?> _scriptUserExtra(Map<String, Object?> extra) => {
  for (final entry in extra.entries)
    if (entry.key != 'dshgo') entry.key: entry.value,
};

class _ScriptProjection<T> {
  _ScriptProjection(this.input, this.value);
  final List<Object?> input;
  final T value;
}

class _ScriptMessageProjections {
  final messages = <String, _ScriptProjection<TavernScriptMessage>>{};
  final swipes = <String, _ScriptProjection<TavernScriptSwipe>>{};
  String? stateChatId;
  Object? stateVersion;
  final states = <String, Map<String, Object?>>{};
}

TavernScriptShapeIssue? _scriptMessageShape(Map<String, Object?> state) {
  if (!state.containsKey('messageVariables') || state['messageVariables'] is Map<String, Object?>) {
    return null;
  }
  final value = state['messageVariables'];
  final kind = value == null
      ? 'null'
      : value is String
      ? 'string'
      : value is bool
      ? 'bool'
      : value is num
      ? 'number'
      : value is List<Object?>
      ? 'list'
      : 'object';
  return TavernScriptShapeIssue(
    fieldPath: '/messageVariables',
    actualKind: kind,
    message: 'Saved message variables are not an object; rawData is preserved.',
  );
}

Map<String, Object?> _scriptSwipeInfo(StoredNode node) {
  final index = node.original['swipe_id'];
  final infos = node.original['swipe_info'];
  final originalIndex = index is num && index.isFinite && index >= 0 && index == index.roundToDouble()
      ? index.toInt()
      : 0;
  final info = infos is List<Object?> && originalIndex < infos.length && infos[originalIndex] is Map<String, Object?>
      ? Map<String, Object?>.of(infos[originalIndex]! as Map<String, Object?>)
      : <String, Object?>{};
  for (final key in const ['send_date', 'gen_started', 'gen_finished', 'extra']) {
    info.remove(key);
  }
  info['send_date'] = node.original.containsKey('send_date')
      ? node.original['send_date']
      : node.message.at.toUtc().toIso8601String();
  for (final key in const ['gen_started', 'gen_finished']) {
    if (node.original.containsKey(key)) {
      info[key] = node.original[key];
    }
  }
  info['extra'] = _scriptUserExtra(node.extra);
  return info;
}

extension _ScriptMessageOperations on _ScriptCoordinator {
  Map<String, Object?> _scriptMessageState(String chatId, StoredNode node, {_ScriptMessageProjections? cache}) {
    final nodeId = node.message.nodeId;
    if (cache != null) {
      final version = engine._store.displayVersion(chatId);
      if (cache.stateChatId != chatId || !identical(cache.stateVersion, version)) {
        cache.stateChatId = chatId;
        cache.stateVersion = version;
        cache.states.clear();
      }
      final previous = cache.states[nodeId];
      if (previous != null) return previous;
    }
    final own = node.extra['dshgo'];
    final override = own is Map<String, Object?> ? own['tavernState'] : null;
    final state = override is Map<String, Object?> ? override : engine._store.nodeState(chatId, nodeId);
    if (cache != null) cache.states[nodeId] = state;
    return state;
  }

  TavernScriptMessage _projectMessage(
    String chatId,
    StoredNode node,
    int index, {
    required bool includeSwipes,
    _ScriptMessageProjections? cache,
    Set<String>? usedSwipes,
  }) {
    final message = node.message;
    final state = _scriptMessageState(chatId, node, cache: cache);
    final extra = _scriptUserExtra(node.extra);
    final swipes = !includeSwipes
        ? <TavernScriptSwipe>[]
        : [
            for (final sibling
                in message.siblingCount == 1 ? [node] : engine._store.scriptChildren(chatId, message.parentId))
              _projectSwipe(chatId, sibling, cache: cache, used: usedSwipes),
          ];
    final input = <Object?>[
      chatId,
      index,
      message.speaker,
      message.role,
      message.text,
      message.hidden,
      message.speakerCharacterId,
      message.siblingIndex,
      state.containsKey('messageVariables'),
      state['messageVariables'],
      extra,
      swipes,
    ];
    final previous = cache?.messages[message.nodeId];
    if (previous != null && _stateJsonEqual(previous.input, input)) return previous.value;
    final projected = TavernScriptMessage(
      messageId: index,
      ref: _scriptRef(chatId, message.nodeId),
      name: message.speaker,
      role: _scriptRole(message.role),
      nativeRole: message.role,
      message: message.text,
      hidden: message.hidden,
      speakerCharacterId: message.speakerCharacterId,
      hasData: state.containsKey('messageVariables'),
      rawData: state['messageVariables'],
      dataIssue: _scriptMessageShape(state),
      extra: extra,
      swipeId: message.siblingIndex,
      swipes: swipes,
    );
    if (cache != null) cache.messages[message.nodeId] = _ScriptProjection(input, projected);
    return projected;
  }

  TavernScriptSwipe _projectSwipe(
    String chatId,
    StoredNode node, {
    _ScriptMessageProjections? cache,
    Set<String>? used,
  }) {
    final state = _scriptMessageState(chatId, node, cache: cache);
    final info = _scriptSwipeInfo(node);
    final input = <Object?>[
      chatId,
      node.message.siblingIndex,
      node.message.text,
      state.containsKey('messageVariables'),
      state['messageVariables'],
      info,
    ];
    used?.add(node.message.nodeId);
    final previous = cache?.swipes[node.message.nodeId];
    if (previous != null && _stateJsonEqual(previous.input, input)) return previous.value;
    final projected = TavernScriptSwipe(
      ref: _scriptRef(chatId, node.message.nodeId),
      swipeId: node.message.siblingIndex,
      text: node.message.text,
      hasData: state.containsKey('messageVariables'),
      rawData: state['messageVariables'],
      dataIssue: _scriptMessageShape(state),
      info: info,
    );
    if (cache != null) cache.swipes[node.message.nodeId] = _ScriptProjection(input, projected);
    return projected;
  }

  Future<List<TavernScriptMessage>?> _projectMessages(_ScriptChatCapture capture, {bool includeSwipes = true}) async {
    final cache = capture.context.messageProjections;
    final usedSwipes = <String>{};
    final version = engine._store.displayVersion(capture.chatId);
    final projected = <TavernScriptMessage>[];
    final profile = engine._turns[capture.chatId]?.profile;
    var batchStarted = profile?.now;
    for (var index = 0; index < capture.path.length; index++) {
      projected.add(
        _projectMessage(
          capture.chatId,
          capture.path[index],
          index,
          includeSwipes: includeSwipes,
          cache: cache,
          usedSwipes: usedSwipes,
        ),
      );
      if ((index + 1) % 64 == 0 && index + 1 < capture.path.length) {
        if (batchStarted != null) profile?.record('script_projection', batchStarted);
        await Future<void>.delayed(Duration.zero);
        batchStarted = profile?.now;
        if (capture.context.closed || !identical(version, engine._store.displayVersion(capture.chatId))) return null;
      }
    }
    final usedMessages = {for (final node in capture.path) node.message.nodeId};
    cache.messages.removeWhere((id, _) => !usedMessages.contains(id));
    cache.swipes.removeWhere((id, _) => !usedSwipes.contains(id));
    if (batchStarted != null) profile?.record('script_projection', batchStarted);
    return projected;
  }

  Future<TavernScriptMessagePage> _getChatMessages(
    String contextId,
    TavernMessageRange range, {
    TavernScriptRole? role,
    TavernHiddenFilter hidden = TavernHiddenFilter.all,
    bool includeSwipes = false,
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    final count = capture.path.length;
    final first = range.first == null
        ? 0
        : range.first! < 0
        ? count + range.first!
        : range.first!;
    final last = range.last == null
        ? count - 1
        : range.last! < 0
        ? count + range.last!
        : range.last!;
    final result = <TavernScriptMessage>[];
    for (var index = max(0, first); index < count && index <= last; index++) {
      final node = capture.path[index];
      if (role != null && _scriptRole(node.message.role) != role) {
        continue;
      }
      if (hidden == TavernHiddenFilter.hiddenOnly && !node.message.hidden ||
          hidden == TavernHiddenFilter.visibleOnly && node.message.hidden) {
        continue;
      }
      result.add(_projectMessage(capture.chatId, node, index, includeSwipes: includeSwipes));
    }
    return TavernScriptMessagePage(pathRevision: capture.revision, totalPathLength: count, messages: result);
  });

  int _messageIndex(_ScriptChatCapture capture, int index, String operation, {bool allowEnd = false}) {
    final length = capture.path.length;
    final resolved = index < 0 ? length + index : index;
    if (resolved < 0 || resolved > length || !allowEnd && resolved == length) {
      throw _messageScriptError(
        capture.context.value.id,
        operation,
        TavernScriptErrorCode.range,
        'The message index is outside the captured path.',
      );
    }
    return resolved;
  }

  Map<String, Object?> _captureMessageFields(String contextId, Map<String, Object?> fields) {
    const operation = 'setChatMessages';
    const allowed = {
      'name',
      'role',
      'message',
      'hidden',
      'data',
      'extra',
      'swipeId',
      'swipes',
      'swipesData',
      'swipesInfo',
      'speakerCharacterId',
    };
    for (final entry in fields.entries) {
      final value = entry.value;
      if (!allowed.contains(entry.key)) {
        throw _messageScriptError(
          contextId,
          operation,
          TavernScriptErrorCode.invalidArgument,
          'Unknown message field: ${entry.key}',
          fieldPath: '/${entry.key}',
        );
      }
      final valid = switch (entry.key) {
        'name' || 'message' => value is String,
        'role' => value is String && TavernScriptRole.values.any((role) => role.name == value),
        'hidden' => value is bool,
        'data' || 'extra' => value is Map<String, Object?>,
        'speakerCharacterId' => value == null || value is String && value.isNotEmpty,
        'swipeId' => value is int && value >= 0,
        'swipes' => value is List<Object?> && value.isNotEmpty && value.every((item) => item is String),
        'swipesData' || 'swipesInfo' => value is List<Object?> && value.every((item) => item is Map<String, Object?>),
        _ => false,
      };
      if (!valid) {
        throw _messageScriptError(
          contextId,
          operation,
          TavernScriptErrorCode.invalidArgument,
          'Invalid value for message field ${entry.key}.',
          fieldPath: '/${entry.key}',
        );
      }
    }
    _checkUserExtra(contextId, operation, fields['extra'], '/extra');
    final infos = fields['swipesInfo'];
    if (infos is List<Object?>) {
      for (var index = 0; index < infos.length; index++) {
        final info = infos[index]! as Map<String, Object?>;
        if (info.containsKey('extra')) {
          if (info['extra'] is! Map<String, Object?>) {
            throw _messageScriptError(
              contextId,
              operation,
              TavernScriptErrorCode.invalidArgument,
              'Swipe extra must be an object.',
              fieldPath: '/swipesInfo/$index/extra',
            );
          }
          _checkUserExtra(contextId, operation, info['extra'], '/swipesInfo/$index/extra');
        }
      }
    }
    return fields;
  }

  void _checkUserExtra(String contextId, String operation, Object? value, String path) {
    if (value is Map<String, Object?> && value.containsKey('dshgo')) {
      throw _messageScriptError(
        contextId,
        operation,
        TavernScriptErrorCode.reservedField,
        'extra.dshgo is owned by the engine; edit state through data.',
        fieldPath: '$path/dshgo',
      );
    }
  }

  _CapturedMessagePatch _captureMessagePatch(_ScriptChatCapture capture, TavernScriptMessagePatch patch) {
    final contextId = capture.context.value.id;
    final fields = _captureMessageFields(contextId, patch.fields);
    String? target;
    if (patch.messageId != null) {
      target = capture.path[_messageIndex(capture, patch.messageId!, 'setChatMessages')].message.nodeId;
    }
    if (patch.ref != null) {
      if (patch.ref!.chatId != capture.chatId || target != null && target != patch.ref!.nodeId) {
        throw _messageScriptError(
          contextId,
          'setChatMessages',
          TavernScriptErrorCode.invalidArgument,
          'Message number and stable reference must identify the same page in this chat.',
        );
      }
      target = patch.ref!.nodeId;
    }
    if (target == null) {
      throw _messageScriptError(
        contextId,
        'setChatMessages',
        TavernScriptErrorCode.invalidArgument,
        'A message number or stable reference is required.',
      );
    }
    final node = _requireScriptNode(capture, target, 'setChatMessages');
    final family = engine._store.children(capture.chatId, node.message.parentId);
    final familyIds = [for (final page in family) page.message.nodeId];
    final targetIndex = familyIds.indexOf(target);
    final visible = capture.path.where((page) => page.message.parentId == node.message.parentId).firstOrNull;
    final newCount = fields['swipes'] is List<Object?> ? (fields['swipes']! as List<Object?>).length : family.length;
    final selectedIndex = fields['swipeId'] as int? ?? targetIndex;
    if (!fields.containsKey('swipeId') &&
        (targetIndex >= newCount || visible != null && familyIds.indexOf(visible.message.nodeId) >= newCount)) {
      throw _messageScriptError(
        contextId,
        'setChatMessages',
        TavernScriptErrorCode.invalidArgument,
        'Removing the target or selected page requires an explicit retained swipeId.',
      );
    }
    if (selectedIndex >= newCount) {
      throw _messageScriptError(
        contextId,
        'setChatMessages',
        TavernScriptErrorCode.range,
        'swipeId must identify a retained or newly supplied page.',
      );
    }
    for (final key in const ['swipesData', 'swipesInfo']) {
      if (fields[key] is List<Object?> && (fields[key]! as List<Object?>).length != newCount) {
        throw _messageScriptError(
          contextId,
          'setChatMessages',
          TavernScriptErrorCode.invalidArgument,
          '$key must have exactly one object per resulting swipe.',
        );
      }
    }
    void consistent(String field, Object? parallel) {
      if (fields.containsKey(field) && !_stateJsonEqual(fields[field], parallel)) {
        throw _messageScriptError(
          contextId,
          'setChatMessages',
          TavernScriptErrorCode.invalidArgument,
          'Conflicting repeated values for $field and its selected swipe.',
          fieldPath: '/$field',
        );
      }
    }

    if (fields['swipes'] is List<Object?>) {
      consistent('message', (fields['swipes']! as List<Object?>)[selectedIndex]);
    }
    if (fields['swipesData'] is List<Object?>) {
      consistent('data', (fields['swipesData']! as List<Object?>)[selectedIndex]);
    }
    if (fields['swipesInfo'] is List<Object?>) {
      final info = (fields['swipesInfo']! as List<Object?>)[selectedIndex]! as Map<String, Object?>;
      if (info.containsKey('extra')) {
        consistent('extra', info['extra']);
      }
    }
    return _CapturedMessagePatch(
      nodeId: target,
      fields: fields,
      familyIds: familyIds,
      newIds: [for (var index = family.length; index < newCount; index++) engine._store.newNodeId()],
      selectedIndex: selectedIndex,
      entryState: newCount > family.length ? engine._stateAt(capture.chatId, target) : null,
      needsCurrentPath: patch.messageId != null,
      structural: newCount != family.length || fields.containsKey('swipeId'),
    );
  }

  StoredNode _requireScriptNode(_ScriptChatCapture capture, String nodeId, String operation) {
    try {
      return engine._store.node(capture.chatId, nodeId);
    } on StateError {
      throw _messageScriptError(
        capture.context.value.id,
        operation,
        TavernScriptErrorCode.notFound,
        'The stable page no longer exists in this chat.',
        nodeId: nodeId,
      );
    }
  }

  Future<Map<String, _ScriptSpeakerCapture>> _messageSpeakers(
    _ScriptChatCapture capture,
    Iterable<String> ids,
    String operation,
  ) async {
    final result = <String, _ScriptSpeakerCapture>{};
    for (final id in ids.toSet()) {
      if (id.isEmpty) {
        throw _messageScriptError(
          capture.context.value.id,
          operation,
          TavernScriptErrorCode.invalidArgument,
          'speakerCharacterId must be nonempty or null.',
        );
      }
      final revision = engine._directors._cardRevisions[id] ?? 0;
      final record = await engine._record(id);
      if (record == null) {
        throw _messageScriptError(
          capture.context.value.id,
          operation,
          TavernScriptErrorCode.notFound,
          'The explicitly identified speaker does not exist.',
        );
      }
      if (revision != (engine._directors._cardRevisions[id] ?? 0)) {
        throw _messageScriptError(
          capture.context.value.id,
          operation,
          TavernScriptErrorCode.revisionConflict,
          'The speaker changed while preparing the message write.',
        );
      }
      result[id] = _ScriptSpeakerCapture(revision, record.card.name);
    }
    return result;
  }

  void _checkMessageSpeakers(
    _ScriptChatCapture capture,
    Map<String, _ScriptSpeakerCapture> speakers,
    String operation,
  ) {
    for (final entry in speakers.entries) {
      if (engine._deletingCharacters.contains(entry.key) ||
          entry.value.revision != (engine._directors._cardRevisions[entry.key] ?? 0)) {
        throw _messageScriptError(
          capture.context.value.id,
          operation,
          TavernScriptErrorCode.revisionConflict,
          'The captured speaker changed before commit.',
        );
      }
    }
  }

  void _checkMessageFamily(_ScriptChatCapture capture, String nodeId, List<String> expected, String operation) {
    final node = _requireScriptNode(capture, nodeId, operation);
    final actual = [
      for (final child in engine._store.children(capture.chatId, node.message.parentId)) child.message.nodeId,
    ];
    if (!_stateJsonEqual(expected, actual)) {
      throw _messageScriptError(
        capture.context.value.id,
        operation,
        TavernScriptErrorCode.revisionConflict,
        'The captured swipe family changed before commit.',
        nodeId: nodeId,
      );
    }
  }

  Future<TavernScriptMutation> _runMessagePlan(
    _ScriptChatCapture capture,
    String operation,
    TavernScriptWriteOptions options, {
    required bool structural,
    bool requireSamePath = false,
    void Function()? check,
    required void Function(_ScriptMessagePlan plan) prepare,
  }) async {
    late _ScriptMessagePlan plan;
    var committed = false;
    TavernScriptMutation action(_ToolPreparationPermit? permit) => _toolPreparationSql(
      engine,
      permit,
      () {
        _checkChatCapture(capture, expectedRevision: options.expectedPathRevision, requireSamePath: requireSamePath);
        check?.call();
        plan = _ScriptMessagePlan(this, capture, operation, options);
        prepare(plan);
        return plan.commit();
      },
      onCommitted: () {
        committed = true;
        plan.adoptCommitted();
      },
    );
    try {
      final mutation = structural
          ? await _structureWrite(capture, () => action(null))
          : await _dataWrite(capture, action);
      // This Future waits for committed cache delivery, never for the lifecycle
      // notifications produced by this write. A RECEIVED handler may await it.
      await _publishMutation(capture.context, mutation, events: plan.lifecycle(mutation));
      return mutation;
    } catch (error, stack) {
      if (!committed) {
        rethrow;
      }
      final failure = _scriptFailure(error);
      if (failure.committed) {
        rethrow;
      }
      Error.throwWithStackTrace(
        TavernScriptException(
          code: failure.code,
          operation: operation,
          message: failure.message,
          contextId: capture.context.value.id,
          nodeId: failure.nodeId,
          generationId: failure.generationId,
          executionId: failure.executionId,
          fieldPath: failure.fieldPath,
          sourceSpan: failure.sourceSpan,
          committed: true,
          modelFailure: failure.modelFailure,
          issues: failure.issues,
          stateEdit: failure.stateEdit,
        ),
        stack,
      );
    }
  }

  Future<TavernScriptMutation> _setChatMessages(
    String contextId,
    List<TavernScriptMessagePatch> patches, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    final captured = [for (final patch in patches) _captureMessagePatch(capture, patch)];
    return _setCapturedMessages(capture, captured, options);
  });

  Future<TavernScriptMutation> _setCapturedMessages(
    _ScriptChatCapture capture,
    List<_CapturedMessagePatch> patches,
    TavernScriptWriteOptions options,
  ) async {
    final needsData = patches.any(
      (patch) => patch.newIds.isNotEmpty || patch.fields.containsKey('data') || patch.fields.containsKey('swipesData'),
    );
    final forceGameplay =
        needsData &&
        patches.any(
          (patch) =>
              patch.entryState?.containsKey('dshgoPackDefinitionConfigId') == true ||
              patch.familyIds.any(
                (id) => engine._stateAt(capture.chatId, id).containsKey('dshgoPackDefinitionConfigId'),
              ),
        );
    final dataContext = needsData ? await _prepareDataContext(capture.chatId, forceGameplay: forceGameplay) : null;
    final speakers = await _messageSpeakers(capture, [
      for (final patch in patches)
        if (patch.fields['speakerCharacterId'] is String) patch.fields['speakerCharacterId']! as String,
    ], 'setChatMessages');
    return _runMessagePlan(
      capture,
      'setChatMessages',
      options,
      structural: patches.any((patch) => patch.structural),
      requireSamePath: patches.any((patch) => patch.needsCurrentPath),
      check: () {
        _checkMessageSpeakers(capture, speakers, 'setChatMessages');
        for (final patch in patches) {
          _requireScriptNode(capture, patch.nodeId, 'setChatMessages');
          if (const ['swipes', 'swipesData', 'swipesInfo', 'swipeId'].any(patch.fields.containsKey)) {
            _checkMessageFamily(capture, patch.nodeId, patch.familyIds, 'setChatMessages');
          }
        }
      },
      prepare: (plan) {
        if (dataContext != null) {
          _checkDataContext(dataContext);
        }
        for (final patch in patches) {
          plan.applyPatch(patch, dataContext);
        }
      },
    );
  }

  Future<TavernScriptMutation> _createChatMessages(
    String contextId,
    List<TavernScriptMessageDraft> messages, {
    int? insertBefore,
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    final insertion = insertBefore == null
        ? capture.path.length
        : _messageIndex(capture, insertBefore, 'createChatMessages', allowEnd: true);
    final drafts = <_CapturedMessageDraft>[];
    for (final message in messages) {
      final extra = message.extra;
      _checkUserExtra(contextId, 'createChatMessages', extra, '/extra');
      final speaker =
          message.speakerCharacterId ??
          (message.role == TavernScriptRole.assistant ? capture.context.value.characterId : null);
      if (speaker == '') {
        throw _messageScriptError(
          contextId,
          'createChatMessages',
          TavernScriptErrorCode.invalidArgument,
          'speakerCharacterId must be nonempty or omitted.',
        );
      }
      drafts.add(
        _CapturedMessageDraft(
          id: engine._store.newNodeId(),
          role: message.role,
          text: message.message,
          name: message.name,
          hidden: message.hidden,
          speakerCharacterId: speaker,
          data: message.data,
          extra: extra,
        ),
      );
    }
    return _createCapturedMessages(capture, drafts, insertion, options);
  });

  Future<TavernScriptMutation> _createCapturedMessages(
    _ScriptChatCapture capture,
    List<_CapturedMessageDraft> drafts,
    int insertion,
    TavernScriptWriteOptions options,
  ) async {
    final capturedParent = insertion == 0 ? null : capture.path[insertion - 1].message.nodeId;
    final dataContext = drafts.isEmpty
        ? null
        : await _prepareDataContext(
            capture.chatId,
            forceGameplay: engine._stateAt(capture.chatId, capturedParent).containsKey('dshgoPackDefinitionConfigId'),
          );
    final speakers = await _messageSpeakers(capture, [
      for (final draft in drafts) ?draft.speakerCharacterId,
    ], 'createChatMessages');
    return _runMessagePlan(
      capture,
      'createChatMessages',
      options,
      structural: drafts.isNotEmpty,
      requireSamePath: true,
      check: () => _checkMessageSpeakers(capture, speakers, 'createChatMessages'),
      prepare: (plan) {
        if (drafts.isEmpty) {
          return;
        }
        final context = dataContext!;
        _checkDataContext(context);
        final oldPath = List<String>.of(plan.path);
        final before = insertion < oldPath.length ? oldPath[insertion] : null;
        final oldFamily = before == null ? <String>[] : plan.children(plan.links[before]!.parentId, physical: true);
        String? parent = insertion == 0 ? null : oldPath[insertion - 1];
        final initial = parent == null ? _initialMessageState(context) : null;
        var baseline = initial?.state ?? _copy(plan.page(parent!).state);
        if (initial != null && initial.adoptedGameplay != null) {
          plan.initialized[drafts.first.id] = initial;
        }
        final chat = engine._store.chat(capture.chatId);
        final settings = _personaSettings(
          engine._effectiveSettings(chat, engine._chatCodec.metadataForNode(engine._store, capture.chatId)),
          engine._personas.resolve(personaId: chat.personaId),
        );
        final userName = settings['userName'] is String ? settings['userName']! as String : 'User';
        for (final draft in drafts) {
          final name =
              draft.name ??
              switch (draft.role) {
                TavernScriptRole.user => userName,
                TavernScriptRole.assistant => speakers[draft.speakerCharacterId]?.name ?? 'Assistant',
                TavernScriptRole.system => 'System',
              };
          final value = _ScriptWorkingPage(
            id: draft.id,
            created: true,
            role: _scriptNativeRole(draft.role),
            name: name,
            text: draft.text,
            hidden: draft.hidden,
            speakerCharacterId: draft.speakerCharacterId,
            state: _copy(baseline),
            extra: _copy(draft.extra),
            original: <String, Object?>{},
          );
          plan.add(value, parent);
          if (draft.data != null) {
            plan.setData(value, draft.data!, context);
          }
          baseline = _copy(value.state);
          parent = value.id;
        }
        for (final id in oldFamily) {
          plan.reparent(id, parent);
        }
        plan.path = [...oldPath.take(insertion), for (final draft in drafts) draft.id, ...oldPath.skip(insertion)];
        // Raw CRUD creates cache data; it is not a send/receive operation.
      },
    );
  }

  Future<TavernScriptMutation> _deleteChatMessages(
    String contextId,
    List<int> messageIds, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    final targets = {
      for (final index in messageIds) capture.path[_messageIndex(capture, index, 'deleteChatMessages')].message.nodeId,
    };
    return _runMessagePlan(
      capture,
      'deleteChatMessages',
      options,
      structural: targets.isNotEmpty,
      requireSamePath: true,
      prepare: (plan) => plan.deleteFamilies(targets),
    );
  });

  Future<TavernScriptMutation> _rotateChatMessages(
    String contextId,
    int begin,
    int middle,
    int end, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    final first = _messageIndex(capture, begin, 'rotateChatMessages', allowEnd: true);
    final split = _messageIndex(capture, middle, 'rotateChatMessages', allowEnd: true);
    final last = _messageIndex(capture, end, 'rotateChatMessages', allowEnd: true);
    if (first > split || split > last) {
      throw _messageScriptError(
        contextId,
        'rotateChatMessages',
        TavernScriptErrorCode.range,
        'Rotation requires begin <= middle <= end within the captured path.',
      );
    }
    final ids = [for (final node in capture.path) node.message.nodeId];
    final desired = [...ids.take(first), ...ids.sublist(split, last), ...ids.sublist(first, split), ...ids.skip(last)];
    return _runMessagePlan(
      capture,
      'rotateChatMessages',
      options,
      structural: first != split && split != last,
      requireSamePath: true,
      prepare: (plan) {
        if (!_stateJsonEqual(plan.path, desired)) {
          plan.reorder(desired);
        }
      },
    );
  });

  Future<TavernScriptMutation> _selectSwipe(
    String contextId,
    TavernScriptMessageRef message,
    int swipeId, {
    TavernScriptWriteOptions options = const TavernScriptWriteOptions(),
  }) => Future.sync(() {
    final capture = _captureChat(contextId);
    if (message.chatId != capture.chatId) {
      throw _messageScriptError(
        contextId,
        'selectSwipe',
        TavernScriptErrorCode.invalidArgument,
        'The stable message reference belongs to another chat.',
      );
    }
    final node = _requireScriptNode(capture, message.nodeId, 'selectSwipe');
    final family = [
      for (final sibling in engine._store.children(capture.chatId, node.message.parentId)) sibling.message.nodeId,
    ];
    if (swipeId < 0 || swipeId >= family.length) {
      throw _messageScriptError(
        contextId,
        'selectSwipe',
        TavernScriptErrorCode.range,
        'swipeId is outside the captured page family.',
      );
    }
    final selected = family[swipeId];
    return _runMessagePlan(
      capture,
      'selectSwipe',
      options,
      structural: true,
      check: () => _checkMessageFamily(capture, message.nodeId, family, 'selectSwipe'),
      prepare: (plan) => plan.select(selected),
    );
  });
}

class _ScriptSpeakerCapture {
  _ScriptSpeakerCapture(this.revision, this.name);
  final int revision;
  final String name;
}

class _CapturedMessageDraft {
  _CapturedMessageDraft({
    required this.id,
    required this.role,
    required this.text,
    required this.hidden,
    required this.extra,
    this.name,
    this.speakerCharacterId,
    this.data,
  });
  final String id;
  final TavernScriptRole role;
  final String text;
  final String? name;
  final bool hidden;
  final String? speakerCharacterId;
  final Map<String, Object?>? data;
  final Map<String, Object?> extra;
}

class _CapturedMessagePatch {
  _CapturedMessagePatch({
    required this.nodeId,
    required this.fields,
    required this.familyIds,
    required this.newIds,
    required this.selectedIndex,
    required this.needsCurrentPath,
    required this.structural,
    this.entryState,
  });
  final String nodeId;
  final Map<String, Object?> fields;
  final List<String> familyIds;
  final List<String> newIds;
  final int selectedIndex;
  final bool needsCurrentPath;
  final bool structural;
  final Map<String, Object?>? entryState;
}

class _ScriptPlannedLink {
  _ScriptPlannedLink(this.parentId, this.selectedChildId, this.sequence, this.deleted);
  String? parentId;
  String? selectedChildId;
  final int sequence;
  final bool deleted;
}

class _ScriptWorkingPage {
  _ScriptWorkingPage({
    required this.id,
    required this.created,
    required this.role,
    required this.name,
    required this.text,
    required this.hidden,
    required this.state,
    required this.extra,
    required this.original,
    this.speakerCharacterId,
  });
  final String id;
  final bool created;
  TavernRole role;
  String name;
  String text;
  bool hidden;
  String? speakerCharacterId;
  Map<String, Object?> state;
  Map<String, Object?> extra;
  Map<String, Object?> original;
  final dirty = <String>{};
}

/// A detached batch plan. Field and DSH preparation finish before the first
/// SQL write; later patches see earlier planned changes but retain their
/// originally captured target ids. Only edited pages load full state.
class _ScriptMessagePlan {
  _ScriptMessagePlan(this.owner, this.capture, this.operation, this.options)
    : oldRevision = owner._pathRevision(capture.chatId),
      beforePath = owner.engine._historyTo(capture.chatId, owner.engine._store.chat(capture.chatId).currentLeafId),
      originalLinks = owner.engine._store.treeLinks(capture.chatId) {
    links.addAll({
      for (final entry in originalLinks.entries)
        entry.key: _ScriptPlannedLink(
          entry.value.parentId,
          entry.value.selectedChildId,
          entry.value.sequence,
          entry.value.deleted,
        ),
    });
    path = [for (final node in beforePath) node.message.nodeId];
    sequence = originalLinks.values.fold<int>(0, (value, link) => max(value, link.sequence));
  }
  final _ScriptCoordinator owner;
  final _ScriptChatCapture capture;
  final String operation;
  final TavernScriptWriteOptions options;
  final String oldRevision;
  final List<StoredNode> beforePath;
  final Map<String, StoredTreeLink> originalLinks;
  final links = <String, _ScriptPlannedLink>{};
  final pages = <String, _ScriptWorkingPage>{};
  final removed = <String>{};
  final affected = <String>{};
  final edited = <String>{};
  final updated = <String>{};
  final prepared = <({String id, _ScriptPreparedData value})>[];
  final initialized = <String, _ScriptPreparedData>{};
  final swiped = <({String? before, String after})>[];
  late List<String> path;
  late int sequence;
  bool changed = false;
  bool clearCachedInspection = false;
  String get chatId => capture.chatId;
  TavernEngine get engine => owner.engine;

  Never fail(TavernScriptErrorCode code, String text, {String? nodeId}) =>
      throw _messageScriptError(capture.context.value.id, operation, code, text, nodeId: nodeId);

  _ScriptWorkingPage page(String id) {
    final link = links[id];
    if (link == null || link.deleted || removed.contains(id)) {
      fail(TavernScriptErrorCode.notFound, 'A captured page was removed earlier in this batch.', nodeId: id);
    }
    return pages.putIfAbsent(id, () {
      final node = engine._store.node(chatId, id);
      return _ScriptWorkingPage(
        id: id,
        created: false,
        role: node.message.role,
        name: node.message.speaker,
        text: node.message.text,
        hidden: node.message.hidden,
        speakerCharacterId: node.message.speakerCharacterId,
        state: engine._stateAt(chatId, id),
        extra: engine._store.rawNodeExtra(chatId, id),
        original: _copy(node.original),
      );
    });
  }

  List<String> children(String? parent, {bool physical = false}) {
    final ids = [
      for (final entry in links.entries)
        if (entry.value.parentId == parent && !removed.contains(entry.key) && (physical || !entry.value.deleted))
          entry.key,
    ];
    ids.sort((left, right) => links[left]!.sequence.compareTo(links[right]!.sequence));
    return ids;
  }

  void add(_ScriptWorkingPage value, String? parent) {
    if (links.containsKey(value.id)) {
      fail(TavernScriptErrorCode.duplicateId, 'Allocated page id is already present.');
    }
    pages[value.id] = value;
    links[value.id] = _ScriptPlannedLink(parent, null, ++sequence, false);
    affected.add(value.id);
  }

  void reparent(String id, String? parent) {
    final link = links[id];
    if (link == null || removed.contains(id)) {
      fail(TavernScriptErrorCode.notFound, 'Missing page in a tree plan.', nodeId: id);
    }
    if (link.parentId == parent) {
      return;
    }
    link.parentId = parent;
    if (!link.deleted) {
      affected.add(id);
    }
  }

  void select(String id) {
    if (!links.containsKey(id) || links[id]!.deleted || removed.contains(id)) {
      fail(TavernScriptErrorCode.notFound, 'The selected page is no longer available.', nodeId: id);
    }
    final old = path.where((candidate) => links[candidate]!.parentId == links[id]!.parentId).firstOrNull;
    final ancestors = <String>[];
    final visited = <String>{};
    String? current = id;
    while (current != null) {
      if (!visited.add(current) ||
          !links.containsKey(current) ||
          links[current]!.deleted ||
          removed.contains(current)) {
        fail(TavernScriptErrorCode.invalidArgument, 'The selected page has an invalid ancestor path.');
      }
      ancestors.add(current);
      current = links[current]!.parentId;
    }
    final next = ancestors.reversed.toList();
    current = links[id]!.selectedChildId;
    while (current != null) {
      if (!visited.add(current) ||
          !links.containsKey(current) ||
          links[current]!.deleted ||
          removed.contains(current) ||
          links[current]!.parentId != next.last) {
        fail(TavernScriptErrorCode.invalidArgument, 'The selected page has an invalid remembered child.');
      }
      next.add(current);
      current = links[current]!.selectedChildId;
    }
    if (!_stateJsonEqual(path, next)) {
      swiped.add((before: old, after: id));
      affected.add(id);
    }
    path = next;
    for (var index = 0; index < path.length; index++) {
      links[path[index]]!.selectedChildId = index + 1 < path.length ? path[index + 1] : null;
    }
  }

  void setText(_ScriptWorkingPage target, String value) {
    if (target.text == value) {
      return;
    }
    target.text = value;
    target.dirty.add('message');
    edited.add(target.id);
    affected.add(target.id);
  }

  void setExtra(_ScriptWorkingPage target, Map<String, Object?> value) {
    final next = <String, Object?>{
      ..._copy(value),
      if (target.extra.containsKey('dshgo')) 'dshgo': target.extra['dshgo'],
    };
    if (_stateJsonEqual(target.extra, next)) {
      return;
    }
    target.extra = next;
    target.dirty.add('extra');
    updated.add(target.id);
    affected.add(target.id);
  }

  void setInfo(_ScriptWorkingPage target, Map<String, Object?> value) {
    final original = _copy(target.original);
    final rawIndex = original['swipe_id'];
    final index = rawIndex is num && rawIndex.isFinite && rawIndex >= 0 && rawIndex == rawIndex.roundToDouble()
        ? rawIndex.toInt()
        : 0;
    final old = original['swipe_info'];
    final infos = old is List<Object?> ? List<Object?>.of(old) : <Object?>[];
    while (infos.length <= index) {
      infos.add(null);
    }
    infos[index] = _copy(value);
    original['swipe_info'] = infos;
    for (final key in const ['send_date', 'gen_started', 'gen_finished']) {
      if (value.containsKey(key)) {
        original[key] = value[key];
      } else {
        original.remove(key);
      }
    }
    if (!_stateJsonEqual(target.original, original)) {
      target.original = original;
      target.dirty.add('original');
      updated.add(target.id);
      affected.add(target.id);
    }
    if (value['extra'] case final Map<String, Object?> extra) {
      setExtra(target, extra);
    }
  }

  void setData(_ScriptWorkingPage target, Map<String, Object?> value, _ScriptDataContext context) {
    final result = owner._prepareMessageData(
      context,
      nodeId: target.id,
      baseline: target.state,
      data: value,
      extra: target.extra,
    );
    target.state = _copy(result.state);
    prepared.add((id: target.id, value: result));
    affected.add(target.id);
  }

  void applyPatch(_CapturedMessagePatch captured, _ScriptDataContext? dataContext) {
    final originalTarget = page(captured.nodeId);
    final parent = links[captured.nodeId]!.parentId;
    var family = children(parent);
    final fields = captured.fields;
    final supplied = fields['swipes'] as List<Object?>?;
    if (supplied != null) {
      final retained = captured.familyIds.take(min(supplied.length, captured.familyIds.length)).toList();
      for (final id in retained) {
        if (!family.contains(id)) {
          fail(
            TavernScriptErrorCode.revisionConflict,
            'A prior batch operation changed a retained page family.',
            nodeId: id,
          );
        }
      }
      final desired = [...retained, ...captured.newIds];
      if (desired.length != supplied.length) {
        fail(TavernScriptErrorCode.invalidArgument, 'Invalid resulting swipe count.');
      }
      for (final id in captured.newIds) {
        final state = _copy(captured.entryState!);
        final value = _ScriptWorkingPage(
          id: id,
          created: true,
          role: originalTarget.role,
          name: originalTarget.name,
          text: originalTarget.text,
          hidden: originalTarget.hidden,
          speakerCharacterId: originalTarget.speakerCharacterId,
          state: state,
          extra: _scriptUserExtra(originalTarget.extra),
          original: <String, Object?>{},
        );
        add(value, parent);
        // An inherited object traverses the common validator without changing
        // dshgo or its runtime. Absent/malformed historical data is inherited
        // verbatim, never silently replaced by an empty successful object.
        if (state['messageVariables'] case final Map<String, Object?> inherited) {
          setData(value, inherited, dataContext!);
        }
      }
      final toRemove = family.where((id) => !desired.contains(id)).toSet();
      if (!fields.containsKey('swipeId') && (toRemove.contains(captured.nodeId) || path.any(toRemove.contains))) {
        fail(TavernScriptErrorCode.invalidArgument, 'Removing a target or selected page requires explicit swipeId.');
      }
      final recipient = desired[captured.selectedIndex];
      // Keep the recipient's own remembered continuation, including null.
      // Newly attached futures never replace it or become an implicit first child.
      for (final id in toRemove) {
        for (final child in children(id, physical: true)) {
          reparent(child, recipient);
        }
        removed.add(id);
        affected.add(id);
      }
      for (final link in links.values) {
        if (removed.contains(link.selectedChildId)) {
          link.selectedChildId = null;
        }
      }
      family = desired;
      for (var index = 0; index < family.length; index++) {
        setText(page(family[index]), supplied[index]! as String);
      }
      if (toRemove.isNotEmpty || captured.newIds.isNotEmpty) {
        updated.add(recipient);
        affected.add(recipient);
      }
    }
    final targetId = fields.containsKey('swipeId')
        ? (supplied == null ? captured.familyIds : family)[captured.selectedIndex]
        : captured.nodeId;
    final target = page(targetId);
    final datas = fields['swipesData'] as List<Object?>?;
    final infos = fields['swipesInfo'] as List<Object?>?;
    for (final values in [datas, infos]) {
      if (values != null && values.length != family.length) {
        fail(TavernScriptErrorCode.invalidArgument, 'A swipe object list does not match the current batch family.');
      }
    }
    if (infos != null) {
      for (var index = 0; index < family.length; index++) {
        setInfo(page(family[index]), infos[index]! as Map<String, Object?>);
      }
    }
    if (fields['extra'] case final Map<String, Object?> extra) {
      setExtra(target, extra);
    }
    if (fields['name'] case final String name) {
      if (target.name != name) {
        target.name = name;
        target.dirty.add('name');
        updated.add(targetId);
        affected.add(targetId);
      }
    }
    if (fields['role'] case final String role) {
      final requested = TavernScriptRole.values.byName(role);
      if (_scriptRole(target.role) != requested) {
        target.role = _scriptNativeRole(requested);
        target.dirty.add('role');
        updated.add(targetId);
        affected.add(targetId);
      }
    }
    if (fields['hidden'] case final bool hidden) {
      if (target.hidden != hidden) {
        target.hidden = hidden;
        target.dirty.add('hidden');
        updated.add(targetId);
        affected.add(targetId);
      }
      // Native setHidden also owns this saved ST exclusion marker. An
      // explicit bridge write must not leave it sticky when the column has
      // already changed; an omitted hidden field still preserves it verbatim.
      if (target.original.containsKey('is_system') && target.original['is_system'] != hidden) {
        target.original['is_system'] = hidden;
        target.dirty.add('original');
        updated.add(targetId);
        affected.add(targetId);
      }
    }
    if (fields.containsKey('speakerCharacterId') && target.speakerCharacterId != fields['speakerCharacterId']) {
      target.speakerCharacterId = fields['speakerCharacterId'] as String?;
      target.dirty.add('speakerCharacterId');
      updated.add(targetId);
      affected.add(targetId);
    }
    if (supplied == null) {
      if (fields['message'] case final String text) {
        setText(target, text);
      }
    }
    if (datas != null) {
      for (var index = 0; index < family.length; index++) {
        setData(page(family[index]), datas[index]! as Map<String, Object?>, dataContext!);
      }
    } else if (fields['data'] case final Map<String, Object?> data) {
      setData(target, data, dataContext!);
    }
    if (fields.containsKey('swipeId')) {
      select(targetId);
    }
  }

  void deleteFamilies(Set<String> targets) {
    for (final id in targets) {
      page(id);
      removed.addAll(children(links[id]!.parentId));
    }
    for (final entry in links.entries) {
      if (removed.contains(entry.key)) {
        continue;
      }
      var parent = entry.value.parentId;
      final seen = <String>{};
      while (parent != null && removed.contains(parent)) {
        if (!seen.add(parent)) {
          fail(TavernScriptErrorCode.invalidArgument, 'Invalid deleted ancestor chain.');
        }
        parent = links[parent]!.parentId;
      }
      reparent(entry.key, parent);
    }
    for (final link in links.values) {
      if (removed.contains(link.selectedChildId)) {
        link.selectedChildId = null;
      }
    }
    path = path.where((id) => !removed.contains(id)).toList();
    affected.addAll(removed);
  }

  void reorder(List<String> desired) {
    final families = <String, List<String>>{
      for (final node in beforePath) node.message.nodeId: children(node.message.parentId, physical: true),
    };
    for (var index = 0; index < desired.length; index++) {
      final parent = index == 0 ? null : desired[index - 1];
      for (final id in families[desired[index]]!) {
        reparent(id, parent);
      }
    }
    path = desired;
  }

  TavernScriptMutation commit() {
    // Normalize only the final batch projection. An intermediate role change
    // must not erase an identity a later patch validly keeps as character.
    for (final value in pages.values) {
      if (removed.contains(value.id) || value.role == TavernRole.character || value.speakerCharacterId == null) {
        continue;
      }
      value.speakerCharacterId = null;
      if (!value.created) {
        value.dirty.add('speakerCharacterId');
        updated.add(value.id);
        affected.add(value.id);
      }
    }
    final beforeChat = engine._store.chat(chatId);
    final storedLatest = removed.isEmpty ? null : engine._storedLatestInspection(beforeChat);
    final latestPointer = _map(_map(beforeChat.metadata['dshgo'])['latestInspection'])['nodeId'];
    final storedAnchor = storedLatest?.nodeId ?? storedLatest?.contextNodeId;
    final cachedLatest = engine._latestInspections[chatId];
    final cachedAnchor = cachedLatest?.nodeId ?? cachedLatest?.contextNodeId;
    clearCachedInspection = cachedAnchor != null && removed.contains(cachedAnchor);
    final pending = [
      for (final value in pages.values)
        if (value.created && !removed.contains(value.id)) value,
    ];
    final inserted = <String>{};
    while (pending.isNotEmpty) {
      var progress = false;
      for (final value in List<_ScriptWorkingPage>.of(pending)) {
        final parent = links[value.id]!.parentId;
        if (parent != null && !originalLinks.containsKey(parent) && !inserted.contains(parent)) {
          continue;
        }
        final initial = initialized[value.id];
        if (initial != null) {
          owner._ensurePreparedGameplay(initial);
        }
        engine._store.append(
          chatId,
          id: value.id,
          parentId: parent,
          role: value.role,
          speaker: value.name,
          speakerCharacterId: value.speakerCharacterId,
          text: value.text,
          hidden: value.hidden,
          state: value.state,
          extra: value.extra,
          original: value.original,
          makeCurrent: false,
        );
        inserted.add(value.id);
        pending.remove(value);
        progress = true;
      }
      if (!progress) {
        fail(TavernScriptErrorCode.invalidArgument, 'New pages contain an invalid parent cycle.');
      }
    }
    for (final value in pages.values) {
      if (value.created || removed.contains(value.id) || value.dirty.isEmpty) {
        continue;
      }
      engine._store.updateMessage(
        chatId,
        value.id,
        role: value.dirty.contains('role') ? value.role : null,
        speaker: value.dirty.contains('name') ? value.name : null,
        hidden: value.dirty.contains('hidden') ? value.hidden : null,
        text: value.dirty.contains('message') ? value.text : null,
        speakerCharacterId: value.dirty.contains('speakerCharacterId') ? value.speakerCharacterId : null,
        clearSpeakerCharacterId: value.dirty.contains('speakerCharacterId') && value.speakerCharacterId == null,
        extra: value.dirty.contains('extra') ? value.extra : null,
        original: value.dirty.contains('original') ? value.original : null,
      );
    }
    final edits = <String, TavernStateEditResult>{};
    for (final item in prepared) {
      if (removed.contains(item.id)) {
        continue;
      }
      owner._commitMessageData(chatId, item.id, item.value);
      if (item.value.stateEdit case final edit?) {
        edits[item.id] = edit;
      }
    }
    final parents = <String, String?>{
      for (final entry in links.entries)
        if (!removed.contains(entry.key) &&
            originalLinks.containsKey(entry.key) &&
            originalLinks[entry.key]!.parentId != entry.value.parentId)
          entry.key: entry.value.parentId,
    };
    final choices = <String, String?>{};
    for (final entry in links.entries) {
      if (removed.contains(entry.key) ||
          !originalLinks.containsKey(entry.key) ||
          originalLinks[entry.key]!.selectedChildId == entry.value.selectedChildId) {
        continue;
      }
      final child = entry.value.selectedChildId;
      if (child == null || !removed.contains(child) && links[child]?.parentId == entry.key && !links[child]!.deleted) {
        choices[entry.key] = child;
      }
    }
    final pathChanged = !_stateJsonEqual([for (final node in beforePath) node.message.nodeId], path);
    if (parents.isNotEmpty || choices.isNotEmpty || inserted.isNotEmpty || removed.isNotEmpty || pathChanged) {
      engine._store.rewriteTree(
        chatId,
        parentByNode: parents,
        selectedPath: path,
        selectedChildren: choices,
        deleteNodeIds: {
          for (final id in removed)
            if (originalLinks.containsKey(id)) id,
        },
        capturePortableState: (node, physical) {
          final override = _map(node.extra['dshgo'])['tavernState'];
          return engine._withStateHash(beforeChat, _copy(override is Map<String, Object?> ? override : physical));
        },
      );
    }
    changed = owner._pathRevision(chatId) != oldRevision;
    if (changed) {
      engine._restoreVariables(chatId);
      if (removed.contains(latestPointer) || storedAnchor != null && removed.contains(storedAnchor)) {
        engine._writeLatestInspection(chatId, null);
      }
    }
    final after = engine._historyTo(chatId, engine._store.chat(chatId).currentLeafId);
    final changedIndices = <int, TavernScriptMessageRef?>{};
    for (var index = 0; index < max(beforePath.length, after.length); index++) {
      final oldId = index < beforePath.length ? beforePath[index].message.nodeId : null;
      final newId = index < after.length ? after[index].message.nodeId : null;
      if (oldId != newId) {
        changedIndices[index] = newId == null ? null : _scriptRef(chatId, newId);
      }
    }
    final affectedParents = {
      for (final id in affected)
        if (links.containsKey(id) && !removed.contains(id)) links[id]!.parentId,
    };
    return TavernScriptMutation(
      oldRevision: oldRevision,
      pathRevision: owner._pathRevision(chatId),
      affectedRefs: [
        for (final id in affected)
          if (!removed.contains(id)) _scriptRef(chatId, id),
      ],
      removedRefs: [
        for (final id in removed)
          if (originalLinks.containsKey(id)) _scriptRef(chatId, id),
      ],
      indexChanges: changedIndices,
      refresh: options.refresh,
      stateEdits: edits,
      upsertMessages: [
        for (var index = 0; index < after.length; index++)
          if (changedIndices.containsKey(index) ||
              affected.contains(after[index].message.nodeId) ||
              affectedParents.contains(after[index].message.parentId))
            owner._projectMessage(chatId, after[index], index, includeSwipes: true),
      ],
    );
  }

  /// Only synchronous in-memory adoption belongs in the outer COMMIT hook.
  /// No SQL, host callback or cache invalidation runs before a successful commit.
  void adoptCommitted() {
    if (changed) {
      engine._liveVariables.remove(chatId);
    }
    if (clearCachedInspection) {
      engine._latestInspections.remove(chatId);
    }
  }

  List<_ScriptLifecycle> lifecycle(TavernScriptMutation mutation) {
    final indices = {for (var index = 0; index < path.length; index++) path[index]: index};
    final result = <_ScriptLifecycle>[];
    void add(String name, String id) {
      if (removed.contains(id)) {
        return;
      }
      result.add(_ScriptLifecycle(name: name, nodeRef: _scriptRef(chatId, id), args: [?indices[id]]));
    }

    for (final id in edited) {
      add('MESSAGE_EDITED', id);
    }
    for (final id in updated) {
      add('MESSAGE_UPDATED', id);
    }
    for (final selection in swiped) {
      if (removed.contains(selection.after)) {
        continue;
      }
      result.add(
        _ScriptLifecycle(
          name: 'MESSAGE_SWIPED',
          nodeRef: _scriptRef(chatId, selection.after),
          args: [
            ?indices[selection.after],
            {
              'oldRef': selection.before == null ? null : {'chatId': chatId, 'nodeId': selection.before},
              'newRef': {'chatId': chatId, 'nodeId': selection.after},
              'swipeId': children(links[selection.after]!.parentId).indexOf(selection.after),
            },
          ],
        ),
      );
    }
    if (mutation.removedRefs.isNotEmpty) {
      final oldFloor = {
        for (var index = 0; index < beforePath.length; index++) beforePath[index].message.parentId: index,
      };
      result.add(
        _ScriptLifecycle(
          name: 'MESSAGE_DELETED',
          args: [
            {
              'removed': [
                for (final ref in mutation.removedRefs)
                  {
                    'chatId': ref.chatId,
                    'nodeId': ref.nodeId,
                    'messageId': oldFloor[originalLinks[ref.nodeId]!.parentId],
                  },
              ],
              'pathRevision': mutation.pathRevision,
            },
          ],
        ),
      );
    }
    return result;
  }
}
