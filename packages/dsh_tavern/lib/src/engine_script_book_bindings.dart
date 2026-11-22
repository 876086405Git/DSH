part of 'engine.dart';

class _CharacterPrimaryBook {
  const _CharacterPrimaryBook({this.bookId, this.worldName, this.candidates = const []});
  final String? bookId;
  final String? worldName;
  final List<String> candidates;

  Map<String, Object?>? get evidence => worldName == null ? null : {'worldName': worldName, 'candidates': candidates};

  TavernScriptIssue? issue(String characterId) => worldName == null || bookId != null
      ? null
      : TavernScriptIssue(
          code: candidates.isEmpty ? 'notFound' : 'ambiguousName',
          message: candidates.isEmpty
              ? 'No readable standalone book matches the character world name.'
              : 'More than one readable standalone book matches the character world name.',
          committed: false,
          stage: 'bookBindings',
          details: {'characterId': characterId, 'worldName': worldName, 'candidateBookIds': candidates},
        );
}

String? _characterWorldName(Map<String, Object?> settings, String characterId, Map<String, Object?> data) {
  if (data.containsKey('character_book') || _readMap(settings['characterPrimaryLorebooks']).containsKey(characterId)) {
    return null;
  }
  final name = _readMap(data['extensions'])['world'];
  return name is String && name.isNotEmpty ? name : null;
}

// Preserve the owned list, including duplicates. Each execution consumer
// already applies its own source-aware deduplication.
List<String> _characterLinkedBookIds(
  Map<String, Object?> settings,
  String characterId, {
  required _CharacterPrimaryBook primary,
}) => [?primary.bookId, ..._strings(_readMap(settings['characterLorebooks'])[characterId])];

Map<String, Object?> _characterBookMissing(TavernScriptIssue issue) => {
  ...issue.details,
  'source': WorldInfoSource.character.name,
  'reason': issue.code,
};

Map<String, Object?> _bookBindingSlot(Map<String, Object?> owner, String key) => {
  'present': owner.containsKey(key),
  if (owner.containsKey(key)) 'value': owner[key],
};

class _ScriptBookBindingView {
  const _ScriptBookBindingView(
    this.snapshot, {
    this.source,
    this.primaryName,
    this.primaryBookId,
    this.characterData,
    this.issue,
  });
  final TavernScriptBookBindingsSnapshot snapshot;
  final ChatJsonlMetadataSource? source;
  final String? primaryName;
  final String? primaryBookId;
  final Map<String, Object?>? characterData;
  final TavernScriptIssue? issue;
}

extension _ScriptBookBindings on _ScriptCoordinator {
  List<String> _characterWorldCandidates(String name) =>
      (scriptResources.directory.standaloneNames[name]?.toList() ?? <String>[])..sort();

  _CharacterPrimaryBook _characterPrimaryBook(
    Map<String, Object?> settings,
    String characterId,
    Map<String, Object?> data,
  ) {
    if (data.containsKey('character_book')) return const _CharacterPrimaryBook();
    final primaries = _readMap(settings['characterPrimaryLorebooks']);
    if (primaries.containsKey(characterId)) {
      final explicit = primaries[characterId];
      return _CharacterPrimaryBook(bookId: explicit is String ? explicit : null);
    }
    final name = _characterWorldName(settings, characterId, data);
    if (name == null) return const _CharacterPrimaryBook();
    final candidates = _characterWorldCandidates(name);
    return _CharacterPrimaryBook(
      bookId: candidates.length == 1 ? candidates.single : null,
      worldName: name,
      candidates: candidates,
    );
  }

  Future<Map<String, _CharacterPrimaryBook>> _captureCharacterPrimaryBooks(
    Map<String, Object?> settings,
    Map<String, Map<String, Object?>> cards,
  ) async {
    if (!scriptResources.directory.loaded &&
        cards.entries.any((entry) => _characterWorldName(settings, entry.key, entry.value) != null)) {
      // Card capture precedes the book queue. Never acquire the library or
      // preset queue while loading this directory.
      await engine._bookOperation(_ensureStandaloneDirectory);
    }
    return {for (final entry in cards.entries) entry.key: _characterPrimaryBook(settings, entry.key, entry.value)};
  }

