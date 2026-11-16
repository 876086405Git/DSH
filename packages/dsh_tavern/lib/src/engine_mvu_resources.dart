part of 'engine.dart';

class _MvuResources {
  _MvuResources({
    required this.dataContext,
    required this.chat,
    required this.settings,
    required this.config,
    required this.groupNames,
    required this.groupIdentity,
    required this.selection,
    required this.hostVersion,
  });

  final _ScriptDataContext dataContext;
  final StoredChat chat;
  final Map<String, Object?> settings;
  final TavernModelConfig config;
  final _GroupNames? groupNames;
  final String? groupIdentity;
  final List<({String handle, TavernScriptBookRef ref, WorldInfoSource source})> selection;
  final String? hostVersion;
  final books = <mvu_core.MvuBook>[];
  final issues = <TavernScriptIssue>[];
  final _bookVersions = <String, String?>{};
}

List<({String handle, TavernScriptBookRef ref, WorldInfoSource source})> _mvuBookSelection(
  Map<String, Object?> settings,
  String hostId, {
  required bool embedded,
}) {
  final result = <({String handle, TavernScriptBookRef ref, WorldInfoSource source})>[];
  final seen = <String>{};
  void standalone(Object? value, WorldInfoSource source) {
    for (final id in _strings(value)) {
      final handle = 'standalone:$id';
      if (seen.add(handle)) {
        result.add((handle: handle, ref: TavernScriptBookRef.standalone(bookId: id), source: source));
      }
    }
  }

  final bindings = _map(settings['lorebooks']);
  standalone(bindings['global'], WorldInfoSource.global);
  if (embedded) {
    result.add((
      handle: 'embedded:$hostId',
      ref: TavernScriptBookRef.embedded(characterId: hostId),
      source: WorldInfoSource.character,
    ));
  }
  if (!embedded) {
    final primary = _map(settings['characterPrimaryLorebooks'])[hostId];
    if (primary is String) {
      standalone([primary], WorldInfoSource.character);
    }
  }
  standalone(bindings['character'], WorldInfoSource.character);
  standalone(_characterLinkedBookIds(settings, hostId, embedded: embedded), WorldInfoSource.character);
  return result;
}

extension _ScriptMvuResources on _ScriptCoordinator {
  String? _mvuObservedVersion(String key) {
    final observed = scriptResources.observations[key];
    return observed == null ? null : '$epoch:resource:$key:${observed.revision}';
  }

  String? _mvuGroupIdentity(TavernGroupChat? group) => group == null
      ? null
      : jsonEncode([
          group.hostCharacterId,
          for (final member in group.members)
            [
              member.characterId,
              member.muted,
              engine._directors._cardRevisions[member.characterId] ?? 0,
              engine._deletingCharacters.contains(member.characterId),
            ],
        ]);

  Future<_MvuResources> _captureMvuResources(
    String chatId, {
    required Map<String, Object?> state,
    required void Function() check,
  }) async {
    check();
    final dataContext = await _prepareDataContext(
      chatId,
      forceGameplay: state.containsKey('dshgoPackDefinitionConfigId'),
    );
    check();
    _checkDataContext(dataContext);
    final chat = engine._store.chat(chatId);
    final group = engine._store.groupChat(chatId);
    final groupIdentity = _mvuGroupIdentity(group);
    final hostVersion = _mvuObservedVersion('characterData:${dataContext.hostId}');
    final settings = _personaSettings(dataContext.settings, engine._personas.resolve(personaId: chat.personaId));
    final config = engine._config;
    final selection = _mvuBookSelection(
      dataContext.settings,
      dataContext.hostId,
      embedded: dataContext.hostData.containsKey('character_book'),
    );
    final names = group == null ? null : await engine._groups.captureNames(group);
    check();
    final capture = _MvuResources(
      dataContext: dataContext,
      chat: chat,
      settings: settings,
      config: config,
      groupNames: names,
      groupIdentity: groupIdentity,
      selection: selection,
      hostVersion: hostVersion,
    );
    _checkMvuResources(capture);
    for (final item in selection) {
      WorldInfoBook? book;
      try {
        final snapshot = await _readScriptBook(item.ref);
        capture._bookVersions[item.handle] = snapshot.version;
        book = WorldInfoBook.fromJson(id: item.handle, source: item.source, json: snapshot.book);
      } on TavernScriptException catch (error) {
        if (error.code != TavernScriptErrorCode.notFound &&
            error.code != TavernScriptErrorCode.invalidJson &&
            error.code != TavernScriptErrorCode.shapeMismatch) {
          rethrow;
        }
        capture._bookVersions.putIfAbsent(item.handle, () => _mvuObservedVersion(item.handle));
        capture.issues.add(
          TavernScriptIssue(
            code: 'mvu_book_unavailable',
            message: error.message,
            committed: false,
            stage: 'mvu',
            details: {'source': item.handle},
          ),
        );
      } on FormatException catch (error) {
        capture._bookVersions.putIfAbsent(item.handle, () => _mvuObservedVersion(item.handle));
        capture.issues.add(
          TavernScriptIssue(
            code: 'mvu_book_unavailable',
            message: error.message,
            committed: false,
            stage: 'mvu',
            details: {'source': item.handle},
          ),
        );
      }
      check();
      _checkMvuResources(capture);
      if (book != null) {
        capture.books.add(
          mvu_core.MvuBook(
            name: item.handle,
            entries: [
              for (final entry in book.entries)
                mvu_core.MvuInitEntry(id: entry.uid, comment: entry.comment, content: entry.content),
            ],
          ),
        );
      }
    }
    return capture;
  }

