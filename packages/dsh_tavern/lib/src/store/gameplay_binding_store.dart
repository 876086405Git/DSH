part of 'chat_store.dart';

const _gameplayBindingSchema = '''
CREATE TABLE gameplay_scopes (
  scope TEXT NOT NULL,
  target TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  PRIMARY KEY (scope, target)
);
CREATE TABLE gameplay_bindings (
  binding_id TEXT NOT NULL PRIMARY KEY,
  scope TEXT NOT NULL,
  target TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  installed_pack_id TEXT NOT NULL,
  pack_version TEXT NOT NULL,
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  removed INTEGER NOT NULL CHECK (removed IN (0, 1)),
  sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
  once_epoch INTEGER NOT NULL CHECK (once_epoch > 0),
  aliases_json TEXT NOT NULL,
  FOREIGN KEY (scope, target) REFERENCES gameplay_scopes(scope, target),
  FOREIGN KEY (installed_pack_id, pack_version)
    REFERENCES gameplay_pack_versions(installed_pack_id, pack_version)
);
CREATE INDEX gameplay_bindings_scope
  ON gameplay_bindings(scope, target, sort_order);
CREATE TABLE gameplay_source_ids (
  binding_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  resource_local_id TEXT NOT NULL,
  entry_local_id TEXT NOT NULL,
  stable_id TEXT NOT NULL UNIQUE,
  PRIMARY KEY (binding_id, kind, resource_local_id, entry_local_id),
  FOREIGN KEY (binding_id) REFERENCES gameplay_bindings(binding_id)
);
CREATE TABLE gameplay_effective_configs (
  config_id TEXT NOT NULL PRIMARY KEY,
  source_vector_json TEXT NOT NULL,
  effective_definitions_json TEXT NOT NULL,
  source_map_json TEXT NOT NULL
);
''';

const _gameplayWorldInfoPolicySchema = '''
ALTER TABLE gameplay_source_ids ADD COLUMN wi_policy_epoch INTEGER;
ALTER TABLE gameplay_source_ids ADD COLUMN wi_policy_json TEXT;
''';

const _gameplayCastImportsSchema = """
ALTER TABLE gameplay_bindings ADD COLUMN cast_imports_json TEXT NOT NULL DEFAULT '{}';
""";

/// Mutable only while one synchronous scope operation constructs its result.
final class _GameplayBindingDraft {
  _GameplayBindingDraft(TavernPackBinding value)
    : bindingId = value.bindingId,
      bindingRevision = value.bindingRevision,
      installedPackId = value.packRef.installedPackId,
      packVersion = value.packRef.packVersion,
      enabled = value.enabled,
      removed = value.removed,
      order = value.order,
      onceEpoch = value.onceEpoch,
      aliases = value.aliases,
      castImports = value.castImports,
      sourceMap = [for (final source in value.sourceMap) Map<String, Object?>.of(source)];

  final String bindingId;
  int bindingRevision;
  final String installedPackId;
  String packVersion;
  bool enabled;
  bool removed;
  int order;
  int onceEpoch;
  Map<String, String> aliases;
  Map<String, TavernCastImportRef> castImports;
  final List<Map<String, Object?>> sourceMap;
  final addedSources = <Map<String, Object?>>[];
  final updatedPolicies = <Map<String, Object?>>[];

  TavernPackBinding get value => TavernPackBinding(
    bindingId: bindingId,
    bindingRevision: bindingRevision,
    packRef: TavernPackVersionRef(installedPackId: installedPackId, packVersion: packVersion),
    enabled: enabled,
    removed: removed,
    order: order,
    onceEpoch: onceEpoch,
    aliases: aliases,
    castImports: castImports,
    sourceMap: sourceMap,
  );
}

extension GameplayBindingStore on ChatStore {
  /// A fixed read set. Borrow an existing SQL transaction without publishing
  /// or ending it; otherwise own a short read-only snapshot.
  TavernPackScopeSnapshot readGameplayScopeData(TavernPackScopeTarget scope) {
    _ensureOpen();
    final failure = _transactionFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    final owns = _db.autocommit;
    final managedDepth = _transactionDepth;
    var started = false;
    try {
      if (owns) {
        _db.execute('BEGIN DEFERRED');
        started = true;
      }
      final result = _readGameplayScopeData(scope);
      if (owns) {
        _db.execute('COMMIT');
      }
      return result;
    } catch (error, stackTrace) {
      try {
        if (owns && started && !_db.autocommit) {
          _db.execute('ROLLBACK');
        }
        if (!owns && managedDepth > 0 && _db.autocommit) {
          _transactionFailure ??= (error: error, stackTrace: stackTrace);
        }
      } catch (_) {
        _transactionFailure ??= (error: error, stackTrace: stackTrace);
      }
      rethrow;
    }
  }

