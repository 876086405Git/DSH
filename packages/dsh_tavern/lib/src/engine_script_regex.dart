part of 'engine.dart';

extension _ScriptRegexBridge on _ScriptCoordinator {
  Future<List<TavernScriptRegex>> queryTavernRegexes(String contextId, TavernScriptRegexQuery query) async {
    final view = await _captureScriptRegexView(contextId, query: query);
    return view.rules;
  }

  Future<_ScriptRegexView> _captureScriptRegexView(
    String contextId, {
    TavernScriptRegexQuery? query,
    Map<String, Object?>? characterData,
    bool forCache = false,
  }) async {
    final requested = query ?? TavernScriptRegexQuery();
    final context = _context(contextId);
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final metadata = chat == null ? null : engine._chatCodec.metadataForNode(engine._store, chat.id);
    final settings = _runtimeCopy(engine._effectiveSettings(chat, metadata));
    final rootSettings = _map(engine._document['settings']);
    final chatSettings = chat?.settings;
    final settingsVersion = _scriptRegexSettingsVersion(rootSettings, chatSettings, settings);
    final presetRef = requested.presetId == null
        ? const TavernScriptPresetRef.current()
        : TavernScriptPresetRef.stored(requested.presetId!);
    final preset = _scriptPresetViewNow(context, presetRef);
    final presetSettings = (preset.raw.isEmpty ? ChatPreset.stDefault() : ChatPreset(preset.raw)).settings;
    final managed = engine._regexLibrary.scripts;
    final managedVersion = _scriptManagedRegexVersion(managed);
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final actorId = requested.characterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    final actorRevision = actorId == null ? null : engine._directors._cardRevisions[actorId] ?? 0;
    final packBuckets = <String>{
      if (requested.sources.contains(TavernScriptRegexSource.global)) 'global',
      if (requested.sources.contains(TavernScriptRegexSource.character) && actorId != null) 'character',
      if (requested.sources.contains(TavernScriptRegexSource.chat) && chatId != null) 'chat',
    };
    final gameplay = packBuckets.isEmpty
        ? null
        : _captureGameplayResources(
            engine,
            characterId: actorId,
            chatId: chatId,
            kinds: const {'regex'},
            deferResourceErrors: true,
          );
    final rules = <TavernScriptRegex>[];
    final sources = <Map<String, Object?>>[];
    final issues = <Map<String, Object?>>[];
    Map<String, Object?>? actorView;
    final enabledGlobally = settings['regexEnabled'] != false;

    void checkGameplay() {
      if (gameplay != null && !_gameplayResourcesCurrent(engine, gameplay)) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'getTavernRegexes',
          'The captured gameplay regex sources changed.',
          contextId: contextId,
        );
      }
    }

    void addPacks(TavernScriptRegexSource bucket) {
      if (gameplay == null || !packBuckets.contains(bucket.name)) {
        return;
      }
      checkGameplay();
      final source = <String, Object?>{
        'kind': 'pack',
        'bucket': bucket.name,
        'readonly': true,
        'scopes': [
          for (final scope in gameplay.snapshot.scopeSnapshots)
            if (scope.scope.kind.name == bucket.name &&
                (bucket != TavernScriptRegexSource.character || scope.scope.targetId == actorId))
              scope.toJson(),
        ],
      };
      source['version'] = _scriptRegexVersion(source);
      sources.add(source);
      try {
        // The same real loader and bucket gate serve query and ready-cache views.
        final packed = _resolveGameplayResources(
          gameplay,
          settings,
          actorId: actorId,
          kinds: const {'regex'},
          regexBuckets: {bucket.name},
        ).regex;
        for (final rule in packed) {
          if (!requested.effectiveOnly || rule.effective) {
            rules.add(rule);
          }
        }
      } catch (error) {
        if (!forCache || !_scriptRegexResourceDataError(error)) {
          rethrow;
        }
        issues.add(_scriptRegexCacheIssue(error, source));
      }
    }

    void addArray(
      Object? value,
      TavernScriptRegexSource bucket,
      Map<String, Object?> location, {
      required bool sourceEnabled,
      required bool present,
    }) {
      final version = _scriptRegexVersion(value);
      sources.add({
        ...location,
        'bucket': bucket.name,
        'version': version,
        'present': present,
        'isNull': value == null,
      });
      if (value is! List<Object?>) {
        if (forCache && value != null) {
          issues.add({'code': 'shapeMismatch', 'source': location, 'message': 'The regex source is not an array.'});
        }
        return;
      }
      for (final (index, item) in value.indexed) {
        // A query keeps its established non-executable-member projection.
        // read-for-write separately requires the complete physical array.
        if (item is! Map<String, Object?>) {
          if (forCache) {
            issues.add({
              'code': 'shapeMismatch',
              'source': location,
              'index': index,
              'message': 'This regex array member is not an object.',
            });
          }
          continue;
        }
        final raw = _captureScriptObject(item);
        final execution = RegexScript.fromJson(raw);
        final effective = enabledGlobally && sourceEnabled && !execution.disabled;
        if (requested.effectiveOnly && !effective) {
          continue;
        }
        rules.add(
          TavernScriptRegex(
            source: bucket,
            sourceRef: {...location, 'index': index, 'version': version},
            raw: raw,
            stId: execution.id,
            execution: execution,
            enabled: !execution.disabled,
            effective: effective,
            diagnostics: _scriptRegexShapeDiagnostics(raw, index),
          ),
        );
      }
    }

    if (requested.sources.contains(TavernScriptRegexSource.global)) {
      final inline = _scriptInlineRegexLocation(rootSettings, chatSettings, settings, chatId);
      final field = inline['field']! as String;
      addArray(
        settings[field],
        TavernScriptRegexSource.global,
        inline,
        sourceEnabled: true,
        present: inline['scope'] == 'chat' ? chatSettings!.containsKey(field) : rootSettings.containsKey(field),
      );
      sources.add({
        'kind': 'managedGlobal',
        'bucket': 'global',
        'version': managedVersion,
        'writeTarget': const TavernScriptRegexWriteTarget.globalLibrary().toJson(),
      });
      for (final (index, item) in managed.indexed) {
        final raw = item.raw;
        final execution = RegexScript.fromJson({...raw, if (!item.compatible) 'disabled': true});
        final effective = enabledGlobally && !execution.disabled;
        if (requested.effectiveOnly && !effective) {
          continue;
        }
        rules.add(
          TavernScriptRegex(
            source: TavernScriptRegexSource.global,
            sourceRef: {
              'kind': 'managedGlobal',
              'resourceId': item.id,
              'index': index,
              'libraryVersion': managedVersion,
              'writeTarget': const TavernScriptRegexWriteTarget.globalLibrary().toJson(),
              'version': _scriptRegexVersion({
                'raw': raw,
                'diagnostics': [for (final diagnostic in item.diagnostics) diagnostic.toJson()],
              }),
            },
            raw: raw,
            engineId: item.id,
            stId: execution.id,
            execution: execution,
            enabled: item.enabled,
            effective: effective,
            diagnostics: item.diagnostics,
          ),
        );
      }
      addPacks(TavernScriptRegexSource.global);
    }
    if (requested.sources.contains(TavernScriptRegexSource.preset)) {
      final extensions = _map(presetSettings['extensions']);
      addArray(
        extensions['regex_scripts'],
        TavernScriptRegexSource.preset,
        {
          'kind': 'preset',
          'presetSource': preset.source,
          'presetVersion': preset.version,
          'resourceId': ?(presetRef.presetId ?? preset.source['loadedPresetId']),
          'selection': requested.presetId == null ? preset.source['loadedSource'] : 'explicit',
          'writeTarget': TavernScriptRegexWriteTarget.preset(preset: presetRef).toJson(),
        },
        sourceEnabled: settings['presetRegexEnabled'] != false,
        present: extensions.containsKey('regex_scripts'),
      );
    }
    if (requested.sources.contains(TavernScriptRegexSource.character) && actorId != null) {
      try {
        actorView = characterData?['characterId'] == actorId
            ? characterData
            : await engine._libraryOperation(() => _scriptCharacterDataView(actorId));
        _context(contextId);
        if (actorView == null) {
          throw _scriptError(
            TavernScriptErrorCode.notFound,
            'getTavernRegexes',
            'The selected character is unavailable.',
            contextId: contextId,
          );
        }
        final card = actorView['data']! as Map<String, Object?>;
        final extensions = _map(card['extensions']);
        addArray(
          extensions['regex_scripts'],
          TavernScriptRegexSource.character,
          {
            'kind': 'character',
            'resourceId': actorId,
            'resourceVersion': actorView['version'],
            'writeTarget': TavernScriptRegexWriteTarget.character(characterId: actorId).toJson(),
          },
          sourceEnabled:
              settings['characterRegexEnabled'] != false &&
              !_strings(settings['disabledCharacterRegex']).contains(actorId),
          present: extensions.containsKey('regex_scripts'),
        );
      } catch (error) {
        final missing = error is TavernScriptException && error.code == TavernScriptErrorCode.notFound;
        if (!forCache || !missing && !_scriptRegexResourceDataError(error)) {
          rethrow;
        }
        final source = <String, Object?>{'kind': 'character', 'resourceId': actorId};
        sources.add({...source, 'available': false});
        issues.add(_scriptRegexCacheIssue(error, source));
      }
      addPacks(TavernScriptRegexSource.character);
    }
    addPacks(TavernScriptRegexSource.chat);
    _context(contextId);
    checkGameplay();

    bool current() {
      if (context.closed || _closed || engine._closed || engine._closing || !identical(contexts[contextId], context)) {
        return false;
      }
      final latest = chatId == null ? null : engine._store.chat(chatId);
      final currentMetadata = latest == null ? null : engine._chatCodec.metadataForNode(engine._store, latest.id);
      final currentSettings = engine._effectiveSettings(latest, currentMetadata);
      if (settingsVersion !=
              _scriptRegexSettingsVersion(_map(engine._document['settings']), latest?.settings, currentSettings) ||
          managedVersion != _scriptManagedRegexVersion(engine._regexLibrary.scripts) ||
          preset.version != _scriptPresetViewNow(context, presetRef).version) {
        return false;
      }
      if (actorId != null && actorRevision != (engine._directors._cardRevisions[actorId] ?? 0)) {
        return false;
      }
      if (actorView != null && !_scriptCharacterDataViewCurrent(actorView)) {
        return false;
      }
      return gameplay == null || _gameplayResourcesCurrent(engine, gameplay);
    }

    final view = _ScriptRegexView(rules: rules, sources: sources, issues: issues, current: current);
    if (!current()) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'getTavernRegexes',
        'The captured regex sources changed.',
        contextId: contextId,
      );
    }
    return view;
  }

  bool _scriptRegexViewCurrent(_ScriptRegexView view) => view.current();

  Map<String, Object?> _scriptRegexViewJson(_ScriptRegexView view) {
    final value = <String, Object?>{
      'sources': view.sources,
      'rules': [
        for (final rule in view.rules)
          {
            'source': rule.source.name,
            'sourceRef': rule.sourceRef,
            'raw': rule.raw,
            'engineId': ?rule.engineId,
            'stId': rule.stId,
            'enabled': rule.enabled,
            'effective': rule.effective,
            'diagnostics': [for (final issue in rule.diagnostics) issue.toJson()],
          },
      ],
      'issues': view.issues,
    };
    // This is an execution-cache token. It is not a physical write CAS.
    return {'version': _scriptRegexVersion(value), ...value};
  }

  Future<TavernDisplayResult> formatScriptText(
    String contextId,
    String text, {
    required int source,
    required RegexPhase destination,
    num? depth,
    String? characterId,
  }) async {
    final context = _context(contextId);
    if (!const {
      RegexPlacement.userInput,
      RegexPlacement.aiOutput,
      RegexPlacement.slashCommand,
      RegexPlacement.worldInfo,
      RegexPlacement.reasoning,
    }.contains(source)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'formatAsTavernRegexedString',
        'The regex source must be a supported numeric placement.',
        contextId: contextId,
      );
    }
    if (destination != RegexPhase.prompt && destination != RegexPhase.display) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'formatAsTavernRegexedString',
        'This formatter supports prompt and display destinations.',
        contextId: contextId,
      );
    }
    if ((depth != null && !depth.isFinite) || characterId == '') {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'formatAsTavernRegexedString',
        'Depth must be finite and an explicit character id must be nonempty.',
        contextId: contextId,
      );
    }
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final anchor = chat?.currentLeafId;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final metadata = chat == null
        ? <String, Object?>{}
        : _runtimeCopy(engine._chatCodec.metadataForNode(engine._store, chat.id));
    final state = chat == null
        ? <String, Object?>{}
        : anchor == null && group == null
        ? _emptyChatState(metadata)
        : engine._stateAt(chat.id, anchor);
    final history = chat == null ? <StoredNode>[] : engine._historyTo(chat.id, anchor);
    final live = chat == null ? null : engine._liveVariables[chat.id];
    final local = _runtimeCopy(
      live != null && live.leaf == anchor
          ? live.values
          : state.containsKey('variables')
          ? _map(state['variables'])
          : chat?.variables ?? <String, Object?>{},
    );
    final global = _runtimeCopy(engine._globalVariables);
    final settings = _runtimeCopy(
      _personaSettings(engine._effectiveSettings(chat, metadata), engine._personas.resolve(personaId: chat?.personaId)),
    );
    final config = engine._config;
    final at = engine._clock();
    final actorId = characterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    final gameplayCapture = _captureGameplayResources(
      engine,
      characterId: actorId,
      chatId: chatId,
      kinds: const {'regex'},
      deferResourceErrors: true,
    );
    final actor = actorId == null ? null : await engine._record(actorId);
    if (actorId != null && actor == null) {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'formatAsTavernRegexedString',
        'The selected character is unavailable.',
        contextId: contextId,
      );
    }
    final groupView = group == null ? null : await engine._groups.capture(group);
    _context(contextId);
    void checkGameplay() {
      if (!_gameplayResourcesCurrent(engine, gameplayCapture)) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'formatAsTavernRegexedString',
          'The captured gameplay regex sources changed.',
          contextId: contextId,
        );
      }
    }

    checkGameplay();
    final packRegex = _resolveGameplayResources(
      gameplayCapture,
      settings,
      actorId: actorId,
      kinds: const {'regex'},
    ).regex;
    final random = Random(_displaySeed(jsonEncode([chatId, context.value.nodeId, source, destination.name])));
    final environment = _MacroEnvironment(
      actor == null ? <String, Object?>{} : _effectiveCard(actor.card.data, settings),
      settings,
      local,
      global,
      history,
      config,
      at,
      random.nextDouble,
      chat == null
          ? ''
          : _macroChatIdentity(
              chat,
              state,
              metadata,
              state['chatJsonlSourceFile'] as String?,
              node: history.lastOrNull,
            ),
      '',
      'normal',
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: actorId ?? '',
      groupNames: groupView?.names,
      groupNotMuted: groupView?.enabledNames,
      messageVariables: state['messageVariables'],
      messageVariablesExists: state.containsKey('messageVariables'),
      packRegex: packRegex,
    );
    var resourceConflict = false;
    ({Object error, StackTrace stackTrace})? resourceFailure;
    bool cancelled() {
      if (context.closed || _closed || engine._closing) {
        return true;
      }
      if (resourceConflict || resourceFailure != null) {
        return true;
      }
      // applyDisplay catches rule replacement errors. Preserve a real store
      // error here and rethrow it after its original worker Future is drained.
      try {
        resourceConflict = !_gameplayResourcesCurrent(engine, gameplayCapture);
      } catch (error, stackTrace) {
        resourceFailure = (error: error, stackTrace: stackTrace);
      }
      return resourceConflict || resourceFailure != null;
    }

    checkGameplay();
    final RegexDisplayResult rendered;
    if (destination == RegexPhase.display) {
      rendered = await environment.regex.applyDisplay(
        text,
        placement: source,
        worker: engine._regexWorker,
        depth: depth,
        expand: environment.regexExpand,
        characterOverride: source == RegexPlacement.userInput ? environment.userName : null,
        isCancelled: cancelled,
      );
    } else {
      rendered = environment.regex.applyWithDiagnostics(
        text,
        placement: source,
        phase: RegexPhase.prompt,
        depth: depth,
        expand: environment.regexExpand,
        characterOverride: source == RegexPlacement.userInput ? environment.userName : null,
      );
    }
    final failure = resourceFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    if (resourceConflict) {
      throw _scriptError(
        TavernScriptErrorCode.revisionConflict,
        'formatAsTavernRegexedString',
        'The captured gameplay regex sources changed.',
        contextId: contextId,
      );
    }
    if (!context.closed && !_closed && !engine._closing) {
      checkGameplay();
    }
    // Both phases stay detached: no variable/hash or SQL writes and no generation receipt.
    return TavernDisplayResult(
      text: rendered.text,
      warnings: rendered.warnings,
      replacements: rendered.replacements,
      superseded: rendered.cancelled || context.closed || _closed || engine._closing,
    );
  }
}

