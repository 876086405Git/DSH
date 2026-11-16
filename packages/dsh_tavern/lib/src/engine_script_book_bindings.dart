part of 'engine.dart';

// The generic character bucket remains at each caller. This projection adds
// only this character's explicit primary and its own ordered additional list.
List<String> _characterLinkedBookIds(Map<String, Object?> settings, String characterId, {required bool embedded}) {
  final primary = _map(settings['characterPrimaryLorebooks'])[characterId];
  return [if (!embedded && primary is String) primary, ..._strings(_map(settings['characterLorebooks'])[characterId])];
}

Map<String, Object?> _bookBindingSlot(Map<String, Object?> owner, String key) => {
  'present': owner.containsKey(key),
  if (owner.containsKey(key)) 'value': owner[key],
};

class _ScriptBookBindingView {
  const _ScriptBookBindingView(this.snapshot, {this.source, this.primaryName, this.primaryBookId, this.characterData});
  final TavernScriptBookBindingsSnapshot snapshot;
  final ChatJsonlMetadataSource? source;
  final String? primaryName;
  final String? primaryBookId;
  final Map<String, Object?>? characterData;
}

extension _ScriptBookBindings on _ScriptCoordinator {
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
        engine._store.chat(id!);
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
  }) {
    final settings = _optionalObject(document ?? engine._document, 'settings');
    final legacy = _optionalObject(settings, 'lorebooks');
    TavernScriptBookRef? primary;
    final additional = <TavernScriptBookRef>[];
    final inherited = <TavernScriptBookRef>[];
    ChatJsonlMetadataSource? source;
    String? primaryName;
    String? primaryBookId;
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
        final data = _optionalObject(capturedCharacter, 'data');
        final own = _optionalObject(settings, 'characterLorebooks');
        final primaries = _optionalObject(settings, 'characterPrimaryLorebooks');
        final explicit = primaries[id];
        if (data.containsKey('character_book')) {
          primary = TavernScriptBookRef.embedded(characterId: id);
        } else if (explicit is String) {
          primary = TavernScriptBookRef.standalone(bookId: explicit);
        }
        append(additional, own[id]);
        append(inherited, legacy['character']);
        evidence.addAll({
          'characterVersion': capturedCharacter['version'],
          'primary': _bookBindingSlot(primaries, id),
          'own': _bookBindingSlot(own, id),
          'inherited': _bookBindingSlot(legacy, 'character'),
        });
      case TavernScriptBookBindingScope.persona:
        final id = target.targetId!;
        final own = _optionalObject(settings, 'personaLorebooks');
        append(additional, own[id]);
        append(inherited, legacy['persona']);
        evidence.addAll({'own': _bookBindingSlot(own, id), 'inherited': _bookBindingSlot(legacy, 'persona')});
      case TavernScriptBookBindingScope.chat:
        final chat = engine._store.chat(target.targetId!);
        source = engine._chatCodec.metadataSourceForNode(engine._store, chat.id);
        final raw = engine._chatCodec.readMetadataSource(chat.metadata, source);
        if (raw == null) {
          throw _scriptError(
            TavernScriptErrorCode.revisionConflict,
            'bookBindings',
            'The selected chat metadata source is absent.',
          );
        }
        final names = _optionalObject(chat.settings, 'stLorebookIds');
        final own = _optionalObject(chat.settings, 'lorebooks');
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
    );
  }

  Future<_ScriptBookBindingView> _captureBookBindingView(
    String contextId,
    TavernScriptBookBindingsTarget target, {
    Map<String, Object?>? characterData,
  }) async {
    final context = _bookBindingContext(contextId, target);
    final character =
        target.scope == TavernScriptBookBindingScope.character && characterData?['characterId'] == target.targetId
        ? characterData
        : await _bookBindingCharacter(contextId, target);
    _checkBookBindingContext(contextId, context, target, character);
    return _bookBindingView(target, character: character);
  }

  // Cache builders call this after their last awaited resource read. The
  // version includes the selected metadata carrier identity as well as raw
  // source contents; equal JSON from another physical source is not a match.
  bool _bookBindingViewCurrent(_ScriptBookBindingView view) {
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
      return _bookBindingView(target, character: view.characterData).snapshot.version == snapshot.version;
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
    _checkBookBindingContext(contextId, context, target, character);
    final embedded = character != null && _optionalObject(character, 'data').containsKey('character_book');
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
              _resourceExpected(expectedVersion, current.snapshot.version, 'updateBookBindings');
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
            final current = _bookBindingView(target, document: document, character: character);
            _resourceExpected(expectedVersion, current.snapshot.version, 'updateBookBindings');
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
                    primaries.remove(id);
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