  /// Used by the fixed gameplay snapshot reader on this same connection.
  TavernPackScopeSnapshot _readGameplayScopeData(TavernPackScopeTarget scope) {
    final key = _gameplayScopeKey(scope);
    final rows = _db.select('SELECT revision FROM gameplay_scopes WHERE scope = ? AND target = ?', key);
    final bindingRows = _db.select('''
      SELECT b.binding_id, b.revision, b.installed_pack_id,
        char(1) || b.pack_version AS pack_version,
        b.enabled, b.removed, b.sort_order, b.once_epoch, b.aliases_json, b.cast_imports_json,
        v.removed AS version_removed
      FROM gameplay_bindings b
      LEFT JOIN gameplay_pack_versions v
        ON v.installed_pack_id = b.installed_pack_id AND v.pack_version = b.pack_version
      WHERE b.scope = ? AND b.target = ?
      ORDER BY b.sort_order, b.rowid''', key);
    final bindings = <TavernPackBinding>[];
    final issues = _gameplayScopeTargetIssues(scope);
    for (final row in bindingRows) {
      final bindingId = row['binding_id'] as String;
      final binding = TavernPackBinding(
        bindingId: bindingId,
        bindingRevision: row['revision'] as int,
        packRef: TavernPackVersionRef(
          installedPackId: row['installed_pack_id'] as String,
          packVersion: ChatStore._unguardText(row['pack_version'])!,
        ),
        enabled: row['enabled'] == 1,
        removed: row['removed'] == 1,
        order: row['sort_order'] as int,
        onceEpoch: row['once_epoch'] as int,
        aliases: (jsonDecode(row['aliases_json'] as String) as Map<String, Object?>).cast<String, String>(),
        castImports: _gameplayCastImportRefs(jsonDecode(row['cast_imports_json'] as String) as Map<String, Object?>),
        sourceMap: _readGameplaySourceMap(bindingId),
      );
      bindings.add(binding);
      issues.addAll(_gameplayCastImportIssues(binding));
      if (row['version_removed'] != 0) {
        issues.add(_gameplayVersionIssue(binding, missing: row['version_removed'] == null));
      }
    }
    return TavernPackScopeSnapshot(
      scope: scope,
      token: TavernGameplayRevision(
        domainId: authoringDomainId,
        revision: rows.isEmpty ? 0 : rows.single['revision'] as int,
      ),
      bindings: bindings,
      issues: issues,
    );
  }

