part of 'engine.dart';

// The twelve native settings are projected through their existing parser.
// overflow_alert is a stored compatibility preference, not a scanner switch.
const _scriptWorldInfoFields = <String, String>{
  'scan_depth': 'world_info_depth',
  'context_percentage': 'world_info_budget',
  'budget_cap': 'world_info_budget_cap',
  'min_activations': 'world_info_min_activations',
  'max_depth': 'world_info_min_activations_depth_max',
  'max_recursion_steps': 'world_info_max_recursion_steps',
  'insertion_strategy': 'world_info_character_strategy',
  'include_names': 'world_info_include_names',
  'recursive': 'world_info_recursive',
  'case_sensitive': 'world_info_case_sensitive',
  'match_whole_words': 'world_info_match_whole_words',
  'use_group_scoring': 'world_info_use_group_scoring',
  'overflow_alert': 'overflow_alert',
};
const _scriptWorldInfoIntegers = <String>{
  'scan_depth',
  'budget_cap',
  'min_activations',
  'max_depth',
  'max_recursion_steps',
};

extension _ScriptHelperSettings on _ScriptCoordinator {
  TavernScriptWorldInfoSettingsSnapshot _scriptWorldInfoSettingsView(Map<String, Object?> document) {
    final settings = _scriptMapView(document['settings']);
    final raw = _scriptMapView(settings['worldInfo']);
    final native = WorldInfoSettings.fromJson(raw);
    final value = <String, Object?>{
      'selected_global_lorebooks': [
        for (final id in _strings(_scriptMapView(settings['lorebooks'])['global'])) 'standalone:$id',
      ],
      'scan_depth': native.scanDepth,
      'context_percentage': native.budgetPercent,
      'budget_cap': native.budgetCap,
      'min_activations': native.minActivations,
      'max_depth': native.minActivationsDepthMax,
      'max_recursion_steps': native.maxRecursionSteps,
      'insertion_strategy': switch (native.strategy) {
        WorldInfoStrategy.evenly => 'evenly',
        WorldInfoStrategy.characterFirst => 'character_first',
        WorldInfoStrategy.globalFirst => 'global_first',
      },
      'include_names': native.includeNames,
      'recursive': native.recursive,
      'case_sensitive': native.caseSensitive,
      'match_whole_words': native.matchWholeWords,
      'use_group_scoring': native.useGroupScoring,
      'overflow_alert': raw['overflow_alert'] is bool ? raw['overflow_alert'] : false,
    };
    return TavernScriptWorldInfoSettingsSnapshot(version: _resourceVersion('worldInfoSettings', value), value: value);
  }

