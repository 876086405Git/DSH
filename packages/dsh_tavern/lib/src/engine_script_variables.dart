part of 'engine.dart';

class _ResolvedScriptVariable {
  _ResolvedScriptVariable(this.context, this.target, {this.capture, this.requireSamePath = false});
  final _ScriptContextState context;
  final TavernVariableTarget target;
  final _ScriptChatCapture? capture;
  final bool requireSamePath;
}

class _ScriptRawVariable {
  const _ScriptRawVariable(this.present, this.value);
  final bool present;
  final Object? value;
}

class _ScriptVariableVersion {
  _ScriptVariableVersion(this.target, this.identity, this.fingerprint);
  final TavernVariableTarget target;
  final int identity;
  String fingerprint;
  int revision = 0;
  int? messageTreeRevision;
}

class _ScriptDataContext {
  _ScriptDataContext(
    this.chatId,
    this.hostId,
    this.hostRevision,
    this.hostData,
    this.definition,
    this.settings, {
    this.gameplay,
    this.gameplayAdmission,
  });
  final String chatId;
  final String hostId;
  final int hostRevision;
  final Map<String, Object?> hostData;
  final state_core.StateDefinition definition;
  final Map<String, Object?> settings;
  final _GameplayRuntime? gameplay;
  final _GameplayAdmission? gameplayAdmission;
}

class _ScriptPreparedData {
  _ScriptPreparedData(this.state, this.stateEdit, this.audit, this.run, {this.adoptedGameplay, this.gameplayAdmission});
  final Map<String, Object?> state;
  final TavernStateEditResult? stateEdit;
  final Map<String, Object?>? audit;
  final Map<String, Object?>? run;
  final _GameplayRuntime? adoptedGameplay;
  final _GameplayAdmission? gameplayAdmission;
}

extension _ScriptVariableOperations on _ScriptCoordinator {
  _ResolvedScriptVariable _resolveTarget(_ScriptContextState context, TavernVariableTarget target) {
    _context(context.value.id);
    void invalid(String text) =>
        throw _scriptError(TavernScriptErrorCode.invalidArgument, 'variables', text, contextId: context.value.id);
    if (target.scope != TavernVariableScope.message && (target.messageId != null || target.messageRef != null)) {
      invalid('Only the message scope accepts a message identity.');
    }
    if (target.scope != TavernVariableScope.character && target.characterId != null) {
      invalid('Unexpected character identity.');
    }
    if (target.scope != TavernVariableScope.script && target.scriptOwner != null) {
      invalid('Unexpected script owner.');
    }
    if (target.scope != TavernVariableScope.chat &&
        target.scope != TavernVariableScope.message &&
        target.chatId != null) {
      invalid('Unexpected chat identity.');
    }
    TavernVariableTarget resolved;
    _ScriptChatCapture? capture;
    switch (target.scope) {
      case TavernVariableScope.global:
        resolved = const TavernVariableTarget(scope: TavernVariableScope.global);
      case TavernVariableScope.character:
        final id = target.characterId ?? context.value.characterId;
        if (id == null) {
          throw _scriptError(TavernScriptErrorCode.noContext, 'variables', 'No character is bound.');
        }
        resolved = TavernVariableTarget(scope: target.scope, characterId: id);
      case TavernVariableScope.script:
        final owner = target.scriptOwner ?? context.value.script;
        if (owner == null) {
          throw _scriptError(TavernScriptErrorCode.noContext, 'variables', 'No script owner is bound.');
        }
        _checkOwnerIdentity(owner);
        resolved = TavernVariableTarget(scope: target.scope, scriptOwner: owner);
      case TavernVariableScope.chat || TavernVariableScope.message:
        final id = target.chatId ?? target.messageRef?.chatId ?? context.value.chatId;
        if (id == null) {
          throw _scriptError(TavernScriptErrorCode.noContext, 'variables', 'No chat is bound.');
        }
        if (target.messageRef != null && target.messageRef!.chatId != id) {
          invalid('Message and chat identities disagree.');
        }
        capture = _captureChatAt(context, id);
        if (target.scope == TavernVariableScope.chat) {
          resolved = TavernVariableTarget(scope: target.scope, chatId: id);
          break;
        }
        var ref = target.messageRef;
        if (ref == null || target.messageId != null) {
          final requested = target.messageId ?? -1;
          final index = requested < 0 ? capture.path.length + requested : requested;
          if (index < 0 || index >= capture.path.length) {
            throw _scriptError(
              TavernScriptErrorCode.range,
              'variables',
              'The requested message is outside the captured path.',
            );
          }
          final numbered = TavernScriptMessageRef(chatId: id, nodeId: capture.path[index].message.nodeId);
          if (ref != null && ref != numbered) {
            invalid('Message number and stable reference disagree.');
          }
          ref = numbered;
        }
        final nodeId = ref.nodeId;
        if (!capture.path.any((node) => node.message.nodeId == nodeId)) {
          engine._store.node(id, nodeId);
        }
        resolved = TavernVariableTarget(scope: target.scope, chatId: id, messageRef: ref);
    }
    return _ResolvedScriptVariable(
      context,
      resolved,
      capture: capture,
      requireSamePath:
          target.scope == TavernVariableScope.message && (target.messageRef == null || target.messageId != null),
    );
  }

  Future<TavernVariableSnapshot> _getVariables(String contextId, TavernVariableTarget target) =>
      _bridgeOperation(() => _readVariable(_resolveTarget(_context(contextId), target)));

  Future<TavernVariableSnapshot> _replaceVariables(
    String contextId,
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) {
    final captured = _captureScriptObject(value);
    return _bridgeOperation(() {
      final resolved = _resolveTarget(_context(contextId), target);
      return _writeVariable(resolved, (_) => captured, expectedVersion: expectedVersion);
    });
  }

