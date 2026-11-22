part of 'engine.dart';

class _ScriptResourceState {
  final observations = <String, _ScriptObservedValue>{};
  final directory = _ScriptBookDirectoryState();
  final characterDataViews = Expando<Map<String, Object?>>();
  final avatarViews = Expando<_ScriptCharacterAvatarView>();
  final standaloneBooks = <String, _ScriptRuntimeStandalone>{};
}

class _ScriptRuntimeStandalone {
  _ScriptRuntimeStandalone(this.stat, this.book);
  final FileStat stat;
  final _ScriptStandaloneBook book;

  bool matches(FileStat current) =>
      stat.type == current.type &&
      stat.size == current.size &&
      stat.modified == current.modified &&
      stat.changed == current.changed;
}

class _ScriptStandaloneBook {
  _ScriptStandaloneBook(this.id, this.raw, this.envelope, this.sourceName, this.version);
  final String id, version;
  final Map<String, Object?> raw;
  final Map<String, Object?>? envelope;
  final String? sourceName;
  String get displayName => raw['name'] is String ? raw['name']! as String : '';
}

extension _ScriptRawResources on _ScriptCoordinator {
  String _resourceVersion(String key, Object? value, {bool present = true}) {
    final fingerprint = jsonEncode({'present': present, if (present) 'value': value});
    final observation = scriptResources.observations.putIfAbsent(key, () => _ScriptObservedValue(fingerprint));
    observation.observe(fingerprint);
    return '$epoch:resource:$key:${observation.revision}';
  }

  void scriptResourceCardCommitted(String id, Map<String, Object?> actualData) {
    _resourceVersion('characterData:$id', actualData);
    _resourceVersion('embedded:$id', actualData['character_book'], present: actualData.containsKey('character_book'));
    scriptBookDirectoryCardCommitted(id, actualData);
    engine._characterCache = null;
    unawaited(engine._characterDetails.remove(id));
  }

  void scriptResourceBookCommitted(String id, Map<String, Object?>? actualRaw) {
    scriptResources.standaloneBooks.remove(id);
    _resourceVersion('standalone:$id', actualRaw, present: actualRaw != null);
    _observeStandaloneDirectory(id, actualRaw, engine._bookSourceNames[id]);
    resourcesChanged();
  }

  Future<Map<String, Object?>?> _scriptCharacterDataView(String characterId) =>
      engine._library.readRuntimeAuthority(characterId, (data) {
        final cached = scriptResources.characterDataViews[data];
        if (cached != null && _scriptCharacterDataViewCurrent(cached)) return cached;
        scriptBookDirectoryCardCommitted(characterId, data);
        return scriptResources.characterDataViews[data] = {
          'characterId': characterId,
          'version': _resourceVersion('characterData:$characterId', data),
          // Private runtime authority is read-only; the public DTO captures it.
          'data': data,
        };
      });

  bool _scriptCharacterDataViewCurrent(Map<String, Object?> view) {
    final id = view['characterId'];
    final observed = scriptResources.observations['characterData:$id'];
    return observed != null && view['version'] == '$epoch:resource:characterData:$id:${observed.revision}';
  }

  void _resourceExpected(String? expected, String current, String operation) {
    if (expected != null && expected != current) {
      throw _scriptError(TavernScriptErrorCode.revisionConflict, operation, 'The authoritative target changed.');
    }
  }

