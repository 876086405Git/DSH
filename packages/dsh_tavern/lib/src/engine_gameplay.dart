part of 'engine.dart';

extension _GameplayResolutionOperations on TavernEngine {
  Future<TavernGameplayResolution> _resolveGameplayConfig(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
  }) => _authoringOperation(
    () async => (await _captureGameplayResolution(
      context,
      proposedScopes: proposedScopes,
      validateCurrentState: validateCurrentState,
    )).resolution,
  );

  Future<_GameplayResolutionCapture> _captureGameplayResolution(
    TavernGameplayContext context, {
    List<TavernPackScopePreview> proposedScopes = const [],
    bool validateCurrentState = false,
    Set<(String, String)> extraResources = const {},
  }) async {
    // Capture all caller-owned collections before the first asynchronous read.
    final proposed = _captureGameplayScopes(proposedScopes);
    final snapshot = _store.readGameplaySnapshot(
      chatId: context.chatId,
      characterId: context.characterId,
      readBindings: true,
      proposedScopes: proposed,
      readInitialState: validateCurrentState,
      extraResources: extraResources,
    );
    final scopes = snapshot.resolvedScopes;
    final bindingIds = <String>{};
    for (final scope in scopes) {
      for (final binding in scope.bindings) {
        if (!bindingIds.add(binding.bindingId)) {
          throw ArgumentError('A gameplay context requires unique binding identities across its scopes.');
        }
      }
    }
    final chat = snapshot.chat;
    final group = snapshot.group;
    final actorId = context.characterId;
    final hostId = chat?.characterId ?? actorId;
    final roster = [for (final member in group?.members ?? const <TavernGroupMember>[]) member.characterId];
    if (chat != null && actorId != hostId && (group == null || !roster.contains(actorId))) {
      throw ArgumentError('A gameplay context must use the chat host or an actual group member.');
    }
    final related = <String>{hostId, actorId, ...roster};
    for (final scope in scopes) {
      final valid = switch (scope.scope) {
        TavernGameplayScope.global => scope.targetId == null,
        TavernGameplayScope.character => related.contains(scope.targetId),
        TavernGameplayScope.chat => chat != null && scope.targetId == chat.id,
      };
      if (!valid) {
        throw ArgumentError('A proposed scope must belong to this real gameplay context.');
      }
    }
    final settingsIdentity = _document['settings'];
    final globalSettings = _map(settingsIdentity);
    final settingsText = jsonEncode(globalSettings);
    final presetWorking = _capturePresetWorking(chatId: chat?.id);
    final personaVersion = _personas.authoringVersion;
    final persona = _personas.resolve(personaId: chat?.personaId);
    final chatVersion = chat == null ? null : _store.displayVersion(chat.id);
    final metadata = chat == null
        ? <String, Object?>{}
        : snapshot.node == null
        ? {..._copy(chat.metadata), 'variables': _copy(chat.variables)}
        : _chatCodec.metadataForState(chat, snapshot.state!);
    final resources = <String, _AuthoringCapturedResource>{};
    Future<_AuthoringCapturedResource> capture(TavernAuthoringTarget target) async {
      final previous = resources[target.physicalResourceId];
      if (previous != null) {
        return previous;
      }
      final value = await _captureAuthoringResource(target);
      resources[target.physicalResourceId] = value;
      return value;
    }

    final cards = <String, _AuthoringCapturedResource>{};
    for (final id in related) {
      cards[id] = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id));
    }
    if (cards[hostId]!.character == null || cards[actorId]!.character == null) {
      throw const TavernImportError('角色不存在。');
    }
    for (final entry in snapshot.presetRows.entries) {
      final captured = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: entry.key));
      if (!_stateJsonEqual(captured.document, entry.value)) {
        _gameplayCaptureConflict();
      }
    }
    final regex = await capture(
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global'),
    );
    final managed = [
      for (final script in regex._regexRecords!) {...script.raw, if (!script.compatible) 'disabled': true},
    ];
    final settings = _personaSettings(
      _authoringContextSettings(
        globalSettings,
        chat,
        metadata,
        selectedPreset: snapshot.selectedPreset?.raw,
        selectedPresetId: snapshot.selectedPreset?.id,
        presetWorking: presetWorking,
        managedRegex: managed,
      ),
      persona,
    );
    final actorData = _effectiveCard(cards[actorId]!.character!.card.data, settings);
    final primaries = await _scripts._captureCharacterPrimaryBooks(settings, {
      if (group == null)
        actorId: actorData
      else
        for (final id in roster) id: cards[id]?.character?.card.data ?? <String, Object?>{},
    });
    final legacy = await _captureGameplayLegacyResources(
      actorId: actorId,
      actorData: actorData,
      cards: cards,
      group: group,
      chat: chat,
      settings: settings,
      metadata: metadata,
      personaId: persona.persona?.id,
      selectedPreset: snapshot.selectedPreset,
      currentPreset: {'source': presetWorking.source, 'token': presetWorking.token},
      primaries: primaries,
      regex: regex,
      capture: capture,
    );
    _GameplayCurrentValue? currentState;
    if (validateCurrentState && chat != null) {
      final input = _StateInput(snapshot.state!);
      currentState = (
        source: <String, Object?>{'kind': 'state', 'chatId': chat.id, 'nodeId': snapshot.node?.message.nodeId},
        valueExists: input.valueExists,
        value: input.value,
        issues: input.issues,
      );
    }
    void check() {
      if (!_scripts._characterBookNamesCurrent(primaries.values)) _gameplayCaptureConflict();
      if (!_presetWorkingCurrent(presetWorking)) {
        _gameplayCaptureConflict();
      }
      if (_authoringAuthority.domainId != snapshot.domainId ||
          !identical(_document['settings'], settingsIdentity) ||
          jsonEncode(_map(_document['settings'])) != settingsText ||
          !identical(_personas.authoringVersion, personaVersion) ||
          chat != null && !identical(_store.displayVersion(chat.id), chatVersion) ||
          _store.defaultPresetId != snapshot.defaultPresetId) {
        _gameplayCaptureConflict();
      }
      final current = _store.readGameplaySnapshot(
        chatId: context.chatId,
        characterId: context.characterId,
        readBindings: true,
        proposedScopes: proposed,
        readResources: false,
      );
      if (!_stateJsonEqual(_gameplayBindingIdentity(current), _gameplayBindingIdentity(snapshot))) {
        _gameplayCaptureConflict();
      }
    }

    await _recheckCapturedAuthoringResources(resources.values, check: check);
    final byScope = {for (final scope in scopes) (scope.scope, scope.targetId): scope};
    final ordered = <TavernPackScopePreview>[];
    void addScope(TavernGameplayScope kind, String? target) {
      final scope = byScope[(kind, target)];
      if (scope != null) {
        ordered.add(scope);
      }
    }

    addScope(TavernGameplayScope.global, null);
    // Roster order is also the native group WI order. A separate host is a
    // definition owner, without becoming an extra roster WI source.
    for (final id in <String>{...roster, hostId, actorId}) {
      addScope(TavernGameplayScope.character, id);
    }
    if (chat != null) {
      addScope(TavernGameplayScope.chat, chat.id);
    }
    final resolution = _composeGameplay(
      [
        for (final scope in ordered)
          for (final binding in scope.bindings)
            (
              scope: scope.scope,
              targetId: scope.targetId,
              binding: binding,
              version: snapshot.packs[(binding.packRef.installedPackId, binding.packRef.packVersion)]!.version,
              files: snapshot.packs[(binding.packRef.installedPackId, binding.packRef.packVersion)]!.files,
            ),
      ],
      cards,
      (
        request: context,
        hostCharacterId: hostId,
        rosterCharacterIds: roster,
        isGroup: group != null,
        legacyResources: legacy,
        currentState: currentState,
        validateCurrentState: validateCurrentState,
        regexEnabled: settings['regexEnabled'] != false,
        characterRegexEnabled:
            settings['regexEnabled'] != false &&
            settings['characterRegexEnabled'] != false &&
            !_strings(settings['disabledCharacterRegex']).contains(actorId),
      ),
      bindingIdentity: _gameplayBindingIdentity(snapshot),
    );
    return _GameplayResolutionCapture(
      resolution: resolution,
      snapshot: snapshot,
      resources: resources,
      cards: cards,
      check: check,
    );
  }
}