  bool _characterBookNamesCurrent(Iterable<_CharacterPrimaryBook> primaries) => primaries.every(
    (primary) =>
        primary.worldName == null || _stateJsonEqual(primary.candidates, _characterWorldCandidates(primary.worldName!)),
  );

  _ScriptContextState _bookBindingContext(String contextId, TavernScriptBookBindingsTarget target) {
    final context = _context(contextId);
    if (target.scope == TavernScriptBookBindingScope.global) {
      if (target.targetId != null) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'bookBindings',
          'Global book bindings do not have a target identity.',
          contextId: contextId,
        );
      }
    } else if (target.targetId == null || target.targetId!.isEmpty) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'bookBindings',
        'This book binding scope requires a target identity.',
        contextId: contextId,
      );
    }
    if (target.scope == TavernScriptBookBindingScope.chat && context.value.chatId != target.targetId) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'bookBindings',
        'Chat book bindings require this context to belong to that chat.',
        contextId: contextId,
      );
    }
    return context;
  }

  void _checkBookBindingContext(
    String contextId,
    _ScriptContextState context,
    TavernScriptBookBindingsTarget target,
    Map<String, Object?>? character,
  ) {
    if (!identical(_bookBindingContext(contextId, target), context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        'bookBindings',
        'The context instance changed.',
        contextId: contextId,
      );
    }
    final id = target.targetId;
    if (target.scope == TavernScriptBookBindingScope.character) {
      if (engine._deletingCharacters.contains(id) || character == null || !_scriptCharacterDataViewCurrent(character)) {
        throw _scriptError(
          TavernScriptErrorCode.revisionConflict,
          'bookBindings',
          'The captured character or its embedded-book presence changed.',
          contextId: contextId,
        );
      }
    } else if (target.scope == TavernScriptBookBindingScope.persona &&
        (engine._deletingPersonas.contains(id) || engine._personas.get(id!) == null)) {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'bookBindings',
        'The persona no longer exists.',
        contextId: contextId,
      );
    } else if (target.scope == TavernScriptBookBindingScope.chat) {
      try {
        engine._store.chatCurrentLeafId(id!);
      } on StateError {
        throw _scriptError(
          TavernScriptErrorCode.notFound,
          'bookBindings',
          'The chat no longer exists.',
          contextId: contextId,
        );
      }
    }
  }

  Future<Map<String, Object?>?> _bookBindingCharacter(String contextId, TavernScriptBookBindingsTarget target) async {
    if (target.scope != TavernScriptBookBindingScope.character) {
      return null;
    }
    final value = await _scriptCharacterDataView(target.targetId!);
    if (value == null || engine._deletingCharacters.contains(target.targetId)) {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'bookBindings',
        'The character does not exist.',
        contextId: contextId,
      );
    }
    return value;
  }

  _ScriptBookBindingView _bookBindingView(
    TavernScriptBookBindingsTarget target, {
    Map<String, Object?>? document,
    Map<String, Object?>? character,
    _ScriptChatRead? chatRead,
  }) {
    final settings = _readOptionalObject(document ?? engine._document, 'settings');
    final legacy = _readOptionalObject(settings, 'lorebooks');
    TavernScriptBookRef? primary;
    final additional = <TavernScriptBookRef>[];
    final inherited = <TavernScriptBookRef>[];
    ChatJsonlMetadataSource? source;
    String? primaryName;
    String? primaryBookId;
    TavernScriptIssue? issue;
    final evidence = <String, Object?>{'scope': target.scope.name, 'targetId': target.targetId};
    void append(List<TavernScriptBookRef> into, Object? raw) {
      for (final id in _strings(raw)) {
        into.add(TavernScriptBookRef.standalone(bookId: id));
      }
    }

    switch (target.scope) {
      case TavernScriptBookBindingScope.global:
        append(additional, legacy['global']);
        evidence['own'] = _bookBindingSlot(legacy, 'global');
      case TavernScriptBookBindingScope.character:
        final id = target.targetId!;
        final capturedCharacter = character!;
        final data = _readOptionalObject(capturedCharacter, 'data');
        final own = _readOptionalObject(settings, 'characterLorebooks');
        final primaries = _readOptionalObject(settings, 'characterPrimaryLorebooks');
        final selected = _characterPrimaryBook(settings, id, data);
        if (data.containsKey('character_book')) {
          primary = TavernScriptBookRef.embedded(characterId: id);
        } else if (selected.bookId case final bookId?) {
          primary = TavernScriptBookRef.standalone(bookId: bookId);
        }
        issue = selected.issue(id);
        append(additional, own[id]);
        append(inherited, legacy['character']);
        evidence.addAll({
          'characterVersion': capturedCharacter['version'],
          'primary': _bookBindingSlot(primaries, id),
          if (selected.evidence != null) 'automaticPrimary': selected.evidence,
          'own': _bookBindingSlot(own, id),
          'inherited': _bookBindingSlot(legacy, 'character'),
        });
      case TavernScriptBookBindingScope.persona:
        final id = target.targetId!;
        final own = _readOptionalObject(settings, 'personaLorebooks');
        append(additional, own[id]);
        append(inherited, legacy['persona']);
        evidence.addAll({'own': _bookBindingSlot(own, id), 'inherited': _bookBindingSlot(legacy, 'persona')});
      case TavernScriptBookBindingScope.chat:
        final chat = chatRead?.chat ?? engine._store.chat(target.targetId!);
        source = chatRead?.source ?? engine._chatCodec.metadataSourceForNode(engine._store, chat.id);
        final raw = chatRead == null
            ? engine._chatCodec.readMetadataSource(chat.metadata, source)
            : chatRead.sourceMetadata;
        if (raw == null) {
          throw _scriptError(
            TavernScriptErrorCode.revisionConflict,
            'bookBindings',
            'The selected chat metadata source is absent.',
          );
        }
        final names = _readOptionalObject(chat.settings, 'stLorebookIds');
        final own = _readOptionalObject(chat.settings, 'lorebooks');
        final name = raw['world_info'];
        final mapped = name is String ? names[name] : null;
        final ownIds = _strings(own['chat']);
        if (name is String && mapped is String) {
          primaryName = name;
          primaryBookId = mapped;
          // An explicit chat list replaces the metadata projection. Report
          // the effective primary, while retaining the raw source for CAS.
          if (!own.containsKey('chat') || ownIds.contains(mapped)) {
            primary = TavernScriptBookRef.standalone(bookId: mapped);
          }
        }
        if (own.containsKey('chat')) {
          var separatedPrimary = false;
          for (final id in ownIds) {
            if (!separatedPrimary && id == mapped) {
              separatedPrimary = true;
              continue;
            }
            additional.add(TavernScriptBookRef.standalone(bookId: id));
          }
        } else if (!raw.containsKey('world_info')) {
          append(inherited, legacy['chat']);
        }
        evidence.addAll({
          'source': source.identity,
          'metadata': raw,
          'own': _bookBindingSlot(own, 'chat'),
          'names': _bookBindingSlot(chat.settings, 'stLorebookIds'),
          'inherited': _bookBindingSlot(legacy, 'chat'),
        });
    }
    final key = 'bookBindings:${jsonEncode([target.scope.name, target.targetId])}';
    return _ScriptBookBindingView(
      TavernScriptBookBindingsSnapshot(
        scope: target.scope,
        targetId: target.targetId,
        version: _resourceVersion(key, evidence),
        primary: primary,
        additional: additional,
        inherited: inherited,
      ),
      source: source,
      primaryName: primaryName,
      primaryBookId: primaryBookId,
      characterData: character,
      issue: issue,
    );
  }

  Future<_ScriptBookBindingView> _captureBookBindingView(
    String contextId,
    TavernScriptBookBindingsTarget target, {
    Map<String, Object?>? characterData,
    _ScriptChatRead? chatRead,
  }) async {
    final context = _bookBindingContext(contextId, target);
    final character =
        target.scope == TavernScriptBookBindingScope.character && characterData?['characterId'] == target.targetId
        ? characterData
        : await _bookBindingCharacter(contextId, target);
    if (character != null &&
        !scriptResources.directory.loaded &&
        _characterWorldName(
              _readOptionalObject(engine._document, 'settings'),
              target.targetId!,
              _readOptionalObject(character, 'data'),
            ) !=
            null) {
      await engine._bookOperation(_ensureStandaloneDirectory);
    }
    _checkBookBindingContext(contextId, context, target, character);
    return _bookBindingView(target, character: character, chatRead: chatRead);
  }

  // Cache builders call this after their last awaited resource read. The
  // version includes the selected metadata carrier identity as well as raw
  // source contents; equal JSON from another physical source is not a match.
  bool _bookBindingViewCurrent(_ScriptBookBindingView view, {_ScriptChatRead? chatRead}) {
    final snapshot = view.snapshot;
    final target = TavernScriptBookBindingsTarget(scope: snapshot.scope, targetId: snapshot.targetId);
    final id = target.targetId;
    if (target.scope == TavernScriptBookBindingScope.character &&
        (engine._deletingCharacters.contains(id) ||
            view.characterData == null ||
            !_scriptCharacterDataViewCurrent(view.characterData!))) {
      return false;
    }
    if (target.scope == TavernScriptBookBindingScope.persona &&
        (engine._deletingPersonas.contains(id) || engine._personas.get(id!) == null)) {
      return false;
    }
    try {
      return _bookBindingView(target, character: view.characterData, chatRead: chatRead).snapshot.version ==
          snapshot.version;
    } on StateError {
      if (target.scope != TavernScriptBookBindingScope.chat) {
        rethrow;
      }
      return false;
    }
  }

  Future<TavernScriptBookBindingsSnapshot> _readBookBindings(
    String contextId,
    TavernScriptBookBindingsTarget target,
  ) async => (await _captureBookBindingView(contextId, target)).snapshot;

  String? _bookBindingObservedVersion(String id) {
    final key = 'standalone:$id';
    final current = scriptResources.observations[key];
    return current == null ? null : '$epoch:resource:$key:${current.revision}';
  }

  Future<TavernScriptBookBindingsSnapshot> _updateBookBindings(
    String contextId,
    TavernScriptBookBindingsEdit edit, {
    required String expectedVersion,
  }) async {
    final target = TavernScriptBookBindingsTarget(scope: edit.scope, targetId: edit.targetId);
    final context = _bookBindingContext(contextId, target);
    final requestedPrimary = edit.primary;
    final additionalIds = <String>[];
    for (final ref in edit.additional) {
      if (ref is! TavernScriptStandaloneBookRef) {
        throw _scriptError(
          TavernScriptErrorCode.unsupportedOption,
          'updateBookBindings',
          'Additional bindings refer to standalone books.',
          contextId: contextId,
        );
      }
      _requireBookId(ref.bookId);
      additionalIds.add(ref.bookId);
    }
    if (requestedPrimary case TavernScriptStandaloneBookRef(:final bookId)) {
      _requireBookId(bookId);
    }
    if ((target.scope == TavernScriptBookBindingScope.global || target.scope == TavernScriptBookBindingScope.persona) &&
        requestedPrimary != null) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'updateBookBindings',
        'This scope has no primary book.',
        contextId: contextId,
      );
    }
    if (target.scope == TavernScriptBookBindingScope.chat && requestedPrimary is TavernScriptEmbeddedBookRef) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'updateBookBindings',
        'A chat primary refers to a standalone book.',
        contextId: contextId,
      );
    }
    final chatCapture = target.scope == TavernScriptBookBindingScope.chat ? _captureChat(contextId) : null;
    final character = await _bookBindingCharacter(contextId, target);
    if (character != null &&
        !scriptResources.directory.loaded &&
        _characterWorldName(
              _readOptionalObject(engine._document, 'settings'),
              target.targetId!,
              _readOptionalObject(character, 'data'),
            ) !=
            null) {
      await engine._bookOperation(_ensureStandaloneDirectory);
    }
    _checkBookBindingContext(contextId, context, target, character);
    final embedded = character != null && _readOptionalObject(character, 'data').containsKey('character_book');
    if (target.scope == TavernScriptBookBindingScope.character) {
      if (embedded) {
        if (requestedPrimary != TavernScriptBookRef.embedded(characterId: target.targetId!)) {
          throw _scriptError(
            TavernScriptErrorCode.unsupportedOption,
            'updateBookBindings',
            'The embedded book remains primary. Delete that book explicitly before replacing this binding.',
            contextId: contextId,
          );
        }
      } else if (requestedPrimary is TavernScriptEmbeddedBookRef) {
        throw _scriptError(
          TavernScriptErrorCode.unsupportedOption,
          'updateBookBindings',
          'An embedded primary must already exist on this character.',
          contextId: contextId,
        );
      }
    }
    final before = _bookBindingView(target, character: character);
    _resourceExpected(expectedVersion, before.snapshot.version, 'updateBookBindings');
    final books = <String, ({String? version, int revision, String? sourceName})>{};
    final referenced = <String>{
      ...additionalIds,
      if (requestedPrimary case TavernScriptStandaloneBookRef(:final bookId)) bookId,
    };
    for (final id in referenced) {
      final book = await engine._bookOperation(() => _scriptReadStandaloneNow(id));
      _checkBookBindingContext(contextId, context, target, character);
      books[id] = (
        version: _bookBindingObservedVersion(id),
        revision: engine._bookRevisions[id] ?? 0,
        sourceName: book?.sourceName,
      );
    }

    void check() {
      _checkBookBindingContext(contextId, context, target, character);
      if (chatCapture != null) {
        _checkChatCapture(chatCapture, requireSamePath: true);
      }
      // This runs again after the temporary settings file is written. The
      // version includes only this character's exact name candidates, so an
      // unrelated directory change cannot invalidate the edit.
      _resourceExpected(
        expectedVersion,
        _bookBindingView(target, character: character).snapshot.version,
        'updateBookBindings',
      );
      for (final item in books.entries) {
        if (_bookBindingObservedVersion(item.key) != item.value.version ||
            (engine._bookRevisions[item.key] ?? 0) != item.value.revision) {
          throw _scriptError(
            TavernScriptErrorCode.revisionConflict,
            'updateBookBindings',
            'A referenced book changed before the binding was adopted.',
            contextId: contextId,
          );
        }
      }
    }

    var adopted = false;
    TavernScriptBookBindingsSnapshot? saved;
    try {
      if (target.scope == TavernScriptBookBindingScope.chat) {
        await _dataWrite(
          chatCapture!,
          (permit) => _toolPreparationSql(
            engine,
            permit,
            () {
              check();
              final current = _bookBindingView(target, character: character);
              final chat = engine._store.chat(target.targetId!);
              final settings = _copy(chat.settings);
              final names = _optionalObject(settings, 'stLorebookIds');
              final own = _optionalObject(settings, 'lorebooks');
              String? name;
              String? primaryId;
              if (requestedPrimary case TavernScriptStandaloneBookRef(:final bookId)) {
                primaryId = bookId;
                name = current.primaryBookId == bookId && current.primaryName != null
                    ? current.primaryName!
                    : books[bookId]!.sourceName ?? bookId;
                if (names.containsKey(name) && names[name] != bookId) {
                  throw _scriptError(
                    TavernScriptErrorCode.ambiguousName,
                    'updateBookBindings',
                    'The exact world-info source name already maps to another book.',
                    contextId: contextId,
                  );
                }
                names[name] = bookId;
              }
              own['chat'] = [?primaryId, ...additionalIds];
              settings['lorebooks'] = own;
              settings['stLorebookIds'] = names;
              final source = current.source!;
              final metadata = engine._chatCodec.updateMetadataSource(
                chat.metadata,
                sourceFile: source.sourceFile,
                target: source,
                update: (raw) => {...raw, 'world_info': name},
              );
              engine._store.updateChat(chat.id, settings: settings, metadata: metadata);
            },
            onCommitted: () {
              adopted = true;
              saved = _bookBindingView(target, character: character).snapshot;
            },
          ),
        );
      } else {
        await engine._presetOperation(
          () => engine._settingsDocument((document) async {
            check();
            final settings = _optionalObject(document, 'settings');
            switch (target.scope) {
              case TavernScriptBookBindingScope.global:
                final own = _optionalObject(settings, 'lorebooks');
                own['global'] = List<String>.of(additionalIds);
                settings['lorebooks'] = own;
              case TavernScriptBookBindingScope.character:
                final id = target.targetId!;
                final own = _optionalObject(settings, 'characterLorebooks');
                own[id] = List<String>.of(additionalIds);
                settings['characterLorebooks'] = own;
                if (!embedded) {
                  final primaries = _optionalObject(settings, 'characterPrimaryLorebooks');
                  if (requestedPrimary case TavernScriptStandaloneBookRef(:final bookId)) {
                    primaries[id] = bookId;
                  } else {
                    primaries[id] = null;
                  }
                  settings['characterPrimaryLorebooks'] = primaries;
                }
              case TavernScriptBookBindingScope.persona:
                final own = _optionalObject(settings, 'personaLorebooks');
                own[target.targetId!] = List<String>.of(additionalIds);
                settings['personaLorebooks'] = own;
              case TavernScriptBookBindingScope.chat:
                throw StateError('Chat bindings use their captured SQL source.');
            }
            final next = _copy(document)..['settings'] = settings;
            await engine._commitSettingsDocument(
              next,
              check: check,
              onCommitted: () {
                adopted = true;
                engine._document['settings'] = _copy(settings);
                saved = _bookBindingView(target, document: next, character: character).snapshot;
              },
            );
          }),
        );
      }
      await engine._directors.settingsChanged(
        target.scope == TavernScriptBookBindingScope.chat ? target.targetId : null,
      );
      TavernScriptException? cacheFailure;
      for (final current in contexts.values.toList()) {
        if (!current.closed) {
          try {
            await _refreshContext(current);
          } on TavernScriptException catch (error) {
            cacheFailure ??= error;
          }
        }
      }
      if (cacheFailure != null) {
        throw cacheFailure;
      }
      return saved!;
    } catch (error) {
      if (!adopted) {
        rethrow;
      }
      final failure = _scriptFailure(error);
      throw TavernScriptException(
        code: failure.code,
        operation: 'updateBookBindings',
        message: failure.message,
        contextId: contextId,
        fieldPath: failure.fieldPath,
        committed: true,
        stateEdit: failure.stateEdit,
        issues: [
          ...failure.issues,
          TavernScriptIssue(
            code: 'resourceAdopted',
            message: 'The book bindings were adopted before a later step failed.',
            contextId: contextId,
            committed: true,
            stage: 'storage',
            details: {'scope': target.scope.name, 'targetId': target.targetId, 'version': ?saved?.version},
          ),
        ],
      );
    }
  }
}
