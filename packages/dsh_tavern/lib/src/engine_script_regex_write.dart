part of 'engine.dart';

extension _ScriptRegexWriter on _ScriptCoordinator {
  Future<TavernScriptRegexWriteSnapshot> _readTavernRegexesForWrite(
    String contextId,
    TavernScriptRegexWriteTarget target,
  ) async {
    final context = _context(contextId);
    _checkRegexWriteTarget(target);
    final TavernScriptRegexWriteSnapshot result;
    switch (target.kind) {
      case TavernScriptRegexWriteKind.globalInline:
        result = await engine._presetOperation(
          () => engine._settingsDocument((document) async => _inlineRegexSnapshot(document)),
        );
      case TavernScriptRegexWriteKind.globalLibrary:
        final source = await engine._regexLibrary.readAuthoringSnapshot();
        result = _managedRegexSnapshot(source.document, present: source.present, rawText: source.rawText);
      case TavernScriptRegexWriteKind.character:
        final id = target.characterId!;
        final found = await engine._libraryOperation(
          () => engine._library.readAuthority(id, (data) => _characterRegexSnapshot(id, data)),
        );
        if (found == null) {
          throw _scriptError(
            TavernScriptErrorCode.notFound,
            'readTavernRegexesForWrite',
            'The character is unavailable.',
            contextId: contextId,
          );
        }
        result = found;
      case TavernScriptRegexWriteKind.preset:
        result = _presetRegexSnapshot(target, await _readScriptPreset(contextId, target.preset!));
    }
    _checkHelperSettingsContext(context);
    return result;
  }

