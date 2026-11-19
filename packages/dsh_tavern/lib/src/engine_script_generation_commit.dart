part of 'engine.dart';

extension _ScriptGenerationCommit on _ScriptCoordinator {
  String _generationFieldFingerprint(String chatId, String field) {
    try {
      final chat = engine._store.chat(chatId);
      if (field == 'selection') {
        return _scriptRuntimeFingerprint([
          chat.selectedRootId,
          chat.currentLeafId,
          for (final node in engine._historyTo(chatId, chat.currentLeafId)) node.message.nodeId,
        ]);
      }
      if (field == 'metadataSource') {
        return _scriptRuntimeFingerprint(_slashMetadataSource(chat).source);
      }
      if (field == 'metadata:world_info') {
        final selected = _slashMetadataSource(chat);
        return _scriptRuntimeFingerprint([
          selected.source,
          selected.metadata.containsKey('world_info'),
          selected.metadata['world_info'],
        ]);
      }
      if (field == 'settings:stLorebookIds') {
        return _scriptRuntimeFingerprint([chat.settings.containsKey('stLorebookIds'), chat.settings['stLorebookIds']]);
      }
      if (field == 'settings:lorebooks.chat') {
        final books = chat.settings['lorebooks'];
        return _scriptRuntimeFingerprint(
          books is Map<String, Object?> ? [books.containsKey('chat'), books['chat']] : ['container', books],
        );
      }
      final metadata = engine._chatCodec.metadataForNode(engine._store, chatId);
      final state = chat.currentLeafId == null && engine._store.groupChat(chatId) == null
          ? _emptyChatState(metadata)
          : engine._stateAt(chatId, chat.currentLeafId);
      if (field == 'local') {
        final live = engine._liveVariables[chatId];
        final local = live != null && live.leaf == chat.currentLeafId
            ? live.values
            : state.containsKey('variables')
            ? _map(state['variables'])
            : chat.variables;
        return _scriptRuntimeFingerprint([chat.variables, local]);
      }
      if (field == 'dshgoPackWorldInfo') {
        final projected = _gameplayWorldInfoCarrier(state, includeIdentityOnly: false);
        return _scriptRuntimeFingerprint([projected.exists, projected.raw]);
      }
      return _scriptRuntimeFingerprint([state.containsKey(field), state[field]]);
    } catch (error) {
      return jsonEncode(['unavailable', error.runtimeType.toString()]);
    }
  }

  String _generationFieldVersion(String chatId, String field) =>
      _generationFieldVersionForFingerprint(chatId, field, _generationFieldFingerprint(chatId, field));

  String _generationFieldVersionForFingerprint(String chatId, String field, String fingerprint) {
    final chat = _generationChatObservations.putIfAbsent(
      chatId,
      () => _ScriptChatObservation(++_nextGenerationObservation),
    );
    final value = chat.fields.putIfAbsent(field, () => _ScriptObservedValue(fingerprint));
    value.observe(fingerprint);
    return '$epoch:preparation:${chat.identity}:$field:${value.revision}';
  }

  void generationStoreCommitted(Set<String> chatIds) {
    // Run at actual outer COMMIT, even when nobody next asks for a snapshot.
    // Only observed targets are read: unrelated scopes cannot invalidate them.
    for (final chatId in chatIds) {
      final observation = _generationChatObservations[chatId];
      if (observation == null) continue;
      for (final entry in observation.fields.entries) {
        entry.value.observe(_generationFieldFingerprint(chatId, entry.key));
      }
      for (final entry in observation.persistent.values) {
        entry.value.observe(_persistentInjectionFingerprint(chatId, entry.source, entry.rawId));
      }
    }
  }

  String _persistentInjectionKey(ChatJsonlMetadataSource source, String rawId) => jsonEncode([source.identity, rawId]);

  String _persistentInjectionFingerprint(String chatId, ChatJsonlMetadataSource source, String rawId) {
    try {
      final chat = engine._store.chat(chatId);
      final metadata = engine._chatCodec.readMetadataSource(chat.metadata, source);
      if (metadata == null) return _scriptRuntimeFingerprint(['missingSource']);
      final raw = metadata['script_injects'];
      return _scriptRuntimeFingerprint(
        raw is Map<String, Object?>
            ? [raw.containsKey(rawId), raw[rawId]]
            : ['container', metadata.containsKey('script_injects'), raw],
      );
    } catch (error) {
      return jsonEncode(['unavailable', error.runtimeType.toString()]);
    }
  }

  String _persistentInjectionToken(_ScriptChatObservation chat, _ScriptPersistentObservation entry) =>
      '$epoch:persistent:${chat.identity}:${entry.identity}:${entry.value.revision}';