String _scriptRegexVersion(Object? raw) => crypto.sha256.convert(utf8.encode(jsonEncode(raw))).toString();

List<TavernRegexDiagnostic> _scriptRegexShapeDiagnostics(Map<String, Object?> raw, int index) {
  final trims = raw['trimStrings'];
  if (raw['findRegex'] is String &&
      raw['replaceString'] is String &&
      (trims == null || (trims is List<Object?> && trims.every((item) => item is String)))) {
    return const [];
  }
  return [
    TavernRegexDiagnostic(
      path: '[$index]',
      status: TavernRegexCompatibility.incompatible,
      code: 'invalid-script',
      message: 'Known regex string fields have an incompatible shape.',
    ),
  ];
}

final class _ScriptRegexView {
  _ScriptRegexView({
    required List<TavernScriptRegex> rules,
    required List<Map<String, Object?>> sources,
    required List<Map<String, Object?>> issues,
    required this.current,
  }) : rules = List.unmodifiable(rules),
       sources = List.unmodifiable(sources),
       issues = List.unmodifiable(issues);
  final List<TavernScriptRegex> rules;
  final List<Map<String, Object?>> sources, issues;
  final bool Function() current;
}

String _scriptManagedRegexVersion(List<TavernRegexScript> records) => _scriptRegexVersion([
  for (final record in records)
    {
      'id': record.id,
      'raw': record.raw,
      'diagnostics': [for (final issue in record.diagnostics) issue.toJson()],
    },
]);

