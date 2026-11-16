part of 'engine.dart';

class _ScriptEmbeddedDirectory {
  _ScriptEmbeddedDirectory(this.entry, this.issue);
  final TavernScriptBookDirectoryEntry? entry;
  final TavernScriptIssue? issue;
}

class _ScriptBookDirectoryState {
  bool loaded = false;
  String? standaloneVersion;
  final standalone = <String, TavernScriptBookDirectoryEntry>{};
  final issues = <String, TavernScriptIssue>{};
  final embedded = <String, _ScriptEmbeddedDirectory>{};
}

class _ScriptBookDirectoryView {
  _ScriptBookDirectoryView(this.snapshot, this.standaloneVersion, this.characterIds, this.embeddedVersions);
  final TavernScriptBookDirectorySnapshot snapshot;
  final String standaloneVersion;
  final List<String> characterIds;
  final Map<String, String> embeddedVersions;
}

extension _ScriptBookDirectory on _ScriptCoordinator {
  void _checkScriptBookContext(_ScriptContextState context, String operation) {
    if (!identical(_context(context.value.id), context)) {
      throw _scriptError(
        TavernScriptErrorCode.closedContext,
        operation,
        'The context instance changed.',
        contextId: context.value.id,
      );
    }
  }

  String? _scriptBookObservedVersion(String key) {
    final value = scriptResources.observations[key];
    return value == null ? null : '$epoch:resource:$key:${value.revision}';
  }

  TavernScriptIssue _bookDirectoryIssue(String handle, Object error) {
    final failure = _scriptFailure(error);
    return TavernScriptIssue(
      code: failure.code.name,
      message: failure.message,
      committed: false,
      stage: 'bookDirectory',
      details: {'handle': handle},
    );
  }

  void _updateStandaloneDirectoryVersion() {
    final state = scriptResources.directory;
    if (!state.loaded) {
      return;
    }
    final ids = state.standalone.keys.toList()..sort();
    final issueKeys = state.issues.keys.toList()..sort();
    state.standaloneVersion = _resourceVersion('bookDirectory:standalone', {
      'books': [for (final id in ids) state.standalone[id]!.toJson()],
      'issues': [for (final key in issueKeys) _scriptDirectoryIssueJson(state.issues[key]!)],
    });
  }

  void _observeStandaloneDirectory(String id, Map<String, Object?>? raw, String? sourceName, {Object? error}) {
    final state = scriptResources.directory;
    final before = state.standalone[id]?.toJson();
    final oldIssue = state.issues[id];
    if (raw == null && error == null) {
      state.standalone.remove(id);
      state.issues.remove(id);
    } else {
      state.standalone[id] = TavernScriptBookDirectoryEntry(
        ref: TavernScriptBookRef.standalone(bookId: id),
        name: raw?['name'] is String ? raw!['name']! as String : null,
        stWorldName: sourceName,
        readable: error == null,
      );
      if (error == null) {
        state.issues.remove(id);
      } else {
        state.issues[id] = _bookDirectoryIssue('standalone:$id', error);
      }
    }
    if (!_stateJsonEqual(before, state.standalone[id]?.toJson()) ||
        !_stateJsonEqual(
          oldIssue == null ? null : _scriptDirectoryIssueJson(oldIssue),
          state.issues[id] == null ? null : _scriptDirectoryIssueJson(state.issues[id]!),
        )) {
      _updateStandaloneDirectoryVersion();
    }
  }

  void scriptBookDirectoryCardCommitted(String id, Map<String, Object?>? data, {Object? error}) {
    final present = data?.containsKey('character_book') == true;
    final raw = data?['character_book'];
    final failure =
        error ??
        (present && raw is! Map<String, Object?>
            ? _scriptError(
                TavernScriptErrorCode.shapeMismatch,
                'bookDirectory',
                'The embedded book root is not an object.',
              )
            : null);
    final entry = present
        ? TavernScriptBookDirectoryEntry(
            ref: TavernScriptBookRef.embedded(characterId: id),
            name: raw is Map<String, Object?> && raw['name'] is String ? raw['name']! as String : null,
            readable: failure == null,
          )
        : null;
    final issue = failure == null ? null : _bookDirectoryIssue('embedded:$id', failure);
    scriptResources.directory.embedded[id] = _ScriptEmbeddedDirectory(entry, issue);
    _resourceVersion('bookDirectoryEmbedded:$id', {
      'book': entry?.toJson(),
      'issue': issue == null ? null : _scriptDirectoryIssueJson(issue),
    });
  }