  Future<TavernVariableSnapshot> _updateVariablesWith(
    String contextId,
    TavernVariableTarget target,
    FutureOr<TavernJsonObject> Function(TavernJsonObject value) updater,
  ) async {
    late _ResolvedScriptVariable resolved;
    try {
      resolved = _resolveTarget(_context(contextId), target);
    } catch (error, stack) {
      Error.throwWithStackTrace(_scriptFailure(error), stack);
    }
    final before = await _bridgeOperation(() => _readVariable(resolved));
    _context(contextId);
    final token = _ScriptCancellation();
    resolved.context.callbacks.add(token);
    late Map<String, Object?> replacement;
    try {
      // The arbitrary user Future is not an engine storage operation. close()
      // cancels this wait, while separately draining real accepted reads/writes.
      final answer = await Future.any<TavernJsonObject>([
        Future<TavernJsonObject>.sync(() => updater(before.value)),
        token.whenCancelled.then<TavernJsonObject>(
          (_) => throw _scriptError(
            TavernScriptErrorCode.cancelled,
            'updateVariablesWith',
            'The callback context was closed.',
            contextId: contextId,
          ),
        ),
      ]);
      replacement = _captureScriptObject(answer);
    } on TavernScriptException {
      rethrow;
    } catch (error) {
      throw _scriptError(
        TavernScriptErrorCode.hookFailure,
        'updateVariablesWith',
        'The updater failed (${error.runtimeType}).',
        contextId: contextId,
      );
    } finally {
      resolved.context.callbacks.remove(token);
    }
    _context(contextId);
    return _bridgeOperation(() => _writeVariable(resolved, (_) => replacement, expectedVersion: before.version));
  }

  Future<TavernVariableMutation> _mutateVariables(
    String contextId,
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) {
    final captured = List<TavernVariableChange>.of(changes);
    return _bridgeOperation(() async {
      for (final change in captured) {
        if (change.pathTokens.isEmpty ||
            change.pathTokens.any((token) => token is! String && (token is! int || token < 0)) ||
            (change.kind != TavernVariableChangeKind.remove && !change.hasValue) ||
            (change.kind == TavernVariableChangeKind.remove && change.hasValue)) {
          throw _scriptError(
            TavernScriptErrorCode.invalidArgument,
            'mutateVariables',
            'Invalid path tokens or value presence.',
          );
        }
      }
      final resolved = _resolveTarget(_context(contextId), target);
      final results = <TavernVariableChangeResult>[];
      final nativeGlobal = resolved.target.scope == TavernVariableScope.global;
      final snapshot = await _writeVariable(
        resolved,
        (raw) {
          // The global path plan receives a validated runtime projection, which
          // can retain native Infinity even though its public JSON value is null.
          final next = nativeGlobal ? _runtimeCopy(raw.value! as Map<String, Object?>) : _variableObject(raw);
          for (final change in captured) {
            results.add(_applyVariableChange(next, change, jsonComparison: nativeGlobal));
          }
          return next;
        },
        expectedVersion: expectedVersion,
        mergeNativeGlobals: nativeGlobal,
      );
      return TavernVariableMutation(snapshot: snapshot, results: results);
    });
  }

  Future<TavernVariableSnapshot> _readVariable(
    _ResolvedScriptVariable resolved, {
    void Function(String version)? onReadVersion,
  }) async {
    final target = resolved.target;
    _context(resolved.context.value.id);
    final snapshot = await _readStoredVariable(
      target,
      (raw) {
        final version = _variableVersion(target, raw);
        onReadVersion?.call(version);
        return TavernVariableSnapshot(resolvedTarget: target, version: version, value: _variableObject(raw));
      },
      onUnavailable: (error) {
        onReadVersion?.call(_variableVersionForFingerprint(target, _unavailableVariableFingerprint(error)));
      },
    );
    _context(resolved.context.value.id);
    return snapshot;
  }

  _ScriptRawVariable _readMessageVariable(TavernScriptMessageRef ref) {
    // Only this raw carrier is observed. Physical state and complete portable
    // overrides have the same priority as _stateAt, without reading inspection
    // or adding the unrelated chat hash used by native runtime state.
    return _fieldVariable(engine._store.scriptNodeState(ref.chatId, ref.nodeId), 'messageVariables');
  }

  Future<T> _readStoredVariable<T>(
    TavernVariableTarget target,
    T Function(_ScriptRawVariable raw) read, {
    void Function(TavernScriptException error)? onUnavailable,
  }) async {
    T inspect(_ScriptRawVariable Function() load) {
      late final _ScriptRawVariable raw;
      try {
        raw = load();
      } on TavernScriptException catch (error) {
        // A malformed outer carrier also has a commit-observed token. Record
        // it inside the same resource queue, before another writer can run.
        onUnavailable?.call(error);
        rethrow;
      }
      return read(raw);
    }

    switch (target.scope) {
      case TavernVariableScope.global:
        return engine._settingsDocument((document) async => inspect(() => _fieldVariable(document, 'globalVariables')));
      case TavernVariableScope.chat:
        return inspect(() => _ScriptRawVariable(true, engine._store.chatVariables(target.chatId!)));
      case TavernVariableScope.message:
        final ref = target.messageRef!;
        return inspect(() => _readMessageVariable(ref));
      case TavernVariableScope.character:
        return engine._libraryOperation(() async {
          late T result;
          final present = await engine._library.readRuntimeAuthority(target.characterId!, (data) {
            result = inspect(() {
              final extensions = _readOptionalObject(data, 'extensions');
              final helper = _readOptionalObject(extensions, 'tavern_helper');
              return _fieldVariable(helper, 'variables');
            });
            return true;
          });
          if (present != true) {
            throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Character not found.');
          }
          return result;
        });
      case TavernVariableScope.script:
        final owner = target.scriptOwner!;
        if (owner.kind == TavernScriptOwnerKind.global) {
          return engine._settingsDocument(
            (document) async =>
                inspect(() => _fieldVariable(_readOptionalObject(document, 'scriptData'), owner.scriptId)),
          );
        }
        if (owner.kind == TavernScriptOwnerKind.character) {
          return engine._libraryOperation(() async {
            late T result;
            final present = await engine._library.readRuntimeAuthority(owner.assetId!, (data) {
              result = inspect(() => _scriptData(_readOptionalObject(data, 'extensions'), owner.scriptId));
              return true;
            });
            if (present != true) {
              throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Script character not found.');
            }
            return result;
          });
        }
        return engine._presetOperation(
          () => inspect(
            () => _scriptData(_readOptionalObject(engine._presetScriptOwnerRaw(owner), 'extensions'), owner.scriptId),
          ),
        );
    }
  }