  Future<TavernCharacter> replaceScriptCharacterData(
    String contextId,
    String characterId,
    TavernJsonObject data, {
    String? expectedVersion,
  }) => _bridgeOperation(() async {
    final context = _context(contextId);
    final captured = _captureScriptObject(data);
    var adopted = false;
    String? adoptedVersion;
    void check() {
      if (!identical(_context(contextId), context)) {
        throw _scriptError(
          TavernScriptErrorCode.closedContext,
          'replaceCharacterData',
          'The context instance changed.',
        );
      }
      if (engine._deletingCharacters.contains(characterId)) {
        throw _scriptError(TavernScriptErrorCode.busy, 'replaceCharacterData', 'Character deletion is active.');
      }
    }

    try {
      final stored = await engine._libraryOperation(
        () => engine._library.updateAuthority(
          characterId,
          (current) {
            check();
            _resourceExpected(
              expectedVersion,
              _resourceVersion('characterData:$characterId', current),
              'replaceCharacterData',
            );
            return captured;
          },
          check: check,
          onCommitted: (actual) {
            adopted = true;
            adoptedVersion = _resourceVersion('characterData:$characterId', actual);
          },
        ),
      );
      engine._cacheCharacterDetail(characterId, Future.value(stored));
      engine._notifyLists();
      final stats = engine._store.characterChatStats()[characterId];
      return stored.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    } catch (error) {
      if (!adopted) rethrow;
      throw _resourcePartial(error, 'replaceCharacterData', contextId, {
        'targetKind': 'characterData',
        'characterId': characterId,
        'version': ?adoptedVersion,
      });
    }
  });

  TavernScriptException _resourcePartial(
    Object error,
    String operation,
    String contextId,
    Map<String, Object?> adopted,
  ) {
    final failure = _scriptFailure(error);
    return TavernScriptException(
      code: failure.code,
      operation: operation,
      message: failure.message,
      contextId: contextId,
      fieldPath: failure.fieldPath,
      committed: true,
      issues: [
        ...failure.issues,
        TavernScriptIssue(
          code: 'resourceAdopted',
          message: 'The authoritative file was adopted before a later step failed.',
          contextId: contextId,
          committed: true,
          stage: 'storage',
          details: adopted,
        ),
      ],
    );
  }

  Future<_ScriptStandaloneBook?> _scriptReadStandaloneRuntime(String id) async {
    _requireBookId(id);
    final stat = await File('${engine.directory.path}/lorebooks/$id.json').stat();
    final cached = scriptResources.standaloneBooks[id];
    if (cached != null && cached.matches(stat)) return cached.book;
    final book = await _scriptReadStandaloneNow(id);
    if (book != null && stat.type == FileSystemEntityType.file) {
      scriptResources.standaloneBooks[id] = _ScriptRuntimeStandalone(stat, book);
    }
    return book;
  }

  Future<_ScriptStandaloneBook?> _scriptReadStandaloneNow(String id) async {
    _requireBookId(id);
    scriptResources.standaloneBooks.remove(id);
    final file = File('${engine.directory.path}/lorebooks/$id.json');
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
      _resourceVersion('standalone:$id', null, present: false);
      _observeStandaloneDirectory(id, null, null);
      return null;
    }
    Never unreadable(TavernScriptErrorCode code, String message) {
      final error = _scriptError(code, 'readBook', message);
      _observeStandaloneDirectory(id, null, null, error: error);
      throw error;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      unreadable(TavernScriptErrorCode.invalidJson, 'The book file is not valid JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      unreadable(TavernScriptErrorCode.shapeMismatch, 'The book root is not an object.');
    }
    Map<String, Object?> raw = decoded;
    Map<String, Object?>? envelope;
    String? source;
    if (!decoded.containsKey('entries') && decoded['format'] == 'dshgo-lorebook') {
      if (decoded['version'] != 1 ||
          decoded['book'] is! Map<String, Object?> ||
          (decoded['stWorldName'] != null && decoded['stWorldName'] is! String)) {
        unreadable(TavernScriptErrorCode.shapeMismatch, 'The stored book envelope is malformed.');
      }
      envelope = decoded;
      raw = decoded['book']! as Map<String, Object?>;
      source = decoded['stWorldName'] as String?;
    }
    final captured = _captureScriptObject(raw);
    _observeStandaloneDirectory(id, captured, source);
    return _ScriptStandaloneBook(
      id,
      captured,
      envelope == null ? null : _captureScriptObject(envelope),
      source,
      _resourceVersion('standalone:$id', captured),
    );
  }