  void _checkMvuResources(_MvuResources capture) {
    _checkDataContext(capture.dataContext);
    final chat = engine._store.chat(capture.dataContext.chatId);
    final current = _mvuBookSelection(
      engine._effectiveSettings(chat),
      capture.dataContext.hostId,
      embedded: capture.dataContext.hostData.containsKey('character_book'),
    );
    final sameSelection =
        current.length == capture.selection.length &&
        Iterable<int>.generate(current.length).every(
          (index) =>
              current[index].handle == capture.selection[index].handle &&
              current[index].source == capture.selection[index].source,
        );
    if (!sameSelection ||
        _mvuObservedVersion('characterData:${capture.dataContext.hostId}') != capture.hostVersion ||
        _mvuGroupIdentity(engine._store.groupChat(chat.id)) != capture.groupIdentity) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, 'mvu', 'The captured initialization sources changed.');
    }
    for (final item in capture._bookVersions.entries) {
      if (_mvuObservedVersion(item.key) != item.value) {
        throw _scriptError(TavernScriptErrorCode.revisionConflict, 'mvu', 'A captured initialization book changed.');
      }
    }
  }

  _MacroEnvironment _mvuEnvironment(
    _MvuResources capture, {
    required Map<String, Object?> state,
    required List<StoredNode> history,
    required DateTime at,
    String input = '',
    String generationType = 'normal',
    _MacroEnvironment? turnEnvironment,
  }) {
    if (turnEnvironment case final source?) {
      // Keep the actual actor and frozen prompt resources, but bind a fresh
      // macro context to this physical target's current variable table.
      return _MacroEnvironment(
        source.card,
        source.settings,
        _map(state['variables']),
        engine._globalVariables,
        history,
        source.config,
        source.now,
        source.random,
        source.chatId,
        source.input,
        source.generationType,
        characterId: source.characterId,
        chatIdHash: source.chatIdHash,
        pickRerollSeed: source.pickRerollSeed,
        groupNames: source.groupNames,
        groupNotMuted: source.groupNotMuted,
        preset: ChatPreset(source._presetSettings),
        regexPresetSettings: source._regexPresetSettings,
        collapseNewlinesOverride: source.collapseNewlinesOverride,
        messageVariables: state['messageVariables'],
        messageVariablesExists: state.containsKey('messageVariables'),
        packRegex: source._capturedPackRegex,
      )..outlets.addAll(source.outlets);
    }
    final metadata = engine._chatCodec.metadataForState(capture.chat, state);
    final admission = capture.dataContext.gameplayAdmission;
    return _MacroEnvironment(
      _effectiveCard(capture.dataContext.hostData, capture.settings),
      capture.settings,
      _map(state['variables']),
      engine._globalVariables,
      history,
      capture.config,
      at,
      engine._random,
      _macroChatIdentity(
        capture.chat,
        state,
        metadata,
        state['chatJsonlSourceFile'] as String?,
        node: history.lastOrNull,
      ),
      input,
      generationType,
      characterId: capture.dataContext.hostId,
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      groupNames: capture.groupNames?.names,
      groupNotMuted: capture.groupNames?.enabledNames,
      messageVariables: state['messageVariables'],
      messageVariablesExists: state.containsKey('messageVariables'),
      gameplayCapture: admission == null ? null : _GameplayResourceCapture.fromAdmission(admission),
    );
  }
}