  Future<TavernVariableSnapshot> _writeVariable(
    _ResolvedScriptVariable resolved,
    Map<String, Object?> Function(_ScriptRawVariable raw) transform, {
    String? expectedVersion,
    bool mergeNativeGlobals = false,
  }) async {
    final target = resolved.target;
    _context(resolved.context.value.id);
    final globalThrough = engine._globalVariables.revision;
    TavernVariableSnapshot result(
      Map<String, Object?> actual, {
      TavernStateEditResult? stateEdit,
      bool beforeCommit = false,
    }) => TavernVariableSnapshot(
      resolvedTarget: target,
      version: beforeCommit
          ? _anticipatedVariableVersion(target, _ScriptRawVariable(true, actual))
          : _variableVersion(target, _ScriptRawVariable(true, actual)),
      value: actual,
      stateEdit: stateEdit,
    );
    void checkVersion(_ScriptRawVariable current) {
      _context(resolved.context.value.id);
      final currentVersion = _variableVersion(target, current);
      if (expectedVersion != null && expectedVersion != currentVersion) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'variables',
          'The target value changed before commit.',
          contextId: resolved.context.value.id,
        );
      }
    }

    Map<String, Object?> prepare(_ScriptRawVariable current) {
      checkVersion(current);
      return _captureScriptObject(transform(current));
    }

    late TavernVariableSnapshot saved;
    var committed = false;
    try {
      switch (target.scope) {
        case TavernVariableScope.global:
          saved = await engine._settingsDocument((document) async {
            final current = _fieldVariable(document, 'globalVariables');
            late Map<String, Object?> runtime;
            late Map<String, Object?> value;
            if (mergeNativeGlobals) {
              // CAS belongs to the actual committed carrier. Only after that
              // check may a path mutation include pre-call native intent.
              checkVersion(current);
              _variableObject(current);
              runtime = _runtimeCopy(
                transform(_ScriptRawVariable(true, engine._globalVariables.project(globalThrough))),
              );
              value = _copy(runtime);
            } else {
              value = prepare(current);
              runtime = value;
            }
            final next = _copy(document)..['globalVariables'] = value;
            await engine._commitSettingsDocument(next, globals: (runtime: runtime, through: globalThrough));
            committed = true;
            return result(value);
          });
        case TavernVariableScope.chat:
          saved = await _dataWrite(resolved.capture!, (permit) {
            late ({String? leaf, Map<String, Object?> values}) adopted;
            return _toolPreparationSql(
              engine,
              permit,
              () {
                final chat = engine._store.chat(target.chatId!);
                final value = prepare(_ScriptRawVariable(true, chat.variables));
                final leaf = chat.currentLeafId;
                if (leaf != null) {
                  final state = engine._stateAt(chat.id, leaf)..['variables'] = value;
                  engine._store.writeNodeState(chat.id, leaf, state);
                  engine._writeNodeState(chat.id, leaf, state);
                } else if (engine._store.groupChat(chat.id) != null) {
                  final state = engine._store.groupInitialState(chat.id)..['variables'] = value;
                  engine._store.setGroupInitialState(chat.id, state);
                }
                engine._store.updateChat(chat.id, variables: value);
                adopted = (leaf: leaf, values: _copy(value));
                return result(value, beforeCommit: true);
              },
              onCommitted: () {
                committed = true;
                engine._liveVariables[target.chatId!] = adopted;
              },
            );
          });
        case TavernVariableScope.message:
          final ref = target.messageRef!;
          final dataContext = await _prepareDataContext(
            ref.chatId,
            forceGameplay: engine._stateAt(ref.chatId, ref.nodeId).containsKey('dshgoPackDefinitionConfigId'),
          );
          saved = await _dataWrite(
            resolved.capture!,
            (permit) => _toolPreparationSql(
              engine,
              permit,
              () {
                _checkChatCapture(resolved.capture!, requireSamePath: resolved.requireSamePath);
                final baseline = engine._stateAt(ref.chatId, ref.nodeId);
                final value = prepare(_fieldVariable(baseline, 'messageVariables'));
                final prepared = _prepareMessageData(
                  dataContext,
                  nodeId: ref.nodeId,
                  baseline: baseline,
                  data: value,
                  extra: engine._store.rawNodeExtra(ref.chatId, ref.nodeId),
                );
                _commitMessageData(ref.chatId, ref.nodeId, prepared);
                engine._restoreVariables(ref.chatId);
                return result(
                  _captureScriptObject(prepared.state['messageVariables']),
                  stateEdit: prepared.stateEdit,
                  beforeCommit: true,
                );
              },
              onCommitted: () {
                committed = true;
                engine._liveVariables.remove(ref.chatId);
              },
            ),
          );
        case TavernVariableScope.character:
          saved = await engine._libraryOperation(() async {
            final id = target.characterId!;
            engine._authoringAuthority.checkWritable('character:$id');
            final record = await engine._library.read(id);
            if (record == null) {
              throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Character not found.');
            }
            final extensions = _optionalObject(record.card.data, 'extensions');
            final helper = _optionalObject(extensions, 'tavern_helper');
            final value = prepare(_fieldVariable(helper, 'variables'));
            helper['variables'] = value;
            extensions['tavern_helper'] = helper;
            await _saveScriptCharacter(id, extensions);
            committed = true;
            return result(value);
          });
        case TavernVariableScope.script:
          final owner = target.scriptOwner!;
          if (owner.kind == TavernScriptOwnerKind.global) {
            saved = await engine._settingsDocument((document) async {
              final container = _optionalObject(document, 'scriptData');
              final value = prepare(_fieldVariable(container, owner.scriptId));
              container[owner.scriptId] = value;
              final next = _copy(document)..['scriptData'] = container;
              await engine._commitSettingsDocument(next);
              committed = true;
              engine._document['scriptData'] = _copy(container);
              engine._globalScriptsChanged.add(null);
              return result(value);
            });
          } else if (owner.kind == TavernScriptOwnerKind.character) {
            saved = await engine._libraryOperation(() async {
              final id = owner.assetId!;
              engine._authoringAuthority.checkWritable('character:$id');
              final record = await engine._library.read(id);
              if (record == null) {
                throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Script character not found.');
              }
              final extensions = _optionalObject(record.card.data, 'extensions');
              final entry = _scriptEntry(extensions, owner.scriptId);
              final value = prepare(_fieldVariable(entry, 'data'));
              entry['data'] = value;
              await _saveScriptCharacter(id, extensions);
              committed = true;
              return result(value);
            });
          } else {
            saved = await engine._presetOperation(() async {
              final value = await engine._editPresetScriptOwner(
                owner,
                (entry) {
                  final value = prepare(_fieldVariable(entry, 'data'));
                  entry['data'] = value;
                  return value;
                },
                check: () {
                  _context(resolved.context.value.id);
                },
                onCommitted: () {
                  committed = true;
                },
              );
              return result(value);
            });
          }
      }
    } on TavernScriptException catch (error) {
      if (error.committed) {
        for (final context in contexts.values.toList()) {
          if (context.closed) {
            continue;
          }
          try {
            await _refreshContext(context);
          } catch (_) {
            /* Preserve the committed storage failure. */
          }
        }
      }
      rethrow;
    } on StateError {
      throw _scriptError(
        committed ? TavernScriptErrorCode.storage : TavernScriptErrorCode.notFound,
        'variables',
        committed ? 'Storage reported a failure after commit.' : 'The captured target no longer exists.',
        contextId: resolved.context.value.id,
        nodeId: target.messageRef?.nodeId,
        committed: committed,
      );
    } catch (error, stack) {
      final reported = _scriptReportedFailure(error);
      if (reported != null) Error.throwWithStackTrace(reported, stack);
      throw _scriptError(
        TavernScriptErrorCode.storage,
        'variables',
        'Variable storage failed (${error.runtimeType}).',
        contextId: resolved.context.value.id,
        nodeId: target.messageRef?.nodeId,
        committed: committed,
      );
    }
    TavernScriptException? cacheFailure;
    for (final context in contexts.values.toList()) {
      if (!context.closed) {
        try {
          await _refreshContext(context);
        } on TavernScriptException catch (error) {
          cacheFailure ??= error;
        }
      }
    }
    if (cacheFailure != null) {
      throw cacheFailure;
    }
    return saved;
  }

  Future<void> _saveScriptCharacter(String id, Map<String, Object?> extensions) async {
    if (engine._deletingCharacters.contains(id)) {
      throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Character deletion is running.');
    }
    var committed = false;
    try {
      final record = await engine._library.updateScriptStorage(
        id,
        extensions,
        onCommitted: () {
          committed = true;
        },
      );
      engine._characterCache = null;
      engine._cacheCharacterDetail(id, Future.value(record));
      engine._notifyLists();
    } catch (error, stack) {
      // card.json can commit before its derived summary fails. Evict and read
      // the authoritative file; never publish the older cached character.
      engine._characterCache = null;
      unawaited(engine._characterDetails.remove(id));
      StoredCharacter? actual;
      try {
        actual = await engine._library.read(id);
      } catch (_) {
        /* Preserve the original storage issue. */
      }
      if (actual != null) {
        engine._cacheCharacterDetail(id, Future.value(actual));
      }
      final reported = _scriptReportedFailure(error);
      if (reported != null) Error.throwWithStackTrace(reported, stack);
      throw _scriptError(
        TavernScriptErrorCode.storage,
        'variables',
        'Character storage failed (${error.runtimeType}).',
        committed: committed,
      );
    }
  }

  Future<void> _validateScriptOwner(TavernScriptOwner owner) async {
    _checkOwnerIdentity(owner);
    if (owner.kind == TavernScriptOwnerKind.global) {
      return;
    }
    await _readStoredVariable(TavernVariableTarget(scope: TavernVariableScope.script, scriptOwner: owner), (_) {});
  }

  Future<_ScriptDataContext> _prepareDataContext(String chatId, {bool forceGameplay = false}) async {
    final admittedChat = engine._store.chat(chatId);
    final admission = _captureGameplayAdmission(
      engine,
      characterId: admittedChat.characterId,
      chatId: chatId,
      settings: const {},
    );
    final useGameplay = admission.hasActivePacks || forceGameplay;
    final settings = useGameplay
        ? engine._effectiveReadSettings(admittedChat, engine._chatCodec.metadataForNode(engine._store, chatId))
        : null;
    while (true) {
      final chat = engine._store.chat(chatId);
      final revision = engine._directors._cardRevisions[chat.characterId] ?? 0;
      final record = await engine._record(chat.characterId);
      if (record == null) {
        throw _scriptError(TavernScriptErrorCode.notFound, 'data', 'The host character does not exist.');
      }
      if (chat.characterId != admission.hostCharacterId) {
        throw _scriptError(TavernScriptErrorCode.revisionConflict, 'data', 'The captured host identity changed.');
      }
      if (revision != (engine._directors._cardRevisions[chat.characterId] ?? 0)) {
        continue;
      }
      final _GameplayRuntime? gameplay;
      if (useGameplay) {
        try {
          gameplay = await _prepareGameplayRuntime(
            engine,
            admission,
            hostData: record.card.data,
            force: forceGameplay,
            settings: settings,
          );
        } on TavernGameplayException catch (error, stack) {
          if (error.code != 'capture_conflict') {
            rethrow;
          }
          Error.throwWithStackTrace(
            _scriptError(TavernScriptErrorCode.revisionConflict, 'data', 'The captured gameplay bindings changed.'),
            stack,
          );
        }
      } else {
        gameplay = null;
      }
      if (revision != (engine._directors._cardRevisions[chat.characterId] ?? 0)) {
        continue;
      }
      return _ScriptDataContext(
        chatId,
        chat.characterId,
        revision,
        record.card.data,
        gameplay?.state ?? _stateDefinition(record.card.data),
        settings ?? engine._effectiveReadSettings(chat, engine._chatCodec.metadataForNode(engine._store, chatId)),
        gameplay: gameplay,
        gameplayAdmission: admission,
      );
    }
  }

  _ScriptPreparedData _initialMessageState(_ScriptDataContext dataContext) {
    _checkDataContext(dataContext);
    final chat = engine._store.chat(dataContext.chatId);
    final state = engine._store.groupChat(chat.id) == null
        ? _emptyChatState(engine._chatCodec.metadataForNode(engine._store, chat.id))
        : engine._store.groupInitialState(chat.id);
    state['variables'] = _copy(chat.variables);
    final before = _StateInput(state);
    _initializeDshState(
      dataContext.definition,
      state,
      dataContext.settings['stateEnabled'] != false,
      gameplay: dataContext.gameplay,
    );
    final adopted = !before.valueExists && _StateInput(state).valueExists ? dataContext.gameplay : null;
    return _ScriptPreparedData(
      state,
      null,
      null,
      null,
      adoptedGameplay: adopted,
      gameplayAdmission: adopted == null ? null : dataContext.gameplayAdmission,
    );
  }

  void _checkDataContext(_ScriptDataContext dataContext) {
    if (engine._store.chatCharacterId(dataContext.chatId) != dataContext.hostId ||
        engine._deletingCharacters.contains(dataContext.hostId) ||
        dataContext.hostRevision != (engine._directors._cardRevisions[dataContext.hostId] ?? 0)) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'data', 'The captured host definition changed.');
    }
    final admission = dataContext.gameplayAdmission;
    if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'data', 'The captured gameplay bindings changed.');
    }
  }

  _ScriptPreparedData _prepareMessageData(
    _ScriptDataContext context, {
    required String? nodeId,
    required Map<String, Object?> baseline,
    required Map<String, Object?> data,
    Map<String, Object?> extra = const {},
  }) {
    _checkDataContext(context);
    return _prepareScriptMessageData(
      context,
      nodeId: nodeId,
      baseline: baseline,
      data: data,
      extra: extra,
      createInvocation: _newStateId,
    );
  }

  void _ensurePreparedGameplay(_ScriptPreparedData prepared) {
    if (prepared.adoptedGameplay == null) {
      return;
    }
    final admission = prepared.gameplayAdmission;
    if (admission != null && !_gameplayAdmissionCurrent(engine, admission)) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'data', 'The captured gameplay bindings changed.');
    }
    _ensureGameplayConfig(engine, prepared.adoptedGameplay);
  }

  void _commitMessageData(String chatId, String nodeId, _ScriptPreparedData prepared) {
    _ensurePreparedGameplay(prepared);
    engine._store.writeNodeState(chatId, nodeId, prepared.state);
    final extra = engine._store.rawNodeExtra(chatId, nodeId);
    engine._store.updateMessage(
      chatId,
      nodeId,
      extra: {
        ...extra,
        'dshgo': {..._map(extra['dshgo']), ...?prepared.audit, 'tavernState': _copy(prepared.state)},
      },
    );
    if (prepared.run case final run?) {
      engine._store.writeAgentRun(
        StoredAgentRun(
          id: '${run['invocationId']}:script',
          chatId: chatId,
          nodeId: nodeId,
          kind: 'state.script',
          at: engine._clock(),
          result: run,
        ),
      );
    }
  }
}