  Future<TavernScriptBookSnapshot> readScriptBook(String contextId, TavernScriptBookRef ref) =>
      _bridgeOperation(() async {
        final context = _context(contextId);
        final result = await _readScriptBook(ref);
        if (!identical(_context(contextId), context)) {
          throw _scriptError(TavernScriptErrorCode.closedContext, 'readBook', 'The context instance changed.');
        }
        return result;
      });

  Future<TavernScriptBookSnapshot> _readScriptBook(TavernScriptBookRef ref) async {
    switch (ref) {
      case TavernScriptStandaloneBookRef(:final bookId):
        return engine._bookOperation(() async {
          final value = await _scriptReadStandaloneNow(bookId);
          if (value == null) throw _scriptError(TavernScriptErrorCode.notFound, 'readBook', 'The book does not exist.');
          return TavernScriptBookSnapshot(ref: ref, version: value.version, book: value.raw);
        });
      case TavernScriptEmbeddedBookRef(:final characterId):
        final result = await engine._library.readAuthority(characterId, (data) {
          scriptBookDirectoryCardCommitted(characterId, data);
          final version = _resourceVersion(
            'embedded:$characterId',
            data['character_book'],
            present: data.containsKey('character_book'),
          );
          if (!data.containsKey('character_book')) {
            throw _scriptError(TavernScriptErrorCode.notFound, 'readBook', 'The character has no embedded book.');
          }
          final value = data['character_book'];
          if (value is! Map<String, Object?>) {
            throw _scriptError(
              TavernScriptErrorCode.shapeMismatch,
              'readBook',
              'The embedded book root is not an object.',
            );
          }
          return TavernScriptBookSnapshot(ref: ref, version: version, book: value);
        });
        if (result == null) {
          throw _scriptError(TavernScriptErrorCode.notFound, 'readBook', 'The character does not exist.');
        }
        return result;
    }
  }

  Future<TavernScriptBookSnapshot> replaceScriptBook(
    String contextId,
    TavernScriptBookRef ref,
    TavernJsonObject book, {
    String? expectedVersion,
  }) => _bridgeOperation(() async {
    final context = _context(contextId);
    final captured = _captureScriptObject(book);
    void check() {
      if (!identical(_context(contextId), context)) {
        throw _scriptError(TavernScriptErrorCode.closedContext, 'replaceBook', 'The context instance changed.');
      }
    }

    return _replaceScriptBook(contextId, ref, captured, expectedVersion: expectedVersion, check: check);
  });

  Future<TavernScriptBookSnapshot> _replaceScriptBook(
    String contextId,
    TavernScriptBookRef ref,
    Map<String, Object?> book, {
    String? expectedVersion,
    required void Function() check,
  }) async {
    var adopted = false;
    String? adoptedVersion;
    try {
      switch (ref) {
        case TavernScriptStandaloneBookRef(:final bookId):
          return await engine._bookOperation(() async {
            engine._authoringAuthority.checkWritable('lorebook:$bookId');
            final old = await _scriptReadStandaloneNow(bookId);
            if (old == null) {
              throw _scriptError(TavernScriptErrorCode.notFound, 'replaceBook', 'The book does not exist.');
            }
            check();
            _resourceExpected(expectedVersion, old.version, 'replaceBook');
            await engine._writeBookNow(
              bookId,
              book,
              stWorldName: old.sourceName,
              preservedEnvelope: old.envelope,
              check: check,
              onRenamed: () {
                adopted = true;
                adoptedVersion = _resourceVersion('standalone:$bookId', book);
              },
            );
            resourcesChanged();
            return TavernScriptBookSnapshot(ref: ref, version: adoptedVersion!, book: book);
          });
        case TavernScriptEmbeddedBookRef(:final characterId):
          void characterCheck() {
            check();
            if (engine._deletingCharacters.contains(characterId)) {
              throw _scriptError(TavernScriptErrorCode.busy, 'replaceBook', 'Character deletion is active.');
            }
          }
          final stored = await engine._libraryOperation(
            () => engine._library.updateAuthority(
              characterId,
              (data) {
                characterCheck();
                final version = _resourceVersion(
                  'embedded:$characterId',
                  data['character_book'],
                  present: data.containsKey('character_book'),
                );
                _resourceExpected(expectedVersion, version, 'replaceBook');
                return {...data, 'character_book': book};
              },
              check: characterCheck,
              onCommitted: (actual) {
                adopted = true;
                adoptedVersion = _resourceVersion('embedded:$characterId', actual['character_book']);
              },
            ),
          );
          engine._cacheCharacterDetail(characterId, Future.value(stored));
          engine._notifyLists();
          return TavernScriptBookSnapshot(ref: ref, version: adoptedVersion!, book: book);
      }
    } catch (error) {
      if (!adopted) rethrow;
      throw _resourcePartial(error, 'replaceBook', contextId, {
        'targetKind': 'book',
        'ref': ref.toJson(),
        'version': ?adoptedVersion,
      });
    }
  }