  TavernPackBindingReceipt updateGameplayBindingsData(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
    void Function(TavernPackBindingReceipt result)? onCommitted,
  }) {
    final request = <String, Object?>{
      'scope': scope.toJson(),
      'expected': expected.toJson(),
      'operationId': operationId,
      'edits': [for (final edit in edits) edit.toJson()],
    };
    final requestJson = jsonEncode(request);
    late TavernPackBindingReceipt result;
    return transaction(
      () {
        final recorded = _db.select(
          '''
        SELECT kind, request_json, result_json FROM gameplay_operations
        WHERE domain_id = ? AND operation_id = ?''',
          [expected.domainId, operationId],
        );
        if (recorded.isNotEmpty) {
          final row = recorded.single;
          if (row['kind'] != 'update_scope' || !_toolEqual(jsonDecode(row['request_json'] as String), request)) {
            throw const TavernGameplayException(
              code: 'operation_conflict',
              message: 'The operation identity has different parameters.',
            );
          }
          result = _gameplayBindingReceipt(jsonDecode(row['result_json'] as String) as Map<String, Object?>);
          return result;
        }
        if (operationId.isEmpty || expected.domainId.isEmpty || expected.revision < 0) {
          throw const TavernGameplayException(
            code: 'invalid_binding_edit',
            message: 'A scope operation requires a valid identity and revision.',
          );
        }
        if (expected.domainId != authoringDomainId) {
          throw const TavernGameplayException(
            code: 'revision_conflict',
            message: 'The captured scope belongs to another root domain.',
          );
        }
        final before = _readGameplayScopeData(scope);
        final key = <Object?>[scope.kind.name, scope.targetId ?? ''];
        if (expected.revision != before.token.revision) {
          throw const TavernGameplayException(code: 'revision_conflict', message: 'The gameplay scope has changed.');
        }
        final old = {for (final value in before.bindings) value.bindingId: value};
        final working = {for (final value in before.bindings) value.bindingId: _GameplayBindingDraft(value)};
        final order = [for (final value in before.bindings) value.bindingId];
        final created = <String, String>{};
        final selectedVersions = <String>{};
        final enableRequested = <String>{};
        final resets = <String>{};
        final castImportsRequested = <String>{};

        _GameplayBindingDraft requireBinding(String id) {
          final value = working[id];
          if (value == null) {
            throw const TavernGameplayException(
              code: 'binding_not_found',
              message: 'The binding is not in this scope.',
            );
          }
          return value;
        }

        for (final edit in edits) {
          switch (edit) {
            case TavernPackBindingCreate():
              if (edit.clientKey.isEmpty || created.containsKey(edit.clientKey)) {
                throw const TavernGameplayException(
                  code: 'invalid_binding_edit',
                  message: 'Create client keys must be nonempty and unique.',
                );
              }
              final id = ChatStore._newId();
              created[edit.clientKey] = id;
              order.add(id);
              working[id] = _GameplayBindingDraft(
                TavernPackBinding(
                  bindingId: id,
                  bindingRevision: 1,
                  packRef: edit.packRef,
                  enabled: edit.enabled,
                  removed: false,
                  order: order.length - 1,
                  onceEpoch: 1,
                  aliases: edit.aliases,
                  castImports: edit.castImports,
                  sourceMap: const [],
                ),
              );
              selectedVersions.add(id);
              castImportsRequested.add(id);
            case TavernPackBindingSelectVersion():
              final value = requireBinding(edit.bindingId);
              value.packVersion = edit.packVersion;
              selectedVersions.add(value.bindingId);
            case TavernPackBindingSetEnabled():
              final value = requireBinding(edit.bindingId);
              value.enabled = edit.enabled;
              if (edit.enabled) {
                value.removed = false;
                enableRequested.add(value.bindingId);
              }
            case TavernPackBindingReorder():
              final ids = edit.bindingIds;
              if (ids.length != working.length || ids.toSet().length != ids.length || !ids.every(working.containsKey)) {
                throw const TavernGameplayException(
                  code: 'invalid_binding_edit',
                  message: 'Reorder must contain every scope binding exactly once.',
                );
              }
              order
                ..clear()
                ..addAll(ids);
            case TavernPackBindingRemove():
              final value = requireBinding(edit.bindingId);
              value.enabled = false;
              value.removed = true;
            case TavernPackBindingResetOnce():
              final value = requireBinding(edit.bindingId);
              if (!resets.add(value.bindingId)) {
                throw const TavernGameplayException(
                  code: 'invalid_binding_edit',
                  message: 'A request may reset each binding at most once.',
                );
              }
              value.onceEpoch++;
            case TavernPackBindingSetAliases():
              requireBinding(edit.bindingId).aliases = edit.aliases;
            case TavernPackBindingSetCastImports():
              requireBinding(edit.bindingId).castImports = edit.imports;
              castImportsRequested.add(edit.bindingId);
          }
        }

        final issues = _gameplayScopeTargetIssues(scope);
        final resourceChanges = <Map<String, Object?>>[];
        for (var index = 0; index < order.length; index++) {
          final value = working[order[index]]!;
          value.order = index;
          final version = _readGameplayVersion(value.value.packRef);
          final requireAvailable =
              selectedVersions.contains(value.bindingId) ||
              enableRequested.contains(value.bindingId) && value.enabled && !value.removed;
          if (requireAvailable && (version == null || version.removed)) {
            throw TavernGameplayException(
              code: version == null ? 'version_not_found' : 'version_unavailable',
              message: 'The selected gameplay pack version is unavailable.',
            );
          }
          if (version == null || version.removed) {
            issues.add(_gameplayVersionIssue(value.value, missing: version == null));
          }
          for (final alias in value.aliases.entries) {
            if (alias.key.isEmpty || alias.key == 'self' || alias.key == 'card' || alias.value.isEmpty) {
              throw const TavernGameplayException(
                code: 'invalid_binding_edit',
                message: 'Aliases require a nonreserved name and a binding target.',
              );
            }
            if (!working.containsKey(alias.value) &&
                _db.select('SELECT 1 FROM gameplay_bindings WHERE binding_id = ?', [alias.value]).isEmpty) {
              throw const TavernGameplayException(
                code: 'binding_not_found',
                message: 'An alias target binding does not exist.',
              );
            }
          }
          for (final issue in _gameplayCastImportIssues(value.value)) {
            if (castImportsRequested.contains(value.bindingId) && issue['code'] != 'cast_source_version_mismatch') {
              throw TavernGameplayException(
                code: issue['code']! as String,
                message: 'The cast import does not identify an adopted character from this pack and local cast.',
                details: issue,
              );
            }
            issues.add(issue);
          }
          final sources = <(String, String, String), Map<String, Object?>>{
            for (final source in value.sourceMap) _gameplaySourceKey(source): source,
          };
          final currentKeys = version == null
              ? <(String, String, String)>{}
              : _gameplayVersionSourceKeys(version).toSet();
          for (final sourceKey in currentKeys) {
            if (sources.containsKey(sourceKey)) {
              continue;
            }
            final source = <String, Object?>{
              'kind': sourceKey.$1,
              'resourceLocalId': sourceKey.$2,
              if (sourceKey.$3.isNotEmpty) 'entryLocalId': sourceKey.$3,
              'stableId': ChatStore._newId(),
            };
            sources[sourceKey] = source;
            value.sourceMap.add(source);
            value.addedSources.add(source);
          }

          final previous = old[value.bindingId];
          final versionChanged = previous == null || previous.packRef.packVersion != value.packVersion;
          final adoptPolicy =
              selectedVersions.contains(value.bindingId) ||
              enableRequested.contains(value.bindingId) && value.enabled && !value.removed ||
              resets.contains(value.bindingId);
          final currentEntries = version != null && (adoptPolicy || versionChanged)
              ? _readGameplayWorldInfoEntries(version, scope.kind)
              : <(String, String, String), WorldInfoEntry>{};
          if (adoptPolicy) {
            for (final entry in currentEntries.entries) {
              final source = sources[entry.key]!;
              final declaration = entry.value.timerDeclarations;
              if (source['wiPolicyEpoch'] == value.onceEpoch) {
                if (!_toolEqual(source['wiPolicy'], declaration)) {
                  throw TavernGameplayException(
                    code: 'timer_policy_conflict',
                    message:
                        'The sticky/cooldown declarations for binding "${value.bindingId}", '
                        'resource "${entry.key.$2}", entry "${entry.key.$3}" changed within the same epoch. '
                        'Use resetOnce or a new binding to adopt them.',
                    details: {
                      'bindingId': value.bindingId,
                      'resourceLocalId': entry.key.$2,
                      'entryLocalId': entry.key.$3,
                      'onceEpoch': value.onceEpoch,
                      'before': source['wiPolicy'],
                      'after': declaration,
                    },
                  );
                }
              } else {
                // A retained declaration from an older epoch is evidence only.
                // A returning entry establishes the current epoch's own baseline.
                source['wiPolicyEpoch'] = value.onceEpoch;
                source['wiPolicy'] = declaration;
                if (!value.addedSources.contains(source)) {
                  value.updatedPolicies.add(source);
                }
              }
            }
          }

          Map<String, Object?> change(Map<String, Object?> source, String kind) => {
            'bindingId': value.bindingId,
            'kind': source['kind'],
            'resourceLocalId': source['resourceLocalId'],
            if (source.containsKey('entryLocalId')) 'entryLocalId': source['entryLocalId'],
            'stableId': source['stableId'],
            'change': kind,
            'beforeEpoch': previous?.onceEpoch,
            'afterEpoch': value.onceEpoch,
          };
          if (versionChanged) {
            final previousVersion = previous == null ? null : _readGameplayVersion(previous.packRef);
            final previousKeys = previousVersion == null
                ? <(String, String, String)>{}
                : _gameplayVersionSourceKeys(previousVersion).toSet();
            for (final sourceKey in currentKeys.difference(previousKeys)) {
              final source = sources[sourceKey]!;
              resourceChanges.add({...change(source, 'added'), 'newIdentity': value.addedSources.contains(source)});
            }
            for (final sourceKey in previousKeys.difference(currentKeys)) {
              resourceChanges.add(change(sources[sourceKey]!, 'removed'));
            }
            if (previousVersion != null && currentEntries.isNotEmpty) {
              final previousEntries = _readGameplayWorldInfoEntries(previousVersion, scope.kind);
              for (final entry in currentEntries.entries) {
                final prior = previousEntries[entry.key];
                if (prior != null) {
                  final beforeDelay = prior.delayDeclaration;
                  final afterDelay = entry.value.delayDeclaration;
                  if (!_toolEqual(beforeDelay, afterDelay)) {
                    resourceChanges.add({
                      ...change(sources[entry.key]!, 'delay_changed'),
                      'before': beforeDelay,
                      'after': afterDelay,
                    });
                  }
                }
              }
            }
          }
          if (previous != null && previous.onceEpoch != value.onceEpoch) {
            // Reset changes every known mapping's next consumption identity,
            // including entries absent from the selected version.
            for (final source in previous.sourceMap) {
              resourceChanges.add(change(source, 'identity_changed'));
            }
          }
        }

        final changedIds = <String>{};
        for (final id in order) {
          final value = working[id]!;
          final previous = old[id];
          if (previous == null || !_toolEqual(previous.toJson(), value.value.toJson())) {
            changedIds.add(id);
            value.bindingRevision = previous == null ? 1 : previous.bindingRevision + 1;
          }
        }
        final changed = changedIds.isNotEmpty;
        result = TavernPackBindingReceipt(
          operationId: operationId,
          snapshot: TavernPackScopeSnapshot(
            scope: scope,
            token: TavernGameplayRevision(
              domainId: before.token.domainId,
              revision: before.token.revision + (changed ? 1 : 0),
            ),
            bindings: [for (final id in order) working[id]!.value],
            issues: issues,
          ),
          createdBindings: created,
          changed: changed,
          resourceChanges: resourceChanges,
        );
        final resultJson = jsonEncode(result.toJson());
        if (changed) {
          _db.execute(
            '''
          INSERT INTO gameplay_scopes (scope, target, revision) VALUES (?, ?, ?)
          ON CONFLICT (scope, target) DO UPDATE SET revision = excluded.revision''',
            [...key, result.snapshot.token.revision],
          );
          for (final id in changedIds) {
            final value = working[id]!;
            _db.execute(
              '''
            INSERT INTO gameplay_bindings
              (binding_id, scope, target, revision, installed_pack_id, pack_version,
               enabled, removed, sort_order, once_epoch, aliases_json, cast_imports_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (binding_id) DO UPDATE SET
              revision = excluded.revision, pack_version = excluded.pack_version,
              enabled = excluded.enabled, removed = excluded.removed,
              sort_order = excluded.sort_order, once_epoch = excluded.once_epoch,
              aliases_json = excluded.aliases_json, cast_imports_json = excluded.cast_imports_json''',
              [
                id,
                ...key,
                value.bindingRevision,
                value.installedPackId,
                value.packVersion,
                value.enabled ? 1 : 0,
                value.removed ? 1 : 0,
                value.order,
                value.onceEpoch,
                jsonEncode(value.aliases),
                jsonEncode({for (final entry in value.castImports.entries) entry.key: entry.value.toJson()}),
              ],
            );
            for (final source in value.addedSources) {
              _db.execute(
                '''
              INSERT INTO gameplay_source_ids
                (binding_id, kind, resource_local_id, entry_local_id, stable_id,
                 wi_policy_epoch, wi_policy_json)
              VALUES (?, ?, ?, ?, ?, ?, ?)''',
                [
                  id,
                  source['kind'],
                  source['resourceLocalId'],
                  source['entryLocalId'] ?? '',
                  source['stableId'],
                  source['wiPolicyEpoch'],
                  source.containsKey('wiPolicy') ? jsonEncode(source['wiPolicy']) : null,
                ],
              );
            }
            for (final source in value.updatedPolicies) {
              _db.execute(
                '''
              UPDATE gameplay_source_ids SET wi_policy_epoch = ?, wi_policy_json = ?
              WHERE binding_id = ? AND kind = ? AND resource_local_id = ? AND entry_local_id = ?''',
                [
                  source['wiPolicyEpoch'],
                  jsonEncode(source['wiPolicy']),
                  id,
                  source['kind'],
                  source['resourceLocalId'],
                  source['entryLocalId'] ?? '',
                ],
              );
            }
          }
        }
        _db.execute(
          '''
        INSERT INTO gameplay_operations (domain_id, operation_id, kind, request_json, result_json)
        VALUES (?, ?, 'update_scope', ?, ?)''',
          [expected.domainId, operationId, requestJson, resultJson],
        );
        return result;
      },
      onCommitted: () {
        onCommitted?.call(result);
      },
    );
  }

  /// Read the definition snapshot carried by an adopted physical state.
  /// A missing row remains missing; current bindings do not reconstruct it.
  Map<String, Object?>? readGameplayEffectiveConfigData(String configId) {
    _ensureOpen();
    final rows = _db.select(
      '''
      SELECT source_vector_json, effective_definitions_json, source_map_json
      FROM gameplay_effective_configs WHERE config_id = ?''',
      [configId],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return {
      'sourceVector': jsonDecode(row['source_vector_json'] as String),
      'effectiveDefinitions': jsonDecode(row['effective_definitions_json'] as String),
      'sourceMap': jsonDecode(row['source_map_json'] as String),
    };
  }

  /// Participates in the caller's actual state-adoption transaction.
  /// Pure resolution never calls this method.
  void ensureGameplayEffectiveConfigData(
    String configId, {
    required Object? sourceVector,
    required Object? effectiveDefinitions,
    required Object? sourceMap,
  }) {
    _ensureOpen();
    if (_db.autocommit) {
      throw StateError('An effective gameplay configuration requires an active adoption transaction.');
    }
    final value = <String, Object?>{
      'sourceVector': sourceVector,
      'effectiveDefinitions': effectiveDefinitions,
      'sourceMap': sourceMap,
    };
    final existing = readGameplayEffectiveConfigData(configId);
    if (existing != null) {
      if (!_toolEqual(existing, value)) {
        throw StateError('The effective gameplay configuration identity has different content.');
      }
      return;
    }
    _db.execute(
      '''
      INSERT INTO gameplay_effective_configs
        (config_id, source_vector_json, effective_definitions_json, source_map_json)
      VALUES (?, ?, ?, ?)''',
      [configId, jsonEncode(sourceVector), jsonEncode(effectiveDefinitions), jsonEncode(sourceMap)],
    );
  }

  List<Map<String, Object?>> _readGameplaySourceMap(String bindingId) => [
    for (final row in _db.select(
      '''
      SELECT kind, char(1) || resource_local_id AS resource_local_id,
        char(1) || entry_local_id AS entry_local_id, stable_id,
        wi_policy_epoch, wi_policy_json
      FROM gameplay_source_ids WHERE binding_id = ? ORDER BY rowid''',
      [bindingId],
    ))
      {
        'kind': row['kind'] as String,
        'resourceLocalId': ChatStore._unguardText(row['resource_local_id'])!,
        if (ChatStore._unguardText(row['entry_local_id'])!.isNotEmpty)
          'entryLocalId': ChatStore._unguardText(row['entry_local_id'])!,
        'stableId': row['stable_id'] as String,
        if (row['wi_policy_epoch'] != null) 'wiPolicyEpoch': row['wi_policy_epoch'] as int,
        if (row['wi_policy_json'] != null)
          'wiPolicy': jsonDecode(row['wi_policy_json'] as String) as Map<String, Object?>,
      },
  ];

  Map<(String, String, String), WorldInfoEntry> _readGameplayWorldInfoEntries(
    TavernPackVersion version,
    TavernGameplayScope scope,
  ) {
    final entries = <(String, String, String), WorldInfoEntry>{};
    for (final resource in gameplayPackResources(version.manifest)) {
      if (resource['kind'] != 'lorebook') {
        continue;
      }
      final resourceId = resource['localId']! as String;
      final rows = _db.select(
        '''
        SELECT bytes FROM gameplay_pack_files
        WHERE installed_pack_id = ? AND pack_version = ? AND path = ?''',
        [version.ref.installedPackId, version.ref.packVersion, resource['path']],
      );
      if (rows.isEmpty) {
        throw StateError('A stored gameplay resource file is missing.');
      }
      final text = decodeAuthoringText(rows.single['bytes'] as Uint8List).text;
      // Match the existing lorebook intake's UTF-8 and object JSON boundary.
      final json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
      if (json is! Map<String, Object?>) {
        throw const FormatException('Gameplay lorebook must be a JSON object.');
      }
      final book = WorldInfoBook.fromJson(
        id: resourceId,
        source: WorldInfoSource.values.byName(scope.name),
        json: json,
      );
      final mappings = <String, String>{};
      for (final raw in resource['entries'] as List<Object?>? ?? const <Object?>[]) {
        final mapping = raw! as Map<String, Object?>;
        mappings[mapping['pointer']! as String] = mapping['localId']! as String;
      }
      for (final entry in book.entries) {
        final entryId = mappings[entry.sourcePointer]!;
        entries[('lorebook', resourceId, entryId)] = entry;
      }
    }
    return entries;
  }

  List<Map<String, Object?>> _gameplayCastImportIssues(TavernPackBinding binding) {
    final issues = <Map<String, Object?>>[];
    for (final entry in binding.castImports.entries) {
      final ref = entry.value;
      Map<String, Object?> issue(String code) => {
        'code': code,
        'bindingId': binding.bindingId,
        'localCastId': entry.key,
        'castImport': ref.toJson(),
      };
      if (entry.key.isEmpty || ref.domainId.isEmpty || ref.operationId.isEmpty) {
        issues.add(issue('invalid_cast_import'));
        continue;
      }
      final saved = readAuthoringOperationData(ref.domainId, ref.operationId);
      if (saved == null) {
        issues.add(issue('cast_import_not_found'));
        continue;
      }
      if (saved.committed != true) {
        issues.add({...issue('cast_import_not_adopted'), 'state': saved.state.name});
        continue;
      }
      final source = saved.request['source'];
      final pack = source is Map<String, Object?> ? source['packRef'] : null;
      if (saved.request['method'] != 'importDshgoCastMember' ||
          saved.request['localCastId'] != entry.key ||
          source is! Map<String, Object?> ||
          (source['kind'] != 'packManifest' && source['kind'] != 'packResource') ||
          pack is! Map<String, Object?> ||
          pack['installedPackId'] != binding.packRef.installedPackId ||
          pack['packVersion'] is! String ||
          (pack['packVersion']! as String).isEmpty ||
          !saved.physicalResourceId.startsWith('character:') ||
          saved.physicalResourceId.length == 'character:'.length ||
          saved.after['present'] != true) {
        issues.add(issue('cast_import_mismatch'));
        continue;
      }
      if (pack['packVersion'] != binding.packRef.packVersion) {
        issues.add({
          ...issue('cast_source_version_mismatch'),
          'sourcePackRef': {'installedPackId': pack['installedPackId'], 'packVersion': pack['packVersion']},
          'selectedPackRef': binding.packRef.toJson(),
          'characterId': saved.physicalResourceId.substring('character:'.length),
        });
      }
    }
    return issues;
  }

  List<Map<String, Object?>> _gameplayScopeTargetIssues(TavernPackScopeTarget scope) => [
    if (scope.kind == TavernGameplayScope.chat &&
        _db.select('SELECT 1 FROM chats WHERE id = ?', [scope.targetId]).isEmpty)
      {'code': 'target_not_found', 'scope': scope.toJson()},
  ];
}