/// Shared calculation only. The native wrapper still checks its live context
/// and commits at its original boundary; an authoring caller adopts locally.
_ScriptPreparedData _prepareScriptMessageData(
  _ScriptDataContext context, {
  required String? nodeId,
  required Map<String, Object?> baseline,
  required Map<String, Object?> data,
  required Map<String, Object?> extra,
  required String Function() createInvocation,
}) {
  final requested = _captureScriptObject(data);
  final old = baseline['messageVariables'];
  final oldObject = old is Map<String, Object?> ? old : null;
  final sameDshgo =
      oldObject != null &&
      oldObject.containsKey('dshgo') == requested.containsKey('dshgo') &&
      _stateJsonEqual(oldObject['dshgo'], requested['dshgo']);
  final next = _copy(baseline)..['messageVariables'] = requested;
  if (sameDshgo ||
      (oldObject == null && !baseline.containsKey('messageVariables') && !requested.containsKey('dshgo'))) {
    return _ScriptPreparedData(next, null, null, null);
  }
  final referenced = baseline.containsKey('dshgoPackDefinitionConfigId');
  if (context.gameplay == null && referenced) {
    throw _scriptError(
      TavernScriptErrorCode.revisionConflict,
      'messageData',
      'The target acquired a gameplay interpretation after preparation.',
      nodeId: nodeId,
    );
  }
  if (!context.definition.hasSchema && context.gameplay == null) {
    return _ScriptPreparedData(next, null, null, null);
  }
  final input = _StateInput(baseline);
  final invocation = createInvocation();
  final issues = [...input.issues];
  var receipts = <Map<String, Object?>>[];
  var changes = <Map<String, Object?>>[];
  var effects = <Map<String, Object?>>[];
  var applied = false;
  var changed = false;
  Map<String, Object?> candidate = next;
  if (input.writable) {
    final session = context.definition.startSession(
      valueExists: input.valueExists,
      value: input.value,
      runtimeExists: input.runtimeExists,
      runtime: input.runtime,
      packRuntimeExists: input.packRuntimeExists,
      packRuntime: input.packRuntime,
    );
    final remove = !requested.containsKey('dshgo');
    final operation = session.apply(
      [
        {'op': remove ? 'remove' : 'set', 'path': '', 'why': 'script', if (!remove) 'value': requested['dshgo']},
      ],
      actor: state_core.StateActor.user,
      source: 'script',
    );
    final result = session.finish(runRules: operation.acceptedCount > 0);
    receipts = result.receipts;
    issues.addAll(result.issues);
    applied = operation.acceptedCount == 1 && operation.rejectedCount == 0 && result.valid;
    if (applied) {
      changed = result.changed;
      changes = result.changes;
      effects = _identifiedEffects(result.effects, invocation);
      candidate = _stateResultSnapshot(next, result, effects, const {});
      _stampGameplayConfig(context.gameplay, candidate);
    }
  }
  final audit = _stateOwnAudit(invocation, changes, effects, issues);
  final panel = _statePanel(
    context.chatId,
    nodeId,
    applied ? candidate : baseline,
    applied ? _stateNodeExtra(extra, candidate, audit) : extra,
    context.definition,
    context.settings,
    dshgoOnly: context.gameplay != null || referenced,
    allowInitialPreview: context.gameplay == null && !referenced,
    protection: _SecretProtection(context.hostData, applied ? candidate : baseline, gameplay: context.gameplay),
  );
  final stateEdit = TavernStateEditResult(
    applied: applied,
    changed: changed,
    snapshot: panel,
    receipts: receipts,
    issues: issues,
  );
  if (!applied) {
    throw _scriptError(
      TavernScriptErrorCode.stateValidation,
      'messageData',
      'The complete message-variable replacement was rejected.',
      nodeId: nodeId,
      stateEdit: stateEdit,
    );
  }
  return _ScriptPreparedData(
    candidate,
    stateEdit,
    audit,
    {
      'version': 1,
      'invocationId': invocation,
      'source': 'script',
      'definitionFingerprint': context.definition.fingerprint,
      'committed': true,
      'changed': changed,
      'receipts': receipts,
      'changes': changes,
      'effects': effects,
      'issues': issues,
    },
    adoptedGameplay: context.gameplay,
    gameplayAdmission: context.gameplayAdmission,
  );
}