  Future<void> _ensureStandaloneDirectory() async {
    final state = scriptResources.directory;
    if (state.loaded) {
      return;
    }
    state.standalone.clear();
    state.issues.clear();
    final folder = Directory('${engine.directory.path}/lorebooks');
    try {
      await for (final file in folder.list(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.json')) {
          continue;
        }
        final filename = file.uri.pathSegments.last;
        final id = filename.substring(0, filename.length - 5);
        try {
          _requireBookId(id);
        } on ArgumentError catch (error) {
          state.issues['file:$filename'] = _bookDirectoryIssue(filename, error);
          continue;
        }
        try {
          final value = await _scriptReadStandaloneNow(id);
          _observeStandaloneDirectory(id, value?.raw, value?.sourceName);
        } on FormatException catch (error) {
          _observeStandaloneDirectory(id, null, null, error: error);
        } on TavernScriptException catch (error) {
          if (error.code != TavernScriptErrorCode.invalidJson && error.code != TavernScriptErrorCode.shapeMismatch) {
            rethrow;
          }
          _observeStandaloneDirectory(id, null, null, error: error);
        }
      }
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 2 && (!Platform.isWindows || code != 3)) {
        rethrow;
      }
    }
    state.loaded = true;
    _updateStandaloneDirectoryVersion();
  }

  List<String> _scriptDirectoryCharacterIds(_ScriptContextState context) {
    final ids = <String>{?context.value.characterId};
    final chatId = context.value.chatId;
    if (chatId != null) {
      final chat = engine._store.chat(chatId);
      final group = engine._store.groupChat(chatId);
      if (group == null) {
        ids.add(chat.characterId);
      } else {
        ids.add(group.hostCharacterId);
        ids.addAll(group.members.map((member) => member.characterId));
      }
    }
    return ids.toList()..sort();
  }

  Future<_ScriptBookDirectoryView> _scriptBookDirectoryView(_ScriptContextState context) async {
    await engine._bookOperation(_ensureStandaloneDirectory);
    final state = scriptResources.directory;
    final standaloneVersion = state.standaloneVersion!;
    final books = state.standalone.values.toList();
    final issues = state.issues.values.toList();
    final ids = _scriptDirectoryCharacterIds(context);
    final embeddedVersions = <String, String>{};
    for (final id in ids) {
      if (!state.embedded.containsKey(id)) {
        try {
          final found = await engine._library.readAuthority(id, (data) {
            scriptBookDirectoryCardCommitted(id, data);
            return true;
          });
          if (found != true) {
            scriptBookDirectoryCardCommitted(id, null);
          }
        } on FormatException catch (error) {
          scriptBookDirectoryCardCommitted(id, null, error: error);
        } on JsonUnsupportedObjectError {
          scriptBookDirectoryCardCommitted(
            id,
            null,
            error: _scriptError(
              TavernScriptErrorCode.invalidJson,
              'bookDirectory',
              'The character authority contains a non-JSON value.',
            ),
          );
        } on TavernScriptException catch (error) {
          if (error.code != TavernScriptErrorCode.invalidJson && error.code != TavernScriptErrorCode.shapeMismatch) {
            rethrow;
          }
          scriptBookDirectoryCardCommitted(id, null, error: error);
        }
      }
      final embedded = state.embedded[id]!;
      if (embedded.entry != null) {
        books.add(embedded.entry!);
      }
      if (embedded.issue != null) {
        issues.add(embedded.issue!);
      }
      embeddedVersions[id] = _scriptBookObservedVersion('bookDirectoryEmbedded:$id')!;
    }
    books.sort((a, b) => a.handle.compareTo(b.handle));
    issues.sort((a, b) => jsonEncode(a.details).compareTo(jsonEncode(b.details)));
    final version = _resourceVersion('bookDirectory:${context.value.id}', {
      'standalone': standaloneVersion,
      'embedded': embeddedVersions,
    });
    return _ScriptBookDirectoryView(
      TavernScriptBookDirectorySnapshot(version: version, books: books, issues: issues),
      standaloneVersion,
      ids,
      embeddedVersions,
    );
  }

  bool _scriptBookDirectoryViewCurrent(_ScriptContextState context, _ScriptBookDirectoryView view) =>
      scriptResources.directory.standaloneVersion == view.standaloneVersion &&
      _stateJsonEqual(_scriptDirectoryCharacterIds(context), view.characterIds) &&
      view.embeddedVersions.entries.every(
        (entry) => _scriptBookObservedVersion('bookDirectoryEmbedded:${entry.key}') == entry.value,
      );

  Future<TavernScriptBookDirectorySnapshot> _getBookDirectory(String contextId) async {
    final context = _context(contextId);
    while (true) {
      final view = await _scriptBookDirectoryView(context);
      _checkScriptBookContext(context, 'getBookDirectory');
      if (_scriptBookDirectoryViewCurrent(context, view)) {
        return view.snapshot;
      }
    }
  }

  Future<TavernScriptBookRef> _resolveBook(String contextId, String nameOrHandle) async {
    final directory = await _getBookDirectory(contextId);
    for (final entry in directory.books) {
      if (entry.handle == nameOrHandle) {
        return entry.ref;
      }
    }
    final reserved = nameOrHandle.startsWith('standalone:') || nameOrHandle.startsWith('embedded:');
    final matches = reserved || nameOrHandle.isEmpty
        ? <TavernScriptBookDirectoryEntry>[]
        : directory.books.where((entry) => entry.name == nameOrHandle || entry.stWorldName == nameOrHandle).toList();
    if (matches.length > 1) {
      throw _scriptError(
        TavernScriptErrorCode.ambiguousName,
        'resolveBook',
        'More than one book has this exact name. Use its stable handle.',
        contextId: contextId,
      );
    }
    if (matches.isEmpty) {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'resolveBook',
        'No book in this directory matches the identity.',
        contextId: contextId,
      );
    }
    return matches.single.ref;
  }

  Future<TavernScriptBookSnapshot> _createScriptBook(String contextId, String name, TavernJsonObject raw) async {
    final context = _context(contextId);
    final captured = _captureScriptObject(raw);
    if (!captured.containsKey('name')) {
      captured['name'] = name;
    }
    final book = WorldInfoBook.fromJson(id: 'create', source: WorldInfoSource.global, json: captured).raw;
    var adopted = false;
    TavernScriptBookSnapshot? result;
    String? id;
    try {
      await engine._bookOperation(() async {
        _checkScriptBookContext(context, 'createBook');
        final random = Random.secure();
        String generated;
        do {
          generated = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        } while (await FileSystemEntity.type(
              '${engine.directory.path}/lorebooks/$generated.json',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound);
        id = generated;
        await engine._writeBookNow(
          generated,
          book,
          stWorldName: name,
          requireMissing: true,
          check: () => _checkScriptBookContext(context, 'createBook'),
          onRenamed: () {
            adopted = true;
            result = TavernScriptBookSnapshot(
              ref: TavernScriptBookRef.standalone(bookId: generated),
              version: _resourceVersion('standalone:$generated', book),
              book: book,
            );
          },
        );
      });
      resourcesChanged();
      await _refreshHelperResourceContexts();
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'createBook', contextId, {
          'targetKind': 'book',
          'bookId': ?id,
          'version': ?result?.version,
        }),
        stack,
      );
    }
  }

  Future<void> _deleteScriptBook(String contextId, TavernScriptBookRef ref, {required String expectedVersion}) async {
    final context = _context(contextId);
    var adopted = false;
    void check() => _checkScriptBookContext(context, 'deleteBook');
    try {
      switch (ref) {
        case TavernScriptStandaloneBookRef(:final bookId):
          await engine._bookOperation(() async {
            final current = await _scriptReadStandaloneNow(bookId);
            check();
            if (current == null) {
              throw _scriptError(TavernScriptErrorCode.notFound, 'deleteBook', 'The book does not exist.');
            }
            _resourceExpected(expectedVersion, current.version, 'deleteBook');
            await engine._deleteBookNow(
              bookId,
              check: check,
              onDeleted: () {
                adopted = true;
              },
            );
          });
        case TavernScriptEmbeddedBookRef(:final characterId):
          void characterCheck() {
            check();
            if (engine._deletingCharacters.contains(characterId)) {
              throw _scriptError(TavernScriptErrorCode.busy, 'deleteBook', 'Character deletion is active.');
            }
          }
          final stored = await engine._libraryOperation(
            () => engine._library.updateAuthority(
              characterId,
              (data) {
                characterCheck();
                if (!data.containsKey('character_book')) {
                  throw _scriptError(
                    TavernScriptErrorCode.notFound,
                    'deleteBook',
                    'The character has no embedded book.',
                  );
                }
                _resourceExpected(
                  expectedVersion,
                  _resourceVersion('embedded:$characterId', data['character_book']),
                  'deleteBook',
                );
                return _copy(data)..remove('character_book');
              },
              check: characterCheck,
              onCommitted: (_) {
                adopted = true;
              },
            ),
          );
          engine._cacheCharacterDetail(characterId, Future.value(stored));
          engine._notifyLists();
      }
      resourcesChanged();
      await _refreshHelperResourceContexts();
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'deleteBook', contextId, {'targetKind': 'book', 'ref': ref.toJson(), 'present': false}),
        stack,
      );
    }
  }
}

Map<String, Object?> _scriptDirectoryIssueJson(TavernScriptIssue issue) => {
  'code': issue.code,
  'message': issue.message,
  'committed': issue.committed,
  'stage': ?issue.stage,
  'details': issue.details,
};

Map<String, Object?> _scriptBookDirectoryJson(TavernScriptBookDirectorySnapshot view) => {
  'version': view.version,
  'books': [for (final book in view.books) book.toJson()],
  'issues': [for (final issue in view.issues) _scriptDirectoryIssueJson(issue)],
};

Map<String, Object?> _scriptBookBindingsJson(TavernScriptBookBindingsSnapshot view) => {
  'scope': view.scope.name,
  'targetId': ?view.targetId,
  'version': view.version,
  'primary': view.primary?.toJson(),
  'additional': [for (final ref in view.additional) ref.toJson()],
  'inherited': [for (final ref in view.inherited) ref.toJson()],
};