  Future<TavernScriptWorldInfoSettingsSnapshot> _updateWorldInfoSettings(
    String contextId,
    TavernJsonObject patch, {
    String? expectedVersion,
  }) async {
    final context = _context(contextId);
    final captured = _captureScriptObject(patch);
    for (final entry in captured.entries) {
      if (!_scriptWorldInfoFields.containsKey(entry.key)) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'updateWorldInfoSettings',
          'Unknown world-info setting.',
          contextId: contextId,
          fieldPath: entry.key,
        );
      }
      final value = entry.value;
      final valid = entry.key == 'insertion_strategy'
          ? value == 'evenly' || value == 'character_first' || value == 'global_first'
          : entry.key == 'context_percentage'
          ? value is num && value.isFinite
          : _scriptWorldInfoIntegers.contains(entry.key)
          ? value is int
          : value is bool;
      if (!valid) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'updateWorldInfoSettings',
          'Invalid world-info setting value.',
          contextId: contextId,
          fieldPath: entry.key,
        );
      }
    }
    var adopted = false;
    TavernScriptWorldInfoSettingsSnapshot? result;
    try {
      await engine._presetOperation(
        () => engine._settingsDocument((document) async {
          _checkHelperSettingsContext(context);
          final before = _scriptWorldInfoSettingsView(document);
          _resourceExpected(expectedVersion, before.version, 'updateWorldInfoSettings');
          if (captured.isEmpty) {
            result = before;
            return;
          }
          final settings = _optionalObject(document, 'settings');
          final world = _optionalObject(settings, 'worldInfo');
          for (final entry in captured.entries) {
            world[_scriptWorldInfoFields[entry.key]!] = entry.key == 'insertion_strategy'
                ? switch (entry.value) {
                    'character_first' => 1,
                    'global_first' => 2,
                    _ => 0,
                  }
                : entry.value;
          }
          settings['worldInfo'] = world;
          final next = _copy(document)..['settings'] = settings;
          await engine._commitSettingsDocument(
            next,
            check: () => _checkHelperSettingsContext(context),
            onCommitted: () {
              adopted = true;
              engine._document['settings'] = _copy(settings);
              result = _scriptWorldInfoSettingsView(next);
            },
          );
        }),
      );
      if (adopted) {
        await engine._directors.settingsChanged(null);
        await _refreshHelperResourceContexts();
      }
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'updateWorldInfoSettings', contextId, {
          'targetKind': 'worldInfoSettings',
          'version': ?result?.version,
        }),
        stack,
      );
    }
  }

  Future<TavernScriptButtonsSnapshot?> _scriptButtonsView(_ScriptContextState context) async {
    final owner = context.value.script;
    if (owner == null) {
      return null;
    }
    _checkOwnerIdentity(owner);
    final _ScriptRawVariable raw;
    switch (owner.kind) {
      case TavernScriptOwnerKind.global:
        raw = await engine._settingsDocument((document) async => _globalScriptButtons(document, owner));
      case TavernScriptOwnerKind.character:
        final found = await engine._library.readRuntimeAuthority(
          owner.assetId!,
          (data) => _ownedScriptButtons(data, owner),
        );
        if (found == null) {
          throw _scriptError(TavernScriptErrorCode.notFound, 'scriptButtons', 'Script character not found.');
        }
        raw = found;
      case TavernScriptOwnerKind.preset:
        raw = await engine._presetOperation(() => _ownedScriptButtons(engine._presetScriptOwnerRaw(owner), owner));
    }
    _checkHelperSettingsContext(context);
    return _scriptButtonsSnapshot(owner, raw);
  }

  Future<TavernScriptButtonsSnapshot> _replaceScriptButtons(
    String contextId,
    List<TavernScriptButton> buttons, {
    String? expectedVersion,
  }) async {
    final context = _context(contextId);
    final owner = context.value.script;
    if (owner == null) {
      throw _scriptError(
        TavernScriptErrorCode.noContext,
        'replaceScriptButtons',
        'No persistent script owner is bound.',
        contextId: contextId,
      );
    }
    _checkOwnerIdentity(owner);
    final captured = List<TavernScriptButton>.of(buttons);
    var adopted = false;
    TavernScriptButtonsSnapshot? result;
    List<Object?> prepare(_ScriptRawVariable raw) {
      _checkHelperSettingsContext(context);
      final old = _scriptButtonRows(owner, raw);
      _resourceExpected(expectedVersion, _scriptButtonsVersion(owner, raw), 'replaceScriptButtons');
      return _replaceScriptButtonRows(old, captured);
    }

    void accept(_ScriptRawVariable raw) {
      adopted = true;
      result = _scriptButtonsSnapshot(owner, raw);
    }

    try {
      switch (owner.kind) {
        case TavernScriptOwnerKind.global:
          await engine._settingsDocument((document) async {
            final container = _optionalObject(document, 'scriptButtons');
            final rows = prepare(_fieldVariable(container, owner.scriptId));
            container[owner.scriptId] = rows;
            final next = _copy(document)..['scriptButtons'] = container;
            await engine._commitSettingsDocument(
              next,
              check: () => _checkHelperSettingsContext(context),
              onCommitted: () {
                adopted = true;
                engine._document['scriptButtons'] = _copy(container);
                engine._globalScriptsChanged.add(null);
                engine._scriptCatalogChanged.add(null);
                accept(_globalScriptButtons(next, owner));
              },
            );
          });
        case TavernScriptOwnerKind.character:
          void check() {
            _checkHelperSettingsContext(context);
            if (engine._deletingCharacters.contains(owner.assetId!)) {
              throw _scriptError(TavernScriptErrorCode.busy, 'replaceScriptButtons', 'Character deletion is active.');
            }
          }
          final stored = await engine._libraryOperation(
            () => engine._library.updateAuthority(
              owner.assetId!,
              (data) {
                check();
                final extensions = _optionalObject(data, 'extensions');
                final entry = _scriptEntry(extensions, owner.scriptId);
                final raw = _fieldVariable(entry, 'button');
                final rows = prepare(raw);
                final button = _optionalObject(entry, 'button');
                button['buttons'] = rows;
                entry['button'] = button;
                return {...data, 'extensions': extensions};
              },
              check: check,
              onCommitted: (actual) {
                accept(_ownedScriptButtons(actual, owner));
              },
            ),
          );
          engine._cacheCharacterDetail(owner.assetId!, Future.value(stored));
          engine._notifyLists();
        case TavernScriptOwnerKind.preset:
          await engine._presetOperation(() async {
            late _ScriptRawVariable actual;
            await engine._editPresetScriptOwner(
              owner,
              (entry) {
                final rows = prepare(_fieldVariable(entry, 'button'));
                final button = _optionalObject(entry, 'button');
                button['buttons'] = rows;
                entry['button'] = button;
                actual = _fieldVariable(entry, 'button');
              },
              check: () => _checkHelperSettingsContext(context),
              onCommitted: () {
                accept(actual);
              },
            );
          });
      }
      await _refreshHelperResourceContexts();
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'replaceScriptButtons', contextId, {
          'targetKind': 'scriptButtons',
          'owner': owner.toJson(),
          'version': ?result?.version,
        }),
        stack,
      );
    }
  }

  void _checkHelperSettingsContext(_ScriptContextState context) {
    if (!identical(_context(context.value.id), context)) {
      throw _scriptError(TavernScriptErrorCode.closedContext, 'helperSettings', 'The context instance changed.');
    }
  }

  Future<void> _refreshHelperResourceContexts() async {
    for (final context in contexts.values.toList()) {
      if (!context.closed) {
        await _refreshContext(context);
      }
    }
  }

  TavernScriptButtonsSnapshot _scriptButtonsSnapshot(TavernScriptOwner owner, _ScriptRawVariable raw) {
    final rows = _scriptButtonRows(owner, raw);
    return TavernScriptButtonsSnapshot(
      owner: owner,
      version: _scriptButtonsVersion(owner, raw),
      buttons: [
        for (final row in rows) TavernScriptButton(name: row['name']! as String, visible: row['visible']! as bool),
      ],
    );
  }

  String _scriptButtonsVersion(TavernScriptOwner owner, _ScriptRawVariable raw) =>
      _resourceVersion(_scriptButtonsResourceKey(owner), _variableFingerprint(raw));

  bool _scriptButtonsViewCurrent(TavernScriptButtonsSnapshot view) {
    final key = _scriptButtonsResourceKey(view.owner);
    final observed = scriptResources.observations[key];
    return observed != null && view.version == '$epoch:resource:$key:${observed.revision}';
  }

  Iterable<TavernScriptOwner> _helperScriptOwners(TavernScriptOwnerKind kind, {String? assetId}) sync* {
    final seen = <TavernScriptOwner>{};
    for (final context in contexts.values) {
      final owner = context.value.script;
      if (!context.closed && owner != null && owner.kind == kind && owner.assetId == assetId && seen.add(owner)) {
        yield owner;
      }
    }
  }

  void _observeHelperButtons(TavernScriptOwner owner, _ScriptRawVariable Function() read) {
    try {
      _scriptButtonsVersion(owner, read());
    } catch (error) {
      _resourceVersion(_scriptButtonsResourceKey(owner), _unavailableVariableFingerprint(error));
    }
  }

  void scriptHelperDocumentCommitted(Map<String, Object?> document) {
    _scriptWorldInfoSettingsView(document);
    for (final owner in _helperScriptOwners(TavernScriptOwnerKind.global)) {
      _observeHelperButtons(owner, () => _globalScriptButtons(document, owner));
    }
    for (final context in contexts.values) {
      final owner = context.value.script;
      if (!context.closed &&
          owner != null &&
          owner.presetCarrier?.kind == TavernScriptPresetCarrierKind.inline &&
          owner.presetCarrier!.chatId == null) {
        _observeHelperButtons(
          owner,
          () => _ownedScriptButtons(engine._presetScriptOwnerRaw(owner, document: document), owner),
        );
      }
    }
  }

  void scriptHelperCardCommitted(String id, Map<String, Object?> actualData) {
    for (final owner in _helperScriptOwners(TavernScriptOwnerKind.character, assetId: id)) {
      _observeHelperButtons(owner, () => _ownedScriptButtons(actualData, owner));
    }
  }

  void scriptHelperCardRemoved(String id) {
    for (final owner in _helperScriptOwners(TavernScriptOwnerKind.character, assetId: id)) {
      _observeHelperButtons(
        owner,
        () => throw _scriptError(TavernScriptErrorCode.notFound, 'scriptButtons', 'Script character not found.'),
      );
    }
  }

  void scriptHelperPresetsCommitted({bool carriersOnly = false}) {
    final owners = <TavernScriptOwner>{
      for (final context in contexts.values)
        if (!context.closed &&
            context.value.script?.kind == TavernScriptOwnerKind.preset &&
            (!carriersOnly || context.value.script!.presetCarrier != null))
          context.value.script!,
    };
    for (final owner in owners) {
      _observeHelperButtons(owner, () => _ownedScriptButtons(engine._presetScriptOwnerRaw(owner), owner));
    }
  }
}