void _checkOwnerIdentity(TavernScriptOwner owner) {
  final carrier = owner.presetCarrier;
  final invalid = switch (owner.kind) {
    TavernScriptOwnerKind.global => owner.assetId != null || carrier != null,
    TavernScriptOwnerKind.character => owner.assetId == null || carrier != null,
    TavernScriptOwnerKind.preset =>
      carrier == null
          ? owner.assetId == null
          : carrier.chatId == '' ||
                (carrier.kind == TavernScriptPresetCarrierKind.inline
                    ? owner.assetId != null
                    : carrier.workingId == ''),
  };
  if (owner.scriptId.isEmpty || owner.assetId == '' || invalid) {
    throw _scriptError(TavernScriptErrorCode.invalidArgument, 'scriptOwner', 'Invalid persistent script identity.');
  }
}

Map<String, Object?> _optionalObject(Map<String, Object?> parent, String key) =>
    _copy(_readOptionalObject(parent, key));

Map<String, Object?> _scriptMapView(Object? value) => value is Map<String, Object?> ? value : <String, Object?>{};

Map<String, Object?> _readOptionalObject(Map<String, Object?> parent, String key) {
  if (!parent.containsKey(key)) {
    return <String, Object?>{};
  }
  final value = parent[key];
  if (value is! Map<String, Object?>) {
    throw _scriptError(
      TavernScriptErrorCode.shapeMismatch,
      'variables',
      'The $key carrier is not an object.',
      fieldPath: key,
    );
  }
  return value;
}