(String, String, String) _gameplaySourceKey(Map<String, Object?> source) =>
    (source['kind']! as String, source['resourceLocalId']! as String, source['entryLocalId'] as String? ?? '');

Iterable<(String, String, String)> _gameplayVersionSourceKeys(TavernPackVersion version) sync* {
  for (final resource in gameplayPackResources(version.manifest)) {
    final kind = resource['kind']! as String;
    final resourceId = resource['localId']! as String;
    yield (kind, resourceId, '');
    for (final raw in resource['entries'] as List<Object?>? ?? const <Object?>[]) {
      final entry = raw! as Map<String, Object?>;
      yield (kind, resourceId, entry['localId']! as String);
    }
  }
}

List<Object?> _gameplayScopeKey(TavernPackScopeTarget scope) {
  if (scope.kind == TavernGameplayScope.global
      ? scope.targetId != null
      : scope.targetId == null || scope.targetId!.isEmpty) {
    throw const TavernGameplayException(
      code: 'invalid_scope',
      message: 'Global has no target; character and chat require their actual target ID.',
    );
  }
  return [scope.kind.name, scope.targetId ?? ''];
}

Map<String, Object?> _gameplayVersionIssue(TavernPackBinding binding, {required bool missing}) => {
  'code': missing ? 'version_not_found' : 'version_unavailable',
  'bindingId': binding.bindingId,
  'packRef': binding.packRef.toJson(),
};