String _scriptButtonsResourceKey(TavernScriptOwner owner) =>
    'scriptButtons:${jsonEncode([owner.kind.name, owner.assetId, owner.scriptId, owner.presetCarrier?.toJson()])}';

_ScriptRawVariable _globalScriptButtons(Map<String, Object?> document, TavernScriptOwner owner) =>
    _fieldVariable(_readOptionalObject(document, 'scriptButtons'), owner.scriptId);

_ScriptRawVariable _ownedScriptButtons(Map<String, Object?> data, TavernScriptOwner owner) =>
    _fieldVariable(_scriptEntry(_readOptionalObject(data, 'extensions'), owner.scriptId), 'button');

List<Map<String, Object?>> _scriptButtonRows(TavernScriptOwner owner, _ScriptRawVariable raw) {
  if (!raw.present) {
    return const [];
  }
  Object? value = raw.value;
  if (owner.kind != TavernScriptOwnerKind.global) {
    if (value is! Map<String, Object?>) {
      throw _scriptError(
        TavernScriptErrorCode.shapeMismatch,
        'scriptButtons',
        'The script button carrier is not an object.',
      );
    }
    if (!value.containsKey('buttons')) {
      return const [];
    }
    value = value['buttons'];
  }
  if (value is! List<Object?>) {
    throw _scriptError(TavernScriptErrorCode.shapeMismatch, 'scriptButtons', 'Script buttons must be an array.');
  }
  final rows = <Map<String, Object?>>[];
  for (final row in value) {
    if (row is! Map<String, Object?> || row['name'] is! String || row['visible'] is! bool) {
      throw _scriptError(
        TavernScriptErrorCode.shapeMismatch,
        'scriptButtons',
        'A script button must contain a string name and bool visible.',
      );
    }
    rows.add(row);
  }
  return rows;
}

List<Object?> _replaceScriptButtonRows(List<Map<String, Object?>> previous, List<TavernScriptButton> next) {
  // Replacement keeps caller order and duplicate names. Unknown fields follow
  // the corresponding occurrence of an existing name, not an invented ID.
  final old = <String, List<Map<String, Object?>>>{};
  for (final row in previous) {
    old.putIfAbsent(row['name']! as String, () => []).add(row);
  }
  final positions = <String, int>{};
  final result = <Object?>[];
  for (final button in next) {
    final index = positions[button.name] ?? 0;
    positions[button.name] = index + 1;
    final matches = old[button.name];
    result.add(<String, Object?>{
      if (matches != null && index < matches.length) ..._copy(matches[index]),
      'name': button.name,
      'visible': button.visible,
    });
  }
  return result;
}