_ScriptRawVariable _fieldVariable(Map<String, Object?> object, String key) =>
    _ScriptRawVariable(object.containsKey(key), object[key]);

Map<String, Object?> _variableObject(_ScriptRawVariable raw) {
  if (!raw.present) {
    return <String, Object?>{};
  }
  if (raw.value is! Map<String, Object?>) {
    throw _scriptError(
      TavernScriptErrorCode.shapeMismatch,
      'variables',
      'The stored variable target is not an object.',
    );
  }
  return _captureScriptObject(raw.value);
}

String _targetKey(TavernVariableTarget target) => jsonEncode([
  target.scope.name,
  target.characterId,
  target.chatId ?? target.messageRef?.chatId,
  target.messageRef?.nodeId,
  target.scriptOwner?.kind.name,
  target.scriptOwner?.assetId,
  target.scriptOwner?.scriptId,
  target.scriptOwner?.presetCarrier?.toJson(),
]);

Object? _canonicalScriptValue(Object? value) {
  if (value is Map<String, Object?>) {
    return <String, Object?>{for (final key in value.keys.toList()..sort()) key: _canonicalScriptValue(value[key])};
  }
  if (value is List<Object?>) {
    return [for (final item in value) _canonicalScriptValue(item)];
  }
  return value;
}