final class _GameplayResolutionCapture {
  const _GameplayResolutionCapture({
    required this.resolution,
    required this.snapshot,
    required this.resources,
    required this.cards,
    required this.check,
  });
  final TavernGameplayResolution resolution;
  final StoredGameplaySnapshot snapshot;
  final Map<String, _AuthoringCapturedResource> resources;
  final Map<String, _AuthoringCapturedResource> cards;
  final void Function() check;
}

List<TavernPackScopePreview> _captureGameplayScopes(List<TavernPackScopePreview> proposed) {
  final seenScopes = <(TavernGameplayScope, String?)>{};
  final seenBindings = <String>{};
  final result = <TavernPackScopePreview>[];
  for (final scope in proposed) {
    if (!seenScopes.add((scope.scope, scope.targetId))) {
      throw ArgumentError('A gameplay preview contains the same scope twice.');
    }
    final bindings = <TavernPackBindingPreview>[];
    for (final binding in scope.bindings) {
      if (!seenBindings.add(binding.bindingId)) {
        throw ArgumentError('A gameplay preview requires unique explicit binding identities.');
      }
      if (binding.aliases.containsKey('self') || binding.aliases.containsKey('card')) {
        throw ArgumentError('The source names self and card are reserved.');
      }
      bindings.add(
        TavernPackBindingPreview(
          bindingId: binding.bindingId,
          packRef: binding.packRef,
          enabled: binding.enabled,
          aliases: Map<String, String>.of(binding.aliases),
        ),
      );
    }
    result.add(TavernPackScopePreview(scope: scope.scope, targetId: scope.targetId, bindings: bindings));
  }
  return result;
}