Map<String, TavernCastImportRef> _gameplayCastImportRefs(Map<String, Object?> value) => {
  for (final entry in value.entries)
    entry.key: TavernCastImportRef(
      domainId: (entry.value! as Map<String, Object?>)['domainId']! as String,
      operationId: (entry.value! as Map<String, Object?>)['operationId']! as String,
    ),
};

TavernPackBindingReceipt _gameplayBindingReceipt(Map<String, Object?> value) {
  final saved = value['snapshot']! as Map<String, Object?>;
  final scope = saved['scope']! as Map<String, Object?>;
  final token = saved['token']! as Map<String, Object?>;
  return TavernPackBindingReceipt(
    operationId: value['operationId']! as String,
    snapshot: TavernPackScopeSnapshot(
      scope: TavernPackScopeTarget(
        kind: TavernGameplayScope.values.byName(scope['kind']! as String),
        targetId: scope['targetId'] as String?,
      ),
      token: TavernGameplayRevision(domainId: token['domainId']! as String, revision: token['revision']! as int),
      bindings: [
        for (final raw in saved['bindings']! as List<Object?>) _gameplayBindingFromJson(raw! as Map<String, Object?>),
      ],
      issues: [for (final raw in saved['issues']! as List<Object?>) raw! as Map<String, Object?>],
    ),
    createdBindings: (value['createdBindings']! as Map<String, Object?>).cast<String, String>(),
    changed: value['changed']! as bool,
    resourceChanges: [
      for (final raw in value['resourceChanges'] as List<Object?>? ?? const <Object?>[]) raw! as Map<String, Object?>,
    ],
  );
}