  String persistentInjectionVersion(String chatId, ChatJsonlMetadataSource source, String rawId, Object? capturedRaw) {
    final chat = _generationChatObservations.putIfAbsent(
      chatId,
      () => _ScriptChatObservation(++_nextGenerationObservation),
    );
    // The raw value and physical source were captured synchronously together.
    // Re-reading the current leaf here would bind a native branch target to a
    // different source before its original SQL selection has taken place.
    final fingerprint = _scriptRuntimeFingerprint([true, capturedRaw]);
    final entry = chat.persistent.putIfAbsent(
      _persistentInjectionKey(source, rawId),
      () => _ScriptPersistentObservation(
        identity: ++chat.nextPersistentIdentity,
        source: source,
        rawId: rawId,
        fingerprint: fingerprint,
      ),
    );
    entry.value.observe(fingerprint);
    return _persistentInjectionToken(chat, entry);
  }

  String? currentPersistentInjectionVersion(String chatId, ChatJsonlMetadataSource source, String rawId) {
    final chat = _generationChatObservations[chatId];
    final entry = chat?.persistent[_persistentInjectionKey(source, rawId)];
    if (chat == null || entry == null) return null;
    entry.value.observe(_persistentInjectionFingerprint(chatId, entry.source, entry.rawId));
    return _persistentInjectionToken(chat, entry);
  }