  Future<List<TavernScriptBookBinding>> scriptContextBooks(String contextId) => _bridgeOperation(() async {
    final context = _context(contextId);
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final metadata = chat == null ? null : engine._chatCodec.metadataForNode(engine._store, chat.id);
    final settings = engine._effectiveSettings(chat, metadata);
    final persona = engine._personas.resolve(personaId: chat?.personaId).persona;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final actorId = context.value.characterId ?? (group == null ? chat?.characterId : null);
    final bindings = _map(settings['lorebooks']);
    final result = <TavernScriptBookBinding>[];
    final seen = <String>{};
    void add(
      TavernScriptBookRef ref,
      TavernScriptBookSource source, {
      String? characterId,
      String? personaId,
      String? chatId,
    }) {
      final key = jsonEncode([ref.toJson(), source.name, characterId, personaId, chatId]);
      if (!seen.add(key)) return;
      result.add(
        TavernScriptBookBinding(
          ref: ref,
          source: source,
          characterId: characterId,
          personaId: personaId,
          chatId: chatId,
        ),
      );
    }

    void standalone(
      Object? value,
      TavernScriptBookSource source, {
      String? characterId,
      String? personaId,
      String? chatId,
    }) {
      for (final id in _strings(value)) {
        add(
          TavernScriptBookRef.standalone(bookId: id),
          source,
          characterId: characterId,
          personaId: personaId,
          chatId: chatId,
        );
      }
    }

    standalone(bindings['global'], TavernScriptBookSource.global);
    if (persona != null) {
      standalone(bindings['persona'], TavernScriptBookSource.persona, personaId: persona.id);
      standalone(_map(settings['personaLorebooks'])[persona.id], TavernScriptBookSource.persona, personaId: persona.id);
    }
    if (chat != null) standalone(bindings['chat'], TavernScriptBookSource.chat, chatId: chat.id);
    final actors = group == null ? [?actorId] : [for (final member in group.members) member.characterId];
    for (final id in actors) {
      final source = group == null ? TavernScriptBookSource.character : TavernScriptBookSource.groupMember;
      standalone(bindings['character'], source, characterId: id, chatId: group == null ? null : chatId);
      final data = await engine._library.readRuntimeAuthority(id, (data) => data) ?? <String, Object?>{};
      final primaries = await _captureCharacterPrimaryBooks(settings, {id: data});
      standalone(
        _characterLinkedBookIds(settings, id, primary: primaries[id]!),
        source,
        characterId: id,
        chatId: group == null ? null : chatId,
      );
      if (data.containsKey('character_book')) {
        add(
          TavernScriptBookRef.embedded(characterId: id),
          source,
          characterId: id,
          chatId: group == null ? null : chatId,
        );
      }
    }
    if (!identical(_context(contextId), context)) {
      throw _scriptError(TavernScriptErrorCode.closedContext, 'getContextBooks', 'The context instance changed.');
    }
    return List.unmodifiable(result);
  });
}