  Future<TavernScriptRegexWriteSnapshot> _replaceTavernRegexes(
    String contextId,
    TavernScriptRegexWriteTarget target,
    List<TavernScriptRegexWriteItem> items, {
    required String expectedVersion,
  }) async {
    final context = _context(contextId);
    _checkRegexWriteTarget(target);
    final captured = [for (final item in items) (engineId: item.engineId, raw: _captureScriptObject(item.raw))];
    if (target.kind != TavernScriptRegexWriteKind.globalLibrary && captured.any((item) => item.engineId != null)) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'replaceTavernRegexes',
        'Only a managed library accepts engineId.',
        contextId: contextId,
      );
    }
    final diagnostics = <TavernRegexDiagnostic>[];
    if (target.kind != TavernScriptRegexWriteKind.globalLibrary) {
      for (final (index, item) in captured.indexed) {
        _checkHelperSettingsContext(context);
        diagnostics.add(await inspectRegexScript(item.raw, engine._regexWorker, path: '\$[$index]'));
        _checkHelperSettingsContext(context);
      }
    }
    final raw = [for (final item in captured) item.raw];
    var adopted = false;
    TavernScriptRegexWriteSnapshot? result;
    try {
      switch (target.kind) {
        case TavernScriptRegexWriteKind.globalInline:
          await engine._presetOperation(
            () => engine._settingsDocument((document) async {
              _checkHelperSettingsContext(context);
              final before = _inlineRegexSnapshot(document);
              _resourceExpected(expectedVersion, before.version, 'replaceTavernRegexes');
              final settings = _optionalObject(document, 'settings');
              final field = _rootInlineRegexField(settings);
              settings[field] = raw;
              final next = _copy(document)..['settings'] = settings;
              await engine._commitSettingsDocument(
                next,
                check: () {
                  _checkHelperSettingsContext(context);
                  _resourceExpected(
                    expectedVersion,
                    _inlineRegexSnapshot(engine._document).version,
                    'replaceTavernRegexes',
                  );
                },
                onCommitted: () {
                  adopted = true;
                  engine._document['settings'] = _copy(settings);
                  result = _inlineRegexSnapshot(next, diagnostics: diagnostics);
                },
              );
            }),
          );
          await engine._directors.settingsChanged(null);
        case TavernScriptRegexWriteKind.globalLibrary:
          final source = await engine._regexLibrary.readAuthoringSnapshot();
          _checkHelperSettingsContext(context);
          final before = _managedRegexSnapshot(source.document, present: source.present, rawText: source.rawText);
          _resourceExpected(expectedVersion, before.version, 'replaceTavernRegexes');
          final saved = await engine._regexLibrary.replaceScripts(
            captured,
            expectedPresent: source.present,
            expectedRawText: source.rawText,
            check: () => _checkHelperSettingsContext(context),
            onCommitted: (actual) {
              adopted = true;
              result = _managedRegexSnapshot(
                actual.document,
                present: true,
                rawText: actual.rawText,
                scripts: actual.scripts,
              );
            },
          );
          if (saved == null) {
            throw _scriptError(
              TavernScriptErrorCode.revisionConflict,
              'replaceTavernRegexes',
              'The regex library before-image changed.',
              contextId: contextId,
            );
          }
        case TavernScriptRegexWriteKind.character:
          final id = target.characterId!;
          void check() {
            _checkHelperSettingsContext(context);
            if (engine._deletingCharacters.contains(id)) {
              throw _scriptError(
                TavernScriptErrorCode.busy,
                'replaceTavernRegexes',
                'Character deletion is active.',
                contextId: contextId,
              );
            }
          }
          final stored = await engine._libraryOperation(
            () => engine._library.updateAuthority(
              id,
              (data) {
                check();
                final before = _characterRegexSnapshot(id, data);
                _resourceExpected(expectedVersion, before.version, 'replaceTavernRegexes');
                final extensions = _optionalObject(data, 'extensions');
                extensions['regex_scripts'] = raw;
                return {...data, 'extensions': extensions};
              },
              check: check,
              onCommitted: (actual) {
                adopted = true;
                result = _characterRegexSnapshot(id, actual, diagnostics: diagnostics);
              },
            ),
          );
          engine._cacheCharacterRecord(id, stored);
          engine._notifyLists();
        case TavernScriptRegexWriteKind.preset:
          // This delegate owns its real stored/RAM adoption and post-adoption errors.
          // A whole effective-preset replacement would bake sampling overrides in.
          final preset = await _replaceScriptPresetRegex(
            contextId,
            target.preset!,
            raw,
            expectedVersion: expectedVersion,
          );
          return _presetRegexSnapshot(target, preset, diagnostics: diagnostics);
      }
      await _refreshHelperResourceContexts();
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'replaceTavernRegexes', contextId, {
          'targetKind': 'regex',
          'target': target.toJson(),
          'version': ?result?.version,
        }),
        stack,
      );
    }
  }

  void _checkRegexWriteTarget(TavernScriptRegexWriteTarget target) {
    if (target.kind == TavernScriptRegexWriteKind.character && target.characterId!.isEmpty) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'regexTarget',
        'The character identity must be nonempty.',
      );
    }
    if (target.kind == TavernScriptRegexWriteKind.preset &&
        target.preset!.kind == TavernScriptPresetRefKind.stored &&
        target.preset!.presetId!.isEmpty) {
      throw _scriptError(TavernScriptErrorCode.invalidArgument, 'regexTarget', 'The preset identity must be nonempty.');
    }
  }

  List<TavernScriptRegexWriteItem> _regexWriteItems(Object? raw, String path) {
    if (raw == null) {
      return const [];
    }
    if (raw is! List<Object?> || raw.any((item) => item is! Map<String, Object?>)) {
      throw _scriptError(
        TavernScriptErrorCode.shapeMismatch,
        'readTavernRegexesForWrite',
        'The complete regex carrier must be an array of objects.',
        fieldPath: path,
      );
    }
    return [for (final item in raw) TavernScriptRegexWriteItem(raw: item! as Map<String, Object?>)];
  }

  List<TavernRegexDiagnostic> _regexShapeDiagnostics(List<TavernScriptRegexWriteItem> items) => [
    for (final (index, item) in items.indexed) ..._scriptRegexShapeDiagnostics(item.raw, index),
  ];

  TavernScriptRegexWriteSnapshot _inlineRegexSnapshot(
    Map<String, Object?> document, {
    List<TavernRegexDiagnostic>? diagnostics,
  }) {
    final settings = _optionalObject(document, 'settings');
    final field = _rootInlineRegexField(settings);
    final items = _regexWriteItems(settings[field], 'settings.$field');
    return TavernScriptRegexWriteSnapshot(
      target: const TavernScriptRegexWriteTarget.globalInline(),
      version: _resourceVersion('regexInline', _inlineRegexBefore(settings)),
      source: {
        'kind': 'inlineGlobal',
        'scope': 'global',
        'field': field,
        'present': settings.containsKey(field),
        'isNull': settings[field] == null,
      },
      items: items,
      diagnostics: diagnostics ?? _regexShapeDiagnostics(items),
    );
  }

  TavernScriptRegexWriteSnapshot _managedRegexSnapshot(
    Map<String, Object?> document, {
    required bool present,
    required String? rawText,
    List<TavernRegexScript>? scripts,
  }) {
    final records = scripts ?? RegexLibrary.decodeScripts(document);
    return TavernScriptRegexWriteSnapshot(
      target: const TavernScriptRegexWriteTarget.globalLibrary(),
      version: _resourceVersion('regexLibrary', {'present': present, 'rawText': rawText}),
      source: {'kind': 'managedGlobal', 'scope': 'global', 'field': 'scripts', 'present': present},
      items: [for (final record in records) TavernScriptRegexWriteItem(engineId: record.id, raw: record.raw)],
      diagnostics: [for (final record in records) ...record.diagnostics],
    );
  }

  TavernScriptRegexWriteSnapshot _characterRegexSnapshot(
    String id,
    Map<String, Object?> data, {
    List<TavernRegexDiagnostic>? diagnostics,
  }) {
    final extensions = _optionalObject(data, 'extensions');
    final items = _regexWriteItems(extensions['regex_scripts'], 'extensions.regex_scripts');
    return TavernScriptRegexWriteSnapshot(
      target: TavernScriptRegexWriteTarget.character(characterId: id),
      version: _resourceVersion('characterData:$id', data),
      source: {
        'kind': 'character',
        'characterId': id,
        'field': 'extensions.regex_scripts',
        'present': extensions.containsKey('regex_scripts'),
        'isNull': extensions['regex_scripts'] == null,
      },
      items: items,
      diagnostics: diagnostics ?? _regexShapeDiagnostics(items),
    );
  }

  TavernScriptRegexWriteSnapshot _presetRegexSnapshot(
    TavernScriptRegexWriteTarget target,
    TavernScriptPresetSnapshot preset, {
    List<TavernRegexDiagnostic>? diagnostics,
  }) {
    final extensions = _optionalObject(preset.raw, 'extensions');
    final items = _regexWriteItems(extensions['regex_scripts'], 'extensions.regex_scripts');
    return TavernScriptRegexWriteSnapshot(
      target: target,
      version: preset.version,
      source: {
        ...preset.source,
        'field': 'extensions.regex_scripts',
        'present': extensions.containsKey('regex_scripts'),
        'isNull': extensions['regex_scripts'] == null,
      },
      items: items,
      diagnostics: diagnostics ?? _regexShapeDiagnostics(items),
    );
  }
}

String _rootInlineRegexField(Map<String, Object?> settings) =>
    settings['globalRegexScripts'] != null || settings['regex'] == null ? 'globalRegexScripts' : 'regex';

Map<String, Object?> _inlineRegexBefore(Map<String, Object?> settings) => {
  for (final key in const ['globalRegexScripts', 'regex'])
    key: {'present': settings.containsKey(key), 'value': settings[key]},
};