extension _ScriptVariableVersions on _ScriptCoordinator {
  String _anticipatedVariableVersion(TavernVariableTarget target, _ScriptRawVariable raw) {
    final entry = _variableVersions[_targetKey(target)]!;
    final revision = entry.revision + (entry.fingerprint == _variableFingerprint(raw) ? 0 : 1);
    // SQL can prepare its detached result before COMMIT without adopting a
    // revision early. The synchronous commit observer adopts exactly this
    // change; a rollback leaves the real counter untouched.
    return '$epoch:variable:${entry.identity}:$revision';
  }

  String _variableVersion(TavernVariableTarget target, _ScriptRawVariable raw) {
    return _variableVersionForFingerprint(target, _variableFingerprint(raw));
  }

  String _variableVersionForFingerprint(TavernVariableTarget target, String fingerprint) {
    final key = _targetKey(target);
    final entry = _variableVersions.putIfAbsent(
      key,
      () => _ScriptVariableVersion(target, ++_nextVariableIdentity, fingerprint),
    );
    if (entry.fingerprint != fingerprint) {
      entry.fingerprint = fingerprint;
      entry.revision++;
    }
    if (target.scope == TavernVariableScope.message) {
      entry.messageTreeRevision = engine._store.treeRevision(target.messageRef!.chatId);
    }
    return '$epoch:variable:${entry.identity}:${entry.revision}';
  }

  String? _currentVariableVersion(String key) {
    final entry = _variableVersions[key];
    return entry == null ? null : '$epoch:variable:${entry.identity}:${entry.revision}';
  }

  void _observeVariable(_ScriptVariableVersion entry, _ScriptRawVariable Function() read) {
    // These observers run after a real commit. A deleted/malformed target
    // invalidates its old token, but no read/shape error can turn COMMIT into
    // an apparent rollback or prevent notification of other targets.
    final chatId = entry.target.chatId ?? entry.target.messageRef?.chatId;
    final profile = chatId == null ? null : engine._turns[chatId]?.profile;
    final started = profile?.now;
    try {
      String fingerprint;
      try {
        fingerprint = _variableFingerprint(read());
      } catch (error) {
        fingerprint = _unavailableVariableFingerprint(error);
      }
      if (entry.fingerprint != fingerprint) {
        entry.fingerprint = fingerprint;
        entry.revision++;
      }
    } finally {
      if (started != null) {
        profile?.record('script_store_observe', started);
      }
    }
  }

  void documentCommitted(Map<String, Object?> document) {
    if (_closed) {
      return;
    }
    scriptHelperDocumentCommitted(document);
    resourcesChanged();
    for (final entry in _variableVersions.values) {
      final target = entry.target;
      if (target.scope == TavernVariableScope.global) {
        _observeVariable(entry, () => _fieldVariable(document, 'globalVariables'));
      } else if (target.scope == TavernVariableScope.script &&
          target.scriptOwner!.kind == TavernScriptOwnerKind.global) {
        _observeVariable(
          entry,
          () => _fieldVariable(_optionalObject(document, 'scriptData'), target.scriptOwner!.scriptId),
        );
      } else if (target.scope == TavernVariableScope.script &&
          target.scriptOwner!.presetCarrier?.kind == TavernScriptPresetCarrierKind.inline &&
          target.scriptOwner!.presetCarrier!.chatId == null) {
        final owner = target.scriptOwner!;
        _observeVariable(
          entry,
          () => _scriptData(
            _readOptionalObject(engine._presetScriptOwnerRaw(owner, document: document), 'extensions'),
            owner.scriptId,
          ),
        );
      }
    }
  }

  void cardCommitted(String id, Map<String, Object?> data) {
    if (_closed) {
      return;
    }
    scriptResourceCardCommitted(id, data);
    scriptHelperCardCommitted(id, data);
    for (final entry in _variableVersions.values) {
      final target = entry.target;
      if (target.scope == TavernVariableScope.character && target.characterId == id) {
        _observeVariable(
          entry,
          () => _fieldVariable(_optionalObject(_optionalObject(data, 'extensions'), 'tavern_helper'), 'variables'),
        );
      } else if (target.scope == TavernVariableScope.script &&
          target.scriptOwner!.kind == TavernScriptOwnerKind.character &&
          target.scriptOwner!.assetId == id) {
        _observeVariable(entry, () => _scriptData(_optionalObject(data, 'extensions'), target.scriptOwner!.scriptId));
      }
    }
  }

  void cardRemoved(String id) {
    if (_closed) return;
    scriptHelperCardRemoved(id);
    scriptBookDirectoryCardCommitted(id, null);
    _resourceVersion('characterData:$id', null, present: false);
    _resourceVersion('embedded:$id', null, present: false);
    for (final entry in _variableVersions.values) {
      final target = entry.target;
      if (target.scope == TavernVariableScope.character && target.characterId == id) {
        _observeVariable(
          entry,
          () => throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Character not found.'),
        );
      } else if (target.scope == TavernVariableScope.script &&
          target.scriptOwner!.kind == TavernScriptOwnerKind.character &&
          target.scriptOwner!.assetId == id) {
        _observeVariable(
          entry,
          () => throw _scriptError(TavernScriptErrorCode.notFound, 'variables', 'Script character not found.'),
        );
      }
    }
  }