TavernPackBinding _gameplayBindingFromJson(Map<String, Object?> value) {
  final ref = value['packRef']! as Map<String, Object?>;
  return TavernPackBinding(
    bindingId: value['bindingId']! as String,
    bindingRevision: value['bindingRevision']! as int,
    packRef: TavernPackVersionRef(
      installedPackId: ref['installedPackId']! as String,
      packVersion: ref['packVersion']! as String,
    ),
    enabled: value['enabled']! as bool,
    removed: value['removed']! as bool,
    order: value['order']! as int,
    onceEpoch: value['onceEpoch']! as int,
    aliases: (value['aliases']! as Map<String, Object?>).cast<String, String>(),
    castImports: _gameplayCastImportRefs(value['castImports'] as Map<String, Object?>? ?? const {}),
    sourceMap: [for (final raw in value['sourceMap']! as List<Object?>) raw! as Map<String, Object?>],
  );
}

/// Detached database closure for one authoring simulation. Origin tokens are
/// evidence only; bootstrap preserves resource identities but not that domain.
final class StoredGameplaySimulationData {
  const StoredGameplaySimulationData({
    required this.domainId,
    required this.scopes,
    required this.packs,
    required this.configs,
    this.castImports = const {},
  });
  final String domainId;
  final List<TavernPackScopeSnapshot> scopes;
  final Map<
    (String, String),
    ({TavernPackVersion version, Uint8List archive, String inspectionJson, Map<String, Uint8List> files})
  >
  packs;
  final Map<String, ({String sourceVectorJson, String effectiveDefinitionsJson, String sourceMapJson})?> configs;

  /// Only the referenced adopted/published cast rows, in their original domain.
  /// Null records an unresolved reference and is also checked by the final seal.
  final Map<(String, String), Map<String, Object?>?> castImports;
}