Never _gameplayCaptureConflict() =>
    throw const TavernGameplayException(code: 'capture_conflict', message: 'A gameplay source changed during capture.');

Future<List<_GameplayLegacyResource>> _captureGameplayLegacyResources({
  required String actorId,
  required Map<String, Object?> actorData,
  required Map<String, _AuthoringCapturedResource> cards,
  required TavernGroupChat? group,
  required StoredChat? chat,
  required Map<String, Object?> settings,
  required Map<String, Object?> metadata,
  required String? personaId,
  required StoredPreset? selectedPreset,
  required Map<String, Object?> currentPreset,
  required Map<String, _CharacterPrimaryBook> primaries,
  required _AuthoringCapturedResource regex,
  required Future<_AuthoringCapturedResource> Function(TavernAuthoringTarget target) capture,
}) async {
  final result = <_GameplayLegacyResource>[];
  final bindings = _map(settings['lorebooks']);
  final activeName = metadata['world_info'];
  final activeId = activeName is String ? _map(chat?.settings['stLorebookIds'])[activeName] : null;
  for (final entry in primaries.entries) {
    if (entry.value.issue(entry.key) case final issue?) {
      result.add((
        kind: 'lorebook',
        bucket: WorldInfoSource.character.name,
        source: <String, Object?>{'kind': 'card', 'characterId': entry.key},
        resource: <String, Object?>{'worldName': entry.value.worldName, 'phase': 'linked'},
        present: false,
        raw: null,
        entries: <Map<String, Object?>>[],
        issues: <Map<String, Object?>>[_characterBookMissing(issue)],
      ));
    }
  }
  for (final bucket in WorldInfoSource.values) {
    final ids = <({String id, String? characterId, String? personaId})>[
      for (final id in _strings(bindings[bucket.name])) (id: id, characterId: null, personaId: null),
      if (bucket == WorldInfoSource.character)
        for (final entry in primaries.entries)
          for (final id in _characterLinkedBookIds(settings, entry.key, primary: entry.value))
            (id: id, characterId: entry.key, personaId: null),
      if (bucket == WorldInfoSource.persona && personaId != null)
        for (final id in _strings(_map(settings['personaLorebooks'])[personaId]))
          (id: id, characterId: null, personaId: personaId),
    ];
    for (final link in ids) {
      final captured = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: link.id));
      final document = captured.document;
      final source = <String, Object?>{
        'kind': 'lorebook',
        'bookId': link.id,
        'characterId': ?link.characterId,
        'personaId': ?link.personaId,
      };
      if (document == null) {
        result.add((
          kind: 'lorebook',
          bucket: bucket.name,
          source: source,
          resource: <String, Object?>{'bookId': link.id, 'phase': 'linked'},
          present: false,
          raw: null,
          entries: <Map<String, Object?>>[],
          issues: <Map<String, Object?>>[
            {'bookId': link.id, 'source': bucket.name, 'reason': 'missing'},
          ],
        ));
        continue;
      }
      final raw = _authoringBook(document);
      final envelope = !document.containsKey('entries') && document['format'] == 'dshgo-lorebook';
      final book = WorldInfoBook.fromJson(
        id: link.id,
        source: bucket,
        json: raw,
        stWorldName: activeId == link.id && activeName is String
            ? activeName
            : envelope
            ? document['stWorldName'] as String?
            : null,
      );
      result.add((
        kind: 'lorebook',
        bucket: bucket.name,
        source: source,
        resource: <String, Object?>{
          'bookId': link.id,
          'phase': 'linked',
          'stWorldName': book.stWorldName,
          'snapshotHash': _directorHash(captured.snapshot.toJson()),
          if (envelope && document.containsKey('importReport')) 'importReport': document['importReport'],
        },
        present: true,
        raw: book.raw,
        entries: _gameplayLegacyBookEntries(book),
        issues: <Map<String, Object?>>[],
      ));
    }
  }
  final embedded = group == null
      ? <String, Map<String, Object?>>{actorId: actorData}
      : {
          for (final member in group.members)
            if (cards[member.characterId]?.character case final character?) member.characterId: character.card.data,
        };
  for (final entry in embedded.entries) {
    final raw = entry.value['character_book'];
    if (raw is! Map<String, Object?>) {
      continue;
    }
    final book = WorldInfoBook.fromJson(id: '${entry.key}:card', source: WorldInfoSource.character, json: raw);
    result.add((
      kind: 'lorebook',
      bucket: 'character',
      source: <String, Object?>{'kind': 'card', 'characterId': entry.key},
      resource: <String, Object?>{'bookId': book.id, 'phase': 'embedded', 'stWorldName': book.stWorldName},
      present: true,
      raw: book.raw,
      entries: _gameplayLegacyBookEntries(book),
      issues: <Map<String, Object?>>[],
    ));
  }
  final enabled = settings['regexEnabled'] != false;
  final inlineKey = settings['globalRegexScripts'] != null ? 'globalRegexScripts' : 'regex';
  if (settings.containsKey(inlineKey)) {
    result.add(
      _gameplayLegacyRegexArray(
        settings[inlineKey],
        bucket: 'global',
        source: {'kind': 'settings', 'chatId': ?chat?.id},
        pointer: '/$inlineKey',
        enabled: enabled,
      ),
    );
  }
  if (regex.snapshot.present || regex._regexRecords!.isNotEmpty) {
    final entries = <Map<String, Object?>>[];
    for (final (index, item) in regex._regexRecords!.indexed) {
      final raw = item.raw;
      final execution = RegexScript.fromJson({...raw, if (!item.compatible) 'disabled': true});
      entries.add({
        'index': index,
        'pointer': '/scripts/$index/raw',
        'localId': item.id,
        'stId': execution.id,
        'raw': raw,
        'disabled': execution.disabled,
        'effective': enabled && !execution.disabled,
        'diagnostics': [for (final diagnostic in item.diagnostics) diagnostic.toJson()],
      });
    }
    result.add((
      kind: 'regex',
      bucket: 'managed',
      source: <String, Object?>{'kind': 'managedRegex'},
      resource: <String, Object?>{'enabled': enabled, 'snapshotHash': _directorHash(regex.snapshot.toJson())},
      present: regex.snapshot.present,
      raw: regex.document,
      entries: entries,
      issues: <Map<String, Object?>>[],
    ));
  }
  final presetRaw = _map(settings['preset']);
  final preset = (presetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(presetRaw)).settings;
  final presetExtensions = _map(preset['extensions']);
  if (presetExtensions.containsKey('regex_scripts')) {
    result.add(
      _gameplayLegacyRegexArray(
        presetExtensions['regex_scripts'],
        bucket: 'preset',
        source: {'kind': 'preset', 'presetId': selectedPreset?.id, 'current': currentPreset},
        pointer: '/extensions/regex_scripts',
        enabled: enabled && settings['presetRegexEnabled'] != false,
      ),
    );
  }
  final characterExtensions = _map(actorData['extensions']);
  if (characterExtensions.containsKey('regex_scripts')) {
    result.add(
      _gameplayLegacyRegexArray(
        characterExtensions['regex_scripts'],
        bucket: 'character',
        source: {'kind': 'card', 'characterId': actorId},
        pointer: '/extensions/regex_scripts',
        enabled:
            enabled &&
            settings['characterRegexEnabled'] != false &&
            !_strings(settings['disabledCharacterRegex']).contains(actorId),
      ),
    );
  }
  return result;
}