  void storeCommitted(Set<String> chatIds, bool presetsChanged) {
    if (_closed) {
      return;
    }
    engine._presetWorkingStoreCommitted(chatIds, presetsChanged);
    generationStoreCommitted(chatIds);
    if (presetsChanged) {
      engine._scriptCatalogChanged.add(null);
      _scriptPresetLibraryCommitted();
      scriptHelperPresetsCommitted();
      resourcesChanged();
    }
    for (final entry in _variableVersions.values) {
      final target = entry.target;
      if (target.scope == TavernVariableScope.chat && chatIds.contains(target.chatId)) {
        // updateChat(variables) also commits for an empty path and need not
        // advance tree_revision. Always inspect this small chat carrier.
        _observeVariable(entry, () => _ScriptRawVariable(true, engine._store.chatVariables(target.chatId!)));
      } else if (target.scope == TavernVariableScope.message && chatIds.contains(target.messageRef!.chatId)) {
        final ref = target.messageRef!;
        int? revision;
        try {
          revision = engine._store.treeRevision(ref.chatId);
        } catch (_) {
          /* Deleted chat. */
        }
        // Body checkpoints do not touch a saved state/portable override. All
        // state writers and updateMessage(extra) do advance this revision.
        if (revision != null && revision == entry.messageTreeRevision) {
          continue;
        }
        _observeVariable(entry, () => _readMessageVariable(ref));
        entry.messageTreeRevision = revision;
      } else if (target.scope == TavernVariableScope.script &&
          target.scriptOwner!.kind == TavernScriptOwnerKind.preset &&
          (presetsChanged ||
              (target.scriptOwner!.presetCarrier?.kind == TavernScriptPresetCarrierKind.inline &&
                  chatIds.contains(target.scriptOwner!.presetCarrier!.chatId)))) {
        final owner = target.scriptOwner!;
        _observeVariable(
          entry,
          () => _scriptData(_readOptionalObject(engine._presetScriptOwnerRaw(owner), 'extensions'), owner.scriptId),
        );
      }
    }
  }

  void presetScriptCarriersChanged() {
    for (final entry in _variableVersions.values) {
      final owner = entry.target.scriptOwner;
      if (entry.target.scope == TavernVariableScope.script && owner != null && owner.presetCarrier != null) {
        _observeVariable(
          entry,
          () => _scriptData(_readOptionalObject(engine._presetScriptOwnerRaw(owner), 'extensions'), owner.scriptId),
        );
      }
    }
    scriptHelperPresetsCommitted(carriersOnly: true);
  }
}

String _variableFingerprint(_ScriptRawVariable raw) => jsonEncode([raw.present, _canonicalScriptValue(raw.value)]);

String _unavailableVariableFingerprint(Object error) => error is TavernScriptException
    ? jsonEncode(['unavailable', error.code.name, error.message, error.fieldPath])
    : jsonEncode(['unavailable', error.runtimeType.toString()]);

Map<String, Object?> _scriptEntry(Map<String, Object?> extensions, String scriptId) {
  final scripts = scriptTreeFromExtensions(extensions);
  if (scripts == null) {
    throw _scriptError(TavernScriptErrorCode.notFound, 'script', 'The script container has no matching script.');
  }
  if (scripts is! List<Object?>) {
    throw _scriptError(TavernScriptErrorCode.shapeMismatch, 'script', 'Scripts must be an array.');
  }
  final found = [
    for (final leaf in scriptTreeLeaves(scripts))
      if (leaf.raw['id'] == scriptId) leaf.raw,
  ];
  if (found.isEmpty) {
    throw _scriptError(TavernScriptErrorCode.notFound, 'script', 'Script not found in its owner.');
  }
  if (found.length > 1) {
    throw _scriptError(TavernScriptErrorCode.ambiguousName, 'script', 'Script id is repeated in its owner.');
  }
  return found.single;
}

_ScriptRawVariable _scriptData(Map<String, Object?> extensions, String id) =>
    _fieldVariable(_scriptEntry(extensions, id), 'data');

TavernVariableChangeResult _applyVariableChange(
  Map<String, Object?> root,
  TavernVariableChange change, {
  bool jsonComparison = false,
}) {
  Object? parent = root;
  for (final token in change.pathTokens.take(change.pathTokens.length - 1)) {
    if (parent is Map<String, Object?> && token is String && parent.containsKey(token)) {
      parent = parent[token];
    } else if (parent is List<Object?> && token is int && token >= 0 && token < parent.length) {
      parent = parent[token];
    } else {
      if (change.kind == TavernVariableChangeKind.remove) {
        return TavernVariableChangeResult(
          kind: change.kind,
          pathTokens: change.pathTokens,
          existed: false,
          changed: false,
        );
      }
      throw _scriptError(
        TavernScriptErrorCode.range,
        'mutateVariables',
        'A path parent is missing or not a container.',
      );
    }
  }
  final key = change.pathTokens.last;
  late bool existed;
  Object? before;
  if (parent is Map<String, Object?> && key is String) {
    existed = parent.containsKey(key);
    before = parent[key];
    if (change.kind == TavernVariableChangeKind.remove) {
      parent.remove(key);
    } else if (change.kind == TavernVariableChangeKind.set || !existed) {
      parent[key] = change.value;
    }
  } else if (parent is List<Object?> && key is int && key >= 0) {
    existed = key < parent.length;
    before = existed ? parent[key] : null;
    if (change.kind == TavernVariableChangeKind.remove) {
      if (existed) {
        parent.removeAt(key);
      }
    } else if (key > parent.length) {
      throw _scriptError(
        TavernScriptErrorCode.range,
        'mutateVariables',
        'Sparse array writes are not native JSON operations.',
      );
    } else if (!existed) {
      parent.add(change.value);
    } else if (change.kind == TavernVariableChangeKind.set) {
      parent[key] = change.value;
    }
  } else {
    throw _scriptError(
      TavernScriptErrorCode.invalidArgument,
      'mutateVariables',
      'Path token does not match its container.',
    );
  }
  final changed = change.kind == TavernVariableChangeKind.remove
      ? existed
      : change.kind == TavernVariableChangeKind.insertIfAbsent && existed
      ? false
      : !existed || !_stateJsonEqual(jsonComparison ? _jsonCompatible(before) : before, change.value);
  return TavernVariableChangeResult(
    kind: change.kind,
    pathTokens: change.pathTokens,
    existed: existed,
    changed: changed,
  );
}