  Future<_ScriptGenerationCapture> _captureGeneration(
    _ScriptGenerationRecord record, {
    bool includeInjections = true,
    _ScriptGenerationNeeds? needsOverride,
  }) async {
    final context = _context(record.context.value.id);
    final request = record.request;
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    if (request is! TavernScriptRawRequest && chat == null && record.slashSpec?.raw != true) {
      throw _scriptError(TavernScriptErrorCode.noContext, 'generate', 'Normal generation requires a chat.');
    }
    final capturedMetadata = chat == null ? null : _captureScriptMetadata(chat);
    final metadata = capturedMetadata?.metadata ?? <String, Object?>{};
    final persistentSource = capturedMetadata?.source;
    final candidates = includeInjections
        ? injectionRegistry.capture(
            chatId: chatId,
            metadata: metadata,
            persistentSource: persistentSource,
            request: request.injects,
          )
        : <_ScriptInjectionCandidate>[];
    final needs = needsOverride ?? generationNeeds(request, candidates);
    final stateNeeded = needs.history || needs.worldInfo;
    final anchor = stateNeeded ? chat?.currentLeafId : null;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final state = !stateNeeded || chat == null
        ? <String, Object?>{}
        : anchor == null && group == null
        ? _emptyChatState(metadata)
        : engine._stateAt(chat.id, anchor);
    final history = !stateNeeded || chat == null ? <StoredNode>[] : engine._historyTo(chat.id, anchor);
    final live = chat == null ? null : engine._liveVariables[chat.id];
    final local = !stateNeeded || chat == null
        ? <String, Object?>{}
        : live != null && live.leaf == anchor
        ? _runtimeCopy(live.values)
        : state.containsKey('variables')
        ? _runtimeCopy(_map(state['variables']))
        : _runtimeCopy(chat.variables);
    final global = _ScriptRuntimeIntentMap(_runtimeCopy(engine._globalVariables));
    final observation = _ScriptGenerationObservation(
      globalRuntime: engine._globalVariables.observation,
      globalCommitted: _variableVersion(
        const TavernVariableTarget(scope: TavernVariableScope.global),
        _fieldVariable(engine._document, 'globalVariables'),
      ),
      selection: stateNeeded && chat != null ? _generationFieldVersion(chat.id, 'selection') : null,
      targets: {
        if (stateNeeded && chat != null)
          for (final target in const [
            'local',
            'timedWorldInfo',
            'decoratorState',
            'stChatIdHash',
            'dshgoPackWorldInfo',
          ])
            target: _generationFieldVersion(chat.id, target),
      },
    );
    final resourcesNeeded = needs.history || needs.card || needs.worldInfo || request is! TavernScriptRawRequest;
    final persona = resourcesNeeded ? engine._personas.resolve(personaId: chat?.personaId) : null;
    final settings = resourcesNeeded
        ? _runtimeCopy(_personaSettings(engine._effectiveSettings(chat, metadata), persona!))
        : <String, Object?>{};
    final contextPresetRaw = _map(settings['preset']);
    final contextRegexPreset = resourcesNeeded
        ? (contextPresetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(contextPresetRaw)).settings
        : <String, Object?>{};
    ChatPreset? promptPreset;
    if (request.presetId != null) {
      promptPreset = ChatPreset(engine._requirePreset(request.presetId!).raw);
    } else if (request is! TavernScriptRawRequest) {
      promptPreset = contextPresetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(contextPresetRaw);
    }
    final actorId =
        request.speakerCharacterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    // D-B3-QUIET-ACTOR-02: only a real private quiet strategy may select a
    // uniquely resolved actor outside this group; public B2 keeps its guard.
    if (group != null &&
        request.speakerCharacterId != null &&
        record.slashSpec?.raw != false &&
        !group.members.any((member) => member.characterId == request.speakerCharacterId)) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'generate',
        'The requested actor is not a member of this group.',
      );
    }
    final gameplayCapture = resourcesNeeded
        ? _captureGameplayResources(
            engine,
            characterId: actorId,
            chatId: chatId,
            kinds: const {'regex', 'lorebook'},
            deferResourceErrors: true,
          )
        : null;
    StoredCharacter? actor;
    if ((needs.card || request.speakerCharacterId != null || request is! TavernScriptRawRequest) && actorId != null) {
      actor = await record.cancellation.wait(engine._trackOperation(engine._record(actorId)));
      if (actor == null) {
        throw _scriptError(TavernScriptErrorCode.notFound, 'generate', 'The requested character is missing.');
      }
    }
    _GroupView? groupView;
    if (group != null && (needs.card || needs.worldInfo)) {
      groupView = await record.cancellation.wait(
        engine._trackOperation(engine._groups.capture(group, checkCancelled: record.cancellation.check)),
      );
    }
    record.cancellation.check();
    _context(context.value.id);
    _checkScriptGameplayResources(engine, gameplayCapture, 'generate');
    return _ScriptGenerationCapture(
      generationId: record.id,
      context: context,
      request: request,
      config: record.config,
      at: record.at,
      settings: settings,
      card: actor == null ? {} : _effectiveCard(actor.card.data, settings),
      metadata: _runtimeCopy(metadata),
      state: _runtimeCopy(state),
      local: _ScriptRuntimeIntentMap(local),
      global: global,
      observation: observation,
      injectionCandidates: candidates,
      history: history,
      contextRegexPresetSettings: _runtimeCopy(contextRegexPreset),
      chat: chat,
      anchor: anchor,
      actorId: actorId,
      personaId: persona?.persona?.id,
      groupView: groupView,
      promptPreset: promptPreset,
      capturedChatState: stateNeeded && chat != null,
      gameplayCapture: gameplayCapture,
    );
  }

  _ScriptEffectPlan _generationEffectPlan(_ScriptPreparedGeneration prepared) {
    final capture = prepared.capture;
    return _ScriptEffectPlan(
      context: capture.context,
      operation: 'generate',
      global: capture.global,
      local: capture.local,
      observation: capture.observation,
      chatId: capture.chat?.id,
      anchor: capture.anchor,
      capturedChatState: capture.capturedChatState,
      stateUpdates: prepared.stateUpdates,
      stChatIdHash: prepared.stChatIdHash,
      hasHashUpdate: prepared.hasHashUpdate,
      gameplayCapture: capture.gameplayCapture,
      packWorldInfo: prepared.packWorldInfo,
    );
  }

  Future<void> _commitGeneration(_ScriptGenerationRecord record, _ScriptPreparedGeneration prepared) async {
    final plan = _generationEffectPlan(prepared);
    final receipt = record.receipt;
    receipt.requiredTargets.addAll(plan.carriers);
    record.cancellation.check();
    receipt.phase = 'accept';
    _checkScriptEffectTargets(plan);
    receipt.claimedInjectionVersions.addAll(injectionRegistry.claim(prepared.injectionUses, generationId: record.id));
    receipt.accepted = true;
    record.status = TavernScriptGenerationStatus.accepted;
    record.slashSpec?.onPreparationAccepted(record, prepared);
    await _commitScriptEffectPlan(
      plan,
      checkAlive: record.cancellation.check,
      signals: _ScriptCarrierSignals(
        onEntering: (kind) {
          receipt.phase = kind;
        },
        onStarted: (kind) {
          receipt.startedTargets.add(kind);
          receipt.failedTarget = kind;
          record.slashSpec?.onCarrierStarted(record, kind);
        },
        onCommitted: (kind, status) {
          receipt.persistedTargets.add({
            'targetKind': kind,
            if (kind == 'chat') 'chatId': plan.chatId!,
            if (kind == 'chat' && plan.anchor != null) 'nodeId': plan.anchor,
            'status': status,
          });
          receipt.failedTarget = null;
        },
        onAdopted: (adoption) {
          record.slashSpec?.onCarrierAdopted(record, adoption);
        },
        onFinished: (_) {
          receipt.failedTarget = null;
        },
      ),
    );
    if (receipt.persistedTargets.isNotEmpty) resourcesChanged();
  }
}