extension GameplaySimulationStore on ChatStore {
  /// Reads only the captured scopes, their referenced versions/files, and the
  /// historical explanation IDs actually carried by this sample.
  StoredGameplaySimulationData readGameplaySimulationData(
    StoredGameplaySnapshot snapshot, {
    required Iterable<String> configIds,
  }) {
    _ensureOpen();
    final failure = _transactionFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    final owns = _db.autocommit;
    final managedDepth = _transactionDepth;
    var started = false;
    try {
      if (owns) {
        _db.execute('BEGIN DEFERRED');
        started = true;
      }
      if (authoringDomainId != snapshot.domainId) {
        throw const TavernAuthoringException('capture_conflict', 'The gameplay domain changed during capture.');
      }
      for (final scope in snapshot.scopeSnapshots) {
        if (!_toolEqual(scope.toJson(), _readGameplayScopeData(scope.scope).toJson())) {
          throw const TavernAuthoringException('capture_conflict', 'The gameplay scope changed during capture.');
        }
      }
      final packs =
          <
            (String, String),
            ({TavernPackVersion version, Uint8List archive, String inspectionJson, Map<String, Uint8List> files})
          >{};
      for (final entry in snapshot.packs.entries) {
        final ref = TavernPackVersionRef(installedPackId: entry.key.$1, packVersion: entry.key.$2);
        final version = _readGameplayVersion(ref);
        final prior = entry.value.version;
        if ((version == null) != (prior == null) ||
            version != null &&
                prior != null &&
                (version.digest != prior.digest ||
                    version.removed != prior.removed ||
                    version.availability.domainId != prior.availability.domainId ||
                    version.availability.revision != prior.availability.revision)) {
          throw const TavernAuthoringException('capture_conflict', 'The gameplay version changed during capture.');
        }
        if (version == null) {
          continue;
        }
        final row = _db
            .select(
              '''
          SELECT original_zip, char(1) || inspection_json AS inspection_json
          FROM gameplay_pack_versions
          WHERE installed_pack_id = ? AND pack_version = ?''',
              [ref.installedPackId, ref.packVersion],
            )
            .single;
        final files = <String, Uint8List>{};
        for (final file in _db.select(
          '''
          SELECT char(1) || path AS path, bytes FROM gameplay_pack_files
          WHERE installed_pack_id = ? AND pack_version = ? ORDER BY rowid''',
          [ref.installedPackId, ref.packVersion],
        )) {
          files[ChatStore._unguardText(file['path'])!] = Uint8List.fromList(file['bytes'] as Uint8List);
        }
        packs[entry.key] = (
          version: version,
          archive: Uint8List.fromList(row['original_zip'] as Uint8List),
          inspectionJson: ChatStore._unguardText(row['inspection_json'])!,
          files: files,
        );
      }
      final configs = readGameplayConfigurationRows(configIds);
      final castImports = readGameplayCastImportRows([
        for (final scope in snapshot.scopeSnapshots)
          for (final binding in scope.bindings) ...binding.castImports.values,
      ]);
      final result = StoredGameplaySimulationData(
        domainId: snapshot.domainId,
        scopes: snapshot.scopeSnapshots,
        packs: packs,
        configs: configs,
        castImports: castImports,
      );
      if (owns) {
        _db.execute('COMMIT');
      }
      return result;
    } catch (error, stackTrace) {
      try {
        if (owns && started && !_db.autocommit) {
          _db.execute('ROLLBACK');
        }
        if (!owns && managedDepth > 0 && _db.autocommit) {
          _transactionFailure ??= (error: error, stackTrace: stackTrace);
        }
      } catch (_) {
        _transactionFailure ??= (error: error, stackTrace: stackTrace);
      }
      rethrow;
    }
  }

  /// Fixed journal evidence used both by capture and its final seal. Reads never
  /// publish an adopted row; pending/non-cast rows remain unresolved here.
  Map<(String, String), Map<String, Object?>?> readGameplayCastImportRows(Iterable<TavernCastImportRef> refs) {
    _ensureOpen();
    final result = <(String, String), Map<String, Object?>?>{
      for (final ref in refs) (ref.domainId, ref.operationId): null,
    };
    for (final key in result.keys) {
      final rows = _db.select(
        '''
        SELECT char(1) || domain_id AS domain_id,
          char(1) || operation_id AS operation_id,
          char(1) || physical_resource_id AS physical_resource_id,
          char(1) || request_json AS request_json, base_revision,
          char(1) || before_json AS before_json,
          char(1) || after_json AS after_json,
          char(1) || artifacts_json AS artifacts_json,
          char(1) || state AS state, adopted_revision,
          char(1) || issue_json AS issue_json, created_at, updated_at,
          before_raw_text_id, after_raw_text_id, request_uses_after
        FROM authoring_operations
        WHERE domain_id = ? AND operation_id = ? AND state IN ('adopted', 'published')''',
        [key.$1, key.$2],
      );
      if (rows.isEmpty) {
        continue;
      }
      final row = rows.single;
      final requestJson = ChatStore._unguardText(row['request_json'])!;
      final request = jsonDecode(requestJson) as Map<String, Object?>;
      if (request['method'] != 'importDshgoCastMember') {
        continue;
      }
      // These rows may be copied into an isolated simulation database. Carry
      // portable snapshot JSON, never references to this database's payloads.
      final materialized =
          row['before_raw_text_id'] != null || row['after_raw_text_id'] != null || row['request_uses_after'] == 1
          ? readAuthoringOperationData(key.$1, key.$2)!
          : null;
      result[key] = {
        'domain_id': ChatStore._unguardText(row['domain_id'])!,
        'operation_id': ChatStore._unguardText(row['operation_id'])!,
        'physical_resource_id': ChatStore._unguardText(row['physical_resource_id'])!,
        'request_json': row['request_uses_after'] == 1 ? jsonEncode(materialized!.request) : requestJson,
        'base_revision': row['base_revision'] as int,
        'before_json': materialized == null
            ? ChatStore._unguardText(row['before_json'])!
            : jsonEncode(materialized.before),
        'after_json': materialized == null
            ? ChatStore._unguardText(row['after_json'])!
            : jsonEncode(materialized.after),
        'artifacts_json': ChatStore._unguardText(row['artifacts_json'])!,
        'state': ChatStore._unguardText(row['state'])!,
        'adopted_revision': row['adopted_revision'] as int?,
        'issue_json': ChatStore._unguardText(row['issue_json']),
        'created_at': row['created_at'] as int,
        'updated_at': row['updated_at'] as int,
      };
    }
    return result;
  }