String _scriptRegexSettingsVersion(
  Map<String, Object?> global,
  Map<String, Object?>? chat,
  Map<String, Object?> effective,
) => _scriptRegexVersion({
  'global': _inlineRegexBefore(global),
  'chat': chat == null ? null : _inlineRegexBefore(chat),
  'effective': {
    for (final key in const [
      'globalRegexScripts',
      'regex',
      'regexEnabled',
      'presetRegexEnabled',
      'characterRegexEnabled',
      'disabledCharacterRegex',
    ])
      key: {'present': effective.containsKey(key), 'value': effective[key]},
  },
});

Map<String, Object?> _scriptInlineRegexLocation(
  Map<String, Object?> global,
  Map<String, Object?>? chat,
  Map<String, Object?> effective,
  String? chatId,
) {
  final rootField = _rootInlineRegexField(global);
  final String field;
  if (effective['globalRegexScripts'] != null) {
    field = 'globalRegexScripts';
  } else if (effective['regex'] != null ||
      chat != null && (chat.containsKey('globalRegexScripts') || chat.containsKey('regex'))) {
    field = 'regex';
  } else {
    field = rootField;
  }
  final chatOwned = chat?.containsKey(field) == true;
  return {
    'kind': 'inlineGlobal', 'scope': chatOwned ? 'chat' : 'global', 'field': field,
    if (chatOwned) 'chatId': chatId,
    // A root shadow alias can be selected only by a chat's null override.
    // Its physical globalInline target still selects the other root field.
    if (!chatOwned && field == rootField) 'writeTarget': const TavernScriptRegexWriteTarget.globalInline().toJson(),
  };
}

bool _scriptRegexResourceDataError(Object error) =>
    error is FormatException ||
    error is StateError && error.message == 'A stored gameplay resource file is missing.' ||
    error is TavernGameplayException && error.code == 'resource_identity_conflict';

Map<String, Object?> _scriptRegexCacheIssue(Object error, Map<String, Object?> source) => {
  'source': source,
  'code': error is TavernGameplayException
      ? error.code
      : error is TavernScriptException
      ? error.code.name
      : 'invalidResource',
  'message': error is TavernGameplayException
      ? error.message
      : error is TavernScriptException
      ? error.message
      : error is FormatException
      ? error.message
      : error.toString(),
};