List<Map<String, Object?>> _gameplayLegacyBookEntries(WorldInfoBook book) {
  final pointers = Map<Map<String, Object?>, String>.identity();
  final raw = book.raw['entries'];
  if (raw is Map<String, Object?>) {
    for (final entry in raw.entries) {
      pointers[entry.value! as Map<String, Object?>] = '/entries/${_gameplayPointerToken(entry.key)}';
    }
  } else {
    for (final (index, value) in (raw! as List<Object?>).indexed) {
      pointers[value! as Map<String, Object?>] = '/entries/$index';
    }
  }
  return [
    for (final entry in book.entries)
      {'uid': entry.uid, 'pointer': pointers[entry.raw]!, 'raw': entry.raw, 'disabled': entry.disabled},
  ];
}

_GameplayLegacyResource _gameplayLegacyRegexArray(
  Object? raw, {
  required String bucket,
  required Map<String, Object?> source,
  required String pointer,
  required bool enabled,
}) {
  final entries = <Map<String, Object?>>[];
  if (raw is List<Object?>) {
    for (final (index, item) in raw.indexed) {
      if (item is! Map<String, Object?>) {
        continue;
      }
      final execution = RegexScript.fromJson(item);
      entries.add({
        'index': index,
        'pointer': '/$index',
        'stId': execution.id,
        'raw': item,
        'disabled': execution.disabled,
        'effective': enabled && !execution.disabled,
        'diagnostics': [for (final issue in _scriptRegexShapeDiagnostics(item, index)) issue.toJson()],
      });
    }
  }
  return (
    kind: 'regex',
    bucket: bucket,
    source: source,
    resource: <String, Object?>{'pointer': pointer, 'enabled': enabled},
    present: true,
    raw: raw,
    entries: entries,
    issues: <Map<String, Object?>>[],
  );
}