  /// A final seal check preserves an observed missing or malformed historical
  /// row without trying to parse that row ahead of its actual consumer.
  Map<String, ({String sourceVectorJson, String effectiveDefinitionsJson, String sourceMapJson})?>
  readGameplayConfigurationRows(Iterable<String> configIds) {
    _ensureOpen();
    final ids = configIds.toSet().toList();
    final result = <String, ({String sourceVectorJson, String effectiveDefinitionsJson, String sourceMapJson})?>{
      for (final id in ids) id: null,
    };
    if (ids.isEmpty) {
      return result;
    }
    final slots = List.filled(ids.length, '?').join(', ');
    for (final row in _db.select('''
      SELECT char(1) || config_id AS config_id,
        char(1) || source_vector_json AS source_vector_json,
        char(1) || effective_definitions_json AS effective_definitions_json,
        char(1) || source_map_json AS source_map_json
      FROM gameplay_effective_configs WHERE config_id IN ($slots)''', ids)) {
      result[ChatStore._unguardText(row['config_id'])!] = (
        sourceVectorJson: ChatStore._unguardText(row['source_vector_json'])!,
        effectiveDefinitionsJson: ChatStore._unguardText(row['effective_definitions_json'])!,
        sourceMapJson: ChatStore._unguardText(row['source_map_json'])!,
      );
    }
    return result;
  }

  /// Called only inside the simulator's real bootstrap transaction. The temporary
  /// domain stays new. Only referenced, already-adopted cast journal rows cross
  /// as historical evidence; their artifacts are never followed or executed.
  void bootstrapGameplaySimulationData(StoredGameplaySimulationData captured) {
    _ensureOpen();
    if (_db.autocommit) {
      throw StateError('Gameplay simulation bootstrap requires its adoption transaction.');
    }
    final installed = <String>{};
    for (final pack in captured.packs.values) {
      final version = pack.version;
      final ref = version.ref;
      if (installed.add(ref.installedPackId)) {
        _db.execute('INSERT INTO gameplay_packs (installed_pack_id, external_pack_id) VALUES (?, ?)', [
          ref.installedPackId,
          version.externalPackId,
        ]);
      }
      _db.execute(
        '''
        INSERT INTO gameplay_pack_versions
          (installed_pack_id, pack_version, manifest_raw, digest, original_zip,
           inspection_json, availability_revision, removed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          ref.installedPackId,
          ref.packVersion,
          version.manifestRaw,
          version.digest,
          pack.archive,
          pack.inspectionJson,
          version.availability.revision,
          version.removed ? 1 : 0,
        ],
      );
      for (final file in pack.files.entries) {
        _db.execute(
          '''
          INSERT INTO gameplay_pack_files (installed_pack_id, pack_version, path, bytes)
          VALUES (?, ?, ?, ?)''',
          [ref.installedPackId, ref.packVersion, file.key, file.value],
        );
      }
    }
    for (final scope in captured.scopes) {
      if (scope.token.revision == 0) {
        continue;
      }
      final key = _gameplayScopeKey(scope.scope);
      _db.execute('INSERT INTO gameplay_scopes (scope, target, revision) VALUES (?, ?, ?)', [
        ...key,
        scope.token.revision,
      ]);
      for (final binding in scope.bindings) {
        _db.execute(
          '''
          INSERT INTO gameplay_bindings
            (binding_id, scope, target, revision, installed_pack_id, pack_version,
             enabled, removed, sort_order, once_epoch, aliases_json, cast_imports_json)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            binding.bindingId,
            ...key,
            binding.bindingRevision,
            binding.packRef.installedPackId,
            binding.packRef.packVersion,
            binding.enabled ? 1 : 0,
            binding.removed ? 1 : 0,
            binding.order,
            binding.onceEpoch,
            jsonEncode(binding.aliases),
            jsonEncode({for (final entry in binding.castImports.entries) entry.key: entry.value.toJson()}),
          ],
        );
        for (final source in binding.sourceMap) {
          _db.execute(
            '''
            INSERT INTO gameplay_source_ids
              (binding_id, kind, resource_local_id, entry_local_id, stable_id,
               wi_policy_epoch, wi_policy_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)''',
            [
              binding.bindingId,
              source['kind'],
              source['resourceLocalId'],
              source['entryLocalId'] ?? '',
              source['stableId'],
              source['wiPolicyEpoch'],
              source.containsKey('wiPolicy') ? jsonEncode(source['wiPolicy']) : null,
            ],
          );
        }
      }
    }
    for (final row in captured.castImports.values) {
      if (row == null) {
        continue;
      }
      _db.execute(
        '''
        INSERT INTO authoring_operations
          (domain_id, operation_id, physical_resource_id, request_json, base_revision,
           before_json, after_json, artifacts_json, state, adopted_revision,
           issue_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          row['domain_id'],
          row['operation_id'],
          row['physical_resource_id'],
          row['request_json'],
          row['base_revision'],
          row['before_json'],
          row['after_json'],
          row['artifacts_json'],
          row['state'],
          row['adopted_revision'],
          row['issue_json'],
          row['created_at'],
          row['updated_at'],
        ],
      );
    }
    for (final entry in captured.configs.entries) {
      final config = entry.value;
      if (config != null) {
        _db.execute(
          '''
          INSERT INTO gameplay_effective_configs
            (config_id, source_vector_json, effective_definitions_json, source_map_json)
          VALUES (?, ?, ?, ?)''',
          [entry.key, config.sourceVectorJson, config.effectiveDefinitionsJson, config.sourceMapJson],
        );
      }
    }
  }
}
